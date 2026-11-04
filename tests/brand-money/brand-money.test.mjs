import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_brand_money_setup.sql (after the party payment SQL) on a tiny copy of the tables it reads (no live database).
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

const P='AKASH TRADERS',Q='RAJ PAN CENTER';
async function po(no,party,amt,sku,billed=true,day=today){
 const id=(await db.query('insert into orders(order_no,customer_name,order_date) values($1,$2,$3) returning id',[no,party,day])).rows[0].id;
 await db.query('insert into order_items values($1,1,$2,$3)',[id,amt,sku]);
 if(billed)await db.query('insert into lwb_tally_invoices(order_id,invoice_no,invoice_date,amount,entered_by) values($1,$2,$3,$4,$5)',[id,'T-'+no,day,amt,ids.accounts]);
 return id;
}
let r1,r2,c1;

test('old money and opening get the brand of a one-brand party; two-brand party stays without brand',async()=>{
 await db.query("insert into lwb_customer_master values($1),($2)",[P,Q]);
 r1=await po('R-1',P,40000,'RAJNI 4G',true,dayAdd(today,-9));
 c1=await po('C-1',P,30000,'COKE 600',true,dayAdd(today,-8));
 await po('R-2',Q,20000,'RAJNI 4G',false);
 // money from before this change: no brand column yet
 await db.query("insert into lwb_tally_payments(receipt_id,order_id,party,pay_date,mode,amount,created_by) values (gen_random_uuid(),null,$1,$3,'CASH',5000,$4),(gen_random_uuid(),null,$2,$3,'UPI',7000,$4)",[P,Q,today,ids.accounts]);
 await db.query("insert into lwb_party_opening_balances(customer_name,as_of_date,amount,updated_by) values ($1,$3,11000,$4),($2,$3,22000,$4)",[P,Q,today,ids.admin]);
 await db.exec(await sql('lwb_brand_money_setup.sql'));
 const pay=(await db.query('select party,company_id from lwb_tally_payments order by party')).rows;
 assert.deepEqual(pay.map(p=>[p.party,p.company_id]),[[P,null],[Q,R]]);
 const ob=(await db.query('select customer_name,company_id from lwb_party_opening_balances order by 1')).rows;
 assert.deepEqual(ob.map(p=>[p.customer_name,p.company_id]),[[P,null],[Q,R]]);
 // run again: safe
 await db.exec(await sql('lwb_brand_money_setup.sql'));
});

test('payment of one brand goes only to that brand; advance stays per brand',async()=>{
 await as('accounts');
 // two-brand party: brand needed for a split; none = kept without brand, not split
 const n=await receive(P,[{mode:'UPI',amount:1000,ref:'U0'}],null);
 assert.equal(n.company_id,null);assert.equal(Number(n.split),0);
 const r=await receive(P,[{mode:'BANK',amount:50000,ref:'U1'}],C);
 assert.equal(Number(r.split),30000);assert.equal(Number(r.advance),20000);
 const d=await data();
 assert.equal(Number(d.orders.find(o=>o.order_id===r1).due),40000); // Rajnigandha bill untouched
 assert.equal(Number(d.orders.find(o=>o.order_id===c1).due),0);
 assert.equal(d.orders.find(o=>o.order_id===r1).company_id,R);
 const adv=d.advance_b.filter(a=>a.parent===P).map(a=>[a.company_id,Number(a.amount)]).sort((a,b)=>String(a[0]).localeCompare(String(b[0])));
 assert.deepEqual(adv,[[C,20000],[null,6000]].sort((a,b)=>String(a[0]).localeCompare(String(b[0]))));
 assert.equal(d.companies.length,2);
 // by hand: Coca-Cola money can not go to the Rajnigandha bill
 await assert.rejects(call('select public.lwb_party_adjust($1,$2::jsonb,$3)',[P,JSON.stringify([{order_id:r1,amount:100}]),C]),/another brand/);
 await assert.rejects(call('select public.lwb_party_adjust($1,null,null)',[P]),/Choose the brand/);
 await assert.rejects(call('select public.lwb_party_adjust($1,null,$2)',[P,C]),/Nothing to adjust/);
 // one-brand party: brand found by itself
 const q=await receive(Q,[{mode:'CASH',amount:3000}],null);
 assert.equal(q.company_id,R);
});

