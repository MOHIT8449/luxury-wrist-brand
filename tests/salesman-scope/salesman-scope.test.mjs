import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_salesman_party_scope_setup.sql on an empty PGlite database (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  nadim:'00000000-0000-4000-8000-000000000003',harsh:'00000000-0000-4000-8000-000000000004',
  newsm:'00000000-0000-4000-8000-000000000005',office:'00000000-0000-4000-8000-000000000006',
  acc:'00000000-0000-4000-8000-000000000007'};
const roles={admin:'admin',head:'manager',nadim:'sales',harsh:'sales',newsm:'SALES',office:'sales',acc:'accounts'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE SCHEMA storage;
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(id serial,bucket_id text,name text);
CREATE FUNCTION storage.foldername(text) RETURNS text[] LANGUAGE sql AS $$ SELECT string_to_array($1,'/') $$;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.lwb_customer_master(id uuid default gen_random_uuid() primary key,customer_name text,city text,mobile text,is_active boolean default true,order_every_days int);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text,order_date timestamptz default now(),total_amount numeric,created_by uuid);
CREATE TABLE public.order_items(id uuid default gen_random_uuid() primary key,order_id uuid,sku_name text,rate numeric);
CREATE TABLE public.sku_master(id serial primary key,sku_name text,category text,is_active boolean default true);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,created_at timestamptz default now());
CREATE TABLE public.tax_invoices(id uuid default gen_random_uuid() primary key,order_id uuid,invoice_no text);
CREATE TABLE public.sales_returns(id uuid default gen_random_uuid() primary key,order_id uuid,return_no text);
CREATE TABLE public.sales_return_items(id uuid default gen_random_uuid() primary key,sales_return_id uuid,qty numeric);
CREATE TABLE public.lwb_payment_collections(id uuid default gen_random_uuid() primary key,invoice_id uuid,amount numeric,submitted_by uuid);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA public TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3,null)',[id,roles[k],'Name '+k]);
const load=async f=>{const s=await readFile(new URL('../../'+f,import.meta.url),'utf8');await db.exec(s)};
await load('lwb_sales_team_setup.sql');
await load('lwb_order_entry_rules_setup.sql');
await load('lwb_complaint_box_setup.sql');
await load('lwb_party_salesman_assign_setup.sql');
// Harsh already set up (had a party); Office salesman set as OFFICE; Nadim and newsm never set up.
await db.query("insert into lwb_salesmen(user_id,kind) values($1,'FIELD'),($2,'OFFICE')",[ids.harsh,ids.office]);
await load('lwb_salesman_party_scope_setup.sql');
await load('lwb_salesman_party_scope_setup.sql'); // safe to run again
await load('lwb_sales_head_in_team_setup.sql');await load('lwb_sales_head_in_team_setup.sql');

const P=(await db.query(`insert into lwb_customer_master(customer_name,city) values('NADIM SHOP','SURAT'),('HARSH SHOP','BARDOLI'),('OFFICE SHOP','SURAT') returning id`)).rows.map(r=>r.id);
const O=(await db.query(`insert into orders(order_no,customer_name,status,created_by) values('LXY-00001','NADIM SHOP','approved',$1),('LXY-00002','HARSH SHOP','approved',$2),('LXY-00003','OFFICE SHOP','approved',$3) returning id`,[ids.admin,ids.admin,ids.admin])).rows.map(r=>r.id);
const I=(await db.query(`insert into tax_invoices(order_id,invoice_no) values($1,'T1'),($2,'T2'),($3,'T3') returning id`,O)).rows.map(r=>r.id);
const R=(await db.query(`insert into sales_returns(order_id,return_no) values($1,'R1'),($2,'R2') returning id`,[O[0],O[1]])).rows.map(r=>r.id);
await db.query(`insert into sales_return_items(sales_return_id,qty) values($1,1),($2,2)`,R);
await db.query(`insert into lwb_payment_collections(invoice_id,amount,submitted_by) values($1,10,$3),($2,20,$4)`,[I[0],I[1],ids.admin,ids.admin]);

async function run(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('SET ROLE authenticated');
  try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}
}

test('every SALES login is in lwb_salesmen; OFFICE stays OFFICE; new SALES login added by itself', async()=>{
  const k=async who=>(await db.query('select kind from lwb_salesmen where user_id=$1',[ids[who]])).rows[0]?.kind;
  assert.equal(await k('nadim'),'FIELD');assert.equal(await k('newsm'),'FIELD');
  assert.equal(await k('harsh'),'FIELD');assert.equal(await k('office'),'OFFICE');
  assert.equal(await k('acc'),undefined);
  const nid='00000000-0000-4000-8000-000000000099';
  await db.query("insert into user_profiles values($1,'sales',true,'Brand New',null)",[nid]);
  assert.equal((await db.query('select kind from lwb_salesmen where user_id=$1',[nid])).rows[0].kind,'FIELD');
  await db.query("update user_profiles set role='sales' where id=$1",[ids.acc]);
  assert.equal((await db.query('select kind from lwb_salesmen where user_id=$1',[ids.acc])).rows[0].kind,'FIELD');
  await db.query("update user_profiles set role='accounts' where id=$1",[ids.acc]);
  await db.query('delete from lwb_salesmen where user_id=$1',[ids.acc]);
  const team=(await run('head','select full_name,kind from lwb_sales_team()')).rows.map(r=>r.full_name+':'+r.kind);
  assert.ok(team.includes('Name nadim:FIELD')&&team.includes('Name newsm:FIELD'));
});

