import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_receipt_past_edit_setup.sql + lwb_acc_cdiff_fix_26nov_navdurga.sql on a tiny copy of the tables (no live database).
// The real ledger edit, accounts dashboard and cash box handover SQL run first, as on the live database.
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
await db.exec(`CREATE TABLE public.lwb_party_returns(id uuid primary key default gen_random_uuid(),return_no text,party text,order_id uuid,company_id uuid,return_date date,amount numeric(14,2),note text,note_id uuid,created_by uuid,created_at timestamptz default now(),cancelled_by uuid,cancelled_at timestamptz);
ALTER TABLE public.lwb_tally_notes ADD COLUMN IF NOT EXISTS cancelled_by uuid;`);
await db.exec(await sql('lwb_receipt_date_change_setup.sql'));
await db.exec(await sql('lwb_ledger_admin_edit_setup.sql'));
await db.exec(await sql('lwb_ledger_admin_edit_setup.sql'));  // safe to run again
await db.exec(await sql('lwb_ledger_accounts_edit_setup.sql'));
const P='SHREE DEV NARAYAN (BHAIYA NAGAR)';
await db.query("insert into lwb_customer_master values($1)",[P]);
async function po(no,amt,sku='COKE 600'){
 const id=(await db.query('insert into orders(order_no,customer_name,order_date) values($1,$2,$3) returning id',[no,P,today])).rows[0].id;
 await db.query('insert into order_items values($1,1,$2,$3)',[id,amt,sku]);
 await db.query('insert into lwb_tally_invoices(order_id,invoice_no,invoice_date,amount,bills,entered_by) values($1,$2,$3,$4,$5,$6)',[id,'T-'+no,today,amt,JSON.stringify([{firm:P,no:'T-'+no,amount:amt}]),ids.accounts]);
 return id;
}
const lines=async rid=>(await db.query('select id,mode,amount::float8 a,ref_no,pay_date::text d,remark from lwb_tally_payments where receipt_id=$1 and cancelled_at is null order by amount desc,id',[rid])).rows;
const allocs=async rid=>(await db.query('select order_id,amount::float8 a from lwb_party_allocs where receipt_id=$1 and cancelled_at is null',[rid])).rows;
// cash box handover chain, as on live
await db.exec(`
ALTER TABLE public.user_profiles ADD CONSTRAINT user_profiles_role_check CHECK (lower(btrim(role)) IN ('admin','accounts','manager','sales','warehouse','transport','driver'));
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
CREATE FUNCTION public.lwb_hired_reader() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('accounts','admin','manager'));
$fn$;
CREATE TABLE IF NOT EXISTS public.lwb_goods_inward(id uuid default gen_random_uuid() primary key,invoice_no text,invoice_date date,received_date date);
CREATE TABLE IF NOT EXISTS public.lwb_goods_inward_items(inward_id uuid,taxable_amount numeric,total_amount numeric);
ALTER TABLE public.sku_master ADD COLUMN IF NOT EXISTS gst_rate numeric; ALTER TABLE public.sku_master ADD COLUMN IF NOT EXISTS cess_rate numeric;
`);
for(const f of ['lwb_cashier_role_setup.sql','lwb_gst_register_setup.sql','lwb_acc_shift_handover_setup.sql','lwb_acc_cash_split_handover_setup.sql',
  'lwb_acc_cash_diff_damaged_setup.sql'])await db.exec(await sql(f));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');
ids.vishal='00000000-0000-4000-8000-000000000020';
await db.query('insert into auth.users values($1)',[ids.vishal]);await db.query("insert into user_profiles values($1,'manager',true,'Vishal')",[ids.vishal]);
await as('admin');await call('select public.lwb_acc_cash_people_set($1)',[[ids.accounts,ids.vishal,ids.admin]]);
const one=async(q,a)=>Object.values((await call(q,a))[0])[0];
const book=async()=>Number((await one('select public.lwb_acc_dashboard($1,$2)',[today,today])).closing);
const r2=v=>Math.round(v*100)/100;
const give=async(counted,note)=>one('select public.lwb_acc_shift_give3($1::jsonb,$2::jsonb,$3,$4::jsonb)',
  [JSON.stringify([{to:ids.vishal,amount:counted}]),JSON.stringify({coins:counted}),note,'[]']);

