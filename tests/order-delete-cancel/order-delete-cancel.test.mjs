import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_order_delete_cancel_setup.sql on a small copy of the live tables (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000002',
  sales:'00000000-0000-4000-8000-000000000003',godown:'00000000-0000-4000-8000-000000000004',
  driver:'00000000-0000-4000-8000-000000000005',accounts:'00000000-0000-4000-8000-000000000006'};
const role={admin:'admin',manager:'manager',sales:'sales',godown:'warehouse',driver:'driver',accounts:'accounts'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text,
  total_qty numeric,total_amount numeric,total_weight numeric,manager_note text,created_by uuid,
  cancelled_by uuid,cancelled_at timestamptz,cancel_reason text);
CREATE TABLE public.order_items(id uuid default gen_random_uuid() primary key,order_id uuid not null references public.orders(id),
  sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric,rate numeric,unit_weight numeric,amount numeric,total_weight numeric);
CREATE TABLE public.sku_master(id serial primary key,sku_name text);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid references public.orders(id),
  driver_mobile text,loading_manager_id uuid,vehicle_no text);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,
  order_id uuid not null unique references public.orders(id) on delete restrict,
  assignment_id uuid not null references public.dispatch_assignments(id) on delete restrict,delivery_status text);
-- grandchild of a delivery report
CREATE TABLE public.lwb_driver_payments(id serial primary key,report_id uuid references public.lwb_delivery_reports(id),amount numeric);
-- return line pointing at an SKU line
CREATE TABLE public.lwb_driver_return_lines(id serial primary key,order_item_id uuid not null references public.order_items(id),pcs int);
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key references public.orders(id) on delete cascade,invoice_no text);
CREATE TABLE public.lwb_sheet_pallet(id serial primary key,order_id uuid references public.orders(id) on delete set null,qty int);
-- no foreign key, only an order_id column
CREATE TABLE public.erp_notifications(id serial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid);
CREATE FUNCTION public.lwb_driver_phone_matches(a text,b text) RETURNS boolean LANGUAGE sql AS $$ SELECT right(regexp_replace(a,'\\D','','g'),10)=right(regexp_replace(b,'\\D','','g'),10) $$;
INSERT INTO sku_master(sku_name) VALUES ('COKE 250'),('THUMS UP 750'),('SPRITE 2L');
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3,$4)',[id,role[k],k.toUpperCase(),k==='driver'?'+91 98765 43210':null]);
await db.exec(await readFile(new URL('../../lwb_order_delete_cancel_setup.sql',import.meta.url),'utf8'));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');
async function as(r){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[r]])}
async function call(sql,args){await db.exec('SET ROLE authenticated');try{return (await db.query(sql,args)).rows}finally{await db.exec('RESET ROLE')}}
const one=async(sql,args)=>(await db.query(sql,args)).rows[0];
async function order(no,status,{crew=false,items=[['COKE 250',10,10,300,12]]}={}){
  const o=(await one('insert into orders(order_no,customer_name,status,created_by) values($1,$2,$3,$4) returning id',[no,'RAM STORES',status,ids.sales])).id;
  for(const [sku,appr,loaded,rate,wt] of items)await db.query('insert into order_items(order_id,sku_name,ordered_qty,approved_qty,loaded_qty,rate,unit_weight,amount,total_weight) values($1,$2,$3::numeric,$3::numeric,$4::numeric,$5::numeric,$6::numeric,$3::numeric*$5::numeric,$3::numeric*$6::numeric)',[o,sku,appr,loaded,rate,wt]);
  if(crew)await db.query('insert into dispatch_assignments(order_id,driver_mobile,loading_manager_id,vehicle_no) values($1,$2,$3,$4)',[o,'9876543210',ids.godown,'GJ01AB1']);
  return o;
}
const bells=async(o,type)=>(await db.query('select u.role from erp_notifications n join user_profiles u on u.id=n.user_id where n.order_id=$1 and n.notification_type=$2 order by 1',[o,type])).rows.map(r=>r.role);