test('new bill takes only the advance of its brand',async()=>{
 await as('accounts');
 const c2=await po('C-2',P,15000,'COKE 600');
 const r3=await po('R-3',P,9000,'RAJNI 4G');
 const d=await data();
 assert.equal(Number(d.orders.find(o=>o.order_id===c2).due),0);    // from the 20,000 Coca-Cola advance
 assert.equal(Number(d.orders.find(o=>o.order_id===r3).due),9000); // no Rajnigandha advance
 const adv=d.advance_b.find(a=>a.parent===P&&a.company_id===C);
 assert.equal(Number(adv.amount),5000);
});

test('choose the brand of old money: it then pays that brand oldest first',async()=>{
 await as('accounts');
 const d=await data();
 const old=d.receipts.filter(x=>x.party===P&&x.company_id===null);
 assert.equal(old.length,2);
 const res=(await call('select public.lwb_party_receipt_brand($1,$2) j',[old[0].receipt_id,R]))[0].j;
 assert.ok(Number(res.split)>0);
 const d2=await data();
 assert.ok(Number(d2.orders.find(o=>o.order_id===r1).due)<40000);
 // a receipt split to a Coca-Cola bill can not become Rajnigandha
 const coke=d2.receipts.find(x=>x.company_id===C&&x.allocs.length);
 await assert.rejects(call('select public.lwb_party_receipt_brand($1,$2)',[coke.receipt_id,R]),/other brand/);
});

test('opening balance per brand; ledger rows carry the brand',async()=>{
 await as('accounts');
 await assert.rejects(call('select public.lwb_set_party_opening_balance($1,1,$2,null,$3)',[P,today,R]),/Admin/);
 await as('admin');
 await assert.rejects(call('select public.lwb_set_party_opening_balance($1,100,$2,null,null)',[P,today]),/Choose the brand/);
 await call('select public.lwb_set_party_opening_balance($1,30000,$2,null,$3)',[P,today,R]);
 await call('select public.lwb_set_party_opening_balance($1,45000,$2,null,$3)',[P,today,C]);
 await call('select public.lwb_set_party_opening_balance($1,46000,$2,null,$3)',[P,today,C]); // update, not a 2nd row
 await call('select public.lwb_set_party_opening_balance($1,0,$2,null,null)',[P,today]);    // old row without brand removed
 const ob=(await db.query('select company_id,amount from lwb_party_opening_balances where customer_name=$1 order by amount',[P])).rows;
 assert.deepEqual(ob.map(x=>[x.company_id,Number(x.amount)]),[[R,30000],[C,46000]]);
 // Q is one-brand: no brand needed
 await call('select public.lwb_set_party_opening_balance($1,25000,$2,null,null)',[Q,today]);
 await as('accounts');
 const op=await call('select * from public.lwb_party_openings() where parent=$1',[Q]);
 assert.equal(op.length,1);assert.equal(op[0].company_id,R);assert.equal(Number(op[0].amount),25000);
 const led=await call('select * from public.lwb_party_ledger_b() where customer_name=$1',[P]);
 const of=k=>led.filter(l=>l.entry_kind===k);
 assert.deepEqual(of('OPENING').map(l=>l.company_id).sort(),[R,C].sort());
 assert.ok(of('TALLY_BILL').every(l=>l.company_id===(l.order_no.startsWith('R')?R:C)));
 assert.ok(of('PARTY_PAYMENT').some(l=>l.company_id===C));
 const bal=b=>led.filter(l=>l.company_id===b).reduce((a,l)=>a+Number(l.debit)-Number(l.credit),0);
 assert.equal(bal(C),30000+15000+46000-50000);
});

