import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
import {PDFDocument, rgb} from 'pdf-lib';
import fontkit from '@pdf-lib/fontkit';
import {pages, buildPdf, PAGE_PX} from '../../supabase/functions/lwb-daily-whatsapp/render.mjs';

// lwb_evening_report_setup.sql on a tiny copy of the tables it reads (no live database).
// Numbers per brand (today / last 3 days / month), banks, cheques, handover -> popup due,
// download mark, Admin only, and the PDF (OUT=dir keeps evening.pdf + doc.json).
const U = {admin: '00000000-0000-4000-8000-000000000001', head: '00000000-0000-4000-8000-000000000002', sales: '00000000-0000-4000-8000-000000000003'};
const COKE = '10000000-0000-4000-8000-000000000001', RAJ = '10000000-0000-4000-8000-000000000002';
const db = new PGlite();
await db.exec(`
CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
CREATE TABLE public.user_profiles(id uuid primary key,role text,active boolean,full_name text,mobile text);
CREATE TABLE public.lwb_companies(id uuid primary key,name text);
CREATE TABLE public.ledger_t(entry_date date,entry_kind text,customer_name text,ref_no text,debit numeric,credit numeric,company_id uuid,created_at timestamptz default now());
CREATE FUNCTION public.lwb_party_ledger_b() RETURNS TABLE(entry_date date,entry_kind text,customer_name text,ref_no text,order_no text,debit numeric,credit numeric,
  note text,created_at timestamptz,company_id uuid) LANGUAGE sql AS $$ SELECT entry_date,entry_kind,customer_name,ref_no,null::text,debit,credit,null::text,created_at,company_id FROM public.ledger_t $$;
CREATE TABLE public.lwb_goods_inward(id uuid default gen_random_uuid() primary key,received_date date,supplier_name text,invoice_no text,company_id uuid);
CREATE TABLE public.lwb_goods_inward_items(inward_id uuid,total_amount numeric);
CREATE TABLE public.lwb_company_payments(id uuid default gen_random_uuid() primary key,company_id uuid,pay_date date,amount numeric,mode text,ref_no text,created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_acc_banks(id bigserial primary key,name text,account_no text,active boolean default true,bal numeric);
CREATE FUNCTION public.lwb_acc_reset_bank_balance(p bigint) RETURNS numeric LANGUAGE sql AS $$ SELECT bal FROM public.lwb_acc_banks WHERE id = p $$;
CREATE TABLE public.chq_t(book_date date,at timestamptz default now(),amount numeric,party text,cheque_no text,cheque_date date);
CREATE FUNCTION public.lwb_acc_cheque_rows() RETURNS TABLE(src text,id uuid,book_date date,at timestamptz,amount numeric,party text,order_no text,cheque_no text,cheque_date date)
  LANGUAGE sql AS $$ SELECT 'ENTRY',gen_random_uuid(),book_date,at,amount,party,null::text,cheque_no,cheque_date FROM public.chq_t $$;
CREATE TABLE public.lwb_acc_entries(id uuid default gen_random_uuid() primary key,entry_date date,kind text,mode text,amount numeric,party text,ref_no text,created_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_acc_day_close(id bigserial primary key,close_date date,is_start boolean default false,counted numeric,handed_to_name text,closed_by uuid,closed_at timestamptz default now(),cancelled_at timestamptz);
CREATE TABLE public.lwb_acc_shift_handovers(id bigserial primary key,given_by uuid,given_to uuid,given_at timestamptz default now(),counted numeric,status text,received_amount numeric,received_by uuid,received_at timestamptz);
`);
await db.exec(`insert into user_profiles values('${U.admin}','admin',true,'Mohit','9512297456'),('${U.head}','manager',true,'Rakesh','9800000002'),('${U.sales}','sales',true,'Nadim',null);
  insert into lwb_companies values('${COKE}','Coca-Cola'),('${RAJ}','Rajnigandha');`);

