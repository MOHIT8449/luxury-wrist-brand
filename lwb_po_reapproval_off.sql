-- LUXURY WRIST BRAND ERP — NO ADMIN APPROVAL FOR A SALES HEAD'S PO EDIT (26 Nov 2026)
--
-- Mohit: the sales side does not need Admin's approval after an edit. warehouse-orders.html no longer
-- sends an edited PO back to Approval Pending (lwb_po_send_reapproval is not called any more).
-- This releases the POs already waiting ("✎ Edited · waiting for Admin", e.g. LXY-00698, LXY-00684):
-- each goes back to the step it was on (reapprove_from, driver / vehicle kept), its marks are cleared and
-- the unread PO_REAPPROVAL / PO_EDIT_HOLD bells are marked read. The edited SKU lines are already saved.
-- Nothing is dropped. Applied automatically on merge. Safe to run again.

BEGIN;

DO $rel$
DECLARE r record; n integer := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'orders' AND column_name = 'reapprove_from') THEN
    RAISE NOTICE 'reapprove columns not found: nothing to release'; RETURN;
  END IF;
  FOR r IN SELECT id, order_no, reapprove_from FROM public.orders
           WHERE reapprove_from IS NOT NULL AND public.lwb_order_pending(status) FOR UPDATE LOOP
    -- Direct status change (the trigger lwb_po_reapprove_back clears the marks when the status leaves pending).
    UPDATE public.orders SET status = r.reapprove_from,
      reapprove_from = NULL, reapprove_by = NULL, reapprove_at = NULL, reapprove_note = NULL
    WHERE id = r.id;
    UPDATE public.erp_notifications SET is_read = true
     WHERE order_id = r.id AND is_read = false AND notification_type IN ('PO_REAPPROVAL','PO_EDIT_HOLD');
    n := n + 1;
    RAISE NOTICE '% -> %', r.order_no, r.reapprove_from;
  END LOOP;
  RAISE NOTICE 'released % PO(s)', n;
END;
$rel$;

COMMIT;
