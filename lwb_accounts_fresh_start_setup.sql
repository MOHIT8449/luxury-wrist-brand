-- LUXURY WRIST BRAND ERP — ACCOUNTS FRESH START (remove all Accounts Dashboard entries till today)
--
-- Runs by itself when merged to main (after every lwb_accounts_*.sql, lwb_bank_statement_setup.sql and
-- lwb_party_group_billing_setup.sql). Safe to run again. This file deletes NOTHING by itself.
--
-- Mohit (5 Nov 2026): remove every entry made so far in the Accounts Dashboard and start fresh with the
-- running data. He chose "Accounts entries only": party payments stay in the party ledger.
--
-- Page accounts-reset.html (Admin only, Settings > Accounts Fresh Start):
-- 1. lwb_acc_reset_preview(start_date)  counts what would go. Read only.
-- 2. lwb_acc_reset_run(start_date, 'RESET', opening_cash, banks)  Admin types RESET. One transaction:
--    every removed / changed row is first copied to lwb_acc_reset_rows (backup, lwb_acc_reset_backup).
--
-- Removed (Accounts' own data): Cash In / Cash Out / Bank deposit / Cash from bank entries (also staff
-- salary / upad and vehicle expenses, which are entries), opening cash + every day close / handover,
-- bank checks, cheque details, bank statement uploads + lines, staff monthly salary rows.
-- Reset: bank opening balance (to the new figure typed, else 0, from the start date), staff opening
-- balance (0 from the start date). Company payments made through a Cash Out stay in the company ledger
-- (only their link to the removed entry is cleared).
-- Kept: parties, POs, Tally bills, party payments / Payment Collection / driver money (party ledger and
-- outstanding do not change), stock, bank names, heads, staff and vehicle masters.
--
-- Start date: Accounts Dashboard money lines from the ERP (Payment Collection, party payments, driver
-- money) dated before the start date no longer count on the dashboard (cash, bank, bank check, cheques).
-- lwb_acc_lines() = lwb_acc_lines_all() from the start date. Future changes to the money lines go into
-- lwb_acc_lines_all() (a copy of the lwb_party_group_billing_setup.sql version).

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_acc_resets (
  id           bigserial PRIMARY KEY,
  start_date   date NOT NULL,
  opening_cash numeric(14,2),
  banks        jsonb NOT NULL DEFAULT '[]'::jsonb,
  counts       jsonb NOT NULL DEFAULT '{}'::jsonb,
  done_by      uuid,
  done_by_name text,
  done_at      timestamptz NOT NULL DEFAULT now()
);

