-- LUXURY WRIST BRAND ERP — ACCOUNTS DASHBOARD: STAFF LEDGER (SALARY + UPAD), BILL PHOTO, GST BILL
--
-- Runs by itself when merged to main (after lwb_accounts_dashboard_setup.sql). Safe to run again.
-- Nothing is dropped or deleted.
--
-- Mohit asked (30 Oct 2026):
--  1. Staff like a party master: every staff has a ledger. Salary of the month, upad (advance) taken,
--     salary paid, and what is still to pay (or the upad still to recover).
--  2. Cash Out: "Paid to" picked from staff / earlier names or typed; bill / voucher no. optional;
--     photo of the bill and a GST bill mark (GST amount, GSTIN).
--
-- Staff ledger: balance to pay = opening + salary of each month − salary paid − upad
--                                + upad returned. Below zero = upad still with the staff.
-- Salary paid / upad are normal Cash Out entries (heads "Salary" / "Staff advance") with the staff;
-- upad given back is a Cash In entry (head "Staff advance return"). So they stay in the cash book too.

BEGIN;

ALTER TABLE public.lwb_acc_categories ADD COLUMN IF NOT EXISTS staff_link boolean NOT NULL DEFAULT false;

INSERT INTO public.lwb_acc_categories (kind, name, sort)
SELECT 'IN', 'Staff advance return', 50
WHERE NOT EXISTS (SELECT 1 FROM public.lwb_acc_categories c WHERE c.kind = 'IN' AND lower(btrim(c.name)) = 'staff advance return');
UPDATE public.lwb_acc_categories SET staff_link = true
WHERE staff_link = false AND ((kind = 'OUT' AND lower(btrim(name)) IN ('salary','staff advance'))
                              OR (kind = 'IN' AND lower(btrim(name)) = 'staff advance return'));

CREATE TABLE IF NOT EXISTS public.lwb_acc_staff (
  id              bigserial PRIMARY KEY,
  name            text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 80),
  mobile          text CHECK (mobile IS NULL OR length(mobile) <= 15),
  designation     text CHECK (designation IS NULL OR length(designation) <= 60),
  monthly_salary  numeric(14,2) NOT NULL DEFAULT 0 CHECK (monthly_salary >= 0),
  opening_balance numeric(14,2) NOT NULL DEFAULT 0,
  opening_date    date,
  active          boolean NOT NULL DEFAULT true,
  created_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_acc_staff_name_uidx ON public.lwb_acc_staff(lower(btrim(name)));

-- Salary earned for a month (one row per staff per month; changed in place, 0 = none).
CREATE TABLE IF NOT EXISTS public.lwb_acc_staff_salary (
  id         bigserial PRIMARY KEY,
  staff_id   bigint NOT NULL REFERENCES public.lwb_acc_staff(id),
  month      date NOT NULL CHECK (extract(day FROM month) = 1),
  amount     numeric(14,2) NOT NULL CHECK (amount >= 0),
  note       text CHECK (note IS NULL OR length(note) <= 200),
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (staff_id, month)
);

ALTER TABLE public.lwb_acc_entries
  ADD COLUMN IF NOT EXISTS staff_id bigint REFERENCES public.lwb_acc_staff(id),
  ADD COLUMN IF NOT EXISTS photo_paths text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS gst_bill boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS gst_amount numeric(14,2) CHECK (gst_amount IS NULL OR gst_amount >= 0),
  ADD COLUMN IF NOT EXISTS gstin text CHECK (gstin IS NULL OR length(gstin) <= 15),
  ADD COLUMN IF NOT EXISTS entry_time time,
  ADD COLUMN IF NOT EXISTS cash_notes jsonb;

ALTER TABLE public.lwb_acc_staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_acc_staff_salary ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_acc_staff, public.lwb_acc_staff_salary FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Private bucket for bill photos: upload into your own folder, read by Accounts / Admin.
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lwb-acc-bills', 'lwb-acc-bills', false, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
DROP POLICY IF EXISTS lwb_acc_bill_upload ON storage.objects;
CREATE POLICY lwb_acc_bill_upload ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'lwb-acc-bills' AND (storage.foldername(name))[1] = auth.uid()::text AND public.lwb_acc_user());
DROP POLICY IF EXISTS lwb_acc_bill_read ON storage.objects;
CREATE POLICY lwb_acc_bill_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'lwb-acc-bills' AND public.lwb_acc_user());

