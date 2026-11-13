-- Apply only after review, after the existing live tracking and order-followup setup.
-- Does not change orders, inventory, collections, PODs or accounting entries.
BEGIN;
-- Existing tracking foundation (safe on both previously installed and new tracking databases).


-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_tracking_settings(
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  tracked_roles text[] NOT NULL DEFAULT ARRAY['driver','sales','accounts','warehouse','transport'],
  work_start time NOT NULL DEFAULT '08:00',
  work_end time NOT NULL DEFAULT '21:00',
  godown_lat double precision,
  godown_lng double precision,
  godown_radius_m int NOT NULL DEFAULT 200 CHECK (godown_radius_m BETWEEN 50 AND 2000),
  avg_speed_kmph numeric NOT NULL DEFAULT 25 CHECK (avg_speed_kmph BETWEEN 5 AND 80),
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.lwb_tracking_settings(id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Latest position, one row per person.
CREATE TABLE IF NOT EXISTS public.lwb_staff_location(
  user_id uuid PRIMARY KEY,
  lat double precision,
  lng double precision,
  accuracy_m real,
  speed_kmph real,
  heading real,
  status text NOT NULL DEFAULT 'ON' CHECK (status IN ('ON','DENIED','OFF')),
  updated_at timestamptz NOT NULL DEFAULT now(),
  history_at timestamptz
);

-- Route history (one point a minute, or when moved 40 m). Kept 30 days.
CREATE TABLE IF NOT EXISTS public.lwb_location_history(
  id bigserial PRIMARY KEY,
  user_id uuid NOT NULL,
  lat double precision NOT NULL,
  lng double precision NOT NULL,
  accuracy_m real,
  speed_kmph real,
  at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_location_history_user_at ON public.lwb_location_history(user_id, at);
CREATE INDEX IF NOT EXISTS lwb_location_history_at ON public.lwb_location_history(at);

CREATE TABLE IF NOT EXISTS public.lwb_trip_events(
  id bigserial PRIMARY KEY,
  driver_user_id uuid NOT NULL,
  order_id uuid REFERENCES public.orders(id) ON DELETE CASCADE,
  event text NOT NULL CHECK (event IN ('LEFT_GODOWN','REACHED_PARTY','DELIVERY_REPORT','LEFT_PARTY','BACK_GODOWN')),
  lat double precision,
  lng double precision,
  source text NOT NULL DEFAULT 'AUTO' CHECK (source IN ('AUTO','MANUAL')),
  at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_trip_events_order_event ON public.lwb_trip_events(order_id, event) WHERE order_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS lwb_trip_events_driver_at ON public.lwb_trip_events(driver_user_id, at);

-- Party pin (filled from the driver's GPS at the first delivery).
ALTER TABLE public.lwb_customer_master ADD COLUMN IF NOT EXISTS geo_lat double precision;
ALTER TABLE public.lwb_customer_master ADD COLUMN IF NOT EXISTS geo_lng double precision;
ALTER TABLE public.lwb_customer_master ADD COLUMN IF NOT EXISTS geo_set_at timestamptz;

-- Read / write only through the functions below.
ALTER TABLE public.lwb_tracking_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_staff_location ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_location_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_trip_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_tracking_settings, public.lwb_staff_location, public.lwb_location_history, public.lwb_trip_events FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
-- Straight-line distance in metres (haversine).
CREATE OR REPLACE FUNCTION public.lwb_geo_m(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE SET search_path = '' AS $fn$
  SELECT CASE WHEN lat1 IS NULL OR lng1 IS NULL OR lat2 IS NULL OR lng2 IS NULL THEN NULL ELSE
    2 * 6371000 * asin(least(1, sqrt(
      power(sin(radians(lat2 - lat1) / 2), 2) +
      cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))) END
$fn$;

-- Strict viewer allowlist. Page overrides never grant tracking access.
CREATE OR REPLACE FUNCTION public.lwb_track_viewer()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid()
    AND p.active = true AND lower(btrim(p.role)) = 'admin');
$fn$;

-- A driver's orders on the road now (loaded, not reported yet) and the ones
-- reported in the last 12 hours. Driver = same 10-digit mobile as the assignment.
CREATE OR REPLACE FUNCTION public.lwb_trip_orders(p_driver uuid)
RETURNS TABLE(order_id uuid, party_name text, party_lat double precision, party_lng double precision,
              report_status text, reported_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_mobile text;
BEGIN
  SELECT p.mobile INTO v_mobile FROM public.user_profiles p
  WHERE p.id = p_driver AND p.active = true AND lower(btrim(p.role)) = 'driver';
  IF coalesce(v_mobile,'') = '' THEN RETURN; END IF;
  RETURN QUERY
    SELECT DISTINCT ON (o.id) o.id, o.customer_name::text, cm.geo_lat, cm.geo_lng, d.delivery_status::text, d.reported_at
    FROM public.dispatch_assignments a
    JOIN public.orders o ON o.id = a.order_id
    LEFT JOIN public.lwb_delivery_reports d ON d.order_id = o.id
    LEFT JOIN LATERAL (SELECT c.geo_lat, c.geo_lng FROM public.lwb_customer_master c
                       WHERE lower(btrim(c.customer_name)) = lower(btrim(o.customer_name))
                       ORDER BY c.geo_lat IS NULL, c.customer_code LIMIT 1) cm ON true
    WHERE public.lwb_driver_phone_matches(v_mobile, a.driver_mobile)
      AND ((d.id IS NULL AND lower(o.status) IN ('loaded','invoiced')
            AND coalesce(a.loading_completed_at, o.order_date::timestamptz) > now() - interval '4 days')
        OR d.reported_at > now() - interval '12 hours')
    ORDER BY o.id;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Phone side
-- ---------------------------------------------------------------------------
-- Is this login tracked right now? (phone asks once when a page opens)
CREATE OR REPLACE FUNCTION public.lwb_track_me()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_role text; s public.lwb_tracking_settings%ROWTYPE; v_now time := (now() AT TIME ZONE 'Asia/Kolkata')::time;
BEGIN
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
  SELECT * INTO s FROM public.lwb_tracking_settings WHERE id = 1;
  RETURN jsonb_build_object(
    'tracked', v_role IS NOT NULL AND v_role <> 'admin',
    'in_hours', v_now BETWEEN s.work_start AND s.work_end,
    'work_start', to_char(s.work_start,'HH24:MI'), 'work_end', to_char(s.work_end,'HH24:MI'),
    'role', v_role);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_track_ping(
  p_lat double precision, p_lng double precision,
  p_accuracy real DEFAULT NULL, p_speed_kmph real DEFAULT NULL, p_heading real DEFAULT NULL,
  p_status text DEFAULT 'ON')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE
  v_uid uuid := auth.uid(); v_role text; s public.lwb_tracking_settings%ROWTYPE;
  v_now time := (now() AT TIME ZONE 'Asia/Kolkata')::time;
  v_status text := upper(btrim(coalesce(p_status,'ON')));
  v_old public.lwb_staff_location%ROWTYPE; v_hist boolean;
  v_good boolean; r record; v_ref_lat double precision; v_ref_lng double precision;
  v_events text[] := '{}'; n int;
BEGIN
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = v_uid AND p.active = true;
  SELECT * INTO s FROM public.lwb_tracking_settings WHERE id = 1;
  IF v_role IS NULL OR v_role = 'admin' THEN RETURN jsonb_build_object('tracked', false); END IF;
  IF NOT (v_now BETWEEN s.work_start AND s.work_end) THEN RETURN jsonb_build_object('tracked', true, 'in_hours', false); END IF;
  IF v_status NOT IN ('ON','DENIED','OFF') THEN RAISE EXCEPTION 'Invalid location status'; END IF;

  IF v_status <> 'ON' THEN
    INSERT INTO public.lwb_staff_location(user_id, status, updated_at) VALUES (v_uid, v_status, now())
    ON CONFLICT (user_id) DO UPDATE SET status = excluded.status, updated_at = now();
    RETURN jsonb_build_object('tracked', true, 'in_hours', true, 'saved', true);
  END IF;

  IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'Invalid location';
  END IF;

  SELECT * INTO v_old FROM public.lwb_staff_location WHERE user_id = v_uid;
  v_hist := v_old.history_at IS NULL OR v_old.history_at < now() - interval '55 seconds'
            OR coalesce(public.lwb_geo_m(v_old.lat, v_old.lng, p_lat, p_lng), 1e9) > 40;
  INSERT INTO public.lwb_staff_location(user_id, lat, lng, accuracy_m, speed_kmph, heading, status, updated_at, history_at)
  VALUES (v_uid, p_lat, p_lng, p_accuracy, p_speed_kmph, p_heading, 'ON', now(), CASE WHEN v_hist THEN now() END)
  ON CONFLICT (user_id) DO UPDATE SET lat = excluded.lat, lng = excluded.lng, accuracy_m = excluded.accuracy_m,
    speed_kmph = excluded.speed_kmph, heading = excluded.heading, status = 'ON', updated_at = now(),
    history_at = CASE WHEN v_hist THEN now() ELSE public.lwb_staff_location.history_at END;
  IF v_hist THEN
    INSERT INTO public.lwb_location_history(user_id, lat, lng, accuracy_m, speed_kmph) VALUES (v_uid, p_lat, p_lng, p_accuracy, p_speed_kmph);
  END IF;
  IF random() < 0.01 THEN DELETE FROM public.lwb_location_history WHERE at < now() - interval '30 days'; END IF;

  -- Driver trip steps from GPS (only with a reasonably exact fix).
  v_good := coalesce(p_accuracy, 0) <= 150;
  IF v_role = 'driver' AND v_good THEN
    FOR r IN SELECT * FROM public.lwb_trip_orders(v_uid) LOOP
      IF r.report_status IS NULL THEN
        IF s.godown_lat IS NOT NULL
           AND public.lwb_geo_m(s.godown_lat, s.godown_lng, p_lat, p_lng) > s.godown_radius_m
           AND NOT EXISTS (SELECT 1 FROM public.lwb_trip_events e WHERE e.order_id = r.order_id AND e.event = 'LEFT_GODOWN') THEN
          INSERT INTO public.lwb_trip_events(driver_user_id, order_id, event, lat, lng) VALUES (v_uid, r.order_id, 'LEFT_GODOWN', p_lat, p_lng)
          ON CONFLICT DO NOTHING;
          v_events := array_append(v_events, 'LEFT_GODOWN');
        END IF;
        IF r.party_lat IS NOT NULL AND public.lwb_geo_m(r.party_lat, r.party_lng, p_lat, p_lng) <= 150
           AND NOT EXISTS (SELECT 1 FROM public.lwb_trip_events e WHERE e.order_id = r.order_id AND e.event = 'REACHED_PARTY') THEN
          INSERT INTO public.lwb_trip_events(driver_user_id, order_id, event, lat, lng) VALUES (v_uid, r.order_id, 'REACHED_PARTY', p_lat, p_lng)
          ON CONFLICT DO NOTHING;
          v_events := array_append(v_events, 'REACHED_PARTY');
        END IF;
      ELSIF NOT EXISTS (SELECT 1 FROM public.lwb_trip_events e WHERE e.order_id = r.order_id AND e.event = 'LEFT_PARTY') THEN
        v_ref_lat := r.party_lat; v_ref_lng := r.party_lng;
        IF v_ref_lat IS NULL THEN
          SELECT e.lat, e.lng INTO v_ref_lat, v_ref_lng FROM public.lwb_trip_events e
          WHERE e.order_id = r.order_id AND e.event IN ('DELIVERY_REPORT','REACHED_PARTY') AND e.lat IS NOT NULL
          ORDER BY e.at DESC LIMIT 1;
        END IF;
        IF v_ref_lat IS NOT NULL AND public.lwb_geo_m(v_ref_lat, v_ref_lng, p_lat, p_lng) > 300 THEN
          INSERT INTO public.lwb_trip_events(driver_user_id, order_id, event, lat, lng) VALUES (v_uid, r.order_id, 'LEFT_PARTY', p_lat, p_lng)
          ON CONFLICT DO NOTHING;
          v_events := array_append(v_events, 'LEFT_PARTY');
        END IF;
      END IF;
    END LOOP;

    -- Back at the godown: was out today, nothing left to deliver, inside the godown circle.
    IF s.godown_lat IS NOT NULL
       AND public.lwb_geo_m(s.godown_lat, s.godown_lng, p_lat, p_lng) <= s.godown_radius_m
       AND NOT EXISTS (SELECT 1 FROM public.lwb_trip_orders(v_uid) t WHERE t.report_status IS NULL) THEN
      SELECT count(*) INTO n FROM public.lwb_trip_events e
      WHERE e.driver_user_id = v_uid AND e.event = 'LEFT_GODOWN'
        AND e.at > coalesce((SELECT max(b.at) FROM public.lwb_trip_events b WHERE b.driver_user_id = v_uid AND b.event = 'BACK_GODOWN'), '-infinity')
        AND e.at > now() - interval '18 hours';
      IF n > 0 THEN
        INSERT INTO public.lwb_trip_events(driver_user_id, order_id, event, lat, lng) VALUES (v_uid, NULL, 'BACK_GODOWN', p_lat, p_lng);
        v_events := array_append(v_events, 'BACK_GODOWN');
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('tracked', true, 'in_hours', true, 'saved', true, 'events', to_jsonb(v_events));
END;
$fn$;

-- Buttons on the driver's order card (if GPS missed a step).
-- p_order_id NULL with LEFT_GODOWN = all orders still on the vehicle; BACK_GODOWN = no order.
CREATE OR REPLACE FUNCTION public.lwb_trip_mark(p_order_id uuid, p_event text,
  p_lat double precision DEFAULT NULL, p_lng double precision DEFAULT NULL)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_uid uuid := auth.uid(); v_ev text := upper(btrim(coalesce(p_event,''))); n int := 0; r record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = v_uid AND p.active = true AND lower(btrim(p.role)) = 'driver') THEN
    RAISE EXCEPTION 'Only an active driver login can mark trip steps';
  END IF;
  IF v_ev NOT IN ('LEFT_GODOWN','REACHED_PARTY','LEFT_PARTY','BACK_GODOWN') THEN RAISE EXCEPTION 'Invalid trip step'; END IF;
  IF p_lat IS NOT NULL AND (p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180) THEN RAISE EXCEPTION 'Invalid location'; END IF;
  IF v_ev = 'BACK_GODOWN' THEN
    INSERT INTO public.lwb_trip_events(driver_user_id, order_id, event, lat, lng, source) VALUES (v_uid, NULL, v_ev, p_lat, p_lng, 'MANUAL');
    RETURN 1;
  END IF;
  FOR r IN SELECT * FROM public.lwb_trip_orders(v_uid) t
           WHERE (p_order_id IS NULL AND v_ev = 'LEFT_GODOWN' AND t.report_status IS NULL) OR t.order_id = p_order_id LOOP
    IF v_ev = 'LEFT_PARTY' AND r.report_status IS NULL THEN RAISE EXCEPTION 'Submit the delivery report first, then mark Left party'; END IF;
    INSERT INTO public.lwb_trip_events(driver_user_id, order_id, event, lat, lng, source)
    VALUES (v_uid, r.order_id, v_ev, p_lat, p_lng, 'MANUAL') ON CONFLICT DO NOTHING;
    IF FOUND THEN n := n + 1; END IF;
  END LOOP;
  IF p_order_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_trip_orders(v_uid) t WHERE t.order_id = p_order_id) THEN
    RAISE EXCEPTION 'This order is not on your vehicle';
  END IF;
  RETURN n;
END;
$fn$;

-- Driver's own trip steps for the order cards: [{order_id, events:{EVENT: time}}]
CREATE OR REPLACE FUNCTION public.lwb_driver_trip_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('order_id', t.order_id, 'events',
      coalesce((SELECT jsonb_object_agg(e.event, e.at) FROM public.lwb_trip_events e WHERE e.order_id = t.order_id), '{}'::jsonb)))
    FROM public.lwb_trip_orders(auth.uid()) t), '[]'::jsonb);
END;
$fn$;

-- Delivery report submitted: note the time + place; first delivery pins the party.
CREATE OR REPLACE FUNCTION public.lwb_trip_on_delivery_report()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE l public.lwb_staff_location%ROWTYPE; v_fresh boolean;
BEGIN
  SELECT * INTO l FROM public.lwb_staff_location WHERE user_id = NEW.driver_user_id;
  v_fresh := l.lat IS NOT NULL AND l.status = 'ON' AND l.updated_at > now() - interval '10 minutes';
  INSERT INTO public.lwb_trip_events(driver_user_id, order_id, event, lat, lng)
  VALUES (NEW.driver_user_id, NEW.order_id, 'DELIVERY_REPORT', CASE WHEN v_fresh THEN l.lat END, CASE WHEN v_fresh THEN l.lng END)
  ON CONFLICT DO NOTHING;
  IF v_fresh AND coalesce(l.accuracy_m, 0) <= 100 AND NEW.delivery_status <> 'NOT_DELIVERED' THEN
    UPDATE public.lwb_customer_master c SET geo_lat = l.lat, geo_lng = l.lng, geo_set_at = now()
    FROM public.orders o
    WHERE o.id = NEW.order_id AND lower(btrim(c.customer_name)) = lower(btrim(o.customer_name)) AND c.geo_lat IS NULL;
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW; -- tracking must never block a delivery report
END;
$fn$;
DROP TRIGGER IF EXISTS trg_lwb_trip_delivery_report ON public.lwb_delivery_reports;
CREATE TRIGGER trg_lwb_trip_delivery_report AFTER INSERT ON public.lwb_delivery_reports
  FOR EACH ROW EXECUTE FUNCTION public.lwb_trip_on_delivery_report();

-- ---------------------------------------------------------------------------
-- Office side (Admin / Sales Head / Godown Manager / Accounts)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_live_map()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE s public.lwb_tracking_settings%ROWTYPE; v_people jsonb; v_trips jsonb;
BEGIN
  IF NOT public.lwb_track_viewer() THEN RAISE EXCEPTION 'Live Tracking is only for Admin'; END IF;
  SELECT * INTO s FROM public.lwb_tracking_settings WHERE id = 1;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'user_id', p.id, 'name', coalesce(nullif(btrim(p.full_name),''), 'User'), 'role', lower(btrim(p.role)), 'mobile', p.mobile,
      'lat', l.lat, 'lng', l.lng, 'accuracy', l.accuracy_m, 'speed', l.speed_kmph, 'heading', l.heading,
      'status', l.status, 'updated_at', l.updated_at) ORDER BY lower(btrim(p.role)), p.full_name), '[]'::jsonb)
  INTO v_people
  FROM public.user_profiles p LEFT JOIN public.lwb_staff_location l ON l.user_id = p.id
  WHERE p.active = true AND lower(btrim(p.role)) <> 'admin';

  SELECT coalesce(jsonb_agg(x ORDER BY x->>'driver_name', x->>'order_no'), '[]'::jsonb) INTO v_trips FROM (
    SELECT DISTINCT ON (o.id) jsonb_build_object(
      'order_id', o.id, 'order_no', o.order_no, 'party_name', o.customer_name,
      'party_address', cm.billing_address, 'party_city', cm.city,
      'party_lat', cm.geo_lat, 'party_lng', cm.geo_lng,
      'vehicle_no', a.vehicle_no, 'driver_name', coalesce(dp.full_name, a.driver_name), 'driver_mobile', a.driver_mobile,
      'driver_user_id', dp.id, 'order_status', o.status,
      'report_status', d.delivery_status, 'reported_at', d.reported_at,
      'events', coalesce((SELECT jsonb_object_agg(e.event, e.at) FROM public.lwb_trip_events e WHERE e.order_id = o.id), '{}'::jsonb)
    ) AS x
    FROM public.dispatch_assignments a
    JOIN public.orders o ON o.id = a.order_id
    LEFT JOIN public.lwb_delivery_reports d ON d.order_id = o.id
    LEFT JOIN LATERAL (SELECT c.billing_address, c.city, c.geo_lat, c.geo_lng FROM public.lwb_customer_master c
                       WHERE lower(btrim(c.customer_name)) = lower(btrim(o.customer_name))
                       ORDER BY c.geo_lat IS NULL, c.customer_code LIMIT 1) cm ON true
    LEFT JOIN LATERAL (SELECT p.id, p.full_name FROM public.user_profiles p
                       WHERE p.active = true AND lower(btrim(p.role)) = 'driver'
                         AND public.lwb_driver_phone_matches(p.mobile, a.driver_mobile) LIMIT 1) dp ON true
    WHERE (d.id IS NULL AND lower(o.status) IN ('loaded','invoiced')
           AND coalesce(a.loading_completed_at, o.order_date::timestamptz) > now() - interval '4 days')
       OR (d.reported_at AT TIME ZONE 'Asia/Kolkata')::date = (now() AT TIME ZONE 'Asia/Kolkata')::date
    ORDER BY o.id, a.loading_completed_at DESC NULLS LAST
  ) q;

  RETURN jsonb_build_object(
    'now', now(),
    'settings', jsonb_build_object('tracked_roles', s.tracked_roles,
      'work_start', to_char(s.work_start,'HH24:MI'), 'work_end', to_char(s.work_end,'HH24:MI'),
      'godown_lat', s.godown_lat, 'godown_lng', s.godown_lng, 'godown_radius_m', s.godown_radius_m,
      'avg_speed_kmph', s.avg_speed_kmph),
    'can_edit', EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'admin'),
    'people', v_people, 'trips', v_trips,
    'back_godown', coalesce((SELECT jsonb_object_agg(b.driver_user_id, b.at) FROM (
        SELECT e.driver_user_id, max(e.at) at FROM public.lwb_trip_events e
        WHERE e.event = 'BACK_GODOWN' AND (e.at AT TIME ZONE 'Asia/Kolkata')::date = (now() AT TIME ZONE 'Asia/Kolkata')::date
        GROUP BY e.driver_user_id) b), '{}'::jsonb));
