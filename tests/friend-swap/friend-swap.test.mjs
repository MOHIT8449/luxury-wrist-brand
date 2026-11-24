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
await db.exec(await sql('lwb_acc_friend_swap_setup.sql'));
await db.exec(await sql('lwb_acc_friend_swap_setup.sql')); // safe to run again
const bank=(await db.query(`insert into lwb_acc_banks(name) values('HDFC') returning id`)).rows[0].id;
const day=async(f,t)=>(await call('select public.lwb_acc_dashboard($1,$2) j',[f,t||f]))[0].j;

test('swap entries change cash and bank, head is Friend swap',async()=>{
 await as('accounts');
 const b2c=(await call('select public.lwb_acc_swap_add($1) id',[{date:today,dir:'B2C',bank_id:bank,amount:20000,person:'  raju   bhai ',ref:'4471'}]))[0].id;
 const c2b=(await call('select public.lwb_acc_swap_add($1) id',[{date:today,dir:'C2B',bank_id:bank,amount:15000,person:'Ketan Shah'}]))[0].id;
 const d=await day(today);
 const L=id=>d.lines.find(l=>l.id===id);
 assert.equal(L(b2c).kind,'DEPOSIT');assert.equal(L(b2c).category,'Friend swap');assert.equal(L(b2c).party,'RAJU BHAI');
 assert.equal(L(c2b).kind,'WITHDRAW');assert.equal(L(c2b).category,'Friend swap');
 assert.equal(L(b2c).status,'PENDING'); // bank part waits for the bank check
 assert.equal(Number(L(b2c).cash)+Number(L(c2b).cash),-5000);
 const names=(await call('select public.lwb_acc_swap_names() j'))[0].j;
 assert.deepEqual(names,['KETAN SHAH','RAJU BHAI']);
});

test('checks: person, direction, role; normal deposit unchanged',async()=>{
 await as('accounts');
 await assert.rejects(call('select public.lwb_acc_swap_add($1)',[{date:today,dir:'B2C',bank_id:bank,amount:100,person:''}]),/person name/);
 await assert.rejects(call('select public.lwb_acc_swap_add($1)',[{date:today,dir:'X',bank_id:bank,amount:100,person:'AB'}]),/Choose/);
 await assert.rejects(call('select public.lwb_acc_swap_add($1)',[{date:today,dir:'B2C',amount:100,person:'AB'}]),/bank/);
 await as('manager');
 await assert.rejects(call('select public.lwb_acc_swap_add($1)',[{date:today,dir:'B2C',bank_id:bank,amount:100,person:'AB'}]),/Only active/);
 await as('accounts');
 const dep=(await call('select public.lwb_acc_add_entry($1) id',[{date:today,kind:'DEPOSIT',bank_id:bank,amount:500}]))[0].id;
 assert.equal((await day(today)).lines.find(l=>l.id===dep).category,'Bank deposit');
});

test('one-time fix: 23/11 Rs 1,00,000 Other expense becomes a Friend swap',async()=>{
 await db.exec(`CREATE TABLE IF NOT EXISTS public.lwb_vehicle_trips(id uuid primary key default gen_random_uuid(),acc_entry_id uuid)`);
 await as('admin');
 const oc=(await db.query(`select id from lwb_acc_categories where name='Other expense'`)).rows[0].id;
 const id=(await db.query(`insert into lwb_acc_entries(entry_date,kind,category_id,mode,amount,remark,created_by) values('2026-11-23','OUT',$1,'CASH',100000,'bank aaya',$2) returning id`,[oc,ids.accounts])).rows[0].id;
 await db.exec(await sql('lwb_acc_swap_fix_23nov_1lakh.sql'));
 await db.exec(await sql('lwb_acc_swap_fix_23nov_1lakh.sql')); // safe to run again
 const e=(await db.query('select kind,category_id,mode,party,remark from lwb_acc_entries where id=$1',[id])).rows[0];
 assert.equal(e.kind,'DEPOSIT');assert.equal(e.category_id,null);assert.equal(e.party,'FRIEND (23/11)');assert.match(e.remark,/^bank aaya · Was Cash Out/);
 const l=(await db.query(`select category,cash_effect from lwb_acc_lines_all() where id=$1`,[id])).rows[0];
 assert.equal(l.category,'Friend swap');assert.equal(Number(l.cash_effect),-100000);
 assert.equal((await db.query('select count(*)::int c from lwb_acc_swap_fix_log')).rows[0].c,1);
});
