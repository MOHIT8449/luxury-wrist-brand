import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_sales_head_outstanding_setup.sql on a tiny copy of the tables it reads (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000002',
  sales:'00000000-0000-4000-8000-000000000003',accounts:'00000000-0000-4000-8000-000000000004',
  cashier:'00000000-0000-4000-8000-000000000005',warehouse:'00000000-0000-4000-8000-000000000006'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,sales_person text,status text);
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key,invoice_no text,invoice_date date,amount numeric,bills jsonb,entered_at timestamptz default now());
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,reported_at timestamptz default now(),
  cash_reported numeric,payment_status text,payment_mode text,cash_amount numeric,online_amount numeric,online_mode text,
  bank_ref text,online_reference text,payment_reference text,payment_reviewed_at timestamptz,driver_user_id uuid);
CREATE TABLE public.lwb_tally_payments(id uuid default gen_random_uuid() primary key,receipt_id uuid,order_id uuid,party text,pay_date date,
  mode text,amount numeric,ref_no text,created_by uuid,created_at timestamptz default now(),cancelled_at timestamptz,company_id uuid);
CREATE TABLE public.lwb_party_allocs(id uuid default gen_random_uuid() primary key,receipt_id uuid,order_id uuid,amount numeric,
  created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_acc_cheques(src text,src_id uuid,deposited_on date,primary key(src,src_id));
CREATE TABLE public.lwb_acc_verify(src text,src_id uuid,status text,primary key(src,src_id));
CREATE TABLE public.lwb_companies(id uuid primary key,name text,color text,sort_no int,active boolean);
CREATE TABLE public.lwb_tally_party_map(tally_name text,tally_key text,customer_name text);
CREATE TABLE public.lwb_party_opening_balances(customer_name text,company_id uuid,amount numeric,as_of_date date);
CREATE TABLE public.lwb_party_returns(id uuid default gen_random_uuid(),party text,order_id uuid,company_id uuid,amount numeric,return_date date,cancelled_at timestamptz);
CREATE TABLE public.erp_notifications(id bigint generated always as identity,user_id uuid,title text,message text,notification_type text,order_id uuid);
CREATE TABLE public.bill_rows(order_id uuid,due numeric,collected numeric);
-- Stand-ins for the live helpers.
CREATE FUNCTION public.lwb_party_parent(p text) RETURNS text LANGUAGE sql AS $$ SELECT btrim(p) $$;
CREATE FUNCTION public.lwb_party_key(p text) RETURNS text LANGUAGE sql AS $$ SELECT upper(btrim(p)) $$;
CREATE FUNCTION public.lwb_order_company(p uuid) RETURNS uuid LANGUAGE sql AS $$ SELECT NULL::uuid $$;
CREATE FUNCTION public.lwb_order_office_paid(p uuid) RETURNS numeric LANGUAGE sql AS $$
  SELECT coalesce((SELECT sum(amount) FROM public.lwb_tally_payments WHERE order_id=p AND cancelled_at IS NULL),0)
       + coalesce((SELECT sum(amount) FROM public.lwb_party_allocs WHERE order_id=p AND cancelled_at IS NULL),0) $$;
CREATE FUNCTION public.lwb_order_tally_due(p uuid) RETURNS numeric LANGUAGE sql AS $$ SELECT due FROM public.bill_rows WHERE order_id=p $$;
CREATE FUNCTION public.lwb_tally_bill_rows(p_days int)
RETURNS TABLE (order_id uuid, order_no text, party text, status text, order_date date, dispatch_date date,
               invoice_no text, invoice_date date, bill_amount numeric, erp_amount numeric,
               approved_return numeric, pending_return numeric, credit_notes numeric, debit_notes numeric,
               collected numeric, verified numeric, due numeric, credit_pending numeric, delivery text, notes jsonb)
LANGUAGE sql AS $$
  SELECT o.id,o.order_no,o.customer_name,o.status,current_date,current_date,t.invoice_no,t.invoice_date,t.amount,t.amount,
         0::numeric,0::numeric,0::numeric,0::numeric,b.collected,b.collected,b.due,0::numeric,'',  '[]'::jsonb
  FROM public.orders o LEFT JOIN public.lwb_tally_invoices t ON t.order_id=o.id LEFT JOIN public.bill_rows b ON b.order_id=o.id $$;
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role.toUpperCase()]);
await db.exec(await readFile(new URL('../../lwb_sales_head_outstanding_setup.sql',import.meta.url),'utf8'));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]])}
async function q(sql,args){await db.exec('SET ROLE authenticated');try{return (await db.query(sql,args)).rows}finally{await db.exec('RESET ROLE')}}
const o=async(no,party,sp)=>(await db.query("insert into orders(order_no,customer_name,sales_person,status) values($1,$2,$3,'delivered') returning id",[no,party,sp])).rows[0].id;

const a=await o('LXY-1','RAM TRADERS','Nadim');
const b=await o('LXY-2','RAM TRADERS','Nadim');
const c=await o('LXY-3','SHYAM STORES','Harsh');
const d=await o('LXY-4','SHYAM STORES','Harsh'); // not billed
await db.query(`insert into lwb_tally_invoices(order_id,invoice_no,invoice_date,amount) values($1,'T-1',current_date-40,10000),($2,'T-2',current_date-5,8000),($3,'T-3',current_date-2,5000)`,[a,b,c]);
await db.query(`insert into bill_rows values($1,4000,6000),($2,8000,0),($3,0,5000)`,[a,b,c]);
// a: driver cash 1000 (with driver) + online 2000 UPI verified; office cheque 1500 deposited; party receipt 1500 cash+upi split
await db.query(`insert into lwb_delivery_reports(order_id,cash_reported,payment_status,cash_amount,online_amount,online_mode,driver_user_id) values
  ($1,3000,'VERIFIED',1000,2000,'UPI',$2),($1,900,'REJECTED',900,null,null,$2),($3,5000,null,null,null,null,$2)`,[a,ids.sales,c]);
