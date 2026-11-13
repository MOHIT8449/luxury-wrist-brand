import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_rate_ledger_fix_setup.sql (after the rate scheme + ledger SQL) on an empty PGlite database (no live data), storage schema stubbed.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',sales:'00000000-0000-4000-8000-000000000004'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE SCHEMA storage;
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(id bigserial primary key,bucket_id text,name text);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
CREATE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql AS $$ SELECT string_to_array(name,'/') $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
GRANT USAGE ON SCHEMA public, auth, storage TO authenticated;
`);
for(const [k,r] of [['admin','admin'],['head','manager'],['sales','sales']])await db.query('insert into user_profiles values($1,$2,true,$3)',[ids[k],r,k.toUpperCase()]);
const read=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(await read('lwb_rate_scheme_setup.sql'));
const sql=await read('lwb_rate_ledger_setup.sql');
await db.exec(sql);
const fix=await read('lwb_rate_ledger_fix_setup.sql');
await db.exec(fix);await db.exec(fix); // safe to run again
async function run(who,q,p){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);await db.exec('SET ROLE authenticated');try{return await db.query(q,p)}finally{await db.exec('RESET ROLE')}}
const save=(who,rows)=>run(who,`select public.lwb_save_rates('{}'::jsonb,'[]'::jsonb,'x',$1::jsonb)`,[JSON.stringify(rows)]);
const fixQ='select public.lwb_rate_history_fix($1,$2,$3::jsonb,$4::date,$5) r';

test('Admin fixes free bottle of one pack; other packs and the log stay right', async()=>{
  await save('head',[{name:'250 ML PET',fb:2.5,oms:40.2,land:440},{name:'1 LTR KINLEY',fb:0,oms:40,land:120}]);
  const id=(await db.query('select max(id) id from lwb_rate_history')).rows[0].id;
  const r=(await run('admin',fixQ,[id,'250 ml pet',JSON.stringify({fb:2.8,oms:46.89}),'2026-11-01','Typed 2.5, circular says 2.8'])).rows[0].r;
  assert.equal(r.row.fb,2.8);assert.equal(r.valid_from,'2026-11-01');
  const h=(await db.query('select rows,valid_from::text v,fix_count from lwb_rate_history where id=$1',[id])).rows[0];
  assert.deepEqual(h.rows,[{name:'250 ML PET',fb:2.8,oms:46.89,land:440},{name:'1 LTR KINLEY',fb:0,oms:40,land:120}]);
  assert.equal(h.v,'2026-11-01');assert.equal(h.fix_count,1);
  const f=(await run('head','select pack_name,old_row,new_row,reason,created_by from lwb_rate_history_fixes')).rows;
  assert.equal(f.length,1);assert.equal(f[0].old_row.fb,2.5);assert.equal(f[0].new_row.fb,2.8);assert.equal(f[0].created_by,ids.admin);
  // only the date
  await run('admin',fixQ,[id,null,null,'2026-11-03','Scheme started on 3 Nov']);
  assert.equal((await db.query('select valid_from::text v from lwb_rate_history where id=$1',[id])).rows[0].v,'2026-11-03');
});

test('only Admin, reason needed, numbers only, known fields, pack must be there', async()=>{
  const id=(await db.query('select max(id) id from lwb_rate_history')).rows[0].id;
  await assert.rejects(run('head',fixQ,[id,'250 ML PET','{"fb":3}',null,'x']),/Only Admin/);
  await assert.rejects(run('sales',fixQ,[id,'250 ML PET','{"fb":3}',null,'x']),/Only Admin/);
  await assert.rejects(run('admin',fixQ,[id,'250 ML PET','{"fb":3}',null,' ']),/why/);
  await assert.rejects(run('admin',fixQ,[id,'250 ML PET','{"fb":"3"}',null,'x']),/number/);
  await assert.rejects(run('admin',fixQ,[id,'250 ML PET','{"fb":-1}',null,'x']),/number/);
  await assert.rejects(run('admin',fixQ,[id,'250 ML PET','{"name":1}',null,'x']),/Unknown field/);
  await assert.rejects(run('admin',fixQ,[id,'600 ML','{"fb":3}',null,'x']),/not in this ledger entry/);
  await assert.rejects(run('admin',fixQ,[id,'250 ML PET','{"fb":2.8}',null,'x']),/Nothing changed/);
  await assert.rejects(run('admin',fixQ,[999,'250 ML PET','{"fb":3}',null,'x']),/not found/);
  // no direct writes to the log
  await assert.rejects(run('admin',`insert into lwb_rate_history_fixes(history_id,reason) values(1,'x')`),/permission denied/);
});
