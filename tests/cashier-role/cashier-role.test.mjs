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
await db.exec(await sql('lwb_acc_shift_handover_setup.sql'));
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

test('Shift handover in the day: count, hand to the next person, he accepts; short needs a note',async()=>{
 await as('cashier');
 const people=await one('select public.lwb_acc_shift_people()');
 assert.deepEqual(people.map(p=>p.role).sort(),['accounts','admin','cashier']);
 const book=Number((await dash()).closing);
 // notes that do not match the book need a note
 await assert.rejects(one('select public.lwb_acc_shift_give($1,$2::jsonb,null)',[ids.accounts,JSON.stringify({'500':1})]),/short by Rs/);
 await assert.rejects(one('select public.lwb_acc_shift_give($1,$2::jsonb,null)',[ids.cashier,JSON.stringify({'500':1})]),/Choose the person/);
 await assert.rejects(one('select public.lwb_acc_shift_give($1,$2::jsonb,null)',[ids.manager,JSON.stringify({'500':1})]),/only to an active/);
 const notes={'500':Math.floor(book/500),'coins':book-500*Math.floor(book/500)};
 const g=await one('select public.lwb_acc_shift_give($1,$2::jsonb,null)',[ids.accounts,JSON.stringify(notes)]);
 assert.equal(Number(g.counted),book);
 await assert.rejects(one('select public.lwb_acc_shift_give($1,$2::jsonb,$3)',[ids.admin,JSON.stringify(notes),'x']),/already waiting/);
 assert.equal((await db.query("select count(*)::int n from erp_notifications where user_id=$1 and notification_type='ACC_SHIFT_HANDOVER' and not is_read",[ids.accounts])).rows[0].n,1);
 let L=await one('select public.lwb_acc_shift_list(null,null)');
 assert.equal(L.pending.to_name,'accounts user');assert.equal(L.holder,null);
 // only the receiver (or Admin) accepts
 await assert.rejects(one('select public.lwb_acc_shift_receive($1,null,null)',[g.id]),/Only accounts user/);
 await as('accounts');
 await assert.rejects(one('select public.lwb_acc_shift_receive($1,$2,null)',[g.id,book-100]),/Write a note/);
 await one('select public.lwb_acc_shift_receive($1,$2,$3)',[g.id,book-100,'100 less']);
 await db.query("alter table user_profiles add column if not exists mobile text");
 await db.query("update user_profiles set mobile='98250 12345' where id=$1",[ids.accounts]);
 L=await one('select public.lwb_acc_shift_list(null,null)');
 assert.equal(L.holder.name,'accounts user');assert.equal(L.holder.mobile,'98250 12345');assert.equal(L.holder.role,'accounts');assert.equal(L.holder.today,true);
 assert.ok(L.last_entry===null||typeof L.last_entry.name==='string');assert.equal(L.pending,null);assert.equal(L.rows[0].status,'RECEIVED');
 // short goes to Admin + the giver as a bell
 const bell=(await db.query("select distinct p.role from erp_notifications n join user_profiles p on p.id=n.user_id where n.notification_type='ACC_SHIFT_HANDOVER' and n.title like 'Cash handover short%'")).rows.map(r=>r.role).sort();
 assert.deepEqual(bell,['admin','cashier']);
 // cancel a waiting one: only the giver or Admin
 const g2=await one('select public.lwb_acc_shift_give($1,$2::jsonb,$3)',[ids.cashier,JSON.stringify({'10':1}),'test']);
 await as('cashier');await assert.rejects(one('select public.lwb_acc_shift_cancel($1,null)',[g2.id]),/Only the person/);
 await as('accounts');await one('select public.lwb_acc_shift_cancel($1,null)',[g2.id]);
 assert.equal((await one('select public.lwb_acc_shift_list(null,null)')).pending,null);
 await as('manager');await assert.rejects(one('select public.lwb_acc_shift_list(null,null)'),/only/);
 assert.equal((await db.query("select has_table_privilege('authenticated','public.lwb_acc_shift_handovers','SELECT') a")).rows[0].a,false);
});

