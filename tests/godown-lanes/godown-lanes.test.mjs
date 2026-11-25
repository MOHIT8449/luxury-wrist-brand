import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_godown_lanes_setup.sql on PGlite with stand-in tables (no live data).
const ADMIN='00000000-0000-4000-8000-000000000001',GM='00000000-0000-4000-8000-000000000002',SALES='00000000-0000-4000-8000-000000000003';
const SKU='b0000000-0000-4000-8000-000000000001';
const sql=await readFile(new URL('../../lwb_godown_lanes_setup.sql',import.meta.url),'utf8');
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
INSERT INTO user_profiles VALUES ('${ADMIN}','admin',true),('${GM}','warehouse',true),('${SALES}','sales',true);
GRANT USAGE ON SCHEMA public, auth TO authenticated;`);
await db.exec(sql);await db.exec(sql); // safe to run again
const as=who=>db.query("select set_config('request.jwt.claim.sub',$1,false)",[who]);

test('54 lines seeded with the layout capacity',async()=>{
  const r=await db.query("select zone,count(*)::int n,sum(slots*levels)::int cap from lwb_godown_lanes group by zone order by zone");
  assert.deepEqual(r.rows,[{zone:'A',n:25,cap:500},{zone:'B',n:25,cap:550},{zone:'C',n:2,cap:120},{zone:'D',n:2,cap:56}]);
});
test('Admin sets SKU and levels; rerun keeps it',async()=>{
  await as(ADMIN);
  await db.query("select lwb_godown_lane_set('a07',$1,3,'Sprite 250')",[SKU]);
  await db.exec(sql);
  const r=await db.query("select sku_id,levels,note,updated_by from lwb_godown_lanes where lane_code='A07'");
  assert.equal(r.rows[0].sku_id,SKU);assert.equal(r.rows[0].levels,3);assert.equal(r.rows[0].note,'Sprite 250');assert.equal(r.rows[0].updated_by,ADMIN);
});
test('Godown team and salesman cannot change a line; bad levels refused',async()=>{
  for(const who of [GM,SALES]){await as(who);
    await assert.rejects(db.query("select lwb_godown_lane_set('A01',null,2,null)"),/Only Admin or Sales Head/);}
  await as(ADMIN);
  await assert.rejects(db.query("select lwb_godown_lane_set('A01',null,9,null)"),/Levels must be 1 to 5/);
  await assert.rejects(db.query("select lwb_godown_lane_set('Z99',null,2,null)"),/not found/);
});
test('read: godown roles yes, salesman no',async()=>{
  await db.exec("SET ROLE authenticated");
  await as(GM);assert.equal((await db.query("select count(*)::int n from lwb_godown_lanes")).rows[0].n,54);
  await as(SALES);assert.equal((await db.query("select count(*)::int n from lwb_godown_lanes")).rows[0].n,0);
  await db.exec("RESET ROLE");
});
