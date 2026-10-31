import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_po_summary_lists_setup.sql on a tiny copy of the tables it reads (no live database).
// Every summary card's list must hold exactly the orders its number counts.
const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000002',accounts:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz,created_at timestamptz default now(),customer_name text,sales_person text,
  status text,total_qty numeric,total_amount numeric,total_weight numeric,priority text default 'NORMAL');
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,driver_name text,vehicle_no text,driver_mobile text);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,assignment_id uuid,driver_user_id uuid,delivery_status text,reported_at timestamptz default now(),
  cash_reported numeric default 0,payment_mode text,cash_amount numeric,online_amount numeric,online_mode text,online_reference text,payment_reference text,bank_ref text,payment_status text,payment_reviewed_at timestamptz);
CREATE TABLE public.lwb_internal_bills(id uuid default gen_random_uuid() primary key,order_id uuid,internal_bill_no text,customer_name text);
CREATE TABLE public.tax_invoices(id uuid default gen_random_uuid() primary key,order_id uuid,invoice_no text);
CREATE TABLE public.lwb_payment_collections(id uuid default gen_random_uuid() primary key,invoice_id uuid,internal_bill_id uuid,collection_date date,amount numeric,payment_mode text,reference_no text,status text);
CREATE TABLE public.ledger(entry_date date,customer_name text,debit numeric,credit numeric);
CREATE FUNCTION public.lwb_party_ledger() RETURNS SETOF public.ledger LANGUAGE sql AS $$ SELECT * FROM public.ledger $$;
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role+' user']);
// the live summary function (latest version) to compare the counts with
const sla=await readFile(new URL('../../lwb_order_priority_sla_setup.sql',import.meta.url),'utf8');
const fn=sla.slice(sla.indexOf('CREATE OR REPLACE FUNCTION public.lwb_po_approval_summary'));
await db.exec(fn.slice(0,fn.indexOf('$fn$;')+5));
await db.exec(await readFile(new URL('../../lwb_po_summary_lists_setup.sql',import.meta.url),'utf8'));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated; GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated');

const today=(await db.query("select timezone('Asia/Kolkata', now())::date::text d")).rows[0].d;
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(sql,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(sql,args)).rows}finally{await db.exec('RESET ROLE')}}
let n=0;
async function order(status,hoursAgo,extra={}){
  const r=await db.query(`insert into orders(order_no,order_date,created_at,customer_name,status,total_qty,total_amount,total_weight,priority)
    values($1,now()-make_interval(hours=>$2),now()-make_interval(hours=>$2),$3,$4,10,1000,100,$5) returning id`,['LXY-'+(++n),hoursAgo,'Party '+n,status,extra.priority||'NORMAL']);
  const id=r.rows[0].id;
  if(extra.assign)await db.query('insert into dispatch_assignments(order_id,driver_name,vehicle_no) values($1,$2,$3)',[id,'Ramesh','GJ05AB1234']);
  if(extra.delivered)await db.query("insert into lwb_delivery_reports(order_id,delivery_status) values($1,$2)",[id,extra.delivered]);
  return id;
}

test('only Admin and Sales Head open the PO summary lists',async()=>{
  for(const r of ['accounts','sales','none']){await as(r);await assert.rejects(call("select * from lwb_po_summary_orders('pending',null,null)"),/Admin and Sales Head only/)}
  await as('admin');await assert.rejects(call("select * from lwb_po_summary_orders('xyz',null,null)"),/Unknown summary card/);
  assert.equal((await db.query("select has_function_privilege('anon','public.lwb_po_summary_orders(text,date,date)','EXECUTE') a")).rows[0].a,false);
});

