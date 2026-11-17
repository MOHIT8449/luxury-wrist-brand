import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_tally_invoice_no_rules_setup.sql on a tiny copy of the tables it reads (no live database).
// lwb_save_tally_bills is the live one (lwb_bill_change_setup.sql); lwb_save_tally_invoice is a short stand-in.
const ids={admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',sales:'00000000-0000-4000-8000-000000000003'};
const RJ='10000000-0000-4000-8000-000000000001',CC='10000000-0000-4000-8000-000000000002';
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
const between=(src,a,b)=>src.slice(src.indexOf(a),src.indexOf(b,src.indexOf(a)));
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text default 'loaded');
CREATE TABLE public.order_items(order_id uuid,sku_name text);
CREATE TABLE public.sku_master(sku_name text,company_id uuid);
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key references orders(id),invoice_no text not null,invoice_date date not null,note text,amount numeric(14,2),bills jsonb not null default '[]',entered_by uuid,entered_at timestamptz default now(),updated_by uuid,updated_at timestamptz);
CREATE TABLE public.lwb_tally_party_map(tally_key text primary key,customer_name text);
CREATE FUNCTION public.lwb_tally_staff() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active AND p.role IN ('accounts','admin')) $$;
CREATE FUNCTION public.lwb_party_key(t text) RETURNS text LANGUAGE sql AS $$ SELECT upper(btrim(t)) $$;
CREATE FUNCTION public.lwb_party_parent(t text) RETURNS text LANGUAGE sql AS $$ SELECT t $$;
CREATE FUNCTION public.lwb_save_tally_invoice(p_order_id uuid,p_invoice_no text,p_invoice_date date,p_note text) RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE public.lwb_tally_invoices SET invoice_no=p_invoice_no,invoice_date=p_invoice_date WHERE order_id=p_order_id;
  IF FOUND THEN RETURN 'UPDATED'; END IF;
  INSERT INTO public.lwb_tally_invoices(order_id,invoice_no,invoice_date) VALUES (p_order_id,p_invoice_no,p_invoice_date);
  RETURN 'SAVED';
