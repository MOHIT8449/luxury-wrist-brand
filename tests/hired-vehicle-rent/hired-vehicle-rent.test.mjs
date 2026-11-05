import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_hired_vehicle_rent_setup.sql on a tiny copy of the tables it reads (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',accounts:'00000000-0000-4000-8000-000000000002',manager:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004',warehouse:'00000000-0000-4000-8000-000000000006'};
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
for(const f of ['lwb_accounts_staff_setup.sql','lwb_accounts_vehicle_setup.sql','lwb_employee_master_setup.sql','lwb_hired_vehicle_rent_setup.sql','lwb_hired_auto_trip_setup.sql','lwb_hired_party_rate_setup.sql'])await db.exec(await sql(f));
// safe to run again
await db.exec(await sql('lwb_hired_vehicle_rent_setup.sql'));
await db.exec(await sql('lwb_hired_auto_trip_setup.sql'));
await db.exec(await sql('lwb_hired_party_rate_setup.sql'));await db.exec(await sql('lwb_hired_party_rate_setup.sql'));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

const today=(await db.query("select public.lwb_acc_today()::text d")).rows[0].d;
const dayAdd=(d,n)=>{const x=new Date(d+'T12:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10)};
const monthStart=today.slice(0,8)+'01',prevMonth=dayAdd(monthStart,-1).slice(0,8)+'01';
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const one=async(q,args)=>Object.values((await call(q,args))[0])[0];
const cat=async(kind,name)=>(await db.query('select id from lwb_acc_categories where kind=$1 and name=$2',[kind,name])).rows[0].id;
const veh=async no=>(await db.query("insert into lwb_vehicles(vehicle_no,vehicle_type,ownership,transporter_name) values($1,'Pickup','OWN','Jay Khodiyar') returning id",[no])).rows[0].id;
const save=(v,p)=>call('select public.lwb_hired_save($1,$2::jsonb)',[v,JSON.stringify(p)]);
const add=p=>one('select public.lwb_hired_add($1::jsonb)',[JSON.stringify(p)]);
const out=p=>one('select public.lwb_acc_add_entry4($1::jsonb)',[JSON.stringify({date:today,kind:'OUT',mode:'CASH',...p})]);
const list=async(f,t)=>(await one('select public.lwb_hired_list($1,$2)',[f,t]));
const ledger=async(v,f,t)=>(await one('select public.lwb_hired_ledger($1,$2,$3)',[v,f,t]));

test('setup: only Admin / Manager set rent; vehicle becomes Transporter; routes kept by name',async()=>{
  const v=await veh('GJ05CX1100');
  await as('accounts');await assert.rejects(save(v,{rent_type:'ROUTE',start_date:today,routes:[{name:'Rajkot to Gondal',rate:1500}]}),/Only Admin \/ Manager/);
  await as('warehouse');await assert.rejects(save(v,{rent_type:'ROUTE',start_date:today,routes:[{name:'Rajkot to Gondal',rate:1500}]}),/Only Admin \/ Manager/);
  await as('manager');
  await assert.rejects(save(v,{rent_type:'ROUTE',start_date:today,routes:[]}),/at least one route/);
  await assert.rejects(save(v,{rent_type:'ROUTE',start_date:today,routes:[{name:'A to B',rate:10},{name:'a to b ',rate:20}]}),/written twice/);
  await assert.rejects(save(v,{rent_type:'MONTHLY',start_date:today}),/monthly rent/);
  await save(v,{rent_type:'ROUTE',start_date:today,opening_balance:500,routes:[{name:'Rajkot to Gondal',rate:1500},{name:'Rajkot to Jetpur',rate:1800}]});
  assert.equal((await db.query('select ownership from lwb_vehicles where id=$1',[v])).rows[0].ownership,'TRANSPORTER');
  await save(v,{rent_type:'ROUTE',start_date:today,opening_balance:500,routes:[{name:'Rajkot to Gondal',rate:1600}]});
  const s=(await one('select public.lwb_hired_setups()')).find(x=>x.vehicle_id===v);
  assert.deepEqual(s.routes.map(r=>[r.name,Number(r.rate)]),[['Rajkot to Gondal',1600]]);
  await as('sales');await assert.rejects(call('select public.lwb_hired_setups()'),/Accounts/);
});

test('route trips + extra + rent paid + diesel cut give the balance; other heads only when cut is on',async()=>{
  const v=(await db.query("select id from lwb_vehicles where vehicle_no='GJ05CX1100'")).rows[0].id;
  await as('accounts');
  await assert.rejects(add({vehicle_id:v,date:today,route:'Nowhere',trips:1}),/Choose the route/);
  await assert.rejects(add({vehicle_id:v,date:dayAdd(today,1),route:'Rajkot to Gondal',trips:1}),/up to today/);
  await assert.rejects(add({vehicle_id:v,date:dayAdd(today,-1),route:'Rajkot to Gondal',trips:1}),/starts on/);
  await add({vehicle_id:v,date:today,route:'rajkot to gondal',trips:3,extra:200,orders:['PO-1']});
  await add({vehicle_id:v,date:today,kind:'EXTRA',amount:-300,remark:'One day off'});
  await assert.rejects(add({vehicle_id:v,date:today,kind:'EXTRA',amount:100,remark:''}),/what the amount is for/);
  await out({category_id:await cat('OUT','Vehicle rent'),amount:2000,vehicle_id:v});
  await out({category_id:await cat('OUT','Diesel / Fuel'),amount:700,vehicle_id:v});
  await out({category_id:await cat('OUT','Diesel / Fuel'),amount:999});            // not on this vehicle
  let r=(await list(today,today)).find(x=>x.id===v);
  assert.equal(Number(r.rent),3*1600+200-300);assert.equal(Number(r.trips),3);
  assert.equal(Number(r.paid),2000);assert.equal(Number(r.cut),700);
  assert.equal(Number(r.balance),500+4700-2000-700);
  const L=await ledger(v,today,today);
  assert.equal(Number(L.opening),500);assert.equal(L.lines.length,4);
  assert.equal(L.lines.reduce((a,l)=>a+Number(l.amount),0),4700-2700);
  // cut off: diesel stays an expense only
  await as('admin');await save(v,{rent_type:'ROUTE',start_date:today,opening_balance:500,cut_expenses:false,routes:[{name:'Rajkot to Gondal',rate:1600}]});
  await as('accounts');r=(await list(today,today)).find(x=>x.id===v);
  assert.equal(Number(r.cut),0);assert.equal(Number(r.balance),500+4700-2000);
  // cancel a line
  const ex=(await db.query("select id from lwb_hired_charges where vehicle_id=$1 and kind='EXTRA'",[v])).rows[0].id;
  await assert.rejects(call('select public.lwb_hired_cancel($1,$2)',[ex,'']),/why/);
  await call('select public.lwb_hired_cancel($1,$2)',[ex,'entered wrong']);
  r=(await list(today,today)).find(x=>x.id===v);assert.equal(Number(r.rent),3*1600+200);
});

test('monthly: rent added on the 1st of every month, first month for the days only, once',async()=>{
  const v=await veh('GJ03BW4521');
  // start on the 11th of last month
  const start=prevMonth.slice(0,8)+'11';
  const days=new Date(Date.UTC(+prevMonth.slice(0,4),+prevMonth.slice(5,7),0)).getUTCDate();
  await as('admin');await save(v,{rent_type:'MONTHLY',monthly_rent:22000,start_date:start});
  await as('accounts');
  await assert.rejects(add({vehicle_id:v,date:today,trips:1}),/monthly rent/);
  assert.equal(await one('select public.lwb_hired_post_months()'),2);
  assert.equal(await one('select public.lwb_hired_post_months()'),0);
  const rows=(await db.query("select month::text m,amount,charge_date::text d from lwb_hired_charges where vehicle_id=$1 order by month",[v])).rows;
  assert.deepEqual(rows.map(x=>[x.m,Number(x.amount)]),[[prevMonth,Math.round(22000*(days-10)/days)],[monthStart,22000]]);
  assert.equal(rows[0].d,start);
  // a cancelled month is not added again
  const m=(await db.query("select id from lwb_hired_charges where vehicle_id=$1 and month=$2",[v,monthStart])).rows[0].id;
  await call('select public.lwb_hired_cancel($1,$2)',[m,'vehicle off this month']);
  assert.equal(await one('select public.lwb_hired_post_months()'),0);
  // start date can not move past rent already added
  await as('admin');await assert.rejects(save(v,{rent_type:'MONTHLY',monthly_rent:22000,start_date:monthStart}),/already added before/);
  // not hired any more: no new months, ledger kept in the list
  await save(v,{active:false});
  await as('accounts');const r=(await list(prevMonth,today)).find(x=>x.id===v);
  assert.equal(r.active,false);assert.equal(Number(r.rent),Math.round(22000*(days-10)/days));
  await as('sales');await assert.rejects(call('select public.lwb_hired_post_months()'),/Accounts/);
});

test('per trip: assigning orders adds one trip for the day by itself; days list shows it',async()=>{
  const v=await veh('GJ01DT7788');
  await as('manager');await save(v,{rent_type:'TRIP',trip_rate:900,start_date:dayAdd(today,-5)});
  const o1=(await db.query("insert into orders(order_no,status) values('PO-11','delivered'),('PO-12','loaded'),('PO-13','cancelled') returning id")).rows.map(x=>x.id);
  await db.query("insert into dispatch_assignments(order_id,vehicle_no,assigned_at) values($1,'GJ 01 DT 7788',now()),($2,'gj01dt7788',now()),($3,'GJ01DT7788',now())",o1);
  let C=(await db.query("select trips,amount,order_nos,auto from lwb_hired_charges where vehicle_id=$1 and cancelled_at is null",[v])).rows;
  assert.equal(C.length,1);assert.equal(C[0].auto,true);assert.equal(Number(C[0].amount),900);assert.deepEqual(C[0].order_nos,['PO-11','PO-12']);
  await as('accounts');
  let D=await one('select public.lwb_hired_dispatch_days($1,$2,$3)',[v,dayAdd(today,-5),today]);
  assert.equal(D.length,1);assert.deepEqual(D[0].orders.sort(),['PO-11','PO-12']);assert.equal(Number(D[0].added),1);
  // a second trip that day by hand
  await add({vehicle_id:v,date:D[0].date,trips:1});
  D=await one('select public.lwb_hired_dispatch_days($1,$2,$3)',[v,dayAdd(today,-5),today]);
  assert.equal(Number(D[0].added),2);
  const r=(await list(dayAdd(today,-5),today)).find(x=>x.id===v);assert.equal(Number(r.rent),1800);
  const L=await ledger(v,today,today);assert.equal(L.lines.filter(l=>l.auto).length,1);
});

test('auto trip: route rate, monthly / own vehicle untouched, order moved, cancelled day stays, fill from start',async()=>{
  const rv=(await db.query("select id from lwb_vehicles where vehicle_no='GJ05CX1100'")).rows[0].id;
  const own=await veh('GJ05AB1234'),mon=(await db.query("select id from lwb_vehicles where vehicle_no='GJ03BW4521'")).rows[0].id;
  const o=async no=>(await db.query("insert into orders(order_no,status) values($1,'loaded') returning id",[no])).rows[0].id;
  const before=async v=>(await db.query("select count(*)::int n from lwb_hired_charges where vehicle_id=$1",[v])).rows[0].n;
  const nMon=await before(mon);
  const a=await o('PO-21'),b=await o('PO-22'),c=await o('PO-23');
  // GJ05CX1100 already has a hand trip today: the order joins it, no new line
  await db.query("insert into dispatch_assignments(order_id,vehicle_no) values($1,'GJ05CX1100')",[a]);
  let R=(await db.query("select order_nos,auto from lwb_hired_charges where vehicle_id=$1 and kind='TRIP' and cancelled_at is null",[rv])).rows;
  assert.equal(R.length,1);assert.equal(R[0].auto,false);assert.deepEqual(R[0].order_nos,['PO-1','PO-21']);
  // monthly and own vehicles: nothing
  await db.query("insert into dispatch_assignments(order_id,vehicle_no) values($1,'GJ03BW4521'),($2,'GJ05AB1234')",[b,c]);
  assert.equal(await before(mon),nMon);assert.equal(await before(own),0);
  // a new route vehicle gets its first route's rate; moving the order away cancels the auto line, moving back revives it
  const nv=await veh('GJ10ZZ5555');
  await as('admin');await save(nv,{rent_type:'ROUTE',start_date:dayAdd(today,-3),routes:[{name:'Surat to Navsari',rate:1200},{name:'Surat to Bardoli',rate:1400}]});
  const d=await o('PO-31');
  const da=(await db.query("insert into dispatch_assignments(order_id,vehicle_no) values($1,'GJ10ZZ5555') returning id",[d])).rows[0].id;
  R=(await db.query("select route_name,amount from lwb_hired_charges where vehicle_id=$1 and cancelled_at is null",[nv])).rows;
  assert.deepEqual(R.map(x=>[x.route_name,Number(x.amount)]),[['Surat to Navsari',1200]]);
  await db.query("update dispatch_assignments set vehicle_no='GJ05AB1234' where id=$1",[da]);
  assert.equal((await db.query("select count(*)::int n from lwb_hired_charges where vehicle_id=$1 and cancelled_at is null",[nv])).rows[0].n,0);
  await db.query("update dispatch_assignments set vehicle_no='GJ10ZZ5555' where id=$1",[da]);
  assert.equal((await db.query("select count(*)::int n from lwb_hired_charges where vehicle_id=$1 and cancelled_at is null",[nv])).rows[0].n,1);
  // Accounts cancels the day: a new order that day does not bring it back
  const id=(await db.query("select id from lwb_hired_charges where vehicle_id=$1",[nv])).rows[0].id;
  await as('accounts');await call('select public.lwb_hired_cancel($1,$2)',[id,'did not go']);
  await db.query("insert into dispatch_assignments(order_id,vehicle_no) values($1,'GJ10ZZ5555')",[await o('PO-32')]);
  assert.equal((await db.query("select count(*)::int n from lwb_hired_charges where vehicle_id=$1 and cancelled_at is null",[nv])).rows[0].n,0);
  // fill: assignments from before the rent setup come in from the start date
  const fv=await veh('GJ06FF1111');
  const e=await o('PO-41'),f=await o('PO-42');
  await db.query("insert into dispatch_assignments(order_id,vehicle_no,assigned_at) values($1,'GJ06FF1111',now()-interval '2 days'),($2,'GJ06FF1111',now()-interval '9 days')",[e,f]);
  await as('admin');await save(fv,{rent_type:'TRIP',trip_rate:500,start_date:dayAdd(today,-4)});
  assert.equal(await one('select public.lwb_hired_auto_fill($1)',[fv]),1);
  assert.equal(await one('select public.lwb_hired_auto_fill($1)',[fv]),0);
  await as('sales');await assert.rejects(call('select public.lwb_hired_auto_fill($1)',[fv]),/Accounts/);
});

test('per party: first rate by Manager, Admin verifies, then it adds by itself; 2 parties = 2 lines',async()=>{
  const v=await veh('GJ05PT3321');
  await as('manager');await save(v,{rent_type:'PARTY',start_date:dayAdd(today,-3)});
  const o=async(no,party)=>(await db.query("insert into orders(order_no,customer_name,status) values($1,$2,'loaded') returning id",[no,party])).rows[0].id;
  const asg=async(id,ago=0)=>db.query("insert into dispatch_assignments(order_id,vehicle_no,assigned_at) values($1,'GJ05PT3321',now()-($2||' days')::interval)",[id,String(ago)]);
  const live=async()=>(await db.query("select charge_date::text d,route_name,party_key,amount,order_nos,auto from lwb_hired_charges where vehicle_id=$1 and cancelled_at is null order by charge_date,id",[v])).rows;
  await asg(await o('PO-61','Shree Jagdish Traders (Bardoli)'),1);
  await asg(await o('PO-62','SHREE  JAGDISH TRADERS (BARDOLI)'),1);   // same party, other spelling, same day
  await asg(await o('PO-63','Patel Stores (Gondal)'),1);
  assert.equal((await live()).length,0);
  let L=await one('select public.lwb_hired_rate_list()');
  assert.equal(L.groups.length,2);
  const g=L.groups.find(x=>x.party_key==='SHREE JAGDISH TRADERS (BARDOLI)');assert.deepEqual(g.orders.sort(),['PO-61','PO-62']);assert.equal(Number(g.days),1);
  // ledger shows the waiting days, not in the balance
  await as('accounts');
  let led=await ledger(v,dayAdd(today,-3),today);assert.equal(led.lines.filter(l=>l.src==='PENDING').length,2);
  assert.equal(Number((await list(dayAdd(today,-3),today)).find(x=>x.id===v).balance),0);
  await assert.rejects(call('select public.lwb_hired_rate_set($1,$2,1200,null)',[v,'Shree Jagdish Traders (Bardoli)']),/Admin \/ Manager/);
  // Manager sets -> WAITING, bell to Admin; nothing in the ledger yet
  await as('manager');
  await assert.rejects(call('select public.lwb_hired_rate_set($1,$2,0,null)',[v,'Shree Jagdish Traders (Bardoli)']),/Enter the rent/);
  assert.equal(await one('select public.lwb_hired_rate_set($1,$2,1200,null)',[v,'shree jagdish traders (bardoli)']),'WAITING');
  assert.equal((await db.query("select count(*)::int n from erp_notifications where notification_type='HIRED_RATE_VERIFY' and user_id=$1",[ids.admin])).rows[0].n,1);
  assert.equal((await live()).length,0);
  const rid=(await db.query("select id from lwb_hired_party_rates where vehicle_id=$1 and status='WAITING'",[v])).rows[0].id;
  await assert.rejects(call('select public.lwb_hired_rate_verify($1,true,null,null)',[rid]),/Only Admin/);
  // Admin sends back, Manager sets again, Admin verifies with a changed rate
  await as('admin');
  await assert.rejects(call('select public.lwb_hired_rate_verify($1,false,null,$2)',[rid,'']),/why/);
  await call('select public.lwb_hired_rate_verify($1,false,null,$2)',[rid,'Too high, ask again']);
  assert.equal((await db.query("select count(*)::int n from erp_notifications where notification_type='HIRED_RATE_SENT_BACK' and user_id=$1",[ids.manager])).rows[0].n,1);
  await as('manager');await call('select public.lwb_hired_rate_set($1,$2,1150,null)',[v,'Shree Jagdish Traders (Bardoli)']);
  await as('admin');assert.equal(await one('select public.lwb_hired_rate_verify($1,true,1100,null)',[rid]),1);
  let C=await live();assert.equal(C.length,1);assert.equal(Number(C[0].amount),1100);assert.deepEqual(C[0].order_nos.sort(),['PO-61','PO-62']);
  // Manager can not change a verified rate; next trip to that party adds by itself
  await as('manager');await assert.rejects(call('select public.lwb_hired_rate_set($1,$2,900,null)',[v,'Shree Jagdish Traders (Bardoli)']),/already verified/);
  await asg(await o('PO-64','Shree Jagdish Traders (Bardoli)'),0);
  C=await live();assert.equal(C.length,2);assert.equal(Number(C[1].amount),1100);assert.equal(C[1].auto,true);
  // Admin sets a new party's rate: verified at once; 2 parties the same day = 2 lines
  await as('admin');assert.equal(await one('select public.lwb_hired_rate_set($1,$2,1000,null)',[v,'Patel Stores (Gondal)']),'VERIFIED');
  await asg(await o('PO-65','Patel Stores (Gondal)'),0);
  C=await live();assert.equal(C.length,4);
  assert.deepEqual(C.filter(c=>c.d===today).map(c=>[c.route_name,Number(c.amount)]).sort(),[['Patel Stores (Gondal)',1000],['Shree Jagdish Traders (Bardoli)',1100]]);
  L=await one('select public.lwb_hired_rate_list()');assert.equal(L.groups.length,0);
  // + Trip by hand for a verified party; an unknown party is refused
  await as('accounts');
  await add({vehicle_id:v,date:today,route:'patel stores (gondal)',trips:1});
  await assert.rejects(add({vehicle_id:v,date:today,route:'Nobody',trips:1}),/Choose the party/);
  // order moved away from a waiting day: the day goes away
  await as('manager');
  const mv=await o('PO-66','New Party (Surat)');await asg(mv,0);
  assert.equal((await one('select public.lwb_hired_rate_list()')).groups.length,1);
  await db.query("update dispatch_assignments set vehicle_no='GJ05AB1234' where order_id=$1",[mv]);
  assert.equal((await one('select public.lwb_hired_rate_list()')).groups.length,0);
  await as('accounts');await assert.rejects(call('select public.lwb_hired_rate_list()'),/Admin \/ Manager/);
});
