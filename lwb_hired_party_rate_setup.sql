-- LUXURY WRIST BRAND ERP — HIRED VEHICLES: RENT PER PARTY, FIRST RATE BY MANAGER, VERIFIED BY ADMIN
--
-- Runs by itself when merged to main (after lwb_hired_vehicle_rent_setup.sql and lwb_hired_auto_trip_setup.sql).
-- Safe to run again. No table or column is dropped; one index of lwb_hired_auto_trip_setup.sql is replaced
-- by a wider one (one auto trip per vehicle, day AND party).
--
-- Mohit asked (5 Nov 2026): a hired / third party vehicle (e.g. Porter) is paid per party it goes to.
-- The first time a vehicle goes to a new party the Manager enters that trip's rent and Admin verifies it;
-- after that every trip of that vehicle to that party adds the same rent by itself.
--
--   * Rent type PARTY. Rate is kept per vehicle + party (orders.customer_name, spaces / case ignored).
--   * One trip per vehicle, day and party (2 parties in one trip = 2 lines, each party's rent).
--   * Order assigned, party has a VERIFIED rate  -> trip in the ledger at once (auto).
--     No rate yet / waiting / sent back            -> the day waits in lwb_hired_pending ("Trip rent to set").
--   * Manager sets the rate -> WAITING + bell to Admins. Admin sets it -> VERIFIED at once.
--   * Admin verifies (may change the rate) -> VERIFIED, every waiting day of that vehicle + party goes in the
--     ledger. Send back -> SENT_BACK with a note + bell to the Manager, who sets it again.

BEGIN;

ALTER TABLE public.lwb_hired_vehicles DROP CONSTRAINT IF EXISTS lwb_hired_vehicles_rent_type_check;
ALTER TABLE public.lwb_hired_vehicles ADD CONSTRAINT lwb_hired_vehicles_rent_type_check CHECK (rent_type IN ('MONTHLY','TRIP','ROUTE','PARTY'));

ALTER TABLE public.lwb_hired_charges ADD COLUMN IF NOT EXISTS party_key text;
CREATE UNIQUE INDEX IF NOT EXISTS lwb_hired_charges_auto2_uidx ON public.lwb_hired_charges (vehicle_id, charge_date, coalesce(party_key, '')) WHERE kind = 'TRIP' AND auto;
DROP INDEX IF EXISTS public.lwb_hired_charges_auto_uidx;

CREATE OR REPLACE FUNCTION public.lwb_hired_pkey(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT upper(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g')) $fn$;

CREATE TABLE IF NOT EXISTS public.lwb_hired_party_rates (
  id          bigserial PRIMARY KEY,
  vehicle_id  uuid NOT NULL REFERENCES public.lwb_hired_vehicles(vehicle_id) ON DELETE CASCADE,
  party_key   text NOT NULL CHECK (length(party_key) BETWEEN 2 AND 150),
  party_name  text NOT NULL,
  rate        numeric(14,2) NOT NULL CHECK (rate > 0),
  status      text NOT NULL CHECK (status IN ('WAITING','VERIFIED','SENT_BACK')),
  note        text CHECK (note IS NULL OR length(note) <= 300),
  set_by      uuid,
  set_at      timestamptz NOT NULL DEFAULT now(),
  verified_by uuid,
  verified_at timestamptz,
  UNIQUE (vehicle_id, party_key)
);

-- Days of a PARTY vehicle that wait for the party's rate.
CREATE TABLE IF NOT EXISTS public.lwb_hired_pending (
  id         bigserial PRIMARY KEY,
  vehicle_id uuid NOT NULL REFERENCES public.lwb_hired_vehicles(vehicle_id) ON DELETE CASCADE,
  trip_date  date NOT NULL,
  party_key  text NOT NULL,
  party_name text NOT NULL,
  order_nos  text[] NOT NULL DEFAULT '{}',
  status     text NOT NULL DEFAULT 'NEED_RATE' CHECK (status IN ('NEED_RATE','DONE','CANCELLED')),
  charge_id  bigint REFERENCES public.lwb_hired_charges(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (vehicle_id, trip_date, party_key)
);

ALTER TABLE public.lwb_hired_party_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_hired_pending ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_hired_party_rates, public.lwb_hired_pending FROM PUBLIC, anon, authenticated;

-- Put one order on the auto trip line of a vehicle / day / party (party_key '' = not a party vehicle).
CREATE OR REPLACE FUNCTION public.lwb_hired_join_trip(p_vehicle uuid, p_day date, p_party_key text, p_route text, p_rate numeric, p_order text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_line bigint; v_pk text := nullif(p_party_key, '');
BEGIN
  -- a trip already on that day (for that party): put the order on it (the auto line first)
  SELECT c.id INTO v_line FROM public.lwb_hired_charges c
  WHERE c.vehicle_id = p_vehicle AND c.kind = 'TRIP' AND c.charge_date = p_day AND c.cancelled_at IS NULL
    AND coalesce(c.party_key, '') = coalesce(v_pk, '')
  ORDER BY c.auto DESC, c.id LIMIT 1;
  IF v_line IS NOT NULL THEN
    IF p_order IS NOT NULL THEN
      UPDATE public.lwb_hired_charges SET order_nos = coalesce(order_nos, '{}') || p_order
      WHERE id = v_line AND NOT (p_order = ANY (coalesce(order_nos, '{}')));
    END IF;
    RETURN v_line;
  END IF;
  -- the auto line was cancelled only because its orders moved away: use it again
  UPDATE public.lwb_hired_charges SET cancelled_at = NULL, cancelled_by = NULL, cancel_note = NULL,
         order_nos = CASE WHEN p_order IS NULL THEN NULL ELSE ARRAY[p_order] END
  WHERE vehicle_id = p_vehicle AND kind = 'TRIP' AND auto AND charge_date = p_day AND coalesce(party_key, '') = coalesce(v_pk, '')
    AND cancel_note = 'Order moved to another vehicle'
  RETURNING id INTO v_line;
  IF v_line IS NOT NULL THEN RETURN v_line; END IF;
  -- the auto trip of that day was cancelled by Accounts: keep it cancelled
  IF EXISTS (SELECT 1 FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.kind = 'TRIP' AND c.auto
             AND c.charge_date = p_day AND coalesce(c.party_key, '') = coalesce(v_pk, '')) THEN RETURN NULL; END IF;
  IF coalesce(p_rate, 0) <= 0 THEN RETURN NULL; END IF;
  INSERT INTO public.lwb_hired_charges (vehicle_id, charge_date, kind, route_name, party_key, trips, rate, extra, amount, order_nos, remark, auto)
  VALUES (p_vehicle, p_day, 'TRIP', p_route, v_pk, 1, p_rate, 0, p_rate, CASE WHEN p_order IS NULL THEN NULL ELSE ARRAY[p_order] END,
          'Auto · Transport Assignment', true)
  ON CONFLICT DO NOTHING RETURNING id INTO v_line;
  RETURN v_line;
END;
$fn$;

-- Add (or join) the trip of a hired vehicle for one order (party = the order's party, for PARTY vehicles).
CREATE OR REPLACE FUNCTION public.lwb_hired_auto_trip(p_vehicle_no text, p_day date, p_order text, p_party text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_hired_vehicles; v_key text := upper(regexp_replace(coalesce(p_vehicle_no,''), '[^A-Za-z0-9]', '', 'g'));
        v_route text; v_rate numeric; v_pk text := public.lwb_hired_pkey(p_party); q public.lwb_hired_party_rates;
BEGIN
  IF v_key = '' OR p_day IS NULL THEN RETURN; END IF;
  SELECT x.* INTO h FROM public.lwb_hired_vehicles x JOIN public.lwb_vehicles v ON v.id = x.vehicle_id
  WHERE v.vehicle_no = v_key AND x.active AND x.rent_type IN ('TRIP','ROUTE','PARTY');
  IF h.vehicle_id IS NULL OR p_day < h.start_date OR p_day > public.lwb_acc_today() THEN RETURN; END IF;
  IF h.rent_type = 'PARTY' THEN
    IF length(v_pk) < 2 THEN RETURN; END IF;
    SELECT * INTO q FROM public.lwb_hired_party_rates r WHERE r.vehicle_id = h.vehicle_id AND r.party_key = v_pk;
    IF q.status = 'VERIFIED' THEN
      PERFORM public.lwb_hired_join_trip(h.vehicle_id, p_day, v_pk, q.party_name, q.rate, p_order);
    ELSE
      INSERT INTO public.lwb_hired_pending AS p (vehicle_id, trip_date, party_key, party_name, order_nos)
      VALUES (h.vehicle_id, p_day, v_pk, btrim(p_party), CASE WHEN p_order IS NULL THEN '{}' ELSE ARRAY[p_order] END)
      ON CONFLICT (vehicle_id, trip_date, party_key) DO UPDATE
        SET order_nos = CASE WHEN p_order IS NULL OR p_order = ANY (p.order_nos) THEN p.order_nos ELSE p.order_nos || p_order END,
            status = CASE WHEN p.status = 'CANCELLED' THEN 'NEED_RATE' ELSE p.status END;
    END IF;
    RETURN;
  END IF;
  IF h.rent_type = 'ROUTE' THEN
    SELECT r.name, r.rate INTO v_route, v_rate FROM public.lwb_hired_routes r WHERE r.vehicle_id = h.vehicle_id AND r.active ORDER BY r.sort, r.id LIMIT 1;
  ELSE v_rate := h.trip_rate;
  END IF;
  PERFORM public.lwb_hired_join_trip(h.vehicle_id, p_day, '', v_route, v_rate, p_order);
END;
$fn$;

-- Old 3-argument call (lwb_hired_auto_trip_setup.sql): party from the order.
CREATE OR REPLACE FUNCTION public.lwb_hired_auto_trip(p_vehicle_no text, p_day date, p_order text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT public.lwb_hired_auto_trip(p_vehicle_no, p_day, p_order,
          (SELECT o.customer_name FROM public.orders o WHERE o.order_no = p_order ORDER BY o.id LIMIT 1)) $fn$;

-- The order left this vehicle: take it off the day's lines; cancel an auto line / waiting day left empty.
CREATE OR REPLACE FUNCTION public.lwb_hired_auto_untrip(p_vehicle_no text, p_day date, p_order text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_key text := upper(regexp_replace(coalesce(p_vehicle_no,''), '[^A-Za-z0-9]', '', 'g'));
BEGIN
  IF v_key = '' OR p_day IS NULL OR p_order IS NULL THEN RETURN; END IF;
  UPDATE public.lwb_hired_charges c SET order_nos = array_remove(c.order_nos, p_order)
  FROM public.lwb_vehicles v
  WHERE v.vehicle_no = v_key AND c.vehicle_id = v.id AND c.kind = 'TRIP' AND c.charge_date = p_day
    AND c.cancelled_at IS NULL AND p_order = ANY (coalesce(c.order_nos, '{}'));
  UPDATE public.lwb_hired_charges c SET cancelled_at = now(), cancel_note = 'Order moved to another vehicle'
  FROM public.lwb_vehicles v
  WHERE v.vehicle_no = v_key AND c.vehicle_id = v.id AND c.kind = 'TRIP' AND c.auto AND c.charge_date = p_day
    AND c.cancelled_at IS NULL AND cardinality(coalesce(c.order_nos, '{}')) = 0;
  UPDATE public.lwb_hired_pending p SET order_nos = array_remove(p.order_nos, p_order)
  FROM public.lwb_vehicles v
  WHERE v.vehicle_no = v_key AND p.vehicle_id = v.id AND p.trip_date = p_day AND p.status = 'NEED_RATE' AND p_order = ANY (p.order_nos);
  UPDATE public.lwb_hired_pending p SET status = 'CANCELLED'
  FROM public.lwb_vehicles v
  WHERE v.vehicle_no = v_key AND p.vehicle_id = v.id AND p.trip_date = p_day AND p.status = 'NEED_RATE' AND cardinality(p.order_nos) = 0;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_hired_assignment_trip()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_order text; v_party text; v_status text; v_day date; v_old_day date;
BEGIN
  BEGIN
    SELECT o.order_no, o.customer_name, lower(coalesce(o.status,'')) INTO v_order, v_party, v_status FROM public.orders o WHERE o.id = NEW.order_id;
    IF v_status IN ('cancelled','canceled','rejected') THEN RETURN NEW; END IF;
    v_day := (coalesce(NEW.assigned_at, now()) AT TIME ZONE 'Asia/Kolkata')::date;
    IF TG_OP = 'UPDATE' THEN
      v_old_day := (coalesce(OLD.assigned_at, now()) AT TIME ZONE 'Asia/Kolkata')::date;
      IF upper(regexp_replace(coalesce(OLD.vehicle_no,''), '[^A-Za-z0-9]', '', 'g')) IS NOT DISTINCT FROM upper(regexp_replace(coalesce(NEW.vehicle_no,''), '[^A-Za-z0-9]', '', 'g'))
         AND v_old_day = v_day THEN RETURN NEW; END IF;
      PERFORM public.lwb_hired_auto_untrip(OLD.vehicle_no, v_old_day, v_order);
    END IF;
    PERFORM public.lwb_hired_auto_trip(NEW.vehicle_no, v_day, v_order, v_party);
  EXCEPTION WHEN others THEN
    RAISE WARNING 'hired auto trip skipped: %', SQLERRM;
  END;
  RETURN NEW;
END;
$fn$;

-- Fill the auto trips of one hired vehicle from its start date (up to 62 days back). Returns lines added.
CREATE OR REPLACE FUNCTION public.lwb_hired_auto_fill(p_vehicle uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_hired_vehicles; v_no text; r record; v_before integer; v_after integer;
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin only'; END IF;
  SELECT x.* INTO h FROM public.lwb_hired_vehicles x WHERE x.vehicle_id = p_vehicle;
  SELECT v.vehicle_no INTO v_no FROM public.lwb_vehicles v WHERE v.id = p_vehicle;
  IF h.vehicle_id IS NULL OR NOT h.active OR h.rent_type NOT IN ('TRIP','ROUTE','PARTY') THEN RETURN 0; END IF;
  SELECT (SELECT count(*) FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.kind = 'TRIP')
       + (SELECT count(*) FROM public.lwb_hired_pending p WHERE p.vehicle_id = p_vehicle) INTO v_before;
  FOR r IN SELECT (a.assigned_at AT TIME ZONE 'Asia/Kolkata')::date AS day, o.order_no, o.customer_name
           FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
           WHERE upper(regexp_replace(coalesce(a.vehicle_no,''), '[^A-Za-z0-9]', '', 'g')) = v_no
             AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected')
             AND (a.assigned_at AT TIME ZONE 'Asia/Kolkata')::date >= greatest(h.start_date, public.lwb_acc_today() - 62)
           ORDER BY a.assigned_at LOOP
    PERFORM public.lwb_hired_auto_trip(v_no, r.day, r.order_no, r.customer_name);
  END LOOP;
  SELECT (SELECT count(*) FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.kind = 'TRIP')
       + (SELECT count(*) FROM public.lwb_hired_pending p WHERE p.vehicle_id = p_vehicle) INTO v_after;
  RETURN v_after - v_before;
END;
$fn$;

-- Waiting days with a verified rate go in the ledger (one line per day).
CREATE OR REPLACE FUNCTION public.lwb_hired_post_pending(p_vehicle uuid, p_party_key text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE q public.lwb_hired_party_rates; p record; o text; v_line bigint; v_n integer := 0;
BEGIN
  SELECT * INTO q FROM public.lwb_hired_party_rates r WHERE r.vehicle_id = p_vehicle AND r.party_key = p_party_key AND r.status = 'VERIFIED';
  IF q.id IS NULL THEN RETURN 0; END IF;
  FOR p IN SELECT * FROM public.lwb_hired_pending x WHERE x.vehicle_id = p_vehicle AND x.party_key = p_party_key AND x.status = 'NEED_RATE' ORDER BY x.trip_date LOOP
    v_line := NULL;
    IF cardinality(p.order_nos) = 0 THEN v_line := public.lwb_hired_join_trip(p_vehicle, p.trip_date, p_party_key, q.party_name, q.rate, NULL);
    ELSE FOREACH o IN ARRAY p.order_nos LOOP v_line := coalesce(public.lwb_hired_join_trip(p_vehicle, p.trip_date, p_party_key, q.party_name, q.rate, o), v_line); END LOOP;
    END IF;
    UPDATE public.lwb_hired_pending SET status = 'DONE', charge_id = v_line WHERE id = p.id;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$fn$;

-- "Trip rent to set" (Vehicle Master): waiting days grouped by vehicle + party, and every party rate.
CREATE OR REPLACE FUNCTION public.lwb_hired_rate_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_fleet_editor() THEN RAISE EXCEPTION 'Trip rent is for Admin / Manager only'; END IF;
  RETURN jsonb_build_object(
    'is_admin', public.lwb_acc_admin(),
    'groups', coalesce((SELECT jsonb_agg(g ORDER BY g.first_date) FROM (
        SELECT p.vehicle_id, v.vehicle_no AS no, v.transporter_name AS owner, p.party_key, min(p.party_name) AS party,
               count(*) AS days, min(p.trip_date) AS first_date, max(p.trip_date) AS last_date,
               (SELECT array_agg(DISTINCT x) FROM public.lwb_hired_pending p2, unnest(p2.order_nos) x
                 WHERE p2.vehicle_id = p.vehicle_id AND p2.party_key = p.party_key AND p2.status = 'NEED_RATE') AS orders,
               q.id AS rate_id, q.rate, q.status, q.note, (SELECT u.full_name FROM public.user_profiles u WHERE u.id = q.set_by) AS set_by_name, q.set_at
        FROM public.lwb_hired_pending p JOIN public.lwb_vehicles v ON v.id = p.vehicle_id
        LEFT JOIN public.lwb_hired_party_rates q ON q.vehicle_id = p.vehicle_id AND q.party_key = p.party_key
        WHERE p.status = 'NEED_RATE'
        GROUP BY p.vehicle_id, v.vehicle_no, v.transporter_name, p.party_key, q.id, q.rate, q.status, q.note, q.set_by, q.set_at) g), '[]'::jsonb),
    'rates', coalesce((SELECT jsonb_agg(jsonb_build_object('id', q.id, 'vehicle_id', q.vehicle_id, 'no', v.vehicle_no, 'party', q.party_name,
        'rate', q.rate, 'status', q.status, 'note', q.note, 'set_by_name', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = q.set_by),
        'verified_by_name', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = q.verified_by), 'verified_at', q.verified_at)
        ORDER BY v.vehicle_no, q.party_name)
      FROM public.lwb_hired_party_rates q JOIN public.lwb_vehicles v ON v.id = q.vehicle_id), '[]'::jsonb)
  );
END;
$fn$;

-- Manager / Admin sets the rent of a vehicle for a party. Manager -> WAITING (bell to Admins); Admin -> VERIFIED.
CREATE OR REPLACE FUNCTION public.lwb_hired_rate_set(p_vehicle uuid, p_party text, p_rate numeric, p_note text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_pk text := public.lwb_hired_pkey(p_party); v_admin boolean := public.lwb_acc_admin(); v_no text; v_name text; v_status text;
BEGIN
  IF NOT public.lwb_fleet_editor() THEN RAISE EXCEPTION 'Only Admin / Manager can set the trip rent'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_hired_vehicles h WHERE h.vehicle_id = p_vehicle AND h.rent_type = 'PARTY') THEN
    RAISE EXCEPTION 'This vehicle is not on per party rent (Vehicle Master)'; END IF;
  IF length(v_pk) < 2 THEN RAISE EXCEPTION 'Party name is missing'; END IF;
  IF p_rate IS NULL OR p_rate <= 0 OR p_rate > 100000 THEN RAISE EXCEPTION 'Enter the rent for this trip'; END IF;
  SELECT q.status INTO v_status FROM public.lwb_hired_party_rates q WHERE q.vehicle_id = p_vehicle AND q.party_key = v_pk;
  IF v_status = 'VERIFIED' AND NOT v_admin THEN RAISE EXCEPTION 'This rate is already verified. Only Admin can change it.'; END IF;
  v_name := coalesce((SELECT min(p.party_name) FROM public.lwb_hired_pending p WHERE p.vehicle_id = p_vehicle AND p.party_key = v_pk), btrim(p_party));
  INSERT INTO public.lwb_hired_party_rates AS q (vehicle_id, party_key, party_name, rate, status, note, set_by, set_at, verified_by, verified_at)
  VALUES (p_vehicle, v_pk, v_name, round(p_rate, 2), CASE WHEN v_admin THEN 'VERIFIED' ELSE 'WAITING' END, nullif(btrim(coalesce(p_note,'')), ''),
          auth.uid(), now(), CASE WHEN v_admin THEN auth.uid() END, CASE WHEN v_admin THEN now() END)
  ON CONFLICT (vehicle_id, party_key) DO UPDATE SET rate = EXCLUDED.rate, status = EXCLUDED.status, note = EXCLUDED.note,
    set_by = EXCLUDED.set_by, set_at = now(), verified_by = EXCLUDED.verified_by, verified_at = EXCLUDED.verified_at;
  IF v_admin THEN PERFORM public.lwb_hired_post_pending(p_vehicle, v_pk); RETURN 'VERIFIED'; END IF;
  SELECT v.vehicle_no INTO v_no FROM public.lwb_vehicles v WHERE v.id = p_vehicle;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
  SELECT u.id, 'Verify trip rent', v_no || ' → ' || v_name || ': ₹' || round(p_rate, 2) || ' per trip. Vehicle Master > Trip rent to set.', 'HIRED_RATE_VERIFY'
  FROM public.user_profiles u WHERE u.active AND lower(btrim(u.role)) = 'admin' AND u.id IS DISTINCT FROM auth.uid();
  RETURN 'WAITING';
END;
$fn$;

-- Admin verifies (rate may be changed) or sends back a waiting rate.
CREATE OR REPLACE FUNCTION public.lwb_hired_rate_verify(p_rate_id bigint, p_ok boolean, p_rate numeric, p_note text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE q public.lwb_hired_party_rates; v_no text;
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can verify the trip rent'; END IF;
  SELECT * INTO q FROM public.lwb_hired_party_rates r WHERE r.id = p_rate_id FOR UPDATE;
  IF q.id IS NULL THEN RAISE EXCEPTION 'Rate not found'; END IF;
  IF q.status <> 'WAITING' THEN RAISE EXCEPTION 'This rate is not waiting for verification'; END IF;
  IF p_ok THEN
    IF p_rate IS NOT NULL AND (p_rate <= 0 OR p_rate > 100000) THEN RAISE EXCEPTION 'Check the rent'; END IF;
    UPDATE public.lwb_hired_party_rates SET status = 'VERIFIED', rate = coalesce(round(p_rate, 2), rate), verified_by = auth.uid(), verified_at = now(),
      note = coalesce(nullif(btrim(coalesce(p_note,'')), ''), note) WHERE id = q.id;
    RETURN public.lwb_hired_post_pending(q.vehicle_id, q.party_key);
  END IF;
  IF length(btrim(coalesce(p_note,''))) < 3 THEN RAISE EXCEPTION 'Write why it is sent back'; END IF;
  UPDATE public.lwb_hired_party_rates SET status = 'SENT_BACK', note = left(btrim(p_note), 300) WHERE id = q.id;
  SELECT v.vehicle_no INTO v_no FROM public.lwb_vehicles v WHERE v.id = q.vehicle_id;
  IF q.set_by IS NOT NULL AND q.set_by IS DISTINCT FROM auth.uid() THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
    VALUES (q.set_by, 'Trip rent sent back', v_no || ' → ' || q.party_name || ': ' || left(btrim(p_note), 200) || '. Set it again in Vehicle Master > Trip rent to set.', 'HIRED_RATE_SENT_BACK');
  END IF;
  RETURN 0;
END;
$fn$;

-- Rent setup, lists and + Trip now know rent type PARTY (same as before otherwise).
CREATE OR REPLACE FUNCTION public.lwb_hired_save(p_vehicle uuid, p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_type text := upper(btrim(coalesce(p->>'rent_type',''))); v_on boolean := coalesce((p->>'active')::boolean, true);
        v_month numeric; v_trip numeric; v_start date; v_open numeric; x jsonb; v_names text[] := '{}'; v_i integer := 0; v_old date;
BEGIN
  IF NOT public.lwb_fleet_editor() THEN RAISE EXCEPTION 'Only Admin / Manager can set the vehicle rent'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_vehicles v WHERE v.id = p_vehicle) THEN RAISE EXCEPTION 'Vehicle not found in Vehicle Master'; END IF;
  IF NOT v_on THEN
    UPDATE public.lwb_hired_vehicles SET active = false, updated_by = auth.uid(), updated_at = now() WHERE vehicle_id = p_vehicle;
    RETURN;
  END IF;
  IF v_type NOT IN ('MONTHLY','TRIP','ROUTE','PARTY') THEN RAISE EXCEPTION 'Choose how the rent is counted: Monthly fixed, Per trip, Per route or Per party'; END IF;
  BEGIN
    v_month := coalesce(nullif(p->>'monthly_rent','')::numeric, 0);
    v_trip := coalesce(nullif(p->>'trip_rate','')::numeric, 0);
    v_open := coalesce(nullif(p->>'opening_balance','')::numeric, 0);
    v_start := nullif(p->>'start_date','')::date;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the rent amounts and the start date';
  END;
  IF v_start IS NULL THEN RAISE EXCEPTION 'Enter the rent start date'; END IF;
  IF v_start > public.lwb_acc_today() + 31 THEN RAISE EXCEPTION 'Start date is too far ahead'; END IF;
  IF v_month < 0 OR v_trip < 0 OR abs(v_open) > 10000000 OR v_month > 1000000 OR v_trip > 100000 THEN RAISE EXCEPTION 'Check the rent amounts'; END IF;
  IF v_type = 'MONTHLY' AND v_month <= 0 THEN RAISE EXCEPTION 'Enter the monthly rent'; END IF;
  IF v_type = 'TRIP' AND v_trip <= 0 THEN RAISE EXCEPTION 'Enter the rent for one trip'; END IF;
  IF v_type = 'ROUTE' AND jsonb_array_length(coalesce(p->'routes','[]'::jsonb)) = 0 THEN RAISE EXCEPTION 'Add at least one route with its rate'; END IF;

  SELECT h.start_date INTO v_old FROM public.lwb_hired_vehicles h WHERE h.vehicle_id = p_vehicle;
  IF v_old IS NOT NULL AND v_start > v_old AND EXISTS (SELECT 1 FROM public.lwb_hired_charges c
       WHERE c.vehicle_id = p_vehicle AND c.cancelled_at IS NULL AND c.charge_date < v_start) THEN
    RAISE EXCEPTION 'Rent is already added before %. Cancel those lines in the ledger first, or keep the start date.', to_char(v_start,'DD/MM/YYYY');
  END IF;

  INSERT INTO public.lwb_hired_vehicles AS h (vehicle_id, rent_type, monthly_rent, trip_rate, start_date, opening_balance, cut_expenses, active, updated_by)
  VALUES (p_vehicle, v_type, v_month, v_trip, v_start, v_open, coalesce((p->>'cut_expenses')::boolean, true), true, auth.uid())
  ON CONFLICT (vehicle_id) DO UPDATE SET rent_type = EXCLUDED.rent_type, monthly_rent = EXCLUDED.monthly_rent,
    trip_rate = EXCLUDED.trip_rate, start_date = EXCLUDED.start_date, opening_balance = EXCLUDED.opening_balance,
    cut_expenses = EXCLUDED.cut_expenses, active = true, updated_by = auth.uid(), updated_at = now();
  UPDATE public.lwb_vehicles SET ownership = 'TRANSPORTER' WHERE id = p_vehicle AND ownership <> 'TRANSPORTER';

  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p->'routes','[]'::jsonb)) LOOP
    v_i := v_i + 1;
    IF length(btrim(coalesce(x->>'name',''))) < 2 THEN RAISE EXCEPTION 'Write the route name (e.g. Rajkot to Gondal)'; END IF;
    IF coalesce(nullif(x->>'rate','')::numeric, 0) <= 0 THEN RAISE EXCEPTION 'Enter the rate of route %', btrim(x->>'name'); END IF;
    IF lower(btrim(x->>'name')) = ANY (v_names) THEN RAISE EXCEPTION 'Route % is written twice', btrim(x->>'name'); END IF;
    v_names := v_names || lower(btrim(x->>'name'));
    INSERT INTO public.lwb_hired_routes AS r (vehicle_id, name, rate, active, sort)
    VALUES (p_vehicle, btrim(x->>'name'), (x->>'rate')::numeric, true, v_i)
    ON CONFLICT (vehicle_id, lower(btrim(name))) DO UPDATE SET name = EXCLUDED.name, rate = EXCLUDED.rate, active = true, sort = EXCLUDED.sort;
  END LOOP;
  UPDATE public.lwb_hired_routes r SET active = false WHERE r.vehicle_id = p_vehicle AND NOT (lower(btrim(r.name)) = ANY (v_names));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_hired_list(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin only'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN RAISE EXCEPTION 'Check the dates'; END IF;
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x.active DESC, x.no) FROM (
    SELECT h.vehicle_id AS id, v.vehicle_no AS no, v.vehicle_type AS type, v.transporter_name AS owner, v.owner_mobile AS mobile,
      h.rent_type, h.monthly_rent, h.trip_rate, h.start_date, h.cut_expenses, (h.active AND v.is_active) AS active,
      coalesce((SELECT jsonb_agg(jsonb_build_object('name', r.name, 'rate', r.rate) ORDER BY r.sort, r.id)
                FROM public.lwb_hired_routes r WHERE r.vehicle_id = h.vehicle_id AND r.active), '[]'::jsonb) AS routes,
      coalesce((SELECT jsonb_agg(jsonb_build_object('name', q.party_name, 'rate', q.rate) ORDER BY q.party_name)
                FROM public.lwb_hired_party_rates q WHERE q.vehicle_id = h.vehicle_id AND q.status = 'VERIFIED'), '[]'::jsonb) AS party_rates,
      (SELECT count(*) FROM public.lwb_hired_pending p WHERE p.vehicle_id = h.vehicle_id AND p.status = 'NEED_RATE') AS pending,
      coalesce((SELECT sum(c.amount) FROM public.lwb_hired_charges c WHERE c.vehicle_id = h.vehicle_id AND c.cancelled_at IS NULL
                AND c.charge_date BETWEEN p_from AND p_to), 0) AS rent,
      coalesce((SELECT sum(c.trips) FROM public.lwb_hired_charges c WHERE c.vehicle_id = h.vehicle_id AND c.cancelled_at IS NULL
                AND c.kind = 'TRIP' AND c.charge_date BETWEEN p_from AND p_to), 0) AS trips,
      coalesce((SELECT sum(m.amount) FROM public.lwb_hired_money(h.vehicle_id) m WHERE m.kind = 'PAID' AND m.entry_date BETWEEN p_from AND p_to), 0) AS paid,
      coalesce((SELECT sum(m.amount) FROM public.lwb_hired_money(h.vehicle_id) m WHERE m.kind = 'CUT' AND m.entry_date BETWEEN p_from AND p_to), 0) AS cut,
      h.opening_balance
        + coalesce((SELECT sum(c.amount) FROM public.lwb_hired_charges c WHERE c.vehicle_id = h.vehicle_id AND c.cancelled_at IS NULL AND c.charge_date <= p_to), 0)
        - coalesce((SELECT sum(m.amount) FROM public.lwb_hired_money(h.vehicle_id) m WHERE m.entry_date <= p_to), 0) AS balance
    FROM public.lwb_hired_vehicles h JOIN public.lwb_vehicles v ON v.id = h.vehicle_id
    WHERE (h.active AND v.is_active) OR EXISTS (SELECT 1 FROM public.lwb_hired_charges c WHERE c.vehicle_id = h.vehicle_id AND c.cancelled_at IS NULL)
  ) x), '[]'::jsonb);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_hired_setups()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin / Manager only'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('vehicle_id', h.vehicle_id, 'rent_type', h.rent_type,
      'monthly_rent', h.monthly_rent, 'trip_rate', h.trip_rate, 'start_date', h.start_date, 'opening_balance', h.opening_balance,
      'cut_expenses', h.cut_expenses, 'active', h.active,
      'routes', coalesce((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'rate', r.rate) ORDER BY r.sort, r.id)
                          FROM public.lwb_hired_routes r WHERE r.vehicle_id = h.vehicle_id AND r.active), '[]'::jsonb),
      'party_rates', coalesce((SELECT jsonb_agg(jsonb_build_object('name', q.party_name, 'rate', q.rate, 'status', q.status) ORDER BY q.party_name)
                          FROM public.lwb_hired_party_rates q WHERE q.vehicle_id = h.vehicle_id), '[]'::jsonb)))
    FROM public.lwb_hired_vehicles h), '[]'::jsonb);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_hired_add(p jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_hired_vehicles; v_kind text := upper(coalesce(p->>'kind','TRIP')); v_date date; v_trips integer;
        v_rate numeric; v_extra numeric; v_amt numeric; v_route text; v_id bigint; v_orders text[];
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin only'; END IF;
  BEGIN
    SELECT * INTO h FROM public.lwb_hired_vehicles x WHERE x.vehicle_id = (p->>'vehicle_id')::uuid;
    v_date := (p->>'date')::date;
    v_trips := coalesce(nullif(p->>'trips','')::integer, 1);
    v_extra := coalesce(nullif(p->>'extra','')::numeric, 0);
    v_amt := nullif(p->>'amount','')::numeric;
    v_orders := CASE WHEN jsonb_typeof(p->'orders') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(p->'orders')) END;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the date, trips and amount';
  END;
  IF h.vehicle_id IS NULL OR NOT h.active THEN RAISE EXCEPTION 'This vehicle is not hired on rent (Vehicle Master)'; END IF;
  IF v_date IS NULL OR v_date > public.lwb_acc_today() THEN RAISE EXCEPTION 'Choose a date up to today'; END IF;
  IF v_date < h.start_date THEN RAISE EXCEPTION 'Rent of this vehicle starts on %', to_char(h.start_date,'DD/MM/YYYY'); END IF;
  IF v_kind = 'EXTRA' THEN
    IF v_amt IS NULL OR v_amt = 0 OR abs(v_amt) > 500000 THEN RAISE EXCEPTION 'Enter the amount (+ extra, − cut)'; END IF;
    IF length(btrim(coalesce(p->>'remark',''))) < 2 THEN RAISE EXCEPTION 'Write what the amount is for'; END IF;
    INSERT INTO public.lwb_hired_charges (vehicle_id, charge_date, kind, amount, remark, created_by)
    VALUES (h.vehicle_id, v_date, 'EXTRA', round(v_amt, 2), btrim(p->>'remark'), auth.uid()) RETURNING id INTO v_id;
    RETURN v_id;
  END IF;
  IF v_kind <> 'TRIP' THEN RAISE EXCEPTION 'Unknown line'; END IF;
  IF h.rent_type = 'MONTHLY' THEN RAISE EXCEPTION 'This vehicle is on monthly rent: add an Extra line instead of trips'; END IF;
  IF v_trips < 1 OR v_trips > 99 THEN RAISE EXCEPTION 'Trips: 1 to 99'; END IF;
  IF v_extra < 0 OR v_extra > 100000 THEN RAISE EXCEPTION 'Check the extra amount'; END IF;
  IF h.rent_type = 'ROUTE' THEN
    SELECT r.name, r.rate INTO v_route, v_rate FROM public.lwb_hired_routes r
    WHERE r.vehicle_id = h.vehicle_id AND r.active AND lower(btrim(r.name)) = lower(btrim(coalesce(p->>'route','')));
    IF v_route IS NULL THEN RAISE EXCEPTION 'Choose the route'; END IF;
  ELSIF h.rent_type = 'PARTY' THEN
    SELECT q.party_name, q.rate INTO v_route, v_rate FROM public.lwb_hired_party_rates q
    WHERE q.vehicle_id = h.vehicle_id AND q.status = 'VERIFIED' AND q.party_key = public.lwb_hired_pkey(p->>'route');
    IF v_route IS NULL THEN RAISE EXCEPTION 'Choose the party (a new party''s rate is set in Vehicle Master > Trip rent to set)'; END IF;
  ELSE v_rate := h.trip_rate;
  END IF;
  INSERT INTO public.lwb_hired_charges (vehicle_id, charge_date, kind, route_name, party_key, trips, rate, extra, amount, order_nos, remark, created_by)
  VALUES (h.vehicle_id, v_date, 'TRIP', v_route, CASE WHEN h.rent_type = 'PARTY' THEN public.lwb_hired_pkey(v_route) END, v_trips, v_rate, round(v_extra, 2), round(v_trips * v_rate + v_extra, 2),
          v_orders, nullif(btrim(coalesce(p->>'remark','')), ''), auth.uid()) RETURNING id INTO v_id;
  RETURN v_id;
