import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_fix_sb_treding.sql on a tiny copy of the tables (no live database).
const admin='00000000-0000-4000-8000-000000000001';
const CO='30000000-0000-4000-8000-000000000001';
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
const KEEP='10000000-0000-4000-8000-000000000001',DROP='10000000-0000-4000-8000-000000000002',OTHER='10000000-0000-4000-8000-000000000003';
const K='S B TRADING COMPANY (GODADRA)',D='S B TREDING COMPANY';
async function setup({dropInMaster=true,extra=''}={}){
  const db=new PGlite();
  await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
INSERT INTO public.user_profiles VALUES ('${admin}','admin',true,'Mohit');
CREATE TABLE public.lwb_customer_master(id uuid primary key default gen_random_uuid(),customer_code text,customer_name text not null,
  gst_registration_status text,pan text unique,gstin text unique,mobile text,billing_address text,city text,state text,pincode text,
  contact_person text,credit_days int default 0,is_active boolean default true);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,order_date date default current_date,total_amount numeric);
CREATE TABLE public.lwb_internal_bills(id uuid default gen_random_uuid() primary key,customer_name text,amount numeric);
CREATE TABLE public.lwb_tally_payments(id serial primary key,party text,amount numeric);
CREATE TABLE public.lwb_party_opening_balances(id uuid default gen_random_uuid() primary key,customer_name text,amount numeric,company_id uuid);
CREATE UNIQUE INDEX ON public.lwb_party_opening_balances(upper(btrim(customer_name)),coalesce(company_id,'00000000-0000-0000-0000-000000000000'::uuid));
CREATE TABLE public.lwb_party_salesman(customer_id uuid primary key references lwb_customer_master(id),salesman_id uuid);
CREATE TABLE public.lwb_tally_party_map(tally_key text primary key,tally_name text not null,customer_name text,updated_at timestamptz,updated_by uuid);
CREATE TABLE public.lwb_change_log(id serial primary key,customer_name text);
CREATE FUNCTION public.lwb_party_key(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT btrim(regexp_replace(upper(coalesce(p,'')), '[^A-Z0-9]+', ' ', 'g')) $$;
CREATE FUNCTION public.lwb_party_parent(p text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT btrim(m.customer_name) FROM public.lwb_tally_party_map m WHERE m.tally_key=public.lwb_party_key(p)), btrim(p)) $$;
-- ledger stub: opening + orders (Dr) + party payments (Cr), on the main party; admin only
CREATE FUNCTION public.lwb_party_ledger() RETURNS TABLE(customer_name text,debit numeric,credit numeric) LANGUAGE sql STABLE AS $$
  SELECT public.lwb_party_parent(e.n), e.dr, e.cr FROM (
    SELECT customer_name n, greatest(amount,0) dr, greatest(-amount,0) cr FROM public.lwb_party_opening_balances
    UNION ALL SELECT customer_name, total_amount, 0 FROM public.orders
    UNION ALL SELECT party, 0, amount FROM public.lwb_tally_payments) e
  WHERE EXISTS (SELECT 1 FROM public.user_profiles WHERE id=auth.uid() AND role='admin') $$;
INSERT INTO lwb_customer_master(id,customer_code,customer_name,mobile) VALUES
 ('${KEEP}','C1','${K}',null),('${OTHER}','C3','S B TRADERS',null);
${dropInMaster?`INSERT INTO lwb_customer_master(id,customer_code,customer_name,mobile) VALUES ('${DROP}','C2','${D}','999');
INSERT INTO lwb_party_salesman VALUES ('${DROP}','20000000-0000-4000-8000-000000000001');`:''}
INSERT INTO orders(order_no,customer_name,total_amount) VALUES ('LXY-00104','${K}',102770),('LXY-00310','${K}',97400),
 ('LXY-00200','${D}',150000),('LXY-00201','S.B. TREDING  COMPANY',76649),('LXY-00300','S B TRADERS',5000);
INSERT INTO lwb_tally_payments(party,amount) VALUES ('${K}',112200),('s b treding company',10000);
INSERT INTO lwb_change_log(customer_name) VALUES ('${D}');
${extra}`);
  await db.exec(await sql('lwb_party_merge_setup.sql'));
  await db.exec(await sql('lwb_party_merged_delete_setup.sql'));
  return db;
}
const n=async(db,q)=>Number((await db.query(q)).rows[0].n);
const bal=async(db,name)=>{await db.exec(`SELECT set_config('request.jwt.claim.sub','${admin}',false)`);
  return n(db,`SELECT coalesce(sum(debit-credit),0) n FROM lwb_party_ledger() WHERE lwb_party_key(customer_name)=lwb_party_key('${name}')`);};

test('everything of S B TREDING lands on GODADRA, opening balances added, ledger = sum of both', async()=>{
  const db=await setup({extra:`INSERT INTO lwb_party_opening_balances(customer_name,amount,company_id) VALUES ('${K}',20000,'${CO}'),('${D}',5000,'${CO}'),('${D}',1000,null);`});
  const bk=await bal(db,K), bd=await bal(db,D);
  await db.exec(`SELECT set_config('request.jwt.claim.sub','',false)`);
  await db.exec(await sql('lwb_party_fix_sb_treding.sql'));
  assert.equal(await bal(db,K), bk+bd);
  assert.equal(await bal(db,D), 0);
  assert.equal(await n(db,`SELECT count(*) n FROM orders WHERE customer_name='${K}'`),4);
  assert.equal(await n(db,`SELECT count(*) n FROM orders WHERE customer_name='S B TRADERS'`),1);
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_tally_payments WHERE party='${K}'`),2);
  assert.equal(await n(db,`SELECT amount n FROM lwb_party_opening_balances WHERE customer_name='${K}' AND company_id='${CO}'`),25000);
  assert.equal(await n(db,`SELECT amount n FROM lwb_party_opening_balances WHERE customer_name='${K}' AND company_id IS NULL`),1000);
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_party_salesman WHERE customer_id='${KEEP}'`),1);
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_change_log WHERE customer_name='${D}'`),1); // history kept
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_customer_master WHERE id='${DROP}'`),0);
  assert.equal((await db.query(`SELECT mobile FROM lwb_customer_master WHERE id='${KEEP}'`)).rows[0].mobile,'999');
  assert.equal((await db.query(`SELECT customer_name FROM lwb_tally_party_map WHERE tally_key='S B TREDING COMPANY'`)).rows[0].customer_name,K);
  const done=(await db.query(`SELECT data FROM lwb_party_fix_log WHERE step='done'`)).rows[0].data;
  assert.equal(done.old_party_deleted,true);
  assert.equal(done.opening_folded,1);
  await db.exec(await sql('lwb_party_fix_sb_treding.sql'));   // second run does nothing
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_party_fix_log`),2);
});

test('S B TREDING not in Party Master: names moved + Tally name link', async()=>{
  const db=await setup({dropInMaster:false});
  const bk=await bal(db,K), bd=await bal(db,D);
  assert.ok(bd>0);
  await db.exec(`SELECT set_config('request.jwt.claim.sub','',false)`);
  await db.exec(await sql('lwb_party_fix_sb_treding.sql'));
  assert.equal(await bal(db,K), bk+bd);
  assert.equal(await n(db,`SELECT count(*) n FROM orders WHERE lwb_party_key(customer_name)='S B TREDING COMPANY'`),0);
  assert.equal((await db.query(`SELECT customer_name FROM lwb_tally_party_map WHERE tally_key='S B TREDING COMPANY'`)).rows[0].customer_name,K);
});