const T = (await db.query("select (now() at time zone 'Asia/Kolkata')::date::text d")).rows[0].d;
const day = n => new Date(new Date(T + "T12:00:00Z").getTime() + n * 864e5).toISOString().slice(0, 10);
const sameMonth = day(-1).slice(0, 7) === T.slice(0, 7);
// sales bills + receipts (party ledger), purchase, company payment
const L = [[day(0), 'TALLY_BILL', 'Devnarayan Sales', 'LWB/CC/5875', 36850, 0, COKE], [day(0), 'TALLY_BILL', 'Ankit Enterprise', 'LWB/CC/5876', 34075, 0, COKE],
  [day(-1), 'ERP_BILL', 'Tapi Store', 'LXY-00901', 46875, 0, COKE], [day(-5), 'TALLY_BILL', 'Old Party', 'LWB/CC/5000', 100000, 0, COKE],
  [day(0), 'PARTY_PAYMENT', 'Jain Stores', 'UPI 4411', 0, 82529, COKE], [day(-2), 'DRIVER_PAYMENT', 'Limbu Tobaco', 'CASH', 0, 3960, COKE],
  [day(0), 'TALLY_BILL', 'Shree Jagdish', 'RJ/101', 61100, 0, RAJ], [day(0), 'OPENING', 'Nobody', 'Opening', 5000, 0, COKE],
  [day(0), 'TALLY_BILL', 'No Brand Party', 'X/1', 1000, 0, null]];
for (const r of L) await db.query('insert into ledger_t(entry_date,entry_kind,customer_name,ref_no,debit,credit,company_id) values($1,$2,$3,$4,$5,$6,$7)', r);
const g = (await db.query(`insert into lwb_goods_inward(received_date,supplier_name,invoice_no,company_id) values($1,'Hindustan Coca Cola Beverages Pvt Ltd','7012739233',$2) returning id`, [day(0), COKE])).rows[0].id;
await db.query('insert into lwb_goods_inward_items values($1,810504.24),($1,1000)', [g]);
await db.query(`insert into lwb_company_payments(company_id,pay_date,amount,mode,ref_no) values($1,$2,500000,'BANK','UTR99'),($1,$2,9999,'CREDIT_NOTE',null)`, [COKE, day(0)]);
await db.query(`insert into lwb_company_payments(company_id,pay_date,amount,mode,cancelled_at) values($1,$2,7777,'BANK',now())`, [COKE, day(0)]);
await db.exec(`insert into lwb_acc_banks(name,account_no,bal) values('ICICI BANK','0154',50081681),('Varachha Bank',null,189825);
  insert into lwb_acc_banks(name,active,bal) values('Closed bank',false,999);`);
await db.query(`insert into chq_t(book_date,amount,party,cheque_no,cheque_date) values($1,25000,'Gurmukh Traders','004512',$1),($2,1,'Old','1',$2)`, [day(0), day(-1)]);
await db.query(`insert into lwb_acc_entries(entry_date,kind,mode,amount,party,ref_no) values($1,'OUT','CHEQUE',15000,'Rent','000777'),($1,'OUT','CASH',100,'Tea',null)`, [day(0)]);

const sql = await readFile(new URL('../../lwb_evening_report_setup.sql', import.meta.url), 'utf8');
await db.exec(sql);
await db.exec(sql);                 // safe to run again
const as = async id => db.query("select set_config('request.jwt.claim.sub',$1,false)", [id || '']);
const q1 = async (s, a = []) => (await db.query(s, a)).rows[0];

test('Indian numbers keep paise', async () => {
  assert.equal((await q1("select public.lwb_ev_num(3675068.08) v")).v, '36,75,068.08');
  assert.equal((await q1("select public.lwb_ev_num(25312587) v")).v, '2,53,12,587');
  assert.equal((await q1("select public.lwb_ev_num(-588.5) v")).v, '-588.50');
});

test('only Admin: report, due and mark', async () => {
  await as(U.sales);
  await assert.rejects(db.query('select public.lwb_evening_report(null)'), /Only Admin/);
  assert.equal((await q1('select public.lwb_evening_due() v')).v.due, false);
  await as(U.head);
  await assert.rejects(db.query('select public.lwb_evening_mark(null)'), /Only Admin/);
});