-- ---------------------------------------------------------------------------
-- Entry with staff / bill photos / GST. Same checks as lwb_acc_add_entry, plus:
-- a staff head (Salary, Staff advance, Staff advance return) needs the staff.
-- p adds: {"staff_id":3,"photos":["<uid>/x.jpg"],"gst_bill":true,"gst_amount":180,"gstin":"24ABCDE1234F1Z5"}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_add_entry2(p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_id uuid; v_staff bigint; v_link boolean; v_photos text[] := '{}'; v_x text;
  v_gst boolean := coalesce((p->>'gst_bill')::boolean, false); v_gamt numeric; v_gstin text;
  v_time time; v_notes jsonb;
BEGIN
  BEGIN
    v_staff := nullif(p->>'staff_id','')::bigint;
    v_gamt := round(nullif(p->>'gst_amount','')::numeric, 2);
    v_time := nullif(p->>'time','')::time;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the staff, time and GST amount';
  END;
  v_gstin := nullif(upper(btrim(coalesce(p->>'gstin',''))),'');
  IF jsonb_typeof(p->'photos') = 'array' THEN
    FOR v_x IN SELECT jsonb_array_elements_text(p->'photos') LOOP
      IF v_x !~ ('^' || auth.uid()::text || '/[A-Za-z0-9_.-]{1,80}$') THEN RAISE EXCEPTION 'Bad photo'; END IF;
      v_photos := v_photos || v_x;
    END LOOP;
  END IF;
  IF cardinality(v_photos) > 5 THEN RAISE EXCEPTION 'Up to 5 photos'; END IF;
  IF v_gstin IS NOT NULL AND v_gstin !~ '^[0-9]{2}[A-Z0-9]{13}$' THEN RAISE EXCEPTION 'GSTIN should be 15 letters / numbers'; END IF;
  IF NOT v_gst THEN v_gamt := NULL; v_gstin := NULL; END IF;
  -- note count of a cash entry: {"500":3,"100":2}, only the usual notes
  IF jsonb_typeof(p->'notes') = 'object' THEN
    SELECT jsonb_object_agg(k, v::int) INTO v_notes FROM jsonb_each_text(p->'notes') AS n(k, v)
    WHERE k IN ('500','200','100','50','20','10') AND v ~ '^[0-9]{1,5}$' AND v::int > 0;
  END IF;

  v_id := public.lwb_acc_add_entry(p);   -- all the normal checks

  SELECT c.staff_link INTO v_link FROM public.lwb_acc_entries e JOIN public.lwb_acc_categories c ON c.id = e.category_id WHERE e.id = v_id;
  IF coalesce(v_link,false) THEN
    IF v_staff IS NULL THEN RAISE EXCEPTION 'Choose the staff'; END IF;
  END IF;
  IF v_staff IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_staff s WHERE s.id = v_staff AND s.active) THEN
    RAISE EXCEPTION 'Choose an active staff';
  END IF;
  IF v_gamt IS NOT NULL AND v_gamt > (SELECT e.amount FROM public.lwb_acc_entries e WHERE e.id = v_id) THEN
    RAISE EXCEPTION 'GST amount is more than the bill amount';
  END IF;

  UPDATE public.lwb_acc_entries SET staff_id = v_staff, photo_paths = v_photos, gst_bill = v_gst, gst_amount = v_gamt, gstin = v_gstin, entry_time = v_time, cash_notes = v_notes,
    party = coalesce(party, (SELECT s.name FROM public.lwb_acc_staff s WHERE s.id = v_staff))
  WHERE id = v_id;
  RETURN v_id;
END;
$fn$;

