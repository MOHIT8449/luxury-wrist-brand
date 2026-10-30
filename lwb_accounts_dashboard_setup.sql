-- LUXURY WRIST BRAND ERP — ACCOUNTS DASHBOARD: CASH IN / CASH OUT, BANK DEPOSIT,
-- NIGHT CASH HANDOVER, BANK / UPI VERIFICATION BY ADMIN
--
-- Runs by itself when merged to main (after lwb_party_payment_collection_setup.sql). Safe to run again.
-- Nothing is dropped or deleted.
--
-- Mohit asked (30 Oct 2026) for an Accounts Manager dashboard (accounts-dashboard.html):
--  1. Date filter; today's Cash In and Cash Out. Payment collections are Cash In, money paid out is
--     Cash Out with an expense head (Food, Canteen, Salary, Labour, Maintenance ...). Heads can be added.
--  2. Bank deposit of the day; cash balance = opening + cash in − cash out − bank deposit.
--  3. Night: Accounts counts the cash and hands it to Admin / Sales Head. Morning: the same cash comes
--     back and is the opening balance of the next day.
--  4. Mode wise (Cash / UPI / Bank / RTGS / Cheque) and bank wise totals, party outstanding.
--  5. Every UPI / Bank / RTGS / Cheque receipt and every cash deposit waits for Admin to check the bank.
--     Admin gets a bell; once verified it counts in that bank.
--
-- Money already in the ERP is read, never copied (no double count):
--   PAYMENT      = Payment Collection on Tally bills (lwb_tally_payments, not cancelled)
--   DRIVER_CASH  = cash part of driver money received / verified by Office (lwb_delivery_reports)
--   DRIVER_ONLINE= UPI / bank part of that driver money
--   OLD          = old Payment Collection rows (lwb_payment_collections, POSTED)
--   ENTRY        = new manual entries of this page (lwb_acc_entries): other Cash In, expenses,
--                  bank deposits and cash withdrawn from the bank
-- The private Cashbook is not read. Party ledger, Tally, stock are not changed.
-- Money from the ERP counts on the day it was entered / received at the office (India time); a
-- receipt entered after that day was closed counts on the next day.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Who can use it
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin'));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) = 'admin');
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_today()
RETURNS date LANGUAGE sql STABLE SET search_path = ''
AS $fn$ SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date $fn$;

-- ---------------------------------------------------------------------------
-- 1. Tables (no grants: read and written only through the functions below)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_acc_categories (
  id         bigserial PRIMARY KEY,
  kind       text NOT NULL CHECK (kind IN ('IN','OUT')),
  name       text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 60),
  active     boolean NOT NULL DEFAULT true,
  sort       integer NOT NULL DEFAULT 100,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_acc_categories_name_uidx ON public.lwb_acc_categories(kind, lower(btrim(name)));

CREATE TABLE IF NOT EXISTS public.lwb_acc_banks (
  id              bigserial PRIMARY KEY,
  name            text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 80),
  account_no      text CHECK (account_no IS NULL OR length(account_no) <= 40),
  opening_balance numeric(14,2) NOT NULL DEFAULT 0,
  opening_date    date,
  active          boolean NOT NULL DEFAULT true,
  created_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_acc_banks_name_uidx ON public.lwb_acc_banks(lower(btrim(name)));

CREATE TABLE IF NOT EXISTS public.lwb_acc_entries (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_date    date NOT NULL,
  kind          text NOT NULL CHECK (kind IN ('IN','OUT','DEPOSIT','WITHDRAW')),
  category_id   bigint REFERENCES public.lwb_acc_categories(id),
  mode          text NOT NULL CHECK (mode IN ('CASH','UPI','BANK','RTGS','CHEQUE')),
  bank_id       bigint REFERENCES public.lwb_acc_banks(id),
  amount        numeric(14,2) NOT NULL CHECK (amount > 0),
  party         text CHECK (party IS NULL OR length(party) <= 120),
  ref_no        text CHECK (ref_no IS NULL OR length(ref_no) <= 100),
  remark        text CHECK (remark IS NULL OR length(remark) <= 300),
  created_by    uuid NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  cancelled_by  uuid,
  cancelled_at  timestamptz,
  cancel_reason text
);
CREATE INDEX IF NOT EXISTS lwb_acc_entries_date_idx ON public.lwb_acc_entries(entry_date);

-- Admin's bank check of one money line (any source). No row = waiting.
CREATE TABLE IF NOT EXISTS public.lwb_acc_verify (
  src         text NOT NULL,
  src_id      uuid NOT NULL,
  status      text NOT NULL CHECK (status IN ('VERIFIED','REJECTED')),
  bank_id     bigint REFERENCES public.lwb_acc_banks(id),
  note        text CHECK (note IS NULL OR length(note) <= 300),
  verified_by uuid NOT NULL,
  verified_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (src, src_id)
);

