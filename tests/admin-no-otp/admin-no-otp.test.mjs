import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';

// lwb_admin_login_no_otp_setup.sql: Admin opens the ERP without OTP; every other role still needs it.
const ids={admin:'00000000-0000-4000-8000-000000000001',sales:'00000000-0000-4000-8000-000000000002',off:'00000000-0000-4000-8000-000000000003'};
const db=new PGlite({extensions:{pgcrypto}});
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE SCHEMA auth; CREATE SCHEMA extensions; CREATE TABLE auth.users(id uuid primary key);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
`);
await db.query("insert into auth.users values($1),($2),($3)",[ids.admin,ids.sales,ids.off]);
await db.query("insert into user_profiles values($1,' Admin ',true),($2,'sales',true),($3,'admin',false)",[ids.admin,ids.sales,ids.off]);
for(const f of ['lwb_mpin_setup.sql','lwb_whatsapp_otp_setup.sql'])
  await db.exec(await readFile(new URL('../../'+f,import.meta.url),'utf8'));
const as=async(u,claims={})=>{await db.query(`select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claims',$2,false)`,[u,JSON.stringify(claims)])};
for(const u of [ids.admin,ids.sales]){await as(u);await db.query('select lwb_mpin_set($1,$2)',['devAAAAAAAAAAAAAAAAAAAAA','2580'])}
await db.exec(await readFile(new URL('../../lwb_admin_login_no_otp_setup.sql',import.meta.url),'utf8'));
const ok=async(u,claims)=>{await as(u,claims);return (await db.query('select lwb_login_otp_ok() r')).rows[0].r};

test('Admin needs no OTP',async()=>{assert.equal(await ok(ids.admin),true)});
test('other roles and inactive Admin still need the OTP',async()=>{
  assert.equal(await ok(ids.sales),false);
  assert.equal(await ok(ids.off),false);
  assert.equal(await ok(ids.sales,{aal:'aal2'}),true,'Authenticator still works');
});
test('Admin MPIN removed, others kept',async()=>{
  const r=(await db.query('select user_id::text u from lwb_user_mpin order by 1')).rows.map(x=>x.u);
  assert.deepEqual(r,[ids.sales]);
});
