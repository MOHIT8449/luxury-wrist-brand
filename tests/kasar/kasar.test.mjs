import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_kasar_setup.sql after the party payment + brand money SQL, on a tiny copy of the tables (no live database).
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
await db.exec(`ALTER TABLE lwb_tally_notes ADD COLUMN created_by uuid, ADD COLUMN cancelled_by uuid;
CREATE FUNCTION public.lwb_outstanding_viewer() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active AND p.role IN ('accounts','admin','manager')) $$;
CREATE FUNCTION public.lwb_flow_tally_note() RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE v_o public.orders%ROWTYPE;
BEGIN
  INSERT INTO public.erp_notifications(title,message,order_id) VALUES (initcap(NEW.kind)||' Note Entered', NEW.reason, NEW.order_id);
  RETURN NEW;
END;
$fn$;
CREATE TRIGGER trg_lwb_flow_tally_note AFTER INSERT ON public.lwb_tally_notes FOR EACH ROW EXECUTE FUNCTION public.lwb_flow_tally_note();`);
await db.exec(await sql('lwb_brand_money_setup.sql'));
await db.exec(await sql('lwb_kasar_setup.sql'));
await db.exec(await sql('lwb_kasar_setup.sql')); // safe to run again

const kasar=(id,amt,kind='LESS')=>call('select public.lwb_kasar_save($1,$2,$3,null,null) j',[id,amt,kind]).then(r=>r[0].j);
let b1,b2,b3;

test('kasar on a small due closes the bill; ledger shows it; no alert',async()=>{
 await db.query("insert into lwb_customer_master values($1),($2)",[P,Q]);
 b1=await po('K-1',P,68575,'COKE 600',true,dayAdd(today,-5));
 await as('accounts');
 await receive(P,[{mode:'CASH',amount:68570}],C);
 assert.equal(await due(b1),5);
 await assert.rejects(kasar(b1,6),/more than its due/);
 await assert.rejects(kasar(b1,501,'EXTRA'),/at most Rs 500/);
 await as('manager');
 await assert.rejects(kasar(b1,5),/Only active Accounts or Admin/);
 await as('accounts');
 await kasar(b1,5);
 assert.equal(await due(b1),0);
 const led=await call('select * from public.lwb_party_ledger_b() where order_no=$1',['K-1']);
 const k=led.find(l=>l.entry_kind==='CREDIT_NOTE');
 assert.equal(k.ref_no,'KASAR');assert.equal(Number(k.credit),5);assert.match(k.note,/Kasar/);assert.equal(k.company_id,C);
 const all=await call('select * from public.lwb_party_ledger_b() where customer_name=$1',[P]);
 assert.equal(all.reduce((a,l)=>a+Number(l.debit)-Number(l.credit),0),0);
 const n=(await db.query("select count(*)::int c from erp_notifications where title like 'Credit%'")).rows[0].c;
 assert.equal(n,0);
});

test('payment with kasar: less on the last bill, extra on a bill',async()=>{
 await as('accounts');
 b2=await po('K-2',Q,110000,'RAJNI 4G',true,dayAdd(today,-3));
 // party pays 1,09,985 on 1,10,000: 15 kasar, bill closed
 const r=(await call('select public.lwb_party_receive_kasar($1,$2,$3::jsonb,$4::jsonb,null,$5,$6::jsonb) j',
   [Q,today,JSON.stringify([{mode:'BANK',amount:109985,ref:'K1'}]),JSON.stringify([{order_id:b2,amount:109985}]),R,JSON.stringify([{order_id:b2,amount:15,kind:'LESS'}])]))[0].j;
 assert.equal(Number(r.kasar),15);assert.equal(Number(r.advance),0);
 assert.equal(await due(b2),0);
 // party pays 10 more than the bill: extra kasar, nothing left as advance
 b3=await po('K-3',Q,5000,'RAJNI 4G',true,dayAdd(today,-1));
 const x=(await call('select public.lwb_party_receive_kasar($1,$2,$3::jsonb,$4::jsonb,null,$5,$6::jsonb) j',
   [Q,today,JSON.stringify([{mode:'CASH',amount:5010}]),JSON.stringify([{order_id:b3,amount:5010}]),R,JSON.stringify([{order_id:b3,amount:10,kind:'EXTRA'}])]))[0].j;
 assert.equal(Number(x.advance),0);assert.equal(await due(b3),0);
 // a bill of another party is refused, and nothing is saved
 await assert.rejects(call('select public.lwb_party_receive_kasar($1,$2,$3::jsonb,null,null,$4,$5::jsonb)',
   [Q,today,JSON.stringify([{mode:'CASH',amount:100}]),C,JSON.stringify([{order_id:b1,amount:1}])]),/not of/);
});

test('kasar ledger lists entries; cancel brings the due back',async()=>{
 await as('manager');
 const l=(await call('select public.lwb_kasar_list(400) j'))[0].j;
 assert.equal(l.length,3);
 assert.deepEqual(l.map(x=>[x.order_no,x.kind,Number(x.amount)]).sort(),[['K-1','LESS',5],['K-2','LESS',15],['K-3','EXTRA',10]].sort());
 assert.equal(l.find(x=>x.order_no==='K-2').parent,Q);
 await assert.rejects(call('select public.lwb_kasar_cancel($1)',[l[0].id]),/Only active/);
 await as('accounts');
 const one=l.find(x=>x.order_no==='K-1');
 await call('select public.lwb_kasar_cancel($1)',[one.id]);
 assert.equal(await due(b1),5);
 assert.equal((await call('select public.lwb_kasar_list(400) j'))[0].j.length,2);
 // a normal credit note can not be cancelled from here
 const cn=(await db.query("insert into lwb_tally_notes(order_id,kind,note_no,note_date,amount) values ($1,'CREDIT','CN-1',current_date,1) returning id",[b1])).rows[0].id;
 await assert.rejects(call('select public.lwb_kasar_cancel($1)',[cn]),/not found/);
 // second kasar on the same bill gets its own number
 await db.query("delete from lwb_tally_notes where id=$1",[cn]);
 await kasar(b1,5);
 assert.ok((await db.query("select note_no from lwb_tally_notes where order_id=$1 and is_kasar and cancelled_at is null",[b1])).rows[0].note_no.startsWith('KASAR-'));
});
