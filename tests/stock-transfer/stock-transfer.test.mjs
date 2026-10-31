import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_stock_transfer_setup.sql on an empty PGlite database (no live database).
// lwb_live_stock here is a stand-in view over a small table, like the live view.
const ids={admin:'00000000-0000-4000-8000-000000000001',head:'00000000-0000-4000-8000-000000000002',
  head2:'00000000-0000-4000-8000-000000000009',godown:'00000000-0000-4000-8000-000000000003',
  acc:'00000000-0000-4000-8000-000000000004',sales:'00000000-0000-4000-8000-000000000005',
  driver:'00000000-0000-4000-8000-000000000007'};
const roles={admin:'admin',head:'manager',head2:'manager',godown:'warehouse',acc:'accounts',sales:'sales',driver:'driver'};
const sku={thums:'10000000-0000-4000-8000-000000000001',sprite:'10000000-0000-4000-8000-000000000002'};
const db=new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text);
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text,order_id uuid,is_read boolean not null default false,created_at timestamptz default now());
CREATE TABLE public.lwb_user_page_access(user_id uuid,extra text[]);
CREATE FUNCTION public.lwb_has_page(p text) RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS(SELECT 1 FROM public.lwb_user_page_access a WHERE a.user_id=auth.uid() AND p=ANY(a.extra)) $$;
CREATE TABLE public.sku_master(id uuid primary key,sku_name text,pcs_per_case int,is_active boolean default true);
CREATE TABLE public.stock_now(sku_id uuid,saleable_pcs bigint,damaged_pcs bigint);
CREATE VIEW public.lwb_live_stock AS SELECT s.id AS sku_id,s.sku_name,s.pcs_per_case,coalesce(n.saleable_pcs,0) AS saleable_pcs,coalesce(n.damaged_pcs,0) AS damaged_pcs
  FROM public.sku_master s LEFT JOIN public.stock_now n ON n.sku_id=s.id;
