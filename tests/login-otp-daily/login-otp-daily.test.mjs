import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';

// lwb_login_otp_daily_setup.sql: WhatsApp OTP once a day for Admin / Sales Head / Accounts, per phone.
const id=n=>'00000000-0000-4000-8000-00000000000'+n;
const U={admin:id(1),manager:id(2),accounts:id(3),sales:id(4),off:id(5)};
const S=n=>'10000000-0000-4000-8000-00000000000'+n;
const dev='devAAAAAAAAAAAAAAAAAAAAA',dev2='devBBBBBBBBBBBBBBBBBBBBB';
const db=new PGlite({extensions:{pgcrypto}});
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE SCHEMA auth; CREATE SCHEMA extensions; CREATE TABLE auth.users(id uuid primary key);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql AS $$ SELECT coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
`);
for(const [r,u] of Object.entries(U)){await db.query('insert into auth.users values($1)',[u]);
  await db.query('insert into user_profiles values($1,$2,$3)',[u,r==='off'?'admin':' '+r+' ',r!=='off'])}
for(const f of ['lwb_mpin_setup.sql','lwb_whatsapp_otp_setup.sql'])
  await db.exec(await readFile(new URL('../../'+f,import.meta.url),'utf8'));
const as=async(u,sid,claims={})=>{await db.query(`select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claims',$2,false)`,[u,JSON.stringify({session_id:sid,...claims})])};
for(const u of [U.admin,U.sales]){await as(u,S(9));await db.query('select lwb_mpin_set($1,$2)',[dev,'2580'])}
await db.exec(await readFile(new URL('../../lwb_login_otp_daily_setup.sql',import.meta.url),'utf8'));
const one=async(q,a=[])=>(await db.query(q,a)).rows[0].r;
const otpOk=()=>one('select lwb_login_otp_ok() r');
const passOtp=async(u,sid)=>{await db.query('insert into lwb_login_otp_sessions(session_id,user_id) values($1,$2)',[sid,u])};

test('first login of the day needs the OTP, later logins on the same phone do not',async()=>{
  for(const [k,u] of [['admin',U.admin],['manager',U.manager],['accounts',U.accounts]]){
    await as(u,S(1));
    assert.equal(await otpOk(),false,k+' first login');
    assert.equal(await one('select lwb_login_otp_today($1) r',[dev]),false,k+' nothing remembered yet');
    assert.equal(await one('select lwb_login_otp_remember($1) r',[dev]),false,k+' cannot remember without OTP');
    await passOtp(u,S(1));
    assert.equal(await one('select lwb_login_otp_remember($1) r',[dev]),true);
    await as(u,S(2));                       // new password login, same day, same phone
    assert.equal(await otpOk(),false);
    assert.equal(await one('select lwb_login_otp_today($1) r',[dev]),true,k+' same day');
    assert.equal(await otpOk(),true,k+' this login now counts as OTP passed');
    await as(u,S(3));
    assert.equal(await one('select lwb_login_otp_today($1) r',[dev2]),false,k+' other phone needs OTP');
    await db.query('delete from lwb_login_otp_sessions');
  }
});
test('yesterday does not count',async()=>{
  await db.query(`update lwb_login_otp_days set day=day-1`);
  await as(U.admin,S(4));
  assert.equal(await one('select lwb_login_otp_today($1) r',[dev]),false);
});
test('Salesman and inactive Admin: OTP every time',async()=>{
  for(const [i,u] of [[5,U.sales],[8,U.off]]){
    await as(u,S(i));await passOtp(u,S(i));
    assert.equal(await one('select lwb_login_otp_remember($1) r',[dev]),false);
    await as(u,S(6));assert.equal(await one('select lwb_login_otp_today($1) r',[dev]),false);
  }
});
test('Authenticator (aal2) also counts for the day',async()=>{
  await as(U.manager,S(7),{aal:'aal2'});
  assert.equal(await one('select lwb_login_otp_remember($1) r',[dev2]),true);
});
test('Admin MPIN removed, others kept',async()=>{
  assert.deepEqual((await db.query('select user_id::text u from lwb_user_mpin')).rows.map(x=>x.u),[U.sales]);
});
test('tables closed, functions only for logged-in users',async()=>{
  const g=(await db.query(`select has_table_privilege('authenticated','lwb_login_otp_days','select') t,
    has_function_privilege('anon','lwb_login_otp_today(text)','execute') a,
    has_function_privilege('authenticated','lwb_login_otp_today(text)','execute') b`)).rows[0];
  assert.deepEqual(g,{t:false,a:false,b:true});
});
