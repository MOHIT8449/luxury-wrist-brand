-- LUXURY WRIST BRAND ERP — TRIPS: PORTER / ONE-TIME VEHICLE RENT + MANY PARTIES IN ONE TRIP = ONE RENT
--
-- Runs by itself when merged to main (after lwb_hired_vehicle_rent_setup.sql, lwb_hired_auto_trip_setup.sql,
-- lwb_hired_party_rate_setup.sql). Safe to run again. No table or column is dropped; one index of
-- lwb_hired_party_rate_setup.sql is replaced by one that leaves trip lines out.
--
-- Mohit asked (7 Nov 2026):
--   1) A Porter / one-day / one-trip vehicle is paid at once and the Sales side knows the rent. At driver assignment
--      the vehicle is Own / Transport / Porter. For Porter the rent, how it was paid and who paid are OPTIONAL then;
--      when left empty a popup asks for it later (after 2 hours, and at day close). The rent goes to Accounts
--      ("Porter / one-time rent"), where Book makes the Cash Out (head Vehicle rent).
--   2) 2-3 parties' POs loaded in one vehicle at a time = ONE trip with ONE rent (hired vehicles too).
--      Per party vehicle: the trip rent = the highest verified rate among its parties (Mohit picked this).
--
--   * lwb_vehicle_trips: one row per trip (T-DDMM-NN), vehicle, kind, driver, Porter rent + pay mode + paid by.
--   * dispatch_assignments.trip_id: every PO of the trip points to it.
--   * Hired vehicle (per trip / route / party): a PO with a trip gives one auto rent line per TRIP (not per day /
--     party). A second trip the same day = a second line. Old POs with no trip keep the day rule.
--   * The assignment itself never fails because of the rent part (WARNING only).

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_vehicle_trips (
  id            bigserial PRIMARY KEY,
  trip_date     date NOT NULL,
  seq           integer NOT NULL,
  trip_no       text NOT NULL,
  vehicle_no    text NOT NULL CHECK (length(vehicle_no) BETWEEN 1 AND 40),
  kind          text NOT NULL CHECK (kind IN ('OWN','TRANSPORT','PORTER')),
  driver_name   text CHECK (driver_name IS NULL OR length(driver_name) <= 150),
  driver_mobile text CHECK (driver_mobile IS NULL OR length(driver_mobile) <= 20),
  owner_name    text CHECK (owner_name IS NULL OR length(owner_name) <= 150),
  rent          numeric(14,2) CHECK (rent IS NULL OR (rent > 0 AND rent <= 100000)),
  pay_mode      text CHECK (pay_mode IS NULL OR pay_mode IN ('CASH','ONLINE','ACCOUNTS')),
  paid_by       text CHECK (paid_by IS NULL OR length(paid_by) <= 120),
  note          text CHECK (note IS NULL OR length(note) <= 300),
  rent_by       uuid,
  rent_at       timestamptz,
  acc_entry_id  uuid REFERENCES public.lwb_acc_entries(id) ON DELETE SET NULL,
  booked_by     uuid,
  booked_at     timestamptz,
  status        text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','CANCELLED')),
  cancel_note   text,
  cancelled_by  uuid,
  cancelled_at  timestamptz,
  created_by    uuid,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (trip_date, seq)
);
CREATE INDEX IF NOT EXISTS lwb_vehicle_trips_veh_idx ON public.lwb_vehicle_trips (vehicle_no, trip_date);
ALTER TABLE public.lwb_vehicle_trips ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_vehicle_trips FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_vehicle_trips_id_seq FROM PUBLIC, anon, authenticated;

