import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_transport_change_lock_setup.sql on PGlite: driver / vehicle / Godown Manager can be changed by
// Sales Head / Manager until loading is CONFIRMED (also while loading). After that only Admin.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',godown:'00000000-0000-4000-8000-000000000003'};
const roles={admin:'admin',head:'manager',godown:'warehouse'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
CREATE FUNCTION public.lwb_active_role() RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active IS TRUE $$;
CREATE FUNCTION public.lwb_role_in(p_roles text[]) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT coalesce(public.lwb_active_role()=ANY(p_roles),false) $$;
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,status text);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,driver_name text,driver_mobile text,
  vehicle_no text,transporter_name text,loading_person text,loading_manager_id uuid,remarks text,loading_completed_at timestamptz,trip_id uuid);
GRANT USAGE ON SCHEMA public,auth TO authenticated;
GRANT SELECT,UPDATE ON public.dispatch_assignments,public.orders TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_role_in(text[]),public.lwb_active_role() TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true)',[id,roles[k]]);
const s=await sql('lwb_transport_change_lock_setup.sql');await db.exec(s);await db.exec(s); // safe to run again

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
async function po(status){const o=(await db.query("insert into orders(order_no,status) values('PO',$1) returning id",[status])).rows[0].id;
  await db.query("insert into dispatch_assignments(order_id,driver_name,vehicle_no,loading_person) values($1,'OLD','GJ01','HARSH')",[o]);return o;}
const change=(o,f,v)=>call(`update dispatch_assignments set ${f}=$2 where order_id=$1`,[o,v]);
const row=async o=>(await db.query('select * from dispatch_assignments where order_id=$1',[o])).rows[0];

test('Sales Head / Manager can change driver, vehicle and Godown Manager before and during loading', async()=>{
  await as('head');
  for(const st of ['transport_allocated','loading']){const o=await po(st);
    await change(o,'driver_name','NEW');await change(o,'vehicle_no','GJ05');await change(o,'loading_manager_id',ids.godown);await change(o,'loading_person','HARSH GAJERA');
    const r=await row(o);assert.equal(r.driver_name,'NEW');assert.equal(r.vehicle_no,'GJ05');assert.equal(r.loading_manager_id,ids.godown);}
});

test('After loading is confirmed: Sales Head / Godown Manager refused, Admin allowed', async()=>{
  for(const st of ['loaded','invoiced','delivered']){const o=await po(st);
    for(const who of ['head','godown']){await as(who);
      await assert.rejects(change(o,'driver_name','X'),/Only Admin/);
      await assert.rejects(change(o,'loading_manager_id',ids.godown),/Only Admin/);}
    await as('admin');await change(o,'vehicle_no','GJ09');assert.equal((await row(o)).vehicle_no,'GJ09');}
});

test('Other fields (remarks, times, trip) and system jobs are never blocked', async()=>{
  const o=await po('loaded');await as('head');
  await change(o,'remarks','note');await change(o,'loading_completed_at',new Date().toISOString());
  assert.equal((await row(o)).remarks,'note');
  await as('');await db.query("update dispatch_assignments set driver_name='SYS' where order_id=$1",[o]);
  assert.equal((await row(o)).driver_name,'SYS');
});
