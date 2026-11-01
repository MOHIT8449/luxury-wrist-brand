import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_bill_before_loading_setup.sql on a tiny copy of the tables it reads (no live database).
// Party billing SQL runs first, as on the live database.
const ids={admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',manager:'00000000-0000-4000-8000-000000000003',warehouse:'00000000-0000-4000-8000-000000000004'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
const between=(src,a,b)=>src.slice(src.indexOf(a),src.indexOf(b,src.indexOf(a)));
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid primary key);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text default 'pending',order_date date default current_date,
  total_qty numeric,total_amount numeric,approved_at timestamptz,priority text,created_by uuid);
CREATE TABLE public.order_items(order_id uuid,ordered_qty numeric,approved_qty numeric,loaded_qty numeric,rate numeric);
CREATE TABLE public.dispatch_assignments(order_id uuid,loading_completed_at timestamptz,vehicle_no text,driver_name text,driver_mobile text,loading_manager_id uuid);
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key references orders(id),invoice_no text not null,invoice_date date not null,note text,amount numeric(14,2),bills jsonb not null default '[]',entered_by uuid,entered_at timestamptz default now(),updated_by uuid,updated_at timestamptz);
CREATE TABLE public.lwb_tally_notes(id uuid default gen_random_uuid() primary key,order_id uuid,kind text,note_no text,note_date date,amount numeric(14,2),reason text,created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,driver_user_id uuid,cash_reported numeric(14,2) default 0,delivery_status text,payment_mode text,payment_reference text,cash_amount numeric(14,2),online_amount numeric(14,2),online_mode text,online_reference text,bank_ref text,payment_status text,payment_reviewed_by uuid,payment_reviewed_at timestamptz,reported_at timestamptz default now());
CREATE TABLE public.lwb_driver_delivery_returns(order_id uuid,status text,total_return_amount numeric,reviewed_at timestamptz,created_at timestamptz default now());
CREATE TABLE public.sales_returns(order_id uuid,return_no text,return_date date,total_amount numeric,approval_status text);
CREATE TABLE public.lwb_internal_bills(id uuid default gen_random_uuid() primary key,order_id uuid,internal_bill_no text,bill_date date,order_no text,customer_name text,goods_amount numeric,created_at timestamptz default now());
CREATE TABLE public.tax_invoices(id uuid primary key,order_id uuid,invoice_no text,invoice_date date,grand_total numeric);
CREATE TABLE public.lwb_payment_collections(id uuid default gen_random_uuid() primary key,invoice_id uuid,internal_bill_id uuid,collection_date date,amount numeric(14,2),payment_mode text,reference_no text,remarks text,status text,submitted_by uuid,submitted_at timestamptz default now(),reviewed_at timestamptz);
CREATE TABLE public.lwb_party_opening_balances(id uuid default gen_random_uuid() primary key,customer_name text,as_of_date date,amount numeric(14,2),remarks text,updated_by uuid,updated_at timestamptz default now());
CREATE TABLE public.lwb_customer_master(customer_name text);
CREATE TABLE public.lwb_tally_party_map(tally_key text primary key,tally_name text not null,customer_name text,updated_at timestamptz default now(),updated_by uuid);
CREATE SCHEMA storage;
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(bucket_id text,name text);
CREATE FUNCTION storage.foldername(text) RETURNS text[] LANGUAGE sql AS $$ SELECT (string_to_array($1,'/'))[1:array_length(string_to_array($1,'/'),1)-1] $$;
CREATE FUNCTION public.lwb_tally_staff() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active AND p.role IN ('accounts','admin')) $$;
CREATE FUNCTION public.lwb_tally_check_user() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT public.lwb_tally_staff() $$;
CREATE FUNCTION public.lwb_ledger_viewer() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active AND p.role IN ('accounts','admin','manager')) $$;
CREATE FUNCTION public.lwb_order_bill_numbers(p_order_id uuid) RETURNS TABLE(gross numeric, approved_return numeric, pending_return numeric, net numeric) LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(i.loaded_qty*i.rate),0), 0::numeric, 0::numeric, coalesce(sum(i.loaded_qty*i.rate),0) FROM public.order_items i WHERE i.order_id=p_order_id $$;
CREATE FUNCTION public.lwb_order_posted_collections(p uuid) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT 0::numeric $$;
CREATE FUNCTION public.lwb_order_driver_received(p uuid) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT 0::numeric $$;
CREATE FUNCTION public.lwb_order_return_credit(p uuid) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT 0::numeric $$;
CREATE FUNCTION public.lwb_save_tally_invoice(p_order_id uuid,p_invoice_no text,p_invoice_date date,p_note text) RETURNS text LANGUAGE sql AS $$ SELECT 'stub' $$;
CREATE FUNCTION public.lwb_driver_phone_matches(a text,b text) RETURNS boolean LANGUAGE sql AS $$ SELECT right(a,10)=right(b,10) $$;
`);
const tc=await sql('lwb_cashbook_tally_check_setup.sql');
await db.exec(between(tc,'CREATE OR REPLACE FUNCTION public.lwb_tally_set_party_map','REVOKE ALL ON FUNCTION public.lwb_tally_check_user()'));
for(const [role,id] of Object.entries(ids)){await db.query('insert into auth.users values($1)',[id]);await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role+' user'])}
await db.exec(await sql('lwb_party_payment_collection_setup.sql'));
await db.exec(await sql('lwb_accounts_dashboard_setup.sql'));
await db.exec(await sql('lwb_party_group_billing_setup.sql'));
const fl=await sql('lwb_sales_order_followup_setup.sql');
await db.exec(between(fl,'CREATE OR REPLACE FUNCTION public.lwb_order_pending','-- The signed-in salesman'));
const pop=await sql('lwb_order_flow_popups_setup.sql');
await db.exec(between(pop,'CREATE OR REPLACE FUNCTION public.lwb_flow_send','REVOKE ALL ON FUNCTION public.lwb_flow_send'));
await db.exec(await sql('lwb_bill_before_loading_setup.sql'));
await db.exec(await sql('lwb_bill_before_loading_setup.sql'));  // safe to run again
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated; GRANT SELECT,UPDATE ON orders TO authenticated');

const today=(await db.query("select (now() at time zone 'Asia/Kolkata')::date::text d")).rows[0].d;
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const notes=async(id,type)=>(await db.query('select n.*,p.role from erp_notifications n join user_profiles p on p.id=n.user_id where order_id=$1 and notification_type=$2',[id,type])).rows;
const early=async()=>(await call('select public.lwb_bills_before_loading() j'))[0].j;
const billing=async()=>(await call('select public.lwb_party_billing(400) j'))[0].j;
const saveBill=(id,no,amount)=>call('select public.lwb_save_tally_bills($1,$2,$3::jsonb,null) r',[id,today,JSON.stringify([{no,amount}])]);

let o1,o2;
async function po(no,qty,rate){
 const id=(await db.query("insert into orders(order_no,customer_name,total_qty,total_amount,created_by) values($1,'RAM STORES',$2,$3,$4) returning id",[no,qty,qty*rate,ids.manager])).rows[0].id;
 await db.query('insert into order_items(order_id,ordered_qty,approved_qty,rate) values($1,$2,$2,$3)',[id,qty,rate]);
 return id;
}

test('PO approved: popup to Accounts (make bill) and Godown Manager (get ready), not on later status changes',async()=>{
 o1=await po('PO-1001',10,500);o2=await po('PO-1002',4,250);
 await as('manager');
 await db.query("update orders set status='approved',approved_at=now() where id in ($1,$2)",[o1,o2]);
 const acc=await notes(o1,'PO_APPROVED_BILL'),gdn=await notes(o1,'PO_APPROVED_LOADING');
 assert.deepEqual(acc.map(n=>n.role),['accounts']);
 assert.match(acc[0].message,/PO-1001 · RAM STORES · 10 CS · Rs 5000\.00/);
 assert.deepEqual(gdn.map(n=>n.role),['warehouse']);
 await db.query("update orders set status='transport_allocated' where id=$1",[o1]);
 assert.equal((await notes(o1,'PO_APPROVED_BILL')).length,1);
});

test('Bills to make: approved POs at once, for Accounts / Admin only',async()=>{
 await as('accounts');
 const list=await early();
 assert.deepEqual(list.map(o=>o.order_no).sort(),['PO-1001','PO-1002']);
 assert.equal(Number(list.find(o=>o.order_no==='PO-1001').erp_amount),5000);
 for(const r of ['warehouse','manager']){await as(r);await assert.rejects(call('select public.lwb_bills_before_loading()'),/Admin \/ Accounts/)}
});

test('Tally bill before loading: saved, leaves Bills to make, counts in To collect; pending PO refused',async()=>{
 await as('accounts');
 await saveBill(o1,'T-55',5000);
 assert.deepEqual((await early()).map(o=>o.order_no),['PO-1002']);
 const row=(await billing()).orders.find(o=>o.order_id===o1);
 assert.equal(row.invoice_no,'T-55');
 assert.equal(Number(row.due),5000);
 const p=await po('PO-1003',1,100);
 await assert.rejects(saveBill(p,'T-56',100),/not approved yet/);
});

test('Vehicle loaded on a billed PO: no "Make Tally bill"; Accounts told only when the value differs',async()=>{
 await db.query('update order_items set loaded_qty=approved_qty');
 await as('warehouse');
 await db.query("update orders set status='loaded' where id=$1",[o1]);
 assert.equal((await notes(o1,'TALLY_BILL_PENDING')).length,0);
 assert.equal((await notes(o1,'VEHICLE_LOADED')).filter(n=>n.role==='accounts').length,0);
 assert.equal((await db.query("select count(*)::int c from erp_notifications where order_id=$1 and notification_type='PO_APPROVED_BILL' and not is_read",[o1])).rows[0].c,0);
 // PO-1002 billed for 4 cases, only 3 loaded
 await as('accounts');await saveBill(o2,'T-57',1000);
 await db.query('update order_items set loaded_qty=3 where order_id=$1',[o2]);
 await as('warehouse');
 await db.query("update orders set status='loaded' where id=$1",[o2]);
 const diff=(await notes(o2,'VEHICLE_LOADED')).filter(n=>n.role==='accounts');
 assert.equal(diff.length,1);
 assert.match(diff[0].message,/Tally bill Rs 1000\.00 was made before loading/);
 // a PO loaded without a bill still asks for it
 const p=await po('PO-1004',2,100);
 await db.query("update orders set status='approved' where id=$1",[p]);
 await db.query('update order_items set loaded_qty=2 where order_id=$1',[p]);
 await db.query("update orders set status='loaded' where id=$1",[p]);
 assert.deepEqual((await notes(p,'TALLY_BILL_PENDING')).map(n=>n.role),['accounts']);
});
