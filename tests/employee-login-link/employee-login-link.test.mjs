import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';

// lwb_employee_login_link_setup.sql on an empty PGlite database (no live data): employees get linked to
// the ERP login with the same mobile, Admin makes a login from an employee, logins made in Manage Users link by themselves.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000005',
  divyesh:'00000000-0000-4000-8000-000000000009'};
const db=new PGlite({extensions:{pgcrypto}});
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE SCHEMA storage; CREATE SCHEMA extensions;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE auth.users(instance_id uuid,id uuid primary key,aud text,role text,email text,encrypted_password text,email_confirmed_at timestamptz,
  raw_app_meta_data jsonb,raw_user_meta_data jsonb,created_at timestamptz,updated_at timestamptz,last_sign_in_at timestamptz,
  confirmation_token text,recovery_token text,email_change_token_new text,email_change text);
CREATE UNIQUE INDEX ON auth.users(email);
CREATE TABLE auth.identities(id uuid primary key,provider_id text,user_id uuid,identity_data jsonb,provider text,last_sign_in_at timestamptz,created_at timestamptz,updated_at timestamptz);
CREATE TABLE public.user_profiles(id uuid primary key,full_name text,role text,active boolean,mobile text);
CREATE TABLE public.lwb_user_page_access(user_id uuid,extra text[]);
CREATE FUNCTION public.lwb_has_page(p text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$ SELECT false $$;
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
CREATE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$ SELECT (string_to_array(name,'/'))[1:array_length(string_to_array(name,'/'),1)-1] $$;
CREATE FUNCTION storage.filename(name text) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT (string_to_array(name,'/'))[array_length(string_to_array(name,'/'),1)] $$;
`);
const roles={admin:'admin',head:'manager',godown:'warehouse',sales:'sales',divyesh:'driver'};
const mob={divyesh:'9081795895'};
for(const [k,id] of Object.entries(ids)){await db.query('insert into auth.users(id,email) values($1,$2)',[id,k+'@x.in']);await db.query('insert into user_profiles values($1,$2,$3,true,$4)',[id,'Name '+k,roles[k],mob[k]||null])}
for(const f of ['lwb_user_login_setup.sql','lwb_fleet_master_setup.sql','lwb_accounts_dashboard_setup.sql','lwb_accounts_staff_setup.sql',
  'lwb_accounts_vehicle_setup.sql','lwb_employee_master_setup.sql','lwb_employee_roles_setup.sql'])await db.exec(await sql(f));
// Before: Divyesh (driver login 9081795895) is also in Employee Master; Kishan is a Godown Manager without login.
await db.query(`insert into lwb_acc_staff(name,mobile,designation,monthly_salary) values
 ('Divyesh','+91 90817 95895','Driver',15000),('Kishan','9000000003','Godown Manager',20000),('Bhola',null,'Loader',9000)`);
// Godown Manager list of PO Approval, as in lwb_loading_workflow_setup.sql.
const lw=await sql('lwb_loading_workflow_setup.sql');
await db.exec(lw.slice(lw.indexOf('CREATE OR REPLACE FUNCTION public.lwb_godown_managers()'),lw.indexOf('GRANT EXECUTE ON FUNCTION public.lwb_godown_managers()')));
await db.exec('GRANT EXECUTE ON FUNCTION public.lwb_godown_managers() TO authenticated');
const link=await sql('lwb_employee_login_link_setup.sql');
await db.exec(link);await db.exec(link); // safe to run again
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const staff=async name=>(await db.query('select * from lwb_acc_staff where name=$1',[name])).rows[0];

test('old employee is linked to the login with the same mobile', async()=>{
  assert.equal((await staff('Divyesh')).user_id,ids.divyesh);
  assert.equal((await staff('Kishan')).user_id,null);
});

test('Admin makes a login from the employee; role comes from the Work / Post', async()=>{
  await as('admin');
  const id=(await call('select lwb_emp_create_login($1,$2) id',[(await staff('Kishan')).id,'secret1']))[0].id;
  assert.equal((await staff('Kishan')).user_id,id);
  const p=(await db.query('select full_name,role,mobile,active from user_profiles where id=$1',[id])).rows[0];
  assert.deepEqual(p,{full_name:'Kishan',role:'warehouse',mobile:'9000000003',active:true});
  // so Kishan is in the Godown Manager list of PO Approval
  const gm=(await call('select full_name from lwb_godown_managers()')).map(r=>r.full_name);
  assert.ok(gm.includes('Kishan'));
  await assert.rejects(call('select lwb_emp_create_login($1,$2)',[(await staff('Kishan')).id,'secret1']),/already has an ERP login/);
  await assert.rejects(call('select lwb_emp_create_login($1,$2)',[(await staff('Bhola')).id,'secret1']),/Choose the login role/);
  await as('head');
  await assert.rejects(call('select lwb_emp_create_login($1,$2)',[(await staff('Bhola')).id,'secret1']),/Only an active Admin/);
});

test('a login made in Manage Users links to the employee with that mobile, and the other way round', async()=>{
  await as('admin');
  await call('select lwb_emp_save2($1::jsonb)',[JSON.stringify({name:'Ravi Sales',mobile:'9111111111',designation:'Salesman',monthly_salary:12000})]);
  const uid=(await call("select lwb_admin_create_user('Ravi','9111111111',null,'secret1','sales') id"))[0].id;
  assert.equal((await staff('Ravi Sales')).user_id,uid);
  // a login first, then the employee
  const u2=(await call("select lwb_admin_create_user('Mukesh','9222222222',null,'secret1','driver') id"))[0].id;
  await call('select lwb_emp_save2($1::jsonb)',[JSON.stringify({name:'Mukesh',mobile:'9222222222',designation:'Driver',monthly_salary:0})]);
  assert.equal((await staff('Mukesh')).user_id,u2);
});

test('list shows each employee with its login; link by hand and unlink', async()=>{
  await as('godown');
  const rows=(await call('select lwb_emp_logins() j'))[0].j;
  const d=rows.find(r=>r.name==='Divyesh');assert.equal(d.login_role,'driver');assert.equal(d.role_for_post,'driver');
  assert.equal(rows.find(r=>r.name==='Bhola').user_id,null);
  await assert.rejects(call('select lwb_emp_link_login($1,$2)',[(await staff('Bhola')).id,ids.sales]),/Only an active Admin/);
  await as('admin');
  await call('select lwb_emp_link_login($1,$2)',[(await staff('Bhola')).id,ids.sales]);
  assert.equal((await staff('Bhola')).user_id,ids.sales);
  await assert.rejects(call('select lwb_emp_link_login($1,$2)',[(await staff('Kishan')).id,ids.sales]),/already linked to/);
  await call('select lwb_emp_link_login($1,null)',[(await staff('Bhola')).id]);
  assert.equal((await staff('Bhola')).user_id,null);
  await as('sales');await assert.rejects(call('select lwb_emp_logins()'),/Employee Master is for/);
});
