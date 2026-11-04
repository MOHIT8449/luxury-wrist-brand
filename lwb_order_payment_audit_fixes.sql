-- LUXURY WRIST BRAND ERP — ORDER → PAYMENT AUDIT FIXES (4 Nov 2026)
--
-- Runs by itself when merged to main (after lwb_office_receive_driver_money.sql, lwb_order_delete_cancel_setup.sql,
-- lwb_party_group_billing_setup.sql). Safe to run again. Nothing is dropped, deleted or changed in the data.
--
-- Mohit asked for a full check of order → PO → loading → bill → payment → outstanding. Two money holes:
--  1. lwb_office_receive_driver_payment: Accounts could take more from the driver than is still due, because
--     money already taken at the office (Payment Collection, party payment split) and credit / debit notes were
--     not counted (only the loaded value). The due then went below zero and was hidden (Outstanding shows ≥ 0).
--     Now the limit is the money still due on the Tally bill (or loaded value − office money with no Tally bill).
--     A Tally bill above the loaded value can now be received in full.
--  2. lwb_head_cancel_order: a PO with a Tally bill could be cancelled. It then left Billing & Outstanding
--     (To collect) but its bill stayed in Party Ledger / Outstanding, and the bill could not be changed any more.
--     Now cancel asks first for a credit note for the full bill, and for any money taken on it to be cancelled.
-- Same functions as before otherwise (copied from the two files named above).

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_office_receive_driver_payment(
  p_report_id uuid, p_cash_notes jsonb, p_online_amount numeric, p_online_mode text,
  p_bank_ref text, p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_rep public.lwb_delivery_reports%ROWTYPE;
  v_notes jsonb := '{}'::jsonb;
  v_key text; v_cnt numeric; v_cash numeric := 0;
  v_online numeric := round(COALESCE(p_online_amount,0),2);
  v_mode text := upper(btrim(COALESCE(p_online_mode,'')));
  v_ref text := NULLIF(btrim(COALESCE(p_bank_ref,'')),'');
  v_note text := NULLIF(btrim(COALESCE(p_note,'')),'');
  v_total numeric; v_bill record; v_out numeric;
  v_order record; v_by text; v_limit numeric;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin')) THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can receive the driver''s money';
  END IF;
  SELECT * INTO v_rep FROM public.lwb_delivery_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Delivery report not found'; END IF;
  IF v_rep.delivery_status = 'NOT_DELIVERED' THEN RAISE EXCEPTION 'This order was not delivered'; END IF;
  IF v_rep.payment_status = 'VERIFIED' THEN RAISE EXCEPTION 'This payment is already received and verified'; END IF;

  FOR v_key IN SELECT jsonb_object_keys(COALESCE(p_cash_notes,'{}'::jsonb)) LOOP
    IF v_key NOT IN ('500','200','100','50','20','10','coins') THEN RAISE EXCEPTION 'Unknown note %', v_key; END IF;
    BEGIN
      v_cnt := COALESCE(NULLIF(p_cash_notes->>v_key,''),'0')::numeric;
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter a number for %', v_key;
    END;
    IF v_cnt < 0 OR v_cnt > 100000 OR (v_key <> 'coins' AND v_cnt <> trunc(v_cnt)) THEN
      RAISE EXCEPTION 'Check the count of %', v_key;
    END IF;
    IF v_cnt > 0 THEN
      v_notes := v_notes || jsonb_build_object(v_key, v_cnt);
      v_cash := v_cash + CASE WHEN v_key = 'coins' THEN round(v_cnt,2) ELSE v_key::numeric * v_cnt END;
    END IF;
  END LOOP;
  IF v_cash >= 200000 THEN
    RAISE EXCEPTION 'Cash of Rs 2 lakh or more from one party needs compliance review. Do not take it here.';
  END IF;

  IF v_online < 0 OR v_online > 99999999 THEN RAISE EXCEPTION 'Check the UPI / bank amount'; END IF;
  IF v_online = 0 THEN
    v_mode := NULL; v_ref := NULL;
  ELSE
    IF v_mode NOT IN ('UPI','BANK','CHEQUE') THEN RAISE EXCEPTION 'Select UPI, Bank or Cheque'; END IF;
    IF length(COALESCE(v_ref,'')) < 4 THEN
      RAISE EXCEPTION 'Check the UPI / bank payment in the bank and enter its UTR / reference number';
    END IF;
    IF EXISTS (SELECT 1 FROM public.lwb_delivery_reports d
               WHERE d.id <> p_report_id AND upper(btrim(d.bank_ref)) = upper(v_ref)) THEN
      RAISE EXCEPTION 'This UTR / reference is already used on another order';
    END IF;
  END IF;
  IF length(COALESCE(v_note,'')) > 300 THEN RAISE EXCEPTION 'Note is too long'; END IF;

  v_total := v_cash + v_online;
  IF v_total <= 0 THEN RAISE EXCEPTION 'Enter the cash or UPI amount received'; END IF;
  SELECT * INTO v_bill FROM public.lwb_order_bill_numbers(v_rep.order_id);
  IF v_total > v_bill.gross + 1 AND NOT EXISTS (SELECT 1 FROM public.lwb_tally_invoices t
       WHERE t.order_id = v_rep.order_id AND t.amount IS NOT NULL) THEN
    RAISE EXCEPTION 'Rs % is more than the bill Rs %', v_total, v_bill.gross;
  END IF;
  -- Money still due on this PO (4 Nov 2026 audit): Tally bill − credit notes + debit notes − money the office
  -- already took (Payment Collection, party payment split). This report's own earlier figure is put back,
  -- because it is replaced now. No Tally bill amount yet: loaded value − office money.
  v_limit := public.lwb_order_tally_due(v_rep.order_id);
  IF v_limit IS NOT NULL THEN
    IF coalesce(v_rep.payment_status,'') <> 'REJECTED' THEN v_limit := v_limit + coalesce(v_rep.cash_reported,0); END IF;
  ELSE
    v_limit := v_bill.gross - public.lwb_order_office_paid(v_rep.order_id);
  END IF;
  IF v_total > v_limit + 1 THEN
    RAISE EXCEPTION 'Rs % is more than the money still due on this PO (Rs %). The office already took Rs % on it (Payment Collection / party payment).',
      v_total, greatest(round(v_limit,2),0), public.lwb_order_office_paid(v_rep.order_id);
  END IF;
  v_out := GREATEST(0, round(v_limit - v_total, 2));

  UPDATE public.lwb_delivery_reports SET
    cash_reported = v_total,
    payment_mode = CASE WHEN v_cash > 0 AND v_online > 0 THEN 'CASH+' || v_mode
                        WHEN v_cash > 0 THEN 'CASH' ELSE v_mode END,
    collection_review_status = 'PENDING_OFFICE',
    cash_amount = v_cash, cash_notes = v_notes,
    online_amount = v_online, online_mode = v_mode,
    online_reference = CASE WHEN v_online > 0 THEN COALESCE(online_reference, v_ref) END,
    online_photo_paths = CASE WHEN v_online > 0 THEN online_photo_paths ELSE '{}' END,
    bank_ref = v_ref, office_received = true,
    payment_saved_at = COALESCE(payment_saved_at, now()),
    payment_status = 'VERIFIED', payment_reviewed_by = auth.uid(), payment_reviewed_at = now(),
    payment_review_note = v_note
  WHERE id = p_report_id;

  UPDATE public.erp_notifications SET is_read = true
  WHERE order_id = v_rep.order_id AND notification_type = 'DELIVERY_COLLECTION' AND is_read = false;

  SELECT o.order_no, o.customer_name INTO v_order FROM public.orders o WHERE o.id = v_rep.order_id;
  SELECT full_name INTO v_by FROM public.user_profiles WHERE id = auth.uid();
  IF v_rep.driver_user_id IS NOT NULL THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    VALUES (v_rep.driver_user_id, 'Payment Received by Office',
      COALESCE(v_by,'Accounts') || ' received Rs ' || to_char(v_total,'FM9999999990.00') || ' from you for ' ||
        COALESCE(v_order.order_no,'order') || ' (' || COALESCE(v_order.customer_name,'') || ')' ||
        CASE WHEN v_cash > 0 THEN ' · Cash Rs ' || to_char(v_cash,'FM9999999990.00') ELSE '' END ||
        CASE WHEN v_online > 0 THEN ' · ' || v_mode || ' Rs ' || to_char(v_online,'FM9999999990.00') ELSE '' END ||
        CASE WHEN v_out > 0 THEN ' · Still due Rs ' || to_char(v_out,'FM9999999990.00') ELSE '' END || '.',
      'DELIVERY_COLLECTION_VERIFIED', v_rep.order_id);
  END IF;

  RETURN jsonb_build_object('received', v_total, 'cash', v_cash, 'online', v_online, 'outstanding', v_out);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_office_receive_driver_payment(uuid,jsonb,numeric,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_office_receive_driver_payment(uuid,jsonb,numeric,text,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_head_cancel_order(p_order_id uuid, p_reason text, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_st text;
  v_by text;
  v_crew boolean;
  v_msg text;
  v_bill record;
  v_due numeric;
  v_paid numeric;
BEGIN
  IF public.lwb_order_actor_role() NOT IN ('admin','manager') THEN
    RAISE EXCEPTION 'Only Admin or Sales Head can cancel this order.';
  END IF;
  IF length(btrim(coalesce(p_reason,''))) < 3 THEN RAISE EXCEPTION 'Cancellation reason is required.'; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found (deleted?). Refresh the page.'; END IF;
  v_st := lower(btrim(coalesce(v_o.status,'')));
  IF v_st IN ('cancelled','canceled') THEN RAISE EXCEPTION 'Order % is already cancelled.', v_o.order_no; END IF;
  IF public.lwb_order_is_delivered(p_order_id, v_o.status) THEN
    RAISE EXCEPTION 'Order % is already delivered. Use Sales Return instead of Cancel.', v_o.order_no;
  END IF;
  -- Tally bill already made (4 Nov 2026 audit): a cancelled PO leaves Billing & Outstanding, but its Tally bill
  -- stayed in Party Ledger / Outstanding and could not be changed any more. Cancel only when the bill is
  -- squared (credit note for the full bill) and no money is taken on the PO.
  SELECT t.invoice_no, t.amount INTO v_bill FROM public.lwb_tally_invoices t WHERE t.order_id = p_order_id AND t.amount IS NOT NULL;
  IF FOUND THEN
    v_due := public.lwb_order_tally_due(p_order_id);
    v_paid := public.lwb_order_office_paid(p_order_id)
            + coalesce((SELECT sum(d.cash_reported) FROM public.lwb_delivery_reports d
                        WHERE d.order_id = p_order_id AND coalesce(d.payment_status,'') <> 'REJECTED'),0);
    IF v_paid > 0.5 THEN
      RAISE EXCEPTION 'Rs % is already received on PO %. Cancel that payment (or undo the party payment split) on Billing & Outstanding first.',
        round(v_paid,2), v_o.order_no;
    END IF;
    IF abs(coalesce(v_due,0)) > 1 THEN
      RAISE EXCEPTION 'Tally bill % (Rs %) is made for PO %. Ask Accounts to enter a Credit Note for the full bill on Billing & Outstanding, then cancel.',
        v_bill.invoice_no, v_bill.amount, v_o.order_no;
    END IF;
  END IF;

  UPDATE public.orders SET status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(),
    cancel_reason = btrim(p_reason),
    manager_note = CASE WHEN p_note IS NULL THEN manager_note ELSE nullif(btrim(p_note),'') END
  WHERE id = p_order_id;

  SELECT full_name INTO v_by FROM public.user_profiles WHERE id = auth.uid();
  INSERT INTO public.lwb_order_audit (order_id, order_no, action, reason, details, done_by, done_by_name)
  VALUES (p_order_id, v_o.order_no, 'CANCEL', btrim(p_reason), jsonb_build_object('status_before', v_o.status), auth.uid(), v_by);

  -- Vehicle side already working on it: tell Godown Manager, Driver (+ Accounts after loading).
  v_crew := v_st IN ('transport_allocated','allocated','loading','loaded','invoiced','dispatched');
  IF v_crew THEN
    v_msg := concat_ws(' · ', v_o.order_no, v_o.customer_name,
      'cancelled at ' || public.lwb_order_stage_name(v_o.status), 'by ' || coalesce(v_by, 'Sales Head'))
      || '. Reason: ' || btrim(p_reason) || '.'
      || CASE WHEN v_st IN ('loading','loaded','invoiced','dispatched')
           THEN ' Do not deliver: bring the goods back to the godown.' ELSE ' Do not load this order.' END;
    PERFORM public.lwb_order_crew_notify(p_order_id, 'Order Cancelled — Do Not Deliver', v_msg, 'ORDER_CANCELLED',
      v_st IN ('loaded','invoiced','dispatched'));
  END IF;
  RETURN jsonb_build_object('order_no', v_o.order_no, 'status_before', v_o.status);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_head_cancel_order(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_head_cancel_order(uuid, text, text) TO authenticated;

COMMIT;