let R;
test('numbers per brand: today, last 3 days, month, lists, banks, cheques', async () => {
  await as(U.admin);
  R = (await q1('select public.lwb_evening_report(null) v')).v;
  const S = R.sum;
  assert.equal(Number(S.sales), 36850 + 34075 + 61100 + 1000);
  assert.equal(Number(S.received), 82529);
  assert.equal(Number(S.purchase), 811504.24);
  assert.equal(Number(S.paid), 500000);                       // credit note + cancelled not counted
  assert.equal(Number(S.bank), 50081681 + 189825);           // closed bank not counted
  assert.equal(S.cheques_in, 1); assert.equal(S.cheques_out, 1);
  const rows = R.doc.rows, txt = JSON.stringify(rows);
  const h1 = rows.filter(r => r[0] === 'h1').map(r => r[2]);
  assert.deepEqual(h1, ['LUXURY WRIST BRAND · ALL BRANDS', 'LUXURY WRIST BRAND (COCA-COLA)', 'LUXURY WRIST BRAND (RAJNIGANDHA)', 'LUXURY WRIST BRAND (BRAND NOT SET)']);
  assert.equal(rows.filter(r => r[0] === 'brk').length, 3);
  // Coca-Cola sales: 3 bills in the last 3 days (old one only in the month)
  const coke = rows.slice(rows.findIndex(r => r[0] === 'h1' && /COCA/.test(r[2])));
  const sum = coke.find(r => r[0] === 'sum');
  assert.equal(sum[1][0], 'Today - ₹ 70,925');
  assert.equal(sum[1][1], 'Last 3 days - ₹ 1,17,800');
  if (sameMonth) assert.ok(/This Month - ₹ (2,17,800|1,17,800)/.test(sum[1][2]));
  const bills = coke.slice(coke.findIndex(r => r[0] === 'th') + 1, coke.findIndex(r => r[0] === 'tr' && r[2]));
  assert.deepEqual(bills.map(r => r[1][0]), ['1', '2', '3']);
  assert.ok(bills.every(r => r[1].length === 5));
  assert.equal(bills[2][1][3], 'LXY-00901');
  assert.ok(!txt.includes('OLD PARTY') && !txt.includes('NOBODY'));   // older than 3 days / opening
  assert.ok(txt.includes('HINDUSTAN COCA COLA BEVERAGES PVT LTD') && txt.includes('8,11,504.24'));
  assert.ok(txt.includes('BANK UTR99') && !txt.includes('9,999') && !txt.includes('7,777'));
  assert.ok(txt.includes('Total Bank Balance: ₹ 5,02,71,506 (as of today)'));
  assert.ok(txt.includes('Total Cheques Received Today: 1 of ₹ 25,000') && txt.includes('GURMUKH TRADERS'));
  assert.ok(txt.includes('Total Cheques Given Today: 1 of ₹ 15,000') && txt.includes('000777'));
  assert.ok(txt.includes('-- No purchase in the last 3 days --'));     // Rajnigandha
  const all = rows.find(r => r[0] === 'tr' && r[1][0] === 'ALL BRANDS');
  assert.deepEqual(all[1], ['ALL BRANDS', '1,33,025', '82,529', '8,11,504.24', '5,00,000']);
  assert.equal(rows.find(r => r[0] === 'kv' && r[1] === 'Cash handover')[2], 'Not done yet');
});