test('every card list has exactly as many orders as its number',async()=>{
  await order('pending_approval',1);
  await order('pending_approval',20,{priority:'URGENT'});          // late approval + urgent
  await order('approved',2);
  await order('approved',50,{priority:'HIGH'});                    // late delivery + high
  await order('transport_allocated',3,{assign:true});
  await order('loading',4,{assign:true});
  await order('loaded',40,{assign:true});                          // late delivery
  await order('loaded',5,{assign:true,delivered:'DELIVERED'});     // delivered today
  await order('cancelled',60);
  await order('pending_approval',80);                              // old: late approval, outside "today"
  await as('manager');
  for(const [from,to] of [[today,today],[null,null],['2020-01-01',today]]){
    const sum=(await call('select lwb_po_approval_summary($1,$2) j',[from,to]))[0].j;
    for(const b of ['total','approved','allocated','loading','delivered','pending','late_approval','late_delivery','urgent']){
      const rows=await call('select order_no,status from lwb_po_summary_orders($1,$2,$3)',[b,from,to]);
      assert.equal(rows.length,Number(sum[b].count),b+' '+from+'..'+to);
      assert.ok(rows.every(r=>!/cancel/.test(r.status)),'no cancelled order in '+b);
    }
  }
  const pend=await call("select order_no from lwb_po_summary_orders('pending',null,null)");
  assert.equal(pend.length,8);
});

test('Daily Summary lists: orders, deliveries, payments, outstanding',async()=>{
  await as('sales');await assert.rejects(call("select lwb_daily_summary_list($1,'orders')",[today]),/Admin, Manager and Accounts only/);
  await as('accounts');
  await assert.rejects(call("select lwb_daily_summary_list($1,'abc')",[today]),/Unknown Daily Summary card/);
  const o=(await call("select lwb_daily_summary_list($1,'orders') j",[today]))[0].j;
  const want=(await db.query("select count(*)::int n from orders where timezone('Asia/Kolkata',order_date)::date=$1",[today])).rows[0].n;
  assert.ok(want>0);assert.equal(o.length,want);assert.ok(o.every(x=>x.order_no));
  const d=(await call("select lwb_daily_summary_list($1,'deliveries') j",[today]))[0].j;
  assert.deepEqual(d.map(x=>[x.delivery_status,x.driver,x.vehicle_no]),[['DELIVERED','Driver',null]]);
  const ord=(await db.query("insert into orders(order_no,order_date,customer_name,status) values('LXY-P',now(),'Shree Traders','loaded') returning id")).rows[0].id;
  const bill=(await db.query("insert into lwb_internal_bills(order_id,internal_bill_no,customer_name) values($1,'LWB-EB-1','Shree Traders') returning id",[ord])).rows[0].id;
  await db.query("insert into lwb_payment_collections(internal_bill_id,collection_date,amount,payment_mode,reference_no,status) values($1,$2,500,'UPI','UTR1','POSTED'),($1,$2,200,'CASH',null,'REJECTED')",[bill,today]);
  await db.query("insert into lwb_delivery_reports(order_id,delivery_status,cash_reported,payment_mode,cash_amount,online_amount,online_mode,bank_ref,payment_status,payment_reviewed_at) values($1,'DELIVERED',900,'CASH+UPI',600,300,'UPI','UTR9','VERIFIED',now())",[ord]);
  const p=(await call("select lwb_daily_summary_list($1,'payments') j",[today]))[0].j;
  assert.deepEqual(p.map(x=>[x.source,x.party,x.bill,x.mode,Number(x.amount)]).sort(),
    [['Driver','Shree Traders','LXY-P','CASH (driver)',600],['Driver','Shree Traders','LXY-P','UPI (driver)',300],['Payment Collection','Shree Traders','LWB-EB-1','UPI',500]]);
  await db.query("insert into ledger values($1,'A',1000,200),($1,'B',50,50),($1,'C',300,0)",[today]);
  const u=(await call("select lwb_daily_summary_list($1,'outstanding') j",[today]))[0].j;
  assert.deepEqual(u.map(x=>[x.party,Number(x.amount)]),[['A',800],['C',300]]);
});
