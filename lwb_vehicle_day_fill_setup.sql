-- LUXURY WRIST BRAND ERP — VEHICLE REPORT: GIVE THE VEHICLE TO A PO ALREADY DELIVERED WITHOUT ONE (Mohit, 24 Nov 2026)
--
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped or deleted.
--
-- Mohit: "No vehicle given" in the Vehicle Report has POs (mostly Rajnigandha) that were delivered with no vehicle on
-- Transport Assignment. "Give me an option here to update who delivered it." From now on no PO is marked Loaded /
-- Delivered without a vehicle (lwb_admin_mark_load_deliver_setup.sql, Coca-Cola and Rajnigandha alike).
--
-- lwb_vehicle_day_fill(p_ids, p_vehicle_no, p_driver_name, p_driver_mobile) -> {done:[order_no], skipped:[{order_no, why}]}
--   Admin, Sales Head (manager) or Transport. Only Godown Delivery POs that are already loaded / delivered and have
--   no vehicle yet: their Transport Assignment row gets the vehicle + driver (a new row when there is none), with
--   assigned_at = the delivered day (driver report / Admin mark, else loading day) so the PO stays on that day.
--   Loading time, stock, bill and status are not touched. The "Load this vehicle" bells that a new assignment rings
--   are marked read at once (the goods are already delivered). Every change is in PO History (lwb_change_log).

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_vehicle_day_fill(p_ids uuid[], p_vehicle_no text, p_driver_name text, p_driver_mobile text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_me text;
  v_veh text := upper(regexp_replace(btrim(coalesce(p_vehicle_no,'')), '\s+', ' ', 'g'));
  v_drv text := nullif(regexp_replace(btrim(coalesce(p_driver_name,'')), '\s+', ' ', 'g'), '');
  v_mob text := nullif(regexp_replace(coalesce(p_driver_mobile,''), '\D', '', 'g'), '');
  v_owner text;
  v_o record;
  v_aid uuid;
  v_aveh text;
  v_load timestamptz;
  v_at timestamptz;
  v_tp text;
  v_done text[] := '{}';
  v_skip jsonb := '[]'::jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','transport')) THEN
    RAISE EXCEPTION 'Only Admin, Sales Head or Transport can give the vehicle';
  END IF;
  IF p_ids IS NULL OR cardinality(p_ids) = 0 THEN RAISE EXCEPTION 'Choose a PO'; END IF;
  IF cardinality(p_ids) > 200 THEN RAISE EXCEPTION 'Choose 200 PO or less'; END IF;
  IF length(v_veh) < 4 OR length(v_veh) > 40 THEN RAISE EXCEPTION 'Enter the vehicle number'; END IF;
  IF v_drv IS NULL OR length(v_drv) > 80 THEN RAISE EXCEPTION 'Enter the driver name'; END IF;
  IF v_mob IS NOT NULL THEN
    v_mob := right(v_mob, 10);
    IF length(v_mob) <> 10 THEN RAISE EXCEPTION 'Driver mobile must be 10 digits'; END IF;
  END IF;
  SELECT p.full_name INTO v_me FROM public.user_profiles p WHERE p.id = auth.uid();
  IF to_regclass('public.lwb_vehicles') IS NOT NULL THEN
    SELECT nullif(btrim(v.transporter_name),'') INTO v_owner FROM public.lwb_vehicles v
    WHERE upper(regexp_replace(v.vehicle_no, '[^A-Za-z0-9]', '', 'g')) = upper(regexp_replace(v_veh, '[^A-Za-z0-9]', '', 'g')) LIMIT 1;
  END IF;

  FOR v_o IN SELECT o.* FROM public.orders o WHERE o.id = ANY(p_ids) ORDER BY o.order_no FOR UPDATE LOOP
    v_tp := upper(btrim(split_part(coalesce(to_jsonb(v_o) ->> 'transportation', ''), '|', 1)));
    IF v_tp LIKE 'SELF%' OR v_tp LIKE 'DIRECT%' THEN
      v_skip := v_skip || jsonb_build_object('order_no', v_o.order_no, 'why', 'Self Pickup / Direct Vehicle'); CONTINUE;
    END IF;
    IF lower(btrim(coalesce(v_o.status::text,''))) IN ('cancelled','canceled','rejected','deleted') THEN
      v_skip := v_skip || jsonb_build_object('order_no', v_o.order_no, 'why', 'cancelled'); CONTINUE;
    END IF;
    IF NOT (lower(btrim(coalesce(v_o.status::text,''))) IN ('loaded','invoiced','dispatched','out_for_delivery','delivered',
                                                            'partially_delivered','closed','completed')
            OR EXISTS (SELECT 1 FROM public.lwb_delivery_reports d WHERE d.order_id = v_o.id AND d.delivery_status IN ('DELIVERED','PARTIAL'))
            OR (to_regclass('public.lwb_admin_order_marks') IS NOT NULL
                AND EXISTS (SELECT 1 FROM public.lwb_admin_order_marks m WHERE m.order_id = v_o.id))) THEN
      v_skip := v_skip || jsonb_build_object('order_no', v_o.order_no, 'why', 'not loaded yet: use Transport on the PO'); CONTINUE;
    END IF;
    v_aid := NULL; v_aveh := NULL; v_load := NULL;
    SELECT a.id, nullif(btrim(coalesce(a.vehicle_no,'')),''), a.loading_completed_at INTO v_aid, v_aveh, v_load
    FROM public.dispatch_assignments a WHERE a.order_id = v_o.id ORDER BY a.assigned_at DESC NULLS LAST LIMIT 1;
    IF v_aveh IS NOT NULL THEN
      v_skip := v_skip || jsonb_build_object('order_no', v_o.order_no, 'why', 'already has vehicle ' || v_aveh); CONTINUE;
    END IF;

    -- The day it went: driver report, else Admin "Delivered" / "Loaded" mark (noon IST), else loading, else now.
    v_at := coalesce(
      (SELECT d.reported_at FROM public.lwb_delivery_reports d WHERE d.order_id = v_o.id AND d.delivery_status IN ('DELIVERED','PARTIAL') LIMIT 1),
      CASE WHEN to_regclass('public.lwb_admin_order_marks') IS NOT NULL THEN
        (SELECT (m.mark_date + time '12:00') AT TIME ZONE 'Asia/Kolkata' FROM public.lwb_admin_order_marks m
         WHERE m.order_id = v_o.id ORDER BY (m.kind = 'DELIVERED') DESC LIMIT 1) END,
      v_load,
      now());

    BEGIN
    IF v_aid IS NOT NULL THEN
      UPDATE public.dispatch_assignments a
      SET vehicle_no = v_veh, driver_name = v_drv, driver_mobile = coalesce(v_mob, a.driver_mobile),
          transporter_name = coalesce(a.transporter_name, v_owner),
          assigned_at = coalesce(a.assigned_at, v_at)
      WHERE a.id = v_aid;
    ELSE
      INSERT INTO public.dispatch_assignments (order_id, vehicle_no, driver_name, driver_mobile, transporter_name, loading_person, assigned_at, remarks)
      VALUES (v_o.id, v_veh, v_drv, v_mob, v_owner, 'Added after delivery', v_at,
              'Vehicle added after delivery from Vehicle Report by ' || coalesce(v_me, 'Admin'));
    END IF;
    v_done := array_append(v_done, v_o.order_no);
    EXCEPTION WHEN others THEN
      v_skip := v_skip || jsonb_build_object('order_no', v_o.order_no, 'why', SQLERRM);
    END;
  END LOOP;

  -- The goods are already delivered: the "load this vehicle" bells this just rang are done.
  UPDATE public.erp_notifications n SET is_read = true
  WHERE n.order_id = ANY(p_ids) AND n.is_read = false AND n.created_at >= now()
    AND n.notification_type IN ('LOADING_ASSIGNMENT','LOADING_ASSIGNMENT_DISPATCH','LOADING_ASSIGNMENT_DRIVER');

  RETURN jsonb_build_object('done', to_jsonb(v_done), 'skipped', v_skip);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_day_fill(uuid[], text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_day_fill(uuid[], text, text, text) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';
