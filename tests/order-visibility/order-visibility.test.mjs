import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_order_visibility_setup.sql on a tiny copy of the tables it reads (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',salesman:'00000000-0000-4000-8000-000000000002',
  driver:'00000000-0000-4000-8000-000000000003',manager:'00000000-0000-4000-8000-000000000004',accounts:'00000000-0000-4000-8000-000000000005'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,status text);
CREATE TABLE public.lwb_delivery_reports(id uuid default gen_random_uuid() primary key,order_id uuid unique,delivery_status text,reported_at timestamptz);
CREATE TABLE public.lwb_admin_order_marks(id uuid default gen_random_uuid() primary key,order_id uuid,kind text,mark_date date,marked_at timestamptz default now());
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role.toUpperCase()+' USER']);
// Stand-in for the live driver list (lwb_driver_delivery_setup.sql): one row per order with its report.
await db.exec(`CREATE FUNCTION public.lwb_driver_list_delivery_orders() RETURNS SETOF jsonb LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
  SELECT jsonb_build_object('order_id',o.id,'order_no',o.order_no,'report',CASE WHEN d.id IS NULL THEN NULL ELSE jsonb_build_object('reported_at',d.reported_at) END)
  FROM public.orders o LEFT JOIN public.lwb_delivery_reports d ON d.order_id=o.id $$`);
const sql=await readFile(new URL('../../lwb_order_visibility_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql); // safe to run again
await db.exec(`GRANT USAGE ON SCHEMA public,auth TO authenticated;
  GRANT SELECT ON public.lwb_delivery_reports,public.user_profiles TO authenticated;
  ALTER TABLE public.lwb_delivery_reports ENABLE ROW LEVEL SECURITY;
  CREATE POLICY read_all ON public.lwb_delivery_reports FOR SELECT TO authenticated USING (true);`);
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]])}
async function q(text,args){await db.exec('SET ROLE authenticated');try{return (await db.query(text,args)).rows}finally{await db.exec('RESET ROLE')}}
const o=async no=>(await db.query("insert into orders(order_no,status) values($1,'delivered') returning id",[no])).rows[0].id;
const old=await o('OLD-40'),recent=await o('NEW-3'),partial=await o('PART-20'),notDel=await o('NOT-50'),marked=await o('MARK-15'),open=await o('OPEN');
const ago=d=>new Date(Date.now()-d*86400000).toISOString();
await db.query(`insert into lwb_delivery_reports(order_id,delivery_status,reported_at) values
  ($1,'DELIVERED',$2),($3,'DELIVERED',$4),($5,'PARTIAL',$6),($7,'NOT_DELIVERED',$8)`,[old,ago(40),recent,ago(3),partial,ago(20),notDel,ago(50)]);
await db.query(`insert into lwb_admin_order_marks(order_id,kind,mark_date,marked_at) values($1,'DELIVERED',(now()-interval '15 days')::date,now())`,[marked]);
const all=[old,recent,partial,notDel,marked,open];
const hidden=async()=>(await q('select lwb_order_hidden_ids($1::uuid[]) as h',[all]))[0].h.sort();

test('nothing set = nothing hidden; only Admin can read or save the days', async()=>{
  await as('salesman');
  assert.deepEqual(await hidden(),[]);
  await assert.rejects(q('select * from lwb_order_visibility_list()'),/Only Admin/);
  await assert.rejects(q(`select lwb_order_visibility_save('[{"role":"sales","days":1}]')`),/Only Admin/);
  await assert.rejects(q('select * from lwb_order_visibility'),/permission denied/);
  await as('admin');
  const l=await q('select * from lwb_order_visibility_list()');
  assert.deepEqual(l.map(r=>r.role),['sales','manager','driver','accounts','warehouse','transport']);
  assert.ok(l.every(r=>r.days===null));
});

test('days per role: delivered (report or Admin mark) older than the days is hidden; not delivered stays', async()=>{
  await as('admin');
  await q(`select lwb_order_visibility_save('[{"role":"salesman","days":10},{"role":"driver","days":"30"},{"role":"manager","days":""},{"role":"accounts","days":0}]')`);
  const l=Object.fromEntries((await q('select * from lwb_order_visibility_list()')).map(r=>[r.role,r]));
  assert.equal(l.sales.days,10);assert.equal(l.driver.days,30);assert.equal(l.manager.days,null);assert.equal(l.accounts.days,0);
  assert.equal(l.sales.updated_by_name,'ADMIN USER');
  await as('salesman');
  assert.equal((await q('select lwb_order_visibility_mine() as d'))[0].d,10);
  assert.deepEqual(await hidden(),[old,partial,marked].sort());
  await as('driver');
  assert.deepEqual(await hidden(),[old]);
  await as('manager');
  assert.deepEqual(await hidden(),[]);
  await as('accounts');
  assert.deepEqual(await hidden(),[old,recent,partial,marked].sort());
  await as('admin');
  assert.deepEqual(await hidden(),[]);
});

test('bad input is refused; clearing a role brings everything back', async()=>{
  await as('admin');
  await assert.rejects(q(`select lwb_order_visibility_save('[{"role":"sales","days":-1}]')`),/whole days/);
  await assert.rejects(q(`select lwb_order_visibility_save('[{"role":"sales","days":5000}]')`),/3650/);
  await assert.rejects(q(`select lwb_order_visibility_save('[{"role":"boss","days":5}]')`),/Unknown role/);
  await q(`select lwb_order_visibility_save('[{"role":"sales","days":null}]')`);
  await as('salesman');
  assert.deepEqual(await hidden(),[]);
});

test('driver list: 12 hours as before when empty, Admin days when set', async()=>{
  const fresh=await o('FRESH-6H');
  await db.query(`insert into lwb_delivery_reports(order_id,delivery_status,reported_at) values($1,'DELIVERED',now()-interval '6 hours')`,[fresh]);
  const list=async()=>(await q('select x->>\'order_no\' as n from lwb_driver_my_delivery_orders() x')).map(r=>r.n).sort();
  await as('admin');
  await q(`select lwb_order_visibility_save('[{"role":"driver","days":null}]')`);
  await as('driver');
  assert.deepEqual(await list(),['FRESH-6H','MARK-15','OPEN']);
  assert.deepEqual((await q('select order_id from lwb_delivery_reports')).length,1);
  await as('admin');
  await q(`select lwb_order_visibility_save('[{"role":"driver","days":25}]')`);
  await as('driver');
  assert.deepEqual(await list(),['FRESH-6H','MARK-15','NEW-3','OPEN','PART-20']);
  assert.equal((await q('select order_id from lwb_delivery_reports')).length,3);
});
