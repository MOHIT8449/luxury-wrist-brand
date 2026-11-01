-- LUXURY WRIST BRAND ERP — BILL AS SOON AS THE PO IS APPROVED
--
-- Runs by itself when merged to main (after lwb_loading_workflow_setup.sql and
-- lwb_party_payment_collection_setup.sql). Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (1 Nov 2026): once a PO is approved its quantity is fixed, so Accounts and the Godown Manager
-- should see it at once. The party waits at the cash counter for the bill; Accounts should not have to wait
-- for loading to finish.
--   * lwb_po_billable: approved, transport given, loading or loaded (not pending / cancelled).
--   * lwb_save_tally_invoice: the Tally bill no. can be entered from approval on (was: only after loading).
--     The bill is still made in Tally; the ERP only keeps its number and amount.
--   * lwb_tally_bill_rows: a PO billed before loading counts in To collect from the day of the bill.
--   * lwb_bills_before_loading: approved POs without a Tally bill, for Billing & Outstanding > Bills to make.
--   * PO approved -> popup to Accounts (make the bill) and Godown Managers (get ready for loading).
--   * Vehicle loaded on a PO billed already: no "Make Tally bill" popup; Accounts are told only when the
--     loaded value differs from the bill.
-- No order, stock, bill amount, payment, ledger or Tally data is changed by this file.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_po_billable(p_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT coalesce(lower(btrim(p_status)),'') IN
    ('approved','approved_next','manager_approved','warehouse_approved','transport_allocated','allocated',
     'loading','loaded','invoiced','dispatched','delivered');
$fn$;
GRANT EXECUTE ON FUNCTION public.lwb_po_billable(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 1. Tally bill no. from approval on (same as lwb_loading_workflow_setup.sql, status check widened)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_save_tally_invoice(p_order_id uuid, p_invoice_no text, p_invoice_date date, p_note text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_no text := regexp_replace(btrim(coalesce(p_invoice_no,'')), '\s*,\s*', ', ', 'g');
  v_note text := nullif(btrim(coalesce(p_note,'')),'');
  v_order public.orders%ROWTYPE;
  v_old public.lwb_tally_invoices%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin')) THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can enter the Tally invoice number';
  END IF;
  IF v_no = '' THEN RAISE EXCEPTION 'Enter the Tally invoice number'; END IF;
  IF length(v_no) > 200 THEN RAISE EXCEPTION 'Invoice number is too long'; END IF;
  IF p_invoice_date IS NULL OR p_invoice_date > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1 THEN
    RAISE EXCEPTION 'Enter a valid invoice date';
  END IF;
  IF length(coalesce(v_note,'')) > 300 THEN RAISE EXCEPTION 'Note is too long'; END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  -- From PO approval on: the quantity is fixed, so Accounts may bill before the vehicle is loaded.
  IF NOT public.lwb_po_billable(v_order.status) THEN
    RAISE EXCEPTION 'PO % is not approved yet (status %), so it cannot be billed', v_order.order_no, coalesce(v_order.status,'-');
  END IF;

  SELECT * INTO v_old FROM public.lwb_tally_invoices WHERE order_id = p_order_id FOR UPDATE;
  IF FOUND THEN
    UPDATE public.lwb_tally_invoices
    SET invoice_no = v_no, invoice_date = p_invoice_date, note = v_note, updated_by = auth.uid(), updated_at = now()
    WHERE order_id = p_order_id;
    RETURN 'UPDATED';
  END IF;

  INSERT INTO public.lwb_tally_invoices (order_id, invoice_no, invoice_date, note, entered_by)
  VALUES (p_order_id, v_no, p_invoice_date, v_note, auth.uid());

  UPDATE public.erp_notifications SET is_read = true
  WHERE order_id = p_order_id AND notification_type = 'TALLY_BILL_PENDING' AND is_read = false;

  -- Sales Head / Admin: bill made (the number stays with Accounts)
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, 'Tally Bill Made',
    coalesce(v_order.order_no,'Order') || ' · ' || coalesce(v_order.customer_name,'') || ': Accounts made the Tally bill.',
    'TALLY_BILL_DONE', p_order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('manager','admin') AND p.id IS DISTINCT FROM auth.uid();
  RETURN 'SAVED';
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_save_tally_invoice(uuid,text,date,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_save_tally_invoice(uuid,text,date,text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Bill rows (same as lwb_party_payment_collection_setup.sql, plus POs billed before loading)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_tally_bill_rows(p_days integer)
RETURNS TABLE (order_id uuid, order_no text, party text, status text, order_date date, dispatch_date date,
               invoice_no text, invoice_date date, bill_amount numeric, erp_amount numeric,
               approved_return numeric, pending_return numeric, credit_notes numeric, debit_notes numeric,
               collected numeric, verified numeric, due numeric, credit_pending numeric, delivery text,
               notes jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  WITH o AS (
    SELECT o.id, o.order_no::text AS order_no, btrim(o.customer_name::text) AS party,
           lower(btrim(coalesce(o.status::text,''))) AS status, o.order_date::date AS order_date,
           coalesce((SELECT max(a.loading_completed_at) FROM public.dispatch_assignments a WHERE a.order_id = o.id)
                    AT TIME ZONE 'Asia/Kolkata', o.order_date::timestamp)::date AS dispatch_date
    FROM public.orders o
    WHERE (lower(btrim(coalesce(o.status::text,''))) IN ('loaded','invoiced','dispatched','delivered')
           -- billed before loading: the Tally bill is due from the day it is made
           OR (public.lwb_po_billable(o.status::text)
               AND EXISTS (SELECT 1 FROM public.lwb_tally_invoices ti WHERE ti.order_id = o.id)))
      AND o.order_date::date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - least(greatest(coalesce(p_days,120),1),400)
  )
  SELECT o.id, o.order_no, o.party, o.status, o.order_date, o.dispatch_date,
         t.invoice_no, t.invoice_date, t.amount, b.gross, b.approved_return, b.pending_return,
         coalesce(n.cr,0), coalesce(n.dr,0), coalesce(c.got,0) + op.amt, coalesce(c.ok,0) + op.amt,
         round(coalesce(t.amount, b.net + coalesce(n.cr,0)) - coalesce(n.cr,0) + coalesce(n.dr,0) - coalesce(c.got,0) - op.amt, 2),
         greatest(0, round(b.approved_return - coalesce(n.cr,0), 2)),
         coalesce(c.delivery,''),
         coalesce(n.list,'[]'::jsonb)
  FROM o
  CROSS JOIN LATERAL public.lwb_order_bill_numbers(o.id) b
  CROSS JOIN LATERAL (SELECT public.lwb_order_office_paid(o.id) AS amt) op
  LEFT JOIN public.lwb_tally_invoices t ON t.order_id = o.id
  LEFT JOIN LATERAL (
    SELECT sum(x.amount) FILTER (WHERE x.kind = 'CREDIT' AND x.cancelled_at IS NULL) AS cr,
           sum(x.amount) FILTER (WHERE x.kind = 'DEBIT' AND x.cancelled_at IS NULL) AS dr,
           jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'note_no', x.note_no, 'note_date', x.note_date,
                     'amount', x.amount, 'reason', x.reason, 'cancelled', x.cancelled_at IS NOT NULL)
                     ORDER BY x.created_at) AS list
    FROM public.lwb_tally_notes x WHERE x.order_id = o.id) n ON true
  LEFT JOIN LATERAL (
    SELECT sum(d.cash_reported) FILTER (WHERE coalesce(d.payment_status,'') <> 'REJECTED') AS got,
           sum(d.cash_reported) FILTER (WHERE d.payment_status = 'VERIFIED') AS ok,
           max(d.delivery_status::text) AS delivery
    FROM public.lwb_delivery_reports d WHERE d.order_id = o.id) c ON true
  ORDER BY o.dispatch_date DESC, o.party, o.order_no;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_tally_bill_rows(integer) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Approved POs not billed yet (Accounts / Admin): Bills to make, before loading
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_bills_before_loading()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN RAISE EXCEPTION 'Active Admin / Accounts role required.'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'order_id', o.id, 'order_no', o.order_no, 'party', btrim(o.customer_name::text),
      'status', lower(btrim(coalesce(o.status::text,''))), 'order_date', o.order_date::date,
      'approved_at', o.approved_at, 'priority', o.priority,
      'qty', (SELECT coalesce(sum(coalesce(i.approved_qty, i.ordered_qty)),0) FROM public.order_items i WHERE i.order_id = o.id),
      'erp_amount', (SELECT coalesce(round(sum(coalesce(i.approved_qty, i.ordered_qty, 0)::numeric * coalesce(i.rate,0)::numeric),2),0)
                     FROM public.order_items i WHERE i.order_id = o.id),
      'vehicle_no', a.vehicle_no, 'driver_name', a.driver_name)
      ORDER BY o.approved_at DESC NULLS LAST, o.order_date DESC, o.order_no)
    FROM public.orders o
    LEFT JOIN LATERAL (SELECT x.vehicle_no, x.driver_name FROM public.dispatch_assignments x
                       WHERE x.order_id = o.id LIMIT 1) a ON true
    WHERE lower(btrim(coalesce(o.status::text,''))) IN
          ('approved','approved_next','manager_approved','warehouse_approved','transport_allocated','allocated','loading')
      AND o.order_date::date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - 60
      AND NOT EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = o.id)), '[]'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bills_before_loading() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_bills_before_loading() TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. PO approved -> Accounts (make the bill) and Godown Managers (get ready to load)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_flow_po_approved()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_info text;
