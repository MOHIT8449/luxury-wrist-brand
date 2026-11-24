import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_vehicle_day_setup.sql on a tiny copy of the tables it reads (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004',transport:'00000000-0000-4000-8000-000000000007',driver:'00000000-0000-4000-8000-000000000008'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text,total_qty numeric,total_weight numeric,total_amount numeric);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,vehicle_no text,driver_name text,driver_mobile text,assigned_at timestamptz default now(),loading_completed_at timestamptz,trip_id bigint);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid unique,delivery_status text,reported_at timestamptz default now());
CREATE TABLE public.lwb_admin_order_marks(order_id uuid,kind text,mark_date date);
CREATE TABLE public.lwb_driver_delivery_returns(id uuid default gen_random_uuid() primary key,order_id uuid,status text);
CREATE TABLE public.lwb_driver_delivery_return_items(return_id uuid,qty_cases numeric);
CREATE TABLE public.lwb_vehicle_trips(id bigserial primary key,trip_no text);
CREATE TABLE public.lwb_vehicles(id uuid primary key default gen_random_uuid(),vehicle_no text unique,vehicle_type text,capacity_kg numeric,size_ton numeric,ownership text default 'OWN',transporter_name text,is_active boolean default true);
CREATE TABLE public.lwb_acc_staff(id bigserial primary key,name text,mobile text,active boolean default true,default_vehicle_id uuid);
CREATE TABLE public.lwb_user_page_access(user_id uuid,extra text[]);
CREATE FUNCTION public.lwb_has_page(p_page text) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM public.lwb_user_page_access a WHERE a.user_id = auth.uid() AND p_page = ANY(a.extra)) $$;
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role+' user']);
const setup=await sql('lwb_vehicle_day_setup.sql');
await db.exec(setup);await db.exec(setup); // safe to run again
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const day=(f,t)=>call('select public.lwb_vehicle_day($1,$2) j',[f,t]).then(r=>r[0].j);

// Data: 2 vehicles, 1 fixed driver; 3 orders on 23/11 (one late at night IST), one on 22/11, one cancelled.
const v1=(await db.query("insert into lwb_vehicles(vehicle_no,vehicle_type,capacity_kg,size_ton) values('GJ05AB1234','Tata 407',4000,4) returning id")).rows[0].id;
await db.query("insert into lwb_vehicles(vehicle_no,vehicle_type) values('GJ05XY9999','Pickup')");
await db.query("insert into lwb_vehicles(vehicle_no,is_active) values('GJ05OLD0001',false)");
await db.query("insert into lwb_acc_staff(name,mobile,default_vehicle_id) values('Ramesh','9876543210',$1),('Old driver','9000000000',null)",[v1]);
const trip=(await db.query("insert into lwb_vehicle_trips(trip_no) values('T-2311-01') returning id")).rows[0].id;
async function po(no,party,qty,kg,status,vno,at,loaded){
  const o=(await db.query('insert into orders(order_no,customer_name,status,total_qty,total_weight,total_amount) values($1,$2,$3,$4,$5,$6) returning id',[no,party,status,qty,kg,qty*100])).rows[0].id;
  await db.query('insert into dispatch_assignments(order_id,vehicle_no,driver_name,driver_mobile,assigned_at,loading_completed_at,trip_id) values($1,$2,$3,$4,$5,$6,$7)',[o,vno,'Ramesh','9876543210',at,loaded,no==='PO-1'?trip:null]);
  return o;
}
const o1=await po('PO-1','Shree Jagdish',100,1500,'delivered','GJ 05 AB 1234','2026-11-23T03:00:00Z','2026-11-23T04:00:00Z');
const o2=await po('PO-2','Devnarayan',50,800,'loaded','GJ05AB1234','2026-11-22T05:00:00Z','2026-11-23T17:00:00Z'); // 22:30 IST on 23/11
const o3=await po('PO-3','Manshi',40,600,'transport_allocated','GJ05XY9999','2026-11-23T06:00:00Z',null);
await po('PO-4','Old party',10,100,'delivered','GJ05AB1234','2026-11-22T06:00:00Z','2026-11-22T07:00:00Z');
await po('PO-5','Cancelled',10,100,'cancelled','GJ05AB1234','2026-11-23T06:00:00Z',null);
await po('PO-6','Porter party',5,50,'loaded','MH12PORTER1','2026-11-23T08:00:00Z',null);
await db.query("insert into lwb_delivery_reports(order_id,delivery_status,reported_at) values($1,'PARTIAL','2026-11-23T09:00:00Z')",[o1]);
// Loaded on 22/11, delivered on 23/11 -> 23/11. Delivered PO with no Transport Assignment row -> 23/11, no vehicle.
const o7=await po('PO-7','Late load',20,200,'delivered','GJ05AB1234','2026-11-22T05:00:00Z','2026-11-22T06:00:00Z');
await db.query("insert into lwb_delivery_reports(order_id,delivery_status,reported_at) values($1,'DELIVERED','2026-11-23T05:00:00Z')",[o7]);
const o8=(await db.query("insert into orders(order_no,customer_name,status,total_qty,total_weight,total_amount) values('PO-8','No vehicle party','delivered',260,2618,111600) returning id")).rows[0].id;
await db.query("insert into lwb_admin_order_marks values($1,'DELIVERED','2026-11-23')",[o8]);
const r=(await db.query("insert into lwb_driver_delivery_returns(order_id,status) values($1,'APPROVED'),($1,'REJECTED') returning id",[o1])).rows;
await db.query('insert into lwb_driver_delivery_return_items values($1,3.5),($2,20)',[r[0].id,r[1].id]);
await db.query("insert into lwb_admin_order_marks values($1,'DELIVERED','2026-11-23')",[o3]);

