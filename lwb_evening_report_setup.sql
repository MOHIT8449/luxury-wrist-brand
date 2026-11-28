-- LUXURY WRIST BRAND ERP — EVENING REPORT (Daily Report PDF) AFTER THE CASH HANDOVER (Mohit, 26 Nov 2026)
--
-- Runs by itself when merged to main. Safe to run again. Reads business data only: no order, bill,
-- stock, payment, ledger or cash row is changed. New: one small table (who downloaded which day).
--
-- Mohit (sample "15-02-2026-evening_report.pdf"): one Daily Report PDF, company by company:
--   Total Sales            Today / Last 3 days / This Month + every bill of the last 3 days
--   Total Payments Received  same, every receipt
--   Total Purchase         same, every purchase bill
--   Total Payments Done    same, every payment to the company
--   then Total Bank Balance (each bank), Cheques received today, Cheques given today.
-- When the cash handover of the day is done, Admin gets a popup "Download evening report" on any
-- page (evening-report.js). Not downloaded -> it comes again every 5 minutes; downloaded -> nothing
-- more that day; next day again after that day's handover. The same PDF also goes on WhatsApp with
-- the daily reports (kind EVENING in lwb_daily_whatsapp_setup.sql, Admin on by default).
--
-- "Handover done" = the cashier's Close Day of today, or today's cash handover received by an Admin.
--
-- doc rows (drawn by supabase/functions/lwb-daily-whatsapp/render.mjs, browser and Edge Function):
--   ["h1", title, line 2, line 3]   ["sec", text]   ["sum", [3 texts]]   ["note", text]   ["brk"]
--   ["th", [cells], [column widths]]   ["tr", [cells], total?, tone?]   ["kv", label, value, tone?]

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_evening_report_dl (
  report_date date NOT NULL,
  user_id uuid NOT NULL,
  downloaded_at timestamptz NOT NULL DEFAULT now(),
  times integer NOT NULL DEFAULT 1,
  PRIMARY KEY (report_date, user_id)
);
ALTER TABLE public.lwb_evening_report_dl ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_evening_report_dl FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_ev_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'admin')
$fn$;

-- Indian number: 1234567.5 -> 12,34,568 ; keeps paise when there are any (36,75,068.08)
CREATE OR REPLACE FUNCTION public.lwb_ev_num(p numeric)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $fn$
DECLARE v numeric := round(abs(coalesce(p,0)), 2); s text := trunc(v)::bigint::text; f text := ''; h text; o text;
BEGIN
  IF v <> trunc(v) THEN f := '.' || lpad(round((v - trunc(v)) * 100)::int::text, 2, '0'); END IF;
  IF length(s) > 3 THEN
    o := right(s, 3); h := left(s, length(s) - 3);
    WHILE length(h) > 2 LOOP o := right(h, 2) || ',' || o; h := left(h, length(h) - 2); END LOOP;
    s := h || ',' || o;
  END IF;
  RETURN CASE WHEN coalesce(p,0) < 0 AND v > 0 THEN '-' ELSE '' END || s || f;
END;
$fn$;

