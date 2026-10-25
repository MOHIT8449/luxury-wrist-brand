-- LUXURY WRIST BRAND ERP — LOADING ASSIGNMENT NOTIFICATIONS INSIDE THE ERP
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- When a driver / vehicle is saved for an order (Transport Assignment or PO Approval),
-- an ERP notification (🔔 bell) goes to:
--   * the Driver login whose mobile matches the saved Driver Mobile (Driver app / portal)
--   * active Warehouse and Manager users (dispatch team)
-- The person who saved it is not notified. WhatsApp is not used.
-- It fires on a new assignment, or when driver mobile / driver name / vehicle changes.
-- No order, stock, bill, payment or Tally data is changed.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_notify_loading_assignment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
DECLARE
  v_order public.orders%ROWTYPE;
  v_info text;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.driver_mobile IS NOT DISTINCT FROM OLD.driver_mobile
     AND NEW.driver_name IS NOT DISTINCT FROM OLD.driver_name
     AND NEW.vehicle_no IS NOT DISTINCT FROM OLD.vehicle_no THEN
    RETURN NEW;
  END IF;
  IF coalesce(btrim(NEW.driver_name),'') = '' AND coalesce(btrim(NEW.vehicle_no),'') = '' THEN
    RETURN NEW;
  END IF;

  SELECT o.* INTO v_order FROM public.orders o WHERE o.id = NEW.order_id;

  v_info := coalesce(v_order.order_no,'Order') ||
    CASE WHEN v_order.customer_name IS NOT NULL THEN ' · ' || v_order.customer_name ELSE '' END ||
    ' · Vehicle ' || coalesce(nullif(btrim(NEW.vehicle_no),''),'-') ||
    ' · Driver ' || coalesce(nullif(btrim(NEW.driver_name),''),'-') ||
    CASE WHEN coalesce(btrim(NEW.driver_mobile),'') <> '' THEN ' (' || btrim(NEW.driver_mobile) || ')' ELSE '' END ||
    CASE WHEN coalesce(btrim(NEW.loading_person),'') <> '' THEN ' · Loading: ' || btrim(NEW.loading_person) ELSE '' END ||
    CASE WHEN v_order.total_weight IS NOT NULL THEN ' · ' || to_char(v_order.total_weight,'FM999999990.0') || ' KG' ELSE '' END;

  -- Driver: matched by mobile number only, never by name
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id,
    CASE WHEN TG_OP = 'INSERT' THEN 'Naya Loading Assignment' ELSE 'Loading Assignment badla' END,
    v_info || '. Driver app me order dekho.',
    'LOADING_ASSIGNMENT_DRIVER',
    NEW.order_id
  FROM public.user_profiles p
  WHERE p.active = true
    AND lower(btrim(p.role)) = 'driver'
    AND public.lwb_driver_phone_matches(p.mobile, NEW.driver_mobile)
    AND p.id IS DISTINCT FROM auth.uid();

  -- Dispatch team
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id,
    CASE WHEN TG_OP = 'INSERT' THEN 'Loading ke liye gaadi assign hui' ELSE 'Loading gaadi / driver badla' END,
    v_info || '.',
    'LOADING_ASSIGNMENT_DISPATCH',
    NEW.order_id
  FROM public.user_profiles p
  WHERE p.active = true
    AND lower(btrim(p.role)) IN ('warehouse','manager')
    AND p.id IS DISTINCT FROM auth.uid();

  RETURN NEW;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_notify_loading_assignment() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_lwb_notify_loading_assignment ON public.dispatch_assignments;
CREATE TRIGGER trg_lwb_notify_loading_assignment
AFTER INSERT OR UPDATE OF driver_mobile, driver_name, vehicle_no
ON public.dispatch_assignments
FOR EACH ROW
EXECUTE FUNCTION public.lwb_notify_loading_assignment();

COMMIT;
