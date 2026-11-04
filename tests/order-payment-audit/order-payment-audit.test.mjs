import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_order_payment_audit_fixes.sql (4 Nov 2026 audit) on a tiny copy of the tables it reads (no live database).
// Party billing, bill-before-loading and order cancel SQL run first, as on the live database.
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
  total_qty numeric,total_amount numeric,approved_at timestamptz,priority text,created_by uuid,manager_note text,cancelled_by uuid,cancelled_at timestamptz,cancel_reason text);
CREATE TABLE public.order_items(order_id uuid,ordered_qty numeric,approved_qty numeric,loaded_qty numeric,rate numeric);
CREATE TABLE public.dispatch_assignments(order_id uuid,loading_completed_at timestamptz,vehicle_no text,driver_name text,driver_mobile text,loading_manager_id uuid);
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key references orders(id),invoice_no text not null,invoice_date date not null,note text,amount numeric(14,2),bills jsonb not null default '[]',entered_by uuid,entered_at timestamptz default now(),updated_by uuid,updated_at timestamptz);
CREATE TABLE public.lwb_tally_notes(id uuid default gen_random_uuid() primary key,order_id uuid,kind text,note_no text,note_date date,amount numeric(14,2),reason text,created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,driver_user_id uuid,cash_reported numeric(14,2) default 0,delivery_status text,payment_mode text,payment_reference text,cash_amount numeric(14,2),online_amount numeric(14,2),online_mode text,online_reference text,bank_ref text,payment_status text,payment_reviewed_by uuid,payment_reviewed_at timestamptz,reported_at timestamptz default now(),
  collection_review_status text,cash_notes jsonb,online_photo_paths text[],payment_saved_at timestamptz,payment_review_note text,office_received boolean default false);
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
await db.exec(await sql('lwb_order_delete_cancel_setup.sql'));
await db.exec(await sql('lwb_order_payment_audit_fixes.sql'));
await db.exec(await sql('lwb_order_payment_audit_fixes.sql'));  // safe to run again
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated; GRANT SELECT,UPDATE ON orders TO authenticated');

const today=(await db.query("select (now() at time zone 'Asia/Kolkata')::date::text d")).rows[0].d;
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const saveBill=(id,no,amount)=>call('select public.lwb_save_tally_bills($1,$2,$3::jsonb,null) r',[id,today,JSON.stringify([{no,amount}])]);
const receive=(rep,cash,online,ref)=>call('select public.lwb_office_receive_driver_payment($1,$2::jsonb,$3,$4,$5,null) r',[rep,JSON.stringify(cash),online,online?'UPI':null,ref||null]);
const cancel=id=>call('select public.lwb_head_cancel_order($1,$2) r',[id,'market cancelled']);
const officePay=(id,amt)=>db.query("insert into lwb_tally_payments(receipt_id,order_id,pay_date,mode,amount,created_by) values(gen_random_uuid(),$1,current_date,'UPI',$2,$3)",[id,amt,ids.accounts]);
const note=(id,amt)=>db.query("insert into lwb_tally_notes(order_id,kind,note_no,note_date,amount) values($1,'CREDIT','CN-1',current_date,$2)",[id,amt]);

async function po(no,qty,rate,status='loaded'){
 const id=(await db.query("insert into orders(order_no,customer_name,total_qty,total_amount,created_by,status) values($1,'RAM STORES',$2,$3,$4,$5) returning id",[no,qty,qty*rate,ids.manager,status])).rows[0].id;
 await db.query('insert into order_items(order_id,ordered_qty,approved_qty,loaded_qty,rate) values($1,$2,$2,$2,$3)',[id,qty,rate]);
 return id;
}
const report=async(id,cash=0)=>(await db.query("insert into lwb_delivery_reports(order_id,delivery_status,cash_reported,payment_status) values($1,'DELIVERED',$2,$3) returning id",[id,cash,cash?'PENDING':null])).rows[0].id;

test('Driver money: office can not take more than is still due after office payment / credit note',async()=>{
 const o=await po('PO-2001',10,500);  // loaded Rs 5000
 await as('accounts');await saveBill(o,'T-1',5000);
 await officePay(o,3000);  // party paid Rs 3000 at the office
 const rep=await report(o,2000);  // driver says he got Rs 2000 (waiting)
 await assert.rejects(receive(rep,{"500":6},0),/more than the money still due on this PO \(Rs 2000\.00\)/);
 const r=(await receive(rep,{"500":4},0))[0].r;
 assert.equal(Number(r.received),2000);
 assert.equal(Number(r.outstanding),0);
});

test('Driver money: a credit note lowers what can be received; Tally bill above loaded value can be received in full',async()=>{
 const o=await po('PO-2002',10,500);
 await as('accounts');await saveBill(o,'T-2',5000);await note(o,1000);
 const rep=await report(o);
 await assert.rejects(receive(rep,{"500":10},0),/still due on this PO \(Rs 4000\.00\)/);
 assert.equal(Number((await receive(rep,{"500":8},0))[0].r.outstanding),0);
 const p=await po('PO-2003',10,500);
 await saveBill(p,'T-3',5250);  // Tally bill more than loaded value
 const rep2=await report(p);
 const r=(await receive(rep2,{"500":10},250,'UTR998877'))[0].r;
 assert.equal(Number(r.received),5250);
});

test('Driver money: no Tally bill yet, limit is loaded value minus office money',async()=>{
 const o=await po('PO-2004',4,250);
 await officePay(o,600);
 const rep=await report(o);
 await as('accounts');
 await assert.rejects(receive(rep,{"500":1},0),/still due on this PO \(Rs 400\.00\)/);
 assert.equal(Number((await receive(rep,{"200":2},0))[0].r.received),400);
});

test('Cancel: refused while a Tally bill is due or money is taken; allowed after a full credit note',async()=>{
 const o=await po('PO-2005',2,500);
 await as('accounts');await saveBill(o,'T-5',1000);
 await as('manager');
 await assert.rejects(cancel(o),/Tally bill T-5 \(Rs 1000\.00\) is made for PO PO-2005/);
 await officePay(o,100);
 await assert.rejects(cancel(o),/Rs 100\.00 is already received on PO PO-2005/);
 await db.query('update lwb_tally_payments set cancelled_at=now() where order_id=$1',[o]);
 await note(o,1000);
 assert.equal((await cancel(o))[0].r.order_no,'PO-2005');
 assert.equal((await db.query('select status from orders where id=$1',[o])).rows[0].status,'cancelled');
});

test('Cancel: a PO with no Tally bill cancels as before',async()=>{
 const o=await po('PO-2006',2,500,'approved');
 await as('manager');
 assert.equal((await cancel(o))[0].r.status_before,'approved');
});