END;
$fn$;

-- One person's route for a day (IST).
CREATE OR REPLACE FUNCTION public.lwb_location_trail(p_user_id uuid, p_day date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_day date := coalesce(p_day, (now() AT TIME ZONE 'Asia/Kolkata')::date);
BEGIN
  IF NOT public.lwb_track_viewer() THEN RAISE EXCEPTION 'Live Tracking is only for Admin'; END IF;
  RETURN jsonb_build_object(
    'points', coalesce((SELECT jsonb_agg(jsonb_build_array(h.lat, h.lng, h.at, h.speed_kmph) ORDER BY h.at)
      FROM public.lwb_location_history h
      WHERE h.user_id = p_user_id AND (h.at AT TIME ZONE 'Asia/Kolkata')::date = v_day), '[]'::jsonb),
    'events', coalesce((SELECT jsonb_agg(jsonb_build_object('event', e.event, 'at', e.at, 'lat', e.lat, 'lng', e.lng,
        'order_no', o.order_no, 'party_name', o.customer_name, 'source', e.source) ORDER BY e.at)
      FROM public.lwb_trip_events e LEFT JOIN public.orders o ON o.id = e.order_id
      WHERE e.driver_user_id = p_user_id AND (e.at AT TIME ZONE 'Asia/Kolkata')::date = v_day), '[]'::jsonb));
END;
$fn$;

-- Settings: Admin only. Keys left out stay as they are.
CREATE OR REPLACE FUNCTION public.lwb_tracking_save_settings(p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_roles text[];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles x WHERE x.id = auth.uid() AND x.active = true AND lower(btrim(x.role)) = 'admin') THEN
    RAISE EXCEPTION 'Only Admin can change tracking settings';
  END IF;
  IF p ? 'tracked_roles' THEN
    SELECT coalesce(array_agg(DISTINCT lower(btrim(r))), '{}') INTO v_roles FROM jsonb_array_elements_text(p->'tracked_roles') r;
    IF EXISTS (SELECT 1 FROM unnest(v_roles) r WHERE r NOT IN ('driver','sales','accounts','warehouse','transport','manager','admin')) THEN
      RAISE EXCEPTION 'Unknown role in tracking list';
    END IF;
  END IF;
  IF p ? 'godown_lat' AND p->>'godown_lat' IS NOT NULL AND ((p->>'godown_lat')::float8 NOT BETWEEN -90 AND 90 OR (p->>'godown_lng')::float8 NOT BETWEEN -180 AND 180) THEN
    RAISE EXCEPTION 'Invalid godown location';
  END IF;
  UPDATE public.lwb_tracking_settings SET
    tracked_roles = CASE WHEN p ? 'tracked_roles' THEN v_roles ELSE tracked_roles END,
    work_start = CASE WHEN p ? 'work_start' THEN (p->>'work_start')::time ELSE work_start END,
    work_end = CASE WHEN p ? 'work_end' THEN (p->>'work_end')::time ELSE work_end END,
    godown_lat = CASE WHEN p ? 'godown_lat' THEN (p->>'godown_lat')::float8 ELSE godown_lat END,
    godown_lng = CASE WHEN p ? 'godown_lat' THEN (p->>'godown_lng')::float8 ELSE godown_lng END,
    godown_radius_m = CASE WHEN p ? 'godown_radius_m' THEN (p->>'godown_radius_m')::int ELSE godown_radius_m END,
    avg_speed_kmph = CASE WHEN p ? 'avg_speed_kmph' THEN (p->>'avg_speed_kmph')::numeric ELSE avg_speed_kmph END,
    updated_by = auth.uid(), updated_at = now()
  WHERE id = 1;
END;
$fn$;

-- Pin (or clear) a party's location by hand: Admin only.
CREATE OR REPLACE FUNCTION public.lwb_set_party_location(p_party text, p_lat double precision, p_lng double precision)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles x WHERE x.id = auth.uid() AND x.active = true AND lower(btrim(x.role)) = 'admin') THEN
    RAISE EXCEPTION 'Only Admin can pin a party';
  END IF;
  IF p_lat IS NOT NULL AND (p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180) THEN RAISE EXCEPTION 'Invalid location'; END IF;
  UPDATE public.lwb_customer_master c SET geo_lat = p_lat, geo_lng = CASE WHEN p_lat IS NULL THEN NULL ELSE p_lng END, geo_set_at = now()
  WHERE lower(btrim(c.customer_name)) = lower(btrim(p_party));
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$fn$;

