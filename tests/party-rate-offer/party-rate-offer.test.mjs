import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_rate_offer_setup.sql on an empty PGlite database (no live data).
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',head2:'00000000-0000-4000-8000-000000000003',sales:'00000000-0000-4000-8000-000000000004'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,r] of [['admin','admin'],['head','manager'],['head2','manager'],['sales','sales']])await db.query('insert into user_profiles values($1,$2,true,$3)',[ids[k],r,k.toUpperCase()]);
const read=f=>readFile(new URL('../../'+f,import.meta.url),'utf8');
await db.exec(await read('lwb_rate_scheme_setup.sql'));
const sql=await read('lwb_party_rate_offer_setup.sql');
await db.exec(sql);await db.exec(sql); // safe to run again
async function run(who,q,p){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]]);await db.exec('SET ROLE authenticated');try{return await db.query(q,p)}finally{await db.exec('RESET ROLE')}}
const save=(who,o)=>run(who,'select public.lwb_party_rate_offer_save($1) r',[JSON.stringify(o)]).then(r=>r.rows[0].r);

test('save an offer like a PO: party + items + rate per case, numbered RO-DDMM-NN', async()=>{
  const a=await save('head',{party_name:'Shree Ram Traders',offer_date:'2026-11-10',lines:[
    {item:'2.25L',rate:650},{item:'150ml Tetra',rate:265},{item:'250ml Maaza',rate:465},{item:'850ml Maaza',rate:580},{item:'1L Kinley',rate:165}]});
  assert.equal(a.offer_no,'RO-1011-01');
  const b=await save('admin',{party_name:'shree  ram traders ',offer_date:'2026-11-10',lines:[{item:'2.25L',rate:640}]});
  assert.equal(b.offer_no,'RO-1011-02');
  const list=(await run('admin',`select public.lwb_party_rate_offer_list(3650,'SHREE RAM TRADERS') l`)).rows[0].l;
  assert.equal(list.length,2);
  assert.equal(list[1].lines.length,5);assert.equal(list[1].by,'HEAD');
  assert.deepEqual(list[1].lines[0],{item:'2.25L',rate:650,note:null});
});

test('(i) history: past rates of one item for one party with the change, last rates for a new offer', async()=>{
  await save('head',{party_name:'Shree Ram Traders',offer_date:'2026-11-16',lines:[{item:'2.25 l'.replace(' l','L'),rate:655},{item:'1L Kinley',rate:160}]});
  const h=(await run('head',`select public.lwb_party_rate_history('Shree Ram Traders','2.25L') h`)).rows[0].h;
  assert.deepEqual(h.map(x=>[x.offer_date,x.rate,x.change,x.by]),[['2026-11-16',655,15,'HEAD'],['2026-11-10',640,-10,'ADMIN'],['2026-11-10',650,null,'HEAD']]);
  const last=(await run('head',`select public.lwb_party_rate_last('Shree Ram Traders') l`)).rows[0].l;
  const m=Object.fromEntries(last.map(x=>[x.item_key,x.rate]));
  assert.deepEqual(m,{'2.25L':655,'150ML TETRA':265,'250ML MAAZA':465,'850ML MAAZA':580,'1L KINLEY':160});
  // other party sees nothing of this one
  assert.deepEqual((await run('head',`select public.lwb_party_rate_last('Other Party') l`)).rows[0].l,[]);
});

test('cancel: maker or Admin only, with a reason; cancelled rate leaves "last rate"', async()=>{
  const id=(await db.query(`select id from lwb_party_rate_offers where offer_date='2026-11-16'`)).rows[0].id;
  await assert.rejects(run('head2','select public.lwb_party_rate_offer_cancel($1,$2)',[id,'x']),/person who made it/);
  await assert.rejects(run('head','select public.lwb_party_rate_offer_cancel($1,$2)',[id,' ']),/why/);
  assert.equal((await run('head','select public.lwb_party_rate_offer_cancel($1,$2) r',[id,'wrong party'])).rows[0].r,true);
  const last=(await run('head',`select public.lwb_party_rate_last('Shree Ram Traders') l`)).rows[0].l;
  assert.equal(last.find(x=>x.item_key==='2.25L').rate,640);
  const h=(await run('head',`select public.lwb_party_rate_history('Shree Ram Traders','2.25L') h`)).rows[0].h;
  assert.equal(h[0].status,'CANCELLED');assert.equal(h[0].change,null);
});

test('checks: Admin / Sales Head only, no direct table access, bad lines refused', async()=>{
  await assert.rejects(save('sales',{party_name:'X',lines:[{item:'2.25L',rate:1}]}),/Only Admin or Sales Head/);
  await assert.rejects(run('sales',`select public.lwb_party_rate_history('X','Y')`),/Only Admin or Sales Head/);
  await assert.rejects(run('head','select * from lwb_party_rate_offers'),/permission denied/);
  await assert.rejects(run('head','insert into lwb_party_rate_offer_lines(offer_id,line_no,item,item_key,rate) values(1,9,$1,$1,1)',['A']),/permission denied/);
  await assert.rejects(save('head',{party_name:'',lines:[{item:'A',rate:1}]}),/Pick the party/);
  await assert.rejects(save('head',{party_name:'X',lines:[]}),/at least one/);
  await assert.rejects(save('head',{party_name:'X',lines:[{item:'A',rate:''}]}),/Enter the rate/);
  await assert.rejects(save('head',{party_name:'X',lines:[{item:'A',rate:1},{item:' a ',rate:2}]}),/added twice/);
});
