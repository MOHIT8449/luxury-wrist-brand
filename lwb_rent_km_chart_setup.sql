-- Hired vehicle trip rent by DISTANCE (km from the godown) x VEHICLE SIZE (ton) (18 Nov 2026).
--
-- Mohit: rent is paid by the party's km and the vehicle's ton. Parties at the same place (e.g. Shree Jagdish and
-- Shree Devnarayan Marketing, side by side) have the same km, so the same rent.
--   * lwb_rent_km_rates: the chart, one rent per "up to N km" slab and vehicle size (Admin sets it).
--   * lwb_rent_km_perkm: beyond the last slab, rupees per km for each size.
--   * lwb_rent_party_km: the party's road km (one way) when set by hand; else the straight-line km from the
--     godown (Live Tracking settings) to the party's map location in Party Master.
--   * A trip of a per party hired vehicle with a size: each party gets the chart rent for its km; the trip takes
--     the highest of its parties (= the farthest party). Written as a rate of that vehicle + party (note 'KM chart'),
--     so the existing trip / ledger code posts it. Order of rates: the vehicle's own rate > party x size card
--     (lwb_rent_rate_card_setup.sql) > this km chart.
-- Run after lwb_rent_rate_card_setup.sql. Safe to run again. Nothing is dropped.
BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_rent_km_rates (
  km_upto    numeric(7,1) NOT NULL CHECK (km_upto > 0 AND km_upto <= 5000),
  size_ton   numeric(5,1) NOT NULL CHECK (size_ton > 0 AND size_ton <= 60),
  rate       numeric(14,2) NOT NULL CHECK (rate > 0 AND rate <= 100000),
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (km_upto, size_ton)
);
CREATE TABLE IF NOT EXISTS public.lwb_rent_km_perkm (
  size_ton    numeric(5,1) PRIMARY KEY CHECK (size_ton > 0 AND size_ton <= 60),
  rate_per_km numeric(10,2) NOT NULL CHECK (rate_per_km > 0 AND rate_per_km <= 10000),
  updated_by  uuid,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.lwb_rent_party_km (
  party_key  text PRIMARY KEY CHECK (length(party_key) BETWEEN 2 AND 150),
  party_name text NOT NULL,
  road_km    numeric(7,1) NOT NULL CHECK (road_km > 0 AND road_km <= 5000),
  set_by     uuid,
  set_at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_rent_km_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_rent_km_perkm ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_rent_party_km ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_rent_km_rates, public.lwb_rent_km_perkm, public.lwb_rent_party_km FROM PUBLIC, anon, authenticated;

-- A rate written by the card or by the km chart is a copy; any other rate is the vehicle's own.
CREATE OR REPLACE FUNCTION public.lwb_rate_card_own_trg()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $fn$
BEGIN
  IF NEW.note IS NULL OR NEW.note NOT IN ('Rate card', 'KM chart') THEN NEW.from_card := false; END IF;
  RETURN NEW;
END;
$fn$;

-- Straight-line km from the godown to the party's map location (NULL when either is missing).
CREATE OR REPLACE FUNCTION public.lwb_rent_map_km(p_party_key text)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v numeric;
BEGIN
  SELECT round((public.lwb_geo_m(m.geo_lat, m.geo_lng, s.godown_lat, s.godown_lng) / 1000)::numeric, 1) INTO v
  FROM public.lwb_customer_master m CROSS JOIN public.lwb_tracking_settings s
  WHERE s.id = 1 AND public.lwb_hired_pkey(m.customer_name) = p_party_key AND m.geo_lat IS NOT NULL AND m.geo_lng IS NOT NULL
  ORDER BY (m.merged_into IS NULL) DESC LIMIT 1;
  RETURN v;
EXCEPTION WHEN others THEN RETURN NULL;
END;
$fn$;

-- km used for rent: road km set by hand, else map km. {km, src: ROAD | MAP} or NULL.
CREATE OR REPLACE FUNCTION public.lwb_rent_party_km_of(p_party_key text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v numeric;
BEGIN
  SELECT k.road_km INTO v FROM public.lwb_rent_party_km k WHERE k.party_key = p_party_key;
  IF v IS NOT NULL THEN RETURN jsonb_build_object('km', v, 'src', 'ROAD'); END IF;
  v := public.lwb_rent_map_km(p_party_key);
  IF v IS NOT NULL AND v > 0 THEN RETURN jsonb_build_object('km', v, 'src', 'MAP'); END IF;
  RETURN NULL;
END;
$fn$;

-- Chart rent for a size and km: the first slab that covers the km, else km x rate per km. NULL = not in the chart.
CREATE OR REPLACE FUNCTION public.lwb_rent_km_rate(p_size numeric, p_km numeric)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(
    (SELECT r.rate FROM public.lwb_rent_km_rates r WHERE r.size_ton = p_size AND r.km_upto >= p_km ORDER BY r.km_upto LIMIT 1),
    CASE WHEN p_km > coalesce((SELECT max(r.km_upto) FROM public.lwb_rent_km_rates r WHERE r.size_ton = p_size), 0)
         THEN (SELECT round(p_km * x.rate_per_km) FROM public.lwb_rent_km_perkm x WHERE x.size_ton = p_size) END);
$fn$;

-- Write the km chart rent as a rate of the vehicle + party and post the waiting trips.
-- p_vehicle NULL = every per party hired vehicle with a size; p_party_key NULL = every party of that vehicle
-- (waiting trips + Transport Assignment of the last 62 days). Own rates and card rates are not touched.
CREATE OR REPLACE FUNCTION public.lwb_rent_km_apply(p_vehicle uuid, p_party_key text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r record; q public.lwb_hired_party_rates; k jsonb; v_rate numeric; v_n integer := 0;
BEGIN
  FOR r IN
    WITH veh AS (
      SELECT h.vehicle_id, v.vehicle_no, v.size_ton FROM public.lwb_hired_vehicles h JOIN public.lwb_vehicles v ON v.id = h.vehicle_id
      WHERE h.active AND h.rent_type = 'PARTY' AND v.size_ton IS NOT NULL AND (p_vehicle IS NULL OR h.vehicle_id = p_vehicle))
    SELECT DISTINCT x.vehicle_id, x.size_ton, x.pk, x.party FROM (
      SELECT veh.vehicle_id, veh.size_ton, p.party_key AS pk, p.party_name AS party
      FROM veh JOIN public.lwb_hired_pending p ON p.vehicle_id = veh.vehicle_id AND p.status = 'NEED_RATE'
      UNION ALL
      SELECT veh.vehicle_id, veh.size_ton, public.lwb_hired_pkey(o.customer_name), btrim(o.customer_name)
      FROM veh JOIN public.dispatch_assignments a ON upper(regexp_replace(coalesce(a.vehicle_no,''), '[^A-Za-z0-9]', '', 'g')) = veh.vehicle_no
      JOIN public.orders o ON o.id = a.order_id
      WHERE a.assigned_at > now() - interval '62 days') x
    WHERE length(x.pk) >= 2 AND (p_party_key IS NULL OR x.pk = p_party_key)
  LOOP
    SELECT * INTO q FROM public.lwb_hired_party_rates z WHERE z.vehicle_id = r.vehicle_id AND z.party_key = r.pk;
    -- the vehicle's own rate or a party x size card rate wins
    IF q.id IS NOT NULL AND q.status = 'VERIFIED' AND (NOT q.from_card OR q.note = 'Rate card') THEN CONTINUE; END IF;
    IF q.id IS NOT NULL AND q.status = 'WAITING' AND NOT q.from_card THEN CONTINUE; END IF;
    k := public.lwb_rent_party_km_of(r.pk);
    v_rate := CASE WHEN k IS NULL THEN NULL ELSE public.lwb_rent_km_rate(r.size_ton, (k->>'km')::numeric) END;
    IF coalesce(v_rate, 0) <= 0 THEN
      -- chart / km gone: an old km chart copy goes out (the trips wait again for a rate)
      IF q.id IS NOT NULL AND q.note = 'KM chart' THEN DELETE FROM public.lwb_hired_party_rates WHERE id = q.id; END IF;
      CONTINUE;
    END IF;
    IF q.id IS NOT NULL AND q.note = 'KM chart' AND q.rate = v_rate AND q.status = 'VERIFIED'
       AND NOT EXISTS (SELECT 1 FROM public.lwb_hired_pending p WHERE p.vehicle_id = r.vehicle_id AND p.party_key = r.pk AND p.status = 'NEED_RATE') THEN
      CONTINUE;
    END IF;
    INSERT INTO public.lwb_hired_party_rates AS z (vehicle_id, party_key, party_name, rate, status, note, set_by, set_at, verified_by, verified_at, from_card)
    VALUES (r.vehicle_id, r.pk, coalesce(r.party, r.pk), round(v_rate, 2), 'VERIFIED', 'KM chart', auth.uid(), now(), auth.uid(), now(), true)
    ON CONFLICT (vehicle_id, party_key) DO UPDATE SET rate = EXCLUDED.rate, status = 'VERIFIED', note = 'KM chart', from_card = true,
      verified_at = now();
    v_n := v_n + public.lwb_hired_post_pending(r.vehicle_id, r.pk);
  END LOOP;
  RETURN v_n;
END;
$fn$;

-- Transport assignment: the party's km rent is ready before the trip line is counted
-- (this trigger's name sorts before trg_lwb_hired_assignment_trip, so it runs first). Never stops the assignment.
CREATE OR REPLACE FUNCTION public.lwb_rent_km_assign_trg()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id uuid; v_pk text;
BEGIN
  BEGIN
    SELECT v.id INTO v_id FROM public.lwb_vehicles v WHERE v.vehicle_no = upper(regexp_replace(coalesce(NEW.vehicle_no,''), '[^A-Za-z0-9]', '', 'g'));
    SELECT public.lwb_hired_pkey(o.customer_name) INTO v_pk FROM public.orders o WHERE o.id = NEW.order_id;
    IF v_id IS NOT NULL AND length(coalesce(v_pk,'')) >= 2 THEN PERFORM public.lwb_rent_km_apply(v_id, v_pk); END IF;
  EXCEPTION WHEN others THEN RAISE WARNING 'km rent skipped: %', SQLERRM;
  END;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS trg_lwb_hired_a_km ON public.dispatch_assignments;
CREATE TRIGGER trg_lwb_hired_a_km AFTER INSERT OR UPDATE OF vehicle_no, assigned_at, trip_id ON public.dispatch_assignments
  FOR EACH ROW EXECUTE FUNCTION public.lwb_rent_km_assign_trg();

-- Vehicle size changed / vehicle put on per party rent: card rates, then km chart rates (never stops the save).
CREATE OR REPLACE FUNCTION public.lwb_rate_card_vehicle_trg()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id uuid; v_size numeric;
BEGIN
  BEGIN
    IF TG_TABLE_NAME = 'lwb_vehicles' THEN
      v_id := (to_jsonb(NEW)->>'id')::uuid; v_size := (to_jsonb(NEW)->>'size_ton')::numeric;
      DELETE FROM public.lwb_hired_party_rates q WHERE q.vehicle_id = v_id AND q.from_card
        AND (q.note = 'KM chart' OR NOT EXISTS (SELECT 1 FROM public.lwb_hired_rate_card c WHERE c.size_ton = v_size AND c.party_key = q.party_key AND c.status = 'VERIFIED'));
    ELSE
      v_id := (to_jsonb(NEW)->>'vehicle_id')::uuid;
    END IF;
    PERFORM public.lwb_rate_card_apply(NULL, v_id);
    PERFORM public.lwb_rent_km_apply(v_id, NULL);
  EXCEPTION WHEN others THEN RAISE WARNING 'rate card skipped: %', SQLERRM;
  END;
  RETURN NEW;
END;
$fn$;

-- Page: the chart, rate per km, and the parties with their km (parties of hired trips first).
CREATE OR REPLACE FUNCTION public.lwb_rent_km_get()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_fleet_editor() THEN RAISE EXCEPTION 'Trip rent is for Admin / Manager only'; END IF;
  RETURN jsonb_build_object(
    'is_admin', public.lwb_acc_admin(),
    'godown_set', EXISTS (SELECT 1 FROM public.lwb_tracking_settings s WHERE s.id = 1 AND s.godown_lat IS NOT NULL),
    'rates', coalesce((SELECT jsonb_agg(jsonb_build_object('km_upto', r.km_upto, 'size_ton', r.size_ton, 'rate', r.rate) ORDER BY r.km_upto, r.size_ton)
                       FROM public.lwb_rent_km_rates r), '[]'::jsonb),
    'per_km', coalesce((SELECT jsonb_agg(jsonb_build_object('size_ton', x.size_ton, 'rate_per_km', x.rate_per_km) ORDER BY x.size_ton)
                        FROM public.lwb_rent_km_perkm x), '[]'::jsonb),
    'parties', coalesce((SELECT jsonb_agg(z ORDER BY z.used DESC, z.party) FROM (
        SELECT p.pk AS party_key, p.party, (SELECT k.road_km FROM public.lwb_rent_party_km k WHERE k.party_key = p.pk) AS road_km,
               public.lwb_rent_map_km(p.pk) AS map_km, p.used
        FROM (SELECT public.lwb_hired_pkey(o.customer_name) AS pk, min(btrim(o.customer_name)) AS party, count(*) AS used
              FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
              JOIN public.lwb_vehicles v ON v.vehicle_no = upper(regexp_replace(coalesce(a.vehicle_no,''), '[^A-Za-z0-9]', '', 'g'))
              JOIN public.lwb_hired_vehicles h ON h.vehicle_id = v.id AND h.active
              WHERE a.assigned_at > now() - interval '62 days' GROUP BY 1
              UNION
              SELECT k.party_key, k.party_name, 0 FROM public.lwb_rent_party_km k
              WHERE NOT EXISTS (SELECT 1 FROM public.dispatch_assignments a2 JOIN public.orders o2 ON o2.id = a2.order_id
                                WHERE public.lwb_hired_pkey(o2.customer_name) = k.party_key AND a2.assigned_at > now() - interval '62 days')) p
        WHERE length(p.pk) >= 2) z), '[]'::jsonb));
END;
$fn$;

-- Admin saves the whole chart: p = {"rates":[{"km_upto":10,"size_ton":3,"rate":800},...], "per_km":[{"size_ton":3,"rate_per_km":36}]}
CREATE OR REPLACE FUNCTION public.lwb_rent_km_save(p jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE x jsonb;
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can change the rent chart'; END IF;
  DELETE FROM public.lwb_rent_km_rates;
  DELETE FROM public.lwb_rent_km_perkm;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p->'rates', '[]'::jsonb)) LOOP
    IF nullif(x->>'rate','') IS NULL THEN CONTINUE; END IF;
    BEGIN
      INSERT INTO public.lwb_rent_km_rates (km_upto, size_ton, rate, updated_by)
      VALUES (round((x->>'km_upto')::numeric, 1), round((x->>'size_ton')::numeric, 1), round((x->>'rate')::numeric, 2), auth.uid())
      ON CONFLICT (km_upto, size_ton) DO UPDATE SET rate = EXCLUDED.rate, updated_by = EXCLUDED.updated_by, updated_at = now();
    EXCEPTION WHEN check_violation OR invalid_text_representation THEN
      RAISE EXCEPTION 'Check the chart: % km, % ton, ₹%', x->>'km_upto', x->>'size_ton', x->>'rate';
    END;
  END LOOP;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p->'per_km', '[]'::jsonb)) LOOP
    IF nullif(x->>'rate_per_km','') IS NULL THEN CONTINUE; END IF;
    BEGIN
      INSERT INTO public.lwb_rent_km_perkm (size_ton, rate_per_km, updated_by)
      VALUES (round((x->>'size_ton')::numeric, 1), round((x->>'rate_per_km')::numeric, 2), auth.uid())
      ON CONFLICT (size_ton) DO UPDATE SET rate_per_km = EXCLUDED.rate_per_km, updated_by = EXCLUDED.updated_by, updated_at = now();
    EXCEPTION WHEN check_violation OR invalid_text_representation THEN
      RAISE EXCEPTION 'Check the rate per km for % ton', x->>'size_ton';
    END;
  END LOOP;
  RETURN public.lwb_rent_km_apply(NULL, NULL);
END;
$fn$;

-- Admin / Manager sets (or clears with NULL) a party's road km.
CREATE OR REPLACE FUNCTION public.lwb_rent_party_km_set(p_party text, p_km numeric)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_pk text := public.lwb_hired_pkey(p_party);
BEGIN
  IF NOT public.lwb_fleet_editor() THEN RAISE EXCEPTION 'Only Admin / Manager can set the party km'; END IF;
  IF length(v_pk) < 2 THEN RAISE EXCEPTION 'Party name is missing'; END IF;
  IF p_km IS NULL THEN DELETE FROM public.lwb_rent_party_km WHERE party_key = v_pk;
  ELSE
    IF p_km <= 0 OR p_km > 5000 THEN RAISE EXCEPTION 'Enter the road km (one way)'; END IF;
    INSERT INTO public.lwb_rent_party_km (party_key, party_name, road_km, set_by, set_at)
    VALUES (v_pk, btrim(p_party), round(p_km, 1), auth.uid(), now())
    ON CONFLICT (party_key) DO UPDATE SET road_km = EXCLUDED.road_km, set_by = EXCLUDED.set_by, set_at = now();
  END IF;
  RETURN public.lwb_rent_km_apply(NULL, v_pk);
END;
$fn$;

-- Lists of lwb_rent_rate_card_setup.sql + km: each waiting group gets the party's km; ledger lines get the
-- farthest km of their POs' parties.
CREATE OR REPLACE FUNCTION public.lwb_rent_orders_km(p_orders text[])
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT max((public.lwb_rent_party_km_of(public.lwb_hired_pkey(o.customer_name))->>'km')::numeric)
  FROM public.orders o WHERE o.order_no = ANY (coalesce(p_orders, '{}'));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_hired_rate_list2()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v jsonb := public.lwb_hired_rate_list();
BEGIN
  RETURN v || jsonb_build_object(
    'groups', coalesce((SELECT jsonb_agg(g.x || jsonb_build_object('size_ton', vh.size_ton,
        'load_kg', CASE WHEN jsonb_typeof(g.x->'orders') = 'array' THEN public.lwb_rate_card_load(ARRAY(SELECT jsonb_array_elements_text(g.x->'orders'))) END,
        'km', public.lwb_rent_party_km_of(g.x->>'party_key'),
        'card', (SELECT jsonb_build_object('id', c.id, 'rate', c.rate, 'status', c.status, 'note', c.note,
                   'set_by_name', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = c.set_by))
                 FROM public.lwb_hired_rate_card c WHERE c.size_ton = vh.size_ton AND c.party_key = g.x->>'party_key')) ORDER BY g.n)
      FROM jsonb_array_elements(coalesce(v->'groups','[]'::jsonb)) WITH ORDINALITY g(x, n)
      LEFT JOIN public.lwb_vehicles vh ON vh.id = (g.x->>'vehicle_id')::uuid), '[]'::jsonb),
    'rates', coalesce((SELECT jsonb_agg(r.x || jsonb_build_object('from_card', q.from_card, 'size_ton', vh.size_ton) ORDER BY r.n)
      FROM jsonb_array_elements(coalesce(v->'rates','[]'::jsonb)) WITH ORDINALITY r(x, n)
      LEFT JOIN public.lwb_hired_party_rates q ON q.id = (r.x->>'id')::bigint
      LEFT JOIN public.lwb_vehicles vh ON vh.id = q.vehicle_id), '[]'::jsonb),
    'card', coalesce((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'size_ton', c.size_ton, 'party_key', c.party_key, 'party', c.party_name,
        'rate', c.rate, 'status', c.status, 'note', c.note, 'set_by_name', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = c.set_by),
        'verified_by_name', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = c.verified_by), 'verified_at', c.verified_at,
        'vehicles', (SELECT count(*) FROM public.lwb_vehicles x JOIN public.lwb_hired_vehicles h ON h.vehicle_id = x.id AND h.active AND h.rent_type = 'PARTY'
                     WHERE x.size_ton = c.size_ton)) ORDER BY c.party_name, c.size_ton)
      FROM public.lwb_hired_rate_card c), '[]'::jsonb),
    'sizes', coalesce((SELECT jsonb_agg(DISTINCT s ORDER BY s) FROM (
        SELECT x.size_ton AS s FROM public.lwb_vehicles x WHERE x.size_ton IS NOT NULL
        UNION SELECT c.size_ton FROM public.lwb_hired_rate_card c
        UNION SELECT r.size_ton FROM public.lwb_rent_km_rates r) z), '[]'::jsonb));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_hired_ledger2(p_vehicle uuid, p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v jsonb := public.lwb_hired_ledger(p_vehicle, p_from, p_to);
BEGIN
  RETURN jsonb_set(jsonb_set(v, '{vehicle,size_ton}', coalesce((SELECT to_jsonb(x.size_ton) FROM public.lwb_vehicles x WHERE x.id = p_vehicle), 'null'::jsonb)),
    '{lines}', coalesce((SELECT jsonb_agg(CASE WHEN jsonb_typeof(l.x->'order_nos') = 'array' AND jsonb_array_length(l.x->'order_nos') > 0
        THEN l.x || jsonb_build_object('load_kg', public.lwb_rate_card_load(ARRAY(SELECT jsonb_array_elements_text(l.x->'order_nos'))),
                                       'km', public.lwb_rent_orders_km(ARRAY(SELECT jsonb_array_elements_text(l.x->'order_nos')))) ELSE l.x END ORDER BY l.n)
      FROM jsonb_array_elements(coalesce(v->'lines','[]'::jsonb)) WITH ORDINALITY l(x, n)), '[]'::jsonb));
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_rent_map_km(text), public.lwb_rent_party_km_of(text), public.lwb_rent_km_rate(numeric,numeric),
  public.lwb_rent_km_apply(uuid,text), public.lwb_rent_km_assign_trg(), public.lwb_rent_orders_km(text[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_rent_km_get(), public.lwb_rent_km_save(jsonb), public.lwb_rent_party_km_set(text,numeric),
  public.lwb_hired_rate_list2(), public.lwb_hired_ledger2(uuid,date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_rent_km_get(), public.lwb_rent_km_save(jsonb), public.lwb_rent_party_km_set(text,numeric),
  public.lwb_hired_rate_list2(), public.lwb_hired_ledger2(uuid,date,date) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
