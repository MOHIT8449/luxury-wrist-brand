import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_admin_mark_load_deliver_setup.sql on an empty PGlite database (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',accounts:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004',head2:'00000000-0000-4000-8000-000000000005'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,full_name text,role text,active boolean);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz default now(),customer_name text,status text);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric default 0,rate numeric);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,loading_started_at timestamptz,loading_completed_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(order_id uuid,delivery_status text,reported_at timestamptz default now());
CREATE TABLE public.lwb_tally_invoices(order_id uuid);
CREATE TABLE public.lwb_user_page_access(user_id uuid primary key,hidden text[] not null default '{}',updated_at timestamptz,updated_by uuid);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
await db.query(`insert into user_profiles values($1,'Mohit','admin',true),($2,'Vinesh','manager',true),($3,'Yogesh','accounts',true),($4,'Ravi','sales',true),($5,'Old Head','manager',true)`,[ids.admin,ids.head,ids.accounts,ids.sales,ids.head2]);
await db.exec(await readFile(new URL('../../lwb_admin_mark_load_deliver_setup.sql',import.meta.url),'utf8'));
async function order(no,status,{assign=false,days=0}={}){
  const id=(await db.query(`insert into orders(order_no,customer_name,status,order_date) values($1,'SHREE KRISHNA',$2,now()-make_interval(days=>$3)) returning id`,[no,status,days])).rows[0].id;
  await db.query(`insert into order_items(order_id,sku_name,ordered_qty,approved_qty,rate) values($1,'COKE',10,8,100),($1,'FANTA',5,null,50)`,[id]);
  if(assign)await db.query('insert into dispatch_assignments(order_id) values($1)',[id]);
  return id;
}
async function as(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  return db.query(q,params);
}
const today=(await db.query(`select (now() at time zone 'Asia/Kolkata')::date::text d`)).rows[0].d;
const mark=(who,id,l,d,date=today,note=null)=>as(who,'select lwb_admin_mark_order($1,$2,$3,$4::date,$5) r',[id,l,d,date,note]).then(x=>x.rows[0].r);

test('only Admin or an allowed Sales Head can mark',async()=>{
  const o=await order('P-1','approved');
  await assert.rejects(mark('accounts',o,true,false),/Only Admin/);
  await assert.rejects(mark('sales',o,true,false),/Only Admin/);
  // Admin turned it off for this Sales Head (Manage Users > Pages)
  await db.query(`insert into lwb_user_page_access(user_id,hidden) values($1,'{warehouse-orders.html#mark}')`,[ids.head2]);
  await assert.rejects(mark('head2',o,true,false),/Only Admin/);
  assert.equal((await as('head2','select lwb_can_mark_po() ok')).rows[0].ok,false);
  assert.equal((await as('head','select lwb_can_mark_po() ok')).rows[0].ok,true);
});

test('Sales Head marks Loaded + Delivered; log keeps his role',async()=>{
  const o=await order('P-11','approved');
  const r=await mark('head',o,true,true);
  assert.deepEqual(r.marked,['LOADED','DELIVERED']);
  const m=(await as('admin','select * from lwb_admin_order_marks($1) order by kind',[[o]])).rows;
  assert.deepEqual(m.map(x=>[x.kind,x.marked_by_name,x.marked_by_role]),[['DELIVERED','Vinesh','MANAGER'],['LOADED','Vinesh','MANAGER']]);
  const b=(await db.query(`select title from erp_notifications where order_id=$1 and user_id=$2`,[o,ids.accounts])).rows[0];
  assert.match(b.title,/^Sales Head marked/);
  // a re-mark by Admin later shows ADMIN
  const o2=await order('P-12','approved');
  await mark('admin',o2,true,false);
  assert.equal((await as('head','select * from lwb_admin_order_marks($1)',[[o2]])).rows[0].marked_by_role,'ADMIN');
});

