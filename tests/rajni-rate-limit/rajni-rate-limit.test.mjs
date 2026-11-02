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
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz default now(),
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
const [rg]=(await db.query(`insert into lwb_companies(name,pack_unit) values('RAJNIGANDHA','BOX') returning id`)).rows.map(r=>r.id);
await db.query(`insert into sku_master values('RG POUCH 10',$1),('RG SACHET 5',$1),('RG PEARLS',$1)`,[rg]);
async function order(no,status,lines,by='head'){
  const id=(await db.query(`insert into orders(order_no,customer_name,sales_person,status,total_qty,total_amount,created_by) values($1,'SHREE RAM','Vinas',$2,0,0,$3) returning id`,[no,status,ids[by]])).rows[0].id;
  const pend=status.startsWith('pending');
  for(const [s,q,r] of lines)await db.query(`insert into order_items(order_id,sku_name,ordered_qty,approved_qty,rate) values($1,$2,$3,$4,$5)`,[id,s,q,pend?null:q,r]);
  return id;
}
const read=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(await read('lwb_quick_slip_setup.sql'));
const sql=await read('lwb_rajni_rate_limit_setup.sql');
await db.exec(sql);await db.exec(sql); // safe to run again

async function run(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('SET ROLE authenticated');
  try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}
}
const P={driver_name:'Ramesh',vehicle_no:'GJ02AB1234'};
const LIM=[{sku_key:'rg pouch 10',landing:300,min_rate:330,std_rate:350},{sku_key:'RG SACHET 5',landing:390,min_rate:420,std_rate:440},{sku_key:'RG PEARLS',landing:320,min_rate:'',std_rate:360}];

test('only Admin sets the rate list; sales roles get min / std but never landing', async()=>{
  await assert.rejects(run('head','select public.lwb_price_limits_save($1)',[JSON.stringify(LIM)]),/Only Admin/);
  await assert.rejects(run('admin','select public.lwb_price_limits_save($1)',[JSON.stringify([{sku_key:'X',min_rate:50,std_rate:40}])]),/below Min/);
  assert.equal((await run('admin','select public.lwb_price_limits_save($1) n',[JSON.stringify(LIM)])).rows[0].n,3);
  assert.equal((await run('admin','select public.lwb_price_limits_save($1) n',[JSON.stringify(LIM)])).rows[0].n,0); // nothing changed
  const s=(await run('sales','select public.lwb_sale_rates() v')).rows[0].v;
  assert.equal(s.length,3);assert.ok(s.every(x=>!('landing' in x)));
  assert.equal(s.find(x=>x.sku_key==='RG POUCH 10').min_rate,330);
  await assert.rejects(run('head','select public.lwb_price_limits_get()'),/Only Admin/);
  await assert.rejects(run('sales','select * from lwb_sku_price_limits'),/permission denied/);
  const g=(await run('admin','select public.lwb_price_limits_get() v')).rows[0].v;
  assert.equal(g.can_edit,true);assert.equal(g.rows.length,3);
  assert.equal((await run('admin','select public.lwb_price_history($1) v',['rg pouch 10'])).rows[0].v.length,1);
});

