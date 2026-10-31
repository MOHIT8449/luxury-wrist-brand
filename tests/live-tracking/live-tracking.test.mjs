import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_live_tracking_setup.sql on an empty PGlite database (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',acc:'00000000-0000-4000-8000-000000000004',
  sales:'00000000-0000-4000-8000-000000000005',driver:'00000000-0000-4000-8000-000000000007',
  driver2:'00000000-0000-4000-8000-000000000008'};
const roles={admin:'admin',head:'manager',godown:'warehouse',acc:'accounts',sales:'sales',driver:'driver',driver2:'driver'};
const mob={driver:'9876500001',driver2:'9876500002'};
const O1='10000000-0000-4000-8000-000000000001',O2='10000000-0000-4000-8000-000000000002',O3='10000000-0000-4000-8000-000000000003';
// Godown at (21.0000, 72.0000). Party A 5 km north, party B 8 km east (no pin yet).
const G=[21,72],A=[21.045,72],B=[21,72.077];

const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.orders(id uuid primary key,order_no text,customer_name text,status text,order_date date default current_date);
CREATE TABLE public.dispatch_assignments(id uuid primary key default gen_random_uuid(),order_id uuid,driver_name text,driver_mobile text,vehicle_no text,loading_completed_at timestamptz default now());
CREATE TABLE public.lwb_delivery_reports(id uuid primary key default gen_random_uuid(),order_id uuid unique,driver_user_id uuid,delivery_status text,reported_at timestamptz default now());
CREATE TABLE public.lwb_customer_master(customer_code text,customer_name text,billing_address text,city text);
CREATE FUNCTION public.lwb_driver_phone_matches(a text,b text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(right(regexp_replace(a,'[^0-9]','','g'),10)=right(regexp_replace(b,'[^0-9]','','g'),10) AND length(regexp_replace(a,'[^0-9]','','g'))>=10,false) $$;
CREATE FUNCTION public.lwb_has_page(p text) RETURNS boolean LANGUAGE sql AS $$ SELECT false $$;
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3,$4)',[id,roles[k].toUpperCase(),'Name '+k,mob[k]||null]);
await db.exec(`
insert into lwb_customer_master values('C1','Party A','Main road','Surat'),('C2','Party B','Ring road','Surat');
insert into orders values('${O1}','PO-1','Party A','loaded'),('${O2}','PO-2','Party B','invoiced'),('${O3}','PO-3','Party A','approved');
insert into dispatch_assignments(order_id,driver_name,driver_mobile,vehicle_no) values
 ('${O1}','Old name','+91 98765 00001','GJ05AB1'),('${O2}','Old name','9876500001','GJ05AB1'),('${O3}','X','9876500002','GJ05AB2');
`);
const setup=await readFile(new URL('../../lwb_live_tracking_setup.sql',import.meta.url),'utf8');
await db.exec(setup);
await db.exec(setup); // safe to run again

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const one=async(q,args)=>Object.values((await call(q,args))[0])[0];
const ping=async(who,[lat,lng],acc=10)=>{await as(who);return one('select lwb_track_ping($1,$2,$3,20,0) r',[lat,lng,acc])};
const events=async(order)=>(await db.query('select event,source from lwb_trip_events where order_id=$1 order by id',[order])).rows.map(r=>r.event);
const map=async(who='head')=>{await as(who);return one('select lwb_live_map() m')};

test('only Admin / Sales Head change settings; work hours and godown are saved', async()=>{
  await as('sales');
  await assert.rejects(call('select lwb_tracking_save_settings($1)',[{work_start:'00:00'}]),/Only Admin or Sales Head/);
  await as('head');
  await call('select lwb_tracking_save_settings($1)',[{work_start:'00:00',work_end:'23:59:59',godown_lat:G[0],godown_lng:G[1],godown_radius_m:200}]);
  await assert.rejects(call('select lwb_tracking_save_settings($1)',[{tracked_roles:['party']}]),/Unknown role/);
  const s=(await map()).settings;
  assert.equal(s.godown_lat,21);assert.equal(s.work_start,'00:00');
  assert.deepEqual(s.tracked_roles,['driver','sales','accounts','warehouse','transport']);
});