test('Cash handover only to the chosen people, tagged and split (₹5L = ₹2.5L + ₹2.5L)',async()=>{
 ids.sales='00000000-0000-4000-8000-000000000008';ids.vishal='00000000-0000-4000-8000-000000000009';
 await db.query('insert into user_profiles(id,role,active,full_name) values($1,$2,true,$3),($4,$5,true,$6)',[ids.sales,'sales','Ramesh Sales',ids.vishal,'sales','Vishal Bhai']);
 await db.exec(await sql('lwb_acc_cash_split_handover_setup.sql'));
 await db.exec(await sql('lwb_acc_cash_split_handover_setup.sql')); // safe to run again
 await as('accounts');
 let PP=await one('select public.lwb_acc_cash_people_get()');
 assert.equal(PP.is_admin,false);assert.equal(PP.all,null);
 assert.ok(PP.list.some(p=>p.name==='Vishal Bhai'));assert.ok(!PP.list.some(p=>p.name==='Ramesh Sales'));assert.ok(!PP.list.some(p=>p.role==='manager'));
 await assert.rejects(one('select public.lwb_acc_cash_people_set($1)',[[ids.sales]]),/Only Admin/);
 await as('admin');
 PP=await one('select public.lwb_acc_cash_people_get()');
 assert.ok(PP.all.some(p=>p.name==='Ramesh Sales'&&!p.on));
 await one('select public.lwb_acc_cash_people_set($1)',[[ids.accounts,ids.vishal,ids.sales,ids.admin]]);
 assert.deepEqual((await one('select public.lwb_acc_cash_people_get()')).list.map(p=>p.name),['accounts user','Vishal Bhai','Ramesh Sales','admin user']);
 await as('accounts');
 const book=Number((await dash()).closing);
 const notes={'500':Math.floor(book/500),'coins':r2(book-500*Math.floor(book/500))};
 function r2(v){return Math.round(v*100)/100}
 const half=Math.floor(book/2);
 // not in the list / parts do not add up / same person twice
 await assert.rejects(one('select public.lwb_acc_shift_give_split($1::jsonb,$2::jsonb,null)',[JSON.stringify([{to:ids.cashier,amount:book}]),JSON.stringify(notes)]),/not in the list/);
 await assert.rejects(one('select public.lwb_acc_shift_give_split($1::jsonb,$2::jsonb,null)',[JSON.stringify([{to:ids.vishal,amount:half}]),JSON.stringify(notes)]),/add up/);
 await assert.rejects(one('select public.lwb_acc_shift_give_split($1::jsonb,$2::jsonb,null)',[JSON.stringify([{to:ids.vishal,amount:half},{to:ids.vishal,amount:book-half}]),JSON.stringify(notes)]),/twice/);
 const g=await one('select public.lwb_acc_shift_give_split($1::jsonb,$2::jsonb,null)',[JSON.stringify([{to:ids.vishal,amount:half},{to:ids.sales,amount:r2(book-half)}]),JSON.stringify(notes)]);
 assert.equal(g.parts,2);
 assert.equal((await db.query("select count(*)::int n from erp_notifications where user_id=any($1) and notification_type='ACC_SHIFT_HANDOVER' and not is_read and message like '%cash split%'",[[ids.vishal,ids.sales]])).rows[0].n,2);
 let L=await one('select public.lwb_acc_shift_list(null,null)');
 assert.equal(L.pending.parts.length,2);assert.equal(Number(L.pending.counted),book);assert.equal(L.pending.to_name,'Vishal Bhai + Ramesh Sales');
 assert.equal(L.rows.filter(r=>r.batch===g.batch).length,2);assert.equal(Number(L.rows[0].batch_total),book);
 await assert.rejects(one('select public.lwb_acc_shift_give_split($1::jsonb,$2::jsonb,$3)',[JSON.stringify([{to:ids.admin,amount:book}]),JSON.stringify(notes),'x']),/already waiting/);
 // Sales person (no Accounts page) sees and accepts only his own part
 await as('sales');
 L=await one('select public.lwb_acc_shift_list(null,null)');
 assert.equal(L.can_give,false);assert.equal(L.last_entry,null);assert.ok(L.rows.every(r=>r.to_name==='Ramesh Sales'));
 const pv=L.pending.parts.find(p=>p.to===ids.vishal),ps=L.pending.parts.find(p=>p.to===ids.sales);
 await assert.rejects(one('select public.lwb_acc_shift_receive($1,null,null)',[pv.id]),/Only Vishal Bhai/);
 await assert.rejects(one('select public.lwb_acc_shift_give_split($1::jsonb,$2::jsonb,null)',[JSON.stringify([{to:ids.admin,amount:1}]),JSON.stringify({coins:1})]),/only/);
 await one('select public.lwb_acc_shift_receive($1,null,null)',[ps.id]);
 L=await one('select public.lwb_acc_shift_list(null,null)');
 assert.equal(L.pending.to_name,'Vishal Bhai');
 await as('vishal');await one('select public.lwb_acc_shift_receive($1,null,null)',[pv.id]);
 await as('accounts');
 L=await one('select public.lwb_acc_shift_list(null,null)');
 assert.equal(L.pending,null);assert.deepEqual(L.holders.map(h=>h.name).sort(),['Ramesh Sales','Vishal Bhai']);
 assert.equal(L.holders.reduce((a,h)=>a+Number(h.amount),0),book);
 // the old single call still works; cancel cancels every waiting part
 const g2=await one('select public.lwb_acc_shift_give_split($1::jsonb,$2::jsonb,$3)',[JSON.stringify([{to:ids.vishal,amount:10},{to:ids.admin,amount:10}]),JSON.stringify({'10':2}),'test']);
 await one('select public.lwb_acc_shift_cancel($1,null)',[g2.id]);
 assert.equal((await one('select public.lwb_acc_shift_list(null,null)')).pending,null);
 const g3=await one('select public.lwb_acc_shift_give($1,$2::jsonb,$3)',[ids.admin,JSON.stringify({'10':1}),'test']);
 assert.equal(g3.parts,1);
 await as('manager');await assert.rejects(one('select public.lwb_acc_shift_list(null,null)'),/only/);
 assert.equal((await db.query("select has_table_privilege('authenticated','public.lwb_acc_cash_people','SELECT') a")).rows[0].a,false);
});

