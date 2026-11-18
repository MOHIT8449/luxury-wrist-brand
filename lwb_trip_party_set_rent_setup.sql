-- Trip rent of per party hired vehicles: two or more parties on one trip get their own rent (18 Nov 2026).
--
-- Mohit: once a rent is set for Umesh's vehicle to Shree Jagdish, the next trip to Shree Jagdish uses it (no question).
-- But when the vehicle goes to Shree Jagdish and Devnarayan together, ask the rent of that trip; set once, the same
-- set of parties uses it again. After Transport Assignment, a popup asks the rent (Vishal enters it the same day).
--   * lwb_trip_sync: a trip with 2+ parties looks for the rate of the set "A + B" (party keys in name order);
--     with no rate it waits in "Trip rent to set" as that set. One party: as before.
--   * lwb_trip_rent_todo(): trips waiting for a rent (Admin / Manager / Transport), for the popup.
--   * lwb_trip_rent_set(pending, rate): Admin = verified and posted; Manager / Transport = waits for Admin to verify.
-- Run after lwb_trip_rent_setup.sql and lwb_rent_km_chart_setup.sql. Safe to run again.
BEGIN;

-- a set of parties needs a longer key
DO $do$
DECLARE c record;
BEGIN
  FOR c IN SELECT conrelid::regclass::text AS t, conname FROM pg_constraint
           WHERE contype = 'c' AND conrelid IN ('public.lwb_hired_party_rates'::regclass, 'public.lwb_hired_pending'::regclass, 'public.lwb_hired_rate_card'::regclass)
             AND pg_get_constraintdef(oid) LIKE '%length(party_key)%' AND pg_get_constraintdef(oid) LIKE '%150%' LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', c.t, c.conname);
  END LOOP;
END
$do$;
ALTER TABLE public.lwb_hired_party_rates DROP CONSTRAINT IF EXISTS lwb_hired_party_rates_key_len;
ALTER TABLE public.lwb_hired_party_rates ADD CONSTRAINT lwb_hired_party_rates_key_len CHECK (length(party_key) BETWEEN 2 AND 1000);

CREATE OR REPLACE FUNCTION public.lwb_trip_sync(p_trip bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE t public.lwb_vehicle_trips; h public.lwb_hired_vehicles; v_orders text[]; v_line public.lwb_hired_charges;
        v_rate numeric; v_route text; v_keys text[] := '{}'; v_names text[] := '{}'; v_ckey text; v_cname text; v_np integer;
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
      -- one party: that party's rate. Two or more parties together: the rate of that set of parties
      -- (key "A + B", parties in name order), asked once and used again for the same set.
      SELECT string_agg(z.pk, ' + ' ORDER BY z.pk), string_agg(z.party, ' + ' ORDER BY z.pk), count(*) INTO v_ckey, v_cname, v_np
      FROM (SELECT public.lwb_hired_pkey(o.customer_name) AS pk, min(btrim(o.customer_name)) AS party
            FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
            WHERE a.trip_id = t.id AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected')
              AND length(public.lwb_hired_pkey(o.customer_name)) >= 2
            GROUP BY 1) z;
      IF v_np > 0 THEN
        v_keys := ARRAY[v_ckey];
        SELECT string_to_array(v_cname, ' + ') INTO v_names;
        SELECT q.rate INTO v_rate FROM public.lwb_hired_party_rates q WHERE q.vehicle_id = h.vehicle_id AND q.party_key = v_ckey AND q.status = 'VERIFIED';
        IF v_rate IS NOT NULL THEN
          UPDATE public.lwb_hired_pending SET status = 'DONE' WHERE trip_id = t.id AND party_key = v_ckey AND status = 'NEED_RATE';
        ELSE
          INSERT INTO public.lwb_hired_pending AS p (vehicle_id, trip_date, party_key, party_name, order_nos, trip_id)
          VALUES (h.vehicle_id, t.trip_date, v_ckey, v_cname, v_orders, t.id)
          ON CONFLICT (vehicle_id, trip_date, party_key) DO UPDATE
            SET order_nos = ARRAY(SELECT DISTINCT x FROM unnest(p.order_nos || EXCLUDED.order_nos) x ORDER BY 1),
                party_name = EXCLUDED.party_name,
                trip_id = EXCLUDED.trip_id, status = CASE WHEN p.status = 'CANCELLED' THEN 'NEED_RATE' ELSE p.status END;
        END IF;
      END IF;
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

-- Trips that wait for a rent (no rate, or the rate was sent back), newest first. For the popup after Transport Assignment.
CREATE OR REPLACE FUNCTION public.lwb_trip_rent_todo()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles u WHERE u.id = auth.uid() AND u.active AND lower(btrim(u.role)) IN ('admin','manager','transport')) THEN
    RETURN jsonb_build_object('rows', '[]'::jsonb, 'is_admin', false);
  END IF;
  RETURN jsonb_build_object('is_admin', public.lwb_acc_admin(), 'rows', coalesce((SELECT jsonb_agg(z ORDER BY z.trip_date DESC, z.id DESC) FROM (
    SELECT p.id, p.trip_id, t.trip_no, p.trip_date, v.vehicle_no, v.size_ton, v.transporter_name AS owner, p.party_name AS party,
           position(' + ' in p.party_key) > 0 AS together, p.order_nos,
           public.lwb_rate_card_load(p.order_nos) AS load_kg,
           q.status AS rate_status, q.rate, q.note
    FROM public.lwb_hired_pending p
    JOIN public.lwb_vehicles v ON v.id = p.vehicle_id
    JOIN public.lwb_hired_vehicles h ON h.vehicle_id = p.vehicle_id AND h.active AND h.rent_type = 'PARTY'
    LEFT JOIN public.lwb_vehicle_trips t ON t.id = p.trip_id
    LEFT JOIN public.lwb_hired_party_rates q ON q.vehicle_id = p.vehicle_id AND q.party_key = p.party_key
    WHERE p.status = 'NEED_RATE' AND p.trip_date > public.lwb_acc_today() - 62
      AND coalesce(q.status, '') <> 'WAITING'
    LIMIT 50) z), '[]'::jsonb));
