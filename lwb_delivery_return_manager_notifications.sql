-- LUXURY WRIST BRAND | SALES HEAD & GODOWN MANAGER: DELIVERY RETURN NOTIFICATIONS
-- Run in Supabase SQL Editor AFTER reviewing. Idempotent trigger setup.
-- Existing driver return RPC saves header then updates total_return_amount once
-- at the end; the AFTER UPDATE trigger fires with the finalized amount.
-- Existing admin/accounts notifications remain unchanged.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_notify_return_to_operations()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
 v_order_no text;
BEGIN
 IF NEW.status <> 'PENDING_OFFICE' THEN
   RETURN NEW;
 END IF;

 SELECT o.order_no INTO v_order_no
 FROM public.orders o
 WHERE o.id = NEW.order_id;

 INSERT INTO public.erp_notifications (
    user_id, title, message, notification_type, order_id
 )
 SELECT p.id,
    'Delivery Return - Action Required',
    'Driver has collected a leakage / breakage / damage return on ' ||
       coalesce(v_order_no,'assigned order') ||
       '. Amount ₹' || to_char(NEW.total_return_amount,'FM9999999990.00') ||
       '. Pending office verification and warehouse damage receiving.',
    'DELIVERY_RETURN_OPERATIONS',
    NEW.order_id
 FROM public.user_profiles p
 WHERE p.active = true
   AND lower(btrim(p.role)) IN ('manager','warehouse');

 RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_lwb_notify_return_operations
 ON public.lwb_driver_delivery_returns;

CREATE TRIGGER trg_lwb_notify_return_operations
AFTER UPDATE OF total_return_amount
ON public.lwb_driver_delivery_returns
FOR EACH ROW
WHEN (NEW.status = 'PENDING_OFFICE')
EXECUTE FUNCTION public.lwb_notify_return_to_operations();

COMMIT;
