import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_cash_sale_party_setup.sql: one CASH SALE party, buyer name + mobile on the PO, always SELF PICKUP,
// never blocked by the party details rule. The real party details SQL runs first, as on the live database.
const ids={admin:'00000000-0000-4000-8000-000000000001',sales:'00000000-0000-4000-8000-000000000002',other:'00000000-0000-4000-8000-000000000003'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,transportation text,created_by uuid);
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
CREATE FUNCTION public.lwb_geo_m(lat1 float8,lng1 float8,lat2 float8,lng2 float8) RETURNS float8 LANGUAGE sql IMMUTABLE AS $$ SELECT NULL::float8 $$;
INSERT INTO public.user_profiles VALUES ('${ids.admin}','admin',true,'Admin'),('${ids.sales}','salesman',true,'Ravi'),('${ids.other}','salesman',true,'Amit');
INSERT INTO public.lwb_customer_master(customer_name,is_active) VALUES ('NO DETAILS STORE',true);
`);
await db.exec(await sql('lwb_party_details_rule_setup.sql'));
await db.exec(await sql('lwb_party_pan_optional_location_setup.sql'));
const setup=await sql('lwb_cash_sale_party_setup.sql');
await db.exec(setup); await db.exec(setup); // safe to run again
const as=u=>db.exec(`SELECT set_config('request.jwt.claim.sub','${u}',false)`);
const one=async(q,p=[])=>(await db.query(q,p)).rows[0];
const order=(party,tp)=>one(`INSERT INTO public.orders(order_no,customer_name,transportation,created_by) VALUES ('PO',$1,$2,auth.uid()) RETURNING *`,[party,tp]);

test('exactly one active CASH SALE party is created', async()=>{
  const r=await one(`SELECT count(*)::int n, min(customer_name) name, bool_and(is_active) active FROM public.lwb_customer_master WHERE is_cash_sale`);
  assert.deepEqual(r,{n:1,name:'CASH SALE',active:true});
});

test('cash sale PO is always SELF PICKUP and never blocked by missing party details', async()=>{
  await as(ids.sales);
  for(let i=0;i<8;i++){
    const o=await order('Cash Sale','DELIVERY');
    assert.equal(o.transportation,'SELF PICKUP');
  }
  // a normal party with no details is still blocked after the free orders
  for(let i=0;i<3;i++) await order('NO DETAILS STORE','DELIVERY');
  await assert.rejects(order('NO DETAILS STORE','DELIVERY'),/Party details missing/);
  assert.equal((await order('NO DETAILS STORE x','DELIVERY')).transportation,'DELIVERY');
});

test('buyer name + mobile saved on the PO, validated, only by its maker or Admin', async()=>{
  await as(ids.sales);
  const o=await order('CASH SALE',null);
  await assert.rejects(one(`SELECT public.lwb_set_order_cash_buyer($1,'','9876543210')`,[o.id]),/buyer name/);
  await assert.rejects(one(`SELECT public.lwb_set_order_cash_buyer($1,'Ramesh','12345')`,[o.id]),/10-digit/);
  const r=(await one(`SELECT public.lwb_set_order_cash_buyer($1,'  ramesh   patel ','+91 98765 43210') r`,[o.id])).r;
  assert.deepEqual(r,{name:'RAMESH PATEL',mobile:'9876543210'});
  const s=await one(`SELECT cash_buyer_name,cash_buyer_mobile FROM public.orders WHERE id=$1`,[o.id]);
  assert.deepEqual(s,{cash_buyer_name:'RAMESH PATEL',cash_buyer_mobile:'9876543210'});
  await as(ids.other);
  await assert.rejects(one(`SELECT public.lwb_set_order_cash_buyer($1,'X Y','9876543210')`,[o.id]),/Only the person/);
  await as(ids.admin);
  assert.ok(await one(`SELECT public.lwb_set_order_cash_buyer($1,'Suresh','9123456780')`,[o.id]));
  const normal=await order('NO DETAILS STORE','DELIVERY');
  await assert.rejects(one(`SELECT public.lwb_set_order_cash_buyer($1,'Suresh','9123456780')`,[normal.id]),/not a Cash Sale/);
});
