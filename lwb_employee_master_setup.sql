-- LUXURY WRIST BRAND ERP — EMPLOYEE MASTER (GODOWN STAFF) + SALARY LIMIT ON UPAD
--
-- Runs by itself when merged to main (after lwb_accounts_staff_setup.sql and lwb_accounts_vehicle_setup.sql).
-- Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (30 Oct 2026): like Vehicle Master and Driver Master, an Employee Master that the Godown
-- manager keeps. Every godown employee gets an Employee ID (made by the ERP, or typed by hand). Cash Out
-- (upad / salary) is paid to that employee by ID + name and goes in the employee's ledger. A fixed
-- monthly salary is set, and upad in a month must not go over it.
--
-- The employees are the same rows as the Staff ledger of the Accounts Dashboard (lwb_acc_staff), so the
-- ledger, upad and salary all stay in one place. This file adds:
--   * emp_code (Employee ID, e.g. EMP001), joining date and note on lwb_acc_staff; old staff get an ID;
--   * lwb_emp_list / lwb_emp_save for Masters > Employee Master (Admin, Manager, Godown, Accounts);
--   * the monthly limit: in one month, upad (less upad returned) can not go over the salary of that
--     month, and salary paid in one month can not go over it either. Admin can still allow more;
--     that entry is marked over_salary.
-- The salary of a month = the "Salary of <month>" row when Accounts set one (leave / overtime), otherwise
-- the fixed monthly salary. Salary 0 = no limit.

BEGIN;

ALTER TABLE public.lwb_acc_staff
  ADD COLUMN IF NOT EXISTS emp_code text,
  ADD COLUMN IF NOT EXISTS joining_date date,
  ADD COLUMN IF NOT EXISTS note text,
  ADD COLUMN IF NOT EXISTS updated_by uuid,
  ADD COLUMN IF NOT EXISTS updated_at timestamptz;
ALTER TABLE public.lwb_acc_entries ADD COLUMN IF NOT EXISTS over_salary boolean NOT NULL DEFAULT false;

DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_acc_staff_emp_code_chk') THEN
    ALTER TABLE public.lwb_acc_staff ADD CONSTRAINT lwb_acc_staff_emp_code_chk
      CHECK (emp_code IS NULL OR emp_code ~ '^[A-Z0-9][A-Z0-9-]{1,11}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_acc_staff_note_chk') THEN
    ALTER TABLE public.lwb_acc_staff ADD CONSTRAINT lwb_acc_staff_note_chk CHECK (note IS NULL OR length(note) <= 300);
  END IF;
END $do$;
CREATE UNIQUE INDEX IF NOT EXISTS lwb_acc_staff_code_uidx ON public.lwb_acc_staff (emp_code) WHERE emp_code IS NOT NULL;

-- Next free ID: EMP + 3 digits after the biggest EMPnnn used so far.
CREATE OR REPLACE FUNCTION public.lwb_emp_next_code()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT 'EMP' || lpad((coalesce(max(substring(s.emp_code FROM '^EMP([0-9]{1,8})$')::bigint), 0) + 1)::text, 3, '0')
  FROM public.lwb_acc_staff s;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_emp_next_code() FROM PUBLIC, anon, authenticated;

-- A staff added without an ID (also from the Accounts Dashboard) gets the next one.
CREATE OR REPLACE FUNCTION public.lwb_emp_code_fill()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NEW.emp_code IS NULL THEN NEW.emp_code := public.lwb_emp_next_code(); END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_emp_code_fill() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS lwb_acc_staff_code ON public.lwb_acc_staff;
CREATE TRIGGER lwb_acc_staff_code BEFORE INSERT ON public.lwb_acc_staff FOR EACH ROW EXECUTE FUNCTION public.lwb_emp_code_fill();

-- Staff already there get IDs in the order they were added.
DO $do$ DECLARE r record; BEGIN
  FOR r IN SELECT id FROM public.lwb_acc_staff WHERE emp_code IS NULL ORDER BY id LOOP
    UPDATE public.lwb_acc_staff SET emp_code = public.lwb_emp_next_code() WHERE id = r.id;
  END LOOP;
END $do$;

-- Who keeps the Employee Master: Admin, Manager, Godown (warehouse) and Accounts.
CREATE OR REPLACE FUNCTION public.lwb_emp_editor()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','warehouse','accounts'));
$fn$;

-- Salary of a month for the limit: the month's salary row, else the fixed monthly salary.
CREATE OR REPLACE FUNCTION public.lwb_emp_month_cap(p_staff bigint, p_month date)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce((SELECT x.amount FROM public.lwb_acc_staff_salary x WHERE x.staff_id = p_staff AND x.month = date_trunc('month', p_month)::date),
                  (SELECT s.monthly_salary FROM public.lwb_acc_staff s WHERE s.id = p_staff), 0);
$fn$;