test('Cash payment after a handover: Accounts must ask Admin; Admin OK sets the Short right (Mohit 27 Nov 2026)',async()=>{
 await db.exec(await sql('lwb_receipt_past_edit_setup.sql'));
 await db.exec(await sql('lwb_receipt_past_edit_setup.sql')); // safe to run again
 await as('admin');await call('select public.lwb_acc_set_opening($1,$2,$3)',[today,10000,'start']);
 await as('accounts');
 const rc=await receive(P,[{mode:'CASH',amount:33220}],C);                    // real cash 30,220
 const rid=rc.receipt_id||rc.id;
 assert.equal(await book(),43220);
 // same day, before any handover: Accounts may still edit directly
 assert.equal((await one('select public.lwb_receipt_edit_check($1,$2,$3::jsonb)',[rid,today,JSON.stringify([{id:(await lines(rid))[0].id,mode:'CASH',amount:33220}])])).needs_admin,false);
 // handover: counted 40,220 -> Short 3,000 + 653 real short
 const g=await give(39567,'short');assert.equal(Number(g.diff),3653);
 await as('vishal');await call('select public.lwb_acc_shift_receive($1,null,null)',[g.id]);
 await as('accounts');
 assert.equal(await book(),39567);
 const L=[{id:(await lines(rid))[0].id,mode:'CASH',amount:30220}];
 const K=await one('select public.lwb_receipt_edit_check($1,$2,$3::jsonb)',[rid,today,JSON.stringify(L)]);
 assert.equal(K.needs_admin,true);assert.equal(Number(K.delta),-3000);assert.equal(Number(K.adjust.from),3653);assert.equal(Number(K.adjust.to),653);
 await assert.rejects(call('select public.lwb_receipt_edit($1,$2,$3::jsonb,null,$4)',[rid,today,JSON.stringify(L),'typo']),/Needs Admin OK/);
 await assert.rejects(call('select public.lwb_receipt_delete($1,$2)',[rid,'typo']),/Needs Admin OK/);
 await assert.rejects(call('select public.lwb_receipt_edit_ask($1,$2,$3::jsonb,null,null)',[rid,today,JSON.stringify(L)]),/reason/);
 const A=await one('select public.lwb_receipt_edit_ask($1,$2,$3::jsonb,null,$4)',[rid,today,JSON.stringify(L),'33,220 typed, 30,220 came']);
 await assert.rejects(call('select public.lwb_receipt_edit_ask($1,$2,$3::jsonb,null,$4)',[rid,today,JSON.stringify(L),'again']),/already waiting/);
 assert.equal((await db.query("select count(*)::int n from erp_notifications where notification_type='RECEIPT_EDIT_ASK' and user_id=$1",[ids.admin])).rows[0].n,1);
 assert.equal(await book(),39567);                                            // nothing changed yet
 await assert.rejects(call('select public.lwb_receipt_edit_decide($1,true,null)',[A.id]),/Only Admin/);
 await as('admin');
 assert.equal((await one('select public.lwb_receipt_edit_asks($1,$2)',['WAITING',30]))[0].can_decide,true);
 const d=await one('select public.lwb_receipt_edit_decide($1,true,null)',[A.id]);
 assert.equal(d.status,'APPROVED');assert.equal(Number(d.adjust.to),653);
 assert.equal((await lines(rid))[0].a,30220);
 assert.equal(await book(),39567);                                            // book = counted cash again
 const cd=(await db.query("select amount::float8 a from lwb_acc_cash_diff where batch_id=$1",[g.batch])).rows[0].a;assert.equal(cd,653);
 const bells=(await db.query("select user_id from erp_notifications where notification_type='RECEIPT_EDIT_DONE'")).rows.map(r=>r.user_id);
 assert.ok(bells.includes(ids.accounts)&&bells.includes(ids.vishal));
 const M=await one('select public.lwb_receipt_edit_marks($1,$2)',[today,today]);
 assert.equal(Number(M.payments.find(p=>p.receipt_id===rid).old),33220);assert.equal(Number(M.entries[0].old),3653);
 // reject path + UPI edits stay free
 await as('accounts');
 const u=await receive(P,[{mode:'UPI',amount:500,ref:'UTR1'}],C);const urid=u.receipt_id||u.id;
 assert.equal((await one('select public.lwb_receipt_edit_check($1,$2,$3::jsonb)',[urid,today,JSON.stringify([{id:(await lines(urid))[0].id,mode:'UPI',amount:400,ref:'UTR1'}])])).needs_admin,false);
 const A2=await one('select public.lwb_receipt_edit_ask($1,$2,$3::jsonb,null,$4)',[rid,today,JSON.stringify([{id:(await lines(rid))[0].id,mode:'CASH',amount:30000}]),'try']);
 await as('admin');await assert.rejects(call('select public.lwb_receipt_edit_decide($1,false,null)',[A2.id]),/why/);
 await one('select public.lwb_receipt_edit_decide($1,false,$2)',[A2.id,'30,220 is right']);
 assert.equal((await lines(rid))[0].a,30220);
 await as('manager');await assert.rejects(call('select public.lwb_receipt_edit_asks(null,30)'),/only/i);
});

test('One-time 26/11 fix: Short 3,653 -> 653 only when the data matches; runs once',async()=>{
 await db.exec(`DELETE FROM lwb_receipt_cash_adjust`);
 await assert.rejects(db.exec(await sql('lwb_acc_cdiff_fix_26nov_navdurga.sql')),/Expected one 26\/11 Short/);
 await db.exec('ROLLBACK');
  const rid=(await db.query(`select receipt_id from lwb_tally_payments where mode='CASH' and amount=30220`)).rows[0].receipt_id;
 await db.exec(`UPDATE lwb_tally_payments SET party='NAVDURGA TRADERS (AMROLI)', pay_date='2026-11-26' WHERE receipt_id='${rid}';
   INSERT INTO lwb_acc_entries(id,entry_date,kind,mode,amount,created_by) VALUES (gen_random_uuid(),'2026-11-26','OUT','CASH',3653,'${ids.admin}');
   INSERT INTO lwb_acc_cash_diff(day,kind,amount,entry_id,created_by) SELECT '2026-11-26','SHORT',3653,id,'${ids.admin}' FROM lwb_acc_entries WHERE amount=3653 AND entry_date='2026-11-26';`);
 await db.exec(await sql('lwb_acc_cdiff_fix_26nov_navdurga.sql'));
 await db.exec(await sql('lwb_acc_cdiff_fix_26nov_navdurga.sql'));   // second time: nothing
 assert.equal((await db.query(`select amount::float8 a from lwb_acc_cash_diff where day='2026-11-26'`)).rows[0].a,653);
 assert.equal((await db.query(`select amount::float8 a from lwb_acc_entries where entry_date='2026-11-26' and kind='OUT'`)).rows[0].a,653);
 assert.equal((await db.query(`select count(*)::int n from lwb_receipt_cash_adjust`)).rows[0].n,1);
});
