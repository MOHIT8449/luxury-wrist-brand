import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_po_out_for_delivery_setup.sql on a tiny copy of the tables it reads (no live database).
const db=new PGlite();
const acc='00000000-0000-4000-8000-000000000002',gm='00000000-0000-4000-8000-000000000003';
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,full_name text,role text,active boolean);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,status text);
CREATE TABLE public.dispatch_assignments(order_id uuid,assigned_at timestamptz,loading_completed_at timestamptz);
CREATE TABLE public.lwb_tally_invoices(order_id uuid primary key,invoice_no text,entered_at timestamptz default now(),updated_at timestamptz);
`);
const sql=await readFile(new URL('../../lwb_po_out_for_delivery_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql); // safe to run again
await db.query("insert into user_profiles values($1,'YOGESH','accounts',true),($2,'RAMESH','warehouse',true)",[acc,gm]);
const as=u=>db.query("select set_config('request.jwt.claim.sub',$1,false)",[u]);
const po=async(no,st)=>(await db.query('insert into orders(order_no,status) values($1,$2) returning id',[no,st])).rows[0].id;
const err=async(q,p,re)=>{await assert.rejects(db.query(q,p),re)};

test('Out for delivery needs a loaded PO with its Tally bill; Accounts only',async()=>{
  const a=await po('A','loaded'),b=await po('B','loaded'),c=await po('C','loading');
  await db.query("insert into dispatch_assignments values($1,now(),now() - interval '5 hours')",[a]);
  await as(gm);
  await err('select lwb_mark_out_for_delivery($1)',[[a]],/Only Accounts/);
  await as(acc);
  await err('select lwb_mark_out_for_delivery($1)',[[a]],/Tally bill first: A/);
  await err('select lwb_mark_out_for_delivery($1)',[[c]],/Not loaded yet.*C/);
  await db.query("insert into lwb_tally_invoices(order_id,invoice_no) values($1,'GST/1')",[a]);
  assert.equal((await db.query('select lwb_mark_out_for_delivery($1) n',[[a]])).rows[0].n,1);
  assert.equal((await db.query('select lwb_mark_out_for_delivery($1) n',[[a]])).rows[0].n,0); // twice = no change
  await as(gm);
  const f=(await db.query('select * from lwb_po_flow_flags($1) order by bill_no nulls last',[[a,b]])).rows;
  assert.equal(f[0].bill_no,'GST/1');assert.equal(f[0].out_by_name,'YOGESH');assert.ok(f[0].loaded_at&&f[0].out_at);
  assert.equal(f[1].bill_no,null);assert.equal(f[1].out_at,null);
  await err('select lwb_undo_out_for_delivery($1)',[a],/Only Accounts/);
  await as(acc);
  await db.query('select lwb_undo_out_for_delivery($1)',[a]);
  assert.equal((await db.query('select count(*)::int n from lwb_po_out_delivery')).rows[0].n,0);
});
