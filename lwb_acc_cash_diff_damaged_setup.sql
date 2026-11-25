-- LUXURY WRIST BRAND ERP — CASH HANDOVER: OFFICE / OTHER HEADS + CASH DIFFERENCE LEDGER + DAMAGED CASH (Mohit, 25 Nov 2026)
--
-- 1. Hand over the cash box: besides the @tagged people (counted notes), the rest of the book cash can be
--    "Office / Godown pe pada" or "Given to someone else" (name), many lines. These stay in cash in hand
--    (still our money, only kept somewhere else). Whatever is still not explained = Difference:
--    it leaves cash in hand as a Cash Out (head "Cash difference"), or comes in as Cash In when extra,
--    and goes into the Cash Difference ledger. Money found later = "Difference found" (Cash In back).
--    Admin can write a difference off (no cash change, it only closes the ledger balance).
-- 2. Damaged cash: a separate box, NOT in cash in hand.
--      Opening damaged cash   once (Admin can cancel and set again), cash in hand does not change
--      From cash in hand      a damaged note found in the day's cash: Cash Out head "Damaged cash"
--      Bank submit            face value leaves the box; what the bank paid = non-cash Cash In
--                             (head "Damaged cash to bank", waits in Bank check); the rest = Bank short.
--
--   lwb_acc_shift_extra                 Office / Other lines of a handover (batch_id)
--   lwb_acc_cash_diff                   Cash Difference ledger
--   lwb_acc_damaged_cash                Damaged cash box
--   lwb_acc_shift_give3(parts, notes, note, extra)  handover with heads; difference posted
--   lwb_acc_shift_extras(from, to)      the head lines + difference of the handovers (for the page)
--   lwb_acc_shift_cancel(id, note)      also cancels the head lines and the difference entry
--   lwb_acc_cdiff_get() / lwb_acc_cdiff_add(p) / lwb_acc_cdiff_cancel(id, reason)
--   lwb_acc_dmg_get() / lwb_acc_dmg_add(p) / lwb_acc_dmg_bank(p) / lwb_acc_dmg_cancel(id, reason)
-- Builds on lwb_acc_cash_split_handover_setup.sql. Safe to run again.

BEGIN;

-- heads used by these entries (not expenses: admin-business.js / finance.html / reports.html skip them)
INSERT INTO public.lwb_acc_categories (kind, name, sort)
SELECT x.k, x.n, 900 FROM (VALUES ('OUT','Cash difference'), ('IN','Cash difference'), ('OUT','Damaged cash'), ('IN','Damaged cash to bank')) x(k, n)
WHERE NOT EXISTS (SELECT 1 FROM public.lwb_acc_categories c WHERE c.kind = x.k AND lower(btrim(c.name)) = lower(x.n));
UPDATE public.lwb_acc_categories SET active = true
WHERE (kind, lower(btrim(name))) IN (('OUT','cash difference'), ('IN','cash difference'), ('OUT','damaged cash'), ('IN','damaged cash to bank'));

CREATE TABLE IF NOT EXISTS public.lwb_acc_shift_extra (
  id           bigserial PRIMARY KEY,
  batch_id     bigint NOT NULL,
  kind         text NOT NULL CHECK (kind IN ('OFFICE','OTHER')),
  name         text CHECK (name IS NULL OR length(name) <= 80),
  amount       numeric(14,2) NOT NULL CHECK (amount > 0),
  created_by   uuid NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  cancelled_at timestamptz
);
CREATE INDEX IF NOT EXISTS lwb_acc_shift_extra_batch ON public.lwb_acc_shift_extra (batch_id);
ALTER TABLE public.lwb_acc_shift_extra ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_acc_shift_extra FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_acc_cash_diff (
  id            bigserial PRIMARY KEY,
  day           date NOT NULL,
  kind          text NOT NULL CHECK (kind IN ('SHORT','EXTRA','FOUND','WRITE_OFF')),
  amount        numeric(14,2) NOT NULL CHECK (amount > 0),
  batch_id      bigint,
  entry_id      uuid,
  note          text CHECK (note IS NULL OR length(note) <= 300),
  created_by    uuid NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  cancelled_by  uuid,
  cancelled_at  timestamptz,
  cancel_reason text
);
CREATE INDEX IF NOT EXISTS lwb_acc_cash_diff_batch ON public.lwb_acc_cash_diff (batch_id);
ALTER TABLE public.lwb_acc_cash_diff ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_acc_cash_diff FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_acc_damaged_cash (
  id            bigserial PRIMARY KEY,
  day           date NOT NULL,
  kind          text NOT NULL CHECK (kind IN ('OPENING','FROM_CASH','BANK')),
  amount        numeric(14,2) NOT NULL CHECK (amount > 0),          -- face value of the notes
  bank_amount   numeric(14,2) CHECK (bank_amount IS NULL OR bank_amount >= 0),   -- BANK: what the bank paid
  bank_id       bigint REFERENCES public.lwb_acc_banks(id),
  entry_id      uuid,
  notes         jsonb,
  ref_no        text CHECK (ref_no IS NULL OR length(ref_no) <= 100),
  note          text CHECK (note IS NULL OR length(note) <= 300),
  created_by    uuid NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  cancelled_by  uuid,
  cancelled_at  timestamptz,
  cancel_reason text,
  CHECK (kind <> 'BANK' OR (bank_amount IS NOT NULL AND bank_amount <= amount))
);
ALTER TABLE public.lwb_acc_damaged_cash ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_acc_damaged_cash FROM PUBLIC, anon, authenticated;