END $$;
`);
const bm=await sql('lwb_brand_money_setup.sql');
await db.exec(between(bm,'CREATE OR REPLACE FUNCTION public.lwb_order_company','REVOKE ALL ON FUNCTION public.lwb_order_company'));
const bc=await sql('lwb_bill_change_setup.sql');
await db.exec(between(bc,'CREATE OR REPLACE FUNCTION public.lwb_save_tally_bills','-- ---------------------------------------------------------------------------\n-- 2.'));
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true)',[id,role]);
await db.query("insert into sku_master values ('RAJNI 4G',$1),('THUMS UP 250',$2)",[RJ,CC]);
// old data from before the rule: one merged line and one number on two POs
const po=async(no,sku,party='AL KAZMI TOBACCO')=>{const id=(await db.query('insert into orders(order_no,customer_name) values($1,$2) returning id',[no,party])).rows[0].id;
  await db.query('insert into order_items values($1,$2)',[id,sku]);return id};
const old1=await po('LXY-00325','RAJNI 4G'),old2=await po('LXY-00100','RAJNI 4G'),old3=await po('LXY-00101','RAJNI 4G','OTHER PARTY');
await db.query(`insert into lwb_tally_invoices(order_id,invoice_no,invoice_date,amount,bills) values
  ($1,'3673,3674,3675','2026-11-16',496960,'[{"firm":"AL KAZMI TOBACCO","no":"3673,3674,3675","amount":496960}]'),
  ($2,'3500','2026-11-01',1000,'[]'),($3,'3500','2026-11-02',2000,'[]')`,[old1,old2,old3]);
await db.exec(await sql('lwb_tally_invoice_no_rules_setup.sql'));
await db.exec(await sql('lwb_tally_invoice_no_rules_setup.sql'));  // safe to run again
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const save=(id,bills,date='2026-11-17')=>call('select public.lwb_save_tally_bills($1,$2,$3::jsonb,null) r',[id,date,JSON.stringify(bills)]);
const err=async p=>{try{await p}catch(e){return e.message}assert.fail('expected an error')};

test('One bill line with 3 invoice numbers is refused; one line each is saved',async()=>{
 await as('accounts');
 const o=await po('LXY-00400','RAJNI 4G');
 for(const no of ['3701,3702','3701 3702','3701 & 3702','3701+3702','3701-3702','3701;3702','3701 and 3702'])
  assert.match(await err(save(o,[{no,amount:100}])),/more than one invoice no/,no);
 assert.equal((await db.query('select count(*)::int c from lwb_tally_invoices where order_id=$1',[o])).rows[0].c,0);
 await save(o,[{no:'3701',amount:100},{no:'3702',amount:200}]);
 const t=(await db.query('select invoice_no,amount::numeric a from lwb_tally_invoices where order_id=$1',[o])).rows[0];
 assert.equal(t.invoice_no,'3701, 3702');assert.equal(Number(t.a),300);
 // a prefix with "/" or "-" is one number
 const p=await po('LXY-00401','RAJNI 4G');await save(p,[{no:'RJ/26-27/3703',amount:50}]);
});

test('Same invoice no. again (same brand, same year) is refused on any PO and any bill name',async()=>{
 await as('accounts');
 const o=await po('LXY-00402','RAJNI 4G','SOME OTHER NAME');
 assert.match(await err(save(o,[{no:'3701',amount:100}])),/Duplicate: invoice no\. 3701 already exists in PO LXY-00400/);
 assert.match(await err(save(o,[{no:' 03702 ',amount:100}])),/already exists in PO LXY-00400/);
 assert.match(await err(save(o,[{no:'3704',amount:1},{no:'3704',amount:2}])),/entered twice/);
 // Coca-Cola has its own series; a new financial year starts again
 const c=await po('LXY-00403','THUMS UP 250');await save(c,[{no:'3701',amount:100}]);
 const n=await po('LXY-00404','RAJNI 4G');await save(n,[{no:'3701',amount:100}],'2027-04-01');
 // and a direct write to the table is refused too
 const d=await po('LXY-00406','RAJNI 4G');
 await assert.rejects(db.query("insert into lwb_tally_invoices(order_id,invoice_no,invoice_date) values($1,'3702','2026-11-10')",[d]),/Duplicate: invoice no\. 3702/);
 await assert.rejects(db.query(`update lwb_tally_invoices set bills='[{"no":"3701","amount":5}]' where order_id=$1`,[n]).then(()=>db.query(`update lwb_tally_invoices set bills='[{"no":"3702","amount":5}]', invoice_date='2026-11-10' where order_id=$1`,[n])),/Duplicate: invoice no\. 3702/);
});

test('Old merged / repeated bills: other fields can still be saved; Edit must split them',async()=>{
 await as('accounts');
 await db.query("update lwb_tally_invoices set invoice_date='2026-11-15', amount=496000 where order_id=$1",[old1]);
 await db.query("update lwb_tally_invoices set amount=999 where order_id=$1",[old3]);
 assert.match(await err(save(old1,[{no:'3673,3674,3675',amount:496960}],'2026-11-16')),/more than one/);
 await save(old1,[{no:'3673',amount:150000},{no:'3674',amount:200000},{no:'3675',amount:146960}],'2026-11-16');
 const t=(await db.query('select invoice_no,amount::numeric a from lwb_tally_invoices where order_id=$1',[old1])).rows[0];
 assert.equal(t.invoice_no,'3673, 3674, 3675');assert.equal(Number(t.a),496960);
});

test('Live check and the fix list',async()=>{
 await as('accounts');
 const o=await po('LXY-00405','RAJNI 4G');
 const j=(await call('select public.lwb_tally_no_check($1,$2,$3) j',[o,'2026-11-17',['3701','9999','3673']]))[0].j;
 assert.deepEqual(j.map(x=>x.no).sort(),['3673','3701']);
 assert.equal(j.find(x=>x.no==='3701').order_no,'LXY-00400');
 assert.deepEqual((await call('select public.lwb_tally_no_check($1,$2,$3) j',[o,'2026-11-17',['9999']]))[0].j,[]);
 const p=(await call('select public.lwb_tally_no_problems() j'))[0].j;
 assert.equal(p.merged.length,0); // 3673,3674,3675 was split above
 assert.equal(p.dupes.length,1);assert.equal(p.dupes[0].no,'3500');
 assert.deepEqual(p.dupes[0].rows.map(r=>r.order_no),['LXY-00100','LXY-00101']);
 await as('sales');
 await assert.rejects(call('select public.lwb_tally_no_check($1,$2,$3) j',[o,'2026-11-17',['1']]),/Only active Accounts or Admin/);
 await assert.rejects(call('select public.lwb_tally_no_problems() j'),/Only active Accounts or Admin/);
});