-- Grants
REVOKE ALL ON FUNCTION public.lwb_track_viewer(), public.lwb_trip_orders(uuid), public.lwb_trip_on_delivery_report() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_track_me(), public.lwb_track_ping(double precision,double precision,real,real,real,text),
  public.lwb_trip_mark(uuid,text,double precision,double precision), public.lwb_driver_trip_status(), public.lwb_live_map(),
  public.lwb_location_trail(uuid,date), public.lwb_tracking_save_settings(jsonb),
  public.lwb_set_party_location(text,double precision,double precision) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_geo_m(double precision,double precision,double precision,double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_track_me(), public.lwb_track_ping(double precision,double precision,real,real,real,text),
  public.lwb_trip_mark(uuid,text,double precision,double precision), public.lwb_driver_trip_status(), public.lwb_live_map(),
  public.lwb_location_trail(uuid,date), public.lwb_tracking_save_settings(jsonb),
  public.lwb_set_party_location(text,double precision,double precision) TO authenticated;


-- Driver background tracking and strict role upgrade.

CREATE OR REPLACE FUNCTION public.lwb_track_viewer()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid()
    AND p.active = true AND lower(btrim(p.role)) = 'admin');
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_live_map()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE s public.lwb_tracking_settings%ROWTYPE; v_people jsonb; v_trips jsonb;
BEGIN
  IF NOT public.lwb_track_viewer() THEN RAISE EXCEPTION 'Live Tracking is only for Admin'; END IF;
  SELECT * INTO s FROM public.lwb_tracking_settings WHERE id = 1;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'user_id', p.id, 'name', coalesce(nullif(btrim(p.full_name),''), 'User'), 'role', lower(btrim(p.role)), 'mobile', p.mobile,
      'lat', l.lat, 'lng', l.lng, 'accuracy', l.accuracy_m, 'speed', l.speed_kmph, 'heading', l.heading,
      'status', l.status, 'updated_at', l.updated_at,
      'agreed_at', (SELECT c.agreed_at FROM public.lwb_gps_consent c WHERE c.user_id = p.id)) ORDER BY lower(btrim(p.role)), p.full_name), '[]'::jsonb)
  INTO v_people
  FROM public.user_profiles p LEFT JOIN public.lwb_staff_location l ON l.user_id = p.id
  WHERE p.active = true AND lower(btrim(p.role)) <> 'admin';

  SELECT coalesce(jsonb_agg(x ORDER BY x->>'driver_name', x->>'order_no'), '[]'::jsonb) INTO v_trips FROM (
    SELECT DISTINCT ON (o.id) jsonb_build_object(
      'order_id', o.id, 'order_no', o.order_no, 'party_name', o.customer_name,
      'party_address', cm.billing_address, 'party_city', cm.city,
      'party_lat', cm.geo_lat, 'party_lng', cm.geo_lng,
      'vehicle_no', a.vehicle_no, 'driver_name', coalesce(dp.full_name, a.driver_name), 'driver_mobile', a.driver_mobile,
      'driver_user_id', dp.id, 'order_status', o.status,
      'report_status', d.delivery_status, 'reported_at', d.reported_at,
      'events', coalesce((SELECT jsonb_object_agg(e.event, e.at) FROM public.lwb_trip_events e WHERE e.order_id = o.id), '{}'::jsonb)
    ) AS x
    FROM public.dispatch_assignments a
    JOIN public.orders o ON o.id = a.order_id
    LEFT JOIN public.lwb_delivery_reports d ON d.order_id = o.id
    LEFT JOIN LATERAL (SELECT c.billing_address, c.city, c.geo_lat, c.geo_lng FROM public.lwb_customer_master c
                       WHERE lower(btrim(c.customer_name)) = lower(btrim(o.customer_name))
                       ORDER BY c.geo_lat IS NULL, c.customer_code LIMIT 1) cm ON true
    LEFT JOIN LATERAL (SELECT p.id, p.full_name FROM public.user_profiles p
                       WHERE p.active = true AND lower(btrim(p.role)) = 'driver'
                         AND public.lwb_driver_phone_matches(p.mobile, a.driver_mobile) LIMIT 1) dp ON true
    WHERE (d.id IS NULL AND lower(o.status) IN ('loaded','invoiced')
           AND coalesce(a.loading_completed_at, o.order_date::timestamptz) > now() - interval '4 days')
       OR (d.reported_at AT TIME ZONE 'Asia/Kolkata')::date = (now() AT TIME ZONE 'Asia/Kolkata')::date
    ORDER BY o.id, a.loading_completed_at DESC NULLS LAST
  ) q;

  RETURN jsonb_build_object(
    'now', now(),
    'settings', jsonb_build_object('tracked_roles', s.tracked_roles,
      'work_start', to_char(s.work_start,'HH24:MI'), 'work_end', to_char(s.work_end,'HH24:MI'),
      'godown_lat', s.godown_lat, 'godown_lng', s.godown_lng, 'godown_radius_m', s.godown_radius_m,
      'avg_speed_kmph', s.avg_speed_kmph),
    'can_edit', EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'admin'),
    'people', v_people, 'trips', v_trips,
    'back_godown', coalesce((SELECT jsonb_object_agg(b.driver_user_id, b.at) FROM (
        SELECT e.driver_user_id, max(e.at) at FROM public.lwb_trip_events e
        WHERE e.event = 'BACK_GODOWN' AND (e.at AT TIME ZONE 'Asia/Kolkata')::date = (now() AT TIME ZONE 'Asia/Kolkata')::date
        GROUP BY e.driver_user_id) b), '{}'::jsonb));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_location_trail(p_user_id uuid, p_day date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_day date := coalesce(p_day, (now() AT TIME ZONE 'Asia/Kolkata')::date);
BEGIN
  IF NOT public.lwb_track_viewer() THEN RAISE EXCEPTION 'Live Tracking is only for Admin'; END IF;
  RETURN jsonb_build_object(
    'points', coalesce((SELECT jsonb_agg(jsonb_build_array(h.lat, h.lng, h.at, h.speed_kmph) ORDER BY h.at)
      FROM public.lwb_location_history h
      WHERE h.user_id = p_user_id AND (h.at AT TIME ZONE 'Asia/Kolkata')::date = v_day), '[]'::jsonb),
    'events', coalesce((SELECT jsonb_agg(jsonb_build_object('event', e.event, 'at', e.at, 'lat', e.lat, 'lng', e.lng,
        'order_no', o.order_no, 'party_name', o.customer_name, 'source', e.source) ORDER BY e.at)
      FROM public.lwb_trip_events e LEFT JOIN public.orders o ON o.id = e.order_id
      WHERE e.driver_user_id = p_user_id AND (e.at AT TIME ZONE 'Asia/Kolkata')::date = v_day), '[]'::jsonb));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_set_party_location(p_party text, p_lat double precision, p_lng double precision)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE n int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles x WHERE x.id = auth.uid() AND x.active = true AND lower(btrim(x.role)) = 'admin') THEN
    RAISE EXCEPTION 'Only Admin can pin a party';
  END IF;
  IF p_lat IS NOT NULL AND (p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180) THEN RAISE EXCEPTION 'Invalid location'; END IF;
  UPDATE public.lwb_customer_master c SET geo_lat = p_lat, geo_lng = CASE WHEN p_lat IS NULL THEN NULL ELSE p_lng END, geo_set_at = now()
  WHERE lower(btrim(c.customer_name)) = lower(btrim(p_party));
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_track_viewer() FROM PUBLIC, anon, authenticated;
-- Native endpoint: every active login except Admin sends GPS. Role changes apply immediately.
CREATE OR REPLACE FUNCTION public.lwb_driver_track_ping(
 p_lat double precision, p_lng double precision, p_accuracy real DEFAULT NULL,
 p_speed_kmph real DEFAULT NULL, p_heading real DEFAULT NULL, p_status text DEFAULT 'ON')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.user_profiles WHERE id=auth.uid() AND active=true AND lower(btrim(role))<>'admin')
 THEN RETURN jsonb_build_object('tracked',false); END IF;
 RETURN public.lwb_track_ping(p_lat,p_lng,p_accuracy,p_speed_kmph,p_heading,p_status);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_driver_track_ping(double precision,double precision,real,real,real,text) FROM PUBLIC, anon;

