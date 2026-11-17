import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_party_rate_history_setup.sql on an empty PGlite database. Rights helpers are stubs here.
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz,created_at timestamptz default now(),customer_name text,status text);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,sku_name text,ordered_qty numeric,rate numeric);
CREATE TABLE public.t_flags(entry boolean,mine text[]);INSERT INTO public.t_flags VALUES(true,NULL);
CREATE FUNCTION public.lwb_po_entry_user() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT entry FROM public.t_flags $$;
CREATE FUNCTION public.lwb_party_name_visible(p text) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT mine IS NULL OR upper(btrim(p))=ANY(mine) FROM public.t_flags $$;
`);
const sql=await readFile(new URL('../../lwb_party_rate_history_setup.sql',import.meta.url),'utf8');
await db.exec(sql);await db.exec(sql); // safe to run again
async function po(no,day,party,status,lines){
  const id=(await db.query(`insert into orders(order_no,order_date,customer_name,status) values($1,$2,$3,$4) returning id`,[no,'2026-11-'+day+'T10:00:00+05:30',party,status])).rows[0].id;
  for(const [s,q,r] of lines)await db.query(`insert into order_items(order_id,sku_name,ordered_qty,rate) values($1,$2,$3,$4)`,[id,s,q,r]);
}
const hist=async(p,s)=>(await db.query('select public.lwb_party_sku_rate_history($1,$2) h',[p,s])).rows[0].h;

test('last 5 rates of one item for one party, newest first', async()=>{
  for(let d=1;d<=7;d++)await po('P'+d,String(d).padStart(2,'0'),'RAJ STORES','approved',[['1.25L SPRITE',10*d,600+d],['250ML COKE',5,465]]);
  await po('PX','08','RAJ STORES','cancelled',[['1.25L SPRITE',50,500]]);   // cancelled: left out
  await po('PZ','09','RAJ STORES','approved',[['1.25L SPRITE',0,500]]);     // no cases: left out
  await po('PO','09','OTHER PARTY','approved',[['1.25L SPRITE',10,590]]);   // other party
  const h=await hist(' raj stores ','1.25l sprite');
  assert.deepEqual(h.map(x=>[x.order_no,+x.qty,+x.rate]),[['P7',70,607],['P6',60,606],['P5',50,605],['P4',40,604],['P3',30,603]]);
  assert.deepEqual(await hist('RAJ STORES','300ML THUMS UP'),[]);
  assert.deepEqual(await hist('','1.25L SPRITE'),[]);
});

test('salesman only for his own parties; other logins refused', async()=>{
  await db.query(`update t_flags set mine=array['OTHER PARTY']`);
  assert.deepEqual(await hist('RAJ STORES','1.25L SPRITE'),[]);
  assert.equal((await hist('OTHER PARTY','1.25L SPRITE')).length,1);
  await db.query(`update t_flags set entry=false`);
  await assert.rejects(hist('OTHER PARTY','1.25L SPRITE'),/Only Admin, Manager or Salesman/);
});
