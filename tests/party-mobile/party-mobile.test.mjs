import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_task_management_setup.sql + lwb_party_mobile_task_setup.sql on an empty PGlite database.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  s1:'00000000-0000-4000-8000-000000000005',s2:'00000000-0000-4000-8000-000000000006',gone:'00000000-0000-4000-8000-000000000008',
  acc:'00000000-0000-4000-8000-000000000004'};
const roles={admin:'ADMIN',head:'MANAGER',s1:'SALES',s2:'SALES',gone:'SALES',acc:'ACCOUNTS'};
const names={admin:'Mohit',head:'Head',s1:'Ravi',s2:'Amit',gone:'Old',acc:'Yogesh'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean not null default false,created_at timestamptz default now());
CREATE TABLE public.lwb_customer_master(id uuid default gen_random_uuid() primary key,customer_code text,customer_name text,city text,contact_person text,mobile text,is_active boolean default true,merged_into uuid);
CREATE TABLE public.lwb_salesmen(user_id uuid primary key);
CREATE TABLE public.lwb_party_salesman(customer_id uuid primary key references lwb_customer_master(id),salesman_id uuid not null);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,$3,$4)',[id,roles[k],k!=='gone',names[k]]);
await db.exec(await readFile(new URL('../../lwb_task_management_setup.sql',import.meta.url),'utf8'));
const P={};
for(const [n,mob,own,act] of [['A1',null,'s1',true],['A2','98',' s1',true],['A3','9876543210','s1',true],['B1','','s2',true],
  ['O1',null,null,true],['G1',null,'gone',true],['X1',null,'s1',false]]){
  P[n]=(await db.query('insert into lwb_customer_master(customer_code,customer_name,mobile,is_active) values($1,$2,$3,$4) returning id',[n,'Shop '+n,mob,act])).rows[0].id;
  if(own)await db.query('insert into lwb_party_salesman values($1,$2)',[P[n],ids[own.trim()]]);
}
const setup=await readFile(new URL('../../lwb_party_mobile_task_setup.sql',import.meta.url),'utf8');
await db.exec(setup);
await db.exec(setup); // safe to run again
async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,a=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,a)).rows}finally{await db.exec('RESET ROLE')}}
const tasks=async()=>(await db.query("select t.*,u.full_name who from lwb_tasks t join user_profiles u on u.id=t.assigned_to where auto_key='PARTY_MOBILE' order by t.id")).rows;
const bells=async(k)=>(await db.query('select * from erp_notifications where user_id=$1 order by id',[ids[k]])).rows;

test('merge gives one task each: Sales Head (all 5) and salesmen with own pending parties; run again gives nothing new', async()=>{
  const t=await tasks();
  assert.deepEqual(t.map(x=>[x.who,x.title,x.status]),[
    ['Head','📞 Fill mobile number of 5 parties','OPEN'],
    ['Amit','📞 Fill mobile number of 1 parties','OPEN'],
    ['Ravi','📞 Fill mobile number of 2 parties','OPEN']]);
  assert.ok(t.every(x=>x.assigned_by===ids.admin));
  assert.equal((await bells('s1')).filter(b=>b.notification_type==='TASK_NEW').length,1);
});

test('lists: salesman sees only his own; Head sees all with owner; Accounts sees nothing', async()=>{
  await as('s1');
  assert.deepEqual((await call('select customer_code from lwb_party_mobile_pending()')).map(r=>r.customer_code),['A1','A2']);
  assert.equal((await call('select lwb_party_mobile_pending_count() n'))[0].n,2);
  await as('head');
  const all=await call('select customer_code,owner_name from lwb_party_mobile_pending()');
  assert.deepEqual(all.map(r=>r.customer_code).sort(),['A1','A2','B1','G1','O1']);
  assert.equal(all.find(r=>r.customer_code==='G1').owner_name,null); // inactive salesman -> office
  await as('acc');
  assert.equal((await call('select count(*)::int n from lwb_party_mobile_pending()'))[0].n,0);
  await assert.rejects(call('select lwb_party_mobile_set($1,$2)',[P.A1,'9876500001']),/Only Admin/);
});

test('save checks: valid number, own party only, saved number not overwritten', async()=>{
  await as('s1');
  await assert.rejects(call('select lwb_party_mobile_set($1,$2)',[P.A1,'12345']),/valid 10 digit/);
  await assert.rejects(call('select lwb_party_mobile_set($1,$2)',[P.B1,'9876500001']),/not found in your list/);
  await assert.rejects(call('select lwb_party_mobile_set($1,$2)',[P.A3,'9876500001']),/already saved/);
  const r=(await call('select lwb_party_mobile_set($1,$2) r',[P.A1,'+91 98765 00001']))[0].r;
  assert.equal(r.mobile,'9876500001');assert.equal(r.pending,1);
  assert.equal((await db.query('select mobile from lwb_customer_master where id=$1',[P.A1])).rows[0].mobile,'9876500001');
  assert.equal((await db.query('select count(*)::int n from lwb_party_mobile_fills')).rows[0].n,1);
});

test('last number filled: salesman task closes as DONE by itself, Admin gets a bell', async()=>{
  await as('s1');
  await call('select lwb_party_mobile_set($1,$2)',[P.A2,'9876500002']);
  const t=(await tasks()).find(x=>x.who==='Ravi');
  assert.equal(t.status,'DONE');
  assert.ok((await bells('admin')).some(b=>b.notification_type==='TASK_DONE'&&b.message.includes('Ravi filled every')));
  // Party Master edit (direct update) also closes a task.
  await db.query("update lwb_customer_master set mobile='9876500003' where id=$1",[P.B1]);
  assert.equal((await tasks()).find(x=>x.who==='Amit').status,'DONE');
  assert.equal((await tasks()).find(x=>x.who==='Head').status,'OPEN');
});

test('progress for Admin; give again only to people without an open task', async()=>{
  await as('admin');
  const p=await call('select person_name,pending,filled,task_status from lwb_party_mobile_progress()');
  assert.deepEqual(p.map(r=>[r.person_name,r.pending,r.filled,r.task_status]),[['Head',2,0,'OPEN'],['Amit',0,0,'DONE'],['Ravi',0,2,'DONE']]);
  await db.query("update lwb_customer_master set mobile=null where id=$1",[P.A3]);
  const g=(await call('select lwb_party_mobile_tasks_give() r'))[0].r;
  assert.equal(g.given,1); // Ravi again; Head already has one open
  await as('s1');
  await assert.rejects(call('select lwb_party_mobile_tasks_give()'),/Admin or Sales Head/);
  await assert.rejects(call('update lwb_customer_master set mobile=null'),/permission denied/);
});

test('Head fills office parties; his task closes when all are filled', async()=>{
  await as('head');
  for(const [k,m] of [['O1','9876500010'],['G1','9876500011'],['A3','9876500012']])await call('select lwb_party_mobile_set($1,$2)',[P[k],m]);
  const t=await tasks();
  assert.ok(t.every(x=>x.status==='DONE'),JSON.stringify(t.map(x=>[x.who,x.status])));
});
