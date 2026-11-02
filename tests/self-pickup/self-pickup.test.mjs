import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_self_pickup_driver_setup.sql on an empty PGlite database (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',sales:'00000000-0000-4000-8000-000000000002',
  other:'00000000-0000-4000-8000-000000000003',driver:'00000000-0000-4000-8000-000000000004',
  harsh:'00000000-0000-4000-8000-000000000005',vijayLogin:'00000000-0000-4000-8000-000000000006'};
const roles={admin:'admin',sales:'sales',other:'sales',driver:'driver',harsh:'warehouse',vijayLogin:'warehouse'};
const mobiles={harsh:'9898989898',vijayLogin:'+91 98111 11111'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text,transportation text,created_by uuid);
CREATE TABLE public.lwb_acc_staff(id bigserial primary key,emp_code text,name text,mobile text,designation text,monthly_salary numeric,active boolean default true);
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY own ON public.orders FOR SELECT TO authenticated USING (created_by = auth.uid() OR EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.role='admin'));
GRANT USAGE ON SCHEMA public, auth TO authenticated; GRANT SELECT ON public.orders, public.user_profiles TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3,$4)',[id,roles[k],k==='harsh'?'Harsh Gajera':'Name '+k,mobiles[k]||null]);
const staff=(await db.query(`insert into lwb_acc_staff(emp_code,name,mobile,designation,monthly_salary,active) values
 ('EMP001','Vijay Godown','9811111111','Godown Manager',20000,true),('EMP002','Kalu Loader','9822222222','Loader',12000,true),
 ('EMP003','Old GM','9833333333','godown  manager',0,false) returning id`)).rows.map(r=>r.id);
const ord=(await db.query(`insert into orders(order_no,customer_name,status,transportation,created_by) values
 ('LXY-1','A','pending_approval','SELF PICKUP',$1),('LXY-2','B','pending_approval','DELIVERY',$1),('LXY-3','C','approved','SELF PICKUP',$1) returning id`,[ids.sales])).rows.map(r=>r.id);
