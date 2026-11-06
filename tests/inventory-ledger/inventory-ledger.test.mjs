import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_inventory_ledger_setup.sql on PGlite with stand-in tables (no live data).
// Three shapes of the live stock view are tried: one that ignores loading, one that reads
// order_items.loaded_qty, and one fed by negative DISPATCH stock rows.
const ADMIN='00000000-0000-4000-8000-000000000001',SALES='00000000-0000-4000-8000-000000000002';
const SKU='50000000-0000-4000-8000-000000000001';
const sql=await readFile(new URL('../../lwb_inventory_ledger_setup.sql',import.meta.url),'utf8');

async function setup(view){
  const db=new PGlite();
  await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
CREATE TABLE public.sku_master(id uuid primary key,sku_name text,pcs_per_case int,is_active boolean default true);
CREATE TABLE public.orders(id uuid primary key default gen_random_uuid(),order_no text,customer_name text,status text);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_id uuid,sku_name text,loaded_qty numeric);
CREATE TABLE public.dispatch_assignments(id bigserial primary key,order_id uuid,loading_completed_at timestamptz);
CREATE TABLE public.lwb_admin_order_marks(order_id uuid,kind text,mark_date date,marked_at timestamptz);
CREATE TABLE public.lwb_inventory_movements(id bigserial primary key,sku_id uuid,sku_name text,movement_type text,stock_bucket text,qty_pcs int,order_id uuid,created_at timestamptz);
CREATE TABLE public.lwb_stock_moves(id bigserial primary key,kind text,from_bucket text,to_bucket text,sku_id uuid,qty_pcs int,status text,move_date date,decided_at timestamptz);
INSERT INTO user_profiles VALUES ('${ADMIN}','admin',true),('${SALES}','salesman',true);
INSERT INTO sku_master VALUES ('${SKU}','RG 2.2G',96);
`);
  await db.exec(view);
  await db.exec(`GRANT USAGE ON SCHEMA public, auth TO authenticated;`);
  await db.exec(sql);await db.exec(sql); // safe to run again
  // Fresh start 4 Nov: opening 100 IC. 5 Nov purchase 10 IC. Loaded: 6 IC (loaded, vehicle time),
  // 2 IC (dispatched), 1 IC (Admin mark only, no transport row), 3 IC cancelled (not counted).
  const at=d=>`'2026-11-0${d} 10:00+05:30'`;
  await db.exec(`
INSERT INTO lwb_inventory_movements(sku_id,sku_name,movement_type,stock_bucket,qty_pcs,created_at) VALUES
 ('${SKU}','RG 2.2G','OPENING','SALEABLE',9600,${at(4)}),('${SKU}','RG 2.2G','PURCHASE_IN','SALEABLE',960,${at(5)});
INSERT INTO orders(id,order_no,customer_name,status) VALUES
 ('a0000000-0000-4000-8000-000000000001','PO-1','A','loaded'),('a0000000-0000-4000-8000-000000000002','PO-2','B','dispatched'),
 ('a0000000-0000-4000-8000-000000000003','PO-3','C','delivered'),('a0000000-0000-4000-8000-000000000004','PO-4','D','cancelled');
INSERT INTO order_items(order_id,sku_id,sku_name,loaded_qty) VALUES
 ('a0000000-0000-4000-8000-000000000001','${SKU}','RG 2.2G',6),('a0000000-0000-4000-8000-000000000002',null,'rg 2.2g',2),
 ('a0000000-0000-4000-8000-000000000003','${SKU}','RG 2.2G',1),('a0000000-0000-4000-8000-000000000004','${SKU}','RG 2.2G',3);
INSERT INTO dispatch_assignments(order_id,loading_completed_at) VALUES
 ('a0000000-0000-4000-8000-000000000001',${at(5)}),('a0000000-0000-4000-8000-000000000002',${at(6)}),('a0000000-0000-4000-8000-000000000004',${at(6)});
