import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_ledger_admin_edit_setup.sql on a tiny copy of the tables (no live database).
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
let b1,b2,dupe,keep;

test('Admin edits a receipt: date, amount, mode, ref; splits follow the new total; log kept',async()=>{
 b1=await po('S-1',13650);b2=await po('S-2',29750);
 await as('accounts');
 keep=(await receive(P,[{mode:'CASH',amount:12000},{mode:'UPI',amount:1650,ref:'U1'}],C,null)).receipt_id;
 dupe=(await receive(P,[{mode:'CASH',amount:12000},{mode:'UPI',amount:1650,ref:'U2'}],C,null)).receipt_id;
 assert.equal((await allocs(keep)).reduce((a,x)=>a+x.a,0),13650);
 // Manager cannot edit (Admin and Accounts can)
 await as('manager');
 const L=await lines(keep);
 await assert.rejects(call('select public.lwb_receipt_edit($1,$2,$3::jsonb)',[keep,today,JSON.stringify(L.map(l=>({id:l.id,mode:l.mode,amount:l.a,ref:l.ref_no})))]),/Only Admin/);
 await as('admin');
 const y=dayAdd(today,-1);
 // cash 12,000 -> 10,000 and UPI -> Bank with ref
 await call('select public.lwb_receipt_edit($1,$2,$3::jsonb,$4,$5)',[keep,y,JSON.stringify([{id:L[0].id,mode:'CASH',amount:10000},{id:L[1].id,mode:'BANK',amount:1650,ref:'NEFT9'}]),'fixed','typo']);
 const n=await lines(keep);
 assert.deepEqual(n.map(x=>[x.mode,x.a,x.ref_no,x.d,x.remark]),[['CASH',10000,null,y,'fixed'],['BANK',1650,'NEFT9',y,'fixed']]);
 assert.equal((await allocs(keep)).reduce((a,x)=>a+x.a,0),11650);   // splits cut to the new total
 // a line must stay; future refused; ref used elsewhere refused
 await assert.rejects(call('select public.lwb_receipt_edit($1,$2,$3::jsonb)',[keep,y,JSON.stringify([{id:L[0].id,mode:'CASH',amount:10000}])]),/Every line/);
 await assert.rejects(call('select public.lwb_receipt_edit($1,$2,$3::jsonb)',[keep,dayAdd(today,1),JSON.stringify([{id:L[0].id,mode:'CASH',amount:1},{id:L[1].id,mode:'BANK',amount:1}])]),/future/);
 await assert.rejects(call('select public.lwb_receipt_edit($1,$2,$3::jsonb)',[keep,y,JSON.stringify([{id:L[0].id,mode:'CASH',amount:1},{id:L[1].id,mode:'UPI',amount:1,ref:'U2'}])]),/already entered/);
 // add money with a new line: goes to the oldest due bill of the brand
 await call('select public.lwb_receipt_edit($1,$2,$3::jsonb)',[keep,y,JSON.stringify([{id:L[0].id,mode:'CASH',amount:10000},{id:L[1].id,mode:'BANK',amount:1650,ref:'NEFT9'},{mode:'UPI',amount:500,ref:'U3'}])]);
 assert.equal((await lines(keep)).length,3);
 const log=(await call('select public.lwb_ledger_edit_log_for($1) j',[[keep]]))[0].j;
 assert.equal(log.length,2);assert.equal(log[0].action,'EDIT');assert.equal(log[0].reason,'typo');assert.equal(log[0].by,'admin user');
});

