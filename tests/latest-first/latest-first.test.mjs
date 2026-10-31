import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {PGlite} from '@electric-sql/pglite';

// lwb_latest_first_setup.sql on an empty PGlite database (no live database),
// and erp-recent.js (the page-side sort) in a small VM.
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
-- old table without created_at / updated_at, with a json column (to_jsonb compare)
CREATE TABLE public.sku_master(id int primary key,sku_name text,extra json);
-- table with created_at only and an AFTER UPDATE trigger of its own
CREATE TABLE public.orders(id int primary key,status text,created_at timestamptz default now());
CREATE TABLE public.order_log(order_id int,status text);
CREATE FUNCTION public.log_order() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN INSERT INTO public.order_log VALUES(NEW.id,NEW.status);RETURN NEW;END$$;
CREATE TRIGGER trg_log AFTER UPDATE OF status ON public.orders FOR EACH ROW EXECUTE FUNCTION public.log_order();
-- table that already has updated_at + its own touch trigger
CREATE TABLE public.lwb_vehicles(id int primary key,vehicle_no text,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
-- Sheet & Pallet style history trigger that must not see updated_at as an edit
CREATE TABLE public.lwb_sp_entries(id int primary key,pallets int,verified_at timestamptz,created_at timestamptz default now());
CREATE TABLE public.lwb_sp_history(entry_id int,action text);
CREATE FUNCTION public.lwb_sp_log_change() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN
  IF (to_jsonb(NEW)-'verified_at') IS DISTINCT FROM (to_jsonb(OLD)-'verified_at') THEN INSERT INTO public.lwb_sp_history VALUES(OLD.id,'EDIT'); END IF; RETURN NEW; END$$;
CREATE TRIGGER lwb_sp_entries_history BEFORE UPDATE ON public.lwb_sp_entries FOR EACH ROW EXECUTE FUNCTION public.lwb_sp_log_change();
-- updated_at of another type: left alone
CREATE TABLE public.lwb_drivers(id int primary key,updated_at text);
-- a view with the same name as a list table: skipped
CREATE TABLE public.base_x(id int); CREATE VIEW public.lwb_tasks AS SELECT * FROM public.base_x;
CREATE TABLE public.lwb_acc_staff(id int primary key,name text,emp_code text,active boolean,created_at timestamptz,updated_at timestamptz);
INSERT INTO public.sku_master VALUES(1,'A','{"a":1}'),(2,'B',null);
INSERT INTO public.orders(id,status,created_at) VALUES(1,'pending','2026-10-01'),(2,'pending','2026-10-02');
INSERT INTO public.lwb_vehicles(id,vehicle_no) VALUES(1,'GJ05AA1111');
INSERT INTO public.lwb_sp_entries(id,pallets) VALUES(1,5);
`);
const setup=await readFile(new URL('../../lwb_latest_first_setup.sql',import.meta.url),'utf8');

test('setup runs, and runs again',async()=>{
  await db.exec(setup);
  await db.exec(setup);
});
const col=async(t,c)=>(await db.query("select data_type from information_schema.columns where table_schema='public' and table_name=$1 and column_name=$2",[t,c])).rows[0]?.data_type;

test('columns are added without touching old rows',async()=>{
  assert.equal(await col('sku_master','updated_at'),'timestamp with time zone');
  assert.equal(await col('sku_master','created_at'),'timestamp with time zone');
  const r=(await db.query('select created_at,updated_at from sku_master order by id')).rows;
  assert.deepEqual(r.map(x=>[x.created_at,x.updated_at]),[[null,null],[null,null]]);
  await db.exec("insert into sku_master(id,sku_name) values(3,'C')");
  assert.ok((await db.query('select created_at from sku_master where id=3')).rows[0].created_at);
  assert.equal((await db.query('select count(*)::int n from order_log')).rows[0].n,0); // no mass update fired other triggers
});

test('an edit sets updated_at, a no-change save does not',async()=>{
  await db.exec("update sku_master set sku_name='A2' where id=1");
  const a=(await db.query('select updated_at from sku_master where id=1')).rows[0].updated_at;
  assert.ok(a);
  await db.exec("update sku_master set sku_name='B' where id=2");
  assert.equal((await db.query('select updated_at from sku_master where id=2')).rows[0].updated_at,null);
  await db.exec("update orders set status='cancelled' where id=1");
  assert.ok((await db.query('select updated_at from orders where id=1')).rows[0].updated_at);
  assert.equal((await db.query('select count(*)::int n from order_log')).rows[0].n,1);
});

test('other tables: own triggers keep working, wrong types and views are skipped',async()=>{
  await db.exec("update lwb_sp_entries set verified_at=now() where id=1");
  assert.equal((await db.query('select count(*)::int n from lwb_sp_history')).rows[0].n,0);
  assert.ok((await db.query('select updated_at from lwb_sp_entries')).rows[0].updated_at);
  await db.exec("update lwb_sp_entries set pallets=6 where id=1");
  assert.equal((await db.query('select count(*)::int n from lwb_sp_history')).rows[0].n,1);
  assert.equal(await col('lwb_drivers','updated_at'),'text');
  assert.equal((await db.query("select count(*)::int n from pg_trigger where tgname='zz_lwb_touch_updated_at' and tgrelid='public.lwb_drivers'::regclass")).rows[0].n,0);
  const v=(await db.query("select updated_at from lwb_vehicles")).rows[0].updated_at;
  await db.exec("update lwb_vehicles set vehicle_no='GJ05AA2222'");
  assert.ok((await db.query("select updated_at from lwb_vehicles")).rows[0].updated_at>=v);
});

test('erp-recent.js puts the latest added / edited row first',async()=>{
  const ctx={window:{},Date,Number,Map,String,Array,Math};vm.createContext(ctx);
  vm.runInContext(await readFile(new URL('../../erp-recent.js',import.meta.url),'utf8'),ctx);
  const R=ctx.window.ERPRecent;
  const rows=[
    {n:'old',created_at:'2026-10-01T10:00:00Z'},
    {n:'edited',created_at:'2026-09-01T10:00:00Z',updated_at:'2026-10-31T09:00:00Z'},
    {n:'none1'},
    {n:'new',created_at:'2026-10-30T10:00:00Z'},
    {n:'cancelled',created_at:'2026-08-01T10:00:00Z',cancelled_at:'2026-10-31 10:00:00+05:30'},
    {n:'none2'}];
  R.sort(rows);
  assert.deepEqual(rows.map(x=>x.n),['edited','cancelled','new','old','none1','none2']);
  const extra=[{n:'a',reported_at:'2026-10-01'},{n:'b',reported_at:'2026-10-05'}];
  assert.deepEqual(R.sort(extra,'reported_at').map(x=>x.n),['b','a']);
  // attach copies created_at / updated_at by id, skipping missing columns
  const fake={from:()=>{const q={cols:'',select(c){q.cols=c;return q},order(){return q},range(){
    return Promise.resolve(/updated_at/.test(q.cols)?{error:{message:'column missing'}}:{data:[{id:1,created_at:'2026-10-02'},{id:2,created_at:'2026-10-03'}]})}};return q}};
  const r2=await R.attach(fake,'t',[{id:1},{id:2}]);
  assert.deepEqual(R.sort(r2).map(x=>x.id),[2,1]);
});
