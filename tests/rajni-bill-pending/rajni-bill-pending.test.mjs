import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_quick_slip_setup.sql + lwb_rajni_bill_pending_setup.sql on an empty PGlite database (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  accounts:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004',other:'00000000-0000-4000-8000-000000000005'};
const roles={admin:'admin',head:'manager',accounts:'accounts',sales:'salesman',other:'salesman'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid primary key);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.lwb_companies(id uuid default gen_random_uuid() primary key,name text,pack_unit text);
CREATE TABLE public.sku_master(sku_name text,company_id uuid);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz default now(),
  customer_name text,sales_person text,status text,total_qty numeric,total_amount numeric,created_by uuid,approved_by uuid,approved_at timestamptz);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric default 0,rate numeric);
CREATE TABLE public.dispatch_assignments(order_id uuid);
CREATE TABLE public.lwb_customer_master(customer_name text,mobile text,billing_address text,city text,pincode text,is_active boolean);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false);
CREATE FUNCTION public.lwb_company_ok(p uuid) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT true $$;
CREATE TABLE public.lwb_acc_banks(id bigserial primary key,name text,account_no text,active boolean default true);
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key,invoice_no text,invoice_date date,amount numeric);
CREATE TABLE public.lwb_tally_payments(id uuid primary key default gen_random_uuid(),receipt_id uuid not null,order_id uuid,party text,pay_date date,
  mode text,amount numeric,ref_no text,cash_notes jsonb,remark text,created_by uuid,created_at timestamptz default now(),cancelled_at timestamptz,company_id uuid);
CREATE TABLE public.lwb_acc_entries(id uuid,entry_date date,created_at timestamptz,kind text,mode text,amount numeric,category_id bigint,party text,ref_no text,remark text,bank_id bigint,created_by uuid,cancelled_at timestamptz);
CREATE TABLE public.lwb_acc_categories(id bigint,name text);
CREATE TABLE public.lwb_delivery_reports(id uuid,order_id uuid,driver_user_id uuid,payment_status text,payment_reviewed_at timestamptz,payment_reviewed_by uuid,
  cash_reported numeric,cash_amount numeric,online_amount numeric,online_mode text,payment_mode text,bank_ref text,online_reference text,payment_reference text);
CREATE TABLE public.lwb_payment_collections(id uuid,invoice_id uuid,status text,payment_mode text,amount numeric,reference_no text,remarks text,submitted_by uuid,submitted_at timestamptz,reviewed_at timestamptz);
CREATE TABLE public.tax_invoices(id uuid,order_id uuid);
CREATE FUNCTION public.lwb_acc_book_day(t timestamptz) RETURNS date LANGUAGE sql AS $$ SELECT (t AT TIME ZONE 'Asia/Kolkata')::date $$;
CREATE FUNCTION public.lwb_party_parent(p text) RETURNS text LANGUAGE sql AS $$ SELECT upper(btrim(coalesce(p,''))) $$;
CREATE FUNCTION public.lwb_party_key(p text) RETURNS text LANGUAGE sql AS $$ SELECT lower(btrim(coalesce(p,''))) $$;
CREATE FUNCTION public.lwb_party_known(p text) RETURNS boolean LANGUAGE sql AS $$ SELECT EXISTS (SELECT 1 FROM public.lwb_customer_master m WHERE upper(btrim(m.customer_name))=upper(btrim(p))) $$;
CREATE FUNCTION public.lwb_tally_staff() RETURNS boolean LANGUAGE sql AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles WHERE id=auth.uid() AND role IN ('admin','accounts')) $$;
CREATE FUNCTION public.lwb_party_brand_check(p text,c uuid) RETURNS uuid LANGUAGE sql AS $$ SELECT c $$;
CREATE TABLE public.apply_calls(parent text,company uuid);
CREATE FUNCTION public.lwb_party_apply_b(p text,c uuid,a jsonb) RETURNS numeric LANGUAGE plpgsql AS $$ BEGIN INSERT INTO public.apply_calls VALUES (p,c); RETURN 0; END $$;
CREATE FUNCTION public.lwb_party_receipt_free_b(p text,c uuid) RETURNS TABLE(free numeric) LANGUAGE sql AS $$
  SELECT coalesce(sum(amount),0) FROM public.lwb_tally_payments WHERE party=p AND company_id IS NOT DISTINCT FROM c AND cancelled_at IS NULL $$;