END;
$fn$;

-- Enter the rent of a waiting trip: the rate of that vehicle + party (or set of parties).
CREATE OR REPLACE FUNCTION public.lwb_trip_rent_set(p_pending bigint, p_rate numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE p public.lwb_hired_pending; v_admin boolean := public.lwb_acc_admin(); v_status text; v_no text; v_n integer := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles u WHERE u.id = auth.uid() AND u.active AND lower(btrim(u.role)) IN ('admin','manager','transport')) THEN
    RAISE EXCEPTION 'Only Admin, Manager or Transport can enter the trip rent';
  END IF;
  IF p_rate IS NULL OR p_rate <= 0 OR p_rate > 100000 THEN RAISE EXCEPTION 'Enter the rent for this trip'; END IF;
  SELECT * INTO p FROM public.lwb_hired_pending x WHERE x.id = p_pending;
  IF p.id IS NULL OR p.status <> 'NEED_RATE' THEN RAISE EXCEPTION 'This trip does not wait for a rent any more. Refresh.'; END IF;
  SELECT q.status INTO v_status FROM public.lwb_hired_party_rates q WHERE q.vehicle_id = p.vehicle_id AND q.party_key = p.party_key;
  IF v_status = 'VERIFIED' AND NOT v_admin THEN RAISE EXCEPTION 'This rate is already verified. Only Admin can change it.'; END IF;
  INSERT INTO public.lwb_hired_party_rates AS q (vehicle_id, party_key, party_name, rate, status, note, set_by, set_at, verified_by, verified_at)
  VALUES (p.vehicle_id, p.party_key, p.party_name, round(p_rate, 2), CASE WHEN v_admin THEN 'VERIFIED' ELSE 'WAITING' END, NULL,
          auth.uid(), now(), CASE WHEN v_admin THEN auth.uid() END, CASE WHEN v_admin THEN now() END)
  ON CONFLICT (vehicle_id, party_key) DO UPDATE SET rate = EXCLUDED.rate, status = EXCLUDED.status, note = NULL, party_name = EXCLUDED.party_name,
    set_by = EXCLUDED.set_by, set_at = now(), verified_by = EXCLUDED.verified_by, verified_at = EXCLUDED.verified_at;
  IF v_admin THEN
    v_n := public.lwb_hired_post_pending(p.vehicle_id, p.party_key);
    RETURN jsonb_build_object('status', 'VERIFIED', 'posted', v_n);
  END IF;
  SELECT v.vehicle_no INTO v_no FROM public.lwb_vehicles v WHERE v.id = p.vehicle_id;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
  SELECT u.id, 'Verify trip rent', v_no || ' → ' || p.party_name || ': ₹' || round(p_rate, 2) || ' per trip. Vehicle Master > Trip rent to set.', 'HIRED_RATE_VERIFY'
  FROM public.user_profiles u WHERE u.active AND lower(btrim(u.role)) = 'admin' AND u.id IS DISTINCT FROM auth.uid();
  RETURN jsonb_build_object('status', 'WAITING', 'posted', 0);
END;
$fn$;

-- trips already waiting as single parties of a multi-party trip: move them to the set of parties
DO $do$
DECLARE r record;
BEGIN
  FOR r IN SELECT DISTINCT p.trip_id FROM public.lwb_hired_pending p WHERE p.status = 'NEED_RATE' AND p.trip_id IS NOT NULL LOOP
    BEGIN PERFORM public.lwb_trip_sync(r.trip_id);
    EXCEPTION WHEN others THEN RAISE WARNING 'trip % skipped: %', r.trip_id, SQLERRM;
    END;
  END LOOP;
END
$do$;

REVOKE ALL ON FUNCTION public.lwb_trip_rent_todo(), public.lwb_trip_rent_set(bigint,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_trip_rent_todo(), public.lwb_trip_rent_set(bigint,numeric) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