test('Handover heads: Office / Other + Difference ledger; Damaged cash box (Mohit 25 Nov 2026)',async()=>{
 await db.exec(await sql('lwb_acc_cash_diff_damaged_setup.sql'));
 await db.exec(await sql('lwb_acc_cash_diff_damaged_setup.sql')); // safe to run again
 const r2=v=>Math.round(v*100)/100;
 await as('admin');
 const pend=await one('select public.lwb_acc_shift_list(null,null)');if(pend.pending)await one('select public.lwb_acc_shift_cancel($1,null)',[pend.pending.id]);
 await as('accounts');
 const inc=async v=>{const c=(await db.query("select id from lwb_acc_categories where kind='IN' and active order by id limit 1")).rows[0].id;
   await one('select public.lwb_acc_add_entry($1)',[{date:today,kind:'IN',category_id:c,mode:'CASH',amount:v,party:'X'}])};
 let book=Number((await dash()).closing);if(book<5000){await inc(10000);book=Number((await dash()).closing)}
 const cnt=Math.floor((book-3000)/500)*500,notes={'500':cnt/500};      // counted notes to Vishal; office 1,000; Ramesh 500; rest = difference
 const diff=r2(book-cnt-1000-500);
 const parts=JSON.stringify([{to:ids.vishal,amount:cnt}]),extra=JSON.stringify([{kind:'OFFICE',amount:1000},{kind:'OTHER',name:' ramesh  bhai ',amount:500}]);
 await assert.rejects(one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,null,$3::jsonb)',[parts,JSON.stringify(notes),extra]),/Write a note/);
 await assert.rejects(one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,$3,$4::jsonb)',[parts,JSON.stringify(notes),'x',JSON.stringify([{kind:'OTHER',amount:5}])]),/name/);
 const g=await one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,$3,$4::jsonb)',[parts,JSON.stringify(notes),'rest at godown',extra]);
 assert.equal(Number(g.diff),diff);assert.equal(Number(g.extra),1500);
 // the difference leaves cash in hand; office / other stay in it
 assert.equal(r2(Number((await dash()).closing)),r2(book-diff));
 let X=await one('select public.lwb_acc_shift_extras(null,null)');
 assert.equal(Number(X.last),Number(g.batch));
 assert.deepEqual(X.rows.map(r=>r.kind+':'+(r.name||'')+':'+Number(r.amount)).sort(),['DIFF:SHORT:'+diff,'OFFICE::1000','OTHER:RAMESH BHAI:500']);
 let CD=await one('select public.lwb_acc_cdiff_get()');assert.equal(Number(CD.balance),diff);
 assert.equal((await dash()).lines.find(l=>l.category==='Cash difference').kind,'OUT');
 // cancel takes all of it back
 await one('select public.lwb_acc_shift_cancel($1,null)',[g.id]);
 assert.equal(r2(Number((await dash()).closing)),book);
 assert.equal(Number((await one('select public.lwb_acc_cdiff_get()')).balance),0);
 assert.equal((await one('select public.lwb_acc_shift_extras(null,null)')).rows.length,0);
 // again, received; then found part of it, Admin writes off the rest
 const g2=await one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,$3,$4::jsonb)',[parts,JSON.stringify(notes),'rest at godown',extra]);
 await as('vishal');await one('select public.lwb_acc_shift_receive($1,null,null)',[g2.id]);
 await as('accounts');
 await assert.rejects(one('select public.lwb_acc_cdiff_add($1)',[{kind:'FOUND',amount:diff+1,note:'x'}]),/open in the Cash Difference/);
 await assert.rejects(one('select public.lwb_acc_cdiff_add($1)',[{kind:'WRITE_OFF',amount:1,note:'x'}]),/Only Admin/);
 await one('select public.lwb_acc_cdiff_add($1)',[{kind:'FOUND',amount:500,note:'found in godown drawer'}]);
 assert.equal(r2(Number((await dash()).closing)),r2(book-diff+500));
 await as('admin');await one('select public.lwb_acc_cdiff_add($1)',[{kind:'WRITE_OFF',amount:r2(diff-500),note:'lost'}]);
 CD=await one('select public.lwb_acc_cdiff_get()');assert.equal(Number(CD.balance),0);assert.equal(CD.rows.length,4);
 await assert.rejects(one('select public.lwb_acc_cdiff_cancel($1,$2)',[CD.rows.find(r=>r.kind==='SHORT'&&!r.cancelled).id,'x']),/handover/);
 // extra cash: comes in as Cash In
 await as('accounts');
 let b2=Number((await dash()).closing);
 const g3=await one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,$3,$4::jsonb)',[JSON.stringify([{to:ids.vishal,amount:b2+500}]),JSON.stringify({coins:b2+500}),'extra found','[]']);
 assert.equal(Number(g3.diff),-500);assert.equal(r2(Number((await dash()).closing)),r2(b2+500));
 await as('vishal');await one('select public.lwb_acc_shift_receive($1,null,null)',[g3.id]);
 // Damaged cash: not in cash in hand
 await as('accounts');
 const before=r2(Number((await dash()).closing));
 await one('select public.lwb_acc_dmg_add($1)',[{kind:'OPENING',notes:{'500':4,'100':5}}]);
 await assert.rejects(one('select public.lwb_acc_dmg_add($1)',[{kind:'OPENING',amount:100}]),/already set/);
 assert.equal(r2(Number((await dash()).closing)),before);
 await one('select public.lwb_acc_dmg_add($1)',[{kind:'FROM_CASH',amount:500,note:'torn note from party'}]);
 assert.equal(r2(Number((await dash()).closing)),r2(before-500));
 let DM=await one('select public.lwb_acc_dmg_get()');assert.equal(Number(DM.balance),3000);
 const bk=(await db.query(`insert into lwb_acc_banks(name) values('ICICI DMG') returning id`)).rows[0].id;
 await assert.rejects(one('select public.lwb_acc_dmg_bank($1)',[{amount:3500,bank_amount:0}]),/Only Rs/);
 await assert.rejects(one('select public.lwb_acc_dmg_bank($1)',[{amount:500,bank_amount:600,bank_id:bk}]),/more than/);
 await assert.rejects(one('select public.lwb_acc_dmg_bank($1)',[{amount:500,bank_amount:250}]),/bank/);
 const bb=await one('select public.lwb_acc_dmg_bank($1)',[{amount:500,bank_amount:250,bank_id:bk}]);
 assert.equal(Number(bb.short),250);assert.equal(Number(bb.balance),2500);
 const dl=(await dash()).lines.find(l=>l.category==='Damaged cash to bank');
 assert.equal(dl.mode,'BANK');assert.equal(Number(dl.amount),250);assert.equal(dl.status,'PENDING');
 assert.equal(r2(Number((await dash()).closing)),r2(before-500)); // bank money is not cash
 DM=await one('select public.lwb_acc_dmg_get()');
 assert.equal(Number(DM.short),250);assert.equal(Number(DM.opening),2500);assert.equal(Number(DM.from_cash),500);assert.equal(DM.rows[0].status,'PENDING');
 await assert.rejects(one('select public.lwb_acc_dmg_cancel($1,$2)',[DM.rows.find(r=>r.kind==='OPENING').id,'x']),/Only Admin/);
 await one('select public.lwb_acc_dmg_cancel($1,$2)',[DM.rows.find(r=>r.kind==='BANK').id,'wrong']);
 assert.equal(Number((await one('select public.lwb_acc_dmg_get()')).balance),3000);
 assert.equal((await dash()).lines.some(l=>l.category==='Damaged cash to bank'),false);
 await as('manager');await assert.rejects(one('select public.lwb_acc_dmg_get()'),/Only/);
 assert.equal((await db.query("select has_table_privilege('authenticated','public.lwb_acc_damaged_cash','SELECT') a")).rows[0].a,false);
});

