import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_trip_rent_setup.sql on a tiny copy of the tables it reads (no live database).
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
const order=async(no,party,status='approved')=>(await db.query("insert into orders(order_no,customer_name,status) values($1,$2,$3) returning id",[no,party,status])).rows[0].id;
// what the page does: trip first, then the assignment row with trip_id
async function assign(oid,vno,trip){const f=await db.query('select id from dispatch_assignments where order_id=$1',[oid]);
  if(f.rows.length)await db.query('update dispatch_assignments set vehicle_no=$2,trip_id=$3 where id=$1',[f.rows[0].id,vno,trip]);
  else await db.query('insert into dispatch_assignments(order_id,vehicle_no,trip_id) values($1,$2,$3)',[oid,vno,trip]);}
const lines=async v=>(await db.query("select amount,order_nos,route_name,trip_id,cancelled_at from lwb_hired_charges where vehicle_id=$1 and kind='TRIP' order by id",[v])).rows;

test('only Admin / Manager / Transport open trips; kind comes from Vehicle Master; numbers T-DDMM-NN',async()=>{
  await veh('GJ05OW1111','OWN');
  await as('sales');await assert.rejects(open({vehicle_no:'GJ05OW1111'}),/Only Admin \/ Manager \/ Transport/);
  await as('transport');
  await assert.rejects(open({vehicle_no:' '}),/vehicle number/);
  const a=await open({vehicle_no:'gj 05 ow 1111',driver_name:'Ramesh'});
  assert.equal(a.kind,'OWN');assert.match(a.trip_no,/^T-\d{4}-01$/);
  const b=await open({vehicle_no:'GJ05ZZ0001'});
  assert.equal(b.kind,'PORTER');assert.match(b.trip_no,/-02$/);assert.equal(b.rent,null);
  await assert.rejects(open({vehicle_no:'GJ05ZZ0001',rent:'-5'}),/Rent/);
});

test('Porter: rent optional at assign, popup list after 2 hours, set later, Accounts books one Cash Out',async()=>{
  await as('transport');
  const o=await order('PO-P1','Mahadev Hardware');
  const t=await open({vehicle_no:'GJ05BX4410',kind:'PORTER',driver_name:'Suresh',owner:'Porter',order_id:o});
  await assign(o,'GJ05BX4410',t.id);
  let due=await one('select public.lwb_trip_rent_due()');
  assert.equal(due.length,1);assert.equal(due[0].trip_no,t.trip_no);
  await db.query("update lwb_vehicle_trips set created_at=now()-interval '3 hours' where id=$1",[t.id]);
  due=await one('select public.lwb_trip_rent_due()');assert.equal(due[0].due,true);
  await as('manager');assert.equal((await one('select public.lwb_trip_rent_due()')).length,0);  // only the one who assigned
  await as('accounts');
  let L=await one('select public.lwb_trip_rent_list($1,$2)',[today,today]);
  assert.equal(L.find(x=>x.id===t.id).status,'NO_RENT');
  await assert.rejects(call('select public.lwb_trip_rent_book($1,$2::jsonb)',[t.id,'{}']),/Enter the rent/);
  await as('transport');
  await assert.rejects(call('select public.lwb_trip_rent_set($1,$2::jsonb)',[t.id,'{}']),/Enter the rent/);
  await call('select public.lwb_trip_rent_set($1,$2::jsonb)',[t.id,JSON.stringify({rent:650,pay_mode:'CASH',paid_by:'Rakesh'})]);
  assert.equal((await one('select public.lwb_trip_rent_due()')).length,0);
  await as('transport');await assert.rejects(call('select public.lwb_trip_rent_book($1,$2::jsonb)',[t.id,'{}']),/Only Accounts/);
  await as('accounts');
  L=await one('select public.lwb_trip_rent_list($1,$2)',[today,today]);
  const r=L.find(x=>x.id===t.id);assert.equal(r.status,'TO_BOOK');assert.equal(Number(r.rent),650);assert.equal(r.orders[0].order_no,'PO-P1');
  const eid=await one('select public.lwb_trip_rent_book($1,$2::jsonb)',[t.id,'{}']);
  const e=(await db.query('select e.kind,e.mode,e.amount,e.party,e.remark,c.name from lwb_acc_entries e join lwb_acc_categories c on c.id=e.category_id where e.id=$1',[eid])).rows[0];
  assert.equal(e.kind,'OUT');assert.equal(e.mode,'CASH');assert.equal(Number(e.amount),650);assert.equal(e.name,'Vehicle rent');
  assert.equal(e.party,'Porter · GJ05BX4410');assert.match(e.remark,/paid by Rakesh · PO-P1 Mahadev Hardware/);
  await assert.rejects(call('select public.lwb_trip_rent_book($1,$2::jsonb)',[t.id,'{}']),/already booked/);
  await as('transport');await assert.rejects(call('select public.lwb_trip_rent_set($1,$2::jsonb)',[t.id,'{"rent":700}']),/already booked/);
  await assert.rejects(open({vehicle_no:'GJ05BX4410',kind:'PORTER',order_id:o,rent:700}),/already booked/);
  // the Cash Out is cancelled: the trip is to book again
  await db.query('update lwb_acc_entries set cancelled_at=now() where id=$1',[eid]);
  await as('accounts');assert.equal((await one('select public.lwb_trip_rent_list($1,$2)',[today,today])).find(x=>x.id===t.id).status,'TO_BOOK');
  await assert.rejects(call('select public.lwb_trip_rent_cancel($1,$2)',[t.id,'']),/why/);
  await call('select public.lwb_trip_rent_cancel($1,$2)',[t.id,'Party paid the Porter']);
  assert.equal((await one('select public.lwb_trip_rent_list($1,$2)',[today,today])).find(x=>x.id===t.id).status,'CANCELLED');
});

