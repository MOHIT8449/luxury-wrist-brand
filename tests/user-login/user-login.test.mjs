import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';

// lwb_user_login_setup.sql on a tiny copy of auth.users / identities / user_profiles (no live database).
const ADMIN='00000000-0000-4000-8000-000000000001';
const db=new PGlite({extensions:{pgcrypto}});
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE SCHEMA extensions;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE auth.users(instance_id uuid,id uuid primary key,aud text,role text,email text,encrypted_password text,email_confirmed_at timestamptz,
  raw_app_meta_data jsonb,raw_user_meta_data jsonb,created_at timestamptz,updated_at timestamptz,last_sign_in_at timestamptz,
  confirmation_token text,recovery_token text,email_change_token_new text,email_change text);
CREATE UNIQUE INDEX ON auth.users(email);
CREATE TABLE auth.identities(id uuid primary key,provider_id text,user_id uuid,identity_data jsonb,provider text,last_sign_in_at timestamptz,created_at timestamptz,updated_at timestamptz);
CREATE TABLE public.user_profiles(id uuid primary key,full_name text,role text,active boolean,mobile text);
INSERT INTO auth.users(id,email) VALUES ('${ADMIN}','owner@example.com');
INSERT INTO public.user_profiles VALUES ('${ADMIN}','Owner','admin',true,null);
`);
const setup=await readFile(new URL('../../lwb_user_login_setup.sql',import.meta.url),'utf8');
await db.exec(setup);
await db.exec(setup); // safe to run again
await db.exec(`SELECT set_config('request.jwt.claim.sub','${ADMIN}',false)`);

const one=async(sql,p=[])=>(await db.query(sql,p)).rows[0];
const create=(name,mob,email)=>one('select public.lwb_admin_create_user($1,$2,$3,$4,$5) id',[name,mob,email,'secret1','sales']).then(r=>r.id);
const authEmail=id=>one('select u.email, i.identity_data->>\'email\' ie from auth.users u join auth.identities i on i.user_id=u.id where u.id=$1',[id]);
const loginEmail=(login,pw='secret1')=>one('select public.lwb_login_email($1,$2) e',[login,pw]).then(r=>r.e);

test('admin changes a user email; mobile login and new email both work',async()=>{
  const id=await create('Harsh','9081470585','harsh@old.com');
  const r=await one('select public.lwb_admin_set_email($1,$2) e',[id,' Harsh@New.com ']);
  assert.equal(r.e,'harsh@new.com');
  assert.deepEqual(await authEmail(id),{email:'harsh@new.com',ie:'harsh@new.com'});
  assert.equal(await loginEmail('9081470585'),'harsh@new.com');
  const u=(await db.query('select * from public.lwb_admin_users() where user_id=$1',[id])).rows[0];
  assert.equal(u.email,'harsh@new.com');
});

test('email already used by another login is refused',async()=>{
  const a=await create('A','9000000001','a@x.com');
  await create('B','9000000002','b@x.com');
  await assert.rejects(db.query('select public.lwb_admin_set_email($1,$2)',[a,'B@x.com']),/already used/);
  await assert.rejects(db.query('select public.lwb_admin_set_email($1,$2)',[a,'not-an-email']),/valid email/);
  await assert.rejects(db.query('select public.lwb_admin_set_email($1,$2)',[a,'m9@staff.lwb-erp.in']),/real email/);
});

test('removing the email falls back to mobile-only login; needs a mobile',async()=>{
  const id=await create('C','9000000003','c@x.com');
  assert.equal((await one('select public.lwb_admin_set_email($1,$2) e',[id,''])).e,null);
  assert.equal((await authEmail(id)).email,'m9000000003@staff.lwb-erp.in');
  assert.equal(await loginEmail('9000000003'),'m9000000003@staff.lwb-erp.in');
  const e=await create('D',null,'d@x.com');
  await assert.rejects(db.query('select public.lwb_admin_set_email($1,$2)',[e,null]),/no mobile/);
});

test('new mobile on a mobile-only login moves its internal email too',async()=>{
  const id=await create('E','9000000005',null);
  await db.query('select public.lwb_admin_set_login($1,$2,$3)',[id,'9000000006',null]);
  assert.deepEqual(await authEmail(id),{email:'m9000000006@staff.lwb-erp.in',ie:'m9000000006@staff.lwb-erp.in'});
  assert.equal(await loginEmail('9000000006'),'m9000000006@staff.lwb-erp.in');
  assert.equal(await loginEmail('9000000005'),null);
  // The old mobile is free again for a new login.
  await create('F','9000000005',null);
});

test('add an email, then remove the mobile (page save order)',async()=>{
  const id=await create('G','9000000007',null);
  await db.query('select public.lwb_admin_set_email($1,$2)',[id,'g@x.com']);
  await db.query('select public.lwb_admin_set_login($1,null,null,true)',[id]);
  assert.equal((await one('select mobile from public.user_profiles where id=$1',[id])).mobile,null);
  assert.equal((await authEmail(id)).email,'g@x.com');
});

test('only an active admin can change emails',async()=>{
  const id=await create('H','9000000008','h@x.com');
  await db.exec(`SELECT set_config('request.jwt.claim.sub','${id}',false)`);
  await assert.rejects(db.query('select public.lwb_admin_set_email($1,$2)',[id,'z@x.com']),/Only an active Admin/);
  await db.exec(`SELECT set_config('request.jwt.claim.sub','${ADMIN}',false)`);
});