-- a money entry of today, written by these functions (no 60 day / 2 lakh checks: it is a book move)
CREATE OR REPLACE FUNCTION public.lwb_acc_book_entry(p_kind text, p_head text, p_mode text, p_bank bigint, p_amount numeric,
                                                    p_party text, p_ref text, p_remark text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id uuid; v_cat bigint; v_last date;
BEGIN
  SELECT max(c.close_date) INTO v_last FROM public.lwb_acc_day_close c WHERE c.cancelled_at IS NULL;
  IF v_last IS NOT NULL AND v_last >= public.lwb_acc_today() THEN
    RAISE EXCEPTION 'Today is already closed (Close Day). Admin reopens the day first.'; END IF;
  SELECT c.id INTO v_cat FROM public.lwb_acc_categories c WHERE c.kind = p_kind AND lower(btrim(c.name)) = lower(p_head) ORDER BY c.id LIMIT 1;
  IF v_cat IS NULL THEN RAISE EXCEPTION 'Head % is missing', p_head; END IF;
  INSERT INTO public.lwb_acc_entries (entry_date, kind, category_id, mode, bank_id, amount, party, ref_no, remark, created_by)
  VALUES (public.lwb_acc_today(), p_kind, v_cat, p_mode, p_bank, round(p_amount, 2), p_party, p_ref, left(p_remark, 300), auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_book_entry_cancel(p_id uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE e public.lwb_acc_entries%ROWTYPE; v_last date;
BEGIN
  IF p_id IS NULL THEN RETURN; END IF;
  SELECT * INTO e FROM public.lwb_acc_entries WHERE id = p_id FOR UPDATE;
  IF e.id IS NULL OR e.cancelled_at IS NOT NULL THEN RETURN; END IF;
  SELECT max(c.close_date) INTO v_last FROM public.lwb_acc_day_close c WHERE c.cancelled_at IS NULL;
  IF v_last IS NOT NULL AND e.entry_date <= v_last THEN
    RAISE EXCEPTION 'Day % is closed. Admin must reopen it first.', to_char(e.entry_date,'DD/MM/YYYY'); END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_acc_verify v WHERE v.src = 'ENTRY' AND v.src_id = p_id AND v.status = 'VERIFIED')
     AND NOT public.lwb_acc_admin() THEN
    RAISE EXCEPTION 'Admin has already checked this in the bank. Ask Admin to cancel it.'; END IF;
  UPDATE public.lwb_acc_entries SET cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = left(coalesce(p_reason,'Cancelled'), 300)
  WHERE id = p_id;
END
$fn$;

-- ---------------------------------------------------------------------------
-- 1. Handover with Office / Other heads; the rest = Difference
-- p_extra: [{"kind":"OFFICE","amount":20000}, {"kind":"OTHER","name":"Ramesh","amount":5000}]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_shift_give3(p_parts jsonb, p_notes jsonb, p_note text DEFAULT NULL, p_extra jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_book numeric := 0; v_counted numeric; v_ex numeric := 0; v_diff numeric; r jsonb; v_batch bigint;
  v_note text := nullif(btrim(coalesce(p_note,'')),''); x record; v_n int := 0; v_entry uuid; v_holder text;
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  IF p_extra IS NULL OR jsonb_typeof(p_extra) <> 'array' THEN p_extra := '[]'::jsonb; END IF;
  IF jsonb_array_length(p_extra) > 10 THEN RAISE EXCEPTION 'Keep 10 lines or less'; END IF;
  FOR x IN SELECT upper(btrim(coalesce(e->>'kind',''))) AS k, nullif(btrim(regexp_replace(coalesce(e->>'name',''), '\s+', ' ', 'g')),'') AS nm,
                  round(nullif(e->>'amount','')::numeric, 2) AS amt FROM jsonb_array_elements(p_extra) e LOOP
    IF x.k NOT IN ('OFFICE','OTHER') THEN RAISE EXCEPTION 'Choose Office / Godown or Given to someone'; END IF;
    IF x.k = 'OTHER' AND (x.nm IS NULL OR length(x.nm) < 2) THEN RAISE EXCEPTION 'Write the name of the person who has the cash'; END IF;
    IF length(coalesce(x.nm,'')) > 80 THEN RAISE EXCEPTION 'Name is too long'; END IF;
    IF x.amt IS NULL OR x.amt <= 0 THEN RAISE EXCEPTION 'Write the amount for %', CASE x.k WHEN 'OFFICE' THEN 'Office / Godown' ELSE x.nm END; END IF;
    v_ex := v_ex + x.amt; v_n := v_n + 1;
  END LOOP;
  v_counted := public.lwb_acc_shift_count(p_notes);
  SELECT coalesce(c.amount, 0) INTO v_book FROM public.lwb_acc_cash_at(public.lwb_acc_today() + 1) c;
  v_diff := round(v_book - v_counted - v_ex, 2);
  IF abs(v_diff) >= 1 AND v_note IS NULL THEN
    RAISE EXCEPTION 'Difference: cash is % by Rs %. Write a note why.', CASE WHEN v_diff > 0 THEN 'short' ELSE 'extra' END,
      to_char(abs(v_diff), 'FM99999999990.00'); END IF;
  -- the people part (checks, one waiting handover, bells) as before; the note is required there only
  -- when the counted cash is not the book cash, which our own note above covers
  r := public.lwb_acc_shift_give_split(p_parts, p_notes, coalesce(v_note, CASE WHEN abs(v_book - v_counted) >= 1 THEN 'Rest: Office / Godown / other' END));
  v_batch := (r->>'batch')::bigint;
  INSERT INTO public.lwb_acc_shift_extra (batch_id, kind, name, amount, created_by)
  SELECT v_batch, upper(btrim(e->>'kind')), CASE WHEN upper(btrim(e->>'kind')) = 'OTHER' THEN upper(btrim(regexp_replace(e->>'name', '\s+', ' ', 'g'))) END,
         round((e->>'amount')::numeric, 2), auth.uid()
  FROM jsonb_array_elements(p_extra) e;
  IF abs(v_diff) >= 1 THEN
    SELECT string_agg(public.lwb_acc_shift_name(nullif(e->>'to','')::uuid), ', ') INTO v_holder FROM jsonb_array_elements(p_parts) e;
    v_entry := public.lwb_acc_book_entry(CASE WHEN v_diff > 0 THEN 'OUT' ELSE 'IN' END, 'Cash difference', 'CASH', NULL, abs(v_diff),
      'CASH DIFFERENCE', NULL, 'Cash box handover by ' || public.lwb_acc_shift_name(auth.uid()) || ' to ' || coalesce(v_holder,'') ||
      ' · book Rs ' || to_char(v_book, 'FM99999999990') || ', counted Rs ' || to_char(v_counted, 'FM99999999990') ||
      CASE WHEN v_ex > 0 THEN ', office / other Rs ' || to_char(v_ex, 'FM99999999990') ELSE '' END || coalesce(' · ' || v_note, ''));
    INSERT INTO public.lwb_acc_cash_diff (day, kind, amount, batch_id, entry_id, note, created_by)
    VALUES (public.lwb_acc_today(), CASE WHEN v_diff > 0 THEN 'SHORT' ELSE 'EXTRA' END, abs(v_diff), v_batch, v_entry, v_note, auth.uid());
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
    SELECT p.id, 'Cash difference Rs ' || to_char(abs(v_diff), 'FM99999999990') || CASE WHEN v_diff > 0 THEN ' short' ELSE ' extra' END,
           public.lwb_acc_shift_name(auth.uid()) || ' handed the cash box. Book Rs ' || to_char(v_book, 'FM99999999990') ||
           ', counted Rs ' || to_char(v_counted, 'FM99999999990') || CASE WHEN v_ex > 0 THEN ', office / other Rs ' || to_char(v_ex, 'FM99999999990') ELSE '' END ||
           '. ' || coalesce(v_note, ''), 'ACC_SHIFT_HANDOVER'
    FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'admin' AND p.id <> auth.uid();
  END IF;
  RETURN r || jsonb_build_object('extra', v_ex, 'diff', v_diff, 'diff_entry', v_entry);
END
$fn$;

-- cancel = every part still waiting; the head lines and the difference go with it
CREATE OR REPLACE FUNCTION public.lwb_acc_shift_cancel(p_id bigint, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_acc_shift_handovers%ROWTYPE; d record;
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  SELECT * INTO h FROM public.lwb_acc_shift_handovers WHERE id = p_id FOR UPDATE;
  IF h.id IS NULL OR h.status <> 'PENDING' THEN RAISE EXCEPTION 'This handover is not waiting any more'; END IF;
  IF h.given_by <> auth.uid() AND NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only the person who handed it (or Admin) can cancel'; END IF;
  UPDATE public.erp_notifications n SET is_read = true
  WHERE n.notification_type = 'ACC_SHIFT_HANDOVER' AND n.is_read = false
    AND n.user_id IN (SELECT x.given_to FROM public.lwb_acc_shift_handovers x WHERE x.batch_id = h.batch_id AND x.status = 'PENDING');
  UPDATE public.lwb_acc_shift_handovers SET status = 'CANCELLED', cancelled_by = auth.uid(), cancelled_at = now(),
    receive_note = nullif(btrim(coalesce(p_note,'')),'') WHERE batch_id = h.batch_id AND status = 'PENDING';
  IF NOT EXISTS (SELECT 1 FROM public.lwb_acc_shift_handovers x WHERE x.batch_id = h.batch_id AND x.status <> 'CANCELLED') THEN
    UPDATE public.lwb_acc_shift_extra SET cancelled_at = now() WHERE batch_id = h.batch_id AND cancelled_at IS NULL;
    FOR d IN SELECT * FROM public.lwb_acc_cash_diff c WHERE c.batch_id = h.batch_id AND c.cancelled_at IS NULL LOOP
      PERFORM public.lwb_acc_book_entry_cancel(d.entry_id, 'Cash box handover cancelled');
      UPDATE public.lwb_acc_cash_diff SET cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = 'Handover cancelled' WHERE id = d.id;
    END LOOP;
  END IF;
  RETURN jsonb_build_object('ok', true);
END
$fn$;

-- head lines + difference of the handovers in the dates, and of the last handover (cash box now)
CREATE OR REPLACE FUNCTION public.lwb_acc_shift_extras(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_from date := coalesce(p_from, public.lwb_acc_today()); v_to date := coalesce(p_to, public.lwb_acc_today()); v_last bigint;
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RETURN jsonb_build_object('rows', '[]'::jsonb); END IF;
  SELECT h.batch_id INTO v_last FROM public.lwb_acc_shift_handovers h WHERE h.status <> 'CANCELLED' ORDER BY h.given_at DESC, h.id DESC LIMIT 1;
  RETURN jsonb_build_object('last', v_last, 'rows', coalesce((
    SELECT jsonb_agg(z ORDER BY z->>'batch', z->>'id') FROM (
      SELECT jsonb_build_object('id', 'x' || e.id, 'batch', e.batch_id, 'kind', e.kind, 'name', e.name, 'amount', e.amount) AS z
      FROM public.lwb_acc_shift_extra e
      WHERE e.cancelled_at IS NULL AND (e.batch_id = v_last OR (e.created_at AT TIME ZONE 'Asia/Kolkata')::date BETWEEN v_from AND v_to)
      UNION ALL
      SELECT jsonb_build_object('id', 'd' || c.id, 'batch', c.batch_id, 'kind', 'DIFF', 'name', c.kind, 'amount', c.amount)
      FROM public.lwb_acc_cash_diff c
      WHERE c.cancelled_at IS NULL AND c.batch_id IS NOT NULL AND (c.batch_id = v_last OR c.day BETWEEN v_from AND v_to)) q), '[]'::jsonb));
END
$fn$;

-- ---------------------------------------------------------------------------
-- 2. Cash Difference ledger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_cdiff_get()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only Accounts / Cashier / Admin'; END IF;
  RETURN jsonb_build_object(
    'is_admin', public.lwb_acc_admin(),
    'balance', coalesce((SELECT sum(CASE WHEN c.kind = 'SHORT' THEN c.amount ELSE -c.amount END) FROM public.lwb_acc_cash_diff c WHERE c.cancelled_at IS NULL), 0),
    'short', coalesce((SELECT sum(c.amount) FROM public.lwb_acc_cash_diff c WHERE c.cancelled_at IS NULL AND c.kind = 'SHORT'), 0),
    'extra', coalesce((SELECT sum(c.amount) FROM public.lwb_acc_cash_diff c WHERE c.cancelled_at IS NULL AND c.kind = 'EXTRA'), 0),
    'found', coalesce((SELECT sum(c.amount) FROM public.lwb_acc_cash_diff c WHERE c.cancelled_at IS NULL AND c.kind = 'FOUND'), 0),
    'written_off', coalesce((SELECT sum(c.amount) FROM public.lwb_acc_cash_diff c WHERE c.cancelled_at IS NULL AND c.kind = 'WRITE_OFF'), 0),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'day', c.day, 'at', c.created_at, 'kind', c.kind, 'amount', c.amount,
              'batch', c.batch_id, 'note', c.note, 'by', public.lwb_acc_shift_name(c.created_by),
              'cancelled', c.cancelled_at IS NOT NULL, 'cancel_reason', c.cancel_reason,
              'remark', (SELECT e.remark FROM public.lwb_acc_entries e WHERE e.id = c.entry_id)) ORDER BY c.created_at DESC, c.id DESC)
            FROM (SELECT * FROM public.lwb_acc_cash_diff ORDER BY created_at DESC LIMIT 500) c), '[]'::jsonb));
END
$fn$;

-- p: {"kind":"FOUND"|"WRITE_OFF", "amount":5000, "note":"found in godown drawer"}
CREATE OR REPLACE FUNCTION public.lwb_acc_cdiff_add(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_kind text := upper(btrim(coalesce(p->>'kind',''))); v_amt numeric; v_note text := nullif(btrim(coalesce(p->>'note','')),'');
  v_bal numeric; v_entry uuid; v_id bigint;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only Accounts / Cashier / Admin'; END IF;
  BEGIN v_amt := round(nullif(p->>'amount','')::numeric, 2); EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the amount'; END;
  IF v_kind NOT IN ('FOUND','WRITE_OFF') THEN RAISE EXCEPTION 'Choose Difference found or Write off'; END IF;
  IF v_kind = 'WRITE_OFF' AND NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can write off a difference'; END IF;
  IF v_amt IS NULL OR v_amt <= 0 THEN RAISE EXCEPTION 'Enter the amount'; END IF;
  IF v_note IS NULL THEN RAISE EXCEPTION 'Write a note'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_acc_cash_diff'));
  SELECT coalesce(sum(CASE WHEN c.kind = 'SHORT' THEN c.amount ELSE -c.amount END), 0) INTO v_bal FROM public.lwb_acc_cash_diff c WHERE c.cancelled_at IS NULL;
  IF v_amt > v_bal + 0.001 THEN RAISE EXCEPTION 'Only Rs % is open in the Cash Difference ledger', to_char(greatest(v_bal,0), 'FM99999999990.00'); END IF;
  IF v_kind = 'FOUND' THEN
    v_entry := public.lwb_acc_book_entry('IN', 'Cash difference', 'CASH', NULL, v_amt, 'CASH DIFFERENCE', NULL, 'Difference found · ' || v_note);
  END IF;
  INSERT INTO public.lwb_acc_cash_diff (day, kind, amount, entry_id, note, created_by)
  VALUES (public.lwb_acc_today(), v_kind, v_amt, v_entry, left(v_note, 300), auth.uid()) RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'entry', v_entry);
END
$fn$;

-- cancel a Found / Write off line (handover lines go with the handover)
CREATE OR REPLACE FUNCTION public.lwb_acc_cdiff_cancel(p_id bigint, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE c public.lwb_acc_cash_diff%ROWTYPE; v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only Accounts / Cashier / Admin'; END IF;
  SELECT * INTO c FROM public.lwb_acc_cash_diff WHERE id = p_id FOR UPDATE;
  IF c.id IS NULL OR c.cancelled_at IS NOT NULL THEN RAISE EXCEPTION 'Line not found'; END IF;
  IF c.kind IN ('SHORT','EXTRA') THEN RAISE EXCEPTION 'This came from a cash box handover. Cancel that handover (while it is waiting), or enter Difference found.'; END IF;
  IF c.created_by <> auth.uid() AND NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can cancel another person''s line'; END IF;
  IF c.kind = 'WRITE_OFF' AND NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin'; END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Write why it is cancelled'; END IF;
  PERFORM public.lwb_acc_book_entry_cancel(c.entry_id, v_reason);
  UPDATE public.lwb_acc_cash_diff SET cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = left(v_reason, 300) WHERE id = p_id;
  RETURN jsonb_build_object('ok', true);
END
$fn$;

-- ---------------------------------------------------------------------------
-- 3. Damaged cash box (not in cash in hand)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_dmg_balance()
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(sum(CASE WHEN d.kind = 'BANK' THEN -d.amount ELSE d.amount END), 0)
  FROM public.lwb_acc_damaged_cash d WHERE d.cancelled_at IS NULL;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_dmg_get()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE s numeric := 0;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only Accounts / Cashier / Admin'; END IF;
  RETURN jsonb_build_object(
    'is_admin', public.lwb_acc_admin(),
    'balance', public.lwb_acc_dmg_balance(),
    'opening', coalesce((SELECT sum(d.amount) FROM public.lwb_acc_damaged_cash d WHERE d.cancelled_at IS NULL AND d.kind = 'OPENING'), 0),
    'from_cash', coalesce((SELECT sum(d.amount) FROM public.lwb_acc_damaged_cash d WHERE d.cancelled_at IS NULL AND d.kind = 'FROM_CASH'), 0),
    'to_bank', coalesce((SELECT sum(d.amount) FROM public.lwb_acc_damaged_cash d WHERE d.cancelled_at IS NULL AND d.kind = 'BANK'), 0),
    'bank_paid', coalesce((SELECT sum(d.bank_amount) FROM public.lwb_acc_damaged_cash d WHERE d.cancelled_at IS NULL AND d.kind = 'BANK'), 0),
    'short', coalesce((SELECT sum(d.amount - d.bank_amount) FROM public.lwb_acc_damaged_cash d WHERE d.cancelled_at IS NULL AND d.kind = 'BANK'), 0),
    'has_opening', EXISTS (SELECT 1 FROM public.lwb_acc_damaged_cash d WHERE d.cancelled_at IS NULL AND d.kind = 'OPENING'),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('id', d.id, 'day', d.day, 'at', d.created_at, 'kind', d.kind, 'amount', d.amount,
              'bank_amount', d.bank_amount, 'short', CASE WHEN d.kind = 'BANK' THEN d.amount - d.bank_amount END,
              'bank', (SELECT b.name FROM public.lwb_acc_banks b WHERE b.id = d.bank_id), 'ref', d.ref_no, 'notes', d.notes, 'note', d.note,
              'by', public.lwb_acc_shift_name(d.created_by), 'mine', d.created_by = auth.uid(),
              'status', CASE WHEN d.kind <> 'BANK' OR d.entry_id IS NULL THEN NULL
                             ELSE coalesce((SELECT v.status FROM public.lwb_acc_verify v WHERE v.src = 'ENTRY' AND v.src_id = d.entry_id), 'PENDING') END,
              'cancelled', d.cancelled_at IS NOT NULL, 'cancel_reason', d.cancel_reason) ORDER BY d.created_at DESC, d.id DESC)
            FROM (SELECT * FROM public.lwb_acc_damaged_cash ORDER BY created_at DESC LIMIT 500) d), '[]'::jsonb));
