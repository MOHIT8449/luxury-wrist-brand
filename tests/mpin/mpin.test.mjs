import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';

// lwb_mpin_setup.sql on a tiny database (no live Supabase).
const ids={admin:'00000000-0000-4000-8000-000000000001',sales:'00000000-0000-4000-8000-000000000002',off:'00000000-0000-4000-8000-000000000003'};
const dev='devAAAAAAAAAAAAAAAAAAAAA',dev2='devBBBBBBBBBBBBBBBBBBBBB';
const db=new PGlite({extensions:{pgcrypto}});
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE SCHEMA extensions;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
`);
await db.query("insert into user_profiles values($1,'admin',true),($2,'sales',true),($3,'sales',false)",[ids.admin,ids.sales,ids.off]);
const sql=await readFile(new URL('../../lwb_mpin_setup.sql',import.meta.url),'utf8');
await db.exec(sql);
await db.exec(sql); // safe to run again
const as=async(who,q,p=[])=>{await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[who?ids[who]:'']);return db.query(q,p)};
const one=async(who,q,p)=>Object.values((await as(who,q,p)).rows[0])[0];
const err=async(who,q,p)=>{try{await as(who,q,p)}catch(e){return e.message}return null};

test('set needs a login, an active user, 4 digits and not an easy MPIN',async()=>{
  assert.match(await err(null,'select lwb_mpin_set($1,$2)',[dev,'2580']),/Login first/);
  assert.match(await err('off','select lwb_mpin_set($1,$2)',[dev,'2580']),/not active/);
  assert.match(await err('sales','select lwb_mpin_set($1,$2)',[dev,'25801']),/4 digits/);
  assert.match(await err('sales','select lwb_mpin_set($1,$2)',['bad id','2580']),/Phone/);
  for(const p of ['1111','1234','4321','0123','6789','9876'])
    assert.match(await err('sales','select lwb_mpin_set($1,$2)',[dev,p]),/too easy/,p);
  assert.equal(await one('sales','select lwb_mpin_set($1,$2)',[dev,'2580']),true);
  assert.equal(await one('sales','select lwb_mpin_status($1)',[dev]),true);
  assert.equal(await one('sales','select lwb_mpin_status($1)',[dev2]),false);
  const h=(await db.query('select pin_hash from lwb_user_mpin')).rows[0].pin_hash;
  assert.ok(h.startsWith('$2a$')&&!h.includes('2580'),'kept only as a bcrypt hash');
});

test('right MPIN opens; wrong one counts down; 5 wrong removes it',async()=>{
  await as('sales','select lwb_mpin_set($1,$2)',[dev,'2580']);
  assert.deepEqual(await one('sales','select lwb_mpin_verify($1,$2)',[dev,'2580']),{ok:true});
  assert.deepEqual(await one('admin','select lwb_mpin_verify($1,$2)',[dev,'2580']),{ok:false,blocked:true},'another user cannot use it');
  for(let left=4;left>=1;left--)assert.deepEqual(await one('sales','select lwb_mpin_verify($1,$2)',[dev,'0000']),{ok:false,left});
  assert.deepEqual(await one('sales','select lwb_mpin_verify($1,$2)',[dev,'2580']),{ok:true},'a right MPIN clears the count');
  for(let i=0;i<4;i++)await as('sales','select lwb_mpin_verify($1,$2)',[dev,'9999']);
  assert.deepEqual(await one('sales','select lwb_mpin_verify($1,$2)',[dev,'9999']),{ok:false,blocked:true});
  assert.equal(await one('sales','select lwb_mpin_status($1)',[dev]),false);
  assert.deepEqual(await one('sales','select lwb_mpin_verify($1,$2)',[dev,'2580']),{ok:false,blocked:true});
});

test('Admin sees and resets; others cannot; table is closed',async()=>{
  await as('sales','select lwb_mpin_set($1,$2)',[dev,'2580']);
  await as('sales','select lwb_mpin_set($1,$2)',[dev2,'2580']);
  assert.match(await err('sales','select * from lwb_admin_mpin_users()'),/Only Admin/);
  assert.match(await err('sales','select lwb_admin_reset_mpin($1)',[ids.sales]),/Only Admin/);
  assert.deepEqual((await as('admin','select * from lwb_admin_mpin_users()')).rows.map(r=>Object.values(r)[0]),[ids.sales]);
  assert.equal(await one('admin','select lwb_admin_reset_mpin($1)',[ids.sales]),2);
  assert.equal(await one('sales','select lwb_mpin_status($1)',[dev]),false);
  const g=(await db.query("select has_table_privilege('authenticated','lwb_user_mpin','select') s, has_function_privilege('anon','lwb_mpin_verify(text,text)','execute') a")).rows[0];
  assert.deepEqual(g,{s:false,a:false});
});

test('remove clears only this phone; at most 5 phones',async()=>{
  for(let i=0;i<6;i++)await as('sales','select lwb_mpin_set($1,$2)',['phone'+String(i).padStart(12,'0'),'2580']);
  assert.equal(await one('sales','select count(*)::int from lwb_user_mpin where user_id=$1',[ids.sales]),5);
  await as('sales','select lwb_mpin_remove($1)',['phone000000000005']);
  assert.equal(await one('sales','select lwb_mpin_status($1)',['phone000000000005']),false);
  assert.equal(await one('sales','select lwb_mpin_status($1)',['phone000000000004']),true);
});
