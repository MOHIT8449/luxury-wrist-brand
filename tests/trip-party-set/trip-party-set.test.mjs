import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_trip_party_set_rent_setup.sql on PGlite: a trip with 2+ parties asks its own rent, once per set of parties.
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
await db.exec(await sql('lwb_rent_km_chart_setup.sql'));
// safe to run again


await db.exec(await sql('lwb_trip_rent_setup.sql'));
const setSql=await sql('lwb_trip_party_set_rent_setup.sql');await db.exec(setSql);await db.exec(setSql); // safe to run again
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




const live=async v=>(await lines(v)).filter(x=>!x.cancelled_at);
async function trip(vno,parties,isNew=true){await as('transport');let t=null;
  for(const [i,p] of parties.entries()){const o=await order('PO-'+Math.random().toString(36).slice(2,8),p,'approved',800);
    t=t?{id:t.id,...t}:await open({vehicle_no:vno,order_id:o,new:isNew});await assign(o,vno,t.id);}
  return t.id;}
const todo=async()=>(await one('select public.lwb_trip_rent_todo()')).rows;

test('one party: rent asked once, used again; two parties together: asked as a set, once',async()=>{
  const v=await veh('GJ19Y9416');
  await as('admin');await save(v,{rent_type:'PARTY',start_date:dayAdd(today,-3)});
  const t1=await trip('GJ19Y9416',['Shree Jagdish Trader']);
  let T=await todo();assert.equal(T.length,1);assert.equal(T[0].party,'Shree Jagdish Trader');assert.equal(T[0].together,false);
  // Transport (Vishal) enters it: waits for Admin, leaves the popup
  assert.equal((await one('select public.lwb_trip_rent_set($1,1500)',[T[0].id])).status,'WAITING');
  assert.equal((await todo()).length,0);assert.equal((await live(v)).length,0);
  await as('sales');await assert.rejects(call('select public.lwb_trip_rent_set($1,1)',[T[0].id]),/Only Admin, Manager or Transport/);
  const rid=(await db.query("select id from lwb_hired_party_rates where vehicle_id=$1",[v])).rows[0].id;
  await as('admin');await call('select public.lwb_hired_rate_verify($1,true,null,null)',[rid]);
  assert.equal(Number((await live(v))[0].amount),1500);
  // next trip to Jagdish alone: no question
  const t2=await trip('GJ19Y9416',['Shree Jagdish Trader']);
  assert.equal((await todo()).length,0);assert.equal(Number((await live(v)).find(x=>x.trip_id===t2).amount),1500);
  // Jagdish + Devnarayan together: asked as one set (even though Jagdish has a rate)
  const t3=await trip('GJ19Y9416',['Shree Jagdish Trader','Shree Devnarayan Marketing']);
  T=await todo();assert.equal(T.length,1);assert.equal(T[0].together,true);assert.equal(T[0].party,'Shree Devnarayan Marketing + Shree Jagdish Trader');
  assert.equal((await live(v)).filter(x=>x.trip_id===t3).length,0);
  await as('admin');assert.equal((await one('select public.lwb_trip_rent_set($1,1900)',[T[0].id])).status,'VERIFIED'); // Admin: posted at once
  assert.equal(Number((await live(v)).find(x=>x.trip_id===t3).amount),1900);
  // the same set again (other order): no question, same rent
  await as('transport');const t4=await trip('GJ19Y9416',['Shree Devnarayan Marketing','shree jagdish trader ']);
  assert.equal((await todo()).length,0);assert.equal(Number((await live(v)).find(x=>x.trip_id===t4).amount),1900);
  // a PO of the set moved out: the trip becomes Jagdish alone -> 1500
  const o=(await db.query("select a.order_id from dispatch_assignments a join orders o on o.id=a.order_id where a.trip_id=$1 and o.customer_name='Shree Devnarayan Marketing'",[t4])).rows[0].order_id;
  await db.query("update dispatch_assignments set trip_id=null,vehicle_no='GJ01ZZ0001' where order_id=$1",[o]);
  assert.equal(Number((await live(v)).find(x=>x.trip_id===t4).amount),1500);
});
