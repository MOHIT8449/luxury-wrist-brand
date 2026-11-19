import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';

// lwb_mpin_login_setup.sql: MPIN check for the lwb-mpin-login Edge Function (no live Supabase).
const ids={sales:'00000000-0000-4000-8000-000000000002',off:'00000000-0000-4000-8000-000000000003'};
const dev='devAAAAAAAAAAAAAAAAAAAAA',dev2='devBBBBBBBBBBBBBBBBBBBBB';
const db=new PGlite({extensions:{pgcrypto}});
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE SCHEMA auth; CREATE SCHEMA extensions;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
`);
await db.query("insert into user_profiles values($1,'sales',true),($2,'sales',false)",[ids.sales,ids.off]);
for(const f of ['lwb_mpin_setup.sql','lwb_mpin_login_setup.sql','lwb_mpin_login_setup.sql'])
  await db.exec(await readFile(new URL('../../'+f,import.meta.url),'utf8'));
await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[ids.sales]);
await db.query('select lwb_mpin_set($1,$2)',[dev,'2580']);
const check=async(u,d,p)=>(await db.query('select lwb_mpin_login_check($1,$2,$3) r',[u,d,p])).rows[0].r;

test('right MPIN on the right phone only',async()=>{
  assert.deepEqual(await check(ids.sales,dev,'2580'),{ok:true});
  assert.deepEqual(await check(ids.sales,dev2,'2580'),{ok:false,blocked:true},'other phone');
  assert.deepEqual(await check(ids.off,dev,'2580'),{ok:false,inactive:true},'inactive login');
  assert.deepEqual(await check(ids.sales,'bad',  '2580'),{ok:false,blocked:true});
});

test('5 wrong tries remove the MPIN',async()=>{
  for(let left=4;left>=1;left--)assert.deepEqual(await check(ids.sales,dev,'0000'),{ok:false,left});
  assert.deepEqual(await check(ids.sales,dev,'0000'),{ok:false,blocked:true});
  assert.deepEqual(await check(ids.sales,dev,'2580'),{ok:false,blocked:true});
});

test('only the server key may call it',async()=>{
  const g=(await db.query(`select has_function_privilege('anon','lwb_mpin_login_check(uuid,text,text)','execute') a,
    has_function_privilege('authenticated','lwb_mpin_login_check(uuid,text,text)','execute') b,
    has_function_privilege('service_role','lwb_mpin_login_check(uuid,text,text)','execute') c`)).rows[0];
  assert.deepEqual(g,{a:false,b:false,c:true});
});
