-- LUXURY WRIST BRAND ERP — SELF PICKUP: GODOWN MANAGER LIST ALSO FROM GODOWN LOGINS
--
-- Runs by itself when merged to main (after lwb_self_pickup_driver_setup.sql). Safe to run again.
-- Adds one column; nothing is dropped or deleted. No stock, bill, payment, ledger or Tally data is changed.
--
-- Mohit (2 Nov 2026): the Self Pickup popup said "No Godown Manager in Employee Master yet" although the
-- Godown Manager (e.g. Harsh Gajera) works in the ERP with a Godown login. The list now has:
--   * active Employee Master staff whose Work / Post is Godown Manager (or Warehouse Manager / Godown Incharge),
--   * active logins with role warehouse (Godown), the same people Loading & Dispatch offers,
-- one row per person (an employee linked to a login, or with the same mobile, is shown once).
-- Each row has key 'S:<employee id>' or 'U:<login id>'; lwb_set_order_pickup takes p.godown_key.

BEGIN;

ALTER TABLE public.lwb_order_pickup ADD COLUMN IF NOT EXISTS godown_user_id uuid;

CREATE OR REPLACE FUNCTION public.lwb_pickup_gm_post(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT lower(regexp_replace(btrim(coalesce(p,'')), '\s+', ' ', 'g')) ~ '^(godown|warehouse) ?(manager|incharge|in-charge|in charge|head)$';
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_pickup_godown_managers()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(coalesce(p.role,''))) NOT IN ('', 'driver')) THEN
    RAISE EXCEPTION 'Login is not active.';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('key', x.key, 'id', x.staff_id, 'user_id', x.user_id, 'name', x.name, 'mobile', x.mobile)
      ORDER BY lower(x.name))
    FROM (
      -- Employee Master Godown Managers
      SELECT 'S:' || s.id AS key, s.id AS staff_id, nullif(to_jsonb(s)->>'user_id','')::uuid AS user_id, s.name, s.mobile
      FROM public.lwb_acc_staff s
      WHERE s.active AND public.lwb_pickup_gm_post(s.designation)
      UNION ALL
      -- Godown logins not already listed through Employee Master
      SELECT 'U:' || u.id, NULL, u.id, coalesce(nullif(btrim(u.full_name),''), 'Godown Manager'), u.mobile
      FROM public.user_profiles u
      WHERE u.active = true AND lower(btrim(coalesce(u.role,''))) = 'warehouse'
        AND NOT EXISTS (
          SELECT 1 FROM public.lwb_acc_staff s
          WHERE s.active AND public.lwb_pickup_gm_post(s.designation)
            AND (nullif(to_jsonb(s)->>'user_id','')::uuid = u.id
                 OR (right(regexp_replace(coalesce(s.mobile,''), '\D', '', 'g'), 10) <> ''
                     AND right(regexp_replace(coalesce(s.mobile,''), '\D', '', 'g'), 10)
                       = right(regexp_replace(coalesce(u.mobile,''), '\D', '', 'g'), 10))))
    ) x
  ), '[]'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pickup_godown_managers() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_pickup_godown_managers() TO authenticated;

