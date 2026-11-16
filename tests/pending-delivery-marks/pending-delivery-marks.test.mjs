import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_pending_delivery_marks_fix.sql on an empty PGlite database (no live data):
// a PO marked delivered by Admin is not "pending delivery", even when its status moved on later.
const admin='00000000-0000-4000-8000-000000000001';
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,full_name text,role text,active boolean);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz default now(),created_at timestamptz default now(),
  customer_name text,status text,total_qty numeric default 10,total_amount numeric default 1000,total_weight numeric default 100,priority text default 'NORMAL');
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric default 0,rate numeric);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,loading_started_at timestamptz,loading_completed_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(order_id uuid,delivery_status text,reported_at timestamptz default now());
CREATE TABLE public.lwb_tally_invoices(order_id uuid);
CREATE TABLE public.lwb_user_page_access(user_id uuid primary key,hidden text[] not null default '{}',updated_at timestamptz,updated_by uuid);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
await db.query(`insert into user_profiles values($1,'Mohit','admin',true)`,[admin]);
await db.exec(await readFile(new URL('../../lwb_admin_mark_load_deliver_setup.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../../lwb_pending_delivery_marks_fix.sql',import.meta.url),'utf8'));
await db.query("select set_config('request.jwt.claim.sub',$1,false)",[admin]);
const today=(await db.query(`select (now() at time zone 'Asia/Kolkata')::date::text d`)).rows[0].d;
const order=async(no,status)=>(await db.query(`insert into orders(order_no,customer_name,status) values($1,'PARTY',$2) returning id`,[no,status])).rows[0].id;

const waiting=await order('P-1','pending_approval');
const assigned=await order('P-2','transport_allocated');
const markedThenBilled=await order('P-3','loaded');
const driverDone=await order('P-4','loaded');
await order('P-5','cancelled');
await db.query('select lwb_admin_mark_order($1,false,true,$2::date,null)',[markedThenBilled,today]);
await db.query(`update orders set status='invoiced' where id=$1`,[markedThenBilled]); // status moved on after the mark
await db.query(`insert into lwb_delivery_reports(order_id,delivery_status) values($1,'DELIVERED')`,[driverDone]);

test('pending delivery leaves out Admin-marked and driver-delivered POs',async()=>{
  const s=(await db.query('select lwb_po_approval_summary($1::date,$1::date) s',[today])).rows[0].s;
  assert.equal(Number(s.pending.count),2);
  assert.equal(Number(s.delivered.count),2);
  const list=(await db.query(`select id from lwb_po_summary_orders('pending',null,null)`)).rows.map(r=>r.id).sort();
  assert.deepEqual(list,[waiting,assigned].sort());
});

test('delivered list counts the Admin mark by its date',async()=>{
  const list=(await db.query(`select id from lwb_po_summary_orders('delivered',$1::date,$1::date)`,[today])).rows.map(r=>r.id).sort();
  assert.deepEqual(list,[markedThenBilled,driverDone].sort());
});
