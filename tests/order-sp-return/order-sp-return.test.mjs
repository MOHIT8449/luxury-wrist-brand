import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_sheet_pallet_setup.sql + lwb_order_sheet_pallet_setup.sql + lwb_order_sp_return_setup.sql on PGlite.
const ids={admin:'00000000-0000-4000-8000-000000000001',sales:'00000000-0000-4000-8000-000000000002',
  acc:'00000000-0000-4000-8000-000000000004',wh:'00000000-0000-4000-8000-000000000005'};
const roles={admin:'admin',sales:'sales',acc:'accounts',wh:'warehouse'};
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
const file=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(await file('lwb_sheet_pallet_setup.sql'));
await db.exec(await file('lwb_order_sheet_pallet_setup.sql'));
const sql=await file('lwb_order_sp_return_setup.sql');
await db.exec(sql);await db.exec(sql); // safe to run again
const ord=(await db.query(`insert into orders(order_no,order_date,customer_name,status,transportation,created_by) values
 ('LXY-1','2026-11-03T05:00:00Z','Shree Traders','delivered','DELIVERY',$1),
 ('LXY-2','2026-11-03T05:00:00Z','Shree Traders','delivered','DELIVERY',$1) returning id`,[ids.sales])).rows.map(r=>r.id);

async function run(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('SET ROLE authenticated');
  try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}
}
const set=(who,id,p,s,rp,rs)=>run(who,'select public.lwb_set_order_sp($1,$2,$3,$4,$5) v',[id,p,s,rp,rs]).then(r=>r.rows[0].v);
const ledger=id=>db.query("select entry_type,party_name,pallets,sheets,ref_no,source from lwb_sp_entries where order_id=$1 order by entry_type",[id]).then(r=>r.rows);
const balance=()=>db.query(`select sum(case entry_type when 'PARTY_OUT' then pallets else -pallets end)::int p,
  sum(case entry_type when 'PARTY_OUT' then sheets else -sheets end)::int s from lwb_sp_entries where party_name='Shree Traders'`).then(r=>r.rows[0]);

test('accounts writes given + returned on a delivered PO: two ledger rows', async()=>{
  const v=await set('acc',ord[0],11,40,5,10);
  assert.equal(v.changed,true);
  assert.deepEqual((await db.query('select sp_pallets,sp_sheets,sp_ret_pallets,sp_ret_sheets from orders where id=$1',[ord[0]])).rows[0],
    {sp_pallets:11,sp_sheets:40,sp_ret_pallets:5,sp_ret_sheets:10});
  assert.deepEqual(await ledger(ord[0]),[
    {entry_type:'PARTY_IN',party_name:'Shree Traders',pallets:5,sheets:10,ref_no:'LXY-1',source:'ORDER_RETURN'},
    {entry_type:'PARTY_OUT',party_name:'Shree Traders',pallets:11,sheets:40,ref_no:'LXY-1',source:'ORDER'}]);
  assert.deepEqual(await balance(),{p:6,s:30});
});

test('change keeps one row each; returned 0 + 0 removes only the return row', async()=>{
  await set('wh',ord[0],11,40,11,20);
  assert.equal((await ledger(ord[0])).length,2);
  assert.deepEqual(await balance(),{p:0,s:20});
  assert.equal((await set('admin',ord[0],11,40,11,20)).changed,false);
  await set('admin',ord[0],11,40,0,0);
  assert.deepEqual((await ledger(ord[0])).map(r=>r.source),['ORDER']);
  await set('admin',ord[1],0,0,3,0); // party returns old pallets on another PO
  assert.deepEqual(await balance(),{p:8,s:40});
});

test('salesman cannot; bad numbers refused; cancel and delete remove both rows', async()=>{
  await assert.rejects(set('sales',ord[0],1,1,0,0),/Only Admin, Sales Head, Accounts/);
  await assert.rejects(set('acc',ord[0],-1,0,0,0),/0 to 999/);
  await assert.rejects(set('acc',ord[0],0,0,0,10000),/0 to 999/);
  await set('acc',ord[0],11,40,2,2);
  await db.query("update orders set customer_name='Shree Traders Ltd' where id=$1",[ord[0]]);
  assert.deepEqual((await ledger(ord[0])).map(r=>r.party_name),['Shree Traders Ltd','Shree Traders Ltd']);
  await db.query("update orders set status='cancelled' where id=$1",[ord[0]]);
  assert.deepEqual(await ledger(ord[0]),[]);
  await assert.rejects(set('acc',ord[0],1,0,0,0),/cancelled/);
  await db.query("delete from orders where id=$1",[ord[1]]);
  assert.equal((await db.query("select count(*)::int n from lwb_sp_entries")).rows[0].n,0);
});

test('old RPC still works and app users cannot call the internal sync', async()=>{
  await db.query("insert into orders(id,order_no,customer_name,status,created_by) values('00000000-0000-4000-8000-0000000000aa','LXY-9','Ram','approved',$1)",[ids.sales]);
  await run('sales','select public.lwb_set_order_sheet_pallet($1,11,0)',['00000000-0000-4000-8000-0000000000aa']);
  assert.equal((await ledger('00000000-0000-4000-8000-0000000000aa')).length,1);
  await assert.rejects(run('sales','select public.lwb_sp_sync_order_return($1)',['00000000-0000-4000-8000-0000000000aa']),/permission denied/);
});