-- Night cash count + handover; morning return. The counted cash (or what came back) is the next
-- day's opening cash. is_start = the first opening cash set when the dashboard was started.
CREATE TABLE IF NOT EXISTS public.lwb_acc_day_close (
  id              bigserial PRIMARY KEY,
  close_date      date NOT NULL,
  is_start        boolean NOT NULL DEFAULT false,
  opening         numeric(14,2) NOT NULL DEFAULT 0,
  cash_in         numeric(14,2) NOT NULL DEFAULT 0,
  cash_out        numeric(14,2) NOT NULL DEFAULT 0,
  deposit         numeric(14,2) NOT NULL DEFAULT 0,
  withdraw        numeric(14,2) NOT NULL DEFAULT 0,
  expected        numeric(14,2) NOT NULL DEFAULT 0,
  counted         numeric(14,2) NOT NULL CHECK (counted >= 0),
  counted_notes   jsonb,
  handed_to       uuid,
  handed_to_name  text,
  note            text CHECK (note IS NULL OR length(note) <= 300),
  closed_by       uuid NOT NULL,
  closed_at       timestamptz NOT NULL DEFAULT now(),
  returned_amount numeric(14,2),
  returned_by     uuid,
  returned_at     timestamptz,
  return_note     text CHECK (return_note IS NULL OR length(return_note) <= 300),
  cancelled_by    uuid,
  cancelled_at    timestamptz,
  cancel_reason   text
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_acc_day_close_date_uidx ON public.lwb_acc_day_close(close_date) WHERE cancelled_at IS NULL;

ALTER TABLE public.lwb_acc_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_acc_banks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_acc_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_acc_verify ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_acc_day_close ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_acc_categories, public.lwb_acc_banks, public.lwb_acc_entries,
  public.lwb_acc_verify, public.lwb_acc_day_close FROM PUBLIC, anon, authenticated;

-- Starting heads (only added when missing; Accounts can add more, Admin can switch off).
INSERT INTO public.lwb_acc_categories (kind, name, sort)
SELECT v.kind, v.name, v.sort FROM (VALUES
  ('OUT','Food',10),('OUT','Canteen',20),('OUT','Tea / Refreshment',30),('OUT','Salary',40),
  ('OUT','Staff advance',50),('OUT','Labour charge',60),('OUT','Loading / Unloading',70),
  ('OUT','Maintenance',80),('OUT','Repair',90),('OUT','Diesel / Fuel',100),('OUT','Transport / Freight',110),
  ('OUT','Rent',120),('OUT','Electricity',130),('OUT','Office expense',140),('OUT','Stationery / Printing',150),
  ('OUT','Supplier payment',160),('OUT','Other expense',990),
  ('IN','Party payment',10),('IN','Owner / Capital',20),('IN','Scrap sale',30),('IN','Refund received',40),
  ('IN','Other income',990)
) v(kind, name, sort)
WHERE NOT EXISTS (SELECT 1 FROM public.lwb_acc_categories c WHERE c.kind = v.kind AND lower(btrim(c.name)) = lower(v.name));

-- ---------------------------------------------------------------------------
-- 2. Which day a money line counts on: its India date, or the next day when that day was
--    already closed before it was entered.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_book_day(p_at timestamptz)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM public.lwb_acc_day_close c
                           WHERE c.cancelled_at IS NULL AND c.close_date = (p_at AT TIME ZONE 'Asia/Kolkata')::date
                             AND c.closed_at <= p_at)
              THEN (p_at AT TIME ZONE 'Asia/Kolkata')::date + 1
              ELSE (p_at AT TIME ZONE 'Asia/Kolkata')::date END;
$fn$;

