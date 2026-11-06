import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_sku_sales_rank_setup.sql on PGlite with stand-in tables (no live data).
const ADMIN='00000000-0000-4000-8000-000000000001',OFF='00000000-0000-4000-8000-000000000002';
const sql=await readFile(new URL('../../lwb_sku_sales_rank_setup.sql',import.meta.url),'utf8');

async function setup(){
  const db=new PGlite();
  await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
CREATE TABLE public.orders(id uuid primary key default gen_random_uuid(),order_no text,status text,order_date date,created_at timestamptz default now());
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric);
INSERT INTO user_profiles VALUES ('${ADMIN}','salesman',true),('${OFF}','salesman',false);
INSERT INTO orders(id,order_no,status,order_date) VALUES
 ('a0000000-0000-4000-8000-000000000001','PO-1','approved',current_date),
 ('a0000000-0000-4000-8000-000000000002','PO-2','delivered',current_date-10),
 ('a0000000-0000-4000-8000-000000000003','PO-3','cancelled',current_date),
 ('a0000000-0000-4000-8000-000000000004','PO-4','delivered',current_date-200);
INSERT INTO order_items(order_id,sku_name,ordered_qty,approved_qty,loaded_qty) VALUES
 ('a0000000-0000-4000-8000-000000000001','250ML LIMCA MRP 20',10,null,null),
 ('a0000000-0000-4000-8000-000000000001','500ML KINLEY MRP 10',5,4,null),
 ('a0000000-0000-4000-8000-000000000002',' 500ml kinley mrp 10 ',20,20,18),
 ('a0000000-0000-4000-8000-000000000003','ZERO 250ML SPRITE MRP 10',99,null,null),
 ('a0000000-0000-4000-8000-000000000004','250ML MAAZA MRP 20',50,50,50);
GRANT USAGE ON SCHEMA public, auth TO authenticated;`);
  await db.exec(sql);await db.exec(sql); // safe to run again
  return db;
}
async function rank(db,who,days=90){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[who]);
  const r=await db.query('select * from lwb_sku_sales_rank($1) order by qty desc',[days]);
  return r.rows.map(x=>[x.sku_key,Number(x.qty),Number(x.po_count)]);
}

test('most sold first; loaded > approved > ordered; cancelled and old POs left out',async()=>{
  const db=await setup();
  assert.deepEqual(await rank(db,ADMIN),[['500ML KINLEY MRP 10',22,2],['250ML LIMCA MRP 20',10,1]]);
  assert.deepEqual((await rank(db,ADMIN,365)).map(x=>x[0]),['250ML MAAZA MRP 20','500ML KINLEY MRP 10','250ML LIMCA MRP 20']);
});

test('inactive or no login gets nothing',async()=>{
  const db=await setup();
  assert.deepEqual(await rank(db,OFF),[]);
  assert.deepEqual(await rank(db,''),[]);
});
