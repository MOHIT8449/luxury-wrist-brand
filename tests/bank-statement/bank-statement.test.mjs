import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_bank_statement_setup.sql on a tiny copy of the tables it reads (no live database).
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
CREATE TABLE public.order_items(order_id uuid,loaded_qty numeric,rate numeric);
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
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

const today=(await db.query("select (now() at time zone 'Asia/Kolkata')::date::text d")).rows[0].d;
const dayAdd=(d,n)=>{const x=new Date(d+'T12:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};
const D=n=>dayAdd(today,-n);
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const one=async(q,args)=>Object.values((await call(q,args))[0])[0];
const imp=(rows,file='stmt.xlsx')=>one('select public.lwb_bank_stmt_import($1,$2,$3::jsonb)',[bank,file,JSON.stringify(rows)]);
const list=(from=D(30),to=today)=>one('select public.lwb_bank_stmt_list($1,$2,$3)',[bank,from,to]);
const assign=(ids_,p)=>one('select public.lwb_bank_stmt_assign($1::uuid[],$2::jsonb)',['{'+ids_.join(',')+'}',JSON.stringify(p)]);
const dash=async()=>one('select public.lwb_acc_dashboard($1,$2)',[D(30),today]);
const bankBal=async()=>Number((await dash()).banks.find(b=>b.id===bank).balance);
const partyDue=async p=>{const d=await one('select public.lwb_party_billing(400)');return d.orders.filter(o=>o.party===p||o.customer_name===p).reduce((a,o)=>a+Number(o.due),0)};
const P='SHREE JAGDISH TRADERS';
let bank,o1;
const row=(n,narr,cr,dr,ref='')=>({date:D(n),narration:narr,ref,credit:cr||0,debit:dr||0});

test('setup: bank, party with a bill, ERP money waiting for the bank check',async()=>{
 await db.query("insert into lwb_customer_master values($1)",[P]);
 o1=(await db.query("insert into orders(order_no,customer_name,order_date) values('LXY-1',$1,$2) returning id",[P,D(9)])).rows[0].id;
 await db.query('insert into order_items values($1,1,30000)',[o1]);
 await db.query('insert into lwb_tally_invoices(order_id,invoice_no,invoice_date,amount,bills,entered_by) values($1,$2,$3,30000,$4,$5)',[o1,'T-1',D(9),JSON.stringify([{name:P,no:'T-1',amount:30000}]),ids.accounts]);
 await as('accounts');
 bank=await one("select public.lwb_acc_save_bank(null,'ICICI 0013','741651000013',0,null,true)");
 // UPI party payment with UTR (entered by Accounts) and a cash deposit, both waiting for Admin
 await one('select public.lwb_party_receive($1,$2,$3::jsonb,null,null)',[P,D(8),JSON.stringify([{mode:'UPI',amount:5000,ref:'UTR998877'}])]);
 await one('select public.lwb_acc_add_entry($1::jsonb)',[JSON.stringify({date:D(7),kind:'DEPOSIT',bank_id:bank,amount:20000})]);
 // two same UPI amounts on one day without a reference: can not be told apart
 const cat=(await db.query("select id from lwb_acc_categories where kind='IN' and name='Other income'")).rows[0].id;
 for(const r of ['A','B'])await one('select public.lwb_acc_add_entry($1::jsonb)',[JSON.stringify({date:D(6),kind:'IN',category_id:cat,mode:'UPI',bank_id:bank,amount:1000,party:'Ramesh '+r})]);
 assert.equal((await dash()).pending.length,4);
 assert.equal(await partyDue(P),25000);
});

test('only Admin uploads; Accounts sees the list; others nothing',async()=>{
 await as('accounts');await assert.rejects(imp([row(1,'X',10)]),/Only Admin/);
 assert.ok(Array.isArray((await list()).lines));
 for(const r of ['manager','driver']){await as(r);await assert.rejects(list(),/Accounts or Admin only/)}
 await assert.rejects(call("select public.lwb_bank_stmt_assign('{}'::uuid[],'{}'::jsonb)"),/Only Admin/);
});

let first;
test('1st to 7th, then 1st to 10th: old lines are skipped, twins kept, matching ERP money is checked by itself',async()=>{
 await as('admin');
 first=[
  row(9,'NEFT-OPENING ADJ',null,null),                       // no amount: not a line
  row(8,'UPI/SHREE JAGDISH/UTR998877/PAYMENT',5000),          // = UPI party payment by UTR
  row(7,'CASH DEPOSIT BY SELF',20000),                         // = the only 20,000 deposit
  row(6,'UPI/9876543210/RAMESH',1000),                         // two ERP lines of 1,000 -> not sure
  row(5,'NEFT-SHREE JAGDISH TRADERS-HDFC',12000,null,'N123456789'),
  row(5,'NEFT-SHREE JAGDISH TRADERS-HDFC',12000,null,'N123456789'), // same line twice in the file: both kept
  row(4,'BANK CHARGES',null,118),
  row(3,'IMPS/OWN TRANSFER',null,50000),
 ];
 const r1=await imp(first,'1-7.xlsx');
 assert.deepEqual([r1.lines,r1.new,r1.skipped,r1.bad,r1.matched],[7,7,0,1,2]);
 const again=await imp(first,'1-7 again.xlsx');
 assert.deepEqual([again.new,again.skipped,again.matched],[0,7,0]);
 const r2=await imp([...first,row(2,'UPI/AKASH/4455',3000),row(1,'CHQ CLG 000451',8000,null,'000451'),row(0,'ATM WDL',null,10000)],'1-10.xlsx');
 assert.deepEqual([r2.new,r2.skipped],[3,7]);
 const L=await list();
 assert.equal(L.lines.length,10);
 const st=s=>L.lines.filter(l=>l.status===s).length;
 assert.equal(st('MATCHED'),2);assert.equal(st('OPEN'),8);
 const amb=L.lines.find(l=>Number(l.credit)===1000);
 assert.equal(amb.sugg.length,2,'both 1,000 entries are offered');
 const d=await dash();
 assert.equal(d.pending.length,2,'UPI payment and deposit are bank-checked now');
 assert.equal(await bankBal(),25000);
});

test('Suspense: tick many and book them at once; party outstanding drops; undo puts it back',async()=>{
 await as('admin');
 let L=await list();const by=f=>L.lines.filter(f).map(l=>l.id);
 const neft=by(l=>Number(l.credit)===12000);
 // money out can not be a party payment: that line fails alone, the rest are booked
 const r=await assign([...neft,...by(l=>Number(l.debit)===118)],{type:'PARTY',party:P});
 assert.equal(r.done,2);assert.equal(r.errors.length,1);assert.match(r.errors[0].error,/money out/);
 assert.equal(await partyDue(P),25000-24000);
 // expense head, cash withdrawn, ignore, match one of the 1,000 suggestions
 const charges=(await db.query("select id from lwb_acc_categories where kind='OUT' and name='Bank charges'")).rows[0].id;
 assert.equal((await assign(by(l=>Number(l.debit)===118),{type:'OUT',category_id:charges})).done,1);
 assert.equal((await assign(by(l=>Number(l.debit)===10000),{type:'WITHDRAW'})).done,1);
 assert.equal((await assign(by(l=>Number(l.debit)===50000),{type:'IGNORE',note:'Own account transfer'})).done,1);
 const amb=L.lines.find(l=>Number(l.credit)===1000);
 assert.equal((await assign([amb.id],{type:'MATCH',src:amb.sugg[0].src,id:amb.sugg[0].id})).done,1);
 await assert.rejects(assign([amb.id,neft[0]],{type:'MATCH',src:'ENTRY',id:amb.sugg[1].id}),/one line/);
 // bank: 5,000 + 20,000 + 24,000 + 1,000 in; 118 + 10,000 out
 assert.equal(await bankBal(),25000+24000+1000-118-10000);
 L=await list();
 assert.equal(L.lines.filter(l=>l.status==='OPEN').length,2,'only Akash UPI and the cheque are left');
 const wd=L.lines.find(l=>Number(l.debit)===10000);assert.equal(wd.how,'WITHDRAW');assert.equal(wd.linked.category,'Cash from bank');
 // the upload with booked lines can not be removed
 const imps=L.imports;assert.equal(imps.length,3);
 await assert.rejects(one('select public.lwb_bank_stmt_remove_import($1)',[imps.find(i=>i.file==='1-7.xlsx').id]),/Undo them first/);
 assert.equal(await one('select public.lwb_bank_stmt_remove_import($1)',[imps.find(i=>i.file==='1-7 again.xlsx').id]),0);
 // undo the party payment: due back, payment cancelled
 await one('select public.lwb_bank_stmt_undo($1)',[neft[0]]);
 assert.equal(await partyDue(P),25000-12000);
 // undo an auto match: back to waiting, not matched again by itself
 L=await list();const m=L.lines.find(l=>l.how==='AUTO'&&Number(l.credit)===20000);
 await one('select public.lwb_bank_stmt_undo($1)',[m.id]);
 assert.equal((await dash()).pending.length,2);
 await imp(first);L=await list();
 assert.equal(L.lines.find(l=>l.id===m.id).status,'OPEN');
 assert.equal(await bankBal(),25000+12000+1000-118-10000-20000);
});