-- Every money line of every source. Internal only.
-- cash_effect: what it does to the cash in hand (+ / −). needs_verify: Admin must check the bank.
CREATE OR REPLACE FUNCTION public.lwb_acc_lines()
RETURNS TABLE (src text, id uuid, book_date date, at timestamptz, kind text, mode text, amount numeric,
               category text, party text, ref text, remark text, order_no text, bank_id bigint,
               cash_effect numeric, needs_verify boolean, created_by uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  RETURN QUERY
  SELECT 'ENTRY'::text, e.id, e.entry_date, e.created_at, e.kind, e.mode, e.amount,
         coalesce(c.name, CASE e.kind WHEN 'DEPOSIT' THEN 'Bank deposit' WHEN 'WITHDRAW' THEN 'Cash from bank' END),
         e.party, e.ref_no, e.remark, NULL::text, e.bank_id,
         CASE WHEN e.kind = 'IN' AND e.mode = 'CASH' THEN e.amount
              WHEN e.kind = 'OUT' AND e.mode = 'CASH' THEN -e.amount
              WHEN e.kind = 'DEPOSIT' THEN -e.amount
              WHEN e.kind = 'WITHDRAW' THEN e.amount ELSE 0 END,
         (e.kind = 'IN' AND e.mode <> 'CASH') OR e.kind = 'DEPOSIT',
         e.created_by
  FROM public.lwb_acc_entries e
  LEFT JOIN public.lwb_acc_categories c ON c.id = e.category_id
  WHERE e.cancelled_at IS NULL;

  RETURN QUERY
  SELECT 'PAYMENT'::text, p.id, public.lwb_acc_book_day(p.created_at), p.created_at, 'IN'::text, p.mode, p.amount,
         'Payment collection'::text, btrim(o.customer_name::text), p.ref_no,
         concat_ws(' · ', 'Tally bill ' || nullif(t.invoice_no,''), 'paid on ' || to_char(p.pay_date,'DD/MM/YYYY'), p.remark),
         o.order_no::text, NULL::bigint,
         CASE WHEN p.mode = 'CASH' THEN p.amount ELSE 0 END, p.mode <> 'CASH', p.created_by
  FROM public.lwb_tally_payments p
  JOIN public.orders o ON o.id = p.order_id
  LEFT JOIN public.lwb_tally_invoices t ON t.order_id = p.order_id
  WHERE p.cancelled_at IS NULL;

  -- Driver money once Office received / verified it. Older rows have only cash_reported + payment_mode.
  RETURN QUERY
  WITH d AS (
    SELECT r.id, r.payment_reviewed_at AS at, r.payment_reviewed_by, btrim(o.customer_name::text) AS party,
           o.order_no::text AS order_no, coalesce(dp.full_name, 'Driver') AS driver,
           coalesce(r.cash_amount, CASE WHEN r.online_amount IS NULL AND coalesce(r.payment_mode,'CASH') = 'CASH'
                                        THEN r.cash_reported ELSE 0 END) AS cash,
           coalesce(r.online_amount, CASE WHEN r.cash_amount IS NULL AND coalesce(r.payment_mode,'CASH') <> 'CASH'
                                          THEN r.cash_reported ELSE 0 END) AS online,
           coalesce(nullif(r.online_mode,''), nullif(regexp_replace(coalesce(r.payment_mode,''), '^CASH\+?', ''), ''), 'UPI') AS omode,
           coalesce(nullif(btrim(r.bank_ref),''), nullif(btrim(r.online_reference),''), nullif(btrim(r.payment_reference),'')) AS ref
    FROM public.lwb_delivery_reports r
    JOIN public.orders o ON o.id = r.order_id
    LEFT JOIN public.user_profiles dp ON dp.id = r.driver_user_id
    WHERE r.payment_status = 'VERIFIED' AND r.payment_reviewed_at IS NOT NULL AND coalesce(r.cash_reported,0) > 0
  )
  SELECT 'DRIVER_CASH'::text, d.id, public.lwb_acc_book_day(d.at), d.at, 'IN'::text, 'CASH'::text, d.cash,
         'Driver collection'::text, d.party, NULL::text, 'Driver ' || d.driver, d.order_no, NULL::bigint,
         d.cash, false, d.payment_reviewed_by
  FROM d WHERE d.cash > 0
  UNION ALL
  SELECT 'DRIVER_ONLINE'::text, d.id, public.lwb_acc_book_day(d.at), d.at, 'IN'::text,
         CASE WHEN d.omode IN ('UPI','BANK','CHEQUE') THEN d.omode ELSE 'UPI' END, d.online,
         'Driver collection'::text, d.party, d.ref, 'Driver ' || d.driver, d.order_no, NULL::bigint,
         0::numeric, true, d.payment_reviewed_by
  FROM d WHERE d.online > 0;

  RETURN QUERY
  SELECT 'OLD'::text, c.id, public.lwb_acc_book_day(coalesce(c.reviewed_at, c.submitted_at)), coalesce(c.reviewed_at, c.submitted_at),
         'IN'::text, CASE WHEN c.payment_mode IN ('CASH','UPI','BANK','CHEQUE') THEN c.payment_mode ELSE 'BANK' END, c.amount,
         'Payment collection'::text, btrim(o.customer_name::text), c.reference_no, c.remarks, o.order_no::text, NULL::bigint,
         CASE WHEN c.payment_mode = 'CASH' THEN c.amount ELSE 0 END, c.payment_mode <> 'CASH', c.submitted_by
  FROM public.lwb_payment_collections c
  LEFT JOIN public.tax_invoices i ON i.id = c.invoice_id
  LEFT JOIN public.orders o ON o.id = i.order_id
  WHERE c.status = 'POSTED';
END;
$fn$;

-- Cash in hand at the start of day p_date: the last closed day's counted cash (or what came back in
-- the morning) + every cash line after it. set = false when no opening cash was ever set.
CREATE OR REPLACE FUNCTION public.lwb_acc_cash_at(p_date date)
RETURNS TABLE (amount numeric, is_set boolean, base_date date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE c public.lwb_acc_day_close%ROWTYPE;
BEGIN
  SELECT * INTO c FROM public.lwb_acc_day_close x
  WHERE x.cancelled_at IS NULL AND x.close_date < p_date ORDER BY x.close_date DESC LIMIT 1;
  IF c.id IS NULL THEN
    RETURN QUERY SELECT 0::numeric, false, NULL::date;
    RETURN;
  END IF;
  RETURN QUERY
  SELECT round(coalesce(c.returned_amount, c.counted) + coalesce((
           SELECT sum(l.cash_effect) FROM public.lwb_acc_lines() l
           WHERE l.book_date > c.close_date AND l.book_date < p_date), 0), 2),
         true, c.close_date;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_book_day(timestamptz), public.lwb_acc_lines(), public.lwb_acc_cash_at(date)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Bell for Admin: money waiting for the bank check. One unread bell per Admin, kept up to date.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_ping_admins()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_n integer; v_amt numeric; v_today_n integer; v_today numeric; v_msg text; a record;
BEGIN
  SELECT count(*), coalesce(sum(l.amount),0),
         count(*) FILTER (WHERE l.book_date = public.lwb_acc_today()),
         coalesce(sum(l.amount) FILTER (WHERE l.book_date = public.lwb_acc_today()),0)
    INTO v_n, v_amt, v_today_n, v_today
  FROM public.lwb_acc_lines() l
  WHERE l.needs_verify AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_verify v WHERE v.src = l.src AND v.src_id = l.id);

  IF v_n = 0 THEN
    UPDATE public.erp_notifications SET is_read = true WHERE notification_type = 'ACC_BANK_VERIFY' AND is_read = false;
    RETURN;
  END IF;
  v_msg := 'Today Rs ' || to_char(v_today,'FM99999999990.00') || ' in ' || v_today_n || ' bank / UPI / cheque / deposit entr'
           || CASE WHEN v_today_n = 1 THEN 'y' ELSE 'ies' END
           || '. Waiting for your bank check: ' || v_n || ' (Rs ' || to_char(v_amt,'FM99999999990.00')
           || '). Check the bank and verify on Accounts Dashboard.';
  FOR a IN SELECT p.id FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'admin' LOOP
    UPDATE public.erp_notifications SET message = v_msg, title = 'Bank check: Rs ' || to_char(v_amt,'FM99999999990') || ' to verify'
    WHERE user_id = a.id AND notification_type = 'ACC_BANK_VERIFY' AND is_read = false;
    IF NOT FOUND THEN
      INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
      VALUES (a.id, 'Bank check: Rs ' || to_char(v_amt,'FM99999999990') || ' to verify', v_msg, 'ACC_BANK_VERIFY');
    END IF;
  END LOOP;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_ping_admins() FROM PUBLIC, anon, authenticated;

-- New Payment Collection by UPI / Bank / Cheque, or driver UPI received by Office -> bell.
-- Never blocks the original save.
CREATE OR REPLACE FUNCTION public.lwb_acc_ping_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  BEGIN
    PERFORM public.lwb_acc_ping_admins();
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_ping_trigger() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_lwb_acc_ping_payment ON public.lwb_tally_payments;
CREATE TRIGGER trg_lwb_acc_ping_payment AFTER INSERT ON public.lwb_tally_payments
  FOR EACH ROW WHEN (NEW.mode <> 'CASH') EXECUTE FUNCTION public.lwb_acc_ping_trigger();

DROP TRIGGER IF EXISTS trg_lwb_acc_ping_driver ON public.lwb_delivery_reports;
CREATE TRIGGER trg_lwb_acc_ping_driver AFTER UPDATE OF payment_status ON public.lwb_delivery_reports
  FOR EACH ROW WHEN (NEW.payment_status = 'VERIFIED' AND OLD.payment_status IS DISTINCT FROM 'VERIFIED'
                     AND coalesce(NEW.payment_mode,'CASH') <> 'CASH')
  EXECUTE FUNCTION public.lwb_acc_ping_trigger();

