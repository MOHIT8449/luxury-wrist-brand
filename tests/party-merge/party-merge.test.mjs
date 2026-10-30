import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_merge_setup.sql on a tiny copy of the tables it touches (no live database).
const admin='00000000-0000-4000-8000-000000000001',manager='00000000-0000-4000-8000-000000000003';
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid primary key);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
INSERT INTO public.user_profiles VALUES ('${admin}','admin',true,'Mohit'),('${manager}','manager',true,'M');
CREATE TABLE public.lwb_customer_master(id uuid primary key default gen_random_uuid(),customer_code text,customer_name text not null,
  gst_registration_status text,pan text unique,gstin text unique,mobile text,billing_address text,city text,state text,pincode text,
  contact_person text,credit_days int default 0,is_active boolean default true,
  CHECK (gst_registration_status<>'REGISTERED' OR gstin IS NOT NULL));
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,order_date date default current_date);
CREATE TABLE public.lwb_internal_bills(id uuid default gen_random_uuid() primary key,customer_name text);
CREATE TABLE public.lwb_party_opening_balances(id uuid default gen_random_uuid() primary key,customer_name text,amount numeric);
CREATE UNIQUE INDEX ON public.lwb_party_opening_balances(upper(btrim(customer_name)));
CREATE TABLE public.lwb_party_salesman(customer_id uuid primary key references lwb_customer_master(id),salesman_id uuid);
CREATE TABLE public.lwb_party_calls(id serial primary key,customer_id uuid references lwb_customer_master(id),customer_name text);
CREATE TABLE public.lwb_tally_party_map(tally_key text primary key,tally_name text not null,customer_name text,updated_at timestamptz,updated_by uuid);
CREATE FUNCTION public.lwb_party_key(p text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT btrim(regexp_replace(upper(coalesce(p,'')), '[^A-Z0-9]+', ' ', 'g')) $$;
`);
await db.exec(await sql('lwb_party_merge_setup.sql'));
await db.exec(await sql('lwb_party_merge_setup.sql')); // safe to run again
const as=async u=>db.exec(`SELECT set_config('request.jwt.claim.sub','${u}',false)`);
const one=async(q,p)=>(await db.query(q,p)).rows[0];

const keep='10000000-0000-4000-8000-000000000001',drop='10000000-0000-4000-8000-000000000002',other='10000000-0000-4000-8000-000000000003';
await db.exec(`
INSERT INTO lwb_customer_master(id,customer_code,customer_name,gst_registration_status,mobile,state) VALUES
 ('${keep}','CUS-1','AKASH TRADERS (LIMBAYAT)','UNREGISTERED',null,'Gujarat'),
 ('${other}','CUS-3','OTHER PARTY','UNREGISTERED',null,'Gujarat');
INSERT INTO lwb_customer_master(id,customer_code,customer_name,gst_registration_status,gstin,mobile,billing_address,state) VALUES
 ('${drop}','CUS-2','AKASH  TRADERS LIMBAYAT','REGISTERED','24ABCDE1234F1Z5','9876543210','Main road','Gujarat');
INSERT INTO orders(order_no,customer_name) VALUES ('1','akash traders limbayat'),('2','AKASH TRADERS (LIMBAYAT)'),('3','OTHER PARTY');
INSERT INTO lwb_internal_bills(customer_name) VALUES ('AKASH  TRADERS LIMBAYAT');
INSERT INTO lwb_party_opening_balances(customer_name,amount) VALUES ('AKASH TRADERS LIMBAYAT',500);
INSERT INTO lwb_party_salesman VALUES ('${drop}','20000000-0000-4000-8000-000000000001');
INSERT INTO lwb_party_calls(customer_id,customer_name) VALUES ('${drop}','AKASH TRADERS LIMBAYAT');
`);

test('only Admin can merge or read usage', async()=>{
  await as(manager);
  await assert.rejects(db.query(`SELECT lwb_merge_party($1,$2)`,[keep,drop]),/Only an active Admin/);
  await assert.rejects(db.query(`SELECT * FROM lwb_party_usage($1)`,[[keep]]),/Only an active Admin/);
});

test('usage counts POs by name', async()=>{
  await as(admin);
  const r=(await db.query(`SELECT * FROM lwb_party_usage($1) ORDER BY orders`,[[keep,drop,other]])).rows;
  assert.equal(r.length,3);
  assert.equal(Number(r.find(x=>x.customer_id===keep).orders),1);
  assert.equal(Number(r.find(x=>x.customer_id===drop).orders),1); // case and extra spaces do not matter
});

test('merge moves records, copies details, keeps the duplicate as Inactive', async()=>{
  await as(admin);
  await assert.rejects(db.query(`SELECT lwb_merge_party($1,$1)`,[keep]),/two different/);
  const res=(await one(`SELECT lwb_merge_party($1,$2) r`,[keep,drop])).r;
  assert.equal(res.kept,'AKASH TRADERS (LIMBAYAT)');
  assert.equal(Number((await one(`SELECT count(*) n FROM orders WHERE customer_name='AKASH TRADERS (LIMBAYAT)'`)).n),2);
  assert.equal((await one(`SELECT customer_name FROM lwb_internal_bills`)).customer_name,'AKASH TRADERS (LIMBAYAT)');
  assert.equal((await one(`SELECT customer_name FROM lwb_party_opening_balances`)).customer_name,'AKASH TRADERS (LIMBAYAT)');
  assert.equal((await one(`SELECT customer_id FROM lwb_party_salesman`)).customer_id,keep);
  assert.deepEqual(await one(`SELECT customer_id,customer_name FROM lwb_party_calls`),{customer_id:keep,customer_name:'AKASH TRADERS (LIMBAYAT)'});
  assert.equal(Number((await one(`SELECT count(*) n FROM lwb_tally_party_map`)).n),0); // same Tally key, no link needed
  const k=await one(`SELECT * FROM lwb_customer_master WHERE id=$1`,[keep]);
  assert.equal(k.mobile,'9876543210');assert.equal(k.gstin,'24ABCDE1234F1Z5');assert.equal(k.gst_registration_status,'REGISTERED');assert.equal(k.is_active,true);
  const d=await one(`SELECT * FROM lwb_customer_master WHERE id=$1`,[drop]);
  assert.equal(d.is_active,false);assert.equal(d.merged_into,keep);assert.equal(d.gstin,null);assert.equal(d.customer_name,'AKASH  TRADERS LIMBAYAT');
  assert.equal(Number((await one(`SELECT count(*) n FROM lwb_party_merges`)).n),1);
  assert.equal(Number((await one(`SELECT count(*) n FROM orders WHERE customer_name='OTHER PARTY'`)).n),1);
  await assert.rejects(db.query(`SELECT lwb_merge_party($1,$2)`,[other,drop]),/already merged/);
  await assert.rejects(db.query(`SELECT lwb_merge_party($1,$2)`,[drop,other]),/already merged into another/);
});

test('salesman of the kept party is kept; two opening balances are refused', async()=>{
  await as(admin);
  const a='10000000-0000-4000-8000-00000000000a',b='10000000-0000-4000-8000-00000000000b';
  await db.exec(`INSERT INTO lwb_customer_master(id,customer_name,gst_registration_status) VALUES ('${a}','RAJ STORE','UNREGISTERED'),('${b}','RAJ STORES','UNREGISTERED');
    INSERT INTO lwb_party_salesman VALUES ('${a}','20000000-0000-4000-8000-00000000000a'),('${b}','20000000-0000-4000-8000-00000000000b');
    INSERT INTO lwb_party_opening_balances(customer_name,amount) VALUES ('RAJ STORE',1),('RAJ STORES',2);`);
  await assert.rejects(db.query(`SELECT lwb_merge_party($1,$2)`,[a,b]),/Both parties have an Opening Balance/);
  await db.exec(`UPDATE lwb_party_opening_balances SET customer_name='RAJ STORES X' WHERE customer_name='RAJ STORES'`);
  const res=(await one(`SELECT lwb_merge_party($1,$2) r`,[a,b])).r;
  assert.deepEqual(res.kept_own,['lwb_party_salesman.customer_id']);
  assert.equal((await one(`SELECT customer_name FROM lwb_tally_party_map WHERE tally_key='RAJ STORES'`)).customer_name,'RAJ STORE');
  assert.equal((await one(`SELECT salesman_id FROM lwb_party_salesman WHERE customer_id=$1`,[a])).salesman_id,'20000000-0000-4000-8000-00000000000a');
});
