import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_dial_find_setup.sql (Call button on every page) on PGlite, after the whole Dial Book chain.
// Live tables (party master, Goods Inward, ECRS trucks ...) are small stand-ins.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',acc:'00000000-0000-4000-8000-000000000004',
  sales:'00000000-0000-4000-8000-000000000005',cashier:'00000000-0000-4000-8000-000000000006',
  driver:'00000000-0000-4000-8000-000000000007',sales2:'00000000-0000-4000-8000-000000000008'};
const roles={admin:'admin',head:'manager',godown:'warehouse',acc:'accounts',sales:'sales',cashier:'cashier',driver:'driver',sales2:'sales'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE SCHEMA auth; CREATE SCHEMA extensions;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE FUNCTION extensions.gen_random_bytes(int) RETURNS bytea LANGUAGE sql AS $$ SELECT decode(md5(random()::text),'hex') $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.lwb_companies(id uuid primary key default gen_random_uuid(),name text);
CREATE TABLE public.lwb_customer_master(id uuid primary key default gen_random_uuid(),customer_name text,mobile text,city text,is_active boolean default true,brand_ids uuid[]);
CREATE TABLE public.lwb_party_salesman(customer_id uuid primary key,salesman_id uuid);
CREATE TABLE public.lwb_acc_staff(id bigserial primary key,name text,mobile text,designation text,active boolean default true);
CREATE TABLE public.lwb_ecrs_trucks(id bigserial primary key,day date,vehicle_no text,invoice_no text,sent_rows jsonb,dispatched_at timestamptz,updated_at timestamptz);
CREATE TABLE public.lwb_tracking_settings(id int primary key,godown_lat double precision,godown_lng double precision);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,is_read boolean default false);
CREATE TABLE public.lwb_transport_master(id uuid primary key default gen_random_uuid(),transport_name text,is_active boolean default true);
CREATE TABLE public.lwb_goods_inward(id bigserial primary key,invoice_no text,vehicle_no text,driver_name text,driver_mobile text,transport_name text,
  received_date date,created_at timestamptz default now(),time_out timestamptz);
CREATE FUNCTION public.lwb_pst_role() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true $$;
GRANT USAGE ON SCHEMA public, auth TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.lwb_pst_role() TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.lwb_goods_inward TO authenticated;
GRANT USAGE ON SEQUENCE public.lwb_goods_inward_id_seq TO authenticated;
INSERT INTO lwb_transport_master(transport_name) VALUES ('Vikas Road Lines'),('R K Trailer'),('Shree Ganesh Roadways');
-- Old purchase bills (before this file): same vehicle, driver changed once; one bill with a bad mobile
INSERT INTO lwb_goods_inward(invoice_no,vehicle_no,driver_name,driver_mobile,transport_name,received_date,created_at) VALUES
 ('A1','gj05bx4471','Suresh','9811100001','Vikas Road Lines','2026-10-01','2026-10-01 10:00+05:30'),
 ('A2','GJ05 BX 4471','Suresh','98111 00001','Vikas Road Lines','2026-10-10','2026-10-10 10:00+05:30'),
 ('A3','GJ-05-BX-4471','Ramesh','+91 9811100002','Vikas Road Lines','2026-11-20','2026-11-20 10:00+05:30'),
 ('A4','GJ16AU1234','','9811100003','R K Trailer','2026-11-21','2026-11-21 10:00+05:30'),
 ('A5','GJ16AU9999','X','12345','R K Trailer','2026-11-21','2026-11-21 10:00+05:30');
