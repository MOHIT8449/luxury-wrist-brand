import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_brand_settle_setup.sql after lwb_brand_money_setup.sql, on a tiny copy of the tables (no live database).
// The real Payment Collection and Accounts Dashboard SQL run first, as on the live database.
const ids={admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',manager:'00000000-0000-4000-8000-000000000003',driver:'00000000-0000-4000-8000-000000000005'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid primary key);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text default 'loaded',order_date date default current_date);
CREATE TABLE public.order_items(order_id uuid,loaded_qty numeric,rate numeric,sku_name text);
CREATE TABLE public.lwb_companies(id uuid primary key,name text,color text default '#123456',active boolean default true,sort_no int default 0);
CREATE TABLE public.sku_master(sku_name text,company_id uuid);
CREATE TABLE public.dispatch_assignments(order_id uuid,loading_completed_at timestamptz);
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key references orders(id),invoice_no text not null,invoice_date date not null,note text,amount numeric(14,2),bills jsonb not null default '[]',entered_by uuid,entered_at timestamptz default now());
CREATE TABLE public.lwb_tally_notes(id uuid default gen_random_uuid() primary key,order_id uuid,kind text,note_no text,note_date date,amount numeric(14,2),reason text,created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,driver_user_id uuid,cash_reported numeric(14,2) default 0,delivery_status text,payment_mode text,payment_reference text,cash_amount numeric(14,2),online_amount numeric(14,2),online_mode text,online_reference text,bank_ref text,payment_status text,payment_reviewed_by uuid,payment_reviewed_at timestamptz,reported_at timestamptz default now());
CREATE TABLE public.lwb_driver_delivery_returns(order_id uuid,status text,total_return_amount numeric,reviewed_at timestamptz,created_at timestamptz default now());
CREATE TABLE public.sales_returns(order_id uuid,return_no text,return_date date,total_amount numeric,approval_status text);
CREATE TABLE public.lwb_internal_bills(id uuid default gen_random_uuid() primary key,order_id uuid,internal_bill_no text,bill_date date,order_no text,customer_name text,goods_amount numeric,created_at timestamptz default now());
CREATE TABLE public.tax_invoices(id uuid primary key,order_id uuid,invoice_no text,invoice_date date,grand_total numeric);
CREATE TABLE public.lwb_payment_collections(id uuid default gen_random_uuid() primary key,invoice_id uuid,internal_bill_id uuid,collection_date date,amount numeric(14,2),payment_mode text,reference_no text,remarks text,status text,submitted_by uuid,submitted_at timestamptz default now(),reviewed_at timestamptz);
CREATE TABLE public.lwb_party_opening_balances(id uuid default gen_random_uuid() primary key,customer_name text,as_of_date date,amount numeric(14,2),remarks text,updated_by uuid,updated_at timestamptz default now());
CREATE UNIQUE INDEX lwb_party_opening_balances_party_uidx ON public.lwb_party_opening_balances(upper(btrim(customer_name)));
CREATE FUNCTION public.lwb_set_party_opening_balance(text,numeric,date,text) RETURNS void LANGUAGE sql AS $$ SELECT $$;
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
CREATE FUNCTION public.lwb_order_driver_received(p uuid) RETURNS numeric LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(d.cash_reported),0) FROM public.lwb_delivery_reports d WHERE d.order_id=p AND d.payment_status='VERIFIED' $$;
CREATE FUNCTION public.lwb_save_tally_invoice(p_order uuid,p_no text,p_date date,p_note text) RETURNS text LANGUAGE sql AS $$
  INSERT INTO public.lwb_tally_invoices(order_id,invoice_no,invoice_date,note,entered_by) VALUES (p_order,p_no,p_date,p_note,auth.uid())
  ON CONFLICT (order_id) DO UPDATE SET invoice_no=excluded.invoice_no, invoice_date=excluded.invoice_date RETURNING 'SAVED' $$;
