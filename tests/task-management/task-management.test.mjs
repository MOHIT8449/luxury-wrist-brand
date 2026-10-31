import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_task_management_setup.sql on an empty PGlite database (no live database).
const ids={
  admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  godown:'00000000-0000-4000-8000-000000000003',acc:'00000000-0000-4000-8000-000000000004',
  sales:'00000000-0000-4000-8000-000000000005',sales2:'00000000-0000-4000-8000-000000000006',
  driver:'00000000-0000-4000-8000-000000000007',gone:'00000000-0000-4000-8000-000000000008'};
const roles={admin:'admin',head:'manager',godown:'warehouse',acc:'accounts',sales:'sales',sales2:'sales',driver:'driver',gone:'sales'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean not null default false,created_at timestamptz default now());
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,$3,$4)',[id,roles[k].toUpperCase(),k!=='gone','Name '+k]);
const setup=await readFile(new URL('../../lwb_task_management_setup.sql',import.meta.url),'utf8');
await db.exec(setup);
await db.exec(setup); // safe to run again
async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const today=async()=>(await db.query("select to_char(public.lwb_task_today(),'YYYY-MM-DD') d")).rows[0].d;
const give=async(who,to,extra={})=>{await as(who);
  return (await call('select lwb_task_add($1) ids',[{title:'Clean the godown',due_date:await today(),assignees:to.map(k=>ids[k]),...extra}]))[0].ids.map(Number)};
const bells=async(who)=>(await db.query('select title,message,notification_type t,is_read from erp_notifications where user_id=$1 order by id',[ids[who]])).rows;
const see=async(who)=>{await as(who);return (await call('select id,assigned_to_name from lwb_tasks order by id')).map(r=>Number(r.id))};

test('people list follows the chain: own level or below, Admin all, inactive left out', async()=>{
  await as('acc');
  const acc=(await call('select name,role from lwb_task_people()')).map(r=>r.role);
  assert.deepEqual(acc,['accounts','driver','sales','sales']);
  await as('sales');
  assert.deepEqual((await call('select role from lwb_task_people()')).map(r=>r.role),['driver','sales','sales']);
  await as('admin');
  assert.equal((await call('select count(*)::int n from lwb_task_people()'))[0].n,7);
  await as('godown');
  assert.deepEqual((await call('select role from lwb_task_people()')).map(r=>r.role),['warehouse','accounts','driver','sales','sales']);
});

test('Admin gives a task to the Sales Head: he gets a bell, the task is on his list', async()=>{
  const [id]=await give('admin',['head'],{priority:'URGENT',details:'Before 6 pm'});
  const b=await bells('head');
  assert.equal(b.length,1);
  assert.equal(b[0].t,'TASK_NEW');
  assert.equal(b[0].title,'URGENT · New task: Clean the godown');
  assert.match(b[0].message,new RegExp('^TSK-'+id+' · Clean the godown · Due .* · by Name admin \\(Admin\\)\\.$'));
  assert.ok((await see('head')).includes(id));
});

test('a junior cannot give a task upward; same level and below is fine', async()=>{
  await as('sales');
  await assert.rejects(call('select lwb_task_add($1)',[{title:'x',assignees:[ids.head]}]),/your level or below: Name head \(Sales Head\)/);
  await as('acc');
  await assert.rejects(call('select lwb_task_add($1)',[{title:'x',assignees:[ids.godown]}]),/level or below/);
  await assert.rejects(call('select lwb_task_add($1)',[{title:'x',assignees:[ids.gone]}]),/not active/);
  const ids2=await give('sales',['sales2','driver']);
  assert.equal(ids2.length,2);
  const batch=(await db.query('select distinct batch_id from lwb_tasks where id = any($1)',[ids2])).rows;
  assert.equal(batch.length,1);
});

test('input checks: title, assignees, past due date', async()=>{
  await as('head');
  await assert.rejects(call('select lwb_task_add($1)',[{title:' ',assignees:[ids.sales]}]),/enter the task/);
  await assert.rejects(call('select lwb_task_add($1)',[{title:'x',assignees:[]}]),/who gets the task/);
  await assert.rejects(call('select lwb_task_add($1)',[{title:'x',due_date:'2020-01-01',assignees:[ids.sales]}]),/before today/);
  await as('');
  await assert.rejects(call('select lwb_task_add($1)',[{title:'x',assignees:[ids.sales]}]),/not active/);
});

test('who sees what: person, giver, seniors; not juniors or peers of the person', async()=>{
  const [id]=await give('head',['sales']);
  for(const w of ['sales','head','admin','godown','acc'])assert.ok((await see(w)).includes(id),w+' should see');
  for(const w of ['sales2','driver'])assert.ok(!(await see(w)).includes(id),w+' should not see');
  // Accounts does not see a task given to the Godown Manager.
  const [g]=await give('admin',['godown']);
  assert.ok(!(await see('acc')).includes(g));
  assert.ok((await see('head')).includes(g));
  // No direct writes.
  await as('sales');
  await assert.rejects(call("update lwb_tasks set status='DONE' where id=$1",[id]),/permission denied/);
});