test('Loaded: status, loaded qty, transport times, log, Accounts bell',async()=>{
  const o=await order('P-2','transport_allocated',{assign:true,days:3});
  const d=(await db.query(`select ((now() at time zone 'Asia/Kolkata')::date-2)::text d`)).rows[0].d;
  const r=await mark('admin',o,true,false,d,'Godown did not press Loaded');
  assert.equal(r.status,'loaded');assert.deepEqual(r.marked,['LOADED']);
  assert.equal((await db.query('select status from orders where id=$1',[o])).rows[0].status,'loaded');
  assert.deepEqual((await db.query('select loaded_qty::int q from order_items where order_id=$1 order by id',[o])).rows.map(x=>x.q),[8,5]);
  const a=(await db.query(`select (loading_completed_at at time zone 'Asia/Kolkata')::text t from dispatch_assignments where order_id=$1`,[o])).rows[0];
  assert.equal(a.t,d+' 12:00:00');
  const m=(await as('accounts','select * from lwb_admin_order_marks($1)',[[o]])).rows;
  assert.equal(m.length,1);assert.equal(m[0].kind,'LOADED');assert.equal(m[0].marked_by_name,'Mohit');assert.equal(m[0].old_status,'transport_allocated');
  assert.equal((await db.query(`select count(*)::int n from erp_notifications where order_id=$1 and notification_type='TALLY_BILL_PENDING' and user_id=$2`,[o,ids.accounts])).rows[0].n,1);
  await assert.rejects(mark('admin',o,true,false),/already loaded/);
});

test('Delivered on an approved PO marks loaded + delivered; shows as delivered',async()=>{
  const o=await order('P-3','approved');
  const r=await mark('admin',o,true,true);
  assert.equal(r.status,'delivered');assert.deepEqual(r.marked,['LOADED','DELIVERED']);
  const dl=(await as('head','select * from lwb_po_delivered_orders($1)',[[o]])).rows;
  assert.equal(dl.length,1);
  await assert.rejects(mark('admin',o,false,true),/already delivered/);
});

test('Delivered only on a loaded PO; refused when the driver reported delivery',async()=>{
  const o=await order('P-4','loaded');
  const r=await mark('admin',o,false,true);
  assert.deepEqual(r.marked,['DELIVERED']);assert.equal(r.status,'delivered');
  const o2=await order('P-5','loaded');
  await db.query(`insert into lwb_delivery_reports(order_id,delivery_status) values($1,'DELIVERED')`,[o2]);
  await assert.rejects(mark('admin',o2,false,true),/already delivered/);
});

test('bad input: pending / cancelled, future date, date before PO, nothing chosen',async()=>{
  const p=await order('P-6','pending_approval');
  await assert.rejects(mark('admin',p,true,false),/not approved/);
  await assert.rejects(mark('admin',p,false,true),/not approved/);
  const c=await order('P-7','cancelled');
  await assert.rejects(mark('admin',c,true,true),/not approved/);
  const o=await order('P-8','approved');
  const fut=(await db.query(`select ((now() at time zone 'Asia/Kolkata')::date+1)::text d`)).rows[0].d;
  await assert.rejects(mark('admin',o,true,false,fut),/today or before/);
  const old=(await db.query(`select ((now() at time zone 'Asia/Kolkata')::date-5)::text d`)).rows[0].d;
  await assert.rejects(mark('admin',o,true,false,old),/before the PO date/);
  await assert.rejects(mark('admin',o,false,false),/Choose Loaded or Delivered/);
});

test('no Accounts bell when the Tally bill is made already',async()=>{
  const o=await order('P-9','approved');
  await db.query('insert into lwb_tally_invoices values($1)',[o]);
  await mark('admin',o,true,false);
  assert.equal((await db.query(`select count(*)::int n from erp_notifications where order_id=$1`,[o])).rows[0].n,0);
});

test('status check without delivered: keeps loaded, mark still counts',async()=>{
  await db.exec(`ALTER TABLE orders ADD CONSTRAINT st CHECK (status IN ('approved','loaded','pending_approval','cancelled','transport_allocated','delivered_x')) NOT VALID`);
  const o=await order('P-10','approved');
  const r=await mark('admin',o,true,true);
  assert.equal(r.status,'loaded');assert.deepEqual(r.marked,['LOADED','DELIVERED']);
  assert.equal((await db.query('select status from orders where id=$1',[o])).rows[0].status,'loaded');
  assert.equal((await as('admin','select * from lwb_po_delivered_orders($1)',[[o]])).rows.length,1);
});