CREATE FUNCTION public.lwb_order_return_credit(p uuid) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT 0::numeric $$;
`);
// the real Tally party link function
const tc=await sql('lwb_cashbook_tally_check_setup.sql');
await db.exec(tc.slice(tc.indexOf('CREATE OR REPLACE FUNCTION public.lwb_tally_set_party_map'),tc.indexOf('REVOKE ALL ON FUNCTION public.lwb_tally_check_user()')));
for(const [role,id] of Object.entries(ids)){await db.query('insert into auth.users values($1)',[id]);await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role+' user'])}
await db.exec(await sql('lwb_party_payment_collection_setup.sql'));
await db.exec(await sql('lwb_accounts_dashboard_setup.sql'));
await db.exec(await sql('lwb_party_group_billing_setup.sql'));
await db.exec(await sql('lwb_party_auto_adjust_setup.sql'));
const R='00000000-0000-4000-9000-00000000000a',C='00000000-0000-4000-9000-00000000000b';
await db.exec(`INSERT INTO lwb_companies(id,name,sort_no) VALUES ('${R}','RAJNIGANDHA',1),('${C}','COCA-COLA',2);
INSERT INTO sku_master VALUES ('RAJNI 4G','${R}'),('COKE 600','${C}');`);
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

const today=(await db.query("select (now() at time zone 'Asia/Kolkata')::date::text d")).rows[0].d;
const dayAdd=(d,n)=>{const x=new Date(d+'T12:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const data=async()=>(await call('select public.lwb_party_billing(400) j'))[0].j;
const receive=(party,lines,co,allocs=null,date=today)=>call('select public.lwb_party_receive($1,$2,$3::jsonb,$4::jsonb,null,$5) j',[party,date,JSON.stringify(lines),allocs==null?null:JSON.stringify(allocs),co]).then(r=>r[0].j);
const due=async id=>Number((await data()).orders.find(o=>o.order_id===id).due);


await db.exec(await sql('lwb_brand_money_setup.sql'));
const P='RAVI SALES (GOPI PURA)',Q='SHREE HARI AGENCY';
async function po(no,party,amt,sku,day=today){
 const id=(await db.query('insert into orders(order_no,customer_name,order_date) values($1,$2,$3) returning id',[no,party,day])).rows[0].id;
 await db.query('insert into order_items values($1,1,$2,$3)',[id,amt,sku]);
 await as('accounts');await call('select 1');
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids.accounts]);
 await db.query('insert into lwb_tally_invoices(order_id,invoice_no,invoice_date,amount,entered_by) values($1,$2,$3,$4,$5)',[id,'T-'+no,day,amt,ids.accounts]);
 return id;
}
const advB=async(party,co)=>Number(((await data()).advance_b.find(a=>a.parent===party&&a.company_id===co)||{amount:0}).amount);
let r1,r2,c1;

test('old data: advance left beside a due bill of the same brand (the Ravi Sales case)',async()=>{
 await db.query("insert into lwb_customer_master values($1),($2)",[P,Q]);
 r1=await po('R-1',P,239652,'RAJNI 4G',dayAdd(today,-1));
 r2=await po('R-2',P,268501,'RAJNI 4G');
 c1=await po('C-1',P,10000,'COKE 600');
 await as('accounts');
 // Choose bills: 2,39,652 to R-1 and 2,64,900 to R-2, the rest (3,598) stays as advance (old behaviour)
 await receive(P,[{mode:'BANK',amount:508150,ref:'U1'}],R,[{order_id:r1,amount:239652},{order_id:r2,amount:264900}]);
 // Coca-Cola money kept as advance
 await receive(P,[{mode:'UPI',amount:4000,ref:'U2'}],C,[]);
 assert.equal(await due(r2),3601);
 assert.equal(await advB(P,R),3598);
 assert.equal(await advB(P,C),4000);
 assert.equal(await due(c1),10000);
});

test('settle SQL: same-brand advance pays the due bill, the other brand is untouched, backup + log kept',async()=>{
 await as('');
 await db.exec(await sql('lwb_party_brand_settle_setup.sql'));
 await as('accounts');
 assert.equal(await due(r2),3);         // 3,601 − 3,598
 assert.equal(await advB(P,R),0);
 assert.equal(await due(c1),6000);      // Coca-Cola advance only on the Coca-Cola bill
 assert.equal(await advB(P,C),0);
 const b=(await db.query('select parent,company_id,free::float8 f,bills_due::float8 d from lwb_party_settle_backup order by company_id')).rows;
 assert.equal(b.length,2);
 const lg=(await db.query('select order_id,amount::float8 a from lwb_party_settle_log order by a')).rows;
 assert.deepEqual(lg.map(x=>x.a).sort((a,b)=>a-b),[3598,4000]);
 // the new split carries the name of the person who took the money
 const by=(await db.query('select created_by from lwb_party_allocs where id in (select alloc_id from lwb_party_settle_log)')).rows;
 assert.ok(by.every(x=>x.created_by===ids.accounts));
 // run again: safe, nothing more to do
 await as('');
 await db.exec(await sql('lwb_party_brand_settle_setup.sql'));
 assert.equal((await db.query('select count(*)::int n from lwb_party_settle_log')).rows[0].n,2);
});

test('new payment with "Choose bills": money left goes to the oldest due bill of the same brand only',async()=>{
 await as('accounts');
 const r3=await po('R-3',P,5000,'RAJNI 4G');
 const c2=await po('C-2',P,7000,'COKE 600');
 const res=await receive(P,[{mode:'CASH',amount:6000}],R,[{order_id:r3,amount:2000}]);
 // 2,000 to R-3 by hand, then R-2 (3) is older, then rest of R-3
 assert.equal(await due(r2),0);
 assert.equal(await due(r3),0);
 assert.equal(Number(res.split),5003);
 assert.equal(await advB(P,R),997);
 assert.equal(await due(c2),7000);      // Rajnigandha money never pays Coca-Cola
 assert.equal(await due(c1),6000);
 // "Keep as advance" with a bill due of that brand: it is set too (one balance)
 await receive(P,[{mode:'UPI',amount:2500,ref:'U3'}],C,[]);
 assert.equal(await due(c1),3500);
});
