import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_core_table_write_rules.sql on an empty PGlite database with the live "everyone may do all" rules.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  sm:'00000000-0000-4000-8000-000000000003',wh:'00000000-0000-4000-8000-000000000004',
  tr:'00000000-0000-4000-8000-000000000005',off:'00000000-0000-4000-8000-000000000006'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,status text,created_by uuid);
CREATE TABLE public.order_items(id uuid default gen_random_uuid() primary key,order_id uuid references public.orders(id) on delete cascade,rate numeric);
CREATE TABLE public.sku_master(id serial primary key,sku_name text,rate numeric);
CREATE TABLE public.tax_invoices(id uuid default gen_random_uuid() primary key,order_id uuid);
CREATE TABLE public.dispatch_assignments(id uuid default gen_random_uuid() primary key,order_id uuid,vehicle text);
CREATE TABLE public.order_audit_log(id serial primary key,note text);
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['orders','order_items','sku_master','tax_invoices','dispatch_assignments','order_audit_log'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY open_all ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)',t);
  END LOOP; END $$;
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;
`);
const roles={admin:'admin',head:'manager',sm:'sales',wh:'warehouse',tr:'transport'};
for(const [k,r] of Object.entries(roles))await db.query('insert into user_profiles values($1,$2,true)',[ids[k],r]);
await db.query("insert into user_profiles values($1,'admin',false)",[ids.off]);
await db.exec(await readFile(new URL('../../lwb_core_table_write_rules.sql',import.meta.url),'utf8'));
await db.exec(`insert into sku_master(sku_name,rate) values('A',10);
  insert into orders(id,order_no,status,created_by) values('10000000-0000-4000-8000-000000000001','1','approved',null);
  insert into order_items(order_id,rate) values('10000000-0000-4000-8000-000000000001',10);
  insert into order_audit_log(note) values('x');`);

async function as(who,sql,params=[]){
  await db.exec('BEGIN');
  try{
    await db.query("select set_config('request.jwt.claim.sub',$1,true)",[ids[who]]);
    await db.exec('SET LOCAL ROLE authenticated');
    const r=await db.query(sql,params);await db.exec('COMMIT');return {ok:true,rows:r.affectedRows??r.rows.length};
  }catch(e){await db.exec('ROLLBACK');return {ok:false,error:e.message};}
}
const changed=r=>r.ok&&r.rows>0;

test('salesman cannot change SKU rate, Sales Head can',async()=>{
  assert.equal(changed(await as('sm','update sku_master set rate=1')),false);
  assert.equal((await as('sm',"insert into sku_master(sku_name) values('B')")).ok,false);
  assert.equal(changed(await as('head','update sku_master set rate=11')),true);
});
test('salesman places a PO but cannot edit or delete approved POs',async()=>{
  assert.equal((await as('sm',"insert into orders(order_no,status,created_by) values('2','pending_approval',$1)",[ids.sm])).ok,true);
  assert.equal(changed(await as('sm',"update orders set status='delivered'")),false);
  assert.equal(changed(await as('sm',"delete from orders where order_no='1'")),false);
  assert.equal(changed(await as('sm','update order_items set rate=1')),false);
});
test('salesman can remove his own pending PO (New PO page rollback)',async()=>{
  assert.equal(changed(await as('sm',"delete from orders where order_no='2'")),true);
});
test('warehouse updates POs and lines, cannot delete a PO',async()=>{
  assert.equal(changed(await as('wh',"update orders set status='loaded' where order_no='1'")),true);
  assert.equal(changed(await as('wh','update order_items set rate=12')),true);
  assert.equal(changed(await as('wh',"delete from orders where order_no='1'")),false);
});
test('transport assigns vehicles only',async()=>{
  assert.equal((await as('tr',"insert into dispatch_assignments(vehicle) values('GJ1')")).ok,true);
  assert.equal(changed(await as('tr',"update orders set status='x'")),false);
  assert.equal(changed(await as('tr','delete from dispatch_assignments')),false);
});
test('audit log cannot be edited or deleted, even by Admin',async()=>{
  assert.equal(changed(await as('admin',"update order_audit_log set note='y'")),false);
  assert.equal(changed(await as('admin','delete from order_audit_log')),false);
  assert.equal((await as('sm',"insert into order_audit_log(note) values('z')")).ok,true);
});
test('inactive admin login gets nothing; active admin deletes',async()=>{
  assert.equal(changed(await as('off','update sku_master set rate=0')),false);
  assert.equal(changed(await as('admin',"delete from orders where order_no='1'")),true);
});
test('file can run again',async()=>{
  await db.exec(await readFile(new URL('../../lwb_core_table_write_rules.sql',import.meta.url),'utf8'));
});
