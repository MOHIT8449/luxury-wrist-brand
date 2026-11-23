-- 23 Nov 2026: owner asked to switch staff location off completely for now.
-- lwb_track_me now says "not tracked" for every login, so:
--   * the website never asks for or sends location,
--   * the Android app's location service stops itself (and the newest APK
--     no longer asks for location permission),
--   * the native GPS endpoint saves nothing.
-- To switch it back on, re-run lwb_driver_background_tracking_setup.sql.
-- No data is removed. Live Tracking page keeps showing deliveries.
CREATE OR REPLACE FUNCTION public.lwb_track_me()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_role text; s public.lwb_tracking_settings%ROWTYPE;
BEGIN
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
  SELECT * INTO s FROM public.lwb_tracking_settings WHERE id = 1;
  RETURN jsonb_build_object('tracked', false, 'in_hours', false, 'paused', true,
    'work_start', to_char(s.work_start,'HH24:MI'), 'work_end', to_char(s.work_end,'HH24:MI'), 'role', v_role);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_driver_track_ping(
 p_lat double precision, p_lng double precision, p_accuracy real DEFAULT NULL,
 p_speed_kmph real DEFAULT NULL, p_heading real DEFAULT NULL, p_status text DEFAULT 'ON')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
 RETURN jsonb_build_object('tracked', false);
END;
$fn$;
