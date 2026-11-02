-- LUXURY WRIST BRAND ERP — SELF PICKUP: SEARCH A DRIVER ENTERED BEFORE
--
-- Runs by itself when merged to main (after lwb_self_pickup_driver_setup.sql). Safe to run again.
-- Read-only: adds one function. Nothing is changed or deleted.
--
-- Mohit asked (2 Nov 2026): outside drivers / Porter vehicles change, but once a driver's name, mobile and
-- vehicle are entered on a Self Pickup order, next time search and pick them instead of typing again.
-- lwb_pickup_drivers(): the drivers of earlier Self Pickup orders, one row per driver mobile (else name +
-- vehicle), with the vehicle used last, newest first (max 500). For every active login except drivers.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_pickup_drivers()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(coalesce(p.role,''))) NOT IN ('', 'driver')) THEN
    RAISE EXCEPTION 'Login is not active.';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('driver_name', d.driver_name, 'driver_mobile', d.driver_mobile,
      'vehicle_no', d.vehicle_no, 'last_used', d.updated_at, 'times', d.times) ORDER BY d.updated_at DESC)
    FROM (SELECT * FROM (
      SELECT DISTINCT ON (k) x.driver_name, x.driver_mobile, x.vehicle_no, x.updated_at,
             count(*) OVER (PARTITION BY k) AS times
      FROM (SELECT t.*, coalesce(t.driver_mobile, lower(coalesce(t.driver_name,'')) || '|' || coalesce(t.vehicle_no,'')) AS k
            FROM public.lwb_order_pickup t
            WHERE coalesce(t.driver_name, t.driver_mobile, t.vehicle_no) IS NOT NULL) x
      ORDER BY k, x.updated_at DESC
    ) d0
    ORDER BY d0.updated_at DESC LIMIT 500
    ) d
  ), '[]'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pickup_drivers() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_pickup_drivers() TO authenticated;

COMMIT;
