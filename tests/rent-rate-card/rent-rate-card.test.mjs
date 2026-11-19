import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_rent_rate_card_setup.sql (after the hired / trip rent files) on PGlite: rent by vehicle size x party.
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
const cardSql=await sql('lwb_rent_rate_card_setup.sql');await db.exec(cardSql);await db.exec(cardSql); // safe to run again
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

test('one card rate (3 Ton + party) is used by every 3 Ton per party vehicle; other sizes wait',async()=>{
  const [a,b,c]=[await veh('GJ19Y9416'),await veh('GJ05XX0003'),await veh('GJ07TU7996')];
  await size(a,3);await size(b,3);await size(c,4);
  await as('admin');for(const v of [a,b,c])await save(v,{rent_type:'PARTY',start_date:dayAdd(today,-3)});
  await as('transport');
  const o1=await order('PO-C1','Shree Jagdish Trader','approved',2800),o2=await order('PO-C2','shree jagdish trader ','approved',1500),o3=await order('PO-C3','Shree Jagdish Trader','approved',3900);
  const t1=await open({vehicle_no:'GJ19Y9416',order_id:o1});await assign(o1,'GJ19Y9416',t1.id);
  const t2=await open({vehicle_no:'GJ05XX0003',order_id:o2});await assign(o2,'GJ05XX0003',t2.id);
  const t3=await open({vehicle_no:'GJ07TU7996',order_id:o3});await assign(o3,'GJ07TU7996',t3.id);
  assert.equal((await live(a)).length,0); // waits for a rate
  // Manager: WAITING, nothing posted; Admin verifies -> both 3 Ton vehicles get their line, the 4 Ton one still waits
  await as('manager');assert.equal((await one('select public.lwb_rate_card_set(3,$1,1500,null)',['Shree Jagdish Trader'])).status,'WAITING');
  assert.equal((await live(a)).length,0);
  await assert.rejects(call('select public.lwb_rate_card_verify(1,true,null,null)'),/Only Admin/);
  const cid=(await db.query("select id from lwb_hired_rate_card where size_ton=3")).rows[0].id;
  await as('admin');assert.equal(await one('select public.lwb_rate_card_verify($1,true,null,null)',[cid]),2);
  assert.equal(Number((await live(a))[0].amount),1500);assert.equal(Number((await live(b))[0].amount),1500);
  assert.equal((await live(c)).length,0);
  // Admin sets the 4 Ton rate: posted at once
  assert.equal((await one('select public.lwb_rate_card_set(4,$1,1700,null)',['SHREE JAGDISH TRADER'])).posted,1);
  assert.equal(Number((await live(c))[0].amount),1700);
  // Manager can not change a verified card rate
  await as('manager');await assert.rejects(call('select public.lwb_rate_card_set(4,$1,1,null)',['Shree Jagdish Trader']),/already verified/);
});

test("a vehicle's own rate wins over the card; a new trip uses the card by itself; size change moves card rates",async()=>{
  const v=await veh('GJ05OWN777');await size(v,3);
  await as('admin');await save(v,{rent_type:'PARTY',start_date:dayAdd(today,-3)});
  // card rate of 3 Ton for Jagdish already exists (1500): copied on save
  const q=(await db.query("select rate,from_card from lwb_hired_party_rates where vehicle_id=$1",[v])).rows;
  assert.equal(q.length,1);assert.equal(Number(q[0].rate),1500);assert.equal(q[0].from_card,true);
  await call('select public.lwb_hired_rate_set($1,$2,1650,null)',[v,'Shree Jagdish Trader']); // special rate for this vehicle
  await call('select public.lwb_rate_card_set(3,$1,1550,null)',['Shree Jagdish Trader']);           // card changes: special stays
  assert.equal(Number((await db.query("select rate from lwb_hired_party_rates where vehicle_id=$1",[v])).rows[0].rate),1650);
  await as('transport');const o=await order('PO-C9','Shree Jagdish Trader','approved',2000);
  const t=await open({vehicle_no:'GJ05OWN777',order_id:o});await assign(o,'GJ05OWN777',t.id);
  assert.equal(Number((await live(v))[0].amount),1650);
  // another 3 Ton vehicle follows the new card rate
  const b=(await db.query("select id from lwb_vehicles where vehicle_no='GJ05XX0003'")).rows[0].id;
  assert.equal(Number((await db.query("select rate from lwb_hired_party_rates where vehicle_id=$1",[b])).rows[0].rate),1550);
  // size 3 -> 4: card rates follow the new size
  await size(b,4);
  assert.equal(Number((await db.query("select rate from lwb_hired_party_rates where vehicle_id=$1",[b])).rows[0].rate),1700);
});

test('lists: Trip rent to set carries size, load and card; ledger lines carry the load',async()=>{
  await as('transport');const o=await order('PO-C10','Bankiyarani Super Store','approved',2600.5);
  const t=await open({vehicle_no:'GJ19Y9416',new:true,order_id:o});await assign(o,'GJ19Y9416',t.id);
  await as('manager');await call('select public.lwb_rate_card_set(3,$1,900,null)',['Bankiyarani Super Store']);
  const L=await one('select public.lwb_hired_rate_list2()');
  const g=L.groups.find(x=>x.party==='Bankiyarani Super Store');
  assert.equal(Number(g.size_ton),3);assert.equal(Number(g.load_kg),2600.5);assert.equal(g.card.status,'WAITING');assert.equal(Number(g.card.rate),900);
  assert.ok(L.card.some(c=>Number(c.size_ton)===4&&Number(c.rate)===1700&&c.vehicles===2));
  assert.deepEqual(L.sizes.map(Number),[3,4]);
  assert.ok(L.rates.some(r=>r.from_card===true));
  await as('accounts');const v=(await db.query("select id from lwb_vehicles where vehicle_no='GJ19Y9416'")).rows[0].id;
  const G=await one('select public.lwb_hired_ledger2($1,$2,$3)',[v,dayAdd(today,-5),today]);
  assert.equal(Number(G.vehicle.size_ton),3);
  assert.ok(G.lines.some(l=>l.src==='CHARGE'&&Number(l.load_kg)===2800));
  assert.ok(G.lines.some(l=>l.src==='PENDING'&&Number(l.load_kg)===2600.5));
});