-- Handover of the day: {at, how, by, to, amount} or NULL.
CREATE OR REPLACE FUNCTION public.lwb_ev_handover(p_date date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r jsonb; c jsonb;
BEGIN
  IF to_regclass('public.lwb_acc_shift_handovers') IS NOT NULL THEN
    EXECUTE $q$
      SELECT jsonb_build_object('at', h.received_at, 'how', 'HANDOVER',
               'by', coalesce(nullif(btrim(g.full_name),''), 'Cashier'), 'to', coalesce(nullif(btrim(t.full_name),''), 'Admin'),
               'amount', coalesce(h.received_amount, h.counted))
      FROM public.lwb_acc_shift_handovers h
      JOIN public.user_profiles t ON t.id = coalesce(h.received_by, h.given_to)
      LEFT JOIN public.user_profiles g ON g.id = h.given_by
      WHERE h.status = 'RECEIVED' AND h.received_at IS NOT NULL
        AND (h.received_at AT TIME ZONE 'Asia/Kolkata')::date = $1
        AND lower(btrim(coalesce(t.role,''))) = 'admin'
      ORDER BY h.received_at DESC LIMIT 1 $q$ INTO r USING p_date;
  END IF;
  IF to_regclass('public.lwb_acc_day_close') IS NOT NULL THEN
    EXECUTE $q$
      SELECT jsonb_build_object('at', c.closed_at, 'how', 'CLOSE_DAY', 'by', coalesce(nullif(btrim(u.full_name),''), 'Cashier'),
               'to', coalesce(nullif(btrim(c.handed_to_name),''), ''), 'amount', c.counted)
      FROM public.lwb_acc_day_close c LEFT JOIN public.user_profiles u ON u.id = c.closed_by
      WHERE c.close_date = $1 AND c.cancelled_at IS NULL AND NOT c.is_start
      ORDER BY c.closed_at DESC LIMIT 1 $q$ INTO c USING p_date;
  END IF;
  IF r IS NULL THEN RETURN c; END IF;
  IF c IS NULL THEN RETURN r; END IF;
  RETURN CASE WHEN (r->>'at')::timestamptz >= (c->>'at')::timestamptz THEN r ELSE c END;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- The report itself -> {rows, sum:{sales, received, purchase, paid, bank}, handover}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_evening_doc(p_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  d date := coalesce(p_date, (now() AT TIME ZONE 'Asia/Kolkata')::date);
  d3 date; m0 date; lo date; per text;
  rows jsonb := '[]'::jsonb; ov jsonb := '[]'::jsonb; x jsonb; b record; ho jsonb;
  W5 constant jsonb := '[0.07,0.13,0.42,0.22,0.16]'::jsonb;
  bank_tot numeric := 0; banks jsonb := '[]'::jsonb; cin jsonb := '[]'::jsonb; cout jsonb := '[]'::jsonb;
  parts jsonb := '[]'::jsonb;
  t_s numeric := 0; t_r numeric := 0; t_p numeric := 0; t_d numeric := 0;
  sect text; v_rows jsonb; v_today numeric; v_3 numeric; v_m numeric;
BEGIN
  d3 := d - 2; m0 := date_trunc('month', d)::date; lo := least(d3, m0);
  per := to_char(d3, 'DD/MM/YYYY') || ' - ' || to_char(d, 'DD/MM/YYYY');

  -- k: S sales bill, R payment received, P purchase bill, D payment done to the company
  CREATE TEMP TABLE IF NOT EXISTS lwb_ev_m (k text, day date, brand uuid, party text, ref text, amount numeric, at timestamptz) ON COMMIT DROP;
  DELETE FROM pg_temp.lwb_ev_m WHERE true;

  IF to_regprocedure('public.lwb_party_ledger_b()') IS NOT NULL THEN
    EXECUTE $q$
      INSERT INTO pg_temp.lwb_ev_m
      SELECT CASE WHEN l.entry_kind IN ('TALLY_BILL','ERP_BILL','OLD_INVOICE') THEN 'S' ELSE 'R' END, l.entry_date, l.company_id,
             upper(btrim(l.customer_name)), coalesce(nullif(btrim(l.ref_no),''), nullif(btrim(l.order_no),''), ''),
             CASE WHEN l.entry_kind IN ('TALLY_BILL','ERP_BILL','OLD_INVOICE') THEN coalesce(l.debit,0) ELSE coalesce(l.credit,0) END, l.created_at
      FROM public.lwb_party_ledger_b() l
      WHERE l.entry_date BETWEEN $1 AND $2
        AND l.entry_kind IN ('TALLY_BILL','ERP_BILL','OLD_INVOICE','PARTY_PAYMENT','PAYMENT','OFFICE_PAYMENT','DRIVER_PAYMENT') $q$ USING lo, d;
  END IF;
  IF to_regclass('public.lwb_goods_inward') IS NOT NULL AND to_regclass('public.lwb_goods_inward_items') IS NOT NULL THEN
    EXECUTE $q$
      INSERT INTO pg_temp.lwb_ev_m
      SELECT 'P', g.received_date, nullif(to_jsonb(g)->>'company_id','')::uuid,
             upper(coalesce(nullif(btrim(g.supplier_name),''), 'Supplier')), coalesce(to_jsonb(g)->>'invoice_no',''),
             (SELECT coalesce(sum(coalesce(i.total_amount,0)),0) FROM public.lwb_goods_inward_items i WHERE i.inward_id = g.id), NULL::timestamptz
      FROM public.lwb_goods_inward g WHERE g.received_date BETWEEN $1 AND $2 $q$ USING lo, d;
  END IF;
  IF to_regclass('public.lwb_company_payments') IS NOT NULL THEN
    EXECUTE $q$
      INSERT INTO pg_temp.lwb_ev_m
      SELECT 'D', p.pay_date, p.company_id, upper(coalesce(co.name::text, 'Company')),
             p.mode || coalesce(' ' || nullif(btrim(p.ref_no),''), ''), p.amount, p.created_at
      FROM public.lwb_company_payments p LEFT JOIN public.lwb_companies co ON co.id = p.company_id
      WHERE p.cancelled_at IS NULL AND p.mode <> 'CREDIT_NOTE' AND p.pay_date BETWEEN $1 AND $2 $q$ USING lo, d;
  END IF;
  DELETE FROM pg_temp.lwb_ev_m WHERE coalesce(amount,0) = 0;

  -- banks + cheques (one set for the whole business)
  IF to_regclass('public.lwb_acc_banks') IS NOT NULL AND to_regprocedure('public.lwb_acc_reset_bank_balance(bigint)') IS NOT NULL THEN
    EXECUTE $q$ SELECT coalesce(jsonb_agg(jsonb_build_object('name', b.name, 'no', b.account_no, 'bal', public.lwb_acc_reset_bank_balance(b.id)) ORDER BY b.name), '[]'::jsonb)
                FROM public.lwb_acc_banks b WHERE b.active $q$ INTO banks;
    SELECT coalesce(sum((e->>'bal')::numeric),0) INTO bank_tot FROM jsonb_array_elements(banks) e;
  END IF;
  IF to_regprocedure('public.lwb_acc_cheque_rows()') IS NOT NULL THEN
    EXECUTE $q$ SELECT coalesce(jsonb_agg(jsonb_build_object('party', upper(coalesce(nullif(btrim(r.party),''), '-')), 'no', coalesce(r.cheque_no,''),
                  'date', r.cheque_date, 'amount', r.amount) ORDER BY r.at), '[]'::jsonb)
                FROM public.lwb_acc_cheque_rows() r WHERE r.book_date = $1 $q$ INTO cin USING d;
  END IF;
  IF to_regclass('public.lwb_acc_entries') IS NOT NULL THEN
    EXECUTE $q$ SELECT coalesce(jsonb_agg(jsonb_build_object('party', upper(coalesce(nullif(btrim(e.party),''), '-')), 'no', coalesce(e.ref_no,''),
                  'date', e.entry_date, 'amount', e.amount) ORDER BY e.created_at), '[]'::jsonb)
                FROM public.lwb_acc_entries e WHERE e.kind = 'OUT' AND e.mode = 'CHEQUE' AND e.cancelled_at IS NULL AND e.entry_date = $1 $q$ INTO cout USING d;
  END IF;
  ho := public.lwb_ev_handover(d);

  -- ============ Page 1: all brands at a glance ============
  rows := jsonb_build_array(jsonb_build_array('h1', 'Daily Report', 'LUXURY WRIST BRAND · ALL BRANDS', per),
    jsonb_build_array('kv', 'Cash handover',
      CASE WHEN ho IS NULL THEN 'Not done yet'
           ELSE concat_ws(' · ', (ho->>'by') || CASE WHEN coalesce(ho->>'to','') <> '' THEN ' to ' || (ho->>'to') ELSE '' END,
                          '₹ ' || public.lwb_ev_num((ho->>'amount')::numeric),
                          to_char((ho->>'at')::timestamptz AT TIME ZONE 'Asia/Kolkata', 'HH12:MI AM')) END,
      CASE WHEN ho IS NULL THEN 'r' ELSE 'g' END),
    jsonb_build_array('kv', 'Total bank balance', '₹ ' || public.lwb_ev_num(bank_tot) || ' (as of today)', CASE WHEN bank_tot < 0 THEN 'r' ELSE 'b' END),
    jsonb_build_array('sec', 'Today, brand-wise'),
    jsonb_build_array('th', jsonb_build_array('BRAND','SALES','RECEIVED','PURCHASE','PAID'), '[0.32,0.17,0.17,0.17,0.17]'::jsonb));

  FOR b IN
    SELECT z.id, z.name FROM (
      SELECT co.id, co.name::text AS name FROM public.lwb_companies co
      WHERE EXISTS (SELECT 1 FROM pg_temp.lwb_ev_m m WHERE m.brand = co.id) OR coalesce((to_jsonb(co)->>'active')::boolean, true)
      UNION ALL
      SELECT NULL::uuid, 'Brand not set' WHERE EXISTS (SELECT 1 FROM pg_temp.lwb_ev_m m WHERE m.brand IS NULL)) z
    ORDER BY (z.id IS NULL), z.name
  LOOP
    ov := ov || jsonb_build_array(jsonb_build_array('tr', jsonb_build_array(upper(b.name),
      public.lwb_ev_num((SELECT coalesce(sum(amount),0) FROM pg_temp.lwb_ev_m WHERE k = 'S' AND day = d AND brand IS NOT DISTINCT FROM b.id)),
      public.lwb_ev_num((SELECT coalesce(sum(amount),0) FROM pg_temp.lwb_ev_m WHERE k = 'R' AND day = d AND brand IS NOT DISTINCT FROM b.id)),
      public.lwb_ev_num((SELECT coalesce(sum(amount),0) FROM pg_temp.lwb_ev_m WHERE k = 'P' AND day = d AND brand IS NOT DISTINCT FROM b.id)),
      public.lwb_ev_num((SELECT coalesce(sum(amount),0) FROM pg_temp.lwb_ev_m WHERE k = 'D' AND day = d AND brand IS NOT DISTINCT FROM b.id)))));

    -- ============ one part per brand, like the sample ============
    x := jsonb_build_array(jsonb_build_array('brk'),
           jsonb_build_array('h1', 'Daily Report', 'LUXURY WRIST BRAND (' || upper(b.name) || ')', per));
    FOREACH sect IN ARRAY ARRAY['S','R','P','D'] LOOP
      SELECT coalesce(sum(amount) FILTER (WHERE day = d),0), coalesce(sum(amount) FILTER (WHERE day >= d3),0), coalesce(sum(amount) FILTER (WHERE day >= m0),0)
        INTO v_today, v_3, v_m FROM pg_temp.lwb_ev_m WHERE k = sect AND brand IS NOT DISTINCT FROM b.id;
      SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(rn::text, to_char(day, 'DD/MM/YYYY'), party, ref, public.lwb_ev_num(amount))) ORDER BY rn), '[]'::jsonb)
        INTO v_rows
      FROM (SELECT *, row_number() OVER (ORDER BY day DESC, at DESC NULLS LAST, ref) rn FROM pg_temp.lwb_ev_m
            WHERE k = sect AND day >= d3 AND brand IS NOT DISTINCT FROM b.id) q;
      x := x || jsonb_build_array(
        jsonb_build_array('sec', CASE sect WHEN 'S' THEN 'Total Sales' WHEN 'R' THEN 'Total Payments Received' WHEN 'P' THEN 'Total Purchase' ELSE 'Total Payments Done' END),
        jsonb_build_array('sum', jsonb_build_array('Today - ₹ ' || public.lwb_ev_num(v_today), 'Last 3 days - ₹ ' || public.lwb_ev_num(v_3), 'This Month - ₹ ' || public.lwb_ev_num(v_m))));
      IF jsonb_array_length(v_rows) = 0 THEN
        x := x || jsonb_build_array(jsonb_build_array('note', CASE sect WHEN 'S' THEN '-- No sales in the last 3 days --' WHEN 'R' THEN '-- No payments received in the last 3 days --'
                                                                        WHEN 'P' THEN '-- No purchase in the last 3 days --' ELSE '-- No payments done in the last 3 days --' END));
      ELSE
        x := x || jsonb_build_array(jsonb_build_array('th', CASE sect
                 WHEN 'S' THEN jsonb_build_array('S.No.','Date','Customer Name','Invoice No.','Amount')
                 WHEN 'R' THEN jsonb_build_array('S.No.','Date','Customer Name','Mode / Ref.','Amount')
                 WHEN 'P' THEN jsonb_build_array('S.No.','Date','Vendor Name','Bill No.','Amount')
                 ELSE jsonb_build_array('S.No.','Date','Paid To','Mode / Ref.','Amount') END, W5))
             || v_rows
             || jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('', '', 'TOTAL · LAST 3 DAYS', jsonb_array_length(v_rows) || CASE WHEN jsonb_array_length(v_rows) = 1 THEN ' entry' ELSE ' entries' END, public.lwb_ev_num(v_3)), true,
                                  CASE sect WHEN 'R' THEN 'g' WHEN 'D' THEN 'r' END));
      END IF;
    END LOOP;
    -- an empty brand (nothing in these dates) is only a line on page 1
    IF EXISTS (SELECT 1 FROM pg_temp.lwb_ev_m WHERE brand IS NOT DISTINCT FROM b.id) THEN parts := parts || x; END IF;
  END LOOP;

  SELECT coalesce(sum(amount) FILTER (WHERE k = 'S'),0), coalesce(sum(amount) FILTER (WHERE k = 'R'),0),
         coalesce(sum(amount) FILTER (WHERE k = 'P'),0), coalesce(sum(amount) FILTER (WHERE k = 'D'),0)
    INTO t_s, t_r, t_p, t_d FROM pg_temp.lwb_ev_m WHERE day = d;
  rows := rows || ov || jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('ALL BRANDS', public.lwb_ev_num(t_s), public.lwb_ev_num(t_r),
            public.lwb_ev_num(t_p), public.lwb_ev_num(t_d)), true));

  -- bank + cheques on page 1, like the end of each company in the sample
  rows := rows || jsonb_build_array(jsonb_build_array('sec', 'Total Bank Balance: ₹ ' || public.lwb_ev_num(bank_tot) || ' (as of today)'));
  IF jsonb_array_length(banks) = 0 THEN
    rows := rows || jsonb_build_array(jsonb_build_array('note', '-- No bank account in Accounts --'));
  ELSE
    rows := rows || jsonb_build_array(jsonb_build_array('th', jsonb_build_array('S.No.','Account Name','Balance','Type'), '[0.08,0.46,0.30,0.16]'::jsonb))
         || (SELECT jsonb_agg(jsonb_build_array('tr', jsonb_build_array(i::text, (e->>'name') || coalesce(' · ' || nullif(e->>'no',''), ''),
                    public.lwb_ev_num((e->>'bal')::numeric), 'Bank'), false, CASE WHEN (e->>'bal')::numeric < 0 THEN 'r' END) ORDER BY i)
             FROM jsonb_array_elements(banks) WITH ORDINALITY z(e, i));
  END IF;
  rows := rows || jsonb_build_array(jsonb_build_array('sec', 'Total Cheques Received Today: ' || jsonb_array_length(cin) || ' of ₹ '
            || public.lwb_ev_num((SELECT coalesce(sum((e->>'amount')::numeric),0) FROM jsonb_array_elements(cin) e))));
  rows := rows || CASE WHEN jsonb_array_length(cin) = 0 THEN jsonb_build_array(jsonb_build_array('note', '-- No cheque received today --'))
    ELSE jsonb_build_array(jsonb_build_array('th', jsonb_build_array('Party Name','Cheque No.','Cheque Date','Amount')))
         || (SELECT jsonb_agg(jsonb_build_array('tr', jsonb_build_array(e->>'party', e->>'no', to_char((e->>'date')::date, 'DD/MM/YYYY'), public.lwb_ev_num((e->>'amount')::numeric))))
             FROM jsonb_array_elements(cin) e) END;
  rows := rows || jsonb_build_array(jsonb_build_array('sec', 'Total Cheques Given Today: ' || jsonb_array_length(cout) || ' of ₹ '
            || public.lwb_ev_num((SELECT coalesce(sum((e->>'amount')::numeric),0) FROM jsonb_array_elements(cout) e))));
  rows := rows || CASE WHEN jsonb_array_length(cout) = 0 THEN jsonb_build_array(jsonb_build_array('note', '-- No cheque given today --'))
    ELSE jsonb_build_array(jsonb_build_array('th', jsonb_build_array('Party Name','Cheque No.','Cheque Date','Amount')))
         || (SELECT jsonb_agg(jsonb_build_array('tr', jsonb_build_array(e->>'party', e->>'no', to_char((e->>'date')::date, 'DD/MM/YYYY'), public.lwb_ev_num((e->>'amount')::numeric))))
             FROM jsonb_array_elements(cout) e) END;

  rows := rows || parts;

  RETURN jsonb_build_object('who', 'ADMIN · EVENING REPORT', 'rows', rows, 'handover', ho,
    'sum', jsonb_build_object('sales', t_s, 'received', t_r, 'purchase', t_p, 'paid', t_d, 'bank', bank_tot,
                              'cheques_in', jsonb_array_length(cin), 'cheques_out', jsonb_array_length(cout)));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Admin calls
