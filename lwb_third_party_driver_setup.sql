-- Third-party drivers in Employee Master (18 Nov 2026).
-- Drivers of hired / transporter vehicles (e.g. Umesh Pawar LWB0146, Kuldip Kumar LWB0147) were added
-- as employees by mistake. They stay in Employee Master (so PO Approval / Transport Assignment can still
-- pick them and their Driver Portal login keeps working), but are marked "Third-party driver":
--   * no salary, no advance (upad): monthly salary is 0, Accounts staff list leaves them out;
--   * their rent is paid on the vehicle (Vehicle Master > Hired · fixed rent, trip rent ledger);
--   * Employee Master shows their trips this month from Transport Assignment.
-- Run after lwb_employee_roles_setup.sql. Safe to run again.
BEGIN;

ALTER TABLE public.lwb_acc_staff ADD COLUMN IF NOT EXISTS third_party boolean NOT NULL DEFAULT false;

-- Employee Master list: same as before + third_party, the default vehicle's hired rent setup and
-- this month's Transport Assignment trips (one trip = one vehicle on one day) of the driver.
CREATE OR REPLACE FUNCTION public.lwb_emp_list2()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v jsonb := public.lwb_emp_list(); v_m date := date_trunc('month', public.lwb_acc_today())::date;
        v_hired boolean := to_regclass('public.lwb_hired_vehicles') IS NOT NULL;
BEGIN
  RETURN jsonb_set(v, '{rows}', coalesce((
    SELECT jsonb_agg(e.r || jsonb_build_object('alt_mobile', s.alt_mobile, 'license_no', s.license_no,
      'license_expiry', s.license_expiry, 'default_vehicle_id', s.default_vehicle_id, 'vehicle_no', vh.vehicle_no,
      'transporter_name', s.transporter_name, 'address', s.address, 'third_party', s.third_party,
      'vehicle_ownership', vh.ownership,
      'hired', CASE WHEN v_hired AND s.default_vehicle_id IS NOT NULL THEN public.lwb_tp_hired(s.default_vehicle_id) END,
      'month_trips', CASE WHEN s.third_party THEN public.lwb_tp_trips(s.mobile, vh.vehicle_no, v_m) END) ORDER BY e.n)
    FROM jsonb_array_elements(coalesce(v->'rows', '[]'::jsonb)) WITH ORDINALITY e(r, n)
    LEFT JOIN public.lwb_acc_staff s ON s.id = (e.r->>'id')::bigint
    LEFT JOIN public.lwb_vehicles vh ON vh.id = s.default_vehicle_id), '[]'::jsonb));
END;
$fn$;

