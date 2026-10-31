import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_employee_roles_setup.sql on an empty PGlite database (no live data): Driver Master rows are copied
// into Employee Master once, their documents move with them, and the pick list gives employees by Work / Post.
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
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text);
CREATE TABLE public.lwb_tally_invoices(order_id uuid,invoice_no text);
CREATE TABLE public.lwb_tally_payments(id uuid default gen_random_uuid() primary key,receipt_id uuid,order_id uuid,pay_date date,mode text,amount numeric(14,2),ref_no text,cash_notes jsonb,remark text,created_by uuid,created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,driver_user_id uuid,cash_reported numeric(14,2) default 0,payment_mode text,payment_reference text,cash_amount numeric(14,2),online_amount numeric(14,2),online_mode text,online_reference text,bank_ref text,payment_status text,payment_reviewed_by uuid,payment_reviewed_at timestamptz);
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
  'lwb_employee_master_setup.sql','lwb_documents_setup.sql'])await db.exec(await sql(f));
await db.exec('GRANT USAGE ON SCHEMA public,auth,storage TO authenticated');

// Live-like data before the merge: 2 vehicles, 3 drivers in Driver Master, 2 employees.
const veh=(await db.query("insert into lwb_vehicles(vehicle_no,vehicle_type) values('GJ05FW9821','Tempo'),('GJ05AB1111','Pickup') returning id")).rows.map(r=>r.id);
const drv=(await db.query(`insert into lwb_drivers(driver_name,mobile,alt_mobile,license_no,license_expiry,default_vehicle_id,transporter_name,address,is_active,note) values
 ('Ramesh Patel','9876543210','9123456789','gj05 2020 1234','2027-05-01',$1,'Own','Surat',true,'Night trips'),
 ('Suresh Bhai','9000000001',null,null,null,$2,null,null,true,null),
 ('Mahesh','9000000002',null,null,null,null,null,null,false,null) returning id`,[veh[0],veh[1]])).rows.map(r=>r.id);
// Suresh is already an employee (same mobile, +91), working as Loader; another "Mahesh" exists with another mobile.
await db.query(`insert into lwb_acc_staff(name,mobile,designation,monthly_salary) values('Suresh Bhai','+91 90000 00001','Loader',12000),('Mahesh','9111111111','Packer',10000)`);
// Driver photo + Aadhaar number saved on Driver Master before.
await db.query(`insert into lwb_documents(entity_type,entity_id,doc_type,path,mime) values('DRIVER',$1,'PHOTO','DRIVER/'||$1||'/PHOTO/x-1.jpg','image/jpeg'),('DRIVER',$1,'DL','DRIVER/'||$1||'/DL/x-2.jpg','image/jpeg')`,[drv[0]]);
await db.query(`insert into lwb_doc_info(entity_type,entity_id,info) values('DRIVER',$1,'{"aadhaar_no":"234567890123"}')`,[drv[0]]);

const roleSql=await sql('lwb_employee_roles_setup.sql');
await db.exec(roleSql);await db.exec(roleSql); // safe to run again

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const staff=async name=>(await db.query('select * from lwb_acc_staff where name=$1',[name])).rows[0];
const pick=async(who,role)=>{await as(who);return (await call('select lwb_staff_pick($1) j',[role]))[0].j};

test('every Driver Master row is in Employee Master once', async()=>{
  assert.equal((await db.query('select count(*)::int n from lwb_drivers where staff_id is null')).rows[0].n,0);
  assert.equal((await db.query('select count(*)::int n from lwb_acc_staff')).rows[0].n,4); // 2 old + Ramesh + new Mahesh
  const r=await staff('Ramesh Patel');
  assert.equal(r.designation,'Driver');assert.equal(r.mobile,'9876543210');assert.equal(r.alt_mobile,'9123456789');
  assert.equal(r.license_no,'GJ05 2020 1234');assert.equal(r.default_vehicle_id,veh[0]);assert.equal(r.address,'Surat');
  assert.equal(Number(r.monthly_salary),0);assert.equal(r.note,'Night trips');assert.ok(/^EMP\d{3}$/.test(r.emp_code));
  // matched by mobile: the Loader is now the Driver, the old post kept in the note, salary untouched
  const s=await staff('Suresh Bhai');
  assert.equal(s.designation,'Driver');assert.equal(s.note,'Work / Post was Loader');assert.equal(Number(s.monthly_salary),12000);
  assert.equal(s.default_vehicle_id,veh[1]);
  // same name, other mobile: both kept
  const m=await staff('Mahesh (0002)');assert.equal(m.active,false);assert.equal(m.mobile,'9000000002');
  assert.equal((await staff('Mahesh')).designation,'Packer');
});

