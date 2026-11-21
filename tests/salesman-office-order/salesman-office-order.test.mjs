import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_salesman_office_order_hide_setup.sql on an empty PGlite database (no live data).
// Nadim = field salesman of NADIM SHOP. Office (Sales Head) also takes orders for NADIM SHOP.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  nadim:'00000000-0000-4000-8000-000000000003',harsh:'00000000-0000-4000-8000-000000000004',
  office:'00000000-0000-4000-8000-000000000006'};
const roles={admin:'admin',head:'manager',nadim:'sales',harsh:'sales',office:'sales'};
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
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text,order_date timestamptz default now(),created_at timestamptz default now(),
  total_qty numeric,total_amount numeric,created_by uuid,cancel_reason text,cancelled_at timestamptz);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,rate numeric,ordered_qty numeric,approved_qty numeric,loaded_qty numeric,entry_uom text,ordered_pallet_qty numeric);
CREATE TABLE public.sku_master(id serial primary key,sku_name text,category text,is_active boolean default true,company_id uuid);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,created_at timestamptz default now());
CREATE TABLE public.dispatch_assignments(id bigserial primary key,order_id uuid,driver_name text,vehicle_no text);
CREATE TABLE public.lwb_delivery_reports(order_id uuid,delivery_status text,reported_at timestamptz,received_by text,delivery_note text);
CREATE TABLE public.lwb_admin_order_marks(order_id uuid,kind text,mark_date date,marked_at timestamptz,note text);
CREATE TABLE public.lwb_rate_packs(id serial primary key,pack_name text,slab3_rate numeric,active boolean default true);
CREATE TABLE public.lwb_rate_pack_skus(sku_key text,pack_id int);
CREATE TABLE public.lwb_rate_history(id serial primary key,created_at timestamptz default now(),rows jsonb);
CREATE FUNCTION public.lwb_order_pending(p_status text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(lower(btrim(p_status)),'') IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new') $$;
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA public TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3,null)',[id,roles[k],'Name '+k]);
const load=async f=>{const s=await readFile(new URL('../../'+f,import.meta.url),'utf8');await db.exec(s)};
await load('lwb_sales_team_setup.sql');
await load('lwb_order_entry_rules_setup.sql');
await load('lwb_party_rate_history_setup.sql');
await load('lwb_po_line_history_accounts_setup.sql');
await db.query("insert into lwb_salesmen(user_id,kind) values($1,'FIELD'),($2,'FIELD'),($3,'OFFICE') on conflict (user_id) do update set kind=excluded.kind",[ids.nadim,ids.harsh,ids.office]);
await load('lwb_salesman_office_order_hide_setup.sql');
await load('lwb_salesman_office_order_hide_setup.sql'); // safe to run again

const BR='11111111-1111-4111-8111-111111111111';
await db.query("insert into sku_master(sku_name,company_id) values('COKE 1L',$1),('FANTA 1L',$1)",[BR]);
const P=(await db.query(`insert into lwb_customer_master(customer_name,city) values('NADIM SHOP','SURAT'),('HARSH SHOP','BARDOLI') returning id`)).rows.map(r=>r.id);
// own PO (Nadim), office PO for Nadim's party (Sales Head), office PO for Harsh's party
const O=(await db.query(`insert into orders(order_no,customer_name,status,total_qty,total_amount,created_by,order_date) values
  ('LXY-1','NADIM SHOP','approved',10,5000,$1,now()-interval '2 days'),('LXY-2','NADIM SHOP','approved',20,9000,$2,now()-interval '1 day'),
  ('LXY-3','HARSH SHOP','approved',5,2500,$2,now()) returning id`,[ids.nadim,ids.head])).rows.map(r=>r.id);
await db.query(`insert into order_items(order_id,sku_name,rate,ordered_qty,approved_qty) values
  ($1,'COKE 1L',500,10,10),($2,'COKE 1L',450,20,20),($3,'FANTA 1L',500,5,5)`,O);