test('SKU visibility, targets and plan note save for any SALES login; not for other roles', async()=>{
  await run('head',"select lwb_set_sku_visibility('Coke 1L','ONLY',$1)",[[ids.nadim,ids.harsh]]);
  assert.equal((await db.query("select count(*)::int n from lwb_sku_salesman_rules where sku_key='COKE 1L'")).rows[0].n,2);
  await assert.rejects(run('head',"select lwb_set_sku_visibility('Coke 1L','ONLY',$1)",[[ids.acc]]),/not a SALES login/);
  await run('head',"select lwb_save_sales_targets('2026-11-01',$1)",[JSON.stringify([{salesman_id:ids.newsm,target_amount:1000}])]);
  await run('head',"select lwb_add_sales_plan_note('2026-11-02',$1,'Push Coke')",[ids.nadim]);
  await assert.rejects(run('nadim',"select lwb_set_sku_visibility('X','ALL',null)"),/Admin or Sales Head/);
});

test('field salesman sees only his parties, orders, invoices, returns and collections', async()=>{
  await run('head','select lwb_assign_parties($1,$2)',[[P[0]],ids.nadim]);
  await run('head','select lwb_assign_parties($1,$2)',[[P[1]],ids.harsh]);
  const names=async(who,q)=>(await run(who,q)).rows.map(r=>Object.values(r)[0]).sort();
  assert.deepEqual(await names('nadim','select customer_name from lwb_customer_master'),['NADIM SHOP']);
  assert.deepEqual(await names('nadim','select customer_name from orders'),['NADIM SHOP']);
  assert.deepEqual(await names('nadim','select invoice_no from tax_invoices'),['T1']);
  assert.deepEqual(await names('nadim','select return_no from sales_returns'),['R1']);
  assert.deepEqual(await names('nadim','select qty::int from sales_return_items'),[1]);
  assert.deepEqual(await names('nadim','select amount::int from lwb_payment_collections'),[10]);
  assert.deepEqual(await names('nadim','select customer_name from lwb_party_activity()'),['NADIM SHOP']);
  // not-set-up-yet salesman with no party sees nothing
  assert.deepEqual(await names('newsm','select customer_name from lwb_customer_master'),[]);
  assert.deepEqual(await names('newsm','select invoice_no from tax_invoices'),[]);
  // Office salesman, Admin and Accounts keep everything
  assert.equal((await run('office','select * from tax_invoices')).rows.length,3);
  assert.equal((await run('admin','select * from lwb_customer_master')).rows.length,3);
  assert.equal((await run('acc','select * from lwb_payment_collections')).rows.length,2);
  assert.equal((await run('acc','select * from sales_return_items')).rows.length,2);
});

test('complaint: field salesman can name only his own party and PO', async()=>{
  await assert.rejects(run('nadim','select lwb_complaint_add($1)',[{category:'MARKET',subject:'x',party_name:'harsh shop'}]),/your own parties/);
  await assert.rejects(run('nadim','select lwb_complaint_add($1)',[{category:'MARKET',subject:'x',order_no:'lxy-00002'}]),/not one of your orders/);
  const id=(await run('nadim','select lwb_complaint_add($1) v',[{category:'MARKET',subject:'rate high',party_name:'Nadim Shop',order_no:'lxy-00001'}])).rows[0].v;
  const c=(await db.query('select party_name,order_no from lwb_complaints where id=$1',[id])).rows[0];
  assert.equal(c.party_name,'Nadim Shop');assert.equal(c.order_no,'LXY-00001');
  // Office salesman / Godown etc. unchanged
  await run('office','select lwb_complaint_add($1)',[{category:'MARKET',subject:'x',party_name:'HARSH SHOP'}]);
  await run('acc','select lwb_complaint_add($1)',[{category:'ACCOUNTS',subject:'x',party_name:'Any party'}]);
});

test('Sales Head shows in the team, can get parties / targets as OFFICE, still sees every party', async()=>{
  const team=(await run('admin','select full_name,role from lwb_sales_team()')).rows;
  assert.equal(team[0].role,'manager');assert.ok(team.some(r=>r.full_name==='Name head'));
  assert.ok(!team.some(r=>r.role==='accounts'));
  await run('admin','select lwb_assign_parties($1,$2)',[[P[2]],ids.head]);
  assert.equal((await db.query('select kind from lwb_salesmen where user_id=$1',[ids.head])).rows[0].kind,'OFFICE');
  await run('admin',"select lwb_save_salesman($1,'FIELD','Rajnigandha')",[ids.head]);
  assert.equal((await db.query('select kind from lwb_salesmen where user_id=$1',[ids.head])).rows[0].kind,'OFFICE');
  await run('admin',"select lwb_save_sales_targets('2026-11-01',$1)",[JSON.stringify([{salesman_id:ids.head,target_amount:5000}])]);
  assert.equal((await run('head','select * from lwb_customer_master')).rows.length,3);
  await assert.rejects(run('admin','select lwb_assign_parties($1,$2)',[[P[2]],ids.acc]),/not an active Salesman or Sales Head/);
});
