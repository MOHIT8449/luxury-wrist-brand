-- LUXURY WRIST BRAND ERP — BANK STATEMENT IMPORT, AUTO MATCH AND SUSPENSE (Accounts Dashboard)
--
-- Runs by itself when merged to main (after lwb_accounts_dashboard_setup.sql and
-- lwb_party_group_billing_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (2 Nov 2026): Admin uploads the bank statement of any dates (1st to 7th, later 1st to
-- 10th again). Lines already uploaded are skipped by themselves. Lines that match money already in
-- the ERP (UPI / bank / cheque receipts, cash deposits, bank expenses) are matched and bank-checked
-- by themselves. The rest wait in a Suspense list (like Tally suspense) where Admin ticks many lines
-- at once and books them as: party payment (party outstanding drops), cash deposit, cash withdrawn,
-- other income, expense (head), or ignore (own transfer etc.). Every bank has its own file format;
-- the page reads the columns and sends clean rows here.
--
-- Duplicate check: fingerprint = bank + date + debit + credit + narration (letters and digits only) +
-- reference + the n-th time the same line is in the same file. Same file again, or an overlapping
-- date range of the same bank, gives the same fingerprints, so those lines are skipped.
--
-- Booking rules (nothing in the ERP is copied; one statement line is linked to at most one ERP line):
--   MATCH      an existing waiting ERP line is bank-checked (lwb_acc_verify VERIFIED, this bank).
--   PARTY      lwb_party_receive(party, bank date, UPI / BANK line) = party payment, oldest bill first;
--              then bank-checked.
--   DEPOSIT / WITHDRAW / IN / OUT  a new lwb_acc_entries row on the bank date, mode Bank / UPI,
--              bank-checked. On a day already closed it changes only the bank, not the cash in hand
--              (cash in hand starts from the counted cash of the last closed day).
--   IGNORE     kept in the statement, not booked (own transfer, reversal ...).
-- Undo puts the line back in Suspense and cancels what was booked (kept for the record).

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Tables (no grants: only through the functions below)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_bank_stmt_imports (
  id            bigserial PRIMARY KEY,
  bank_id       bigint NOT NULL REFERENCES public.lwb_acc_banks(id),
  file_name     text CHECK (file_name IS NULL OR length(file_name) <= 200),
  from_date     date,
  to_date       date,
  rows_in_file  integer NOT NULL DEFAULT 0,
  rows_new      integer NOT NULL DEFAULT 0,
  rows_skipped  integer NOT NULL DEFAULT 0,
  auto_matched  integer NOT NULL DEFAULT 0,
  created_by    uuid NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.lwb_bank_stmt_lines (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bank_id       bigint NOT NULL REFERENCES public.lwb_acc_banks(id),
  import_id     bigint REFERENCES public.lwb_bank_stmt_imports(id),
  seq           integer NOT NULL DEFAULT 0,
  fp            text NOT NULL,
  txn_date      date NOT NULL,
  narration     text CHECK (narration IS NULL OR length(narration) <= 500),
  ref_no        text CHECK (ref_no IS NULL OR length(ref_no) <= 100),
  debit         numeric(14,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
  credit        numeric(14,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
  balance       numeric(16,2),
  status        text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','MATCHED','ASSIGNED','IGNORED')),
  how           text,
  link_src      text,
  link_id       uuid,
  receipt_id    uuid,
  verified_here boolean NOT NULL DEFAULT false,
  party         text,
  category_id   bigint REFERENCES public.lwb_acc_categories(id),
  note          text CHECK (note IS NULL OR length(note) <= 300),
  no_auto       boolean NOT NULL DEFAULT false,
  done_by       uuid,
  done_at       timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lwb_bank_stmt_one_side CHECK ((debit > 0) <> (credit > 0))
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_bank_stmt_lines_fp_uidx ON public.lwb_bank_stmt_lines(bank_id, fp);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_bank_stmt_lines_link_uidx ON public.lwb_bank_stmt_lines(link_src, link_id)
  WHERE link_src IS NOT NULL AND status IN ('MATCHED','ASSIGNED');
CREATE INDEX IF NOT EXISTS lwb_bank_stmt_lines_open_idx ON public.lwb_bank_stmt_lines(bank_id, status, txn_date);

ALTER TABLE public.lwb_bank_stmt_imports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_bank_stmt_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_bank_stmt_imports, public.lwb_bank_stmt_lines FROM PUBLIC, anon, authenticated;

-- Heads a bank statement usually needs (only added when missing).
INSERT INTO public.lwb_acc_categories (kind, name, sort)
SELECT v.kind, v.name, v.sort FROM (VALUES
  ('OUT','Bank charges',170),('OUT','Loan EMI / Interest',180),('OUT','GST / Tax paid',190),
  ('IN','Bank interest',50),('IN','Loan received',60)
) v(kind, name, sort)
WHERE NOT EXISTS (SELECT 1 FROM public.lwb_acc_categories c WHERE c.kind = v.kind AND lower(btrim(c.name)) = lower(v.name));

-- ---------------------------------------------------------------------------
-- 2. Helpers (internal)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_bank_norm(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT upper(regexp_replace(coalesce(p,''), '[^A-Za-z0-9]', '', 'g')) $fn$;

-- ERP money lines a statement line of this bank can be matched with: waiting for the bank check
-- (or already checked into this bank), or bank expenses / cash withdrawn of this bank; not linked yet.
-- dir C = money into the bank, D = money out.
CREATE OR REPLACE FUNCTION public.lwb_bank_candidates(p_bank bigint, p_since date)
RETURNS TABLE (src text, id uuid, book_date date, amount numeric, mode text, dir text, refn text,
               party text, category text, ref text, kind text, need boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT l.src, l.id, l.book_date, l.amount, l.mode,
         CASE WHEN l.kind IN ('IN','DEPOSIT') THEN 'C' ELSE 'D' END,
         public.lwb_bank_norm(l.ref), l.party, l.category, l.ref, l.kind, l.needs_verify
  FROM public.lwb_acc_lines() l
  LEFT JOIN public.lwb_acc_verify v ON v.src = l.src AND v.src_id = l.id
  WHERE l.book_date >= p_since
    AND ( (l.needs_verify AND coalesce(l.bank_id, p_bank) = p_bank
           AND (v.src_id IS NULL OR (v.status = 'VERIFIED' AND v.bank_id = p_bank)))
       OR (NOT l.needs_verify AND l.bank_id = p_bank AND (l.kind = 'WITHDRAW' OR (l.kind = 'OUT' AND l.mode <> 'CASH'))) )
    AND NOT EXISTS (SELECT 1 FROM public.lwb_bank_stmt_lines x
                    WHERE x.link_src = l.src AND x.link_id = l.id AND x.status IN ('MATCHED','ASSIGNED'));
$fn$;

-- Link one statement line to one ERP line and bank-check it. Internal.
CREATE OR REPLACE FUNCTION public.lwb_bank_link(p_line uuid, p_src text, p_id uuid, p_how text, p_need boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE s public.lwb_bank_stmt_lines%ROWTYPE; v_here boolean := false;
BEGIN
  SELECT * INTO s FROM public.lwb_bank_stmt_lines WHERE id = p_line;
  IF coalesce(p_need,false) AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_verify v WHERE v.src = p_src AND v.src_id = p_id) THEN
    INSERT INTO public.lwb_acc_verify (src, src_id, status, bank_id, note, verified_by, verified_at)
    VALUES (p_src, p_id, 'VERIFIED', s.bank_id, 'Bank statement ' || to_char(s.txn_date,'DD/MM/YYYY'), auth.uid(), now());
    v_here := true;
  END IF;
  UPDATE public.lwb_bank_stmt_lines
     SET status = CASE WHEN p_how IN ('AUTO','MATCH') THEN 'MATCHED' ELSE 'ASSIGNED' END,
         how = p_how, link_src = p_src, link_id = p_id, verified_here = v_here,
         done_by = auth.uid(), done_at = now()
   WHERE id = p_line;
END;
$fn$;

-- Auto match the open lines of one bank. A line is matched when the reference / UTR of an ERP line is
-- in its narration (same amount), or when exactly one ERP line of the same amount and direction is
-- near its date and that ERP line has no other open statement line. Returns how many were matched.
CREATE OR REPLACE FUNCTION public.lwb_bank_automatch(p_bank bigint)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r record; v_n integer := 0; v_used_s uuid[] := '{}'; v_used_c text[] := '{}'; v_since date;
BEGIN
  SELECT min(s.txn_date) - 45 INTO v_since FROM public.lwb_bank_stmt_lines s
  WHERE s.bank_id = p_bank AND s.status = 'OPEN' AND NOT s.no_auto;
  IF v_since IS NULL THEN RETURN 0; END IF;
  FOR r IN
    WITH c AS (SELECT * FROM public.lwb_bank_candidates(p_bank, v_since)),
    s AS (SELECT x.id, x.txn_date, x.debit + x.credit AS amt, CASE WHEN x.credit > 0 THEN 'C' ELSE 'D' END AS dir,
                 public.lwb_bank_norm(x.narration) AS narn, public.lwb_bank_norm(x.ref_no) AS refn
          FROM public.lwb_bank_stmt_lines x WHERE x.bank_id = p_bank AND x.status = 'OPEN' AND NOT x.no_auto),
    p AS (SELECT s.id AS sid, c.src, c.id AS cid, abs(c.book_date - s.txn_date) AS dd,
                 (length(c.refn) >= 6 AND (strpos(s.narn, c.refn) > 0 OR s.refn = c.refn)) AS refhit,
                 c.need, c.book_date BETWEEN s.txn_date - CASE WHEN c.mode = 'CHEQUE' THEN 30 ELSE 5 END AND s.txn_date + 4 AS near
          FROM s JOIN c ON c.amount = s.amt AND c.dir = s.dir AND c.book_date BETWEEN s.txn_date - 45 AND s.txn_date + 10),
    q AS (SELECT p.* FROM p WHERE p.refhit OR p.near)
    SELECT q.*, count(*) OVER (PARTITION BY q.sid) AS nc, count(*) OVER (PARTITION BY q.src, q.cid) AS ns
    FROM q ORDER BY q.refhit DESC, q.dd, q.sid
  LOOP
    CONTINUE WHEN r.sid = ANY(v_used_s) OR (r.src || ':' || r.cid) = ANY(v_used_c);
    CONTINUE WHEN NOT r.refhit AND (r.nc > 1 OR r.ns > 1);
    PERFORM public.lwb_bank_link(r.sid, r.src, r.cid, 'AUTO', r.need);
    v_used_s := v_used_s || r.sid; v_used_c := v_used_c || (r.src || ':' || r.cid);
    v_n := v_n + 1;
  END LOOP;
  IF v_n > 0 THEN PERFORM public.lwb_acc_ping_admins(); END IF;
  RETURN v_n;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_bank_norm(text), public.lwb_bank_candidates(bigint, date),
  public.lwb_bank_link(uuid, text, uuid, text, boolean), public.lwb_bank_automatch(bigint) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Upload: p_rows = [{"date":"2026-11-01","narration":"UPI/...","ref":"123","debit":0,"credit":500,"balance":1500}, ...]
--    in the order of the file. Returns counts.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_bank_stmt_import(p_bank_id bigint, p_file text, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_imp bigint; v_total integer; v_bad integer; v_new integer; v_from date; v_to date; v_auto integer;
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin uploads the bank statement'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_acc_banks b WHERE b.id = p_bank_id AND b.active) THEN
    RAISE EXCEPTION 'Choose an active bank';
  END IF;
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'No lines found in the statement';
  END IF;
  IF jsonb_array_length(p_rows) > 5000 THEN RAISE EXCEPTION 'Upload 5000 lines or less at a time'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_bank_stmt|' || p_bank_id));

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.lwb_bank_stmt_in (
    n integer, d date, narration text, ref text, debit numeric, credit numeric, balance numeric, ok boolean, fp text
  ) ON COMMIT DROP;
  DELETE FROM pg_temp.lwb_bank_stmt_in WHERE true;  -- Supabase blocks DELETE with no WHERE

  INSERT INTO pg_temp.lwb_bank_stmt_in (n, d, narration, ref, debit, credit, balance, ok)
  SELECT t.n,
         CASE WHEN t.r->>'date' ~ '^\d{4}-\d{2}-\d{2}$' THEN (t.r->>'date')::date END,
         left(nullif(btrim(regexp_replace(coalesce(t.r->>'narration',''), '\s+', ' ', 'g')),''), 500),
         left(nullif(btrim(coalesce(t.r->>'ref','')),''), 100),
         CASE WHEN coalesce(t.r->>'debit','') ~ '^-?\d+(\.\d+)?$' THEN round(abs((t.r->>'debit')::numeric),2) ELSE 0 END,
         CASE WHEN coalesce(t.r->>'credit','') ~ '^-?\d+(\.\d+)?$' THEN round(abs((t.r->>'credit')::numeric),2) ELSE 0 END,
         CASE WHEN coalesce(t.r->>'balance','') ~ '^-?\d+(\.\d+)?$' THEN round((t.r->>'balance')::numeric,2) END,
         true
  FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS t(r, n);

  UPDATE pg_temp.lwb_bank_stmt_in SET ok = false
  WHERE d IS NULL OR d > public.lwb_acc_today() + 1 OR d < date '2000-01-01'
     OR ((debit > 0) = (credit > 0)) OR debit > 1000000000 OR credit > 1000000000;

  -- same line twice in one file: 1st, 2nd ... time
  UPDATE pg_temp.lwb_bank_stmt_in i SET fp = x.fp
  FROM (SELECT y.n, md5(concat_ws('|', y.d, y.debit, y.credit, public.lwb_bank_norm(y.narration), public.lwb_bank_norm(y.ref),
               row_number() OVER (PARTITION BY y.d, y.debit, y.credit, public.lwb_bank_norm(y.narration), public.lwb_bank_norm(y.ref)
                                  ORDER BY y.n))) AS fp
        FROM pg_temp.lwb_bank_stmt_in y WHERE y.ok) x
  WHERE x.n = i.n;

  SELECT count(*), count(*) FILTER (WHERE NOT ok), min(d) FILTER (WHERE ok), max(d) FILTER (WHERE ok)
    INTO v_total, v_bad, v_from, v_to FROM pg_temp.lwb_bank_stmt_in;
  IF v_total = v_bad THEN RAISE EXCEPTION 'No line with a date and an amount was found. Check the columns.'; END IF;

  INSERT INTO public.lwb_bank_stmt_imports (bank_id, file_name, from_date, to_date, rows_in_file, created_by)
  VALUES (p_bank_id, left(nullif(btrim(coalesce(p_file,'')),''),200), v_from, v_to, v_total - v_bad, auth.uid())
  RETURNING id INTO v_imp;

  INSERT INTO public.lwb_bank_stmt_lines (bank_id, import_id, seq, fp, txn_date, narration, ref_no, debit, credit, balance)
  SELECT p_bank_id, v_imp, i.n, i.fp, i.d, i.narration, i.ref, i.debit, i.credit, i.balance
  FROM pg_temp.lwb_bank_stmt_in i WHERE i.ok
  ORDER BY i.n
  ON CONFLICT (bank_id, fp) DO NOTHING;
  GET DIAGNOSTICS v_new = ROW_COUNT;

  v_auto := public.lwb_bank_automatch(p_bank_id);
  UPDATE public.lwb_bank_stmt_imports SET rows_new = v_new, rows_skipped = v_total - v_bad - v_new, auto_matched = v_auto
  WHERE id = v_imp;
  RETURN jsonb_build_object('import_id', v_imp, 'lines', v_total - v_bad, 'new', v_new,
                            'skipped', v_total - v_bad - v_new, 'bad', v_bad, 'matched', v_auto,
                            'from', v_from, 'to', v_to);
END;
$fn$;

-- A wrong upload (for example the wrong bank) is taken out when none of its new lines is booked yet.
CREATE OR REPLACE FUNCTION public.lwb_bank_stmt_remove_import(p_import bigint)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_n integer;
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can remove an upload'; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_bank_stmt_lines s WHERE s.import_id = p_import AND s.status IN ('MATCHED','ASSIGNED')) THEN
    RAISE EXCEPTION 'Some lines of this upload are already matched or booked. Undo them first.';
  END IF;
  DELETE FROM public.lwb_bank_stmt_lines WHERE import_id = p_import;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  DELETE FROM public.lwb_bank_stmt_imports WHERE id = p_import;
  IF NOT FOUND THEN RAISE EXCEPTION 'Upload not found'; END IF;
  RETURN v_n;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. Read: one bank's statement lines of the dates + suggestions for the open ones
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_bank_stmt_list(p_bank_id bigint, p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_from date := coalesce(p_from, public.lwb_acc_today() - 30); v_to date := coalesce(p_to, public.lwb_acc_today());
        v_bank bigint := p_bank_id;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts or Admin only'; END IF;
  IF v_bank IS NULL THEN
    SELECT b.id INTO v_bank FROM public.lwb_acc_banks b WHERE b.active ORDER BY b.name LIMIT 1;
  END IF;
  IF v_to < v_from THEN v_to := v_from; END IF;
  IF v_to - v_from > 400 THEN RAISE EXCEPTION 'Choose 400 days or less'; END IF;
  RETURN jsonb_build_object(
    'today', public.lwb_acc_today(), 'is_admin', public.lwb_acc_admin(), 'bank_id', v_bank, 'from', v_from, 'to', v_to,
    'banks', coalesce((SELECT jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'account_no', b.account_no,
               'last_date', (SELECT max(s.txn_date) FROM public.lwb_bank_stmt_lines s WHERE s.bank_id = b.id),
               'open', (SELECT count(*) FROM public.lwb_bank_stmt_lines s WHERE s.bank_id = b.id AND s.status = 'OPEN'))
               ORDER BY b.name) FROM public.lwb_acc_banks b WHERE b.active), '[]'::jsonb),
    'categories', coalesce((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'name', c.name) ORDER BY c.kind, c.sort, c.name)
               FROM public.lwb_acc_categories c WHERE c.active), '[]'::jsonb),
    -- every open line of the bank (any date: suspense is never hidden by the date filter) + the others of the dates
    'lines', coalesce((
      WITH s AS (
        SELECT x.* FROM public.lwb_bank_stmt_lines x
        WHERE x.bank_id = v_bank AND (x.status = 'OPEN' OR x.txn_date BETWEEN v_from AND v_to)),
      c AS (SELECT * FROM public.lwb_bank_candidates(v_bank, (SELECT min(s.txn_date) - 45 FROM s WHERE s.status = 'OPEN'))),
      al AS (SELECT l.src, l.id, l.book_date, l.party, l.category, l.mode, l.ref FROM public.lwb_acc_lines() l
             WHERE EXISTS (SELECT 1 FROM s WHERE s.link_src = l.src AND s.link_id = l.id))
      SELECT jsonb_agg(jsonb_build_object(
        'id', s.id, 'date', s.txn_date, 'narration', s.narration, 'ref', s.ref_no, 'debit', s.debit, 'credit', s.credit,
        'balance', s.balance, 'status', s.status, 'how', s.how, 'party', s.party, 'note', s.note,
        'category', (SELECT k.name FROM public.lwb_acc_categories k WHERE k.id = s.category_id),
        'link_src', s.link_src, 'by', p.full_name, 'at', s.done_at,
        'linked', CASE WHEN s.link_src IS NULL THEN NULL ELSE (
            SELECT jsonb_build_object('date', l.book_date, 'party', l.party, 'category', l.category, 'mode', l.mode, 'ref', l.ref)
            FROM al l WHERE l.src = s.link_src AND l.id = s.link_id LIMIT 1) END,
        'sugg', CASE WHEN s.status <> 'OPEN' THEN NULL ELSE (
            SELECT jsonb_agg(jsonb_build_object('src', c.src, 'id', c.id, 'date', c.book_date, 'party', c.party,
                     'category', c.category, 'mode', c.mode, 'ref', c.ref, 'kind', c.kind) ORDER BY abs(c.book_date - s.txn_date))
            FROM c WHERE c.amount = s.debit + s.credit AND c.dir = CASE WHEN s.credit > 0 THEN 'C' ELSE 'D' END
              AND c.book_date BETWEEN s.txn_date - 45 AND s.txn_date + 10) END)
        ORDER BY s.txn_date DESC, s.seq DESC)
      FROM s LEFT JOIN public.user_profiles p ON p.id = s.done_by), '[]'::jsonb),
    'imports', coalesce((SELECT jsonb_agg(jsonb_build_object('id', i.id, 'file', i.file_name, 'from', i.from_date, 'to', i.to_date,
               'lines', i.rows_in_file, 'new', i.rows_new, 'skipped', i.rows_skipped, 'matched', i.auto_matched,
               'at', i.created_at, 'by', p.full_name,
               'booked', EXISTS (SELECT 1 FROM public.lwb_bank_stmt_lines s WHERE s.import_id = i.id AND s.status IN ('MATCHED','ASSIGNED')))
               ORDER BY i.created_at DESC)
      FROM (SELECT * FROM public.lwb_bank_stmt_imports WHERE bank_id = v_bank ORDER BY created_at DESC LIMIT 30) i
      LEFT JOIN public.user_profiles p ON p.id = i.created_by), '[]'::jsonb)
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. Book many lines at once.
--    p: {"type":"PARTY|DEPOSIT|WITHDRAW|IN|OUT|IGNORE|MATCH", "party":"..", "category_id":3, "note":"..",
--        "src":"PAYMENT", "id":"<erp line>"  (MATCH: one line only)}
--    Each line is booked on its own: one wrong line does not stop the others. Returns {done, errors[]}.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_bank_stmt_assign(p_ids uuid[], p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_type text := upper(btrim(coalesce(p->>'type','')));
  v_party text := nullif(btrim(coalesce(p->>'party','')),'');
  v_cat bigint; v_note text := left(nullif(btrim(coalesce(p->>'note','')),''), 300);
  v_id uuid; s public.lwb_bank_stmt_lines%ROWTYPE; v_amt numeric; v_mode text; v_ref text; v_res jsonb; v_pay uuid;
  v_entry uuid; v_kind text; v_remark text; v_done integer := 0; v_err jsonb := '[]'::jsonb; c record;
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin books bank statement lines'; END IF;
  IF p_ids IS NULL OR cardinality(p_ids) = 0 THEN RAISE EXCEPTION 'Tick the lines first'; END IF;
  IF cardinality(p_ids) > 500 THEN RAISE EXCEPTION 'Tick 500 lines or less at a time'; END IF;
  IF v_type NOT IN ('PARTY','DEPOSIT','WITHDRAW','IN','OUT','IGNORE','MATCH') THEN RAISE EXCEPTION 'Choose what these lines are'; END IF;
  BEGIN v_cat := nullif(p->>'category_id','')::bigint; EXCEPTION WHEN others THEN RAISE EXCEPTION 'Choose the head'; END;
  IF v_type = 'PARTY' AND v_party IS NULL THEN RAISE EXCEPTION 'Choose the party'; END IF;
  IF v_type IN ('IN','OUT') AND (v_cat IS NULL OR NOT EXISTS (SELECT 1 FROM public.lwb_acc_categories k
       WHERE k.id = v_cat AND k.kind = v_type AND k.active)) THEN
    RAISE EXCEPTION 'Choose the % head', CASE v_type WHEN 'IN' THEN 'income' ELSE 'expense' END;
  END IF;
  IF v_type = 'MATCH' AND cardinality(p_ids) <> 1 THEN RAISE EXCEPTION 'Match one line at a time'; END IF;

  FOREACH v_id IN ARRAY p_ids LOOP
    BEGIN
      SELECT * INTO s FROM public.lwb_bank_stmt_lines WHERE id = v_id FOR UPDATE;
      IF s.id IS NULL THEN RAISE EXCEPTION 'Line not found'; END IF;
      IF s.status <> 'OPEN' THEN RAISE EXCEPTION 'Already done'; END IF;
      v_amt := s.debit + s.credit;
      IF v_type IN ('PARTY','DEPOSIT','IN') AND s.credit = 0 THEN RAISE EXCEPTION 'This is money out of the bank'; END IF;
      IF v_type IN ('WITHDRAW','OUT') AND s.debit = 0 THEN RAISE EXCEPTION 'This is money into the bank'; END IF;
      v_mode := CASE WHEN s.narration ~* '(^|[^A-Z])UPI' THEN 'UPI' ELSE 'BANK' END;
      v_ref := CASE WHEN length(public.lwb_bank_norm(s.ref_no)) >= 4 AND public.lwb_bank_norm(s.ref_no) !~ '^0+$' THEN s.ref_no END;
      v_remark := left('Bank statement ' || to_char(s.txn_date,'DD/MM/YYYY') || coalesce(' · ' || s.narration,''), 300);

      IF v_type = 'IGNORE' THEN
        UPDATE public.lwb_bank_stmt_lines SET status = 'IGNORED', how = 'IGNORE', note = v_note, done_by = auth.uid(), done_at = now()
        WHERE id = v_id;

      ELSIF v_type = 'MATCH' THEN
        SELECT * INTO c FROM public.lwb_bank_candidates(s.bank_id, s.txn_date - 45) x
        WHERE x.src = p->>'src' AND x.id::text = p->>'id' LIMIT 1;
        IF c.id IS NULL THEN RAISE EXCEPTION 'That ERP entry is not waiting for this bank (or is already matched)'; END IF;
        IF c.amount <> v_amt OR c.dir <> (CASE WHEN s.credit > 0 THEN 'C' ELSE 'D' END) THEN
          RAISE EXCEPTION 'Amount or direction does not match';
        END IF;
        PERFORM public.lwb_bank_link(v_id, c.src, c.id, 'MATCH', c.need);

      ELSIF v_type = 'PARTY' THEN
        -- the bank line is unique already; a reference used before stays only in the remark
        IF v_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.lwb_tally_payments x WHERE x.mode = v_mode
             AND upper(btrim(x.ref_no)) = upper(btrim(v_ref)) AND x.cancelled_at IS NULL) THEN
          v_ref := NULL;
        END IF;
        v_res := public.lwb_party_receive(v_party, s.txn_date,
                   jsonb_build_array(jsonb_build_object('mode', v_mode, 'amount', v_amt, 'ref', v_ref)), NULL, v_remark);
        SELECT t.id INTO v_pay FROM public.lwb_tally_payments t WHERE t.receipt_id = (v_res->>'receipt_id')::uuid LIMIT 1;
        PERFORM public.lwb_bank_link(v_id, 'PAYMENT', v_pay, 'PARTY', true);
        UPDATE public.lwb_bank_stmt_lines SET receipt_id = (v_res->>'receipt_id')::uuid, party = v_res->>'party', note = v_note
        WHERE id = v_id;

      ELSE
        v_kind := v_type;
        INSERT INTO public.lwb_acc_entries (entry_date, kind, category_id, mode, bank_id, amount, party, ref_no, remark, created_by)
        VALUES (s.txn_date, v_kind, CASE WHEN v_kind IN ('IN','OUT') THEN v_cat END,
                CASE WHEN v_kind IN ('IN','OUT') THEN v_mode ELSE 'CASH' END, s.bank_id, v_amt,
                CASE WHEN v_kind IN ('IN','OUT') THEN left(v_party,120) END, v_ref, v_remark, auth.uid())
        RETURNING id INTO v_entry;
        PERFORM public.lwb_bank_link(v_id, 'ENTRY', v_entry, v_kind, v_kind IN ('IN','DEPOSIT'));
        UPDATE public.lwb_bank_stmt_lines SET category_id = CASE WHEN v_kind IN ('IN','OUT') THEN v_cat END,
               party = CASE WHEN v_kind IN ('IN','OUT') THEN left(v_party,120) END, note = v_note
        WHERE id = v_id;
      END IF;
      v_done := v_done + 1;
    EXCEPTION WHEN others THEN
      v_err := v_err || jsonb_build_object('id', v_id, 'date', s.txn_date, 'amount', s.debit + s.credit, 'error', SQLERRM);
    END;
  END LOOP;
  PERFORM public.lwb_acc_ping_admins();
  RETURN jsonb_build_object('done', v_done, 'errors', v_err);
END;
$fn$;

-- Undo: back to Suspense. What was booked from the line is cancelled (kept for the record);
-- a matched ERP line goes back to waiting for the bank check only if the match checked it.
CREATE OR REPLACE FUNCTION public.lwb_bank_stmt_undo(p_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE s public.lwb_bank_stmt_lines%ROWTYPE;
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can undo'; END IF;
  SELECT * INTO s FROM public.lwb_bank_stmt_lines WHERE id = p_id FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Line not found'; END IF;
  IF s.status = 'OPEN' THEN RETURN 'OPEN'; END IF;
  IF s.status = 'ASSIGNED' AND s.how = 'PARTY' AND s.receipt_id IS NOT NULL THEN
    UPDATE public.lwb_tally_payments SET cancelled_at = now(), cancelled_by = auth.uid()
    WHERE receipt_id = s.receipt_id AND cancelled_at IS NULL;
    UPDATE public.lwb_party_allocs SET cancelled_at = now(), cancelled_by = auth.uid()
    WHERE receipt_id = s.receipt_id AND cancelled_at IS NULL;
  ELSIF s.status = 'ASSIGNED' AND s.link_src = 'ENTRY' THEN
    UPDATE public.lwb_acc_entries SET cancelled_at = now(), cancelled_by = auth.uid(),
           cancel_reason = 'Bank statement line undone'
    WHERE id = s.link_id AND cancelled_at IS NULL;
  END IF;
  IF s.link_src IS NOT NULL AND (s.verified_here OR s.status = 'ASSIGNED') THEN
    DELETE FROM public.lwb_acc_verify WHERE src = s.link_src AND src_id = s.link_id;
  END IF;
  UPDATE public.lwb_bank_stmt_lines
     SET status = 'OPEN', how = NULL, link_src = NULL, link_id = NULL, receipt_id = NULL, verified_here = false,
         party = NULL, category_id = NULL, note = NULL, done_by = NULL, done_at = NULL,
         no_auto = (s.status = 'MATCHED')
   WHERE id = p_id;
  PERFORM public.lwb_acc_ping_admins();
  RETURN 'OPEN';
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_bank_stmt_import(bigint, text, jsonb), public.lwb_bank_stmt_remove_import(bigint),
  public.lwb_bank_stmt_list(bigint, date, date), public.lwb_bank_stmt_assign(uuid[], jsonb), public.lwb_bank_stmt_undo(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_bank_stmt_import(bigint, text, jsonb), public.lwb_bank_stmt_remove_import(bigint),
  public.lwb_bank_stmt_list(bigint, date, date), public.lwb_bank_stmt_assign(uuid[], jsonb), public.lwb_bank_stmt_undo(uuid)
  TO authenticated;

COMMIT;
