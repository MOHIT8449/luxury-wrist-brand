import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_bills_to_make_brand_fix.sql on a tiny copy of the tables it reads (no live database).
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
const acc='00000000-0000-4000-8000-000000000002';
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
CREATE FUNCTION public.lwb_tally_staff() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active AND p.role IN ('accounts','admin')) $$;
CREATE TABLE public.lwb_companies(id uuid primary key,name text);
CREATE TABLE public.sku_master(id uuid default gen_random_uuid() primary key,sku_name text,company_id uuid,is_active boolean default true);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text,order_date date default current_date,approved_at timestamptz,priority text);
CREATE TABLE public.order_items(order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,rate numeric);
CREATE TABLE public.dispatch_assignments(order_id uuid,vehicle_no text,driver_name text);
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key,invoice_no text);
`);
// SKU alias table + word key from lwb_sku_alias_setup.sql
const al=await sql('lwb_sku_alias_setup.sql');
const cut=(s,a,b)=>s.slice(s.indexOf(a),s.indexOf(b,s.indexOf(a)));
await db.exec(cut(al,'CREATE TABLE IF NOT EXISTS public.lwb_sku_alias','CREATE INDEX'));
await db.exec(cut(al,'CREATE OR REPLACE FUNCTION public.lwb_sku_words','CREATE OR REPLACE FUNCTION public.lwb_sku_id_of'));
const fix=await sql('lwb_bills_to_make_brand_fix.sql');
await db.exec(fix);await db.exec(fix); // safe to run again
await db.query("insert into user_profiles values($1,'accounts',true)",[acc]);

const RG='00000000-0000-4000-8000-0000000000a1',CC='00000000-0000-4000-8000-0000000000b2';
await db.query("insert into lwb_companies values($1,'RAJNIGANDHA'),($2,'COCA-COLA')",[RG,CC]);
const sku=async(n,c)=>(await db.query('insert into sku_master(sku_name,company_id) values($1,$2) returning id',[n,c])).rows[0].id;
const s1=await sku('2.2GM 10/- BOX MRP 540',RG);await sku('250ML THUMS UP MRP 10',CC);
await db.query("insert into lwb_sku_alias(alias_key,sku_id) values('RG 2.2 GM OLD NAME',$1)",[s1]);
const po=async(no,status,...names)=>{const id=(await db.query('insert into orders(order_no,customer_name,status,approved_at) values($1,$2,$3,now()) returning id',[no,'KISMAT',status])).rows[0].id;
  for(const n of names)await db.query('insert into order_items values($1,$2,10,10,447)',[id,n]);return id};
const co=async id=>(await db.query('select public.lwb_order_company($1) c',[id])).rows[0].c;

test('brand of a PO: exact, renamed (alias), words in another order, extra spaces',async()=>{
  assert.equal(await co(await po('A','loaded','2.2GM 10/- BOX MRP 540')),RG);
  assert.equal(await co(await po('B','loaded','rg 2.2 gm old name')),RG);
  assert.equal(await co(await po('C','loaded','BOX MRP 540 2.2GM 10/-')),RG);
  assert.equal(await co(await po('D','loaded','2.2GM  10/-   BOX MRP 540')),RG);
});
test('two brands or unknown SKU = no brand; unknown line next to a known one keeps the brand',async()=>{
  assert.equal(await co(await po('E','loaded','2.2GM 10/- BOX MRP 540','250ML THUMS UP MRP 10')),null);
  assert.equal(await co(await po('F','loaded','SOMETHING NEW')),null);
  assert.equal(await co(await po('G','loaded','SOMETHING NEW','MRP 10 THUMS UP 250ML')),CC);
});
test('approved POs not loaded yet come with their brand',async()=>{
  const id=await po('H','approved','BOX MRP 540 2.2GM 10/-');
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[acc]);
  const j=(await db.query('select public.lwb_bills_before_loading() j')).rows[0].j;
  const h=j.find(x=>x.order_id===id);
  assert.equal(h.company_id,RG);assert.equal(Number(h.erp_amount),4470);
  await db.query("insert into lwb_tally_invoices values($1,'9')",[id]);
  assert.ok(!(await db.query('select public.lwb_bills_before_loading() j')).rows[0].j.some(x=>x.order_id===id));
});
