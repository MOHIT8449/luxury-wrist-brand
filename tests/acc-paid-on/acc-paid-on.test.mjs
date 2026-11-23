import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_accounts_fresh_start_setup.sql on a tiny copy of the Accounts tables (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',manager:'00000000-0000-4000-8000-000000000003'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text);
CREATE TABLE public.lwb_tally_invoices(order_id uuid,invoice_no text);
CREATE TABLE public.lwb_tally_payments(id uuid default gen_random_uuid() primary key,receipt_id uuid,order_id uuid,party text,pay_date date,mode text,amount numeric(14,2),ref_no text,cash_notes jsonb,remark text,created_by uuid,created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,driver_user_id uuid,cash_reported numeric(14,2) default 0,payment_mode text,payment_reference text,cash_amount numeric(14,2),online_amount numeric(14,2),online_mode text,online_reference text,bank_ref text,payment_status text,payment_reviewed_by uuid,payment_reviewed_at timestamptz);
CREATE TABLE public.tax_invoices(id uuid primary key,order_id uuid);
CREATE SCHEMA storage;
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(bucket_id text,name text);
CREATE FUNCTION storage.foldername(text) RETURNS text[] LANGUAGE sql AS $$ SELECT (string_to_array($1,'/'))[1:array_length(string_to_array($1,'/'),1)-1] $$;
CREATE TABLE public.lwb_payment_collections(id uuid default gen_random_uuid() primary key,invoice_id uuid,collection_date date,amount numeric(14,2),payment_mode text,reference_no text,remarks text,status text,submitted_by uuid,submitted_at timestamptz default now(),reviewed_at timestamptz);
CREATE FUNCTION public.lwb_party_parent(p text) RETURNS text LANGUAGE sql STABLE AS $$ SELECT p $$;
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role+' user']);
await db.exec(await sql('lwb_accounts_dashboard_setup.sql'));
await db.exec(`create table lwb_vehicles(id uuid primary key default gen_random_uuid(),vehicle_no text unique,vehicle_type text,ownership text default 'OWN',transporter_name text,is_active boolean default true)`);
await db.exec(await sql('lwb_accounts_staff_setup.sql'));
await db.exec(await sql('lwb_accounts_vehicle_setup.sql'));
await db.exec(await sql('lwb_accounts_cheque_setup.sql'));
await db.exec(`
CREATE TABLE public.lwb_company_payments(id uuid primary key default gen_random_uuid(),company_id uuid,amount numeric,cancelled_at timestamptz,acc_entry_id uuid);
CREATE TABLE public.lwb_bank_stmt_imports(id bigserial primary key,bank_id bigint references lwb_acc_banks(id),file_name text);
CREATE TABLE public.lwb_bank_stmt_lines(id uuid primary key default gen_random_uuid(),bank_id bigint references lwb_acc_banks(id),import_id bigint references lwb_bank_stmt_imports(id),status text,credit numeric);
`);
await db.exec(await sql('lwb_accounts_fresh_start_setup.sql'));
await db.exec(await sql('lwb_accounts_fresh_start_setup.sql')); // safe to run again
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

const today=(await db.query("select public.lwb_acc_today()::text d")).rows[0].d;
const dayAdd=(d,n)=>{const x=new Date(d+'T12:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const n=async t=>Number((await db.query(`select count(*)::int c from ${t}`)).rows[0].c);
await db.exec(await sql('lwb_acc_paid_on_day_setup.sql'));
await db.exec(await sql('lwb_acc_paid_on_day_setup.sql')); // safe to run again
await as('admin');
const pay=async(pd,mode,amt,ago='0 hours')=>(await db.query(`insert into lwb_tally_payments(party,pay_date,mode,amount,created_by,created_at) values('MAA TRADERS',$1,$2,$3,$4,now()-$5::interval) returning id`,[pd,mode,amt,ids.accounts,ago])).rows[0].id;
const day=async(f,t)=>(await call('select public.lwb_acc_dashboard($1,$2) j',[f,t||f]))[0].j;
const has=(d,id)=>d.lines.some(l=>l.id===id);

test('late entry of an old payment goes to its paid on date, not today',async()=>{
 const id=await pay(dayAdd(today,-1),'CASH',32000);
 assert.equal(has(await day(today),id),false);
 const y=await day(dayAdd(today,-1));
 assert.equal(has(y,id),true);
 assert.equal(y.lines.find(l=>l.id===id).date,dayAdd(today,-1));
});

test('today payment stays today; a future paid on date is today',async()=>{
 const a=await pay(today,'UPI',5000),b=await pay(dayAdd(today,3),'CASH',100);
 const t=await day(today);assert.equal(has(t,a),true);assert.equal(has(t,b),true);
});

test('paid on a day closed before the entry = next open day; cash counts after the close',async()=>{
 const c=dayAdd(today,-2);
 await db.query(`insert into lwb_acc_day_close(close_date,opening,expected,counted,closed_by) values($1,0,0,1000,$2)`,[c,ids.accounts]);
 const id=await pay(dayAdd(today,-6),'CASH',700);
 const l=(await db.query('select book_date::text d from public.lwb_acc_lines_all() where id=$1',[id])).rows[0];
 assert.equal(l.d,dayAdd(today,-1));
 // entered BEFORE the close was done = stays on its paid on day
 const old=await pay(dayAdd(today,-3),'CASH',50,'3 days');
 const o=(await db.query('select book_date::text d from public.lwb_acc_lines_all() where id=$1',[old])).rows[0];
 assert.equal(o.d,dayAdd(today,-3));
 const t=(await db.query('select amount from public.lwb_acc_cash_at($1)',[dayAdd(today,1)])).rows[0];
 assert.ok(Number(t.amount)>=1000+700);
});
