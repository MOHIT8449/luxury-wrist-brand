import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_task_management_setup.sql + lwb_task_siren_setup.sql on an empty PGlite database.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',sales:'00000000-0000-4000-8000-000000000005'};
const roles={admin:'admin',head:'manager',sales:'sales'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean not null default false,created_at timestamptz default now());
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k].toUpperCase(),'Name '+k]);
const read=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(await read('lwb_task_management_setup.sql'));
const siren=await read('lwb_task_siren_setup.sql');
await db.exec(siren);await db.exec(siren); // safe to run again
async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const today=async()=>(await db.query("select to_char(public.lwb_task_today(),'YYYY-MM-DD') d")).rows[0].d;
const give=async(who,to,extra={})=>{await as(who);
  return (await call('select lwb_task_add($1) ids',[{title:'Send the truck now',due_date:await today(),assignees:to.map(k=>ids[k]),...extra}]))[0].ids.map(Number)};
const task=async id=>(await db.query('select * from lwb_tasks where id=$1',[id])).rows[0];
const ist=async(h,m=0,dayAdd=0)=>(await db.query("select ((public.lwb_task_today()+$3::int)::timestamp + make_interval(hours=>$1::int,mins=>$2::int)) at time zone 'Asia/Kolkata' t",[h,m,dayAdd])).rows[0].t;
const tick=async at=>(await db.query('select public.lwb_task_siren_tick($1) n',[at])).rows[0].n;
const sirens=async who=>(await db.query("select title,message,is_read from erp_notifications where user_id=$1 and notification_type='TASK_SIREN' order by id",[ids[who]])).rows;

test('hours slot: inside 9-20 IST same time, before 9 -> 9 AM, after 8 PM -> next 9 AM', async()=>{
  const s=async t=>(await db.query('select public.lwb_task_siren_slot($1) s',[t])).rows[0].s.getTime();
  assert.equal(await s(await ist(10,15)),(await ist(10,15)).getTime());
  assert.equal(await s(await ist(19,59)),(await ist(19,59)).getTime());
  assert.equal(await s(await ist(7,0)),(await ist(9,0)).getTime());
  assert.equal(await s(await ist(20,0)),(await ist(9,0,1)).getTime());
  assert.equal(await s(await ist(23,30)),(await ist(9,0,1)).getTime());
});

test('urgent task gets the siren, normal task does not; rings every 20 min in hours only', async()=>{
  const [u]=await give('admin',['sales'],{priority:'URGENT'});
  const [n]=await give('admin',['sales']);
  assert.equal((await task(u)).siren,true);
  assert.equal((await task(n)).siren,false);
  await db.query('update lwb_tasks set siren_next_at=$2 where id=$1',[u,await ist(10,0)]);
  assert.equal(await tick(await ist(10,0)),1);
  assert.equal(await tick(await ist(10,10)),0);            // not yet 20 min
  assert.equal(await tick(await ist(10,20)),1);            // 20 min later
  const b=await sirens('sales');
  assert.equal(b.length,2);
  assert.match(b[1].title,/^🚨 URGENT task · ring 2: Send the truck now$/);
  assert.match(b[1].message,new RegExp('^TSK-'+u+' · '));
  assert.deepEqual(b.map(x=>x.is_read),[true,false]);     // only the newest stays unread
  // 19:50 rings, 20:10 is outside: moves to 9 AM next day without a bell.
  await db.query('update lwb_tasks set siren_next_at=$2 where id=$1',[u,await ist(19,50)]);
  assert.equal(await tick(await ist(19,50)),1);
  assert.equal(await tick(await ist(20,10)),0);
  assert.equal((await task(u)).siren_next_at.getTime(),(await ist(9,0,1)).getTime());
  assert.equal(await tick(await ist(8,59,1)),0);
  assert.equal(await tick(await ist(9,0,1)),1);
  assert.equal((await task(u)).siren_count,4);
});

test('the person sees it in the app; Remind later; Done stops the siren and reads the bells', async()=>{
  const [u]=await give('admin',['head'],{priority:'URGENT'});
  await db.query('update lwb_tasks set siren_next_at=$2 where id=$1',[u,await ist(11,0)]);
  assert.equal(await tick(await ist(11,0)),1);
  await db.query('update lwb_tasks set siren_last_at=now() where id=$1',[u]); // rang just now
  await as('head');
  let mine=await call('select id,every_min from lwb_task_my_sirens()');
  assert.deepEqual(mine.map(r=>Number(r.id)),[u]);
  assert.equal(mine[0].every_min,20);
  await as('sales');assert.equal((await call('select lwb_task_siren_seen($1) ok',[u]))[0].ok,false); // not his
  await as('head');assert.equal((await call('select lwb_task_siren_seen($1) ok',[u]))[0].ok,true);
  assert.equal((await call('select count(*)::int n from lwb_task_my_sirens()'))[0].n,0);
  await call("select lwb_task_update($1,'DONE','Sent')",[u]);
  await db.query('update lwb_tasks set siren_next_at=$2 where id=$1',[u,await ist(11,0)]);
  assert.equal(await tick(await ist(11,30)),0);
  assert.equal((await db.query("select count(*)::int n from erp_notifications where user_id=$1 and notification_type='TASK_SIREN' and not is_read",[ids.head])).rows[0].n,0);
});

test('giver / Admin turns the siren off and on; others cannot; demo is Admin only', async()=>{
  const [u]=await give('head',['sales'],{priority:'URGENT'});
  await as('sales');await assert.rejects(call('select lwb_task_siren_set($1,false)',[u]),/giver or Admin/);
  await as('head');assert.equal((await call('select lwb_task_siren_set($1,false) v',[u]))[0].v,false);
  let t=await task(u);assert.equal(t.siren,false);assert.equal(t.siren_next_at,null);
  await as('admin');assert.equal((await call('select lwb_task_siren_set($1,true) v',[u]))[0].v,true);
  t=await task(u);assert.equal(t.siren,true);assert.ok(t.siren_next_at);
  const notes=(await db.query('select body from lwb_task_updates where task_id=$1 order by id',[u])).rows.map(r=>r.body);
  assert.deepEqual(notes,['🔕 Siren turned off','🚨 Siren turned on (every 20 min, 9 AM - 8 PM)']);
  await as('head');await assert.rejects(call('select lwb_task_siren_test()'),/Only Admin/);
  await as('admin');await call('select lwb_task_siren_test()');
  assert.equal((await sirens('admin')).length,1);
});

test('urgent task due later starts ringing at 9 AM on the due date; reopen restarts', async()=>{
  const due=(await db.query("select to_char(public.lwb_task_today()+2,'YYYY-MM-DD') d")).rows[0].d;
  const [u]=await give('admin',['sales'],{priority:'URGENT',due_date:due});
  assert.equal((await task(u)).siren_next_at.getTime(),(await ist(9,0,2)).getTime());
  await as('admin');await call("select lwb_task_update($1,'CANCELLED')",[u]);
  await call("select lwb_task_update($1,'OPEN')",[u]);
  assert.equal((await task(u)).siren_next_at.getTime(),(await ist(9,0,2)).getTime());
});
