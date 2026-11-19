import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_maintenance_mode_setup.sql on an empty PGlite database shaped like Supabase.
const ids={admin:'00000000-0000-4000-8000-000000000001',sm:'00000000-0000-4000-8000-000000000003',
  drv:'00000000-0000-4000-8000-000000000004'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role; CREATE ROLE authenticator;
CREATE SCHEMA auth; CREATE SCHEMA storage;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,full_name text,role text,active boolean);
CREATE FUNCTION public.lwb_is_admin() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active AND lower(btrim(p.role))='admin') $$;
GRANT EXECUTE ON FUNCTION public.lwb_is_admin() TO authenticated;
CREATE TABLE public.parties(id serial primary key,name text);
CREATE TABLE public.erp_notifications(id serial primary key,user_id uuid,title text);
CREATE TABLE storage.objects(id serial primary key,bucket_id text,name text);
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['public.parties','public.erp_notifications','storage.objects','public.user_profiles'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY open_all ON %s FOR ALL TO authenticated USING (true) WITH CHECK (true)',t);
  END LOOP; END $$;
CREATE PUBLICATION supabase_realtime FOR TABLE public.erp_notifications;
GRANT USAGE ON SCHEMA public, auth, storage TO anon, authenticated, service_role;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public, storage TO authenticated;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public, storage TO authenticated;
INSERT INTO public.user_profiles VALUES
  ('${ids.admin}','Mohit','admin',true),('${ids.sm}','Ravi','sales',true),('${ids.drv}','Raju','driver',true);
INSERT INTO public.parties(name) VALUES ('A'),('B');
INSERT INTO public.erp_notifications(user_id,title) VALUES ('${ids.sm}','x');
INSERT INTO storage.objects(bucket_id,name) VALUES ('b','f.jpg');
`);
const sql=(await readFile(new URL('../../lwb_maintenance_mode_setup.sql',import.meta.url),'utf8'))
  .replace(/^NOTIFY .*$/gm,'');
await db.exec(sql);
await db.exec(sql); // safe to run again

// One API request: claims + path set, role switched, pre-request hook, then the statement (like PostgREST).
async function as(who,stmt,path='/parties',params=[]){
  await db.exec('BEGIN');
  try{
    const method=/^\s*select/i.test(stmt)&&!path.startsWith('/rpc/')?'GET':'POST';
    await db.query("select set_config('request.jwt.claim.sub',$1,true), set_config('request.path',$2,true), set_config('request.method',$3,true)",[who in ids?ids[who]:'',path,method]);
    await db.exec('SET LOCAL ROLE '+(who==='anon'?'anon':who==='service'?'service_role':'authenticated'));
    await db.query('select public.lwb_maintenance_gate()');
    const r=await db.query(stmt,params);await db.exec('COMMIT');return {ok:true,rows:r.rows,n:r.rows.length||r.affectedRows||0};
  }catch(e){await db.exec('ROLLBACK');return {ok:false,error:e.message,code:e.code};}
}
const setOn=(on,msg)=>as('admin','select public.lwb_set_maintenance($1,$2) s','/rpc/lwb_set_maintenance',[on,msg]);

test('OFF: everyone works as before',async()=>{
  assert.equal((await as('sm','select * from parties')).n,2);
  assert.equal((await as('drv','select * from erp_notifications')).n,1);
  const s=await as('sm','select public.lwb_maintenance_status() s','/rpc/lwb_maintenance_status');
  assert.equal(s.rows[0].s.on,false);assert.equal(s.rows[0].s.admin,false);
});

test('only Admin can switch',async()=>{
  const r=await as('sm','select public.lwb_set_maintenance(true,null)','/rpc/lwb_set_maintenance');
  assert.equal(r.ok,false);assert.match(r.error,/Only Admin/);
  assert.equal((await as('anon','select public.lwb_set_maintenance(true,null)','/rpc/lwb_set_maintenance')).ok,false);
});

test('ON: non-Admin sees nothing, changes nothing; Admin keeps full access',async()=>{
  const on=await setOn(true,'Rate update till 4 PM');
  assert.equal(on.ok,true);assert.equal(on.rows[0].s.on,true);assert.equal(on.rows[0].s.changed_by,'Mohit');
  for(const who of ['sm','drv']){
    for(const [stmt,path] of [['select * from parties','/parties'],["insert into parties(name) values('Z')",'/parties'],
      ["update parties set name='Q'",'/parties'],['delete from parties','/parties'],['select 1','/rpc/lwb_any_rpc']]){
      const r=await as(who,stmt,path);
      assert.equal(r.ok,false,who+' '+stmt);assert.equal(r.code,'PT423');assert.match(r.error,/maintenance/);
    }
    // own profile only (so pages open and show the maintenance screen), never the team list
    const pr=await as(who,'select id from user_profiles','/user_profiles');
    assert.equal(pr.ok,true);assert.deepEqual(pr.rows.map(r=>r.id),[ids[who]]);
    assert.equal((await as(who,"update user_profiles set full_name='X'",'/user_profiles')).code,'PT423');
    // the status call is allowed, so the page can show the maintenance screen
    const s=await as(who,'select public.lwb_maintenance_status() s','/rpc/lwb_maintenance_status');
    assert.equal(s.ok,true);assert.equal(s.rows[0].s.on,true);assert.equal(s.rows[0].s.message,'Rate update till 4 PM');
    assert.equal(s.rows[0].s.changed_by,null);
  }
  assert.equal((await as('admin','select * from parties')).n,2);
  assert.equal((await as('admin','select * from user_profiles','/user_profiles')).n,3);
  assert.equal((await as('admin',"insert into parties(name) values('C')")).ok,true);
  // anon (login screens) and service_role (Edge Functions) pass the gate
  assert.equal((await as('anon','select public.lwb_maintenance_status() s','/rpc/lwb_maintenance_status')).rows[0].s.on,true);
  assert.equal((await as('service','select 1 x','/rpc/lwb_login_email')).ok,true);
});

test('ON: realtime + storage rules hide rows from non-Admin even without the gate',async()=>{
  const raw=async(who,stmt)=>{await db.exec('BEGIN');try{
    await db.query("select set_config('request.jwt.claim.sub',$1,true)",[ids[who]]);await db.exec('SET LOCAL ROLE authenticated');
    const r=await db.query(stmt);await db.exec('COMMIT');return r.rows.length}catch(e){await db.exec('ROLLBACK');return 'err:'+e.message}};
  assert.equal(await raw('sm','select * from erp_notifications'),0);
  assert.equal(await raw('sm','select * from storage.objects'),0);
  assert.equal(await raw('admin','select * from erp_notifications'),1);
  assert.equal(await raw('admin','select * from storage.objects'),1);
});

test('OFF again: everything opens, log kept',async()=>{
  assert.equal((await setOn(false,null)).ok,true);
  assert.equal((await as('sm','select * from parties')).n,3);
  assert.equal((await as('sm',"insert into parties(name) values('D')")).ok,true);
  const s=await as('sm','select public.lwb_maintenance_status() s','/rpc/lwb_maintenance_status');
  assert.equal(s.rows[0].s.on,false);assert.equal(s.rows[0].s.message,null);
  const log=await db.query('select is_on from lwb_maintenance_log order by id');
  assert.deepEqual(log.rows.map(r=>r.is_on),[true,false]);
});

test('pre-request hook is set on authenticator',async()=>{
  const r=await db.query("select cfg from pg_db_role_setting s, unnest(s.setconfig) cfg where s.setrole='authenticator'::regrole");
  assert.ok(r.rows.some(x=>x.cfg==='pgrst.db_pre_request=public.lwb_maintenance_gate'));
});