END
$fn$;

-- note count of damaged notes (any of 2000/500/200/100/50/20/10) or a plain amount
CREATE OR REPLACE FUNCTION public.lwb_acc_dmg_count(p_notes jsonb, p_amount numeric)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $fn$
DECLARE t numeric := 0; k text; v numeric;
BEGIN
  IF p_notes IS NULL OR jsonb_typeof(p_notes) <> 'object' OR p_notes = '{}'::jsonb THEN RETURN round(coalesce(p_amount, 0), 2); END IF;
  FOR k, v IN SELECT e.key, nullif(e.value::text,'null')::numeric FROM jsonb_each(p_notes) e LOOP
    IF k NOT IN ('2000','500','200','100','50','20','10') OR v IS NULL OR v < 0 THEN RAISE EXCEPTION 'Check the note count'; END IF;
    t := t + k::numeric * floor(v);
  END LOOP;
  RETURN round(t, 2);
END
$fn$;

-- p: {"kind":"OPENING"|"FROM_CASH", "amount":1500, "notes":{"500":3}, "note":"..."}
CREATE OR REPLACE FUNCTION public.lwb_acc_dmg_add(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_kind text := upper(btrim(coalesce(p->>'kind',''))); v_amt numeric; v_notes jsonb; v_note text := nullif(btrim(coalesce(p->>'note','')),'');
  v_entry uuid; v_id bigint;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only Accounts / Cashier / Admin'; END IF;
  IF v_kind NOT IN ('OPENING','FROM_CASH') THEN RAISE EXCEPTION 'Choose Opening damaged cash or From cash in hand'; END IF;
  v_notes := CASE WHEN jsonb_typeof(p->'notes') = 'object' AND p->'notes' <> '{}'::jsonb THEN p->'notes' END;
  BEGIN v_amt := public.lwb_acc_dmg_count(v_notes, nullif(p->>'amount','')::numeric);
  EXCEPTION WHEN raise_exception THEN RAISE; WHEN others THEN RAISE EXCEPTION 'Check the amount'; END;
  IF v_amt IS NULL OR v_amt <= 0 OR v_amt > 10000000 THEN RAISE EXCEPTION 'Enter the damaged cash amount'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_acc_damaged_cash'));
  IF v_kind = 'OPENING' AND EXISTS (SELECT 1 FROM public.lwb_acc_damaged_cash d WHERE d.cancelled_at IS NULL AND d.kind = 'OPENING') THEN
    RAISE EXCEPTION 'Opening damaged cash is already set. Admin cancels it to set it again.'; END IF;
  IF v_kind = 'FROM_CASH' THEN
    v_entry := public.lwb_acc_book_entry('OUT', 'Damaged cash', 'CASH', NULL, v_amt, 'DAMAGED CASH', NULL,
      'Damaged notes moved out of cash in hand' || coalesce(' · ' || v_note, ''));
  END IF;
  INSERT INTO public.lwb_acc_damaged_cash (day, kind, amount, notes, note, entry_id, created_by)
  VALUES (public.lwb_acc_today(), v_kind, v_amt, v_notes, left(v_note, 300), v_entry, auth.uid()) RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'amount', v_amt, 'balance', public.lwb_acc_dmg_balance());