ALTER TABLE public.dispatch_assignments ADD COLUMN IF NOT EXISTS trip_id bigint REFERENCES public.lwb_vehicle_trips(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS dispatch_assignments_trip_idx ON public.dispatch_assignments (trip_id) WHERE trip_id IS NOT NULL;
ALTER TABLE public.lwb_hired_charges ADD COLUMN IF NOT EXISTS trip_id bigint REFERENCES public.lwb_vehicle_trips(id) ON DELETE SET NULL;
ALTER TABLE public.lwb_hired_pending ADD COLUMN IF NOT EXISTS trip_id bigint REFERENCES public.lwb_vehicle_trips(id) ON DELETE SET NULL;
-- one auto line per vehicle / day / party only for POs with no trip; one line per trip
CREATE UNIQUE INDEX IF NOT EXISTS lwb_hired_charges_auto3_uidx ON public.lwb_hired_charges (vehicle_id, charge_date, coalesce(party_key, ''))
  WHERE kind = 'TRIP' AND auto AND trip_id IS NULL;
DROP INDEX IF EXISTS public.lwb_hired_charges_auto2_uidx;
CREATE UNIQUE INDEX IF NOT EXISTS lwb_hired_charges_trip_uidx ON public.lwb_hired_charges (trip_id) WHERE kind = 'TRIP' AND trip_id IS NOT NULL;

-- Who assigns transport (Transport Allocation / PO Approval & Driver).
CREATE OR REPLACE FUNCTION public.lwb_trip_editor()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','transport'));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_trip_vkey(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) $fn$;

-- POs still waiting to load (a trip with only these can take one more PO).
CREATE OR REPLACE FUNCTION public.lwb_trip_waiting(p_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT lower(btrim(coalesce(p_status, ''))) IN ('approved','approved_next','manager_approved','warehouse_approved','transport_allocated','allocated') $fn$;

-- Booked = a Cash Out entry is made and not cancelled.
CREATE OR REPLACE FUNCTION public.lwb_trip_booked(p_entry uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT p_entry IS NOT NULL AND EXISTS (SELECT 1 FROM public.lwb_acc_entries e WHERE e.id = p_entry AND e.cancelled_at IS NULL) $fn$;

-- ---------------------------------------------------------------------------
-- Hired vehicle rent of one trip: one auto TRIP line for the whole trip.
--   per trip = trip rate, per route = first route, per party = highest VERIFIED rate of the trip's parties
--   (parties with no verified rate wait in "Trip rent to set"; the line follows when the rate is verified).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_trip_sync(p_trip bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE t public.lwb_vehicle_trips; h public.lwb_hired_vehicles; v_orders text[]; v_line public.lwb_hired_charges;
        v_rate numeric; v_route text; r record; v_keys text[] := '{}'; v_names text[] := '{}';
BEGIN
  SELECT * INTO t FROM public.lwb_vehicle_trips x WHERE x.id = p_trip;
  IF t.id IS NULL THEN RETURN; END IF;
  SELECT array_agg(o.order_no ORDER BY o.order_no) INTO v_orders
  FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
  WHERE a.trip_id = t.id AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected');
  -- no PO left: the trip is closed (a booked Porter rent stays as it is)
  IF v_orders IS NULL AND t.status = 'OPEN' AND NOT public.lwb_trip_booked(t.acc_entry_id) THEN
    UPDATE public.lwb_vehicle_trips SET status = 'CANCELLED', cancel_note = 'No PO left on this trip', cancelled_at = now() WHERE id = t.id;
    t.status := 'CANCELLED';
  ELSIF v_orders IS NOT NULL AND t.status = 'CANCELLED' AND t.cancel_note = 'No PO left on this trip' THEN
    UPDATE public.lwb_vehicle_trips SET status = 'OPEN', cancel_note = NULL, cancelled_at = NULL WHERE id = t.id;
    t.status := 'OPEN';
  END IF;

  SELECT x.* INTO h FROM public.lwb_hired_vehicles x JOIN public.lwb_vehicles v ON v.id = x.vehicle_id
  WHERE v.vehicle_no = t.vehicle_no AND x.active AND x.rent_type IN ('TRIP','ROUTE','PARTY');
  SELECT * INTO v_line FROM public.lwb_hired_charges c WHERE c.trip_id = t.id AND c.kind = 'TRIP';

  IF h.vehicle_id IS NOT NULL AND v_orders IS NOT NULL AND t.status = 'OPEN'
     AND t.trip_date >= h.start_date AND t.trip_date <= public.lwb_acc_today() THEN
    IF h.rent_type = 'TRIP' THEN v_rate := h.trip_rate;
    ELSIF h.rent_type = 'ROUTE' THEN
      SELECT x.name, x.rate INTO v_route, v_rate FROM public.lwb_hired_routes x WHERE x.vehicle_id = h.vehicle_id AND x.active ORDER BY x.sort, x.id LIMIT 1;
    ELSE
      FOR r IN SELECT public.lwb_hired_pkey(o.customer_name) AS pk, min(btrim(o.customer_name)) AS party, array_agg(o.order_no ORDER BY o.order_no) AS nos
               FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
               WHERE a.trip_id = t.id AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected')
                 AND length(public.lwb_hired_pkey(o.customer_name)) >= 2
               GROUP BY 1 ORDER BY 2 LOOP
        v_keys := v_keys || r.pk; v_names := v_names || r.party;
        IF EXISTS (SELECT 1 FROM public.lwb_hired_party_rates q WHERE q.vehicle_id = h.vehicle_id AND q.party_key = r.pk AND q.status = 'VERIFIED') THEN
          v_rate := greatest(coalesce(v_rate, 0), (SELECT q.rate FROM public.lwb_hired_party_rates q WHERE q.vehicle_id = h.vehicle_id AND q.party_key = r.pk));
          UPDATE public.lwb_hired_pending SET status = 'DONE' WHERE trip_id = t.id AND party_key = r.pk AND status = 'NEED_RATE';
        ELSE
          INSERT INTO public.lwb_hired_pending AS p (vehicle_id, trip_date, party_key, party_name, order_nos, trip_id)
          VALUES (h.vehicle_id, t.trip_date, r.pk, r.party, r.nos, t.id)
          ON CONFLICT (vehicle_id, trip_date, party_key) DO UPDATE
            SET order_nos = ARRAY(SELECT DISTINCT x FROM unnest(p.order_nos || EXCLUDED.order_nos) x ORDER BY 1),
                trip_id = EXCLUDED.trip_id, status = CASE WHEN p.status = 'CANCELLED' THEN 'NEED_RATE' ELSE p.status END;
        END IF;
      END LOOP;
      v_route := left(array_to_string(v_names, ', '), 60);
      UPDATE public.lwb_hired_pending SET status = 'CANCELLED'
      WHERE trip_id = t.id AND status = 'NEED_RATE' AND NOT (party_key = ANY (v_keys));
    END IF;
  END IF;

  IF coalesce(v_rate, 0) <= 0 THEN
    -- not a hired vehicle any more / no PO / no verified rate yet: the auto line goes out
    IF v_line.id IS NOT NULL AND v_line.cancelled_at IS NULL AND v_line.auto THEN
      UPDATE public.lwb_hired_charges SET cancelled_at = now(), cancel_note = 'Order moved to another vehicle', order_nos = v_orders WHERE id = v_line.id;
    END IF;
    IF h.vehicle_id IS NULL OR v_orders IS NULL OR t.status <> 'OPEN' THEN
      UPDATE public.lwb_hired_pending SET status = 'CANCELLED' WHERE trip_id = t.id AND status = 'NEED_RATE';
    END IF;
    RETURN;
  END IF;

  IF v_line.id IS NOT NULL THEN
    IF v_line.cancelled_at IS NOT NULL AND coalesce(v_line.cancel_note, '') <> 'Order moved to another vehicle' THEN
      UPDATE public.lwb_hired_charges SET order_nos = v_orders WHERE id = v_line.id;   -- cancelled by Accounts: stays cancelled
      RETURN;
    END IF;
    UPDATE public.lwb_hired_charges SET cancelled_at = NULL, cancelled_by = NULL, cancel_note = NULL, order_nos = v_orders,
           vehicle_id = h.vehicle_id, charge_date = t.trip_date, route_name = v_route, rate = v_rate, trips = 1,
           amount = v_rate + coalesce(extra, 0), remark = 'Auto · Trip ' || t.trip_no
    WHERE id = v_line.id;
  ELSE
    INSERT INTO public.lwb_hired_charges (vehicle_id, charge_date, kind, route_name, trips, rate, extra, amount, order_nos, remark, auto, trip_id)
    VALUES (h.vehicle_id, t.trip_date, 'TRIP', v_route, 1, v_rate, 0, v_rate, v_orders, 'Auto · Trip ' || t.trip_no, true, t.id);
  END IF;
END;
$fn$;

-- Transport assignment changed: trip POs follow their trip, POs with no trip keep the old day rule.
CREATE OR REPLACE FUNCTION public.lwb_hired_assignment_trip()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_order text; v_party text; v_status text; v_day date; v_old_day date; v_same boolean;
BEGIN
  BEGIN
    SELECT o.order_no, o.customer_name, lower(coalesce(o.status,'')) INTO v_order, v_party, v_status FROM public.orders o WHERE o.id = NEW.order_id;
    v_day := (coalesce(NEW.assigned_at, now()) AT TIME ZONE 'Asia/Kolkata')::date;
    IF TG_OP = 'UPDATE' THEN
      v_old_day := (coalesce(OLD.assigned_at, now()) AT TIME ZONE 'Asia/Kolkata')::date;
      v_same := public.lwb_trip_vkey(OLD.vehicle_no) IS NOT DISTINCT FROM public.lwb_trip_vkey(NEW.vehicle_no) AND v_old_day = v_day;
      IF v_same AND OLD.trip_id IS NOT DISTINCT FROM NEW.trip_id THEN RETURN NEW; END IF;
      IF OLD.trip_id IS NULL THEN PERFORM public.lwb_hired_auto_untrip(OLD.vehicle_no, v_old_day, v_order);
      ELSIF OLD.trip_id IS DISTINCT FROM NEW.trip_id THEN PERFORM public.lwb_trip_sync(OLD.trip_id);
      END IF;
    END IF;
    IF NEW.trip_id IS NOT NULL THEN PERFORM public.lwb_trip_sync(NEW.trip_id); RETURN NEW; END IF;
    IF v_status IN ('cancelled','canceled','rejected') THEN RETURN NEW; END IF;
    PERFORM public.lwb_hired_auto_trip(NEW.vehicle_no, v_day, v_order, v_party);
  EXCEPTION WHEN others THEN
    RAISE WARNING 'hired auto trip skipped: %', SQLERRM;
  END;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS trg_lwb_hired_assignment_trip ON public.dispatch_assignments;
CREATE TRIGGER trg_lwb_hired_assignment_trip
AFTER INSERT OR UPDATE OF vehicle_no, assigned_at, trip_id
ON public.dispatch_assignments
FOR EACH ROW
EXECUTE FUNCTION public.lwb_hired_assignment_trip();

-- Verified rate: waiting days go in the ledger; waiting parties of a trip re-count that trip's one line.
CREATE OR REPLACE FUNCTION public.lwb_hired_post_pending(p_vehicle uuid, p_party_key text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE q public.lwb_hired_party_rates; p record; o text; v_line bigint; v_n integer := 0;
BEGIN
  SELECT * INTO q FROM public.lwb_hired_party_rates r WHERE r.vehicle_id = p_vehicle AND r.party_key = p_party_key AND r.status = 'VERIFIED';
  IF q.id IS NULL THEN RETURN 0; END IF;
  FOR p IN SELECT * FROM public.lwb_hired_pending x WHERE x.vehicle_id = p_vehicle AND x.party_key = p_party_key AND x.status = 'NEED_RATE' ORDER BY x.trip_date LOOP
    IF p.trip_id IS NOT NULL THEN
      UPDATE public.lwb_hired_pending SET status = 'DONE' WHERE id = p.id;
      PERFORM public.lwb_trip_sync(p.trip_id);
      UPDATE public.lwb_hired_pending SET charge_id = (SELECT c.id FROM public.lwb_hired_charges c WHERE c.trip_id = p.trip_id AND c.kind = 'TRIP') WHERE id = p.id;
    ELSE
      v_line := NULL;
      IF cardinality(p.order_nos) = 0 THEN v_line := public.lwb_hired_join_trip(p_vehicle, p.trip_date, p_party_key, q.party_name, q.rate, NULL);
      ELSE FOREACH o IN ARRAY p.order_nos LOOP v_line := coalesce(public.lwb_hired_join_trip(p_vehicle, p.trip_date, p_party_key, q.party_name, q.rate, o), v_line); END LOOP;
      END IF;
      UPDATE public.lwb_hired_pending SET status = 'DONE', charge_id = v_line WHERE id = p.id;
    END IF;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$fn$;

-- Fill the auto trips of one hired vehicle from its start date (trips by trip, old POs by day).
CREATE OR REPLACE FUNCTION public.lwb_hired_auto_fill(p_vehicle uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_hired_vehicles; v_no text; r record; v_before integer; v_after integer;
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin only'; END IF;
  SELECT x.* INTO h FROM public.lwb_hired_vehicles x WHERE x.vehicle_id = p_vehicle;
  SELECT v.vehicle_no INTO v_no FROM public.lwb_vehicles v WHERE v.id = p_vehicle;
  IF h.vehicle_id IS NULL OR NOT h.active OR h.rent_type NOT IN ('TRIP','ROUTE','PARTY') THEN RETURN 0; END IF;
  SELECT (SELECT count(*) FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.kind = 'TRIP' AND c.cancelled_at IS NULL)
       + (SELECT count(*) FROM public.lwb_hired_pending p WHERE p.vehicle_id = p_vehicle) INTO v_before;
  FOR r IN SELECT (a.assigned_at AT TIME ZONE 'Asia/Kolkata')::date AS day, o.order_no, o.customer_name
           FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
           WHERE public.lwb_trip_vkey(a.vehicle_no) = v_no AND a.trip_id IS NULL
             AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected')
             AND (a.assigned_at AT TIME ZONE 'Asia/Kolkata')::date >= greatest(h.start_date, public.lwb_acc_today() - 62)
           ORDER BY a.assigned_at LOOP
    PERFORM public.lwb_hired_auto_trip(v_no, r.day, r.order_no, r.customer_name);
  END LOOP;
  FOR r IN SELECT t.id FROM public.lwb_vehicle_trips t
           WHERE t.vehicle_no = v_no AND t.status = 'OPEN' AND t.trip_date >= greatest(h.start_date, public.lwb_acc_today() - 62) ORDER BY t.id LOOP
    PERFORM public.lwb_trip_sync(r.id);
  END LOOP;
  SELECT (SELECT count(*) FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.kind = 'TRIP' AND c.cancelled_at IS NULL)
       + (SELECT count(*) FROM public.lwb_hired_pending p WHERE p.vehicle_id = p_vehicle) INTO v_after;
  RETURN greatest(v_after - v_before, 0);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Trips for the assignment pages
-- ---------------------------------------------------------------------------
-- Today's trip of this vehicle that can take one more PO (none of its POs loaded yet). NULL = none.
CREATE OR REPLACE FUNCTION public.lwb_trip_find(p_vehicle_no text, p_skip_order text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_key text := public.lwb_trip_vkey(p_vehicle_no);
BEGIN
  IF NOT public.lwb_trip_editor() THEN RAISE EXCEPTION 'Only Admin / Manager / Transport assign trips'; END IF;
  IF v_key = '' THEN RETURN NULL; END IF;
  RETURN (SELECT jsonb_build_object('id', t.id, 'trip_no', t.trip_no, 'kind', t.kind, 'rent', t.rent, 'pay_mode', t.pay_mode,
            'paid_by', t.paid_by, 'owner', t.owner_name,
            'orders', (SELECT jsonb_agg(jsonb_build_object('order_no', o.order_no, 'party', o.customer_name) ORDER BY o.order_no)
                       FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
                       WHERE a.trip_id = t.id AND a.order_id::text IS DISTINCT FROM p_skip_order
                         AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected')))
    FROM public.lwb_vehicle_trips t
    WHERE t.vehicle_no = v_key AND t.status = 'OPEN' AND t.trip_date = public.lwb_acc_today()
      AND EXISTS (SELECT 1 FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
                  WHERE a.trip_id = t.id AND a.order_id::text IS DISTINCT FROM p_skip_order
                    AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected'))
      AND NOT EXISTS (SELECT 1 FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
                      WHERE a.trip_id = t.id AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected')
                        AND NOT public.lwb_trip_waiting(o.status))
    ORDER BY t.id DESC LIMIT 1);
END;
$fn$;

-- Make / pick the trip before the PO's assignment is saved; the page then saves dispatch_assignments.trip_id.
-- p: {vehicle_no, kind OWN|TRANSPORT|PORTER (blank = from Vehicle Master), driver_name, driver_mobile, owner,
--     trip_id (join this trip) | join true (today's open trip of the vehicle, else a new one) | order_id (keep its trip),
--     rent, pay_mode CASH|ONLINE|ACCOUNTS, paid_by (Porter only, all optional; keys left out = kept)}
CREATE OR REPLACE FUNCTION public.lwb_trip_open(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_key text := public.lwb_trip_vkey(p->>'vehicle_no'); v_kind text := upper(btrim(coalesce(p->>'kind','')));
        t public.lwb_vehicle_trips; v_id bigint; v_today date := public.lwb_acc_today(); v_seq integer; v_own text;
        v_rent numeric; v_mode text; v_rent_given boolean := p ? 'rent'; v_found jsonb;
BEGIN
  IF NOT public.lwb_trip_editor() THEN RAISE EXCEPTION 'Only Admin / Manager / Transport assign trips'; END IF;
  IF v_key = '' THEN RAISE EXCEPTION 'Enter the vehicle number'; END IF;
  IF v_kind = '' THEN
    SELECT v.ownership INTO v_own FROM public.lwb_vehicles v WHERE v.vehicle_no = v_key;
    v_kind := CASE WHEN v_own IS NULL THEN 'PORTER' WHEN v_own = 'TRANSPORTER' THEN 'TRANSPORT' ELSE 'OWN' END;
  END IF;
  IF v_kind NOT IN ('OWN','TRANSPORT','PORTER') THEN RAISE EXCEPTION 'Vehicle: Own, Transport or Porter'; END IF;
  BEGIN v_rent := nullif(btrim(coalesce(p->>'rent','')), '')::numeric;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the rent';
  END;
  IF v_rent IS NOT NULL AND (v_rent <= 0 OR v_rent > 100000) THEN RAISE EXCEPTION 'Rent: 1 to 1,00,000'; END IF;
  v_mode := nullif(upper(btrim(coalesce(p->>'pay_mode',''))), '');
  IF v_mode IS NOT NULL AND v_mode NOT IN ('CASH','ONLINE','ACCOUNTS') THEN RAISE EXCEPTION 'Paid: Cash now, Online or Accounts later'; END IF;

  -- which trip
  IF nullif(p->>'trip_id','') IS NOT NULL THEN
    SELECT * INTO t FROM public.lwb_vehicle_trips x WHERE x.id = (p->>'trip_id')::bigint;
    IF t.id IS NULL OR t.status <> 'OPEN' THEN RAISE EXCEPTION 'That trip is closed. Save as a new trip.'; END IF;
    IF t.vehicle_no <> v_key THEN RAISE EXCEPTION 'Trip % is on vehicle %', t.trip_no, t.vehicle_no; END IF;
  ELSE
    IF nullif(p->>'order_id','') IS NOT NULL AND coalesce((p->>'new')::boolean, false) = false THEN
      SELECT x.* INTO t FROM public.dispatch_assignments a JOIN public.lwb_vehicle_trips x ON x.id = a.trip_id
      WHERE a.order_id::text = p->>'order_id' AND x.vehicle_no = v_key AND x.status = 'OPEN' LIMIT 1;
    END IF;
    IF t.id IS NULL AND coalesce((p->>'join')::boolean, false) THEN
      v_found := public.lwb_trip_find(v_key, p->>'order_id');
      IF v_found IS NOT NULL THEN SELECT * INTO t FROM public.lwb_vehicle_trips x WHERE x.id = (v_found->>'id')::bigint; END IF;
    END IF;
  END IF;

  IF t.id IS NULL THEN
    LOOP
      SELECT coalesce(max(x.seq), 0) + 1 INTO v_seq FROM public.lwb_vehicle_trips x WHERE x.trip_date = v_today;
      BEGIN
        INSERT INTO public.lwb_vehicle_trips (trip_date, seq, trip_no, vehicle_no, kind, driver_name, driver_mobile, owner_name,
                                              rent, pay_mode, paid_by, rent_by, rent_at, created_by)
        VALUES (v_today, v_seq, 'T-' || to_char(v_today, 'DDMM') || '-' || lpad(v_seq::text, 2, '0'), v_key, v_kind,
                nullif(btrim(coalesce(p->>'driver_name','')), ''), nullif(btrim(coalesce(p->>'driver_mobile','')), ''),
                nullif(btrim(coalesce(p->>'owner','')), ''),
                CASE WHEN v_kind = 'PORTER' THEN round(v_rent, 2) END, CASE WHEN v_kind = 'PORTER' THEN v_mode END,
                CASE WHEN v_kind = 'PORTER' THEN left(nullif(btrim(coalesce(p->>'paid_by','')), ''), 120) END,
                CASE WHEN v_kind = 'PORTER' AND v_rent IS NOT NULL THEN auth.uid() END,
                CASE WHEN v_kind = 'PORTER' AND v_rent IS NOT NULL THEN now() END, auth.uid())
        RETURNING id INTO v_id;
        EXIT;
      EXCEPTION WHEN unique_violation THEN NULL;  -- someone took this number at the same moment: next one
      END;
    END LOOP;
    SELECT * INTO t FROM public.lwb_vehicle_trips x WHERE x.id = v_id;
  ELSE
    IF public.lwb_trip_booked(t.acc_entry_id) AND v_rent_given AND v_rent IS DISTINCT FROM t.rent THEN
      RAISE EXCEPTION 'Rent of trip % is already booked by Accounts. Ask Accounts to cancel that Cash Out first.', t.trip_no;
    END IF;
    UPDATE public.lwb_vehicle_trips x SET kind = v_kind,
      driver_name = coalesce(nullif(btrim(coalesce(p->>'driver_name','')), ''), x.driver_name),
      driver_mobile = coalesce(nullif(btrim(coalesce(p->>'driver_mobile','')), ''), x.driver_mobile),
      owner_name = CASE WHEN p ? 'owner' THEN nullif(btrim(coalesce(p->>'owner','')), '') ELSE x.owner_name END,
      rent = CASE WHEN v_kind <> 'PORTER' THEN NULL WHEN v_rent_given THEN round(v_rent, 2) ELSE x.rent END,
      pay_mode = CASE WHEN v_kind <> 'PORTER' THEN NULL WHEN p ? 'pay_mode' THEN v_mode ELSE x.pay_mode END,
      paid_by = CASE WHEN v_kind <> 'PORTER' THEN NULL WHEN p ? 'paid_by' THEN left(nullif(btrim(coalesce(p->>'paid_by','')), ''), 120) ELSE x.paid_by END,
      rent_by = CASE WHEN v_rent_given AND v_rent IS DISTINCT FROM x.rent THEN auth.uid() ELSE x.rent_by END,
      rent_at = CASE WHEN v_rent_given AND v_rent IS DISTINCT FROM x.rent THEN now() ELSE x.rent_at END
    WHERE x.id = t.id RETURNING * INTO t;
  END IF;
  RETURN jsonb_build_object('id', t.id, 'trip_no', t.trip_no, 'kind', t.kind, 'rent', t.rent, 'pay_mode', t.pay_mode, 'paid_by', t.paid_by);
END;
$fn$;

-- Trip of POs (for the lists): [{order_id, trip_id, trip_no, kind, rent, pay_mode, paid_by, owner, pos}]
CREATE OR REPLACE FUNCTION public.lwb_trip_of_orders(p_order_ids text[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_trip_editor() AND NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'You can not read trips'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('order_id', a.order_id, 'trip_id', t.id, 'trip_no', t.trip_no, 'kind', t.kind, 'rent', t.rent,
      'pay_mode', t.pay_mode, 'paid_by', t.paid_by, 'owner', t.owner_name,
      'pos', (SELECT count(*) FROM public.dispatch_assignments b WHERE b.trip_id = t.id)))
    FROM public.dispatch_assignments a JOIN public.lwb_vehicle_trips t ON t.id = a.trip_id
    WHERE a.order_id::text = ANY (coalesce(p_order_ids, '{}'))), '[]'::jsonb);
END;
$fn$;

-- Porter trips of mine with no rent yet (the "fill the rent" popup). due = 2 hours old, an older day, or day close (7 pm).
CREATE OR REPLACE FUNCTION public.lwb_trip_rent_due()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_trip_editor() THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'trip_no', t.trip_no, 'date', t.trip_date, 'vehicle_no', t.vehicle_no,
      'driver', t.driver_name, 'mobile', t.driver_mobile, 'owner', t.owner_name, 'pay_mode', t.pay_mode, 'paid_by', t.paid_by, 'created_at', t.created_at,
      'due', t.created_at < now() - interval '2 hours' OR t.trip_date < public.lwb_acc_today()
             OR (now() AT TIME ZONE 'Asia/Kolkata')::time >= time '19:00',
      'orders', (SELECT jsonb_agg(jsonb_build_object('order_no', o.order_no, 'party', o.customer_name) ORDER BY o.order_no)
                 FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id WHERE a.trip_id = t.id))
      ORDER BY t.id)
    FROM public.lwb_vehicle_trips t
    WHERE t.kind = 'PORTER' AND t.status = 'OPEN' AND t.rent IS NULL AND t.created_by = auth.uid()
      AND t.trip_date >= public.lwb_acc_today() - 15
      AND EXISTS (SELECT 1 FROM public.dispatch_assignments a WHERE a.trip_id = t.id)), '[]'::jsonb);
END;
$fn$;

-- Fill / change the Porter rent later (who assigned, Admin / Manager, or Accounts). Not after it is booked.
CREATE OR REPLACE FUNCTION public.lwb_trip_rent_set(p_trip bigint, p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE t public.lwb_vehicle_trips; v_rent numeric; v_mode text := nullif(upper(btrim(coalesce(p->>'pay_mode',''))), '');
BEGIN
  IF NOT (public.lwb_trip_editor() OR public.lwb_acc_user()) THEN RAISE EXCEPTION 'Only Admin / Manager / Transport / Accounts set the trip rent'; END IF;
  SELECT * INTO t FROM public.lwb_vehicle_trips x WHERE x.id = p_trip FOR UPDATE;
  IF t.id IS NULL OR t.status <> 'OPEN' THEN RAISE EXCEPTION 'Trip not found or closed'; END IF;
  IF t.kind <> 'PORTER' THEN RAISE EXCEPTION 'Rent is entered only for a Porter / one-time vehicle'; END IF;
  IF public.lwb_trip_booked(t.acc_entry_id) THEN RAISE EXCEPTION 'Rent of trip % is already booked by Accounts', t.trip_no; END IF;
  BEGIN v_rent := nullif(btrim(coalesce(p->>'rent','')), '')::numeric;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the rent';
  END;
  IF v_rent IS NULL OR v_rent <= 0 OR v_rent > 100000 THEN RAISE EXCEPTION 'Enter the rent of this trip'; END IF;
  IF v_mode IS NOT NULL AND v_mode NOT IN ('CASH','ONLINE','ACCOUNTS') THEN RAISE EXCEPTION 'Paid: Cash now, Online or Accounts later'; END IF;
  UPDATE public.lwb_vehicle_trips SET rent = round(v_rent, 2), pay_mode = coalesce(v_mode, pay_mode),
    paid_by = CASE WHEN p ? 'paid_by' THEN left(nullif(btrim(coalesce(p->>'paid_by','')), ''), 120) ELSE paid_by END,
    owner_name = CASE WHEN p ? 'owner' THEN nullif(btrim(coalesce(p->>'owner','')), '') ELSE owner_name END,
    note = CASE WHEN p ? 'note' THEN left(nullif(btrim(coalesce(p->>'note','')), ''), 300) ELSE note END,
    rent_by = auth.uid(), rent_at = now()
  WHERE id = t.id;
END;
$fn$;

-- Accounts: Porter / one-time trips (dates, plus every not-booked one of the last 60 days).
CREATE OR REPLACE FUNCTION public.lwb_trip_rent_list(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Porter rent is for Accounts / Admin only'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN RAISE EXCEPTION 'Check the dates'; END IF;
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x.st_ord, x.date DESC, x.id DESC) FROM (
    SELECT t.id, t.trip_no, t.trip_date AS date, t.vehicle_no, t.driver_name AS driver, t.driver_mobile AS mobile, t.owner_name AS owner,
      t.rent, t.pay_mode, t.paid_by, t.note,
      (SELECT u.full_name FROM public.user_profiles u WHERE u.id = t.created_by) AS by_name,
      (SELECT u.full_name FROM public.user_profiles u WHERE u.id = t.rent_by) AS rent_by_name,
      CASE WHEN t.status = 'CANCELLED' THEN 'CANCELLED' WHEN public.lwb_trip_booked(t.acc_entry_id) THEN 'BOOKED'
           WHEN t.rent IS NULL THEN 'NO_RENT' ELSE 'TO_BOOK' END AS status,
      CASE WHEN t.status = 'CANCELLED' THEN 4 WHEN public.lwb_trip_booked(t.acc_entry_id) THEN 3 WHEN t.rent IS NULL THEN 2 ELSE 1 END AS st_ord,
      t.cancel_note,
      (SELECT jsonb_build_object('date', e.entry_date, 'mode', e.mode, 'amount', e.amount) FROM public.lwb_acc_entries e
        WHERE e.id = t.acc_entry_id AND e.cancelled_at IS NULL) AS entry,
      coalesce((SELECT jsonb_agg(jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'party', o.customer_name) ORDER BY o.order_no)
        FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id WHERE a.trip_id = t.id), '[]'::jsonb) AS orders
    FROM public.lwb_vehicle_trips t
    WHERE t.kind = 'PORTER'
      AND (t.trip_date BETWEEN p_from AND p_to
           OR (t.status = 'OPEN' AND NOT public.lwb_trip_booked(t.acc_entry_id) AND t.trip_date >= public.lwb_acc_today() - 60))
      AND (EXISTS (SELECT 1 FROM public.dispatch_assignments a WHERE a.trip_id = t.id) OR t.acc_entry_id IS NOT NULL)
  ) x), '[]'::jsonb);
END;
$fn$;

-- Accounts books the Porter rent: one Cash Out with head Vehicle rent (party = Porter · vehicle no.).
-- p: {date, mode CASH|UPI|BANK|RTGS|CHEQUE, bank_id, ref, amount (blank = trip rent)}
CREATE OR REPLACE FUNCTION public.lwb_trip_rent_book(p_trip bigint, p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE t public.lwb_vehicle_trips; v_amt numeric; v_cat bigint; v_entry uuid; v_orders text;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only Accounts / Admin book the rent'; END IF;
  SELECT * INTO t FROM public.lwb_vehicle_trips x WHERE x.id = p_trip FOR UPDATE;
  IF t.id IS NULL OR t.status <> 'OPEN' THEN RAISE EXCEPTION 'Trip not found or cancelled'; END IF;
  IF t.kind <> 'PORTER' THEN RAISE EXCEPTION 'Only Porter / one-time rent is booked here'; END IF;
  IF public.lwb_trip_booked(t.acc_entry_id) THEN RAISE EXCEPTION 'Rent of trip % is already booked', t.trip_no; END IF;
  BEGIN v_amt := coalesce(nullif(btrim(coalesce(p->>'amount','')), '')::numeric, t.rent);
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the amount';
  END;
  IF v_amt IS NULL OR v_amt <= 0 OR v_amt > 100000 THEN RAISE EXCEPTION 'Enter the rent of this trip'; END IF;
  SELECT c.id INTO v_cat FROM public.lwb_acc_categories c WHERE c.kind = 'OUT' AND lower(btrim(c.name)) = 'vehicle rent' AND c.active ORDER BY c.id LIMIT 1;
  IF v_cat IS NULL THEN RAISE EXCEPTION 'Head "Vehicle rent" is missing in Cash Out heads'; END IF;
  SELECT string_agg(o.order_no || ' ' || coalesce(o.customer_name, ''), ', ' ORDER BY o.order_no) INTO v_orders
  FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id WHERE a.trip_id = t.id;
  v_entry := public.lwb_acc_add_entry(jsonb_build_object(
    'date', coalesce(nullif(p->>'date',''), public.lwb_acc_today()::text), 'kind', 'OUT', 'category_id', v_cat,
    'mode', coalesce(nullif(upper(p->>'mode'),''), CASE WHEN t.pay_mode = 'ONLINE' THEN 'UPI' ELSE 'CASH' END),
    'bank_id', nullif(p->>'bank_id',''), 'ref', nullif(btrim(coalesce(p->>'ref','')), ''), 'amount', round(v_amt, 2),
    'party', left(coalesce(t.owner_name, 'Porter') || ' · ' || t.vehicle_no, 120),
    'remark', left('Trip ' || t.trip_no || ' (' || to_char(t.trip_date, 'DD/MM') || ')' || coalesce(' · ' || t.driver_name, '')
                   || coalesce(' · paid by ' || t.paid_by, '') || coalesce(' · ' || v_orders, ''), 300)));
  UPDATE public.lwb_vehicle_trips SET acc_entry_id = v_entry, booked_by = auth.uid(), booked_at = now(),
    rent = round(v_amt, 2), rent_by = CASE WHEN rent IS DISTINCT FROM round(v_amt, 2) THEN auth.uid() ELSE rent_by END,
    rent_at = CASE WHEN rent IS DISTINCT FROM round(v_amt, 2) THEN now() ELSE rent_at END
  WHERE id = t.id;
  RETURN v_entry;
END;
$fn$;

-- Accounts: no rent for this trip (e.g. Porter not used / paid by the party). Kept as cancelled with the reason.
CREATE OR REPLACE FUNCTION public.lwb_trip_rent_cancel(p_trip bigint, p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE t public.lwb_vehicle_trips;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only Accounts / Admin'; END IF;
  IF length(btrim(coalesce(p_note,''))) < 3 THEN RAISE EXCEPTION 'Write why there is no rent'; END IF;
  SELECT * INTO t FROM public.lwb_vehicle_trips x WHERE x.id = p_trip FOR UPDATE;
  IF t.id IS NULL OR t.kind <> 'PORTER' THEN RAISE EXCEPTION 'Trip not found'; END IF;
  IF public.lwb_trip_booked(t.acc_entry_id) THEN RAISE EXCEPTION 'Rent is booked. Cancel that Cash Out entry first.'; END IF;
  UPDATE public.lwb_vehicle_trips SET status = 'CANCELLED', cancel_note = left(btrim(p_note), 200), cancelled_by = auth.uid(), cancelled_at = now()
  WHERE id = t.id;
END;
$fn$;

-- Ledger lines carry the trip no.
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
               c.trips, c.rate, c.extra, c.amount, c.remark, c.order_nos, NULL::text AS head, NULL::text AS mode, NULL::text AS ref, c.auto,
               (SELECT t.trip_no FROM public.lwb_vehicle_trips t WHERE t.id = c.trip_id) AS trip_no
        FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.cancelled_at IS NULL AND c.charge_date BETWEEN p_from AND p_to
        UNION ALL
        SELECT m.entry_date, 1, m.created_at, 'MONEY', m.id::text, m.kind, NULL, NULL, NULL, NULL, -m.amount, m.remark, NULL, m.head, m.mode, m.ref_no, false, NULL
        FROM public.lwb_hired_money(p_vehicle) m WHERE m.entry_date BETWEEN p_from AND p_to
        UNION ALL
        SELECT p.trip_date, 2, p.created_at, 'PENDING', p.id::text, CASE WHEN q.status = 'WAITING' THEN 'WAITING' ELSE 'NEED_RATE' END, p.party_name, 1, q.rate, 0, 0::numeric,
               CASE WHEN q.status = 'WAITING' THEN 'Rate ₹' || trim_scale(q.rate)::text || ' waiting for Admin' WHEN q.status = 'SENT_BACK' THEN 'Rate sent back: ' || coalesce(q.note,'') ELSE 'Rate not set yet (Manager)' END,
               p.order_nos, NULL, NULL, NULL, true, (SELECT t.trip_no FROM public.lwb_vehicle_trips t WHERE t.id = p.trip_id)
        FROM public.lwb_hired_pending p LEFT JOIN public.lwb_hired_party_rates q ON q.vehicle_id = p.vehicle_id AND q.party_key = p.party_key
        WHERE p.vehicle_id = p_vehicle AND p.status = 'NEED_RATE' AND p.trip_date BETWEEN p_from AND p_to) l), '[]'::jsonb)
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_trip_sync(bigint), public.lwb_trip_booked(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_trip_editor(), public.lwb_trip_vkey(text), public.lwb_trip_waiting(text), public.lwb_trip_find(text,text),
  public.lwb_trip_open(jsonb), public.lwb_trip_of_orders(text[]), public.lwb_trip_rent_due(), public.lwb_trip_rent_set(bigint,jsonb),
  public.lwb_trip_rent_list(date,date), public.lwb_trip_rent_book(bigint,jsonb), public.lwb_trip_rent_cancel(bigint,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_trip_editor(), public.lwb_trip_vkey(text), public.lwb_trip_waiting(text), public.lwb_trip_find(text,text),
  public.lwb_trip_open(jsonb), public.lwb_trip_of_orders(text[]), public.lwb_trip_rent_due(), public.lwb_trip_rent_set(bigint,jsonb),
  public.lwb_trip_rent_list(date,date), public.lwb_trip_rent_book(bigint,jsonb), public.lwb_trip_rent_cancel(bigint,text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'trips table' AS item, (to_regclass('public.lwb_vehicle_trips') IS NOT NULL)::text AS ok
UNION ALL SELECT 'dispatch_assignments.trip_id', EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
  AND table_name = 'dispatch_assignments' AND column_name = 'trip_id')::text
UNION ALL SELECT 'trip open', (to_regprocedure('public.lwb_trip_open(jsonb)') IS NOT NULL)::text;
