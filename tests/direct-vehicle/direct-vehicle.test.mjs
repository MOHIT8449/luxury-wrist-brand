import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_direct_vehicle_setup.sql on an empty PGlite database.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  acc:'00000000-0000-4000-8000-000000000004',sales:'00000000-0000-4000-8000-000000000005'};
const roles={admin:'ADMIN',head:'MANAGER',acc:'ACCOUNTS',sales:'SALES'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text default 'approved',transportation text,total_amount numeric);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,rate numeric);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k],k]);
const dv=(await db.query("insert into orders(order_no,customer_name,transportation,total_amount) values('LXY-1','Big Party','DIRECT VEHICLE | VEHICLE: GJ05AB1234',5000000) returning id")).rows[0].id;
const del=(await db.query("insert into orders(order_no,customer_name,transportation) values('LXY-2','Small','DELIVERY') returning id")).rows[0].id;
const it=(await db.query("insert into order_items(order_id,sku_name,ordered_qty,approved_qty,rate) values($1,'Coke 2L',1000,null,3000),($1,'Thums Up 1L',1000,900,2000) returning id",[dv])).rows.map(r=>String(r.id));
const sql=await readFile(new URL('../../lwb_direct_vehicle_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql); // safe to run again
async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,a=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,a)).rows}finally{await db.exec('RESET ROLE')}}

test('advance money: staff add, salesman refused, only Direct Vehicle POs', async()=>{
  await as('head');
  await call("select lwb_dv_pay_add($1,current_date,'rtgs',5000000,'UTR1',null)",[dv]);
  await assert.rejects(call("select lwb_dv_pay_add($1,current_date,'RTGS',100,null,null)",[del]),/not a Direct Vehicle/);
  await assert.rejects(call("select lwb_dv_pay_add($1,current_date,'RTGS',0,null,null)",[dv]),/Enter the amount/);
  await as('sales');
  await assert.rejects(call("select lwb_dv_pay_add($1,current_date,'RTGS',100,null,null)",[dv]),/Only Admin/);
  assert.equal((await call('select count(*)::int n from lwb_direct_vehicle_pay'))[0].n,0); // salesman reads nothing
  await as('acc');
  const p=await call('select order_id,mode,amount::numeric a,created_by_name from lwb_direct_vehicle_pay');
  assert.deepEqual(p.map(r=>[r.mode,Number(r.a),r.created_by_name]),[['RTGS',5000000,'head']]);
});

test('final qty: amount = final cases x PO rate, missing lines keep PO qty; balance = final - advance', async()=>{
  await as('acc');
  const r=(await call('select lwb_dv_save($1,7,$2,$3::jsonb,$4,false) r',[dv,'23/11 Order 1',JSON.stringify([{item_id:it[0],cs:1100}]),'+100 Coke']))[0].r;
  assert.equal(Number(r.final_amount),1100*3000+900*2000); // 5,100,000
  assert.equal(Number(r.final_cases),2000);
  const d=(await call('select * from lwb_direct_vehicle where order_id=$1',[dv]))[0];
  assert.equal(d.truck_label,'23/11 Order 1');assert.ok(d.final_at);
  await assert.rejects(call('select lwb_dv_save($1,null,null,$2::jsonb,null,false)',[dv,JSON.stringify([{item_id:'999',cs:1}])]),/only lines of this PO/);
  await assert.rejects(call('select lwb_dv_save($1,null,null,$2::jsonb,null,false)',[dv,JSON.stringify([{item_id:it[0],cs:-1}])]),/0 or more/);
  // clear final
  await call("select lwb_dv_save($1,null,null,'[]'::jsonb,null,false)",[dv]);
  assert.equal((await call('select final_amount from lwb_direct_vehicle where order_id=$1',[dv]))[0].final_amount,null);
});

test('delete money line: Admin / Accounts only', async()=>{
  const id=(await db.query('select id from lwb_direct_vehicle_pay limit 1')).rows[0].id;
  await as('head');
  await assert.rejects(call('select lwb_dv_pay_delete($1)',[id]),/Only Admin or Accounts/);
  await as('admin');
  await call('select lwb_dv_pay_delete($1)',[id]);
  assert.equal((await db.query('select count(*)::int n from lwb_direct_vehicle_pay')).rows[0].n,0);
});

test('cancelled PO refused', async()=>{
  await db.query("update orders set status='cancelled' where id=$1",[dv]);
  await as('admin');
  await assert.rejects(call("select lwb_dv_pay_add($1,current_date,'CASH',10,null,null)",[dv]),/cancelled/);
});
