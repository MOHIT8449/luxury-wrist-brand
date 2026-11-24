import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {initWasm, Resvg} from '@resvg/resvg-wasm';
import {PDFDocument, rgb} from 'pdf-lib';
import fontkit from '@pdf-lib/fontkit';
import {renderSvg, pages, buildPdf, renderPage, PAGE_PX} from '../../supabase/functions/lwb-daily-whatsapp/render.mjs';

// lwb_daily_whatsapp_setup.sql on a tiny copy of the tables it reads (no live database).
// Builds the 6 reports for one day, checks the numbers, who gets what, focus-party tasks,
// never-twice sending, and draws every report to PNG (OUT=dir to keep the images).
const U = {
  admin:'00000000-0000-4000-8000-000000000001', head:'00000000-0000-4000-8000-000000000002',
  nadim:'00000000-0000-4000-8000-000000000003', suresh:'00000000-0000-4000-8000-000000000004',
  dinesh:'00000000-0000-4000-8000-000000000005', acc:'00000000-0000-4000-8000-000000000006',
  godown:'00000000-0000-4000-8000-000000000007', driver:'00000000-0000-4000-8000-000000000008'};
const COKE='10000000-0000-4000-8000-000000000001', RAJ='10000000-0000-4000-8000-000000000002';
const db = new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE SCHEMA extensions;
CREATE FUNCTION extensions.gen_random_bytes(n int) RETURNS bytea LANGUAGE sql AS $$ SELECT decode(md5(random()::text) || md5(random()::text), 'hex') $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.lwb_companies(id uuid primary key,name text,pack_unit text);
CREATE TABLE public.sku_master(sku_name text,company_id uuid,pack_unit text);
CREATE TABLE public.orders(id uuid default gen_random_uuid() primary key,order_no text,order_date timestamptz,customer_name text,transportation text,
  sales_person text,status text,total_qty numeric,total_amount numeric,total_weight numeric,created_by uuid);