BEGIN
  IF lower(btrim(coalesce(NEW.status,''))) NOT IN ('approved','approved_next','manager_approved','warehouse_approved')
     OR (TG_OP = 'UPDATE' AND NOT public.lwb_order_pending(OLD.status)) THEN
    RETURN NULL;
  END IF;
  v_info := coalesce(NEW.order_no,'PO') || ' · ' || coalesce(btrim(NEW.customer_name),'') ||
    ' · ' || to_char(coalesce(NEW.total_qty,0),'FM9999990') || ' CS · Rs ' || to_char(coalesce(NEW.total_amount,0),'FM9999999990.00');
  BEGIN
    PERFORM public.lwb_flow_send(NEW.id, ARRAY['accounts'], 'PO Approved — Make Bill',
      v_info || '. Quantity is final: make the Tally bill now (Billing & Outstanding > Bills to make), no need to wait for loading.',
      'PO_APPROVED_BILL');
    PERFORM public.lwb_flow_send(NEW.id, ARRAY['godown'], 'PO Approved — Get Ready to Load',
      v_info || '. Driver and vehicle come next from the Sales Head; keep the goods ready.',
      'PO_APPROVED_LOADING');
  EXCEPTION WHEN others THEN NULL;  -- a popup never stops the approval
  END;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_flow_po_approved() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_flow_po_approved ON public.orders;
