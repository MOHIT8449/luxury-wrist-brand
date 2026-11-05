-- LUXURY WRIST BRAND ERP — HIRED VEHICLES: TRIP ADDED BY ITSELF ON TRANSPORT ASSIGNMENT
--
-- Runs by itself when merged to main (after lwb_hired_vehicle_rent_setup.sql). Safe to run again.
-- Nothing is dropped or deleted (only this file's own trigger is re-created).
--
-- Mohit asked (5 Nov 2026): when an order is assigned to a hired vehicle (per trip / per route rent),
-- the trip should come into its rent ledger by itself.
--
--   * One trip per vehicle per day, however many orders go that day (orders are listed on the line).
--   * Rate = the vehicle's trip rate; per route = its first route (cancel and add by hand to change).
--   * A day that already has a trip (by hand or by itself) only gets the order added to that line.
--   * A cancelled auto trip is not added again for that day.
--   * Order moved to another vehicle: the order leaves the old auto line; the line is cancelled when
--     no order is left on it.
--   * Saving a rent setup fills the auto trips from the start date (up to 62 days back).
-- The assignment itself never fails because of this: any error here is skipped.

BEGIN;

ALTER TABLE public.lwb_hired_charges ADD COLUMN IF NOT EXISTS auto boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX IF NOT EXISTS lwb_hired_charges_auto_uidx ON public.lwb_hired_charges (vehicle_id, charge_date) WHERE kind = 'TRIP' AND auto;

-- Add (or join) the day's trip of a hired vehicle for one order.
CREATE OR REPLACE FUNCTION public.lwb_hired_auto_trip(p_vehicle_no text, p_day date, p_order text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_hired_vehicles; v_key text := upper(regexp_replace(coalesce(p_vehicle_no,''), '[^A-Za-z0-9]', '', 'g'));
        v_line bigint; v_route text; v_rate numeric;
BEGIN
  IF v_key = '' OR p_day IS NULL THEN RETURN; END IF;
  SELECT x.* INTO h FROM public.lwb_hired_vehicles x JOIN public.lwb_vehicles v ON v.id = x.vehicle_id
  WHERE v.vehicle_no = v_key AND x.active AND x.rent_type IN ('TRIP','ROUTE');
  IF h.vehicle_id IS NULL OR p_day < h.start_date OR p_day > public.lwb_acc_today() THEN RETURN; END IF;
  -- a trip already on that day: put the order on it (the auto line first)
  SELECT c.id INTO v_line FROM public.lwb_hired_charges c
  WHERE c.vehicle_id = h.vehicle_id AND c.kind = 'TRIP' AND c.charge_date = p_day AND c.cancelled_at IS NULL
  ORDER BY c.auto DESC, c.id LIMIT 1;
  IF v_line IS NOT NULL THEN
    IF p_order IS NOT NULL THEN
      UPDATE public.lwb_hired_charges SET order_nos = coalesce(order_nos, '{}') || p_order
      WHERE id = v_line AND NOT (p_order = ANY (coalesce(order_nos, '{}')));
    END IF;
    RETURN;
  END IF;
  -- the auto line was cancelled only because its orders moved away: use it again
  UPDATE public.lwb_hired_charges SET cancelled_at = NULL, cancelled_by = NULL, cancel_note = NULL,
         order_nos = CASE WHEN p_order IS NULL THEN NULL ELSE ARRAY[p_order] END
  WHERE vehicle_id = h.vehicle_id AND kind = 'TRIP' AND auto AND charge_date = p_day AND cancel_note = 'Order moved to another vehicle';
  IF FOUND THEN RETURN; END IF;
  -- the auto trip of that day was cancelled by Accounts: keep it cancelled
  IF EXISTS (SELECT 1 FROM public.lwb_hired_charges c WHERE c.vehicle_id = h.vehicle_id AND c.kind = 'TRIP' AND c.auto AND c.charge_date = p_day) THEN RETURN; END IF;
  IF h.rent_type = 'ROUTE' THEN
    SELECT r.name, r.rate INTO v_route, v_rate FROM public.lwb_hired_routes r WHERE r.vehicle_id = h.vehicle_id AND r.active ORDER BY r.sort, r.id LIMIT 1;
  ELSE v_rate := h.trip_rate;
  END IF;
  IF coalesce(v_rate, 0) <= 0 THEN RETURN; END IF;
  INSERT INTO public.lwb_hired_charges (vehicle_id, charge_date, kind, route_name, trips, rate, extra, amount, order_nos, remark, auto)
  VALUES (h.vehicle_id, p_day, 'TRIP', v_route, 1, v_rate, 0, v_rate, CASE WHEN p_order IS NULL THEN NULL ELSE ARRAY[p_order] END,
          'Auto · Transport Assignment', true)
  ON CONFLICT DO NOTHING;
END;
$fn$;

-- The order left this vehicle: take it off the day's auto line; cancel the line when no order is left.
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
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_hired_assignment_trip()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_order text; v_status text; v_day date; v_old_day date;
BEGIN
  BEGIN
    SELECT o.order_no, lower(coalesce(o.status,'')) INTO v_order, v_status FROM public.orders o WHERE o.id = NEW.order_id;
    IF v_status IN ('cancelled','canceled','rejected') THEN RETURN NEW; END IF;
    v_day := (coalesce(NEW.assigned_at, now()) AT TIME ZONE 'Asia/Kolkata')::date;
    IF TG_OP = 'UPDATE' THEN
      v_old_day := (coalesce(OLD.assigned_at, now()) AT TIME ZONE 'Asia/Kolkata')::date;
      IF upper(regexp_replace(coalesce(OLD.vehicle_no,''), '[^A-Za-z0-9]', '', 'g')) IS NOT DISTINCT FROM upper(regexp_replace(coalesce(NEW.vehicle_no,''), '[^A-Za-z0-9]', '', 'g'))
         AND v_old_day = v_day THEN RETURN NEW; END IF;
      PERFORM public.lwb_hired_auto_untrip(OLD.vehicle_no, v_old_day, v_order);
    END IF;
    PERFORM public.lwb_hired_auto_trip(NEW.vehicle_no, v_day, v_order);
  EXCEPTION WHEN others THEN
    RAISE WARNING 'hired auto trip skipped: %', SQLERRM;
  END;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_lwb_hired_assignment_trip ON public.dispatch_assignments;
CREATE TRIGGER trg_lwb_hired_assignment_trip
AFTER INSERT OR UPDATE OF vehicle_no, assigned_at
ON public.dispatch_assignments
FOR EACH ROW
EXECUTE FUNCTION public.lwb_hired_assignment_trip();

-- Fill the auto trips of one hired vehicle from its start date (up to 62 days back). Returns lines added.
CREATE OR REPLACE FUNCTION public.lwb_hired_auto_fill(p_vehicle uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_hired_vehicles; v_no text; r record; v_before integer; v_after integer;
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin only'; END IF;
  SELECT x.* INTO h FROM public.lwb_hired_vehicles x WHERE x.vehicle_id = p_vehicle;
  SELECT v.vehicle_no INTO v_no FROM public.lwb_vehicles v WHERE v.id = p_vehicle;
  IF h.vehicle_id IS NULL OR NOT h.active OR h.rent_type NOT IN ('TRIP','ROUTE') THEN RETURN 0; END IF;
  SELECT count(*) INTO v_before FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.kind = 'TRIP';
  FOR r IN SELECT (a.assigned_at AT TIME ZONE 'Asia/Kolkata')::date AS day, o.order_no
           FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
           WHERE upper(regexp_replace(coalesce(a.vehicle_no,''), '[^A-Za-z0-9]', '', 'g')) = v_no
             AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected')
             AND (a.assigned_at AT TIME ZONE 'Asia/Kolkata')::date >= greatest(h.start_date, public.lwb_acc_today() - 62)
           ORDER BY a.assigned_at LOOP
    PERFORM public.lwb_hired_auto_trip(v_no, r.day, r.order_no);
  END LOOP;
  SELECT count(*) INTO v_after FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.kind = 'TRIP';
  RETURN v_after - v_before;
END;
$fn$;

-- Ledger lines now say which trips came by themselves ('auto').
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
        FROM public.lwb_hired_money(p_vehicle) m WHERE m.entry_date BETWEEN p_from AND p_to) l), '[]'::jsonb)
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_hired_auto_trip(text,date,text), public.lwb_hired_auto_untrip(text,date,text),
  public.lwb_hired_assignment_trip() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_hired_auto_fill(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_hired_auto_fill(uuid) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'auto trip trigger' AS item,
  EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_hired_assignment_trip')::text AS ok;
