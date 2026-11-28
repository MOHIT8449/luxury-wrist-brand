import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_admin_undo_delivered_setup.sql (after lwb_admin_mark_load_deliver_setup.sql) on an empty PGlite database.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',accounts:'00000000-0000-4000-8000-000000000003'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,full_name text,role text,active boolean);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz default now(),customer_name text,status text,transportation text default 'DELIVERY');
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric default 0,rate numeric);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,vehicle_no text,loading_started_at timestamptz,loading_completed_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(order_id uuid,delivery_status text,cash_reported numeric default 0,reported_at timestamptz default now());
CREATE TABLE public.lwb_tally_invoices(order_id uuid);
CREATE TABLE public.lwb_user_page_access(user_id uuid primary key,hidden text[] not null default '{}',updated_at timestamptz,updated_by uuid);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
GRANT USAGE ON SCHEMA public, auth TO authenticated;
-- like lwb_notify_vehicle_loaded: a bell when status becomes loaded
CREATE FUNCTION public.t_loaded_bell() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN
  IF NEW.status = 'loaded' AND OLD.status IS DISTINCT FROM 'loaded' THEN
    INSERT INTO public.erp_notifications(user_id,title,notification_type,order_id) VALUES ('00000000-0000-4000-8000-000000000003','Vehicle Loaded — Make Tally Bill','TALLY_BILL_PENDING',NEW.id);
  END IF; RETURN NEW; END $$;
CREATE TRIGGER t_loaded_bell AFTER UPDATE OF status ON public.orders FOR EACH ROW EXECUTE FUNCTION public.t_loaded_bell();
`);
await db.query(`insert into user_profiles values($1,'Mohit','admin',true),($2,'Vinesh','manager',true),($3,'Yogesh','accounts',true)`,[ids.admin,ids.head,ids.accounts]);
await db.exec(await readFile(new URL('../../lwb_admin_mark_load_deliver_setup.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../../lwb_admin_undo_delivered_setup.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../../lwb_admin_undo_delivered_setup.sql',import.meta.url),'utf8')); // safe to run again

async function order(no,status='loaded'){
  const id=(await db.query(`insert into orders(order_no,customer_name,status) values($1,'SHREE JAGDISH TRADER',$2) returning id`,[no,status])).rows[0].id;
  await db.query(`insert into order_items(order_id,sku_name,ordered_qty,approved_qty,loaded_qty,rate) values($1,'COKE',10,10,10,100)`,[id]);
  await db.query('insert into dispatch_assignments(order_id,vehicle_no) values($1,$2)',[id,'GJ05AB1234']);
  return id;
}
async function as(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  return db.query(q,params);
}
const today=(await db.query(`select (now() at time zone 'Asia/Kolkata')::date::text d`)).rows[0].d;
const markDelivered=id=>as('admin','select lwb_admin_mark_order($1,true,true,$2::date,null) r',[id,today]);
const undo=(who,id,to,reason='Only loaded, marked delivered by mistake')=>as(who,'select lwb_admin_undo_delivered($1,$2,$3) r',[id,to,reason]).then(x=>x.rows[0].r);

test('only Admin, with a reason, on a delivered PO',async()=>{
  const o=await order('LXY-1');
  await assert.rejects(undo('admin',o,'LOADED'),/not delivered/);
  await markDelivered(o);
  await assert.rejects(undo('head',o,'LOADED'),/Only Admin/);
  await assert.rejects(undo('accounts',o,'LOADED'),/Only Admin/);
  await assert.rejects(undo('admin',o,'LOADED',' '),/reason/);
  await assert.rejects(undo('admin',o,'X'),/Loaded or Out/);
});

test('Delivered mark -> back to Loaded: mark gone, status loaded, log kept, bells read',async()=>{
  const o=await order('LXY-2');
  await markDelivered(o);
  assert.equal((await db.query('select status from orders where id=$1',[o])).rows[0].status,'delivered');
  const r=await undo('admin',o,'LOADED');
  assert.equal(r.status,'loaded');assert.equal(r.mark_removed,true);
  assert.equal((await db.query('select status from orders where id=$1',[o])).rows[0].status,'loaded');
  assert.equal((await db.query(`select count(*)::int n from lwb_admin_order_marks where order_id=$1 and kind='DELIVERED'`,[o])).rows[0].n,0);
  assert.equal((await as('admin','select count(*)::int n from lwb_po_delivered_orders($1)',[[o]])).rows[0].n,0);
  // the bell made by the status change is already read (no phone push)
  assert.equal((await db.query(`select count(*)::int n from erp_notifications where order_id=$1 and is_read=false and title like 'Vehicle Loaded%'`,[o])).rows[0].n,0);
  const log=(await as('accounts','select * from lwb_po_undo_delivered_log($1)',[[o]])).rows;
  assert.equal(log.length,1);assert.equal(log[0].to_step,'LOADED');assert.equal(log[0].undone_by_name,'Mohit');assert.equal(log[0].was_marked_by,'Mohit');
  // it can be marked Delivered again later
  await markDelivered(o);
  assert.equal((await db.query('select status from orders where id=$1',[o])).rows[0].status,'delivered');
});

test('Out for delivery needs the Tally bill',async()=>{
  const o=await order('LXY-3');
  await markDelivered(o);
  await assert.rejects(undo('admin',o,'OUT'),/no Tally bill/);
  await db.query('insert into lwb_tally_invoices values($1)',[o]);
  const r=await undo('admin',o,'OUT');
  assert.equal(r.to,'OUT');
  assert.equal((await db.query('select count(*)::int n from lwb_po_out_delivery where order_id=$1',[o])).rows[0].n,1);
  // Loaded removes Out for delivery
  await markDelivered(o);
  await undo('admin',o,'LOADED');
  assert.equal((await db.query('select count(*)::int n from lwb_po_out_delivery where order_id=$1',[o])).rows[0].n,0);
});

test('driver report: removed when no money, refused with money',async()=>{
  const o=await order('LXY-4');
  await db.query(`insert into lwb_delivery_reports(order_id,delivery_status) values($1,'DELIVERED')`,[o]);
  const r=await undo('admin',o,'LOADED');
  assert.equal(r.report_removed,true);
  assert.equal((await db.query('select count(*)::int n from lwb_delivery_reports where order_id=$1',[o])).rows[0].n,0);
  assert.equal((await db.query('select report_before is not null b from lwb_po_undo_delivered where order_id=$1',[o])).rows[0].b,true);
  const o2=await order('LXY-5');
  await db.query(`insert into lwb_delivery_reports(order_id,delivery_status,cash_reported) values($1,'DELIVERED',5000)`,[o2]);
  await assert.rejects(undo('admin',o2,'LOADED'),/driver money/);
});
