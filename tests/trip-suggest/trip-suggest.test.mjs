import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_trip_suggest_setup.sql on a tiny copy of the tables it reads (no live database).
const ids={transport:'00000000-0000-4000-8000-000000000007',sales:'00000000-0000-4000-8000-000000000004',sm1:'00000000-0000-4000-8000-000000000011'};
const db=new PGlite();
const sql=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,customer_name text,status text);
CREATE TABLE public.lwb_customer_master(id uuid default gen_random_uuid() primary key,customer_name text,is_active boolean default true,city text,pincode text,geo_lat double precision,geo_lng double precision);
CREATE TABLE public.lwb_salesmen(user_id uuid primary key,area text);
CREATE TABLE public.lwb_party_salesman(customer_id uuid primary key,salesman_id uuid);
CREATE FUNCTION public.lwb_trip_editor() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active AND p.role IN ('admin','manager','transport')) $$;
CREATE FUNCTION public.lwb_geo_m(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE SET search_path = '' AS $fn$
  SELECT CASE WHEN lat1 IS NULL OR lng1 IS NULL OR lat2 IS NULL OR lng2 IS NULL THEN NULL ELSE
    2 * 6371000 * asin(least(1, sqrt(power(sin(radians(lat2 - lat1) / 2), 2) +
      cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))) END $fn$;
`);
for(const [role,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,role==='sm1'?'sales':role,role==='sm1'?'Harsh':role+' user']);
await db.exec(await sql('lwb_trip_suggest_setup.sql'));
await db.exec(await sql('lwb_trip_suggest_setup.sql')); // safe to run again
await db.exec('GRANT USAGE ON SCHEMA public,auth TO authenticated');
async function as(role){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[role]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const one=async(q,args)=>Object.values((await call(q,args))[0])[0];
const party=async(name,o={})=>(await db.query('insert into lwb_customer_master(customer_name,city,pincode,geo_lat,geo_lng) values($1,$2,$3,$4,$5) returning id',[name,o.city||null,o.pin||null,o.lat??null,o.lng??null])).rows[0].id;
const order=async(no,name)=>(await db.query("insert into orders(order_no,customer_name,status) values($1,$2,'approved') returning id",[no,name])).rows[0].id;

test('area guess: name bracket, GPS neighbour, pincode, city, salesman; saved wins',async()=>{
  const a=await party('NILKANTH ENTERPRISE (VARACHHA)',{lat:21.2100,lng:72.8600,pin:'395006'});
  const b=await party('KEVAL RAJ',{lat:21.2120,lng:72.8620});           // ~300 m from Nilkanth
  const c=await party('OM SAI',{pin:'395006'});
  const d=await party('JAY AMBE',{city:'Bardoli'});
  const e=await party('FAUNTAIN',{city:'Surat'});
  const f=await party('NAVKAR (1)');
  await db.query("insert into lwb_salesmen values($1,' new   city ')",[ids.sm1]);
  await db.query('insert into lwb_party_salesman values($1,$2)',[e,ids.sm1]);
  const g=async id=>(await db.query('select public.lwb_party_area_guess($1) g',[id])).rows[0].g;
  assert.deepEqual(await g(a),{area:'Varachha',src:'NAME'});
  assert.deepEqual(await g(b),{area:'Varachha',src:'GPS'});
  assert.equal((await g(c)).src,'PINCODE');
  assert.deepEqual(await g(d),{area:'Bardoli',src:'CITY'});
  assert.deepEqual(await g(e),{area:'New City',src:'SALESMAN',salesman:'Harsh'});
  assert.equal((await g(f)).area,null);
  await db.query("update lwb_customer_master set area='Rachna' where id=$1",[b]);
  assert.deepEqual(await g(b),{area:'Rachna',src:'SAVED'});
});

test('only Admin / Manager / Transport; suggest data per PO; list + save areas',async()=>{
  const o1=await order('LXY-1','nilkanth enterprise (varachha) ');
  const o2=await order('LXY-2','UNKNOWN PARTY');
  await as('sales');
  await assert.rejects(call('select public.lwb_trip_suggest_data($1)',[[o1]]),/Only Admin/);
  await assert.rejects(call('select public.lwb_party_area_save($1::jsonb)',['[]']),/Only Admin/);
  await as('transport');
  const d=await one('select public.lwb_trip_suggest_data($1)',[[o1,o2]]);
  const r1=d.find(x=>x.order_id===o1),r2=d.find(x=>x.order_id===o2);
  assert.equal(r1.area,'Varachha');assert.equal(r1.lat,21.21);assert.equal(r2.party_id,null);assert.equal(r2.area,null);
  let L=await one('select public.lwb_party_area_list(true)');
  assert.equal(L.total,6);assert.equal(L.missing,5);
  assert.ok(L.areas.includes('New City')&&L.areas.includes('Rachna'));
  const fau=L.rows.find(x=>x.name==='FAUNTAIN'),nav=L.rows.find(x=>x.name==='NAVKAR (1)');
  assert.equal(fau.area,'New City');assert.equal(nav.area,null);
  const n=await one('select public.lwb_party_area_save($1::jsonb)',[JSON.stringify([{id:fau.id,area:'  new city'},{id:nav.id,area:'limbayat'}])]);
  assert.equal(n,2);
  L=await one('select public.lwb_party_area_list(true)');assert.equal(L.missing,3);
  assert.equal((await one('select public.lwb_party_area_save($1::jsonb)',[JSON.stringify([{id:fau.id,area:'New City'}])])),0);
  L=await one('select public.lwb_party_area_list(false)');assert.equal(L.rows.find(x=>x.name==='NAVKAR (1)').saved,'Limbayat');
});

test('page grouping: same area or GPS within 3 km together, packed up to vehicle size, far party alone',async()=>{
  const g={};new Function('window','document',await sql('trip-suggest.js'))(g,{});
  const it=(id,kg,area,lat,lng,sm)=>({id,order_no:id,party:'P'+id,kg,area,lat,lng,sm_area:sm||null});
  const items=[it('a',765,'Yogi Chowk',21.21,72.88),it('b',836,null,21.212,72.882),     // b: no area, 300 m from a
    it('c',1042,'Varachha',null,null,'Varachha'),it('d',443,'Varachha'),it('e',341,'Varachha'),
    it('f',1287,'Saroli',21.20,72.70),it('g',0,null,null,null)];                          // f ~19 km away; g unknown
  const vehicles=[{vehicle_no:'GJ05PT3321',capacity_kg:1700},{vehicle_no:'GJ05BIG',capacity_kg:3000},{vehicle_no:'GJ05BUSY',capacity_kg:1700,on_trip:['X']}];
  const r=g.LWBSuggest.group(items,{mode:'area',cap:1700,vehicles});
  const by=n=>r.trips.filter(t=>t.name===n);
  assert.deepEqual(by('Yogi Chowk').map(t=>t.items.map(x=>x.id).sort()),[['a','b']]);
  const v=by('Varachha');assert.equal(v.length,2);assert.ok(v.every(t=>t.kg<=1700));
  assert.equal(by('Saroli')[0].items.length,1);assert.ok(by('Saroli')[0].near>15);
  assert.deepEqual(r.unknown.map(x=>x.id),['g']);
  assert.ok(r.trips.every(t=>!t.vehicle||t.vehicle.vehicle_no!=='GJ05BUSY'));
  assert.equal(new Set(r.trips.filter(t=>t.vehicle).map(t=>t.vehicle.vehicle_no)).size,r.trips.filter(t=>t.vehicle).length);
  const big=g.LWBSuggest.group(items,{mode:'area',cap:3000,vehicles});assert.equal(big.trips.filter(t=>t.name==='Varachha').length,1);
  // neighbouring areas share a vehicle only while it fits; no chaining across the city
  const nb=[it('n1',500,'Varachha',21.207,72.861),it('n2',400,'Nana Varachha',21.215,72.866),it('n3',900,'Rachna',21.204,72.856),it('n4',300,'Kapodra',21.225,72.880)];
  const r2=g.LWBSuggest.group(nb,{mode:'area',cap:1700});
  assert.ok(r2.trips.every(t=>t.kg<=1700));assert.ok(r2.trips.some(t=>t.items.length>1));
  assert.ok(!r2.trips.some(t=>t.items.length===4));
  const sm=g.LWBSuggest.group(items,{mode:'salesman',cap:3000});assert.equal(sm.trips.find(t=>t.items.some(x=>x.id==='a')).items.length,1);
});
