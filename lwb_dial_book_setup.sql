-- LUXURY WRIST BRAND ERP — DIAL BOOK + CALL LOG + PURCHASE VEHICLE DRIVER (27 Nov 2026)
--
-- Mohit asked (27 Nov 2026): one "Dial Book" like the phone has: every party, the team (sales, Sales Head,
-- Godown Manager, Accounts ...) and the purchase truck drivers, with a Call button, and a record of who
-- called whom. Sales Head and Accounts see every number; a salesman only his own parties; Godown Manager
-- team + drivers (no parties for now). No import / export for anyone (only Admin can download a contacts
-- file). Purchase: at night Admin / Sales enter vehicle no. + driver mobile once (linked together) and send
-- the godown location on WhatsApp; next day anyone can call the driver from that vehicle.
--
--   lwb_vehicle_fmt(text)   one format for every vehicle no.: GJ05 BX 4471 (state + 2-digit RTO, series,
--                           4-digit number) or 22 BH 1234 AA. NULL = not a valid Indian number.
--   lwb_vehicle_driver      one row per vehicle (key = number without spaces): driver mobile / name,
--                           ECRS order, when the godown location was sent.
--   lwb_dial_calls          the call log: who pressed Call, to whom, when, from which page, + result / note.
--
-- RPCs:
--   lwb_dial_book()                         the list for this login; numbers come back MASKED (98•••••312).
--   lwb_dial_call(kind, ref, source)        the full number of one contact (scope checked again) + log row.
--   lwb_dial_note(id, result, note)         result / note on my own call (same day).
--   lwb_dial_log(from, to)                  Admin / Sales Head: every call; others: their own.
--   lwb_vehicle_driver_save(...)            Admin / Sales Head / Salesman / Accounts.
--   lwb_vehicle_loc_sent(vehicle)           marks "location sent"; returns the WhatsApp text data.
--   lwb_vehicle_drivers(vehicles text[])    masked driver per vehicle, for Purchase List / ECRS rows.
--   lwb_dial_export()                       Admin only: every contact with the full number (contacts file).
--
-- Website limit: a call is made by the phone's own dialer, so the length of the call cannot be known.
-- Only "Call pressed" (time) and the result / note typed after it are saved.
-- Safe to run again. Nothing is dropped or deleted. Orders, bills, stock, ledger and Tally are not touched.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Vehicle number format
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_vehicle_fmt(p text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $fn$
DECLARE v text := upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')); m text[];
BEGIN
  IF v = '' THEN RETURN NULL; END IF;
  m := regexp_match(v, '^([0-9]{2})BH([0-9]{1,4})([A-Z]{1,2})$');
  IF m IS NOT NULL THEN RETURN m[1] || ' BH ' || lpad(m[2], 4, '0') || ' ' || m[3]; END IF;
  m := regexp_match(v, '^([A-Z]{2})([0-9]{1,2})([A-Z]{1,3})([0-9]{1,4})$');
  IF m IS NULL OR NOT (m[1] = ANY (ARRAY['AN','AP','AR','AS','BR','CG','CH','DD','DL','DN','GA','GJ','HP','HR','JH','JK',
      'KA','KL','LA','LD','MH','ML','MN','MP','MZ','NL','OD','OR','PB','PY','RJ','SK','TN','TR','TS','UK','UA','UP','WB'])) THEN
    RETURN NULL;
  END IF;
  IF m[4]::int = 0 THEN RETURN NULL; END IF;
  RETURN m[1] || lpad(m[2], 2, '0') || ' ' || m[3] || ' ' || lpad(m[4], 4, '0');
END $fn$;
-- Search / join key: the formatted number without spaces, else the typed text cleaned.
CREATE OR REPLACE FUNCTION public.lwb_vehicle_key(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT nullif(replace(coalesce(public.lwb_vehicle_fmt(p), upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'))), ' ', ''), '')
$$;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_fmt(text), public.lwb_vehicle_key(text) TO authenticated;

-- 10-digit Indian mobile or NULL.
CREATE OR REPLACE FUNCTION public.lwb_dial_mob(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN d ~ '^(91|0)?[6-9][0-9]{9}$' THEN right(d, 10) END
  FROM (SELECT regexp_replace(coalesce(p, ''), '\D', '', 'g') AS d) x
$$;
CREATE OR REPLACE FUNCTION public.lwb_dial_mask(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN p IS NULL THEN NULL ELSE left(p, 2) || '•••••' || right(p, 3) END
$$;

-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_vehicle_driver (
  vehicle_key text PRIMARY KEY,
  vehicle_no text NOT NULL,
  driver_mobile text NOT NULL CHECK (driver_mobile ~ '^[6-9][0-9]{9}$'),
  driver_name text CHECK (driver_name IS NULL OR length(driver_name) <= 80),
  ecrs_truck_id bigint,
  loc_sent_at timestamptz,
  loc_sent_by uuid,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_vehicle_driver_upd_idx ON public.lwb_vehicle_driver(updated_at DESC);
ALTER TABLE public.lwb_vehicle_driver ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_vehicle_driver FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_dial_calls (
  id bigserial PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('PARTY','TEAM','STAFF','DRIVER','VEHICLE')),
  ref text NOT NULL,
  to_name text,
  to_mobile text,
  vehicle_no text,
  source text CHECK (source IS NULL OR length(source) <= 40),
  result text CHECK (result IS NULL OR result IN ('TALKED','NO_ANSWER','ORDER','PAYMENT','ON_WAY','BUSY','WRONG')),
  note text CHECK (note IS NULL OR length(note) <= 300),
  called_by uuid NOT NULL DEFAULT auth.uid(),
  called_by_name text,
  called_by_role text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_dial_calls_at_idx ON public.lwb_dial_calls(created_at DESC);
CREATE INDEX IF NOT EXISTS lwb_dial_calls_by_idx ON public.lwb_dial_calls(called_by, created_at DESC);
CREATE INDEX IF NOT EXISTS lwb_dial_calls_ref_idx ON public.lwb_dial_calls(kind, ref, created_at DESC);
ALTER TABLE public.lwb_dial_calls ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_dial_calls FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_dial_calls_id_seq FROM PUBLIC, anon, authenticated;

-- Party type for the saved contact name (Mohit, 27 Nov 2026): WS = wholesale (default), RT = retail.
ALTER TABLE public.lwb_customer_master ADD COLUMN IF NOT EXISTS party_type text NOT NULL DEFAULT 'WS';
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_customer_party_type_chk') THEN
    ALTER TABLE public.lwb_customer_master ADD CONSTRAINT lwb_customer_party_type_chk CHECK (party_type IN ('WS','RT'));
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3. Who may do what
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_dial_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
$$;
REVOKE ALL ON FUNCTION public.lwb_dial_role() FROM PUBLIC, anon;

-- Every contact this login may call, with the FULL number (internal; never granted to the website).
-- kind / ref: PARTY customer id · TEAM user id · STAFF employee id · DRIVER driver login id · VEHICLE vehicle key.
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
  -- Purchase truck drivers: vehicle + driver entered in the last 30 days.
  RETURN QUERY
    SELECT 'VEHICLE'::text, v.vehicle_key, (v.vehicle_no || coalesce(' · ' || nullif(btrim(coalesce(v.driver_name, '')), ''), ''))::text,
           v.driver_mobile,
           CASE WHEN t.id IS NOT NULL THEN 'ECRS ' || to_char(t.day, 'DD/MM') ELSE 'Purchase truck' END::text,
           v.vehicle_no, 'Truck driver'::text, v.updated_at,
           upper(concat_ws(' ', v.vehicle_no, nullif(btrim(coalesce(v.driver_name, '')), ''), 'TRUCK DRIVER'))::text
    FROM public.lwb_vehicle_driver v
    LEFT JOIN public.lwb_ecrs_trucks t ON t.id = v.ecrs_truck_id
    WHERE v.updated_at > now() - interval '30 days';
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_all() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The list (masked numbers) + last call of each contact
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_dial_book()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE r text := public.lwb_dial_role(); v jsonb; v_recent jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind', a.kind, 'ref', a.ref, 'name', a.name, 'masked', public.lwb_dial_mask(a.mobile),
           'last4', right(a.mobile, 4), 'sub', a.sub, 'save_as', a.save_as, 'vehicle_no', a.vehicle_no, 'tag', a.tag, 'at', a.at,
           'last_at', lc.created_at, 'last_by', lc.called_by_name, 'last_result', lc.result) ORDER BY a.kind, a.name), '[]'::jsonb)
    INTO v
  FROM public.lwb_dial_all() a
  LEFT JOIN LATERAL (SELECT c.created_at, c.called_by_name, c.result FROM public.lwb_dial_calls c
                     WHERE c.kind = a.kind AND c.ref = a.ref
                       AND (r IN ('admin','manager') OR c.called_by = auth.uid())
                     ORDER BY c.created_at DESC LIMIT 1) lc ON true;
  -- My last 15 different contacts.
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'ref', x.ref, 'at', x.created_at) ORDER BY x.created_at DESC), '[]'::jsonb)
    INTO v_recent
  FROM (SELECT DISTINCT ON (c.kind, c.ref) c.kind, c.ref, c.created_at FROM public.lwb_dial_calls c
        WHERE c.called_by = auth.uid() AND c.created_at > now() - interval '30 days' AND coalesce(c.source, '') <> 'Download'
        ORDER BY c.kind, c.ref, c.created_at DESC) x
  WHERE x.created_at IS NOT NULL
  LIMIT 15;
  RETURN jsonb_build_object('role', r, 'me', auth.uid(), 'all_log', r IN ('admin','manager'), 'export', r = 'admin',
    'contacts', v, 'recent', v_recent);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_book() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_book() TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Call pressed: full number + log row (max 120 calls an hour per login, so the list cannot be copied out)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_dial_call(p_kind text, p_ref text, p_source text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE a record; v_id bigint; v_name text; v_role text;
BEGIN
  SELECT * INTO a FROM public.lwb_dial_all() x WHERE x.kind = upper(btrim(coalesce(p_kind, ''))) AND x.ref = btrim(coalesce(p_ref, '')) LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'This number is not in your Dial Book'; END IF;
  IF (SELECT count(*) FROM public.lwb_dial_calls c WHERE c.called_by = auth.uid() AND c.created_at > now() - interval '1 hour') >= 120 THEN
    RAISE EXCEPTION 'Too many calls in one hour. Please wait a little.';
  END IF;
  SELECT p.full_name, lower(btrim(p.role)) INTO v_name, v_role FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.lwb_dial_calls(kind, ref, to_name, to_mobile, vehicle_no, source, called_by, called_by_name, called_by_role)
  VALUES (a.kind, a.ref, a.name, a.mobile, a.vehicle_no, left(nullif(btrim(coalesce(p_source, '')), ''), 40), auth.uid(), v_name, v_role)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'mobile', a.mobile, 'name', a.name);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_call(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_call(text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_dial_note(p_id bigint, p_result text, p_note text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_res text := nullif(upper(btrim(coalesce(p_result, ''))), '');
BEGIN
  IF v_res IS NOT NULL AND v_res NOT IN ('TALKED','NO_ANSWER','ORDER','PAYMENT','ON_WAY','BUSY','WRONG') THEN
    RAISE EXCEPTION 'Unknown call result';
  END IF;
  UPDATE public.lwb_dial_calls SET result = v_res, note = left(nullif(btrim(coalesce(p_note, '')), ''), 300)
  WHERE id = p_id AND called_by = auth.uid() AND created_at > now() - interval '24 hours';
  IF NOT FOUND THEN RAISE EXCEPTION 'Only your own call of today can get a note'; END IF;
  RETURN true;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_note(bigint, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_note(bigint, text, text) TO authenticated;

-- Call log (IST days). Admin / Sales Head: everybody's calls; others: only their own. Numbers masked.
CREATE OR REPLACE FUNCTION public.lwb_dial_log(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE r text := public.lwb_dial_role(); v_from date := coalesce(p_from, (now() AT TIME ZONE 'Asia/Kolkata')::date);
        v_to date := coalesce(p_to, (now() AT TIME ZONE 'Asia/Kolkata')::date);
BEGIN
  IF r IS NULL OR r NOT IN ('admin','manager','accounts','sales','warehouse','cashier','transport') THEN
    RAISE EXCEPTION 'Dial Book: not allowed for this login';
  END IF;
  IF v_to - v_from > 92 THEN v_from := v_to - 92; END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'at', c.created_at, 'kind', c.kind, 'ref', c.ref,
            'to_name', c.to_name, 'masked', public.lwb_dial_mask(c.to_mobile), 'vehicle_no', c.vehicle_no, 'source', c.source,
            'result', c.result, 'note', c.note, 'by', c.called_by, 'by_name', c.called_by_name, 'by_role', c.called_by_role)
            ORDER BY c.created_at DESC), '[]'::jsonb)
    FROM (SELECT * FROM public.lwb_dial_calls c
          WHERE (c.created_at AT TIME ZONE 'Asia/Kolkata')::date BETWEEN v_from AND v_to
            AND (r IN ('admin','manager') OR c.called_by = auth.uid())
          ORDER BY c.created_at DESC LIMIT 2000) c);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_log(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_log(date, date) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Purchase vehicle + driver
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_vehicle_driver_save(p_vehicle text, p_mobile text, p_name text DEFAULT NULL, p_ecrs bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_no text := public.lwb_vehicle_fmt(p_vehicle); v_mob text := public.lwb_dial_mob(p_mobile); v_key text;
BEGIN
  IF coalesce(public.lwb_dial_role(), '') NOT IN ('admin','manager','sales','accounts') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Salesman or Accounts can save a vehicle driver';
  END IF;
  IF v_no IS NULL THEN RAISE EXCEPTION 'Vehicle no. is not right. Example: GJ05 BX 4471'; END IF;
  IF v_mob IS NULL THEN RAISE EXCEPTION 'Driver mobile: enter a 10-digit mobile'; END IF;
  IF p_ecrs IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_ecrs_trucks t WHERE t.id = p_ecrs) THEN
    RAISE EXCEPTION 'ECRS order not found';
  END IF;
  v_key := replace(v_no, ' ', '');
  INSERT INTO public.lwb_vehicle_driver AS d (vehicle_key, vehicle_no, driver_mobile, driver_name, ecrs_truck_id, updated_by, updated_at)
  VALUES (v_key, v_no, v_mob, left(nullif(btrim(coalesce(p_name, '')), ''), 80), p_ecrs, auth.uid(), now())
  ON CONFLICT (vehicle_key) DO UPDATE SET
    vehicle_no = EXCLUDED.vehicle_no, driver_mobile = EXCLUDED.driver_mobile,
    driver_name = coalesce(EXCLUDED.driver_name, CASE WHEN d.driver_mobile = EXCLUDED.driver_mobile THEN d.driver_name END),
    ecrs_truck_id = coalesce(EXCLUDED.ecrs_truck_id, d.ecrs_truck_id),
    loc_sent_at = CASE WHEN d.driver_mobile = EXCLUDED.driver_mobile AND d.updated_at > now() - interval '3 days' THEN d.loc_sent_at END,
    loc_sent_by = CASE WHEN d.driver_mobile = EXCLUDED.driver_mobile AND d.updated_at > now() - interval '3 days' THEN d.loc_sent_by END,
    updated_by = auth.uid(), updated_at = now();
  -- The ECRS order gets the vehicle no. when it has none yet (company dispatch can still change it).
  IF p_ecrs IS NOT NULL THEN
    UPDATE public.lwb_ecrs_trucks SET vehicle_no = v_no, updated_at = now() WHERE id = p_ecrs AND nullif(btrim(coalesce(vehicle_no, '')), '') IS NULL;
  END IF;
  RETURN jsonb_build_object('vehicle_key', v_key, 'vehicle_no', v_no, 'masked', public.lwb_dial_mask(v_mob));
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_driver_save(text, text, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_driver_save(text, text, text, bigint) TO authenticated;

-- "📍 Send location": the WhatsApp text needs the driver mobile + godown point; marks it sent and logs it.
CREATE OR REPLACE FUNCTION public.lwb_vehicle_loc_sent(p_vehicle text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE d public.lwb_vehicle_driver; g record; v_me record;
BEGIN
  IF coalesce(public.lwb_dial_role(), '') NOT IN ('admin','manager','sales','accounts') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Salesman or Accounts can send the godown location';
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

-- Driver of each vehicle (masked) for Purchase List / ECRS / Goods Inward rows. Every Dial Book login.
CREATE OR REPLACE FUNCTION public.lwb_vehicle_drivers(p_vehicles text[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  IF coalesce(public.lwb_dial_role(), '') NOT IN ('admin','manager','accounts','sales','warehouse','cashier','transport') THEN
    RETURN '[]'::jsonb;
  END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('vehicle_key', d.vehicle_key, 'vehicle_no', d.vehicle_no,
            'name', d.driver_name, 'masked', public.lwb_dial_mask(d.driver_mobile), 'ecrs_truck_id', d.ecrs_truck_id,
            'loc_sent_at', d.loc_sent_at, 'updated_at', d.updated_at)), '[]'::jsonb)
    FROM public.lwb_vehicle_driver d
    WHERE d.vehicle_key IN (SELECT public.lwb_vehicle_key(x) FROM unnest(coalesce(p_vehicles, '{}')) x));
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_drivers(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_drivers(text[]) TO authenticated;

-- Admin only: every contact with the full number (phone contacts file). Logged once per download.
CREATE OR REPLACE FUNCTION public.lwb_dial_export()
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v jsonb; v_me record;
BEGIN
  IF coalesce(public.lwb_dial_role(), '') <> 'admin' THEN RAISE EXCEPTION 'Only Admin can download contacts'; END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind', a.kind, 'name', a.name, 'save_as', a.save_as, 'mobile', a.mobile, 'tag', a.tag, 'sub', a.sub) ORDER BY a.kind, a.name), '[]'::jsonb)
    INTO v FROM public.lwb_dial_all() a;
  SELECT p.full_name INTO v_me FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.lwb_dial_calls(kind, ref, to_name, source, note, called_by, called_by_name, called_by_role)
  VALUES ('TEAM', auth.uid()::text, 'Contacts file', 'Download', jsonb_array_length(v) || ' contacts downloaded', auth.uid(), v_me.full_name, 'admin');
  RETURN v;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_export() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_export() TO authenticated;

-- Admin / Sales Head: party is Wholesale (WS) or Retail (RT).
CREATE OR REPLACE FUNCTION public.lwb_set_party_type(p_customer_ids uuid[], p_type text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_n integer; v_t text := upper(btrim(coalesce(p_type, '')));
BEGIN
  IF coalesce(public.lwb_dial_role(), '') NOT IN ('admin','manager') THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF v_t NOT IN ('WS','RT') THEN RAISE EXCEPTION 'Type must be WS or RT'; END IF;
  UPDATE public.lwb_customer_master SET party_type = v_t WHERE id = ANY (coalesce(p_customer_ids, '{}'));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_set_party_type(uuid[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_party_type(uuid[], text) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';