test("Today's cashier: the Sales Head holding the cash box gets the Cashier work; others do not (Mohit 26 Nov 2026)",async()=>{
 ids.manager2='00000000-0000-4000-8000-000000000010';
 await db.query('insert into user_profiles(id,role,active,full_name) values($1,$2,true,$3)',[ids.manager2,'manager','Second Head']);
 await db.exec(await sql('lwb_acc_duty_cashier_setup.sql'));
 await db.exec(await sql('lwb_acc_duty_cashier_setup.sql')); // safe to run again
 const inList=(await db.query('select user_id from lwb_acc_cash_people')).rows.map(r=>r.user_id);
 assert.ok(inList.includes(ids.manager)&&inList.includes(ids.manager2));
 assert.equal((await db.query("select has_function_privilege('authenticated','public.lwb_acc_duty_cashier(uuid)','EXECUTE') a")).rows[0].a,false);
 const r2=v=>Math.round(v*100)/100;
 // not on duty yet
 await as('manager');
 assert.equal((await one('select public.lwb_acc_on_duty()')).on_duty,false);
 await assert.rejects(dash(),/./);
 // Accounts hands the whole box to the Sales Head; till he presses Received he is not the cashier
 await as('accounts');
 const book=r2(Number((await dash()).closing));
 const g=await one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,null,$3::jsonb)',[JSON.stringify([{to:ids.manager,amount:book}]),JSON.stringify({coins:book}),'[]']);
 await as('manager');
 assert.equal((await one('select public.lwb_acc_on_duty()')).on_duty,false);
 await one('select public.lwb_acc_shift_receive($1,null,null)',[g.id]);
 const od=await one('select public.lwb_acc_on_duty()');
 assert.equal(od.on_duty,true);assert.equal(Number(od.amount),book);
 // he works as the Cashier: cash book, Cash In, party payment; no Tally / bank check
 const d=await dash();assert.equal(d.is_cashier,true);assert.equal(d.can_check,false);assert.equal(d.is_admin,false);
 const c=(await db.query("select id from lwb_acc_categories where kind='IN' and active order by id limit 1")).rows[0].id;
 await one('select public.lwb_acc_add_entry($1)',[{date:today,kind:'IN',category_id:c,mode:'CASH',amount:700,party:'Shop'}]);
 await one('select public.lwb_party_receive($1,$2,$3::jsonb,null,null)',[P,today,JSON.stringify([{mode:'CASH',amount:300}])]);
 assert.equal(r2(Number((await dash()).closing)),r2(book+1000));
 await assert.rejects(one("select public.lwb_acc_save_bank(null,'X BANK','1',0,null,true)"),/./);
 assert.equal((await one('select public.lwb_acc_shift_list(null,null)')).can_give,true);
 // the other Sales Head: nothing
 await as('manager2');
 assert.equal((await one('select public.lwb_acc_on_duty()')).on_duty,false);
 await assert.rejects(dash(),/./);
 await assert.rejects(one('select public.lwb_party_receive($1,$2,$3::jsonb,null,null)',[P,today,JSON.stringify([{mode:'CASH',amount:1}])]),/./);
 // he hands the box to the other Sales Head; after Received ✓ the Cashier work moves with it
 await as('manager');
 const b2=r2(Number((await dash()).closing));
 const g2=await one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,null,$3::jsonb)',[JSON.stringify([{to:ids.manager2,amount:b2}]),JSON.stringify({coins:b2}),'[]']);
 assert.equal((await one('select public.lwb_acc_on_duty()')).on_duty,true);   // still his till received
 await as('manager2');await one('select public.lwb_acc_shift_receive($1,null,null)',[g2.id]);
 assert.equal((await one('select public.lwb_acc_on_duty()')).on_duty,true);
 assert.equal((await dash()).is_cashier,true);
 await as('manager');
 assert.equal((await one('select public.lwb_acc_on_duty()')).on_duty,false);
 await assert.rejects(dash(),/./);
 // back to Accounts: no Sales Head is the cashier
 await as('manager2');
 const g3=await one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,null,$3::jsonb)',[JSON.stringify([{to:ids.accounts,amount:b2}]),JSON.stringify({coins:b2}),'[]']);
 await as('accounts');await one('select public.lwb_acc_shift_receive($1,null,null)',[g3.id]);
 await as('manager2');assert.equal((await one('select public.lwb_acc_on_duty()')).on_duty,false);
 await as('accounts');assert.equal((await dash()).is_cashier,false);
});

