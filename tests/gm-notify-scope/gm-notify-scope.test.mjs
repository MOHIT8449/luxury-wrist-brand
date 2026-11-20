import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_gm_notify_scope_setup.sql on an empty PGlite database (no live data).
const ADMIN='00000000-0000-4000-8000-000000000001',HEAD='00000000-0000-4000-8000-000000000002',
  GM1='00000000-0000-4000-8000-000000000003',GM2='00000000-0000-4000-8000-000000000004',ACC='00000000-0000-4000-8000-000000000005';
const O1='10000000-0000-4000-8000-000000000001',O2='10000000-0000-4000-8000-000000000002',O3='10000000-0000-4000-8000-000000000003';
const B1='20000000-0000-4000-8000-000000000001';
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,full_name text,role text,active boolean default true);
CREATE TABLE public.dispatch_assignments(id bigserial primary key,order_id uuid,loading_manager_id uuid);
CREATE TABLE public.lwb_order_pickup(order_id uuid primary key,godown_user_id uuid);
CREATE TABLE public.lwb_goods_inward(id uuid primary key,godown_user_id uuid);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,
  ref_type text,ref_id text,is_read boolean default false,created_at timestamptz default now());
CREATE FUNCTION public.lwb_return_gm(p uuid) RETURNS uuid LANGUAGE sql AS $$
  SELECT loading_manager_id FROM public.dispatch_assignments WHERE order_id=p AND loading_manager_id IS NOT NULL ORDER BY id DESC LIMIT 1 $$;
INSERT INTO user_profiles VALUES ('${ADMIN}','Mohit','admin'),('${HEAD}','Head','manager'),('${GM1}','Vishal','warehouse'),('${GM2}','Raju','Warehouse '),('${ACC}','Acc','accounts');
INSERT INTO dispatch_assignments(order_id,loading_manager_id) VALUES ('${O1}','${GM1}'),('${O2}',NULL);
INSERT INTO lwb_order_pickup VALUES ('${O3}','${GM2}');
INSERT INTO lwb_goods_inward VALUES ('${B1}','${GM1}');
-- an old unread bill-made bell from before the change
INSERT INTO erp_notifications(user_id,title,notification_type,order_id) VALUES ('${GM1}','Bill made','TALLY_BILL_DONE','${O1}');
`);
await db.exec(await readFile(new URL('../../lwb_gm_notify_scope_setup.sql',import.meta.url),'utf8'));
const bell=(u,t,o=null,rt=null,ri=null,title='x')=>db.query(`insert into erp_notifications(user_id,title,notification_type,order_id,ref_type,ref_id) values($1,$2,$3,$4,$5,$6)`,[u,title,t,o,rt,ri]);
const types=async u=>(await db.query(`select notification_type t from erp_notifications where user_id=$1 and created_at is not null order by id`,[u])).rows.map(r=>r.t);

test('old unread other-work bell of a Godown Manager is marked read',async()=>{
  const r=(await db.query(`select is_read from erp_notifications where user_id=$1 and notification_type='TALLY_BILL_DONE'`,[GM1])).rows;
  assert.deepEqual(r,[{is_read:true}]);
});

test('Godown Manager gets only his own loading, purchase, task, return bells',async()=>{
  await db.query(`delete from erp_notifications`);
  for(const t of ['TALLY_BILL_DONE','ORDER_APPROVED','PO_APPROVED_LOADING','BILL_CHANGE_APPROVAL','ORDER_DELIVERED','CC_ORDER_NEW','DELIVERY_RETURN_PENDING','RATE_APPROVAL'])await bell(GM1,t,O1);
  await bell(GM1,'LOADING_ASSIGNMENT_DISPATCH',O1);           // his vehicle
  await bell(GM1,'LOADING_ASSIGNMENT_DISPATCH',O2);           // nobody given -> not sent
  await bell(GM1,'LOADING_ASSIGNMENT_DISPATCH',O3);           // other GM's self pickup
  await bell(GM2,'LOADING_ASSIGNMENT_DISPATCH',O3);           // self pickup given to GM2
  await bell(GM2,'LOADING_ASSIGNMENT_DISPATCH',O1,null,null,'Loading Moved to Another Godown Manager');
  await bell(GM1,'PURCHASE_ARRIVED',null,'PURCHASE_BILL',B1);
  await bell(GM2,'PURCHASE_ARRIVED',null,'PURCHASE_BILL',B1);
  await bell(GM1,'TASK_NEW');await bell(GM1,'CHAT_MSG');await bell(GM1,'ANNOUNCEMENT');
  await bell(GM1,'DELIVERY_RETURN_RECEIVE',O1);await bell(GM2,'DELIVERY_RETURN_RECEIVE',O1);
  assert.deepEqual(await types(GM1),['LOADING_ASSIGNMENT_DISPATCH','PURCHASE_ARRIVED','TASK_NEW','CHAT_MSG','ANNOUNCEMENT','DELIVERY_RETURN_RECEIVE']);
  assert.deepEqual(await types(GM2),['LOADING_ASSIGNMENT_DISPATCH','LOADING_ASSIGNMENT_DISPATCH']);
});

test('other roles are not touched',async()=>{
  await db.query(`delete from erp_notifications`);
  for(const u of [ADMIN,HEAD,ACC])await bell(u,'TALLY_BILL_DONE',O1);
  assert.equal((await db.query(`select count(*)::int n from erp_notifications`)).rows[0].n,3);
});

test('policy check: Godown Manager login sees only his own work',async()=>{
  await db.query(`delete from erp_notifications`);
  await db.query(`alter table erp_notifications disable trigger trg_lwb_gm_bell_filter`);
  await bell(GM1,'TALLY_BILL_DONE',O1);await bell(GM1,'TASK_NEW');
  await db.query(`alter table erp_notifications enable trigger trg_lwb_gm_bell_filter`);
  await db.exec(`create policy own on erp_notifications for select to authenticated using (user_id = auth.uid()); grant select on erp_notifications to authenticated`);
  await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[GM1]);
  await db.query(`set role authenticated`);
  const r=(await db.query(`select notification_type t from erp_notifications`)).rows.map(x=>x.t);
  await db.query(`reset role`);
  assert.deepEqual(r,['TASK_NEW']);
});
