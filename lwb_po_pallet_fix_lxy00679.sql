-- LUXURY WRIST BRAND ERP — DATA FIX: PALLET COUNT OF LXY-00679 AFTER EDIT PO (25 Nov 2026)
--
-- Mohit: LXY-00679 shows 10P after 1L KINLEY was raised 60 -> 120 CS in Edit PO; it is 11 pallets.
-- The PO pallet count (orders.sp_pallets) was filled once at PO entry and Edit PO did not work it out
-- again (fixed in warehouse-orders.html). This sets it once from the saved lines:
-- sum(cases / cases per pallet), rounded up. Only this PO, only if it is not delivered / cancelled
-- and already had a pallet count. The Sheet & Pallet Ledger row follows (lwb_sp_sync_order).
-- Applied automatically on merge. Safe to run again.

BEGIN;

DO $fix$
DECLARE v_id uuid; v_old integer; v_new integer;
BEGIN
  SELECT o.id, o.sp_pallets INTO v_id, v_old FROM public.orders o
  WHERE o.order_no = 'LXY-00679'
    AND lower(btrim(coalesce(o.status,''))) NOT IN ('delivered','closed','completed','cancelled','canceled');
  IF v_id IS NULL OR coalesce(v_old,0) = 0 THEN RAISE NOTICE 'LXY-00679: nothing to fix'; RETURN; END IF;
  SELECT ceil(round(sum(coalesce(i.approved_qty, i.ordered_qty, 0)::numeric / s.cases_per_pallet), 2) - 0.01)::integer
    INTO v_new
  FROM public.order_items i
  JOIN LATERAL (SELECT m.cases_per_pallet FROM public.sku_master m
                WHERE upper(btrim(m.sku_name)) = upper(btrim(i.sku_name)) AND coalesce(m.cases_per_pallet,0) > 0
                LIMIT 1) s ON true
  WHERE i.order_id = v_id;
  IF v_new IS NULL OR v_new < 1 OR v_new = v_old THEN RAISE NOTICE 'LXY-00679: pallet % stays', v_old; RETURN; END IF;
  UPDATE public.orders SET sp_pallets = v_new WHERE id = v_id;
  IF to_regprocedure('public.lwb_sp_sync_order(uuid)') IS NOT NULL THEN PERFORM public.lwb_sp_sync_order(v_id); END IF;
  RAISE NOTICE 'LXY-00679: pallet % -> %', v_old, v_new;
END;
$fix$;

COMMIT;