test('Cash box only for Admin / Accounts / Sales Head: Salesman taken off the list, can not be tagged (Mohit 26 Nov 2026)',async()=>{
 await db.exec(await sql('lwb_acc_cash_people_roles_setup.sql'));
 await db.exec(await sql('lwb_acc_cash_people_roles_setup.sql')); // safe to run again
 const roles=(await db.query('select distinct lower(p.role) r from lwb_acc_cash_people c join user_profiles p on p.id=c.user_id')).rows.map(r=>r.r).sort();
 assert.ok(!roles.includes('sales'));assert.ok(roles.includes('manager'));
 await as('admin');
 const PP=await one('select public.lwb_acc_cash_people_get()');
 assert.ok(PP.all.every(p=>['admin','accounts','manager','cashier'].includes(p.role)));
 await one('select public.lwb_acc_cash_people_set($1)',[[ids.accounts,ids.manager,ids.manager2,ids.sales,ids.admin]]);
 assert.ok(!(await one('select public.lwb_acc_cash_people_get()')).list.some(p=>p.role==='sales'));
 await as('accounts');
 const book=Math.round(Number((await dash()).closing)*100)/100;
 await assert.rejects(one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,null,$3::jsonb)',[JSON.stringify([{to:ids.sales,amount:book}]),JSON.stringify({coins:book}),'[]']),/not in the list/);
 const g=await one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,null,$3::jsonb)',[JSON.stringify([{to:ids.manager,amount:book}]),JSON.stringify({coins:book}),'[]']);
 await as('manager');await one('select public.lwb_acc_shift_receive($1,null,null)',[g.id]);
 await as('sales');await assert.rejects(one('select public.lwb_acc_shift_list(null,null)'),/only/);
 await as('manager2');assert.equal((await one('select public.lwb_acc_shift_list(null,null)')).holder.id,ids.manager);
});