test('per trip vehicle: 3 POs in one trip = one rent; 2nd trip same day = 2nd rent; PO moved out leaves the trip',async()=>{
  const v=await veh('GJ01TR2020');
  await as('manager');await save(v,{rent_type:'TRIP',trip_rate:900,start_date:dayAdd(today,-5)});
  await as('transport');
  const [a,b,c,d]=[await order('PO-T1','A Traders'),await order('PO-T2','B Traders'),await order('PO-T3','C Traders'),await order('PO-T4','D Traders')];
  const t1=await open({vehicle_no:'GJ01TR2020',order_id:a});
  assert.equal(t1.kind,'TRANSPORT');
  for(const o of [a,b,c])await assign(o,'GJ01TR2020',t1.id);
  let C=await lines(v);
  assert.equal(C.length,1);assert.equal(Number(C[0].amount),900);assert.deepEqual(C[0].order_nos,['PO-T1','PO-T2','PO-T3']);
  // the vehicle's open trip is offered to the next PO
  const f=await one('select public.lwb_trip_find($1)',['GJ01TR2020']);assert.equal(f.id,t1.id);assert.equal(f.orders.length,3);
  const j=await open({vehicle_no:'GJ01TR2020',join:true,order_id:d});assert.equal(j.id,t1.id);
  // once loaded, a new PO is a new trip
  await db.query("update orders set status='loaded' where id=$1",[a]);
  assert.equal(await one('select public.lwb_trip_find($1)',['GJ01TR2020']),null);
  const t2=await open({vehicle_no:'GJ01TR2020',join:true,order_id:d});assert.notEqual(t2.id,t1.id);
  await assign(d,'GJ01TR2020',t2.id);
  C=await lines(v);assert.equal(C.length,2);assert.equal(C.filter(x=>!x.cancelled_at).reduce((s,x)=>s+Number(x.amount),0),1800);
  // PO-T4 goes to an own vehicle: its trip has no PO left, the rent line is cancelled
  await veh('GJ01OW3030','OWN');
  const t3=await open({vehicle_no:'GJ01OW3030',order_id:d});
  await assign(d,'GJ01OW3030',t3.id);
  C=await lines(v);assert.ok(C.find(x=>x.trip_id===t2.id).cancelled_at);
  assert.equal((await db.query('select status from lwb_vehicle_trips where id=$1',[t2.id])).rows[0].status,'CANCELLED');
  // ledger shows the trip no.
  await as('accounts');const L=await one('select public.lwb_hired_ledger($1,$2,$3)',[v,today,today]);
  assert.equal(L.lines.filter(l=>l.src==='CHARGE').length,1);assert.equal(L.lines[0].trip_no,t1.trip_no);
});

