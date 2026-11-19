import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_order_delay_alert_setup.sql on a tiny copy of the tables it reads (no live database).
// Delayed orders get ONE bell per limit for Admin + Sales Head; nothing about the order changes.
const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000002',warehouse:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz,created_at timestamptz,customer_name text,status text,total_amount numeric);
CREATE TABLE public.lwb_delivery_reports(order_id uuid,delivery_status text);
CREATE TABLE public.lwb_admin_order_marks(order_id uuid,kind text);
CREATE TABLE public.erp_notifications(id uuid default gen_random_uuid() primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false,created_at timestamptz default now());
CREATE FUNCTION public.lwb_order_pending(p_status text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(lower(btrim(p_status)),'') IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new') $$;
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role+' user']);
const sql=await readFile(new URL('../../lwb_order_delay_alert_setup.sql',import.meta.url),'utf8');
await db.exec(sql.slice(0,sql.indexOf('-- Every 30 minutes')));
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');

async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q){await db.exec('SET ROLE authenticated');try{return (await db.query(q)).rows}finally{await db.exec('RESET ROLE')}}
let n=0;
async function order(status,hoursAgo,extra={}){
  const r=await db.query(`insert into orders(order_no,order_date,created_at,customer_name,status,total_amount)
    values($1,now()-make_interval(hours=>$2),now()-make_interval(hours=>$2),$3,$4,1000) returning id`,['LXY-'+(100+ ++n),hoursAgo,'Party '+n,status]);
  const id=r.rows[0].id;
  if(extra.delivered)await db.query("insert into lwb_delivery_reports values($1,'DELIVERED')",[id]);
  if(extra.marked)await db.query("insert into lwb_admin_order_marks values($1,'DELIVERED')",[id]);
  return id;
}
const bells=async()=> (await db.query('select user_id,title,notification_type,order_id from erp_notifications order by title')).rows;

test('only staff logins can run it; salesman and anon cannot',async()=>{
  await as('sales');await assert.rejects(call('select lwb_order_delay_notify() j'),/Not allowed/);
  assert.equal((await db.query("select has_function_privilege('anon','public.lwb_order_delay_notify()','EXECUTE') a")).rows[0].a,false);
  assert.equal((await db.query("select has_function_privilege('authenticated','public.lwb_order_delay_notify_internal()','EXECUTE') a")).rows[0].a,false);
});

test('one bell per late order, to Admin + Sales Head only, never twice',async()=>{
  const ok=await order('pending_approval',3);            // on time
  const lateA=await order('pending_approval',15);        // approval late only
  const lateD=await order('approved',40);                // delivery late
  const both=await order('pending_approval',50);         // approval + delivery late
  await order('loaded',60,{delivered:true});             // delivered: no bell
  await order('loaded',60,{marked:true});                // marked delivered: no bell
  await order('cancelled',80);                           // cancelled: no bell
  const before=(await db.query('select id,status from orders order by id')).rows;
  await as('warehouse');
  const r=(await call('select lwb_order_delay_notify() j'))[0].j;
  assert.equal(r.approval,2);assert.equal(r.delivery,2);
  const b=await bells();
  assert.equal(b.length,8,'4 alerts x (admin + manager)');
  assert.ok(b.every(x=>[ids.admin,ids.manager].includes(x.user_id)));
  assert.deepEqual([...new Set(b.filter(x=>x.notification_type==='ORDER_DELAY_APPROVAL').map(x=>x.order_id))].sort(),[lateA,both].sort());
  assert.deepEqual([...new Set(b.filter(x=>x.notification_type==='ORDER_DELAY_DELIVERY').map(x=>x.order_id))].sort(),[lateD,both].sort());
  assert.ok(!b.some(x=>x.order_id===ok));
  // run again: nothing new
  const again=(await call('select lwb_order_delay_notify() j'))[0].j;
  assert.equal(again.new,0);assert.equal((await bells()).length,8);
  // orders untouched (never blocked / changed)
  assert.deepEqual((await db.query('select id,status from orders order by id')).rows,before);
});

test('more than 3 new late orders in one run -> one combined bell each',async()=>{
  await db.exec('delete from erp_notifications');
  for(let i=0;i<9;i++)await order('approved',40+i);
  const r=(await db.query('select lwb_order_delay_notify_internal() j')).rows[0].j;
  assert.equal(r.delivery,9);
  const b=await bells();
  assert.equal(b.length,2);
  assert.match(b[0].title,/^9 POs delivery late 36h\+$/);
  const m=(await db.query('select message from erp_notifications limit 1')).rows[0].message;
  assert.match(m,/\+ 3 more/);assert.match(m,/not blocked|work as normal/);
});