test('person starts and finishes; giver gets a bell; task bells are cleared', async()=>{
  const [id]=await give('head',['godown'],{title:'Count empty pallets'});
  await as('godown');
  assert.equal((await call("select lwb_task_update($1,'IN_PROGRESS',null) s",[id]))[0].s,'IN_PROGRESS');
  await db.query('delete from erp_notifications where user_id=$1',[ids.head]);
  assert.equal((await call("select lwb_task_update($1,'DONE','42 pallets') s",[id]))[0].s,'DONE');
  const hb=await bells('head');
  assert.equal(hb.length,1);assert.equal(hb[0].t,'TASK_DONE');
  assert.equal(hb[0].message,'TSK-'+id+' · Count empty pallets · Name godown: 42 pallets.');
  const gb=(await bells('godown')).filter(b=>b.message.startsWith('TSK-'+id+' '));
  assert.ok(gb.every(b=>b.is_read));
  const u=await call('select body,status_after from lwb_task_updates where task_id=$1 order by id',[id]);
  assert.deepEqual(u.map(r=>r.body),['Started','Marked done · 42 pallets']);
  // Person cannot reopen or cancel.
  await assert.rejects(call("select lwb_task_update($1,'OPEN',null)",[id]),/Only the giver/);
});

test('giver reopens, changes due date and cancels; person is told', async()=>{
  const [id]=await give('acc',['driver'],{title:'Bring cheque'});
  await as('driver');await call("select lwb_task_update($1,'DONE',null)",[id]);
  await as('acc');
  await db.query('delete from erp_notifications where user_id=$1',[ids.driver]);
  await call("select lwb_task_update($1,'OPEN','Cheque not received')",[id]);
  const tomorrow=(await db.query("select to_char(public.lwb_task_today()+1,'YYYY-MM-DD') d")).rows[0].d;
  await call('select lwb_task_update($1,null,null,$2::date)',[id,tomorrow]);
  await call("select lwb_task_update($1,'CANCELLED',null)",[id]);
  assert.deepEqual((await bells('driver')).map(b=>b.t),['TASK_REOPENED','TASK_DUE_CHANGED','TASK_CANCELLED']);
  await as('driver');
  await assert.rejects(call('select lwb_task_update($1,null,null,lwb_task_today()+5)',[id]),/Only the giver/);
  await assert.rejects(call("select lwb_task_update($1,'DONE',null)",[id]),/Open the task again/);
  await assert.rejects(call('select lwb_task_update($1,null,null)',[id]),/write a note/);
});

test('senior in team view can only write a note; both get the bell; outsider cannot touch it', async()=>{
  const [id]=await give('acc',['sales']);
  await as('head');
  await assert.rejects(call("select lwb_task_update($1,'CANCELLED',null)",[id]),/Only the giver/);
  await db.query('delete from erp_notifications');
  await call("select lwb_task_update($1,null,'Do it today please')",[id]);
  assert.deepEqual((await bells('acc')).map(b=>b.t),['TASK_NOTE']);
  assert.deepEqual((await bells('sales')).map(b=>b.t),['TASK_NOTE']);
  await as('sales2');
  await assert.rejects(call("select lwb_task_update($1,null,'hi')",[id]),/Task not found/);
});

test('due bells: once a day to the person, once to the giver when late', async()=>{
  await db.exec("delete from erp_notifications; delete from lwb_tasks");
  const [a,b]=await give('head',['sales','sales2'],{title:'Visit 10 parties'});
  await db.query("update lwb_tasks set due_date=lwb_task_today()-2 where id=$1",[a]);
  await as('sales');
  assert.equal((await call('select lwb_task_due_bells() n'))[0].n,1);
  assert.equal((await call('select lwb_task_due_bells() n'))[0].n,0);
  assert.match((await bells('sales'))[1].title,/^Task overdue 2 day\(s\): Visit 10 parties$/);
  await as('sales2');
  assert.equal((await call('select lwb_task_due_bells() n'))[0].n,1);
  assert.match((await bells('sales2'))[1].title,/^Task due today/);
  await as('head');
  assert.equal((await call('select lwb_task_due_bells() n'))[0].n,1);
  assert.equal((await call('select lwb_task_due_bells() n'))[0].n,0);
  const hb=await bells('head');
  assert.equal(hb.at(-1).t,'TASK_OVERDUE');
  assert.match(hb.at(-1).message,new RegExp('^TSK-'+a+' · Visit 10 parties · Name sales · was due '));
});
