import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_rate_ledger_setup.sql on an empty PGlite database (no live data), storage schema stubbed.
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
await db.exec(sql);await db.exec(sql); // safe to run again
async function run(who,q,p){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);await db.exec('SET ROLE authenticated');try{return await db.query(q,p)}finally{await db.exec('RESET ROLE')}}
const save=(who,note)=>run(who,`select public.lwb_save_rates('{}'::jsonb,'[]'::jsonb,$1,'[{"name":"250ML CSD","fb":2.5}]'::jsonb)`,[note]);

test('valid from + circular go on the entry this login just saved', async()=>{
  await save('head','Scheme 6 Nov: free bottle 2.5');
  const id=(await run('head',`select public.lwb_rate_history_meta('2026-11-07',$1) id`,[[ids.head+'/1-circular.pdf']])).rows[0].id;
  const e=(await db.query('select valid_from::text v,files,created_by from lwb_rate_history where id=$1',[id])).rows[0];
  assert.deepEqual(e,{v:'2026-11-07',files:[ids.head+'/1-circular.pdf'],created_by:ids.head});
  // a second call adds files, keeps the date when none is given
  await run('head',`select public.lwb_rate_history_meta(null,$1)`,[[ids.head+'/2-photo.jpg']]);
  assert.equal((await db.query('select array_length(files,1) n,valid_from::text v from lwb_rate_history where id=$1',[id])).rows[0].n,2);
});

test('only own files, only own recent entry, only Admin / Sales Head', async()=>{
  await assert.rejects(run('head',`select public.lwb_rate_history_meta(null,$1)`,[[ids.admin+'/x.pdf']]),/not yours/);
  await assert.rejects(run('admin',`select public.lwb_rate_history_meta('2026-11-01','{}')`),/No ledger entry saved by you/);
  await db.query(`update lwb_rate_history set created_at=now()-interval '1 hour'`);
  await assert.rejects(run('head',`select public.lwb_rate_history_meta('2026-11-01','{}')`),/No ledger entry saved by you/);
  await assert.rejects(run('sales',`select public.lwb_rate_history_meta('2026-11-01','{}')`),/Only Admin or Sales Head/);
});

test('names of who saved: Admin / Sales Head only', async()=>{
  assert.deepEqual((await run('admin','select public.lwb_rate_history_people() p')).rows[0].p,{[ids.head]:'HEAD'});
  assert.deepEqual((await run('sales','select public.lwb_rate_history_people() p')).rows[0].p,{});
  assert.equal((await db.query(`select public from storage.buckets where id='lwb-rate-circulars'`)).rows[0].public,false);
});