test('map is only for Admin, Sales Head and Godown Manager', async()=>{
  for(const who of ['sales','acc','driver']){await as(who);await assert.rejects(call('select lwb_live_map()'),/only for Admin, Sales Head and Godown Manager/)}
  for(const who of ['admin','head','godown'])assert.ok(Array.isArray((await map(who)).people));
  await as('sales');await assert.rejects(call('select lwb_location_trail($1,null)',[ids.driver]),/only for/);
});

test('tables cannot be read directly by staff', async()=>{
  await as('head');
  await assert.rejects(call('select * from lwb_staff_location'),/permission denied/);
  await assert.rejects(call('select * from lwb_location_history'),/permission denied/);
});

test('a salesman sends location; Admin is not tracked by default', async()=>{
  assert.equal((await ping('admin',[21.2,72.8])).tracked,false);
  await as('sales');assert.equal((await one('select lwb_track_me() r')).tracked,true);
  assert.equal((await ping('sales',[21.2,72.8])).saved,true);
  const p=(await map()).people.find(x=>x.user_id===ids.sales);
  assert.equal(p.lat,21.2);assert.equal(p.status,'ON');
  await as('sales');await call("select lwb_track_ping(null,null,null,null,null,'DENIED')");
  assert.equal((await map()).people.find(x=>x.user_id===ids.sales).status,'DENIED');
  await assert.rejects(ping('sales',[200,72]),/Invalid location/);
});

test('history keeps one point a minute or every 40 m', async()=>{
  await ping('acc',[21.1,72.1]);await ping('acc',[21.1,72.1]);await ping('acc',[21.1001,72.1]); // 11 m: skipped
  await ping('acc',[21.105,72.1]); // 550 m: kept
  await as('head');
  const t=await one('select lwb_location_trail($1,null) t',[ids.acc]);
  assert.equal(t.points.length,2);
});

test('driver trip: map shows his loaded orders with the ERP driver name', async()=>{
  const m=await map();
  const mine=m.trips.filter(t=>t.driver_user_id===ids.driver).map(t=>t.order_no).sort();
  assert.deepEqual(mine,['PO-1','PO-2']);
  assert.equal(m.trips.find(t=>t.order_no==='PO-1').driver_name,'Name driver');
  assert.ok(!m.trips.some(t=>t.order_no==='PO-3'),'approved but not loaded is not on the road');
});

test('inside the godown nothing happens; leaving marks LEFT_GODOWN on every order', async()=>{
  await ping('driver',[21.0005,72]);
  assert.deepEqual(await events(O1),[]);
  const r=await ping('driver',[21.01,72]);
  assert.deepEqual(r.events,['LEFT_GODOWN','LEFT_GODOWN']);
  assert.deepEqual(await events(O1),['LEFT_GODOWN']);assert.deepEqual(await events(O2),['LEFT_GODOWN']);
  await ping('driver',[21.02,72]);
  assert.deepEqual(await events(O1),['LEFT_GODOWN'],'only once');
});

test('a bad GPS fix (accuracy 900 m) does not mark steps', async()=>{
  await as('head');await call('select lwb_set_party_location($1,$2,$3)',['Party A',A[0],A[1]]);
  await ping('driver',A,900);
  assert.deepEqual(await events(O1),['LEFT_GODOWN']);
});

test('near the party pin marks REACHED_PARTY; ETA data is on the map', async()=>{
  await ping('driver',[A[0]-0.001,A[1]]); // ~110 m
  assert.deepEqual(await events(O1),['LEFT_GODOWN','REACHED_PARTY']);
  const t=(await map()).trips.find(x=>x.order_no==='PO-1');
  assert.equal(t.party_lat,A[0]);assert.ok(t.events.REACHED_PARTY);
});

