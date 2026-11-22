import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_rate_roi_setup.sql on an empty PGlite database (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',sales:'00000000-0000-4000-8000-000000000004'};
const day=n=>new Date(Date.now()+19800000+n*86400000).toISOString().slice(0,10);
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,order_date timestamptz default now(),status text default 'approved');
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid references orders(id) on delete cascade,sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric default 0,rate numeric);
CREATE TABLE public.sku_master(id uuid default gen_random_uuid() primary key,sku_name text,category text,pcs_per_case integer);
CREATE TABLE public.lwb_goods_inward(id uuid default gen_random_uuid() primary key,invoice_date date,received_date date);
CREATE TABLE public.lwb_goods_inward_items(id bigserial primary key,inward_id uuid,sku_id uuid,quantity_pcs bigint);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT ALL ON public.orders, public.order_items TO authenticated; GRANT USAGE ON SEQUENCE order_items_id_seq TO authenticated;
`);
for(const [k,r] of [['admin','admin'],['head','manager'],['sales','sales']])await db.query('insert into user_profiles values($1,$2,true,$3)',[ids[k],r,k.toUpperCase()]);
const read=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(await read('lwb_rate_scheme_setup.sql'));
await db.exec(`CREATE TABLE public.lwb_rate_pack_skus(sku_key text primary key, pack_id uuid references lwb_rate_packs(id));`);
await db.exec(await read('lwb_party_rate_offer_setup.sql'));
await db.exec(await read('lwb_party_rate_offer_dates_setup.sql'));
await db.exec(`SET request.jwt.claim.sub='${ids.head}'`);
// an offer saved before this change (no ROI column yet)
await db.query(`select public.lwb_party_rate_offer_save($1)`,[JSON.stringify({party_name:'Old Party',lines:[{item:'250M',rate:440}]})]);
const sql=await read('lwb_party_rate_roi_setup.sql');
await db.exec(sql);await db.exec(sql); // safe to run again

const pk=(await db.query(`insert into lwb_rate_packs(pack_name,gr,slab3_rate) values('250M',400,450) returning id`)).rows[0].id;
const pk2=(await db.query(`insert into lwb_rate_packs(pack_name,gr,slab3_rate) values('1L KINLEY',150,170) returning id`)).rows[0].id;
await db.query(`insert into lwb_rate_pack_skus(sku_key,pack_id) values('THUMS UP 250ML',$1),('SPRITE 250ML',$1),('KINLEY 1L',$2)`,[pk,pk2]);
const sk=(await db.query(`insert into sku_master(sku_name,category,pcs_per_case) values('THUMS UP 250ML','250ML CSD',24),('KINLEY 1L','Water',12) returning id`)).rows.map(r=>r.id);

async function run(who,q,p){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);await db.exec('SET ROLE authenticated');try{return await db.query(q,p)}finally{await db.exec('RESET ROLE')}}
const save=(who,o)=>run(who,'select public.lwb_party_rate_offer_save($1) r',[JSON.stringify(o)]).then(r=>r.rows[0].r);
const list=who=>run(who,`select public.lwb_party_rate_offer_list(3650,null) l`).then(r=>r.rows[0].l);
const report=(who,m)=>run(who,'select public.lwb_party_roi_report($1) r',[m||null]).then(r=>r.rows[0].r);
const order=async(party,lines,date,status)=>{const o=(await db.query('insert into orders(order_no,customer_name,order_date,status) values($1,$2,coalesce($3::timestamptz,now()),coalesce($4,$5)) returning id',['PO-'+Math.random().toString(36).slice(2,6),party,date||null,status||null,'approved'])).rows[0].id;
  for(const [s,q,r] of lines)await db.query('insert into order_items(order_id,sku_name,ordered_qty,approved_qty,rate) values($1,$2,$3,$3,$4)',[o,s,q,r]);return o};

test('ROI setting: Admin only; categories kept upper case', async()=>{
  await assert.rejects(run('head','select public.lwb_party_roi_settings_save(5,$1)',[['water']]),/Only Admin/);
  await run('admin','select public.lwb_party_roi_settings_save(5,$1)',[['water',' Water ','']]);
  const s=(await run('head','select * from lwb_party_roi_settings')).rows[0];
  assert.equal(Number(s.roi_per_case),5);assert.deepEqual(s.no_roi_categories,['WATER']);
  assert.equal((await run('sales','select * from lwb_party_roi_settings')).rows.length,0);
});

test('ROI is saved per line and shown in the list and last rates', async()=>{
  const a=await save('head',{party_name:'Kanha',lines:[{item:'250M',rate:395,roi:5,landing:400},{item:'1L Kinley',rate:160,roi:0}]});
  const o=(await list('head')).find(x=>x.offer_no===a.offer_no);
  assert.equal(o.roi_lines,1);assert.equal(o.recheck_lines,0);
  assert.deepEqual(o.lines.map(l=>[l.item,l.roi,l.landing]),[['250M',5,400],['1L Kinley',null,null]]);
  const last=(await run('head','select public.lwb_party_rate_last($1) r',['kanha'])).rows[0].r;
  assert.equal(last.find(x=>x.item_key==='250M').roi,5);
  assert.equal((await list('head')).find(x=>x.party_name==='Old Party').roi_lines,0);
});

test('pack rate changed: running offers of that pack get a recheck flag; checked clears it', async()=>{
  const ex=await save('head',{party_name:'Ended Party',offer_type:'DATED',valid_from:day(-9),valid_to:day(-2),lines:[{item:'Thums Up 250ml',rate:410}]});
  const sp=await save('head',{party_name:'Sku Party',lines:[{item:'Sprite 250ml',rate:410}]});
  await db.query(`update lwb_rate_packs set gr=405, slab3_rate=455 where id=$1`,[pk]);
  await db.query(`update lwb_rate_packs set sort_no=sort_no where id=$1`,[pk2]); // nothing changed
  const L=await list('head'),by=n=>L.filter(x=>x.party_name===n);
  const k=by('Kanha')[0];
  assert.equal(k.recheck_lines,1);
  assert.match(k.lines[0].recheck_note,/GR 400→405 · List 450→455/);
  assert.equal(k.lines[1].recheck_at,null);
  assert.equal(by('Sku Party')[0].recheck_lines,1);          // offer on a SKU of the pack
  assert.equal(by('Old Party')[0].recheck_lines,1);
  assert.equal(by('Ended Party')[0].recheck_lines,0);        // ended offer is not flagged
  assert.equal((await run('head','select public.lwb_party_rate_recheck_done($1) n',[k.id])).rows[0].n,1);
  await assert.rejects(run('sales','select public.lwb_party_rate_recheck_done($1)',[sp.id]),/Only Admin or Sales Head/);
  assert.equal((await list('head')).find(x=>x.id===k.id).recheck_lines,0);
  void ex;
});

test('ROI report: earned on month purchase (no-ROI category left out) vs given to ROI parties', async()=>{
  const m=day(0).slice(0,8)+'01';
  const g=(await db.query(`insert into lwb_goods_inward(invoice_date) values($1) returning id`,[day(0)])).rows[0].id;
  await db.query(`insert into lwb_goods_inward_items(inward_id,sku_id,quantity_pcs) values($1,$2,2400),($1,$3,1200)`,[g,sk[0],sk[1]]); // 100 cs CSD, 100 cs water
  await order('Kanha',[['Thums Up 250ml',30,395],['Sprite 250ml',10,395],['Kinley 1L',50,160]]);
  await order('Kanha',[['Thums Up 250ml',99,395]],null,'cancelled');
  await order('Shiv',[['Thums Up 250ml',40,410]]);
  const r=await report('head',m);
  assert.equal(Number(r.roi_per_case),5);
  assert.equal(Number(r.earned_cases),100);assert.equal(Number(r.earned_amount),500);
  assert.deepEqual(r.earned.map(e=>[e.category,Number(e.cases),e.roi]),[['250ML CSD',100,true],['WATER',100,false]]);
  assert.equal(Number(r.given_cases),40);assert.equal(Number(r.given_amount),200);
  assert.deepEqual(r.given.map(p=>[p.party,Number(p.cases),Number(p.amount)]),[['Kanha',40,200]]);
  assert.equal(r.roi_parties,1);
  await assert.rejects(report('sales',m),/Only Admin or Sales Head/);
});
