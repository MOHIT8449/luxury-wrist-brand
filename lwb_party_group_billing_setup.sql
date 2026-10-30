-- LUXURY WRIST BRAND ERP — GROUP PARTY (ONE LEDGER FOR MANY BILL NAMES), PARTY PAYMENT WITH ADVANCE,
-- PAYMENT SPLIT OVER BILLS, ONE BILLING SCREEN AFTER LOADING
--
-- Runs by itself when merged to main (after lwb_party_payment_collection_setup.sql,
-- lwb_accounts_dashboard_setup.sql and lwb_tally_subfirm_bills_setup.sql). Safe to run again.
-- Nothing is dropped or deleted (only lwb_tally_payments.order_id may now be empty for a party payment).
--
-- Mohit asked (30 Oct 2026):
--  1. One clear flow: once the vehicle is loaded (loading sign-off), Accounts enters the Tally invoice no.
--     of that PO, and the bill shows by itself as money to collect (Cash In of the Accounts Dashboard).
--  2. Group party: SHREE JAGDISH TRADERS is the main (parent) party; its bills are made in other names
--     (Priya Traders, Rohit Traders, Aarti Traders, Agarwal Traders ...). Ledger and outstanding stay on the
--     main party; every bill shows the name it was made in and its amount.
--     The group links are the same links Tally Bill Check / sub-firm bills already use (lwb_tally_party_map:
--     name -> main party). An ERP party can be put under a main party too; its POs then count there.
--  3. A party payment is entered once on the main party (e.g. Rs 10 lakh) and split over its bills,
--     oldest first or by hand (2 lakh Priya, 2 lakh Rohit ...). What is not split stays as ADVANCE and
--     can be adjusted against later bills. A wrong split can be undone (money goes back to advance).
--
-- Tables:   lwb_tally_payments  (+ party; order_id empty = party payment, one row per mode as before)
--           lwb_party_allocs    (party payment -> bill (order) amounts)
-- Bill due  = Tally bill − credit notes + debit notes − driver money − Payment Collection − split amounts.
-- Party Ledger and party-wise outstanding are shown on the main party.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Main party of a name (follows the group links, at most 3 steps)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_key(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT btrim(regexp_replace(upper(coalesce(p,'')), '[^A-Z0-9]+', ' ', 'g')) $fn$;

CREATE OR REPLACE FUNCTION public.lwb_party_parent(p_name text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v text := btrim(coalesce(p_name,''));
  p text;
  i int := 0;
BEGIN
  LOOP
    p := NULL;
    SELECT btrim(m.customer_name) INTO p FROM public.lwb_tally_party_map m
    WHERE m.tally_key = public.lwb_party_key(v) AND nullif(btrim(m.customer_name),'') IS NOT NULL;
    EXIT WHEN p IS NULL OR public.lwb_party_key(p) = public.lwb_party_key(v) OR i >= 3;
    v := p; i := i + 1;
  END LOOP;
  RETURN v;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_parent(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_parent(text), public.lwb_party_key(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Party payment rows (no PO) and their split over bills
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_tally_payments ALTER COLUMN order_id DROP NOT NULL;
ALTER TABLE public.lwb_tally_payments ADD COLUMN IF NOT EXISTS party text;
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_tally_payments_order_or_party') THEN
    ALTER TABLE public.lwb_tally_payments ADD CONSTRAINT lwb_tally_payments_order_or_party
      CHECK (order_id IS NOT NULL OR nullif(btrim(party),'') IS NOT NULL);
  END IF;
END
$do$;
CREATE INDEX IF NOT EXISTS lwb_tally_payments_party_idx ON public.lwb_tally_payments(party) WHERE order_id IS NULL;

CREATE TABLE IF NOT EXISTS public.lwb_party_allocs (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id   uuid NOT NULL,
  order_id     uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  amount       numeric(14,2) NOT NULL CHECK (amount > 0),
  created_by   uuid NOT NULL REFERENCES auth.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  cancelled_by uuid REFERENCES auth.users(id),
  cancelled_at timestamptz
);
CREATE INDEX IF NOT EXISTS lwb_party_allocs_order_idx ON public.lwb_party_allocs(order_id) WHERE cancelled_at IS NULL;
CREATE INDEX IF NOT EXISTS lwb_party_allocs_receipt_idx ON public.lwb_party_allocs(receipt_id);
ALTER TABLE public.lwb_party_allocs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_party_allocs FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_party_allocs TO authenticated;
DROP POLICY IF EXISTS lwb_party_allocs_read ON public.lwb_party_allocs;
CREATE POLICY lwb_party_allocs_read ON public.lwb_party_allocs FOR SELECT TO authenticated
  USING (public.lwb_tally_staff());

-- Office money on one PO: Payment Collection on the PO + party payment split to it. Internal use only.
-- (lwb_tally_bill_rows, lwb_party_bills and lwb_save_tally_payment read this, so the split lowers the due.)
CREATE OR REPLACE FUNCTION public.lwb_order_office_paid(p_order_id uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT round(COALESCE((SELECT sum(p.amount) FROM public.lwb_tally_payments p
                         WHERE p.order_id = p_order_id AND p.cancelled_at IS NULL),0)
             + COALESCE((SELECT sum(a.amount) FROM public.lwb_party_allocs a
                         WHERE a.order_id = p_order_id AND a.cancelled_at IS NULL),0), 2);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_office_paid(uuid) FROM PUBLIC, anon, authenticated;

-- Money still due on one Tally bill (NULL = no Tally bill amount yet). Internal use only.
CREATE OR REPLACE FUNCTION public.lwb_order_tally_due(p_order_id uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT round(t.amount
    - COALESCE((SELECT sum(n.amount) FROM public.lwb_tally_notes n WHERE n.order_id = t.order_id AND n.kind = 'CREDIT' AND n.cancelled_at IS NULL),0)
    + COALESCE((SELECT sum(n.amount) FROM public.lwb_tally_notes n WHERE n.order_id = t.order_id AND n.kind = 'DEBIT' AND n.cancelled_at IS NULL),0)
    - COALESCE((SELECT sum(d.cash_reported) FROM public.lwb_delivery_reports d
                WHERE d.order_id = t.order_id AND coalesce(d.payment_status,'') <> 'REJECTED'),0)
    - public.lwb_order_office_paid(t.order_id), 2)
  FROM public.lwb_tally_invoices t WHERE t.order_id = p_order_id AND t.amount IS NOT NULL;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_tally_due(uuid) FROM PUBLIC, anon, authenticated;

-- Money of party payments not split to any bill yet (advance), per receipt. Internal use only.
CREATE OR REPLACE FUNCTION public.lwb_party_receipt_free(p_parent text)
RETURNS TABLE (receipt_id uuid, pay_date date, created_at timestamptz, total numeric, free numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT r.receipt_id, r.pay_date, r.created_at, r.total,
         round(r.total - COALESCE((SELECT sum(a.amount) FROM public.lwb_party_allocs a
                                   WHERE a.receipt_id = r.receipt_id AND a.cancelled_at IS NULL),0), 2)
  FROM (SELECT p.receipt_id, min(p.pay_date) AS pay_date, min(p.created_at) AS created_at, sum(p.amount) AS total
        FROM public.lwb_tally_payments p
        WHERE p.order_id IS NULL AND p.cancelled_at IS NULL
          AND public.lwb_party_key(public.lwb_party_parent(p.party)) = public.lwb_party_key(p_parent)
        GROUP BY p.receipt_id) r
  ORDER BY r.pay_date, r.created_at;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_receipt_free(text) FROM PUBLIC, anon, authenticated;

-- Split the advance of a main party over its bills. Internal: callers check the role and lock the party.
-- p_allocs: [{"order_id": "...", "amount": 200000}, ...]; NULL = oldest bill first, up to the advance.
CREATE OR REPLACE FUNCTION public.lwb_party_apply(p_parent text, p_allocs jsonb)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_free numeric;
  v_left numeric;
  v_want jsonb := '[]'::jsonb;
  v_line jsonb;
  v_order uuid;
  v_amt numeric;
  v_due numeric;
  v_party text;
  v_no text;
  v_seen uuid[] := '{}';
  v_total numeric := 0;
  v_take numeric;
  r record;
BEGIN
  SELECT COALESCE(sum(f.free),0) INTO v_free FROM public.lwb_party_receipt_free(p_parent) f;

  IF p_allocs IS NULL THEN
    -- oldest bill first
    v_left := v_free;
    FOR r IN
      SELECT t.order_id, public.lwb_order_tally_due(t.order_id) AS due
      FROM public.lwb_tally_invoices t JOIN public.orders o ON o.id = t.order_id
      WHERE t.amount IS NOT NULL
        AND public.lwb_party_key(public.lwb_party_parent(o.customer_name)) = public.lwb_party_key(p_parent)
      ORDER BY t.invoice_date, t.entered_at, o.order_no
    LOOP
      EXIT WHEN v_left < 0.01;
      CONTINUE WHEN r.due IS NULL OR r.due < 0.01;
      v_take := least(r.due, v_left);
      v_want := v_want || jsonb_build_object('order_id', r.order_id, 'amount', v_take);
      v_left := v_left - v_take;
    END LOOP;
  ELSE
    IF jsonb_typeof(p_allocs) <> 'array' THEN RAISE EXCEPTION 'Bad split list'; END IF;
    IF jsonb_array_length(p_allocs) > 200 THEN RAISE EXCEPTION 'Too many bills in one split'; END IF;
    v_want := p_allocs;
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(v_want) LOOP
    BEGIN
      v_order := (v_line->>'order_id')::uuid;
      v_amt := round(coalesce(nullif(v_line->>'amount',''),'0')::numeric, 2);
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'Bad bill or amount in the split';
    END;
    CONTINUE WHEN v_amt = 0;
    IF v_amt < 0 THEN RAISE EXCEPTION 'Split amount can not be less than zero'; END IF;
    IF v_order = ANY (v_seen) THEN RAISE EXCEPTION 'A bill is in the split twice'; END IF;
    v_seen := v_seen || v_order;
    SELECT o.customer_name, o.order_no::text INTO v_party, v_no FROM public.orders o WHERE o.id = v_order;
    IF NOT FOUND THEN RAISE EXCEPTION 'Bill not found'; END IF;
    IF public.lwb_party_key(public.lwb_party_parent(v_party)) <> public.lwb_party_key(p_parent) THEN
      RAISE EXCEPTION 'PO % (%) is not under %', v_no, v_party, p_parent;
    END IF;
    PERFORM 1 FROM public.lwb_tally_invoices t WHERE t.order_id = v_order FOR UPDATE;
    v_due := public.lwb_order_tally_due(v_order);
    IF v_due IS NULL THEN RAISE EXCEPTION 'PO % has no Tally bill amount yet', v_no; END IF;
    IF v_amt > v_due + 1 THEN
      RAISE EXCEPTION 'Rs % on PO % is more than its due Rs %', v_amt, v_no, greatest(v_due,0);
    END IF;
    v_total := v_total + v_amt;
    IF v_total > v_free + 0.5 THEN
      RAISE EXCEPTION 'Split Rs % is more than the money of % not split yet (Rs %)', v_total, p_parent, v_free;
    END IF;
    -- take the money from the oldest party payments first
    v_left := v_amt;
    FOR r IN SELECT f.receipt_id, f.free FROM public.lwb_party_receipt_free(p_parent) f WHERE f.free > 0.004 LOOP
      EXIT WHEN v_left < 0.005;
      v_take := least(r.free, v_left);
      INSERT INTO public.lwb_party_allocs (receipt_id, order_id, amount, created_by)
      VALUES (r.receipt_id, v_order, round(v_take,2), auth.uid());
      v_left := v_left - v_take;
    END LOOP;
    IF v_left > 0.5 THEN RAISE EXCEPTION 'Not enough advance for PO %', v_no; END IF;
  END LOOP;
  RETURN round(v_total, 2);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_apply(text, jsonb) FROM PUBLIC, anon, authenticated;

-- An ERP party name (Party Master or a PO party). Internal use only.
CREATE OR REPLACE FUNCTION public.lwb_party_known(p_name text)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v boolean := false;
BEGIN
  IF EXISTS (SELECT 1 FROM public.orders o WHERE public.lwb_party_key(o.customer_name) = public.lwb_party_key(p_name)) THEN
    RETURN true;
  END IF;
  IF to_regclass('public.lwb_customer_master') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.lwb_customer_master m WHERE public.lwb_party_key(m.customer_name::text) = public.lwb_party_key($1))'
      INTO v USING p_name;
  END IF;
  RETURN v;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_known(text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Party payment: money received from a main party (or any of its bill names), split over its
--    bills now (p_allocs list, or NULL = oldest bill first, or '[]' = keep all as advance).
--    p_lines as in Payment Collection: [{"mode":"CASH","notes":{"500":10}} or {"mode":"CASH","amount":5000},
--    {"mode":"UPI","amount":5000,"ref":"UTR1"}, {"mode":"BANK",...}, {"mode":"CHEQUE","amount":..,"ref":"0012"}]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_receive(p_party text, p_pay_date date, p_lines jsonb,
                                                   p_allocs jsonb DEFAULT NULL, p_remark text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_parent text := public.lwb_party_parent(p_party);
  v_receipt uuid := gen_random_uuid();
  v_remark text := nullif(btrim(coalesce(p_remark,'')),'');
  v_line jsonb; v_mode text; v_amt numeric; v_ref text; v_notes jsonb; v_clean jsonb;
  v_key text; v_cnt numeric; v_total numeric := 0; v_cash numeric := 0;
  v_rows jsonb := '[]'::jsonb;
  v_modes text[] := '{}';
  v_split numeric;
  v_adv numeric;
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can enter a party payment';
  END IF;
  IF v_parent = '' THEN RAISE EXCEPTION 'Choose the party'; END IF;
  IF length(v_parent) > 200 THEN RAISE EXCEPTION 'Party name is too long'; END IF;
  IF NOT public.lwb_party_known(v_parent) THEN
    RAISE EXCEPTION 'Party % is not in the Party Master', v_parent;
  END IF;
  IF p_pay_date IS NULL OR p_pay_date > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1 THEN
    RAISE EXCEPTION 'Enter a valid payment date';
  END IF;
  IF length(coalesce(v_remark,'')) > 300 THEN RAISE EXCEPTION 'Remark is too long'; END IF;
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Enter at least one payment mode';
  END IF;
  IF jsonb_array_length(p_lines) > 8 THEN RAISE EXCEPTION 'Too many payment lines'; END IF;

  -- one party payment of a group at a time
  PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(v_parent)));

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_mode := upper(btrim(coalesce(v_line->>'mode','')));
    v_ref := nullif(btrim(coalesce(v_line->>'ref','')),'');
    v_clean := NULL;
    IF v_mode NOT IN ('CASH','UPI','BANK','CHEQUE') THEN RAISE EXCEPTION 'Select Cash, UPI, Bank or Cheque'; END IF;
    IF v_mode = ANY(v_modes) THEN RAISE EXCEPTION '% is entered twice. Put it in one line.', initcap(v_mode); END IF;
    v_modes := v_modes || v_mode;
    IF length(coalesce(v_ref,'')) > 100 THEN RAISE EXCEPTION 'Reference is too long'; END IF;
    IF v_mode = 'CASH' AND jsonb_typeof(v_line->'notes') = 'object' AND v_line->'notes' <> '{}'::jsonb THEN
      v_notes := v_line->'notes';
      v_clean := '{}'::jsonb; v_amt := 0;
      FOR v_key IN SELECT jsonb_object_keys(v_notes) LOOP
        IF v_key NOT IN ('500','200','100','50','20','10','coins') THEN RAISE EXCEPTION 'Unknown note %', v_key; END IF;
        BEGIN
          v_cnt := coalesce(nullif(v_notes->>v_key,''),'0')::numeric;
        EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter a number for %', v_key;
        END;
        IF v_cnt < 0 OR v_cnt > 100000 OR (v_key <> 'coins' AND v_cnt <> trunc(v_cnt)) THEN
          RAISE EXCEPTION 'Check the count of %', v_key;
        END IF;
        IF v_cnt > 0 THEN
          v_clean := v_clean || jsonb_build_object(v_key, v_cnt);
          v_amt := v_amt + CASE WHEN v_key = 'coins' THEN round(v_cnt,2) ELSE v_key::numeric * v_cnt END;
        END IF;
      END LOOP;
      IF v_clean = '{}'::jsonb THEN v_clean := NULL; END IF;
    ELSE
      BEGIN
        v_amt := round(coalesce(nullif(v_line->>'amount',''),'0')::numeric, 2);
      EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter the % amount', initcap(v_mode);
      END;
      IF v_mode = 'CHEQUE' AND v_ref IS NULL THEN RAISE EXCEPTION 'Enter the cheque number'; END IF;
      IF v_mode <> 'CASH' AND v_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.lwb_tally_payments x WHERE x.mode = v_mode
            AND upper(btrim(x.ref_no)) = upper(v_ref) AND x.cancelled_at IS NULL) THEN
        RAISE EXCEPTION '% reference % is already entered', initcap(v_mode), v_ref;
      END IF;
    END IF;
    IF v_amt <= 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'Enter the % amount', initcap(v_mode); END IF;
    IF v_mode = 'CASH' THEN v_cash := v_cash + v_amt; END IF;
    v_total := v_total + v_amt;
    v_rows := v_rows || jsonb_build_object('mode', v_mode, 'amount', v_amt, 'ref', v_ref, 'notes', v_clean);
  END LOOP;

  IF v_cash >= 200000 THEN
    RAISE EXCEPTION 'Cash of Rs 2 lakh or more in one receipt is not allowed (Income Tax 269ST).';
  END IF;

  INSERT INTO public.lwb_tally_payments (receipt_id, order_id, party, pay_date, mode, amount, ref_no, cash_notes, remark, created_by)
  SELECT v_receipt, NULL, v_parent, p_pay_date, r->>'mode', (r->>'amount')::numeric, r->>'ref',
         CASE WHEN jsonb_typeof(r->'notes') = 'object' THEN r->'notes' END, v_remark, auth.uid()
  FROM jsonb_array_elements(v_rows) r;

  v_split := public.lwb_party_apply(v_parent, p_allocs);
  SELECT COALESCE(sum(f.free),0) INTO v_adv FROM public.lwb_party_receipt_free(v_parent) f;
  RETURN jsonb_build_object('receipt_id', v_receipt, 'party', v_parent, 'amount', round(v_total,2),
                            'split', v_split, 'advance', round(v_adv,2));
END;
$fn$;

-- Split the advance of a party over its bills (p_allocs NULL = oldest bill first).
CREATE OR REPLACE FUNCTION public.lwb_party_adjust(p_party text, p_allocs jsonb DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_parent text := public.lwb_party_parent(p_party);
  v_split numeric;
  v_adv numeric;
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can adjust a payment';
  END IF;
  IF v_parent = '' THEN RAISE EXCEPTION 'Choose the party'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(v_parent)));
  v_split := public.lwb_party_apply(v_parent, p_allocs);
  IF v_split = 0 THEN RAISE EXCEPTION 'Nothing to adjust: no advance or no bill due for %', v_parent; END IF;
  SELECT COALESCE(sum(f.free),0) INTO v_adv FROM public.lwb_party_receipt_free(v_parent) f;
  RETURN jsonb_build_object('party', v_parent, 'split', v_split, 'advance', round(v_adv,2));
END;
$fn$;

-- Undo one split line (the money goes back to the party's advance; the bill is due again).
CREATE OR REPLACE FUNCTION public.lwb_party_unadjust(p_alloc_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can undo a split';
  END IF;
  UPDATE public.lwb_party_allocs SET cancelled_at = now(), cancelled_by = auth.uid()
  WHERE id = p_alloc_id AND cancelled_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Split not found'; END IF;
  RETURN 'UNDONE';
END;
$fn$;

-- A wrong receipt is cancelled (all its modes and its split), kept for the record.
CREATE OR REPLACE FUNCTION public.lwb_cancel_tally_payment(p_receipt_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can cancel a payment';
  END IF;
  UPDATE public.lwb_tally_payments SET cancelled_at = now(), cancelled_by = auth.uid()
  WHERE receipt_id = p_receipt_id AND cancelled_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  UPDATE public.lwb_party_allocs SET cancelled_at = now(), cancelled_by = auth.uid()
  WHERE receipt_id = p_receipt_id AND cancelled_at IS NULL;
  RETURN 'CANCELLED';
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. Group links: put a bill name / ERP party under a main party, or take it out (p_parent NULL)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_group_set(p_member text, p_parent text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_member text := btrim(coalesce(p_member,''));
  v_parent text := nullif(btrim(coalesce(p_parent,'')),'');
  v_top text;
BEGIN
  IF NOT public.lwb_tally_check_user() THEN
    RAISE EXCEPTION 'Active Admin / Accounts role required.';
  END IF;
  IF public.lwb_party_key(v_member) = '' THEN RAISE EXCEPTION 'Enter the bill name'; END IF;
  IF length(v_member) > 200 OR length(coalesce(v_parent,'')) > 200 THEN RAISE EXCEPTION 'Name is too long'; END IF;
  IF v_parent IS NULL THEN
    PERFORM public.lwb_tally_set_party_map(v_member, NULL);
    RETURN 'REMOVED';
  END IF;
  IF public.lwb_party_key(v_member) = public.lwb_party_key(v_parent) THEN
    RAISE EXCEPTION 'A party can not be under itself';
  END IF;
  IF NOT public.lwb_party_known(v_parent) THEN
    RAISE EXCEPTION 'Main party % is not in the Party Master', v_parent;
  END IF;
  v_top := public.lwb_party_parent(v_parent);
  IF public.lwb_party_key(v_top) <> public.lwb_party_key(v_parent) THEN
    RAISE EXCEPTION '% is already under %. Choose % as the main party.', v_parent, v_top, v_top;
  END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_tally_party_map m WHERE nullif(btrim(m.customer_name),'') IS NOT NULL
             AND public.lwb_party_key(m.customer_name) = public.lwb_party_key(v_member)
             AND m.tally_key <> public.lwb_party_key(v_member)) THEN
    RAISE EXCEPTION '% is itself a main party with names under it. Move those names first.', v_member;
  END IF;
  PERFORM public.lwb_tally_set_party_map(v_member, v_parent);
  RETURN 'SAVED';
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. Everything the Billing & Outstanding screen needs, in one call (Accounts / Admin)
--    pending : loaded POs with no Tally bill yet (loading signed), with the names its bill can be made in
--    bills   : POs with a Tally bill: main party, bill names + amounts, due
--    receipts: party payments of the last p_days days with their split
--    advance : money of each main party not split yet
--    groups  : bill name -> main party links;  openings: opening balance per main party
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_billing(p_days integer DEFAULT 400)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_days int := least(greatest(coalesce(p_days,400),30),400);
  v_rows jsonb;
  v_parties jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Active Admin / Accounts role required.';
  END IF;
  IF to_regclass('public.lwb_customer_master') IS NOT NULL THEN
    EXECUTE 'SELECT coalesce(jsonb_agg(DISTINCT btrim(m.customer_name::text)), ''[]''::jsonb)
             FROM public.lwb_customer_master m WHERE nullif(btrim(m.customer_name::text),'''') IS NOT NULL'
      INTO v_parties;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'order_id', r.order_id, 'order_no', r.order_no, 'party', r.party,
           'parent', public.lwb_party_parent(r.party), 'status', r.status,
           'order_date', r.order_date, 'dispatch_date', r.dispatch_date,
           'invoice_no', r.invoice_no, 'invoice_date', r.invoice_date,
           'bill_amount', r.bill_amount, 'erp_amount', r.erp_amount,
           'approved_return', r.approved_return, 'pending_return', r.pending_return,
           'credit_notes', r.credit_notes, 'debit_notes', r.debit_notes,
           'driver', r.collected - public.lwb_order_office_paid(r.order_id),
           'office', public.lwb_order_office_paid(r.order_id),
           'due', r.due, 'credit_pending', r.credit_pending, 'delivery', r.delivery,
           'bills', coalesce(t.bills, '[]'::jsonb), 'entered_at', t.entered_at)
         ORDER BY r.dispatch_date, r.order_no), '[]'::jsonb)
    INTO v_rows
  FROM public.lwb_tally_bill_rows(v_days) r
  LEFT JOIN public.lwb_tally_invoices t ON t.order_id = r.order_id;

  RETURN jsonb_build_object(
    'today', (now() AT TIME ZONE 'Asia/Kolkata')::date,
    'orders', v_rows,
    'receipts', (
      SELECT coalesce(jsonb_agg(x ORDER BY x->>'pay_date' DESC, x->>'at' DESC), '[]'::jsonb) FROM (
        SELECT jsonb_build_object(
          'receipt_id', p.receipt_id, 'party', public.lwb_party_parent(min(p.party)), 'pay_date', min(p.pay_date), 'at', min(p.created_at),
          'remark', min(p.remark), 'cancelled', bool_or(p.cancelled_at IS NOT NULL),
          'total', sum(p.amount),
          'modes', jsonb_agg(jsonb_build_object('mode', p.mode, 'amount', p.amount, 'ref', p.ref_no, 'notes', p.cash_notes) ORDER BY p.mode),
          'by', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = min(p.created_by::text)::uuid),
          'allocs', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'order_id', a.order_id, 'order_no', o.order_no,
                       'invoice_no', ti.invoice_no, 'amount', a.amount, 'at', a.created_at) ORDER BY a.created_at), '[]'::jsonb)
                     FROM public.lwb_party_allocs a JOIN public.orders o ON o.id = a.order_id
                     LEFT JOIN public.lwb_tally_invoices ti ON ti.order_id = a.order_id
                     WHERE a.receipt_id = p.receipt_id AND a.cancelled_at IS NULL)) AS x
        FROM public.lwb_tally_payments p
        WHERE p.order_id IS NULL
          AND (p.cancelled_at IS NULL OR p.pay_date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - 30)
        GROUP BY p.receipt_id) q),
    'advance', (
      SELECT coalesce(jsonb_object_agg(z.parent, z.free), '{}'::jsonb) FROM (
        SELECT r.parent, round(sum(r.free),2) AS free FROM (
          SELECT public.lwb_party_parent(min(p.party)) AS parent,
                 sum(p.amount) - coalesce((SELECT sum(a.amount) FROM public.lwb_party_allocs a
                                           WHERE a.receipt_id = p.receipt_id AND a.cancelled_at IS NULL),0) AS free
          FROM public.lwb_tally_payments p
          WHERE p.order_id IS NULL AND p.cancelled_at IS NULL
          GROUP BY p.receipt_id) r
        GROUP BY r.parent) z
      WHERE abs(z.free) >= 0.01),
    'groups', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('member', m.tally_name, 'parent', btrim(m.customer_name)) ORDER BY m.customer_name, m.tally_name), '[]'::jsonb)
      FROM public.lwb_tally_party_map m
      WHERE nullif(btrim(m.customer_name),'') IS NOT NULL AND public.lwb_party_key(m.customer_name) <> m.tally_key),
    'openings', (
      SELECT coalesce(jsonb_object_agg(z.parent, z.amt), '{}'::jsonb) FROM (
        SELECT public.lwb_party_parent(b.customer_name) AS parent, sum(b.amount) AS amt
        FROM public.lwb_party_opening_balances b GROUP BY 1) z),
    'parties', v_parties
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_party_receive(text,date,jsonb,jsonb,text), public.lwb_party_adjust(text,jsonb),
  public.lwb_party_unadjust(uuid), public.lwb_cancel_tally_payment(uuid), public.lwb_party_group_set(text,text),
  public.lwb_party_billing(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_receive(text,date,jsonb,jsonb,text), public.lwb_party_adjust(text,jsonb),
  public.lwb_party_unadjust(uuid), public.lwb_cancel_tally_payment(uuid), public.lwb_party_group_set(text,text),
  public.lwb_party_billing(integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Bill-wise outstanding on the main party (same columns as before)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_bills()
RETURNS TABLE(
  bill_kind text,
  bill_id uuid,
  bill_no text,
  bill_date date,
  order_id uuid,
  order_no text,
  customer_name text,
  bill_amount numeric,
  return_credit numeric,
  paid_amount numeric,
  pending_amount numeric,
  outstanding_amount numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  WITH tb AS (
    SELECT t.order_id, t.invoice_no, t.invoice_date, t.amount
    FROM public.lwb_tally_invoices t WHERE t.amount IS NOT NULL
  ),
  bills AS (
    SELECT 'ERP_BILL'::text AS kind, b.id, b.internal_bill_no AS no,
           b.bill_date AS dt, b.order_id, b.order_no, b.customer_name,
           b.goods_amount::numeric AS amt
    FROM public.lwb_internal_bills b
    WHERE NOT EXISTS (SELECT 1 FROM tb WHERE tb.order_id = b.order_id)
    UNION ALL
    SELECT 'OLD_INVOICE', i.id, i.invoice_no, i.invoice_date::date,
           i.order_id, o.order_no, o.customer_name,
           COALESCE(i.grand_total,0)::numeric
    FROM public.tax_invoices i
    JOIN public.orders o ON o.id = i.order_id
    WHERE NOT EXISTS (SELECT 1 FROM tb WHERE tb.order_id = i.order_id)
  ),
  pay AS (
    SELECT CASE WHEN c.internal_bill_id IS NOT NULL
                THEN 'ERP_BILL' ELSE 'OLD_INVOICE' END AS kind,
           COALESCE(c.internal_bill_id, c.invoice_id) AS id,
           COALESCE(sum(c.amount) FILTER (WHERE c.status='POSTED'),0) AS posted,
           COALESCE(sum(c.amount) FILTER (WHERE c.status='PENDING'),0) AS pending
    FROM public.lwb_payment_collections c
    GROUP BY 1,2
  ),
  -- the one bill of each order that carries the driver money
  main AS (
    SELECT DISTINCT ON (x.order_id) x.kind, x.id, x.order_id
    FROM bills x WHERE x.order_id IS NOT NULL
    ORDER BY x.order_id, (x.kind = 'ERP_BILL') DESC, x.dt, x.id
  ),
  drv AS (
    SELECT m.kind, m.id, public.lwb_order_driver_received(m.order_id) AS amt
    FROM main m
  ),
  -- Payment Collection money still PENDING on the old bills of a Tally-billed order
  tpend AS (
    SELECT COALESCE(b.order_id, i.order_id) AS order_id, sum(c.amount) AS amt
    FROM public.lwb_payment_collections c
    LEFT JOIN public.lwb_internal_bills b ON b.id = c.internal_bill_id
    LEFT JOIN public.tax_invoices i ON i.id = c.invoice_id
    WHERE c.status = 'PENDING'
    GROUP BY 1
  ),
  tnotes AS (
    SELECT n.order_id,
           COALESCE(sum(n.amount) FILTER (WHERE n.kind = 'CREDIT'),0) AS cr,
           COALESCE(sum(n.amount) FILTER (WHERE n.kind = 'DEBIT'),0) AS dr
    FROM public.lwb_tally_notes n WHERE n.cancelled_at IS NULL
    GROUP BY 1
  ),
  tally AS (
    SELECT tb.order_id, tb.invoice_no, tb.invoice_date, o.order_no::text AS order_no, o.customer_name,
           round(tb.amount + COALESCE(tn.dr,0),2) AS amt,
           round(COALESCE(tn.cr,0),2) AS cr,
           round(public.lwb_order_posted_collections(tb.order_id) + public.lwb_order_driver_received(tb.order_id)
                 + public.lwb_order_office_paid(tb.order_id),2) AS paid,
           round(COALESCE(tp.amt,0),2) AS pending
    FROM tb
    JOIN public.orders o ON o.id = tb.order_id
    LEFT JOIN tnotes tn ON tn.order_id = tb.order_id
    LEFT JOIN tpend tp ON tp.order_id = tb.order_id
  )
  SELECT * FROM (
    SELECT b.kind, b.id, b.no, b.dt, b.order_id, b.order_no,
           public.lwb_party_parent(b.customer_name),
           round(b.amt,2),
           public.lwb_order_return_credit(b.order_id),
           round(COALESCE(p.posted,0) + COALESCE(dv.amt,0),2),
           round(COALESCE(p.pending,0),2),
           GREATEST(0, round(
             b.amt - public.lwb_order_return_credit(b.order_id)
                   - COALESCE(p.posted,0) - COALESCE(dv.amt,0)
           ,2))
    FROM bills b
    LEFT JOIN pay p ON p.kind = b.kind AND p.id = b.id
    LEFT JOIN drv dv ON dv.kind = b.kind AND dv.id = b.id
    UNION ALL
    SELECT 'TALLY_BILL', t.order_id, t.invoice_no, t.invoice_date, t.order_id, t.order_no,
           public.lwb_party_parent(t.customer_name), t.amt, t.cr, t.paid, t.pending,
           GREATEST(0, round(t.amt - t.cr - t.paid, 2))
    FROM tally t
  ) x
  WHERE public.lwb_ledger_viewer()
  ORDER BY 4 DESC, 3 DESC;
$function$;

REVOKE ALL ON FUNCTION public.lwb_party_bills() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_bills() TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. Party ledger on the main party: Tally bill per bill name, party payments (same columns as before)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_ledger()
RETURNS TABLE(
  entry_date date,
  entry_kind text,
  customer_name text,
  ref_no text,
  order_no text,
  debit numeric,
  credit numeric,
  note text,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  WITH tb AS (
    SELECT t.order_id, t.invoice_no, t.invoice_date, t.amount, t.entered_at, t.bills
    FROM public.lwb_tally_invoices t WHERE t.amount IS NOT NULL
  )
  -- every row on the main party (group); a row of a name under it says that name
  SELECT e.entry_date, e.entry_kind, public.lwb_party_parent(e.customer_name), e.ref_no, e.order_no,
         e.debit, e.credit,
         CASE WHEN public.lwb_party_key(public.lwb_party_parent(e.customer_name)) <> public.lwb_party_key(e.customer_name)
              THEN concat_ws(' · ', e.note, 'PO party ' || e.customer_name) ELSE e.note END,
         e.created_at
  FROM (
    SELECT ob.as_of_date, 'OPENING'::text, btrim(ob.customer_name),
           'Opening Balance'::text, NULL::text,
           GREATEST(ob.amount,0)::numeric, GREATEST(-ob.amount,0)::numeric,
           ob.remarks, ob.updated_at
    FROM public.lwb_party_opening_balances ob

    UNION ALL
    SELECT b.bill_date, 'ERP_BILL', btrim(b.customer_name),
           b.internal_bill_no, b.order_no,
           b.goods_amount::numeric, 0::numeric,
           'ERP Internal Bill', b.created_at
    FROM public.lwb_internal_bills b
    WHERE NOT EXISTS (SELECT 1 FROM tb WHERE tb.order_id = b.order_id)

    UNION ALL
    SELECT i.invoice_date::date, 'OLD_INVOICE', btrim(o.customer_name),
           i.invoice_no, o.order_no,
           COALESCE(i.grand_total,0)::numeric, 0::numeric,
           'Old ERP invoice record', NULL::timestamptz
    FROM public.tax_invoices i
    JOIN public.orders o ON o.id = i.order_id
    WHERE NOT EXISTS (SELECT 1 FROM tb WHERE tb.order_id = i.order_id)

    UNION ALL
    -- one row per Tally bill line, with the name the bill was made in
    SELECT tb.invoice_date, 'TALLY_BILL', btrim(o.customer_name),
           coalesce(nullif(btrim(f.b->>'no'),''), tb.invoice_no), o.order_no,
           CASE WHEN f.b IS NULL OR jsonb_typeof(f.b) <> 'object' THEN tb.amount ELSE (f.b->>'amount')::numeric END,
           0::numeric,
           'Tally bill' || coalesce(' · bill in ' || nullif(btrim(f.b->>'firm'),''), ''), tb.entered_at
    FROM tb
    JOIN public.orders o ON o.id = tb.order_id
    CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(tb.bills) = 'array' AND jsonb_array_length(tb.bills) > 0
                                                 THEN tb.bills ELSE '[null]'::jsonb END) f(b)

    UNION ALL
    -- party payment on the main party (split over its bills, rest advance)
    SELECT p.pay_date, 'PARTY_PAYMENT', btrim(p.party),
           p.mode || COALESCE(' ' || NULLIF(btrim(p.ref_no),''),''), NULL::text,
           0::numeric, p.amount::numeric,
           'Party payment' || COALESCE(' · ' || p.remark,''), p.created_at
    FROM public.lwb_tally_payments p
    WHERE p.order_id IS NULL AND p.cancelled_at IS NULL

    UNION ALL
    SELECT n.note_date, CASE WHEN n.kind = 'CREDIT' THEN 'CREDIT_NOTE' ELSE 'DEBIT_NOTE' END,
           btrim(o.customer_name), n.note_no, o.order_no,
           CASE WHEN n.kind = 'DEBIT' THEN n.amount ELSE 0 END::numeric,
           CASE WHEN n.kind = 'CREDIT' THEN n.amount ELSE 0 END::numeric,
           COALESCE(n.reason, CASE WHEN n.kind = 'CREDIT' THEN 'Credit note' ELSE 'Debit note' END)
             || ' · Tally bill ' || tb.invoice_no,
           n.created_at
    FROM public.lwb_tally_notes n
    JOIN tb ON tb.order_id = n.order_id
    JOIN public.orders o ON o.id = n.order_id
    WHERE n.cancelled_at IS NULL

    UNION ALL
    SELECT c.collection_date, 'PAYMENT',
           btrim(COALESCE(b.customer_name, o.customer_name)),
           c.payment_mode || COALESCE(' ' || NULLIF(btrim(c.reference_no),''),''),
           COALESCE(b.order_no, o.order_no),
           0::numeric, c.amount::numeric,
           'Against ' || COALESCE(b.internal_bill_no, i.invoice_no),
           c.reviewed_at
    FROM public.lwb_payment_collections c
    LEFT JOIN public.lwb_internal_bills b ON b.id = c.internal_bill_id
    LEFT JOIN public.tax_invoices i ON i.id = c.invoice_id
    LEFT JOIN public.orders o ON o.id = i.order_id
    WHERE c.status = 'POSTED'

    UNION ALL
    SELECT p.pay_date, 'OFFICE_PAYMENT', btrim(o.customer_name),
           p.mode || COALESCE(' ' || NULLIF(btrim(p.ref_no),''),''), o.order_no,
           0::numeric, p.amount::numeric,
           'Payment Collection · Tally bill ' || COALESCE(t.invoice_no,'') || COALESCE(' · ' || p.remark,''),
           p.created_at
    FROM public.lwb_tally_payments p
    JOIN public.orders o ON o.id = p.order_id
    LEFT JOIN public.lwb_tally_invoices t ON t.order_id = p.order_id
    WHERE p.cancelled_at IS NULL

    UNION ALL
    SELECT timezone('Asia/Kolkata', COALESCE(d.payment_reviewed_at, d.reported_at))::date, 'DRIVER_PAYMENT',
           btrim(COALESCE(b.customer_name, o.customer_name)),
           COALESCE(NULLIF(d.payment_mode,''), 'CASH')
             || COALESCE(' ' || NULLIF(btrim(COALESCE(d.bank_ref, d.online_reference, d.payment_reference)),''),''),
           o.order_no,
           0::numeric, d.cash_reported::numeric,
           'Driver ' || COALESCE(NULLIF(btrim(dp.full_name),''), 'payment')
             || ', received by ' || COALESCE(NULLIF(btrim(rp.full_name),''), 'office'),
           d.payment_reviewed_at
    FROM public.lwb_delivery_reports d
    JOIN public.orders o ON o.id = d.order_id
    LEFT JOIN public.lwb_internal_bills b ON b.order_id = d.order_id
    LEFT JOIN public.user_profiles dp ON dp.id = d.driver_user_id
    LEFT JOIN public.user_profiles rp ON rp.id = d.payment_reviewed_by
    WHERE d.payment_status = 'VERIFIED' AND d.cash_reported > 0
      AND (b.id IS NOT NULL OR EXISTS (SELECT 1 FROM public.tax_invoices t WHERE t.order_id = d.order_id)
           OR EXISTS (SELECT 1 FROM tb WHERE tb.order_id = d.order_id))

    UNION ALL
    SELECT COALESCE(r.reviewed_at, r.created_at)::date, 'DRIVER_RETURN',
           btrim(o.customer_name), 'Driver return', o.order_no,
           0::numeric, r.total_return_amount::numeric,
           'Office approved driver return', r.reviewed_at
    FROM public.lwb_driver_delivery_returns r
    JOIN public.orders o ON o.id = r.order_id
    WHERE r.status = 'APPROVED' AND r.total_return_amount > 0
      AND NOT EXISTS (SELECT 1 FROM tb WHERE tb.order_id = r.order_id)

    UNION ALL
    SELECT s.return_date::date, 'SALES_RETURN', btrim(o.customer_name),
           s.return_no, o.order_no,
           0::numeric, COALESCE(s.total_amount,0)::numeric,
           'Admin approved sales return', NULL::timestamptz
    FROM public.sales_returns s
    JOIN public.orders o ON o.id = s.order_id
    WHERE lower(btrim(COALESCE(s.approval_status,''))) = 'approved'
      AND COALESCE(s.total_amount,0) > 0
      AND NOT EXISTS (SELECT 1 FROM tb WHERE tb.order_id = s.order_id)
  ) e(entry_date, entry_kind, customer_name, ref_no, order_no, debit, credit, note, created_at)
  WHERE public.lwb_ledger_viewer();
$function$;

REVOKE ALL ON FUNCTION public.lwb_party_ledger() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_ledger() TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Accounts Dashboard money lines: a party payment (no PO) is Cash In of the main party
--    (same as lwb_accounts_dashboard_setup.sql, PAYMENT part only changed)
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 9. Tally bill lines: a bill name of the same group is fine for any PO of that group; a new bill name
--    is put under the PO's main party (same as lwb_tally_subfirm_bills_setup.sql otherwise)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_save_tally_bills(p_order_id uuid, p_invoice_date date, p_bills jsonb, p_note text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_party text;
  v_lines jsonb := '[]'::jsonb;
  v_nos text[] := '{}';
  v_seen text[] := '{}';
  v_total numeric := 0;
  v_line jsonb;
  v_firm text;
  v_no text;
  v_amt numeric;
  v_key text;
  v_linked text;
  v_other text;
  v_res text;
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can enter the Tally bill';
  END IF;
  IF p_bills IS NULL OR jsonb_typeof(p_bills) <> 'array' OR jsonb_array_length(p_bills) = 0 THEN
    RAISE EXCEPTION 'Enter at least one Tally bill';
  END IF;
  IF jsonb_array_length(p_bills) > 20 THEN RAISE EXCEPTION 'At most 20 Tally bills for one PO'; END IF;
  SELECT btrim(o.customer_name::text) INTO v_party FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_bills) LOOP
    v_firm := coalesce(nullif(btrim(coalesce(v_line->>'firm','')), ''), v_party);
    v_no := btrim(coalesce(v_line->>'no',''));
    BEGIN
      v_amt := round((v_line->>'amount')::numeric, 2);
    EXCEPTION WHEN others THEN v_amt := NULL;
    END;
    IF v_no = '' THEN RAISE EXCEPTION 'Enter the invoice no. for %', v_firm; END IF;
    IF length(v_no) > 100 OR length(v_firm) > 200 THEN RAISE EXCEPTION 'Invoice no. or firm name is too long'; END IF;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'Enter the amount of bill %', v_no; END IF;
    -- each firm has its own bill numbers in Tally, so a number repeats only within the same firm
    v_key := btrim(regexp_replace(upper(v_firm), '[^A-Z0-9]+', ' ', 'g'));
    IF (v_key || '|' || upper(v_no)) = ANY (v_seen) THEN
      RAISE EXCEPTION 'Invoice no. % of % is entered twice', v_no, v_firm;
    END IF;
    v_seen := v_seen || (v_key || '|' || upper(v_no));
    -- the same firm + bill no. already given to another PO (older rows without firm lines: the PO's party)
    SELECT o.order_no::text INTO v_other
    FROM public.lwb_tally_invoices t JOIN public.orders o ON o.id = t.order_id
    WHERE t.order_id <> p_order_id
      AND t.invoice_date > p_invoice_date - 400
      AND (EXISTS (SELECT 1 FROM jsonb_array_elements(t.bills) b
                   WHERE upper(btrim(b->>'no')) = upper(v_no)
                     AND btrim(regexp_replace(upper(b->>'firm'), '[^A-Z0-9]+', ' ', 'g')) = v_key)
           OR (jsonb_array_length(t.bills) = 0
               AND btrim(regexp_replace(upper(o.customer_name::text), '[^A-Z0-9]+', ' ', 'g')) = v_key
               AND upper(v_no) = ANY (SELECT upper(btrim(x)) FROM unnest(string_to_array(t.invoice_no, ',')) x)))
    LIMIT 1;
    IF v_other IS NOT NULL THEN
      RAISE EXCEPTION 'Invoice no. % of % is already entered for PO %', v_no, v_firm, v_other;
    END IF;
    -- a sub-firm must belong to this party only (one ledger per main party)
    IF v_key <> btrim(regexp_replace(upper(v_party), '[^A-Z0-9]+', ' ', 'g')) THEN
      SELECT m.customer_name INTO v_linked FROM public.lwb_tally_party_map m WHERE m.tally_key = v_key;
      IF FOUND AND v_linked IS NOT NULL
         AND public.lwb_party_key(public.lwb_party_parent(v_linked)) <> public.lwb_party_key(public.lwb_party_parent(v_party)) THEN
        RAISE EXCEPTION 'Bill name % is under party %, not %. Change it in Billing & Outstanding > Party groups first.',
          v_firm, public.lwb_party_parent(v_linked), public.lwb_party_parent(v_party);
      END IF;
    END IF;
    v_nos := v_nos || v_no;
    v_total := v_total + v_amt;
    v_lines := v_lines || jsonb_build_object('firm', v_firm, 'no', v_no, 'amount', v_amt);
  END LOOP;

  IF length(array_to_string(v_nos, ', ')) > 200 THEN RAISE EXCEPTION 'Invoice numbers are too long'; END IF;
  v_res := public.lwb_save_tally_invoice(p_order_id, array_to_string(v_nos, ', '), p_invoice_date, p_note);
  UPDATE public.lwb_tally_invoices SET amount = v_total, bills = v_lines WHERE order_id = p_order_id;

  -- link each new sub-firm to the main party (Tally Bill Check matches the register with these links)
  FOR v_line IN SELECT * FROM jsonb_array_elements(v_lines) LOOP
    v_key := btrim(regexp_replace(upper(v_line->>'firm'), '[^A-Z0-9]+', ' ', 'g'));
    IF v_key <> btrim(regexp_replace(upper(v_party), '[^A-Z0-9]+', ' ', 'g'))
       AND v_key <> public.lwb_party_key(public.lwb_party_parent(v_party)) THEN
      INSERT INTO public.lwb_tally_party_map AS m (tally_key, tally_name, customer_name, updated_at, updated_by)
      VALUES (v_key, v_line->>'firm', public.lwb_party_parent(v_party), now(), auth.uid())
      ON CONFLICT (tally_key) DO UPDATE SET customer_name = excluded.customer_name, updated_at = now(), updated_by = auth.uid()
        WHERE m.customer_name IS NULL;
    END IF;
  END LOOP;
  RETURN v_res;
END;
$fn$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'party split table' AS item, (to_regclass('public.lwb_party_allocs') IS NOT NULL)::text AS ok
UNION ALL SELECT 'party payment', (to_regprocedure('public.lwb_party_receive(text,date,jsonb,jsonb,text)') IS NOT NULL)::text
UNION ALL SELECT 'billing screen data', (to_regprocedure('public.lwb_party_billing(integer)') IS NOT NULL)::text
UNION ALL SELECT 'group links', (to_regprocedure('public.lwb_party_group_set(text,text)') IS NOT NULL)::text;