test('Admin deletes a fully used dummy order with every linked row', async()=>{
  const o=await order('DUMMY-1','loaded',{crew:true});
  const keep=await order('REAL-1','loaded',{crew:true});
  const a=(await one('select id from dispatch_assignments where order_id=$1',[o])).id;
  const rep=(await one("insert into lwb_delivery_reports(order_id,assignment_id,delivery_status) values($1,$2,'DELIVERED') returning id",[o,a])).id;
  await db.query('insert into lwb_driver_payments(report_id,amount) values($1,500)',[rep]);
  await db.query('insert into lwb_driver_return_lines(order_item_id,pcs) select id,2 from order_items where order_id=$1',[o]);
  await db.query("insert into lwb_tally_invoices values($1,'T-1')",[o]);
  await db.query('insert into lwb_sheet_pallet(order_id,qty) values($1,4)',[o]);
  await db.query("insert into erp_notifications(user_id,title,order_id) values($1,'x',$2),($1,'y',$3)",[ids.admin,o,keep]);

  await as('admin');
  const pre=(await call('select lwb_order_delete_preview($1::uuid[]) p',[[o]]))[0].p;
  assert.equal(pre.orders[0].order_no,'DUMMY-1');
  assert.deepEqual(pre.linked,{order_items:1,dispatch_assignments:1,lwb_delivery_reports:1,lwb_driver_payments:1,
    lwb_driver_return_lines:1,lwb_tally_invoices:1,erp_notifications:1});
  assert.equal(Number((await one('select count(*) n from orders')).n),2,'preview changes nothing');

  const r=(await call('select lwb_admin_delete_orders($1::uuid[],$2) r',[[o],'dummy data']))[0].r;
  assert.deepEqual(r.deleted,['DUMMY-1']);
  assert.equal(r.linked.lwb_driver_payments,1);
  assert.equal(Number((await one('select count(*) n from orders where id=$1',[o])).n),0);
  for(const t of ['order_items','dispatch_assignments','lwb_driver_return_lines','lwb_tally_invoices'])
    assert.equal(Number((await one(`select count(*) n from ${t} where ${t==='lwb_driver_return_lines'?'true':'order_id=$1'}`,t==='lwb_driver_return_lines'?[]:[o])).n),0,t);
  assert.equal(Number((await one('select count(*) n from lwb_driver_payments')).n),0);
  assert.equal((await one('select order_id from lwb_sheet_pallet where qty=4')).order_id,null,'SET NULL rows are kept');
  // the other order is untouched
  assert.equal(Number((await one('select count(*) n from order_items where order_id=$1',[keep])).n),1);
  assert.equal(Number((await one('select count(*) n from erp_notifications where order_id=$1',[keep])).n),1);
  const log=await one("select order_no,reason,done_by_name,details from lwb_order_audit where action='DELETE'");
  assert.equal(log.order_no,'DUMMY-1');assert.equal(log.reason,'dummy data');assert.equal(log.details.items.length,1);
});

test('Only Admin can delete; reason and existing orders needed', async()=>{
  const o=await order('DUMMY-2','pending');
  for(const r of ['manager','sales','accounts']){
    await as(r);
    await assert.rejects(call('select lwb_admin_delete_orders($1::uuid[],$2)',[[o],'dummy']),/Only an active Admin/);
    await assert.rejects(call('select lwb_order_delete_preview($1::uuid[])',[[o]]),/Only an active Admin/);
  }
  await as('admin');
  await assert.rejects(call('select lwb_admin_delete_orders($1::uuid[],$2)',[[o],' ']),/Write why/);
  await assert.rejects(call('select lwb_admin_delete_orders($1::uuid[],$2)',[[o,'00000000-0000-4000-8000-0000000000ff'],'dummy']),/already deleted/);
  assert.equal(Number((await one('select count(*) n from orders where id=$1',[o])).n),1,'all or nothing');
  const r=(await call('select lwb_admin_delete_orders($1::uuid[],$2) r',[[o,o],'duplicate']))[0].r;
  assert.deepEqual(r.deleted,['DUMMY-2']);
});

test('Sales Head cancels a loaded order: Godown, Driver and Accounts get a bell', async()=>{
  const o=await order('MKT-1','loaded',{crew:true});
  await as('manager');
  await assert.rejects(call('select lwb_head_cancel_order($1,$2)',[o,'']),/reason is required/);
  const r=(await call('select lwb_head_cancel_order($1,$2,$3) r',[o,'Market cancelled','note x']))[0].r;
  assert.equal(r.status_before,'loaded');
  const row=await one('select status,cancel_reason,cancelled_by,manager_note from orders where id=$1',[o]);
  assert.equal(row.status,'cancelled');assert.equal(row.cancel_reason,'Market cancelled');assert.equal(row.cancelled_by,ids.manager);assert.equal(row.manager_note,'note x');
  assert.deepEqual(await bells(o,'ORDER_CANCELLED'),['accounts','admin','driver','warehouse']);
  await assert.rejects(call('select lwb_head_cancel_order($1,$2)',[o,'again']),/already cancelled/);
});

