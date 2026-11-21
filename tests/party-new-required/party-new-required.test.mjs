import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_new_required_setup.sql: "+ New Party" from the PO form needs name, address, mobile; no duplicate name / mobile.
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
CREATE TABLE public.lwb_tracking_settings(id int primary key,godown_lat float8,godown_lng float8);
INSERT INTO public.lwb_tracking_settings(id) VALUES (1);
CREATE FUNCTION public.lwb_geo_m(lat1 float8,lng1 float8,lat2 float8,lng2 float8) RETURNS float8 LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN lat1 IS NULL OR lng1 IS NULL OR lat2 IS NULL OR lng2 IS NULL THEN NULL ELSE
    2*6371000*asin(least(1,sqrt(power(sin(radians(lat2-lat1)/2),2)+cos(radians(lat1))*cos(radians(lat2))*power(sin(radians(lng2-lng1)/2),2)))) END $$;
INSERT INTO public.user_profiles VALUES ('${ids.admin}','admin',true,'Admin'),('${ids.sales}','salesman',true,'Ravi');
`);
await db.exec(await sql('lwb_party_details_rule_setup.sql'));
const migration=await sql('lwb_party_pan_optional_location_setup.sql');
await db.exec(migration);
await db.exec(migration); // safe to run again
const rule=await sql('lwb_party_new_required_setup.sql');
await db.exec(rule); await db.exec(rule); // safe to run again
const as=u=>db.exec(`SELECT set_config('request.jwt.claim.sub','${u}',false)`);
const one=async(q,p=[])=>(await db.query(q,p)).rows[0];
const add=(name,mobile,address)=>one(`SELECT public.lwb_sales_create_party($1,$2,$3,'SURAT','','','') r`,[name,mobile,address]);

test('name, address and mobile are all required', async()=>{
  await as(ids.sales);
  await assert.rejects(add('','9876543210','MAIN ROAD'),/Fill Party name/);
  await assert.rejects(add('RAM STORES','9876543210','  '),/Fill Address/);
  await assert.rejects(add('RAM STORES','','MAIN ROAD'),/Fill Mobile/);
  await assert.rejects(add('','',''),/Fill Party name, Address, Mobile/);
  await assert.rejects(add('RAM STORES','98765','MAIN ROAD'),/10-digit/);
  await assert.rejects(add('RAM STORES','1234567890','MAIN ROAD'),/10-digit/);
});

test('saves with +91 / spaces cleaned and is assigned to the salesman', async()=>{
  await as(ids.sales);
  const r=(await add('ram  stores','+91 98765 43210','MAIN ROAD')).r;
  const m=await one(`SELECT * FROM public.lwb_customer_master WHERE id=$1`,[r.id]);
  assert.equal(m.customer_name,'RAM STORES'); assert.equal(m.mobile,'9876543210'); assert.equal(m.billing_address,'MAIN ROAD');
  assert.equal((await one(`SELECT salesman_id FROM public.lwb_party_salesman WHERE customer_id=$1`,[r.id])).salesman_id,ids.sales);
  const n=await one(`SELECT message FROM public.erp_notifications ORDER BY id DESC LIMIT 1`);
  assert.match(n.message,/Added by Ravi from PO Entry/);
});

test('duplicate name or mobile is refused and names the party', async()=>{
  await as(ids.admin);
  await assert.rejects(add('Ram-Stores','9123456780','X ROAD'),/"RAM STORES" already has this name\. Select it/);
  await assert.rejects(add('SHYAM TRADERS','09876543210','X ROAD'),/"RAM STORES" already has this mobile number 9876543210/);
  const r=(await add('SHYAM TRADERS','9123456780','X ROAD')).r;
  assert.ok(r.id);
});