-- ---------------------------------------------------------------------------
-- 4. Read: everything the dashboard shows for a date range
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_dashboard(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_from date := coalesce(p_from, public.lwb_acc_today());
  v_to date := coalesce(p_to, public.lwb_acc_today());
  v_open record; v_close record; v_last date;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts Dashboard is for active Accounts or Admin only'; END IF;
  IF v_to < v_from THEN v_to := v_from; END IF;
  IF v_to - v_from > 400 THEN RAISE EXCEPTION 'Choose 400 days or less'; END IF;
  SELECT * INTO v_open FROM public.lwb_acc_cash_at(v_from);
  SELECT * INTO v_close FROM public.lwb_acc_cash_at(v_to + 1);
  SELECT max(c.close_date) INTO v_last FROM public.lwb_acc_day_close c WHERE c.cancelled_at IS NULL;

  RETURN jsonb_build_object(
    'today', public.lwb_acc_today(),
    'from', v_from, 'to', v_to,
    'is_admin', public.lwb_acc_admin(),
    'opening', v_open.amount, 'opening_set', v_open.is_set,
    'closing', v_close.amount, 'closing_set', v_close.is_set,
    'last_close', v_last,
    'lines', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'src', l.src, 'id', l.id, 'date', l.book_date, 'at', l.at, 'kind', l.kind, 'mode', l.mode, 'amount', l.amount,
        'category', l.category, 'party', l.party, 'ref', l.ref, 'remark', l.remark, 'order_no', l.order_no,
        'bank_id', coalesce(v.bank_id, l.bank_id), 'cash', l.cash_effect, 'needs_verify', l.needs_verify,
        'status', CASE WHEN NOT l.needs_verify THEN 'NA' ELSE coalesce(v.status,'PENDING') END,
        'v_note', v.note, 'v_by', vp.full_name, 'v_at', v.verified_at,
        'by', cp.full_name, 'mine', l.created_by = auth.uid()) ORDER BY l.at DESC)
      FROM public.lwb_acc_lines() l
      LEFT JOIN public.lwb_acc_verify v ON v.src = l.src AND v.src_id = l.id
      LEFT JOIN public.user_profiles vp ON vp.id = v.verified_by
      LEFT JOIN public.user_profiles cp ON cp.id = l.created_by
      WHERE l.book_date BETWEEN v_from AND v_to), '[]'::jsonb),
    -- waiting for the bank check, any date
    'pending', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'src', l.src, 'id', l.id, 'date', l.book_date, 'at', l.at, 'kind', l.kind, 'mode', l.mode, 'amount', l.amount,
        'category', l.category, 'party', l.party, 'ref', l.ref, 'remark', l.remark, 'order_no', l.order_no,
        'bank_id', l.bank_id, 'by', cp.full_name) ORDER BY l.at)
      FROM public.lwb_acc_lines() l
      LEFT JOIN public.user_profiles cp ON cp.id = l.created_by
      WHERE l.needs_verify AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_verify v WHERE v.src = l.src AND v.src_id = l.id)), '[]'::jsonb),
    'closes', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', c.id, 'date', c.close_date, 'is_start', c.is_start, 'opening', c.opening, 'cash_in', c.cash_in,
        'cash_out', c.cash_out, 'deposit', c.deposit, 'withdraw', c.withdraw, 'expected', c.expected,
        'counted', c.counted, 'notes', c.counted_notes, 'handed_to', c.handed_to, 'handed_to_name', c.handed_to_name,
        'note', c.note, 'closed_by', bp.full_name, 'closed_at', c.closed_at, 'returned', c.returned_amount,
        'returned_at', c.returned_at, 'returned_by', rp.full_name, 'return_note', c.return_note) ORDER BY c.close_date DESC)
      FROM public.lwb_acc_day_close c
      LEFT JOIN public.user_profiles bp ON bp.id = c.closed_by
      LEFT JOIN public.user_profiles rp ON rp.id = c.returned_by
      WHERE c.cancelled_at IS NULL AND (c.close_date BETWEEN v_from - 1 AND v_to
            OR (c.handed_to IS NOT NULL AND c.returned_at IS NULL AND c.close_date = v_last))), '[]'::jsonb),
    'banks', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', b.id, 'name', b.name, 'account_no', b.account_no, 'active', b.active,
        'opening_balance', b.opening_balance, 'opening_date', b.opening_date,
        'balance', round(b.opening_balance + coalesce((
          SELECT sum(CASE WHEN l.kind IN ('IN','DEPOSIT') THEN l.amount ELSE -l.amount END)
          FROM public.lwb_acc_lines() l
          LEFT JOIN public.lwb_acc_verify v ON v.src = l.src AND v.src_id = l.id
          WHERE coalesce(v.bank_id, l.bank_id) = b.id
            AND (b.opening_date IS NULL OR l.book_date >= b.opening_date)
            AND CASE WHEN l.needs_verify THEN v.status = 'VERIFIED'
                     ELSE (l.kind = 'WITHDRAW' OR (l.kind = 'OUT' AND l.mode <> 'CASH')) END), 0), 2))
        ORDER BY b.active DESC, b.name)
      FROM public.lwb_acc_banks b), '[]'::jsonb),
    'categories', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'name', c.name, 'active', c.active)
             ORDER BY c.kind, c.sort, c.name)
      FROM public.lwb_acc_categories c), '[]'::jsonb),
    'holders', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', p.id, 'name', coalesce(nullif(btrim(p.full_name),''), 'User'),
             'role', lower(btrim(p.role))) ORDER BY lower(btrim(p.role)), p.full_name)
      FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager')), '[]'::jsonb)
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. Write: entries, heads, banks
-- ---------------------------------------------------------------------------
-- p: {"date":"2026-10-30","kind":"OUT","category_id":3,"mode":"CASH","bank_id":null,"amount":450,
--     "party":"Ramesh","ref":"","remark":"tea for loading staff"}
CREATE OR REPLACE FUNCTION public.lwb_acc_add_entry(p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_id uuid;
  v_date date; v_kind text := upper(btrim(coalesce(p->>'kind','')));
  v_mode text := upper(btrim(coalesce(p->>'mode','CASH')));
  v_cat bigint; v_bank bigint; v_amt numeric;
  v_party text := nullif(btrim(coalesce(p->>'party','')),'');
  v_ref text := nullif(btrim(coalesce(p->>'ref','')),'');
  v_remark text := nullif(btrim(coalesce(p->>'remark','')),'');
  v_last date;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only active Accounts or Admin can enter money'; END IF;
  BEGIN
    v_date := (p->>'date')::date;
    v_cat := nullif(p->>'category_id','')::bigint;
    v_bank := nullif(p->>'bank_id','')::bigint;
    v_amt := round(nullif(p->>'amount','')::numeric, 2);
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the date and amount';
  END;
  IF v_kind NOT IN ('IN','OUT','DEPOSIT','WITHDRAW') THEN RAISE EXCEPTION 'Choose Cash In, Cash Out, Bank Deposit or Cash from Bank'; END IF;
  IF v_date IS NULL OR v_date > public.lwb_acc_today() THEN RAISE EXCEPTION 'Enter a valid date (not a future date)'; END IF;
  IF v_date < public.lwb_acc_today() - 60 THEN RAISE EXCEPTION 'Date is more than 60 days old'; END IF;
  SELECT max(c.close_date) INTO v_last FROM public.lwb_acc_day_close c WHERE c.cancelled_at IS NULL;
  IF v_last IS NOT NULL AND v_date <= v_last THEN
    RAISE EXCEPTION 'Day % is already closed. Enter it with a later date (or Admin reopens that day).', to_char(v_last,'DD/MM/YYYY');
  END IF;
  IF v_amt IS NULL OR v_amt <= 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'Enter the amount'; END IF;
  IF v_mode NOT IN ('CASH','UPI','BANK','RTGS','CHEQUE') THEN RAISE EXCEPTION 'Choose Cash, UPI, Bank, RTGS or Cheque'; END IF;
  IF length(coalesce(v_party,'')) > 120 OR length(coalesce(v_ref,'')) > 100 OR length(coalesce(v_remark,'')) > 300 THEN
    RAISE EXCEPTION 'Text is too long';
  END IF;

  IF v_kind IN ('IN','OUT') THEN
    IF v_cat IS NULL OR NOT EXISTS (SELECT 1 FROM public.lwb_acc_categories c WHERE c.id = v_cat AND c.kind = v_kind AND c.active) THEN
      RAISE EXCEPTION 'Choose the % head', CASE v_kind WHEN 'IN' THEN 'Cash In' ELSE 'expense' END;
    END IF;
    IF v_mode = 'CHEQUE' AND v_ref IS NULL THEN RAISE EXCEPTION 'Enter the cheque number'; END IF;
    IF v_mode <> 'CASH' AND v_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.lwb_acc_entries x WHERE x.cancelled_at IS NULL
         AND x.kind = v_kind AND x.mode = v_mode AND upper(btrim(x.ref_no)) = upper(v_ref)) THEN
      RAISE EXCEPTION '% reference % is already entered', v_mode, v_ref;
    END IF;
    IF v_mode = 'CASH' THEN v_bank := NULL; END IF;
  ELSE
    v_cat := NULL; v_mode := 'CASH';
    IF v_bank IS NULL THEN RAISE EXCEPTION 'Choose the bank'; END IF;
  END IF;
  IF v_bank IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_banks b WHERE b.id = v_bank AND b.active) THEN
    RAISE EXCEPTION 'Choose an active bank';
  END IF;
  IF v_kind = 'IN' AND v_mode = 'CASH' AND v_amt >= 200000 THEN
    RAISE EXCEPTION 'Cash of Rs 2 lakh or more from one person in one go is not allowed (Income Tax 269ST).';
  END IF;

  INSERT INTO public.lwb_acc_entries (entry_date, kind, category_id, mode, bank_id, amount, party, ref_no, remark, created_by)
  VALUES (v_date, v_kind, v_cat, v_mode, v_bank, v_amt, v_party, v_ref, v_remark, auth.uid())
  RETURNING id INTO v_id;

  IF (v_kind = 'IN' AND v_mode <> 'CASH') OR v_kind = 'DEPOSIT' THEN
    PERFORM public.lwb_acc_ping_admins();
  END IF;
  RETURN v_id;
