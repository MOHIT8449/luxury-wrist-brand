import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_change_history_setup.sql on an empty PGlite database (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',sm:'00000000-0000-4000-8000-000000000002'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.sku_master(id serial primary key,sku_name text,rate numeric,updated_at timestamptz);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text,note text);
CREATE TABLE public.lwb_location_history(id serial primary key,lat numeric);
CREATE TABLE public.erp_notifications(id serial primary key,user_id uuid,title text);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.sku_master, public.orders TO authenticated;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;
`);
await db.query("insert into user_profiles values($1,'admin',true,'Mohit'),($2,'sales',true,'Harsh')",[ids.admin,ids.sm]);
const sql=await readFile(new URL('../../lwb_change_history_setup.sql',import.meta.url),'utf8');
await db.exec(sql);

async function as(who,q,params=[]){
  await db.exec('BEGIN');
  try{
    await db.query("select set_config('request.jwt.claim.sub',$1,true)",[ids[who]||'']);
    await db.exec('SET LOCAL ROLE authenticated');
    const r=await db.query(q,params);await db.exec('COMMIT');return {ok:true,rows:r.rows};
  }catch(e){await db.exec('ROLLBACK');return {ok:false,error:e.message};}
}
const list=async(who,args={})=>as(who,"select public.lwb_change_log_list(null,null,$1,$2,$3,$4) j",[args.user||null,args.table||null,args.action||null,args.q||null]);

test('add, edit and delete by a salesman are logged with his name',async()=>{
  await as('sm',"insert into sku_master(sku_name,rate) values('RG 10',100)");
  await as('sm',"update sku_master set rate=120, updated_at=now() where sku_name='RG 10'");
  await as('sm',"update sku_master set updated_at=now()");          // only updated_at: not logged
  await as('sm',"insert into orders(order_no,customer_name,status) values('PO-7','Shree Traders','pending')");
  await as('sm',"delete from orders where order_no='PO-7'");
  const r=await list('admin',{user:ids.sm});
  assert.equal(r.ok,true,r.error);
  const j=r.rows[0].j;
  assert.equal(j.total,4);
  const [del,addPo,edit,add]=j.rows;
  assert.equal(del.action,'DELETE');assert.equal(del.row_label,'PO-7');assert.equal(del.changes.customer_name,'Shree Traders');
  assert.equal(addPo.action,'INSERT');
  assert.equal(edit.action,'UPDATE');assert.deepEqual(edit.changes,{rate:[100,120]});
  assert.equal(add.user_name,'Harsh');assert.equal(add.user_role,'sales');assert.equal(add.row_label,'RG 10');
});
test('filters by module, action and search',async()=>{
  assert.equal((await list('admin',{table:'orders'})).rows[0].j.total,2);
  assert.equal((await list('admin',{action:'delete'})).rows[0].j.total,1);
  assert.equal((await list('admin',{q:'shree'})).rows[0].j.total,2);
});
test('only Admin can read; nobody can touch the log table',async()=>{
  assert.equal((await list('sm')).ok,false);
  assert.equal((await as('sm','select * from lwb_change_log')).ok,false);
  assert.equal((await as('admin','delete from lwb_change_log')).ok,false);
  assert.equal((await as('admin','update lwb_change_log set user_id=null')).ok,false);
  assert.equal((await as('admin','select public.lwb_change_log_attach()')).ok,false);
});
test('tracking tables are skipped; meta lists logged modules',async()=>{
  const m=(await as('admin','select public.lwb_change_log_meta() j')).rows[0].j;
  assert.deepEqual(m.tables.sort(),['orders','sku_master','user_profiles']);
  assert.equal(m.users.length,2);
});
test('long text is shortened',async()=>{
  await as('sm',"insert into orders(order_no,note) values('PO-8',repeat('x',9000))");
  const row=(await list('admin',{q:'PO-8'})).rows[0].j.rows[0];
  assert.ok(row.changes.note.length<500);
});
test('a failing log never blocks the save',async()=>{
  await db.exec('ALTER TABLE public.lwb_change_log ADD CONSTRAINT t_block CHECK (table_name <> \'orders\') NOT VALID');
  const r=await as('sm',"insert into orders(order_no) values('PO-9')");
  assert.equal(r.ok,true,r.error);
  await db.exec('ALTER TABLE public.lwb_change_log DROP CONSTRAINT t_block');
});
test('new tables get the trigger on attach; file runs again',async()=>{
  await db.exec('CREATE TABLE public.lwb_new_module(id serial primary key,name text)');
  assert.equal((await db.query('select public.lwb_change_log_attach() n')).rows[0].n,1);
  await db.exec(sql);
});
