import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_group_billing_setup.sql on a tiny copy of the tables it reads (no live database).
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
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

const today=(await db.query("select (now() at time zone 'Asia/Kolkata')::date::text d")).rows[0].d;
const dayAdd=(d,n)=>{const x=new Date(d+'T12:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const data=async()=>(await call('select public.lwb_party_billing(400) j'))[0].j;
const receive=(party,lines,allocs=null,date=today)=>call('select public.lwb_party_receive($1,$2,$3::jsonb,$4::jsonb,null) j',[party,date,JSON.stringify(lines),allocs==null?null:JSON.stringify(allocs)]).then(r=>r[0].j);
const due=async id=>Number((await data()).orders.find(o=>o.order_id===id).due);

const P='SHREE JAGDISH TRADERS (BARDOLI)';
let o1,o2,o3,o4;
async function po(no,party,amt,bills,day){
 const id=(await db.query('insert into orders(order_no,customer_name,order_date) values($1,$2,$3) returning id',[no,party,day||today])).rows[0].id;
 await db.query('insert into order_items values($1,1,$2)',[id,amt]);
 if(bills)await db.query('insert into lwb_tally_invoices(order_id,invoice_no,invoice_date,amount,bills,entered_by) values($1,$2,$3,$4,$5,$6)',
   [id,bills.map(b=>b.no).join(', '),day||today,bills.reduce((a,b)=>a+b.amount,0),JSON.stringify(bills),ids.accounts]);
 return id;
}

test('group links: names under a main party; no chains; only Accounts / Admin',async()=>{
 await db.query("insert into lwb_customer_master values($1),('AKASH TRADERS'),('RAM STORES')",[P]);
 await as('manager');
 await assert.rejects(call('select public.lwb_party_group_set($1,$2)',['PRIYA TRADERS',P]),/Admin \/ Accounts/);
 await as('accounts');
 for(const n of ['PRIYA TRADERS','Rohit Traders','AARTI TRADERS','AGARWAL TRADERS'])await call('select public.lwb_party_group_set($1,$2)',[n,P]);
 await assert.rejects(call('select public.lwb_party_group_set($1,$2)',['X',P.toLowerCase()+' x']),/not in the Party Master/);
 await assert.rejects(call('select public.lwb_party_group_set($1,$2)',[P,P]),/under itself/);
 // PRIYA is under Jagdish, so it can not be a main party
 await assert.rejects(call('select public.lwb_party_group_set($1,$2)',['NEW NAME','PRIYA TRADERS']),/Party Master|already under/);
 await assert.rejects(call('select public.lwb_party_group_set($1,$2)',[P,'AKASH TRADERS']),/itself a main party/);
 // an ERP party can be under a main party too
 await call('select public.lwb_party_group_set($1,$2)',['RAM STORES',P]);
 assert.equal((await call('select public.lwb_party_parent($1) p',['rohit  traders']))[0].p,P);
 assert.equal((await call('select public.lwb_party_parent($1) p',['AKASH TRADERS']))[0].p,'AKASH TRADERS');
 const d=await data();
 assert.equal(d.groups.filter(g=>g.parent===P).length,5);
 await call('select public.lwb_party_group_set($1,null)',['RAM STORES']);
 assert.equal((await data()).groups.length,4);
});

test('loaded PO with no Tally bill is pending; bill lines show the names; due on the main party',async()=>{
 await as('accounts');
 o1=await po('LXY-1',P,290000,[{firm:'PRIYA TRADERS',no:'P-11',amount:160000},{firm:'ROHIT TRADERS',no:'R-7',amount:130000}],dayAdd(today,-10));
 o2=await po('LXY-2',P,100000,[{firm:'AARTI TRADERS',no:'A-3',amount:100000}],dayAdd(today,-5));
 o3=await po('LXY-3',P,50000,null);
 o4=await po('LXY-4','AKASH TRADERS',54405,[{firm:'AKASH TRADERS',no:'K-1',amount:54405}]);
 const d=await data();
 const p3=d.orders.find(o=>o.order_id===o3);
 assert.equal(p3.invoice_no,null);assert.equal(p3.parent,P);
 const p1=d.orders.find(o=>o.order_id===o1);
 assert.equal(Number(p1.due),290000);assert.deepEqual(p1.bills.map(b=>b.firm),['PRIYA TRADERS','ROHIT TRADERS']);
 // driver collected 20,000 on LXY-2 -> due 80,000
 await db.query("insert into lwb_delivery_reports(order_id,cash_reported,payment_status) values($1,20000,'PENDING')",[o2]);
 assert.equal(await due(o2),80000);
});

test('party payment: 5 lakh by bank on the group, oldest bill first, rest stays advance',async()=>{
 await as('accounts');
 await assert.rejects(receive('NOBODY',[{mode:'BANK',amount:5}]),/Party Master/);
 await assert.rejects(receive(P,[{mode:'CASH',amount:250000}]),/269ST/);
 await assert.rejects(receive(P,[{mode:'CHEQUE',amount:5}]),/cheque number/);
 // paid in the name of a bill name: goes to the main party
 const r=await receive('Priya Traders',[{mode:'BANK',amount:400000,ref:'UTR500'},{mode:'CASH',notes:{500:100,200:250}}]);
 assert.equal(r.party,P);assert.equal(Number(r.amount),500000);
 // 2,90,000 to LXY-1, 80,000 to LXY-2 -> 1,30,000 advance
 assert.equal(Number(r.split),370000);assert.equal(Number(r.advance),130000);
 assert.equal(await due(o1),0);assert.equal(await due(o2),0);
 await assert.rejects(receive(P,[{mode:'BANK',amount:1,ref:'utr500'}]),/already entered/);
 const d=await data();
 assert.equal(Number(d.advance[P]),130000);
 const rc=d.receipts.find(x=>x.receipt_id===r.receipt_id);
 assert.equal(rc.allocs.length,2);assert.equal(rc.modes.length,2);
});

test('advance is adjusted when the next bill is made; split by hand; undo a split',async()=>{
 await as('accounts');
 await db.query("insert into lwb_tally_invoices(order_id,invoice_no,invoice_date,amount,bills,entered_by) values($1,'A-9',$2,50000,$3,$4)",
   [o3,today,JSON.stringify([{firm:'AARTI TRADERS',no:'A-9',amount:50000}]),ids.accounts]);
 // a bill of another party can not take Jagdish's money
 await assert.rejects(call('select public.lwb_party_adjust($1,$2::jsonb)',[P,JSON.stringify([{order_id:o4,amount:100}])]),/not under/);
 await assert.rejects(call('select public.lwb_party_adjust($1,$2::jsonb)',[P,JSON.stringify([{order_id:o3,amount:60000}])]),/more than its due/);
 const a=(await call('select public.lwb_party_adjust($1,$2::jsonb) j',[P,JSON.stringify([{order_id:o3,amount:30000}])]))[0].j;
 assert.equal(Number(a.split),30000);assert.equal(Number(a.advance),100000);
 assert.equal(await due(o3),20000);
 // auto: oldest first
 const b=(await call('select public.lwb_party_adjust($1,null) j',[P]))[0].j;
 assert.equal(Number(b.split),20000);assert.equal(Number(b.advance),80000);
 await assert.rejects(call('select public.lwb_party_adjust($1,null)',[P]),/Nothing to adjust/);
 // undo the LXY-1 split -> LXY-1 due again, advance back
 const d=await data();const al=d.receipts[0].allocs.find(x=>x.order_id===o1);
 await call('select public.lwb_party_unadjust($1)',[al.id]);
 assert.equal(await due(o1),290000);
 assert.equal(Number((await data()).advance[P]),370000);
});

test('ledger and outstanding on the main party; bill names in the ledger; cancel a payment',async()=>{
 await as('accounts');
 const led=await call('select * from public.lwb_party_ledger() where customer_name=$1 order by entry_kind,ref_no',[P]);
 const bills=led.filter(l=>l.entry_kind==='TALLY_BILL');
 assert.deepEqual(bills.map(b=>[b.ref_no,Number(b.debit)]),[['A-3',100000],['A-9',50000],['P-11',160000],['R-7',130000]]);
 assert.match(bills.find(b=>b.ref_no==='P-11').note,/bill in PRIYA TRADERS/);
 const pay=led.filter(l=>l.entry_kind==='PARTY_PAYMENT');
 assert.equal(pay.reduce((a,l)=>a+Number(l.credit),0),500000);
 const bal=led.reduce((a,l)=>a+Number(l.debit)-Number(l.credit),0);
 assert.equal(bal,440000-500000); // 60,000 advance (driver money of 20,000 is not verified, not in the ledger)
 const pb=await call('select * from public.lwb_party_bills() where customer_name=$1',[P]);
 assert.equal(pb.length,3);
 // dashboard: the party payment is Cash In of the main party
 const lines=await db.query("select * from public.lwb_acc_lines() where src='PAYMENT'");
 assert.equal(lines.rows.length,2);assert.ok(lines.rows.every(l=>l.party===P&&l.category==='Party payment'));
 // cancel: split goes too
 const rid=(await data()).receipts[0].receipt_id;
 await call('select public.lwb_cancel_tally_payment($1)',[rid]);
 assert.equal(await due(o2),80000);assert.equal(await due(o3),50000);
 assert.equal((await data()).advance[P],undefined);
});

test('old Payment Collection on one PO still works and counts with the split',async()=>{
 await as('accounts');
 await call("select public.lwb_save_tally_payment($1,$2,'[{\"mode\":\"UPI\",\"amount\":10000,\"ref\":\"U1\"}]'::jsonb,null)",[o4,today]);
 assert.equal(await due(o4),44405);
 await receive('AKASH TRADERS',[{mode:'UPI',amount:50000,ref:'U2'}]);
 assert.equal(await due(o4),0);
 assert.equal(Number((await data()).advance['AKASH TRADERS']),5595);
 await as('driver');
 await assert.rejects(call('select public.lwb_party_billing(400)'),/Admin \/ Accounts/);
 await assert.rejects(receive('AKASH TRADERS',[{mode:'UPI',amount:5,ref:'U3'}]),/Only active Accounts/);
});

test('Tally bill lines: any name of the same group; a name of another group is refused; new name goes under the main party',async()=>{
 await as('accounts');
 await call('select public.lwb_party_group_set($1,$2)',['RAM STORES',P]);
 const o5=await po('LXY-5','RAM STORES',70000,null);
 const save=(o,b)=>call('select public.lwb_save_tally_bills($1,$2,$3::jsonb,null)',[o,today,JSON.stringify(b)]);
 await save(o5,[{firm:'PRIYA TRADERS',no:'P-12',amount:40000},{firm:'NEW SHOP',no:'N-1',amount:30000}]);
 assert.equal((await call('select public.lwb_party_parent($1) p',['NEW SHOP']))[0].p,P);
 const d=await data();const r=d.orders.find(o=>o.order_id===o5);
 assert.equal(r.parent,P);assert.equal(Number(r.due),70000);
 const o6=await po('LXY-6','AKASH TRADERS',100,null);
 await assert.rejects(save(o6,[{firm:'PRIYA TRADERS',no:'P-13',amount:100}]),/under party SHREE JAGDISH/);
});

test('money paid before the bill is set against the bill when the bill is saved; one balance',async()=>{
 await db.exec(await sql('lwb_party_auto_adjust_setup.sql'));
 await as('accounts');
 const K='RAJ PAN CENTER';await db.query('insert into lwb_customer_master values($1)',[K]);
 await db.query('insert into orders(order_no,customer_name) values($1,$2)',['LXY-K0',K]);
 // advance first: 1,39,460 kept as advance
 await receive(K,[{mode:'BANK',amount:139460,ref:'K-ADV'}],[]);
 assert.equal(Number((await data()).advance[K]),139460);
 const o=await po('LXY-K1',K,134460,null);
 await call('select public.lwb_save_tally_bills($1,$2,$3::jsonb,null)',[o,today,JSON.stringify([{firm:K,no:'K-9',amount:134460}])]);
 const d=await data();
 assert.equal(Number(d.orders.find(x=>x.order_id===o).due),0);
 assert.equal(Number(d.advance[K]),5000);
});
