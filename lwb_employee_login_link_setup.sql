-- LUXURY WRIST BRAND ERP — EMPLOYEE MASTER <-> ERP LOGIN
--
-- Runs by itself when merged to main (after lwb_employee_roles_setup.sql and lwb_user_login_setup.sql).
-- Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (1 Nov 2026): whoever is added in Employee Master must show up wherever that post is picked:
-- drivers, Godown Managers, salesmen, task assignees. Tasks, Godown Manager (loading) and salesmen go to a
-- person's own ERP login (popup / notification), so every employee who needs one gets a login linked to
-- the employee record:
--   * lwb_acc_staff.user_id = the employee's ERP login (one login = one employee);
--   * linked by itself when the employee's mobile and the login mobile are the same 10 digits (old ones now,
--     and every time an employee or a login is saved);
--   * lwb_emp_create_login: Admin makes the login from the employee (name, mobile, role from the Work / Post);
--   * lwb_emp_link_login: Admin links / unlinks by hand;
--   * lwb_emp_logins: who has a login, for Employee Master and Manage Users.
-- Work / Post -> login role: Driver = driver, Godown Manager = warehouse, Manager = manager,
-- Salesman = sales, Accounts = accounts, Transport = transport. Other posts (Loader, Packer ...) need no login.
-- No order, stock, bill, payment, ledger or Tally data is changed.

BEGIN;

ALTER TABLE public.lwb_acc_staff ADD COLUMN IF NOT EXISTS user_id uuid;

CREATE OR REPLACE FUNCTION public.lwb_emp_login_role(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE public.lwb_emp_role(p)
    WHEN 'driver' THEN 'driver' WHEN 'godown manager' THEN 'warehouse' WHEN 'manager' THEN 'manager'
    WHEN 'salesman' THEN 'sales' WHEN 'accounts' THEN 'accounts' WHEN 'transport' THEN 'transport' END;
$fn$;

-- Old employees: link to the login with the same mobile (one to one; an active employee first).
WITH m AS (
  SELECT DISTINCT ON (p.id) s.id AS staff_id, p.id AS user_id
  FROM public.lwb_acc_staff s
  JOIN public.user_profiles p ON public.lwb_emp_phone(p.mobile) <> '' AND public.lwb_emp_phone(p.mobile) = public.lwb_emp_phone(s.mobile)
  WHERE s.user_id IS NULL
    AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_staff x WHERE x.user_id = p.id)
  ORDER BY p.id, s.active DESC, s.id
), one AS (SELECT DISTINCT ON (staff_id) staff_id, user_id FROM m ORDER BY staff_id, user_id)
UPDATE public.lwb_acc_staff s SET user_id = one.user_id FROM one WHERE s.id = one.staff_id;

CREATE UNIQUE INDEX IF NOT EXISTS lwb_acc_staff_user_uidx ON public.lwb_acc_staff (user_id) WHERE user_id IS NOT NULL;

-- Employee saved with a mobile: link to the free login with that mobile.
CREATE OR REPLACE FUNCTION public.lwb_emp_autolink_staff()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NEW.user_id IS NULL AND public.lwb_emp_phone(NEW.mobile) <> '' THEN
    SELECT p.id INTO NEW.user_id FROM public.user_profiles p
    WHERE public.lwb_emp_phone(p.mobile) = public.lwb_emp_phone(NEW.mobile)
      AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_staff x WHERE x.user_id = p.id AND x.id IS DISTINCT FROM NEW.id)
    LIMIT 1;
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_emp_autolink_staff() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS lwb_acc_staff_autolink ON public.lwb_acc_staff;
CREATE TRIGGER lwb_acc_staff_autolink BEFORE INSERT OR UPDATE OF mobile ON public.lwb_acc_staff
  FOR EACH ROW EXECUTE FUNCTION public.lwb_emp_autolink_staff();

-- Login made / its mobile changed in Manage Users: link to the employee with that mobile and no login yet.
-- Never stops the login from being saved.
CREATE OR REPLACE FUNCTION public.lwb_emp_autolink_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF current_setting('lwb.emp_linking', true) = '1' OR public.lwb_emp_phone(NEW.mobile) = '' THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_acc_staff x WHERE x.user_id = NEW.id) THEN RETURN NULL; END IF;
  UPDATE public.lwb_acc_staff s SET user_id = NEW.id
  WHERE s.id = (SELECT x.id FROM public.lwb_acc_staff x
                WHERE x.user_id IS NULL AND public.lwb_emp_phone(x.mobile) = public.lwb_emp_phone(NEW.mobile)
                ORDER BY x.active DESC, x.id LIMIT 1);
  RETURN NULL;