END;
$fn$;

-- A wrong entry is cancelled (kept for the record). Own entry by Accounts, any by Admin.
-- A bank-checked entry only by Admin. Not on a closed day.
CREATE OR REPLACE FUNCTION public.lwb_acc_cancel_entry(p_id uuid, p_reason text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE e public.lwb_acc_entries%ROWTYPE; v_reason text := nullif(btrim(coalesce(p_reason,'')),''); v_last date;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only active Accounts or Admin can cancel'; END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Write why it is cancelled'; END IF;
  SELECT * INTO e FROM public.lwb_acc_entries WHERE id = p_id FOR UPDATE;
  IF e.id IS NULL OR e.cancelled_at IS NOT NULL THEN RAISE EXCEPTION 'Entry not found'; END IF;
  IF NOT public.lwb_acc_admin() THEN
    IF e.created_by IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Only Admin can cancel another person''s entry'; END IF;
    IF EXISTS (SELECT 1 FROM public.lwb_acc_verify v WHERE v.src = 'ENTRY' AND v.src_id = p_id AND v.status = 'VERIFIED') THEN
      RAISE EXCEPTION 'Admin has already checked this in the bank. Ask Admin to cancel it.';
    END IF;
  END IF;
  SELECT max(c.close_date) INTO v_last FROM public.lwb_acc_day_close c WHERE c.cancelled_at IS NULL;
  IF v_last IS NOT NULL AND e.entry_date <= v_last THEN
    RAISE EXCEPTION 'Day % is closed. Admin must reopen it first.', to_char(e.entry_date,'DD/MM/YYYY');
  END IF;
  UPDATE public.lwb_acc_entries SET cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = left(v_reason,300)
  WHERE id = p_id;
  PERFORM public.lwb_acc_ping_admins();
  RETURN 'CANCELLED';
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_save_category(p_id bigint, p_kind text, p_name text, p_active boolean)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id bigint; v_name text := btrim(regexp_replace(coalesce(p_name,''), '\s+', ' ', 'g'));
        v_kind text := upper(btrim(coalesce(p_kind,'')));
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only active Accounts or Admin can change heads'; END IF;
  IF length(v_name) < 2 OR length(v_name) > 60 THEN RAISE EXCEPTION 'Write a head name (2 to 60 letters)'; END IF;
  IF p_id IS NULL THEN
    IF v_kind NOT IN ('IN','OUT') THEN RAISE EXCEPTION 'Choose Cash In or Cash Out'; END IF;
    SELECT c.id INTO v_id FROM public.lwb_acc_categories c WHERE c.kind = v_kind AND lower(btrim(c.name)) = lower(v_name);
    IF v_id IS NOT NULL THEN
      UPDATE public.lwb_acc_categories SET active = true WHERE id = v_id;
      RETURN v_id;
    END IF;
    INSERT INTO public.lwb_acc_categories (kind, name, sort, created_by) VALUES (v_kind, v_name, 500, auth.uid()) RETURNING id INTO v_id;
    RETURN v_id;
  END IF;
  IF coalesce(p_active, true) = false AND NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can switch off a head'; END IF;
  UPDATE public.lwb_acc_categories SET name = v_name, active = coalesce(p_active, active) WHERE id = p_id RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'Head not found'; END IF;
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'This head already exists';
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_save_bank(p_id bigint, p_name text, p_account_no text,
                                                    p_opening numeric, p_opening_date date, p_active boolean)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id bigint; v_name text := btrim(regexp_replace(coalesce(p_name,''), '\s+', ' ', 'g'));
        v_acc text := nullif(btrim(coalesce(p_account_no,'')),'');
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only active Accounts or Admin can change banks'; END IF;
  IF length(v_name) < 2 OR length(v_name) > 80 THEN RAISE EXCEPTION 'Write the bank name'; END IF;
  IF length(coalesce(v_acc,'')) > 40 THEN RAISE EXCEPTION 'Account number is too long'; END IF;
  IF p_id IS NOT NULL AND NOT public.lwb_acc_admin() AND EXISTS (SELECT 1 FROM public.lwb_acc_banks b WHERE b.id = p_id
       AND (b.opening_balance IS DISTINCT FROM round(coalesce(p_opening,0),2) OR b.opening_date IS DISTINCT FROM p_opening_date
            OR b.active IS DISTINCT FROM coalesce(p_active,true))) THEN
    RAISE EXCEPTION 'Only Admin can change the opening balance or switch off a bank';
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO public.lwb_acc_banks (name, account_no, opening_balance, opening_date, created_by)
    VALUES (v_name, v_acc, round(coalesce(p_opening,0),2), p_opening_date, auth.uid()) RETURNING id INTO v_id;
  ELSE
    UPDATE public.lwb_acc_banks SET name = v_name, account_no = v_acc, opening_balance = round(coalesce(p_opening,0),2),
      opening_date = p_opening_date, active = coalesce(p_active,true)
    WHERE id = p_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Bank not found'; END IF;
  END IF;
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'This bank is already added';
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 6. Admin bank check
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_verify_line(p_src text, p_id uuid, p_ok boolean, p_bank_id bigint, p_note text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE l record; v_note text := nullif(btrim(coalesce(p_note,'')),''); v_bank bigint := p_bank_id;
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin checks the bank'; END IF;
  SELECT * INTO l FROM public.lwb_acc_lines() x WHERE x.src = p_src AND x.id = p_id AND x.needs_verify LIMIT 1;
  IF l.id IS NULL THEN RAISE EXCEPTION 'Entry not found'; END IF;
  IF coalesce(p_ok,false) THEN
    v_bank := coalesce(v_bank, l.bank_id);
    IF v_bank IS NULL OR NOT EXISTS (SELECT 1 FROM public.lwb_acc_banks b WHERE b.id = v_bank) THEN
      RAISE EXCEPTION 'Choose the bank where this money came';
    END IF;
  ELSE
    IF v_note IS NULL THEN RAISE EXCEPTION 'Write why (for example: not in bank)'; END IF;
  END IF;
  INSERT INTO public.lwb_acc_verify (src, src_id, status, bank_id, note, verified_by, verified_at)
  VALUES (p_src, p_id, CASE WHEN p_ok THEN 'VERIFIED' ELSE 'REJECTED' END, CASE WHEN p_ok THEN v_bank END,
          left(v_note,300), auth.uid(), now())
  ON CONFLICT (src, src_id) DO UPDATE SET status = EXCLUDED.status, bank_id = EXCLUDED.bank_id, note = EXCLUDED.note,
    verified_by = EXCLUDED.verified_by, verified_at = EXCLUDED.verified_at;

  IF NOT coalesce(p_ok,false) AND l.created_by IS NOT NULL AND l.created_by IS DISTINCT FROM auth.uid() THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
    VALUES (l.created_by, 'Not found in bank: Rs ' || to_char(l.amount,'FM99999999990.00'),
            l.mode || ' Rs ' || to_char(l.amount,'FM99999999990.00') || coalesce(' · ' || l.party,'') || coalesce(' · Ref ' || l.ref,'')
            || ' · ' || to_char(l.book_date,'DD/MM/YYYY') || ' · Admin: ' || v_note, 'ACC_BANK_REJECTED');
  END IF;
  PERFORM public.lwb_acc_ping_admins();
  RETURN CASE WHEN p_ok THEN 'VERIFIED' ELSE 'REJECTED' END;
END;
$fn$;

-- Admin changes his mind: back to waiting.
CREATE OR REPLACE FUNCTION public.lwb_acc_unverify_line(p_src text, p_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin checks the bank'; END IF;
  DELETE FROM public.lwb_acc_verify WHERE src = p_src AND src_id = p_id;
  PERFORM public.lwb_acc_ping_admins();
  RETURN 'PENDING';
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 7. Night close + handover, morning return, first opening cash
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_note_total(p_notes jsonb)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $fn$
DECLARE v_key text; v_cnt numeric; v_total numeric := 0;
BEGIN
  IF p_notes IS NULL OR jsonb_typeof(p_notes) <> 'object' THEN RAISE EXCEPTION 'Count the cash notes'; END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_notes) LOOP
    IF v_key NOT IN ('2000','500','200','100','50','20','10','coins') THEN RAISE EXCEPTION 'Unknown note %', v_key; END IF;
    BEGIN
      v_cnt := coalesce(nullif(p_notes->>v_key,''),'0')::numeric;
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter a number for %', v_key;
    END;
    IF v_cnt < 0 OR v_cnt > 1000000 OR (v_key <> 'coins' AND v_cnt <> trunc(v_cnt)) THEN RAISE EXCEPTION 'Check the count of %', v_key; END IF;
    v_total := v_total + CASE WHEN v_key = 'coins' THEN round(v_cnt,2) ELSE v_key::numeric * v_cnt END;
  END LOOP;
  RETURN v_total;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_close_day(p_date date, p_notes jsonb, p_handed_to uuid, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_open record; v_in numeric; v_out numeric; v_dep numeric; v_wd numeric; v_exp numeric; v_cnt numeric;
  v_last date; v_holder text; v_by text; v_note text := nullif(btrim(coalesce(p_note,'')),''); v_id bigint;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only active Accounts or Admin can close the day'; END IF;
  IF p_date IS NULL OR p_date > public.lwb_acc_today() THEN RAISE EXCEPTION 'Choose today or an earlier day'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_acc_day_close'));
  SELECT max(c.close_date) INTO v_last FROM public.lwb_acc_day_close c WHERE c.cancelled_at IS NULL;
  IF v_last IS NULL THEN RAISE EXCEPTION 'Set the opening cash first'; END IF;
  IF p_date <= v_last THEN RAISE EXCEPTION 'Day % is already closed', to_char(p_date,'DD/MM/YYYY'); END IF;
  IF length(coalesce(v_note,'')) > 300 THEN RAISE EXCEPTION 'Note is too long'; END IF;
  IF p_handed_to IS NOT NULL THEN
    SELECT coalesce(nullif(btrim(p.full_name),''),'User') INTO v_holder FROM public.user_profiles p
    WHERE p.id = p_handed_to AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager');
    IF v_holder IS NULL THEN RAISE EXCEPTION 'Cash can be handed only to an active Admin or Sales Head'; END IF;
  END IF;
  v_cnt := public.lwb_acc_note_total(p_notes);

  SELECT * INTO v_open FROM public.lwb_acc_cash_at(p_date);
  SELECT coalesce(sum(l.cash_effect) FILTER (WHERE l.kind = 'IN'),0),
         coalesce(-sum(l.cash_effect) FILTER (WHERE l.kind = 'OUT'),0),
         coalesce(-sum(l.cash_effect) FILTER (WHERE l.kind = 'DEPOSIT'),0),
         coalesce(sum(l.cash_effect) FILTER (WHERE l.kind = 'WITHDRAW'),0)
    INTO v_in, v_out, v_dep, v_wd
  FROM public.lwb_acc_lines() l WHERE l.book_date = p_date;
  v_exp := round(v_open.amount + v_in - v_out - v_dep + v_wd, 2);

  INSERT INTO public.lwb_acc_day_close (close_date, opening, cash_in, cash_out, deposit, withdraw, expected, counted,
    counted_notes, handed_to, handed_to_name, note, closed_by)
  VALUES (p_date, v_open.amount, v_in, v_out, v_dep, v_wd, v_exp, v_cnt, p_notes, p_handed_to, v_holder, v_note, auth.uid())
  RETURNING id INTO v_id;

  SELECT coalesce(nullif(btrim(p.full_name),''),'Accounts') INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();
  IF p_handed_to IS NOT NULL AND p_handed_to IS DISTINCT FROM auth.uid() THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
    VALUES (p_handed_to, 'Cash handover: Rs ' || to_char(v_cnt,'FM99999999990') || ' from ' || v_by,
      v_by || ' handed you Rs ' || to_char(v_cnt,'FM99999999990.00') || ' cash for ' || to_char(p_date,'DD/MM/YYYY')
      || '. Give it back in the morning; it is the next day''s opening cash.' || coalesce(' Note: ' || v_note, ''),
      'ACC_CASH_HANDOVER');
  END IF;
  IF abs(v_cnt - v_exp) >= 1 THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
    SELECT p.id, 'Cash ' || CASE WHEN v_cnt < v_exp THEN 'short' ELSE 'extra' END || ' Rs ' || to_char(abs(v_cnt - v_exp),'FM99999999990')
             || ' on ' || to_char(p_date,'DD/MM/YYYY'),
      'Book cash Rs ' || to_char(v_exp,'FM99999999990.00') || ', counted Rs ' || to_char(v_cnt,'FM99999999990.00')
      || ' by ' || v_by || '.' || coalesce(' Note: ' || v_note, ''), 'ACC_CASH_DIFF'
    FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'admin' AND p.id IS DISTINCT FROM auth.uid();
  END IF;
  RETURN jsonb_build_object('id', v_id, 'expected', v_exp, 'counted', v_cnt, 'difference', round(v_cnt - v_exp,2));
END;
$fn$;

-- Morning: the handed-over cash came back to Accounts.
CREATE OR REPLACE FUNCTION public.lwb_acc_cash_returned(p_close_id bigint, p_amount numeric, p_note text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE c public.lwb_acc_day_close%ROWTYPE; v_amt numeric := round(coalesce(p_amount,-1),2);
        v_note text := nullif(btrim(coalesce(p_note,'')),''); v_by text;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only active Accounts or Admin'; END IF;
  SELECT * INTO c FROM public.lwb_acc_day_close WHERE id = p_close_id AND cancelled_at IS NULL FOR UPDATE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'Day close not found'; END IF;
  IF c.returned_at IS NOT NULL THEN RAISE EXCEPTION 'Already received back'; END IF;
  IF v_amt < 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'Enter the cash received back'; END IF;
  IF abs(v_amt - c.counted) >= 1 AND v_note IS NULL THEN RAISE EXCEPTION 'Amount is different from the handover. Write why.'; END IF;
  UPDATE public.lwb_acc_day_close SET returned_amount = v_amt, returned_at = now(), returned_by = auth.uid(),
    return_note = left(v_note,300) WHERE id = c.id;
  SELECT coalesce(nullif(btrim(p.full_name),''),'Accounts') INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();
  UPDATE public.erp_notifications SET is_read = true
  WHERE user_id = c.handed_to AND notification_type = 'ACC_CASH_HANDOVER' AND is_read = false;
  IF c.handed_to IS NOT NULL AND c.handed_to IS DISTINCT FROM auth.uid() THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
    VALUES (c.handed_to, 'Cash back with Accounts: Rs ' || to_char(v_amt,'FM99999999990'),
      v_by || ' received Rs ' || to_char(v_amt,'FM99999999990.00') || ' back (handover of ' || to_char(c.close_date,'DD/MM/YYYY')
      || ': Rs ' || to_char(c.counted,'FM99999999990.00') || ').' || coalesce(' Note: ' || v_note,''), 'ACC_CASH_RETURNED');
  END IF;
  IF abs(v_amt - c.counted) >= 1 THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
    SELECT p.id, 'Morning cash differs by Rs ' || to_char(abs(v_amt - c.counted),'FM99999999990'),
      'Handed over Rs ' || to_char(c.counted,'FM99999999990.00') || ' on ' || to_char(c.close_date,'DD/MM/YYYY')
      || ', received back Rs ' || to_char(v_amt,'FM99999999990.00') || '. ' || v_note, 'ACC_CASH_DIFF'
    FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'admin' AND p.id IS DISTINCT FROM auth.uid();
  END IF;
  RETURN 'RETURNED';
END;
$fn$;

-- Opening cash when the dashboard starts (or again later by Admin): cash in hand at the start of p_date.
-- Accounts can set it only once; after that only Admin.
CREATE OR REPLACE FUNCTION public.lwb_acc_set_opening(p_date date, p_amount numeric, p_note text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_amt numeric := round(coalesce(p_amount,-1),2);
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only active Accounts or Admin'; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_acc_day_close c WHERE c.cancelled_at IS NULL) AND NOT public.lwb_acc_admin() THEN
    RAISE EXCEPTION 'Opening cash is already set. Only Admin can set it again.';
  END IF;
  IF p_date IS NULL OR p_date > public.lwb_acc_today() + 1 OR p_date < public.lwb_acc_today() - 60 THEN
    RAISE EXCEPTION 'Choose a date in the last 60 days';
  END IF;
  IF v_amt < 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'Enter the cash in hand'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_acc_day_close'));
  IF EXISTS (SELECT 1 FROM public.lwb_acc_day_close c WHERE c.cancelled_at IS NULL AND c.close_date >= p_date - 1) THEN
    RAISE EXCEPTION 'A day on or after % is already closed', to_char(p_date - 1,'DD/MM/YYYY');
  END IF;
  INSERT INTO public.lwb_acc_day_close (close_date, is_start, opening, expected, counted, note, closed_by,
                                        returned_amount, returned_by, returned_at)
  VALUES (p_date - 1, true, v_amt, v_amt, v_amt, left(coalesce(nullif(btrim(p_note),''),'Opening cash'),300), auth.uid(),
          v_amt, auth.uid(), now());
  RETURN 'OK';
END;
$fn$;

-- Admin reopens the last closed day (wrong count, missed entry). Kept for the record.
CREATE OR REPLACE FUNCTION public.lwb_acc_reopen_day(p_close_id bigint, p_reason text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE c public.lwb_acc_day_close%ROWTYPE; v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can reopen a day'; END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Write why'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_acc_day_close'));
  SELECT * INTO c FROM public.lwb_acc_day_close WHERE id = p_close_id AND cancelled_at IS NULL;
  IF c.id IS NULL THEN RAISE EXCEPTION 'Day close not found'; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_acc_day_close x WHERE x.cancelled_at IS NULL AND x.close_date > c.close_date) THEN
    RAISE EXCEPTION 'Only the last closed day can be reopened';
  END IF;
  UPDATE public.lwb_acc_day_close SET cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = left(v_reason,300)
  WHERE id = c.id;
  UPDATE public.erp_notifications SET is_read = true
  WHERE user_id = c.handed_to AND notification_type = 'ACC_CASH_HANDOVER' AND is_read = false;
  RETURN 'REOPENED';
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_note_total(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_acc_user(), public.lwb_acc_admin(), public.lwb_acc_today(),
  public.lwb_acc_dashboard(date,date), public.lwb_acc_add_entry(jsonb), public.lwb_acc_cancel_entry(uuid,text),
  public.lwb_acc_save_category(bigint,text,text,boolean), public.lwb_acc_save_bank(bigint,text,text,numeric,date,boolean),
  public.lwb_acc_verify_line(text,uuid,boolean,bigint,text), public.lwb_acc_unverify_line(text,uuid),
  public.lwb_acc_close_day(date,jsonb,uuid,text), public.lwb_acc_cash_returned(bigint,numeric,text),
  public.lwb_acc_set_opening(date,numeric,text), public.lwb_acc_reopen_day(bigint,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_user(), public.lwb_acc_admin(), public.lwb_acc_today(),
  public.lwb_acc_dashboard(date,date), public.lwb_acc_add_entry(jsonb), public.lwb_acc_cancel_entry(uuid,text),
  public.lwb_acc_save_category(bigint,text,text,boolean), public.lwb_acc_save_bank(bigint,text,text,numeric,date,boolean),
  public.lwb_acc_verify_line(text,uuid,boolean,bigint,text), public.lwb_acc_unverify_line(text,uuid),
  public.lwb_acc_close_day(date,jsonb,uuid,text), public.lwb_acc_cash_returned(bigint,numeric,text),
  public.lwb_acc_set_opening(date,numeric,text), public.lwb_acc_reopen_day(bigint,text)
  TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'entries table' AS item, (to_regclass('public.lwb_acc_entries') IS NOT NULL)::text AS ok
UNION ALL SELECT 'day close table', (to_regclass('public.lwb_acc_day_close') IS NOT NULL)::text
UNION ALL SELECT 'dashboard', (to_regprocedure('public.lwb_acc_dashboard(date,date)') IS NOT NULL)::text
UNION ALL SELECT 'expense heads', (SELECT count(*) > 0 FROM public.lwb_acc_categories)::text;