-- ---------------------------------------------------------------------------
-- Popup check (every few minutes): due = handover done today and this Admin has not downloaded yet.
CREATE OR REPLACE FUNCTION public.lwb_evening_due()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE d date := (now() AT TIME ZONE 'Asia/Kolkata')::date; ho jsonb; dl timestamptz;
BEGIN
  IF NOT public.lwb_ev_admin() THEN RETURN jsonb_build_object('due', false); END IF;
  ho := public.lwb_ev_handover(d);
  SELECT x.downloaded_at INTO dl FROM public.lwb_evening_report_dl x WHERE x.report_date = d AND x.user_id = auth.uid();
  RETURN jsonb_build_object('due', ho IS NOT NULL AND dl IS NULL, 'date', d, 'handover', ho, 'downloaded_at', dl);
END;
$fn$;

-- The report of one day (Admin): {date, doc, sum, handover, downloaded_at}
CREATE OR REPLACE FUNCTION public.lwb_evening_report(p_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE d date := coalesce(p_date, (now() AT TIME ZONE 'Asia/Kolkata')::date); r jsonb;
BEGIN
  IF NOT public.lwb_ev_admin() THEN RAISE EXCEPTION 'Only Admin can see the evening report'; END IF;
  IF d > (now() AT TIME ZONE 'Asia/Kolkata')::date THEN RAISE EXCEPTION 'Choose today or an earlier date'; END IF;
  r := public.lwb_evening_doc(d);
  RETURN jsonb_build_object('date', d, 'doc', jsonb_build_object('who', r->'who', 'rows', r->'rows'), 'sum', r->'sum', 'handover', r->'handover',
    'downloaded_at', (SELECT x.downloaded_at FROM public.lwb_evening_report_dl x WHERE x.report_date = d AND x.user_id = auth.uid()));
END;
$fn$;

-- Downloaded -> no more popup for that day.
CREATE OR REPLACE FUNCTION public.lwb_evening_mark(p_date date)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_ev_admin() THEN RAISE EXCEPTION 'Only Admin'; END IF;
  INSERT INTO public.lwb_evening_report_dl(report_date, user_id) VALUES (coalesce(p_date, (now() AT TIME ZONE 'Asia/Kolkata')::date), auth.uid())
  ON CONFLICT (report_date, user_id) DO UPDATE SET times = public.lwb_evening_report_dl.times + 1;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_ev_admin(), public.lwb_ev_num(numeric), public.lwb_ev_handover(date), public.lwb_evening_doc(date)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_evening_due(), public.lwb_evening_report(date), public.lwb_evening_mark(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_evening_due(), public.lwb_evening_report(date), public.lwb_evening_mark(date) TO authenticated;

COMMIT;

SELECT 'evening report ready' AS item, (to_regprocedure('public.lwb_evening_doc(date)') IS NOT NULL)::text AS value;