-- In one month: upad given less upad returned, and salary paid.
CREATE OR REPLACE FUNCTION public.lwb_emp_month_taken(p_staff bigint, p_month date, OUT upad numeric, OUT paid numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(sum(CASE WHEN e.kind = 'OUT' AND lower(c.name) <> 'salary' THEN e.amount WHEN e.kind = 'IN' THEN -e.amount ELSE 0 END), 0),
         coalesce(sum(CASE WHEN e.kind = 'OUT' AND lower(c.name) = 'salary' THEN e.amount ELSE 0 END), 0)
  FROM public.lwb_acc_entries e LEFT JOIN public.lwb_acc_categories c ON c.id = e.category_id
  WHERE e.staff_id = p_staff AND e.cancelled_at IS NULL AND e.kind IN ('IN','OUT')
    AND e.entry_date >= date_trunc('month', p_month)::date AND e.entry_date < (date_trunc('month', p_month) + interval '1 month')::date;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_emp_month_cap(bigint,date), public.lwb_emp_month_taken(bigint,date) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Entry with the salary limit (everything else as lwb_acc_add_entry3).
-- p adds: {"over_salary":true} = Admin allows more than the salary for this one entry.
-- Over the limit without that: error that starts with OVER_SALARY so the page can ask Admin.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_add_entry4(p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id uuid; v_staff bigint; v_amt numeric; v_date date; v_salary boolean; v_cap numeric; v_upad numeric; v_paid numeric;
        v_used numeric; v_over boolean := false; s public.lwb_acc_staff%ROWTYPE;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only active Accounts or Admin can enter money'; END IF;
  BEGIN
    v_staff := nullif(p->>'staff_id','')::bigint;
    v_amt := round(nullif(p->>'amount','')::numeric, 2);
    v_date := (p->>'date')::date;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the staff, date and amount';
  END;
  IF v_staff IS NOT NULL AND p->>'kind' = 'OUT' AND v_amt > 0 AND v_date IS NOT NULL THEN
    SELECT * INTO s FROM public.lwb_acc_staff WHERE id = v_staff;
    v_cap := public.lwb_emp_month_cap(v_staff, v_date);
    IF s.id IS NOT NULL AND v_cap > 0 THEN
      SELECT lower(c.name) = 'salary' INTO v_salary FROM public.lwb_acc_categories c WHERE c.id = nullif(p->>'category_id','')::bigint;
      SELECT t.upad, t.paid INTO v_upad, v_paid FROM public.lwb_emp_month_taken(v_staff, v_date) t;
      v_used := CASE WHEN coalesce(v_salary,false) THEN v_paid ELSE greatest(v_upad, 0) END;
      IF v_used + v_amt > v_cap + 0.5 THEN
        IF coalesce((p->>'over_salary')::boolean, false) AND public.lwb_acc_admin() THEN
          v_over := true;
        ELSE
          RAISE EXCEPTION 'OVER_SALARY: % (%) salary for % is Rs %. % this month: Rs %. Left: Rs %. Only Admin can give more.',
            s.name, s.emp_code, to_char(v_date,'FMMonth YYYY'), to_char(v_cap,'FM99999999990'),
            CASE WHEN coalesce(v_salary,false) THEN 'Salary already paid' ELSE 'Upad already taken' END,
            to_char(v_used,'FM99999999990'), to_char(greatest(v_cap - v_used, 0),'FM99999999990');
        END IF;
      END IF;
    END IF;
  END IF;
  v_id := public.lwb_acc_add_entry3(p);
  IF v_over THEN UPDATE public.lwb_acc_entries SET over_salary = true WHERE id = v_id; END IF;
  RETURN v_id;
END;
$fn$;

-- Staff list of the Accounts Dashboard (same as before) + Employee ID and this month's limit.
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

-- Masters > Employee Master: every employee with this month's upad / salary paid and what is left.
CREATE OR REPLACE FUNCTION public.lwb_emp_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_m date := date_trunc('month', public.lwb_acc_today())::date;
BEGIN
  IF NOT public.lwb_emp_editor() THEN RAISE EXCEPTION 'Employee Master is for Admin, Manager, Godown and Accounts'; END IF;
  RETURN jsonb_build_object('month', v_m, 'next_code', public.lwb_emp_next_code(), 'rows', coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', s.id, 'emp_code', s.emp_code, 'name', s.name, 'mobile', s.mobile,
      'designation', s.designation, 'monthly_salary', s.monthly_salary, 'joining_date', s.joining_date, 'note', s.note,
      'is_active', s.active, 'month_cap', public.lwb_emp_month_cap(s.id, v_m), 'month_upad', t.upad, 'month_paid', t.paid)
      ORDER BY s.active DESC, s.emp_code, s.name)
    FROM public.lwb_acc_staff s CROSS JOIN LATERAL public.lwb_emp_month_taken(s.id, v_m) t), '[]'::jsonb));
