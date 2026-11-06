import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_transport_master_setup.sql on an empty PGlite database (run twice: safe to run again).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',godown:'00000000-0000-4000-8000-000000000003',acc:'00000000-0000-4000-8000-000000000004'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
GRANT USAGE ON SCHEMA public, auth TO authenticated; GRANT SELECT ON public.user_profiles TO authenticated;
INSERT INTO user_profiles VALUES('${ids.admin}','admin',true,'A'),('${ids.head}','manager',true,'H'),('${ids.godown}','warehouse',true,'G'),('${ids.acc}','accounts',true,'C');`);
const sql=await readFile(new URL('../../lwb_transport_master_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql);
async function as(who,q,p=[]){
  await db.exec(`SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub','${ids[who]}',false);`);
  try{return await db.query(q,p)}finally{await db.exec('RESET ROLE')}
}
test('admin and sales head add, name is cleaned, duplicate refused',async()=>{
  await as('admin',`INSERT INTO lwb_transport_master(transport_name) VALUES('  shree   ram roadlines ')`);
  await as('head',`INSERT INTO lwb_transport_master(transport_name) VALUES('VRL LOGISTICS')`);
  await assert.rejects(as('head',`INSERT INTO lwb_transport_master(transport_name) VALUES('SHREE RAM ROADLINES')`),/duplicate|unique/i);
  const r=await as('godown',`SELECT transport_name,is_active FROM lwb_transport_master ORDER BY 1`);
  assert.deepEqual(r.rows.map(x=>x.transport_name),['VRL LOGISTICS','shree ram roadlines']);
});
test('accounts reads but cannot add',async()=>{
  await assert.rejects(as('acc',`INSERT INTO lwb_transport_master(transport_name) VALUES('ABC')`),/row-level security/i);
});
test('too short name refused',async()=>{
  await assert.rejects(as('admin',`INSERT INTO lwb_transport_master(transport_name) VALUES(' x ')`),/2 to 150/);
});

// lwb_goods_inward_godown_setup.sql widens the first role check of a stand-in lwb_post_goods_inward.
test('godown setup: warehouse may post, other role lists untouched, safe to run again',async()=>{
  const g=new PGlite();
  await g.exec(`CREATE SCHEMA auth; CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
  CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
  INSERT INTO user_profiles VALUES('${ids.godown}','warehouse',true),('${ids.acc}','accounts',true);
  CREATE FUNCTION public.lwb_post_goods_inward(p_invoice_no text) RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $f$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active AND lower(p.role) IN ('admin','manager')) THEN
      RAISE EXCEPTION 'Only active Admin or Manager can post Goods Inward'; END IF;
    RETURN (SELECT string_agg(role,',') FROM public.user_profiles WHERE role IN ('admin','manager'));
  END $f$;`);
  const sql=await readFile(new URL('../../lwb_goods_inward_godown_setup.sql',import.meta.url),'utf8');
  await g.exec(sql);await g.exec(sql);
  const def=(await g.query(`SELECT pg_get_functiondef('public.lwb_post_goods_inward(text)'::regprocedure) d`)).rows[0].d;
  assert.equal((def.match(/'warehouse'/g)||[]).length,1);
  await g.exec(`SELECT set_config('request.jwt.claim.sub','${ids.godown}',false)`);
  assert.equal((await g.query(`SELECT public.lwb_post_goods_inward('X') r`)).rows[0].r,null);
  await g.exec(`SELECT set_config('request.jwt.claim.sub','${ids.acc}',false)`);
  await assert.rejects(g.query(`SELECT public.lwb_post_goods_inward('X')`),/Sales Head or Godown Manager/);
  const res=(await g.query(sql.slice(sql.lastIndexOf('SELECT p.proname')))).rows;
  assert.deepEqual(res.map(r=>r.godown_manager_can_post),['yes']);
});
