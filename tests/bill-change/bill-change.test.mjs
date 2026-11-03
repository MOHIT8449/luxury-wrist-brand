import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_bill_change_setup.sql (after the billing files) on a tiny copy of the tables it reads (no live database).
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
await db.exec(await sql('lwb_bill_change_setup.sql'));
await db.exec(await sql('lwb_bill_change_setup.sql'));  // safe to run again
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated; GRANT SELECT,UPDATE ON orders TO authenticated');

const today=(await db.query("select (now() at time zone 'Asia/Kolkata')::date::text d")).rows[0].d;
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const notes=async(id,type)=>(await db.query('select n.*,p.role from erp_notifications n join user_profiles p on p.id=n.user_id where order_id=$1 and notification_type=$2',[id,type])).rows;
const early=async()=>(await call('select public.lwb_bills_before_loading() j'))[0].j;
const billing=async()=>(await call('select public.lwb_party_billing(400) j'))[0].j;
const saveBill=(id,no,amount)=>call('select public.lwb_save_tally_bills($1,$2,$3::jsonb,null) r',[id,today,JSON.stringify([{no,amount}])]);

await db.exec("insert into sku_master values ('THUMS UP 250',true),('THUMS UP 740',true),('MAAZA 600',true),('OLD SKU',false)");
const items=async id=>(await db.query('select sku_name,approved_qty::int a,loaded_qty::int l,rate::numeric r from order_items where order_id=$1 order by id',[id])).rows;
const its=async id=>(await call('select public.lwb_bill_change_items($1) j',[id]))[0].j;
const req=(id,lines,reason='Wrong item loaded',bill=null)=>call('select public.lwb_bill_change_request($1,$2::jsonb,$3,$4,$5) j',[id,JSON.stringify(lines),reason,'note',bill]).then(r=>r[0].j);
const decide=(id,ok,reply=null)=>call('select public.lwb_bill_change_decide($1,$2,$3) j',[id,ok,reply]).then(r=>r[0].j);
const inv=async id=>(await db.query('select amount::numeric a,bills from lwb_tally_invoices where order_id=$1',[id])).rows[0];

let o;
test('setup: loaded PO with 2 lines, Tally bill in 2 names',async()=>{
 o=(await db.query("insert into orders(order_no,customer_name,status,created_by) values('PO-2001','SHREE JAGDISH TRADERS','loaded',$1) returning id",[ids.manager])).rows[0].id;
 await db.query("insert into order_items(order_id,sku_name,ordered_qty,approved_qty,loaded_qty,rate) values ($1,'THUMS UP 250',40,40,40,400),($1,'THUMS UP 740',10,10,10,600)",[o]);
 await as('accounts');
 await call('select public.lwb_save_tally_bills($1,$2,$3::jsonb,null)',[o,today,JSON.stringify([{firm:'SHREE JAGDISH TRADERS',no:'S1',amount:14000},{firm:'JAGDISH AGENCY',no:'J1',amount:8000}])]);
 const t=await inv(o);assert.equal(Number(t.a),22000);assert.equal(t.bills[1].firm,'JAGDISH AGENCY');
});

test('Bill name does not make a party link; money stays on the main party',async()=>{
 assert.equal((await db.query('select count(*)::int c from lwb_tally_party_map')).rows[0].c,0);
 const b=(await call('select public.lwb_party_billing(400) j'))[0].j;
 assert.deepEqual(b.groups,[]);
 assert.equal(b.orders.find(x=>x.order_id===o).parent,'SHREE JAGDISH TRADERS');
});

test('Items popup data: loaded qty, SKU list',async()=>{
 const j=await its(o);
 assert.equal(j.qty_col,'loaded_qty');
 assert.deepEqual(j.items.map(i=>[i.sku_name,Number(i.qty)]),[['THUMS UP 250',40],['THUMS UP 740',10]]);
 assert.ok(j.skus.includes('MAAZA 600')&&!j.skus.includes('OLD SKU'));
});

let ch;
test('Accounts change -> waits for Admin, bell with the difference, nothing changed yet',async()=>{
 const j=await its(o),[a,b]=j.items;
 // 5 cases of 250 were really 740; 250 rate 400 -> 390; Maaza 2 cases added
 const r=await req(o,[{item_id:a.item_id,sku_name:'THUMS UP 250',qty:35,rate:390},{item_id:b.item_id,sku_name:'THUMS UP 740',qty:15,rate:600},{sku_name:'MAAZA 600',qty:2,rate:500}],'Wrong item loaded','J1');
 assert.equal(r.status,'WAITING');
 // old 40*400+10*600=22000, new 35*390+15*600+2*500=23650
 assert.equal(Number(r.diff),1650);ch=r.id;
 assert.deepEqual((await items(o)).map(i=>i.l),[40,10]);
 const bell=(await notes(o,'BILL_CHANGE_APPROVAL'));
 assert.deepEqual(bell.map(n=>n.role),['admin']);
 assert.match(bell[0].message,/PO-2001 · SHREE JAGDISH TRADERS · Rs 22000\.00 -> Rs 23650\.00 \(\+Rs 1650\.00\)/);
 const l=(await call('select public.lwb_bill_change_list(30) j'))[0].j;
 assert.equal(l.length,1);assert.equal(l[0].order_no,'PO-2001');
 assert.deepEqual(l[0].lines.map(x=>x.kind),[['QTY','RATE'],['QTY'],['ADD']]);
});