INSERT INTO lwb_admin_order_marks VALUES ('a0000000-0000-4000-8000-000000000003','LOADED','2026-11-05','2026-11-06 09:00+05:30');
-- 1 IC Saleable -> Damage approved on 6 Nov
INSERT INTO lwb_stock_moves(kind,from_bucket,to_bucket,sku_id,qty_pcs,status,move_date,decided_at) VALUES
 ('TRANSFER','SALEABLE','DAMAGE','${SKU}',96,'APPROVED','2026-11-06',${at(6)}),('TRANSFER','SALEABLE','DAMAGE','${SKU}',96,'PENDING','2026-11-06',null);
`);
  return db;
}
async function ledger(db,from,to,who=ADMIN){
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[who]);
  return (await db.query('select lwb_inventory_ledger($1::date,$2::date) r',[from,to])).rows[0].r;
}
const stx=`(SELECT coalesce(sum(CASE WHEN m.to_bucket='SALEABLE' THEN m.qty_pcs ELSE -m.qty_pcs END),0) FROM lwb_stock_moves m WHERE m.sku_id=s.id AND m.status='APPROVED')`;
const VIEW_IGNORES=`CREATE VIEW public.lwb_live_stock AS SELECT s.id AS sku_id,s.sku_name,s.pcs_per_case,
  (SELECT coalesce(sum(m.qty_pcs),0) FROM lwb_inventory_movements m WHERE m.sku_id=s.id)+${stx} AS saleable_pcs,0 AS damaged_pcs FROM sku_master s;`;
const VIEW_READS=`CREATE VIEW public.lwb_live_stock AS SELECT s.id AS sku_id,s.sku_name,s.pcs_per_case,
  (SELECT coalesce(sum(m.qty_pcs),0) FROM lwb_inventory_movements m WHERE m.sku_id=s.id)
  -(SELECT coalesce(sum(i.loaded_qty),0)*s.pcs_per_case FROM order_items i JOIN orders o ON o.id=i.order_id WHERE upper(i.sku_name)=upper(s.sku_name) AND o.status<>'cancelled')+${stx} AS saleable_pcs,
  0 AS damaged_pcs FROM sku_master s;`;
const row=r=>r.rows.find(x=>x.sku_id===SKU);

test('only stock roles can read it',async()=>{
  const db=await setup(VIEW_IGNORES);
  await assert.rejects(ledger(db,'2026-11-01','2026-11-06',SALES),/Admin, Sales Head, Godown or Accounts only/);
  await assert.rejects(ledger(db,'2026-11-07','2026-11-06'),/valid From and To/);
});

test('every loaded PO counts in Stock Out: dispatched, delivered, Admin mark; not cancelled',async()=>{
  const db=await setup(VIEW_IGNORES);
  const r=await ledger(db,'2026-11-01','2026-11-06');
  assert.deepEqual(r.out_lines.map(x=>x.order_no).sort(),['PO-1','PO-2','PO-3']);
  assert.equal(r.out_lines.find(x=>x.order_no==='PO-2').sku_id,SKU); // matched by name
  assert.equal(row(r).out_pcs,9*96);
  // 5 Nov only: PO-1 (vehicle) + PO-3 (Admin mark 5 Nov)
  const d5=await ledger(db,'2026-11-05','2026-11-05');
  assert.deepEqual(d5.out_lines.map(x=>x.order_no).sort(),['PO-1','PO-3']);
});

test('live stock that ignores loading: shown as a difference',async()=>{
  const db=await setup(VIEW_IGNORES);
  const r=await ledger(db,'2026-11-01','2026-11-06'),x=row(r);
  assert.equal(r.link.follows_loading,false);
  assert.equal(x.opening_pcs,0);          // nothing before the fresh start
  assert.equal(x.opening_entry,9600);
  assert.equal(x.in_pcs,960);
  assert.equal(x.other_pcs,-96);         // approved damage only
  assert.equal(x.out_pcs,864);
  assert.equal(x.book_pcs,9600+960-96-864);
  assert.equal(x.system_pcs,9600+960-96);
  assert.equal(x.system_pcs-x.book_pcs,864); // the sale was never taken out
  // period after the opening: opening of 5 Nov = 100 IC
  const y=row(await ledger(db,'2026-11-05','2026-11-06'));
  assert.equal(y.opening_pcs,9600);assert.equal(y.opening_entry,0);
});

test('live stock that reads loaded qty: no difference',async()=>{
  const db=await setup(VIEW_READS);
  const r=await ledger(db,'2026-11-01','2026-11-06'),x=row(r);
  assert.equal(r.link.view_reads_orders,true);
  assert.equal(x.book_pcs,x.system_pcs);
  assert.equal(x.opening_pcs,0);
  const y=row(await ledger(db,'2026-11-06','2026-11-06'));
  assert.equal(y.opening_pcs,9600+960-7*96); // PO-1 + PO-3 left on 5 Nov
  assert.equal(y.book_pcs,y.system_pcs);
  const z=row(await ledger(db,'2026-11-04','2026-11-05')); // closing of 5 Nov, before 6 Nov changes
  assert.equal(z.system_pcs,9600+960-7*96);assert.equal(z.book_pcs,z.system_pcs);
});

test('live stock fed by DISPATCH stock rows: no difference',async()=>{
  const db=await setup(VIEW_IGNORES);
  await db.exec(`INSERT INTO lwb_inventory_movements(sku_id,sku_name,movement_type,stock_bucket,qty_pcs,order_id,created_at) VALUES
    ('${SKU}','RG 2.2G','DISPATCH','SALEABLE',-576,'a0000000-0000-4000-8000-000000000001','2026-11-05 10:00+05:30'),
    ('${SKU}','RG 2.2G','DISPATCH','SALEABLE',-192,'a0000000-0000-4000-8000-000000000002','2026-11-06 10:00+05:30'),
    ('${SKU}','RG 2.2G','DISPATCH','SALEABLE',-96,'a0000000-0000-4000-8000-000000000003','2026-11-05 12:00+05:30')`);
  const r=await ledger(db,'2026-11-01','2026-11-06'),x=row(r);
  assert.equal(r.link.follows_loading,true);
  assert.equal(x.other_pcs,-96);          // sale rows are not "other"
  assert.equal(x.book_pcs,x.system_pcs);
});

test('Booked = POs given but not loaded yet (approved, pending, loading part); loaded and cancelled not',async()=>{
  const db=await setup(VIEW_IGNORES);
  await db.exec(`ALTER TABLE order_items ADD COLUMN ordered_qty numeric, ADD COLUMN approved_qty numeric;