-- Extra details of the page's own entries in the dates + staff list + names used before.
CREATE OR REPLACE FUNCTION public.lwb_acc_extras(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_parties jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts Dashboard is for active Accounts or Admin only'; END IF;
  -- Party Master names for the Party box (same list the Cashbook uses)
  IF to_regclass('public.lwb_customer_master') IS NOT NULL THEN
    EXECUTE $q$SELECT coalesce(jsonb_agg(n ORDER BY n), '[]'::jsonb) FROM (SELECT DISTINCT btrim(m.customer_name::text) AS n
      FROM public.lwb_customer_master m WHERE nullif(btrim(m.customer_name::text), '') IS NOT NULL) x$q$ INTO v_parties;
  END IF;
  RETURN jsonb_build_object(
    'entries', coalesce((SELECT jsonb_object_agg(e.id, jsonb_build_object('staff_id', e.staff_id, 'staff', s.name,
        'photos', to_jsonb(e.photo_paths), 'gst_bill', e.gst_bill, 'gst_amount', e.gst_amount, 'gstin', e.gstin,
        'time', to_char(e.entry_time,'HH24:MI'), 'notes', e.cash_notes))
      FROM public.lwb_acc_entries e LEFT JOIN public.lwb_acc_staff s ON s.id = e.staff_id
      WHERE e.cancelled_at IS NULL AND e.entry_date BETWEEN p_from AND p_to
        AND (e.staff_id IS NOT NULL OR e.gst_bill OR cardinality(e.photo_paths) > 0 OR e.entry_time IS NOT NULL OR e.cash_notes IS NOT NULL)), '{}'::jsonb),
    'staff_heads', coalesce((SELECT jsonb_agg(c.id) FROM public.lwb_acc_categories c WHERE c.staff_link), '[]'::jsonb),
    'payees', coalesce((SELECT jsonb_agg(x.party ORDER BY x.n DESC) FROM (
        SELECT e.party, count(*) AS n FROM public.lwb_acc_entries e
        WHERE e.cancelled_at IS NULL AND e.party IS NOT NULL AND e.staff_id IS NULL AND e.entry_date > public.lwb_acc_today() - 365
        GROUP BY e.party ORDER BY count(*) DESC LIMIT 300) x), '[]'::jsonb),
    'parties', v_parties
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Staff master + ledger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_staff_lines(p_staff bigint)
RETURNS TABLE (d date, at timestamptz, kind text, particulars text, plus numeric, minus numeric, ref text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT s.month, s.created_at, 'SALARY', 'Salary for ' || to_char(s.month,'FMMonth YYYY') || coalesce(' · ' || s.note,''),
         s.amount, 0::numeric, NULL::text
  FROM public.lwb_acc_staff_salary s WHERE s.staff_id = p_staff AND s.amount > 0
  UNION ALL
  SELECT e.entry_date, e.created_at, CASE WHEN e.kind = 'IN' THEN 'RETURN' WHEN lower(c.name) = 'salary' THEN 'PAID' ELSE 'UPAD' END,
         c.name || ' · ' || e.mode || coalesce(' · ' || e.remark,''),
         CASE WHEN e.kind = 'IN' THEN e.amount ELSE 0 END, CASE WHEN e.kind = 'OUT' THEN e.amount ELSE 0 END, e.ref_no
  FROM public.lwb_acc_entries e LEFT JOIN public.lwb_acc_categories c ON c.id = e.category_id
  WHERE e.staff_id = p_staff AND e.cancelled_at IS NULL AND e.kind IN ('IN','OUT');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_staff_lines(bigint) FROM PUBLIC, anon, authenticated;

-- Every staff with this month's salary / paid / upad and the balance.
CREATE OR REPLACE FUNCTION public.lwb_acc_staff_list(p_month date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_m date := date_trunc('month', coalesce(p_month, public.lwb_acc_today()))::date;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts or Admin only'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'mobile', s.mobile, 'designation', s.designation, 'monthly_salary', s.monthly_salary,
      'opening_balance', s.opening_balance, 'opening_date', s.opening_date, 'active', s.active,
      'month_salary', (SELECT x.amount FROM public.lwb_acc_staff_salary x WHERE x.staff_id = s.id AND x.month = v_m),
      'month_paid', coalesce((SELECT sum(l.minus) FROM public.lwb_acc_staff_lines(s.id) l WHERE l.kind = 'PAID' AND date_trunc('month', l.d) = v_m),0),
      'month_upad', coalesce((SELECT sum(l.minus) FROM public.lwb_acc_staff_lines(s.id) l WHERE l.kind = 'UPAD' AND date_trunc('month', l.d) = v_m),0),
      'balance', round(s.opening_balance + coalesce((SELECT sum(l.plus - l.minus) FROM public.lwb_acc_staff_lines(s.id) l
                       WHERE s.opening_date IS NULL OR l.d >= s.opening_date),0), 2))
      ORDER BY s.active DESC, s.name)
    FROM public.lwb_acc_staff s), '[]'::jsonb);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_staff_ledger(p_staff bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE s public.lwb_acc_staff%ROWTYPE;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts or Admin only'; END IF;
  SELECT * INTO s FROM public.lwb_acc_staff WHERE id = p_staff;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Staff not found'; END IF;
  RETURN jsonb_build_object('staff', to_jsonb(s), 'lines', coalesce((
    SELECT jsonb_agg(jsonb_build_object('date', l.d, 'at', l.at, 'kind', l.kind, 'particulars', l.particulars,
           'plus', l.plus, 'minus', l.minus, 'ref', l.ref) ORDER BY l.d, l.at)
    FROM public.lwb_acc_staff_lines(p_staff) l WHERE s.opening_date IS NULL OR l.d >= s.opening_date), '[]'::jsonb));
END;
$fn$;

-- p: {"id":null,"name":"Ramesh","mobile":"98...","designation":"Loader","monthly_salary":15000,
--     "opening_balance":-2000,"opening_date":"2026-10-01","active":true}
-- opening_balance: + = company still has to pay him, − = upad still with him.
CREATE OR REPLACE FUNCTION public.lwb_acc_save_staff(p jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id bigint := nullif(p->>'id','')::bigint;
        v_name text := btrim(regexp_replace(coalesce(p->>'name',''), '\s+', ' ', 'g'));
        v_mob text := nullif(regexp_replace(coalesce(p->>'mobile',''), '\D', '', 'g'),'');
        v_des text := nullif(btrim(coalesce(p->>'designation','')),'');
        v_sal numeric; v_open numeric; v_od date; v_act boolean := coalesce((p->>'active')::boolean, true);
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts or Admin only'; END IF;
  BEGIN
    v_sal := round(coalesce(nullif(p->>'monthly_salary','')::numeric,0),2);
    v_open := round(coalesce(nullif(p->>'opening_balance','')::numeric,0),2);
    v_od := nullif(p->>'opening_date','')::date;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check salary, opening balance and date';
  END;
  IF length(v_name) < 2 OR length(v_name) > 80 THEN RAISE EXCEPTION 'Write the staff name'; END IF;
  IF v_mob IS NOT NULL AND length(v_mob) NOT IN (10,12) THEN RAISE EXCEPTION 'Mobile should be 10 digits'; END IF;
  IF length(coalesce(v_des,'')) > 60 THEN RAISE EXCEPTION 'Work / post is too long'; END IF;
  IF v_sal < 0 OR v_sal > 10000000 OR abs(v_open) > 10000000 THEN RAISE EXCEPTION 'Check the amounts'; END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.lwb_acc_staff (name, mobile, designation, monthly_salary, opening_balance, opening_date, active, created_by)
    VALUES (v_name, v_mob, v_des, v_sal, v_open, v_od, true, auth.uid()) RETURNING id INTO v_id;
  ELSE
    UPDATE public.lwb_acc_staff SET name = v_name, mobile = v_mob, designation = v_des, monthly_salary = v_sal,
      opening_balance = v_open, opening_date = v_od, active = v_act WHERE id = v_id RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Staff not found'; END IF;
  END IF;
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'A staff with this name already exists';
END;
$fn$;

-- Salary of a month for many staff at once. p_rows: [{"staff_id":1,"amount":15000,"note":"2 days leave"}]
CREATE OR REPLACE FUNCTION public.lwb_acc_save_salaries(p_month date, p_rows jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_m date := date_trunc('month', p_month)::date; r jsonb; v_n integer := 0; v_amt numeric; v_staff bigint;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts or Admin only'; END IF;
  IF v_m IS NULL OR v_m > date_trunc('month', public.lwb_acc_today())::date OR v_m < (date_trunc('month', public.lwb_acc_today()) - interval '24 months')::date THEN
    RAISE EXCEPTION 'Choose a month in the last 2 years';
  END IF;
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Nothing to save'; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    BEGIN
      v_staff := (r->>'staff_id')::bigint; v_amt := round(coalesce(nullif(r->>'amount','')::numeric,0),2);
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the salary amounts';
    END;
    IF v_amt < 0 OR v_amt > 10000000 THEN RAISE EXCEPTION 'Check the salary amounts'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.lwb_acc_staff s WHERE s.id = v_staff) THEN RAISE EXCEPTION 'Staff not found'; END IF;
    INSERT INTO public.lwb_acc_staff_salary (staff_id, month, amount, note, created_by)
    VALUES (v_staff, v_m, v_amt, left(nullif(btrim(coalesce(r->>'note','')),''),200), auth.uid())
    ON CONFLICT (staff_id, month) DO UPDATE SET amount = EXCLUDED.amount, note = EXCLUDED.note,
      created_by = EXCLUDED.created_by, created_at = now();
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_add_entry2(jsonb), public.lwb_acc_extras(date,date), public.lwb_acc_staff_list(date),
  public.lwb_acc_staff_ledger(bigint), public.lwb_acc_save_staff(jsonb), public.lwb_acc_save_salaries(date,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_add_entry2(jsonb), public.lwb_acc_extras(date,date), public.lwb_acc_staff_list(date),
  public.lwb_acc_staff_ledger(bigint), public.lwb_acc_save_staff(jsonb), public.lwb_acc_save_salaries(date,jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'staff table' AS item, (to_regclass('public.lwb_acc_staff') IS NOT NULL)::text AS ok
UNION ALL SELECT 'staff ledger', (to_regprocedure('public.lwb_acc_staff_ledger(bigint)') IS NOT NULL)::text
UNION ALL SELECT 'bill photo bucket', EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'lwb-acc-bills')::text;
