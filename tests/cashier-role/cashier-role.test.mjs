import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_cashier_role_setup.sql + lwb_gst_register_setup.sql on a tiny copy of the tables (no live database).
// The real Accounts Dashboard, party payment and bank statement SQL run first, as on the live database.
// The real Payment Collection and Accounts Dashboard SQL run first, as on the live database.
const ids={admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',manager:'00000000-0000-4000-8000-000000000003',driver:'00000000-0000-4000-8000-000000000005'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid primary key);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,CONSTRAINT user_profiles_role_check CHECK (lower(btrim(role)) IN ('admin','accounts','manager','sales','warehouse','transport','driver')));
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text default 'loaded',order_date date default current_date);
CREATE TABLE public.order_items(order_id uuid,loaded_qty numeric,rate numeric,sku_name text);
CREATE TABLE public.sku_master(sku_name text,gst_rate numeric,cess_rate numeric);
CREATE TABLE public.lwb_goods_inward(id uuid default gen_random_uuid() primary key,invoice_no text,invoice_date date,received_date date);
CREATE TABLE public.lwb_goods_inward_items(inward_id uuid,taxable_amount numeric,total_amount numeric);
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
CREATE TABLE public.lwb_customer_master(customer_name text);
CREATE TABLE public.lwb_tally_party_map(tally_key text primary key,tally_name text not null,customer_name text,updated_at timestamptz default now(),updated_by uuid);
CREATE TABLE public.lwb_companies(id uuid default gen_random_uuid() primary key,name text not null,active boolean default true);
CREATE TABLE public.lwb_company_payments(id uuid default gen_random_uuid() primary key,company_id uuid not null references lwb_companies(id),pay_date date not null,amount numeric(14,2) not null,mode text not null default 'BANK' check (mode in ('BANK','UPI','CHEQUE','CASH','CREDIT_NOTE')),ref_no text,note text,created_by uuid,created_at timestamptz default now(),cancelled_at timestamptz,cancelled_by uuid,acc_entry_id uuid);
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
await db.exec(await sql('lwb_bank_statement_setup.sql'));
// Role setter + hired reader as on live (only the lines this file changes)
await db.exec(`
CREATE FUNCTION public.lwb_admin_set_user_role(p_user_id uuid,p_role text,p_full_name text,p_active boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE v_role text := lower(btrim(coalesce(p_role,'')));
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active IS TRUE AND lower(btrim(p.role))='admin') THEN RAISE EXCEPTION 'Active ERP Admin required'; END IF;
  IF v_role NOT IN ('admin','accounts','manager','sales','warehouse','transport','driver') THEN
    RAISE EXCEPTION 'Invalid ERP Role: %', v_role; END IF;
  INSERT INTO public.user_profiles(id,full_name,role,active) VALUES(p_user_id,coalesce(p_full_name,'x'),v_role,p_active)
  ON CONFLICT(id) DO UPDATE SET full_name=excluded.full_name,role=excluded.role,active=excluded.active;
END $fn$;
GRANT EXECUTE ON FUNCTION public.lwb_admin_set_user_role(uuid,text,text,boolean) TO authenticated;
CREATE FUNCTION public.lwb_hired_reader() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin','manager'));
$fn$;
`);
await db.exec(await sql('lwb_cashier_role_setup.sql'));
await db.exec(await sql('lwb_gst_register_setup.sql'));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');
ids.cashier='00000000-0000-4000-8000-000000000007';
await db.query('insert into auth.users values($1)',[ids.cashier]);

