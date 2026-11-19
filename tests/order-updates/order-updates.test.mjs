import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_order_updates_everyone_setup.sql on an empty PGlite database (no live data).
const ADMIN='00000000-0000-4000-8000-000000000001',HEAD='00000000-0000-4000-8000-000000000002',
  SALES='00000000-0000-4000-8000-000000000004',FIELD='00000000-0000-4000-8000-000000000005',
  ACC='00000000-0000-4000-8000-000000000006',DRV='00000000-0000-4000-8000-000000000007';
const db=new PGlite();
const gps=await readFile(new URL('../../lwb_driver_background_tracking_setup.sql',import.meta.url),'utf8');
// The live salesman-bell guard (13 Nov 2026), exactly as in lwb_driver_background_tracking_setup.sql.
const guard=gps.slice(gps.indexOf('CREATE OR REPLACE FUNCTION public.lwb_sales_order_alert'),gps.indexOf('CREATE OR REPLACE FUNCTION public.lwb_no_sales_updates'));
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,full_name text,role text,active boolean default true);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz default now(),created_at timestamptz default now(),
  customer_name text,status text,total_qty numeric,total_amount numeric,created_by uuid);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,driver_name text,driver_mobile text,vehicle_no text);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid unique,assignment_id uuid,driver_user_id uuid,
  delivery_status text not null,received_by text,pod_path text,delivery_note text,cash_reported numeric not null default 0,payment_mode text,
  collection_review_status text not null default 'NO_COLLECTION',reported_at timestamptz not null default now(),payment_status text);
