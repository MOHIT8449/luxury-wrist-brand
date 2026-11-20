import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_fix_shree_dev_trading.sql on a tiny copy of the tables (no live database).
const admin='00000000-0000-4000-8000-000000000001';
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
const KEEP='10000000-0000-4000-8000-000000000001',DROP='10000000-0000-4000-8000-000000000002',COLD='10000000-0000-4000-8000-000000000003';
async function setup(extra=''){
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
CREATE TABLE public.lwb_payment_remarks(id serial primary key,party text,note text);
CREATE TABLE public.lwb_party_opening_balances(id uuid default gen_random_uuid() primary key,customer_name text,amount numeric);
CREATE UNIQUE INDEX ON public.lwb_party_opening_balances(upper(btrim(customer_name)));
CREATE TABLE public.lwb_party_salesman(customer_id uuid primary key references lwb_customer_master(id),salesman_id uuid);
CREATE TABLE public.lwb_tally_party_map(tally_key text primary key,tally_name text not null,customer_name text,updated_at timestamptz,updated_by uuid);
CREATE TABLE public.lwb_change_log(id serial primary key,customer_name text);
CREATE FUNCTION public.lwb_party_key(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT btrim(regexp_replace(upper(coalesce(p,'')), '[^A-Z0-9]+', ' ', 'g')) $$;
INSERT INTO lwb_customer_master(id,customer_code,customer_name,mobile) VALUES
 ('${KEEP}','C1','SHREE BHERUNATH TREDING-(SACHIN)',null),('${DROP}','C2','SHREE DEV TRADING (SACHIN)','999'),('${COLD}','C3','SHREE DEV COLDRINK (SAYAN)',null);
INSERT INTO orders(order_no,customer_name,total_amount) VALUES ('LXY-00344','SHREE BHERUNATH TREDING-(SACHIN)',422040),
 ('LXY-00452','SHREE DEV TRADING (SACHIN)',93390),('LXY-00108','SHREE DEV TRADING  (SACHIN)',114440),('LXY-00472','SHREE DEV COLDRINK (SAYAN)',126150);
INSERT INTO lwb_internal_bills(customer_name,amount) VALUES ('SHREE DEV TRADING (SACHIN)',1),('SHREE DEV COLDRINK (SAYAN)',2);
INSERT INTO lwb_tally_payments(party,amount) VALUES ('shree dev trading (sachin)',500);
INSERT INTO lwb_payment_remarks(party,note) VALUES ('SHREE DEV TRADING (SACHIN)','kal');
INSERT INTO lwb_party_salesman VALUES ('${DROP}','20000000-0000-4000-8000-000000000001');
INSERT INTO lwb_change_log(customer_name) VALUES ('SHREE DEV TRADING (SACHIN)');
${extra}`);
  await db.exec(await sql('lwb_party_merge_setup.sql'));
  await db.exec(await sql('lwb_party_merged_delete_setup.sql'));
  return db;
}
const n=async(db,q)=>Number((await db.query(q)).rows[0].n);

test('moves everything to Shree Bherunath, deletes the old party, Coldrink untouched', async()=>{
  const db=await setup();
  await db.exec(await sql('lwb_party_fix_shree_dev_trading.sql'));
  assert.equal(await n(db,`SELECT count(*) n FROM orders WHERE customer_name='SHREE BHERUNATH TREDING-(SACHIN)'`),3);
  assert.equal(await n(db,`SELECT count(*) n FROM orders WHERE customer_name ILIKE '%DEV TRADING%'`),0);
  assert.equal(await n(db,`SELECT count(*) n FROM orders WHERE customer_name='SHREE DEV COLDRINK (SAYAN)'`),1);
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_internal_bills WHERE customer_name='SHREE BHERUNATH TREDING-(SACHIN)'`),1);
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_internal_bills WHERE customer_name='SHREE DEV COLDRINK (SAYAN)'`),1);
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_tally_payments WHERE party='SHREE BHERUNATH TREDING-(SACHIN)'`),1);
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_payment_remarks WHERE party='SHREE BHERUNATH TREDING-(SACHIN)'`),1);
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_party_salesman WHERE customer_id='${KEEP}'`),1);
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_change_log WHERE customer_name='SHREE DEV TRADING (SACHIN)'`),1); // history kept
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_customer_master WHERE id='${DROP}'`),0);
  assert.equal((await db.query(`SELECT mobile FROM lwb_customer_master WHERE id='${KEEP}'`)).rows[0].mobile,'999');
  assert.equal((await db.query(`SELECT customer_name FROM lwb_tally_party_map WHERE tally_key='SHREE DEV TRADING SACHIN'`)).rows[0].customer_name,'SHREE BHERUNATH TREDING-(SACHIN)');
  assert.ok(await n(db,`SELECT count(*) n FROM lwb_party_fix_backup`)>=7);
  const done=(await db.query(`SELECT data FROM lwb_party_fix_log WHERE step='done'`)).rows[0].data;
  assert.equal(done.old_party_deleted,true);
  assert.deepEqual(done.counts_keep_drop_after['orders.customer_name'],[3,0]);
  // second run does nothing
  await db.exec(await sql('lwb_party_fix_shree_dev_trading.sql'));
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_party_fix_log`),2);
});

test('both parties with an opening balance: nothing changes', async()=>{
  const db=await setup(`INSERT INTO lwb_party_opening_balances(customer_name,amount) VALUES ('SHREE DEV TRADING (SACHIN)',1),('SHREE BHERUNATH TREDING-(SACHIN)',2);`);
  await assert.rejects(db.exec(await sql('lwb_party_fix_shree_dev_trading.sql')),/Opening Balance|check failed/);
  await db.exec('ROLLBACK').catch(()=>{});
  assert.equal(await n(db,`SELECT count(*) n FROM orders WHERE customer_name='SHREE DEV TRADING (SACHIN)'`),1);
  assert.equal(await n(db,`SELECT count(*) n FROM lwb_customer_master WHERE id='${DROP}'`),1);
});
