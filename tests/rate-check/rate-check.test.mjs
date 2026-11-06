import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_rate_check_setup.sql on an empty PGlite database (no live data), on top of the rate setup files.
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
CREATE TABLE public.sku_master(sku_name text,company_id uuid);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,transportation text,order_date timestamptz default now(),
  customer_name text,sales_person text,status text,total_qty numeric,total_amount numeric,total_weight numeric,created_by uuid,approved_by uuid,approved_at timestamptz);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric default 0,rate numeric);
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
const sql=await read('lwb_rate_check_setup.sql');
await db.exec(sql);await db.exec(sql); // safe to run again

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]])}
async function run(who,q,params){await as(who);await db.exec('SET ROLE authenticated');try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}}
// PO saved in one transaction (header, then lines), like PO Entry
async function po(who,no,{party='RAJ STORES',transport='DELIVERY',kg=0,status='pending_approval'},lines){
  await as(who);await db.exec('BEGIN');
  const id=(await db.query(`insert into orders(order_no,customer_name,sales_person,transportation,total_weight,status,created_by) values($1,$2,'Vinas',$3,$4,$5,$6) returning id`,[no,party,transport,kg,status,ids[who]])).rows[0].id;
  for(const [s,q,r] of lines)await db.query(`insert into order_items(order_id,sku_name,ordered_qty,rate) values($1,$2,$3,$4)`,[id,s,q,r]);
  await db.exec('COMMIT');return id;
}
const bells=async id=>(await db.query(`select n.user_id,n.message,n.is_read from erp_notifications n where order_id=$1 and notification_type='ORDER_RATE_CHECK' order by user_id`,[id])).rows;

test('setup: packs, landing per SKU, check margin (Admin only)', async()=>{
  const [p]=(await db.query(`insert into lwb_rate_packs(pack_name,slab3_rate) values('250ML CSD',465) returning id`)).rows.map(r=>r.id);
  await db.query(`insert into lwb_rate_pack_skus(sku_key,pack_id) values('250ML COKE',$1),('300ML THUMS UP',$1)`,[p]);
  await run('admin','select public.lwb_pack_limits_sync($1)',[JSON.stringify([{pack_id:p,landing:450,min_margin:''}])]);
  await assert.rejects(run('head','select public.lwb_rate_check_margin_set(10)'),/Only Admin/);
  await run('admin','select public.lwb_rate_check_margin_set(10)');
  assert.equal((await db.query('select check_margin::float c from lwb_rate_settings')).rows[0].c,10);
});

test('salesman: 1,500 kg order with the 3 & 4 ton rate -> one popup for Admin + Sales Head, PO not stopped', async()=>{
  const o=await po('sales','S-1',{kg:1500},[['250ML COKE',20,465],['300ML THUMS UP',10,470]]);
  assert.equal((await db.query('select status from orders where id=$1',[o])).rows[0].status,'pending_approval');
  const b=await bells(o);
  assert.deepEqual(b.map(x=>x.user_id).sort(),[ids.admin,ids.head].sort());
  assert.match(b[0].message,/250ML COKE ₹465 — Below 3 ton order, 1500 kg \(Slab 1\) needs ₹470/);
  assert.doesNotMatch(b[0].message,/THUMS UP/); // 470 is the right slab rate
  const r=(await db.query('select reasons from lwb_rate_checks where order_id=$1',[o])).rows[0].reasons;
  assert.equal(r.length,1);assert.equal(r[0].kind,'slab');
});

test('low margin: rate below landing + check margin, even on the right slab', async()=>{
  const o=await po('sales','S-2',{kg:4000},[['250ML COKE',50,455]]);
  const m=(await bells(o))[0].message;
  assert.match(m,/margin ₹5.00 \(check below ₹10\)/);
  assert.match(m,/3 & 4 ton order \(Slab 3\) needs ₹465/);
});

test('rate corrected -> unread warning removed; same reasons again -> no second popup', async()=>{
  const o=await po('sales','S-3',{kg:1500},[['250ML COKE',20,465]]);
  assert.equal((await bells(o)).length,2);
  await as('sales');await db.exec('BEGIN');await db.query('update order_items set rate=470 where order_id=$1',[o]);await db.exec('COMMIT');
  assert.equal((await bells(o)).length,0);
  await as('sales');await db.exec('BEGIN');await db.query('update order_items set rate=470 where order_id=$1',[o]);await db.exec('COMMIT');
  assert.equal((await bells(o)).length,0);
});

test('Sales Head own PO: only Admin is told; self pickup and Jagdish slabs; Admin own PO: nothing', async()=>{
  const h=await po('head','H-1',{transport:'SELF PICKUP',kg:900,status:'approved'},[['250ML COKE',10,455]]);
  const b=await bells(h);assert.deepEqual(b.map(x=>x.user_id),[ids.admin]);
  assert.match(b[0].message,/Self pickup \(Slab 2\) needs ₹460/);
  const j=await po('sales','S-4',{party:'SHREE JAGDISH TRADERS',kg:6000},[['250ML COKE',100,460]]);
  assert.equal((await bells(j)).length,0); // 6 ton, but Jagdish party: Slab 4 (460) is right, margin 10 is OK
  const j2=await po('sales','S-4B',{party:'SHREE JAGDISH TRADERS',kg:6000},[['250ML COKE',100,458]]);
  assert.match((await bells(j2))[0].message,/^S-4B · SHREE JAGDISH TRADERS · Vinas · 250ML COKE ₹458 — margin ₹8.00 .*Shree Jagdish party \(Slab 4\) needs ₹460/);
  const a=await po('admin','A-1',{kg:500},[['250ML COKE',10,400]]);
  assert.equal((await bells(a)).length,0);
});

test('check margin off and right slab -> no popup; salesman can not read checks', async()=>{
  await run('admin','select public.lwb_rate_check_margin_set(null)');
  const o=await po('sales','S-5',{kg:4000},[['250ML COKE',50,455]]);
  assert.match((await bells(o))[0].message,/Slab 3\) needs ₹465/);
  const ok=await po('sales','S-6',{kg:4000},[['250ML COKE',50,466]]);
  assert.equal((await bells(ok)).length,0);
  assert.equal((await run('sales','select count(*)::int n from lwb_rate_checks')).rows[0].n,0);
  await assert.rejects(run('sales','select public.lwb_rate_check_reasons($1)',[ok]),/permission denied/);
});
