import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_my_orders_delivered_marks_fix.sql on an empty PGlite database (no live data).
const S='00000000-0000-4000-8000-000000000004',A='00000000-0000-4000-8000-000000000001';
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz default now(),created_at timestamptz default now(),
  customer_name text,status text,total_qty numeric,total_amount numeric,created_by uuid,cancel_reason text,cancelled_at timestamptz);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric,rate numeric,entry_uom text,ordered_pallet_qty numeric);
CREATE TABLE public.dispatch_assignments(id bigserial primary key,order_id uuid,driver_name text,vehicle_no text);
CREATE TABLE public.lwb_delivery_reports(order_id uuid,delivery_status text,reported_at timestamptz default now(),received_by text,delivery_note text);
CREATE TABLE public.lwb_admin_order_marks(order_id uuid,kind text,mark_date date,note text,marked_at timestamptz default now());
CREATE FUNCTION public.lwb_is_field_salesman() RETURNS boolean LANGUAGE sql AS $$ SELECT false $$;
CREATE FUNCTION public.lwb_my_party_names() RETURNS SETOF text LANGUAGE sql AS $$ SELECT ''::text WHERE false $$;
CREATE FUNCTION public.lwb_order_pending(s text) RETURNS boolean LANGUAGE sql AS $$ SELECT coalesce(s,'') IN ('','pending') $$;
`);
await db.exec(await readFile(new URL('../../lwb_my_orders_delivered_marks_fix.sql',import.meta.url),'utf8'));
await db.query("select set_config('request.jwt.claim.sub',$1,false)",[S]);
const add=async(no,status,by=S)=>(await db.query(`insert into orders(order_no,customer_name,status,created_by) values($1,'RJ TRADERS',$2,$3) returning id`,[no,status,by])).rows[0].id;

test('driver report, Admin mark and status delivered all count as Delivered',async()=>{
  const rep=await add('P-1','loaded'),mk=await add('P-2','loaded'),st=await add('P-3','delivered'),part=await add('P-4','loaded'),
        not=await add('P-5','loaded'),pend=await add('P-6','pending'),nd=await add('P-7','loaded');
  await add('P-8','loaded',A); // someone else's PO: not shown
  await db.query(`insert into lwb_delivery_reports(order_id,delivery_status,received_by) values($1,'DELIVERED','Ramesh'),($2,'PARTIAL',null),($3,'NOT_DELIVERED',null),($4,'NOT_DELIVERED',null)`,[rep,part,not,nd]);
  await db.query(`insert into lwb_admin_order_marks(order_id,kind,mark_date,note) values($1,'DELIVERED',current_date,null),($2,'DELIVERED',current_date-2,'Delivered by self pickup'),($3,'LOADED',current_date,null)`,[mk,nd,pend]);
  const rows=(await db.query('select lwb_my_orders(45) r')).rows[0].r;
  const by=Object.fromEntries(rows.map(o=>[o.order_no,o]));
  assert.equal(rows.length,7);
  assert.equal(by['P-1'].delivery_status,'DELIVERED');assert.equal(by['P-1'].received_by,'Ramesh');assert.equal(by['P-1'].delivery_marked,false);
  assert.equal(by['P-2'].delivery_status,'DELIVERED');assert.equal(by['P-2'].delivery_marked,true);assert.ok(by['P-2'].delivered_at);
  assert.equal(by['P-2'].delivery_note,'Marked delivered by office');
  assert.equal(by['P-3'].delivery_status,'DELIVERED');assert.equal(by['P-3'].delivery_marked,true);
  assert.equal(by['P-4'].delivery_status,'PARTIAL');
  assert.equal(by['P-5'].delivery_status,'NOT_DELIVERED');
  assert.equal(by['P-6'].delivery_status,null);
  // driver said "not delivered", then office marked it delivered: delivered wins, on the marked date
  assert.equal(by['P-7'].delivery_status,'DELIVERED');assert.equal(by['P-7'].delivery_note,'Delivered by self pickup');
  assert.match(by['P-7'].delivered_at,/T06:30:00/); // mark date 12:00 IST
});
