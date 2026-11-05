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
const dash=async()=>(await call('select public.lwb_acc_dashboard($1,$2) j',[today,today]))[0].j;

// Old data: day closed 3 days ago, cash out + bank deposit 2 days ago, UPI party money 5 days ago,
// today: a cash party payment (ERP, stays) and a UPI Cash In entry (Accounts, goes).
const order=(await db.query("insert into orders(order_no,customer_name) values('LXY-1','Shree Traders') returning id")).rows[0].id;
const bank=(await db.query("insert into lwb_acc_banks(name,account_no,opening_balance,opening_date) values('ICICI BANK 0013','741651000013',-2592872,null) returning id")).rows[0].id;
const bank2=(await db.query("insert into lwb_acc_banks(name,opening_balance) values('VARACHHA BANK 0011',-245000) returning id")).rows[0].id;
const cOut=(await db.query("select id from lwb_acc_categories where kind='OUT' and name='Canteen'")).rows[0].id;
await db.query(`insert into lwb_acc_day_close(close_date,opening,expected,counted,closed_by) values($1,0,5000,5000,$2)`,[dayAdd(today,-3),ids.accounts]);
const eOut=(await db.query(`insert into lwb_acc_entries(entry_date,kind,category_id,mode,amount,created_by) values($1,'OUT',$2,'CASH',1000,$3) returning id`,[dayAdd(today,-2),cOut,ids.accounts])).rows[0].id;
const eDep=(await db.query(`insert into lwb_acc_entries(entry_date,kind,mode,bank_id,amount,created_by) values($1,'DEPOSIT','CASH',$2,2000,$3) returning id`,[dayAdd(today,-2),bank,ids.accounts])).rows[0].id;
await db.query(`insert into lwb_acc_entries(entry_date,kind,mode,bank_id,amount,created_by) values($1,'IN','UPI',$2,300,$3)`,[today,bank,ids.accounts]);
const pOld=(await db.query(`insert into lwb_tally_payments(order_id,pay_date,mode,amount,created_by,created_at) values($1,$2,'UPI',700,$3,now()-interval '5 days') returning id`,[order,dayAdd(today,-5),ids.accounts])).rows[0].id;
const pNew=(await db.query(`insert into lwb_tally_payments(party,pay_date,mode,amount,created_by) values('Shree Traders',$1,'CHEQUE',400,$2) returning id`,[today,ids.accounts])).rows[0].id;
await db.query(`insert into lwb_tally_payments(party,pay_date,mode,amount,created_by) values('Shree Traders',$1,'CASH',600,$2)`,[today,ids.accounts]);
await db.query(`insert into lwb_tally_payments(order_id,pay_date,mode,amount,created_by,created_at) values($1,$2,'UPI',900,$3,now()-interval '4 days')`,[order,dayAdd(today,-4),ids.accounts]); // old, never checked
await db.query(`insert into lwb_acc_verify(src,src_id,status,bank_id,verified_by) values('PAYMENT',$1,'VERIFIED',$2,$3),('ENTRY',$4,'VERIFIED',$2,$3)`,[pOld,bank,ids.admin,eDep]);
await db.query(`insert into lwb_acc_cheques(src,src_id,cheque_no) values('PAYMENT',$1,'000777'),('ENTRY',$2,'000111')`,[pNew,eOut]);
const imp=(await db.query(`insert into lwb_bank_stmt_imports(bank_id,file_name) values($1,'oct.xls') returning id`,[bank])).rows[0].id;
await db.query(`insert into lwb_bank_stmt_lines(bank_id,import_id,status,credit) values($1,$2,'OPEN',5),($1,$2,'MATCHED',700)`,[bank,imp]);
const staff=(await db.query(`insert into lwb_acc_staff(name,monthly_salary,opening_balance) values('Ramesh',15000,-2000) returning id`)).rows[0].id;
await db.query(`insert into lwb_acc_staff_salary(staff_id,month,amount,created_by) values($1,date_trunc('month',now())::date,15000,$2)`,[staff,ids.accounts]);
await db.query(`insert into lwb_company_payments(amount,acc_entry_id) values(5000,$1),(7000,null)`,[eOut]);
await db.query(`insert into erp_notifications(user_id,title,notification_type) values($1,'old','ACC_CASH_HANDOVER')`,[ids.admin]);

test('only Admin can preview or reset',async()=>{
 for(const r of ['accounts','manager']){
  await as(r);
  await assert.rejects(call('select public.lwb_acc_reset_preview($1)',[today]),/Only an active Admin/);
  await assert.rejects(call(`select public.lwb_acc_reset_run($1,'RESET',0,'[]')`,[today]),/Only an active Admin/);
 }
 assert.equal((await db.query("select has_table_privilege('authenticated','public.lwb_acc_reset_rows','SELECT') a")).rows[0].a,false);
});

