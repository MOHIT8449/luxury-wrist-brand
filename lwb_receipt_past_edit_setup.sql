-- LUXURY WRIST BRAND ERP — PAST-DAY / HANDED-OVER CASH PAYMENT EDIT NEEDS ADMIN OK
--
-- Runs by itself when merged to main (after lwb_ledger_admin_edit_setup.sql and
-- lwb_acc_cash_diff_damaged_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit (27 Nov 2026, decision card "Haan: fix + naya process"): NAVDURGA TRADERS (AMROLI) 26/11 cash was entered
-- ₹33,220, really ₹30,220. The 15:50 cash box handover recorded Short ₹3,653 because of it. Next day Accounts
-- edited the payment to ₹30,220, so the ₹3,000 came off twice (payment and Short) and the book went ₹3,000 below
-- the real cash. From now on:
--   * A cash payment is LOCKED when its paid on date is before today, or a cash box handover was given after
--     it was entered. Changing its cash (amount, mode to / from cash, date) or deleting / cancelling it is
--     then Admin only. Accounts send an ask (lwb_receipt_edit_ask) with a reason; Admin approves / rejects.
--   * When Admin changes a locked payment (directly or by approving), the Cash difference of the first
--     handover after the entry is set right by the same amount (Short goes down when the cash was entered too
--     high, Extra goes down when it was too low). Next day's opening stays as counted. Every change is in
--     lwb_receipt_cash_adjust (old / new amount) and lwb_ledger_edit_log as before.
--   * Bells: ask -> every active Admin (RECEIPT_EDIT_ASK). Done / rejected -> who asked, the other Admins,
--     every active Accounts / Cashier login and the people of that handover (RECEIPT_EDIT_DONE / _REJECT).
--   * lwb_receipt_edit_marks(from, to) gives the day book its "✏️ Edited" / "Adjusted" marks.
--
-- lwb_receipt_edit / lwb_receipt_delete keep their names and arguments (the website calls them); the old
-- bodies are kept as lwb_receipt_edit_core / lwb_receipt_delete_core. NOTE: running
-- lwb_ledger_admin_edit_setup.sql again puts back the unguarded functions; run this file again after it.

BEGIN;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_receipt_edit_ask (
  id           bigserial PRIMARY KEY,
  receipt_id   uuid NOT NULL,
  party        text,
  action       text NOT NULL DEFAULT 'EDIT' CHECK (action IN ('EDIT','DELETE')),
  date_old     date,
  date_new     date,
  lines        jsonb,
  remark       text CHECK (remark IS NULL OR length(remark) <= 300),
  reason       text NOT NULL CHECK (length(reason) BETWEEN 3 AND 300),
  total_old    numeric(14,2),
  total_new    numeric(14,2),
  cash_old     numeric(14,2),
  cash_new     numeric(14,2),
  status       text NOT NULL DEFAULT 'WAITING' CHECK (status IN ('WAITING','APPROVED','REJECTED','CANCELLED')),
  asked_by     uuid NOT NULL,
  asked_at     timestamptz NOT NULL DEFAULT now(),
  decided_by   uuid,
  decided_at   timestamptz,
  decide_note  text CHECK (decide_note IS NULL OR length(decide_note) <= 300),
  adjust       jsonb
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_receipt_edit_ask_one ON public.lwb_receipt_edit_ask (receipt_id) WHERE status = 'WAITING';
ALTER TABLE public.lwb_receipt_edit_ask ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_receipt_edit_ask FROM PUBLIC, anon, authenticated;

-- every Cash difference change made because of a payment edit (old -> new)
CREATE TABLE IF NOT EXISTS public.lwb_receipt_cash_adjust (
  id          bigserial PRIMARY KEY,
  receipt_id  uuid,
  ask_id      bigint,
  diff_id     bigint NOT NULL,
  entry_id    uuid,
  kind        text NOT NULL,
  amount_old  numeric(14,2) NOT NULL,
  amount_new  numeric(14,2) NOT NULL,
  note        text,
  created_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_receipt_cash_adjust ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_receipt_cash_adjust FROM PUBLIC, anon, authenticated;

-- keep the old bodies once
DO $$ BEGIN
  IF to_regprocedure('public.lwb_receipt_edit_core(uuid,date,jsonb,text,text)') IS NULL THEN
    ALTER FUNCTION public.lwb_receipt_edit(uuid,date,jsonb,text,text) RENAME TO lwb_receipt_edit_core;
  END IF;
  IF to_regprocedure('public.lwb_receipt_delete_core(uuid,text)') IS NULL THEN
    ALTER FUNCTION public.lwb_receipt_delete(uuid,text) RENAME TO lwb_receipt_delete_core;
  END IF;
END $$;
REVOKE ALL ON FUNCTION public.lwb_receipt_edit_core(uuid,date,jsonb,text,text), public.lwb_receipt_delete_core(uuid,text)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lock check: is the cash of this payment already in a closed / handed over count?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_receipt_lock(p_receipt_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_cash numeric; v_total numeric; v_date date; v_at timestamptz; v_party text;
  h record; d_id bigint; d_kind text; d_amt numeric; d_entry uuid; v_why text;
BEGIN
  SELECT coalesce(sum(p.amount) FILTER (WHERE p.mode = 'CASH'), 0), coalesce(sum(p.amount), 0), min(p.pay_date), min(p.created_at),
         coalesce(min(p.party), min(o.customer_name::text))
    INTO v_cash, v_total, v_date, v_at, v_party
  FROM public.lwb_tally_payments p LEFT JOIN public.orders o ON o.id = p.order_id
  WHERE p.receipt_id = p_receipt_id AND p.cancelled_at IS NULL;
  IF v_at IS NULL THEN RETURN jsonb_build_object('found', false, 'locked', false); END IF;

  SELECT x.batch_id, min(x.given_at) AS at INTO h
  FROM public.lwb_acc_shift_handovers x
  WHERE x.status <> 'CANCELLED' AND x.given_at > v_at
    AND x.batch_id = (SELECT y.batch_id FROM public.lwb_acc_shift_handovers y
                      WHERE y.status <> 'CANCELLED' AND y.given_at > v_at ORDER BY y.given_at, y.id LIMIT 1)
  GROUP BY x.batch_id;
  IF h.at IS NULL THEN
    SELECT NULL::bigint AS batch_id, min(x.given_at) AS at INTO h
    FROM public.lwb_acc_shift_handovers x WHERE x.status <> 'CANCELLED' AND x.given_at > v_at;
  END IF;
  IF h.batch_id IS NOT NULL THEN
    SELECT c.id, c.kind, c.amount, c.entry_id INTO d_id, d_kind, d_amt, d_entry FROM public.lwb_acc_cash_diff c
    WHERE c.batch_id = h.batch_id AND c.kind IN ('SHORT','EXTRA') AND c.cancelled_at IS NULL ORDER BY c.id LIMIT 1;
  END IF;

  v_why := CASE WHEN v_cash <= 0 THEN NULL
                WHEN h.at IS NOT NULL THEN 'Cash box was handed over after this entry (' ||
                     to_char(h.at AT TIME ZONE 'Asia/Kolkata', 'DD/MM HH12:MI am') || ')'
                WHEN v_date < public.lwb_acc_today() THEN 'Paid on an old date (' || to_char(v_date, 'DD/MM') || ')' END;
  RETURN jsonb_build_object('found', true, 'party', v_party, 'pay_date', v_date, 'entered_at', v_at,
    'cash', v_cash, 'total', v_total, 'locked', v_why IS NOT NULL, 'why', v_why,
    'handover_at', h.at, 'batch_id', h.batch_id,
    'diff', CASE WHEN d_id IS NOT NULL THEN jsonb_build_object('id', d_id, 'kind', d_kind, 'amount', d_amt, 'entry_id', d_entry) END);
END;
$fn$;

-- what an edit would do (no change): for the Edit form and the Admin approval
CREATE OR REPLACE FUNCTION public.lwb_receipt_edit_check(p_receipt_id uuid, p_date date, p_lines jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  L jsonb := public.lwb_receipt_lock(p_receipt_id);
  v_new numeric := 0; v_total numeric := 0; v_line jsonb; v_amt numeric; v_delta numeric; v_cash_hit boolean;
  v_adj jsonb; v_left numeric := 0; d jsonb; v_to numeric;
BEGIN
  IF NOT (public.lwb_ledger_admin() OR public.lwb_acc_admin()) THEN RAISE EXCEPTION 'Admin / Accounts only'; END IF;
  IF NOT coalesce((L->>'found')::boolean, false) THEN RAISE EXCEPTION 'Payment not found or cancelled'; END IF;
  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
      BEGIN v_amt := round((v_line->>'amount')::numeric, 2); EXCEPTION WHEN others THEN v_amt := 0; END;
      v_total := v_total + coalesce(v_amt, 0);
      IF upper(btrim(coalesce(v_line->>'mode',''))) = 'CASH' THEN v_new := v_new + coalesce(v_amt, 0); END IF;
    END LOOP;
  END IF;                                           -- p_lines NULL = delete: cash goes to 0
  v_delta := round(v_new - (L->>'cash')::numeric, 2);
  v_cash_hit := v_delta <> 0 OR ((L->>'cash')::numeric > 0 AND p_date IS NOT NULL AND p_date <> (L->>'pay_date')::date);
  d := L->'diff';
  IF (L->>'locked')::boolean AND v_delta <> 0 AND L->>'handover_at' IS NOT NULL THEN
    -- the handover after the entry counted the real cash: its difference took the wrong amount in
    IF d IS NOT NULL AND ((v_delta < 0 AND d->>'kind' = 'SHORT') OR (v_delta > 0 AND d->>'kind' = 'EXTRA')) THEN
      v_to := greatest(round((d->>'amount')::numeric - abs(v_delta), 2), 0);
      v_left := round(abs(v_delta) - ((d->>'amount')::numeric - v_to), 2);
      v_adj := jsonb_build_object('diff_id', (d->>'id')::bigint, 'kind', d->>'kind', 'from', (d->>'amount')::numeric, 'to', v_to);
    ELSE
      v_left := abs(v_delta);
    END IF;
  END IF;
  RETURN L || jsonb_build_object('cash_new', v_new, 'total_new', v_total, 'delta', v_delta,
    'needs_admin', (L->>'locked')::boolean AND v_cash_hit, 'adjust', v_adj, 'left', v_left,
    'warn', CASE WHEN v_left > 0 THEN 'Cash book will move by Rs ' || to_char(v_left, 'FM99999999990') ||
      ' that no handover difference explains; the next handover will show it.' END);
END;
$fn$;

-- set the Cash difference right (internal)
CREATE OR REPLACE FUNCTION public.lwb_receipt_cash_settle(p_receipt_id uuid, p_ask_id bigint, p_adj jsonb, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE c public.lwb_acc_cash_diff%ROWTYPE; v_to numeric;
BEGIN
  IF p_adj IS NULL OR p_adj->>'diff_id' IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO c FROM public.lwb_acc_cash_diff WHERE id = (p_adj->>'diff_id')::bigint AND cancelled_at IS NULL FOR UPDATE;
  IF c.id IS NULL THEN RETURN NULL; END IF;
  v_to := round((p_adj->>'to')::numeric, 2);
  IF v_to <= 0 THEN
    UPDATE public.lwb_acc_cash_diff SET cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = left('Payment edit: ' || coalesce(p_note,''), 300)
    WHERE id = c.id;
    UPDATE public.lwb_acc_entries SET cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = left('Payment edit: ' || coalesce(p_note,''), 300)
    WHERE id = c.entry_id AND cancelled_at IS NULL;
  ELSE
    UPDATE public.lwb_acc_cash_diff SET amount = v_to WHERE id = c.id;
    UPDATE public.lwb_acc_entries SET amount = v_to,
           remark = left(coalesce(remark,'') || ' · was Rs ' || to_char(c.amount, 'FM99999999990') || ' (' || coalesce(p_note,'payment edit') || ')', 300)
    WHERE id = c.entry_id AND cancelled_at IS NULL;
  END IF;
  INSERT INTO public.lwb_receipt_cash_adjust (receipt_id, ask_id, diff_id, entry_id, kind, amount_old, amount_new, note, created_by)
  VALUES (p_receipt_id, p_ask_id, c.id, c.entry_id, c.kind, c.amount, greatest(v_to, 0), p_note, auth.uid());
  RETURN jsonb_build_object('diff_id', c.id, 'kind', c.kind, 'from', c.amount, 'to', greatest(v_to, 0));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_receipt_cash_settle(uuid,bigint,jsonb,text) FROM PUBLIC, anon, authenticated;

-- bells after a locked payment changed (internal)
CREATE OR REPLACE FUNCTION public.lwb_receipt_edit_bell(p_ask_id bigint, p_type text, p_title text, p_msg text, p_batch bigint, p_asker uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $fn$
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
  SELECT DISTINCT u.id, left(p_title, 200), left(p_msg, 900), p_type
  FROM public.user_profiles u
  WHERE u.active = true AND u.id IS DISTINCT FROM auth.uid()
    AND (u.id = p_asker
         OR lower(btrim(u.role)) IN ('admin','accounts','cashier')
         OR u.id IN (SELECT h.given_by FROM public.lwb_acc_shift_handovers h WHERE p_batch IS NOT NULL AND h.batch_id = p_batch
                     UNION SELECT h.given_to FROM public.lwb_acc_shift_handovers h WHERE p_batch IS NOT NULL AND h.batch_id = p_batch));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_receipt_edit_bell(bigint,text,text,text,bigint,uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_receipt_rs(p numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $fn$ SELECT 'Rs ' || to_char(coalesce(p,0), 'FM99,99,99,99,990') $fn$;

-- ---------------------------------------------------------------------------
-- Guarded edit / delete (same names + arguments as before)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_receipt_apply(p_receipt_id uuid, p_date date, p_lines jsonb, p_remark text, p_reason text,
                                                    p_ask_id bigint, p_asker uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE K jsonb; r jsonb; v_set jsonb; v_del boolean := p_lines IS NULL; v_party text; v_note text;
BEGIN
  K := public.lwb_receipt_edit_check(p_receipt_id, p_date, p_lines);
  IF coalesce((K->>'needs_admin')::boolean, false) AND NOT public.lwb_acc_admin() THEN
    RAISE EXCEPTION 'Needs Admin OK: %. Use "Ask Admin" to send this change.', K->>'why';
  END IF;
  IF v_del THEN r := to_jsonb(public.lwb_receipt_delete_core(p_receipt_id, p_reason));
  ELSE r := public.lwb_receipt_edit_core(p_receipt_id, p_date, p_lines, p_remark, p_reason); END IF;
  IF coalesce((K->>'needs_admin')::boolean, false) THEN
    v_party := K->>'party';
    v_note := v_party || ' ' || to_char((K->>'pay_date')::date, 'DD/MM') || ' cash ' || public.lwb_receipt_rs((K->>'cash')::numeric) ||
              ' -> ' || public.lwb_receipt_rs((K->>'cash_new')::numeric);
    v_set := public.lwb_receipt_cash_settle(p_receipt_id, p_ask_id, K->'adjust', v_note);
    PERFORM public.lwb_receipt_edit_bell(p_ask_id, 'RECEIPT_EDIT_DONE',
      'Old cash payment ' || CASE WHEN v_del THEN 'deleted' ELSE 'changed' END || ': ' || v_party,
      v_note || ' by ' || public.lwb_acc_shift_name(auth.uid()) ||
      CASE WHEN v_set IS NOT NULL THEN '. Cash difference ' || initcap(v_set->>'kind') || ' ' || public.lwb_receipt_rs((v_set->>'from')::numeric) ||
           ' -> ' || public.lwb_receipt_rs((v_set->>'to')::numeric) ELSE '' END ||
      CASE WHEN (K->>'left')::numeric > 0 THEN '. Book moves ' || public.lwb_receipt_rs((K->>'left')::numeric) || ', check the next handover' ELSE '' END ||
      coalesce('. Reason: ' || nullif(btrim(coalesce(p_reason,'')),''), ''),
      nullif(K->>'batch_id','')::bigint, p_asker);
  END IF;
  RETURN jsonb_build_object('result', r, 'locked', (K->>'needs_admin')::boolean, 'adjust', v_set, 'left', K->'left');
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_receipt_apply(uuid,date,jsonb,text,text,bigint,uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_receipt_edit(p_receipt_id uuid, p_date date, p_lines jsonb,
                                                   p_remark text DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r jsonb;
BEGIN
  IF NOT public.lwb_ledger_admin() THEN RAISE EXCEPTION 'Only Admin can edit a payment'; END IF;
  IF p_lines IS NULL THEN RAISE EXCEPTION 'Enter at least one amount'; END IF;
  r := public.lwb_receipt_apply(p_receipt_id, p_date, p_lines, p_remark, p_reason, NULL, NULL);
  RETURN (r->'result') || jsonb_build_object('locked', r->'locked', 'adjust', r->'adjust', 'left', r->'left');
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_receipt_delete(p_receipt_id uuid, p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_ledger_admin() THEN RAISE EXCEPTION 'Only Admin can delete a payment'; END IF;
  PERFORM public.lwb_receipt_apply(p_receipt_id, NULL, NULL, NULL, p_reason, NULL, NULL);
  RETURN 'DELETED';
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Ask Admin / decide / list
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_receipt_edit_ask(p_receipt_id uuid, p_date date, p_lines jsonb,
                                                       p_remark text DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE K jsonb; v_reason text := nullif(btrim(coalesce(p_reason,'')),''); v_id bigint; v_del boolean := p_lines IS NULL;
BEGIN
  IF NOT public.lwb_ledger_admin() THEN RAISE EXCEPTION 'Only Admin / Accounts can ask for a payment change'; END IF;
  IF v_reason IS NULL OR length(v_reason) < 3 THEN RAISE EXCEPTION 'Write the reason for the change'; END IF;
  IF length(v_reason) > 300 THEN RAISE EXCEPTION 'Reason is too long'; END IF;
  IF NOT v_del AND (p_date IS NULL OR p_date > public.lwb_acc_today()) THEN RAISE EXCEPTION 'Choose a date, not in the future'; END IF;
  K := public.lwb_receipt_edit_check(p_receipt_id, p_date, p_lines);
  IF NOT v_del AND (K->>'total_new')::numeric <= 0 THEN RAISE EXCEPTION 'Enter at least one amount'; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_receipt_edit_ask a WHERE a.receipt_id = p_receipt_id AND a.status = 'WAITING') THEN
    RAISE EXCEPTION 'A change of this payment is already waiting for Admin';
  END IF;
  INSERT INTO public.lwb_receipt_edit_ask (receipt_id, party, action, date_old, date_new, lines, remark, reason,
         total_old, total_new, cash_old, cash_new, asked_by, adjust)
  VALUES (p_receipt_id, K->>'party', CASE WHEN v_del THEN 'DELETE' ELSE 'EDIT' END, (K->>'pay_date')::date, coalesce(p_date, (K->>'pay_date')::date),
          p_lines, nullif(btrim(coalesce(p_remark,'')),''), v_reason, (K->>'total')::numeric, CASE WHEN v_del THEN 0 ELSE (K->>'total_new')::numeric END,
          (K->>'cash')::numeric, (K->>'cash_new')::numeric, auth.uid(), K->'adjust')
  RETURNING id INTO v_id;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
  SELECT u.id, left('Payment change to approve: ' || coalesce(K->>'party',''), 200),
         left(public.lwb_acc_shift_name(auth.uid()) || ' asks: ' || coalesce(K->>'party','') || ' ' || to_char((K->>'pay_date')::date, 'DD/MM') ||
         ' cash ' || public.lwb_receipt_rs((K->>'cash')::numeric) || ' -> ' || public.lwb_receipt_rs((K->>'cash_new')::numeric) ||
         CASE WHEN K->'adjust' IS NOT NULL AND jsonb_typeof(K->'adjust') = 'object' THEN '. Cash difference ' || initcap(K->'adjust'->>'kind') || ' ' ||
              public.lwb_receipt_rs((K->'adjust'->>'from')::numeric) || ' -> ' || public.lwb_receipt_rs((K->'adjust'->>'to')::numeric) ELSE '' END ||
         '. Reason: ' || v_reason, 900), 'RECEIPT_EDIT_ASK'
  FROM public.user_profiles u WHERE u.active = true AND lower(btrim(u.role)) = 'admin' AND u.id <> auth.uid();
  RETURN jsonb_build_object('id', v_id, 'check', K);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_receipt_edit_decide(p_id bigint, p_ok boolean, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE a public.lwb_receipt_edit_ask%ROWTYPE; r jsonb; v_note text := nullif(btrim(coalesce(p_note,'')),'');
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can approve a payment change'; END IF;
  SELECT * INTO a FROM public.lwb_receipt_edit_ask WHERE id = p_id FOR UPDATE;
  IF a.id IS NULL OR a.status <> 'WAITING' THEN RAISE EXCEPTION 'This ask is not waiting any more'; END IF;
  IF NOT coalesce(p_ok, false) THEN
    IF v_note IS NULL THEN RAISE EXCEPTION 'Write why it is rejected'; END IF;
    UPDATE public.lwb_receipt_edit_ask SET status = 'REJECTED', decided_by = auth.uid(), decided_at = now(), decide_note = left(v_note, 300) WHERE id = a.id;
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
    VALUES (a.asked_by, left('Payment change rejected: ' || coalesce(a.party,''), 200),
            left(public.lwb_acc_shift_name(auth.uid()) || ' rejected ' || coalesce(a.party,'') || ' ' || to_char(a.date_old, 'DD/MM') || '. ' || v_note, 900), 'RECEIPT_EDIT_REJECT');
    RETURN jsonb_build_object('id', a.id, 'status', 'REJECTED');
  END IF;
  r := public.lwb_receipt_apply(a.receipt_id, a.date_new, a.lines, a.remark,
         left(a.reason || ' (asked by ' || public.lwb_acc_shift_name(a.asked_by) || ', OK by ' || public.lwb_acc_shift_name(auth.uid()) || ')', 300),
         a.id, a.asked_by);
  UPDATE public.lwb_receipt_edit_ask SET status = 'APPROVED', decided_by = auth.uid(), decided_at = now(), decide_note = left(v_note, 300),
         adjust = coalesce(r->'adjust', 'null'::jsonb) WHERE id = a.id;
  RETURN jsonb_build_object('id', a.id, 'status', 'APPROVED', 'adjust', r->'adjust', 'left', r->'left');
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_receipt_edit_cancel(p_id bigint)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.lwb_receipt_edit_ask SET status = 'CANCELLED', decided_by = auth.uid(), decided_at = now()
  WHERE id = p_id AND status = 'WAITING' AND (asked_by = auth.uid() OR public.lwb_acc_admin());
  IF NOT FOUND THEN RAISE EXCEPTION 'Only who asked (or Admin) can take back a waiting ask'; END IF;
  RETURN 'CANCELLED';
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_receipt_edit_asks(p_status text DEFAULT 'WAITING', p_days integer DEFAULT 60)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT (public.lwb_ledger_admin() OR public.lwb_acc_admin()) THEN RAISE EXCEPTION 'Admin / Accounts only'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', a.id, 'receipt_id', a.receipt_id, 'party', a.party, 'action', a.action,
      'date_old', a.date_old, 'date_new', a.date_new, 'lines', a.lines, 'remark', a.remark, 'reason', a.reason,
      'total_old', a.total_old, 'total_new', a.total_new, 'cash_old', a.cash_old, 'cash_new', a.cash_new,
      'status', a.status, 'by', public.lwb_acc_shift_name(a.asked_by), 'mine', a.asked_by = auth.uid(), 'at', a.asked_at,
      'decided_by', public.lwb_acc_shift_name(a.decided_by), 'decided_at', a.decided_at, 'decide_note', a.decide_note,
      'adjust', a.adjust, 'can_decide', public.lwb_acc_admin() AND a.status = 'WAITING') ORDER BY a.asked_at DESC)
    FROM public.lwb_receipt_edit_ask a
    WHERE (p_status IS NULL OR a.status = upper(p_status)) AND a.asked_at > now() - make_interval(days => greatest(coalesce(p_days, 60), 1))
      AND (public.lwb_acc_admin() OR a.asked_by = auth.uid() OR a.status = 'WAITING')), '[]'::jsonb);
END;
$fn$;

-- day book marks: payments edited, Cash difference rows changed by an edit
CREATE OR REPLACE FUNCTION public.lwb_receipt_edit_marks(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts only'; END IF;
  RETURN jsonb_build_object(
    'payments', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', p.id, 'receipt_id', p.receipt_id, 'old', e.before->>'total', 'new', e.after->>'total',
             'by', public.lwb_acc_shift_name(e.changed_by), 'at', e.changed_at, 'reason', e.reason))
      FROM public.lwb_tally_payments p
      JOIN LATERAL (SELECT * FROM public.lwb_ledger_edit_log l WHERE l.ref_id = p.receipt_id AND l.kind = 'RECEIPT' AND l.action = 'EDIT'
                    ORDER BY l.changed_at DESC LIMIT 1) e ON true
      WHERE p.cancelled_at IS NULL AND p.pay_date BETWEEN coalesce(p_from, p_to) - 2 AND coalesce(p_to, p_from) + 2), '[]'::jsonb),
    'entries', coalesce((
      SELECT jsonb_agg(jsonb_build_object('entry_id', x.entry_id, 'old', x.amount_old, 'new', x.amount_new, 'note', x.note,
             'by', public.lwb_acc_shift_name(x.created_by), 'at', x.created_at))
      FROM public.lwb_receipt_cash_adjust x JOIN public.lwb_acc_entries e ON e.id = x.entry_id
      WHERE e.entry_date BETWEEN coalesce(p_from, p_to) - 2 AND coalesce(p_to, p_from) + 2), '[]'::jsonb));
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_receipt_lock(uuid), public.lwb_receipt_edit_check(uuid,date,jsonb),
  public.lwb_receipt_edit(uuid,date,jsonb,text,text), public.lwb_receipt_delete(uuid,text),
  public.lwb_receipt_edit_ask(uuid,date,jsonb,text,text), public.lwb_receipt_edit_decide(bigint,boolean,text),
  public.lwb_receipt_edit_cancel(bigint), public.lwb_receipt_edit_asks(text,integer), public.lwb_receipt_edit_marks(date,date),
  public.lwb_receipt_rs(numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_receipt_lock(uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_receipt_edit_check(uuid,date,jsonb),
  public.lwb_receipt_edit(uuid,date,jsonb,text,text), public.lwb_receipt_delete(uuid,text),
  public.lwb_receipt_edit_ask(uuid,date,jsonb,text,text), public.lwb_receipt_edit_decide(bigint,boolean,text),
  public.lwb_receipt_edit_cancel(bigint), public.lwb_receipt_edit_asks(text,integer), public.lwb_receipt_edit_marks(date,date)
  TO authenticated;

COMMIT;
