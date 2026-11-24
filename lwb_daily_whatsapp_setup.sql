-- LUXURY WRIST BRAND ERP — DAILY WHATSAPP REPORTS AFTER CLOSE DAY (Mohit, 24 Nov 2026)
--
-- Runs by itself when merged to main. Safe to run again. Reads business data only:
-- no order, bill, stock, payment, ledger or cash row is changed. New: settings tables,
-- company MGR list (salesman -> MGR), a send log, and "focus parties" tasks for salesmen.
--
-- Mohit: "when Close Day (cash handover) is done, today's work is over: send everyone their own
-- report on WhatsApp, as an image like the PO image (purple table)."
--   SALESMAN  each salesman (own sales, product-wise, month target, tomorrow's target, focus parties)
--   MGR       one image per company MGR (his salesmen) -> Admin + Sales Head, they forward it
--             (MGRs are company people with no ERP login)
--   TEAM      Admin + Sales Head: MGR ranking 1st / 2nd ..., salesman ranking, month
--   ADMIN     Admin: sales, purchase, collection brand-wise, cash and bank, outstanding
--   ACCOUNTS  Accounts: party-wise payments, cash book, bank check / cheques pending
--   GODOWN    Godown Manager + Transport + Admin: vehicle-wise tons / cases / amount, delivery, returns, purchase in
--   DAYBOOK   Admin: the whole day as a PDF (like the accounts day book): orders, loading, delivery, money in / out,
--             purchase, returns, calls, tasks, and everything not done / pending, with full lists
--   A report longer than 40 lines also goes as a PDF instead of a cut image.
-- Admin turns people / reports on or off on Reports > WhatsApp Reports (whatsapp-reports.html).
--
-- When: cashier's Close Day (lwb_acc_day_close, not the first opening entry), once per date.
-- Back-up: nobody closed the day by the set time (default 23:00 IST) -> sent anyway.
-- Focus parties of the next working day also become one task per salesman (Tasks page).
-- The Edge Function lwb-daily-whatsapp draws each image and sends it with the Meta Cloud API
-- (same secrets as the login OTP). Nothing is sent until Admin turns it on.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_daily_wa_config (
  id integer PRIMARY KEY CHECK (id = 1),
  enabled boolean NOT NULL DEFAULT false,
  backup_time time DEFAULT '23:00',            -- NULL = no back-up send
  focus_tasks boolean NOT NULL DEFAULT true,   -- focus parties -> task for the salesman
  template text NOT NULL DEFAULT 'lwb_daily_report',
  lang text NOT NULL DEFAULT 'en',
  project_url text NOT NULL DEFAULT 'https://qstgwhbgbznxemajtave.supabase.co',
  webhook_secret text NOT NULL DEFAULT encode(extensions.gen_random_bytes(32), 'hex'),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
INSERT INTO public.lwb_daily_wa_config(id) VALUES (1) ON CONFLICT DO NOTHING;
-- PDF reports (Day Book, long lists) use a template with a DOCUMENT header.
ALTER TABLE public.lwb_daily_wa_config ADD COLUMN IF NOT EXISTS template_doc text NOT NULL DEFAULT 'lwb_daily_report_pdf';

-- Company MGRs (no ERP login) and which salesman works under which MGR.
CREATE TABLE IF NOT EXISTS public.lwb_company_mgrs (
  id bigserial PRIMARY KEY,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  company_id uuid,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_company_mgrs_name ON public.lwb_company_mgrs (upper(btrim(name)));
CREATE TABLE IF NOT EXISTS public.lwb_salesman_mgr (
  user_id uuid PRIMARY KEY REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  mgr_id bigint NOT NULL REFERENCES public.lwb_company_mgrs(id) ON DELETE CASCADE,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

-- A row only when Admin changed the default for that person / report.
CREATE TABLE IF NOT EXISTS public.lwb_daily_wa_people (
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('SALESMAN','MGR','TEAM','ADMIN','ACCOUNTS','GODOWN','DAYBOOK')),
  enabled boolean NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  PRIMARY KEY (user_id, kind)
);
ALTER TABLE public.lwb_daily_wa_people DROP CONSTRAINT IF EXISTS lwb_daily_wa_people_kind_check;
ALTER TABLE public.lwb_daily_wa_people ADD CONSTRAINT lwb_daily_wa_people_kind_check
  CHECK (kind IN ('SALESMAN','MGR','TEAM','ADMIN','ACCOUNTS','GODOWN','DAYBOOK'));

CREATE TABLE IF NOT EXISTS public.lwb_daily_wa_runs (
  report_date date PRIMARY KEY,
  trigger text NOT NULL,
  at timestamptz NOT NULL DEFAULT now(),
  by_user uuid
);

CREATE TABLE IF NOT EXISTS public.lwb_daily_wa_log (
  id bigserial PRIMARY KEY,
  report_date date NOT NULL,
  kind text NOT NULL,
  report_key text NOT NULL DEFAULT '',          -- which report (salesman id / MGR id) for MGR / SALESMAN
  user_id uuid,
  name text,
  mobile text,                                  -- last 4 digits only
  test boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'QUEUED' CHECK (status IN ('QUEUED','SENT','FAILED')),
  wa_message_id text,
  error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_daily_wa_log_once ON public.lwb_daily_wa_log (report_date, kind, report_key, user_id) WHERE NOT test;
CREATE INDEX IF NOT EXISTS lwb_daily_wa_log_date ON public.lwb_daily_wa_log (report_date);

ALTER TABLE public.lwb_daily_wa_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_company_mgrs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_salesman_mgr ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_daily_wa_people ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_daily_wa_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_daily_wa_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_daily_wa_config, public.lwb_company_mgrs, public.lwb_salesman_mgr, public.lwb_daily_wa_people,
  public.lwb_daily_wa_runs, public.lwb_daily_wa_log FROM PUBLIC, anon, authenticated;
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT SELECT ON public.lwb_daily_wa_config TO service_role;
  END IF;
END $g$;

-- ---------------------------------------------------------------------------
-- 2. Small helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_wa_num(p numeric)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $fn$
DECLARE s text := round(abs(coalesce(p,0)))::bigint::text; h text; o text;
BEGIN
  IF length(s) > 3 THEN
    o := right(s, 3); h := left(s, length(s) - 3);
    WHILE length(h) > 2 LOOP o := right(h, 2) || ',' || o; h := left(h, length(h) - 2); END LOOP;
    s := h || ',' || o;
  END IF;
  RETURN CASE WHEN coalesce(p,0) <= -0.5 THEN '-' ELSE '' END || s;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_wa_inr(p numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT CASE WHEN coalesce(p,0) <= -0.5 THEN '-₹ ' || public.lwb_wa_num(-p) ELSE '₹ ' || public.lwb_wa_num(p) END $fn$;

CREATE OR REPLACE FUNCTION public.lwb_wa_ton(p_kg numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT to_char(round(coalesce(p_kg,0) / 1000.0, 1), 'FM999990.0') $fn$;

-- [{u:'cs',q:590},{u:'IC',q:120}] -> "590 cs · 120 IC"
CREATE OR REPLACE FUNCTION public.lwb_wa_qty(p jsonb)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT coalesce(string_agg(public.lwb_wa_num((x->>'q')::numeric) || ' ' || (x->>'u'), ' · ' ORDER BY x->>'u' DESC), '0')
  FROM jsonb_array_elements(coalesce(p, '[]'::jsonb)) x WHERE round(coalesce((x->>'q')::numeric,0)) <> 0
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_daily_wa_mobile(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE WHEN length(d) >= 10 AND right(d, 10) ~ '^[6-9]' THEN right(d, 10) END
  FROM (SELECT regexp_replace(coalesce(p,''), '\D', '', 'g') AS d) x
$fn$;

-- Default receivers of each report by role (Admin can change per person).
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_default(p_role text, p_kind text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE p_kind
    WHEN 'SALESMAN' THEN r IN ('sales','salesman')
    WHEN 'MGR' THEN r IN ('admin','manager')
    WHEN 'TEAM' THEN r IN ('admin','manager')
    WHEN 'ADMIN' THEN r = 'admin'
    WHEN 'DAYBOOK' THEN r = 'admin'
    WHEN 'ACCOUNTS' THEN r = 'accounts'
    WHEN 'GODOWN' THEN r IN ('admin','warehouse','transport')
    ELSE false END
  FROM (SELECT lower(btrim(coalesce(p_role,''))) AS r) x
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_daily_wa_people_list()
RETURNS TABLE (user_id uuid, name text, role text, mobile text, kinds jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT p.id, coalesce(nullif(btrim(p.full_name),''), 'User')::text, lower(btrim(coalesce(p.role,'')))::text,
         public.lwb_daily_wa_mobile(p.mobile::text),
         (SELECT jsonb_object_agg(k.kind, coalesce(x.enabled, public.lwb_daily_wa_default(p.role, k.kind)))
          FROM unnest(ARRAY['SALESMAN','MGR','TEAM','ADMIN','ACCOUNTS','GODOWN','DAYBOOK']) AS k(kind)
          LEFT JOIN public.lwb_daily_wa_people x ON x.user_id = p.id AND x.kind = k.kind)
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(coalesce(p.role,''))) <> 'driver'
$fn$;

REVOKE ALL ON FUNCTION public.lwb_wa_num(numeric), public.lwb_wa_inr(numeric), public.lwb_wa_ton(numeric), public.lwb_wa_qty(jsonb),
  public.lwb_daily_wa_mobile(text), public.lwb_daily_wa_default(text, text), public.lwb_daily_wa_people_list()
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_wa_days(p integer)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT CASE WHEN coalesce(p,0) <= 0 THEN 'Today' WHEN p = 1 THEN '1 day' ELSE p || ' days' END $fn$;
REVOKE ALL ON FUNCTION public.lwb_wa_days(integer) FROM PUBLIC, anon, authenticated;

-- Long lists: first p_cap rows + "+ N more"; empty list -> one "nothing" row.
CREATE OR REPLACE FUNCTION public.lwb_wa_cap(p jsonb, p_cap integer, p_none text DEFAULT 'Nothing')
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE
    WHEN jsonb_array_length(coalesce(p, '[]'::jsonb)) = 0 THEN jsonb_build_array(jsonb_build_array('tr', jsonb_build_array(p_none, '', '', '')))
    WHEN jsonb_array_length(p) <= p_cap THEN p
    ELSE (SELECT jsonb_agg(e ORDER BY i) FROM jsonb_array_elements(p) WITH ORDINALITY z(e, i) WHERE i <= p_cap)
         || jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('+ ' || (jsonb_array_length(p) - p_cap) || ' more (see ERP)', '', '', ''))) END
$fn$;
REVOKE ALL ON FUNCTION public.lwb_wa_cap(jsonb, integer, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Admin DAY BOOK (sent as a PDF): the whole day's work like the accounts day book —
-- what was done, what was not, what is pending, with full lists.
-- Called by lwb_daily_wa_build after it filled its scratch tables (pg_temp.lwb_wa_o / _v / _del / _l / _in).
-- p_cash = {open, open_set, close, close_set}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_daybook(p_date date, p_closed jsonb, p_cash jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  d date := p_date; dd text := to_char(p_date, 'DD/MM/YYYY');
  cap constant integer := 150;
  head jsonb; body jsonb := '[]'::jsonb; x jsonb; n integer; a numeric; n2 integer; a2 numeric; n3 integer; txt text;
  v_marks boolean := to_regclass('public.lwb_admin_order_marks') IS NOT NULL;
  v_gi boolean := to_regclass('public.lwb_goods_inward') IS NOT NULL AND to_regclass('public.lwb_goods_inward_items') IS NOT NULL;
  v_calls boolean := to_regclass('public.lwb_party_calls') IS NOT NULL;
  v_tasks boolean := to_regclass('public.lwb_tasks') IS NOT NULL;
  v_comp boolean := to_regclass('public.lwb_complaints') IS NOT NULL;
  v_pret boolean := to_regclass('public.lwb_party_returns') IS NOT NULL;
  v_rets boolean := to_regclass('public.lwb_driver_delivery_returns') IS NOT NULL AND to_regclass('public.lwb_driver_delivery_return_items') IS NOT NULL;
  v_ver boolean := to_regprocedure('public.lwb_acc_lines()') IS NOT NULL AND to_regclass('public.lwb_acc_verify') IS NOT NULL;
  v_chq boolean := to_regprocedure('public.lwb_acc_lines()') IS NOT NULL AND to_regclass('public.lwb_acc_cheques') IS NOT NULL;
  s_calls text := '-'; s_tasks text := '-'; s_comp text := '-'; s_ret text := '-'; s_pur text := '-'; s_bank text := '-'; s_chq text := '-';
  bad_tasks boolean := false; bad_bank boolean := false; bad_chq boolean := false; bad_comp boolean := false;
BEGIN
  -- open orders that still need work (any date up to this day)
  CREATE TEMP TABLE IF NOT EXISTS lwb_wa_pend (id uuid, order_no text, party text, person text, amount numeric, days integer, stage text) ON COMMIT DROP;
  DELETE FROM pg_temp.lwb_wa_pend WHERE true;
  INSERT INTO pg_temp.lwb_wa_pend
  SELECT o.id, o.order_no::text, upper(btrim(o.customer_name)), coalesce(nullif(btrim(o.sales_person),''), nullif(btrim(cb.full_name),''), '-'),
         coalesce(o.total_amount,0), d - (timezone('Asia/Kolkata', o.order_date::timestamptz))::date,
         CASE WHEN lower(btrim(coalesce(o.status,''))) IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new') THEN 'APPROVAL'
              WHEN lower(btrim(o.status)) IN ('approved','transport_allocated','allocated','loading') THEN 'LOADING'
              ELSE 'DELIVERY' END
  FROM public.orders o LEFT JOIN public.user_profiles cb ON cb.id = o.created_by
  WHERE lower(btrim(coalesce(o.status,''))) IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new',
                                                'approved','transport_allocated','allocated','loading','loaded','invoiced','dispatched')
    AND (timezone('Asia/Kolkata', o.order_date::timestamptz))::date <= d
    AND NOT EXISTS (SELECT 1 FROM public.lwb_delivery_reports z WHERE z.order_id = o.id AND z.delivery_status IN ('DELIVERED','PARTIAL'));
  IF v_marks THEN
    EXECUTE 'DELETE FROM pg_temp.lwb_wa_pend p WHERE EXISTS (SELECT 1 FROM public.lwb_admin_order_marks m WHERE m.order_id = p.id AND m.kind = ''DELIVERED'')';
  END IF;

  -- ---------- 1. Orders of the day ----------
  SELECT count(*), coalesce(sum(amount),0) INTO n, a FROM pg_temp.lwb_wa_o WHERE day = d;
  SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(coalesce(o.order_no::text,'') || ' · ' || o.party,
            initcap(split_part(coalesce(nullif(btrim(pp.full_name),''), nullif(btrim(ord.sales_person),''), '-'), ' ', 1)),
            initcap(replace(coalesce(nullif(btrim(ord.status),''),'pending'), '_', ' ')), public.lwb_wa_num(o.amount))) ORDER BY ord.order_date, o.order_no), '[]'::jsonb)
    INTO x
  FROM pg_temp.lwb_wa_o o JOIN public.orders ord ON ord.id = o.id LEFT JOIN public.user_profiles pp ON pp.id = o.person_id WHERE o.day = d;
  body := body || jsonb_build_array(jsonb_build_array('sec', '1. Orders today · ' || n || ' PO · ' || public.lwb_wa_inr(a)),
            jsonb_build_array('th', jsonb_build_array('PO · PARTY','SALESMAN','STATUS','AMOUNT')))
          || public.lwb_wa_cap(x, cap, 'No order today');
  IF n > 0 THEN body := body || jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('TOTAL', n || ' PO', '', public.lwb_wa_num(a)), true)); END IF;

  -- ---------- 2. Loading (vehicle-wise) ----------
  SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(t || ' · ' || c || ' PO', public.lwb_wa_ton(kg), q, public.lwb_wa_num(amt))) ORDER BY kg DESC), '[]'::jsonb) INTO x
  FROM (SELECT upper(max(vno)) || coalesce(' · ' || upper(max(driver)), '') t, count(*) c, sum(kg) kg, sum(amount) amt,
               public.lwb_wa_qty((SELECT jsonb_agg(jsonb_build_object('u',u,'q',q)) FROM (SELECT y.unit u, sum(y.qty) q FROM pg_temp.lwb_wa_v y WHERE y.vkey = v.vkey GROUP BY 1) z)) q
        FROM pg_temp.lwb_wa_v v GROUP BY vkey) q;
  SELECT count(*), coalesce(sum(amount),0), count(DISTINCT vkey) INTO n, a, n2 FROM pg_temp.lwb_wa_v;
  body := body || jsonb_build_array(jsonb_build_array('sec', '2. Loading · ' || n2 || CASE WHEN n2 = 1 THEN ' vehicle · ' ELSE ' vehicles · ' END || n || ' PO'),
            jsonb_build_array('th', jsonb_build_array('VEHICLE / DRIVER','TON','CASE','AMOUNT')))
          || public.lwb_wa_cap(x, cap, 'No vehicle loaded');
  IF n > 0 THEN
    body := body || (SELECT jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('TOTAL · ' || n || ' PO', public.lwb_wa_ton(sum(kg)),
              public.lwb_wa_qty((SELECT jsonb_agg(jsonb_build_object('u',u,'q',q)) FROM (SELECT unit u, sum(qty) q FROM pg_temp.lwb_wa_v GROUP BY 1) z)),
              public.lwb_wa_num(sum(amount))), true)) FROM pg_temp.lwb_wa_v);
  END IF;

  -- ---------- 3. Delivered ----------
  SELECT count(*), coalesce(sum(amount),0) INTO n, a FROM pg_temp.lwb_wa_del;
  SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(z.party, coalesce(o.order_no::text,''), '', public.lwb_wa_num(z.amount))) ORDER BY z.party), '[]'::jsonb) INTO x
  FROM pg_temp.lwb_wa_del z LEFT JOIN public.orders o ON o.id = z.id;
  body := body || jsonb_build_array(jsonb_build_array('sec', '3. Delivered · ' || n || ' PO · ' || public.lwb_wa_inr(a)),
            jsonb_build_array('th', jsonb_build_array('PARTY','PO','','AMOUNT')))
          || public.lwb_wa_cap(x, cap, 'Nothing delivered');
  IF n > 0 THEN body := body || jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('TOTAL', n || ' PO', '', public.lwb_wa_num(a)), true, 'g')); END IF;

  -- ---------- 4. Money in (every entry) ----------
  SELECT count(*), coalesce(sum(amount),0) INTO n, a FROM pg_temp.lwb_wa_in;
  SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(upper(coalesce(nullif(btrim(party),''), 'Other')) || coalesce(' · PO ' || nullif(order_no,''), ''),
            upper(brand), m, public.lwb_wa_num(amount))) ORDER BY amount DESC), '[]'::jsonb) INTO x FROM pg_temp.lwb_wa_in;
  body := body || jsonb_build_array(jsonb_build_array('sec', '4. Money in · ' || n || ' entries · ' || public.lwb_wa_inr(a)),
            jsonb_build_array('th', jsonb_build_array('PARTY','BRAND','MODE','AMOUNT')))
          || public.lwb_wa_cap(x, cap, 'No payment today');
  IF n > 0 THEN
    body := body || (SELECT jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('TOTAL', '', '', public.lwb_wa_num(sum(amount))), true, 'g'),
              jsonb_build_array('kv', 'Cash', public.lwb_wa_inr(coalesce(sum(amount) FILTER (WHERE m = 'CASH'),0))),
              jsonb_build_array('kv', 'Bank / UPI / cheque', public.lwb_wa_inr(coalesce(sum(amount) FILTER (WHERE m <> 'CASH'),0)))) FROM pg_temp.lwb_wa_in);
  END IF;

  -- ---------- 5. Money out / bank ----------
  SELECT count(*), coalesce(sum(amount),0) INTO n, a FROM pg_temp.lwb_wa_l WHERE kind IN ('OUT','DEPOSIT','WITHDRAW');
  SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(
            coalesce(nullif(concat_ws(' · ', nullif(btrim(category),''), nullif(btrim(party),''), nullif(btrim(remark),'')), ''), initcap(kind)),
            CASE kind WHEN 'OUT' THEN 'Paid' WHEN 'DEPOSIT' THEN 'To bank' ELSE 'From bank' END, coalesce(mode,''), public.lwb_wa_num(amount)),
            false, CASE WHEN kind = 'OUT' THEN 'r' END) ORDER BY kind DESC, amount DESC), '[]'::jsonb) INTO x
  FROM pg_temp.lwb_wa_l WHERE kind IN ('OUT','DEPOSIT','WITHDRAW');
  body := body || jsonb_build_array(jsonb_build_array('sec', '5. Money out & bank · ' || n || ' entries'),
            jsonb_build_array('th', jsonb_build_array('DETAIL','TYPE','MODE','AMOUNT')))
          || public.lwb_wa_cap(x, cap, 'No expense / bank entry');
  body := body || jsonb_build_array(
    jsonb_build_array('kv', 'Opening cash', CASE WHEN (p_cash->>'open_set')::boolean THEN public.lwb_wa_inr((p_cash->>'open')::numeric) ELSE 'Not set' END),
    jsonb_build_array('kv', 'Closing cash', CASE WHEN (p_cash->>'close_set')::boolean THEN public.lwb_wa_inr((p_cash->>'close')::numeric)
        || CASE WHEN p_closed IS NULL THEN ' (day not closed)' WHEN abs(coalesce((p_closed->>'counted')::numeric, (p_cash->>'close')::numeric) - (p_cash->>'close')::numeric) < 1 THEN ' (counted ✓)'
                ELSE ' (counted ' || public.lwb_wa_inr((p_closed->>'counted')::numeric) || ')' END ELSE 'Not set' END,
      CASE WHEN p_closed IS NULL THEN 'r' ELSE 'g' END));

  -- ---------- 6. Purchase bills ----------
  n := 0; a := 0; x := '[]'::jsonb;
  IF v_gi THEN
    EXECUTE 'SELECT count(*), coalesce(sum(t),0), coalesce(jsonb_agg(jsonb_build_array(''tr'', jsonb_build_array(
                upper(coalesce(nullif(btrim(supplier_name),''''), ''Supplier'')) || coalesce('' · '' || nullif(inv,''''), ''''), c::text, '''', public.lwb_wa_num(t))) ORDER BY t DESC), ''[]''::jsonb)
             FROM (SELECT g.supplier_name, to_jsonb(g)->>''invoice_no'' inv,
                          (SELECT count(*) FROM public.lwb_goods_inward_items i WHERE i.inward_id = g.id) c,
                          (SELECT coalesce(sum(coalesce(i.total_amount,0)),0) FROM public.lwb_goods_inward_items i WHERE i.inward_id = g.id) t
                   FROM public.lwb_goods_inward g WHERE g.received_date = $1) q' INTO n, a, x USING d;
  END IF;
  s_pur := n || CASE WHEN n = 1 THEN ' bill · ' ELSE ' bills · ' END || public.lwb_wa_inr(a);
  body := body || jsonb_build_array(jsonb_build_array('sec', '6. Purchase in · ' || s_pur),
            jsonb_build_array('th', jsonb_build_array('SUPPLIER · BILL','ITEMS','','AMOUNT')))
          || public.lwb_wa_cap(x, cap, 'No purchase bill');

  -- ---------- 7. Returns ----------
  x := '[]'::jsonb; n := 0; a := 0; n2 := 0; a2 := 0;
  IF v_pret THEN
    EXECUTE 'SELECT count(*), coalesce(sum(r.amount),0), coalesce(jsonb_agg(jsonb_build_array(''tr'', jsonb_build_array(upper(btrim(r.party)), r.return_no, ''CN'', public.lwb_wa_num(r.amount))) ORDER BY r.amount DESC), ''[]''::jsonb)
             FROM public.lwb_party_returns r WHERE r.return_date = $1 AND r.cancelled_at IS NULL' INTO n, a, x USING d;
  END IF;
  IF v_rets THEN
    EXECUTE 'SELECT count(DISTINCT h.order_id), coalesce(sum(i.qty_cases),0) FROM public.lwb_driver_delivery_returns h
             JOIN public.lwb_driver_delivery_return_items i ON i.return_id = h.id
             WHERE h.status <> ''REJECTED'' AND (timezone(''Asia/Kolkata'', h.created_at))::date = $1' INTO n2, a2 USING d;
    IF n2 > 0 THEN x := x || jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('Driver returns', n2 || ' PO', public.lwb_wa_num(a2) || ' cs', ''))); END IF;
  END IF;
  s_ret := public.lwb_wa_inr(a) || CASE WHEN n2 > 0 THEN ' · ' || public.lwb_wa_num(a2) || ' cs from drivers' ELSE '' END;
  body := body || jsonb_build_array(jsonb_build_array('sec', '7. Returns · ' || s_ret),
            jsonb_build_array('th', jsonb_build_array('PARTY','NO.','TYPE','AMOUNT')))
          || public.lwb_wa_cap(x, cap, 'No return');

  -- ---------- 8. Party calls (salesman-wise) ----------
  IF v_calls THEN
    EXECUTE 'SELECT count(*), count(*) FILTER (WHERE result = ''ORDER_TAKEN'') FROM public.lwb_party_calls WHERE call_date = $1' INTO n, n2 USING d;
    EXECUTE 'SELECT coalesce(jsonb_agg(jsonb_build_array(''tr'', jsonb_build_array(nm, c::text, o::text, nn::text), false, CASE WHEN o = 0 THEN ''r'' END) ORDER BY c DESC), ''[]''::jsonb)
             FROM (SELECT upper(coalesce(nullif(btrim(called_by_name),''''), ''-'')) nm, count(*) c,
                          count(*) FILTER (WHERE result = ''ORDER_TAKEN'') o, count(*) FILTER (WHERE result IN (''NO_ORDER'',''NOT_REACHABLE'')) nn
                   FROM public.lwb_party_calls WHERE call_date = $1 GROUP BY 1) q' INTO x USING d;
    s_calls := n || ' calls · ' || n2 || ' orders';
    body := body || jsonb_build_array(jsonb_build_array('sec', '8. Party calls · ' || s_calls),
              jsonb_build_array('th', jsonb_build_array('CALLED BY','CALLS','ORDER','NO ORDER')))
            || public.lwb_wa_cap(x, cap, 'No call saved today');
  END IF;

  -- ---------- 9. Tasks (person-wise) ----------
  IF v_tasks THEN
    EXECUTE 'SELECT count(*) FILTER (WHERE status = ''DONE'' AND (timezone(''Asia/Kolkata'', done_at))::date = $1),
                    count(*) FILTER (WHERE status IN (''OPEN'',''IN_PROGRESS'')),
                    count(*) FILTER (WHERE status IN (''OPEN'',''IN_PROGRESS'') AND due_date < $1)
             FROM public.lwb_tasks' INTO n, n2, n3 USING d;
    EXECUTE 'SELECT coalesce(jsonb_agg(jsonb_build_array(''tr'', jsonb_build_array(nm, dn::text, op::text, lt::text), false, CASE WHEN lt > 0 THEN ''r'' END) ORDER BY lt DESC, op DESC, nm), ''[]''::jsonb)
             FROM (SELECT upper(coalesce(nullif(btrim(assigned_to_name),''''), ''-'')) nm,
                          count(*) FILTER (WHERE status = ''DONE'' AND (timezone(''Asia/Kolkata'', done_at))::date = $1) dn,
                          count(*) FILTER (WHERE status IN (''OPEN'',''IN_PROGRESS'')) op,
                          count(*) FILTER (WHERE status IN (''OPEN'',''IN_PROGRESS'') AND due_date < $1) lt
                   FROM public.lwb_tasks GROUP BY 1) q WHERE dn + op > 0' INTO x USING d;
    s_tasks := n || ' done · ' || n2 || ' open · ' || n3 || ' late'; bad_tasks := n3 > 0;
    body := body || jsonb_build_array(jsonb_build_array('sec', '9. Tasks · ' || s_tasks),
              jsonb_build_array('th', jsonb_build_array('PERSON','DONE','OPEN','LATE')))
            || public.lwb_wa_cap(x, cap, 'No task');
  END IF;

  -- ---------- 10. Pending work ----------
  body := body || jsonb_build_array(jsonb_build_array('sec', 'PENDING WORK'));
  FOR txt IN SELECT unnest(ARRAY['APPROVAL','LOADING','DELIVERY']) LOOP
    SELECT count(*), coalesce(sum(amount),0) INTO n, a FROM pg_temp.lwb_wa_pend WHERE stage = txt;
    SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(coalesce(order_no,'') || ' · ' || party, initcap(split_part(person, ' ', 1)), public.lwb_wa_days(days),
              public.lwb_wa_num(amount)), false, CASE WHEN days >= 2 THEN 'r' END) ORDER BY days DESC, order_no), '[]'::jsonb) INTO x
    FROM pg_temp.lwb_wa_pend WHERE stage = txt;
    body := body || jsonb_build_array(
              jsonb_build_array('sec', CASE txt WHEN 'APPROVAL' THEN '10. Waiting approval' WHEN 'LOADING' THEN '11. Approved, not loaded' ELSE '12. Loaded, not delivered' END
                                       || ' · ' || n || ' PO · ' || public.lwb_wa_inr(a)),
              jsonb_build_array('th', jsonb_build_array('PO · PARTY','SALESMAN','OLD','AMOUNT')))
            || public.lwb_wa_cap(x, cap, 'Nothing pending');
  END LOOP;

  IF v_ver THEN
    EXECUTE 'SELECT count(*), coalesce(sum(l.amount),0) FROM public.lwb_acc_lines() l WHERE l.needs_verify
             AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_verify v WHERE v.src = l.src AND v.src_id = l.id)' INTO n, a;
    s_bank := CASE WHEN n = 0 THEN 'Nothing pending' ELSE public.lwb_wa_inr(a) || ' (' || n || ' entries)' END; bad_bank := n > 0;
  END IF;
  IF v_chq THEN
    EXECUTE 'SELECT count(*), coalesce(sum(l.amount),0) FROM public.lwb_acc_cheques c JOIN public.lwb_acc_lines() l ON l.src = c.src AND l.id = c.src_id
             WHERE c.deposited_on IS NULL AND coalesce(c.cheque_date, l.book_date) <= $1' INTO n, a USING d;
    s_chq := CASE WHEN n = 0 THEN 'None' ELSE n || ' · ' || public.lwb_wa_inr(a) END; bad_chq := n > 0;
  END IF;
  body := body || jsonb_build_array(jsonb_build_array('sec', '13. Accounts pending'),
    jsonb_build_array('kv', 'Bank not checked', s_bank, CASE WHEN bad_bank THEN 'r' END),
    jsonb_build_array('kv', 'Cheques to deposit', s_chq, CASE WHEN bad_chq THEN 'r' END));

  IF v_comp THEN
    EXECUTE 'SELECT count(*), coalesce(jsonb_agg(jsonb_build_array(''tr'', jsonb_build_array(upper(c.category) || '' · '' || c.subject,
                initcap(split_part(coalesce(c.created_by_name,''-''), '' '', 1)), public.lwb_wa_days($1 - (timezone(''Asia/Kolkata'', c.created_at))::date), initcap(c.status)),
                false, CASE WHEN c.urgent THEN ''r'' END) ORDER BY c.urgent DESC, c.created_at), ''[]''::jsonb)
             FROM public.lwb_complaints c WHERE c.status <> ''RESOLVED''' INTO n, x USING d;
    s_comp := n || ' open'; bad_comp := n > 0;
    body := body || jsonb_build_array(jsonb_build_array('sec', '14. Complaints open · ' || n),
              jsonb_build_array('th', jsonb_build_array('COMPLAINT','BY','OLD','STATUS')))
            || public.lwb_wa_cap(x, cap, 'No open complaint');
  END IF;

  -- ---------- Summary on top ----------
  head := jsonb_build_array(
    jsonb_build_array('kv', 'Date', dd || coalesce(' · Day closed ' || (p_closed->>'at'), ' · Day not closed'), CASE WHEN p_closed IS NULL THEN 'r' END),
    jsonb_build_array('sec', 'Done today'),
    jsonb_build_array('kv', 'Orders', (SELECT count(*) || ' PO · ' || public.lwb_wa_inr(coalesce(sum(amount),0)) FROM pg_temp.lwb_wa_o WHERE day = d)),
    jsonb_build_array('kv', 'Loaded', (SELECT count(*) || ' PO · ' || count(DISTINCT vkey) || ' vehicles · ' || public.lwb_wa_inr(coalesce(sum(amount),0)) FROM pg_temp.lwb_wa_v)),
    jsonb_build_array('kv', 'Delivered', (SELECT count(*) || ' PO · ' || public.lwb_wa_inr(coalesce(sum(amount),0)) FROM pg_temp.lwb_wa_del), 'g'),
    jsonb_build_array('kv', 'Money in', (SELECT public.lwb_wa_inr(coalesce(sum(amount),0)) || ' · ' || count(*) || ' entries' FROM pg_temp.lwb_wa_in), 'g'),
    jsonb_build_array('kv', 'Money out', (SELECT public.lwb_wa_inr(coalesce(sum(amount) FILTER (WHERE kind = 'OUT'),0)) || ' · bank deposit ' ||
                                                 public.lwb_wa_inr(coalesce(sum(amount) FILTER (WHERE kind = 'DEPOSIT'),0)) FROM pg_temp.lwb_wa_l)),
    jsonb_build_array('kv', 'Purchase in', s_pur),
    jsonb_build_array('kv', 'Returns', s_ret),
    jsonb_build_array('kv', 'Party calls', s_calls),
    jsonb_build_array('kv', 'Tasks', s_tasks, CASE WHEN bad_tasks THEN 'r' END),
    jsonb_build_array('sec', 'Not done / pending'),
    jsonb_build_array('kv', 'Waiting approval', (SELECT count(*) || ' PO · ' || public.lwb_wa_inr(coalesce(sum(amount),0)) FROM pg_temp.lwb_wa_pend WHERE stage = 'APPROVAL'),
       (SELECT CASE WHEN count(*) > 0 THEN 'r' END FROM pg_temp.lwb_wa_pend WHERE stage = 'APPROVAL')),
    jsonb_build_array('kv', 'Not loaded', (SELECT count(*) || ' PO · ' || public.lwb_wa_inr(coalesce(sum(amount),0)) FROM pg_temp.lwb_wa_pend WHERE stage = 'LOADING'),
       (SELECT CASE WHEN count(*) > 0 THEN 'r' END FROM pg_temp.lwb_wa_pend WHERE stage = 'LOADING')),
    jsonb_build_array('kv', 'Not delivered', (SELECT count(*) || ' PO · ' || public.lwb_wa_inr(coalesce(sum(amount),0)) FROM pg_temp.lwb_wa_pend WHERE stage = 'DELIVERY'),
       (SELECT CASE WHEN count(*) > 0 THEN 'r' END FROM pg_temp.lwb_wa_pend WHERE stage = 'DELIVERY')),
    jsonb_build_array('kv', 'Bank not checked', s_bank, CASE WHEN bad_bank THEN 'r' END),
    jsonb_build_array('kv', 'Cheques to deposit', s_chq, CASE WHEN bad_chq THEN 'r' END),
    jsonb_build_array('kv', 'Complaints', s_comp, CASE WHEN bad_comp THEN 'r' END));
  RETURN head || body;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_daily_wa_daybook(date, jsonb, jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Build every report of one day (IST).
--    -> {date, closed, reports:[{kind, key, title, who, doc:{who, rows}, focus:[..] (salesman)}],
--        people:[{user_id, name, role, mobile, kinds}]}
--    doc rows: ["kv",label,value,tone] ["sec",text] ["th",[4]] ["tr",[4],total,tone]  (tone g / r / b)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_build(p_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  d date := coalesce(p_date, (now() AT TIME ZONE 'Asia/Kolkata')::date);
  m0 date; nd date; dd text; mon text;
  reps jsonb := '[]'::jsonb; rows jsonb; r record; s record;
  v_marks boolean := to_regclass('public.lwb_admin_order_marks') IS NOT NULL;
  v_plan boolean := to_regprocedure('public.lwb_build_sales_plan(uuid,date)') IS NOT NULL;
  v_tgt boolean := to_regclass('public.lwb_sales_targets') IS NOT NULL;
  v_gi boolean := to_regclass('public.lwb_goods_inward') IS NOT NULL AND to_regclass('public.lwb_goods_inward_items') IS NOT NULL;
  v_acc boolean := to_regprocedure('public.lwb_acc_lines()') IS NOT NULL;
  v_cash boolean := to_regprocedure('public.lwb_acc_cash_at(date)') IS NOT NULL;
  v_led boolean := to_regprocedure('public.lwb_party_ledger_b()') IS NOT NULL;
  v_rets boolean := to_regclass('public.lwb_driver_delivery_returns') IS NOT NULL AND to_regclass('public.lwb_driver_delivery_return_items') IS NOT NULL;
  closed jsonb;
  days_left integer; v_tom numeric; x jsonb;
  m_target numeric; m_done numeric;
  v_open numeric; v_open_set boolean; v_close numeric; v_close_set boolean;
  n integer; a numeric; txt text;
BEGIN
  m0 := date_trunc('month', d)::date;
  nd := d + 1; IF extract(dow FROM nd) = 0 THEN nd := nd + 1; END IF;
  dd := to_char(d, 'DD/MM/YYYY'); mon := upper(to_char(d, 'Mon'));
  SELECT jsonb_build_object('at', to_char(c.closed_at AT TIME ZONE 'Asia/Kolkata', 'HH12:MI AM'), 'to', c.handed_to_name, 'counted', c.counted)
    INTO closed FROM public.lwb_acc_day_close c
   WHERE c.close_date = d AND c.cancelled_at IS NULL AND NOT c.is_start ORDER BY c.closed_at DESC LIMIT 1;

  -- Scratch tables live only until the end of this call's transaction (ON COMMIT DROP); every caller builds once per transaction.
  -- Orders of this month up to the day: brand unit and the person who gets the credit.
  CREATE TEMP TABLE lwb_wa_o ON COMMIT DROP AS
  SELECT o.id, o.order_no, btrim(o.customer_name) AS party, coalesce(o.total_amount,0) AS amount, coalesce(o.total_qty,0) AS qty,
         coalesce(o.total_weight,0) AS kg,
         (timezone('Asia/Kolkata', o.order_date::timestamptz))::date AS day,
         CASE WHEN upper(btrim(split_part(coalesce(o.transportation,''), '|', 1))) LIKE 'DIRECT%' THEN 'DIRECT' ELSE 'GODOWN' END AS kind,
         coalesce(sp.id, CASE WHEN lower(btrim(coalesce(cb.role,''))) IN ('sales','salesman','manager') THEN cb.id END) AS person_id,
         CASE WHEN upper(coalesce(to_jsonb(co)->>'pack_unit','')) = 'BOX' THEN 'IC' ELSE 'cs' END AS unit
  FROM public.orders o
  LEFT JOIN LATERAL (
    SELECT p.id FROM public.user_profiles p
    WHERE nullif(btrim(o.sales_person),'') IS NOT NULL AND upper(btrim(p.full_name)) = upper(btrim(o.sales_person))
    ORDER BY p.active DESC, (lower(btrim(coalesce(p.role,''))) IN ('sales','salesman','manager')) DESC LIMIT 1) sp ON true
  LEFT JOIN public.user_profiles cb ON cb.id = o.created_by
  LEFT JOIN LATERAL (
    SELECT CASE WHEN count(DISTINCT sm.company_id) = 1 THEN (array_agg(sm.company_id) FILTER (WHERE sm.company_id IS NOT NULL))[1] END AS cid
    FROM public.order_items i JOIN public.sku_master sm ON upper(btrim(sm.sku_name)) = upper(btrim(i.sku_name))
    WHERE i.order_id = o.id) oc ON true
  LEFT JOIN public.lwb_companies co ON co.id = oc.cid
  WHERE (timezone('Asia/Kolkata', o.order_date::timestamptz))::date BETWEEN m0 AND d
    AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected','deleted');

  CREATE TEMP TABLE lwb_wa_p ON COMMIT DROP AS SELECT * FROM public.lwb_daily_wa_people_list();

  -- per salesman / Sales Head: today + month + targets
  CREATE TEMP TABLE lwb_wa_s ON COMMIT DROP AS
  SELECT p.user_id, p.name, p.role, sm.mgr_id,
         coalesce((SELECT sum(o.amount) FROM pg_temp.lwb_wa_o o WHERE o.person_id = p.user_id AND o.day = d),0) AS t_amt,
         (SELECT count(*) FROM pg_temp.lwb_wa_o o WHERE o.person_id = p.user_id AND o.day = d) AS t_pos,
         (SELECT count(DISTINCT upper(o.party)) FROM pg_temp.lwb_wa_o o WHERE o.person_id = p.user_id AND o.day = d) AS t_parties,
         (SELECT jsonb_agg(jsonb_build_object('u',u,'q',q)) FROM (SELECT o.unit u, sum(o.qty) q FROM pg_temp.lwb_wa_o o WHERE o.person_id = p.user_id AND o.day = d GROUP BY 1) z) AS t_qty,
         coalesce((SELECT sum(o.kg) FROM pg_temp.lwb_wa_o o WHERE o.person_id = p.user_id AND o.day = d),0) AS t_kg,
         coalesce((SELECT sum(o.amount) FROM pg_temp.lwb_wa_o o WHERE o.person_id = p.user_id),0) AS m_amt,
         coalesce((SELECT sum(o.qty) FROM pg_temp.lwb_wa_o o WHERE o.person_id = p.user_id),0) AS m_qty,
         0::numeric AS tg_amt, 0::numeric AS tg_cs, 0::numeric AS tom_amt, 0::numeric AS tom_cs
  FROM pg_temp.lwb_wa_p p LEFT JOIN public.lwb_salesman_mgr sm ON sm.user_id = p.user_id
  WHERE p.role IN ('sales','salesman','manager');

  -- Targets: next working day's share of what is left of the month target (Sundays off).
  IF date_trunc('month', nd) = date_trunc('month', d) THEN
    SELECT count(*) INTO days_left FROM generate_series(nd, (m0 + interval '1 month - 1 day')::date, interval '1 day') g(x) WHERE extract(dow FROM g.x) <> 0;
  ELSE
    SELECT count(*) INTO days_left FROM generate_series(date_trunc('month', nd)::date, (date_trunc('month', nd) + interval '1 month - 1 day')::date, interval '1 day') g(x) WHERE extract(dow FROM g.x) <> 0;
  END IF;
  IF v_tgt THEN
    EXECUTE 'UPDATE pg_temp.lwb_wa_s s SET tg_amt = coalesce(t.target_amount,0), tg_cs = coalesce(t.target_cases,0)
             FROM public.lwb_sales_targets t WHERE t.month = $1 AND t.salesman_id = s.user_id' USING m0;
    IF date_trunc('month', nd) = date_trunc('month', d) THEN
      UPDATE pg_temp.lwb_wa_s SET tom_amt = greatest(tg_amt - m_amt, 0) / greatest(days_left, 1),
                                  tom_cs = greatest(tg_cs - m_qty, 0) / greatest(days_left, 1)
       WHERE true;  -- Supabase safeupdate refuses an UPDATE without WHERE
    ELSE
      EXECUTE 'UPDATE pg_temp.lwb_wa_s s SET tom_amt = coalesce(t.target_amount,0) / greatest($2, 1), tom_cs = coalesce(t.target_cases,0) / greatest($2, 1)
               FROM public.lwb_sales_targets t WHERE t.month = $1 AND t.salesman_id = s.user_id' USING date_trunc('month', nd)::date, days_left;
    END IF;
  END IF;

  -- ================= SALESMAN: one report per salesman =================
  FOR s IN SELECT * FROM pg_temp.lwb_wa_s WHERE role IN ('sales','salesman') ORDER BY name LOOP
    rows := jsonb_build_array(
      jsonb_build_array('kv', 'Date', dd || ' · Daily report'),
      jsonb_build_array('kv', 'Today''s orders', s.t_pos || ' PO · ' || s.t_parties || ' parties', CASE WHEN s.t_pos = 0 THEN 'r' END),
      jsonb_build_array('th', jsonb_build_array('PRODUCT NAME','QTY','RATE','AMOUNT')));
    SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(q.sku, public.lwb_wa_num(q.qty) || ' ' || q.u,
                    CASE WHEN q.qty > 0 THEN public.lwb_wa_num(q.amt / q.qty) ELSE '' END, public.lwb_wa_num(q.amt))) ORDER BY q.amt DESC), '[]'::jsonb)
      INTO x
    FROM (SELECT upper(btrim(i.sku_name)) sku, sum(coalesce(i.approved_qty, i.ordered_qty, 0)) qty,
                 sum(coalesce(i.amount, coalesce(i.approved_qty, i.ordered_qty, 0) * coalesce(i.rate,0))) amt,
                 CASE WHEN upper(coalesce(max(sm.pack_unit), max(to_jsonb(co)->>'pack_unit'), '')) = 'BOX' THEN 'IC' ELSE 'cs' END u
          FROM pg_temp.lwb_wa_o o JOIN public.order_items i ON i.order_id = o.id
          LEFT JOIN public.sku_master sm ON upper(btrim(sm.sku_name)) = upper(btrim(i.sku_name))
          LEFT JOIN public.lwb_companies co ON co.id = sm.company_id
          WHERE o.person_id = s.user_id AND o.day = d GROUP BY 1) q;
    IF jsonb_array_length(x) = 0 THEN x := jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('No order today','','',''), false, 'r')); END IF;
    IF jsonb_array_length(x) > 14 THEN
      x := (SELECT jsonb_agg(oe ORDER BY oi) FROM jsonb_array_elements(x) WITH ORDINALITY a(oe, oi) WHERE oi <= 13)
           || jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('+ ' || (jsonb_array_length(x) - 13) || ' more products','','','')));
    END IF;
    rows := rows || x || jsonb_build_array(
      jsonb_build_array('kv', 'Total qty', public.lwb_wa_qty(s.t_qty)),
      jsonb_build_array('kv', 'Total amount', public.lwb_wa_inr(s.t_amt)),
      jsonb_build_array('kv', 'Weight', public.lwb_wa_num(s.t_kg) || ' KG'),
      jsonb_build_array('sec', 'Month target'),
      jsonb_build_array('kv', 'Target (' || mon || ')', CASE WHEN s.tg_amt > 0 THEN public.lwb_wa_inr(s.tg_amt) ELSE 'Not set' END),
      jsonb_build_array('kv', 'Achieved', public.lwb_wa_inr(s.m_amt) || CASE WHEN s.tg_amt > 0 THEN ' (' || round(100 * s.m_amt / s.tg_amt) || '%)' ELSE '' END, 'g'),
      jsonb_build_array('kv', CASE WHEN nd > d + 1 THEN 'Monday''s target' ELSE 'Tomorrow''s target' END,
        CASE WHEN s.tg_amt <= 0 AND s.tg_cs <= 0 THEN 'Not set (ask Sales Head)'
             WHEN s.tom_amt <= 0 AND s.tom_cs <= 0 THEN 'Month target done'
             ELSE concat_ws(' · ', CASE WHEN s.tom_amt > 0 THEN public.lwb_wa_inr(round(s.tom_amt / 100) * 100) END,
                                   CASE WHEN s.tom_cs > 0 THEN public.lwb_wa_num(ceil(s.tom_cs)) || ' cases' END) END, 'b'));
    -- Focus parties of the next working day (Sales Team "due after" rule: no order for N+ days)
    x := '[]'::jsonb;
    IF v_plan THEN
      EXECUTE 'SELECT coalesce(public.lwb_build_sales_plan($1, $2)->''parties'', ''[]''::jsonb)' INTO x USING s.user_id, nd;
    END IF;
    rows := rows || jsonb_build_array(jsonb_build_array('sec', 'Focus parties · ' || to_char(nd, 'DD/MM') || ' (' || jsonb_array_length(x) || ')'));
    IF jsonb_array_length(x) = 0 THEN
      rows := rows || jsonb_build_array(jsonb_build_array('kv', 'Parties', 'None due'));
    ELSE
      rows := rows || (SELECT jsonb_agg(jsonb_build_array('kv', oe->>'name', coalesce((oe->>'days') || ' days no order', 'No order yet'), 'r') ORDER BY oi)
                       FROM jsonb_array_elements(x) WITH ORDINALITY a(oe, oi) WHERE oi <= 8);
      IF jsonb_array_length(x) > 8 THEN
        rows := rows || jsonb_build_array(jsonb_build_array('kv', '+ ' || (jsonb_array_length(x) - 8) || ' more', 'See Tasks / My Sales'));
      END IF;
    END IF;
    reps := reps || jsonb_build_object('kind', 'SALESMAN', 'key', s.user_id::text, 'owner', s.user_id, 'title', s.name,
      'doc', jsonb_build_object('who', upper(s.name) || ' · SALESMAN', 'rows', rows), 'focus', x, 'focus_date', nd);
  END LOOP;

  -- ================= MGR: one report per company MGR =================
  FOR r IN SELECT g.id, g.name, co.name::text AS brand FROM public.lwb_company_mgrs g LEFT JOIN public.lwb_companies co ON co.id = g.company_id
           WHERE g.active ORDER BY g.name LOOP
    SELECT coalesce(sum(t_amt),0), coalesce(sum(t_pos),0), coalesce(sum(m_amt),0), coalesce(sum(tg_amt),0), coalesce(sum(tom_amt),0)
      INTO a, n, m_done, m_target, v_tom FROM pg_temp.lwb_wa_s WHERE mgr_id = r.id;
    rows := jsonb_build_array(
      jsonb_build_array('kv', 'Date', dd || ' · MGR report'),
      jsonb_build_array('kv', 'MGR', upper(r.name) || coalesce(' (' || upper(r.brand) || ')', '')),
      jsonb_build_array('kv', 'Team total today', public.lwb_wa_inr(a) || ' · ' || n || ' PO'),
      jsonb_build_array('th', jsonb_build_array('SALESMAN','PO','QTY','AMOUNT')));
    SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(upper(name), t_pos::text, public.lwb_wa_qty(t_qty),
                    CASE WHEN t_pos = 0 THEN 'No order' ELSE public.lwb_wa_num(t_amt) END), false, CASE WHEN t_pos = 0 THEN 'r' END)
                    ORDER BY t_amt DESC, name), jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('No salesman set','','',''), false, 'r')))
      INTO x FROM pg_temp.lwb_wa_s WHERE mgr_id = r.id;
    rows := rows || x || jsonb_build_array(
      jsonb_build_array('tr', jsonb_build_array('TOTAL', n::text,
        public.lwb_wa_qty((SELECT jsonb_agg(jsonb_build_object('u',u,'q',q)) FROM (SELECT o.unit u, sum(o.qty) q FROM pg_temp.lwb_wa_o o
                           JOIN pg_temp.lwb_wa_s s2 ON s2.user_id = o.person_id WHERE s2.mgr_id = r.id AND o.day = d GROUP BY 1) z)),
        public.lwb_wa_num(a)), true),
      jsonb_build_array('sec', 'Month'),
      jsonb_build_array('kv', 'Target (' || mon || ')', CASE WHEN m_target > 0 THEN public.lwb_wa_inr(m_target) ELSE 'Not set' END),
      jsonb_build_array('kv', 'Achieved', public.lwb_wa_inr(m_done) || CASE WHEN m_target > 0 THEN ' (' || round(100 * m_done / m_target) || '%)' ELSE '' END, 'g'),
      jsonb_build_array('kv', CASE WHEN nd > d + 1 THEN 'Monday''s team target' ELSE 'Tomorrow''s team target' END,
        CASE WHEN m_target <= 0 THEN 'Not set' WHEN v_tom <= 0 THEN 'Month target done' ELSE public.lwb_wa_inr(round(v_tom / 100) * 100) END, 'b'));
    reps := reps || jsonb_build_object('kind', 'MGR', 'key', r.id::text, 'title', r.name,
      'doc', jsonb_build_object('who', upper(r.name) || ' · MGR', 'rows', rows));
  END LOOP;

  -- ================= TEAM: MGR ranking + salesman ranking =================
  SELECT coalesce(sum(amount),0), count(*) INTO a, n FROM pg_temp.lwb_wa_o WHERE day = d;
  rows := jsonb_build_array(
    jsonb_build_array('kv', 'Date', dd || ' · Team report'),
    jsonb_build_array('kv', 'Team total today', public.lwb_wa_inr(a) || ' · ' || n || ' PO'),
    jsonb_build_array('sec', 'MGR ranking (today)'),
    jsonb_build_array('th', jsonb_build_array('MGR','PO','QTY','AMOUNT')));
  SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(
           CASE rn WHEN 1 THEN '1st ' WHEN 2 THEN '2nd ' WHEN 3 THEN '3rd ' ELSE rn || 'th ' END || upper(name),
           pos::text, public.lwb_wa_qty(qty), public.lwb_wa_num(amt)), false, CASE WHEN rn = 1 AND amt > 0 THEN 'g' END) ORDER BY rn),
         jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('Set MGRs on WhatsApp Reports','','',''), false, 'r')))
    INTO x
  FROM (SELECT g.name, coalesce(sum(ts.t_amt),0) amt, coalesce(sum(ts.t_pos),0) pos,
               (SELECT jsonb_agg(jsonb_build_object('u',u,'q',q)) FROM (SELECT o.unit u, sum(o.qty) q FROM pg_temp.lwb_wa_o o
                 JOIN pg_temp.lwb_wa_s s2 ON s2.user_id = o.person_id WHERE s2.mgr_id = g.id AND o.day = d GROUP BY 1) z) qty,
               row_number() OVER (ORDER BY coalesce(sum(ts.t_amt),0) DESC, g.name) rn
        FROM public.lwb_company_mgrs g LEFT JOIN pg_temp.lwb_wa_s ts ON ts.mgr_id = g.id
        WHERE g.active GROUP BY g.id, g.name) q;
  rows := rows || x || jsonb_build_array(
    jsonb_build_array('sec', 'Salesman ranking (today)'),
    jsonb_build_array('th', jsonb_build_array('SALESMAN','PO','QTY','AMOUNT')));
  SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(rn || '. ' || upper(name), t_pos::text, public.lwb_wa_qty(t_qty),
           CASE WHEN t_pos = 0 THEN 'No order' ELSE public.lwb_wa_num(t_amt) END), false, CASE WHEN t_pos = 0 THEN 'r' END) ORDER BY rn), '[]'::jsonb)
    INTO x
  FROM (SELECT *, row_number() OVER (ORDER BY t_amt DESC, name) rn FROM pg_temp.lwb_wa_s WHERE role IN ('sales','salesman','manager')) q;
  rows := rows || x;
  SELECT coalesce(sum(amount),0) INTO m_done FROM pg_temp.lwb_wa_o;
  m_target := 0;
  IF v_tgt THEN
    EXECUTE 'SELECT coalesce((SELECT target_amount FROM public.lwb_sales_targets WHERE month = $1 AND salesman_id IS NULL),
                            (SELECT sum(target_amount) FROM public.lwb_sales_targets WHERE month = $1 AND salesman_id IS NOT NULL), 0)'
      INTO m_target USING m0;
  END IF;
  rows := rows || jsonb_build_array(
    jsonb_build_array('sec', 'Month'),
    jsonb_build_array('kv', 'Target (' || mon || ')', CASE WHEN m_target > 0 THEN public.lwb_wa_inr(m_target) ELSE 'Not set' END),
    jsonb_build_array('kv', 'Achieved', public.lwb_wa_inr(m_done) || CASE WHEN m_target > 0 THEN ' (' || round(100 * m_done / m_target) || '%)' ELSE '' END, 'g'));
  reps := reps || jsonb_build_object('kind', 'TEAM', 'key', '', 'title', 'Sales team', 'doc', jsonb_build_object('who', 'SALES TEAM REPORT', 'rows', rows));

  -- ================= GODOWN: vehicles, delivery, returns, purchase in =================
  CREATE TEMP TABLE lwb_wa_v ON COMMIT DROP AS
  SELECT coalesce(nullif(upper(regexp_replace(coalesce(a2.vehicle_no,''), '[^A-Za-z0-9]', '', 'g')), ''), 'NOVEHICLE') AS vkey,
         coalesce(nullif(btrim(a2.vehicle_no),''), 'No vehicle') AS vno, nullif(btrim(a2.driver_name),'') AS driver,
         o.id, coalesce(o.total_weight,0) AS kg, coalesce(o.total_qty,0) AS qty, coalesce(o.total_amount,0) AS amount,
         CASE WHEN upper(coalesce(to_jsonb(co)->>'pack_unit','')) = 'BOX' THEN 'IC' ELSE 'cs' END AS unit
  FROM (SELECT DISTINCT ON (y.order_id) y.* FROM public.dispatch_assignments y
        WHERE y.order_id IS NOT NULL ORDER BY y.order_id, y.assigned_at DESC NULLS LAST) a2
  JOIN public.orders o ON o.id = a2.order_id
  LEFT JOIN LATERAL (
    SELECT CASE WHEN count(DISTINCT sm.company_id) = 1 THEN (array_agg(sm.company_id) FILTER (WHERE sm.company_id IS NOT NULL))[1] END AS cid
    FROM public.order_items i JOIN public.sku_master sm ON upper(btrim(sm.sku_name)) = upper(btrim(i.sku_name))
    WHERE i.order_id = o.id) oc ON true
  LEFT JOIN public.lwb_companies co ON co.id = oc.cid
  WHERE (timezone('Asia/Kolkata', coalesce(a2.loading_completed_at, a2.assigned_at)))::date = d
    AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected','deleted');

  SELECT count(DISTINCT vkey) INTO n FROM pg_temp.lwb_wa_v;
  rows := jsonb_build_array(
    jsonb_build_array('kv', 'Date', dd || ' · Vehicle report'),
    jsonb_build_array('kv', 'Total loaded', CASE WHEN n = 0 THEN 'No vehicle loaded' ELSE
       (SELECT public.lwb_wa_ton(sum(kg)) || ' T · ' || public.lwb_wa_qty((SELECT jsonb_agg(jsonb_build_object('u',u,'q',q)) FROM (SELECT unit u, sum(qty) q FROM pg_temp.lwb_wa_v GROUP BY 1) z))
               || ' · ' || n || CASE WHEN n = 1 THEN ' vehicle' ELSE ' vehicles' END FROM pg_temp.lwb_wa_v) END),
    jsonb_build_array('sec', 'Vehicle-wise loading'),
    jsonb_build_array('th', jsonb_build_array('VEHICLE / DRIVER','TON','CASE','AMOUNT')));
  SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(t, public.lwb_wa_ton(kg), q, public.lwb_wa_num(amt))) ORDER BY kg DESC), '[]'::jsonb)
    INTO x
  FROM (SELECT upper(max(vno)) || coalesce(' · ' || upper(max(driver)), '') t, sum(kg) kg, sum(amount) amt,
               public.lwb_wa_qty((SELECT jsonb_agg(jsonb_build_object('u',u,'q',q)) FROM (SELECT y.unit u, sum(y.qty) q FROM pg_temp.lwb_wa_v y WHERE y.vkey = v.vkey GROUP BY 1) z)) q
        FROM pg_temp.lwb_wa_v v GROUP BY vkey) q;
  rows := rows || x;
  IF n > 0 THEN
    rows := rows || (SELECT jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('TOTAL', public.lwb_wa_ton(sum(kg)),
                      public.lwb_wa_qty((SELECT jsonb_agg(jsonb_build_object('u',u,'q',q)) FROM (SELECT unit u, sum(qty) q FROM pg_temp.lwb_wa_v GROUP BY 1) z)),
                      public.lwb_wa_num(sum(amount))), true)) FROM pg_temp.lwb_wa_v);
  END IF;

  -- Delivered today: driver report Delivered / Partial, or Admin "Mark delivered" with this date.
  CREATE TEMP TABLE lwb_wa_del ON COMMIT DROP AS
  SELECT DISTINCT o.id, upper(btrim(o.customer_name)) AS party, coalesce(o.total_amount,0) AS amount
  FROM public.orders o
  WHERE lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected','deleted')
    AND EXISTS (SELECT 1 FROM public.lwb_delivery_reports dr WHERE dr.order_id = o.id AND dr.delivery_status IN ('DELIVERED','PARTIAL')
                AND (timezone('Asia/Kolkata', dr.reported_at))::date = d);
  IF v_marks THEN
    EXECUTE 'INSERT INTO pg_temp.lwb_wa_del SELECT o.id, upper(btrim(o.customer_name)), coalesce(o.total_amount,0) FROM public.orders o
             JOIN public.lwb_admin_order_marks m ON m.order_id = o.id AND m.kind = ''DELIVERED'' AND m.mark_date = $1
             WHERE NOT EXISTS (SELECT 1 FROM pg_temp.lwb_wa_del z WHERE z.id = o.id)' USING d;
  END IF;
  SELECT count(DISTINCT party) || ' parties · ' || public.lwb_wa_inr(coalesce(sum(amount),0)) INTO txt FROM pg_temp.lwb_wa_del;
  rows := rows || jsonb_build_array(jsonb_build_array('sec', 'Delivery'), jsonb_build_array('kv', 'Delivered', txt, 'g'));
  EXECUTE 'SELECT count(*) || '' PO · '' || public.lwb_wa_inr(coalesce(sum(o.total_amount),0)), count(*) FROM public.orders o
           WHERE lower(o.status) IN (''transport_allocated'',''allocated'',''loading'',''loaded'',''invoiced'',''dispatched'')
             AND NOT EXISTS (SELECT 1 FROM public.lwb_delivery_reports z WHERE z.order_id = o.id AND z.delivery_status IN (''DELIVERED'',''PARTIAL''))'
           || CASE WHEN v_marks THEN ' AND NOT EXISTS (SELECT 1 FROM public.lwb_admin_order_marks m WHERE m.order_id = o.id AND m.kind = ''DELIVERED'')' ELSE '' END
    INTO txt, n;
  rows := rows || jsonb_build_array(jsonb_build_array('kv', 'Pending delivery', txt, CASE WHEN n > 0 THEN 'r' END));
  IF v_rets THEN
    EXECUTE 'SELECT public.lwb_wa_num(coalesce(sum(i.qty_cases),0)) || '' cs ('' || count(DISTINCT h.order_id) || '' PO)''
             FROM public.lwb_driver_delivery_returns h JOIN public.lwb_driver_delivery_return_items i ON i.return_id = h.id
             WHERE h.status <> ''REJECTED'' AND (timezone(''Asia/Kolkata'', h.created_at))::date = $1' INTO txt USING d;
    rows := rows || jsonb_build_array(jsonb_build_array('kv', 'Returns', txt));
  END IF;
  a := 0; n := 0; txt := 'None';
  IF v_gi THEN
    EXECUTE 'SELECT count(*), coalesce(sum((SELECT sum(coalesce(i.total_amount,0)) FROM public.lwb_goods_inward_items i WHERE i.inward_id = g.id)),0),
                    coalesce(string_agg(DISTINCT upper(btrim(g.supplier_name)), '', ''), ''None'')
             FROM public.lwb_goods_inward g WHERE g.received_date = $1' INTO n, a, txt USING d;
  END IF;
  rows := rows || jsonb_build_array(jsonb_build_array('sec', 'Purchase in'),
    jsonb_build_array('kv', 'Bills received', n || CASE WHEN n = 1 THEN ' bill' ELSE ' bills' END),
    jsonb_build_array('kv', 'Supplier', txt));
  reps := reps || jsonb_build_object('kind', 'GODOWN', 'key', '', 'title', 'Godown / vehicles', 'doc', jsonb_build_object('who', 'GODOWN · VEHICLE REPORT', 'rows', rows));

  -- ================= money (Accounts book of the day) =================
  CREATE TEMP TABLE IF NOT EXISTS lwb_wa_l (src text, id uuid, kind text, mode text, amount numeric, party text, order_no text, cash_effect numeric,
                                          category text, remark text) ON COMMIT DROP;
  DELETE FROM pg_temp.lwb_wa_l WHERE true;
  IF v_acc THEN
    INSERT INTO pg_temp.lwb_wa_l SELECT l.src, l.id, l.kind, l.mode, l.amount, l.party, l.order_no, l.cash_effect, l.category::text, l.remark::text
      FROM public.lwb_acc_lines() l WHERE l.book_date = d;
  END IF;
  -- brand of each money-in line: party payment = its brand; driver money / old collection = brand of its PO
  CREATE TEMP TABLE lwb_wa_in ON COMMIT DROP AS
  SELECT l.*, coalesce(co.name::text, 'Brand not set') AS brand,
         CASE WHEN l.mode = 'CASH' THEN 'CASH' WHEN l.mode = 'CHEQUE' THEN 'CHEQUE' ELSE 'BANK' END AS m
  FROM pg_temp.lwb_wa_l l
  LEFT JOIN public.lwb_tally_payments tp ON l.src = 'PAYMENT' AND tp.id = l.id
  LEFT JOIN LATERAL (SELECT o.id FROM public.orders o WHERE o.order_no::text = l.order_no LIMIT 1) od ON true
  LEFT JOIN LATERAL (
    SELECT CASE WHEN count(DISTINCT sm.company_id) = 1 THEN (array_agg(sm.company_id) FILTER (WHERE sm.company_id IS NOT NULL))[1] END AS cid
    FROM public.order_items i JOIN public.sku_master sm ON upper(btrim(sm.sku_name)) = upper(btrim(i.sku_name))
    WHERE i.order_id = od.id) oc ON true
  LEFT JOIN public.lwb_companies co ON co.id = coalesce(nullif(to_jsonb(tp)->>'company_id',''), oc.cid::text)::uuid
  WHERE l.kind = 'IN' AND l.src <> 'ENTRY';

  v_open := 0; v_open_set := false; v_close := 0; v_close_set := false;
  IF v_cash THEN
    EXECUTE 'SELECT amount, is_set FROM public.lwb_acc_cash_at($1)' INTO v_open, v_open_set USING d;
    EXECUTE 'SELECT amount, is_set FROM public.lwb_acc_cash_at($1)' INTO v_close, v_close_set USING d + 1;
  END IF;

  -- ================= ADMIN =================
  SELECT coalesce(sum(amount),0), count(*) INTO a, n FROM pg_temp.lwb_wa_o WHERE day = d;
  rows := jsonb_build_array(
    jsonb_build_array('kv', 'Date', dd || coalesce(' · Day closed ' || (closed->>'at'), ' · Day not closed'), CASE WHEN closed IS NULL THEN 'r' END),
    jsonb_build_array('sec', 'Business today'),
    jsonb_build_array('kv', 'Total sales', public.lwb_wa_inr(a) || ' · ' || n || ' PO'),
    jsonb_build_array('kv', 'From godown', (SELECT public.lwb_wa_inr(coalesce(sum(amount),0)) || ' · ' ||
        public.lwb_wa_qty((SELECT jsonb_agg(jsonb_build_object('u',u,'q',q)) FROM (SELECT unit u, sum(qty) q FROM pg_temp.lwb_wa_o WHERE day = d AND kind = 'GODOWN' GROUP BY 1) z))
        FROM pg_temp.lwb_wa_o WHERE day = d AND kind = 'GODOWN')),
    jsonb_build_array('kv', 'Direct vehicle', (SELECT public.lwb_wa_inr(coalesce(sum(amount),0)) || ' · ' || count(*) || ' PO' FROM pg_temp.lwb_wa_o WHERE day = d AND kind = 'DIRECT')),
    jsonb_build_array('kv', 'Delivered', (SELECT public.lwb_wa_inr(coalesce(sum(amount),0)) || ' · ' || count(DISTINCT party) || ' parties' FROM pg_temp.lwb_wa_del)),
    jsonb_build_array('kv', 'Purchase', CASE WHEN v_gi THEN (SELECT public.lwb_wa_inr(coalesce(sum((SELECT sum(coalesce(i.total_amount,0)) FROM public.lwb_goods_inward_items i WHERE i.inward_id = g.id)),0))
        || ' · ' || count(*) || ' bills' FROM public.lwb_goods_inward g WHERE g.received_date = d) ELSE '-' END),
    jsonb_build_array('sec', 'Collection (brand-wise)'),
    jsonb_build_array('th', jsonb_build_array('BRAND','CASH','BANK/UPI','TOTAL')));
  SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(upper(brand), public.lwb_wa_num(c), public.lwb_wa_num(b), public.lwb_wa_num(t))) ORDER BY t DESC),
         jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('No payment today','','',''))))
    INTO x
  FROM (SELECT brand, coalesce(sum(amount) FILTER (WHERE m = 'CASH'),0) c, coalesce(sum(amount) FILTER (WHERE m <> 'CASH'),0) b, sum(amount) t
        FROM pg_temp.lwb_wa_in GROUP BY brand) q;
  rows := rows || x || (SELECT jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('TOTAL',
            public.lwb_wa_num(coalesce(sum(amount) FILTER (WHERE m = 'CASH'),0)), public.lwb_wa_num(coalesce(sum(amount) FILTER (WHERE m <> 'CASH'),0)),
            public.lwb_wa_num(coalesce(sum(amount),0))), true)) FROM pg_temp.lwb_wa_in);
  rows := rows || jsonb_build_array(
    jsonb_build_array('sec', 'Cash & bank'),
    jsonb_build_array('kv', 'Cash in / out', (SELECT public.lwb_wa_inr(coalesce(sum(amount) FILTER (WHERE (kind = 'IN' AND mode = 'CASH') OR kind = 'WITHDRAW'),0)) || ' / ' ||
                                                     public.lwb_wa_inr(coalesce(sum(amount) FILTER (WHERE kind = 'OUT' AND mode = 'CASH'),0)) FROM pg_temp.lwb_wa_l)),
    jsonb_build_array('kv', 'Bank deposit', (SELECT public.lwb_wa_inr(coalesce(sum(amount) FILTER (WHERE kind = 'DEPOSIT'),0)) FROM pg_temp.lwb_wa_l)),
    jsonb_build_array('kv', 'Cash in hand', CASE WHEN v_close_set THEN public.lwb_wa_inr(v_close) || coalesce(' (given to ' || nullif(btrim(closed->>'to'),'') || ')', '') ELSE 'Opening cash not set' END, 'g'));
  IF v_acc AND to_regclass('public.lwb_acc_verify') IS NOT NULL THEN
    EXECUTE 'SELECT count(*), coalesce(sum(l.amount),0) FROM public.lwb_acc_lines() l WHERE l.needs_verify
             AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_verify v WHERE v.src = l.src AND v.src_id = l.id)' INTO n, a;
    rows := rows || jsonb_build_array(jsonb_build_array('kv', 'Bank not checked', CASE WHEN n = 0 THEN 'Nothing pending' ELSE public.lwb_wa_inr(a) || ' (' || n || ' entries)' END, CASE WHEN n > 0 THEN 'r' END));
  END IF;
  rows := rows || jsonb_build_array(jsonb_build_array('sec', 'Outstanding'));
  IF v_led THEN
    EXECUTE 'WITH b AS (SELECT btrim(l.customer_name) party, l.company_id, sum(coalesce(l.debit,0) - coalesce(l.credit,0)) bal
                       FROM public.lwb_party_ledger_b() l WHERE l.entry_date <= $1 GROUP BY 1, 2)
             SELECT coalesce(jsonb_agg(jsonb_build_array(''kv'', coalesce(co.name::text, ''Brand not set''), public.lwb_wa_inr(x.s)) ORDER BY x.s DESC), ''[]''::jsonb)
                    || jsonb_build_array(jsonb_build_array(''kv'', ''Total'', public.lwb_wa_inr(coalesce(sum(x.s),0)), ''r''))
             FROM (SELECT company_id, sum(bal) s FROM b WHERE bal > 0.5 GROUP BY 1) x LEFT JOIN public.lwb_companies co ON co.id = x.company_id'
      INTO x USING d;
    rows := rows || x;
  ELSE
    rows := rows || jsonb_build_array(jsonb_build_array('kv', 'Total', '-'));
  END IF;
  reps := reps || jsonb_build_object('kind', 'ADMIN', 'key', '', 'title', 'Admin money report', 'doc', jsonb_build_object('who', 'ADMIN REPORT', 'rows', rows));

  -- ================= ACCOUNTS =================
  SELECT count(*), coalesce(sum(amount),0) INTO n, a FROM pg_temp.lwb_wa_in;
  rows := jsonb_build_array(
    jsonb_build_array('kv', 'Date', dd || coalesce(' · Day closed ' || (closed->>'at'), ' · Day not closed'), CASE WHEN closed IS NULL THEN 'r' END),
    jsonb_build_array('sec', 'Payments received (party-wise)'),
    jsonb_build_array('th', jsonb_build_array('PARTY','BRAND','MODE','AMOUNT')));
  SELECT coalesce(jsonb_agg(jsonb_build_array('tr', jsonb_build_array(p, b, md, public.lwb_wa_num(t))) ORDER BY t DESC),
         jsonb_build_array(jsonb_build_array('tr', jsonb_build_array('No payment today','','',''))))
    INTO x
  FROM (SELECT upper(coalesce(nullif(btrim(party),''), 'Other')) p, upper(min(brand)) b,
               CASE WHEN count(DISTINCT m) > 1 THEN 'MIXED' ELSE min(m) END md, sum(amount) t
        FROM pg_temp.lwb_wa_in GROUP BY 1) q;
  rows := rows || x;
  rows := rows || jsonb_build_array(
    jsonb_build_array('tr', jsonb_build_array('TOTAL', n || ' entries', '', public.lwb_wa_num(a)), true),
    jsonb_build_array('sec', 'Cash book'),
    jsonb_build_array('kv', 'Opening cash', CASE WHEN v_open_set THEN public.lwb_wa_inr(v_open) ELSE 'Not set' END),
    jsonb_build_array('kv', 'Cash in', (SELECT public.lwb_wa_inr(coalesce(sum(amount) FILTER (WHERE (kind = 'IN' AND mode = 'CASH') OR kind = 'WITHDRAW'),0)) FROM pg_temp.lwb_wa_l)),
    jsonb_build_array('kv', 'Cash out', (SELECT public.lwb_wa_inr(coalesce(sum(amount) FILTER (WHERE kind = 'OUT' AND mode = 'CASH'),0)) FROM pg_temp.lwb_wa_l)),
    jsonb_build_array('kv', 'Bank deposit', (SELECT public.lwb_wa_inr(coalesce(sum(amount) FILTER (WHERE kind = 'DEPOSIT'),0)) FROM pg_temp.lwb_wa_l)),
    jsonb_build_array('kv', 'Closing cash', CASE WHEN NOT v_close_set THEN 'Not set'
        ELSE public.lwb_wa_inr(v_close) || CASE WHEN closed IS NULL THEN ' (day not closed)'
                                                WHEN abs(coalesce((closed->>'counted')::numeric, v_close) - v_close) < 1 THEN ' (counted ✓)'
                                                ELSE ' (counted ' || public.lwb_wa_inr((closed->>'counted')::numeric) || ')' END END,
      CASE WHEN closed IS NULL THEN 'r' ELSE 'g' END),
    jsonb_build_array('sec', 'Work pending'));
  IF v_acc AND to_regclass('public.lwb_acc_verify') IS NOT NULL THEN
    EXECUTE 'SELECT count(*), coalesce(sum(l.amount),0) FROM public.lwb_acc_lines() l WHERE l.needs_verify
             AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_verify v WHERE v.src = l.src AND v.src_id = l.id)' INTO n, a;
    rows := rows || jsonb_build_array(jsonb_build_array('kv', 'Bank not checked', CASE WHEN n = 0 THEN 'Nothing pending' ELSE public.lwb_wa_inr(a) || ' (' || n || ')' END, CASE WHEN n > 0 THEN 'r' END));
  END IF;
  IF v_acc AND to_regclass('public.lwb_acc_cheques') IS NOT NULL THEN
    EXECUTE 'SELECT count(*), coalesce(sum(l.amount),0) FROM public.lwb_acc_cheques c JOIN public.lwb_acc_lines() l ON l.src = c.src AND l.id = c.src_id
             WHERE c.deposited_on IS NULL AND coalesce(c.cheque_date, l.book_date) <= $1' INTO n, a USING d;
    rows := rows || jsonb_build_array(jsonb_build_array('kv', 'Cheques to deposit', CASE WHEN n = 0 THEN 'None' ELSE n || ' · ' || public.lwb_wa_inr(a) END, CASE WHEN n > 0 THEN 'r' END));
  END IF;
  reps := reps || jsonb_build_object('kind', 'ACCOUNTS', 'key', '', 'title', 'Accounts report', 'doc', jsonb_build_object('who', 'ACCOUNTS REPORT', 'rows', rows));

  -- ================= DAY BOOK (Admin, PDF) =================
  reps := reps || jsonb_build_object('kind', 'DAYBOOK', 'key', '', 'title', 'Day book', 'pdf', true,
    'doc', jsonb_build_object('who', 'ADMIN · DAY BOOK', 'rows', public.lwb_daily_wa_daybook(d, closed,
       jsonb_build_object('open', v_open, 'open_set', v_open_set, 'close', v_close, 'close_set', v_close_set))));

  RETURN jsonb_build_object('date', d, 'focus_date', nd, 'closed', closed, 'reports', reps,
    'people', (SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.name), '[]'::jsonb) FROM pg_temp.lwb_wa_p p));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_daily_wa_build(date) FROM PUBLIC, anon, authenticated;

-- Who gets which report: [{report index, user_id, name, mobile}]
--   SALESMAN -> the salesman himself (if his SALESMAN switch is on); every other kind -> everyone with that switch on.
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_sends(p_build jsonb)
RETURNS TABLE (kind text, report_key text, title text, doc jsonb, user_id uuid, name text, mobile text)
LANGUAGE sql STABLE SET search_path = ''
AS $fn$
  SELECT r->>'kind', r->>'key', r->>'title', r->'doc', (p->>'user_id')::uuid, p->>'name', p->>'mobile'
  FROM jsonb_array_elements(p_build->'reports') r
  JOIN jsonb_array_elements(p_build->'people') p
    ON p->>'mobile' IS NOT NULL AND (p->'kinds'->>(r->>'kind'))::boolean
   AND (r->>'kind' <> 'SALESMAN' OR p->>'user_id' = r->>'owner')
$fn$;
REVOKE ALL ON FUNCTION public.lwb_daily_wa_sends(jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Focus parties -> one task per salesman for the next working day (once per date)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_focus_tasks(p_build jsonb)
RETURNS integer LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r jsonb; v_by uuid; v_by_name text; v_by_role text; v_id bigint; v_n integer := 0; v_key text; v_title text; v_due date;
  u record; v_cnt integer;
BEGIN
  IF to_regclass('public.lwb_tasks') IS NULL OR NOT EXISTS (SELECT 1 FROM public.lwb_daily_wa_config WHERE id = 1 AND focus_tasks) THEN RETURN 0; END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'lwb_tasks' AND column_name = 'auto_key') THEN RETURN 0; END IF;
  SELECT p.id, coalesce(nullif(btrim(p.full_name),''), 'Admin'), lower(btrim(p.role)) INTO v_by, v_by_name, v_by_role
  FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'admin'
  ORDER BY (p.full_name ILIKE '%mohit%') DESC, p.full_name LIMIT 1;
  IF v_by IS NULL THEN RETURN 0; END IF;
  v_due := (p_build->>'focus_date')::date;
  FOR r IN SELECT x FROM jsonb_array_elements(p_build->'reports') x WHERE x->>'kind' = 'SALESMAN' AND jsonb_array_length(coalesce(x->'focus','[]'::jsonb)) > 0 LOOP
    SELECT p.id, coalesce(nullif(btrim(p.full_name),''), 'Staff') AS name, lower(btrim(p.role)) AS role INTO u
    FROM public.user_profiles p WHERE p.id = (r->>'owner')::uuid AND p.active;
    CONTINUE WHEN u.id IS NULL;
    v_key := 'FOCUS_PARTIES:' || v_due;
    CONTINUE WHEN EXISTS (SELECT 1 FROM public.lwb_tasks t WHERE t.assigned_to = u.id AND t.auto_key = v_key);
    v_cnt := jsonb_array_length(r->'focus');
    v_title := '🎯 Focus parties ' || to_char(v_due, 'DD/MM') || ': ' || v_cnt || CASE WHEN v_cnt = 1 THEN ' party' ELSE ' parties' END;
    INSERT INTO public.lwb_tasks(title, details, due_date, priority, assigned_to, assigned_to_name, assigned_to_role,
      assigned_by, assigned_by_name, assigned_by_role, auto_key)
    VALUES (v_title,
      left('Call or visit these parties and bring an order (no order for many days):' || E'\n' ||
        (SELECT string_agg(n || '. ' || (e->>'name') || coalesce(' · ' || nullif(e->>'city',''), '') || ' · ' ||
                           coalesce((e->>'days') || ' days no order', 'no order yet'), E'\n' ORDER BY n)
         FROM jsonb_array_elements(r->'focus') WITH ORDINALITY a(e, n)), 2000),
      v_due, 'NORMAL', u.id, u.name, u.role, v_by, v_by_name, v_by_role, v_key)
    RETURNING id INTO v_id;
    INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
    VALUES (u.id, left('New task: ' || v_title, 150), left('TSK-' || v_id || ' · ' || v_title || ' · Due ' || to_char(v_due, 'DD Mon YYYY') || '. Open Tasks for the list.', 600), 'TASK_NEW');
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
EXCEPTION WHEN OTHERS THEN
  RETURN v_n;    -- tasks must never stop the WhatsApp reports
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_daily_wa_focus_tasks(jsonb) FROM PUBLIC, anon, authenticated;

-- Day Book always; any other report with more than 40 lines (too long for one image).
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_is_pdf(p_kind text, p_doc jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT p_kind = 'DAYBOOK' OR jsonb_array_length(coalesce(p_doc->'rows', '[]'::jsonb)) > 40 $fn$;
REVOKE ALL ON FUNCTION public.lwb_daily_wa_is_pdf(text, jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Sender side (Edge Function, service role): take what to send, then mark each one
-- ---------------------------------------------------------------------------
-- p_test_user set = test: one of every report goes to that person's WhatsApp only (p_only = just that kind, e.g. DAYBOOK).
-- pdf = true: send as a PDF document (Day Book, or a report longer than one phone screen can show).
DROP FUNCTION IF EXISTS public.lwb_daily_wa_claim(date, uuid);
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_claim(p_date date, p_test_user uuid DEFAULT NULL, p_only text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE b jsonb; s record; out jsonb := '[]'::jsonb; v_id bigint; v_to text; v_name text; rep jsonb;
BEGIN
  b := public.lwb_daily_wa_build(p_date);
  IF p_test_user IS NOT NULL THEN
    SELECT public.lwb_daily_wa_mobile(p.mobile::text), p.full_name INTO v_to, v_name FROM public.user_profiles p WHERE p.id = p_test_user;
    IF v_to IS NULL THEN RAISE EXCEPTION 'Your login has no Login Mobile. Add it in Manage Users first.'; END IF;
    -- every report except salesmen: all MGRs and the rest; salesmen: only the first one as a sample
    FOR rep IN SELECT x FROM jsonb_array_elements(b->'reports') WITH ORDINALITY a(x, n)
               WHERE (p_only IS NULL OR x->>'kind' = upper(p_only))
                 AND (x->>'kind' <> 'SALESMAN' OR n = (SELECT min(n2) FROM jsonb_array_elements(b->'reports') WITH ORDINALITY c(y, n2) WHERE y->>'kind' = 'SALESMAN'))
               ORDER BY CASE x->>'kind' WHEN 'DAYBOOK' THEN 0 WHEN 'ADMIN' THEN 1 WHEN 'TEAM' THEN 2 WHEN 'MGR' THEN 3 WHEN 'ACCOUNTS' THEN 4 WHEN 'GODOWN' THEN 5 ELSE 6 END, n LOOP
      INSERT INTO public.lwb_daily_wa_log(report_date, kind, report_key, user_id, name, mobile, test)
      VALUES (p_date, rep->>'kind', rep->>'key', p_test_user, coalesce(v_name,'') || ' (test: ' || (rep->>'title') || ')', right(v_to, 4), true)
      RETURNING id INTO v_id;
      out := out || jsonb_build_object('id', v_id, 'to', '91' || v_to, 'kind', rep->>'kind', 'title', rep->>'title', 'doc', rep->'doc',
                                       'pdf', public.lwb_daily_wa_is_pdf(rep->>'kind', rep->'doc'));
    END LOOP;
  ELSE
    PERFORM public.lwb_daily_wa_focus_tasks(b);
    FOR s IN SELECT * FROM public.lwb_daily_wa_sends(b) LOOP
      v_id := NULL;
      INSERT INTO public.lwb_daily_wa_log(report_date, kind, report_key, user_id, name, mobile)
      VALUES (p_date, s.kind, s.report_key, s.user_id, s.name || CASE WHEN s.kind IN ('MGR') THEN ' (' || s.title || ')' ELSE '' END, right(s.mobile, 4))
      ON CONFLICT (report_date, kind, report_key, user_id) WHERE NOT test DO NOTHING RETURNING id INTO v_id;
      IF v_id IS NULL THEN    -- a FAILED one may be tried again
        UPDATE public.lwb_daily_wa_log l SET status = 'QUEUED', error = NULL, created_at = now()
        WHERE l.report_date = p_date AND l.kind = s.kind AND l.report_key = s.report_key AND l.user_id = s.user_id AND NOT l.test AND l.status = 'FAILED'
        RETURNING l.id INTO v_id;
      END IF;
      CONTINUE WHEN v_id IS NULL;
      out := out || jsonb_build_object('id', v_id, 'to', '91' || s.mobile, 'kind', s.kind, 'title', s.title, 'doc', s.doc,
                                       'pdf', public.lwb_daily_wa_is_pdf(s.kind, s.doc));
    END LOOP;
  END IF;
  RETURN jsonb_build_object('date', p_date, 'test', p_test_user IS NOT NULL,
    'template', (SELECT template FROM public.lwb_daily_wa_config WHERE id = 1),
    'template_doc', (SELECT template_doc FROM public.lwb_daily_wa_config WHERE id = 1),
    'lang', (SELECT lang FROM public.lwb_daily_wa_config WHERE id = 1), 'messages', out);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_daily_wa_mark(p_id bigint, p_ok boolean, p_wa_id text DEFAULT NULL, p_error text DEFAULT NULL)
RETURNS void LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
  UPDATE public.lwb_daily_wa_log
  SET status = CASE WHEN p_ok THEN 'SENT' ELSE 'FAILED' END, wa_message_id = left(p_wa_id, 200),
      error = left(p_error, 300), sent_at = CASE WHEN p_ok THEN now() END
  WHERE id = p_id;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_daily_wa_claim(date, uuid, text), public.lwb_daily_wa_mark(bigint, boolean, text, text) FROM PUBLIC, anon, authenticated;
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT EXECUTE ON FUNCTION public.lwb_daily_wa_claim(date, uuid, text), public.lwb_daily_wa_mark(bigint, boolean, text, text) TO service_role;
  END IF;
END $g$;

-- ---------------------------------------------------------------------------
-- 6. Start a send: calls the Edge Function (pg_net, after this transaction commits)
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.lwb_daily_wa_call(date, uuid);
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_call(p_date date, p_test_user uuid DEFAULT NULL, p_only text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE c public.lwb_daily_wa_config;
BEGIN
  SELECT * INTO c FROM public.lwb_daily_wa_config WHERE id = 1;
  IF to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') IS NULL THEN RETURN false; END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := $3, params := ''{}''::jsonb, headers := $2, timeout_milliseconds := 120000)'
    USING c.project_url || '/functions/v1/lwb-daily-whatsapp',
          jsonb_build_object('Content-Type', 'application/json', 'x-lwb-wa-secret', c.webhook_secret),
          jsonb_build_object('date', p_date, 'test_user', p_test_user, 'only', p_only);
  RETURN true;
END;
$fn$;

-- Once per date (Close Day or back-up time). "Send now" by Admin may run again: only unsent ones go.
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_fire(p_date date, p_trigger text)
RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_new boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.lwb_daily_wa_config WHERE id = 1 AND enabled) THEN RETURN false; END IF;
  INSERT INTO public.lwb_daily_wa_runs(report_date, trigger, by_user) VALUES (p_date, p_trigger, auth.uid())
  ON CONFLICT (report_date) DO NOTHING RETURNING true INTO v_new;
  IF NOT coalesce(v_new, false) AND p_trigger <> 'MANUAL' THEN RETURN false; END IF;
  RETURN public.lwb_daily_wa_call(p_date, NULL);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_daily_wa_call(date, uuid, text), public.lwb_daily_wa_fire(date, text) FROM PUBLIC, anon, authenticated;

-- Close Day (not the first opening cash) of today or yesterday -> send that day's reports.
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_on_close()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT NEW.is_start AND NEW.cancelled_at IS NULL
     AND NEW.close_date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - 1 THEN
    PERFORM public.lwb_daily_wa_fire(NEW.close_date, 'CLOSE_DAY');
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;      -- a WhatsApp problem must never stop the Close Day
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_daily_wa_on_close() FROM PUBLIC, anon, authenticated;
DO $t$ BEGIN
  IF to_regclass('public.lwb_acc_day_close') IS NOT NULL THEN
    DROP TRIGGER IF EXISTS trg_lwb_daily_wa_close ON public.lwb_acc_day_close;
    CREATE TRIGGER trg_lwb_daily_wa_close AFTER INSERT ON public.lwb_acc_day_close
      FOR EACH ROW EXECUTE FUNCTION public.lwb_daily_wa_on_close();
  END IF;
END $t$;

-- Back-up: nobody closed the day by the set time -> send anyway (cash shows "Day not closed").
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_tick()
RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE c public.lwb_daily_wa_config; v_now timestamp := now() AT TIME ZONE 'Asia/Kolkata';
BEGIN
  SELECT * INTO c FROM public.lwb_daily_wa_config WHERE id = 1;
  IF NOT c.enabled OR c.backup_time IS NULL OR v_now::time < c.backup_time THEN RETURN false; END IF;
  RETURN public.lwb_daily_wa_fire(v_now::date, 'BACKUP');
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_daily_wa_tick() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Admin page (whatsapp-reports.html)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'admin')
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_daily_wa_page(p_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE d date := coalesce(p_date, (now() AT TIME ZONE 'Asia/Kolkata')::date); b jsonb;
BEGIN
  IF NOT public.lwb_daily_wa_admin() THEN RAISE EXCEPTION 'WhatsApp Reports is for Admin only'; END IF;
  b := public.lwb_daily_wa_build(d);
  RETURN jsonb_build_object(
    'date', d, 'today', (now() AT TIME ZONE 'Asia/Kolkata')::date, 'closed', b->'closed', 'focus_date', b->'focus_date',
    'reports', (SELECT coalesce(jsonb_agg((x - 'owner' - 'focus') || jsonb_build_object('pdf', public.lwb_daily_wa_is_pdf(x->>'kind', x->'doc'), 'to',
                  (SELECT coalesce(jsonb_agg(s.name ORDER BY s.name), '[]'::jsonb) FROM public.lwb_daily_wa_sends(b) s
                   WHERE s.kind = x->>'kind' AND s.report_key = x->>'key')) ORDER BY n), '[]'::jsonb)
                FROM jsonb_array_elements(b->'reports') WITH ORDINALITY a(x, n)),
    'config', (SELECT jsonb_build_object('enabled', c.enabled, 'backup_time', to_char(c.backup_time, 'HH24:MI'), 'focus_tasks', c.focus_tasks,
                                         'template', c.template, 'template_doc', c.template_doc, 'lang', c.lang) FROM public.lwb_daily_wa_config c WHERE c.id = 1),
    'people', (SELECT coalesce(jsonb_agg(jsonb_build_object('user_id', p->>'user_id', 'name', p->>'name', 'role', p->>'role',
                 'mobile', CASE WHEN p->>'mobile' IS NULL THEN NULL ELSE '******' || right(p->>'mobile', 4) END, 'kinds', p->'kinds',
                 'mgr_id', (SELECT sm.mgr_id FROM public.lwb_salesman_mgr sm WHERE sm.user_id = (p->>'user_id')::uuid))
                 ORDER BY CASE p->>'role' WHEN 'admin' THEN 0 WHEN 'manager' THEN 1 WHEN 'sales' THEN 2 WHEN 'salesman' THEN 2 ELSE 3 END, p->>'name'), '[]'::jsonb)
               FROM jsonb_array_elements(b->'people') p),
    'mgrs', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'company_id', g.company_id, 'brand', co.name, 'active', g.active) ORDER BY g.name), '[]'::jsonb)
             FROM public.lwb_company_mgrs g LEFT JOIN public.lwb_companies co ON co.id = g.company_id),
    'companies', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', co.id, 'name', co.name) ORDER BY co.name), '[]'::jsonb) FROM public.lwb_companies co),
    'run', (SELECT jsonb_build_object('trigger', r.trigger, 'at', r.at) FROM public.lwb_daily_wa_runs r WHERE r.report_date = d),
    'log', (SELECT coalesce(jsonb_agg(jsonb_build_object('kind', l.kind, 'name', l.name, 'mobile', l.mobile, 'test', l.test,
                 'status', l.status, 'error', l.error, 'at', coalesce(l.sent_at, l.created_at)) ORDER BY l.id DESC), '[]'::jsonb)
            FROM (SELECT * FROM public.lwb_daily_wa_log WHERE report_date = d ORDER BY id DESC LIMIT 300) l));
END;
$fn$;

-- p_people: [{user_id, kind, enabled}]
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_save(p_enabled boolean, p_backup_time text, p_focus_tasks boolean DEFAULT true, p_people jsonb DEFAULT '[]'::jsonb)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r jsonb; v_t time;
BEGIN
  IF NOT public.lwb_daily_wa_admin() THEN RAISE EXCEPTION 'Only Admin can change WhatsApp Reports'; END IF;
  IF nullif(btrim(coalesce(p_backup_time,'')),'') IS NOT NULL THEN
    BEGIN v_t := btrim(p_backup_time)::time; EXCEPTION WHEN others THEN RAISE EXCEPTION 'Back-up time must be like 23:00'; END;
  END IF;
  UPDATE public.lwb_daily_wa_config SET enabled = coalesce(p_enabled, false), backup_time = v_t, focus_tasks = coalesce(p_focus_tasks, true),
    updated_at = now(), updated_by = auth.uid() WHERE id = 1;
  FOR r IN SELECT x FROM jsonb_array_elements(coalesce(p_people, '[]'::jsonb)) x LOOP
    INSERT INTO public.lwb_daily_wa_people(user_id, kind, enabled, updated_at, updated_by)
    VALUES ((r->>'user_id')::uuid, r->>'kind', (r->>'enabled')::boolean, now(), auth.uid())
    ON CONFLICT (user_id, kind) DO UPDATE SET enabled = EXCLUDED.enabled, updated_at = now(), updated_by = auth.uid();
  END LOOP;
END;
$fn$;

-- MGR list: add / rename / brand / on-off; p_id NULL = new.
CREATE OR REPLACE FUNCTION public.lwb_company_mgr_save(p_id bigint, p_name text, p_company_id uuid, p_active boolean DEFAULT true)
RETURNS bigint LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id bigint;
BEGIN
  IF NOT public.lwb_daily_wa_admin() THEN RAISE EXCEPTION 'Only Admin can change MGRs'; END IF;
  IF nullif(btrim(coalesce(p_name,'')),'') IS NULL THEN RAISE EXCEPTION 'Enter the MGR name'; END IF;
  IF p_id IS NULL THEN
    INSERT INTO public.lwb_company_mgrs(name, company_id, active) VALUES (btrim(p_name), p_company_id, coalesce(p_active, true)) RETURNING id INTO v_id;
  ELSE
    UPDATE public.lwb_company_mgrs SET name = btrim(p_name), company_id = p_company_id, active = coalesce(p_active, true) WHERE id = p_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'MGR not found'; END IF;
  END IF;
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'An MGR with this name already exists';
END;
$fn$;

-- Salesman under an MGR (p_mgr_id NULL = none).
CREATE OR REPLACE FUNCTION public.lwb_salesman_mgr_set(p_user_id uuid, p_mgr_id bigint)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_daily_wa_admin() THEN RAISE EXCEPTION 'Only Admin can set the MGR of a salesman'; END IF;
  IF p_mgr_id IS NULL THEN
    DELETE FROM public.lwb_salesman_mgr WHERE user_id = p_user_id;
  ELSE
    INSERT INTO public.lwb_salesman_mgr(user_id, mgr_id, updated_at, updated_by) VALUES (p_user_id, p_mgr_id, now(), auth.uid())
    ON CONFLICT (user_id) DO UPDATE SET mgr_id = EXCLUDED.mgr_id, updated_at = now(), updated_by = auth.uid();
  END IF;
END;
$fn$;

-- TEST = one of every report to my own WhatsApp; TEST_DAYBOOK = only the Day Book PDF to me;
-- ALL = send now to everyone not sent yet for that date.
CREATE OR REPLACE FUNCTION public.lwb_daily_wa_send(p_date date, p_mode text)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE d date := coalesce(p_date, (now() AT TIME ZONE 'Asia/Kolkata')::date);
BEGIN
  IF NOT public.lwb_daily_wa_admin() THEN RAISE EXCEPTION 'Only Admin can send WhatsApp Reports'; END IF;
  IF d > (now() AT TIME ZONE 'Asia/Kolkata')::date OR d < (now() AT TIME ZONE 'Asia/Kolkata')::date - 7 THEN
    RAISE EXCEPTION 'Choose today or a date in the last 7 days';
  END IF;
  IF upper(p_mode) IN ('TEST', 'TEST_DAYBOOK') THEN
    IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND public.lwb_daily_wa_mobile(p.mobile::text) IS NOT NULL) THEN
      RAISE EXCEPTION 'Your login has no Login Mobile. Add it in Manage Users first.';
    END IF;
    IF NOT public.lwb_daily_wa_call(d, auth.uid(), CASE WHEN upper(p_mode) = 'TEST_DAYBOOK' THEN 'DAYBOOK' END) THEN
      RAISE EXCEPTION 'Sending is not set up on the server (pg_net)';
    END IF;
    RETURN upper(p_mode);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_daily_wa_config WHERE id = 1 AND enabled) THEN
    RAISE EXCEPTION 'Turn on "Send reports after Close Day" and Save first';
  END IF;
  PERFORM public.lwb_daily_wa_fire(d, 'MANUAL');
  RETURN 'ALL';
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_daily_wa_admin(), public.lwb_daily_wa_page(date), public.lwb_daily_wa_save(boolean, text, boolean, jsonb),
  public.lwb_company_mgr_save(bigint, text, uuid, boolean), public.lwb_salesman_mgr_set(uuid, bigint), public.lwb_daily_wa_send(date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_daily_wa_admin(), public.lwb_daily_wa_page(date), public.lwb_daily_wa_save(boolean, text, boolean, jsonb),
  public.lwb_company_mgr_save(bigint, text, uuid, boolean), public.lwb_salesman_mgr_set(uuid, bigint), public.lwb_daily_wa_send(date, text) TO authenticated;

-- Back-up check every 10 minutes (does something only after the back-up time, once a day).
DO $c$ BEGIN
  IF to_regclass('cron.job') IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'lwb_daily_whatsapp_backup') THEN
      PERFORM cron.schedule('lwb_daily_whatsapp_backup', '*/10 * * * *', 'SELECT public.lwb_daily_wa_tick()');
    END IF;
  END IF;
END $c$;

COMMIT;
