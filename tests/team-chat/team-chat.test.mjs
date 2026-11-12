import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_team_chat_setup.sql on an empty PGlite database (no live database).
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
const setup=await readFile(new URL('../../lwb_team_chat_setup.sql',import.meta.url),'utf8');
await db.exec(setup);
await db.exec(setup); // safe to run again
async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const group=async k=>Number((await db.query('select id from lwb_chat_rooms where gkey=$1',[k])).rows[0].id);
const direct=async(who,to)=>{await as(who);return Number((await call('select lwb_chat_open_direct($1) id',[ids[to]]))[0].id)};
const send=async(who,room,body,tags=[])=>{await as(who);return Number((await call('select lwb_chat_send($1,$2,$3) id',[room,body,tags.map(k=>ids[k])]))[0].id)};
const list=async(who,all=false)=>{await as(who);return call('select * from lwb_chat_rooms_list($1)',[all])};
const see=async(who,room)=>{await as(who);return (await call('select body from lwb_chat_messages where room_id=$1 order by id',[room])).map(r=>r.body)};
const bells=async who=>(await db.query("select title,message,is_read,ref_id from erp_notifications where user_id=$1 and notification_type='CHAT_MSG' order by id",[ids[who]])).rows;

test('five groups, run twice = still five; people list = active logins except me', async()=>{
  assert.equal((await db.query('select count(*)::int n from lwb_chat_rooms where kind=$1',['GROUP'])).rows[0].n,5);
  await as('sales');
  const p=await call('select name,role_label from lwb_chat_people()');
  assert.equal(p.length,6);
  assert.ok(!p.some(x=>x.name==='Name sales'||x.name==='Name gone'));
  assert.ok(p.some(x=>x.name==='Name head'&&x.role_label==='Sales Head'));
});

test('personal chat: only the two people see it; Admin sees it but cannot write in it', async()=>{
  const room=await direct('head','sales');
  assert.equal(await direct('sales','head'),room,'same chat both ways');
  await send('head',room,'Coca-Cola report bhejo',['sales']);
  await send('sales',room,'Haan bhai, sham tak');
  assert.deepEqual(await see('sales',room),['Coca-Cola report bhejo','Haan bhai, sham tak']);
  assert.deepEqual(await see('head',room),['Coca-Cola report bhejo','Haan bhai, sham tak']);
  for(const w of ['sales2','driver','godown','acc'])assert.deepEqual(await see(w,room),[],w+' must not see');
  assert.equal((await see('admin',room)).length,2,'Admin sees every chat');
  await assert.rejects(send('admin',room,'hi'),/only look at this chat/);
  await assert.rejects(send('sales2',room,'hi'),/only look at this chat/);
  await as('sales');
  await assert.rejects(call('select lwb_chat_open_direct($1)',[ids.sales]),/another person/);
  await assert.rejects(call('select lwb_chat_open_direct($1)',[ids.gone]),/not active/);
});

test('groups: members by role, Admin + Sales Head in every group, everyone can reply', async()=>{
  const sales=await group('SALES'),all=await group('ALL'),drivers=await group('DRIVERS');
  await send('admin',sales,'Kal se naya rate');
  await send('sales2',sales,'Theek hai');
  await send('head',sales,'Sab party ko batao');
  assert.equal((await see('sales',sales)).length,3);
  assert.deepEqual(await see('driver',sales),[],'driver not in sales group');
  await assert.rejects(send('driver',sales,'x'),/not in it/);
  await send('driver',all,'Gaadi 4 ka tyre');
  await send('acc',all,'Noted');
  assert.equal((await see('godown',all)).length,2);
  await send('head',drivers,'Sab driver 9 baje');
  assert.equal((await see('driver',drivers)).length,1);
  const mine=(await list('sales')).map(r=>r.name);
  assert.ok(mine.includes('@All Team')&&mine.includes('@All Sales Team'));
  assert.ok(!mine.includes('@All Drivers')&&!mine.includes('@All Godown'));
  const headList=(await list('head')).map(r=>r.name);
  for(const g of ['@All Team','@All Sales Team','@All Drivers','@All Godown','@All Accounts'])assert.ok(headList.includes(g),g);
});