test('Night: cash to Admin only keeps it; the cashier stays; morning Admin hands it on = new cashier (Mohit 26 Nov 2026)',async()=>{
 await db.exec(await sql('lwb_acc_cashier_admin_safe_setup.sql'));
 await db.exec(await sql('lwb_acc_cashier_admin_safe_setup.sql')); // safe to run again
 const give=async(to)=>{const b=Math.round(Number((await dash()).closing)*100)/100;
   return one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,null,$3::jsonb)',[JSON.stringify([{to,amount:b}]),JSON.stringify({coins:b}),'[]'])};
 // (test 12 left the box with the first Sales Head)
 await as('manager');assert.equal((await one('select public.lwb_acc_on_duty()')).on_duty,true);
 let T=await one('select public.lwb_acc_today_cashier()');assert.equal(T.cashiers[0].id,ids.manager);
 // night: he hands the cash to Admin
 const g=await give(ids.admin);
 await as('admin');await one('select public.lwb_acc_shift_receive($1,null,null)',[g.id]);
 T=await one('select public.lwb_acc_today_cashier()');
 assert.equal(T.cashiers[0].id,ids.manager);assert.equal(T.holders[0].id,ids.admin);
 await as('manager');assert.equal((await one('select public.lwb_acc_on_duty()')).on_duty,true);
 // morning: Admin hands it to the other Sales Head = he is the cashier now
 await as('admin');const g2=await give(ids.manager2);
 await as('manager2');await one('select public.lwb_acc_shift_receive($1,null,null)',[g2.id]);
 assert.equal((await one('select public.lwb_acc_on_duty()')).on_duty,true);
 await as('manager');assert.equal((await one('select public.lwb_acc_on_duty()')).on_duty,false);
 T=await one('select public.lwb_acc_today_cashier()');assert.equal(T.cashiers[0].id,ids.manager2);assert.equal(T.holders[0].id,ids.manager2);
 await as('sales');await assert.rejects(one('select public.lwb_acc_today_cashier()'),/only/);
});