CREATE TABLE public.lwb_admin_order_marks(order_id uuid,kind text,mark_date date,old_status text,note text,marked_by uuid,marked_by_name text,
  marked_at timestamptz default now(),marked_by_role text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,
  is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.lwb_customer_master(id uuid default gen_random_uuid() primary key,customer_name text);
CREATE TABLE public.lwb_party_salesman(salesman_id uuid,customer_id uuid);
${guard}
-- Daily Report function with the same delivery / pending lines as the live one (patched by the setup file).
CREATE FUNCTION public.lwb_daily_summary(p_date date DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE d date := coalesce(p_date, timezone('Asia/Kolkata', now())::date); r jsonb;
BEGIN
  WITH dr AS (
    SELECT dr.*, o.order_no, coalesce(a.driver_name,'Driver') AS driver
    FROM public.lwb_delivery_reports dr
    JOIN public.orders o ON o.id = dr.order_id
    LEFT JOIN public.dispatch_assignments a ON a.id = dr.assignment_id
    WHERE timezone('Asia/Kolkata', dr.reported_at)::date = d
  ),
  pend AS (
    SELECT count(*) AS n FROM public.orders o
    WHERE lower(o.status) IN ('loaded')
      AND NOT EXISTS (SELECT 1 FROM public.lwb_delivery_reports x WHERE x.order_id = o.id)
  )
  SELECT jsonb_build_object(
    'delivered', (SELECT count(*) FROM dr WHERE delivery_status = 'DELIVERED'),
    'not_delivered', (SELECT count(*) FROM dr WHERE delivery_status = 'NOT_DELIVERED'),
    'drivers', (SELECT jsonb_agg(driver ORDER BY order_no) FROM dr),
    'pending', (SELECT n FROM pend)) INTO r;
  RETURN r;
END;
$fn$;
INSERT INTO user_profiles VALUES ('${ADMIN}','Mohit','admin',true),('${HEAD}','Head','manager',true),('${SALES}','Ravi','sales',true),
  ('${FIELD}','Field','salesman',true),('${ACC}','Acc','accounts',true),('${DRV}','Driver','driver',true);
`);
await db.exec(await readFile(new URL('../../lwb_order_updates_everyone_setup.sql',import.meta.url),'utf8'));
// Sales Head copy trigger as live (lwb_loading_workflow_setup.sql), on the function the setup file replaced.
await db.exec(`CREATE CONSTRAINT TRIGGER trg_lwb_notify_sales_head_copy AFTER INSERT ON public.erp_notifications
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.lwb_notify_sales_head_copy();`);
const as=u=>db.query("select set_config('request.jwt.claim.sub',$1,false)",[u]);
const bells=async(id)=>(await db.query(`select n.user_id,p.role,n.notification_type t,n.message from erp_notifications n join user_profiles p on p.id=n.user_id
  where n.order_id=$1 order by p.role,n.notification_type`,[id])).rows;
const party=(await db.query(`insert into lwb_customer_master(customer_name) values('RJ TRADERS') returning id`)).rows[0].id;
await db.query(`insert into lwb_party_salesman values($1,$2)`,[FIELD,party]);
let no=0;
const order=async(status='pending',by=SALES)=>{await as(by);return (await db.query(`insert into orders(order_no,customer_name,status,total_qty,total_amount,created_by)
  values($1,'RJ Traders',$2,15,12000,$3) returning id`,['LXY-'+(100+ ++no),status,by])).rows[0].id};

test('salesman bells are no longer dropped; live tracking ones still are',async()=>{
  await db.query(`insert into erp_notifications(user_id,title,message,notification_type,order_id) values
    ($1,'x','LXY-1 · RJ','TALLY_BILL_DONE',gen_random_uuid()),($1,'x','gps','LIVE_GPS',null),($1,'x','veh','LOADING_ASSIGNMENT_DRIVER',gen_random_uuid())`,[SALES]);
  const t=(await db.query(`select notification_type t from erp_notifications where user_id=$1 order by 1`,[SALES])).rows.map(r=>r.t);
  assert.deepEqual(t,['TALLY_BILL_DONE']);
  await db.query(`delete from erp_notifications`);
});

test('PO approved and loaded: salesman who took it + party field salesman are told, once',async()=>{
  const id=await order();
  await as(HEAD);
  await db.query(`update orders set status='approved' where id=$1`,[id]);
  await db.query(`update orders set status='pending_approval' where id=$1`,[id]); // back for rate approval
  await as(ADMIN);
  await db.query(`update orders set status='approved' where id=$1`,[id]);
  await db.query(`insert into dispatch_assignments(order_id,vehicle_no) values($1,'GJ01AB1234')`,[id]);
  await as(ACC);
  await db.query(`update orders set status='loaded' where id=$1`,[id]);
  const b=await bells(id);
  assert.deepEqual(b.map(x=>x.role+':'+x.t),['sales:ORDER_APPROVED','sales:ORDER_DISPATCHED','salesman:ORDER_APPROVED','salesman:ORDER_DISPATCHED']);
  assert.match(b[0].message,/^LXY-\d+ · RJ Traders · 15 CS · Rs 12000\.00 · Approved by Head\.$/);
  assert.match(b[1].message,/Vehicle GJ01AB1234/);
});

test('driver report: salesman, Sales Head and Admin get Delivered (no Sales Head copy twice)',async()=>{
  const id=await order('loaded');
  await as(DRV);
  await db.query(`insert into lwb_delivery_reports(order_id,driver_user_id,delivery_status,received_by) values($1,$2,'DELIVERED','Ramesh')`,[id,DRV]);
  const b=await bells(id);
  assert.deepEqual(b.map(x=>x.role+':'+x.t),['admin:ORDER_DELIVERED','manager:ORDER_DELIVERED','sales:ORDER_DELIVERED','salesman:ORDER_DELIVERED']);
  assert.match(b[0].message,/Received by Ramesh/);
});

test('Mark delivered: everyone but the one who marked',async()=>{
  const id=await order('loaded');
  await as(HEAD);
  await db.query(`insert into lwb_admin_order_marks(order_id,kind,mark_date,marked_by,marked_by_name,marked_by_role,note) values($1,'DELIVERED','2026-11-17',$2,'Head','MANAGER','self pickup')`,[id,HEAD]);
  const b=await bells(id);
  assert.deepEqual(b.map(x=>x.role+':'+x.t),['admin:ORDER_DELIVERED','sales:ORDER_DELIVERED','salesman:ORDER_DELIVERED']);
  assert.match(b[0].message,/Delivered on 17\/11\/2026 · Marked by Head · self pickup\.$/);
  // a LOADED mark sends nothing
  const id2=await order('approved');
  await db.query(`delete from erp_notifications where order_id=$1`,[id2]);
  await db.query(`insert into lwb_admin_order_marks(order_id,kind,mark_date,marked_by) values($1,'LOADED','2026-11-17',$2)`,[id2,HEAD]);
  assert.equal((await bells(id2)).length,0);
});

test('Daily Report counts Mark delivered on its date, with the PO driver; pending leaves it out',async()=>{
  const day='2026-11-10';
  const a=await order('loaded'),b=await order('loaded'),c=await order('loaded'),p=await order('loaded');
  const asg=(await db.query(`insert into dispatch_assignments(order_id,driver_name) values($1,'Suresh') returning id`,[b])).rows[0].id;
  await db.query(`insert into lwb_delivery_reports(order_id,driver_user_id,delivery_status,reported_at) values($1,$2,'DELIVERED','2026-11-10 10:00+05:30'),
    ($3,$2,'NOT_DELIVERED','2026-11-10 09:00+05:30')`,[a,DRV,c]);
  await db.query(`insert into lwb_admin_order_marks(order_id,kind,mark_date,marked_by,marked_at) values
    ($1,'DELIVERED',$3,$4,'2026-11-17 11:00+05:30'),($2,'DELIVERED',$3,$4,'2026-11-10 18:00+05:30')`,[b,c,day,HEAD]);
  const r=(await db.query(`select lwb_daily_summary($1::date) r`,[day])).rows[0].r;
  assert.equal(r.delivered,3);      // driver report + 2 marks
  assert.equal(r.not_delivered,0);  // "not delivered" in the morning, marked delivered that day
  assert.ok(r.drivers.includes('Suresh'));
  const rows=(await db.query(`select order_id,reported_at from lwb_day_delivery_rows($1::date) where order_id=$2`,[day,b])).rows;
  assert.equal(new Date(rows[0].reported_at).toISOString(),'2026-11-10T06:30:00.000Z'); // back date = 12:00 IST
  assert.equal(r.pending>=1,true);
  const pend=(await db.query(`select count(*)::int n from orders o where o.id=$1 and not exists(select 1 from lwb_admin_order_marks m where m.order_id=o.id)`,[p])).rows[0].n;
  assert.equal(pend,1);
  // running the file again changes nothing
  await db.exec(await readFile(new URL('../../lwb_order_updates_everyone_setup.sql',import.meta.url),'utf8'));
  assert.equal((await db.query(`select lwb_daily_summary($1::date) r`,[day])).rows[0].r.delivered,3);
});
