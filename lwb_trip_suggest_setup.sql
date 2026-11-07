-- LUXURY WRIST BRAND ERP — SUGGEST TRIPS BY AREA + VEHICLE SIZE, AND A ONE-TIME PARTY AREA
--
-- Runs by itself when merged to main (after lwb_live_tracking_setup.sql for lwb_geo_m and
-- lwb_trip_rent_setup.sql for lwb_trip_editor). Safe to run again. Nothing is dropped.
--
-- Mohit asked (7 Nov 2026): Transport Allocation should suggest which ready POs go together in one vehicle:
-- parties near each other, packed up to the vehicle size (2 sizes of vehicle, e.g. 1,500-1,700 kg). A party
-- 20 km away is a separate trip. Party Master has no area yet, so the area is guessed, and can be saved once.
--
--   * lwb_customer_master.area: the party's area (one time). Empty = guessed each time, in this order:
--       1. name in brackets at the end, e.g. "NILKANTH ENTERPRISE (VARACHHA)" -> Varachha
--       2. GPS (driver's delivery location): nearest party within 3 km that has an area
--       3. same pincode: the area most parties of that pincode have
--       4. city, when it is not just Surat
--       5. the party's salesman's area (Bardoli / Old City / New City / Varachha ...)
--   * lwb_trip_suggest_data(order ids): area + GPS + salesman area per PO. The page groups and packs.
--   * lwb_party_area_list(only_missing) / lwb_party_area_save(rows): the one-time "Party area" screen.
--   Admin / Manager / Transport.

ALTER TABLE public.lwb_customer_master ADD COLUMN IF NOT EXISTS area text;
ALTER TABLE public.lwb_customer_master ADD COLUMN IF NOT EXISTS geo_lat double precision;
ALTER TABLE public.lwb_customer_master ADD COLUMN IF NOT EXISTS geo_lng double precision;
ALTER TABLE public.lwb_customer_master ADD COLUMN IF NOT EXISTS city text;
ALTER TABLE public.lwb_customer_master ADD COLUMN IF NOT EXISTS pincode text;

-- "  nana   varachha " -> "Nana Varachha"
CREATE OR REPLACE FUNCTION public.lwb_area_clean(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $fn$
  SELECT nullif(initcap(btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g'))), '');
$fn$;

-- area of the name in brackets at the end, when it looks like a place (not a number / "old" / "new")
CREATE OR REPLACE FUNCTION public.lwb_area_from_name(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $fn$
  SELECT CASE WHEN b IS NULL OR b ~ '\d' OR lower(b) IN ('old','new','main','branch','retail','wholesale') THEN NULL
              ELSE public.lwb_area_clean(b) END
  FROM (SELECT substring(coalesce(p_name, '') FROM '\(([^()]{3,30})\)\s*$') AS b) s;
$fn$;

-- the guessed (or saved) area of one party: {area, src}
CREATE OR REPLACE FUNCTION public.lwb_party_area_guess(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE c record; v text; w text;
BEGIN
  SELECT m.id, m.customer_name, m.area, m.geo_lat, m.geo_lng, nullif(btrim(m.pincode), '') pin, m.city
    INTO c FROM public.lwb_customer_master m WHERE m.id = p_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('area', NULL, 'src', NULL); END IF;
  IF public.lwb_area_clean(c.area) IS NOT NULL THEN RETURN jsonb_build_object('area', public.lwb_area_clean(c.area), 'src', 'SAVED'); END IF;
  v := public.lwb_area_from_name(c.customer_name);
  IF v IS NOT NULL THEN RETURN jsonb_build_object('area', v, 'src', 'NAME'); END IF;
  IF c.geo_lat IS NOT NULL THEN
    SELECT coalesce(public.lwb_area_clean(o.area), public.lwb_area_from_name(o.customer_name)) INTO v
    FROM public.lwb_customer_master o
    WHERE o.id <> c.id AND o.geo_lat IS NOT NULL
      AND coalesce(public.lwb_area_clean(o.area), public.lwb_area_from_name(o.customer_name)) IS NOT NULL
      AND public.lwb_geo_m(c.geo_lat, c.geo_lng, o.geo_lat, o.geo_lng) <= 3000
    ORDER BY public.lwb_geo_m(c.geo_lat, c.geo_lng, o.geo_lat, o.geo_lng) LIMIT 1;
    IF v IS NOT NULL THEN RETURN jsonb_build_object('area', v, 'src', 'GPS'); END IF;
  END IF;
  IF c.pin IS NOT NULL THEN
    SELECT a INTO v FROM (
      SELECT coalesce(public.lwb_area_clean(o.area), public.lwb_area_from_name(o.customer_name)) a
      FROM public.lwb_customer_master o WHERE o.id <> c.id AND btrim(o.pincode) = c.pin) s
    WHERE a IS NOT NULL GROUP BY a ORDER BY count(*) DESC, a LIMIT 1;
    IF v IS NOT NULL THEN RETURN jsonb_build_object('area', v, 'src', 'PINCODE', 'pincode', c.pin); END IF;
  END IF;
  IF public.lwb_area_clean(c.city) IS NOT NULL AND lower(btrim(c.city)) NOT IN ('surat', 'surat city') THEN
    RETURN jsonb_build_object('area', public.lwb_area_clean(c.city), 'src', 'CITY');
  END IF;
  SELECT public.lwb_area_clean(s.area), p.full_name INTO v, w
  FROM public.lwb_party_salesman a JOIN public.lwb_salesmen s ON s.user_id = a.salesman_id
  LEFT JOIN public.user_profiles p ON p.id = a.salesman_id WHERE a.customer_id = c.id;
  IF v IS NOT NULL THEN RETURN jsonb_build_object('area', v, 'src', 'SALESMAN', 'salesman', w); END IF;
  RETURN jsonb_build_object('area', NULL, 'src', NULL);
END;
$fn$;

-- per PO: party, area (+ where it came from), GPS, salesman + salesman area
CREATE OR REPLACE FUNCTION public.lwb_trip_suggest_data(p_order_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  IF NOT public.lwb_trip_editor() THEN RAISE EXCEPTION 'Only Admin / Manager / Transport can see trip suggestions'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('order_id', o.id, 'party_id', cm.id, 'lat', cm.geo_lat, 'lng', cm.geo_lng,
             'sm_area', sm.area, 'salesman', sm.full_name) || coalesce(public.lwb_party_area_guess(cm.id), '{}'::jsonb))
    FROM public.orders o
    LEFT JOIN LATERAL (SELECT c.id, c.geo_lat, c.geo_lng FROM public.lwb_customer_master c
                       WHERE lower(btrim(c.customer_name)) = lower(btrim(o.customer_name))
                       ORDER BY c.geo_lat IS NULL, c.id LIMIT 1) cm ON true
    LEFT JOIN LATERAL (SELECT public.lwb_area_clean(s.area) area, p.full_name FROM public.lwb_party_salesman a
                       JOIN public.lwb_salesmen s ON s.user_id = a.salesman_id
                       LEFT JOIN public.user_profiles p ON p.id = a.salesman_id
                       WHERE a.customer_id = cm.id) sm ON true
    WHERE o.id = ANY(p_order_ids)), '[]'::jsonb);
END;
$fn$;

-- the one-time Party area screen: every active party (or only those with no saved area) + the guess
CREATE OR REPLACE FUNCTION public.lwb_party_area_list(p_only_missing boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  IF NOT public.lwb_trip_editor() THEN RAISE EXCEPTION 'Only Admin / Manager / Transport can set party areas'; END IF;
  RETURN jsonb_build_object(
    'total', (SELECT count(*) FROM public.lwb_customer_master m WHERE coalesce(m.is_active, true)),
    'missing', (SELECT count(*) FROM public.lwb_customer_master m WHERE coalesce(m.is_active, true) AND public.lwb_area_clean(m.area) IS NULL),
    'areas', coalesce((SELECT jsonb_agg(a ORDER BY a) FROM (
        SELECT DISTINCT public.lwb_area_clean(m.area) a FROM public.lwb_customer_master m WHERE public.lwb_area_clean(m.area) IS NOT NULL
        UNION SELECT DISTINCT public.lwb_area_clean(s.area) FROM public.lwb_salesmen s WHERE public.lwb_area_clean(s.area) IS NOT NULL) x), '[]'::jsonb),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('id', m.id, 'name', m.customer_name, 'saved', public.lwb_area_clean(m.area),
               'city', m.city, 'pincode', m.pincode, 'gps', m.geo_lat IS NOT NULL) || public.lwb_party_area_guess(m.id)
             ORDER BY m.customer_name)
      FROM public.lwb_customer_master m
      WHERE coalesce(m.is_active, true) AND (NOT p_only_missing OR public.lwb_area_clean(m.area) IS NULL)), '[]'::jsonb));
END;
$fn$;

-- save areas: [{id, area}] ; empty area clears it
CREATE OR REPLACE FUNCTION public.lwb_party_area_save(p_rows jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE n integer;
BEGIN
  IF NOT public.lwb_trip_editor() THEN RAISE EXCEPTION 'Only Admin / Manager / Transport can set party areas'; END IF;
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Send a list of parties'; END IF;
  UPDATE public.lwb_customer_master m SET area = left(public.lwb_area_clean(r->>'area'), 60)
  FROM jsonb_array_elements(p_rows) r
  WHERE m.id = (r->>'id')::uuid AND m.area IS DISTINCT FROM left(public.lwb_area_clean(r->>'area'), 60);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_party_area_guess(uuid), public.lwb_trip_suggest_data(uuid[]),
  public.lwb_party_area_list(boolean), public.lwb_party_area_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_trip_suggest_data(uuid[]), public.lwb_party_area_list(boolean),
  public.lwb_party_area_save(jsonb) TO authenticated;
