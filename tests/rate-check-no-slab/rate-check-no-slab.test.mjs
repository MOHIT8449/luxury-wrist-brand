import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_rate_check_no_slab_setup.sql on an empty PGlite database (no live data), on top of the rate check + slab files.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  sales:'00000000-0000-4000-8000-000000000004'};
const roles={admin:'admin',head:'manager',sales:'sales'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.lwb_companies(id uuid default gen_random_uuid() primary key,name text,pack_unit text);
CREATE TABLE public.lwb_user_companies(user_id uuid,company_id uuid);
CREATE TABLE public.sku_master(sku_name text,company_id uuid,cases_per_pallet integer);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,transportation text,order_date timestamptz default now(),
  customer_name text,sales_person text,status text,total_qty numeric,total_amount numeric,total_weight numeric,created_by uuid,approved_by uuid,approved_at timestamptz);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,ordered_pallet_qty integer,cases_per_pallet_snapshot integer,approved_qty numeric,loaded_qty numeric default 0,rate numeric);
CREATE TABLE public.dispatch_assignments(order_id uuid);
CREATE TABLE public.lwb_customer_master(customer_name text,mobile text,billing_address text,city text,pincode text,is_active boolean);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false);
CREATE FUNCTION public.lwb_my_companies() RETURNS uuid[] LANGUAGE sql STABLE AS $$ SELECT NULL::uuid[] $$;
CREATE FUNCTION public.lwb_company_ok(p uuid) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT true $$;
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k],k.toUpperCase()]);
const [cc]=(await db.query(`insert into lwb_companies(name,pack_unit) values('COCA-COLA','CASE') returning id`)).rows.map(r=>r.id);
await db.query(`insert into sku_master values('250ML COKE',$1),('300ML THUMS UP',$1)`,[cc]);
const read=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
for(const f of ['lwb_quick_slip_setup.sql','lwb_rate_scheme_setup.sql','lwb_order_rates_setup.sql','lwb_rajni_rate_limit_setup.sql','lwb_cc_rate_limit_setup.sql'])await db.exec(await read(f));
await db.exec(await read('lwb_rate_check_setup.sql'));
const sql=await read('lwb_rate_slabs_setup.sql');
await db.exec(sql);

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]])}
async function run(who,q,params){await as(who);await db.exec('SET ROLE authenticated');try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}}
// PO saved in one transaction (header, then lines), like PO Entry
async function po(who,no,{party='RAJ STORES',transport='DELIVERY',kg=0,status='pending_approval',pal=null},lines){
  await as(who);await db.exec('BEGIN');
  const id=(await db.query(`insert into orders(order_no,customer_name,sales_person,transportation,total_weight,status,created_by) values($1,$2,'Vinas',$3,$4,$5,$6) returning id`,[no,party,transport,kg,status,ids[who]])).rows[0].id;
  for(const [s,q,r] of lines)await db.query(`insert into order_items(order_id,sku_name,ordered_qty,rate,ordered_pallet_qty) values($1,$2,$3,$4,$5)`,[id,s,q,r,pal]);

  await db.exec('COMMIT');return id;
}
const bells=async id=>(await db.query(`select n.user_id,n.message,n.is_read from erp_notifications n where order_id=$1 and notification_type='ORDER_RATE_CHECK' order by user_id`,[id])).rows;

const msgs=async id=>(await bells(id)).filter(b=>!b.is_read).map(b=>b.message);
const reasons=async id=>(await db.query('select reasons from lwb_rate_checks where order_id=$1',[id])).rows[0]?.reasons;

test('before: slab warnings are sent; after the file: old ones cleaned, new ones never sent', async()=>{
  const [pack]=(await db.query(`insert into lwb_rate_packs(pack_name,slab3_rate) values('250ML CSD',465) returning id`)).rows.map(r=>r.id);
  await db.query(`insert into lwb_rate_pack_skus(sku_key,pack_id) values('250ML COKE',$1),('300ML THUMS UP',$1)`,[pack]);
  await run('admin','select public.lwb_pack_limits_sync($1)',[JSON.stringify([{pack_id:pack,landing:450,min_margin:''}])]);
  await run('admin','select public.lwb_rate_check_margin_set(10)');
  const slabOnly=await po('sales','A1',{kg:1729},[['250ML COKE',20,465]]);      // below 3 ton: needs 470
  const both=await po('sales','A2',{kg:4015},[['250ML COKE',50,455],['300ML THUMS UP',5,464]]); // margin 5 + slab
  const read=await po('sales','A3',{kg:1500},[['250ML COKE',20,465]]);
  await db.query(`update erp_notifications set is_read=true where order_id=$1`,[read]);
  assert.match((await msgs(slabOnly))[0],/Below 3 Ton order, 1729 kg needs ₹470/);
  assert.match((await msgs(both))[0],/3 & 4 Ton order, 4015 kg needs ₹465/);

  const fix=await readFile(new URL('../../lwb_rate_check_no_slab_setup.sql',import.meta.url),'utf8');
  await db.exec(fix);await db.exec(fix); // safe to run again

  assert.equal((await msgs(slabOnly)).length,0);                 // only slab reason: bell gone
  assert.deepEqual(await reasons(slabOnly),[]);                  // red mark gone
  const m=await msgs(both);assert.equal(m.length,2);             // Admin + Sales Head keep the margin line
  for(const x of m)assert.equal(x,'A2 · RAJ STORES · Vinas · 250ML COKE ₹455 — margin ₹5.00 (check below ₹10)');
  assert.deepEqual((await reasons(both)).map(r=>r.kind),['margin']);
  assert.equal((await bells(read)).length,2);                    // read bells are history: kept

  assert.equal((await bells(await po('sales','B1',{kg:1200},[['250ML COKE',20,465]]))).length,0); // wrong slab: no bell
  assert.equal((await bells(await po('sales','B2',{transport:'SELF PICKUP',kg:900},[['250ML COKE',10,462]]))).length,0);
  assert.match((await msgs(await po('sales','B3',{kg:1200},[['250ML COKE',20,452]])))[0],/margin ₹2.00 \(check below ₹10\)$/);
  await run('admin','select public.lwb_rate_check_margin_set(null)');
  assert.equal((await bells(await po('sales','B4',{kg:1200},[['250ML COKE',20,300]]))).length,0); // margin off: nothing
});