END;
$fn$;

-- p: {"id":null,"emp_code":"","name":"Ramesh","mobile":"98...","designation":"Loader","monthly_salary":15000,
--     "joining_date":"2026-10-01","note":"","is_active":true}   emp_code blank = next free ID.
-- Old balance stays with Accounts (Accounts Dashboard > Staff ledger).
CREATE OR REPLACE FUNCTION public.lwb_emp_save(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id bigint; v_code text := nullif(upper(regexp_replace(coalesce(p->>'emp_code',''), '\s+', '', 'g')),'');
        v_name text := btrim(regexp_replace(coalesce(p->>'name',''), '\s+', ' ', 'g'));
        v_mob text := nullif(regexp_replace(coalesce(p->>'mobile',''), '\D', '', 'g'),'');
        v_des text := nullif(btrim(coalesce(p->>'designation','')),'');
        v_note text := nullif(btrim(coalesce(p->>'note','')),'');
        v_sal numeric; v_join date; v_act boolean;
BEGIN
  IF NOT public.lwb_emp_editor() THEN RAISE EXCEPTION 'Only Admin, Manager, Godown or Accounts can change Employee Master'; END IF;
  BEGIN
    v_id := nullif(p->>'id','')::bigint;
    v_sal := round(coalesce(nullif(p->>'monthly_salary','')::numeric,0),2);
    v_join := nullif(p->>'joining_date','')::date;
    v_act := coalesce((p->>'is_active')::boolean, true);
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the salary and joining date';
  END;
  IF length(v_mob) = 12 AND v_mob LIKE '91%' THEN v_mob := substr(v_mob, 3); END IF;
  IF v_code IS NOT NULL AND v_code !~ '^[A-Z0-9][A-Z0-9-]{1,11}$' THEN RAISE EXCEPTION 'Employee ID: 2 to 12 letters / numbers, e.g. EMP001'; END IF;
  IF length(v_name) < 2 OR length(v_name) > 80 THEN RAISE EXCEPTION 'Write the employee name'; END IF;
  IF v_mob IS NOT NULL AND v_mob !~ '^[6-9][0-9]{9}$' THEN RAISE EXCEPTION 'Mobile should be 10 digits'; END IF;
  IF length(coalesce(v_des,'')) > 60 THEN RAISE EXCEPTION 'Work / post is too long'; END IF;
  IF length(coalesce(v_note,'')) > 300 THEN RAISE EXCEPTION 'Note is too long'; END IF;
  IF v_sal < 0 OR v_sal > 10000000 THEN RAISE EXCEPTION 'Check the salary'; END IF;
  IF v_join IS NOT NULL AND (v_join > public.lwb_acc_today() + 60 OR v_join < date '1980-01-01') THEN RAISE EXCEPTION 'Check the joining date'; END IF;
  IF v_code IS NOT NULL AND EXISTS (SELECT 1 FROM public.lwb_acc_staff s WHERE s.emp_code = v_code AND s.id IS DISTINCT FROM v_id) THEN
    RAISE EXCEPTION 'Employee ID % is already given to %', v_code, (SELECT s.name FROM public.lwb_acc_staff s WHERE s.emp_code = v_code);
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.lwb_acc_staff (emp_code, name, mobile, designation, monthly_salary, joining_date, note, active, created_by)
    VALUES (v_code, v_name, v_mob, v_des, v_sal, v_join, v_note, v_act, auth.uid()) RETURNING id, emp_code INTO v_id, v_code;
  ELSE
    UPDATE public.lwb_acc_staff SET emp_code = coalesce(v_code, emp_code, public.lwb_emp_next_code()), name = v_name, mobile = v_mob,
      designation = v_des, monthly_salary = v_sal, joining_date = v_join, note = v_note, active = v_act,
      updated_by = auth.uid(), updated_at = now()
    WHERE id = v_id RETURNING id, emp_code INTO v_id, v_code;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Employee not found'; END IF;
  END IF;
  RETURN jsonb_build_object('id', v_id, 'emp_code', v_code);
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'An employee with this name or ID already exists';
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_emp_editor(), public.lwb_acc_add_entry4(jsonb), public.lwb_acc_staff_list(date),
  public.lwb_emp_list(), public.lwb_emp_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_emp_editor(), public.lwb_acc_add_entry4(jsonb), public.lwb_acc_staff_list(date),
  public.lwb_emp_list(), public.lwb_emp_save(jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'employee id' AS item,
  EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'lwb_acc_staff' AND column_name = 'emp_code')::text AS ok
UNION ALL SELECT 'staff without id', (SELECT count(*) FROM public.lwb_acc_staff WHERE emp_code IS NULL)::text
UNION ALL SELECT 'salary limit', (to_regprocedure('public.lwb_acc_add_entry4(jsonb)') IS NOT NULL)::text;
