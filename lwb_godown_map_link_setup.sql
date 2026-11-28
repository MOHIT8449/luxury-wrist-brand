-- LUXURY WRIST BRAND ERP — Godown location for the driver WhatsApp: Google Maps place link (28 Nov 2026)
--
-- Mohit asked (28 Nov 2026): the "📍 Send location" WhatsApp to a truck driver sent a bare lat/long link
-- (maps.google.com/?q=21.2103,72.8990), which WhatsApp shows without a photo. Use our Google Maps place
-- "Luxury Wareshouse (Surat)" instead: WhatsApp then shows the photo card with the name and the stars.
--
--   lwb_tracking_settings  + godown_map_url, godown_address (set once below; Live Tracking geofence still uses lat / lng)
--   lwb_vehicle_loc_sent   + map_url, address in the result (dial-book.js puts the place link first in the message)
--
-- Safe to run again. Nothing is dropped or deleted. A link / address changed later by hand is kept.

BEGIN;

ALTER TABLE public.lwb_tracking_settings ADD COLUMN IF NOT EXISTS godown_map_url text
  CHECK (godown_map_url IS NULL OR godown_map_url ~ '^https://');
ALTER TABLE public.lwb_tracking_settings ADD COLUMN IF NOT EXISTS godown_address text
  CHECK (godown_address IS NULL OR length(godown_address) <= 200);
UPDATE public.lwb_tracking_settings
   SET godown_map_url = coalesce(godown_map_url, 'https://maps.app.goo.gl/ymaoBJxw1BLY1hnu8'),
       godown_address = coalesce(godown_address, 'Shade No. 15, Dev Campus, Ram Katha Ground, Simada Canal, Surat, Gujarat 395013')
 WHERE id = 1;

CREATE OR REPLACE FUNCTION public.lwb_vehicle_loc_sent(p_vehicle text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE d public.lwb_vehicle_driver; g record; v_me record;
BEGIN
  IF coalesce(public.lwb_dial_role(), '') NOT IN ('admin','manager','sales','accounts','warehouse') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Salesman, Accounts or Godown Manager can send the godown location';
  END IF;
  SELECT * INTO d FROM public.lwb_vehicle_driver WHERE vehicle_key = public.lwb_vehicle_key(p_vehicle);
  IF NOT FOUND THEN RAISE EXCEPTION 'Save the vehicle driver first'; END IF;
  SELECT s.godown_lat, s.godown_lng, s.godown_map_url, s.godown_address INTO g FROM public.lwb_tracking_settings s WHERE s.id = 1;
  IF (g.godown_lat IS NULL OR g.godown_lng IS NULL) AND g.godown_map_url IS NULL THEN
    RAISE EXCEPTION 'Godown location is not set (Live Tracking > Settings > Godown)';
  END IF;
  SELECT p.full_name, lower(btrim(p.role)) AS role, public.lwb_dial_mob(p.mobile) AS mobile INTO v_me FROM public.user_profiles p WHERE p.id = auth.uid();
  UPDATE public.lwb_vehicle_driver SET loc_sent_at = now(), loc_sent_by = auth.uid() WHERE vehicle_key = d.vehicle_key;
  INSERT INTO public.lwb_dial_calls(kind, ref, to_name, to_mobile, vehicle_no, source, result, note, called_by, called_by_name, called_by_role)
  VALUES ('VEHICLE', d.vehicle_key, d.vehicle_no || coalesce(' · ' || d.driver_name, ''), d.driver_mobile, d.vehicle_no, 'WhatsApp location',
          NULL, '📍 Godown location sent', auth.uid(), v_me.full_name, v_me.role);
  RETURN jsonb_build_object('mobile', d.driver_mobile, 'name', d.driver_name, 'vehicle_no', d.vehicle_no,
    'lat', g.godown_lat, 'lng', g.godown_lng, 'map_url', g.godown_map_url, 'address', g.godown_address, 'my_mobile', v_me.mobile, 'my_name', v_me.full_name);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_loc_sent(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_loc_sent(text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
