import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_sheet_pallet_setup.sql + lwb_sp_company_statement_setup.sql on PGlite.
const ids={admin:'00000000-0000-4000-8000-000000000001',acc:'00000000-0000-4000-8000-000000000004'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE auth.users(id uuid primary key,email text);
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
await db.query("insert into user_profiles values($1,'admin',true,'Admin'),($2,'accounts',true,'Acc')",[ids.admin,ids.acc]);
await db.query("insert into auth.users values($1,'a@x'),($2,'b@x')",[ids.admin,ids.acc]);
const file=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(await file('lwb_sheet_pallet_setup.sql'));
const sql=await file('lwb_sp_company_statement_setup.sql');
await db.exec(sql);await db.exec(sql); // safe to run again
const sql2=await file('lwb_sp_query_remarks_setup.sql');
await db.exec(sql2);await db.exec(sql2);

async function run(who,q,params){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);
  await db.exec('SET ROLE authenticated');
  try{return await db.query(q,params)}finally{await db.exec('RESET ROLE')}
}
await db.exec(`insert into lwb_sp_entries(entry_date,entry_type,party_name,pallets,sheets,ref_no) values
 ('2026-09-01','COMPANY_IN',null,500,300,'OPENING BALANCE'),
 ('2026-10-10','COMPANY_IN',null,24,0,'7000001'),
 ('2026-10-12','PARTY_OUT','SHREE',5,0,'LXY-1'),
 ('2026-11-01','COMPANY_IN',null,24,0,'7012785515'),
 ('2026-11-03','COMPANY_IN',null,10,10,'OPENING BALANCE')`);
const P={file_name:'ILS.xlsx',from_date:'2026-11-01',to_date:'2026-12-31',opening:{sheets:3953,leap:1116,chep:0,own:358},closing:{sheets:4122,leap:1216,chep:0,own:839},
  lines:[{line_date:'2026-11-01',plant:'Goblej',ref_doc:'0342431592',entry_type:'Issue',sheets:0,leap:24,chep:0,own:0,vehicle_no:'GJ01CZ8193',inv_no:'7012785515'},
         {line_date:'2026-11-07',plant:'Goblej',ref_doc:'0081163530',entry_type:'Receipt',sheets:-900,leap:-176,chep:0,own:0,vehicle_no:'GJ 12 AT 8915',inv_no:'7012786292'}]};

test('only admin / manager upload; accounts can read', async()=>{
  await assert.rejects(run('acc','select lwb_sp_stmt_upload($1)',[P]),/Only Admin/);
  const r=(await run('admin','select lwb_sp_stmt_upload($1) v',[P])).rows[0].v;
  assert.equal(r.lines,2);
  const rows=(await run('acc','select entry_type,sheets,leap,vehicle_no from lwb_sp_stmt order by line_date')).rows;
  assert.deepEqual(rows,[{entry_type:'Issue',sheets:0,leap:24,vehicle_no:'GJ01CZ8193'},{entry_type:'Receipt',sheets:-900,leap:-176,vehicle_no:'GJ12AT8915'}]);
  await assert.rejects(run('acc','insert into lwb_sp_stmt(line_date,entry_type) values (now(),$1)',['x']),/permission/);
});

test('upload again replaces the same dates; line outside dates refused', async()=>{
  await run('admin','select lwb_sp_stmt_upload($1)',[P]);
  assert.equal((await db.query('select count(*)::int n from lwb_sp_stmt')).rows[0].n,2);
  await assert.rejects(run('admin','select lwb_sp_stmt_upload($1)',[{...P,lines:[{...P.lines[0],line_date:'2026-10-30'}]}]),/outside/);
  assert.equal((await db.query('select count(*)::int n from lwb_sp_stmt')).rows[0].n,2);
});

test('start from 1 Nov: opening replaced, old rows kept, history has the removed opening', async()=>{
  await assert.rejects(run('acc','select lwb_sp_start_from($1,$2,$3)',['2026-11-01',1474,3953]),/Only Admin/);
  const v=(await run('admin','select lwb_sp_start_from($1,$2,$3) v',['2026-11-01',1474,3953])).rows[0].v;
  assert.equal(v.hidden,3);assert.equal(v.old_opening_replaced,1);
  assert.equal((await db.query('select start_date::text d from lwb_sp_settings')).rows[0].d,'2026-11-01');
  const op=(await db.query("select entry_date::text d,pallets,sheets from lwb_sp_entries where ref_no='OPENING BALANCE' order by entry_date")).rows;
  assert.deepEqual(op,[{d:'2026-09-01',pallets:500,sheets:300},{d:'2026-11-01',pallets:1474,sheets:3953}]);
  assert.equal((await db.query('select count(*)::int n from lwb_sp_entries')).rows[0].n,5);
  assert.equal((await db.query("select count(*)::int n from lwb_sp_history where action='DELETE'")).rows[0].n,1);
  await run('admin','select lwb_sp_start_from(null,0,0)');
  assert.equal((await db.query('select start_date from lwb_sp_settings')).rows[0].start_date,null);
});

test('query tick by admin is not logged as an edit; accounts cannot set it', async()=>{
  const id=(await db.query("select id from lwb_sp_entries where ref_no='7012785515'")).rows[0].id;
  await run('admin',"update lwb_sp_entries set query_note='Short 2',query_at=now() where id=$1",[id]);
  assert.equal((await db.query('select query_note from lwb_sp_entries where id=$1',[id])).rows[0].query_note,'Short 2');
  assert.equal((await db.query("select count(*)::int n from lwb_sp_history where action='EDIT'")).rows[0].n,0);
  const r=await run('acc',"update lwb_sp_entries set query_note='x' where id=$1",[id]);
  assert.equal(r.affectedRows,0);
});

test('query remark: admin saves / updates / marks mailed; accounts only reads', async()=>{
  await assert.rejects(run('acc','select lwb_sp_remark_save($1)',[{item_key:'IN:7012785465',kind:'SHORT',sheets:115}]),/Only Admin/);
  await run('admin','select lwb_sp_remark_save($1)',[{item_key:'IN:7012785465',kind:'SHORT',pallets:0,sheets:115,note:'written on bill'}]);
  await run('admin','select lwb_sp_remark_save($1)',[{item_key:'IN:7012785465',kind:'SHORT',pallets:1,sheets:115,note:'written on bill'}]);
  let r=(await run('acc','select kind,pallets,sheets,status,updated_by_name from lwb_sp_stmt_remarks')).rows;
  assert.deepEqual(r,[{kind:'SHORT',pallets:1,sheets:115,status:'OPEN',updated_by_name:'Admin'}]);
  assert.equal((await run('admin','select lwb_sp_remark_status($1,$2) n',[['IN:7012785465','IN:x'],'MAILED'])).rows[0].n,1);
  r=(await db.query('select status,mailed_at is not null m from lwb_sp_stmt_remarks')).rows[0];
  assert.deepEqual(r,{status:'MAILED',m:true});
  await assert.rejects(run('admin','select lwb_sp_remark_save($1)',[{item_key:'IN:1',kind:'BAD'}]),/check/);
  await run('admin','select lwb_sp_remark_save($1)',[{item_key:'IN:7012785465',kind:''}]);
  assert.equal((await db.query('select count(*)::int n from lwb_sp_stmt_remarks')).rows[0].n,0);
  await assert.rejects(run('acc',"insert into lwb_sp_stmt_remarks(item_key,kind) values('IN:9','SHORT')"),/permission/);
});
