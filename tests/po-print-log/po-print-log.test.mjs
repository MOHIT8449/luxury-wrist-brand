import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_po_print_log_setup.sql on a tiny copy of the tables it reads (no live database).
const ids={admin:'00000000-0000-4000-8000-000000000001',warehouse:'00000000-0000-4000-8000-000000000002',sales:'00000000-0000-4000-8000-000000000003'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,status text);
CREATE TABLE public.order_items(id uuid default gen_random_uuid() primary key,order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,rate numeric);
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role,role.toUpperCase()+' USER']);
const sql=await readFile(new URL('../../lwb_po_print_log_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql); // safe to run again
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]])}
async function q(text,args){await db.exec('SET ROLE authenticated');try{return (await db.query(text,args)).rows}finally{await db.exec('RESET ROLE')}}
const o=async no=>(await db.query("insert into orders(order_no,status) values($1,'approved') returning id",[no])).rows[0].id;
const a=await o('LXY-1'),b=await o('LXY-2');
await db.query(`insert into order_items(order_id,sku_name,ordered_qty,approved_qty,rate) values($1,'Coke 750',10,null,500),($1,'Thums Up',5,4,450)`,[a]);
const info=async list=>Object.fromEntries((await q('select * from lwb_po_print_info($1::uuid[])',[list])).map(r=>[r.order_id,r]));

test('a PO never printed has no row; one print is counted with who printed it', async()=>{
  await as('admin');
  assert.deepEqual(await info([a,b]),{});
  const r=await q('select lwb_po_print_mark($1,$2) as r',[a,'PO']);
  assert.equal(r[0].r.prints,1);
  const i=(await info([a,b]))[a];
  assert.equal(i.prints,1);assert.equal(i.po_prints,1);assert.equal(i.challan_prints,0);
  assert.equal(i.last_by,'ADMIN USER');assert.equal(i.changed,false);
});

test('changing a qty after the print shows changed; printing again clears it', async()=>{
  await as('warehouse');
  await db.query("update order_items set approved_qty=3 where sku_name='Thums Up'");
  assert.equal((await info([a]))[a].changed,true);
  await q('select lwb_po_print_mark($1,$2)',[a,'challan']);
  const i=(await info([a]))[a];
  assert.equal(i.prints,2);assert.equal(i.challan_prints,1);assert.equal(i.changed,false);assert.equal(i.last_by,'WAREHOUSE USER');
});

test('line order does not matter; a salesman can not print or read', async()=>{
  await as('admin');
  await db.query("update order_items set sku_name=sku_name");
  assert.equal((await info([a]))[a].changed,false);
  await as('sales');
  await assert.rejects(q('select lwb_po_print_mark($1,$2)',[a,'PO']),/Only Admin/);
  await assert.rejects(q('select * from lwb_po_print_info($1::uuid[])',[[a]]),/Only Admin/);
  await assert.rejects(q('select * from lwb_po_prints'),/permission denied/);
});