test('Admin deletes the duplicate receipt; Tally bill edit + delete; return edit + delete',async()=>{
 await as('manager');
 await assert.rejects(call('select public.lwb_receipt_delete($1)',[dupe]),/Only Admin/);
 await assert.rejects(call('select public.lwb_tally_bill_delete($1)',[b1]),/Only Admin/);
 await as('admin');
 await call('select public.lwb_receipt_delete($1,$2)',[dupe,'entered twice']);
 assert.equal((await lines(dupe)).length,0);assert.equal((await allocs(dupe)).length,0);
 await assert.rejects(call('select public.lwb_receipt_delete($1)',[dupe]),/already deleted/);
 // bill edit
 await call('select public.lwb_tally_bill_edit($1,$2,$3::jsonb,$4)',[b2,dayAdd(today,-2),JSON.stringify([{firm:P,no:'10462',amount:29000}]),'amount typo']);
 const t=(await db.query('select invoice_no,invoice_date::text d,amount::float8 a from lwb_tally_invoices where order_id=$1',[b2])).rows[0];
 assert.deepEqual([t.invoice_no,t.d,t.a],['10462',dayAdd(today,-2),29000]);
 // bill delete: money set to it goes back to advance
 const before=(await allocs(keep)).filter(a=>a.order_id===b1).reduce((s,x)=>s+x.a,0);
 assert.ok(before>0);
 const r=(await call('select public.lwb_tally_bill_delete($1,$2) j',[b1,'wrong PO']))[0].j;
 assert.equal(r.back_to_advance,before);
 assert.equal((await db.query('select count(*)::int n from lwb_tally_invoices where order_id=$1',[b1])).rows[0].n,0);
 assert.equal((await allocs(keep)).filter(a=>a.order_id===b1).length,0);
 // return
 const rid=(await db.query("insert into lwb_party_returns(return_no,party,return_date,amount,created_by) values('RET-1',$1,$2,893.75,$3) returning id",[P,today,ids.accounts])).rows[0].id;
 await call('select public.lwb_party_return_edit($1,$2,$3)',[rid,dayAdd(today,-3),'1 case']);
 assert.equal((await db.query('select return_date::text d,note from lwb_party_returns where id=$1',[rid])).rows[0].d,dayAdd(today,-3));
 await call('select public.lwb_party_return_delete($1,$2)',[rid,'dup']);
 assert.ok((await db.query('select cancelled_at from lwb_party_returns where id=$1',[rid])).rows[0].cancelled_at);
 const log=(await call('select public.lwb_ledger_edit_log_for($1) j',[[dupe,b1,b2,rid]]))[0].j;
 assert.deepEqual(log.map(x=>x.kind+':'+x.action),['RECEIPT:DELETE','TALLY_BILL:EDIT','TALLY_BILL:DELETE','RETURN:EDIT','RETURN:DELETE']);
 await as('manager');
 assert.equal((await call('select public.lwb_ledger_edit_log_for($1) j',[[dupe]]))[0].j.length,0);
});

