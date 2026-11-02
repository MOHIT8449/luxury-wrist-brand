import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_po_journey_setup.sql on a tiny copy of the tables it reads (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000002',sales:'00000000-0000-4000-8000-000000000003'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,status text);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,driver_name text,vehicle_no text,driver_mobile text,
  loading_person text,assigned_at timestamptz,loading_started_at timestamptz,loading_completed_at timestamptz);
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key,invoice_no text,invoice_date date,amount numeric,entered_at timestamptz default now(),updated_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,delivery_status text,reported_at timestamptz,
  cash_reported numeric,payment_status text);
CREATE TABLE public.lwb_tally_notes(id uuid default gen_random_uuid() primary key,order_id uuid,kind text,amount numeric,cancelled_at timestamptz);
CREATE TABLE public.lwb_office_paid(order_id uuid,amount numeric);
CREATE TABLE public.lwb_loaded(order_id uuid,gross numeric,approved_return numeric);
-- Stand-ins for the live helpers (lwb_driver_payment_setup.sql / lwb_party_group_billing_setup.sql).
CREATE FUNCTION public.lwb_order_bill_numbers(p uuid) RETURNS TABLE(gross numeric,approved_return numeric,pending_return numeric,net numeric)
  LANGUAGE sql AS $$ SELECT coalesce(sum(l.gross),0),coalesce(sum(l.approved_return),0),0::numeric,greatest(0,coalesce(sum(l.gross),0)-coalesce(sum(l.approved_return),0))
  FROM public.lwb_loaded l WHERE l.order_id=p $$;
CREATE FUNCTION public.lwb_order_office_paid(p uuid) RETURNS numeric LANGUAGE sql AS $$ SELECT coalesce(sum(amount),0) FROM public.lwb_office_paid WHERE order_id=p $$;
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true)',[id,role]);
await db.exec(await readFile(new URL('../../lwb_po_journey_setup.sql',import.meta.url),'utf8'));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]])}
async function call(list){await db.exec('SET ROLE authenticated');try{return (await db.query('select * from lwb_po_journey($1::uuid[])',[list])).rows}finally{await db.exec('RESET ROLE')}}
const o=async(no,status)=>(await db.query('insert into orders(order_no,status) values($1,$2) returning id',[no,status])).rows[0].id;

const a=await o('LXY-1','approved');
const b=await o('LXY-2','loading');
const c=await o('LXY-3','loaded');
await db.query(`insert into dispatch_assignments(order_id,driver_name,vehicle_no,loading_person,assigned_at,loading_started_at) values
  ($1,'Kalu','GJ01AB1','Bhavesh',now()-interval '5 hours',now()-interval '3 hours'),
  ($2,'Ramu','GJ01AB2','Bhavesh',now()-interval '9 hours',now()-interval '8 hours')`,[b,c]);
await db.query(`insert into lwb_tally_invoices(order_id,invoice_no,invoice_date,amount,entered_at) values($1,'T-55',current_date,50000,now()-interval '2 hours')`,[c]);
await db.query(`insert into lwb_delivery_reports(order_id,delivery_status,reported_at,cash_reported,payment_status) values
  ($1,'NOT_DELIVERED',now()-interval '90 minutes',0,null),($1,'DELIVERED',now()-interval '1 hour',5000,'PENDING'),($1,'PARTIAL',now()-interval '3 hours',700,'REJECTED')`,[c]);
await db.query(`insert into lwb_tally_notes(order_id,kind,amount,cancelled_at) values($1,'CREDIT',1000,null),($1,'DEBIT',200,null),($1,'CREDIT',999,now())`,[c]);
await db.query(`insert into lwb_office_paid values($1,10000)`,[c]);
await db.query(`insert into lwb_loaded values($1,30000,2000)`,[b]);

test('Sales Head gets transport, loading, bill no. and the latest delivery report per order', async()=>{
  await as('manager');
  const rows=await call([a,b,c,c]);
  assert.equal(rows.length,3);
  const by=Object.fromEntries(rows.map(r=>[r.order_id,r]));
  assert.equal(by[a].vehicle_no,null);assert.equal(by[a].bill_no,null);
  assert.equal(by[b].driver_name,'Kalu');assert.ok(by[b].loading_started_at);assert.equal(by[b].bill_no,null);
  assert.equal(by[c].bill_no,'T-55');assert.ok(by[c].bill_at);assert.equal(by[c].delivery_status,'DELIVERED');
});

test('Collection: bill amount, money received and due for each PO', async()=>{
  await as('manager');
  const by=Object.fromEntries((await call([a,b,c])).map(r=>[r.order_id,r]));
  // No bill, nothing loaded: no due yet.
  assert.equal(by[a].bill_amount,null);assert.equal(Number(by[a].collected),0);assert.equal(by[a].due,null);
  // Loaded, no Tally bill yet: due = loaded value − approved return.
  assert.equal(by[b].bill_amount,null);assert.equal(Number(by[b].due),28000);
  // 50,000 bill − 1,000 credit + 200 debit − 5,000 driver (rejected 700 left out) − 10,000 office = 34,200.
  assert.equal(Number(by[c].bill_amount),50000);assert.equal(Number(by[c].collected),15000);assert.equal(Number(by[c].due),34200);
});

test('Admin allowed, salesman refused, more than 500 refused', async()=>{
  await as('admin');assert.equal((await call([a])).length,1);
  await as('sales');await assert.rejects(call([a]),/Sales Head \/ Godown Manager \/ Accounts only/);
  await as('manager');await assert.rejects(call(Array.from({length:501},()=>a)),/500/);
});
