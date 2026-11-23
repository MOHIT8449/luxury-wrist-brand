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
--   rows     : one row per PO given a vehicle on Transport Assignment, whose day falls in the range.
--              Day = loading done (India time), else the day the vehicle was given.
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

  -- One assignment per order (the latest one if an order was given twice).
  WITH a AS (
    SELECT DISTINCT ON (x.order_id) x.*
    FROM public.dispatch_assignments x
    WHERE x.order_id IS NOT NULL
      AND coalesce(x.loading_completed_at, x.assigned_at) >= (v_from::timestamp AT TIME ZONE 'Asia/Kolkata') - interval '1 day'
      AND coalesce(x.loading_completed_at, x.assigned_at) <  ((v_to + 1)::timestamp AT TIME ZONE 'Asia/Kolkata') + interval '1 day'
    ORDER BY x.order_id, x.assigned_at DESC NULLS LAST
  ), d AS (
    SELECT a.*, (coalesce(a.loading_completed_at, a.assigned_at) AT TIME ZONE 'Asia/Kolkata')::date AS day
    FROM a
  )
  SELECT coalesce(jsonb_agg(r ORDER BY r->>'vehicle_key', r->>'day', r->>'order_no'), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'order_id', o.id, 'order_no', o.order_no, 'party', o.customer_name, 'status', lower(coalesce(o.status,'')),
      'day', d.day, 'vehicle_no', d.vehicle_no,
      'vehicle_key', upper(regexp_replace(coalesce(d.vehicle_no,''), '[^A-Za-z0-9]', '', 'g')),
      'driver_name', d.driver_name, 'driver_mobile', d.driver_mobile,
      'assigned_at', d.assigned_at, 'loaded_at', d.loading_completed_at,
      'cases', coalesce(o.total_qty, 0), 'kg', coalesce(o.total_weight, 0), 'amount', coalesce(o.total_amount, 0),
      'report', r.delivery_status, 'reported_at', r.reported_at,
      'mark_delivered', CASE WHEN v_marks THEN (SELECT m.mark_date FROM public.lwb_admin_order_marks m
                                                WHERE m.order_id = o.id AND m.kind = 'DELIVERED' LIMIT 1) END,
      'ret_cases', CASE WHEN v_rets THEN (SELECT coalesce(sum(i.qty_cases), 0)
                                           FROM public.lwb_driver_delivery_returns h
                                           JOIN public.lwb_driver_delivery_return_items i ON i.return_id = h.id
                                           WHERE h.order_id = o.id AND h.status <> 'REJECTED') ELSE 0 END,
      'trip_no', CASE WHEN v_trips AND d.trip_id IS NOT NULL THEN (SELECT t.trip_no FROM public.lwb_vehicle_trips t WHERE t.id = d.trip_id) END
    ) AS r
    FROM d
    JOIN public.orders o ON o.id = d.order_id
    LEFT JOIN public.lwb_delivery_reports r ON r.order_id = o.id
    WHERE d.day BETWEEN v_from AND v_to
      AND nullif(btrim(coalesce(d.vehicle_no,'')), '') IS NOT NULL
      AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected','deleted')
  ) q(r);

  RETURN jsonb_build_object('from', v_from, 'to', v_to, 'vehicles', v_vehicles, 'rows', v_rows);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_day(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_day(date, date) TO authenticated;

COMMIT;
