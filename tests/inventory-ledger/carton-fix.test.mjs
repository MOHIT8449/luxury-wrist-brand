import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
// lwb_purchase_carton_fix_setup.sql on stand-in tables: old carton bills saved as IC get the missing IC once.
const sql=await readFile(new URL('../../lwb_purchase_carton_fix_setup.sql',import.meta.url),'utf8');
test('carton bills saved as IC get the missing IC, once; Coca-Cola and SKUs without carton size untouched',async()=>{
  const db=new PGlite();
  await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated;
CREATE TABLE public.lwb_companies(id uuid primary key,name text,pack_unit text);
CREATE TABLE public.sku_master(id uuid primary key,sku_name text,pcs_per_case int,company_id uuid,pack_unit text,cases_per_pallet int);
CREATE TABLE public.lwb_inventory_movements(id bigserial primary key,sku_id uuid not null,sku_name text,movement_type text not null,stock_bucket text,qty_pcs int not null,notes text,created_at timestamptz default now());
INSERT INTO lwb_companies VALUES ('10000000-0000-4000-8000-000000000001','RAJNIGANDHA','BOX'),('10000000-0000-4000-8000-000000000002','COCA-COLA','CASE');
INSERT INTO sku_master VALUES ('20000000-0000-4000-8000-000000000001','2.2GM',96,'10000000-0000-4000-8000-000000000001',null,48),
 ('20000000-0000-4000-8000-000000000002','4.25G',180,'10000000-0000-4000-8000-000000000001',null,null),
 ('20000000-0000-4000-8000-000000000003','THUMS UP',24,'10000000-0000-4000-8000-000000000002',null,100);
INSERT INTO lwb_inventory_movements(sku_id,sku_name,movement_type,stock_bucket,qty_pcs,created_at) VALUES
 ('20000000-0000-4000-8000-000000000001','2.2GM','OPENING','SALEABLE',119808,'2026-11-04'),
 ('20000000-0000-4000-8000-000000000001','2.2GM','PURCHASE_IN','SALEABLE',960,'2026-11-05'),
 ('20000000-0000-4000-8000-000000000002','4.25G','PURCHASE_IN','SALEABLE',180,'2026-11-05'),
 ('20000000-0000-4000-8000-000000000003','THUMS UP','PURCHASE_IN','SALEABLE',2400,'2026-11-05');`);
  await db.exec(sql);await db.exec(sql);
  const q=async id=>(await db.query(`select coalesce(sum(qty_pcs),0)::int n from lwb_inventory_movements where sku_id=$1 and movement_type='PURCHASE_IN'`,[id])).rows[0].n;
  assert.equal(await q('20000000-0000-4000-8000-000000000001'),960*48); // 10 carton x 48 IC x 96 pcs
  assert.equal(await q('20000000-0000-4000-8000-000000000002'),180*180); // IC per Carton empty: taken from PCS per IC (180)
  assert.equal(await q('20000000-0000-4000-8000-000000000003'),2400);   // Coca-Cola: cases, untouched
  const n=(await db.query(`select notes from lwb_inventory_movements where notes is not null`)).rows;
  assert.equal(n.length,2);assert.ok(n.some(x=>/10 carton x 48 IC/.test(x.notes)));
  assert.equal((await db.query(`select pcs_per_case from sku_master where id='20000000-0000-4000-8000-000000000002'`)).rows[0].pcs_per_case,180); // PCS per IC untouched
});