test('Sales Head below min: slip refused, sent to Admin, Admin only approves -> slip + Accounts', async()=>{
  const o=await order('R-1','approved',[['RG POUCH 10',10,350],['RG SACHET 5',5,400]]);
  await assert.rejects(run('head','select public.lwb_quick_slip_dispatch($1,$2)',[o,P]),/RATE_BELOW_MIN: RG SACHET 5 ₹400 \(min ₹420/);
  assert.equal((await db.query('select count(*)::int n from lwb_quick_slips')).rows[0].n,0);
  const r=(await run('head','select public.lwb_rate_request($1,$2,$3) v',[o,P,'competitor 405'])).rows[0].v;
  assert.equal(r.status,'WAITING');assert.equal(r.lines.length,1);
  const n=(await db.query(`select user_id from erp_notifications where notification_type='RATE_APPROVAL' and order_id=$1`,[o])).rows;
  assert.deepEqual(n.map(x=>x.user_id),[ids.admin]);
  // Sales Head sees it waiting, but no landing and cannot approve
  const wh=(await run('head','select public.lwb_rate_waiting() v')).rows[0].v;
  assert.equal(wh.length,1);assert.equal(wh[0].can_approve,false);assert.ok(wh[0].lines.every(l=>l.landing==null));
  await assert.rejects(run('head','select public.lwb_rate_approve($1)',[o]),/Only Admin/);
  const wa=(await run('admin','select public.lwb_rate_waiting() v')).rows[0].v;
  assert.equal(wa[0].can_approve,true);assert.equal(wa[0].note,'competitor 405');
  assert.equal(wa[0].lines.find(l=>l.sku==='RG SACHET 5').landing,390);
  const s=(await run('admin','select public.lwb_rate_approve($1) v',[o])).rows[0].v;
  assert.equal(s.driver_name,'Ramesh');assert.equal(s.vehicle_no,'GJ02AB1234');
  assert.equal((await db.query('select status from orders where id=$1',[o])).rows[0].status,'loaded');
  assert.equal((await run('admin','select public.lwb_rate_waiting() v')).rows[0].v.length,0);
  const ok=(await db.query(`select user_id from erp_notifications where notification_type='RATE_APPROVED' and order_id=$1`,[o])).rows;
  assert.deepEqual(ok.map(x=>x.user_id),[ids.head]);
  // profit: 10*(350-300) + 5*(400-390) = 550
  const p=(await run('admin','select public.lwb_slip_profit(null,null) v')).rows[0].v[o];
  assert.equal(Number(p.landing),4950);assert.equal(Number(p.profit),550);assert.equal(p.rate_ok_by_admin,true);
  // landing change later does not change this slip's profit
  await run('admin','select public.lwb_price_limits_save($1)',[JSON.stringify([{...LIM[0],landing:340}])]);
  assert.equal(Number((await run('admin','select public.lwb_slip_profit(null,null) v')).rows[0].v[o].profit),550);
  await run('admin','select public.lwb_price_limits_save($1)',[JSON.stringify([LIM[0]])]);
});

test('at or above min: slip at once; salesman pending order below min waits too', async()=>{
  const o=await order('R-2','approved',[['RG POUCH 10',2,330],['RG PEARLS',1,1]]); // PEARLS has no min
  const s=(await run('head','select public.lwb_quick_slip_dispatch($1,$2) v',[o,P])).rows[0].v;assert.equal(s.order_no,'R-2');
  const p=(await run('sales','select public.lwb_slip_profit(null,null) v')).rows[0].v;assert.equal(p,null); // salesman sees no profit
  const op=await order('R-3','pending_approval',[['RG SACHET 5',3,410]],'sales');
  await assert.rejects(run('sales','select public.lwb_quick_slip_dispatch($1,$2)',[op,P]),/RATE_BELOW_MIN/);
  await run('sales','select public.lwb_rate_request($1,$2,null)',[op,P]);
  assert.equal((await run('sales','select public.lwb_rate_waiting() v')).rows[0].v.length,1);
  await run('admin','select public.lwb_rate_approve($1)',[op]);
  const o2=(await db.query('select status,approved_by from orders where id=$1',[op])).rows[0];
  assert.equal(o2.status,'loaded');assert.equal(o2.approved_by,ids.admin);
  // request refused when nothing is below min / already slipped
  const o3=await order('R-4','approved',[['RG POUCH 10',1,340]]);
  await assert.rejects(run('head','select public.lwb_rate_request($1,$2,null)',[o3,P]),/no rate below/);
  await assert.rejects(run('head','select public.lwb_rate_request($1,$2,null)',[op,P]),/already/);
});

test('after the slip only Admin can lower a line below min; Admin can slip below min directly', async()=>{
  const o=await order('R-5','approved',[['RG POUCH 10',4,350]]);
  await run('head','select public.lwb_quick_slip_dispatch($1,$2)',[o,P]);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids.head]);
  await assert.rejects(db.query('update order_items set rate=300 where order_id=$1',[o]),/RATE_BELOW_MIN/);
  await db.query('update order_items set rate=340 where order_id=$1',[o]); // still above min: fine
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids.admin]);
  await db.query('update order_items set rate=300 where order_id=$1',[o]);
  const oa=await order('R-6','approved',[['RG SACHET 5',1,100]],'admin');
  assert.equal((await run('admin','select public.lwb_quick_slip_dispatch($1,$2) v',[oa,P])).rows[0].v.order_no,'R-6');
});

test('Admin lets one person see landing and profit', async()=>{
  await assert.rejects(run('head','select public.lwb_price_viewer_set($1,true)',[ids.accounts]),/Only Admin/);
  await run('admin','select public.lwb_price_viewer_set($1,true)',[ids.accounts]);
  assert.equal((await run('accounts','select public.lwb_price_limits_get() v')).rows[0].v.can_edit,false);
  assert.notEqual((await run('accounts','select public.lwb_slip_profit(null,null) v')).rows[0].v,null);
  await assert.rejects(run('accounts','select public.lwb_price_limits_save($1)',['[]']),/Only Admin/);
  await run('admin','select public.lwb_price_viewer_set($1,false)',[ids.accounts]);
  await assert.rejects(run('accounts','select public.lwb_price_limits_get()'),/Only Admin/);
});
