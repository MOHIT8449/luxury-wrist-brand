import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_rate_slabs_setup.sql on an empty PGlite database (no live data), on top of the rate setup files.
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
await db.exec(sql);await db.exec(sql); // safe to run again

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


let pack;
const list=async()=>(await run('admin','select code,name,party,transport,min_kg::float,below_kg::float,min_pallets::float,diff::float,is_base,in_image,active from lwb_rate_slabs order by sort_no')).rows;
const why=async id=>((await bells(id))[0]||{}).message||'';

test('seeded with today\'s rule; direct vehicle and 11 pallet are OFF', async()=>{
  [pack]=(await db.query(`insert into lwb_rate_packs(pack_name,slab3_rate) values('250ML CSD',465) returning id`)).rows.map(r=>r.id);
  await db.query(`insert into lwb_rate_pack_skus(sku_key,pack_id) values('250ML COKE',$1),('300ML THUMS UP',$1)`,[pack]);
  const l=await list();
  assert.deepEqual(l.map(x=>[x.code,x.diff,x.active]),[['s4',-5,true],['s2',-5,true],['s6',-10,false],['s5',-5,false],['s1',5,true],['s3',0,true]]);
  assert.equal(l.filter(x=>x.is_base).map(x=>x.code).join(),'s3');
  assert.equal((await run('sales','select count(*)::int n from lwb_rate_slabs')).rows[0].n,6); // salesman reads the rules
});

test('same slabs as before: below 3 ton, 3 & 4 ton, self pickup, Jagdish', async()=>{
  assert.match(await why(await po('sales','A1',{kg:1500},[['250ML COKE',20,465]])),/Below 3 Ton order, 1500 kg needs ₹470/);
  assert.equal((await bells(await po('sales','A2',{kg:4000},[['250ML COKE',50,465]]))).length,0);
  assert.match(await why(await po('sales','A3',{kg:4000},[['250ML COKE',50,464]])),/3 & 4 Ton order, 4000 kg needs ₹465/);
  assert.match(await why(await po('sales','A4',{transport:'SELF PICKUP',kg:900},[['250ML COKE',10,455]])),/Self Pickup needs ₹460/);
  assert.equal((await bells(await po('sales','A5',{party:'SHREE JAGDISH TRADERS',kg:6000},[['250ML COKE',100,460]]))).length,0);
  assert.equal((await bells(await po('sales','A6',{kg:0},[['250ML COKE',10,300]]))).length,0); // no weight yet: no slab
});

test('only Admin / Sales Head save; exactly one Base', async()=>{
  const l=await list();
  await assert.rejects(run('sales','select lwb_rate_slabs_save($1,$2)',[JSON.stringify(l),'[]']),/Only Admin or Sales Head/);
  await assert.rejects(run('admin','select lwb_rate_slabs_save($1,$2)',[JSON.stringify(l.map(x=>({...x,is_base:false}))),'[]']),/exactly one/);
});

test('switch on 11 pallet + direct vehicle, own rate for one pack, remove a slab', async()=>{
  const l=(await list()).map(x=>x.code==='s6'||x.code==='s5'?{...x,active:true}:x).filter(x=>x.code!=='s4');
  await run('head','select lwb_rate_slabs_save($1,$2)',[JSON.stringify(l),JSON.stringify([{pack_id:pack,code:'s6',rate:452}])]);
  assert.equal((await list()).length,5);
  assert.match(await why(await po('sales','B1',{transport:'DIRECT VEHICLE | VEHICLE: GJ01',kg:9000,pal:12},[['250ML COKE',100,451]])),/11 Pallet Vehicle, 12 pallets needs ₹452/);
  assert.equal((await bells(await po('sales','B2',{transport:'DIRECT VEHICLE',kg:9000,pal:12},[['250ML COKE',100,452]]))).length,0);
  assert.match(await why(await po('sales','B3',{transport:'DIRECT VEHICLE',kg:5000,pal:6},[['250ML COKE',100,459]])),/Direct Vehicle needs ₹460/);
  // Jagdish slab removed: Jagdish 6 ton order is now 3 & 4 ton
  assert.match(await why(await po('sales','B4',{party:'SHREE JAGDISH TRADERS',kg:6000},[['250ML COKE',100,460]])),/3 & 4 Ton order, 6000 kg needs ₹465/);
  // case entry (no pallets typed): 1,200 cases / 100 per pallet (SKU Master) = 12 pallets
  await db.query(`update sku_master set cases_per_pallet=100 where sku_name='250ML COKE'`);
  assert.match(await why(await po('sales','B5',{transport:'DIRECT VEHICLE',kg:9000},[['250ML COKE',1200,451]])),/11 Pallet Vehicle, 12 pallets needs ₹452/);
  const own=(await run('sales','select lwb_order_slab_rates() r')).rows[0].r;
  assert.deepEqual(own.map(x=>[x.sku,x.code,+x.rate]),[['250ML COKE','s6',452],['300ML THUMS UP','s6',452]]);
  assert.equal((await run('sales','select count(*)::int n from lwb_rate_slab_rates')).rows[0].n,0); // own rates table: editors only
});