CREATE FUNCTION public.lwb_acc_start_date() RETURNS date LANGUAGE sql AS $$ SELECT date '2000-01-01' $$;
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids)){await db.query('insert into auth.users values($1)',[id]);await db.query('insert into user_profiles(id,role,active) values($1,$2,true)',[id,roles[k]])}
await db.exec(await readFile(new URL('../../lwb_quick_slip_setup.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../../lwb_rajni_bill_pending_setup.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../../lwb_rajni_bill_pending_setup.sql',import.meta.url),'utf8')); // safe to run again
await db.exec(`CREATE FUNCTION public.lwb_acc_lines() RETURNS SETOF record LANGUAGE sql AS $$ SELECT 1 $$`).catch(()=>{});
const rg=(await db.query(`insert into lwb_companies(name,pack_unit,quick_slip) values('RAJNIGANDHA','BOX',true) returning id`)).rows[0].id;
await db.query(`insert into sku_master values('RG PAN MASALA 10',$1)`,[rg]);
await db.query(`insert into lwb_customer_master values('SHREE KRISHNA','9898012345','x','Ahmedabad','1',true)`);
const [hdfc,sbi]=(await db.query(`insert into lwb_acc_banks(name,account_no,active) values('HDFC','5010 0012 4521',true),('SBI','0098',true),('OLD BANK','1',false) returning id`)).rows.map(r=>r.id);

async function as(who,sql,params=[]){
  await db.exec('BEGIN');
  try{await db.query(`select set_config('request.jwt.claim.sub',$1,true)`,[ids[who]]);const r=await db.query(sql,params);await db.exec('COMMIT');return r.rows}
  catch(e){await db.exec('ROLLBACK');throw e}
}
async function slipPo(no,by='head'){
  const id=(await db.query(`insert into orders(order_no,customer_name,status,created_by) values($1,' Shree Krishna ','approved',$2) returning id`,[no,ids[by]])).rows[0].id;
  await db.query(`insert into order_items(order_id,sku_name,ordered_qty,approved_qty,rate) values($1,'RG PAN MASALA 10',10,10,2450)`,[id]);
  await as('head',`select lwb_quick_slip_dispatch($1,'{"driver_name":"Ramesh","vehicle_no":"GJ01AB1234"}')`,[id]);
  return id;
}
const o1=await slipPo('LXY-1',"sales"),o2=await slipPo('LXY-2');
const one=async(sql,p,who='accounts')=>(await as(who,sql,p))[0];

test('bank list: active banks only, last 4 digits, not for salesman',async()=>{
  const b=(await one('select lwb_money_banks() b',[])).b;
  assert.deepEqual(b.map(x=>[x.name,x.last4]),[['HDFC','4521'],['SBI','0098']]);
  await assert.rejects(as('sales','select lwb_money_banks()'),/Only Admin, Sales Head or Accounts/);
});

test('pending list: slips without a Tally bill, with amount and days',async()=>{
  const p=(await one('select lwb_slip_bill_pending() p',[])).p;
  assert.deepEqual(p.map(x=>x.order_no),['LXY-1','LXY-2']);
  assert.equal(Number(p[0].amount),24500);assert.equal(p[0].days,0);assert.equal(p[0].delivered_at,null);assert.equal(p[0].created_by,undefined);
  await assert.rejects(as('sales','select lwb_slip_bill_pending()'),/Only Admin/);
});

test('delivered: salesman only his own order, undo only by office',async()=>{
  await assert.rejects(as('other','select lwb_quick_slip_delivered($1)',[o1]),/salesman of the order/);
  const r=(await one('select lwb_quick_slip_delivered($1) r',[o1],'sales')).r;assert.ok(r.delivered_at);
  await assert.rejects(as('sales','select lwb_quick_slip_delivered($1,false)',[o1]),/Sales Head to undo/);
  const u=(await one('select lwb_quick_slip_delivered($1,false) r',[o1],'head')).r;assert.equal(u.delivered_at,null);
  await one('select lwb_quick_slip_delivered($1) r',[o1],'head');
});