-- Hired rent setup of a vehicle (NULL when not hired): {rent_type, trip_rate, monthly_rent, start_date}.
CREATE OR REPLACE FUNCTION public.lwb_tp_hired(p_vehicle uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r jsonb;
BEGIN
  EXECUTE 'SELECT jsonb_build_object(''rent_type'', h.rent_type, ''trip_rate'', h.trip_rate, ''monthly_rent'', h.monthly_rent, ''start_date'', h.start_date)
           FROM public.lwb_hired_vehicles h WHERE h.vehicle_id = $1 AND h.active' INTO r USING p_vehicle;
  RETURN r;
END;
$fn$;

-- Trips of a driver in a month from Transport Assignment: matched by the driver's mobile, or by the
-- driver's default vehicle. Cancelled POs are left out. {trips, pos}
CREATE OR REPLACE FUNCTION public.lwb_tp_trips(p_mobile text, p_vehicle text, p_month date)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  WITH a AS (
    SELECT DISTINCT a.order_id, (a.assigned_at AT TIME ZONE 'Asia/Kolkata')::date AS d,
           upper(regexp_replace(coalesce(a.vehicle_no,''), '[^A-Za-z0-9]', '', 'g')) AS vk
    FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
    WHERE a.assigned_at >= (p_month::timestamp AT TIME ZONE 'Asia/Kolkata')
      AND a.assigned_at < ((p_month + interval '1 month')::timestamp AT TIME ZONE 'Asia/Kolkata')
      AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected')
      AND ((public.lwb_emp_phone(p_mobile) <> '' AND public.lwb_emp_phone(a.driver_mobile) = public.lwb_emp_phone(p_mobile))
        OR (coalesce(p_vehicle,'') <> '' AND upper(regexp_replace(a.vehicle_no, '[^A-Za-z0-9]', '', 'g'))
                                            = upper(regexp_replace(p_vehicle, '[^A-Za-z0-9]', '', 'g')))))
  SELECT jsonb_build_object('trips', (SELECT count(DISTINCT (d, vk)) FROM a), 'pos', (SELECT count(DISTINCT order_id) FROM a));
$fn$;

-- Same as lwb_employee_roles_setup.sql + p.third_party (true / false; left out = unchanged).
-- A third-party driver gets salary 0 and no salary rows from this month on.
CREATE OR REPLACE FUNCTION public.lwb_emp_save2(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r jsonb; v_id bigint; v_driver boolean := public.lwb_emp_role(p->>'designation') = 'driver';
        v_mob text := public.lwb_emp_phone(p->>'mobile'); v_alt text := nullif(regexp_replace(coalesce(p->>'alt_mobile',''), '\D', '', 'g'), '');
        v_lic text := nullif(upper(btrim(coalesce(p->>'license_no',''))), ''); v_exp date; v_veh uuid;
        v_tr text := nullif(btrim(coalesce(p->>'transporter_name','')), ''); v_addr text := nullif(btrim(coalesce(p->>'address','')), '');
        v_other text; v_tp boolean; v_p jsonb := p;
BEGIN
  IF NOT public.lwb_emp_editor() THEN RAISE EXCEPTION 'Only Admin, Manager, Godown or Accounts can change Employee Master'; END IF;
  BEGIN
    v_id := nullif(p->>'id','')::bigint;
    v_exp := nullif(p->>'license_expiry','')::date;
    v_veh := nullif(p->>'default_vehicle_id','')::uuid;
    v_tp := nullif(p->>'third_party','')::boolean;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the licence expiry date and the vehicle';
  END;
  IF v_tp IS NULL AND v_id IS NOT NULL THEN SELECT s.third_party INTO v_tp FROM public.lwb_acc_staff s WHERE s.id = v_id; END IF;
  v_tp := coalesce(v_tp, false);
  IF v_tp AND NOT v_driver THEN RAISE EXCEPTION 'Only a Driver can be marked as a third-party driver'; END IF;
  IF v_tp THEN v_p := v_p || '{"monthly_salary":0}'::jsonb; END IF;
  IF v_alt IS NOT NULL THEN v_alt := public.lwb_emp_phone(v_alt); IF v_alt = '' THEN RAISE EXCEPTION 'Alternate mobile should be 10 digits'; END IF; END IF;
  IF length(coalesce(v_lic,'')) > 40 THEN RAISE EXCEPTION 'Licence number is too long'; END IF;
  IF length(coalesce(v_tr,'')) > 150 THEN RAISE EXCEPTION 'Transporter name is too long'; END IF;
  IF length(coalesce(v_addr,'')) > 500 THEN RAISE EXCEPTION 'Address is too long'; END IF;
  IF v_veh IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_vehicles x WHERE x.id = v_veh) THEN RAISE EXCEPTION 'Vehicle not found in Vehicle Master'; END IF;
  IF v_driver THEN
    IF v_mob = '' THEN RAISE EXCEPTION 'A Driver needs a 10-digit mobile number (the Driver Portal login is matched by it)'; END IF;
    IF coalesce((p->>'is_active')::boolean, true) THEN
      SELECT x.emp_code || ' · ' || x.name INTO v_other FROM public.lwb_acc_staff x
      WHERE x.active AND public.lwb_emp_role(x.designation) = 'driver' AND public.lwb_emp_phone(x.mobile) = v_mob
        AND x.id IS DISTINCT FROM v_id LIMIT 1;
      IF v_other IS NOT NULL THEN RAISE EXCEPTION 'Mobile % is already given to driver %', v_mob, v_other; END IF;
    END IF;
  END IF;
  r := public.lwb_emp_save(v_p);
  UPDATE public.lwb_acc_staff SET alt_mobile = v_alt, license_no = v_lic, license_expiry = v_exp, default_vehicle_id = v_veh,
    transporter_name = v_tr, address = v_addr, third_party = v_tp
  WHERE id = (r->>'id')::bigint;
  IF v_tp THEN
    DELETE FROM public.lwb_acc_staff_salary x WHERE x.staff_id = (r->>'id')::bigint
      AND x.month >= date_trunc('month', public.lwb_acc_today())::date;
  END IF;
  RETURN r;
END;
$fn$;

-- Accounts Dashboard staff list: same as lwb_employee_master_setup.sql + third_party, so the page keeps
-- third-party drivers out of Staff, Salary and the Cash Out "paid to" list.
CREATE OR REPLACE FUNCTION public.lwb_acc_staff_list(p_month date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_m date := date_trunc('month', coalesce(p_month, public.lwb_acc_today()))::date;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts or Admin only'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id', s.id, 'emp_code', s.emp_code, 'name', s.name, 'mobile', s.mobile, 'designation', s.designation, 'monthly_salary', s.monthly_salary,
      'opening_balance', s.opening_balance, 'opening_date', s.opening_date, 'active', s.active, 'joining_date', s.joining_date,
      'third_party', s.third_party,
      'month_salary', (SELECT x.amount FROM public.lwb_acc_staff_salary x WHERE x.staff_id = s.id AND x.month = v_m),
      'month_paid', coalesce((SELECT sum(l.minus) FROM public.lwb_acc_staff_lines(s.id) l WHERE l.kind = 'PAID' AND date_trunc('month', l.d) = v_m),0),
      'month_upad', coalesce((SELECT sum(l.minus) FROM public.lwb_acc_staff_lines(s.id) l WHERE l.kind = 'UPAD' AND date_trunc('month', l.d) = v_m),0),
      'month_cap', public.lwb_emp_month_cap(s.id, v_m),
      'month_upad_net', (SELECT t.upad FROM public.lwb_emp_month_taken(s.id, v_m) t),
      'balance', round(s.opening_balance + coalesce((SELECT sum(l.plus - l.minus) FROM public.lwb_acc_staff_lines(s.id) l
                       WHERE s.opening_date IS NULL OR l.d >= s.opening_date),0), 2))
      ORDER BY s.active DESC, s.emp_code, s.name)
    FROM public.lwb_acc_staff s), '[]'::jsonb);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_tp_hired(uuid), public.lwb_tp_trips(text,text,date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_emp_list2(), public.lwb_emp_save2(jsonb), public.lwb_acc_staff_list(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_emp_list2(), public.lwb_emp_save2(jsonb), public.lwb_acc_staff_list(date) TO authenticated;

-- Mohit, 18 Nov 2026: these two are drivers of third-party transport, not employees.
UPDATE public.lwb_acc_staff SET third_party = true, monthly_salary = 0
WHERE emp_code IN ('LWB0146','LWB0147') AND public.lwb_emp_role(designation) = 'driver';
DELETE FROM public.lwb_acc_staff_salary x USING public.lwb_acc_staff s
WHERE x.staff_id = s.id AND s.third_party AND x.month >= date '2026-11-01';

COMMIT;