END
$fn$;

-- p: {"amount":500 (face value given), "bank_amount":250 (bank paid), "bank_id":1, "ref":"", "note":""}
CREATE OR REPLACE FUNCTION public.lwb_acc_dmg_bank(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_amt numeric; v_paid numeric; v_bank bigint; v_ref text := nullif(btrim(coalesce(p->>'ref','')),'');
  v_note text := nullif(btrim(coalesce(p->>'note','')),''); v_entry uuid; v_id bigint; v_bal numeric;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only Accounts / Cashier / Admin'; END IF;
  BEGIN
    v_amt := round(nullif(p->>'amount','')::numeric, 2); v_paid := round(coalesce(nullif(p->>'bank_amount','')::numeric, 0), 2);
    v_bank := nullif(p->>'bank_id','')::bigint;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the amounts'; END;
  IF v_amt IS NULL OR v_amt <= 0 THEN RAISE EXCEPTION 'Enter the damaged notes given to the bank'; END IF;
  IF v_paid < 0 OR v_paid > v_amt THEN RAISE EXCEPTION 'Bank paid cannot be more than the notes given'; END IF;
  IF v_paid > 0 AND (v_bank IS NULL OR NOT EXISTS (SELECT 1 FROM public.lwb_acc_banks b WHERE b.id = v_bank AND b.active)) THEN
    RAISE EXCEPTION 'Choose the bank'; END IF;
  IF length(coalesce(v_ref,'')) > 100 THEN RAISE EXCEPTION 'Reference is too long'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_acc_damaged_cash'));
  v_bal := public.lwb_acc_dmg_balance();
  IF v_amt > v_bal + 0.001 THEN RAISE EXCEPTION 'Only Rs % damaged cash is in the box', to_char(v_bal, 'FM99999999990.00'); END IF;
  IF v_paid > 0 THEN
    v_entry := public.lwb_acc_book_entry('IN', 'Damaged cash to bank', 'BANK', v_bank, v_paid, 'DAMAGED CASH', v_ref,
      'Damaged notes Rs ' || to_char(v_amt, 'FM99999999990') || ' given to bank, bank paid Rs ' || to_char(v_paid, 'FM99999999990') ||
      CASE WHEN v_amt > v_paid THEN ', short Rs ' || to_char(v_amt - v_paid, 'FM99999999990') ELSE '' END || coalesce(' · ' || v_note, ''));
    PERFORM public.lwb_acc_ping_admins();
  END IF;
  INSERT INTO public.lwb_acc_damaged_cash (day, kind, amount, bank_amount, bank_id, ref_no, note, entry_id, created_by)
  VALUES (public.lwb_acc_today(), 'BANK', v_amt, v_paid, CASE WHEN v_paid > 0 THEN v_bank END, v_ref, left(v_note, 300), v_entry, auth.uid())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'short', v_amt - v_paid, 'balance', public.lwb_acc_dmg_balance());
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_dmg_cancel(p_id bigint, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE d public.lwb_acc_damaged_cash%ROWTYPE; v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only Accounts / Cashier / Admin'; END IF;
  SELECT * INTO d FROM public.lwb_acc_damaged_cash WHERE id = p_id FOR UPDATE;
  IF d.id IS NULL OR d.cancelled_at IS NOT NULL THEN RAISE EXCEPTION 'Line not found'; END IF;
  IF (d.created_by <> auth.uid() OR d.kind = 'OPENING') AND NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can cancel this line'; END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Write why it is cancelled'; END IF;
  IF d.kind <> 'BANK' AND public.lwb_acc_dmg_balance() - d.amount < -0.001 THEN
    RAISE EXCEPTION 'These notes are already given to the bank. Cancel the bank line first.'; END IF;
  PERFORM public.lwb_acc_book_entry_cancel(d.entry_id, v_reason);
  UPDATE public.lwb_acc_damaged_cash SET cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = left(v_reason, 300) WHERE id = p_id;
  RETURN jsonb_build_object('ok', true, 'balance', public.lwb_acc_dmg_balance());
END
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_book_entry(text,text,text,bigint,numeric,text,text,text), public.lwb_acc_book_entry_cancel(uuid,text),
  public.lwb_acc_dmg_balance(), public.lwb_acc_dmg_count(jsonb,numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_acc_shift_give3(jsonb,jsonb,text,jsonb), public.lwb_acc_shift_cancel(bigint,text), public.lwb_acc_shift_extras(date,date),
  public.lwb_acc_cdiff_get(), public.lwb_acc_cdiff_add(jsonb), public.lwb_acc_cdiff_cancel(bigint,text),
  public.lwb_acc_dmg_get(), public.lwb_acc_dmg_add(jsonb), public.lwb_acc_dmg_bank(jsonb), public.lwb_acc_dmg_cancel(bigint,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_shift_give3(jsonb,jsonb,text,jsonb), public.lwb_acc_shift_cancel(bigint,text), public.lwb_acc_shift_extras(date,date),
  public.lwb_acc_cdiff_get(), public.lwb_acc_cdiff_add(jsonb), public.lwb_acc_cdiff_cancel(bigint,text),
  public.lwb_acc_dmg_get(), public.lwb_acc_dmg_add(jsonb), public.lwb_acc_dmg_bank(jsonb), public.lwb_acc_dmg_cancel(bigint,text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'handover heads table' AS item, (to_regclass('public.lwb_acc_shift_extra') IS NOT NULL)::text AS ok
UNION ALL SELECT 'cash difference ledger', (to_regclass('public.lwb_acc_cash_diff') IS NOT NULL)::text
UNION ALL SELECT 'damaged cash box', (to_regclass('public.lwb_acc_damaged_cash') IS NOT NULL)::text
UNION ALL SELECT 'give3', (to_regprocedure('public.lwb_acc_shift_give3(jsonb,jsonb,text,jsonb)') IS NOT NULL)::text
UNION ALL SELECT 'heads', ((SELECT count(*) FROM public.lwb_acc_categories c WHERE lower(c.name) IN ('cash difference','damaged cash','damaged cash to bank')) >= 4)::text;