test('per party vehicle: one trip, many parties = the highest verified rate; a waiting party raises it when verified',async()=>{
  const v=await veh('GJ05PT3321');
  await as('admin');await save(v,{rent_type:'PARTY',start_date:dayAdd(today,-3)});
  await call('select public.lwb_hired_rate_set($1,$2,700,null)',[v,'Mahadev Hardware']);
  await call('select public.lwb_hired_rate_set($1,$2,950,null)',[v,'Om Sai Agency']);
  await as('transport');
  const [a,b,c]=[await order('PO-Q1','Mahadev Hardware'),await order('PO-Q2','Om Sai Agency'),await order('PO-Q3','Shree Jagdish Traders')];
  const t=await open({vehicle_no:'GJ05PT3321',order_id:a});
  for(const o of [a,b,c])await assign(o,'GJ05PT3321',t.id);
  let C=(await lines(v)).filter(x=>!x.cancelled_at);
  assert.equal(C.length,1);assert.equal(Number(C[0].amount),950);assert.equal(C[0].route_name,'Mahadev Hardware, Om Sai Agency, Shree Jagdish Traders');
  const P=(await db.query("select party_name,status,trip_id from lwb_hired_pending where vehicle_id=$1",[v])).rows;
  assert.equal(P.length,1);assert.equal(P[0].party_name,'Shree Jagdish Traders');assert.equal(P[0].trip_id,t.id);
  // Manager sets 1,200 for the new party, Admin verifies: same one line goes to 1,200
  await as('manager');await call('select public.lwb_hired_rate_set($1,$2,1200,null)',[v,'Shree Jagdish Traders']);
  const rid=(await db.query("select id from lwb_hired_party_rates where vehicle_id=$1 and party_name='Shree Jagdish Traders'",[v])).rows[0].id;
  await as('admin');assert.equal(await one('select public.lwb_hired_rate_verify($1,true,null,null)',[rid]),1);
  C=(await lines(v)).filter(x=>!x.cancelled_at);
  assert.equal(C.length,1);assert.equal(Number(C[0].amount),1200);
  // a trip with only a not-yet-verified party: no line, waits
  await as('transport');const d=await order('PO-Q4','New Party');const t2=await open({vehicle_no:'GJ05PT3321',new:true,order_id:d});
  await assign(d,'GJ05PT3321',t2.id);
  assert.equal((await lines(v)).filter(x=>!x.cancelled_at).length,1);
  // assignment never fails because of the rent
  await db.query("update dispatch_assignments set vehicle_no='X' where order_id=$1",[d]);
});

test('old POs with no trip keep one line per day',async()=>{
  const v=await veh('GJ01OL4040');
  await as('manager');await save(v,{rent_type:'TRIP',trip_rate:500,start_date:dayAdd(today,-2)});
  const a=await order('PO-O1','X'),b=await order('PO-O2','Y');
  await db.query("insert into dispatch_assignments(order_id,vehicle_no) values($1,'GJ01OL4040'),($2,'GJ01OL4040')",[a,b]);
  const C=await lines(v);assert.equal(C.length,1);assert.equal(C[0].trip_id,null);assert.deepEqual(C[0].order_nos,['PO-O1','PO-O2']);
});