const today=(await db.query("select (now() at time zone 'Asia/Kolkata')::date::text d")).rows[0].d;
const dayAdd=(d,n)=>{const x=new Date(d+'T12:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};
const D=n=>dayAdd(today,-n);
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const one=async(q,args)=>Object.values((await call(q,args))[0])[0];
const dash=async()=>one('select public.lwb_acc_dashboard($1,$2)',[today,today]);
const P='SHREE JAGDISH TRADERS';
let bank,o1,cat;

test('Admin can give the new Cashier role; the role check takes it',async()=>{
 await as('accounts');await assert.rejects(call('select public.lwb_admin_set_user_role($1,$2,$3,true)',[ids.cashier,'cashier','Ramesh']),/Admin required/);
 await as('admin');await call('select public.lwb_admin_set_user_role($1,$2,$3,true)',[ids.cashier,'cashier','Ramesh']);
 assert.equal((await db.query('select role from user_profiles where id=$1',[ids.cashier])).rows[0].role,'cashier');
 await assert.rejects(call('select public.lwb_admin_set_user_role($1,$2,$3,true)',[ids.cashier,'boss','x']),/Invalid ERP Role/);
 await assert.rejects(db.query("insert into user_profiles values(gen_random_uuid(),'boss',true,'x')"),/user_profiles_role_check/);
});

test('setup by Accounts: bank and a party bill',async()=>{
 await db.query("insert into lwb_customer_master values($1)",[P]);
 o1=(await db.query("insert into orders(order_no,customer_name,order_date) values('LXY-1',$1,$2) returning id",[P,D(3)])).rows[0].id;
 await db.query("insert into order_items values($1,10,1120,'COKE 600 ML')",[o1]);
 await db.query("insert into sku_master values('COKE 600 ML',28,12)");
 await db.query('insert into lwb_tally_invoices(order_id,invoice_no,invoice_date,amount,bills,entered_by) values($1,$2,$3,11200,$4,$5)',[o1,'T-1',today,JSON.stringify([{name:P,no:'T-1',amount:11200}]),ids.accounts]);
 await as('accounts');
 bank=await one("select public.lwb_acc_save_bank(null,'ICICI 0013','741651000013',0,null,true)");
 cat=(await db.query("select id from lwb_acc_categories where kind='IN' and name='Other income'")).rows[0].id;
});

test('Cashier: cash book, Cash In / Out, deposit, party payment, Close Day',async()=>{
 await as('cashier');
 const d=await dash();
 assert.equal(d.is_cashier,true);assert.equal(d.can_check,false);assert.equal(d.is_admin,false);
 await one('select public.lwb_acc_set_opening($1,0,$2)',[today,'start']);
 await one('select public.lwb_acc_add_entry($1::jsonb)',[JSON.stringify({date:today,kind:'IN',category_id:cat,mode:'CASH',amount:5000,party:'Shop'})]);
 await one('select public.lwb_acc_add_entry($1::jsonb)',[JSON.stringify({date:today,kind:'DEPOSIT',bank_id:bank,amount:3000})]);
 // party payment: sees the bills, receives cash
 const pb=await one('select public.lwb_party_billing(400)');assert.ok(pb.orders.some(o=>o.order_id===o1||o.id===o1||o.order_no==='LXY-1'));
 await one('select public.lwb_party_receive($1,$2,$3::jsonb,null,null)',[P,today,JSON.stringify([{mode:'CASH',amount:2000}])]);
 const d2=await dash();assert.equal(Number(d2.closing),4000);  // 0 + 5000 + 2000 - 3000
 assert.equal(d2.pending.length,1);  // the deposit waits for the bank check
});

test('Cashier can not do Tally work: bank check, bank statement, Heads & Banks, GST',async()=>{
 await as('cashier');
 const p=(await dash()).pending[0];
 await assert.rejects(one('select public.lwb_acc_verify_line($1,$2,true,$3,null)',[p.src,p.id,bank]),/Only Admin \/ Accounts/);
 await assert.rejects(one("select public.lwb_acc_save_bank(null,'X','1',0,null,true)"),/./);
 await assert.rejects(one('select public.lwb_bank_stmt_list($1,$2,$3)',[bank,D(30),today]),/./);
 await assert.rejects(one('select public.lwb_gst_summary(12)'),/Admin \/ Accounts only/);
 await assert.rejects(one('select public.lwb_gst_save($1::jsonb)',[JSON.stringify({month:today})]),/Admin \/ Accounts only/);
 assert.equal(await one('select public.lwb_hired_reader()'),true);
});

test('Accounts (Tally) checks the bank now (was Admin only) and gets the bell',async()=>{
 await as('accounts');
 const d=await dash();assert.equal(d.can_check,true);assert.equal(d.is_admin,false);
 const p=d.pending[0];
 await one('select public.lwb_acc_verify_line($1,$2,true,$3,null)',[p.src,p.id,bank]);
 assert.equal((await dash()).pending.length,0);
 assert.ok(Array.isArray((await one('select public.lwb_bank_stmt_list($1,$2,$3)',[bank,D(30),today])).lines));
 assert.equal((await one('select public.lwb_bank_stmt_list($1,$2,$3)',[bank,D(30),today])).is_admin,true);  // upload / book buttons
 await as('manager');await assert.rejects(dash(),/./);
 // bank check bell: Admin and Accounts
 await as('cashier');await one('select public.lwb_acc_add_entry($1::jsonb)',[JSON.stringify({date:today,kind:'IN',category_id:cat,mode:'UPI',bank_id:bank,amount:700,party:'Shop'})]);
 await db.exec('select public.lwb_acc_ping_admins()');
 const to=(await db.query("select distinct p.role from erp_notifications n join user_profiles p on p.id=n.user_id where n.notification_type='ACC_BANK_VERIFY'")).rows.map(r=>r.role).sort();
 assert.deepEqual(to,['accounts','admin']);
});

test('GST: ERP sales GST from Tally bills, purchase GST from purchase bills, filing saved by Accounts',async()=>{
 const g=(await db.query("insert into lwb_goods_inward(invoice_no,invoice_date,received_date) values('P-1',$1,$1) returning id",[today])).rows[0].id;
 await db.query('insert into lwb_goods_inward_items values($1,1000,1280),($1,500,640)',[g]);
 await as('accounts');
 let s=await one('select public.lwb_gst_summary(3)');
 assert.equal(s.rows.length,3);
 let m=s.rows[0];assert.equal(m.month,today.slice(0,8)+'01');
 assert.equal(m.sales_bills,1);assert.equal(Number(m.sales_amount),11200);
 assert.equal(Number(m.sales_gst),3200);   // 11200 x 40 / 140
 assert.equal(Number(m.pur_gst),420);assert.equal(Number(m.pur_amount),1920);
 await assert.rejects(one('select public.lwb_gst_save($1::jsonb)',[JSON.stringify({month:today,paid:100})]),/date it was paid/);
 await assert.rejects(one('select public.lwb_gst_save($1::jsonb)',[JSON.stringify({month:today,gstr3b_on:dayAdd(today,1)})]),/after today/);
 await one('select public.lwb_gst_save($1::jsonb)',[JSON.stringify({month:today,gstr1_on:today,gstr3b_on:today,tax_3b:3200,itc_used:420,paid:2780,paid_on:today,challan:'CH-1'})]);
 m=(await one('select public.lwb_gst_summary(1)')).rows[0];
 assert.equal(Number(m.paid),2780);assert.equal(m.challan,'CH-1');assert.equal(m.updated_by,'accounts user');
 assert.equal((await db.query("select has_table_privilege('authenticated','public.lwb_gst_months','SELECT') a")).rows[0].a,false);
});

test('running the file again changes nothing more',async()=>{
 await db.exec(await sql('lwb_cashier_role_setup.sql'));
 const def=(await db.query("select pg_get_functiondef('public.lwb_acc_dashboard(date,date)'::regprocedure) d")).rows[0].d;
 assert.equal(def.split('can_check').length-1,1);
 const c=(await db.query("select pg_get_constraintdef(oid) d from pg_constraint where conname='user_profiles_role_check'")).rows[0].d;
 assert.equal(c.split('cashier').length-1,1);
});
