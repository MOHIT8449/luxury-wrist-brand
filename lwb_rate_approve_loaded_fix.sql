-- LUXURY WRIST BRAND ERP — LOW RATE APPROVE ON A PO THAT IS ALREADY LOADED
--
-- Runs by itself when merged to main (after lwb_cc_rate_limit_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit (17 Nov 2026): on Approvals > Low rate approval, "Approve rate" on LXY-00347 did nothing; only
-- "PO LXY-00347 is loaded — a slip is made when the PO is saved." The PO was already loaded (goods went), so
-- making the slip was refused and the whole approval was undone; the PO stayed in the list for ever.
-- Now: when the PO is already loaded / billed / delivered, or its slip is already made, Admin's OK only records
-- the rate approval (no new slip, no status change) and the PO leaves the list. Pending / approved POs work as before.
-- No Tally, ledger, payment, stock or bill amount is written here.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_rate_approve(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_a public.lwb_rate_approvals%ROWTYPE; v_r jsonb; v_o public.orders%ROWTYPE; v_slip boolean; v_st text; v_gone boolean;
BEGIN
  IF NOT public.lwb_price_admin() THEN RAISE EXCEPTION 'Only Admin can approve the rate.'; END IF;
  SELECT * INTO v_a FROM public.lwb_rate_approvals WHERE order_id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This PO is not waiting for a rate OK.'; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF lower(btrim(coalesce(v_o.status,''))) IN ('cancelled','canceled','rejected') THEN
    RAISE EXCEPTION 'PO % is %.', v_o.order_no, v_o.status;
  END IF;
  v_slip := public.lwb_quick_slip_company(p_order_id) IS NOT NULL;
  v_st := lower(btrim(coalesce(v_o.status,'')));
  -- Goods already went (PO loaded / billed / delivered, or the slip is there): only the rate OK is recorded.
  v_gone := v_st NOT IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new',
                         'approved','approved_next','manager_approved','warehouse_approved')
            OR EXISTS (SELECT 1 FROM public.lwb_quick_slips s WHERE s.order_id = p_order_id);
  UPDATE public.lwb_rate_approvals SET status = 'APPROVED', approved_by = auth.uid(), approved_at = now() WHERE order_id = p_order_id;
  IF v_gone THEN
    v_r := jsonb_build_object('order_id', v_o.id, 'order_no', v_o.order_no, 'status', v_o.status, 'already', true);
  ELSIF v_slip THEN
    v_r := public.lwb_quick_slip_dispatch(p_order_id, v_a.slip);
  ELSE
    UPDATE public.order_items SET approved_qty = coalesce(approved_qty, ordered_qty, 0) WHERE order_id = p_order_id;
    IF lower(btrim(coalesce(v_o.status,''))) IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new') THEN
      UPDATE public.orders SET status = 'approved', approved_by = auth.uid(), approved_at = now() WHERE id = p_order_id;
    END IF;
    v_r := jsonb_build_object('order_id', v_o.id, 'order_no', v_o.order_no, 'status', 'approved');
  END IF;
  BEGIN
    UPDATE public.erp_notifications SET is_read = true WHERE order_id = p_order_id AND is_read = false AND notification_type IN ('RATE_APPROVAL','PO_RATE_APPROVAL');
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT DISTINCT u, CASE WHEN v_gone THEN 'Rate OK by Admin' WHEN v_slip THEN 'Rate OK by Admin — slip made' ELSE 'Rate OK by Admin — PO approved' END,
           coalesce(v_o.order_no,'PO') || ' · ' || coalesce(btrim(v_o.customer_name),'') ||
           CASE WHEN v_gone THEN '. Rate approved (PO is already ' || coalesce(v_o.status,'') || ').' WHEN v_slip THEN '. Slip ready to print, sent to Accounts.' ELSE '. Assign transport next.' END,
           CASE WHEN v_slip THEN 'RATE_APPROVED' ELSE 'PO_RATE_APPROVED' END, p_order_id
    FROM unnest(ARRAY[v_a.requested_by, v_o.created_by]) u WHERE u IS NOT NULL AND u IS DISTINCT FROM auth.uid();
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN v_r;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_rate_approve(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_rate_approve(uuid) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
