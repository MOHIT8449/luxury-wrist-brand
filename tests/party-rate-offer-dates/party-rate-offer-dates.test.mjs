import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_rate_offer_dates_setup.sql on an empty PGlite database (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',sales:'00000000-0000-4000-8000-000000000004',acc:'00000000-0000-4000-8000-000000000005'};
const day=n=>new Date(Date.now()+19800000+n*86400000).toISOString().slice(0,10);
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,rate numeric);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT ALL ON public.orders, public.order_items TO authenticated; GRANT USAGE ON SEQUENCE order_items_id_seq TO authenticated;
`);
for(const [k,r] of [['admin','admin'],['head','manager'],['sales','sales'],['acc','accounts']])await db.query('insert into user_profiles values($1,$2,true,$3)',[ids[k],r,k.toUpperCase()]);
const read=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(await read('lwb_rate_scheme_setup.sql'));
await db.exec(`CREATE TABLE public.lwb_rate_pack_skus(sku_key text primary key, pack_id uuid references lwb_rate_packs(id));`);
await db.exec(await read('lwb_party_rate_offer_setup.sql'));
// an offer made before this change
await db.exec(`SET request.jwt.claim.sub='${ids.head}'`);
await db.query(`select public.lwb_party_rate_offer_save($1)`,[JSON.stringify({party_name:'Old Party',offer_date:day(-40),lines:[{item:'250M',rate:440}]})]);
const sql=await read('lwb_party_rate_offer_dates_setup.sql');
await db.exec(sql);await db.exec(sql); // safe to run again
// Rate List pack 250M is linked to two SKUs
const pk=(await db.query(`insert into lwb_rate_packs(pack_name) values('250M') returning id`)).rows[0].id;
await db.query(`insert into lwb_rate_pack_skus(sku_key,pack_id) values('THUMS UP 250ML',$1),('SPRITE 250ML',$1)`,[pk]);

async function run(who,q,p){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);await db.exec('SET ROLE authenticated');try{return await db.query(q,p)}finally{await db.exec('RESET ROLE')}}
const save=(who,o)=>run(who,'select public.lwb_party_rate_offer_save($1) r',[JSON.stringify(o)]).then(r=>r.rows[0].r);
const rates=(who,party,order)=>run(who,'select public.lwb_party_offer_rates($1,$2) r',[party,order||null]).then(r=>r.rows[0].r);
const order=async(who,party,lines)=>{const o=(await run(who,'insert into orders(order_no,customer_name) values($1,$2) returning id',['PO-'+Math.random().toString(36).slice(2,6),party])).rows[0].id;
  for(const [s,r] of lines)await run(who,'insert into order_items(order_id,sku_name,ordered_qty,rate) values($1,$2,10,$3)',[o,s,r]);return o};
const list=who=>run(who,`select public.lwb_party_rate_offer_list(3650,null) l`).then(r=>r.rows[0].l);

test('old offers become Continuous from their own date and still fix the rate', async()=>{
  const o=(await list('head')).find(x=>x.party_name==='Old Party');
  assert.equal(o.offer_type,'CONTINUOUS');assert.equal(o.valid_from,day(-40));assert.equal(o.state,'RUNNING');
  const r=await rates('sales','old party');
  assert.equal(r.can_change,false);
  assert.deepEqual(r.rates.map(x=>[x.sku_key,x.rate]).sort(),[['250M',440],['SPRITE 250ML',440],['THUMS UP 250ML',440]]);
});

test('date range: rate fixed only inside the dates; checks on save', async()=>{
  await assert.rejects(save('head',{party_name:'Kanha',offer_type:'DATED',valid_from:day(0),lines:[{item:'250M',rate:443}]}),/end date/);
  await assert.rejects(save('head',{party_name:'Kanha',offer_type:'DATED',valid_from:day(0),valid_to:day(-1),lines:[{item:'250M',rate:443}]}),/before the start/);
  await assert.rejects(save('sales',{party_name:'Kanha',offer_type:'DATED',valid_from:day(0),valid_to:day(5),lines:[{item:'250M',rate:443}]}),/Only Admin or Sales Head/);
  await save('head',{party_name:'Kanha',offer_type:'DATED',valid_from:day(-10),valid_to:day(-1),lines:[{item:'250M',rate:430}]});
  await save('head',{party_name:'Kanha',offer_type:'DATED',valid_from:day(3),valid_to:day(9),lines:[{item:'250M',rate:420}]});
  assert.deepEqual((await rates('sales','Kanha')).rates,[]);
  const a=await save('head',{party_name:'Kanha',offer_type:'DATED',valid_from:day(0),valid_to:day(5),lines:[{item:'250M',rate:443},{item:'Maaza 600ML',rate:670}]});
  const r=(await rates('sales','KANHA')).rates;
  assert.deepEqual(r.map(x=>[x.sku_key,x.rate,x.offer_no]).sort(),[['250M',443,a.offer_no],['MAAZA 600ML',670,a.offer_no],['SPRITE 250ML',443,a.offer_no],['THUMS UP 250ML',443,a.offer_no]]);
  const st=Object.fromEntries((await list('head')).filter(x=>x.party_name==='Kanha').map(x=>[x.valid_from,x.state]));
  assert.deepEqual(st,{[day(-10)]:'EXPIRED',[day(3)]:'UPCOMING',[day(0)]:'RUNNING'});
});

test('salesman cannot change the offer rate; Admin / Sales Head can; other SKUs free', async()=>{
  await assert.rejects(order('sales','Kanha',[['Thums Up 250ml',450]]),/OFFER_RATE_FIXED.*443/);
  const o=await order('sales','Kanha',[['Thums Up 250ml',443],['Fanta 1L',90]]);
  await assert.rejects(run('sales','update order_items set rate=440 where order_id=$1 and sku_name=$2',[o,'Thums Up 250ml']),/OFFER_RATE_FIXED/);
  await run('head','update order_items set rate=440 where order_id=$1 and sku_name=$2',[o,'Thums Up 250ml']);
  await order('admin','Kanha',[['Sprite 250ml',400]]);
  await run('acc','update order_items set rate=441 where order_id=$1 and sku_name=$2',[o,'Thums Up 250ml']); // accounts bill change not blocked
  assert.equal((await rates('head','Kanha')).can_change,true);
});

test('one-time offer: fixes the next order only, then it is used', async()=>{
  const a=await save('head',{party_name:'Ram Traders',offer_type:'ONE_TIME',valid_from:day(0),lines:[{item:'250M',rate:435}]});
  assert.equal((await rates('sales','Ram Traders')).rates.length,3);
  const o=await order('sales','Ram Traders',[['Thums Up 250ml',435],['Sprite 250ml',435]]);
  let x=(await list('head')).find(y=>y.offer_no===a.offer_no);
  assert.equal(x.state,'USED');assert.match(x.used_order_no,/^PO-/);
  assert.deepEqual((await rates('sales','Ram Traders')).rates,[]);
  assert.equal((await rates('sales','Ram Traders',o)).rates.length,3); // same order (edit) still sees it
  await order('sales','Ram Traders',[['Thums Up 250ml',460]]);      // next order is free
  await db.query('delete from orders where id=$1',[o]);               // order deleted: offer runs again
  x=(await list('head')).find(y=>y.offer_no===a.offer_no);assert.equal(x.state,'RUNNING');
});

test('newest running offer wins; cancelled offer stops', async()=>{
  await save('head',{party_name:'Shiv',offer_type:'CONTINUOUS',valid_from:day(-5),lines:[{item:'250M',rate:450}]});
  const b=await save('admin',{party_name:'Shiv',offer_type:'CONTINUOUS',valid_from:day(-1),lines:[{item:'250M',rate:445}]});
  assert.equal((await rates('sales','Shiv')).rates.find(x=>x.sku_key==='250M').rate,445);
  await run('admin','select public.lwb_party_rate_offer_cancel($1,$2)',[b.id,'wrong']);
  assert.equal((await rates('sales','Shiv')).rates.find(x=>x.sku_key==='250M').rate,450);
  await assert.rejects(db.query(`select public.lwb_party_offer_rates('Shiv')`).then(()=>run('sales','select * from lwb_party_offer_rate_rows($1)',['Shiv'])),/permission denied/);
});
