-- LUXURY WRIST BRAND ERP — ADMIN EDIT / DELETE FROM THE LEDGER (Ledger & Outstanding)
--
-- Runs by itself when merged to main (after lwb_receipt_date_change_setup.sql). Safe to run again.
-- Nothing is dropped. Every change is written to lwb_ledger_edit_log (before / after / reason / who).
--
-- Mohit (21 Nov 2026): from the ledger, Admin must be able to open any entry and edit / update /
-- delete it (receipt date, amount, mode, ref; Tally bill no. / date / amount; goods return). Only
-- Admin, nobody else. Example: SHREE DEV NARAYAN (BHAIYA NAGAR) 17/11 had ₹12,000 cash and ₹1,650 UPI
-- entered twice.
--
--  lwb_receipt_edit(receipt, date, lines, remark, reason)  date / each mode line (mode, amount, ref) /
--      new lines / remark. Money set to bills above the new total is taken back from the newest
--      splits (that bill is due again); more money goes to the same brand's oldest bills (as a new
--      payment does), the rest stays advance.
--  lwb_receipt_delete(receipt, reason)                    = cancel (kept as cancelled, splits undone)
--  lwb_tally_bill_edit(order, date, bills, reason)        = lwb_save_tally_bills, Admin only + log
--  lwb_tally_bill_delete(order, reason)                   Tally bill removed (PO back to Bills to make);
--      party money set to it goes back to advance.
--  lwb_party_return_edit(id, date, note, reason) / lwb_party_return_delete(id, reason)
--  lwb_ledger_edit_log_for(ref ids)                       history shown on the entry

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_ledger_edit_log (
  id          bigserial PRIMARY KEY,
  kind        text NOT NULL,          -- RECEIPT / TALLY_BILL / RETURN
  action      text NOT NULL,          -- EDIT / DELETE
  ref_id      uuid NOT NULL,          -- receipt_id / order_id / return id
  party       text,
  before      jsonb,
  after       jsonb,
  reason      text CHECK (reason IS NULL OR length(reason) <= 300),
  changed_by  uuid NOT NULL,
  changed_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_ledger_edit_log_ref_idx ON public.lwb_ledger_edit_log(ref_id);
ALTER TABLE public.lwb_ledger_edit_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_ledger_edit_log FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_ledger_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) = 'admin');
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_ledger_reason(p text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $fn$
DECLARE v text := nullif(btrim(coalesce(p,'')), '');
BEGIN
  IF v IS NOT NULL AND length(v) > 300 THEN RAISE EXCEPTION 'Reason is too long (300 letters max)'; END IF;
  RETURN v;
END;
$fn$;

-- snapshot of one receipt
CREATE OR REPLACE FUNCTION public.lwb_receipt_snap(p_receipt_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT jsonb_build_object(
    'pay_date', min(p.pay_date), 'remark', min(p.remark), 'total', sum(p.amount),
    'lines', jsonb_agg(jsonb_build_object('id', p.id, 'mode', p.mode, 'amount', p.amount, 'ref', p.ref_no) ORDER BY p.created_at, p.id),
    'allocs', coalesce((SELECT jsonb_agg(jsonb_build_object('order_id', a.order_id, 'amount', a.amount))
                        FROM public.lwb_party_allocs a WHERE a.receipt_id = p_receipt_id AND a.cancelled_at IS NULL), '[]'::jsonb))
  FROM public.lwb_tally_payments p WHERE p.receipt_id = p_receipt_id AND p.cancelled_at IS NULL;
$fn$;

-- ---------------------------------------------------------------------------
-- Receipt: edit
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_receipt_edit(p_receipt_id uuid, p_date date, p_lines jsonb,
                                                   p_remark text DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_reason text := public.lwb_ledger_reason(p_reason);
  v_remark text := nullif(btrim(coalesce(p_remark,'')), '');
  v_before jsonb; v_after jsonb;
  v_first public.lwb_tally_payments%ROWTYPE;
  v_parent text; v_line jsonb; v_id uuid; v_mode text; v_amt numeric; v_ref text;
  v_ids uuid[] := '{}'; v_total numeric := 0; v_cash numeric := 0; v_set numeric; v_over numeric;
  a record; v_split numeric := 0;
BEGIN
  IF NOT public.lwb_ledger_admin() THEN RAISE EXCEPTION 'Only Admin can edit a payment'; END IF;
  IF p_date IS NULL THEN RAISE EXCEPTION 'Choose the date'; END IF;
  IF p_date > v_today THEN RAISE EXCEPTION 'The date cannot be in the future'; END IF;
  IF v_remark IS NOT NULL AND length(v_remark) > 300 THEN RAISE EXCEPTION 'Remark is too long'; END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Enter at least one amount';
  END IF;
  IF jsonb_array_length(p_lines) > 8 THEN RAISE EXCEPTION 'At most 8 lines in one payment'; END IF;

  SELECT * INTO v_first FROM public.lwb_tally_payments p
  WHERE p.receipt_id = p_receipt_id AND p.cancelled_at IS NULL ORDER BY p.created_at, p.id LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found or cancelled'; END IF;
  v_parent := CASE WHEN v_first.order_id IS NULL THEN public.lwb_party_parent(v_first.party) END;
  IF v_parent IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(v_parent)));
  END IF;
  v_before := public.lwb_receipt_snap(p_receipt_id);

  -- check every line first
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_id := nullif(v_line->>'id','')::uuid;
    v_mode := upper(btrim(coalesce(v_line->>'mode','')));
    v_ref := nullif(btrim(coalesce(v_line->>'ref','')), '');
    BEGIN v_amt := round((v_line->>'amount')::numeric, 2);
    EXCEPTION WHEN others THEN v_amt := NULL; END;
    IF v_mode NOT IN ('CASH','UPI','BANK','CHEQUE') THEN RAISE EXCEPTION 'Choose the mode (Cash / UPI / Bank / Cheque)'; END IF;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'Enter the % amount', initcap(v_mode); END IF;
    IF v_mode = 'CHEQUE' AND v_ref IS NULL THEN RAISE EXCEPTION 'Enter the cheque number'; END IF;
    IF v_ref IS NOT NULL AND length(v_ref) > 100 THEN RAISE EXCEPTION 'Reference is too long'; END IF;
    IF v_mode = 'CASH' THEN v_ref := NULL; END IF;
    IF v_id IS NOT NULL THEN
      IF NOT EXISTS (SELECT 1 FROM public.lwb_tally_payments p WHERE p.id = v_id AND p.receipt_id = p_receipt_id AND p.cancelled_at IS NULL) THEN
        RAISE EXCEPTION 'A line of this payment was not found. Reload and try again.';
      END IF;
      IF v_id = ANY (v_ids) THEN RAISE EXCEPTION 'A line is sent twice'; END IF;
      v_ids := v_ids || v_id;
    END IF;
    IF v_mode <> 'CASH' AND v_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.lwb_tally_payments x WHERE x.mode = v_mode
          AND upper(btrim(x.ref_no)) = upper(v_ref) AND x.cancelled_at IS NULL AND x.receipt_id <> p_receipt_id) THEN
      RAISE EXCEPTION '% reference % is already entered on another payment', initcap(v_mode), v_ref;
    END IF;
    IF v_mode = 'CASH' THEN v_cash := v_cash + v_amt; END IF;
    v_total := v_total + v_amt;
  END LOOP;
  IF EXISTS (SELECT 1 FROM public.lwb_tally_payments p WHERE p.receipt_id = p_receipt_id AND p.cancelled_at IS NULL
             AND NOT (p.id = ANY (v_ids))) THEN
    RAISE EXCEPTION 'Every line of the payment must stay (to remove the whole payment use Delete)';
  END IF;

  -- write
  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_id := nullif(v_line->>'id','')::uuid;
    v_mode := upper(btrim(v_line->>'mode'));
    v_amt := round((v_line->>'amount')::numeric, 2);
    v_ref := CASE WHEN v_mode = 'CASH' THEN NULL ELSE nullif(btrim(coalesce(v_line->>'ref','')), '') END;
    IF v_id IS NOT NULL THEN
      UPDATE public.lwb_tally_payments SET mode = v_mode, amount = v_amt, ref_no = v_ref,
             cash_notes = CASE WHEN v_mode = 'CASH' AND amount = v_amt THEN cash_notes END
      WHERE id = v_id;
    ELSE
      INSERT INTO public.lwb_tally_payments (receipt_id, order_id, party, pay_date, mode, amount, ref_no, remark, created_by, company_id)
      VALUES (p_receipt_id, v_first.order_id, v_first.party, p_date, v_mode, v_amt, v_ref, v_remark, auth.uid(), v_first.company_id);
    END IF;
  END LOOP;
  UPDATE public.lwb_tally_payments SET pay_date = p_date, remark = v_remark
  WHERE receipt_id = p_receipt_id AND cancelled_at IS NULL;

  -- money set to bills above the new total comes back from the newest splits
  SELECT coalesce(sum(x.amount),0) INTO v_set FROM public.lwb_party_allocs x WHERE x.receipt_id = p_receipt_id AND x.cancelled_at IS NULL;
  v_over := round(v_set - v_total, 2);
  IF v_over > 0 THEN
    FOR a IN SELECT * FROM public.lwb_party_allocs x WHERE x.receipt_id = p_receipt_id AND x.cancelled_at IS NULL
             ORDER BY x.created_at DESC, x.id DESC LOOP
      EXIT WHEN v_over <= 0;
      UPDATE public.lwb_party_allocs SET cancelled_at = now(), cancelled_by = auth.uid() WHERE id = a.id;
      IF a.amount > v_over THEN
        INSERT INTO public.lwb_party_allocs (receipt_id, order_id, amount, created_by)
        VALUES (p_receipt_id, a.order_id, round(a.amount - v_over, 2), auth.uid());
        v_over := 0;
      ELSE
        v_over := round(v_over - a.amount, 2);
      END IF;
    END LOOP;
  ELSIF v_parent IS NOT NULL AND v_first.company_id IS NOT NULL AND v_total > v_set THEN
    -- more free money: same brand's oldest due bills, as a new payment does
    BEGIN v_split := public.lwb_party_apply_b(v_parent, v_first.company_id, NULL);
    EXCEPTION WHEN others THEN v_split := 0; END;
  END IF;

  v_after := public.lwb_receipt_snap(p_receipt_id);
  INSERT INTO public.lwb_ledger_edit_log (kind, action, ref_id, party, before, after, reason, changed_by)
  VALUES ('RECEIPT', 'EDIT', p_receipt_id, coalesce(v_parent, v_first.party), v_before, v_after, v_reason, auth.uid());
  RETURN jsonb_build_object('receipt_id', p_receipt_id, 'total', v_total, 'split', v_split,
                            'cash_over_limit', v_cash >= 200000);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Receipt: delete (cancel, kept as cancelled)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_receipt_delete(p_receipt_id uuid, p_reason text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_reason text := public.lwb_ledger_reason(p_reason); v_before jsonb; v_party text;
BEGIN
  IF NOT public.lwb_ledger_admin() THEN RAISE EXCEPTION 'Only Admin can delete a payment'; END IF;
  SELECT coalesce(min(p.party), min(o.customer_name::text)) INTO v_party
  FROM public.lwb_tally_payments p LEFT JOIN public.orders o ON o.id = p.order_id
  WHERE p.receipt_id = p_receipt_id AND p.cancelled_at IS NULL;
  IF v_party IS NULL THEN RAISE EXCEPTION 'Payment not found or already deleted'; END IF;
  v_before := public.lwb_receipt_snap(p_receipt_id);
  UPDATE public.lwb_tally_payments SET cancelled_at = now(), cancelled_by = auth.uid()
  WHERE receipt_id = p_receipt_id AND cancelled_at IS NULL;
  UPDATE public.lwb_party_allocs SET cancelled_at = now(), cancelled_by = auth.uid()
  WHERE receipt_id = p_receipt_id AND cancelled_at IS NULL;
  INSERT INTO public.lwb_ledger_edit_log (kind, action, ref_id, party, before, after, reason, changed_by)
  VALUES ('RECEIPT', 'DELETE', p_receipt_id, v_party, v_before, NULL, v_reason, auth.uid());
  RETURN 'DELETED';
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Tally bill: edit (Admin) / delete
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_tally_bill_snap(p_order_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT jsonb_build_object('invoice_no', t.invoice_no, 'invoice_date', t.invoice_date, 'amount', t.amount,
                            'bills', t.bills, 'note', t.note)
  FROM public.lwb_tally_invoices t WHERE t.order_id = p_order_id;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_tally_bill_edit(p_order_id uuid, p_invoice_date date, p_bills jsonb, p_reason text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_reason text := public.lwb_ledger_reason(p_reason); v_before jsonb; v_res text; v_party text;
BEGIN
  IF NOT public.lwb_ledger_admin() THEN RAISE EXCEPTION 'Only Admin can edit a Tally bill here'; END IF;
  IF p_invoice_date IS NULL OR p_invoice_date > (now() AT TIME ZONE 'Asia/Kolkata')::date THEN
    RAISE EXCEPTION 'Choose the bill date (not in the future)';
  END IF;
  SELECT btrim(o.customer_name::text) INTO v_party FROM public.orders o WHERE o.id = p_order_id;
  v_before := public.lwb_tally_bill_snap(p_order_id);
  IF v_before IS NULL THEN RAISE EXCEPTION 'Tally bill not found'; END IF;
  v_res := public.lwb_save_tally_bills(p_order_id, p_invoice_date, p_bills, v_before->>'note');
  INSERT INTO public.lwb_ledger_edit_log (kind, action, ref_id, party, before, after, reason, changed_by)
  VALUES ('TALLY_BILL', 'EDIT', p_order_id, v_party, v_before, public.lwb_tally_bill_snap(p_order_id), v_reason, auth.uid());
  RETURN v_res;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_tally_bill_delete(p_order_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_reason text := public.lwb_ledger_reason(p_reason); v_before jsonb; v_party text; v_back numeric;
BEGIN
  IF NOT public.lwb_ledger_admin() THEN RAISE EXCEPTION 'Only Admin can delete a Tally bill'; END IF;
  SELECT btrim(o.customer_name::text) INTO v_party FROM public.orders o WHERE o.id = p_order_id;
  v_before := public.lwb_tally_bill_snap(p_order_id);
  IF v_before IS NULL THEN RAISE EXCEPTION 'Tally bill not found or already deleted'; END IF;
  SELECT coalesce(sum(a.amount),0) INTO v_back FROM public.lwb_party_allocs a WHERE a.order_id = p_order_id AND a.cancelled_at IS NULL;
  v_before := v_before || jsonb_build_object('allocs', coalesce((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'receipt_id', a.receipt_id, 'amount', a.amount))
                                                                  FROM public.lwb_party_allocs a WHERE a.order_id = p_order_id AND a.cancelled_at IS NULL), '[]'::jsonb));
  -- party money set to this bill goes back to the party's advance
  UPDATE public.lwb_party_allocs SET cancelled_at = now(), cancelled_by = auth.uid()
  WHERE order_id = p_order_id AND cancelled_at IS NULL;
  DELETE FROM public.lwb_tally_invoices WHERE order_id = p_order_id;
  INSERT INTO public.lwb_ledger_edit_log (kind, action, ref_id, party, before, after, reason, changed_by)
  VALUES ('TALLY_BILL', 'DELETE', p_order_id, v_party, v_before, NULL, v_reason, auth.uid());
  RETURN jsonb_build_object('deleted', true, 'back_to_advance', v_back);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Goods return: edit date / note, delete
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_return_edit(p_id uuid, p_date date, p_note text DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_reason text := public.lwb_ledger_reason(p_reason); r public.lwb_party_returns%ROWTYPE;
        v_note text := nullif(btrim(coalesce(p_note,'')), '');
BEGIN
  IF NOT public.lwb_ledger_admin() THEN RAISE EXCEPTION 'Only Admin can edit a return'; END IF;
  IF p_date IS NULL OR p_date > (now() AT TIME ZONE 'Asia/Kolkata')::date THEN RAISE EXCEPTION 'Choose the date (not in the future)'; END IF;
  IF v_note IS NOT NULL AND length(v_note) > 300 THEN RAISE EXCEPTION 'Note is too long'; END IF;
  SELECT * INTO r FROM public.lwb_party_returns WHERE id = p_id AND cancelled_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Return not found or deleted'; END IF;
  UPDATE public.lwb_party_returns SET return_date = p_date, note = v_note WHERE id = p_id;
  IF r.note_id IS NOT NULL THEN UPDATE public.lwb_tally_notes SET note_date = p_date WHERE id = r.note_id; END IF;
  INSERT INTO public.lwb_ledger_edit_log (kind, action, ref_id, party, before, after, reason, changed_by)
  VALUES ('RETURN', 'EDIT', p_id, r.party, jsonb_build_object('return_date', r.return_date, 'note', r.note),
          jsonb_build_object('return_date', p_date, 'note', v_note), v_reason, auth.uid());
  RETURN 'SAVED';
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_party_return_delete(p_id uuid, p_reason text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_reason text := public.lwb_ledger_reason(p_reason); r public.lwb_party_returns%ROWTYPE;
BEGIN
  IF NOT public.lwb_ledger_admin() THEN RAISE EXCEPTION 'Only Admin can delete a return'; END IF;
  UPDATE public.lwb_party_returns SET cancelled_at = now(), cancelled_by = auth.uid()
  WHERE id = p_id AND cancelled_at IS NULL RETURNING * INTO r;
  IF NOT FOUND THEN RAISE EXCEPTION 'Return not found or already deleted'; END IF;
  IF r.note_id IS NOT NULL THEN
    UPDATE public.lwb_tally_notes SET cancelled_at = now(), cancelled_by = auth.uid() WHERE id = r.note_id AND cancelled_at IS NULL;
  END IF;
  INSERT INTO public.lwb_ledger_edit_log (kind, action, ref_id, party, before, after, reason, changed_by)
  VALUES ('RETURN', 'DELETE', p_id, r.party, jsonb_build_object('return_no', r.return_no, 'return_date', r.return_date, 'amount', r.amount),
          NULL, v_reason, auth.uid());
  RETURN 'DELETED';
END;
$fn$;

-- the mode lines of one receipt with their ids (Admin, for the edit form)
CREATE OR REPLACE FUNCTION public.lwb_receipt_lines(p_receipt_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_ledger_admin() THEN RAISE EXCEPTION 'Only Admin can edit a payment'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'mode', p.mode, 'amount', p.amount, 'ref', p.ref_no)
                                    ORDER BY p.created_at, p.id)
                   FROM public.lwb_tally_payments p WHERE p.receipt_id = p_receipt_id AND p.cancelled_at IS NULL), '[]'::jsonb);
END;
$fn$;

-- history of entries (Admin / Accounts / Cashier read it)
CREATE OR REPLACE FUNCTION public.lwb_ledger_edit_log_for(p_ids uuid[])
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(jsonb_agg(jsonb_build_object('ref_id', l.ref_id, 'kind', l.kind, 'action', l.action, 'before', l.before,
           'after', l.after, 'reason', l.reason, 'by', coalesce(u.full_name, 'Staff'), 'at', l.changed_at) ORDER BY l.changed_at), '[]'::jsonb)
  FROM public.lwb_ledger_edit_log l
  LEFT JOIN public.user_profiles u ON u.id = l.changed_by
  WHERE l.ref_id = ANY (coalesce(p_ids, '{}'))
    AND EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                AND lower(btrim(p.role)) IN ('accounts','admin','cashier'));
