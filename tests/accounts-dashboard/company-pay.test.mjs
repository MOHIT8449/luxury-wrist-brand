import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_accounts_dashboard_setup.sql on a tiny copy of the tables it reads (no live database).
const ids={warehouse:'00000000-0000-4000-8000-000000000006',admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',manager:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004',driver:'00000000-0000-4000-8000-000000000005'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text);
CREATE TABLE public.lwb_tally_invoices(order_id uuid,invoice_no text);
CREATE TABLE public.lwb_tally_payments(id uuid default gen_random_uuid() primary key,receipt_id uuid,order_id uuid,pay_date date,mode text,amount numeric(14,2),ref_no text,cash_notes jsonb,remark text,created_by uuid,created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,driver_user_id uuid,cash_reported numeric(14,2) default 0,payment_mode text,payment_reference text,cash_amount numeric(14,2),online_amount numeric(14,2),online_mode text,online_reference text,bank_ref text,payment_status text,payment_reviewed_by uuid,payment_reviewed_at timestamptz);
CREATE TABLE public.tax_invoices(id uuid primary key,order_id uuid);
CREATE SCHEMA storage;
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(bucket_id text,name text);
CREATE FUNCTION storage.foldername(text) RETURNS text[] LANGUAGE sql AS $$ SELECT (string_to_array($1,'/'))[1:array_length(string_to_array($1,'/'),1)-1] $$;
CREATE TABLE public.lwb_payment_collections(id uuid default gen_random_uuid() primary key,invoice_id uuid,collection_date date,amount numeric(14,2),payment_mode text,reference_no text,remarks text,status text,submitted_by uuid,submitted_at timestamptz default now(),reviewed_at timestamptz);
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role+' user']);
await db.exec(await readFile(new URL('../../lwb_accounts_dashboard_setup.sql',import.meta.url),'utf8'));
await db.exec(`create table lwb_vehicles(id uuid primary key default gen_random_uuid(),vehicle_no text unique,vehicle_type text,ownership text default 'OWN',transporter_name text,is_active boolean default true)`);
await db.exec(await readFile(new URL('../../lwb_accounts_staff_setup.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../../lwb_accounts_vehicle_setup.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../../lwb_accounts_cheque_setup.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../../lwb_employee_master_setup.sql',import.meta.url),'utf8'));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

const today=(await db.query("select public.lwb_acc_today()::text d")).rows[0].d;
const dayAdd=(d,n)=>{const x=new Date(d+'T12:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(sql,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(sql,args)).rows}finally{await db.exec('RESET ROLE')}}
const cat=async(kind,name)=>(await db.query('select id from lwb_acc_categories where kind=$1 and name=$2',[kind,name])).rows[0].id;

// lwb_accounts_company_pay_setup.sql: company payment entered once as Cash Out; bank suspense count.
await db.exec(`
CREATE TABLE public.lwb_companies(id uuid primary key default gen_random_uuid(),name text);
CREATE TABLE public.lwb_company_payments(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),company_id uuid NOT NULL REFERENCES public.lwb_companies(id),pay_date date NOT NULL,
  amount numeric(14,2) NOT NULL CHECK (amount > 0),mode text NOT NULL DEFAULT 'BANK' CHECK (mode IN ('BANK','UPI','CHEQUE','CASH','CREDIT_NOTE')),
  ref_no text CHECK (length(ref_no) <= 80),note text CHECK (length(note) <= 300),created_by uuid,created_at timestamptz NOT NULL DEFAULT now(),cancelled_at timestamptz,cancelled_by uuid);
CREATE FUNCTION public.lwb_company_admin() RETURNS boolean LANGUAGE sql AS $$ SELECT exists(select 1 from public.user_profiles where id=auth.uid() and role='admin') $$;
CREATE TABLE public.lwb_bank_stmt_lines(id uuid primary key default gen_random_uuid(),bank_id bigint,txn_date date,debit numeric default 0,credit numeric default 0,status text default 'OPEN');
`);
await db.exec(await readFile(new URL('../../lwb_accounts_company_pay_setup.sql',import.meta.url),'utf8'));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');
const add5=p=>call('select public.lwb_acc_add_entry5($1::jsonb) id',[JSON.stringify(p)]).then(r=>r[0].id);
const pays=async()=>(await db.query('select * from lwb_company_payments order by created_at')).rows;

test('Cash Out > Supplier payment > company saves the money entry and the company payment once',async()=>{
 const co=(await db.query("insert into lwb_companies(name) values('COCA-COLA') returning id")).rows[0].id;
 await as('accounts');
 await call('select public.lwb_acc_set_opening($1,500000,$2)',[today,'start']);
 const sup=await cat('OUT','Supplier payment'),canteen=await cat('OUT','Canteen');
 await assert.rejects(add5({date:today,kind:'OUT',category_id:canteen,mode:'CASH',amount:100,company_id:co}),/head Supplier payment/);
 await assert.rejects(add5({date:today,kind:'IN',category_id:sup,mode:'CASH',amount:100,company_id:co}),/only on Cash Out/);
 const id=await add5({date:today,kind:'OUT',category_id:sup,mode:'RTGS',amount:250000,ref:'UTR9',company_id:co});
 const e=(await db.query('select * from lwb_acc_entries where id=$1',[id])).rows[0];
 assert.equal(e.party,'COCA-COLA');assert.equal(Number(e.amount),250000);
 const P=await pays();
 assert.equal(P.length,1);assert.equal(P[0].mode,'BANK');assert.equal(Number(P[0].amount),250000);assert.equal(P[0].acc_entry_id,id);assert.equal(P[0].ref_no,'UTR9');
 // a normal entry (no company) is like lwb_acc_add_entry4 and makes no company payment
 await add5({date:today,kind:'OUT',category_id:canteen,mode:'CASH',amount:300});
 assert.equal((await pays()).length,1);
 // Admin can not cancel it on the company page; cancelling the money entry cancels it
 await as('admin');
 await assert.rejects(call('select public.lwb_company_pay_cancel($1)',[P[0].id]),/Accounts Dashboard/);
 await as('accounts');
 await call('select public.lwb_acc_cancel_entry($1,$2)',[id,'wrong amount']);
 assert.ok((await pays())[0].cancelled_at);
 // others can not use it
 await as('sales');await assert.rejects(add5({date:today,kind:'OUT',category_id:sup,mode:'CASH',amount:5,company_id:co}),/Accounts or Admin/);
});

test('bank lines to match: count of OPEN lines of active banks',async()=>{
 await as('accounts');
 const b=(await call("select public.lwb_acc_save_bank(null,'SBI','99',0,null,true) id"))[0].id;
 await db.query("insert into lwb_bank_stmt_lines(bank_id,txn_date,credit,status) values($1,$2,5000,'OPEN'),($1,$2,700,'MATCHED')",[b,today]);
 await db.query("insert into lwb_bank_stmt_lines(bank_id,txn_date,debit,status) values($1,$2,1200,'OPEN')",[b,dayAdd(today,-3)]);
 const r=(await call('select public.lwb_bank_stmt_open_count() j'))[0].j;
 assert.equal(Number(r.cnt),2);assert.equal(Number(r.credit),5000);assert.equal(Number(r.debit),1200);assert.equal(r.oldest,dayAdd(today,-3));
 await as('sales');await assert.rejects(call('select public.lwb_bank_stmt_open_count()'),/Accounts or Admin/);
 assert.equal((await db.query("select has_function_privilege('anon','public.lwb_acc_add_entry5(jsonb)','EXECUTE') a")).rows[0].a,false);
});