test('Only Admin decides; warehouse cannot even read',async()=>{
 await assert.rejects(decide(ch,true),/Only Admin/);
 await as('warehouse');
 await assert.rejects(call('select public.lwb_bill_change_list(30)'),/Admin \/ Accounts/);
 await assert.rejects(req(o,[{sku_name:'MAAZA 600',qty:1,rate:1}]),/Only active Accounts or Admin/);
});

test('Admin approves -> PO lines change, chosen Tally bill line takes the difference, To collect follows',async()=>{
 await as('admin');
 const r=await decide(ch,true,'ok');
 assert.equal(r.status,'APPROVED');
 const it=await items(o);
 assert.deepEqual(it.map(i=>[i.sku_name,i.l,Number(i.r)]),[['THUMS UP 250',35,390],['THUMS UP 740',15,600],['MAAZA 600',2,500]]);
 const t=await inv(o);
 assert.equal(Number(t.a),23650);
 assert.deepEqual(t.bills.map(b=>Number(b.amount)),[14000,9650]);
 const row=(await call('select public.lwb_party_billing(400) j'))[0].j.orders.find(x=>x.order_id===o);
 assert.equal(Number(row.due),23650);
 assert.equal((await db.query("select count(*)::int c from erp_notifications where order_id=$1 and notification_type='BILL_CHANGE_APPROVAL' and not is_read",[o])).rows[0].c,0);
 assert.equal((await notes(o,'BILL_CHANGE_APPROVED')).map(n=>n.role).join(),'accounts');
 await assert.rejects(decide(ch,true),/already approved/);
});

test('SKU replaced on a line; send back changes nothing',async()=>{
 await as('accounts');
 const j=await its(o);
 const r=await req(o,j.items.map(i=>({item_id:i.item_id,sku_name:i.sku_name==='MAAZA 600'?'THUMS UP 250':i.sku_name,qty:Number(i.qty),rate:Number(i.rate)})).filter(x=>x.sku_name!=='THUMS UP 250'||x.qty!==35));
 // THUMS UP 250 line left out = removed; Maaza line becomes THUMS UP 250
 const c=(await call('select public.lwb_bill_change_list(30) j'))[0].j.find(x=>x.id===r.id);
 assert.deepEqual(c.lines.map(x=>[x.sku_old,x.sku,x.kind]).sort(),[['MAAZA 600','THUMS UP 250',['SKU']],['THUMS UP 250','THUMS UP 250',['REMOVE']]]);
 await as('admin');
 await decide(r.id,false,'talk to me');
 assert.deepEqual((await items(o)).map(i=>i.sku_name),['THUMS UP 250','THUMS UP 740','MAAZA 600']);
 assert.equal(Number((await inv(o)).a),23650);
 assert.match((await notes(o,'BILL_CHANGE_SENT_BACK'))[0].message,/talk to me/);
});

test('Stale request refused; Admin own change applied at once; checks',async()=>{
 await as('accounts');
 let j=await its(o);
 const r=await req(o,j.items.map(i=>({item_id:i.item_id,sku_name:i.sku_name,qty:Number(i.qty)+(i.sku_name==='MAAZA 600'?1:0),rate:Number(i.rate)})));
 await db.query("update order_items set loaded_qty=3 where order_id=$1 and sku_name='MAAZA 600'",[o]);
 await as('admin');
 await assert.rejects(decide(r.id,true),/STALE/);
 await db.query("update order_items set loaded_qty=2 where order_id=$1 and sku_name='MAAZA 600'",[o]);
 j=await its(o);
 const a=await req(o,j.items.map(i=>({item_id:i.item_id,sku_name:i.sku_name,qty:Number(i.qty),rate:i.sku_name==='MAAZA 600'?450:Number(i.rate)})),null);
 assert.equal(a.status,'APPROVED');assert.equal(Number(a.diff),-100);
 assert.equal(Number((await inv(o)).a),23550);
 // the older waiting request was replaced
 assert.equal((await db.query("select status from lwb_bill_changes where id=$1",[r.id])).rows[0].status,'REPLACED');
 await as('accounts');
 j=await its(o);
 const same=j.items.map(i=>({item_id:i.item_id,sku_name:i.sku_name,qty:Number(i.qty),rate:Number(i.rate)}));
 await assert.rejects(req(o,same),/Nothing changed/);
 await assert.rejects(req(o,[...same,{sku_name:'OLD SKU',qty:1,rate:10}]),/not in the SKU Master/);
 await assert.rejects(req(o,[...same,{sku_name:'MAAZA 600',qty:1,rate:10}]),/two lines/);
 await assert.rejects(req(o,same.map(x=>({...x,qty:x.qty+1})),''),/reason/);
});

test('Before loading the approved qty changes',async()=>{
 const p=(await db.query("insert into orders(order_no,customer_name,status) values('PO-2002','RAM STORES','approved') returning id")).rows[0].id;
 await db.query("insert into order_items(order_id,sku_name,ordered_qty,approved_qty,rate) values ($1,'THUMS UP 250',10,10,400)",[p]);
 await as('admin');
 const j=await its(p);assert.equal(j.qty_col,'approved_qty');
 await req(p,[{item_id:j.items[0].item_id,sku_name:'THUMS UP 250',qty:12,rate:400}]);
 const it=await items(p);assert.equal(it[0].a,12);assert.equal(it[0].l,null);
 const q=(await db.query("insert into orders(order_no,customer_name,status) values('PO-2003','RAM STORES','pending') returning id")).rows[0].id;
 await assert.rejects(req(q,[{sku_name:'MAAZA 600',qty:1,rate:1}]),/Only an approved PO/);
});