test('preview counts and changes nothing',async()=>{
 await as('admin');
 const p=(await call('select public.lwb_acc_reset_preview($1) p',[today]))[0].p;
 assert.equal(p.entries.n,3);assert.equal(Number(p.entries.cash_out),1000);assert.equal(Number(p.entries.deposit),2000);
 assert.equal(p.day_close.n,1);
 assert.equal(p.verify,2,'both bank checks are old');
 assert.equal(p.cheques,1,'cheque of today\'s party payment stays');
 assert.equal(p.bank_stmt.n,2);assert.equal(p.bank_stmt.imports,1);
 assert.equal(p.staff_salary,1);assert.equal(p.staff_opening,1);
 assert.equal(p.company_pay.n,1);
 assert.equal(p.erp_hidden.n,2);assert.equal(Number(p.erp_hidden.amount),1600);
 assert.equal(p.erp_kept.n,2);
 assert.equal(p.banks.length,2);
 assert.equal(await n('lwb_acc_entries'),3);
 await assert.rejects(call('select public.lwb_acc_reset_preview($1)',[dayAdd(today,1)]),/start date/);
 await assert.rejects(call('select public.lwb_acc_reset_preview($1)',[dayAdd(today,-61)]),/start date/);
});

test('wrong word or bad bank stops it, nothing changes',async()=>{
 await as('admin');
 await assert.rejects(call(`select public.lwb_acc_reset_run($1,'reset please',0,'[]')`,[today]),/Type RESET/);
 await assert.rejects(call(`select public.lwb_acc_reset_run($1,'RESET',-5,'[]')`,[today]),/cash in hand/);
 await assert.rejects(call(`select public.lwb_acc_reset_run($1,'RESET',0,'[{"id":99999,"balance":1}]')`,[today]),/bank balances/);
 assert.equal(await n('lwb_acc_entries'),3);assert.equal(await n('lwb_acc_resets'),0);
});

let resetId;
test('reset removes Accounts data, keeps party payments, sets opening cash and bank balances',async()=>{
 await as('admin');
 const before=await n('lwb_tally_payments');
 const r=(await call(`select public.lwb_acc_reset_run($1,'reset',2500,$2::jsonb) r`,[today,JSON.stringify([{id:bank,balance:150000}])]))[0].r;
 resetId=r.id;
 assert.equal(r.counts.lwb_acc_entries,3);assert.equal(r.counts.lwb_acc_day_close,1);
 for(const t of ['lwb_acc_entries','lwb_acc_staff_salary','lwb_bank_stmt_lines','lwb_bank_stmt_imports'])assert.equal(await n(t),0,t);
 assert.equal(await n('lwb_acc_verify'),0);
 assert.deepEqual((await db.query('select src,cheque_no from lwb_acc_cheques')).rows,[{src:'PAYMENT',cheque_no:'000777'}]);
 assert.equal(await n('lwb_tally_payments'),before,'party payments stay');
 assert.equal(await n('lwb_company_payments where acc_entry_id is null'),2,'company payments stay, link cleared');
 const st=(await db.query('select opening_balance,opening_date::text d from lwb_acc_staff')).rows[0];
 assert.equal(Number(st.opening_balance),0);assert.equal(st.d,today);
 const bk=(await db.query('select id,opening_balance,opening_date::text d from lwb_acc_banks order by id')).rows;
 assert.equal(Number(bk[0].opening_balance),150000);assert.equal(bk[0].d,today);assert.equal(Number(bk[1].opening_balance),0);
 assert.equal(await n("erp_notifications where notification_type='ACC_CASH_HANDOVER' and not is_read"),0);
 // backup: every removed row + old values of changed rows
 const del=await n(`lwb_acc_reset_rows where reset_id=${resetId} and action='DELETED'`);
 assert.equal(del,3+1+2+1+2+1+1);
 assert.equal(await n(`lwb_acc_reset_rows where reset_id=${resetId} and tbl='lwb_acc_banks'`),2);

 const d=await dash();
 assert.equal(d.opening_set,true);assert.equal(Number(d.opening),2500);
 assert.equal(Number(d.closing),2500+600,'today\'s cash party payment counts');
 assert.ok(d.lines.every(l=>l.src!=='ENTRY'));
 assert.deepEqual(d.pending.map(l=>Number(l.amount)),[400],'only today\'s cheque waits for the bank check');
 const b=d.banks.find(x=>x.id==bank);assert.equal(Number(b.balance),150000);
 assert.equal(Number(d.banks.find(x=>x.id==bank2).balance),0);
});

test('old dates show nothing on the dashboard; backup can be downloaded',async()=>{
 await as('admin');
 const d=(await call('select public.lwb_acc_dashboard($1,$2) j',[dayAdd(today,-6),dayAdd(today,-1)]))[0].j;
 assert.equal(d.lines.length,0);
 const bk=(await call('select public.lwb_acc_reset_backup($1,0) b',[resetId]))[0].b;
 assert.equal(bk.reset.start_date,today);
 assert.ok(bk.rows.some(x=>x.table==='lwb_acc_entries'&&x.row.amount==1000));
 const p=(await call('select public.lwb_acc_reset_preview($1) p',[today]))[0].p;
 assert.equal(p.entries.n,0);assert.equal(p.last.id,resetId);assert.equal(p.current_start,today);
 await as('accounts');await assert.rejects(call('select public.lwb_acc_reset_backup($1,0)',[resetId]),/Only an active Admin/);
});

test('new entries after the reset work as before',async()=>{
 await as('accounts');
 const c=(await db.query("select id from lwb_acc_categories where kind='OUT' and name='Canteen'")).rows[0].id;
 await call('select public.lwb_acc_add_entry($1::jsonb)',[JSON.stringify({date:today,kind:'OUT',category_id:c,mode:'CASH',amount:100})]);
 const d=await dash();
 assert.equal(Number(d.closing),2500+600-100);
});