test('brand-wise Daily Summary, its lists and the call list (lwb_brand_reports_setup.sql)',async()=>{
 await db.exec(`ALTER TABLE orders ADD COLUMN IF NOT EXISTS total_amount numeric, ADD COLUMN IF NOT EXISTS total_qty numeric, ADD COLUMN IF NOT EXISTS total_weight numeric, ADD COLUMN IF NOT EXISTS sales_person text;
  ALTER TABLE lwb_delivery_reports ADD COLUMN IF NOT EXISTS assignment_id uuid;
  ALTER TABLE user_profiles ADD COLUMN IF NOT EXISTS mobile text;
  ALTER TABLE dispatch_assignments ADD COLUMN IF NOT EXISTS id uuid, ADD COLUMN IF NOT EXISTS driver_name text, ADD COLUMN IF NOT EXISTS driver_mobile text, ADD COLUMN IF NOT EXISTS vehicle_no text;
  ALTER TABLE lwb_customer_master ADD COLUMN IF NOT EXISTS id uuid default gen_random_uuid(), ADD COLUMN IF NOT EXISTS city text, ADD COLUMN IF NOT EXISTS mobile text, ADD COLUMN IF NOT EXISTS is_active boolean default true, ADD COLUMN IF NOT EXISTS order_every_days int;
  CREATE TABLE IF NOT EXISTS lwb_party_salesman(customer_id uuid, salesman_id uuid);
  CREATE TABLE IF NOT EXISTS lwb_party_calls(id bigserial, customer_id uuid, call_date date, next_date date, result text, reason text, note text, called_by_name text, created_at timestamptz default now());
  CREATE OR REPLACE FUNCTION public.lwb_sales_head() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT true $$;
  CREATE OR REPLACE FUNCTION public.lwb_is_sales_user() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT true $$;
  UPDATE orders o SET total_amount=(SELECT sum(loaded_qty*rate) FROM order_items i WHERE i.order_id=o.id), total_qty=1;
  UPDATE lwb_customer_master SET order_every_days=1;`);
 await db.exec(await sql('lwb_brand_reports_setup.sql'));
 await db.exec(await sql('lwb_brand_reports_setup.sql')); // safe to run again
 await as('accounts');
 const sum=async co=>(await call('select public.lwb_daily_summary_b($1,$2) j',[today,co]))[0].j;
 const all=await sum(null),rj=await sum(R),ck=await sum(C);
 // today's POs: R-2 (Q, Rajnigandha 20,000), C-2 (Coca-Cola 15,000), R-3 (Rajnigandha 9,000)
 assert.equal(all.orders.count,3);assert.equal(Number(all.orders.amount),44000);
 assert.equal(rj.orders.count,2);assert.equal(Number(rj.orders.amount),29000);
 assert.equal(ck.orders.count,1);assert.equal(Number(ck.orders.amount),15000);
 // outstanding of a brand = that brand's ledger only
 const bal=async b=>Number((await call("select coalesce(sum(x.v) filter (where x.v>0.5),0) s from (select customer_name, sum(debit-credit) v from public.lwb_party_ledger_b() where company_id=$1 group by 1) x",[b]))[0].s);
 assert.ok(Number(ck.outstanding.total)>0);
 assert.equal(Number(ck.outstanding.total),await bal(C));
 assert.equal(Number(rj.outstanding.total),await bal(R));
 assert.ok(Number(all.outstanding.total)>=Number(ck.outstanding.total));
 const lo=async co=>(await call("select public.lwb_daily_summary_list_b($1,'orders',$2) j",[today,co]))[0].j;
 assert.deepEqual((await lo(C)).map(x=>x.order_no),['C-2']);
 assert.equal((await lo(null)).length,3);
 // call list: Q never bought Coca-Cola, so it is not on the Coca-Cola list
 await as('manager');
 const cl=async co=>(await call('select customer_name from public.lwb_party_call_list_b(true,$1) order by 1',[co])).map(x=>x.customer_name);
 assert.deepEqual(await cl(null),[P,Q]);
 assert.deepEqual(await cl(C),[P]);
 assert.deepEqual(await cl(R),[P,Q]);
});
