import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_brands_setup.sql on PGlite with stand-in tables (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002'};
const RG='c0000000-0000-4000-8000-000000000001',CC='c0000000-0000-4000-8000-000000000002',NOPE='c0000000-0000-4000-8000-000000000009';
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.lwb_companies(id uuid primary key,name text);
INSERT INTO lwb_companies VALUES ('${RG}','RAJNIGANDHA'),('${CC}','COCA-COLA');
CREATE SEQUENCE public.cus_seq;
CREATE TABLE public.lwb_customer_master(id uuid default gen_random_uuid() primary key,
  customer_code text default 'CUS-'||lpad(nextval('public.cus_seq')::text,6,'0'),
  customer_name text not null,gst_registration_status text,pan text,gstin text,billing_address text,city text,state text,
  mobile text,pincode text,contact_person text,credit_days int default 0,is_active boolean default true,
  kyc_free_orders int,min_order_kg numeric(10,2));
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,created_by uuid);
CREATE TABLE public.order_items(id uuid default gen_random_uuid() primary key,order_id uuid,sku_name text);
CREATE TABLE public.sku_master(id serial primary key,sku_name text);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
INSERT INTO user_profiles VALUES ('${ids.admin}','admin',true,'Admin',null),('${ids.head}','manager',true,'Head',null);
`);
const load=async f=>db.exec(await readFile(new URL('../../'+f,import.meta.url),'utf8'));
await load('lwb_sales_team_setup.sql');
await load('lwb_party_master_save_fix.sql');
await load('lwb_party_brands_setup.sql');
await load('lwb_party_brands_setup.sql'); // safe to run again
async function save(who,id,row){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('SET ROLE authenticated');
  try{return (await db.query('select public.lwb_party_master_save($1,$2::jsonb) id',[id,JSON.stringify(row)])).rows[0].id}finally{await db.exec('RESET ROLE')}
}
const brands=async id=>(await db.query('select brand_ids from lwb_customer_master where id=$1',[id])).rows[0].brand_ids;

test('Admin saves the brands a party sells; unknown ids and repeats are dropped',async()=>{
  const id=await save('admin',null,{customer_name:'RAJNI ONLY PAN',state:'Gujarat',brand_ids:[RG,RG,NOPE]});
  assert.deepEqual(await brands(id),[RG]);
  await save('admin',id,{brand_ids:[CC,RG]});
  assert.deepEqual(await brands(id),[CC,RG]); // ordered by brand name
  await save('admin',id,{brand_ids:[]});
  assert.equal(await brands(id),null);
  await save('admin',id,{brand_ids:[CC]});await save('admin',id,{city:'SURAT'});
  assert.deepEqual(await brands(id),[CC]); // other saves keep it
});

test('Sales Head still cannot save the Party Master',async()=>{
  const id=(await db.query('select id from lwb_customer_master limit 1')).rows[0].id;
  await assert.rejects(save('head',id,{brand_ids:[RG]}),/Only Admin/);
});
