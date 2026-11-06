-- LUXURY WRIST BRAND ERP — SELF PICKUP: REPEAT PARTY GETS ITS LAST DRIVER / MOBILE / VEHICLE
--
-- Runs by itself when merged to main (after lwb_self_pickup_godown_list_fix.sql). Safe to run again.
-- Read-only: adds one function. Nothing is changed or deleted.
--
-- Mohit asked (6 Nov 2026): once a Self Pickup party's driver mobile and vehicle number are entered,
-- the same party's next Self Pickup order should fill them by itself (repeat customers often send the
-- same vehicle). lwb_party_last_pickup(party name): the driver, mobile, vehicle and Godown Manager of
-- that party's latest Self Pickup order (lwb_order_pickup), skipping cancelled orders. For every active
-- login except drivers (the same people who can already search earlier pickup drivers).

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_party_last_pickup(p_customer_name text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_party text := lower(regexp_replace(btrim(coalesce(p_customer_name,'')), '\s+', ' ', 'g'));
  r jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(coalesce(p.role,''))) NOT IN ('', 'driver')) THEN
    RAISE EXCEPTION 'Login is not active.';
  END IF;
  IF v_party = '' THEN RETURN NULL; END IF;
  SELECT jsonb_build_object('driver_name', t.driver_name, 'driver_mobile', t.driver_mobile, 'vehicle_no', t.vehicle_no,
           'godown_key', CASE WHEN t.godown_staff_id IS NOT NULL THEN 'S:' || t.godown_staff_id
                              WHEN t.godown_user_id IS NOT NULL THEN 'U:' || t.godown_user_id END,
           'godown_user_id', t.godown_user_id, 'godown_manager_name', t.godown_manager_name,
           'order_no', o.order_no, 'at', t.updated_at)
    INTO r
  FROM public.lwb_order_pickup t
  JOIN public.orders o ON o.id = t.order_id
  WHERE lower(regexp_replace(btrim(coalesce(o.customer_name,'')), '\s+', ' ', 'g')) = v_party
    AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled')
    AND coalesce(t.driver_name, t.driver_mobile, t.vehicle_no) IS NOT NULL
  ORDER BY t.updated_at DESC
  LIMIT 1;
  RETURN r;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_last_pickup(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_last_pickup(text) TO authenticated;

COMMIT;
