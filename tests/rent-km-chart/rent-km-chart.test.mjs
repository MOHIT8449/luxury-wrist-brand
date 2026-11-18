import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_rent_km_chart_setup.sql on PGlite: trip rent by party km from the godown x vehicle size.
const ids={transport:'00000000-0000-4000-8000-000000000007',admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',manager:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004',warehouse:'00000000-0000-4000-8000-000000000006'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,vehicle_no text,driver_mobile text,assigned_at timestamptz default now());
CREATE TABLE public.lwb_tally_invoices(order_id uuid,invoice_no text);
CREATE TABLE public.lwb_tally_payments(id uuid default gen_random_uuid() primary key,receipt_id uuid,order_id uuid,pay_date date,mode text,amount numeric(14,2),ref_no text,cash_notes jsonb,remark text,created_by uuid,created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,driver_user_id uuid,cash_reported numeric(14,2) default 0,payment_mode text,payment_reference text,cash_amount numeric(14,2),online_amount numeric(14,2),online_mode text,online_reference text,bank_ref text,payment_status text,payment_reviewed_by uuid,payment_reviewed_at timestamptz);
CREATE TABLE public.tax_invoices(id uuid primary key,order_id uuid);
CREATE SCHEMA storage;
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(bucket_id text,name text);
CREATE FUNCTION storage.foldername(text) RETURNS text[] LANGUAGE sql AS $$ SELECT (string_to_array($1,'/'))[1:array_length(string_to_array($1,'/'),1)-1] $$;
CREATE TABLE public.lwb_payment_collections(id uuid default gen_random_uuid() primary key,invoice_id uuid,collection_date date,amount numeric(14,2),payment_mode text,reference_no text,remarks text,status text,submitted_by uuid,submitted_at timestamptz default now(),reviewed_at timestamptz);
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role+' user']);
await db.exec(await sql('lwb_accounts_dashboard_setup.sql'));
await db.exec(`create table lwb_vehicles(id uuid primary key default gen_random_uuid(),vehicle_no text unique,vehicle_type text,ownership text default 'OWN' check (ownership in ('OWN','TRANSPORTER')),transporter_name text,owner_mobile text,is_active boolean default true);
CREATE FUNCTION public.lwb_fleet_editor() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active AND p.role IN ('admin','manager')) $$;`);
for(const f of ['lwb_accounts_staff_setup.sql','lwb_accounts_vehicle_setup.sql','lwb_employee_master_setup.sql','lwb_hired_vehicle_rent_setup.sql','lwb_hired_auto_trip_setup.sql','lwb_hired_party_rate_setup.sql','lwb_trip_rent_setup.sql'])await db.exec(await sql(f));
await db.exec('alter table orders add column total_weight numeric');
await db.exec(`CREATE TABLE lwb_customer_master(id serial primary key,customer_name text,geo_lat double precision,geo_lng double precision,merged_into int);
CREATE TABLE lwb_tracking_settings(id int primary key,godown_lat double precision,godown_lng double precision);
CREATE FUNCTION public.lwb_geo_m(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE SET search_path = '' AS $fn$
  SELECT CASE WHEN lat1 IS NULL OR lng1 IS NULL OR lat2 IS NULL OR lng2 IS NULL THEN NULL ELSE
    2 * 6371000 * asin(least(1, sqrt(power(sin(radians(lat2 - lat1) / 2), 2) +
      cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))) END $fn$;
INSERT INTO lwb_tracking_settings VALUES (1,23.0,72.0);`);
await db.exec(await sql('lwb_rent_rate_card_setup.sql'));
const kmSql=await sql('lwb_rent_km_chart_setup.sql');await db.exec(kmSql);await db.exec(kmSql); // safe to run again
// safe to run again


await db.exec(await sql('lwb_trip_rent_setup.sql'));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

