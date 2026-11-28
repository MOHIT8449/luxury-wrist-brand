-- LUXURY WRIST BRAND ERP — DRIVER CONFIRMS THE VEHICLE OF HIS POs (Mohit, 24 Nov 2026)
--
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped or deleted.
--
-- Mohit: the vehicle is now mandatory on Transport Assignment; "can we verify that the correct vehicle was entered?"
-- Chosen: automatic checks in the Vehicle Report (vehicle-report.html) + the driver confirms from his own login.
--   * A PO the driver submitted a delivery report for is already confirmed by him (his login, his mobile).
--   * Other loaded / delivered POs given to his mobile on Transport Assignment (for example marked Delivered by
--     Admin) wait in his Driver & Delivery page under "Confirm your trips": "Yes, my vehicle" / "Not me".
--     "Not me" rings Admin and Sales Head.
--   lwb_vehicle_confirm             one answer per PO (who, vehicle, when)
--   lwb_driver_trip_confirm_list()  driver: his POs of the last 30 days still to confirm
--   lwb_driver_trip_confirm(order, yes, note)  driver answers
--   lwb_vehicle_day (lwb_vehicle_day_setup.sql) returns confirm = REPORT / YES / NO per PO.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_vehicle_confirm (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  answer text NOT NULL CHECK (answer IN ('YES','NO')),
  vehicle_no text,
  driver_user_id uuid NOT NULL,
  driver_name text,
  note text CHECK (note IS NULL OR length(note) <= 200),
  answered_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_vehicle_confirm ENABLE ROW LEVEL SECURITY;  -- read / write through the functions only
REVOKE ALL ON public.lwb_vehicle_confirm FROM PUBLIC, anon, authenticated;

-- The driver's POs to confirm: given to his mobile, vehicle entered, loaded / delivered, no delivery report from him,
-- not answered yet, vehicle given in the last 30 days.
CREATE OR REPLACE FUNCTION public.lwb_driver_trip_confirm_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_mob text;
  v_out jsonb;
BEGIN
  SELECT p.mobile INTO v_mob FROM public.user_profiles p
  WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'driver';
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'party', o.customer_name,
           'vehicle_no', a.vehicle_no, 'qty', o.total_qty,
           'day', (coalesce(a.loading_completed_at, a.assigned_at) AT TIME ZONE 'Asia/Kolkata')::date)
         ORDER BY coalesce(a.loading_completed_at, a.assigned_at) DESC), '[]'::jsonb)
  INTO v_out
  FROM (SELECT DISTINCT ON (x.order_id) x.* FROM public.dispatch_assignments x
        WHERE x.assigned_at >= now() - interval '30 days' ORDER BY x.order_id, x.assigned_at DESC NULLS LAST) a
  JOIN public.orders o ON o.id = a.order_id
  WHERE public.lwb_driver_phone_matches(v_mob, a.driver_mobile)
    AND nullif(btrim(coalesce(a.vehicle_no,'')),'') IS NOT NULL
    AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected','deleted')
    AND (lower(coalesce(o.status,'')) IN ('loaded','invoiced','dispatched','out_for_delivery','delivered','partially_delivered','closed','completed')
         OR a.loading_completed_at IS NOT NULL
         OR (to_regclass('public.lwb_admin_order_marks') IS NOT NULL
             AND EXISTS (SELECT 1 FROM public.lwb_admin_order_marks m WHERE m.order_id = o.id)))
    AND NOT EXISTS (SELECT 1 FROM public.lwb_delivery_reports r WHERE r.order_id = o.id)
    AND NOT EXISTS (SELECT 1 FROM public.lwb_vehicle_confirm c WHERE c.order_id = o.id);
  RETURN v_out;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_driver_trip_confirm_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_driver_trip_confirm_list() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_driver_trip_confirm(p_order_id uuid, p_yes boolean, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_mob text;
  v_name text;
  v_veh text;
  v_no text;
  v_party text;
  v_note text := nullif(btrim(coalesce(p_note,'')),'');
BEGIN
  SELECT p.mobile, p.full_name INTO v_mob, v_name FROM public.user_profiles p
  WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'driver';
  IF NOT FOUND THEN RAISE EXCEPTION 'Only a driver can confirm his trips'; END IF;
  IF p_yes IS NULL THEN RAISE EXCEPTION 'Choose Yes or Not me'; END IF;
  IF length(coalesce(v_note,'')) > 200 THEN RAISE EXCEPTION 'Note is too long'; END IF;
  SELECT a.vehicle_no, o.order_no, o.customer_name INTO v_veh, v_no, v_party
  FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
  WHERE a.order_id = p_order_id AND public.lwb_driver_phone_matches(v_mob, a.driver_mobile)
  ORDER BY a.assigned_at DESC NULLS LAST LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'This PO is not given to your mobile number'; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_vehicle_confirm c WHERE c.order_id = p_order_id) THEN
    RAISE EXCEPTION 'PO % is already answered', v_no;
  END IF;
  INSERT INTO public.lwb_vehicle_confirm(order_id, answer, vehicle_no, driver_user_id, driver_name, note)
  VALUES (p_order_id, CASE WHEN p_yes THEN 'YES' ELSE 'NO' END, v_veh, auth.uid(), v_name, v_note);
  IF NOT p_yes THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, 'Driver says: not my vehicle',
      coalesce(v_name,'Driver') || ' says ' || coalesce(v_no,'PO') || ' · ' || coalesce(btrim(v_party),'') ||
      ' did not go in his vehicle ' || coalesce(v_veh,'-') || '.' || coalesce(' Note: ' || v_note, '') ||
      ' Check Transport on the PO (Vehicle Report).',
      'VEHICLE_CONFIRM_NO', p_order_id
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager');
  END IF;
  RETURN jsonb_build_object('order_no', v_no, 'answer', CASE WHEN p_yes THEN 'YES' ELSE 'NO' END);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_driver_trip_confirm(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_driver_trip_confirm(uuid, boolean, text) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';
