-- LUXURY WRIST BRAND ERP — VEHICLE / DRIVER DAY REPORT (Mohit, 23 Nov 2026)
--
-- Safe to run again. Read only: no table is created or changed.
--
-- Mohit: "which vehicle delivered how much today, which driver did what work, vehicle-wise;
-- the driver is fixed to a vehicle; how many tons were loaded and how many cases delivered".
--
-- lwb_vehicle_day(p_from, p_to) -> jsonb
--   vehicles : every active Vehicle Master vehicle (type, size, capacity, ownership) with its
--              fixed driver(s) = Employee Master drivers whose default vehicle is this one.
--   rows     : one row per PO given a vehicle, loaded, delivered, Admin-marked, self pickup or direct vehicle, in the range.
--              kind = GODOWN (our delivery from the godown) / SELF (party's own vehicle, lwb_order_pickup) /
--              DIRECT (company truck straight to the party, lwb_direct_vehicle), from orders.transportation.
--              Day = delivered day (driver report / Admin mark), else loading done, else vehicle given (India time).
--              A PO delivered / marked with no vehicle on Transport Assignment comes with vehicle_no null.
--              cases = PO total qty (selling unit), kg = PO total weight,
--              delivered = driver report DELIVERED / PARTIAL or Admin "Mark delivered",
--              ret_cases = driver return cases not rejected by the office.
-- Who: Admin, Sales Head (manager), Transport, Accounts, or a login given this page.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_vehicle_day_reader()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
             AND lower(btrim(p.role)) IN ('admin','manager','transport','accounts')) THEN RETURN true; END IF;
  IF to_regprocedure('public.lwb_has_page(text)') IS NULL THEN RETURN false; END IF;
  RETURN EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) <> 'driver')
     AND public.lwb_has_page('vehicle-report.html');
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_day_reader() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_day_reader() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_vehicle_day(p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_from date := coalesce(p_from, (now() AT TIME ZONE 'Asia/Kolkata')::date);
  v_to   date := coalesce(p_to, p_from, (now() AT TIME ZONE 'Asia/Kolkata')::date);
  v_vehicles jsonb;
  v_rows jsonb;
  v_marks boolean := to_regclass('public.lwb_admin_order_marks') IS NOT NULL;
  v_rets boolean := to_regclass('public.lwb_driver_delivery_return_items') IS NOT NULL;
  v_trips boolean := to_regclass('public.lwb_vehicle_trips') IS NOT NULL;
BEGIN
  IF NOT public.lwb_vehicle_day_reader() THEN RAISE EXCEPTION 'You can not open the vehicle report'; END IF;
  IF v_to < v_from THEN RAISE EXCEPTION 'To date is before From date'; END IF;
  IF v_to - v_from > 92 THEN RAISE EXCEPTION 'Choose 93 days or less'; END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', v.id, 'vehicle_no', v.vehicle_no, 'vehicle_type', v.vehicle_type,
      'capacity_kg', v.capacity_kg, 'size_ton', to_jsonb(v) -> 'size_ton',
      'ownership', v.ownership, 'transporter_name', v.transporter_name,
      'drivers', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', s.name, 'mobile', s.mobile) ORDER BY lower(s.name)), '[]'::jsonb)
                  FROM public.lwb_acc_staff s
                  WHERE s.active AND s.default_vehicle_id = v.id)
    ) ORDER BY v.vehicle_no), '[]'::jsonb)
  INTO v_vehicles
  FROM public.lwb_vehicles v WHERE v.is_active;

  -- Every PO that moved in the range: given a vehicle, loaded, delivered by the driver or marked by Admin
  -- (24 Nov 2026: a delivered PO with no vehicle on Transport Assignment showed nowhere; it now shows under "No vehicle").
  -- One assignment per order (the latest one if an order was given twice).
  WITH w AS (
    SELECT (v_from::timestamp AT TIME ZONE 'Asia/Kolkata') - interval '1 day' AS t0,
           ((v_to + 1)::timestamp AT TIME ZONE 'Asia/Kolkata') + interval '1 day' AS t1
  ), ids AS (
    SELECT x.order_id FROM public.dispatch_assignments x, w
    WHERE x.order_id IS NOT NULL AND coalesce(x.loading_completed_at, x.assigned_at) >= w.t0 AND coalesce(x.loading_completed_at, x.assigned_at) < w.t1
    UNION SELECT r.order_id FROM public.lwb_delivery_reports r, w WHERE r.reported_at >= w.t0 AND r.reported_at < w.t1
    UNION SELECT m.order_id FROM public.lwb_admin_order_marks m WHERE v_marks AND m.mark_date BETWEEN v_from - 1 AND v_to + 1
    UNION SELECT p.order_id FROM public.lwb_order_pickup p, w WHERE coalesce(p.updated_at, p.created_at) >= w.t0 AND coalesce(p.updated_at, p.created_at) < w.t1
    UNION SELECT v.order_id FROM public.lwb_direct_vehicle v, w WHERE coalesce(v.final_at, v.updated_at) >= w.t0 AND coalesce(v.final_at, v.updated_at) < w.t1
  ), a AS (
    SELECT DISTINCT ON (x.order_id) x.*
    FROM public.dispatch_assignments x JOIN ids ON ids.order_id = x.order_id
    ORDER BY x.order_id, x.assigned_at DESC NULLS LAST
  ), d AS (
    SELECT o.id AS oid,
      CASE WHEN upper(btrim(split_part(coalesce(o.transportation,''), '|', 1))) LIKE 'SELF%' THEN 'SELF'
           WHEN upper(btrim(split_part(coalesce(o.transportation,''), '|', 1))) LIKE 'DIRECT%' THEN 'DIRECT'
           ELSE 'GODOWN' END AS kind,
      coalesce(nullif(btrim(p.vehicle_no),''), nullif(btrim(a.vehicle_no),''), nullif(btrim(dv.truck_label),'')) AS vehicle_no,
      coalesce(nullif(btrim(p.driver_name),''), a.driver_name) AS driver_name,
      coalesce(nullif(btrim(p.driver_mobile),''), a.driver_mobile) AS driver_mobile,
      a.assigned_at, a.loading_completed_at, a.trip_id,
      coalesce(p.updated_at, p.created_at) AS pickup_at, coalesce(dv.final_at, dv.updated_at) AS direct_at,
      r.delivery_status, r.reported_at,
      CASE WHEN v_marks THEN (SELECT m.mark_date FROM public.lwb_admin_order_marks m WHERE m.order_id = o.id AND m.kind = 'DELIVERED' LIMIT 1) END AS mark_del,
      CASE WHEN v_marks THEN (SELECT m.mark_date FROM public.lwb_admin_order_marks m WHERE m.order_id = o.id AND m.kind = 'LOADED' LIMIT 1) END AS mark_load
    FROM ids JOIN public.orders o ON o.id = ids.order_id
    LEFT JOIN a ON a.order_id = o.id
    LEFT JOIN public.lwb_delivery_reports r ON r.order_id = o.id
    LEFT JOIN public.lwb_order_pickup p ON p.order_id = o.id
    LEFT JOIN public.lwb_direct_vehicle dv ON dv.order_id = o.id
  ), e AS (
    -- Day = delivered day (driver report / Admin mark), else loading done, else the day the vehicle was given.
    SELECT d.*, coalesce(
      CASE WHEN d.delivery_status IN ('DELIVERED','PARTIAL') THEN (d.reported_at AT TIME ZONE 'Asia/Kolkata')::date END,
      d.mark_del,
      (d.loading_completed_at AT TIME ZONE 'Asia/Kolkata')::date,
      d.mark_load,
      (d.reported_at AT TIME ZONE 'Asia/Kolkata')::date,
      (d.assigned_at AT TIME ZONE 'Asia/Kolkata')::date,
      (d.pickup_at AT TIME ZONE 'Asia/Kolkata')::date,
      (d.direct_at AT TIME ZONE 'Asia/Kolkata')::date) AS day
    FROM d
  )
  SELECT coalesce(jsonb_agg(r ORDER BY r->>'vehicle_key', r->>'day', r->>'order_no'), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'order_id', o.id, 'order_no', o.order_no, 'kind', e.kind, 'party', o.customer_name, 'status', lower(coalesce(o.status,'')),
      'day', e.day, 'vehicle_no', nullif(btrim(coalesce(e.vehicle_no,'')), ''),
      'vehicle_key', upper(regexp_replace(coalesce(e.vehicle_no,''), '[^A-Za-z0-9]', '', 'g')),
      'driver_name', e.driver_name, 'driver_mobile', e.driver_mobile,
      'assigned_at', e.assigned_at, 'loaded_at', coalesce(e.loading_completed_at, e.mark_load::timestamptz),
      'cases', coalesce(o.total_qty, 0), 'kg', coalesce(o.total_weight, 0), 'amount', coalesce(o.total_amount, 0),
      'report', e.delivery_status, 'reported_at', e.reported_at, 'mark_delivered', e.mark_del,
      'ret_cases', CASE WHEN v_rets THEN (SELECT coalesce(sum(i.qty_cases), 0)
                                           FROM public.lwb_driver_delivery_returns h
                                           JOIN public.lwb_driver_delivery_return_items i ON i.return_id = h.id
                                           WHERE h.order_id = o.id AND h.status <> 'REJECTED') ELSE 0 END,
      'trip_no', CASE WHEN v_trips AND e.trip_id IS NOT NULL THEN (SELECT t.trip_no FROM public.lwb_vehicle_trips t WHERE t.id = e.trip_id) END
    ) AS r
    FROM e JOIN public.orders o ON o.id = e.oid
    WHERE e.day BETWEEN v_from AND v_to
      AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected','deleted')
  ) q(r);

  RETURN jsonb_build_object('from', v_from, 'to', v_to, 'vehicles', v_vehicles, 'rows', v_rows);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_day(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_day(date, date) TO authenticated;

COMMIT;