test('unread count, @mention flag, one bell per chat until read, read closes the bell', async()=>{
  const room=await direct('godown','acc');
  await send('godown',room,'PO-1182 bill banao');
  await send('godown',room,'Jaldi');
  let r=(await list('acc')).find(x=>Number(x.id)===room);
  assert.equal(r.unread,2);assert.equal(r.name,'Name godown');assert.equal(r.sub,'Godown Manager');
  let b=(await bells('acc')).filter(x=>Number(x.ref_id)===room);
  assert.equal(b.length,1,'one bell for two messages');
  assert.equal(b[0].title,'Chat: Name godown');
  await as('acc');await call('select lwb_chat_read($1)',[room]);
  r=(await list('acc')).find(x=>Number(x.id)===room);
  assert.equal(r.unread,0);
  assert.ok((await bells('acc')).filter(x=>Number(x.ref_id)===room).every(x=>x.is_read));
  await send('godown',room,'Ho gaya?');
  assert.equal((await bells('acc')).filter(x=>Number(x.ref_id)===room&&!x.is_read).length,1,'new bell after reading');
  // mention in a group: tagged person gets "@ " bell and the flag; a non-member tag is dropped
  const all=await group('ALL');
  await as('sales');await call('select lwb_chat_read($1)',[all]);
  const mid=await send('head',all,'@Name sales aaj ka collection?',['sales','driver','gone']);
  const m=(await db.query('select mentions from lwb_chat_messages where id=$1',[mid])).rows[0].mentions;
  assert.deepEqual(m.sort(),[ids.sales,ids.driver].sort());
  r=(await list('sales')).find(x=>Number(x.id)===all);
  assert.equal(r.mention,true);
  assert.ok((await bells('sales')).some(x=>x.title.startsWith('@ @All Team · Name head')));
  assert.ok(!(await bells('head')).some(x=>x.message.includes('aaj ka collection')),'no bell to the sender');
});

test('Admin: everyone\'s chats list, delete one message / whole chat; others cannot', async()=>{
  const room=await direct('sales','sales2');
  const m1=await send('sales',room,'Party ne 2 din maange');
  await send('sales2',room,'Ok');
  await assert.rejects(list('head',true),/Only Admin/);
  const all=await list('admin',true);
  const row=all.find(x=>Number(x.id)===room);
  assert.equal(row.name,'Name sales ↔ Name sales2');assert.equal(row.member,false);
  assert.ok(!all.some(x=>x.kind==='GROUP'));
  await as('head');
  await assert.rejects(call('select lwb_chat_delete($1,$2)',[room,m1]),/Only Admin/);
  await as('admin');
  assert.equal((await call('select lwb_chat_delete($1,$2) n',[room,m1]))[0].n,1);
  assert.deepEqual(await see('sales',room),['Ok']);
  await as('admin');
  assert.equal((await call('select lwb_chat_delete($1) n',[room]))[0].n,1);
  assert.equal((await db.query('select count(*)::int n from lwb_chat_rooms where id=$1',[room])).rows[0].n,0);
  assert.equal((await bells('sales2')).filter(x=>Number(x.ref_id)===room).length,0,'bells of a deleted chat removed');
});

test('input checks and no direct table writes', async()=>{
  const all=await group('ALL');
  await as('sales');
  await assert.rejects(call('select lwb_chat_send($1,$2)',[all,'   ']),/Type a message/);
  await assert.rejects(call('select lwb_chat_send($1,$2)',[all,'x'.repeat(2001)]),/too long/);
  await assert.rejects(call("insert into lwb_chat_messages(room_id,body) values($1,'hack')",[all]),/permission denied/);
  await as('gone');
  await assert.rejects(call('select lwb_chat_send($1,$2)',[all,'hi']),/not active/);
  await assert.rejects(call('select * from lwb_chat_rooms_list()'),/not active/);
});
