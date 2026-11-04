-- LUXURY WRIST BRAND ERP — SALESMAN MASTER (one place to make a salesman).
--
-- Run after lwb_sales_head_in_team_setup.sql, lwb_company_brand_setup.sql and
-- lwb_employee_login_link_setup.sql. Safe to run again.
--
-- Mohit (4 Nov 2026): when a salesman is made, pick at the same time which brands
-- he may sell (Coca-Cola, Rajnigandha or both). Sales Team Setup, Employee Master,
-- Manage Users and Company / Brand > Team brands are combined into one
-- "Salesman Master" (sales-team.html). One Save here does, in one transaction:
--   1. Employee Master row (lwb_acc_staff) — new or updated, other fields kept;
--   2. ERP login (Admin only) with the mobile number as login ID;
--   3. Field / Office + area (lwb_salesmen);
--   4. brands (lwb_user_companies; every brand / none = all brands).
-- Only existing functions are reused, so their checks stay the same
-- (Admin makes logins; a Sales Head gives only his own brands to salesmen).
--
-- No order, bill, stock, payment, ledger or Tally data is changed.

BEGIN;

-- p: {user_id, staff_id, name, mobile, role: 'sales'|'manager', kind: 'FIELD'|'OFFICE', area,
--     active, company_ids: [uuid], password, joining_date, monthly_salary}
-- Returns {user_id, staff_id, login_made}.
CREATE OR REPLACE FUNCTION public.lwb_salesman_save(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_admin boolean := public.lwb_is_admin();
  v_uid uuid; v_staff bigint; s public.lwb_acc_staff%ROWTYPE; u public.user_profiles%ROWTYPE;
  v_name text := btrim(regexp_replace(coalesce(p->>'name',''), '\s+', ' ', 'g'));
  v_mob text := public.lwb_emp_phone(p->>'mobile');
  v_role text := lower(btrim(coalesce(p->>'role','sales')));
  v_kind text := upper(btrim(coalesce(p->>'kind','FIELD')));
  v_area text := nullif(btrim(coalesce(p->>'area','')), '');
  v_active boolean := coalesce((p->>'active')::boolean, true);
  v_pass text := nullif(p->>'password','');
  v_ids uuid[]; v_now uuid[]; v_made boolean := false; e jsonb;
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  BEGIN
    v_uid := nullif(p->>'user_id','')::uuid;
    v_staff := nullif(p->>'staff_id','')::bigint;
    SELECT coalesce(array_agg(x::uuid), '{}') INTO v_ids FROM jsonb_array_elements_text(coalesce(p->'company_ids','[]'::jsonb)) x;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the salesman and brands';
  END;
  IF v_role NOT IN ('sales','manager') THEN RAISE EXCEPTION 'Post must be Salesman or Sales Head'; END IF;
  IF v_role = 'manager' THEN v_kind := 'OFFICE'; END IF;
  IF v_kind NOT IN ('FIELD','OFFICE') THEN RAISE EXCEPTION 'Type must be Field or Office'; END IF;
  -- Every active brand ticked = all brands (no row), same as before.
  IF EXISTS (SELECT 1 FROM public.lwb_companies c WHERE c.active)
     AND NOT EXISTS (SELECT 1 FROM public.lwb_companies c WHERE c.active AND NOT (c.id = ANY(v_ids))) THEN v_ids := '{}'; END IF;

  -- Who is it: the login, and its Employee Master row.
  IF v_uid IS NOT NULL THEN
    SELECT * INTO u FROM public.user_profiles WHERE id = v_uid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Login not found'; END IF;
    IF lower(btrim(coalesce(u.role,''))) NOT IN ('sales','salesman','manager') THEN RAISE EXCEPTION '% is not a Salesman or Sales Head login', u.full_name; END IF;
    IF v_staff IS NULL THEN SELECT id INTO v_staff FROM public.lwb_acc_staff WHERE user_id = v_uid; END IF;
  END IF;
  IF v_staff IS NOT NULL THEN
    SELECT * INTO s FROM public.lwb_acc_staff WHERE id = v_staff FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Employee not found'; END IF;
    IF v_uid IS NULL THEN v_uid := s.user_id;
    ELSIF s.user_id IS NOT NULL AND s.user_id <> v_uid THEN RAISE EXCEPTION 'This employee is linked to another login'; END IF;
  END IF;

  -- Only Admin makes a login or changes name / mobile / post / active of a login; a Sales Head's
  -- save keeps them as the login has them.
  IF NOT v_admin THEN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'Only Admin can make a new salesman login. Ask Admin to add him.'; END IF;
    IF u.id IS NULL THEN SELECT * INTO u FROM public.user_profiles WHERE id = v_uid; END IF;
    IF lower(btrim(u.role)) = 'manager' OR v_role = 'manager' THEN
      IF lower(btrim(u.role)) <> v_role THEN RAISE EXCEPTION 'Only Admin can change the post'; END IF;
    END IF;
    IF (lower(btrim(u.role)) IN ('sales','salesman')) <> (v_role = 'sales') THEN RAISE EXCEPTION 'Only Admin can change the post'; END IF;
    -- Name, mobile and active stay as the login has them.
    v_name := btrim(coalesce(u.full_name,'')); v_mob := public.lwb_emp_phone(u.mobile); v_active := coalesce(u.active, false);
  END IF;
  IF length(v_name) < 2 OR length(v_name) > 80 THEN RAISE EXCEPTION 'Write the salesman name'; END IF;
  IF v_mob = '' AND v_admin THEN RAISE EXCEPTION 'Mobile should be 10 digits (it is the login ID)'; END IF;
  IF v_uid IS NULL AND (v_pass IS NULL OR length(v_pass) < 6) THEN RAISE EXCEPTION 'Password must be at least 6 characters'; END IF;

  -- 1. Employee Master (keeps every other field of an old row).
  e := jsonb_build_object('name', v_name, 'mobile', nullif(v_mob,''), 'is_active', v_active,
         'designation', CASE WHEN v_role = 'manager' THEN 'Manager' ELSE 'Salesman' END);
  IF p ? 'joining_date' THEN e := e || jsonb_build_object('joining_date', nullif(p->>'joining_date','')); END IF;
  IF p ? 'monthly_salary' THEN e := e || jsonb_build_object('monthly_salary', coalesce(nullif(p->>'monthly_salary',''),'0')); END IF;
  IF v_staff IS NOT NULL THEN
    e := (to_jsonb(s) - 'active' - 'user_id' - 'created_by' - 'created_at') || jsonb_build_object('id', s.id) || e;
  END IF;
  v_staff := (public.lwb_emp_save2(e)->>'id')::bigint;
  -- A login with this mobile made earlier in Manage Users is linked by itself (trigger): use it.
  IF v_uid IS NULL THEN
    SELECT x.user_id INTO v_uid FROM public.lwb_acc_staff x WHERE x.id = v_staff;
    IF v_uid IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.user_profiles x WHERE x.id = v_uid
         AND lower(btrim(coalesce(x.role,''))) IN ('sales','salesman','manager')) THEN
      RAISE EXCEPTION 'Mobile % already has a login of another role. Change it in Manage Users first.', v_mob;
    END IF;
  END IF;

  -- 2. Login.
  IF v_uid IS NULL AND NOT v_admin THEN RAISE EXCEPTION 'Only Admin can make a new salesman login. Ask Admin to add him.'; END IF;
  IF v_uid IS NULL THEN
    v_uid := public.lwb_emp_create_login(v_staff, v_pass, v_role);
    v_made := true;
  ELSE
    UPDATE public.lwb_acc_staff SET user_id = v_uid WHERE id = v_staff AND user_id IS NULL;
    IF v_admin THEN
      SELECT * INTO u FROM public.user_profiles WHERE id = v_uid;
      IF lower(btrim(u.role)) IN ('sales','salesman') AND v_role = 'sales' THEN NULL; -- keep 'salesman' spelling
      ELSIF lower(btrim(u.role)) <> v_role OR u.full_name IS DISTINCT FROM v_name OR u.active IS DISTINCT FROM v_active THEN
        PERFORM public.lwb_admin_set_user_role(v_uid, v_role, v_name, v_active);
      END IF;
      IF u.full_name IS DISTINCT FROM v_name OR u.active IS DISTINCT FROM v_active THEN
        UPDATE public.user_profiles SET full_name = v_name, active = v_active WHERE id = v_uid;
      END IF;
      IF public.lwb_emp_phone(u.mobile) <> v_mob THEN PERFORM public.lwb_admin_set_login(v_uid, v_mob, NULL, false); END IF;
      IF v_pass IS NOT NULL THEN PERFORM public.lwb_admin_set_login(v_uid, NULL, v_pass, false); END IF;
    END IF;
  END IF;

  -- 3. Field / Office + area.
  PERFORM public.lwb_save_salesman(v_uid, v_kind, v_area);

  -- 4. Brands (only when changed, so a Sales Head can still save type / area of a two-brand salesman).
  SELECT coalesce(array_agg(company_id), '{}') INTO v_now FROM public.lwb_user_companies WHERE user_id = v_uid;
  IF NOT (v_now @> v_ids AND v_ids @> v_now) THEN PERFORM public.lwb_set_user_companies(v_uid, v_ids); END IF;

  RETURN jsonb_build_object('user_id', v_uid, 'staff_id', v_staff, 'login_made', v_made);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_salesman_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_salesman_save(jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