test('rows of one India day: loaded day first, cancelled left out, delivered + returns', async()=>{
  await as('manager');
  const j=await day('2026-11-23','2026-11-23');
  assert.deepEqual(j.rows.map(x=>x.order_no).sort(),['PO-1','PO-2','PO-3','PO-6','PO-7','PO-8']);
  const p1=j.rows.find(x=>x.order_no==='PO-1');
  assert.equal(p1.vehicle_key,'GJ05AB1234');assert.equal(p1.report,'PARTIAL');assert.equal(Number(p1.ret_cases),3.5);
  assert.equal(p1.trip_no,'T-2311-01');assert.equal(Number(p1.kg),1500);assert.equal(Number(p1.cases),100);
  assert.equal(j.rows.find(x=>x.order_no==='PO-3').mark_delivered,'2026-11-23');
  assert.equal(j.rows.find(x=>x.order_no==='PO-2').day,'2026-11-23');
  const p8=j.rows.find(x=>x.order_no==='PO-8');assert.equal(p8.vehicle_no,null);assert.equal(p8.vehicle_key,'');assert.equal(Number(p8.kg),2618);
  const v=j.vehicles.find(x=>x.vehicle_no==='GJ05AB1234');
  assert.deepEqual(v.drivers.map(d=>d.name),['Ramesh']);assert.equal(Number(v.size_ton),4);
  assert.equal(j.vehicles.length,2);
  const old=await day('2026-11-22','2026-11-22');
  assert.deepEqual(old.rows.map(x=>x.order_no),['PO-4']);
});

test('only office roles or a login given the page; driver / salesman refused', async()=>{
  for(const r of ['admin','transport']){await as(r);assert.ok((await day('2026-11-23','2026-11-23')).rows.length)}
  for(const r of ['sales','driver']){await as(r);await assert.rejects(day('2026-11-23','2026-11-23'),/can not open/)}
  await db.query("insert into lwb_user_page_access values($1,array['vehicle-report.html'])",[ids.sales]);
  await as('sales');assert.equal((await day('2026-11-23','2026-11-23')).rows.length,6);
  await as('manager');await assert.rejects(day('2026-11-23','2026-11-01'),/before/);
});
