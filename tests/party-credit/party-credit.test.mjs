import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_credit_limit_setup.sql on PGlite, with small stand-ins for the live money functions.
const ids={admin:'00000000-0000-4000-8000-000000000001',sales:'00000000-0000-4000-8000-000000000005',driver:'00000000-0000-4000-8000-000000000007'};
const co={cc:'30000000-0000-4000-8000-000000000001',rj:'30000000-0000-4000-8000-000000000002'};
const o={a:'20000000-0000-4000-8000-000000000001',b:'20000000-0000-4000-8000-000000000002',c:'20000000-0000-4000-8000-000000000003'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
CREATE TABLE public.lwb_customer_master(id uuid primary key default gen_random_uuid(),customer_name text,credit_days int,min_order_kg numeric);
CREATE TABLE public.lwb_companies(id uuid primary key,name text,market_credit_days int);
CREATE TABLE public.lwb_party_company_credit(party_key text,company_id uuid,credit_days int);
CREATE TABLE public.lwb_party_opening_balances(customer_name text,company_id uuid,amount numeric,as_of_date date);
CREATE TABLE public.orders(id uuid primary key,customer_name text,company uuid);
CREATE TABLE public.bill_rows(order_id uuid,party text,invoice_date date,dispatch_date date,due numeric);
CREATE TABLE public.free_money(parent text,company uuid,free numeric);
CREATE TABLE public.my_parties(name text);
CREATE FUNCTION public.lwb_party_parent(p text) RETURNS text LANGUAGE sql AS $$ SELECT CASE WHEN upper(btrim(p))='AMBIKA SUBFIRM' THEN 'AMBIKA STORES' ELSE btrim(p) END $$;
CREATE FUNCTION public.lwb_party_key(p text) RETURNS text LANGUAGE sql AS $$ SELECT upper(btrim(p)) $$;
CREATE FUNCTION public.lwb_order_company(p uuid) RETURNS uuid LANGUAGE sql AS $$ SELECT company FROM public.orders WHERE id=p $$;
CREATE FUNCTION public.lwb_tally_bill_rows(p int) RETURNS TABLE(order_id uuid,party text,invoice_date date,dispatch_date date,due numeric) LANGUAGE sql AS $$ SELECT * FROM public.bill_rows $$;
CREATE FUNCTION public.lwb_party_receipt_free_b(p text,c uuid) RETURNS TABLE(free numeric) LANGUAGE sql AS $$ SELECT free FROM public.free_money WHERE upper(parent)=upper(p) AND company=c $$;
CREATE FUNCTION public.lwb_party_name_visible(p text) RETURNS boolean LANGUAGE sql AS $$
  SELECT (SELECT role FROM public.user_profiles WHERE id=auth.uid())<>'sales' OR upper(btrim(p)) IN (SELECT upper(name) FROM public.my_parties) $$;
CREATE FUNCTION public.lwb_party_master_save(p_id uuid, p_row jsonb) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_allowed text[] := ARRAY['customer_name','credit_days','min_order_kg'];
BEGIN RETURN NULL; END $f$;
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
await db.query("insert into user_profiles values($1,'ADMIN',true),($2,'sales',true),($3,'driver',true)",[ids.admin,ids.sales,ids.driver]);
await db.query("insert into lwb_companies values($1,'COCA-COLA',30),($2,'RAJNIGANDHA',15)",[co.cc,co.rj]);
await db.query("insert into lwb_customer_master(customer_name,credit_days) values('AMBIKA STORES',0),('MAHADEV',45)");
await db.query("insert into orders values($1,'AMBIKA STORES',$4),($2,'AMBIKA SUBFIRM',$4),($3,'AMBIKA STORES',$5)",[o.a,o.b,o.c,co.cc,co.rj]);
await db.query(`insert into bill_rows values($1,'AMBIKA STORES',(now() at time zone 'Asia/Kolkata')::date-52,null,100000),($2,'Ambika Subfirm',null,(now() at time zone 'Asia/Kolkata')::date-10,84300),($3,'AMBIKA STORES',(now() at time zone 'Asia/Kolkata')::date-5,null,9000)`,[o.a,o.b,o.c]);
await db.query("insert into lwb_party_opening_balances values('AMBIKA STORES',$1,20000,(now() at time zone 'Asia/Kolkata')::date-70)",[co.cc]);
await db.query("insert into free_money values('AMBIKA STORES',$1,20000)",[co.cc]);
const sql=await readFile(new URL('../../lwb_party_credit_limit_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql);
async function as(w){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[w]])}
async function call(q,a=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,a)).rows}finally{await db.exec('RESET ROLE')}}
const credit=async(w,p,c)=>{await as(w);return (await call('select lwb_party_credit($1,$2) r',[p,c]))[0].r};

test('Party Master save now allows credit_limit', async()=>{
  const d=(await db.query("select pg_get_functiondef('public.lwb_party_master_save(uuid,jsonb)'::regprocedure) d")).rows[0].d;
  assert.match(d,/'min_order_kg','credit_limit'\]/);
  assert.equal((d.match(/credit_limit/g)||[]).length,1); // not added twice on re-run
});

test('brand-wise balance with opening and advance, sub-firm bills on the main party', async()=>{
  const r=await credit('admin','AMBIKA STORES',co.cc);
  assert.equal(Number(r.due),184300);assert.equal(Number(r.opening),20000);assert.equal(Number(r.advance),20000);assert.equal(Number(r.balance),184300);
  assert.equal(r.oldest_days,70); // opening is the oldest
  assert.equal(r.credit_days,30); // brand market days (party has 0)
  assert.equal(r.over_days,true);assert.equal(r.over_limit,false);assert.equal(r.credit_limit,null);
  const rj=await credit('admin','AMBIKA STORES',co.rj);
  assert.equal(Number(rj.balance),9000);assert.equal(rj.oldest_days,5);assert.equal(rj.credit_days,15);assert.equal(rj.over_days,false);
});

test('limit and party days', async()=>{
  await db.query("update lwb_customer_master set credit_limit=150000 where customer_name='AMBIKA STORES'");
  let r=await credit('admin','ambika stores',co.cc);
  assert.equal(Number(r.credit_limit),150000);assert.equal(r.over_limit,true);
  await db.query("insert into lwb_party_company_credit values('AMBIKA STORES',$1,90)",[co.cc]);
  r=await credit('admin','AMBIKA STORES',co.cc);assert.equal(r.credit_days,90);assert.equal(r.over_days,false);
  r=await credit('admin','MAHADEV',co.cc);assert.equal(Number(r.balance),0);assert.equal(r.oldest_days,null);assert.equal(r.credit_days,45);assert.equal(r.over_limit,false);
});

test('order credit, and who may see it', async()=>{
  await as('admin');
  const r=(await call('select lwb_order_credit($1) r',[o.c]))[0].r;
  assert.equal(r.company_id,co.rj);assert.equal(Number(r.balance),9000);
  await assert.rejects(credit('sales','AMBIKA STORES',co.cc),/Not your party/);
  await db.query("insert into my_parties values('AMBIKA STORES')");
  assert.equal(Number((await credit('sales','AMBIKA STORES',co.cc)).balance),184300);
  await assert.rejects(credit('driver','AMBIKA STORES',co.cc),/Not allowed/);
});
