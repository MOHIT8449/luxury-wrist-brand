import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_bill_amount_mismatch_setup.sql on an empty PGlite database (no live data).
const ACC='00000000-0000-4000-8000-000000000005',SALES='00000000-0000-4000-8000-000000000006';
const O1='10000000-0000-4000-8000-000000000001',O2='10000000-0000-4000-8000-000000000002';
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE TABLE auth.users(id uuid primary key);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,full_name text,role text,active boolean default true);
CREATE TABLE public.orders(id uuid primary key);
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key,amount numeric(14,2));
CREATE FUNCTION public.lwb_tally_staff() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active AND lower(btrim(p.role)) IN ('accounts','admin')) $$;
INSERT INTO auth.users VALUES ('${ACC}'),('${SALES}');
INSERT INTO user_profiles VALUES ('${ACC}','Yogesh','accounts'),('${SALES}','Ravi','sales');
INSERT INTO orders VALUES ('${O1}'),('${O2}');
INSERT INTO lwb_tally_invoices VALUES ('${O1}',95000),('${O2}',56170);
`);
const sql=await readFile(new URL('../../lwb_bill_amount_mismatch_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql); // safe to run again
const as=u=>db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[u]);

test('Accounts OKs a short bill: kept with the saved bill amount',async()=>{
  await as(ACC);
  const r=(await db.query(`select public.lwb_bill_mismatch_note($1,100000,'LOADED') j`,[O1])).rows[0].j;
  assert.deepEqual(r,{saved:true,diff:-5000});
  const l=(await db.query(`select order_id,bill_amount::float b,expected::float e,diff::float d,basis,noted_by from public.lwb_bill_mismatch_list(30)`)).rows;
  assert.deepEqual(l,[{order_id:O1,b:95000,e:100000,d:-5000,basis:'LOADED',noted_by:'Yogesh'}]);
});

test('bill within Rs 1 of the value is not a mismatch',async()=>{
  await as(ACC);
  const r=(await db.query(`select public.lwb_bill_mismatch_note($1,56170.6,'CHANGE') j`,[O2])).rows[0].j;
  assert.equal(r.saved,false);
});

test('no Tally bill yet / not Accounts = refused; others see nothing',async()=>{
  await as(ACC);
  await db.query(`delete from lwb_tally_invoices where order_id=$1`,[O2]);
  await assert.rejects(db.query(`select public.lwb_bill_mismatch_note($1,100,'PO')`,[O2]),/Save the Tally bill first/);
  await as(SALES);
  await assert.rejects(db.query(`select public.lwb_bill_mismatch_note($1,100,'PO')`,[O1]),/Only active Accounts or Admin/);
  assert.equal((await db.query(`select count(*)::int n from public.lwb_bill_mismatch_list(30)`)).rows[0].n,0);
});