-- One-time "I agree" on the phone: time saved so Admin can see who agreed.
CREATE TABLE IF NOT EXISTS public.lwb_gps_consent(
  user_id uuid PRIMARY KEY,
  agreed_at timestamptz NOT NULL DEFAULT now(),
  device text
);
ALTER TABLE public.lwb_gps_consent ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_gps_consent FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.lwb_gps_agree(p_device text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.user_profiles WHERE id=auth.uid() AND active=true) THEN RAISE EXCEPTION 'Active login required'; END IF;
 INSERT INTO public.lwb_gps_consent(user_id, agreed_at, device) VALUES (auth.uid(), now(), left(p_device, 120))
 ON CONFLICT (user_id) DO UPDATE SET agreed_at = now(), device = excluded.device;
 RETURN jsonb_build_object('saved', true);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_gps_agree(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_gps_agree(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_driver_track_ping(double precision,double precision,real,real,real,text) TO authenticated;

-- Block every order-related notification for sales, including legacy unread rows.
CREATE OR REPLACE FUNCTION public.lwb_sales_order_alert(p_order uuid, p_type text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $fn$
 SELECT p_order IS NOT NULL OR upper(coalesce(p_type,'')) ~ '^(CC_)?(ORDER_|PO_|TALLY_|VEHICLE_|LOADING_|DELIVERY_|SALES_RETURN|LIVE_|GPS_|TRACK)';
$fn$;
CREATE OR REPLACE FUNCTION public.lwb_suppress_sales_order_alert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
 IF public.lwb_sales_order_alert(NEW.order_id, NEW.notification_type) AND EXISTS (
   SELECT 1 FROM public.user_profiles p WHERE p.id=NEW.user_id AND lower(btrim(p.role)) IN ('sales','salesman')) THEN RETURN NULL; END IF;
 RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_suppress_sales_order_alert() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_suppress_sales_order_alert ON public.erp_notifications;
CREATE TRIGGER trg_lwb_suppress_sales_order_alert BEFORE INSERT OR UPDATE ON public.erp_notifications
 FOR EACH ROW EXECUTE FUNCTION public.lwb_suppress_sales_order_alert();
CREATE OR REPLACE FUNCTION public.lwb_no_sales_updates()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
 SELECT EXISTS(SELECT 1 FROM public.user_profiles WHERE id=auth.uid() AND active=true AND lower(btrim(role)) NOT IN ('sales','salesman'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_no_sales_updates() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_no_sales_updates() TO authenticated;
ALTER TABLE public.erp_notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_sales_no_order_alerts ON public.erp_notifications;
CREATE POLICY lwb_sales_no_order_alerts ON public.erp_notifications AS RESTRICTIVE FOR SELECT TO authenticated
 USING (public.lwb_no_sales_updates() OR NOT public.lwb_sales_order_alert(order_id, notification_type));
-- Restrictive policies cannot be bypassed by another permissive table policy.
ALTER TABLE public.dispatch_assignments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_sales_no_dispatch_updates ON public.dispatch_assignments;
CREATE POLICY lwb_sales_no_dispatch_updates ON public.dispatch_assignments AS RESTRICTIVE FOR SELECT TO authenticated USING(public.lwb_no_sales_updates());
ALTER TABLE public.lwb_delivery_reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_sales_no_delivery_updates ON public.lwb_delivery_reports;
CREATE POLICY lwb_sales_no_delivery_updates ON public.lwb_delivery_reports AS RESTRICTIVE FOR SELECT TO authenticated USING(public.lwb_no_sales_updates());
CREATE OR REPLACE FUNCTION public.lwb_my_orders(p_days integer DEFAULT 45)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_field boolean := public.lwb_is_field_salesman();
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required.'; END IF;
  IF EXISTS(SELECT 1 FROM public.user_profiles WHERE id=auth.uid() AND lower(btrim(role)) IN ('sales','salesman')) THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(x.j ORDER BY x.d DESC)
    FROM (
      SELECT coalesce(o.order_date, o.created_at) AS d,
        jsonb_build_object(
          'id', o.id, 'order_no', o.order_no, 'order_date', coalesce(o.order_date, o.created_at),
          'customer_name', o.customer_name, 'status', o.status,
          'total_qty', o.total_qty, 'total_amount', o.total_amount,
          'mine', o.created_by = auth.uid(),
          'can_edit', o.created_by = auth.uid() AND public.lwb_order_pending(o.status),
          'cancel_reason', o.cancel_reason, 'cancelled_at', o.cancelled_at,
          'driver_name', a.driver_name, 'vehicle_no', a.vehicle_no,
          'delivery_status', r.delivery_status, 'delivered_at', r.reported_at,
          'received_by', r.received_by, 'delivery_note', r.delivery_note,
          'items', (SELECT coalesce(jsonb_agg(jsonb_build_object(
              'id', i.id, 'sku_name', i.sku_name, 'ordered_qty', i.ordered_qty,
              'approved_qty', i.approved_qty, 'loaded_qty', i.loaded_qty, 'rate', i.rate,
              'entry_uom', i.entry_uom, 'ordered_pallet_qty', i.ordered_pallet_qty) ORDER BY i.id), '[]'::jsonb)
            FROM public.order_items i WHERE i.order_id = o.id)
        ) AS j
      FROM public.orders o
      LEFT JOIN LATERAL (SELECT da.driver_name, da.vehicle_no FROM public.dispatch_assignments da
        WHERE da.order_id = o.id ORDER BY da.id DESC LIMIT 1) a ON true
      LEFT JOIN public.lwb_delivery_reports r ON r.order_id = o.id
      WHERE coalesce(o.order_date, o.created_at) >= now() - make_interval(days => greatest(1, least(coalesce(p_days,45), 400)))
        AND (o.created_by = auth.uid()
             OR (v_field AND upper(btrim(coalesce(o.customer_name,''))) IN (SELECT public.lwb_my_party_names())))
    ) x
  ), '[]'::jsonb);
END;
$fn$;
COMMIT;
NOTIFY pgrst, 'reload schema';