test('popup: not before handover, due after Admin received it, gone after download, Close Day too', async () => {
  await as(U.admin);
  let d = (await q1('select public.lwb_evening_due() v')).v;
  assert.equal(d.due, false); assert.equal(d.handover, null);
  // day-time handover between cashiers (before 6 PM) does not count; cancelled does not count
  const at = h => `(('${T} ${h}')::timestamp AT TIME ZONE 'Asia/Kolkata')`;
  await db.query(`insert into lwb_acc_shift_handovers(given_by,given_to,given_at,counted,status) values($1,$2,${at('11:00')},5000,'RECEIVED')`, [U.admin, U.head]);
  await db.query(`insert into lwb_acc_shift_handovers(given_by,given_to,given_at,counted,status) values($1,$2,${at('20:00')},5000,'CANCELLED')`, [U.head, U.admin]);
  assert.equal((await q1('select public.lwb_evening_due() v')).v.due, false);
  // night handover given (not received yet) -> popup at once
  await db.query(`insert into lwb_acc_shift_handovers(given_by,given_to,given_at,counted,status) values($1,$2,${at('21:30')},125000,'PENDING')`, [U.head, U.admin]);
  d = (await q1('select public.lwb_evening_due() v')).v;
  assert.equal(d.due, true); assert.equal(d.handover.received, false);
  await db.exec(`update lwb_acc_shift_handovers set status='RECEIVED', received_amount=124500, received_by='${U.admin}', received_at=now() where status='PENDING'`);
  d = (await q1('select public.lwb_evening_due() v')).v;
  assert.equal(d.due, true); assert.equal(d.handover.received, true); assert.equal(d.handover.by, 'Rakesh'); assert.equal(d.handover.to, 'Mohit'); assert.equal(Number(d.handover.amount), 124500);
  // given to Admin in the day also counts
  await db.exec(`update lwb_acc_shift_handovers set given_at=${at('12:00')} where status='RECEIVED' and counted=125000`);
  assert.equal((await q1('select public.lwb_evening_due() v')).v.due, true);
  const rep = (await q1('select public.lwb_evening_report(null) v')).v;
  assert.ok(/^Rakesh to Mohit · ₹ 1,24,500 · /.test(rep.doc.rows.find(r => r[1] === 'Cash handover')[2]));
  await db.query('select public.lwb_evening_mark(null)');
  await db.query('select public.lwb_evening_mark(null)');
  d = (await q1('select public.lwb_evening_due() v')).v;
  assert.equal(d.due, false); assert.ok(d.downloaded_at);
  assert.equal((await q1('select times from lwb_evening_report_dl')).times, 2);
  // another Admin day: Close Day alone also makes it due
  await db.exec('delete from lwb_acc_shift_handovers; delete from lwb_evening_report_dl;');
  await db.query(`insert into lwb_acc_day_close(close_date,counted,handed_to_name,closed_by) values($1,80000,'Mohit',$2)`, [T, U.head]);
  d = (await q1('select public.lwb_evening_due() v')).v;
  assert.equal(d.due, true); assert.equal(d.handover.how, 'CLOSE_DAY');
  await assert.rejects(db.query('select public.lwb_evening_report($1)', [day(1)]), /today or an earlier/);
});

test('PDF: A4 pages, each brand on a new page, columns fit', async () => {
  await as(U.admin);
  const rep = (await q1('select public.lwb_evening_report(null) v')).v;
  // add many bills so a table goes over pages
  const doc = {...rep.doc, rows: [...rep.doc.rows]};
  const pg = pages(doc);
  const H = {kv: 32, th: 32, tr: 31, sec: 52, grp: 30, h1: 96, sum: 40, note: 34};
  for (const x of pg) assert.ok(x.reduce((h, r) => h + H[r[0]], 0) <= PAGE_PX);
  assert.ok(pg.length >= 4);
  assert.equal(pg.filter(x => x[0][0] === 'h1').length, 4);
  const fonts = await Promise.all(['Roboto_400Regular', 'Roboto_700Bold'].map(f => readFile(new URL(`./node_modules/@expo-google-fonts/roboto/${f}.ttf`, import.meta.url))));
  const bytes = await buildPdf(doc, {PDFDocument, rgb}, fontkit, fonts, {title: 'Daily Report', sub: 'Evening report', date: T.split('-').reverse().join('/'), footer: 'For Admin'});
  assert.equal((await PDFDocument.load(bytes)).getPageCount(), pg.length);
  // a long list: column heads come again on the next page
  const big = {rows: [['h1', 'Daily Report', 'X', 'Y'], ['sec', 'Total Sales'], ['sum', ['a', 'b', 'c']], ['th', ['S.No.', 'Date', 'Customer Name', 'Invoice No.', 'Amount'], [0.07, 0.13, 0.42, 0.22, 0.16]]]};
  for (let i = 1; i <= 70; i++) big.rows.push(['tr', [String(i), '14/02/2026', 'PARTY ' + i, 'LWB/CC/' + (5800 + i) + '/25-26', '36,850']]);
  const bp = pages(big);
  assert.ok(bp.length >= 3);
  for (const x of bp.slice(1)) { assert.equal(x[0][0], 'th'); assert.equal(x[0][2].length, 5); }
  if (process.env.OUT) {
    await mkdir(process.env.OUT, {recursive: true});
    await writeFile(process.env.OUT + '/evening.pdf', bytes);
    await writeFile(process.env.OUT + '/evening-big.pdf', await buildPdf(big, {PDFDocument, rgb}, fontkit, fonts, {title: 'Daily Report', sub: 'Evening report', date: '26/11/2026', footer: 'For Admin'}));
    await writeFile(process.env.OUT + '/evening.json', JSON.stringify(rep));
  }
});