INSERT INTO orders(id,order_no,customer_name,status) VALUES
 ('b0000000-0000-4000-8000-000000000005','PO-5','E','approved'),('b0000000-0000-4000-8000-000000000006','PO-6','F','pending_approval'),
 ('b0000000-0000-4000-8000-000000000007','PO-7','G','loading'),('b0000000-0000-4000-8000-000000000008','PO-8','H','cancelled');
INSERT INTO order_items(order_id,sku_id,sku_name,ordered_qty,approved_qty,loaded_qty) VALUES
 ('b0000000-0000-4000-8000-000000000005','${SKU}','RG 2.2G',6,4,null),('b0000000-0000-4000-8000-000000000006','${SKU}','RG 2.2G',2,null,null),
 ('b0000000-0000-4000-8000-000000000007','${SKU}','RG 2.2G',5,5,2),('b0000000-0000-4000-8000-000000000008','${SKU}','RG 2.2G',7,7,null);
UPDATE order_items SET ordered_qty=loaded_qty,approved_qty=loaded_qty WHERE ordered_qty IS NULL;`);
  const x=row(await ledger(db,'2026-11-01','2026-11-06'));
  assert.equal(x.booked_pcs,(4+2+3)*96);
  assert.equal(x.out_pcs,9*96); // loaded POs are Stock Out, not Booked
});