$fn$;

REVOKE ALL ON FUNCTION public.lwb_ledger_admin(), public.lwb_ledger_reason(text), public.lwb_receipt_snap(uuid),
  public.lwb_tally_bill_snap(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_receipt_edit(uuid,date,jsonb,text,text), public.lwb_receipt_delete(uuid,text),
  public.lwb_tally_bill_edit(uuid,date,jsonb,text), public.lwb_tally_bill_delete(uuid,text),
  public.lwb_party_return_edit(uuid,date,text,text), public.lwb_party_return_delete(uuid,text),
  public.lwb_ledger_edit_log_for(uuid[]), public.lwb_receipt_lines(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_receipt_edit(uuid,date,jsonb,text,text), public.lwb_receipt_delete(uuid,text),
  public.lwb_tally_bill_edit(uuid,date,jsonb,text), public.lwb_tally_bill_delete(uuid,text),
  public.lwb_party_return_edit(uuid,date,text,text), public.lwb_party_return_delete(uuid,text),
  public.lwb_ledger_edit_log_for(uuid[]), public.lwb_receipt_lines(uuid) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'ledger admin edit' AS item,
  (to_regclass('public.lwb_ledger_edit_log') IS NOT NULL
   AND to_regprocedure('public.lwb_receipt_edit(uuid,date,jsonb,text,text)') IS NOT NULL
   AND to_regprocedure('public.lwb_tally_bill_delete(uuid,text)') IS NOT NULL)::text AS ok;
