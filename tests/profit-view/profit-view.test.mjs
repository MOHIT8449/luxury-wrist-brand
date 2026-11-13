import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_quick_slip + lwb_rajni_rate_limit + lwb_profit_view on an empty PGlite database (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  sales:'00000000-0000-4000-8000-000000000004'};
const roles={admin:'admin',head:'manager',sales:'sales'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.lwb_companies(id uuid default gen_random_uuid() primary key,name text,pack_unit text);
CREATE TABLE public.lwb_user_companies(user_id uuid,company_id uuid);
CREATE TABLE public.sku_master(sku_name text,company_id uuid);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz default now(),
  customer_name text,sales_person text,status text,total_qty numeric,total_amount numeric,created_by uuid,approved_by uuid,approved_at timestamptz);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric default 0,rate numeric);
CREATE TABLE public.dispatch_assignments(order_id uuid);
CREATE TABLE public.lwb_customer_master(customer_name text,mobile text,billing_address text,city text,pincode text,is_active boolean);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false);
CREATE FUNCTION public.lwb_my_companies() RETURNS uuid[] LANGUAGE sql STABLE AS $$ SELECT NULL::uuid[] $$;
CREATE FUNCTION public.lwb_company_ok(p uuid) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT true $$;
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k],k.toUpperCase()]);
const read=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(await read('lwb_quick_slip_setup.sql'));
await db.exec(await read('lwb_rajni_rate_limit_setup.sql'));
const sql=await read('lwb_profit_view_setup.sql');
await db.exec(sql);await db.exec(sql); // safe to run again
// Rate & Scheme tables (only the columns lwb_profit_breakdown_setup.sql reads).
await db.exec(`
ALTER TABLE public.sku_master ADD COLUMN category text;
CREATE TABLE public.lwb_rate_settings(id int primary key,mepd_pct numeric,roi_main numeric,roi_landing numeric);
INSERT INTO public.lwb_rate_settings VALUES (1,1.25,3,5);
CREATE TABLE public.lwb_rate_packs(id uuid default gen_random_uuid() primary key,pack_name text,case_config numeric,gr numeric,
  mepd_pct numeric,free_bottle numeric default 0,oms numeric,qps numeric default 0,slab3_rate numeric default 0,active boolean default true);
CREATE TABLE public.lwb_rate_pack_skus(sku_key text primary key,pack_id uuid);
CREATE TABLE public.lwb_mepd_schemes(categories text[],mepd_pct numeric,valid_from date,valid_to date,note text,created_at timestamptz default now());
`);
const sql2=await read('lwb_profit_breakdown_setup.sql');
await db.exec(sql2);await db.exec(sql2); // safe to run again

async function run(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('SET ROLE authenticated');
  try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}
}
const LIM=[{sku_key:'2.25L THUMS UP MRP 90',landing:640,min_rate:650,std_rate:''},{sku_key:'RG POUCH 10',landing:'',min_rate:330,std_rate:350}];

test('Admin always gets the landing per SKU, never the SKUs without landing', async()=>{
  await run('admin','select public.lwb_price_limits_save($1)',[JSON.stringify(LIM)]);
  const v=(await run('admin','select public.lwb_profit_landing() v')).rows[0].v;
  assert.equal(v.admin,true);
  assert.deepEqual(v.landing,{'2.25L THUMS UP MRP 90':640});
  assert.deepEqual(v.viewers,[]);
});

test('Sales Head and Salesman get nothing until Admin allows them', async()=>{
  assert.equal((await run('head','select public.lwb_profit_landing() v')).rows[0].v,null);
  assert.equal((await run('sales','select public.lwb_profit_landing() v')).rows[0].v,null);
  await assert.rejects(run('head','select public.lwb_price_viewer_set($1,true)',[ids.head]),/Only Admin/);
  await run('admin','select public.lwb_price_viewer_set($1,true)',[ids.head]);
  const h=(await run('head','select public.lwb_profit_landing() v')).rows[0].v;
  assert.equal(h.admin,false);assert.equal(h.landing['2.25L THUMS UP MRP 90'],640);assert.deepEqual(h.viewers,[]);
  assert.deepEqual((await run('admin','select public.lwb_profit_landing() v')).rows[0].v.viewers,[ids.head]);
  assert.equal((await run('sales','select public.lwb_profit_landing() v')).rows[0].v,null);
  await run('admin','select public.lwb_price_viewer_set($1,false)',[ids.head]);
  assert.equal((await run('head','select public.lwb_profit_landing() v')).rows[0].v,null);
});

test('an inactive allowed person gets nothing', async()=>{
  await run('admin','select public.lwb_price_viewer_set($1,true)',[ids.sales]);
  await db.query('update user_profiles set active=false where id=$1',[ids.sales]);
  assert.equal((await run('sales','select public.lwb_profit_landing() v')).rows[0].v,null);
});

test('breakdown parts: pack GR, OMS, QPS, ROI and the MEPD % used today', async()=>{
  const [pa]=(await db.query(`insert into lwb_rate_packs(pack_name,case_config,gr,mepd_pct,oms,qps) values('2.25L',9,700,null,40,5) returning id`)).rows;
  const [pb]=(await db.query(`insert into lwb_rate_packs(pack_name,case_config,gr,mepd_pct,oms,qps) values('250ML',24,520,2,null,4) returning id`)).rows;
  await db.query(`insert into lwb_rate_pack_skus values('2.25L THUMS UP MRP 90',$1),('250ML SPRITE MRP 20',$2)`,[pa.id,pb.id]);
  await db.query(`insert into sku_master(sku_name,category) values('2.25L THUMS UP MRP 90','PET CSD'),('250ML SPRITE MRP 20','  250ml  csd ')`);
  await db.query(`insert into lwb_mepd_schemes values('{250ML CSD}',3.5,current_date-1,current_date+5,'Nov scheme'),('{250ML CSD}',9,current_date-30,current_date-10,'old')`);
  const v=(await run('admin','select public.lwb_profit_landing() v')).rows[0].v;
  const a=v.parts['2.25L THUMS UP MRP 90'],b=v.parts['250ML SPRITE MRP 20'];
  assert.equal(a.pack,'2.25L');assert.equal(Number(a.gr),700);assert.equal(Number(a.oms),40);assert.equal(Number(a.qps),5);assert.equal(Number(a.roi),3);
  assert.equal(Number(a.mepd_pct),1.25);assert.equal(a.mepd_from,'default');
  assert.equal(Number(b.mepd_pct),3.5);assert.equal(b.mepd_from,'scheme');assert.equal(b.scheme_note,'Nov scheme');
  assert.equal(v.landing['2.25L THUMS UP MRP 90'],640); // landing list still there
  assert.equal((await run('head','select public.lwb_profit_landing() v')).rows[0].v,null);
});