await db.query(`update lwb_delivery_reports set payment_mode='CHEQUE' where order_id=$1`,[c]);
const pay=(await db.query(`insert into lwb_tally_payments(receipt_id,order_id,party,pay_date,mode,amount,ref_no,created_by) values
  (gen_random_uuid(),$1,'RAM TRADERS',current_date-3,'CHEQUE',1500,'004512',$2) returning id`,[a,ids.accounts])).rows[0].id;
await db.query(`insert into lwb_acc_cheques values('PAYMENT',$1,current_date-1)`,[pay]);
await db.query(`insert into lwb_tally_payments(receipt_id,order_id,party,pay_date,mode,amount,ref_no,created_by) values
  ('00000000-0000-4000-8000-0000000000aa',null,'RAM TRADERS',current_date-2,'CASH',1000,null,$1),
  ('00000000-0000-4000-8000-0000000000aa',null,'RAM TRADERS',current_date-2,'UPI',2500,'UTR9',$1)`,[ids.accounts]);
await db.query(`insert into lwb_party_allocs(receipt_id,order_id,amount) values('00000000-0000-4000-8000-0000000000aa',$1,1500)`,[a]);

test('Sales Head gets outstanding bills with salesman; Salesman / Godown Manager are refused', async()=>{
  await as('manager');
  const r=(await q('select lwb_sales_outstanding(400) as j'))[0].j;
  const by=Object.fromEntries(r.orders.map(x=>[x.order_no,x]));
  assert.deepEqual(Object.keys(by).sort(),['LXY-1','LXY-2','LXY-3']);
  assert.equal(by['LXY-1'].sales_person,'Nadim');
  assert.equal(Number(by['LXY-1'].due),4000);
  assert.equal(Number(by['LXY-1'].office),3000);
  assert.equal(Number(by['LXY-1'].driver),3000);
  assert.deepEqual(r.advance,{'RAM TRADERS':2000});
  for(const role of ['sales','warehouse','cashier']){
    await as(role);
    await assert.rejects(q('select lwb_sales_outstanding(400)'),/Sales Head only/);
    await assert.rejects(q('select * from lwb_order_payments($1::uuid[])',[[a]]),/Sales Head only/);
  }
});

test('Payments per PO: driver cash / online, office cheque status, party split with both modes', async()=>{
  await as('manager');
  const rows=await q('select * from lwb_order_payments($1::uuid[])',[[a,b,c,d]]);
  const A=rows.filter(r=>r.order_id===a).map(r=>[r.src,r.mode,Number(r.amount),r.status]).sort();
  assert.deepEqual(A,[
    ['DRIVER','CASH',1000,'RECEIVED'],['DRIVER','UPI',2000,'RECEIVED'],
    ['OFFICE','CHEQUE',1500,'CHEQUE_DEPOSITED'],['PARTY','CASH+UPI',1500,'RECEIVED']]);
  const C=rows.filter(r=>r.order_id===c).map(r=>[r.src,r.mode,Number(r.amount),r.status]);
  assert.deepEqual(C,[['DRIVER','CHEQUE',5000,'WITH_DRIVER']]);
  assert.equal(rows.filter(r=>r.order_id===b||r.order_id===d).length,0);
  await db.query(`insert into lwb_acc_verify values('PAYMENT',$1,'VERIFIED')`,[pay]);
  const again=await q('select * from lwb_order_payments($1::uuid[])',[[a]]);
  assert.equal(again.find(r=>r.src==='OFFICE').status,'CHEQUE_CLEARED');
  await as('accounts');
  assert.ok((await q('select * from lwb_order_payments($1::uuid[])',[[a]])).length===4);
});

test('Tell Accounts: notifies Accounts, Cashier and Admin once per 30 minutes; shows on the bill', async()=>{
  await as('manager');
  const n=(await q('select lwb_payment_followup($1,null,$2) as n',[b,'party says Monday']))[0].n;
  assert.equal(n,3);
  const notes=(await db.query("select user_id,title,message from erp_notifications where notification_type='PAYMENT_FOLLOWUP' order by user_id")).rows;
  assert.deepEqual(notes.map(x=>x.user_id),[ids.admin,ids.accounts,ids.cashier]);
  assert.match(notes[0].title,/RAM TRADERS/);
  assert.match(notes[0].message,/LXY-2 · Bill T-2 · Due ₹8,000 · party says Monday · by MANAGER/);
  await assert.rejects(q('select lwb_payment_followup($1,null,null)',[b]),/already told/);
  assert.equal((await q('select lwb_payment_followup(null,$1,null) as n',['SHYAM STORES']))[0].n,3);
  await assert.rejects(q('select lwb_payment_followup(null,$1,null)',['SHYAM STORES']),/already told/);
  const r=(await q('select lwb_sales_outstanding(400) as j'))[0].j;
  assert.equal(r.orders.find(x=>x.order_no==='LXY-2').told.by,'MANAGER');
  assert.equal(r.told['SHYAM STORES'].by,'MANAGER');
  for(const role of ['accounts','sales']){
    await as(role);
    await assert.rejects(q('select lwb_payment_followup($1,null,null)',[c]),/Only Sales Head or Admin/);
  }
});