test('delivery report adds DELIVERY_REPORT, then driving away marks LEFT_PARTY', async()=>{
  await db.query("insert into lwb_delivery_reports(order_id,driver_user_id,delivery_status) values($1,$2,'DELIVERED')",[O1,ids.driver]);
  assert.deepEqual(await events(O1),['LEFT_GODOWN','REACHED_PARTY','DELIVERY_REPORT']);
  await ping('driver',[A[0]-0.002,A[1]]); // 220 m: still there
  assert.deepEqual(await events(O1),['LEFT_GODOWN','REACHED_PARTY','DELIVERY_REPORT']);
  await ping('driver',[A[0]-0.01,A[1]]); // 1.1 km
  assert.deepEqual(await events(O1),['LEFT_GODOWN','REACHED_PARTY','DELIVERY_REPORT','LEFT_PARTY']);
  assert.equal((await map()).trips.find(x=>x.order_no==='PO-1').report_status,'DELIVERED');
});

test('first delivery at a party without a pin saves the driver spot as its pin', async()=>{
  await ping('driver',[B[0]+0.0003,B[1]],30);
  await db.query("insert into lwb_delivery_reports(order_id,driver_user_id,delivery_status) values($1,$2,'PARTIAL')",[O2,ids.driver]);
  const p=(await db.query("select geo_lat,geo_lng from lwb_customer_master where customer_name='Party B'")).rows[0];
  assert.equal(p.geo_lat,B[0]+0.0003);
  const pinned=(await db.query("select geo_lat from lwb_customer_master where customer_name='Party A'")).rows[0];
  assert.equal(pinned.geo_lat,A[0],'an existing pin is kept');
});

test('back inside the godown with nothing left marks BACK_GODOWN once', async()=>{
  await ping('driver',[B[0]+0.01,B[1]]); // leaves party B
  assert.ok((await events(O2)).includes('LEFT_PARTY'));
  const r=await ping('driver',[21.0003,72]);
  assert.deepEqual(r.events,['BACK_GODOWN']);
  const again=await ping('driver',[21.0004,72]);
  assert.deepEqual(again.events,[]);
  assert.ok((await map()).back_godown[ids.driver]);
});

test('driver buttons: own orders only; Left party needs the report', async()=>{
  await db.exec(`update orders set status='loaded' where id='${O3}'`);
  await as('driver');
  await assert.rejects(call('select lwb_trip_mark($1,$2)',[O3,'REACHED_PARTY']),/not on your vehicle/);
  await as('driver2');
  await assert.rejects(call('select lwb_trip_mark($1,$2)',[O3,'LEFT_PARTY']),/delivery report first/);
  assert.equal(await one('select lwb_trip_mark(null,$1) n',['LEFT_GODOWN']),1);
  assert.equal(await one('select lwb_trip_mark($1,$2) n',[O3,'REACHED_PARTY']),1);
  assert.equal(await one('select lwb_trip_mark($1,$2) n',[O3,'REACHED_PARTY']),0,'second tap changes nothing');
  const st=await one('select lwb_driver_trip_status() s');
  assert.deepEqual(Object.keys(st.find(x=>x.order_id===O3).events).sort(),['LEFT_GODOWN','REACHED_PARTY']);
  await as('sales');
  await assert.rejects(call('select lwb_trip_mark(null,$1)',['LEFT_GODOWN']),/Only an active driver/);
});

test('outside work hours the phone is told to stop and nothing is saved', async()=>{
  await as('admin');await call('select lwb_tracking_save_settings($1)',[{work_start:'00:00',work_end:'00:00:01'}]);
  const r=await ping('sales',[22,73]);
  assert.equal(r.in_hours,false);
  await as('admin');await call('select lwb_tracking_save_settings($1)',[{work_end:'23:59:59'}]);
  const p=(await map()).people.find(x=>x.user_id===ids.sales);
  assert.notEqual(p.lat,22);
});