CREATE TABLE public.order_items(order_id uuid,sku_name text,ordered_qty numeric,approved_qty numeric,rate numeric,amount numeric);
CREATE TABLE public.dispatch_assignments(order_id uuid,vehicle_no text,driver_name text,assigned_at timestamptz,loading_completed_at timestamptz);
CREATE TABLE public.lwb_delivery_reports(order_id uuid,delivery_status text,reported_at timestamptz);
CREATE TABLE public.lwb_acc_day_close(id bigserial primary key,close_date date,is_start boolean default false,counted numeric,handed_to_name text,
  closed_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.acc_t(src text,id uuid default gen_random_uuid(),book_date date,kind text,mode text,amount numeric,party text,order_no text,cash_effect numeric,needs_verify boolean);
CREATE FUNCTION public.lwb_acc_lines() RETURNS TABLE(src text,id uuid,book_date date,at timestamptz,kind text,mode text,amount numeric,category text,party text,ref text,
  remark text,order_no text,bank_id bigint,cash_effect numeric,needs_verify boolean,created_by uuid)
  LANGUAGE sql AS $$ SELECT src,id,book_date,now(),kind,mode,amount,null::text,party,null::text,null::text,order_no,null::bigint,cash_effect,needs_verify,null::uuid FROM public.acc_t $$;
CREATE FUNCTION public.lwb_acc_cash_at(p date) RETURNS TABLE(amount numeric,is_set boolean,base_date date)
  LANGUAGE sql AS $$ SELECT 40580 + coalesce((SELECT sum(cash_effect) FROM public.acc_t WHERE book_date < p AND book_date >= '2026-11-24'),0), true, '2026-11-23'::date $$;
CREATE TABLE public.lwb_acc_verify(src text,src_id uuid);
CREATE TABLE public.lwb_acc_cheques(src text,src_id uuid,cheque_date date,deposited_on date);
CREATE TABLE public.lwb_tally_payments(id uuid primary key,company_id uuid);
CREATE TABLE public.ledger_t(entry_date date,customer_name text,debit numeric,credit numeric,company_id uuid);
CREATE FUNCTION public.lwb_party_ledger_b() RETURNS TABLE(entry_date date,entry_kind text,customer_name text,ref_no text,order_no text,debit numeric,credit numeric,
  note text,created_at timestamptz,company_id uuid) LANGUAGE sql AS $$ SELECT entry_date,'X'::text,customer_name,null::text,null::text,debit,credit,null::text,null::timestamptz,company_id FROM public.ledger_t $$;
CREATE TABLE public.lwb_sales_targets(month date,salesman_id uuid,target_amount numeric,target_cases numeric);
CREATE FUNCTION public.lwb_build_sales_plan(p uuid,d date) RETURNS jsonb LANGUAGE sql AS $$
  SELECT CASE WHEN p = '00000000-0000-4000-8000-000000000003'::uuid
    THEN jsonb_build_object('parties', jsonb_build_array(jsonb_build_object('name','SHREE JAGDISH','days',6,'city','Surat'), jsonb_build_object('name','OM TRADERS','days',null)))
    ELSE jsonb_build_object('parties','[]'::jsonb) END $$;
CREATE TABLE public.lwb_tasks(id bigserial primary key,title text,details text,due_date date,priority text,status text default 'OPEN',assigned_to uuid,assigned_to_name text,
  assigned_to_role text,assigned_by uuid,assigned_by_name text,assigned_by_role text,auto_key text,done_at timestamptz,created_at timestamptz default now());
CREATE TABLE public.erp_notifications(id bigserial primary key,user_id uuid,title text,message text,notification_type text);
CREATE TABLE public.lwb_goods_inward(id uuid default gen_random_uuid() primary key,received_date date,supplier_name text,invoice_no text,company_id uuid);
CREATE TABLE public.lwb_party_calls(id bigserial primary key,customer_name text,call_date date,result text,called_by_name text);
CREATE TABLE public.lwb_complaints(id bigserial primary key,category text,subject text,urgent boolean default false,status text default 'OPEN',created_by_name text,created_at timestamptz default now());
CREATE TABLE public.lwb_party_returns(id uuid default gen_random_uuid() primary key,return_no text,party text,order_id uuid,company_id uuid,return_date date,amount numeric,cancelled_at timestamptz);
CREATE TABLE public.lwb_goods_inward_items(inward_id uuid,total_amount numeric);
CREATE TABLE public.lwb_driver_delivery_returns(id uuid default gen_random_uuid() primary key,order_id uuid,status text,created_at timestamptz);
CREATE TABLE public.lwb_driver_delivery_return_items(return_id uuid,qty_cases numeric);
`);
const people = [[U.admin,'admin','Mohit','9512297456'],[U.head,'manager','Harsh','9800000002'],[U.nadim,'sales','Nadim Tinwala','9800000003'],
  [U.suresh,'sales','Suresh','9800000004'],[U.dinesh,'sales','Dinesh',null],[U.acc,'accounts','Yogesh','9800000006'],
  [U.godown,'warehouse','Dhruv','9800000007'],[U.driver,'driver','Raju','9800000008']];
for (const p of people) await db.query('insert into user_profiles values($1,$2,true,$3,$4)', p);
await db.exec(`insert into lwb_companies values('${COKE}','Coca-Cola','CASE'),('${RAJ}','Rajnigandha','BOX');
  insert into sku_master values('250ML FANTA','${COKE}',null),('250ML MAAZA','${COKE}',null),('RAJNIGANDHA 4G','${RAJ}',null);`);

const D = '2026-11-24';
async function order(no, person, party, items, opts = {}) {
  const amt = items.reduce((a, i) => a + i[1] * i[2], 0), qty = items.reduce((a, i) => a + i[1], 0);
  const r = await db.query(`insert into orders(order_no,order_date,customer_name,transportation,sales_person,status,total_qty,total_amount,total_weight)
    values($1,$2,$3,$4,$5,$6,$7,$8,$9) returning id`, [no, opts.at || D + 'T10:00:00+05:30', party, opts.tr || 'DELIVERY', person, opts.status || 'approved', qty, amt, qty * 10]);
  const id = r.rows[0].id;
  for (const i of items) await db.query('insert into order_items values($1,$2,$3,$3,$4,$5)', [id, i[0], i[1], i[2], i[1] * i[2]]);
  return id;
}
const o1 = await order('P1', 'Nadim Tinwala', 'Manshi Marketing', [['250ML FANTA', 20, 455], ['250ML MAAZA', 120, 475]]);
const o2 = await order('P2', 'NADIM TINWALA', 'Om Traders', [['250ML FANTA', 10, 455]]);
const o3 = await order('P3', 'Suresh', 'Patel Agency', [['RAJNIGANDHA 4G', 50, 300]]);
await order('P4', 'Suresh', 'Old Party', [['250ML FANTA', 5, 455]], {at: '2026-11-10T10:00:00+05:30'});
await order('P5', 'Nadim Tinwala', 'Cancelled', [['250ML FANTA', 99, 455]], {status: 'cancelled'});
await order('P6', 'Harsh', 'Direct Party', [['250ML MAAZA', 300, 450]], {tr: 'DIRECT VEHICLE'});
await db.query(`insert into dispatch_assignments values($1,'GJ05FW9821','Mohit',$2,$2),($3,'GJ05FW9821','Mohit',$2,null),($4,'GJ 05 BX 4410','Raju',$2,$2)`,
  [o1, D + 'T15:00:00+05:30', o2, o3]);
await db.query(`insert into lwb_delivery_reports values($1,'DELIVERED',$2)`, [o1, D + 'T18:00:00+05:30']);
await db.query(`update orders set status='loaded' where id=$1`, [o3]);
const pay = '20000000-0000-4000-8000-000000000001';
await db.query(`insert into acc_t(src,id,book_date,kind,mode,amount,party,cash_effect,needs_verify) values
  ('PAYMENT',$1,$2,'IN','UPI',120000,'Shree Jagdish',0,true),('DRIVER_CASH',gen_random_uuid(),$2,'IN','CASH',85000,'Manshi Marketing',85000,false),
  ('ENTRY',gen_random_uuid(),$2,'OUT','CASH',38500,null,-38500,false),('ENTRY',gen_random_uuid(),$2,'DEPOSIT','BANK',20000,null,-20000,true)`, [pay, D]);
await db.query(`update acc_t set order_no='P1' where src='DRIVER_CASH'`);
await db.query(`insert into lwb_tally_payments values($1,$2)`, [pay, COKE]);
await db.query(`insert into ledger_t values('2026-11-01','A',500000,0,$1),('2026-11-01','B',200000,0,$2),('2026-11-24','A',0,120000,$1),('2026-11-30','A',999999,0,$1)`, [COKE, RAJ]);
await db.query(`insert into lwb_sales_targets values('2026-11-01',$1,3000000,600)`, [U.nadim]);
const gi = (await db.query(`insert into lwb_goods_inward(received_date,supplier_name,invoice_no,company_id) values($1,'HCCB','INV-77',$2) returning id`, [D, COKE])).rows[0].id;
await db.query(`insert into lwb_goods_inward_items values($1,260000),($1,260000)`, [gi]);

const sql = await readFile(new URL('../../lwb_daily_whatsapp_setup.sql', import.meta.url), 'utf8');
await db.exec(sql.replace('CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;', ''));
await db.exec('GRANT USAGE ON SCHEMA public, auth TO authenticated');
const as = async id => db.query("select set_config('request.jwt.claim.sub',$1,false)", [id || '']);
async function call(q, p) { await db.exec('SET ROLE authenticated'); try { return (await db.query(q, p)).rows } finally { await db.exec('RESET ROLE') } }
const build = async () => (await db.query('select public.lwb_daily_wa_build($1::date) b', [D])).rows[0].b;
const rep = (b, kind, key) => b.reports.find(r => r.kind === kind && (key == null || r.key === key));
const kv = (r, label) => { const x = r.doc.rows.find(z => z[0] === 'kv' && String(z[1]).toLowerCase() === label.toLowerCase()); return x && x[2] };

test('money helpers: Indian format', async () => {
  const r = (await db.query(`select lwb_wa_inr(842560) a, lwb_wa_inr(999) b, lwb_wa_inr(12345678.4) c, lwb_wa_ton(6180) t, lwb_wa_qty('[{"u":"cs","q":590},{"u":"IC","q":120}]') q`)).rows[0];
  assert.deepEqual(r, {a: '₹ 8,42,560', b: '₹ 999', c: '₹ 1,23,45,678', t: '6.2', q: '590 cs · 120 IC'});
});

test('only Admin opens the page; salesman / anon cannot run anything', async () => {
  await as(U.nadim); await assert.rejects(call('select lwb_daily_wa_page($1::date)', [D]), /Admin only/);
  await assert.rejects(call('select lwb_daily_wa_build($1::date)', [D]), /permission denied/);
  await assert.rejects(call('select lwb_daily_wa_claim($1::date)', [D]), /permission denied/);
  for (const f of ['lwb_daily_wa_page(date)', 'lwb_daily_wa_send(date,text)'])
    assert.equal((await db.query(`select has_function_privilege('anon','public.${f}','EXECUTE') a`)).rows[0].a, false);
  await as(U.admin); const p = (await call('select lwb_daily_wa_page($1::date) j', [D]))[0].j;
  assert.ok(p.reports.length >= 5); assert.equal(p.config.enabled, false);
});

test('salesman report: own orders only, product-wise, month target and tomorrow, focus parties', async () => {
  const b = await build(), r = rep(b, 'SALESMAN', U.nadim);
  assert.equal(kv(r, "Today's orders"), '2 PO · 2 parties');                // cancelled + other days left out
  assert.equal(kv(r, 'Total amount'), '₹ 70,650');                           // 20x455 + 120x475 + 10x455
  assert.equal(kv(r, 'Total qty'), '150 cs');
  const prods = r.doc.rows.filter(z => z[0] === 'tr').map(z => z[1][0]);
  assert.deepEqual(prods, ['250ML MAAZA', '250ML FANTA']);
  assert.equal(r.doc.rows.find(z => z[0] === 'tr' && z[1][0] === '250ML FANTA')[1][1], '30 cs');
  assert.match(kv(r, 'Achieved'), /^₹ 70,650 \(2%\)$/);
  // 30,00,000 - 70,650 left over 25,26,27,28,29(Sat),30 = 6 working days (Sunday 29? no: 29 Nov 2026 is a Sunday)
  assert.match(kv(r, "Tomorrow's target"), /^₹ [\d,]+ · \d+ cases$/);
  assert.equal(kv(r, 'SHREE JAGDISH'), '6 days no order');
  assert.equal(kv(r, 'OM TRADERS'), 'No order yet');
  const s = rep(b, 'SALESMAN', U.suresh);
  assert.equal(kv(s, 'Total qty'), '50 IC');                                  // Rajnigandha counts in IC
  assert.equal(kv(rep(b, 'SALESMAN', U.dinesh), "Today's orders"), '0 PO · 0 parties');
});

test('admin + accounts + godown numbers', async () => {
  const b = await build(), a = rep(b, 'ADMIN');
  assert.equal(kv(a, 'Total sales'), '₹ 2,20,650 · 4 PO');                   // P1 + P2 + P3 + P6 (direct)
  assert.equal(kv(a, 'Direct vehicle'), '₹ 1,35,000 · 1 PO');
  assert.equal(kv(a, 'Purchase'), '₹ 5,20,000 · 1 bills');
  assert.equal(kv(a, 'Bank not checked'), '₹ 1,40,000 (2 entries)');
  assert.equal(kv(a, 'Coca-Cola'), '₹ 3,80,000');                             // 5,00,000 - 1,20,000 (30/11 bill is after the day)
  assert.equal(kv(a, 'Total'), '₹ 5,80,000');
  const brand = a.doc.rows.filter(z => z[0] === 'tr').map(z => z[1]);
  assert.deepEqual(brand[0], ['COCA-COLA', '85,000', '1,20,000', '2,05,000']);  // driver cash via its PO brand, party payment via its brand
  const acc = rep(b, 'ACCOUNTS');
  assert.equal(kv(acc, 'Opening cash'), '₹ 40,580');
  assert.equal(kv(acc, 'Cash out'), '₹ 38,500');
  assert.match(kv(acc, 'Closing cash'), /^₹ 67,080 \(day not closed\)$/);    // 40,580 + 85,000 - 38,500 - 20,000
  const g = rep(b, 'GODOWN');
  assert.equal(kv(g, 'Total loaded'), '2.0 T · 150 cs · 50 IC · 2 vehicles');
  const veh = g.doc.rows.filter(z => z[0] === 'tr').map(z => z[1][0]);
  assert.deepEqual(veh, ['GJ05FW9821 · MOHIT', 'GJ 05 BX 4410 · RAJU', 'TOTAL']);
  assert.equal(kv(g, 'Delivered'), '1 parties · ₹ 66,100');
  assert.equal(kv(g, 'Pending delivery'), '1 PO · ₹ 15,000');
});

test('MGR list, salesman -> MGR, ranking', async () => {
  await as(U.admin);
  const m1 = (await call(`select lwb_company_mgr_save(null,'Vishal',$1::uuid,true) id`, [COKE]))[0].id;
  const m2 = (await call(`select lwb_company_mgr_save(null,'Vinas',$1::uuid,true) id`, [RAJ]))[0].id;
  await assert.rejects(call(`select lwb_company_mgr_save(null,'vishal',null,true)`), /already exists/);
  await call('select lwb_salesman_mgr_set($1::uuid,$2::bigint)', [U.nadim, m1]);
  await call('select lwb_salesman_mgr_set($1::uuid,$2::bigint)', [U.dinesh, m1]);
  await call('select lwb_salesman_mgr_set($1::uuid,$2::bigint)', [U.suresh, m2]);
  const b = await build(), m = rep(b, 'MGR', String(m1));
  assert.equal(kv(m, 'Team total today'), '₹ 70,650 · 2 PO');
  const rows = m.doc.rows.filter(z => z[0] === 'tr');
  assert.deepEqual(rows.map(z => z[1][0]), ['NADIM TINWALA', 'DINESH', 'TOTAL']);
  assert.equal(rows[1][1][3], 'No order'); assert.equal(rows[1][3], 'r');
  const t = rep(b, 'TEAM');
  const rank = t.doc.rows.filter(z => z[0] === 'tr').map(z => z[1][0]);
  assert.equal(rank[0], '1st VISHAL'); assert.equal(rank[1], '2nd VINAS');
});

test('who gets what: own salesman report, MGR + team to Admin and Sales Head, no mobile = skipped', async () => {
  const b = await build();
  const s = (await db.query('select kind, report_key, name from lwb_daily_wa_sends($1::jsonb) order by kind, name, report_key', [b])).rows;
  const by = k => s.filter(x => x.kind === k).map(x => x.name);
  assert.deepEqual(by('SALESMAN'), ['Nadim Tinwala', 'Suresh']);              // Dinesh: no mobile
  assert.deepEqual(by('ADMIN'), ['Mohit']);
  assert.deepEqual(by('ACCOUNTS'), ['Yogesh']);
  assert.deepEqual(by('GODOWN'), ['Dhruv', 'Mohit']);
  assert.deepEqual([...new Set(by('MGR'))], ['Harsh', 'Mohit']);
  assert.equal(by('MGR').length, 4);                                          // 2 MGRs x 2 people
  assert.ok(!s.some(x => x.name === 'Raju'));                                 // driver never
  // Admin turns Godown off for himself
  await as(U.admin);
  await call(`select lwb_daily_wa_save(false,'23:00',true,$1::jsonb)`, [JSON.stringify([{user_id: U.admin, kind: 'GODOWN', enabled: false}])]);
  const s2 = (await db.query('select name from lwb_daily_wa_sends(public.lwb_daily_wa_build($1::date)) where kind = $2', [D, 'GODOWN'])).rows.map(x => x.name);
  assert.deepEqual(s2, ['Dhruv']);
});

test('claim: never twice, failed ones again; focus tasks once; test goes only to me', async () => {
  const c1 = (await db.query('select lwb_daily_wa_claim($1::date) j', [D])).rows[0].j;
  assert.ok(c1.messages.length > 5); assert.equal(c1.template, 'lwb_daily_report');
  const tasks = (await db.query('select assigned_to, title, due_date::text, details from lwb_tasks')).rows;
  assert.equal(tasks.length, 1); assert.equal(tasks[0].assigned_to, U.nadim);
  assert.match(tasks[0].title, /Focus parties 25\/11: 2 parties/); assert.match(tasks[0].details, /SHREE JAGDISH · Surat · 6 days/);
  await db.query('select lwb_daily_wa_mark($1,false,null,$2)', [c1.messages[0].id, 'boom']);
  for (const m of c1.messages.slice(1)) await db.query('select lwb_daily_wa_mark($1,true,$2)', [m.id, 'wamid.x']);
  const c2 = (await db.query('select lwb_daily_wa_claim($1::date) j', [D])).rows[0].j;
  assert.equal(c2.messages.length, 1); assert.equal(c2.messages[0].id, c1.messages[0].id);
  assert.equal((await db.query('select count(*)::int n from lwb_tasks')).rows[0].n, 1);
  const t = (await db.query('select lwb_daily_wa_claim($1::date,$2::uuid) j', [D, U.admin])).rows[0].j;
  assert.ok(t.test); assert.ok(t.messages.every(m => m.to === '919512297456'));
  assert.equal(t.messages.filter(m => m.kind === 'SALESMAN').length, 1);
  assert.deepEqual([...new Set(t.messages.map(m => m.kind))], ['DAYBOOK', 'ACCBOOK', 'ADMIN', 'TEAM', 'MGR', 'ACCOUNTS', 'GODOWN', 'SALESMAN']);
});

test('Close Day fires once when on; opening entry / old date / off do nothing', async () => {
  await db.exec('delete from lwb_daily_wa_runs');
  await db.query(`insert into lwb_acc_day_close(close_date,is_start,counted) values(current_date,false,100)`);
  assert.equal((await db.query('select count(*)::int n from lwb_daily_wa_runs')).rows[0].n, 0, 'off: nothing');
  await db.exec('update lwb_daily_wa_config set enabled = true');
  await db.query(`insert into lwb_acc_day_close(close_date,is_start,counted) values(current_date,true,100)`);
  await db.query(`insert into lwb_acc_day_close(close_date,is_start,counted) values(current_date - 5,false,100)`);
  assert.equal((await db.query('select count(*)::int n from lwb_daily_wa_runs')).rows[0].n, 0);
  await db.query(`insert into lwb_acc_day_close(close_date,is_start,counted) values(current_date,false,100)`);
  await db.query(`insert into lwb_acc_day_close(close_date,is_start,counted) values(current_date,false,100)`);
  const r = (await db.query('select trigger from lwb_daily_wa_runs')).rows;
  assert.deepEqual(r, [{trigger: 'CLOSE_DAY'}]);
});

test('every report draws to a PNG', async () => {
  await initWasm(await readFile(new URL('./node_modules/@resvg/resvg-wasm/index_bg.wasm', import.meta.url)));
  const fonts = [await readFile(new URL('./node_modules/@expo-google-fonts/roboto/Roboto_400Regular.ttf', import.meta.url)),
                 await readFile(new URL('./node_modules/@expo-google-fonts/roboto/Roboto_700Bold.ttf', import.meta.url))];
  const b = await build();
  if (process.env.OUT) await mkdir(process.env.OUT, {recursive: true});
  for (const r of b.reports) {
    const png = new Resvg(renderSvg(r.doc), {font: {fontBuffers: fonts, defaultFontFamily: 'Roboto', loadSystemFonts: false}, fitTo: {mode: 'zoom', value: 1.5}}).render().asPng();
    assert.ok(png.length > 5000);
    if (process.env.OUT) await writeFile(`${process.env.OUT}/${r.kind}-${r.title.replace(/\W+/g, '-')}.png`, png);
  }
});

test('day book: done, not done, pending, full lists (Admin, PDF)', async () => {
  await db.query(`insert into orders(order_no,order_date,customer_name,sales_person,status,total_amount) values('P7','2026-10-28T10:00:00+05:30','Waiting Party','Harsh','pending',5000)`);
  await db.query(`insert into lwb_party_calls(customer_name,call_date,result,called_by_name) values('A',$1,'ORDER_TAKEN','Nadim Tinwala'),('B',$1,'NO_ORDER','Nadim Tinwala'),('C',$1,'NOT_REACHABLE','Suresh'),('D','2026-11-20','ORDER_TAKEN','Suresh')`, [D]);
  await db.query(`insert into lwb_tasks(title,due_date,status,assigned_to,assigned_to_name,done_at) values('Old',$1::date - 3,'OPEN',$2,'Suresh',null),('Done',$1,'DONE',$3,'Yogesh',$1::date + time '12:00')`, [D, U.suresh, U.acc]);
  await db.query(`insert into lwb_complaints(category,subject,urgent,created_by_name) values('DRIVER','Late delivery',true,'Harsh')`);
  await db.query(`insert into lwb_party_returns(return_no,party,return_date,amount) values('SR-1','Om Traders',$1,4550),('SR-2','X',$1,1)`, [D]);
  await db.query(`update lwb_party_returns set cancelled_at=now() where return_no='SR-2'`);
  const b = await build(), r = rep(b, 'DAYBOOK'), ac = rep(b, 'ACCBOOK');
  if (process.env.SHOW) { console.log(JSON.stringify(r.doc.rows)); console.log(JSON.stringify(ac.doc.rows)); }
  assert.equal(r.title, 'Day Book · Sales & work'); assert.equal(r.pdf, true); assert.equal(ac.pdf, true);
  assert.equal(kv(r, 'Sales'), '4 PO · ₹ 2,20,650');
  assert.equal(kv(r, 'Delivered'), '1 PO · ₹ 66,100');
  assert.equal(kv(r, 'Party calls'), '3 calls · 1 orders');
  assert.match(kv(r, 'Tasks'), /^1 done · \d+ open · 1 late$/);
  assert.equal(kv(r, 'Complaints'), '1 open');
  const trs = rw => rw.doc.rows.filter(z => z[0] === 'tr').map(z => z[1]);
  // brand-wise today: Coca-Cola sales 66,100 + 4,550 + 1,35,000; Rajnigandha 15,000; purchase on Coca-Cola
  assert.deepEqual(trs(r).find(z => z[0] === 'COCA-COLA'), ['COCA-COLA', '2,05,650', '66,100', '5,20,000']);
  assert.deepEqual(trs(r).find(z => z[0] === 'RAJNIGANDHA'), ['RAJNIGANDHA', '15,000', '0', '0']);
  assert.deepEqual(trs(r).find(z => z[0] === 'ALL BRANDS'), ['ALL BRANDS', '2,20,650', '66,100', '5,20,000']);
  const grp = rw => rw.doc.rows.filter(z => z[0] === 'grp').map(z => z[1] + ' | ' + z[2]);
  assert.ok(grp(r).includes('COCA-COLA | 3 PO  ·  ₹ 2,05,650'));
  assert.ok(grp(r).includes('BRAND NOT SET | 1 PO  ·  ₹ 5,000'));      // P7 has no items
  const secs = rw => rw.doc.rows.filter(z => z[0] === 'sec').map(z => z[1]);
  for (const t of ['Brand-wise today', 'Brand-wise pending', '1. Orders today', '4. Purchase in', '8. Waiting approval', '10. Loaded, not delivered', '11. Complaints open'])
    assert.ok(secs(r).some(x => x.startsWith(t)), t);
  assert.ok(!secs(r).some(x => /Money/.test(x)));
  // accounts PDF
  assert.equal(kv(ac, 'Money in'), '₹ 2,05,000 · 2 entries');
  assert.equal(kv(ac, 'Purchase bills'), '1 · ₹ 5,20,000');
  assert.deepEqual(trs(ac).find(z => z[0] === 'COCA-COLA'), ['COCA-COLA', '85,000', '1,20,000', '2,05,000']);
  for (const t of ['Brand-wise collection', 'Cash book', '1. Money in', '2. Money out', '3. Outstanding', '4. Top 10 dues', '5. Bank not checked', '6. Cheques'])
    assert.ok(secs(ac).some(x => x.startsWith(t)), t);
  assert.ok(trs(ac).some(z => z[0] === 'ALL BRANDS' && z[3] === '5,80,000'));    // outstanding A 3,80,000 + B 2,00,000
  // who gets it: Admin only (default)
  const p = (await (async () => { await as(U.admin); return (await call('select lwb_daily_wa_page($1::date) j', [D]))[0].j })());
  assert.deepEqual(p.reports.find(x => x.kind === 'DAYBOOK').to, ['Mohit']);
  // only the Day Book to me
  const c = (await db.query(`select lwb_daily_wa_claim($1::date, $2::uuid, 'DAYBOOK') j`, [D, U.admin])).rows[0].j;
  assert.deepEqual(c.messages.map(m => [m.kind, m.pdf]), [['DAYBOOK', true], ['ACCBOOK', true]]);
  assert.deepEqual(p.reports.find(x => x.kind === 'ACCBOOK').to, ['Mohit', 'Yogesh']);
  assert.equal(c.template_doc, 'lwb_daily_report_pdf');
});

test('long report -> A4 pages with heads repeated -> PDF', async () => {
  const rows = [['kv', 'Date', '24/11/2026'], ['sec', 'Big list'], ['th', ['A', 'B', 'C', 'D']]];
  for (let i = 0; i < 90; i++) rows.push(['tr', ['Party ' + i, '1', '2', '3']]);
  const doc = {who: 'ADMIN · DAY BOOK', rows};
  const H = {kv: 32, th: 32, tr: 31, sec: 52};
  const pg = pages(doc);
  assert.ok(pg.length >= 3);
  for (const x of pg.slice(1)) assert.equal(x[0][0], 'th');
  for (const x of pg) assert.ok(x.reduce((h, r) => h + H[r[0]], 0) <= PAGE_PX);
  assert.equal(pg.flat().filter(r => r[0] === 'tr').length, 90);
  await initWasm(await readFile(new URL('./node_modules/@resvg/resvg-wasm/index_bg.wasm', import.meta.url))).catch(() => {});
  const fonts = await Promise.all(['Roboto_400Regular', 'Roboto_700Bold'].map(f => readFile(new URL(`./node_modules/@expo-google-fonts/roboto/${f}.ttf`, import.meta.url))));
  const svgPng = svg => new Resvg(svg, {font: {fontBuffers: fonts, defaultFontFamily: 'Roboto', loadSystemFonts: false}, fitTo: {mode: 'zoom', value: 2}}).render().asPng();
  const b = await build(), meta = {title: 'Day Book · Sales & Work', sub: 'Daily work report', date: '24/11/2026', footer: 'For Admin'};
  let t0 = performance.now();
  const bytes = await buildPdf(rep(b, 'DAYBOOK').doc, {PDFDocument, rgb}, fontkit, fonts, meta);
  assert.equal(String.fromCharCode(...bytes.slice(0, 5)), '%PDF-');
  t0 = performance.now();
  const big = await buildPdf(doc, {PDFDocument, rgb}, fontkit, fonts, meta);
  console.log('# pdf ms', Math.round(performance.now() - t0), 'bytes', big.length, 'pages', pg.length);
  assert.ok(big.length < 400000);
  assert.equal((await PDFDocument.load(big)).getPageCount(), pg.length);
  if (process.env.OUT) {
    await writeFile(process.env.OUT + '/DAYBOOK.pdf', bytes); await writeFile(process.env.OUT + '/BIG.pdf', big);
    const acc = await buildPdf(rep(b, 'ACCBOOK').doc, {PDFDocument, rgb}, fontkit, fonts, {title: 'Day Book · Accounts', sub: 'Daily accounts report', date: '24/11/2026', footer: 'For Admin & Accounts'});
    await writeFile(process.env.OUT + '/ACCBOOK.pdf', acc);
  }
});

test('page data for screenshots (PAGE_OUT=file)', { skip: !process.env.PAGE_OUT }, async () => {
  await as(U.admin);
  const p = (await call('select lwb_daily_wa_page($1::date) j', [D]))[0].j;
  const { writeFileSync } = await import('node:fs');
  writeFileSync(process.env.PAGE_OUT, JSON.stringify(p));
});
