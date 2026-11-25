import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_ledger_all_rows_fix.sql: the whole ledger as one json value, so the website API (max 1000 rows
// per call) can not cut the newest entries. Stub lwb_party_ledger_b() with 1500 rows (same columns + viewer rule).
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean);
INSERT INTO public.user_profiles VALUES ('00000000-0000-4000-8000-000000000001','accounts',true),('00000000-0000-4000-8000-000000000009','driver',true);
CREATE FUNCTION public.lwb_party_ledger_b()
RETURNS TABLE(entry_date date, entry_kind text, customer_name text, ref_no text, order_no text,
              debit numeric, credit numeric, note text, created_at timestamptz, company_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT DATE '2026-04-01' + (g % 230), CASE WHEN g > 1400 THEN 'PARTY_PAYMENT' ELSE 'TALLY_BILL' END,
         'PARTY ' || (g % 60), CASE WHEN g > 1400 THEN 'CASH' ELSE 'B' || g END, NULL::text,
         CASE WHEN g > 1400 THEN 0 ELSE 100 END::numeric, CASE WHEN g > 1400 THEN 50.5 ELSE 0 END::numeric,
         'n', now(), NULL::uuid
  FROM generate_series(1,1500) g
  WHERE EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active AND p.role IN ('admin','accounts'));
$$;
GRANT EXECUTE ON FUNCTION public.lwb_party_ledger_b() TO authenticated;
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
await db.exec(await sql('lwb_party_ledger_all_rows_fix.sql'));
await db.exec(await sql('lwb_party_ledger_all_rows_fix.sql')); // safe to run again
async function as(id){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id])}
async function call(q){await db.exec('SET ROLE authenticated');try{return (await db.query(q)).rows}finally{await db.exec('RESET ROLE')}}

test('every ledger row comes back in one value (more than 1000 rows)',async()=>{
  await as('00000000-0000-4000-8000-000000000001');
  const j=(await call('select public.lwb_party_ledger_bj() j'))[0].j;
  assert.equal(j.length,1500);
  const pp=j.filter(x=>x.entry_kind==='PARTY_PAYMENT');
  assert.equal(pp.length,100);                       // the newest rows (after row 1000) are there
  assert.deepEqual(Object.keys(j[0]).sort(),['company_id','created_at','credit','customer_name','debit','entry_date','entry_kind','note','order_no','ref_no']);
  assert.equal(Number(pp[0].credit),50.5);
});
test('same viewer rule as the ledger: others get nothing, anon can not call',async()=>{
  await as('00000000-0000-4000-8000-000000000009');
  assert.deepEqual((await call('select public.lwb_party_ledger_bj() j'))[0].j,[]);
  await db.exec('SET ROLE anon');
  await assert.rejects(db.query('select public.lwb_party_ledger_bj()'));
  await db.exec('RESET ROLE');
});