test('receipt lines with ids: Admin only',async()=>{
 await as('manager');
 await assert.rejects(call('select public.lwb_receipt_lines($1)',[keep]),/Only Admin/);
 await as('admin');
 const l=(await call('select public.lwb_receipt_lines($1) j',[keep]))[0].j;
 assert.equal(l.length,3);assert.ok(l.every(x=>x.id));
});
test('Tally style: Duplicate a receipt (new date, splits like a new payment) and Cancel (₹0 row kept)',async()=>{
 await as('manager');
 await assert.rejects(call('select public.lwb_receipt_duplicate($1,$2,$3::jsonb)',[keep,today,JSON.stringify([{mode:'CASH',amount:100}])]),/Only Admin/);
 await assert.rejects(call('select public.lwb_ledger_cancel($1,$2)',['RECEIPT',keep]),/Only Admin/);
 await as('admin');
 await assert.rejects(call('select public.lwb_receipt_duplicate($1,$2,$3::jsonb)',[keep,dayAdd(today,1),JSON.stringify([{mode:'CASH',amount:100}])]),/future/);
 await assert.rejects(call('select public.lwb_receipt_duplicate($1,$2,$3::jsonb)',[keep,today,JSON.stringify([{mode:'UPI',amount:100,ref:'U3'}])]),/already entered/);
 const y=dayAdd(today,-1);
 const r=(await call('select public.lwb_receipt_duplicate($1,$2,$3::jsonb,$4,$5) j',[keep,y,JSON.stringify([{mode:'CASH',amount:1000},{mode:'UPI',amount:200,ref:'U9'}]),'copy','same again']))[0].j;
 assert.notEqual(r.receipt_id,keep);
 const n=await lines(r.receipt_id);
 assert.deepEqual(n.map(x=>[x.mode,x.a,x.ref_no,x.d,x.remark]),[['CASH',1000,null,y,'copy'],['UPI',200,'U9',y,'copy']]);
 assert.equal((await db.query('select company_id::text c from lwb_tally_payments where receipt_id=$1 limit 1',[r.receipt_id])).rows[0].c,C);
 assert.equal((await allocs(r.receipt_id)).reduce((a,x)=>a+x.a,0),1200);   // went to the due bill (b2)
 // cancel it: lines and splits cancelled, shown in the cancelled list with ₹0 effect
 await call('select public.lwb_ledger_cancel($1,$2,$3)',['RECEIPT',r.receipt_id,'not received']);
 assert.equal((await lines(r.receipt_id)).length,0);assert.equal((await allocs(r.receipt_id)).length,0);
 await assert.rejects(call('select public.lwb_ledger_cancel($1,$2)',['RECEIPT',r.receipt_id]),/already deleted/);
 // cancel a bill and a return too
 await call('select public.lwb_ledger_cancel($1,$2)',['TALLY_BILL',b2]);
 const rid=(await db.query("insert into lwb_party_returns(return_no,party,company_id,return_date,amount,created_by) values('RET-2',$1,$2,$3,100,$4) returning id",[P,C,today,ids.accounts])).rows[0].id;
 await call('select public.lwb_ledger_cancel($1,$2)',['RETURN',rid]);
 await assert.rejects(call('select public.lwb_ledger_cancel($1,$2)',['OTHER',rid]),/Unknown/);
 const cx=(await call('select public.lwb_ledger_cancelled(400) j'))[0].j;
 assert.deepEqual(cx.map(x=>[x.kind,x.date,Number(x.amount),x.no,x.company_id]),[['RECEIPT',y,1200,null,C],['TALLY_BILL',dayAdd(today,-2),29000,'10462',C],['RETURN',today,100,'RET-2',C]]);
 assert.equal(cx[0].lines.length,2);assert.equal(cx[0].reason,'not received');assert.equal(cx[0].party,P);
 const log=(await call('select public.lwb_ledger_edit_log_for($1) j',[[r.receipt_id]]))[0].j;
 assert.deepEqual(log.map(x=>x.action),['DUPLICATE','CANCEL']);
 await as('manager');
 assert.equal((await call('select public.lwb_ledger_cancelled(400) j'))[0].j.length,0);
});
test('Accounts can also edit / duplicate / cancel (Mohit: Accounts all); Manager cannot',async()=>{
 await as('accounts');
 const L=(await call('select public.lwb_receipt_lines($1) j',[keep]))[0].j;
 await call('select public.lwb_receipt_edit($1,$2,$3::jsonb,$4,$5)',[keep,today,JSON.stringify(L.map(l=>({id:l.id,mode:l.mode,amount:l.amount,ref:l.ref}))),'by accounts','date fix']);
 assert.ok((await lines(keep)).every(x=>x.d===today));
 const r=(await call('select public.lwb_receipt_duplicate($1,$2,$3::jsonb) j',[keep,today,JSON.stringify([{mode:'CASH',amount:50}])]))[0].j;
 await call('select public.lwb_ledger_cancel($1,$2)',['RECEIPT',r.receipt_id]);
 const log=(await call('select public.lwb_ledger_edit_log_for($1) j',[[keep,r.receipt_id]]))[0].j;
 assert.ok(log.filter(x=>x.by==='accounts user').length>=3);
 await as('manager');
 await assert.rejects(call('select public.lwb_receipt_lines($1)',[keep]),/Only Admin/);
});
