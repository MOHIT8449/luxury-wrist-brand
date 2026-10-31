import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';

// lwb_password_reset_setup.sql on a tiny copy of auth.users / user_profiles (no live database).
const U='00000000-0000-4000-8000-000000000001',OFF='00000000-0000-4000-8000-000000000002';
const db=new PGlite({extensions:{pgcrypto}});
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE SCHEMA extensions;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
CREATE TABLE auth.users(id uuid primary key,email text,encrypted_password text,updated_at timestamptz);
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
INSERT INTO auth.users VALUES ('${U}','a@x.com','old',null),('${OFF}','b@x.com','old',null);
INSERT INTO public.user_profiles VALUES ('${U}','sales',true),('${OFF}','sales',false);
`);
const setup=await readFile(new URL('../../lwb_password_reset_setup.sql',import.meta.url),'utf8');
await db.exec(setup);await db.exec(setup); // safe to run again

const now=()=>Math.floor(Date.now()/1000);
async function as(uid,amr){
  await db.query("select set_config('request.jwt.claim.sub',$1,false), set_config('request.jwt.claims',$2,false)",[uid||'',JSON.stringify({amr})]);
}
const reset=pw=>db.query('select public.lwb_reset_own_password($1) ok',[pw]);
const ok=async(uid,pw)=>(await db.query("select encrypted_password = extensions.crypt($2, encrypted_password) ok from auth.users where id=$1",[uid,pw])).rows[0].ok;

test('fresh email-code session saves the new password (no Authenticator code needed)',async()=>{
  await as(U,[{method:'recovery',timestamp:now()-30}]);
  assert.equal((await reset('newpass1')).rows[0].ok,true);
  assert.equal(await ok(U,'newpass1'),true);
  await as(U,[{method:'otp',timestamp:now()}]);
  await reset('newpass2');assert.equal(await ok(U,'newpass2'),true);
});

test('a normal password or Authenticator session cannot use it',async()=>{
  await as(U,[{method:'password',timestamp:now()}]);
  await assert.rejects(reset('hacked1'),/expired/);
  await as(U,[{method:'totp',timestamp:now()},{method:'password',timestamp:now()}]);
  await assert.rejects(reset('hacked1'),/expired/);
  assert.equal(await ok(U,'hacked1'),false);
});

test('email code older than 15 minutes is refused',async()=>{
  await as(U,[{method:'recovery',timestamp:now()-1000}]);
  await assert.rejects(reset('later12'),/expired/);
});

test('no session, short password and inactive user are refused',async()=>{
  await as(null,[{method:'recovery',timestamp:now()}]);
  await assert.rejects(reset('newpass9'),/Session not found/);
  await as(U,[{method:'recovery',timestamp:now()}]);
  await assert.rejects(reset('123'),/at least 6/);
  await as(OFF,[{method:'recovery',timestamp:now()}]);
  await assert.rejects(reset('newpass9'),/not active/);
  assert.equal(await ok(OFF,'newpass9'),false);
});