test('driver photo, licence and Aadhaar number move to the employee', async()=>{
  const r=await staff('Ramesh Patel');
  const d=(await db.query("select entity_type,entity_id,doc_type from lwb_documents order by doc_type")).rows;
  assert.deepEqual(d,[{entity_type:'STAFF',entity_id:String(r.id),doc_type:'DL'},{entity_type:'STAFF',entity_id:String(r.id),doc_type:'PHOTO'}]);
  await as('godown');
  const s=await call("select entity_id,doc_types from lwb_doc_summary('STAFF')");
  assert.deepEqual(s,[{entity_id:String(r.id),doc_types:['DL','PHOTO']}]);
  await as('acc');
  const i=await call("select info from lwb_doc_info_get('STAFF',$1)",[[String(r.id)]]);
  assert.equal(i[0].info.aadhaar_no,'234567890123');
});

test('pick list: working drivers with vehicle, no salary; other posts by role', async()=>{
  const d=await pick('head','Driver');
  assert.deepEqual(d.map(x=>x.name),['Ramesh Patel','Suresh Bhai']);
  assert.equal(d[0].vehicle_no,'GJ05FW9821');assert.equal(d[0].mobile,'9876543210');
  assert.ok(!('monthly_salary' in d[0]));
  assert.deepEqual((await pick('transport','packer')).map(x=>x.name),['Mahesh']);
  assert.equal((await pick('godown','')).length,3);
  assert.equal((await pick('ticked','driver')).length,2); // given PO Approval page by Admin
  await as('sales');await assert.rejects(call("select lwb_staff_pick('driver')"),/can not read/);
  await as('driver');await assert.rejects(call("select lwb_staff_pick('driver')"),/can not read/);
});

test('new driver in Employee Master shows in the pick list at once', async()=>{
  await as('godown');
  const r=(await call('select lwb_emp_save2($1::jsonb) j',[JSON.stringify({name:'Kalu Ram',mobile:'9812345678',designation:'Driver',monthly_salary:15000,
    license_no:'gj01 1',license_expiry:'2028-01-01',default_vehicle_id:veh[1],transporter_name:'',address:'',is_active:true})]))[0].j;
  assert.ok(r.emp_code);
  const d=await pick('head','driver');
  const k=d.find(x=>x.name==='Kalu Ram');assert.equal(k.vehicle_no,'GJ05AB1111');assert.equal(k.mobile,'9812345678');
  const l=(await call('select lwb_emp_list2() j'))[0].j.rows.find(x=>x.name==='Kalu Ram');
  assert.equal(l.license_no,'GJ01 1');assert.equal(l.vehicle_no,'GJ05AB1111');assert.equal(Number(l.monthly_salary),15000);
  // a Loader does not need a mobile, and is not a driver
  await call('select lwb_emp_save2($1::jsonb)',[JSON.stringify({name:'Bhola',designation:'Loader',monthly_salary:9000})]);
  assert.ok(!(await pick('head','driver')).some(x=>x.name==='Bhola'));
  assert.deepEqual((await pick('head','loader')).map(x=>x.name),['Bhola']);
});

test('driver needs a mobile, and one mobile = one working driver', async()=>{
  await as('head');
  await assert.rejects(call('select lwb_emp_save2($1::jsonb)',[JSON.stringify({name:'No Phone',designation:'Driver',monthly_salary:0})]),/needs a 10-digit mobile/);
  await assert.rejects(call('select lwb_emp_save2($1::jsonb)',[JSON.stringify({name:'Copy',mobile:'9876543210',designation:'driver',monthly_salary:0})]),/already given to driver/);
  await assert.rejects(call('select lwb_emp_save2($1::jsonb)',[JSON.stringify({name:'Bad Alt',mobile:'9800000001',alt_mobile:'123',designation:'Driver',monthly_salary:0})]),/Alternate mobile/);
  // editing the same driver keeps working
  const r=await staff('Ramesh Patel');
  await call('select lwb_emp_save2($1::jsonb)',[JSON.stringify({id:r.id,emp_code:r.emp_code,name:'Ramesh Patel',mobile:'9876543210',designation:'Driver',monthly_salary:18000,default_vehicle_id:veh[1],is_active:true})]);
  assert.equal((await staff('Ramesh Patel')).default_vehicle_id,veh[1]);
  await as('transport');await assert.rejects(call('select lwb_emp_save2($1::jsonb)',[JSON.stringify({name:'X Y',monthly_salary:0})]),/Only Admin, Manager, Godown or Accounts/);
});

test('old Driver Master rows are kept, nothing deleted', async()=>{
  assert.equal((await db.query('select count(*)::int n from lwb_drivers')).rows[0].n,3);
});
