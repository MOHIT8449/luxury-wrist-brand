import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_sheet_pallet_setup.sql + lwb_order_sheet_pallet_setup.sql on an empty PGlite database.
const ids={admin:'00000000-0000-4000-8000-000000000001',sales:'00000000-0000-4000-8000-000000000002',
  other:'00000000-0000-4000-8000-000000000003',acc:'00000000-0000-4000-8000-000000000004'};
const roles={admin:'admin',sales:'sales',other:'sales',acc:'accounts'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE auth.users(id uuid primary key,email text);
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz default now(),
  customer_name text,status text,transportation text,created_by uuid);
GRANT USAGE ON SCHEMA public, auth TO authenticated; GRANT SELECT ON public.orders, public.user_profiles TO authenticated;
`);
for(const [k,id] of Object.entries(ids)){await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k],'Name '+k]);await db.query('insert into auth.users values($1,$2)',[id,k+'@x'])}
await db.exec(await readFile(new URL('../../lwb_sheet_pallet_setup.sql',import.meta.url),'utf8'));
const sql=await readFile(new URL('../../lwb_order_sheet_pallet_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql); // safe to run again
const ord=(await db.query(`insert into orders(order_no,order_date,customer_name,status,transportation,created_by) values
 ('LXY-1','2026-11-03T05:00:00Z','Shree Traders','pending_approval','DIRECT VEHICLE | VEHICLE: GJ05 AB 1234',$1),
 ('LXY-2','2026-11-03T05:00:00Z','Ram Stores','approved','DIRECT VEHICLE',$1),
 ('LXY-3','2026-11-03T05:00:00Z','Delivered Co','delivered','DIRECT VEHICLE',$1) returning id`,[ids.sales])).rows.map(r=>r.id);

async function run(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('SET ROLE authenticated');
  try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}
}
const set=(who,id,p,s)=>run(who,'select public.lwb_set_order_sheet_pallet($1,$2,$3) v',[id,p,s]).then(r=>r.rows[0].v);
const ledger=id=>db.query("select entry_type,party_name,pallets,sheets,ref_no,vehicle_no,entry_date::text d,source from lwb_sp_entries where order_id=$1",[id]).then(r=>r.rows);

test('salesman saves pallet + sheet on own PO: order and ledger get it', async()=>{
  const v=await set('sales',ord[0],11,40);
  assert.equal(v.changed,true);
  const o=(await db.query('select sp_pallets,sp_sheets from orders where id=$1',[ord[0]])).rows[0];
  assert.deepEqual(o,{sp_pallets:11,sp_sheets:40});
  assert.deepEqual(await ledger(ord[0]),[{entry_type:'PARTY_OUT',party_name:'Shree Traders',pallets:11,sheets:40,ref_no:'LXY-1',vehicle_no:'GJ05AB1234',d:'2026-11-03',source:'ORDER'}]);
});

test('changing the numbers updates the same ledger row; 0 + 0 removes it', async()=>{
  await set('sales',ord[0],11,55);
  let l=await ledger(ord[0]);assert.equal(l.length,1);assert.equal(l[0].sheets,55);
  assert.equal((await set('sales',ord[0],11,55)).changed,false);
  await set('sales',ord[0],0,0);
  assert.deepEqual(await ledger(ord[0]),[]);
  await set('sales',ord[0],11,40);
});

test('only own order for salesman; accounts can set any; delivered blocks salesman', async()=>{
  await assert.rejects(set('other',ord[1],11,10),/Only the person who took the order/);
  await set('acc',ord[1],11,0);
  assert.equal((await ledger(ord[1]))[0].pallets,11);
  await assert.rejects(set('sales',ord[2],11,5),/already delivered/);
  await set('admin',ord[2],11,5);
  await assert.rejects(set('sales',ord[0],-1,5),/0 to 999/);
});

test('cancel removes the ledger row; delete removes it; hand-typed rows stay', async()=>{
  await db.query("insert into lwb_sp_entries(entry_date,entry_type,party_name,pallets,sheets,order_id) values('2026-11-03','PARTY_OUT','Ram Stores',2,0,$1)",[ord[1]]);
  await db.query("update orders set customer_name='Ram Stores Ltd' where id=$1",[ord[1]]);
  assert.equal((await db.query("select party_name from lwb_sp_entries where order_id=$1 and source='ORDER'",[ord[1]])).rows[0].party_name,'Ram Stores Ltd');
  await db.query("update orders set status='cancelled' where id=$1",[ord[1]]);
  assert.deepEqual((await ledger(ord[1])).map(r=>r.source),[null]);
  await assert.rejects(set('admin',ord[1],11,0),/cancelled/);
  await db.query("delete from orders where id=$1",[ord[0]]);
  assert.equal((await db.query("select count(*)::int n from lwb_sp_entries where ref_no='LXY-1'")).rows[0].n,0);
});

test('app users cannot call the internal sync directly', async()=>{
  await assert.rejects(run('sales','select public.lwb_sp_sync_order($1)',[ord[2]]),/permission denied/);
});