EXCEPTION WHEN others THEN RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_emp_autolink_user() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS zz_lwb_user_emp_autolink ON public.user_profiles;
CREATE TRIGGER zz_lwb_user_emp_autolink AFTER INSERT OR UPDATE OF mobile ON public.user_profiles
  FOR EACH ROW EXECUTE FUNCTION public.lwb_emp_autolink_user();

-- Every employee with its login (Employee Master keepers and Admin).
CREATE OR REPLACE FUNCTION public.lwb_emp_logins()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT (public.lwb_emp_editor() OR public.lwb_is_admin()) THEN RAISE EXCEPTION 'Employee Master is for Admin, Manager, Godown and Accounts'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', s.id, 'emp_code', s.emp_code, 'name', s.name, 'mobile', s.mobile,
      'designation', s.designation, 'is_active', s.active, 'user_id', s.user_id, 'login_role', lower(btrim(p.role)),
      'login_active', p.active, 'login_name', p.full_name, 'login_mobile', p.mobile, 'role_for_post', public.lwb_emp_login_role(s.designation))
      ORDER BY s.active DESC, s.emp_code, s.name)
    FROM public.lwb_acc_staff s LEFT JOIN public.user_profiles p ON p.id = s.user_id), '[]'::jsonb);
END;
$fn$;

-- Admin: make the ERP login of an employee. Role blank = from the Work / Post.
CREATE OR REPLACE FUNCTION public.lwb_emp_create_login(p_staff bigint, p_password text, p_role text DEFAULT NULL, p_email text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE s public.lwb_acc_staff%ROWTYPE; v_role text; v_id uuid;
BEGIN
  IF NOT public.lwb_is_admin() THEN RAISE EXCEPTION 'Only an active Admin can create logins'; END IF;
  SELECT * INTO s FROM public.lwb_acc_staff WHERE id = p_staff FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Employee not found'; END IF;
  IF s.user_id IS NOT NULL THEN RAISE EXCEPTION '% already has an ERP login', s.name; END IF;
  v_role := coalesce(nullif(lower(btrim(coalesce(p_role,''))), ''), public.lwb_emp_login_role(s.designation));
  IF v_role IS NULL THEN RAISE EXCEPTION 'Choose the login role for Work / Post %', coalesce(s.designation, '-'); END IF;
  PERFORM set_config('lwb.emp_linking', '1', true);
  v_id := public.lwb_admin_create_user(s.name, s.mobile, p_email, p_password, v_role, s.active);
  PERFORM set_config('lwb.emp_linking', '', true);
  UPDATE public.lwb_acc_staff SET user_id = v_id WHERE id = p_staff;
  RETURN v_id;
END;
$fn$;

-- Admin: link an employee to a login by hand (p_user NULL = unlink).
CREATE OR REPLACE FUNCTION public.lwb_emp_link_login(p_staff bigint, p_user uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_other text;
BEGIN
  IF NOT public.lwb_is_admin() THEN RAISE EXCEPTION 'Only an active Admin can link logins'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_acc_staff WHERE id = p_staff) THEN RAISE EXCEPTION 'Employee not found'; END IF;
  IF p_user IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = p_user) THEN RAISE EXCEPTION 'Login not found'; END IF;
    SELECT x.emp_code || ' · ' || x.name INTO v_other FROM public.lwb_acc_staff x WHERE x.user_id = p_user AND x.id <> p_staff;
    IF v_other IS NOT NULL THEN RAISE EXCEPTION 'This login is already linked to %', v_other; END IF;
  END IF;
  UPDATE public.lwb_acc_staff SET user_id = p_user WHERE id = p_staff;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_emp_logins(), public.lwb_emp_create_login(bigint,text,text,text), public.lwb_emp_link_login(bigint,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_emp_logins(), public.lwb_emp_create_login(bigint,text,text,text), public.lwb_emp_link_login(bigint,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_emp_login_role(text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'employees with ERP login' AS item, (SELECT count(*) FROM public.lwb_acc_staff WHERE user_id IS NOT NULL)::text AS value
UNION ALL SELECT 'working employees without login', (SELECT count(*) FROM public.lwb_acc_staff WHERE user_id IS NULL AND active)::text;