END;
$fn$;

-- Ledger: waiting days of a PARTY vehicle show as lines with no amount (not in the balance).
CREATE OR REPLACE FUNCTION public.lwb_hired_ledger(p_vehicle uuid, p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_hired_vehicles;
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin only'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN RAISE EXCEPTION 'Check the dates'; END IF;
  SELECT * INTO h FROM public.lwb_hired_vehicles x WHERE x.vehicle_id = p_vehicle;
  IF h.vehicle_id IS NULL THEN RAISE EXCEPTION 'This vehicle has no rent setup. Set it in Vehicle Master (Ownership = Hired).'; END IF;
  RETURN jsonb_build_object(
    'vehicle', (SELECT jsonb_build_object('id', v.id, 'no', v.vehicle_no, 'type', v.vehicle_type, 'owner', v.transporter_name,
                 'mobile', v.owner_mobile, 'rent_type', h.rent_type, 'monthly_rent', h.monthly_rent, 'trip_rate', h.trip_rate,
                 'start_date', h.start_date, 'cut_expenses', h.cut_expenses) FROM public.lwb_vehicles v WHERE v.id = p_vehicle),
    'opening', h.opening_balance
       + coalesce((SELECT sum(c.amount) FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.cancelled_at IS NULL AND c.charge_date < p_from), 0)
       - coalesce((SELECT sum(m.amount) FROM public.lwb_hired_money(p_vehicle) m WHERE m.entry_date < p_from), 0),
    'lines', coalesce((SELECT jsonb_agg(l ORDER BY l.date, l.ord, l.at) FROM (
        SELECT c.charge_date AS date, 0 AS ord, c.created_at AS at, 'CHARGE' AS src, c.id::text AS id, c.kind, c.route_name AS route,
               c.trips, c.rate, c.extra, c.amount, c.remark, c.order_nos, NULL::text AS head, NULL::text AS mode, NULL::text AS ref, c.auto
        FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.cancelled_at IS NULL AND c.charge_date BETWEEN p_from AND p_to
        UNION ALL
        SELECT m.entry_date, 1, m.created_at, 'MONEY', m.id::text, m.kind, NULL, NULL, NULL, NULL, -m.amount, m.remark, NULL, m.head, m.mode, m.ref_no, false
        FROM public.lwb_hired_money(p_vehicle) m WHERE m.entry_date BETWEEN p_from AND p_to
        UNION ALL
        SELECT p.trip_date, 2, p.created_at, 'PENDING', p.id::text, CASE WHEN q.status = 'WAITING' THEN 'WAITING' ELSE 'NEED_RATE' END, p.party_name, 1, q.rate, 0, 0::numeric,
               CASE WHEN q.status = 'WAITING' THEN 'Rate ₹' || trim_scale(q.rate)::text || ' waiting for Admin' WHEN q.status = 'SENT_BACK' THEN 'Rate sent back: ' || coalesce(q.note,'') ELSE 'Rate not set yet (Manager)' END,
               p.order_nos, NULL, NULL, NULL, true
        FROM public.lwb_hired_pending p LEFT JOIN public.lwb_hired_party_rates q ON q.vehicle_id = p.vehicle_id AND q.party_key = p.party_key
        WHERE p.vehicle_id = p_vehicle AND p.status = 'NEED_RATE' AND p.trip_date BETWEEN p_from AND p_to) l), '[]'::jsonb)
  );
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_hired_join_trip(uuid,date,text,text,numeric,text), public.lwb_hired_auto_trip(text,date,text,text),
  public.lwb_hired_auto_trip(text,date,text), public.lwb_hired_post_pending(uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_hired_pkey(text), public.lwb_hired_rate_list(), public.lwb_hired_rate_set(uuid,text,numeric,text),
  public.lwb_hired_rate_verify(bigint,boolean,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_hired_pkey(text), public.lwb_hired_rate_list(), public.lwb_hired_rate_set(uuid,text,numeric,text),
  public.lwb_hired_rate_verify(bigint,boolean,numeric,text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'party rates table' AS item, (to_regclass('public.lwb_hired_party_rates') IS NOT NULL)::text AS ok
UNION ALL SELECT 'rate verify', (to_regprocedure('public.lwb_hired_rate_verify(bigint,boolean,numeric,text)') IS NOT NULL)::text;
