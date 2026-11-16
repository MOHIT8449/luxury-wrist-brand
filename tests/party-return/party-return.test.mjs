import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_return_setup.sql (after the billing files) on a tiny copy of the tables it reads (no live database).
// Party billing SQL runs first, as on the live database.
const ids={admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',manager:'00000000-0000-4000-8000-000000000003',warehouse:'00000000-0000-4000-8000-000000000004'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
const between=(src,a,b)=>src.slice(src.indexOf(a),src.indexOf(b,src.indexOf(a)));
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid primary key);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text default 'pending',order_date date default current_date,
  total_qty numeric,total_amount numeric,approved_at timestamptz,priority text,created_by uuid);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric,rate numeric,unit_weight numeric,amount numeric,total_weight numeric,entry_uom text);
CREATE TABLE public.sku_master(sku_name text,is_active boolean);
CREATE TABLE public.dispatch_assignments(order_id uuid,loading_completed_at timestamptz,vehicle_no text,driver_name text,driver_mobile text,loading_manager_id uuid);
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key references orders(id),invoice_no text not null,invoice_date date not null,note text,amount numeric(14,2),bills jsonb not null default '[]',entered_by uuid,entered_at timestamptz default now(),updated_by uuid,updated_at timestamptz);
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
CREATE FUNCTION public.lwb_order_driver_received(p uuid) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT 0::numeric $$;
CREATE FUNCTION public.lwb_order_return_credit(p uuid) RETURNS numeric LANGUAGE sql STABLE AS $$ SELECT 0::numeric $$;
CREATE FUNCTION public.lwb_save_tally_invoice(p_order_id uuid,p_invoice_no text,p_invoice_date date,p_note text) RETURNS text LANGUAGE sql AS $$ SELECT 'stub' $$;
CREATE FUNCTION public.lwb_driver_phone_matches(a text,b text) RETURNS boolean LANGUAGE sql AS $$ SELECT right(a,10)=right(b,10) $$;
`);
const tc=await sql('lwb_cashbook_tally_check_setup.sql');
await db.exec(between(tc,'CREATE OR REPLACE FUNCTION public.lwb_tally_set_party_map','REVOKE ALL ON FUNCTION public.lwb_tally_check_user()'));
for(const [role,id] of Object.entries(ids)){await db.query('insert into auth.users values($1)',[id]);await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role+' user'])}
await db.exec(await sql('lwb_party_payment_collection_setup.sql'));
await db.exec(await sql('lwb_accounts_dashboard_setup.sql'));
await db.exec(await sql('lwb_party_group_billing_setup.sql'));
const fl=await sql('lwb_sales_order_followup_setup.sql');
await db.exec(between(fl,'CREATE OR REPLACE FUNCTION public.lwb_order_pending','-- The signed-in salesman'));
const pop=await sql('lwb_order_flow_popups_setup.sql');
await db.exec(between(pop,'CREATE OR REPLACE FUNCTION public.lwb_flow_send','REVOKE ALL ON FUNCTION public.lwb_flow_send'));
await db.exec(await sql('lwb_bill_before_loading_setup.sql'));

await db.exec("ALTER TABLE public.sku_master ADD COLUMN pcs_per_case int, ADD COLUMN company_id uuid; ALTER TABLE public.lwb_tally_notes ADD COLUMN created_by uuid, ADD COLUMN cancelled_by uuid");
await db.exec(await sql('lwb_party_return_setup.sql'));
await db.exec(await sql('lwb_party_return_setup.sql'));  // safe to run again
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

const today=(await db.query("select (now() at time zone 'Asia/Kolkata')::date::text d")).rows[0].d;
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const billing=async()=>(await call('select public.lwb_party_billing(400) j'))[0].j;
const form=async(o,p=null)=>(await call('select public.lwb_party_return_form($1,$2) j',[o,p]))[0].j;
const save=(o,party,lines,cn=null,date=today)=>call('select public.lwb_party_return_save($1,$2,$3,$4::jsonb,$5,$6) j',[o,party,date,JSON.stringify(lines),'note',cn]).then(r=>r[0].j);
const list=async()=>(await call('select public.lwb_party_return_list(400) j'))[0].j;
const due=async o=>Number((await billing()).orders.find(x=>x.order_id===o).due);

await db.exec(`insert into sku_master values ('1.25L THUMS UP MRP 70',true,null),('250ML MAAZA 1X24 MRP 20',true,null),('750ML SODA MRP 20',true,12),('OLD SKU',false,null)`);

let billed,unbilled;
test('setup: one billed PO, one loaded PO without Tally bill',async()=>{
 billed=(await db.query("insert into orders(order_no,customer_name,status) values('LXY-00114','ANKIT ENTERPRISE','loaded') returning id")).rows[0].id;
 await db.query("insert into order_items(order_id,sku_name,ordered_qty,approved_qty,loaded_qty,rate) values ($1,'1.25L THUMS UP MRP 70',15,15,15,615),($1,'250ML MAAZA 1X24 MRP 20',30,30,30,480)",[billed]);
 unbilled=(await db.query("insert into orders(order_no,customer_name,status) values('LXY-00136','RADHEY TRADERS','loaded') returning id")).rows[0].id;
 await db.query("insert into order_items(order_id,sku_name,ordered_qty,approved_qty,loaded_qty,rate) values ($1,'750ML SODA MRP 20',15,15,15,330)",[unbilled]);
 await as('accounts');
 await call('select public.lwb_save_tally_bills($1,$2,$3::jsonb,null)',[billed,today,JSON.stringify([{no:'T114',amount:23625}])]);
 assert.equal(await due(billed),23625);
});

test('Form: PO lines with cases, rate, PCS per case (SKU Master, else 1X24 in the name), last party rate',async()=>{
 const f=await form(billed);
 assert.equal(f.bill.invoice_no,'T114');
 assert.deepEqual(f.items.map(i=>[i.sku_name,Number(i.cases),Number(i.rate),i.ppc,Number(i.returned)]),
  [['1.25L THUMS UP MRP 70',15,615,null,0],['250ML MAAZA 1X24 MRP 20',30,480,24,0]]);
 const s=f.skus.find(x=>x.sku==='250ML MAAZA 1X24 MRP 20');assert.equal(Number(s.rate),480);
 assert.ok(!f.skus.some(x=>x.sku==='OLD SKU'));
 const g=await form(null,'ankit enterprise');assert.equal(Number(g.skus.find(x=>x.sku==='1.25L THUMS UP MRP 70').rate),615);
 assert.equal(g.skus.find(x=>x.sku==='750ML SODA MRP 20').rate,null);
});

let r1;
test('Return on a billed PO: 2 CS + 6 PCS, plus another SKU -> credit note, Due goes down',async()=>{
 const f=await form(billed),[tu,mz]=f.items;
 r1=await save(billed,null,[{item_id:tu.item_id,cases:2,pcs:0},{item_id:mz.item_id,cases:0,pcs:6,rate:1},{sku_name:'750ml soda mrp 20',cases:1,pcs:0,rate:330}]);
 // 2*615 + 6/24*480 + 1*330 = 1230 + 120 + 330
 assert.equal(Number(r1.amount),1680);
 assert.equal(r1.credit_note,r1.return_no);assert.match(r1.return_no,/^RET-\d{4}$/);
 assert.equal(Number(r1.lines[1].rate),480,'PO line keeps the PO rate');
 assert.equal(await due(billed),23625-1680);
 const n=(await db.query('select note_no,amount::numeric a,kind from lwb_tally_notes where order_id=$1',[billed])).rows;
 assert.deepEqual(n.map(x=>[x.note_no,Number(x.a),x.kind]),[[r1.return_no,1680,'CREDIT']]);
 const f2=await form(billed);assert.equal(Number(f2.items[1].returned),0.25);
});

test('Checks: more than loaded, PCS without packing, unknown SKU, no rate, staff only',async()=>{
 const f=await form(billed),[tu,mz]=f.items;
 await assert.rejects(save(billed,null,[{item_id:tu.item_id,cases:14}]),/only 13 CS is left/);
 await assert.rejects(save(billed,null,[{item_id:tu.item_id,cases:0,pcs:3}]),/no PCS per case/);
 await assert.rejects(save(null,'ANKIT ENTERPRISE',[{sku_name:'PEPSI',cases:1,rate:5}]),/not in SKU Master/);
 await assert.rejects(save(null,'ANKIT ENTERPRISE',[{sku_name:'750ML SODA MRP 20',cases:1}]),/rate per case/);
 await assert.rejects(save(null,'',[{sku_name:'750ML SODA MRP 20',cases:1,rate:5}]),/Choose the party/);
 await assert.rejects(save(null,'X',[{sku_name:'750ML SODA MRP 20',cases:0,pcs:0,rate:5}]),/cases or pieces/);
 await assert.rejects(save(null,'X',[{sku_name:'750ML SODA MRP 20',cases:1.5,rate:5}]),/whole cases/);
 await assert.rejects(save(billed,null,[{item_id:mz.item_id,cases:1}],r1.return_no),/already entered/);
 await as('manager');
 await assert.rejects(save(null,'X',[{sku_name:'750ML SODA MRP 20',cases:1,rate:5}]),/Only active Accounts or Admin/);
 await assert.rejects(list(),/Admin \/ Accounts/);
 await as('accounts');
});

test('Return on a PO without Tally bill: kept on the PO, no credit note',async()=>{
 const f=await form(unbilled);assert.equal(f.bill,null);assert.equal(f.items[0].ppc,12);
 const r=await save(unbilled,null,[{item_id:f.items[0].item_id,cases:1,pcs:6}],'TALLY-CN-9');
 assert.equal(Number(r.amount),495);assert.equal(r.credit_note,null);
 assert.equal((await db.query('select count(*)::int c from lwb_tally_notes where order_id=$1',[unbilled])).rows[0].c,0);
});

let free;
test('New return (no bill): any SKU from a party, brand from the SKU',async()=>{
 const c='00000000-0000-4000-8000-0000000000c1';
 await db.query("update sku_master set company_id=$1",[c]);
 free=await save(null,'  ANKIT ENTERPRISE ',[{sku_name:'750ML SODA MRP 20',cases:0,pcs:12,rate:330},{sku_name:'1.25L THUMS UP MRP 70',cases:1,rate:600}]);
 assert.equal(Number(free.amount),930);assert.equal(free.party,'ANKIT ENTERPRISE');assert.equal(free.order_no,null);
 const l=await list();
 assert.equal(l.length,3);
 const x=l.find(y=>y.id===free.id);
 assert.equal(x.company_id,c);assert.equal(x.order_id,null);assert.equal(x.parent,'ANKIT ENTERPRISE');assert.equal(x.by,'accounts user');
 assert.deepEqual(x.items.map(i=>[i.sku,i.cases,i.pcs,Number(i.amount)]),[['1.25L THUMS UP MRP 70',1,0,600],['750ML SODA MRP 20',0,12,330]]);
 assert.equal(l.find(y=>y.id===r1.id).credit_note,r1.return_no);
});

test('Cancel: return and its credit note, Due back; cancel twice refused',async()=>{
 await call('select public.lwb_party_return_cancel($1)',[r1.id]);
 assert.equal(await due(billed),23625);
 await assert.rejects(call('select public.lwb_party_return_cancel($1)',[r1.id]),/already cancelled/);
 const l=await list();assert.equal(l.find(y=>y.id===r1.id).cancelled,true);
 assert.equal(Number((await form(billed)).items[1].returned),0);
});

test('Date after today refused',async()=>{
 await assert.rejects(save(null,'X',[{sku_name:'750ML SODA MRP 20',cases:1,rate:5}],null,'2999-01-01'),/valid return date/);
});