await db.query(`insert into dispatch_assignments(order_id,driver_name,vehicle_no) values($1,'Ramesh','GJ05AB1234')`,[O[1]]);

async function run(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('SET ROLE authenticated');
  try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}
}

test('field salesman: office PO of his party = header only, no SKU lines / rate', async()=>{
  await run('head','select lwb_assign_parties($1,$2)',[[P[0]],ids.nadim]);
  await run('head','select lwb_assign_parties($1,$2)',[[P[1]],ids.harsh]);
  const orders=(await run('nadim','select order_no,total_qty::int q,total_amount::int a from orders order by order_no')).rows;
  assert.deepEqual(orders.map(o=>o.order_no),['LXY-1','LXY-2']);           // totals of the office PO still readable
  assert.equal(orders[1].a,9000);assert.equal(orders[1].q,20);
  const items=(await run('nadim','select order_id,rate::int r from order_items')).rows;
  assert.deepEqual(items.map(i=>i.r),[500]);                                 // only his own PO's line
  assert.equal(items[0].order_id,O[0]);
  // Admin, Sales Head and an OFFICE salesman keep every line
  assert.equal((await run('head','select * from order_items')).rows.length,3);
  assert.equal((await run('admin','select * from order_items')).rows.length,3);
  assert.equal((await run('office','select * from order_items')).rows.length,3);
});

test('My Orders: office PO gives only total qty, total amount, status', async()=>{
  const list=(await run('nadim','select lwb_my_orders(45) v')).rows[0].v;
  assert.deepEqual(list.map(o=>o.order_no),['LXY-2','LXY-1']);
  const off=list[0],own=list[1];
  assert.equal(off.office,true);assert.equal(off.mine,false);assert.equal(off.can_edit,false);
  assert.equal(Number(off.total_amount),9000);assert.equal(Number(off.total_qty),20);
  assert.deepEqual(off.items,[]);assert.deepEqual(off.brands,[BR]);
  for(const k of ['driver_name','vehicle_no','received_by','delivery_note','cancel_reason'])assert.ok(!(k in off),k+' must not be sent');
  assert.equal(JSON.stringify(off).includes('450'),false);
  assert.equal(own.mine,true);assert.equal(own.items.length,1);assert.equal(Number(own.items[0].rate),500);
  // Harsh: only his own party's PO (office, totals only), nothing of Nadim's party
  const hs=(await run('harsh','select lwb_my_orders(45) v')).rows[0].v;
  assert.deepEqual(hs.map(o=>o.order_no+':'+o.office),['LXY-3:true']);
  // OFFICE salesman: only POs he took himself (none here)
  assert.deepEqual((await run('office','select lwb_my_orders(45) v')).rows[0].v,[]);
});

test('PO Entry rates: field salesman never gets the office rate', async()=>{
  const last=(await run('nadim',"select lwb_party_last_rates('NADIM SHOP') v")).rows[0].v;
  assert.equal(last.length,1);assert.equal(Number(last[0].rate),500);assert.equal(last[0].order_no,'LXY-1');
  const hist=(await run('nadim',"select lwb_party_sku_rate_history('NADIM SHOP','COKE 1L') v")).rows[0].v;
  assert.deepEqual(hist.map(h=>h.order_no),['LXY-1']);
  const ln=(await run('nadim',"select lwb_po_line_history($1,'COKE 1L') v",[O[0]])).rows[0].v;
  assert.deepEqual(ln,[]);
  // Sales Head still sees both rates
  const h=(await run('head',"select lwb_party_sku_rate_history('NADIM SHOP','COKE 1L') v")).rows[0].v;
  assert.deepEqual(h.map(x=>Number(x.rate)),[450,500]);
  // other party: nothing
  assert.deepEqual((await run('nadim',"select lwb_party_last_rates('HARSH SHOP') v")).rows[0].v,[]);
});