`);
let n=0;for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3,$4)',[id,roles[k].toUpperCase(),'Name '+k,'+91 98250 '+String(10000+(++n))]);
const file=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
for(const f of ['lwb_dial_book_setup.sql','lwb_dial_book_numbers_setup.sql','lwb_dial_services_setup.sql'])await db.exec(await file(f));
await db.exec((await file('lwb_gmail_sync_setup.sql')).replace(/CREATE EXTENSION[^;]*;/,''));
await db.exec(await file('lwb_ecrs_on_way_setup.sql'));
const mine=await file('lwb_vehicle_driver_history_setup.sql');
await db.exec(mine);await db.exec(mine); // safe to run again
await db.exec(await file('lwb_ecrs_on_way_setup.sql')); // run again after: still fine
await db.exec("INSERT INTO lwb_tracking_settings VALUES (1,21.2103,72.899) ON CONFLICT DO NOTHING");
const gm=await file('lwb_godown_map_link_setup.sql');await db.exec(gm);await db.exec(gm);
await db.exec(`ALTER TABLE lwb_transport_master ADD COLUMN IF NOT EXISTS created_by uuid;`);
const add=await file('lwb_transport_add_setup.sql');await db.exec(add);await db.exec(add);
const adm=await file('lwb_dial_calls_admin_only_setup.sql');await db.exec(adm);await db.exec(adm);
const co=await file('lwb_dial_company_setup.sql');await db.exec(co);await db.exec(co);

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const one=async(q,a)=>(await db.query(q,a)).rows[0];
const fnd=await file('lwb_dial_find_setup.sql');await db.exec(fnd);await db.exec(fnd); // safe to run again
const party=async(name,mob,sm)=>{const id=(await db.query('insert into lwb_customer_master(customer_name,mobile,city) values($1,$2,$3) returning id',[name,mob,'Surat'])).rows[0].id;
  if(sm)await db.query('insert into lwb_party_salesman values($1,$2)',[id,ids[sm]]);return id};
const pA=await party('SHREE JAGDISH TRADER','9876543312','sales');
const pB=await party('Navdurga Traders','93-7777-0770','sales2');
await party('NO MOBILE PARTY','',null);
const find=async(who,items)=>{await as(who);return (await call('select lwb_dial_find($1::jsonb) j',[JSON.stringify(items)]))[0].j};
const got=r=>r.map(x=>x.k+':'+x.v+'='+x.kind+':'+x.ref).sort();

test('Party by name (any spacing / case / dots) or id; no number given back', async()=>{
  const r=await find('acc',[{k:'PARTY',v:'shree jagdish  trader.'},{k:'PARTY',v:pB},{k:'PARTY',v:'NO MOBILE PARTY'},{k:'PARTY',v:'Unknown'}]);
  assert.deepEqual(got(r),['PARTY:'+pB+'=PARTY:'+pB,'PARTY:shree jagdish  trader.=PARTY:'+pA].sort());
  assert.ok(!/\d{10}/.test(JSON.stringify(r)),'no phone number');
});

test('Who finds what: salesman own parties only, Godown Manager no parties, driver nothing', async()=>{
  assert.deepEqual(got(await find('sales',[{k:'PARTY',v:'SHREE JAGDISH TRADER'},{k:'PARTY',v:'NAVDURGA TRADERS'}])),['PARTY:SHREE JAGDISH TRADER=PARTY:'+pA]);
  assert.deepEqual(await find('godown',[{k:'PARTY',v:'SHREE JAGDISH TRADER'}]),[]);
  assert.deepEqual(await find('driver',[{k:'PARTY',v:'SHREE JAGDISH TRADER'},{k:'USER',v:ids.admin}]),[]);
  await as('');assert.deepEqual((await call('select lwb_dial_find($1::jsonb) j',['[{"k":"PARTY","v":"x"}]']))[0].j,[]);
});

test('Own driver by login id or mobile; team by login id; truck by vehicle no.', async()=>{
  const r=await find('godown',[{k:'USER',v:ids.driver},{k:'MOB',v:'+91 98250 10007'},{k:'USER',v:ids.head},{k:'VEH',v:'gj-05-bx-4471'},{k:'VEH',v:'GJ01AA0001'},{k:'MOB',v:'12'}]);
  assert.deepEqual(got(r),['MOB:+91 98250 10007=DRIVER:'+ids.driver,'USER:'+ids.driver+'=DRIVER:'+ids.driver,'USER:'+ids.head+'=TEAM:'+ids.head,'VEH:gj-05-bx-4471=VEHICLE:GJ05BX4471'].sort());
  assert.deepEqual(await find('head',[{k:'USER',v:ids.head}]),[],'not myself');
  assert.deepEqual(got(await find('acc',[{k:'DRIVER',v:'name  DRIVER'},{k:'TEAM',v:'Name Sales'},{k:'DRIVER',v:'Name sales'},{k:'TEAM',v:''}])),
    ['DRIVER:name  DRIVER=DRIVER:'+ids.driver,'TEAM:Name Sales=TEAM:'+ids.sales].sort());
});

test('Found contact can be called (logged), others refused; bad input is quiet', async()=>{
  const [x]=await find('sales',[{k:'PARTY',v:'shree jagdish trader'}]);
  await as('sales');
  const c=(await call("select lwb_dial_call($1,$2,'Outstanding') j",[x.kind,x.ref]))[0].j;
  assert.equal(c.mobile,'9876543312');
  assert.equal((await one("select source,called_by from lwb_dial_calls where id=$1",[c.id])).source,'Outstanding');
  await assert.rejects(call("select lwb_dial_call('PARTY',$1,'Outstanding')",[pB]),/not in your Dial Book/);
  assert.deepEqual(await find('acc',{k:'PARTY'}),[]);
  assert.deepEqual(await find('acc',[1,'x',{k:'PARTY',v:''}]),[]);
  await as('acc');await assert.rejects(call('select lwb_dial_find($1::jsonb)',[JSON.stringify(Array.from({length:601},(_,i)=>({k:'PARTY',v:'P'+i})))]),/Too many/);
});
