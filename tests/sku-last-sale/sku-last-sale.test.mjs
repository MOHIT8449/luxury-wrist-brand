import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_sku_last_sale_setup.sql on PGlite with stand-in tables (no live data).
const ADMIN='00000000-0000-4000-8000-000000000001',SALES='00000000-0000-4000-8000-000000000002',OFF='00000000-0000-4000-8000-000000000003';
const sql=await readFile(new URL('../../lwb_sku_last_sale_setup.sql',import.meta.url),'utf8');
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
CREATE TABLE public.orders(id uuid primary key,order_no text,status text,order_date timestamptz,created_at timestamptz default now());
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric);
INSERT INTO user_profiles VALUES ('${ADMIN}','admin',true),('${SALES}','sales',true),('${OFF}','warehouse',false);
INSERT INTO orders(id,order_no,status,order_date) VALUES
 ('a0000000-0000-4000-8000-000000000001','PO-1','approved',now()),
 ('a0000000-0000-4000-8000-000000000002','PO-2','delivered',now()-interval '45 days'),
 ('a0000000-0000-4000-8000-000000000003','PO-3','cancelled',now()),
 ('a0000000-0000-4000-8000-000000000004','PO-4','delivered',now()-interval '200 days');
INSERT INTO order_items(order_id,sku_name,ordered_qty,approved_qty,loaded_qty) VALUES
 ('a0000000-0000-4000-8000-000000000001','250ML LIMCA MRP 20',10,null,null),
 ('a0000000-0000-4000-8000-000000000002',' 500ml kinley mrp 10 ',20,20,18),
 ('a0000000-0000-4000-8000-000000000001','500ML KINLEY MRP 10',5,4,null),
 ('a0000000-0000-4000-8000-000000000003','250ML SPRITE MRP 20',99,null,null),
 ('a0000000-0000-4000-8000-000000000004','250ML MAAZA MRP 20',50,50,50);
GRANT USAGE ON SCHEMA public, auth TO authenticated;`);
await db.exec(sql);await db.exec(sql); // safe to run again
async function last(who){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[who]);
  const r=await db.query('select sku_key,(current_date-last_date) ago,qty_30,qty_90 from lwb_sku_last_sale() order by sku_key');
  return r.rows.map(x=>[x.sku_key,Number(x.ago),Number(x.qty_30),Number(x.qty_90)]);
}
test('last sale date and 30 / 90 day qty; cancelled POs left out',async()=>{
  const r=await last(ADMIN);
  assert.deepEqual(r.map(x=>x[0]),['250ML LIMCA MRP 20','250ML MAAZA MRP 20','500ML KINLEY MRP 10']);
  const k=r.find(x=>x[0]==='500ML KINLEY MRP 10');assert.ok(k[1]<=1);assert.equal(k[2],4);assert.equal(k[3],22);
  const m=r.find(x=>x[0]==='250ML MAAZA MRP 20');assert.ok(m[1]>=199);assert.equal(m[2],0);assert.equal(m[3],0);
});
test('salesman, inactive and no login get nothing',async()=>{
  assert.deepEqual(await last(SALES),[]);assert.deepEqual(await last(OFF),[]);assert.deepEqual(await last(''),[]);
});
