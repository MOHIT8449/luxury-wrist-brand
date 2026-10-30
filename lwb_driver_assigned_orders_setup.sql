-- lwb:no-auto-run  (record / read-only script, never applied automatically)
-- LUXURY WRIST BRAND ERP — DRIVER: ASSIGNED ORDERS WAITING FOR LOADING
--
-- RECORD ONLY: this function ALREADY EXISTS in Supabase (checked 23 Oct 2026
-- with pg_get_functiondef). It was created directly in Supabase and was never
-- saved to GitHub, so this file keeps a copy of the live definition.
-- No need to run it. Running it again is harmless (same definition).
--
-- Used by driver-delivery.html → db.rpc("lwb_driver_list_assigned_orders").
-- READ ONLY. Returns one jsonb array of the logged-in active DRIVER's orders in
-- transport_allocated / loading status, matched by Driver Login Mobile.
CREATE OR REPLACE FUNCTION public.lwb_driver_list_assigned_orders()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 SELECT COALESCE(
  jsonb_agg(
   jsonb_build_object(
    'order_id', o.id,
    'order_no', o.order_no,
    'party_name', o.customer_name,
    'order_status', o.status,
    'driver_name', a.driver_name,
    'driver_mobile', a.driver_mobile,
    'vehicle_no', a.vehicle_no,
    'loading_person', a.loading_person,
    'loading_pending', true,
    'planned_cases', (
      SELECT COALESCE(
        SUM(COALESCE(i.approved_qty, i.ordered_qty, 0)), 0
      )
      FROM public.order_items i
      WHERE i.order_id = o.id
    ),
    'loaded_skus', (
      SELECT COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'sku', i.sku_name,
            'cases', COALESCE(i.approved_qty, i.ordered_qty, 0)
          )
          ORDER BY i.created_at
        ), '[]'::jsonb
      )
      FROM public.order_items i
      WHERE i.order_id = o.id
    ),
    'report', NULL
   )
   ORDER BY a.assigned_at DESC
  ), '[]'::jsonb
 )
 FROM public.dispatch_assignments a
 JOIN public.orders o ON o.id = a.order_id
 JOIN public.user_profiles p ON p.id = auth.uid()
 WHERE p.active = true
 AND lower(btrim(p.role)) = 'driver'
 AND public.lwb_driver_phone_matches(
   p.mobile, a.driver_mobile
 )
 AND o.status IN ('transport_allocated', 'loading');
$function$;
