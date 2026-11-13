import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_stts_ledger_setup.sql on an empty PGlite database; 4 bills shaped like the 1-11 Nov 2026 company files (names and bill no. replaced).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',acc:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE SCHEMA storage;
CREATE TABLE storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
CREATE TABLE storage.objects(id bigserial primary key,bucket_id text,name text);
CREATE FUNCTION storage.foldername(name text) RETURNS text[] LANGUAGE sql AS $$ SELECT string_to_array(name,'/') $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
GRANT USAGE ON SCHEMA public, auth, storage TO authenticated;
`);
for(const [k,r] of [['admin','admin'],['head','manager'],['acc','accounts'],['sales','sales']])await db.query('insert into user_profiles values($1,$2,true,$3)',[ids[k],r,k.toUpperCase()]);
const read=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(await read('lwb_rate_scheme_setup.sql'));
await db.exec(await read('lwb_rate_ledger_setup.sql'));
const sql=await read('lwb_stts_ledger_setup.sql');
await db.exec(sql);await db.exec(sql); // safe to run again
const F=JSON.parse(await readFile(new URL('./fixture.json',import.meta.url),'utf8'));
async function run(who,q,p){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);await db.exec('SET ROLE authenticated');try{return await db.query(q,p)}finally{await db.exec('RESET ROLE')}}
const up=(who,fn,rows,file)=>run(who,`select public.${fn}($1::jsonb,$2) r`,[JSON.stringify(rows),file||'f']).then(x=>x.rows[0].r);

test('Sales Register upload: new, then same file = nothing doubled, changed line replaced', async()=>{
  const a=await up('acc','lwb_stts_sales_upload',F.sales,'SalesRegister.csv');
  assert.equal(a.added,F.sales.length);assert.equal(a.same,0);
  const b=await up('acc','lwb_stts_sales_upload',F.sales);
  assert.deepEqual([b.added,b.changed,b.same],[0,0,F.sales.length]);
  const ch=F.sales.map((r,i)=>i===0?{...r,ea:r.ea+1}:r);
  const c=await up('admin','lwb_stts_sales_upload',ch);
  assert.deepEqual([c.added,c.changed],[0,1]);
  assert.equal((await db.query('select count(*)::int n from lwb_stts_sales')).rows[0].n,F.sales.length);
  await up('admin','lwb_stts_sales_upload',F.sales);
});

test('STTS upload replaces the dates it covers, other dates stay', async()=>{
  const a=await up('acc','lwb_stts_claims_upload',F.stts,'STTS.xls');
  assert.equal(a.lines,F.stts.length);assert.equal(a.replaced,0);
  const b=await up('acc','lwb_stts_claims_upload',F.stts);
  assert.equal(b.replaced,F.stts.length);
  assert.equal((await db.query('select count(*)::int n from lwb_stts_claims')).rows[0].n,F.stts.length);
  // an older month stays when November is uploaded again
  await up('acc','lwb_stts_claims_upload',[{doc_type:'SI',doc:'OLD-1',day:'2026-10-15',sale_type:'Free goods (Exclusive)',item:'X',pc:1,amt:10}]);
  await up('acc','lwb_stts_claims_upload',F.stts);
  assert.equal((await db.query(`select count(*)::int n from lwb_stts_claims where doc='OLD-1'`)).rows[0].n,1);
});

test('data for the page: rows, uploads with names, links, Rate Ledger free bottle per pack', async()=>{
  await run('admin',`select public.lwb_save_rates('{}'::jsonb,'[{"pack_name":"250 ML PET","free_bottle":2.8}]'::jsonb,'n','[{"name":"250 ML PET","fb":2.8,"oms":46.89,"land":440}]'::jsonb)`);
  await run('head',`select public.lwb_stts_pack_link('250mlplbtn1x28','250 ML PET')`);
  await assert.rejects(run('acc',`select public.lwb_stts_pack_link('250MLPLBTN1X28','250 ML PET')`),/Only Admin or Sales Head/);
  await assert.rejects(run('admin',`select public.lwb_stts_pack_link('250MLPLBTN1X28','NO SUCH')`),/not found/);
  const d=(await run('acc','select public.lwb_stts_data(24) d')).rows[0].d;
  assert.equal(d.sales.length,F.sales.length);assert.equal(d.claims.length,F.stts.length+1);
  assert.equal(d.links['250MLPLBTN1X28'],'250 ML PET');
  assert.deepEqual(d.rates[0].rows,[{name:'250 ML PET',fb:2.8,oms:46.89}]);
  assert.equal(d.uploads[0].by_name,'ACC');assert.deepEqual(d.packs,['250 ML PET']);
  // the page's matching on this data: TEST-284 gave 159 free bottles, STTS 145 (short 14)
  globalThis.window=globalThis;await import('../../stts-match.js');
  const rateFor=(p,day)=>{const n=d.links[p];if(!n)return null;const r=d.rates[0].rows.find(x=>x.name===n);return r?{fb:+r.fb,oms:+r.oms}:null};
  const m=globalThis.LWBStts.match(d.sales.map(r=>({...r,day:String(r.day).slice(0,10),pc:+r.pc,ea:+r.ea,bpc:+r.bpc,line:+r.line,disc:+r.disc,net:+r.net,promo:+r.promo,landed:+r.landed})),
    d.claims.map(r=>({...r,day:String(r.day).slice(0,10),pc:+r.pc,amt:+r.amt})),rateFor);
  const b=m.rows.find(r=>r.doc==='TEST-284'&&r.kind==='FREE');
  assert.deepEqual([b.exp,b.given,b.stts],[159,159,145]);assert.ok(b.flags.includes('STTS_SHORT'));
  const z=m.rows.find(r=>r.doc==='TEST-532'&&r.kind==='FREE');
  assert.deepEqual([z.exp,z.given],[19,0]);assert.ok(z.flags.includes('NOT_GIVEN'));
});

test('only Admin, Sales Head, Accounts; no direct table access', async()=>{
  await assert.rejects(run('sales','select public.lwb_stts_data(6)'),/Only Admin, Sales Head or Accounts/);
  await assert.rejects(up('sales','lwb_stts_sales_upload',F.sales),/Only Admin, Sales Head or Accounts/);
  await assert.rejects(run('admin','select * from lwb_stts_sales'),/permission denied/);
  await assert.rejects(up('admin','lwb_stts_claims_upload',[]),/No lines/);
  await assert.rejects(up('admin','lwb_stts_sales_upload',[{doc:'',line_no:1}]),/No valid lines/);
});
