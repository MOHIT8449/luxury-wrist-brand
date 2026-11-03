import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

const ids={admin:'00000000-0000-4000-8000-000000000001',manager:'00000000-0000-4000-8000-000000000002',sales:'00000000-0000-4000-8000-000000000003',sales2:'00000000-0000-4000-8000-000000000004',warehouse:'00000000-0000-4000-8000-000000000005',inactive:'00000000-0000-4000-8000-000000000006'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid,role text,active boolean,full_name text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key);
GRANT USAGE ON SCHEMA public,auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,$3,$4)',[id,k==='inactive'?'manager':k.replace(/\d$/,''),k!=='inactive',k.toUpperCase()]);
await db.exec(await readFile(new URL('../../lwb_po_draft_setup.sql',import.meta.url),'utf8'));
await db.exec(await readFile(new URL('../../lwb_po_draft_setup.sql',import.meta.url),'utf8')); // safe to run again
async function as(who,sql,params=[]){
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||'']);
 await db.exec('SET ROLE authenticated');
 try{return (await db.query(sql,params)).rows}finally{await db.exec('RESET ROLE')}
}
const add=(who,party)=>as(who,"insert into lwb_po_drafts(customer_name,line_count,total_amount,data,created_by,created_by_name) values($1,2,1000,$2,$3,'FAKE') returning *",[party,JSON.stringify({customer:party,items:[]}),ids.admin]);

test('saver and names are set by the server, not the browser',async()=>{
 const [d]=await add('sales','PARTY A');
 assert.equal(d.created_by,ids.sales);assert.equal(d.created_by_name,'SALES');assert.equal(d.updated_by_name,'SALES');
});
test('salesman sees and changes only his own drafts; Admin / Sales Head see all',async()=>{
 await add('sales2','PARTY B');
 assert.deepEqual((await as('sales','select customer_name from lwb_po_drafts order by 1')).map(r=>r.customer_name),['PARTY A']);
 assert.equal((await as('manager','select * from lwb_po_drafts')).length,2);
 assert.equal((await as('admin','select * from lwb_po_drafts')).length,2);
 assert.equal((await as('sales',"update lwb_po_drafts set customer_name='X' where customer_name='PARTY B' returning id")).length,0);
 assert.equal((await as('sales',"delete from lwb_po_drafts where customer_name='PARTY B' returning id")).length,0);
});
test('Sales Head edits a salesman draft: saver kept, editor stamped',async()=>{
 const [r]=await as('manager',"update lwb_po_drafts set total_amount=2000,created_by=$1 where customer_name='PARTY A' returning *",[ids.manager]);
 assert.equal(r.created_by,ids.sales);assert.equal(r.created_by_name,'SALES');assert.equal(r.updated_by_name,'MANAGER');assert.equal(Number(r.total_amount),2000);
});
test('warehouse, inactive and logged-out logins cannot add or read drafts',async()=>{
 for(const who of ['warehouse','inactive','none']){
  await assert.rejects(add(who,'PARTY Z'));
  assert.equal((await as(who,'select * from lwb_po_drafts')).length,0);
 }
});
test('a draft is not an order and can be deleted by its saver',async()=>{
 assert.equal((await db.query('select count(*)::int n from orders')).rows[0].n,0);
 assert.equal((await as('sales',"delete from lwb_po_drafts where customer_name='PARTY A' returning id")).length,1);
});