const today=(await db.query("select public.lwb_acc_today()::text d")).rows[0].d;
const dayAdd=(d,n)=>{const x=new Date(d+'T12:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const one=async(q,args)=>Object.values((await call(q,args))[0])[0];
const veh=async(no,own='TRANSPORTER')=>(await db.query("insert into lwb_vehicles(vehicle_no,vehicle_type,ownership,transporter_name) values($1,'Pickup',$2,'Jay Khodiyar') returning id",[no,own])).rows[0].id;
const save=(v,p)=>call('select public.lwb_hired_save($1,$2::jsonb)',[v,JSON.stringify(p)]);
const open=p=>one('select public.lwb_trip_open($1::jsonb)',[JSON.stringify(p)]);
const order=async(no,party,status='approved',kg=0)=>(await db.query("insert into orders(order_no,customer_name,status,total_weight) values($1,$2,$3,$4) returning id",[no,party,status,kg])).rows[0].id;
// what the page does: trip first, then the assignment row with trip_id
async function assign(oid,vno,trip){const f=await db.query('select id from dispatch_assignments where order_id=$1',[oid]);
  if(f.rows.length)await db.query('update dispatch_assignments set vehicle_no=$2,trip_id=$3 where id=$1',[f.rows[0].id,vno,trip]);
  else await db.query('insert into dispatch_assignments(order_id,vehicle_no,trip_id) values($1,$2,$3)',[oid,vno,trip]);}
const lines=async v=>(await db.query("select amount,order_nos,route_name,trip_id,cancelled_at from lwb_hired_charges where vehicle_id=$1 and kind='TRIP' order by id",[v])).rows;



const size=(v,t)=>db.query('update lwb_vehicles set size_ton=$2 where id=$1',[v,t]);
const live=async v=>(await lines(v)).filter(x=>!x.cancelled_at);
// party on the map: 0.09 degree north of the godown = ~10 km straight line
const place=(name,dlat)=>db.query('insert into lwb_customer_master(customer_name,geo_lat,geo_lng) values($1,$2,72.0)',[name,23.0+dlat]);
const chart={rates:[{km_upto:10,size_ton:3,rate:800},{km_upto:25,size_ton:3,rate:1200},{km_upto:10,size_ton:4,rate:1000},{km_upto:25,size_ton:4,rate:1500}],per_km:[{size_ton:3,rate_per_km:50}]};
async function trip(no,party,vno,isNew=false){await as('transport');const o=await order(no,party,'approved',1000);
  const t=await open({vehicle_no:vno,order_id:o,...(isNew?{new:true}:{})});await assign(o,vno,t.id);return t.id;}

test('chart rent by km x size; parties at the same place get the same rent; Manager can not change the chart',async()=>{
  await place('Shree Jagdish Trader',0.08);await place('Shree Devnarayan Marketing',0.081);await place('Far Away Stores',0.3);
  const [a,b]=[await veh('GJ19Y9416'),await veh('GJ07TU7996')];await size(a,3);await size(b,4);
  await as('admin');for(const v of [a,b])await save(v,{rent_type:'PARTY',start_date:dayAdd(today,-3)});
  await trip('PO-K1','Shree Jagdish Trader','GJ19Y9416');
  assert.equal((await live(a)).length,0); // no chart yet: waits
  await as('manager');await assert.rejects(call('select public.lwb_rent_km_save($1::jsonb)',[JSON.stringify(chart)]),/Only Admin/);
  await as('admin');assert.equal(await one('select public.lwb_rent_km_save($1::jsonb)',[JSON.stringify(chart)]),1);
  assert.equal(Number((await live(a))[0].amount),800); // ~8.9 km -> up to 10 km, 3 Ton
  await trip('PO-K2','Shree Devnarayan Marketing','GJ07TU7996');
  assert.equal(Number((await live(b))[0].amount),1000); // same place, 4 Ton
  // beyond the last slab: km x rate per km (~33.4 km x 50)
  await trip('PO-K3','Far Away Stores','GJ19Y9416',true);
  const far=(await live(a)).map(x=>Number(x.amount));assert.equal(far.length,2);assert.ok(far[1]>1600&&far[1]<1700,String(far[1]));
  // 4 Ton has no rate per km: that trip waits
  await trip('PO-K4','Far Away Stores','GJ07TU7996',true);assert.equal((await live(b)).length,1);
});

test('the farthest party sets the trip rent; road km beats map km; own and card rates beat the chart',async()=>{
  await place('Mid Town Mart',0.18); // ~20 km
  const a=(await db.query("select id from lwb_vehicles where vehicle_no='GJ19Y9416'")).rows[0].id;
  await as('transport');const o1=await order('PO-K5','Shree Jagdish Trader','approved',500),o2=await order('PO-K6','Mid Town Mart','approved',500);
  const t=await open({vehicle_no:'GJ19Y9416',new:true,order_id:o1});await assign(o1,'GJ19Y9416',t.id);
  await open({vehicle_no:'GJ19Y9416',trip_id:t.id,order_id:o2});await assign(o2,'GJ19Y9416',t.id);
  const tl=async()=>(await live(a)).filter(x=>x.trip_id===t.id);
  assert.equal((await tl()).length,1);assert.equal(Number((await tl())[0].amount),1200);
  // road km of Mid Town set to 8 -> both parties in the 10 km slab for the next trip (a posted line stays as it is)
  await as('manager');await call('select public.lwb_rent_party_km_set($1,8)',['Mid Town Mart']);
  assert.equal(Number((await tl())[0].amount),1200);
  await as('transport');const o3=await order('PO-K7','Mid Town Mart','approved',500);
  const t2=await open({vehicle_no:'GJ19Y9416',new:true,order_id:o3});await assign(o3,'GJ19Y9416',t2.id);
  assert.equal(Number((await live(a)).find(x=>x.trip_id===t2.id).amount),800);
  await as('manager');
  const G=await one('select public.lwb_rent_km_get()');
  const m=G.parties.find(x=>x.party_key==='MID TOWN MART');assert.equal(Number(m.road_km),8);assert.ok(Number(m.map_km)>19);
  // card rate for 3 Ton + Mid Town wins over the chart
  await as('admin');await call('select public.lwb_rate_card_set(3,$1,950,null)',['Mid Town Mart']);
  assert.equal(Number((await db.query("select rate from lwb_hired_party_rates where vehicle_id=$1 and party_key='MID TOWN MART'",[a])).rows[0].rate),950);
  // a changed chart does not touch card or own rates
  const c2={...chart,rates:chart.rates.map(r=>({...r,rate:r.rate+100}))};await call('select public.lwb_rent_km_save($1::jsonb)',[JSON.stringify(c2)]);
  assert.equal(Number((await db.query("select rate from lwb_hired_party_rates where vehicle_id=$1 and party_key='MID TOWN MART'",[a])).rows[0].rate),950);
  assert.equal(Number((await db.query("select rate from lwb_hired_party_rates where vehicle_id=$1 and party_key='SHREE JAGDISH TRADER'",[a])).rows[0].rate),900);
  await call('select public.lwb_hired_rate_set($1,$2,777,null)',[a,'Shree Jagdish Trader']);
  await call('select public.lwb_rent_km_save($1::jsonb)',[JSON.stringify(chart)]);
  const q=(await db.query("select rate,from_card from lwb_hired_party_rates where vehicle_id=$1 and party_key='SHREE JAGDISH TRADER'",[a])).rows[0];
  assert.equal(Number(q.rate),777);assert.equal(q.from_card,false);
});

test('lists carry km; size change moves km rates',async()=>{
  await as('admin');const L=await one('select public.lwb_hired_rate_list2()');
  const g=L.groups.find(x=>x.party==='Far Away Stores');assert.ok(g&&g.km&&g.km.src==='MAP');
  const a=(await db.query("select id from lwb_vehicles where vehicle_no='GJ19Y9416'")).rows[0].id;
  await as('accounts');const G=await one('select public.lwb_hired_ledger2($1,$2,$3)',[a,dayAdd(today,-5),today]);
  assert.ok(G.lines.some(l=>l.src==='CHARGE'&&Number(l.km)>8&&Number(l.km)<10));
  // 3 Ton -> 4 Ton: Jagdish km rate becomes the 4 Ton chart rate
  const b=(await db.query("select id from lwb_vehicles where vehicle_no='GJ07TU7996'")).rows[0].id;
  await size(b,3);
  assert.equal(Number((await db.query("select rate from lwb_hired_party_rates where vehicle_id=$1 and party_key='SHREE DEVNARAYAN MARKETING'",[b])).rows[0].rate),800);
});