test('mark paid: bank needed for UPI, stays advance until the bill, then set against bills',async()=>{
  await assert.rejects(as('sales','select lwb_quick_slip_paid($1,$2)',[o1,{amount:100,mode:'CASH'}]),/Only Admin, Sales Head or Accounts/);
  await assert.rejects(as('head','select lwb_quick_slip_paid($1,$2)',[o1,{amount:24500,mode:'UPI'}]),/Choose the bank/);
  await assert.rejects(as('head','select lwb_quick_slip_paid($1,$2)',[o1,{amount:24500,mode:'UPI',bank_id:999}]),/Choose the bank/);
  await assert.rejects(as('head','select lwb_quick_slip_paid($1,$2)',[o1,{amount:250000,mode:'CASH'}]),/269ST/);
  await assert.rejects(as('head','select lwb_quick_slip_paid($1,$2)',[o1,{amount:0,mode:'CASH'}]),/Enter the amount/);
  const r=(await one('select lwb_quick_slip_paid($1,$2) r',[o1,{amount:24500,mode:'UPI',bank_id:hdfc,ref:'UTR77'}],'head')).r;
  assert.equal(r.billed,false);assert.equal(Number(r.paid),24500);
  const row=(await db.query(`select party,company_id,bank_id,slip_order_id,order_id,remark from lwb_tally_payments where ref_no='UTR77'`)).rows[0];
  assert.deepEqual([row.party,row.company_id,Number(row.bank_id),row.slip_order_id,row.order_id,row.remark],['SHREE KRISHNA',rg,Number(hdfc),o1,null,'Slip LXY-1']);
  assert.equal((await db.query('select count(*)::int n from apply_calls')).rows[0].n,0);
  await assert.rejects(as('head','select lwb_quick_slip_paid($1,$2)',[o1,{amount:1,mode:'UPI',bank_id:hdfc,ref:'utr77'}]),/already entered/);
  await db.query(`insert into lwb_tally_invoices values($1,'RG/9',current_date,24500)`,[o2]);
  const r2=(await one('select lwb_quick_slip_paid($1,$2) r',[o2,{amount:500,mode:'CASH'}])).r;
  assert.equal(r2.billed,true);assert.equal((await db.query('select count(*)::int n from apply_calls')).rows[0].n,1);
  const p=(await one('select lwb_slip_bill_pending() p',[])).p;
  assert.deepEqual(p.map(x=>x.order_no),['LXY-1']);assert.equal(Number(p[0].paid),24500);assert.equal(p[0].pay_modes,'UPI');assert.ok(p[0].delivered_at);
});

test('slip list: delivered / paid / bill and pending, salesman sees only his own',async()=>{
  const l=(await one('select lwb_quick_slip_list(null,null) l',[],'head')).l;
  const s1=l.slips.find(s=>s.order_no==='LXY-1'),s2=l.slips.find(s=>s.order_no==='LXY-2');
  assert.ok(s1.delivered_at);assert.equal(Number(s1.paid),24500);assert.equal(s1.bill_no,null);assert.equal(s2.bill_no,'RG/9');
  assert.deepEqual(l.pending.map(x=>x.order_no),['LXY-1']);assert.equal(l.can_mark,true);
  const ls=(await one('select lwb_quick_slip_list(null,null) l',[],'other')).l;
  assert.deepEqual(ls.pending,[]);assert.equal(ls.can_mark,false);
});

test('party payment keeps the bank of a UPI line; inactive bank refused',async()=>{
  const r=(await one(`select lwb_party_receive('Shree Krishna',current_date,$1,null,null,$2) r`,[[{mode:'UPI',amount:100,ref:'U1',bank_id:sbi},{mode:'CASH',amount:50,bank_id:sbi}],rg])).r;
  const rows=(await db.query(`select mode,bank_id from lwb_tally_payments where receipt_id=$1 order by mode`,[r.receipt_id])).rows;
  assert.deepEqual(rows.map(x=>[x.mode,x.bank_id==null?null:Number(x.bank_id)]),[['CASH',null],['UPI',Number(sbi)]]);
  await assert.rejects(as('accounts',`select lwb_party_receive('Shree Krishna',current_date,$1,null,null,$2)`,[[{mode:'UPI',amount:1,bank_id:3}],rg]),/Bank not found/);
  const lines=(await db.query(`select bank_id from lwb_acc_lines_all() where src='PAYMENT' and ref='U1'`)).rows;
  assert.equal(Number(lines[0].bank_id),Number(sbi));
});

test('daily popup to Accounts and Admin, one unread at a time',async()=>{
  const n=(await db.query('select lwb_slip_bill_remind_internal() n')).rows[0].n;assert.equal(n,2);
  await db.query('select lwb_slip_bill_remind_internal()');
  const r=(await db.query(`select title,message from erp_notifications where notification_type='SLIP_BILL_PENDING' and not is_read`)).rows;
  assert.equal(r.length,2);assert.match(r[0].title,/Rajnigandha bills pending: 1 · Rs 24500/);assert.match(r[0].message,/LXY-1 Shree Krishna Rs 24500 \(0 days\)/);
  assert.doesNotMatch(r[0].message+r[0].title,/[ऀ-ॿ]/);
});
