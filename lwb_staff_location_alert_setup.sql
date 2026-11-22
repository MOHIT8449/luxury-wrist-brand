-- Staff location gate + Admin alert (22 Nov 2026).
-- 1. When a staff login's location goes OFF / DENIED (phone GPS off or permission
--    blocked), every active Admin gets a bell + phone notification. At most one
--    alert per person every 2 hours, so a flaky phone does not spam Admin.
-- 2. lwb_staff_today(): first and last location time today per person, so Admin
--    can see who started work on time. Admin only.
-- Safe to run again. Does not change orders, stock or accounts.
BEGIN;

ALTER TABLE public.lwb_staff_location ADD COLUMN IF NOT EXISTS off_alert_at timestamptz;

CREATE OR REPLACE FUNCTION public.lwb_staff_location_off_alert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_name text; v_role text; v_was text;
BEGIN
  IF NEW.status NOT IN ('OFF','DENIED') THEN RETURN NEW; END IF;
  -- INSERT ... ON CONFLICT runs the BEFORE INSERT trigger even when the row exists;
  -- then the UPDATE trigger decides, so skip here.
  IF TG_OP = 'INSERT' AND EXISTS (SELECT 1 FROM public.lwb_staff_location x WHERE x.user_id = NEW.user_id) THEN RETURN NEW; END IF;
  v_was := CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END;
  IF v_was IN ('OFF','DENIED') THEN RETURN NEW; END IF;            -- already off, already told
  IF TG_OP = 'UPDATE' AND OLD.off_alert_at > now() - interval '2 hours' THEN RETURN NEW; END IF;
  SELECT coalesce(nullif(btrim(p.full_name),''), 'Staff'), lower(btrim(p.role)) INTO v_name, v_role
  FROM public.user_profiles p WHERE p.id = NEW.user_id;
  IF v_role IS NULL OR v_role = 'admin' THEN RETURN NEW; END IF;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
  SELECT a.id, '📍 Location off: ' || v_name,
         v_name || ' (' || CASE v_role WHEN 'sales' THEN 'Salesman' WHEN 'salesman' THEN 'Salesman' WHEN 'driver' THEN 'Driver'
           WHEN 'warehouse' THEN 'Godown' WHEN 'manager' THEN 'Sales Head' WHEN 'accounts' THEN 'Accounts'
           WHEN 'transport' THEN 'Transport' ELSE initcap(v_role) END || ') ne '
         || CASE NEW.status WHEN 'DENIED' THEN 'location permission block kar di hai' ELSE 'phone ki location band kar di hai' END
         || ' · ' || to_char(now() AT TIME ZONE 'Asia/Kolkata', 'HH12:MI AM') || '. Live Tracking me dekhein.',
         'LOCATION_OFF'
  FROM public.user_profiles a WHERE a.active = true AND lower(btrim(a.role)) = 'admin';
  NEW.off_alert_at := now();
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_staff_location_off_alert() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS lwb_staff_location_off_alert ON public.lwb_staff_location;
CREATE TRIGGER lwb_staff_location_off_alert
  BEFORE INSERT OR UPDATE OF status ON public.lwb_staff_location
  FOR EACH ROW EXECUTE FUNCTION public.lwb_staff_location_off_alert();

-- First / last location today per person (India date), for "came on time?".
CREATE OR REPLACE FUNCTION public.lwb_staff_today()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_from timestamptz := ((now() AT TIME ZONE 'Asia/Kolkata')::date)::timestamp AT TIME ZONE 'Asia/Kolkata';
BEGIN
  IF NOT public.lwb_track_viewer() THEN RAISE EXCEPTION 'Live Tracking is only for Admin'; END IF;
  RETURN coalesce((SELECT jsonb_object_agg(h.user_id, jsonb_build_object('first', h.f, 'last', h.l, 'n', h.n))
    FROM (SELECT user_id, min(at) f, max(at) l, count(*) n FROM public.lwb_location_history
          WHERE at >= v_from GROUP BY user_id) h), '{}'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_staff_today() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_staff_today() TO authenticated;

COMMIT;