test('Cancel refused after delivery and for other roles', async()=>{
  const o=await order('MKT-2','loaded',{crew:true});
  const a=(await one('select id from dispatch_assignments where order_id=$1',[o])).id;
  await as('sales');
  await assert.rejects(call('select lwb_head_cancel_order($1,$2)',[o,'no stock']),/Only Admin or Sales Head/);
  await db.query("insert into lwb_delivery_reports(order_id,assignment_id,delivery_status) values($1,$2,'PARTIAL')",[o,a]);
  await as('admin');
  await assert.rejects(call('select lwb_head_cancel_order($1,$2)',[o,'late']),/already delivered/);
  // pending order: no crew bell
  const p=await order('MKT-3','pending');
  await call('select lwb_head_cancel_order($1,$2)',[p,'duplicate']);
  assert.deepEqual(await bells(p,'ORDER_CANCELLED'),[]);
});

test('Sales Head modifies an order while loading: loaded cases cut down, SKU added / removed, totals and bells', async()=>{
  const o=await order('MOD-1','loaded',{crew:true,items:[['COKE 250',10,10,300,12],['THUMS UP 750',5,5,400,10]]});
  const coke=(await one("select id from order_items where order_id=$1 and sku_name='COKE 250'",[o])).id;
  await as('manager');
  const items=[{id:coke,sku_name:'COKE 250',approved_qty:6,rate:300,unit_weight:12},{id:null,sku_name:'SPRITE 2L',approved_qty:2,rate:500,unit_weight:9}];
  await assert.rejects(call('select lwb_head_modify_order($1,$2,$3,$4)',[o,JSON.stringify(items),null,'']),/Write why/);
  const r=(await call('select lwb_head_modify_order($1,$2,$3,$4) r',[o,JSON.stringify(items),'new note','Market cut 4 CS']))[0].r;
  assert.equal(r.changed,3);
  const lines=(await db.query('select sku_name,approved_qty,loaded_qty,amount from order_items where order_id=$1 order by sku_name',[o])).rows;
  assert.deepEqual(lines.map(l=>[l.sku_name,Number(l.approved_qty),Number(l.loaded_qty),Number(l.amount)]),
    [['COKE 250',6,6,1800],['SPRITE 2L',2,0,1000]]);
  const ord=await one('select total_qty,total_amount,total_weight,manager_note,status from orders where id=$1',[o]);
  assert.deepEqual([Number(ord.total_qty),Number(ord.total_amount),Number(ord.total_weight),ord.manager_note,ord.status],[8,2800,90,'new note','loaded']);
  assert.deepEqual(await bells(o,'ORDER_EDITED'),['accounts','admin','driver','warehouse']);
});

test('Modify refused: wrong stage, wrong role, bad SKU, all zero', async()=>{
  const o=await order('MOD-2','approved');
  const l=await order('MOD-3','loading',{crew:true});
  const it=(await one('select id from order_items where order_id=$1',[l])).id;
  await as('manager');
  await assert.rejects(call('select lwb_head_modify_order($1,$2,$3,$4)',[o,'[{"sku_name":"COKE 250","approved_qty":1,"rate":1}]',null,'change']),/only for loading/);
  await assert.rejects(call('select lwb_head_modify_order($1,$2,$3,$4)',[l,'[{"sku_name":"PEPSI","approved_qty":1,"rate":1}]',null,'change']),/SKU Master/);
  await assert.rejects(call('select lwb_head_modify_order($1,$2,$3,$4)',[l,JSON.stringify([{id:it,sku_name:'COKE 250',approved_qty:0,rate:300}]),null,'change']),/above 0/);
  await as('godown');
  await assert.rejects(call('select lwb_head_modify_order($1,$2,$3,$4)',[l,JSON.stringify([{id:it,sku_name:'COKE 250',approved_qty:3,rate:300}]),null,'change']),/Only Admin or Sales Head/);
  await as('admin');
  const r=(await call('select lwb_head_modify_order($1,$2,$3,$4) r',[l,JSON.stringify([{id:it,sku_name:'COKE 250',approved_qty:3,rate:300,unit_weight:12}]),null,'market']))[0].r;
  assert.equal(r.changed,1);
  // loading stage: no Accounts bell yet
  assert.deepEqual(await bells(l,'ORDER_EDITED'),['driver','manager','warehouse']);
});