test('Handover slip: cashier signs + bag no., receiver signs, slip has notes + last closing (Mohit 28 Nov 2026)',async()=>{
 await db.exec(await sql('lwb_acc_handover_slip_setup.sql'));
 await db.exec(await sql('lwb_acc_handover_slip_setup.sql')); // safe to run again
 const png='data:image/png;base64,iVBORw0KGgo=';
 await as('manager2');
 const b=Math.round(Number((await dash()).closing)*100)/100;
 const g=await one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,null,$3::jsonb)',[JSON.stringify([{to:ids.manager,amount:b}]),JSON.stringify({coins:b}),'[]']);
 await assert.rejects(one('select public.lwb_acc_shift_sign($1,$2,$3,null)',[g.id,'GIVE','hello']),/Sign again/);
 await one('select public.lwb_acc_shift_sign($1,$2,$3,$4)',[g.id,'GIVE',png,' b 12 ']);
 await assert.rejects(one('select public.lwb_acc_shift_sign($1,$2,$3,null)',[g.id,'RECV',png]),/signs for this cash/);
 await as('manager');
 await assert.rejects(one('select public.lwb_acc_shift_sign($1,$2,$3,null)',[g.id,'GIVE',png]),/Only the person who handed/);
 await one('select public.lwb_acc_shift_receive($1,null,null)',[g.id]);
 await one('select public.lwb_acc_shift_sign($1,$2,$3,null)',[g.id,'RECV',png]);
 const S=await one('select public.lwb_acc_shift_slip($1)',[g.id]);
 assert.equal(S.bag_no,'B 12');assert.equal(S.give_sign,png);assert.equal(S.parts.length,1);
 assert.equal(S.parts[0].recv_sign,png);assert.equal(S.parts[0].status,'RECEIVED');
 assert.equal(Number(S.total),b);assert.ok(S.last,'last closing count is there');assert.ok(S.last.notes);
 await as('sales');await assert.rejects(one('select public.lwb_acc_shift_slip($1)',[g.id]),/only/);
 assert.equal((await db.query("select has_table_privilege('authenticated','public.lwb_acc_shift_handovers','SELECT') a")).rows[0].a,false);
});
