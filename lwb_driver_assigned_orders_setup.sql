-- LUXURY WRIST BRAND ERP — DRIVER: ASSIGNED ORDERS WAITING FOR LOADING
-- Supabase SQL Editor: run ONCE after lwb_driver_delivery_setup.sql.
--
-- driver-delivery.html already calls lwb_driver_list_assigned_orders(), but the
-- function was never added to the repo, so the Driver Portal showed
-- "Loading Pending Orders unavailable until Supabase RPC is installed".
--
-- READ ONLY: no table, order, stock, invoice or ledger row is changed.
-- Same phone matching as lwb_driver_list_delivery_orders(): the order's
-- dispatch_assignments.driver_mobile must equal the Driver Login Mobile.
-- Shows ONLY orders still waiting for / in loading, with PLANNED (approved) cases.
-- Delivery submission stays locked until Dispatch marks the order LOADED.
BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_driver_list_assigned_orders()
RETURNS SETOF jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $fn$
DECLARE v_role text; v_mobile text;
BEGIN
 SELECT lower(btrim(p.role)),p.mobile INTO v_role,v_mobile
 FROM public.user_profiles p
 WHERE p.id=auth.uid() AND p.active=true;
 IF coalesce(v_role,'')<>'driver' THEN
  RAISE EXCEPTION 'Active Driver login required';
 END IF;
 IF coalesce(v_mobile,'')='' THEN
  RAISE EXCEPTION 'Driver profile Mobile missing; Admin must map your Login Mobile';
 END IF;
 RETURN QUERY
 SELECT jsonb_build_object(
   'order_id',o.id,'order_no',o.order_no,
   'order_date',o.order_date,'party_name',o.customer_name,
   'party_address',cm.billing_address,
   'party_city',cm.city,'party_state',cm.state,'party_pincode',cm.pincode,
   'order_status',o.status,
   'loading_pending',true,
   'vehicle_no',a.vehicle_no,
   'driver_name',a.driver_name,'driver_mobile',a.driver_mobile,
   'loading_person',a.loading_person,
   'transport_name',a.transporter_name,
   'loaded_skus',COALESCE((
      SELECT jsonb_agg(
       jsonb_build_object('sku',i.sku_name,'cases',coalesce(i.approved_qty,i.ordered_qty))
       ORDER BY i.sku_name)
      FROM public.order_items i
      WHERE i.order_id=o.id AND coalesce(i.approved_qty,i.ordered_qty,0)>0
   ),'[]'::jsonb),
   'planned_cases',coalesce((
      SELECT sum(coalesce(i.approved_qty,i.ordered_qty)) FROM public.order_items i
      WHERE i.order_id=o.id AND coalesce(i.approved_qty,i.ordered_qty,0)>0
   ),0),
   'report',NULL
 )
 FROM public.dispatch_assignments a
 JOIN public.orders o ON o.id=a.order_id
 LEFT JOIN LATERAL (
  SELECT c.billing_address,c.city,c.state,c.pincode
  FROM public.lwb_customer_master c
  WHERE lower(btrim(c.customer_name))=lower(btrim(o.customer_name))
  ORDER BY c.customer_code LIMIT 1
 ) cm ON true
 WHERE lower(btrim(o.status)) IN ('transport_allocated','allocated','loading')
  AND public.lwb_driver_phone_matches(v_mobile,a.driver_mobile)
 ORDER BY o.order_date DESC
 LIMIT 100;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_driver_list_assigned_orders() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_driver_list_assigned_orders() TO authenticated;

COMMIT;
NOTIFY pgrst,'reload schema';

-- Read-only verification. Expect one row: lwb_driver_list_assigned_orders
SELECT p.proname AS function_name
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname='lwb_driver_list_assigned_orders';
