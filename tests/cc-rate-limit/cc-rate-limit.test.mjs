import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_quick_slip_setup.sql + lwb_rajni_rate_limit_setup.sql on an empty PGlite database (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  accounts:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004'};
const roles={admin:'admin',head:'manager',accounts:'accounts',sales:'sales'};
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
  customer_name text,sales_person text,status text,total_qty numeric,total_amount numeric,created_by uuid,approved_by uuid,approved_at timestamptz);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric default 0,rate numeric);
CREATE TABLE public.dispatch_assignments(order_id uuid);
CREATE TABLE public.lwb_customer_master(customer_name text,mobile text,billing_address text,city text,pincode text,is_active boolean);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false);
CREATE FUNCTION public.lwb_my_companies() RETURNS uuid[] LANGUAGE sql STABLE AS $$ SELECT NULL::uuid[] $$;
CREATE FUNCTION public.lwb_company_ok(p uuid) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT true $$;
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k],k.toUpperCase()]);
const [rg,cc]=(await db.query(`insert into lwb_companies(name,pack_unit) values('RAJNIGANDHA','BOX'),('COCA-COLA','CASE') returning id`)).rows.map(r=>r.id);
await db.query(`insert into sku_master values('RG POUCH 10',$1),('CAN 250',$2),('RGB 200',$2)`,[rg,cc]);
async function order(no,status,lines,by='head'){
  const id=(await db.query(`insert into orders(order_no,customer_name,sales_person,status,total_qty,total_amount,created_by) values($1,'SHREE RAM','Vinas',$2,0,0,$3) returning id`,[no,status,ids[by]])).rows[0].id;
  const pend=status.startsWith('pending');
  for(const [s,q,r] of lines)await db.query(`insert into order_items(order_id,sku_name,ordered_qty,approved_qty,rate) values($1,$2,$3,$4,$5)`,[id,s,q,pend?null:q,r]);
  return id;
}
const read=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(await read('lwb_quick_slip_setup.sql'));
await db.exec(await read('lwb_rate_scheme_setup.sql'));
await db.exec(await read('lwb_order_rates_setup.sql'));
await db.exec(await read('lwb_rajni_rate_limit_setup.sql'));
const sql=await read('lwb_cc_rate_limit_setup.sql');
await db.exec(sql);await db.exec(sql); // safe to run again

async function run(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('SET ROLE authenticated');
  try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}
}

const P={driver_name:'Ramesh',vehicle_no:'GJ02AB1234'};
// sales head saves inside one transaction, like lwb_head_create_approved_po
async function headPo(no,lines,who='head'){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('BEGIN');
  const id=(await db.query(`insert into orders(order_no,customer_name,sales_person,status,created_by,approved_by,approved_at) values($1,'JAY BHAVANI','Harsh','approved',$2,$2,now()) returning id`,[no,ids[who]])).rows[0].id;
  for(const [s,q,r] of lines)await db.query(`insert into order_items(order_id,sku_name,ordered_qty,approved_qty,rate) values($1,$2,$3,$3,$4)`,[id,s,q,r]);
  await db.exec('COMMIT');
  return id;
}
const st=async id=>(await db.query('select status from orders where id=$1',[id])).rows[0].status;
let packCan,packRgb;
test('Admin min margin on a pack -> min rate of its SKUs; Sales Head save keeps the margin', async()=>{
  [packCan,packRgb]=(await db.query(`insert into lwb_rate_packs(pack_name) values('250ML CAN'),('200ML RGB') returning id`)).rows.map(r=>r.id);
  await db.query(`insert into lwb_rate_pack_skus(sku_key,pack_id) values('CAN 250',$1),('RGB 200',$2)`,[packCan,packRgb]);
  assert.equal((await run('admin','select public.lwb_pack_limits_sync($1) n',[JSON.stringify([{pack_id:packCan,landing:402.104,min_margin:10},{pack_id:packRgb,landing:158.4,min_margin:''}])])).rows[0].n,2);
  let l=(await db.query(`select sku_key,landing::float,min_rate::float from lwb_sku_price_limits order by sku_key`)).rows;
  assert.deepEqual(l,[{sku_key:'CAN 250',landing:402.1,min_rate:412.1},{sku_key:'RGB 200',landing:158.4,min_rate:null}]);
  // scheme change saved by the Sales Head: landing moves, his margin is ignored, min moves with landing
  await run('head','select public.lwb_pack_limits_sync($1)',[JSON.stringify([{pack_id:packCan,landing:398,min_margin:0}])]);
  l=(await db.query(`select min_rate::float m from lwb_sku_price_limits where sku_key='CAN 250'`)).rows[0];assert.equal(l.m,408);
  await assert.rejects(run('sales','select public.lwb_pack_limits_sync($1)',['[]']),/Only Admin or Sales Head/);
  await run('admin','select public.lwb_pack_limits_sync($1)',[JSON.stringify([{pack_id:packCan,landing:402.1,min_margin:10}])]);
});

