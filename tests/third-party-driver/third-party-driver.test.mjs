import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_third_party_driver_setup.sql on PGlite: third-party drivers stay in Employee Master (driver pick list)
// but get no salary / advance, and the list shows their Transport Assignment trips this month.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',acc:'00000000-0000-4000-8000-000000000004',
  sales:'00000000-0000-4000-8000-000000000005',transport:'00000000-0000-4000-8000-000000000006',
  driver:'00000000-0000-4000-8000-000000000007',ticked:'00000000-0000-4000-8000-000000000008'};
const roles={admin:'admin',head:'manager',godown:'warehouse',acc:'accounts',sales:'sales',transport:'transport',driver:'driver',ticked:'sales'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE SCHEMA storage;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.lwb_user_page_access(user_id uuid,extra text[]);
CREATE FUNCTION public.lwb_has_page(p text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS(SELECT 1 FROM public.lwb_user_page_access a WHERE a.user_id=auth.uid() AND p=ANY(a.extra)) $$;
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,driver_name text,driver_mobile text,vehicle_no text,assigned_at timestamptz default now());
CREATE TABLE public.lwb_tally_invoices(order_id uuid,invoice_no text);
CREATE TABLE public.lwb_tally_payments(id uuid default gen_random_uuid() primary key,receipt_id uuid,order_id uuid,pay_date date,mode text,amount numeric(14,2),ref_no text,cash_notes jsonb,remark text,created_by uuid,created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,delivery_status text,driver_user_id uuid,cash_reported numeric(14,2) default 0,payment_mode text,payment_reference text,cash_amount numeric(14,2),online_amount numeric(14,2),online_mode text,online_reference text,bank_ref text,payment_status text,payment_reviewed_by uuid,payment_reviewed_at timestamptz);
CREATE TABLE public.tax_invoices(id uuid primary key,order_id uuid);
CREATE TABLE public.lwb_payment_collections(id uuid default gen_random_uuid() primary key,invoice_id uuid,collection_date date,amount numeric(14,2),payment_mode text,reference_no text,remarks text,status text,submitted_by uuid,submitted_at timestamptz default now(),reviewed_at timestamptz);
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(id bigserial primary key,bucket_id text,name text);
CREATE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT (string_to_array(name,'/'))[1:array_length(string_to_array(name,'/'),1)-1] $$;
CREATE FUNCTION storage.filename(name text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT (string_to_array(name,'/'))[array_length(string_to_array(name,'/'),1)] $$;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k],'Name '+k]);
await db.query("insert into lwb_user_page_access values($1,ARRAY['warehouse-orders.html'])",[ids.ticked]);
for(const f of ['lwb_fleet_master_setup.sql','lwb_accounts_dashboard_setup.sql','lwb_accounts_staff_setup.sql','lwb_accounts_vehicle_setup.sql',
  'lwb_employee_master_setup.sql','lwb_documents_setup.sql','lwb_employee_roles_setup.sql'])await db.exec(await sql(f));
await db.exec('GRANT USAGE ON SCHEMA public,auth,storage TO authenticated');
const tpSql=await sql('lwb_third_party_driver_setup.sql');

const veh=(await db.query("insert into lwb_vehicles(vehicle_no,vehicle_type,ownership,transporter_name) values('GJ19Y9416','Pickup','TRANSPORTER','U&B PAWAR'),('GJ05AB1111','Tempo','OWN',null) returning id")).rows.map(r=>r.id);
// LWB0146 = third-party driver (to be marked by the SQL), LWB0150 = own driver, LWB0151 = loader
await db.query(`insert into lwb_acc_staff(emp_code,name,mobile,designation,monthly_salary,default_vehicle_id,transporter_name) values
 ('LWB0146','UMESH PAWAR','9607081954','Driver',20000,$1,'U&B PAWAR'),
 ('LWB0150','OWN DRIVER','9000000011','Driver',18000,$2,null),
 ('LWB0151','LOADER ONE','9000000012','Loader',12000,null,null)`,[veh[0],veh[1]]);