GRANT SELECT ON public.lwb_live_stock TO authenticated;
CREATE TABLE public.lwb_goods_inward(id uuid primary key,received_date date);
CREATE TABLE public.lwb_goods_inward_items(id bigserial primary key,inward_id uuid,sku_id uuid,cases int,pcs int);
CREATE TABLE public.orders(id uuid primary key,status text);
CREATE TABLE public.order_items(id bigserial primary key,order_id uuid,loaded_qty numeric);
CREATE TABLE public.dispatch_assignments(id bigserial primary key,order_id uuid,loading_completed_at timestamptz);
GRANT USAGE ON SCHEMA public, auth TO authenticated;
`);
for(const [k,id] of Object.entries(ids))await db.query('insert into user_profiles values($1,$2,true,$3)',[id,roles[k].toUpperCase(),'Name '+k]);
await db.query("insert into sku_master values($1,'250ML THUMSUP',24,true),($2,'600ML SPRITE',24,true)",[sku.thums,sku.sprite]);
await db.query('insert into stock_now values($1,2400,0),($2,480,10)',[sku.thums,sku.sprite]); // 100 CS, 20 CS

const setup=await readFile(new URL('../../lwb_stock_transfer_setup.sql',import.meta.url),'utf8');
await db.exec(setup);
await db.exec(setup); // safe to run again

async function as(who){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[who]||''])}
async function call(q,args=[]){await db.exec('SET ROLE authenticated');try{return (await db.query(q,args)).rows}finally{await db.exec('RESET ROLE')}}
const live=async()=>{await as('sales');return Object.fromEntries((await call('select sku_id,saleable_pcs::int s,damaged_pcs::int d from lwb_live_stock')).map(r=>[r.sku_id,r]))};
const status=async(who='admin')=>{await as(who);return Object.fromEntries((await call('select * from lwb_stx_status()')).map(r=>[r.sku_id,r]))};
const ask=async(who,p)=>{await as(who);return (await call('select lwb_stx_request($1) r',[p]))[0].r};
const decide=async(who,idList,act,note=null,qty=null)=>{await as(who);return (await call('select lwb_stx_decide($1,$2,$3,$4) n',[idList,act,note,qty]))[0].n};
const bells=async(who)=>(await db.query('select title,message,notification_type t from erp_notifications where user_id=$1 order by id',[ids[who]])).rows;
const today=async()=>(await db.query("select to_char(public.lwb_stx_today(),'YYYY-MM-DD') d")).rows[0].d;

test('live stock view is wrapped, same columns, other roles still read it', async()=>{
  const v=(await db.query("select obj_description('public.lwb_live_stock'::regclass,'pg_class') c")).rows[0].c;
  assert.match(v,/^LWB stock-transfer wrapper/);
  const cols=(await db.query("select attname from pg_attribute where attrelid='public.lwb_live_stock'::regclass and attnum>0 order by attnum")).rows.map(r=>r.attname);
  assert.deepEqual(cols,['sku_id','sku_name','pcs_per_case','saleable_pcs','damaged_pcs']);
  const l=await live();
  assert.equal(l[sku.thums].s,2400);assert.equal(l[sku.sprite].d,10);
});

test('Godown asks Saleable -> Leakage: saleable does not move until Sales Head approves', async()=>{
  const r=await ask('godown',{from_bucket:'SALEABLE',to_bucket:'LEAKAGE',reason:'Cap leak in stack 3',lines:[{sku_id:sku.thums,cases:2,pcs:6}]});
  assert.equal(r.kind,'TRANSFER');
  const id=Number(r.ids[0]);
  assert.equal((await live())[sku.thums].s,2400);
  let st=(await status())[sku.thums];
  assert.equal(Number(st.pending_out_pcs),54);
  const hb=await bells('head');
  assert.equal(hb.at(-1).t,'STOCK_MOVE_PENDING');
  assert.match(hb.at(-1).title,/Saleable → Leakage/);
  assert.equal((await bells('godown')).length,0);
  // Godown cannot approve, Accounts cannot approve
  await as('godown');await assert.rejects(call('select lwb_stx_decide($1,$2,null,null)',[[id],'APPROVE']),/Sales Head or Admin/);
  await as('acc');await assert.rejects(call('select lwb_stx_decide($1,$2,null,null)',[[id],'APPROVE']),/Sales Head or Admin/);
  assert.equal(await decide('head',[id],'APPROVE'),1);
  const l=await live();
  assert.equal(l[sku.thums].s,2346);
  assert.equal(l[sku.thums].d,54);
  st=(await status())[sku.thums];
  assert.equal(Number(st.leakage_pcs),54);assert.equal(Number(st.pending_out_pcs),0);
  assert.equal((await bells('godown')).at(-1).t,'STOCK_MOVE_APPROVED');
});

test('cannot ask more than saleable minus waiting requests; reject needs a reason', async()=>{
  const r=await ask('godown',{from_bucket:'SALEABLE',to_bucket:'DAMAGE',reason:'Forklift',lines:[{sku_id:sku.sprite,cases:15}]});
  await assert.rejects(ask('godown',{from_bucket:'SALEABLE',to_bucket:'BREAKAGE',reason:'x',lines:[{sku_id:sku.sprite,cases:6}]}),/only 5 CS 0 PCS in Saleable/);
  await assert.rejects(decide('head',r.ids,'REJECT'),/reason for rejecting/);
  assert.equal(await decide('head',r.ids,'REJECT','Recount please'),1);
  assert.equal((await live())[sku.sprite].s,480);
  assert.equal((await bells('godown')).at(-1).t,'STOCK_MOVE_REJECTED');
});

test('Sales Head cannot approve own request, Admin can approve own; approve less than asked', async()=>{
  const r=await ask('head',{from_bucket:'SALEABLE',to_bucket:'EXPIRY',reason:'Expired batch',lines:[{sku_id:sku.sprite,cases:2,batch_no:'B12',expiry_date:'2026-10-01'}]});
  await assert.rejects(decide('head',r.ids,'APPROVE'),/Admin or another Sales Head/);
  assert.equal(await decide('head2',r.ids,'APPROVE',null,{[r.ids[0]]:24}),1);
  const m=(await db.query('select qty_pcs,requested_pcs,decision_note,batch_no from lwb_stock_moves where id=$1',[r.ids[0]])).rows[0];
  assert.deepEqual([m.qty_pcs,m.requested_pcs,m.batch_no],[24,48,'B12']);
  const a=await ask('admin',{from_bucket:'SALEABLE',to_bucket:'GASLESS',reason:'Flat',lines:[{sku_id:sku.sprite,pcs:12}]});
  assert.equal(await decide('admin',a.ids,'APPROVE'),1);
  const st=(await status())[sku.sprite];
  assert.equal(Number(st.saleable_pcs),480-24-12);
  assert.equal(Number(st.expiry_pcs),24);assert.equal(Number(st.gasless_pcs),12);
});

test('destroy from Leakage needs a witness and approval, reduces the category; not more than held', async()=>{
  await assert.rejects(ask('godown',{from_bucket:'LEAKAGE',to_bucket:'DESTROYED',reason:'Monthly destroy',lines:[{sku_id:sku.thums,cases:1}]}),/witness/);
  await assert.rejects(ask('godown',{from_bucket:'LEAKAGE',to_bucket:'DESTROYED',reason:'Monthly destroy',witness:'Ramesh',lines:[{sku_id:sku.thums,cases:3}]}),/only 2 CS 6 PCS in Leakage/);
  await assert.rejects(ask('godown',{from_bucket:'SALEABLE',to_bucket:'DESTROYED',reason:'x',witness:'R',lines:[{sku_id:sku.thums,cases:1}]}),/not allowed/);
  const r=await ask('godown',{from_bucket:'LEAKAGE',to_bucket:'DESTROYED',reason:'Monthly destroy',witness:'Ramesh',method:'Crushed',lines:[{sku_id:sku.thums,cases:2}]});
  assert.equal(r.kind,'DESTROY');
  await decide('admin',r.ids,'APPROVE');
  const st=(await status())[sku.thums];
  assert.equal(Number(st.leakage_pcs),6);assert.equal(Number(st.destroyed_pcs),48);
  assert.equal((await live())[sku.thums].d,6);
  assert.equal((await live())[sku.thums].s,2346);
});

test('category ledger shows running balance and opening', async()=>{
  await as('acc');
  const rows=await call("select move_id,kind,in_pcs::int i,out_pcs::int o,balance_pcs::int b from lwb_stx_ledger('LEAKAGE',null,null,$1)",[sku.thums]);
  assert.deepEqual(rows.map(r=>[r.kind,r.i,r.o,r.b]),[['TRANSFER',54,0,54],['DESTROY',0,48,6]]);
  const t=await today();
  const op=await call("select move_id,kind,balance_pcs::int b from lwb_stx_ledger('LEAKAGE',($1::date+1),null,$2)",[t,sku.thums]);
  assert.deepEqual(op.map(r=>[r.move_id,r.kind,r.b]),[[null,'OPENING',6]]);
});

test('night audit: 100 vs 99 opens a difference; next night carries it; Found closes it', async()=>{
  const t=await today();
  await as('godown');
  // Thums system now 2346 pcs = 97 CS 18 PCS. Count 1 case less.
  let res=(await call('select lwb_stx_audit_save($1,$2,false,$3) r',[t,[{sku_id:sku.thums,physical_pcs:2322}],'Night count']))[0].r;
  assert.equal(res.submitted,false);
  let sheet=await call('select * from lwb_stx_audit_sheet($1)',[t]);
  assert.equal(sheet.find(x=>x.sku_id===sku.thums).physical_pcs,2322);
  res=(await call('select lwb_stx_audit_save($1,$2,true,null) r',[t,[{sku_id:sku.thums,physical_pcs:2322},{sku_id:sku.sprite,physical_pcs:444}]]))[0].r;
  assert.deepEqual([res.skus,res.diff_skus,res.short_pcs,res.excess_pcs],[2,1,24,0]);
  assert.equal((await bells('head')).at(-1).t,'STOCK_AUDIT_DIFF');
  await assert.rejects(call('select lwb_stx_audit_save($1,$2,true,null)',[t,[]]),/already submitted/);
  let d=await call('select * from lwb_stx_audit_diffs(false)');
  assert.equal(d.length,1);assert.equal(d[0].diff_pcs,-24);assert.equal(d[0].status,'OPEN');
  assert.equal(Number((await status())[sku.thums].open_short_pcs),24);
  // Stock did not change because of the audit.
  assert.equal((await live())[sku.thums].s,2346);
  // Next night (yesterday's audit is re-dated so the test has two dates): still 1 case short -> carried.
  await db.query("update lwb_stock_audits set audit_date=audit_date-1");
  await db.query("update lwb_stock_audit_lines set open_since=open_since-1");
  await as('godown');
  await call('select lwb_stx_audit_save($1,$2,true,null)',[t,[{sku_id:sku.thums,physical_pcs:2322}]]);
  d=await call('select * from lwb_stx_audit_diffs(true)');
  const open=d.filter(x=>x.status==='OPEN'),old=d.find(x=>x.status==='RECOUNTED');
  assert.equal(open.length,1);assert.ok(old);
  assert.equal(open[0].days_open,1);
  await assert.rejects(call('select lwb_stx_audit_resolve($1,$2,null)',[open[0].line_id,'FOUND']),/where it was found/);
  await as('sales');
  await assert.rejects(call('select lwb_stx_audit_resolve($1,$2,$3)',[open[0].line_id,'FOUND','x']),/Godown Manager, Sales Head or Admin|Night audit/);
  await as('godown');
  assert.equal((await call('select lwb_stx_audit_resolve($1,$2,$3) r',[open[0].line_id,'FOUND','Behind pallet row 4']))[0].r.status,'FOUND');
  assert.equal((await call('select * from lwb_stx_audit_diffs(false)')).length,0);
});

test('audit shortage not found -> Loss request; on approval saleable drops and difference closes', async()=>{
  const t=await today();
  await db.query("update lwb_stock_audits set audit_date=audit_date-1"); // free today's date
  await as('godown');
  await call('select lwb_stx_audit_save($1,$2,true,null)',[t,[{sku_id:sku.sprite,physical_pcs:440}]]); // system 444 -> short 4 pcs
  const [line]=await call('select * from lwb_stx_audit_diffs(false)');
  assert.equal(line.diff_pcs,-4);
  const r=(await call('select lwb_stx_audit_resolve($1,$2,$3) r',[line.line_id,'LOSS','Not found after 2 days']))[0].r;
  assert.equal(r.status,'LOSS_PENDING');
  // A recount while the loss waits for approval does not double count it.
  const sheet=(await call('select * from lwb_stx_audit_sheet($1)',[t])).find(x=>x.sku_id===sku.sprite);
  assert.equal(Number(sheet.system_pcs),444);
  await decide('head',[Number(r.move_id)],'APPROVE');
  const st=(await status())[sku.sprite];
  assert.equal(Number(st.saleable_pcs),440);assert.equal(Number(st.loss_pcs),4);
  assert.equal((await db.query('select status from lwb_stock_audit_lines where id=$1',[line.line_id])).rows[0].status,'LOSS');
  // Loss found later -> back to saleable (approval again)
  const b=await ask('godown',{from_bucket:'LOSS',to_bucket:'SALEABLE',reason:'Found in old godown',lines:[{sku_id:sku.sprite,pcs:4}]});
  assert.equal(b.kind,'TO_SALEABLE');
  await decide('admin',b.ids,'APPROVE');
  assert.equal((await live())[sku.sprite].s,444);
});

test('rejecting an audit loss reopens the difference; cancel own request', async()=>{
  const t=await today();
  await db.query("update lwb_stock_audits set audit_date=audit_date-1");
  await as('godown');
  await call('select lwb_stx_audit_save($1,$2,true,null)',[t,[{sku_id:sku.sprite,physical_pcs:420}]]);
  const [line]=await call('select * from lwb_stx_audit_diffs(false)');
  const r=(await call('select lwb_stx_audit_resolve($1,$2,null) r',[line.line_id,'LOSS']))[0].r;
  await decide('head',[Number(r.move_id)],'REJECT','Search again');
  assert.equal((await db.query('select status from lwb_stock_audit_lines where id=$1',[line.line_id])).rows[0].status,'OPEN');
  await as('godown');
  const r2=(await call('select lwb_stx_audit_resolve($1,$2,null) r',[line.line_id,'LOSS']))[0].r;
  await as('godown');
  assert.equal((await call('select lwb_stx_cancel($1) n',[[Number(r2.move_id)]]))[0].n,1);
  assert.equal((await db.query('select status from lwb_stock_audit_lines where id=$1',[line.line_id])).rows[0].status,'OPEN');
});

test('daily report: handled cases, transfers, loss per 1000', async()=>{
  const t=await today();
  await db.query("insert into lwb_goods_inward values('20000000-0000-4000-8000-000000000001',$1)",[t]);
  await db.query("insert into lwb_goods_inward_items(inward_id,sku_id,cases,pcs) values('20000000-0000-4000-8000-000000000001',$1,3000,0)",[sku.thums]);
  await db.query("insert into orders values('30000000-0000-4000-8000-000000000001','loaded'),('30000000-0000-4000-8000-000000000002','cancelled')");
  await db.query("insert into order_items(order_id,loaded_qty) values('30000000-0000-4000-8000-000000000001',1000),('30000000-0000-4000-8000-000000000002',500)");
  await db.query("insert into dispatch_assignments(order_id,loading_completed_at) values('30000000-0000-4000-8000-000000000001',now()),('30000000-0000-4000-8000-000000000002',now())");
  await as('acc');
  const [r]=await call('select * from lwb_stx_daily($1,$1)',[t]);
  assert.equal(Number(r.inward_cases),3000);assert.equal(Number(r.loaded_cases),1000);assert.equal(Number(r.handled_cases),4000);
  assert.equal(Number(r.leakage_cases),2.25);assert.equal(Number(r.loss_cases),0.17);
  assert.equal(Number(r.destroyed_cases),2);
  assert.equal(r.audit_status,'SUBMITTED');
  assert.equal(Number(r.loss_per_1000),0.04);
});

test('salesman, driver and transport have no access; ticked page gives access', async()=>{
  for(const who of ['sales','driver']){
    await as(who);
    await assert.rejects(call('select * from lwb_stx_status()'),/Admin, Sales Head, Godown Manager or Accounts only/);
    await assert.rejects(call('select * from lwb_stx_moves(null,null,null)'),/only/);
    await assert.rejects(call("select lwb_stx_request($1)",[{from_bucket:'SALEABLE',to_bucket:'LOSS',reason:'x',lines:[{sku_id:sku.thums,cases:1}]}]),/Only Godown Manager/);
    await assert.rejects(call('select * from lwb_stock_moves'),/permission denied/);
  }
  await as('acc');
  await assert.rejects(call("select lwb_stx_request($1)",[{from_bucket:'SALEABLE',to_bucket:'LOSS',reason:'x',lines:[{sku_id:sku.thums,cases:1}]}]),/Only Godown Manager/);
  await db.query('insert into lwb_user_page_access values($1,$2)',[ids.sales,['stock-audit.html']]);
  await as('sales');
  assert.ok((await call('select * from lwb_stx_status()')).length>0);
});

test('re-running the setup keeps the link and the numbers', async()=>{
  const before=await live();
  await db.exec(setup);
  assert.deepEqual(await live(),before);
  assert.ok((await db.query("select to_regclass('public.lwb_live_stock_base') r")).rows[0].r);
});
