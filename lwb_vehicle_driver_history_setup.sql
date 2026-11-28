-- LUXURY WRIST BRAND ERP — TRUCK DRIVERS: every driver of a vehicle + transport short name + Gmail format (28 Nov 2026)
--
-- Mohit asked (28 Nov 2026): a purchase truck mostly comes with the same driver, but sometimes the same vehicle comes with
-- a new driver. Keep every driver's number (old ones too) so whoever calls is saved in the phone. The phone / Gmail name
-- must start with the vehicle no. (easy search), then the driver name, then the transport short name:
--      GJ05 BX 4471 RAMESH VIKAS          (Vikas Road Lines)      GJ16 AU 1234 SURESH RK  (R K Trailer)
--      no driver name: GJ05 BX 4471 DRIVER VIKAS                  no transport: GJ05 BX 4471 RAMESH
--
--   lwb_transport_short(name)      'VIKAS ROAD LINES' -> 'VIKAS', 'R K TRAILER' -> 'RK', 'SHREE GANESH ROADWAYS' -> 'GANESH'
--   lwb_vehicle_driver             + transport_name (the vehicle's transport, kept when not given again)
--   lwb_vehicle_driver_hist        one row per vehicle + driver mobile: name, transport, first / last trip, trips
--   lwb_vehicle_driver_put(...)    internal: saves the current driver (when newer) + the history row; marks Gmail sync due
--   lwb_vehicle_driver_save(4 args)   same as before, now also keeps history (Godown Manager may save too)
--   lwb_vehicle_driver_save(5 args)   + p_transport (Dial Book "Gaadi driver" popup)
--   Goods Inward trigger           every saved purchase bill with vehicle no. + driver mobile goes in by itself
--                                  (old bills are taken in once by this file)
--   lwb_vehicle_loc_sent(text)     + Godown Manager (same as lwb_dial_book_setup.sql otherwise)
--   lwb_vehicle_drivers(text[])    + transport, short, old_drivers (masked list for Purchase List / ECRS rows)
--   lwb_dial_all()                 VEHICLE rows: current driver of every vehicle (no 30-day limit any more) + every old
--                                  driver (ref 'VEHICLEKEY:mobile', tag 'Old driver'); save_as in the format above.
--                                  NOTE: this file now owns lwb_dial_all (copy of lwb_dial_services_setup.sql + this change);
--                                  if lwb_dial_services_setup.sql is run again, run this file after it.
--   Gmail quick sync               a new / changed driver or Services number marks the sync due; pg_cron checks every
--                                  10 minutes and syncs only when something changed (nightly 2 AM sync stays).
--
-- Safe to run again. Nothing is dropped or deleted.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Transport short name
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_transport_short(p text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $fn$
DECLARE w text[]; k text[] := '{}'; x text; v text := '';
BEGIN
  w := regexp_split_to_array(btrim(regexp_replace(regexp_replace(upper(coalesce(p, '')), '^\s*M\s*/\s*S\M\.?', ''), '[^A-Z0-9 ]+', ' ', 'g')), '\s+');
  IF w IS NULL OR coalesce(w[1], '') = '' THEN RETURN NULL; END IF;
  FOREACH x IN ARRAY w LOOP
    IF x <> '' AND x NOT IN ('ROAD','ROADS','LINE','LINES','ROADLINE','ROADLINES','ROADWAY','ROADWAYS','TRANSPORT','TRANSPORTS',
        'TRANSPORTER','TRANSPORTERS','TRANSPORTATION','TRAILER','TRAILERS','TRAILOR','TRAILORS','TRAILLER','CARRIER','CARRIERS',
        'CARGO','CARGOS','LOGISTIC','LOGISTICS','MOVERS','PACKERS','FREIGHT','FREIGHTS','SERVICE','SERVICES','CO','COMPANY',
        'PVT','PRIVATE','LTD','LIMITED','LLP','AND','THE','GOODS','TRUCK','TRUCKS','TEMPO','FLEET','EXPRESS',
        'ENTERPRISE','ENTERPRISES','AGENCY','AGENCIES','CORPORATION','CORP','INDIA','SHREE','SHRI','SRI','SHRE','NEW','JAY','JAI') THEN
      k := k || x;
    END IF;
  END LOOP;
  IF cardinality(k) = 0 THEN k := ARRAY[w[1]]; END IF;
  -- single letters next to each other become one word: R K -> RK
  w := '{}';
  FOREACH x IN ARRAY k LOOP
    IF length(x) = 1 AND cardinality(w) > 0 AND w[cardinality(w)] ~ '^#' THEN w[cardinality(w)] := w[cardinality(w)] || x;
    ELSIF length(x) = 1 THEN w := w || ('#' || x);
    ELSE w := w || x; END IF;
  END LOOP;
  -- first word; a short word (MAA, AB) takes the next one too (MAA AMBE). Joined letters (RK) stay alone.
  IF w[1] ~ '^#' THEN v := substr(w[1], 2);
  ELSIF length(w[1]) <= 3 AND cardinality(w) > 1 THEN v := w[1] || ' ' || replace(w[2], '#', '');
  ELSE v := w[1]; END IF;
  RETURN nullif(left(btrim(v), 14), '');
END $fn$;
GRANT EXECUTE ON FUNCTION public.lwb_transport_short(text) TO authenticated;

-- Phone / Gmail name of a truck driver.
CREATE OR REPLACE FUNCTION public.lwb_vehicle_save_as(p_vehicle text, p_name text, p_transport text)
RETURNS text LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT upper(concat_ws(' ', coalesce(public.lwb_vehicle_fmt(p_vehicle), p_vehicle),
           coalesce(nullif(btrim(coalesce(p_name, '')), ''), 'DRIVER'), public.lwb_transport_short(p_transport)))
$$;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_save_as(text, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_vehicle_driver ADD COLUMN IF NOT EXISTS transport_name text;

CREATE TABLE IF NOT EXISTS public.lwb_vehicle_driver_hist (
  vehicle_key text NOT NULL,
  driver_mobile text NOT NULL CHECK (driver_mobile ~ '^[6-9][0-9]{9}$'),
  vehicle_no text NOT NULL,
  driver_name text CHECK (driver_name IS NULL OR length(driver_name) <= 80),
  transport_name text CHECK (transport_name IS NULL OR length(transport_name) <= 150),
  first_at timestamptz NOT NULL DEFAULT now(),
  last_at timestamptz NOT NULL DEFAULT now(),
  trips integer NOT NULL DEFAULT 1,
  last_source text,
  updated_by uuid,
  PRIMARY KEY (vehicle_key, driver_mobile)
);
CREATE INDEX IF NOT EXISTS lwb_vehicle_driver_hist_mob_idx ON public.lwb_vehicle_driver_hist(driver_mobile, last_at DESC);
ALTER TABLE public.lwb_vehicle_driver_hist ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_vehicle_driver_hist FROM PUBLIC, anon, authenticated;

ALTER TABLE public.lwb_gsync_config ADD COLUMN IF NOT EXISTS dirty_at timestamptz;

-- ---------------------------------------------------------------------------
-- 3. Gmail quick sync: mark due + 10-minute check
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_gsync_dirty()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  UPDATE public.lwb_gsync_config SET dirty_at = now() WHERE id = 1 AND refresh_token IS NOT NULL;
  RETURN NULL;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_gsync_dirty() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_lwb_gsync_dirty ON public.lwb_vehicle_driver_hist;
CREATE TRIGGER trg_lwb_gsync_dirty AFTER INSERT OR UPDATE OF driver_name, transport_name, vehicle_no OR DELETE
  ON public.lwb_vehicle_driver_hist FOR EACH STATEMENT EXECUTE FUNCTION public.lwb_gsync_dirty();
DROP TRIGGER IF EXISTS trg_lwb_gsync_dirty ON public.lwb_vehicle_driver;
CREATE TRIGGER trg_lwb_gsync_dirty AFTER INSERT OR UPDATE OF driver_mobile, driver_name, transport_name OR DELETE
  ON public.lwb_vehicle_driver FOR EACH STATEMENT EXECUTE FUNCTION public.lwb_gsync_dirty();
DROP TRIGGER IF EXISTS trg_lwb_gsync_dirty ON public.lwb_dial_services;
CREATE TRIGGER trg_lwb_gsync_dirty AFTER INSERT OR UPDATE OR DELETE
  ON public.lwb_dial_services FOR EACH STATEMENT EXECUTE FUNCTION public.lwb_gsync_dirty();

CREATE OR REPLACE FUNCTION public.lwb_gsync_tick(p_by text)
RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE c public.lwb_gsync_config;
BEGIN
  SELECT * INTO c FROM public.lwb_gsync_config WHERE id = 1;
  IF c.refresh_token IS NULL OR to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') IS NULL THEN RETURN false; END IF;
  IF p_by = 'quick' AND (c.dirty_at IS NULL OR c.dirty_at <= coalesce(c.last_sync_at, '-infinity'::timestamptz)
                         OR coalesce(c.running_until, '-infinity'::timestamptz) > now()) THEN
    RETURN false;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := $3, params := ''{}''::jsonb, headers := $2, timeout_milliseconds := 150000)'
    USING c.project_url || '/functions/v1/lwb-google-contacts',
          jsonb_build_object('Content-Type', 'application/json', 'x-lwb-gsync-secret', c.webhook_secret),
          jsonb_build_object('action', 'sync', 'by', coalesce(p_by, 'nightly'));
  RETURN true;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_gsync_tick(text) FROM PUBLIC, anon, authenticated;

DO $c$ BEGIN
  IF to_regclass('cron.job') IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'lwb_gmail_sync_quick') THEN
      PERFORM cron.schedule('lwb_gmail_sync_quick', '*/10 * * * *', 'SELECT public.lwb_gsync_tick(''quick'')');
    END IF;
  END IF;
END $c$;

-- ---------------------------------------------------------------------------
-- 4. Save a driver (current + history)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_vehicle_driver_put(p_vehicle text, p_mobile text, p_name text, p_transport text,
  p_ecrs bigint, p_at timestamptz, p_source text)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_no text := public.lwb_vehicle_fmt(p_vehicle); v_mob text := public.lwb_dial_mob(p_mobile); v_key text;
        v_name text := left(nullif(btrim(coalesce(p_name, '')), ''), 80);
        v_tr text := left(nullif(regexp_replace(btrim(coalesce(p_transport, '')), '\s+', ' ', 'g'), ''), 150);
        v_at timestamptz := coalesce(p_at, now()); d public.lwb_vehicle_driver; h public.lwb_vehicle_driver_hist; v_cur boolean;
BEGIN
  IF v_no IS NULL OR v_mob IS NULL THEN RETURN NULL; END IF;
  v_key := replace(v_no, ' ', '');
  SELECT * INTO h FROM public.lwb_vehicle_driver_hist WHERE vehicle_key = v_key AND driver_mobile = v_mob;
  SELECT * INTO d FROM public.lwb_vehicle_driver WHERE vehicle_key = v_key;
  -- name: the one given, else what this driver had before
  v_name := coalesce(v_name, h.driver_name, CASE WHEN d.driver_mobile = v_mob THEN d.driver_name END);
  -- transport belongs to the vehicle: the one given, else this driver's, else the vehicle's
  v_tr := coalesce(v_tr, h.transport_name, d.transport_name);
  INSERT INTO public.lwb_vehicle_driver_hist AS x (vehicle_key, driver_mobile, vehicle_no, driver_name, transport_name, first_at, last_at, trips, last_source, updated_by)
  VALUES (v_key, v_mob, v_no, v_name, v_tr, v_at, v_at, 1, left(p_source, 40), auth.uid())
  ON CONFLICT (vehicle_key, driver_mobile) DO UPDATE SET
    vehicle_no = EXCLUDED.vehicle_no,
    driver_name = coalesce(EXCLUDED.driver_name, x.driver_name),
    transport_name = coalesce(EXCLUDED.transport_name, x.transport_name),
    first_at = least(x.first_at, EXCLUDED.first_at),
    trips = x.trips + CASE WHEN EXCLUDED.last_at > x.last_at + interval '12 hours' THEN 1 ELSE 0 END,  -- same trip (dispatch + inward) once
    last_at = greatest(x.last_at, EXCLUDED.last_at),
    last_source = CASE WHEN EXCLUDED.last_at >= x.last_at THEN EXCLUDED.last_source ELSE x.last_source END,
    updated_by = coalesce(EXCLUDED.updated_by, x.updated_by);
  v_cur := d.vehicle_key IS NULL OR v_at >= d.updated_at - interval '1 minute';
  IF v_cur THEN
    INSERT INTO public.lwb_vehicle_driver AS o (vehicle_key, vehicle_no, driver_mobile, driver_name, transport_name, ecrs_truck_id, updated_by, updated_at)
    VALUES (v_key, v_no, v_mob, v_name, v_tr, p_ecrs, auth.uid(), v_at)
    ON CONFLICT (vehicle_key) DO UPDATE SET
      vehicle_no = EXCLUDED.vehicle_no, driver_mobile = EXCLUDED.driver_mobile, driver_name = EXCLUDED.driver_name,
      transport_name = coalesce(EXCLUDED.transport_name, o.transport_name),
      ecrs_truck_id = coalesce(EXCLUDED.ecrs_truck_id, o.ecrs_truck_id),
      loc_sent_at = CASE WHEN o.driver_mobile = EXCLUDED.driver_mobile AND o.updated_at > now() - interval '3 days' THEN o.loc_sent_at END,
      loc_sent_by = CASE WHEN o.driver_mobile = EXCLUDED.driver_mobile AND o.updated_at > now() - interval '3 days' THEN o.loc_sent_by END,
      updated_by = coalesce(EXCLUDED.updated_by, o.updated_by), updated_at = greatest(o.updated_at, EXCLUDED.updated_at);
  ELSIF v_tr IS NOT NULL AND d.transport_name IS NULL THEN
    UPDATE public.lwb_vehicle_driver SET transport_name = v_tr WHERE vehicle_key = v_key;
  END IF;
  IF p_ecrs IS NOT NULL THEN
    UPDATE public.lwb_ecrs_trucks SET vehicle_no = v_no, updated_at = now() WHERE id = p_ecrs AND nullif(btrim(coalesce(vehicle_no, '')), '') IS NULL;
  END IF;
  RETURN jsonb_build_object('vehicle_key', v_key, 'vehicle_no', v_no, 'masked', public.lwb_dial_mask(v_mob), 'name', v_name,
    'transport', v_tr, 'save_as', public.lwb_vehicle_save_as(v_no, v_name, v_tr), 'current', v_cur,
    'new_driver', h.vehicle_key IS NULL, 'changed', d.vehicle_key IS NOT NULL AND d.driver_mobile <> v_mob);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_driver_put(text, text, text, text, bigint, timestamptz, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_vehicle_driver_save(p_vehicle text, p_mobile text, p_name text, p_ecrs bigint, p_transport text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  IF coalesce(public.lwb_dial_role(), '') NOT IN ('admin','manager','sales','accounts','warehouse') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Salesman, Accounts or Godown Manager can save a vehicle driver';
  END IF;
  IF public.lwb_vehicle_fmt(p_vehicle) IS NULL THEN RAISE EXCEPTION 'Vehicle no. is not right. Example: GJ05 BX 4471'; END IF;
  IF public.lwb_dial_mob(p_mobile) IS NULL THEN RAISE EXCEPTION 'Driver mobile: enter a 10-digit mobile'; END IF;
  IF p_ecrs IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_ecrs_trucks t WHERE t.id = p_ecrs) THEN
    RAISE EXCEPTION 'ECRS order not found';
  END IF;
  RETURN public.lwb_vehicle_driver_put(p_vehicle, p_mobile, p_name, p_transport, p_ecrs, now(), 'Dial Book');
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_driver_save(text, text, text, bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_driver_save(text, text, text, bigint, text) TO authenticated;

-- Old 4-argument save (ECRS on the way, older pages): same, transport kept as it was.
CREATE OR REPLACE FUNCTION public.lwb_vehicle_driver_save(p_vehicle text, p_mobile text, p_name text DEFAULT NULL, p_ecrs bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  SELECT public.lwb_vehicle_driver_save(p_vehicle, p_mobile, p_name, p_ecrs, NULL::text)
$$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_driver_save(text, text, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_driver_save(text, text, text, bigint) TO authenticated;

-- "📍 Send location": the Godown Manager may send it too (driver standing at the gate).
CREATE OR REPLACE FUNCTION public.lwb_vehicle_loc_sent(p_vehicle text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE d public.lwb_vehicle_driver; g record; v_me record;
BEGIN
  IF coalesce(public.lwb_dial_role(), '') NOT IN ('admin','manager','sales','accounts','warehouse') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Salesman, Accounts or Godown Manager can send the godown location';
  END IF;
  SELECT * INTO d FROM public.lwb_vehicle_driver WHERE vehicle_key = public.lwb_vehicle_key(p_vehicle);
  IF NOT FOUND THEN RAISE EXCEPTION 'Save the vehicle driver first'; END IF;
  SELECT s.godown_lat, s.godown_lng INTO g FROM public.lwb_tracking_settings s WHERE s.id = 1;
  IF g.godown_lat IS NULL OR g.godown_lng IS NULL THEN
    RAISE EXCEPTION 'Godown location is not set (Live Tracking > Settings > Godown)';
  END IF;
  SELECT p.full_name, lower(btrim(p.role)) AS role, public.lwb_dial_mob(p.mobile) AS mobile INTO v_me FROM public.user_profiles p WHERE p.id = auth.uid();
  UPDATE public.lwb_vehicle_driver SET loc_sent_at = now(), loc_sent_by = auth.uid() WHERE vehicle_key = d.vehicle_key;
  INSERT INTO public.lwb_dial_calls(kind, ref, to_name, to_mobile, vehicle_no, source, result, note, called_by, called_by_name, called_by_role)
  VALUES ('VEHICLE', d.vehicle_key, d.vehicle_no || coalesce(' · ' || d.driver_name, ''), d.driver_mobile, d.vehicle_no, 'WhatsApp location',
          NULL, '📍 Godown location sent', auth.uid(), v_me.full_name, v_me.role);
  RETURN jsonb_build_object('mobile', d.driver_mobile, 'name', d.driver_name, 'vehicle_no', d.vehicle_no,
    'lat', g.godown_lat, 'lng', g.godown_lng, 'my_mobile', v_me.mobile, 'my_name', v_me.full_name);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_loc_sent(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_loc_sent(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Goods Inward: every purchase bill with vehicle + driver mobile (never stops the bill from saving)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_goods_inward_driver()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE j jsonb := to_jsonb(NEW);
BEGIN
  BEGIN
    PERFORM public.lwb_vehicle_driver_put(j->>'vehicle_no', j->>'driver_mobile', j->>'driver_name', j->>'transport_name', NULL,
      CASE WHEN TG_OP = 'INSERT' THEN now() ELSE coalesce((j->>'created_at')::timestamptz, now()) END, 'Goods Inward');
  EXCEPTION WHEN others THEN
    RAISE WARNING 'lwb_goods_inward_driver: %', SQLERRM;
  END;
  RETURN NULL;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_goods_inward_driver() FROM PUBLIC, anon, authenticated;

-- Drivers already saved before this file (Dial Book / ECRS): one history row each.
INSERT INTO public.lwb_vehicle_driver_hist (vehicle_key, driver_mobile, vehicle_no, driver_name, transport_name, first_at, last_at, trips, last_source, updated_by)
SELECT d.vehicle_key, d.driver_mobile, d.vehicle_no, d.driver_name, d.transport_name, d.created_at, d.updated_at, 1, 'Dial Book', d.updated_by
  FROM public.lwb_vehicle_driver d
ON CONFLICT (vehicle_key, driver_mobile) DO NOTHING;

DO $gi$
DECLARE r record; v_n integer := 0;
BEGIN
  IF to_regclass('public.lwb_goods_inward') IS NULL THEN RETURN; END IF;
  EXECUTE 'DROP TRIGGER IF EXISTS trg_lwb_goods_inward_driver ON public.lwb_goods_inward';
  EXECUTE 'CREATE TRIGGER trg_lwb_goods_inward_driver AFTER INSERT OR UPDATE ON public.lwb_goods_inward
           FOR EACH ROW EXECUTE FUNCTION public.lwb_goods_inward_driver()';
  -- Old bills, oldest first (only the newest becomes the current driver of a vehicle). Running again adds no trips.
  FOR r IN EXECUTE $q$
      SELECT j, coalesce((j->>'created_at')::timestamptz, (j->>'received_date')::date::timestamptz, now() - interval '365 days') AS at
        FROM (SELECT to_jsonb(g) AS j FROM public.lwb_goods_inward g) s
       WHERE public.lwb_vehicle_fmt(j->>'vehicle_no') IS NOT NULL AND public.lwb_dial_mob(j->>'driver_mobile') IS NOT NULL
       ORDER BY 2 $q$ LOOP
    PERFORM public.lwb_vehicle_driver_put(r.j->>'vehicle_no', r.j->>'driver_mobile', r.j->>'driver_name', r.j->>'transport_name', NULL, r.at, 'Goods Inward');
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'Goods Inward drivers taken in: %', v_n;
END $gi$;


-- ---------------------------------------------------------------------------
-- 6. Masked list for Purchase List / ECRS / Goods Inward rows
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_vehicle_drivers(p_vehicles text[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  IF coalesce(public.lwb_dial_role(), '') NOT IN ('admin','manager','accounts','sales','warehouse','cashier','transport') THEN
    RETURN '[]'::jsonb;
  END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('vehicle_key', d.vehicle_key, 'vehicle_no', d.vehicle_no,
            'name', d.driver_name, 'masked', public.lwb_dial_mask(d.driver_mobile), 'ecrs_truck_id', d.ecrs_truck_id,
            'loc_sent_at', d.loc_sent_at, 'updated_at', d.updated_at,
            'transport', d.transport_name, 'short', public.lwb_transport_short(d.transport_name),
            'save_as', public.lwb_vehicle_save_as(d.vehicle_no, d.driver_name, d.transport_name),
            'old_drivers', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', h.driver_name, 'masked', public.lwb_dial_mask(h.driver_mobile),
                              'last_at', h.last_at, 'trips', h.trips) ORDER BY h.last_at DESC), '[]'::jsonb)
                              FROM public.lwb_vehicle_driver_hist h WHERE h.vehicle_key = d.vehicle_key AND h.driver_mobile <> d.driver_mobile))), '[]'::jsonb)
    FROM public.lwb_vehicle_driver d
    WHERE d.vehicle_key IN (SELECT public.lwb_vehicle_key(x) FROM unnest(coalesce(p_vehicles, '{}')) x));
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_drivers(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_drivers(text[]) TO authenticated;

-- Transport names for the popups (Transport Master, active).
CREATE OR REPLACE FUNCTION public.lwb_transport_names()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  IF public.lwb_dial_role() IS NULL OR to_regclass('public.lwb_transport_master') IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('name', t.transport_name, 'short', public.lwb_transport_short(t.transport_name))
            ORDER BY t.transport_name), '[]'::jsonb) FROM public.lwb_transport_master t WHERE t.is_active);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_transport_names() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_transport_names() TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. lwb_dial_all: VEHICLE rows = every vehicle's current driver + every old driver
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_dial_all()
RETURNS TABLE (kind text, ref text, name text, mobile text, sub text, vehicle_no text, tag text, at timestamptz, save_as text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE r text := public.lwb_dial_role(); v_all boolean;
BEGIN
  IF r IS NULL OR r NOT IN ('admin','manager','accounts','sales','warehouse','cashier','transport') THEN
    RAISE EXCEPTION 'Dial Book: not allowed for this login';
  END IF;
  v_all := r IN ('admin','manager','accounts');
  -- Parties: Admin / Sales Head / Accounts all active parties; Salesman only his own; others none.
  IF v_all OR r = 'sales' THEN
    RETURN QUERY
      SELECT 'PARTY'::text, c.id::text, btrim(c.customer_name)::text, public.lwb_dial_mob(c.mobile),
             concat_ws(' · ', nullif(btrim(coalesce(c.city, '')), ''), 'Salesman: ' || nullif(btrim(coalesce(sp.full_name, '')), ''))::text,
             NULL::text, coalesce(c.party_type, 'WS')::text, NULL::timestamptz,
             upper(concat_ws(' ', btrim(c.customer_name), nullif(btrim(coalesce(c.city, '')), ''),
               (SELECT string_agg(CASE WHEN co.name ILIKE '%coca%' THEN 'CC' WHEN co.name ILIKE '%rajni%' THEN 'RG'
                                  ELSE left(regexp_replace(upper(co.name), '[^A-Z]', '', 'g'), 3) END, ' ' ORDER BY co.name)
                  FROM public.lwb_companies co WHERE co.id = ANY (coalesce(c.brand_ids, '{}'))),
               coalesce(c.party_type, 'WS')))::text
      FROM public.lwb_customer_master c
      LEFT JOIN public.lwb_party_salesman a ON a.customer_id = c.id
      LEFT JOIN public.user_profiles sp ON sp.id = a.salesman_id
      WHERE coalesce(c.is_active, true) AND public.lwb_dial_mob(c.mobile) IS NOT NULL
        AND (v_all OR a.salesman_id = auth.uid());
  END IF;
  -- Team: every active login with a mobile (not drivers, not me).
  RETURN QUERY
    SELECT 'TEAM'::text, p.id::text, btrim(p.full_name)::text, public.lwb_dial_mob(p.mobile), NULL::text, NULL::text,
           (CASE lower(btrim(p.role)) WHEN 'admin' THEN 'Admin' WHEN 'manager' THEN 'Sales Head' WHEN 'sales' THEN 'Salesman'
             WHEN 'warehouse' THEN 'Godown Manager' WHEN 'accounts' THEN 'Accounts' WHEN 'cashier' THEN 'Cashier'
             WHEN 'transport' THEN 'Transport' ELSE initcap(p.role) END)::text, NULL::timestamptz,
           upper(btrim(p.full_name) || ' LWB ' || CASE lower(btrim(p.role)) WHEN 'admin' THEN 'ADMIN' WHEN 'manager' THEN 'SALES HEAD'
             WHEN 'sales' THEN 'SALESMAN' WHEN 'warehouse' THEN 'GODOWN MANAGER' WHEN 'accounts' THEN 'ACCOUNTS' WHEN 'cashier' THEN 'CASHIER'
             WHEN 'transport' THEN 'TRANSPORT' ELSE p.role END)::text
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(coalesce(p.role, ''))) <> 'driver' AND p.id <> auth.uid()
      AND nullif(btrim(coalesce(p.full_name, '')), '') IS NOT NULL AND public.lwb_dial_mob(p.mobile) IS NOT NULL;
  -- Employee Master staff (loaders, helpers ...) whose mobile is not already a login: Admin / Sales Head / Accounts / GM.
  IF v_all OR r = 'warehouse' THEN
    RETURN QUERY
      SELECT 'STAFF'::text, s.id::text, btrim(s.name)::text, public.lwb_dial_mob(s.mobile), NULL::text, NULL::text,
             coalesce(nullif(btrim(coalesce(s.designation, '')), ''), 'Staff')::text, NULL::timestamptz,
             upper(btrim(s.name) || ' LWB ' || coalesce(nullif(btrim(coalesce(s.designation, '')), ''), 'STAFF'))::text
      FROM public.lwb_acc_staff s
      WHERE s.active AND public.lwb_dial_mob(s.mobile) IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.active = true AND public.lwb_dial_mob(p.mobile) = public.lwb_dial_mob(s.mobile));
  END IF;
  -- Own drivers (driver logins).
  RETURN QUERY
    SELECT 'DRIVER'::text, p.id::text, btrim(p.full_name)::text, public.lwb_dial_mob(p.mobile), 'Own driver'::text, NULL::text,
           'Driver'::text, NULL::timestamptz, upper(btrim(p.full_name) || ' LWB DRIVER')::text
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(coalesce(p.role, ''))) = 'driver'
      AND nullif(btrim(coalesce(p.full_name, '')), '') IS NOT NULL AND public.lwb_dial_mob(p.mobile) IS NOT NULL;
  -- Purchase truck drivers (Mohit, 28 Nov 2026): the current driver of every vehicle, kept for ever.
  RETURN QUERY
    SELECT 'VEHICLE'::text, v.vehicle_key, (v.vehicle_no || coalesce(' · ' || nullif(btrim(coalesce(v.driver_name, '')), ''), ''))::text,
           v.driver_mobile,
           concat_ws(' · ', nullif(btrim(coalesce(v.transport_name, '')), ''),
                     CASE WHEN t.id IS NOT NULL THEN 'ECRS ' || to_char(t.day, 'DD/MM') END,
                     CASE WHEN h.trips > 1 THEN h.trips || ' trips' END)::text,
           v.vehicle_no, 'Truck driver'::text, v.updated_at,
           public.lwb_vehicle_save_as(v.vehicle_no, v.driver_name, v.transport_name)
    FROM public.lwb_vehicle_driver v
    LEFT JOIN public.lwb_ecrs_trucks t ON t.id = v.ecrs_truck_id
    LEFT JOIN public.lwb_vehicle_driver_hist h ON h.vehicle_key = v.vehicle_key AND h.driver_mobile = v.driver_mobile;
  -- Old drivers: every number once (newest vehicle), not when it is some vehicle's current driver.
  RETURN QUERY
    SELECT 'VEHICLE'::text, (h.vehicle_key || ':' || h.driver_mobile)::text,
           (h.vehicle_no || coalesce(' · ' || nullif(btrim(coalesce(h.driver_name, '')), ''), ''))::text,
           h.driver_mobile,
           concat_ws(' · ', nullif(btrim(coalesce(h.transport_name, '')), ''), 'Last trip ' || to_char(h.last_at AT TIME ZONE 'Asia/Kolkata', 'DD/MM/YY'))::text,
           h.vehicle_no, 'Old driver'::text, h.last_at,
           public.lwb_vehicle_save_as(h.vehicle_no, h.driver_name, h.transport_name)
    FROM (SELECT DISTINCT ON (x.driver_mobile) x.* FROM public.lwb_vehicle_driver_hist x
           WHERE NOT EXISTS (SELECT 1 FROM public.lwb_vehicle_driver c WHERE c.driver_mobile = x.driver_mobile)
           ORDER BY x.driver_mobile, x.last_at DESC) h;
  -- Services (Mohit, 27 Nov 2026): vendors, service agencies, complaint numbers. Every Dial Book login.
  RETURN QUERY
    SELECT 'SERVICE'::text, v.id::text, coalesce(nullif(btrim(coalesce(v.name, '')), ''), v.firm)::text, v.mobile,
           concat_ws(' · ', CASE WHEN nullif(btrim(coalesce(v.name, '')), '') IS NOT NULL THEN nullif(btrim(coalesce(v.firm, '')), '') END,
                     nullif(btrim(coalesce(v.area, '')), ''))::text,
           NULL::text, (CASE v.grp WHEN 'VENDOR' THEN 'Vendor' WHEN 'SERVICE' THEN 'Service' ELSE 'Complaint' END || ' · ' || initcap(v.category))::text,
           v.updated_at,
           upper(concat_ws(' ', nullif(btrim(coalesce(v.name, '')), ''), nullif(btrim(coalesce(v.firm, '')), ''),
                 v.category,
                 'LWB', v.grp))::text
    FROM public.lwb_dial_services v
    WHERE v.active;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_all() FROM PUBLIC, anon, authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
