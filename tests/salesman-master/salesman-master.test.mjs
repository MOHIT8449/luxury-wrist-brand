import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';

// lwb_salesman_master_setup.sql on an empty PGlite database (no live data): one Save makes the
// employee, the login, Field / Office + area and the brands of a salesman.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  rajHead:'00000000-0000-4000-8000-000000000003',old:'00000000-0000-4000-8000-000000000004',acc:'00000000-0000-4000-8000-000000000005'};
const db=new PGlite({extensions:{pgcrypto}});
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE SCHEMA storage; CREATE SCHEMA extensions;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE auth.users(instance_id uuid,id uuid primary key,aud text,role text,email text,encrypted_password text,email_confirmed_at timestamptz,
  raw_app_meta_data jsonb,raw_user_meta_data jsonb,created_at timestamptz,updated_at timestamptz,last_sign_in_at timestamptz,
  confirmation_token text,recovery_token text,email_change_token_new text,email_change text,phone text);
CREATE UNIQUE INDEX ON auth.users(email);
CREATE TABLE auth.identities(id uuid primary key,provider_id text,user_id uuid,identity_data jsonb,provider text,last_sign_in_at timestamptz,created_at timestamptz,updated_at timestamptz);
CREATE TABLE auth.sessions(id uuid primary key,user_id uuid);CREATE TABLE auth.refresh_tokens(id bigserial primary key,user_id text,session_id uuid);
CREATE TABLE public.user_profiles(id uuid primary key,full_name text,role text,active boolean,mobile text);
CREATE TABLE public.lwb_user_page_access(user_id uuid,extra text[]);
CREATE FUNCTION public.lwb_has_page(p text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$ SELECT false $$;
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text default 'approved',order_date timestamptz default now(),total_amount numeric,total_qty numeric,created_by uuid);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric default 0,rate numeric,amount numeric);
CREATE TABLE public.sku_master(id uuid default gen_random_uuid() primary key,sku_name text,category text,pcs_per_case int default 24,is_active boolean default true);
CREATE TABLE public.lwb_customer_master(id uuid default gen_random_uuid() primary key,customer_name text,city text,mobile text,is_active boolean default true,order_every_days int);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,driver_name text,driver_mobile text,vehicle_no text,assigned_at timestamptz default now());
CREATE TABLE public.lwb_tally_invoices(order_id uuid,invoice_no text);
CREATE TABLE public.lwb_tally_payments(id uuid default gen_random_uuid() primary key,receipt_id uuid,order_id uuid,pay_date date,mode text,amount numeric(14,2),ref_no text,cash_notes jsonb,remark text,created_by uuid,created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid,delivery_status text,driver_user_id uuid,cash_reported numeric(14,2) default 0,payment_mode text,payment_reference text,cash_amount numeric(14,2),online_amount numeric(14,2),online_mode text,online_reference text,bank_ref text,payment_status text,payment_reviewed_by uuid,payment_reviewed_at timestamptz);
CREATE TABLE public.tax_invoices(id uuid default gen_random_uuid() primary key,order_id uuid,invoice_no text);
CREATE TABLE public.sales_returns(id uuid default gen_random_uuid() primary key,order_id uuid,return_no text);
CREATE TABLE public.sales_return_items(id uuid default gen_random_uuid() primary key,sales_return_id uuid,qty numeric);
CREATE TABLE public.lwb_payment_collections(id uuid default gen_random_uuid() primary key,invoice_id uuid,collection_date date,amount numeric(14,2),payment_mode text,reference_no text,remarks text,status text,submitted_by uuid,submitted_at timestamptz default now(),reviewed_at timestamptz);
CREATE TABLE public.lwb_goods_inward(id uuid default gen_random_uuid() primary key,invoice_no text,invoice_date date,received_date date,supplier_name text);
CREATE TABLE public.lwb_goods_inward_items(id bigserial primary key,inward_id uuid,sku_id uuid,total_amount numeric);
CREATE FUNCTION public.lwb_tally_bill_rows(p_days integer) RETURNS TABLE (order_id uuid, order_no text, party text, status text, order_date date, dispatch_date date,
  invoice_no text, invoice_date date, bill_amount numeric, erp_amount numeric, approved_return numeric, pending_return numeric, credit_notes numeric, debit_notes numeric,
  collected numeric, verified numeric, due numeric, credit_pending numeric, delivery text, notes jsonb)
  LANGUAGE sql STABLE AS $$ SELECT null::uuid,null,null,null,null::date,null::date,null,null::date,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,null,null::jsonb WHERE false $$;
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(id bigserial primary key,bucket_id text,name text);
CREATE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$ SELECT (string_to_array(name,'/'))[1:array_length(string_to_array(name,'/'),1)-1] $$;
CREATE FUNCTION storage.filename(name text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT (string_to_array(name,'/'))[array_length(string_to_array(name,'/'),1)] $$;
`);
const roles={admin:'admin',head:'manager',rajHead:'manager',old:'salesman',acc:'accounts'};
const mob={old:'9824012345'};
for(const [k,id] of Object.entries(ids)){await db.query('insert into auth.users(id,email) values($1,$2)',[id,k+'@x.in']);await db.query('insert into user_profiles values($1,$2,$3,true,$4)',[id,'Name '+k,roles[k],mob[k]||null])}
for(const f of ['lwb_user_login_setup.sql','lwb_fleet_master_setup.sql','lwb_accounts_dashboard_setup.sql','lwb_accounts_staff_setup.sql',
  'lwb_accounts_vehicle_setup.sql','lwb_employee_master_setup.sql','lwb_employee_roles_setup.sql','lwb_employee_login_link_setup.sql',
  'lwb_user_permissions_setup.sql','lwb_sales_team_setup.sql','lwb_sales_head_in_team_setup.sql','lwb_company_brand_setup.sql'])await db.exec(await sql(f));
const setup=await sql('lwb_salesman_master_setup.sql');
await db.exec(setup);await db.exec(setup); // safe to run again
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');
const co=n=>db.query('select id from lwb_companies where name ilike $1',[n+'%']).then(r=>r.rows[0].id);
const CC=await co('Coca'),RJ=await co('Rajni');
await db.query("update lwb_companies set active=false where id<>all($1)",[[CC,RJ]]);
await db.query('insert into lwb_user_companies(user_id,company_id) values($1,$2)',[ids.rajHead,RJ]);

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function save(who,p){await as(who);await db.exec('SET ROLE authenticated');try{return (await db.query('select public.lwb_salesman_save($1) r',[p])).rows[0].r}finally{await db.exec('RESET ROLE')}}
const brandsOf=async u=>(await db.query('select company_id from lwb_user_companies where user_id=$1 order by company_id',[u])).rows.map(r=>r.company_id).sort();
const base={name:'Ashok Vasava',mobile:'97370 12345',role:'sales',kind:'FIELD',area:'Udhna',active:true,password:'Abcd2345',joining_date:'2026-11-01',monthly_salary:15000};

let ashok;
test('Admin makes a Coca-Cola salesman in one save: employee, login, Field + area, brand', async()=>{
  const r=await save('admin',{...base,company_ids:[CC]});
  assert.equal(r.login_made,true);ashok=r;
  const s=(await db.query('select * from lwb_acc_staff where id=$1',[r.staff_id])).rows[0];
  assert.equal(s.user_id,r.user_id);assert.equal(s.designation,'Salesman');assert.equal(Number(s.monthly_salary),15000);assert.equal(s.mobile,'9737012345');
  const u=(await db.query('select * from user_profiles where id=$1',[r.user_id])).rows[0];
  assert.equal(u.role,'sales');assert.equal(u.mobile,'9737012345');assert.equal(u.active,true);
  const sm=(await db.query('select * from lwb_salesmen where user_id=$1',[r.user_id])).rows[0];
  assert.equal(sm.kind,'FIELD');assert.equal(sm.area,'Udhna');
  assert.deepEqual(await brandsOf(r.user_id),[CC]);
  assert.equal((await db.query("select count(*)::int n from auth.users where email='m9737012345@staff.lwb-erp.in'")).rows[0].n,1);
});

test('both brands ticked = All brands (no rows); one brand again = that brand', async()=>{
  await save('admin',{...base,user_id:ashok.user_id,staff_id:ashok.staff_id,password:null,company_ids:[CC,RJ]});
  assert.deepEqual(await brandsOf(ashok.user_id),[]);
  await save('admin',{...base,user_id:ashok.user_id,password:null,company_ids:[RJ],kind:'OFFICE',area:'Office'});
  assert.deepEqual(await brandsOf(ashok.user_id),[RJ]);
  assert.equal((await db.query('select kind from lwb_salesmen where user_id=$1',[ashok.user_id])).rows[0].kind,'OFFICE');
  assert.equal((await db.query('select count(*)::int n from lwb_acc_staff where user_id=$1',[ashok.user_id])).rows[0].n,1);
});

test('Admin edit changes name / mobile / active of the login and keeps other employee fields', async()=>{
  await db.query("update lwb_acc_staff set note='old note', emp_code='EMP777' where id=$1",[ashok.staff_id]);
  await save('admin',{...base,user_id:ashok.user_id,name:'Ashok V',mobile:'9737099999',password:null,company_ids:[RJ],active:false});
  const u=(await db.query('select * from user_profiles where id=$1',[ashok.user_id])).rows[0];
  assert.equal(u.full_name,'Ashok V');assert.equal(u.mobile,'9737099999');assert.equal(u.active,false);
  const s=(await db.query('select * from lwb_acc_staff where id=$1',[ashok.staff_id])).rows[0];
  assert.equal(s.note,'old note');assert.equal(s.emp_code,'EMP777');assert.equal(s.active,false);assert.equal(s.mobile,'9737099999');
});

test('old SALES login without employee row gets one, linked, on its first save', async()=>{
  const r=await save('admin',{...base,user_id:ids.old,name:'Name old',mobile:'9824012345',password:null,company_ids:[CC]});
  assert.equal(r.login_made,false);
  const s=(await db.query('select * from lwb_acc_staff where user_id=$1',[ids.old])).rows;
  assert.equal(s.length,1);assert.equal((await db.query('select role from user_profiles where id=$1',[ids.old])).rows[0].role,'salesman');
  assert.deepEqual(await brandsOf(ids.old),[CC]);
});

test('Sales Head: no new login; edits type / area / brand within his own brands; not name or post', async()=>{
  await assert.rejects(save('head',{...base,name:'New Guy',mobile:'9000000011',company_ids:[CC]}),/Only Admin can make a new salesman login/);
  await save('head',{...base,user_id:ids.old,name:'Name old',mobile:'9824012345',password:null,company_ids:[CC,RJ],area:'Bardoli'});
  assert.deepEqual(await brandsOf(ids.old),[]);
  await save('head',{...base,user_id:ids.old,name:'Changed',mobile:'9000000099',active:false,password:null,company_ids:[]});
  const u=(await db.query('select * from user_profiles where id=$1',[ids.old])).rows[0];
  assert.equal(u.full_name,'Name old');assert.equal(u.mobile,'9824012345');assert.equal(u.active,true);
  await assert.rejects(save('head',{...base,user_id:ids.old,name:'Name old',mobile:'9824012345',role:'manager',password:null,company_ids:[]}),/Only Admin/);
  // Rajnigandha Sales Head may give only Rajnigandha.
  await assert.rejects(save('rajHead',{...base,user_id:ids.old,name:'Name old',mobile:'9824012345',password:null,company_ids:[CC]}),/only your own companies/);
  await save('rajHead',{...base,user_id:ids.old,name:'Name old',mobile:'9824012345',password:null,company_ids:[RJ]});
  assert.deepEqual(await brandsOf(ids.old),[RJ]);
});

test('Admin makes a Sales Head (manager login, Office)', async()=>{
  const r=await save('admin',{...base,name:'Pinal Shah',mobile:'9000000022',role:'manager',kind:'FIELD',company_ids:[RJ]});
  assert.equal((await db.query('select role from user_profiles where id=$1',[r.user_id])).rows[0].role,'manager');
  assert.equal((await db.query('select kind from lwb_salesmen where user_id=$1',[r.user_id])).rows[0].kind,'OFFICE');
  assert.equal((await db.query('select designation from lwb_acc_staff where id=$1',[r.staff_id])).rows[0].designation,'Manager');
});

test('checks: other roles, bad mobile, short password, mobile of another role', async()=>{
  await assert.rejects(save('acc',{...base,name:'X Y',mobile:'9000000033',company_ids:[]}),/Admin or Sales Head required/);
  await assert.rejects(save('admin',{...base,name:'X Y',mobile:'12345',company_ids:[]}),/10 digits/);
  await assert.rejects(save('admin',{...base,name:'X Y',mobile:'9000000033',password:'123',company_ids:[]}),/at least 6/);
  await db.query("update user_profiles set mobile='9000000044' where id=$1",[ids.acc]);
  await assert.rejects(save('admin',{...base,name:'Z Z',mobile:'9000000044',company_ids:[]}),/another role/);
  assert.equal((await db.query("select count(*)::int n from lwb_acc_staff where name='Z Z'")).rows[0].n,0);
});
