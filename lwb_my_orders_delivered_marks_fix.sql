-- LUXURY WRIST BRAND ERP — SALESMAN "MY ORDERS": DELIVERED TAB COUNTS THE ADMIN "MARK DELIVERED" TOO
--
-- Runs by itself when merged to main. Safe to run again. Read-only function: nothing is inserted,
-- changed or deleted.
--
-- Mohit (17 Nov 2026): Salesman My Sales > My Orders showed "Delivered 0" and "Not delivered yet 35"
-- although many of those POs were delivered. lwb_my_orders took "delivered" only from the driver's
-- delivery report (lwb_delivery_reports). A PO that Admin / Sales Head marked delivered by hand
-- (lwb_admin_order_marks kind DELIVERED, order status 'delivered') had no driver report, so it stayed
-- "Not delivered yet" for the salesman. Same gap that lwb_pending_delivery_marks_fix.sql closed for the
-- PO / Sales summary cards.
-- Now a PO is Delivered for the salesman when ANY of these is true (same rule as the PO List Delivered tab):
--   * driver report DELIVERED / PARTIAL (as before, PARTIAL stays "Part delivered"),
--   * Admin / Sales Head "Mark delivered" (delivered_at = the marked date),
--   * order status delivered / closed / completed.
-- Same signature and same output fields, so My Sales, Dashboard and the salesman phone home pick it up.
-- Needs lwb_admin_mark_load_deliver_setup.sql (table lwb_admin_order_marks); without it, works as before.

BEGIN;

DO $do$
BEGIN
  IF to_regclass('public.lwb_admin_order_marks') IS NULL THEN
    RAISE NOTICE 'lwb_admin_order_marks missing: lwb_my_orders not changed';
    RETURN;
  END IF;
  EXECUTE $sql$
CREATE OR REPLACE FUNCTION public.lwb_my_orders(p_days integer DEFAULT 45)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_field boolean := public.lwb_is_field_salesman();
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required.'; END IF;
  -- Salesman sees his own POs (PO List): status, delivery and edit/cancel before approval.
  -- Delivered = driver report DELIVERED / PARTIAL, or Admin / Sales Head mark, or status delivered.
  RETURN coalesce((
    SELECT jsonb_agg(x.j ORDER BY x.d DESC)
    FROM (
      SELECT coalesce(o.order_date, o.created_at) AS d,
        jsonb_build_object(
          'id', o.id, 'order_no', o.order_no, 'order_date', coalesce(o.order_date, o.created_at),
          'customer_name', o.customer_name, 'status', o.status,
          'total_qty', o.total_qty, 'total_amount', o.total_amount,
          'mine', o.created_by = auth.uid(),
          'can_edit', o.created_by = auth.uid() AND public.lwb_order_pending(o.status),
          'cancel_reason', o.cancel_reason, 'cancelled_at', o.cancelled_at,
          'driver_name', a.driver_name, 'vehicle_no', a.vehicle_no,
          'delivery_status', CASE
              WHEN r.delivery_status IN ('DELIVERED','PARTIAL') THEN r.delivery_status
              WHEN m.at IS NOT NULL OR lower(btrim(coalesce(o.status,''))) IN ('delivered','closed','completed') THEN 'DELIVERED'
              ELSE r.delivery_status END,
          'delivered_at', CASE
              WHEN r.delivery_status IN ('DELIVERED','PARTIAL') THEN r.reported_at
              WHEN m.at IS NOT NULL THEN m.at
              ELSE r.reported_at END,
          'delivery_marked', r.delivery_status IS DISTINCT FROM 'DELIVERED' AND r.delivery_status IS DISTINCT FROM 'PARTIAL'
              AND (m.at IS NOT NULL OR lower(btrim(coalesce(o.status,''))) IN ('delivered','closed','completed')),
          'received_by', r.received_by,
          'delivery_note', CASE WHEN r.delivery_status IN ('DELIVERED','PARTIAL') THEN r.delivery_note
              WHEN m.at IS NOT NULL THEN coalesce(nullif(btrim(m.note),''), 'Marked delivered by office')
              ELSE r.delivery_note END,
          'items', (SELECT coalesce(jsonb_agg(jsonb_build_object(
              'id', i.id, 'sku_name', i.sku_name, 'ordered_qty', i.ordered_qty,
              'approved_qty', i.approved_qty, 'loaded_qty', i.loaded_qty, 'rate', i.rate,
              'entry_uom', i.entry_uom, 'ordered_pallet_qty', i.ordered_pallet_qty) ORDER BY i.id), '[]'::jsonb)
            FROM public.order_items i WHERE i.order_id = o.id)
        ) AS j
      FROM public.orders o
      LEFT JOIN LATERAL (SELECT da.driver_name, da.vehicle_no FROM public.dispatch_assignments da
        WHERE da.order_id = o.id ORDER BY da.id DESC LIMIT 1) a ON true
      LEFT JOIN public.lwb_delivery_reports r ON r.order_id = o.id
      LEFT JOIN LATERAL (
        SELECT CASE WHEN mk.mark_date = (mk.marked_at AT TIME ZONE 'Asia/Kolkata')::date THEN mk.marked_at
                    ELSE (mk.mark_date + time '12:00') AT TIME ZONE 'Asia/Kolkata' END AS at, mk.note
        FROM public.lwb_admin_order_marks mk
        WHERE mk.order_id = o.id AND mk.kind = 'DELIVERED' LIMIT 1) m ON true
      WHERE coalesce(o.order_date, o.created_at) >= now() - make_interval(days => greatest(1, least(coalesce(p_days,45), 400)))
        AND (o.created_by = auth.uid()
             OR (v_field AND upper(btrim(coalesce(o.customer_name,''))) IN (SELECT public.lwb_my_party_names())))
    ) x
  ), '[]'::jsonb);
END;
$fn$;
  $sql$;
  REVOKE ALL ON FUNCTION public.lwb_my_orders(integer) FROM PUBLIC, anon;
  GRANT EXECUTE ON FUNCTION public.lwb_my_orders(integer) TO authenticated;
END;
$do$;

COMMIT;
NOTIFY pgrst, 'reload schema';