const sql=await readFile(new URL('../../lwb_self_pickup_driver_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql); // safe to run again
const searchSql=await readFile(new URL('../../lwb_self_pickup_driver_search.sql',import.meta.url),'utf8');
await db.exec(searchSql);await db.exec(searchSql);
const gmSql=await readFile(new URL('../../lwb_self_pickup_godown_list_fix.sql',import.meta.url),'utf8');
await db.exec(gmSql);await db.exec(gmSql);

async function run(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('SET ROLE authenticated');
  try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}
}

test('godown manager list = active Employee Master Godown Managers only, no salary', async()=>{
  const r=(await run('sales','select public.lwb_pickup_godown_managers() v')).rows[0].v;
  // Employee Master Godown Manager + Godown logins; Vijay's login (same mobile) is shown once
  assert.deepEqual(r.map(x=>x.name),['Harsh Gajera','Vijay Godown']);
  assert.equal(r.find(x=>x.name==='Harsh Gajera').key,'U:'+ids.harsh);
  assert.equal(r.find(x=>x.name==='Vijay Godown').key,'S:'+staff[0]);
  assert.equal(r[0].monthly_salary,undefined);
  await assert.rejects(run('driver','select public.lwb_pickup_godown_managers()'),/not active/);
});

test('salesman saves pickup details on own pending SELF PICKUP order; mobile and vehicle cleaned', async()=>{
  const p={driver_name:'  Ramesh   Patel ',driver_mobile:'+91 98765 43210',vehicle_no:'gj-05 ab 1234',godown_staff_id:String(staff[0])};
  const r=(await run('sales','select public.lwb_set_order_pickup($1,$2) v',[ord[0],p])).rows[0].v;
  assert.equal(r.saved,true);
  const row=(await run('sales','select * from lwb_order_pickup where order_id=$1',[ord[0]])).rows[0];
  assert.equal(row.driver_name,'Ramesh Patel');assert.equal(row.driver_mobile,'9876543210');
  assert.equal(row.vehicle_no,'GJ05AB1234');assert.equal(row.godown_manager_name,'Vijay Godown');
  // another salesman can not read it (orders RLS) nor write it
  assert.equal((await run('other','select * from lwb_order_pickup')).rows.length,0);
  await assert.rejects(run('other','select public.lwb_set_order_pickup($1,$2)',[ord[0],p]),/Only Admin/);
});

test('bad mobile / non-godown employee refused; approved order only for Admin', async()=>{
  await assert.rejects(run('sales','select public.lwb_set_order_pickup($1,$2)',[ord[0],{driver_mobile:'12345'}]),/10-digit/);
  await assert.rejects(run('sales','select public.lwb_set_order_pickup($1,$2)',[ord[0],{godown_staff_id:staff[1]}]),/Godown Manager/);
  await assert.rejects(run('sales','select public.lwb_set_order_pickup($1,$2)',[ord[0],{godown_staff_id:staff[2]}]),/Godown Manager/);
  await assert.rejects(run('sales','select public.lwb_set_order_pickup($1,$2)',[ord[2],{driver_name:'X'}]),/Only Admin/);
  const r=(await run('admin','select public.lwb_set_order_pickup($1,$2) v',[ord[2],{driver_name:'X',vehicle_no:'GJ01'}])).rows[0].v;
  assert.equal(r.saved,true);
});

test('not SELF PICKUP or empty details clears the row', async()=>{
  const r=(await run('sales','select public.lwb_set_order_pickup($1,$2) v',[ord[1],{driver_name:'Y'}])).rows[0].v;
  assert.equal(r.saved,false);
  await run('sales','select public.lwb_set_order_pickup($1,$2)',[ord[0],{}]);
  assert.equal((await db.query('select count(*)::int n from lwb_order_pickup where order_id=$1',[ord[0]])).rows[0].n,0);
  // direct writes are refused
  await assert.rejects(run('admin',"insert into lwb_order_pickup(order_id) values($1)",[ord[0]]),/permission denied/);
});

test('drivers entered before: one row per mobile, newest vehicle first, no drivers login', async()=>{
  const o=(await db.query(`insert into orders(order_no,customer_name,status,transportation,created_by) values
   ('LXY-4','D','pending_approval','SELF PICKUP',$1),('LXY-5','E','pending_approval','SELF PICKUP',$1),('LXY-6','F','pending_approval','SELF PICKUP',$1) returning id`,[ids.sales])).rows.map(r=>r.id);
  await run('admin','select public.lwb_set_order_pickup($1,$2)',[o[0],{driver_name:'Salim',driver_mobile:'9909012345',vehicle_no:'GJ05CX1'}]);
  await db.query("update lwb_order_pickup set updated_at=now()-interval '1 day' where order_id=$1",[o[0]]);
  await run('admin','select public.lwb_set_order_pickup($1,$2)',[o[1],{driver_name:'Salim Bhai',driver_mobile:'9909012345',vehicle_no:'GJ05CX2'}]);
  await run('admin','select public.lwb_set_order_pickup($1,$2)',[o[2],{driver_name:'Raju',vehicle_no:'GJ01'}]);
  const r=(await run('sales','select public.lwb_pickup_drivers() v')).rows[0].v;
  const salim=r.filter(d=>d.driver_mobile==='9909012345');
  assert.equal(salim.length,1);assert.equal(salim[0].vehicle_no,'GJ05CX2');assert.equal(salim[0].times,2);
  assert.ok(r.some(d=>d.driver_name==='Raju'&&d.driver_mobile==null));
  await assert.rejects(run('driver','select public.lwb_pickup_drivers()'),/not active/);
});

test('Godown login picked as Godown Manager is saved by key', async()=>{
  await run('sales','select public.lwb_set_order_pickup($1,$2)',[ord[0],{driver_name:'A',driver_mobile:'9876543210',vehicle_no:'GJ05AB1',godown_key:'U:'+ids.harsh}]);
  const row=(await db.query('select * from lwb_order_pickup where order_id=$1',[ord[0]])).rows[0];
  assert.equal(row.godown_user_id,ids.harsh);assert.equal(row.godown_manager_name,'Harsh Gajera');assert.equal(row.godown_staff_id,null);
  await run('sales','select public.lwb_set_order_pickup($1,$2)',[ord[0],{driver_name:'A',godown_key:'S:'+staff[0]}]);
  assert.equal((await db.query('select godown_manager_name n from lwb_order_pickup where order_id=$1',[ord[0]])).rows[0].n,'Vijay Godown');
  await assert.rejects(run('sales','select public.lwb_set_order_pickup($1,$2)',[ord[0],{godown_key:'U:'+ids.sales}]),/Godown Manager/);
});
