import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_po_reapproval_setup.sql on a small copy of the live tables (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000002',
  sales:'00000000-0000-4000-8000-000000000003',godown:'00000000-0000-4000-8000-000000000004'};
const role={admin:'admin',manager:'manager',sales:'sales',godown:'warehouse'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text,
  total_qty numeric,approved_by uuid,created_by uuid);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,loading_manager_id uuid);
CREATE TABLE public.erp_notifications(id serial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean default false);
CREATE FUNCTION public.lwb_order_pending(p_status text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(lower(btrim(p_status)),'') IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new') $$;
GRANT USAGE ON SCHEMA public,auth TO authenticated;
GRANT SELECT,UPDATE ON public.orders TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role[k],k.toUpperCase()]);
await db.exec(await readFile(new URL('../../lwb_po_reapproval_setup.sql',import.meta.url),'utf8'));
async function as(r){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[r]])}
async function call(sql,args){await db.exec('SET ROLE authenticated');try{return (await db.query(sql,args)).rows}finally{await db.exec('RESET ROLE')}}
const one=async(sql,args)=>(await db.query(sql,args)).rows[0];
async function order(no,status,crew=false){
  const o=(await one('insert into orders(order_no,customer_name,status,total_qty,created_by) values($1,$2,$3,10,$4) returning id',[no,'RAM STORES',status,ids.sales])).id;
  if(crew)await db.query('insert into dispatch_assignments(order_id,loading_manager_id) values($1,$2)',[o,ids.godown]);
  return o;
}
const st=async o=>(await one('select status,reapprove_from from orders where id=$1',[o]));
const bells=async(o,type)=>(await db.query('select u.role from erp_notifications n join user_profiles u on u.id=n.user_id where n.order_id=$1 and n.notification_type=$2 and not n.is_read order by 1',[o,type])).rows.map(r=>r.role);

test('Sales Head edit of a Transport Assigned PO: pending, Admin approves, back to Transport Assigned', async()=>{
  const o=await order('LXY-1','transport_allocated',true);
  await as('manager');
  const r=(await call('select lwb_po_send_reapproval($1,$2) r',[o,'COKE 250 10 -> 12 CS']))[0].r;
  assert.equal(r.back_to,'transport_allocated');
  assert.deepEqual(await st(o),{status:'pending_approval',reapprove_from:'transport_allocated'});
  assert.deepEqual(await bells(o,'PO_REAPPROVAL'),['admin']);
  assert.deepEqual(await bells(o,'PO_EDIT_HOLD'),['warehouse']);
  // Sales Head can not approve his own edit
  await assert.rejects(call("update orders set status='approved' where id=$1",[o]),/only Admin/);
  await as('admin');
  await call("update orders set status='approved',approved_by=$2 where id=$1",[o,ids.admin]);
  assert.deepEqual(await st(o),{status:'transport_allocated',reapprove_from:null});
  assert.deepEqual(await bells(o,'PO_REAPPROVAL'),[]);
  assert.deepEqual(await bells(o,'PO_EDIT_APPROVED'),['warehouse']);
});

test('Transport Pending PO goes back to approved; normal pending PO approves as before', async()=>{
  const o=await order('LXY-2','approved');
  await as('admin');
  await call('select lwb_po_send_reapproval($1,null)',[o]);
  assert.equal((await st(o)).status,'pending_approval');
  await call("update orders set status='approved' where id=$1",[o]);
  assert.deepEqual(await st(o),{status:'approved',reapprove_from:null});
  const p=await order('LXY-3','pending_approval');
  await as('manager');
  await call("update orders set status='approved' where id=$1",[p]);
  assert.equal((await st(p)).status,'approved','a normal PO is still approved by the Sales Head');
});

test('Loading PO and salesman are refused; cancel clears the mark', async()=>{
  const l=await order('LXY-4','loading',true);
  await as('manager');
  await assert.rejects(call('select lwb_po_send_reapproval($1,null)',[l]),/before loading/);
  await as('sales');
  const a=await order('LXY-5','approved');
  await assert.rejects(call('select lwb_po_send_reapproval($1,null)',[a]),/Only Admin or Sales Head/);
  await as('manager');
  await call('select lwb_po_send_reapproval($1,null)',[a]);
  await call("update orders set status='cancelled' where id=$1",[a]);
  assert.deepEqual(await st(a),{status:'cancelled',reapprove_from:null});
});