const sid=async c=>(await db.query('select id from lwb_acc_staff where emp_code=$1',[c])).rows[0].id;
await db.query(`insert into lwb_acc_staff_salary(staff_id,month,amount,created_by) values($1,date_trunc('month',now())::date,20000,'00000000-0000-4000-8000-000000000001')`,[await sid('LWB0146')]);
// Trips this month: 2 POs same day same vehicle (1 trip), 1 PO next day (another trip), 1 cancelled PO.
const o=(await db.query(`insert into orders(order_no,customer_name,status) values('PO1','A','delivered'),('PO2','B','delivered'),('PO3','C','loaded'),('PO4','D','cancelled') returning id`)).rows.map(r=>r.id);
const day1=new Date();day1.setUTCDate(1);day1.setUTCHours(6,0,0,0);const day2=new Date(day1);day2.setUTCDate(2);
for(const [i,d,mob] of [[0,day1,'+91 96070 81954'],[1,day1,null],[2,day2,'9607081954'],[3,day2,'9607081954']])
  await db.query("insert into dispatch_assignments(order_id,driver_name,driver_mobile,vehicle_no,assigned_at) values($1,'UMESH',$2,'GJ 19 Y 9416',$3)",[o[i],mob,d]);

await db.exec(tpSql);await db.exec(tpSql); // safe to run again

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const staff=async c=>(await db.query('select * from lwb_acc_staff where emp_code=$1',[c])).rows[0];
const list=async()=>{await as('admin');return (await call('select lwb_emp_list2() j'))[0].j.rows};

test('LWB0146 is marked third-party: no salary, salary row of this month removed', async()=>{
  const s=await staff('LWB0146');assert.equal(s.third_party,true);assert.equal(Number(s.monthly_salary),0);
  assert.equal((await db.query('select count(*)::int n from lwb_acc_staff_salary where staff_id=$1',[s.id])).rows[0].n,0);
  assert.equal((await staff('LWB0150')).third_party,false);assert.equal(Number((await staff('LWB0150')).monthly_salary),18000);
});

test('Employee Master list: third_party flag, cap 0, trips this month from Transport Assignment', async()=>{
  const rows=await list();const u=rows.find(r=>r.emp_code==='LWB0146'),d=rows.find(r=>r.emp_code==='LWB0150');
  assert.equal(u.third_party,true);assert.equal(Number(u.month_cap),0);assert.equal(u.vehicle_ownership,'TRANSPORTER');
  assert.deepEqual(u.month_trips,{trips:2,pos:3});
  assert.equal(d.third_party,false);assert.equal(d.month_trips,null);
});

test('save: Driver can be set third-party and back; non-driver refused; flag kept when left out', async()=>{
  await as('head');
  const base={name:'OWN DRIVER',mobile:'9000000011',designation:'Driver',monthly_salary:18000,is_active:true};
  const id=await sid('LWB0150');
  await call('select lwb_emp_save2($1)',[{...base,id,emp_code:'LWB0150',third_party:true}]);
  let s=await staff('LWB0150');assert.equal(s.third_party,true);assert.equal(Number(s.monthly_salary),0);
  await call('select lwb_emp_save2($1)',[{...base,id,emp_code:'LWB0150',monthly_salary:5}]); // flag left out = kept
  s=await staff('LWB0150');assert.equal(s.third_party,true);assert.equal(Number(s.monthly_salary),0);
  await call('select lwb_emp_save2($1)',[{...base,id,emp_code:'LWB0150',third_party:false,monthly_salary:18000}]);
  s=await staff('LWB0150');assert.equal(s.third_party,false);assert.equal(Number(s.monthly_salary),18000);
  await assert.rejects(call('select lwb_emp_save2($1)',[{name:'LOADER ONE',mobile:'9000000012',designation:'Loader',monthly_salary:12000,is_active:true,id:await sid('LWB0151'),emp_code:'LWB0151',third_party:true}]),/Only a Driver/);
});

test('Accounts staff list carries third_party; driver pick list still has the third-party driver', async()=>{
  await as('acc');const st=(await call('select lwb_acc_staff_list(now()::date) j'))[0].j;
  assert.equal(st.find(x=>x.emp_code==='LWB0146').third_party,true);
  await as('admin');const p=(await call("select lwb_staff_pick('driver') j"))[0].j;
  assert.ok(p.some(x=>x.emp_code==='LWB0146'));
});
