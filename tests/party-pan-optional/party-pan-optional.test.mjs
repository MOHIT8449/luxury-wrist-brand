import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_pan_optional_location_setup.sql: PO Entry "Add new party" without PAN / GSTIN, with shop GPS.
// The real party details rule SQL runs first, as on the live database.
const ids={admin:'00000000-0000-4000-8000-000000000001',sales:'00000000-0000-4000-8000-000000000002'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,customer_name text);
CREATE TABLE public.lwb_sales_settings(id int primary key,updated_at timestamptz,updated_by uuid);
INSERT INTO public.lwb_sales_settings(id) VALUES (1);
CREATE TABLE public.lwb_customer_master(id uuid default gen_random_uuid() primary key,customer_code text,customer_name text,
  gst_registration_status text,pan text,gstin text,billing_address text,city text,state text,pincode text,mobile text,
  credit_days int,is_active boolean);
CREATE TABLE public.lwb_salesmen(user_id uuid primary key,kind text,updated_at timestamptz,updated_by uuid);
CREATE TABLE public.lwb_party_salesman(customer_id uuid primary key,salesman_id uuid,assigned_at timestamptz,assigned_by uuid);
CREATE FUNCTION public.lwb_po_entry_user() RETURNS boolean LANGUAGE sql AS $$ SELECT auth.uid() IS NOT NULL $$;
CREATE FUNCTION public.lwb_is_sales_user() RETURNS boolean LANGUAGE sql AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles WHERE id=auth.uid() AND role='salesman') $$;
CREATE FUNCTION public.lwb_party_visible(uuid) RETURNS boolean LANGUAGE sql AS $$ SELECT true $$;
CREATE FUNCTION public.lwb_sales_head() RETURNS boolean LANGUAGE sql AS $$ SELECT true $$;
INSERT INTO public.user_profiles VALUES ('${ids.admin}','admin',true,'Admin'),('${ids.sales}','salesman',true,'Ravi');
`);
await db.exec(await sql('lwb_party_details_rule_setup.sql'));
const migration=await sql('lwb_party_pan_optional_location_setup.sql');
await db.exec(migration);
await db.exec(migration); // safe to run again
const as=u=>db.exec(`SELECT set_config('request.jwt.claim.sub','${u}',false)`);
const one=async(q,p=[])=>(await db.query(q,p)).rows[0];
const create=(name,pan,gstin,lat,lng)=>one(`SELECT public.lwb_sales_create_party($1,'9548742236','TATITHAIYA','BARDOLI','394305',$2,$3,$4,$5) r`,[name,pan,gstin,lat,lng]);

test('new party saves without PAN / GSTIN and keeps the reminder', async()=>{
  await as(ids.sales);
  const r=(await create('MANISH SINGH GOUR','','',21.1219,73.1121)).r;
  const m=await one(`SELECT * FROM public.lwb_customer_master WHERE id=$1`,[r.id]);
  assert.equal(m.pan,null); assert.equal(m.gst_registration_status,'UNREGISTERED');
  assert.equal(m.geo_lat,21.1219); assert.equal(m.geo_lng,73.1121); assert.ok(m.geo_set_at);
  const k=(await one(`SELECT public.lwb_party_kyc($1) k`,[r.id])).k;
  assert.deepEqual(k.missing,['PAN / GSTIN']); assert.equal(k.has_location,true);
  const n=await one(`SELECT message FROM public.erp_notifications ORDER BY id DESC LIMIT 1`);
  assert.match(n.message,/PAN \/ GSTIN not given yet\. Shop location saved\./);
  assert.equal((await one(`SELECT salesman_id FROM public.lwb_party_salesman WHERE customer_id=$1`,[r.id])).salesman_id,ids.sales);
});

test('mobile and address are still needed; bad PAN and bad GPS refused', async()=>{
  await as(ids.sales);
  await assert.rejects(one(`SELECT public.lwb_sales_create_party('X SHOP','9548742236','','','','','')`),/needs mobile and address/);
  await assert.rejects(create('Y SHOP','ABC','',null,null),/PAN format/);
  await assert.rejects(create('Z SHOP','','',21.1,null),/location is not valid/);
  await assert.rejects(create('Z SHOP','','',0,0),/location is not valid/);
});

test('old 7-argument call (no location) still works', async()=>{
  await as(ids.admin);
  const r=(await one(`SELECT public.lwb_sales_create_party('OLD CALL','9876543210','MAIN ROAD','','','ABCDE1234F','') r`)).r;
  const m=await one(`SELECT pan,geo_lat FROM public.lwb_customer_master WHERE id=$1`,[r.id]);
  assert.equal(m.pan,'ABCDE1234F'); assert.equal(m.geo_lat,null);
});

test('Fill details adds PAN later and location only when none is saved', async()=>{
  await as(ids.sales);
  const id=(await one(`SELECT id FROM public.lwb_customer_master WHERE customer_name='MANISH SINGH GOUR'`)).id;
  const k=(await one(`SELECT public.lwb_sales_fill_party_details($1,'','','','','ABCDE1234F','',22.5,72.9) k`,[id])).k;
  assert.deepEqual(k.missing,[]);
  const m=await one(`SELECT pan,geo_lat FROM public.lwb_customer_master WHERE id=$1`,[id]);
  assert.equal(m.pan,'ABCDE1234F'); assert.equal(m.geo_lat,21.1219); // saved location kept
  const old=(await one(`SELECT id FROM public.lwb_customer_master WHERE customer_name='OLD CALL'`)).id;
  await one(`SELECT public.lwb_sales_fill_party_details($1,'','','','','','',22.5,72.9)`,[old]);
  assert.equal((await one(`SELECT geo_lat FROM public.lwb_customer_master WHERE id=$1`,[old])).geo_lat,22.5);
});

test('missing PAN never stops or counts a salesman order; missing address still does', async()=>{
  await as(ids.sales);
  const r=(await create('NO PAN SHOP','','',null,null)).r;
  for (let i=0;i<5;i++) await db.query(`INSERT INTO public.orders(customer_name) VALUES ('NO PAN SHOP')`);
  assert.equal((await one(`SELECT kyc_orders_used FROM public.lwb_customer_master WHERE id=$1`,[r.id])).kyc_orders_used,0);
  const k=(await one(`SELECT public.lwb_party_kyc($1) k`,[r.id])).k;
  assert.deepEqual(k.missing,['PAN / GSTIN']); assert.deepEqual(k.blocking,[]);
  await db.query(`UPDATE public.lwb_customer_master SET billing_address='' WHERE id=$1`,[r.id]);
  for (let i=0;i<3;i++) await db.query(`INSERT INTO public.orders(customer_name) VALUES ('NO PAN SHOP')`);
  await assert.rejects(db.query(`INSERT INTO public.orders(customer_name) VALUES ('NO PAN SHOP')`),/has no Address\./);
});
