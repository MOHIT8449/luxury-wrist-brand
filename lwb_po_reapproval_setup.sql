-- LUXURY WRIST BRAND ERP — EDITED PO GOES BACK TO APPROVAL PENDING (25 Nov 2026)
--
-- Applied automatically on merge (Supabase apply workflow). Safe to run again. Nothing is dropped.
--
-- Mohit (25 Nov 2026): an approved PO that is changed (SKU / cases / rate) must come back to
-- Approval Pending. Once it is approved again it goes straight back to the step it was on
-- (Transport Pending or Transport Assigned), with its driver / vehicle kept.
--
--   * orders.reapprove_from / reapprove_by / reapprove_at / reapprove_note: the step the PO was on
--     before the edit, who edited it, when, and what changed (shown on the list and the popup).
--   * lwb_po_send_reapproval(order, note): Admin / Sales Head, after saving the new SKU lines of an
--     approved PO (before loading). status -> pending_approval, Admin gets a PO_REAPPROVAL bell and the
--     Godown Manager of an assigned vehicle a PO_EDIT_HOLD bell (do not load until approved).
--   * Trigger lwb_po_reapprove_back (BEFORE UPDATE OF status on orders): when such a PO is approved
--     again (any page: PO list, Approvals, rate OK), the status goes back to reapprove_from. Only
--     Admin can approve an edited PO. Cancelled / other status: the marks are cleared.
--   * Loading / loaded POs are not touched: they keep the old "modify during loading" flow.

BEGIN;

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS reapprove_from text;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS reapprove_by uuid;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS reapprove_at timestamptz;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS reapprove_note text;

CREATE OR REPLACE FUNCTION public.lwb_po_send_reapproval(p_order_id uuid, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_st text; v_by text; v_msg text; v_note text;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid()
      AND p.active IS TRUE AND lower(btrim(p.role)) IN ('admin','manager')) THEN
    RAISE EXCEPTION 'Only Admin or Sales Head can send a PO for approval again.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PO not found.'; END IF;
  v_st := lower(btrim(coalesce(v_o.status,'')));
  IF public.lwb_order_pending(v_st) THEN
    RETURN jsonb_build_object('order_no', v_o.order_no, 'status', v_o.status, 'already', true);
  END IF;
  IF v_st NOT IN ('approved','approved_next','manager_approved','warehouse_approved','transport_allocated','allocated') THEN
    RAISE EXCEPTION 'PO % is %: only a PO before loading goes back to Approval Pending.', v_o.order_no, v_o.status;
  END IF;
  v_note := left(nullif(btrim(coalesce(p_note,'')),''), 600);
  UPDATE public.orders SET status = 'pending_approval', reapprove_from = v_o.status, reapprove_by = auth.uid(),
    reapprove_at = now(), reapprove_note = v_note
  WHERE id = v_o.id;

  BEGIN
    SELECT full_name INTO v_by FROM public.user_profiles WHERE id = auth.uid();
    v_msg := concat_ws(' · ', v_o.order_no, btrim(v_o.customer_name), 'edited by ' || coalesce(v_by,'Sales Head'), v_note);
    -- The old "approved" bells are no longer true.
    UPDATE public.erp_notifications SET is_read = true WHERE order_id = v_o.id AND is_read = false
      AND notification_type IN ('PO_APPROVED_LOADING','PO_APPROVED_BILL','PO_REAPPROVAL');
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, 'PO edited — approve again', v_msg, 'PO_REAPPROVAL', v_o.id
    FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'admin' AND p.id IS DISTINCT FROM auth.uid();
    IF v_st IN ('transport_allocated','allocated') THEN
      INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
      SELECT DISTINCT a.loading_manager_id, 'PO edited — wait before loading',
        v_msg || '. Do not load until Admin approves it again.', 'PO_EDIT_HOLD', v_o.id
      FROM public.dispatch_assignments a
      WHERE a.order_id = v_o.id AND a.loading_manager_id IS NOT NULL AND a.loading_manager_id IS DISTINCT FROM auth.uid();
    END IF;
  EXCEPTION WHEN others THEN NULL;  -- a bell never stops the save
  END;
  RETURN jsonb_build_object('order_no', v_o.order_no, 'status', 'pending_approval', 'back_to', v_o.status);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_send_reapproval(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_send_reapproval(uuid, text) TO authenticated;

-- Approved again -> back to the step it was on.
CREATE OR REPLACE FUNCTION public.lwb_po_reapprove_back()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_new text := lower(btrim(coalesce(NEW.status,'')));
BEGIN
  IF OLD.reapprove_from IS NULL OR NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF public.lwb_order_pending(v_new) THEN RETURN NEW; END IF;
  IF v_new IN ('approved','approved_next','manager_approved','warehouse_approved') THEN
    IF auth.uid() IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid()
        AND p.active IS TRUE AND lower(btrim(p.role)) = 'admin') THEN
      RAISE EXCEPTION 'This PO was edited after approval: only Admin can approve it again.' USING ERRCODE = '42501';
    END IF;
    NEW.status := OLD.reapprove_from;
    BEGIN
      UPDATE public.erp_notifications SET is_read = true
       WHERE order_id = NEW.id AND is_read = false AND notification_type IN ('PO_REAPPROVAL','PO_EDIT_HOLD');
      IF lower(btrim(OLD.reapprove_from)) IN ('transport_allocated','allocated') THEN
        INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
        SELECT DISTINCT a.loading_manager_id, 'Edited PO approved — load it',
          concat_ws(' · ', NEW.order_no, btrim(NEW.customer_name), to_char(coalesce(NEW.total_qty,0),'FM9999990') || ' CS') ||
          '. Print the PO again: SKU / cases changed.', 'PO_EDIT_APPROVED', NEW.id
        FROM public.dispatch_assignments a
        WHERE a.order_id = NEW.id AND a.loading_manager_id IS NOT NULL AND a.loading_manager_id IS DISTINCT FROM auth.uid();
      END IF;
    EXCEPTION WHEN others THEN NULL;
    END;
  END IF;
  NEW.reapprove_from := NULL; NEW.reapprove_by := NULL; NEW.reapprove_at := NULL; NEW.reapprove_note := NULL;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_reapprove_back() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS lwb_po_reapprove_back ON public.orders;
CREATE TRIGGER lwb_po_reapprove_back BEFORE UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.lwb_po_reapprove_back();

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check (all should be true):
-- SELECT to_regprocedure('public.lwb_po_send_reapproval(uuid,text)') IS NOT NULL,
--        EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'lwb_po_reapprove_back'),
--        EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'orders' AND column_name = 'reapprove_from');