test('Sales Head own PO below min goes back to pending for Admin; Admin approves -> approved', async()=>{
  const o=await headPo('CC-1',[['RGB 200',50,170],['CAN 250',20,405]]);
  assert.equal(await st(o),'pending_approval');
  const a=(await db.query('select status from lwb_rate_approvals where order_id=$1',[o])).rows[0];assert.equal(a.status,'WAITING');
  assert.equal((await db.query(`select count(*)::int n from erp_notifications where notification_type='PO_RATE_APPROVAL' and order_id=$1 and user_id=$2`,[o,ids.admin])).rows[0].n,1);
  const w=(await run('admin','select public.lwb_rate_waiting() v')).rows[0].v.find(x=>x.order_id===o);
  assert.equal(w.slip,false);assert.equal(w.brand,'COCA-COLA');assert.equal(w.lines.find(l=>l.sku==='CAN 250').landing,402.1);
  await run('admin','select public.lwb_rate_approve($1)',[o]);
  const r=(await db.query('select status,approved_by from orders where id=$1',[o])).rows[0];
  assert.equal(r.status,'approved');assert.equal(r.approved_by,ids.admin);
  // later the Sales Head can not lower the line again, Admin can
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids.head]);
  await assert.rejects(db.query(`update order_items set rate=400 where order_id=$1 and sku_name='CAN 250'`,[o]),/RATE_BELOW_MIN/);
  await db.query(`update order_items set rate=420 where order_id=$1 and sku_name='CAN 250'`,[o]);
  await db.query(`update order_items set rate=160 where order_id=$1 and sku_name='RGB 200'`,[o]); // no min on this pack
});

test('Sales Head approving a salesman PO below min: stays pending; at or above min: approved', async()=>{
  const o=(await db.query(`insert into orders(order_no,customer_name,status,created_by) values('CC-2','X','pending_approval',$1) returning id`,[ids.sales])).rows[0].id;
  await db.query(`insert into order_items(order_id,sku_name,ordered_qty,rate) values($1,'CAN 250',5,410)`,[o]);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids.head]);
  await db.query(`update orders set status='approved',approved_by=$2,approved_at=now() where id=$1`,[o,ids.head]);
  assert.equal(await st(o),'pending_approval');
  const ok=await headPo('CC-3',[['CAN 250',5,412.1]]);assert.equal(await st(ok),'approved');
  const adm=await headPo('CC-4',[['CAN 250',5,300]],'admin');assert.equal(await st(adm),'approved');
  // Admin approves the waiting PO from the PO Approval page: rate OK is recorded, Sales Head can't re-route it
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids.admin]);
  await db.query(`update orders set status='approved',approved_by=$2,approved_at=now() where id=$1`,[o,ids.admin]);
  assert.equal(await st(o),'approved');
  assert.equal((await db.query('select status from lwb_rate_approvals where order_id=$1',[o])).rows[0].status,'APPROVED');
  assert.equal((await run('admin','select public.lwb_rate_waiting() v')).rows[0].v.some(x=>x.order_id===o),false);
});

test('Salesman punches a PO below min: Admin bell at once (lines saved after the header)', async()=>{
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids.sales]);
  const o=(await db.query(`insert into orders(order_no,customer_name,sales_person,status,created_by) values('CC-5','PARTY','Vinas','pending_approval',$1) returning id`,[ids.sales])).rows[0].id;
  const bells=async()=>(await db.query(`select count(*)::int n from erp_notifications where notification_type='PO_RATE_APPROVAL' and order_id=$1 and user_id=$2`,[o,ids.admin])).rows[0].n;
  assert.equal(await bells(),0);
  await db.query(`insert into order_items(order_id,sku_name,ordered_qty,rate) values($1,'CAN 250',5,400),($1,'RGB 200',5,150)`,[o]);
  assert.equal(await bells(),1); // one bell, not one per line
  assert.equal(await st(o),'pending_approval'); // still waits for the Sales Head too
  assert.equal((await run('admin','select public.lwb_rate_waiting() v')).rows[0].v.some(x=>x.order_id===o),true);
  await db.query(`update order_items set rate=399 where order_id=$1 and sku_name='CAN 250'`,[o]);
  assert.equal(await bells(),1); // no repeat bell on a change
  // a salesman PO at or above min: no bell
  const ok=(await db.query(`insert into orders(order_no,customer_name,status,created_by) values('CC-6','P','pending_approval',$1) returning id`,[ids.sales])).rows[0].id;
  await db.query(`insert into order_items(order_id,sku_name,ordered_qty,rate) values($1,'CAN 250',5,415)`,[ok]);
  assert.equal((await db.query(`select count(*)::int n from erp_notifications where order_id=$1`,[ok])).rows[0].n,0);
  // Admin approves the rate: PO approved, salesman told
  await run('admin','select public.lwb_rate_approve($1)',[o]);
  assert.equal(await st(o),'approved');
  assert.equal((await db.query(`select count(*)::int n from erp_notifications where notification_type='PO_RATE_APPROVED' and order_id=$1 and user_id=$2`,[o,ids.sales])).rows[0].n,1);
});

test('Rajnigandha slip flow is untouched by the Coca-Cola route', async()=>{
  await run('admin','select public.lwb_price_limits_save($1)',[JSON.stringify([{sku_key:'RG POUCH 10',landing:300,min_rate:330,std_rate:350}])]);
  const o=await headPo('RG-1',[['RG POUCH 10',3,320]]);
  assert.equal(await st(o),'approved'); // slip PO keeps approved, the slip itself is blocked
  await assert.rejects(run('head','select public.lwb_quick_slip_dispatch($1,$2)',[o,P]),/RATE_BELOW_MIN/);
  await run('head','select public.lwb_rate_request($1,$2,null)',[o,P]);
  const s=(await run('admin','select public.lwb_rate_approve($1) v',[o])).rows[0].v;assert.equal(s.driver_name,'Ramesh');
  assert.equal(await st(o),'loaded');
});
