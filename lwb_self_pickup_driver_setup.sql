-- LUXURY WRIST BRAND ERP — SELF PICKUP: DRIVER NAME, MOBILE, VEHICLE NO. AND GODOWN MANAGER ON THE ORDER
--
-- Runs by itself when merged to main (after lwb_employee_roles_setup.sql). Safe to run again.
-- Nothing is dropped or deleted. No stock, bill, payment, ledger or Tally data is changed.
--
-- Mohit asked (2 Nov 2026): when Transportation is SELF PICKUP, an outside driver comes to take the goods
-- and it is a different driver every time. On New Sales Order, right below Transportation, take the
-- driver's name, mobile number and vehicle number (typed, not from Vehicle / Employee Master) and allot a
-- Godown Manager (picked from Employee Master, Work / Post "Godown Manager"). Saved with the order.
--
-- This file:
--   * table lwb_order_pickup: one row per order (order_id), written only through lwb_set_order_pickup.
--     A login can read the row of every order it can read (same orders RLS), so PO Approval / Loading
--     pages can show it later with a plain select.
--   * lwb_pickup_godown_managers(): active employees whose Work / Post is Godown Manager (name, mobile,
--     employee code; no salary), for every active login except drivers.
--   * lwb_set_order_pickup(order, p): save / clear the details. Admin, Sales Head, Godown and Transport:
--     any open order. Salesman: own order while it waits for approval. Empty p (or not SELF PICKUP) clears.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_order_pickup (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  driver_name text,
  driver_mobile text,
  vehicle_no text,
  godown_staff_id bigint,
  godown_manager_name text,
  godown_manager_mobile text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);

DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_order_pickup_text_chk') THEN
    ALTER TABLE public.lwb_order_pickup ADD CONSTRAINT lwb_order_pickup_text_chk CHECK (
      length(coalesce(driver_name,'')) <= 80 AND length(coalesce(vehicle_no,'')) <= 20
      AND length(coalesce(godown_manager_name,'')) <= 120
      AND (driver_mobile IS NULL OR driver_mobile ~ '^[6-9][0-9]{9}$'));
  END IF;
  IF to_regclass('public.lwb_acc_staff') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_order_pickup_staff_fk') THEN
    ALTER TABLE public.lwb_order_pickup ADD CONSTRAINT lwb_order_pickup_staff_fk
      FOREIGN KEY (godown_staff_id) REFERENCES public.lwb_acc_staff(id) ON DELETE SET NULL;
  END IF;
END $do$;

ALTER TABLE public.lwb_order_pickup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_order_pickup FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.lwb_order_pickup TO authenticated;
DROP POLICY IF EXISTS lwb_order_pickup_read ON public.lwb_order_pickup;
-- Read = the login can read that order (the orders table's own RLS decides).
CREATE POLICY lwb_order_pickup_read ON public.lwb_order_pickup FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id));

-- Godown Managers from Employee Master (Work / Post = Godown Manager), A–Z.
CREATE OR REPLACE FUNCTION public.lwb_pickup_godown_managers()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(coalesce(p.role,''))) NOT IN ('', 'driver')) THEN
    RAISE EXCEPTION 'Login is not active.';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', s.id, 'emp_code', s.emp_code, 'name', s.name, 'mobile', s.mobile)
      ORDER BY lower(s.name))
    FROM public.lwb_acc_staff s
    WHERE s.active AND lower(regexp_replace(btrim(coalesce(s.designation,'')), '\s+', ' ', 'g')) = 'godown manager'
  ), '[]'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pickup_godown_managers() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_pickup_godown_managers() TO authenticated;

-- p = {driver_name, driver_mobile, vehicle_no, godown_staff_id}; all blank / null = remove the details.
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
  v_staff bigint := nullif(btrim(coalesce(p->>'godown_staff_id','')), '')::bigint;
  s record;
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

  -- Nothing given, or the order is not Self Pickup: remove the details.
  IF (v_name = '' AND v_mob = '' AND v_veh = '' AND v_staff IS NULL)
     OR split_part(btrim(coalesce(v_o.transportation,'')), ' |', 1) <> 'SELF PICKUP' THEN
    DELETE FROM public.lwb_order_pickup WHERE order_id = v_o.id;
    RETURN jsonb_build_object('order_id', v_o.id, 'saved', false);
  END IF;

  IF v_staff IS NOT NULL THEN
    SELECT x.id, x.name, x.mobile INTO s FROM public.lwb_acc_staff x
    WHERE x.id = v_staff AND x.active
      AND lower(regexp_replace(btrim(coalesce(x.designation,'')), '\s+', ' ', 'g')) = 'godown manager';
    IF NOT FOUND THEN RAISE EXCEPTION 'Pick an active Godown Manager from Employee Master.'; END IF;
  END IF;

  INSERT INTO public.lwb_order_pickup AS t (order_id, driver_name, driver_mobile, vehicle_no, godown_staff_id,
    godown_manager_name, godown_manager_mobile, created_by, updated_by)
  VALUES (v_o.id, nullif(v_name,''), nullif(v_mob,''), nullif(v_veh,''), v_staff,
    CASE WHEN v_staff IS NOT NULL THEN s.name END, CASE WHEN v_staff IS NOT NULL THEN s.mobile END, auth.uid(), auth.uid())
  ON CONFLICT (order_id) DO UPDATE SET
    driver_name = excluded.driver_name, driver_mobile = excluded.driver_mobile, vehicle_no = excluded.vehicle_no,
    godown_staff_id = excluded.godown_staff_id, godown_manager_name = excluded.godown_manager_name,
    godown_manager_mobile = excluded.godown_manager_mobile, updated_by = auth.uid(), updated_at = now();

  RETURN jsonb_build_object('order_id', v_o.id, 'saved', true);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_set_order_pickup(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_order_pickup(uuid, jsonb) TO authenticated;

COMMIT;