CREATE TRIGGER trg_lwb_flow_po_approved AFTER INSERT OR UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.lwb_flow_po_approved();

-- ---------------------------------------------------------------------------
-- 5. Vehicle loaded (same as lwb_loading_workflow_setup.sql; no "Make Tally bill" when billed already)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_notify_vehicle_loaded()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_vehicle text; v_cases numeric; v_value numeric; v_by text; v_info text; v_bill numeric; v_billed boolean;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status OR NEW.status <> 'loaded' THEN RETURN NEW; END IF;
  SELECT a.vehicle_no INTO v_vehicle FROM public.dispatch_assignments a WHERE a.order_id = NEW.id LIMIT 1;
  SELECT coalesce(sum(i.loaded_qty),0), coalesce(sum(round(coalesce(i.loaded_qty,0)::numeric * coalesce(i.rate,0)::numeric,2)),0)
    INTO v_cases, v_value FROM public.order_items i WHERE i.order_id = NEW.id;
  SELECT full_name INTO v_by FROM public.user_profiles WHERE id = auth.uid();
  v_info := coalesce(NEW.order_no,'Order') || ' · ' || coalesce(NEW.customer_name,'') ||
    ' · Vehicle ' || coalesce(nullif(btrim(v_vehicle),''),'-') ||
    ' · ' || to_char(v_cases,'FM9999990') || ' CS · Rs ' || to_char(v_value,'FM9999999990.00') ||
    coalesce(' · Loaded by ' || v_by, '');

  SELECT true, t.amount INTO v_billed, v_bill FROM public.lwb_tally_invoices t WHERE t.order_id = NEW.id;
  IF coalesce(v_billed, false) THEN
    -- Bill made before loading: tell Accounts only when the loaded value differs from it.
    UPDATE public.erp_notifications SET is_read = true
    WHERE order_id = NEW.id AND notification_type = 'PO_APPROVED_BILL' AND is_read = false;
    IF v_bill IS NOT NULL AND abs(v_bill - v_value) > 1 THEN
      INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
      SELECT p.id, 'Loaded value differs from the bill',
        v_info || '. Tally bill Rs ' || to_char(v_bill,'FM9999999990.00') ||
        ' was made before loading. Check it; make a credit / debit note if needed.',
        'VEHICLE_LOADED', NEW.id
      FROM public.user_profiles p
      WHERE p.active = true AND lower(btrim(p.role)) = 'accounts' AND p.id IS DISTINCT FROM auth.uid();
    END IF;
  ELSE
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, 'Vehicle Loaded — Make Tally Bill',
      v_info || '. Make the bill in Tally, then enter the invoice number on Tally Bill & Invoice No.',
      'TALLY_BILL_PENDING', NEW.id
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(p.role)) = 'accounts' AND p.id IS DISTINCT FROM auth.uid();
  END IF;

  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, 'Vehicle Loaded', v_info || '. Sent to Accounts for the Tally bill.', 'VEHICLE_LOADED', NEW.id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('manager','admin') AND p.id IS DISTINCT FROM auth.uid();
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_notify_vehicle_loaded() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_notify_vehicle_loaded ON public.orders;
CREATE TRIGGER trg_lwb_notify_vehicle_loaded
AFTER UPDATE OF status ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.lwb_notify_vehicle_loaded();

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'approved POs waiting for a Tally bill' AS item,
  (SELECT count(*) FROM public.orders o
   WHERE lower(btrim(coalesce(o.status,''))) IN ('approved','approved_next','manager_approved','warehouse_approved','transport_allocated','allocated','loading')
     AND NOT EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = o.id))::text AS value
UNION ALL SELECT 'po approved popup', (EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_flow_po_approved'))::text;