-- p = {driver_name, driver_mobile, vehicle_no, godown_key ('S:<id>' | 'U:<uuid>'), or old godown_staff_id}.
CREATE OR REPLACE FUNCTION public.lwb_set_order_pickup(p_order_id uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_role text;
  v_st text;
  v_name text := left(btrim(regexp_replace(coalesce(p->>'driver_name',''), '\s+', ' ', 'g')), 80);
  v_mob text := regexp_replace(coalesce(p->>'driver_mobile',''), '\D', '', 'g');
  v_veh text := upper(regexp_replace(coalesce(p->>'vehicle_no',''), '[^A-Za-z0-9]', '', 'g'));
  v_key text := btrim(coalesce(p->>'godown_key',''));
  v_staff bigint;
  v_user uuid;
  v_gm_name text;
  v_gm_mob text;
BEGIN
  SELECT lower(btrim(u.role)) INTO v_role FROM public.user_profiles u WHERE u.id = auth.uid() AND u.active = true;
  IF v_role IS NULL THEN RAISE EXCEPTION 'Login is not active.'; END IF;

  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  v_st := lower(btrim(coalesce(v_o.status,'')));
  IF v_st IN ('cancelled','canceled','delivered','closed','completed') THEN
    RAISE EXCEPTION 'Order % is already closed.', v_o.order_no;
  END IF;

  IF v_role IN ('admin','manager','warehouse','transport') THEN
    NULL;
  ELSIF v_role IN ('sales','salesman') AND v_o.created_by = auth.uid()
        AND v_st IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new') THEN
    NULL;
  ELSE
    RAISE EXCEPTION 'Only Admin, Sales Head, Godown, Transport or the salesman (before approval) can change pickup details.';
  END IF;

  IF v_mob ~ '^(91|0)[6-9][0-9]{9}$' THEN v_mob := right(v_mob, 10); END IF;
  IF v_mob <> '' AND v_mob !~ '^[6-9][0-9]{9}$' THEN
    RAISE EXCEPTION 'Driver mobile must be a 10-digit mobile number.';
  END IF;
  IF length(v_veh) > 20 THEN RAISE EXCEPTION 'Vehicle number is too long.'; END IF;

  IF v_key = '' AND nullif(btrim(coalesce(p->>'godown_staff_id','')), '') IS NOT NULL THEN
    v_key := 'S:' || btrim(p->>'godown_staff_id');
  END IF;

  IF (v_name = '' AND v_mob = '' AND v_veh = '' AND v_key = '')
     OR split_part(btrim(coalesce(v_o.transportation,'')), ' |', 1) <> 'SELF PICKUP' THEN
    DELETE FROM public.lwb_order_pickup WHERE order_id = v_o.id;
    RETURN jsonb_build_object('order_id', v_o.id, 'saved', false);
  END IF;

  IF v_key ~ '^S:[0-9]+$' THEN
    SELECT x.id, x.name, x.mobile, nullif(to_jsonb(x)->>'user_id','')::uuid INTO v_staff, v_gm_name, v_gm_mob, v_user
    FROM public.lwb_acc_staff x
    WHERE x.id = substr(v_key, 3)::bigint AND x.active AND public.lwb_pickup_gm_post(x.designation);
    IF v_staff IS NULL THEN RAISE EXCEPTION 'Pick an active Godown Manager from the list.'; END IF;
  ELSIF v_key ~ '^U:[0-9a-fA-F-]{36}$' THEN
    SELECT u.id, coalesce(nullif(btrim(u.full_name),''), 'Godown Manager'), u.mobile INTO v_user, v_gm_name, v_gm_mob
    FROM public.user_profiles u
    WHERE u.id = substr(v_key, 3)::uuid AND u.active = true AND lower(btrim(coalesce(u.role,''))) = 'warehouse';
    IF v_user IS NULL THEN RAISE EXCEPTION 'Pick an active Godown Manager from the list.'; END IF;
  ELSIF v_key <> '' THEN
    RAISE EXCEPTION 'Pick an active Godown Manager from the list.';
  END IF;

  INSERT INTO public.lwb_order_pickup AS t (order_id, driver_name, driver_mobile, vehicle_no, godown_staff_id, godown_user_id,
    godown_manager_name, godown_manager_mobile, created_by, updated_by)
  VALUES (v_o.id, nullif(v_name,''), nullif(v_mob,''), nullif(v_veh,''), v_staff, v_user, v_gm_name, v_gm_mob, auth.uid(), auth.uid())
  ON CONFLICT (order_id) DO UPDATE SET
    driver_name = excluded.driver_name, driver_mobile = excluded.driver_mobile, vehicle_no = excluded.vehicle_no,
    godown_staff_id = excluded.godown_staff_id, godown_user_id = excluded.godown_user_id,
    godown_manager_name = excluded.godown_manager_name, godown_manager_mobile = excluded.godown_manager_mobile,
    updated_by = auth.uid(), updated_at = now();

  RETURN jsonb_build_object('order_id', v_o.id, 'saved', true);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_set_order_pickup(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_order_pickup(uuid, jsonb) TO authenticated;

COMMIT;