-- Backup: one row per removed (or changed: old values) database row.
CREATE TABLE IF NOT EXISTS public.lwb_acc_reset_rows (
  id         bigserial PRIMARY KEY,
  reset_id   bigint NOT NULL REFERENCES public.lwb_acc_resets(id),
  tbl        text NOT NULL,
  action     text NOT NULL DEFAULT 'DELETED' CHECK (action IN ('DELETED','CHANGED')),
  row_data   jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_acc_reset_rows_reset_idx ON public.lwb_acc_reset_rows(reset_id, id);

ALTER TABLE public.lwb_acc_resets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_acc_reset_rows ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_acc_resets, public.lwb_acc_reset_rows FROM PUBLIC, anon, authenticated;

-- First day the Accounts Dashboard counts (no reset yet = every day).
CREATE OR REPLACE FUNCTION public.lwb_acc_start_date()
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT coalesce((SELECT max(r.start_date) FROM public.lwb_acc_resets r), DATE '2000-01-01') $fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_start_date() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_start_date() TO authenticated;

-- ---------------------------------------------------------------------------
-- Money lines: every line of every source (copy of the lwb_party_group_billing_setup.sql version) ...
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_lines_all()
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
         CASE WHEN p.order_id IS NULL THEN 'Party payment' ELSE 'Payment collection' END::text,
         coalesce(btrim(o.customer_name::text), public.lwb_party_parent(p.party)), p.ref_no,
         concat_ws(' · ', 'Tally bill ' || nullif(t.invoice_no,''), 'paid on ' || to_char(p.pay_date,'DD/MM/YYYY'), p.remark),
         o.order_no::text, NULL::bigint,
         CASE WHEN p.mode = 'CASH' THEN p.amount ELSE 0 END, p.mode <> 'CASH', p.created_by
  FROM public.lwb_tally_payments p
  LEFT JOIN public.orders o ON o.id = p.order_id
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

-- ... and what the dashboard counts: from the start date only.
CREATE OR REPLACE FUNCTION public.lwb_acc_lines()
RETURNS TABLE (src text, id uuid, book_date date, at timestamptz, kind text, mode text, amount numeric,
               category text, party text, ref text, remark text, order_no text, bank_id bigint,
               cash_effect numeric, needs_verify boolean, created_by uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT l.* FROM public.lwb_acc_lines_all() l WHERE l.book_date >= public.lwb_acc_start_date();
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_lines_all(), public.lwb_acc_lines() FROM PUBLIC, anon, authenticated;

-- Active Admin only.
CREATE OR REPLACE FUNCTION public.lwb_acc_reset_admin()
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p
                 WHERE p.id = auth.uid() AND p.active IS TRUE AND lower(btrim(p.role)) = 'admin') THEN
    RAISE EXCEPTION 'Only an active Admin can reset the accounts.';
  END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_reset_admin() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_acc_reset_check_date(p_start date)
RETURNS void LANGUAGE plpgsql STABLE SET search_path = ''
AS $fn$
BEGIN
  IF p_start IS NULL OR p_start > public.lwb_acc_today() OR p_start < public.lwb_acc_today() - 60 THEN
    RAISE EXCEPTION 'Choose a start date in the last 60 days (not after today).';
  END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_reset_check_date(date) FROM PUBLIC, anon, authenticated;

-- Bank balance as the dashboard shows it (same rule as lwb_acc_dashboard).
CREATE OR REPLACE FUNCTION public.lwb_acc_reset_bank_balance(p_bank bigint)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT round(b.opening_balance + coalesce((
    SELECT sum(CASE WHEN l.kind IN ('IN','DEPOSIT') THEN l.amount ELSE -l.amount END)
    FROM public.lwb_acc_lines() l
    LEFT JOIN public.lwb_acc_verify v ON v.src = l.src AND v.src_id = l.id
    WHERE coalesce(v.bank_id, l.bank_id) = b.id
      AND (b.opening_date IS NULL OR l.book_date >= b.opening_date)
      AND CASE WHEN l.needs_verify THEN v.status = 'VERIFIED'
               ELSE (l.kind = 'WITHDRAW' OR (l.kind = 'OUT' AND l.mode <> 'CASH')) END), 0), 2)
  FROM public.lwb_acc_banks b WHERE b.id = p_bank;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_reset_bank_balance(bigint) FROM PUBLIC, anon, authenticated;

-- Copy to the backup, then delete. Returns the number of rows.
CREATE OR REPLACE FUNCTION public.lwb_acc_reset_take(p_reset bigint, p_tbl text, p_where text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_n bigint;
BEGIN
  IF to_regclass('public.' || p_tbl) IS NULL THEN RETURN 0; END IF;
  EXECUTE format('INSERT INTO public.lwb_acc_reset_rows(reset_id, tbl, row_data) SELECT %s, %L, to_jsonb(x) FROM public.%I x WHERE %s',
                 p_reset, p_tbl, p_tbl, p_where);
  EXECUTE format('DELETE FROM public.%I x WHERE %s', p_tbl, p_where);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_reset_take(bigint, text, text) FROM PUBLIC, anon, authenticated;

-- Bank checks / cheque details that stay: ERP money (not this page's entries) on or after the start date.
CREATE OR REPLACE FUNCTION public.lwb_acc_reset_keep(p_start date)
RETURNS TABLE (src text, id uuid) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT l.src, l.id FROM public.lwb_acc_lines_all() l WHERE l.src <> 'ENTRY' AND l.book_date >= p_start;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_reset_keep(date) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Preview (read only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_reset_preview(p_start date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_keep jsonb; r jsonb := '{}'::jsonb; v jsonb;
BEGIN
  PERFORM public.lwb_acc_reset_admin();
  PERFORM public.lwb_acc_reset_check_date(p_start);

  SELECT coalesce(jsonb_agg(jsonb_build_object('src', k.src, 'id', k.id)), '[]'::jsonb) INTO v_keep FROM public.lwb_acc_reset_keep(p_start) k;

  SELECT jsonb_build_object('n', count(*), 'from', min(e.entry_date), 'to', max(e.entry_date),
           'cash_in', coalesce(sum(e.amount) FILTER (WHERE e.cancelled_at IS NULL AND e.kind = 'IN'), 0),
           'cash_out', coalesce(sum(e.amount) FILTER (WHERE e.cancelled_at IS NULL AND e.kind = 'OUT'), 0),
           'deposit', coalesce(sum(e.amount) FILTER (WHERE e.cancelled_at IS NULL AND e.kind = 'DEPOSIT'), 0),
           'withdraw', coalesce(sum(e.amount) FILTER (WHERE e.cancelled_at IS NULL AND e.kind = 'WITHDRAW'), 0),
           'n_in', count(*) FILTER (WHERE e.cancelled_at IS NULL AND e.kind = 'IN'),
           'n_out', count(*) FILTER (WHERE e.cancelled_at IS NULL AND e.kind = 'OUT'),
           'n_deposit', count(*) FILTER (WHERE e.cancelled_at IS NULL AND e.kind IN ('DEPOSIT','WITHDRAW')),
           'n_cancelled', count(*) FILTER (WHERE e.cancelled_at IS NOT NULL))
    INTO v FROM public.lwb_acc_entries e;
  r := r || jsonb_build_object('entries', v);

  SELECT jsonb_build_object('n', count(*), 'from', min(c.close_date), 'to', max(c.close_date)) INTO v FROM public.lwb_acc_day_close c;
  r := r || jsonb_build_object('day_close', v);
  SELECT c.amount INTO v FROM (SELECT to_jsonb(x.amount) AS amount FROM public.lwb_acc_cash_at(public.lwb_acc_today() + 1) x WHERE x.is_set) c;
  r := r || jsonb_build_object('cash_now', v);

  r := r || jsonb_build_object('verify', (SELECT count(*) FROM public.lwb_acc_verify x
             WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_keep) k WHERE k->>'src' = x.src AND (k->>'id')::uuid = x.src_id)));
  r := r || jsonb_build_object('cheques', (SELECT count(*) FROM public.lwb_acc_cheques x
             WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_keep) k WHERE k->>'src' = x.src AND (k->>'id')::uuid = x.src_id)));

  IF to_regclass('public.lwb_bank_stmt_lines') IS NOT NULL THEN
    EXECUTE 'SELECT jsonb_build_object(''n'', count(*), ''open'', count(*) FILTER (WHERE status = ''OPEN''), ''imports'', (SELECT count(*) FROM public.lwb_bank_stmt_imports))
             FROM public.lwb_bank_stmt_lines' INTO v;
    r := r || jsonb_build_object('bank_stmt', v);
  END IF;
  IF to_regclass('public.lwb_acc_staff_salary') IS NOT NULL THEN
    r := r || jsonb_build_object('staff_salary', (SELECT count(*) FROM public.lwb_acc_staff_salary),
              'staff_opening', (SELECT count(*) FROM public.lwb_acc_staff s WHERE s.opening_balance <> 0));
  END IF;
  IF to_regclass('public.lwb_company_payments') IS NOT NULL
     AND EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid = 'public.lwb_company_payments'::regclass AND a.attname = 'acc_entry_id' AND NOT a.attisdropped) THEN
    EXECUTE 'SELECT jsonb_build_object(''n'', count(*), ''amount'', coalesce(sum(amount) FILTER (WHERE cancelled_at IS NULL),0))
             FROM public.lwb_company_payments WHERE acc_entry_id IS NOT NULL' INTO v;
    r := r || jsonb_build_object('company_pay', v);
  END IF;

  -- ERP money before the start date: stays in the party ledger, stops counting on the dashboard.
  SELECT jsonb_build_object('n', count(*), 'amount', coalesce(sum(l.amount),0),
           'cash', coalesce(sum(l.amount) FILTER (WHERE l.mode = 'CASH'),0), 'online', coalesce(sum(l.amount) FILTER (WHERE l.mode <> 'CASH'),0))
    INTO v FROM public.lwb_acc_lines_all() l WHERE l.src <> 'ENTRY' AND l.book_date < p_start AND l.book_date >= public.lwb_acc_start_date();
  r := r || jsonb_build_object('erp_hidden', v);
  SELECT jsonb_build_object('n', count(*), 'amount', coalesce(sum(l.amount),0))
    INTO v FROM public.lwb_acc_lines_all() l WHERE l.src <> 'ENTRY' AND l.book_date >= p_start;
  r := r || jsonb_build_object('erp_kept', v);

  r := r || jsonb_build_object('banks', coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'account_no', b.account_no, 'active', b.active,
             'opening_balance', b.opening_balance, 'opening_date', b.opening_date,
             'balance', public.lwb_acc_reset_bank_balance(b.id)) ORDER BY b.active DESC, b.name)
    FROM public.lwb_acc_banks b), '[]'::jsonb));

  RETURN r || jsonb_build_object('start', p_start, 'today', public.lwb_acc_today(), 'current_start',
    (SELECT max(x.start_date) FROM public.lwb_acc_resets x),
    'last', (SELECT jsonb_build_object('id', x.id, 'at', x.done_at, 'by', x.done_by_name, 'start', x.start_date)
             FROM public.lwb_acc_resets x ORDER BY x.id DESC LIMIT 1));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_reset_preview(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_reset_preview(date) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Run. Admin types RESET. All or nothing.
--    p_opening_cash: cash in hand at the start of p_start (NULL = set it later on the dashboard).
--    p_banks: [{"id":1,"balance":125000}, ...] = bank balance at the start of p_start (missing = 0).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_reset_run(p_start date, p_typed text, p_opening_cash numeric, p_banks jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_id bigint; v_by text; c jsonb := '{}'::jsonb; v_n bigint; v_keep text := '';
  v_cash numeric := round(p_opening_cash, 2); b record; v_bal numeric;
BEGIN
  PERFORM public.lwb_acc_reset_admin();
  PERFORM public.lwb_acc_reset_check_date(p_start);
  IF upper(btrim(coalesce(p_typed,''))) <> 'RESET' THEN RAISE EXCEPTION 'Type RESET to confirm.'; END IF;
  IF v_cash IS NOT NULL AND (v_cash < 0 OR v_cash > 100000000) THEN RAISE EXCEPTION 'Enter the cash in hand (0 or more).'; END IF;
  IF p_banks IS NOT NULL AND jsonb_typeof(p_banks) <> 'array' THEN RAISE EXCEPTION 'Bank balances must be a list.'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_banks,'[]'::jsonb)) x
             WHERE NOT EXISTS (SELECT 1 FROM public.lwb_acc_banks k WHERE k.id::text = x->>'id')
                OR abs(coalesce((x->>'balance')::numeric,0)) > 10000000000) THEN
    RAISE EXCEPTION 'Check the bank balances.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('lwb_acc_day_close'));

  SELECT p.full_name INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.lwb_acc_resets(start_date, opening_cash, banks, done_by, done_by_name)
  VALUES (p_start, v_cash, coalesce(p_banks,'[]'::jsonb), auth.uid(), v_by) RETURNING id INTO v_id;

  -- Bank checks / cheque details that stay (worked out before day closes go: they decide the book day).
  SELECT coalesce(string_agg(format('(%L,%L::uuid)', k.src, k.id), ','), '') INTO v_keep FROM public.lwb_acc_reset_keep(p_start) k;
  v_keep := CASE WHEN v_keep = '' THEN 'true' ELSE format('(x.src, x.src_id) NOT IN (%s)', v_keep) END;

  c := c || jsonb_build_object('lwb_acc_verify', public.lwb_acc_reset_take(v_id, 'lwb_acc_verify', v_keep));
  c := c || jsonb_build_object('lwb_acc_cheques', public.lwb_acc_reset_take(v_id, 'lwb_acc_cheques', v_keep));
  c := c || jsonb_build_object('lwb_bank_stmt_lines', public.lwb_acc_reset_take(v_id, 'lwb_bank_stmt_lines', 'true'));
  c := c || jsonb_build_object('lwb_bank_stmt_imports', public.lwb_acc_reset_take(v_id, 'lwb_bank_stmt_imports', 'true'));

  -- Company payments made through a Cash Out stay (company ledger); only the link to the entry goes.
  IF to_regclass('public.lwb_company_payments') IS NOT NULL
     AND EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid = 'public.lwb_company_payments'::regclass AND a.attname = 'acc_entry_id' AND NOT a.attisdropped) THEN
    EXECUTE format('INSERT INTO public.lwb_acc_reset_rows(reset_id, tbl, action, row_data)
                    SELECT %s, ''lwb_company_payments'', ''CHANGED'', to_jsonb(x) FROM public.lwb_company_payments x WHERE x.acc_entry_id IS NOT NULL', v_id);
    UPDATE public.lwb_company_payments SET acc_entry_id = NULL WHERE acc_entry_id IS NOT NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    c := c || jsonb_build_object('company_pay_unlinked', v_n);
  END IF;

  c := c || jsonb_build_object('lwb_acc_entries', public.lwb_acc_reset_take(v_id, 'lwb_acc_entries', 'true'));
  c := c || jsonb_build_object('lwb_acc_staff_salary', public.lwb_acc_reset_take(v_id, 'lwb_acc_staff_salary', 'true'));
  c := c || jsonb_build_object('lwb_acc_day_close', public.lwb_acc_reset_take(v_id, 'lwb_acc_day_close', 'true'));

  IF to_regclass('public.lwb_acc_staff') IS NOT NULL THEN
    INSERT INTO public.lwb_acc_reset_rows(reset_id, tbl, action, row_data)
    SELECT v_id, 'lwb_acc_staff', 'CHANGED', to_jsonb(s) FROM public.lwb_acc_staff s
    WHERE s.opening_balance <> 0 OR s.opening_date IS DISTINCT FROM p_start;
    UPDATE public.lwb_acc_staff SET opening_balance = 0, opening_date = p_start
    WHERE opening_balance <> 0 OR opening_date IS DISTINCT FROM p_start;
  END IF;

  -- Banks: new balance from the start date.
  INSERT INTO public.lwb_acc_reset_rows(reset_id, tbl, action, row_data)
  SELECT v_id, 'lwb_acc_banks', 'CHANGED', to_jsonb(k) FROM public.lwb_acc_banks k;
  FOR b IN SELECT k.id FROM public.lwb_acc_banks k LOOP
    SELECT round(coalesce((x->>'balance')::numeric, 0), 2) INTO v_bal
    FROM jsonb_array_elements(coalesce(p_banks,'[]'::jsonb)) x WHERE x->>'id' = b.id::text LIMIT 1;
    UPDATE public.lwb_acc_banks SET opening_balance = coalesce(v_bal, 0), opening_date = p_start WHERE id = b.id;
  END LOOP;

  -- Opening cash of the start date (same row as "Set opening cash" on the dashboard).
  IF v_cash IS NOT NULL THEN
    INSERT INTO public.lwb_acc_day_close (close_date, is_start, opening, expected, counted, note, closed_by,
                                          returned_amount, returned_by, returned_at)
    VALUES (p_start - 1, true, v_cash, v_cash, v_cash, 'Opening cash (Accounts fresh start)', auth.uid(), v_cash, auth.uid(), now());
  END IF;

  -- Old Accounts bells are read; the bank-check bell is worked out again for what is left.
  UPDATE public.erp_notifications SET is_read = true WHERE notification_type LIKE 'ACC\_%' AND is_read = false;
  BEGIN
    PERFORM public.lwb_acc_ping_admins();
  EXCEPTION WHEN others THEN NULL;
  END;

  UPDATE public.lwb_acc_resets SET counts = c WHERE id = v_id;
  RETURN jsonb_build_object('id', v_id, 'counts', c);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_reset_run(date, text, numeric, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_reset_run(date, text, numeric, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Backup rows of a reset (Admin download), 2000 per call.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_reset_backup(p_reset bigint, p_after bigint DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  PERFORM public.lwb_acc_reset_admin();
  RETURN jsonb_build_object(
    'reset', (SELECT to_jsonb(r) FROM public.lwb_acc_resets r WHERE r.id = p_reset),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('n', b.id, 'table', b.tbl, 'action', b.action, 'row', b.row_data) ORDER BY b.id)
                      FROM (SELECT * FROM public.lwb_acc_reset_rows WHERE reset_id = p_reset AND id > coalesce(p_after,0)
                            ORDER BY id LIMIT 2000) b), '[]'::jsonb));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_reset_backup(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_reset_backup(bigint, bigint) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
