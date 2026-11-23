-- LUXURY WRIST BRAND ERP — PARTY MOBILE NUMBER TASK (fill the missing mobile numbers)
--
-- Mohit asked (21 Nov 2026): every party without a mobile number becomes pending work.
--   * Each salesman gets ONE task for his own parties (lwb_party_salesman) that have no mobile.
--   * The Sales Head (MANAGER) gets ONE task for every party (parties with no salesman, or whose
--     salesman login is not active, are his own).
--   * 🔔 TASK_NEW bell (normal task system, lwb_task_management_setup.sql). The task says how many.
--   * Pending list page party-mobile.html: type the number, Save, the party leaves the list.
--   * When a person's list is empty his task closes as DONE by itself (bell to the giver).
--   * Admin / Sales Head see progress person-wise (pending, filled, task status).
--
-- A mobile is "missing" when it has less than 10 digits (same rule as lwb_party_missing).
-- Only lwb_customer_master.mobile (empty ones only), lwb_party_mobile_fills, lwb_tasks,
-- lwb_task_updates and erp_notifications are written. No order, stock, bill, ledger or Tally data.
-- Runs by itself when merged to main. Safe to run again (an open task is not given twice).

BEGIN;

ALTER TABLE public.lwb_tasks ADD COLUMN IF NOT EXISTS auto_key text;
CREATE INDEX IF NOT EXISTS lwb_tasks_auto_idx ON public.lwb_tasks(auto_key, status) WHERE auto_key IS NOT NULL;

-- Every number filled from the list (who, when, old value).
CREATE TABLE IF NOT EXISTS public.lwb_party_mobile_fills (
  id bigserial PRIMARY KEY,
  customer_id uuid NOT NULL REFERENCES public.lwb_customer_master(id) ON DELETE CASCADE,
  old_mobile text,
  mobile text NOT NULL,
  filled_by uuid DEFAULT auth.uid(),
  filled_by_name text,
  filled_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_party_mobile_fills_by_idx ON public.lwb_party_mobile_fills(filled_by, filled_at DESC);
ALTER TABLE public.lwb_party_mobile_fills ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_party_mobile_fills FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_party_mobile_fills_id_seq FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_mobile_ok(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT length(regexp_replace(coalesce(p,''), '\D', '', 'g')) >= 10; $fn$;

-- Parties without a mobile, with who must fill it (owner_id NULL = Sales Head / office).
CREATE OR REPLACE FUNCTION public.lwb_party_mobile_base()
RETURNS TABLE(customer_id uuid, customer_code text, customer_name text, city text, contact_person text,
  mobile text, owner_id uuid, owner_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT m.id, m.customer_code::text, m.customer_name::text, m.city::text, m.contact_person::text, m.mobile::text,
    CASE WHEN p.id IS NOT NULL THEN a.salesman_id END,
    CASE WHEN p.id IS NOT NULL THEN coalesce(nullif(btrim(p.full_name),''), 'Salesman') END
  FROM public.lwb_customer_master m
  LEFT JOIN public.lwb_party_salesman a ON a.customer_id = m.id
  LEFT JOIN public.user_profiles p ON p.id = a.salesman_id AND p.active = true
    AND lower(btrim(p.role)) IN ('sales','salesman')
  WHERE coalesce(m.is_active, true) AND (to_jsonb(m)->>'merged_into') IS NULL
    AND NOT public.lwb_mobile_ok(m.mobile);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_mobile_base() FROM PUBLIC, anon, authenticated;

-- How many are pending for one person: a salesman = his parties; Admin / Sales Head = all.
CREATE OR REPLACE FUNCTION public.lwb_party_mobile_pending_for(p_user uuid)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE WHEN lower(btrim(coalesce(u.role,''))) IN ('sales','salesman')
    THEN (SELECT count(*)::int FROM public.lwb_party_mobile_base() b WHERE b.owner_id = p_user)
    ELSE (SELECT count(*)::int FROM public.lwb_party_mobile_base()) END
  FROM public.user_profiles u WHERE u.id = p_user;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_mobile_pending_for(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- My pending list. Salesman: own parties. Admin / Sales Head: every party (owner shown).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_mobile_pending()
RETURNS TABLE(customer_id uuid, customer_code text, customer_name text, city text, contact_person text,
  mobile text, owner_id uuid, owner_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_role text := public.lwb_task_my_role();
BEGIN
  IF v_role IN ('admin','manager') THEN
    RETURN QUERY SELECT * FROM public.lwb_party_mobile_base() b ORDER BY b.owner_name NULLS FIRST, b.customer_name;
  ELSIF v_role IN ('sales','salesman') THEN
    RETURN QUERY SELECT * FROM public.lwb_party_mobile_base() b WHERE b.owner_id = auth.uid() ORDER BY b.customer_name;
  END IF;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_party_mobile_pending_count()
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE WHEN public.lwb_task_my_role() IN ('admin','manager','sales','salesman')
    THEN public.lwb_party_mobile_pending_for(auth.uid()) ELSE 0 END;
$fn$;

-- ---------------------------------------------------------------------------
-- Close the mobile tasks whose list is now empty (DONE, note, bell to the giver).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_mobile_tasks_close()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE t record; n integer := 0;
BEGIN
  FOR t IN SELECT * FROM public.lwb_tasks WHERE auto_key = 'PARTY_MOBILE' AND status IN ('OPEN','IN_PROGRESS') FOR UPDATE LOOP
    IF coalesce(public.lwb_party_mobile_pending_for(t.assigned_to), 0) = 0 THEN
      UPDATE public.lwb_tasks SET status = 'DONE', done_at = now(), closed_by = t.assigned_to, closed_by_name = t.assigned_to_name,
        last_activity_at = now(), update_count = update_count + 1 WHERE id = t.id;
      INSERT INTO public.lwb_task_updates(task_id, body, by_user, by_name, status_after)
      VALUES (t.id, 'Marked done · every party mobile number is filled', t.assigned_to, t.assigned_to_name, 'DONE');
      UPDATE public.erp_notifications SET is_read = true
      WHERE is_read = false AND notification_type LIKE 'TASK\_%' AND message LIKE 'TSK-' || t.id || ' %';
      INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
      SELECT t.assigned_by, left('Task done: ' || t.title, 150),
        left('TSK-' || t.id || ' · ' || t.title || ' · ' || coalesce(t.assigned_to_name,'Staff') || ' filled every party mobile number.', 600), 'TASK_DONE'
      WHERE t.assigned_by IS DISTINCT FROM t.assigned_to;
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_mobile_tasks_close() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Save one number from the list. Only an empty / short mobile can be filled here
-- (a saved number is changed only in Party Master). Salesman: only his own parties.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_mobile_set(p_customer_id uuid, p_mobile text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_task_my_role();
  v_d text := regexp_replace(coalesce(p_mobile,''), '\D', '', 'g');
  v_name text;
  m record;
BEGIN
  IF v_role NOT IN ('admin','manager','sales','salesman') THEN RAISE EXCEPTION 'Only Admin, Sales Head or Salesman can fill party mobile numbers'; END IF;
  IF v_d !~ '^(91|0)?[6-9][0-9]{9}$' THEN RAISE EXCEPTION 'Enter a valid 10 digit mobile number'; END IF;
  v_d := right(v_d, 10);
  SELECT c.id, c.customer_name, c.mobile INTO m FROM public.lwb_customer_master c WHERE c.id = p_customer_id FOR UPDATE;
  IF m.id IS NULL THEN RAISE EXCEPTION 'Party not found'; END IF;
  IF v_role IN ('sales','salesman') AND NOT EXISTS (SELECT 1 FROM public.lwb_party_salesman a
       WHERE a.customer_id = m.id AND a.salesman_id = auth.uid()) THEN
    RAISE EXCEPTION 'Party not found in your list';
  END IF;
  IF public.lwb_mobile_ok(m.mobile) THEN RAISE EXCEPTION 'Mobile of % is already saved. Change it in Party Master.', m.customer_name; END IF;
  SELECT coalesce(nullif(btrim(x.full_name),''), 'Staff') INTO v_name FROM public.user_profiles x WHERE x.id = auth.uid();
  UPDATE public.lwb_customer_master SET mobile = v_d WHERE id = m.id;
  INSERT INTO public.lwb_party_mobile_fills(customer_id, old_mobile, mobile, filled_by, filled_by_name)
  VALUES (m.id, nullif(btrim(coalesce(m.mobile,'')),''), v_d, auth.uid(), v_name);
  RETURN jsonb_build_object('customer_id', m.id, 'mobile', v_d,
    'pending', public.lwb_party_mobile_pending_for(auth.uid()));
END;
$fn$;

-- Any change of a party mobile (Party Master, PO Entry, this list) may finish a task.
CREATE OR REPLACE FUNCTION public.lwb_party_mobile_after_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF EXISTS (SELECT 1 FROM public.lwb_tasks WHERE auto_key = 'PARTY_MOBILE' AND status IN ('OPEN','IN_PROGRESS')) THEN
    BEGIN
      PERFORM public.lwb_party_mobile_tasks_close();
    EXCEPTION WHEN others THEN NULL;  -- never stop a party save because of a task
    END;
  END IF;
  RETURN NULL;
END;
$fn$;
DROP TRIGGER IF EXISTS trg_lwb_party_mobile_done ON public.lwb_customer_master;
CREATE TRIGGER trg_lwb_party_mobile_done AFTER UPDATE OF mobile, is_active ON public.lwb_customer_master
  FOR EACH STATEMENT EXECUTE FUNCTION public.lwb_party_mobile_after_change();
DROP TRIGGER IF EXISTS trg_lwb_party_mobile_done_ps ON public.lwb_party_salesman;
CREATE TRIGGER trg_lwb_party_mobile_done_ps AFTER INSERT OR UPDATE OR DELETE ON public.lwb_party_salesman
  FOR EACH STATEMENT EXECUTE FUNCTION public.lwb_party_mobile_after_change();

-- ---------------------------------------------------------------------------
-- Give the tasks: one per salesman with pending parties + one per active Sales Head.
-- A person who already has an open mobile task is skipped. p_by = giver (NULL = logged-in Admin /
-- Sales Head; when run from the merge there is no login, so the first active Admin is the giver).
-- Returns {given, skipped, pending}.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_mobile_tasks_give(p_due date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_by uuid := auth.uid();
  v_by_name text;
  v_by_role text;
  v_due date := coalesce(p_due, public.lwb_task_today() + 3);
  v_batch bigint := nextval('public.lwb_task_batch_seq');
  v_given integer := 0;
  v_skip integer := 0;
  v_n integer;
  v_id bigint;
  v_title text;
  u record;
BEGIN
  IF v_by IS NOT NULL THEN
    IF public.lwb_task_my_role() NOT IN ('admin','manager') THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  ELSE
    SELECT p.id INTO v_by FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'admin'
    ORDER BY (p.full_name ILIKE '%mohit%') DESC, p.full_name LIMIT 1;
    IF v_by IS NULL THEN RETURN jsonb_build_object('given', 0, 'skipped', 0, 'pending', 0); END IF;
  END IF;
  IF v_due < public.lwb_task_today() THEN RAISE EXCEPTION 'Due date cannot be before today'; END IF;
  SELECT coalesce(nullif(btrim(p.full_name),''), 'Admin'), lower(btrim(p.role)) INTO v_by_name, v_by_role
  FROM public.user_profiles p WHERE p.id = v_by;

  FOR u IN
    SELECT p.id, coalesce(nullif(btrim(p.full_name),''), 'Staff') AS name, lower(btrim(p.role)) AS role
    FROM public.user_profiles p
    WHERE p.active = true AND (lower(btrim(p.role)) = 'manager'
      OR (lower(btrim(p.role)) IN ('sales','salesman') AND EXISTS (SELECT 1 FROM public.lwb_party_mobile_base() b WHERE b.owner_id = p.id)))
    ORDER BY public.lwb_task_rank(p.role), 2
  LOOP
    v_n := coalesce(public.lwb_party_mobile_pending_for(u.id), 0);
    IF v_n = 0 OR EXISTS (SELECT 1 FROM public.lwb_tasks t WHERE t.auto_key = 'PARTY_MOBILE'
         AND t.assigned_to = u.id AND t.status IN ('OPEN','IN_PROGRESS')) THEN
      v_skip := v_skip + 1; CONTINUE;
    END IF;
    v_title := '📞 Fill mobile number of ' || v_n || ' parties';
    INSERT INTO public.lwb_tasks(batch_id, title, details, due_date, priority, assigned_to, assigned_to_name, assigned_to_role,
      assigned_by, assigned_by_name, assigned_by_role, auto_key)
    VALUES (v_batch, v_title,
      CASE WHEN u.role = 'manager'
        THEN v_n || ' parties have no mobile number (all salesmen + office parties). Open "📞 Party Mobile Pending" (Dashboard strip or menu Sales), type the number and press Save. The party leaves the list. This task closes by itself when the list is empty.'
        ELSE v_n || ' of your parties have no mobile number. Open "📞 Party Mobile Pending" (Dashboard strip or menu Sales), type the number and press Save. The party leaves the list. This task closes by itself when the list is empty.' END,
      v_due, 'NORMAL', u.id, u.name, u.role, v_by, v_by_name, v_by_role, 'PARTY_MOBILE')
    RETURNING id INTO v_id;
    INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
    SELECT u.id, left('New task: ' || v_title, 150),
      left('TSK-' || v_id || ' · ' || v_title || ' · Due ' || to_char(v_due,'DD Mon YYYY') || ' · by ' || v_by_name
        || ' (' || public.lwb_task_role_label(v_by_role) || '). Open Party Mobile Pending and fill the numbers.', 600), 'TASK_NEW'
    WHERE u.id IS DISTINCT FROM v_by;
    v_given := v_given + 1;
  END LOOP;
  RETURN jsonb_build_object('given', v_given, 'skipped', v_skip, 'pending', (SELECT count(*) FROM public.lwb_party_mobile_base()));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Progress for Admin / Sales Head: one row per salesman + Sales Head + office (no salesman).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_mobile_progress()
RETURNS TABLE(person_id uuid, person_name text, role_label text, pending integer, filled integer,
  filled_today integer, task_id bigint, task_status text, task_due date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_today date := public.lwb_task_today();
BEGIN
  IF public.lwb_task_my_role() NOT IN ('admin','manager') THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  RETURN QUERY
  WITH ppl AS (
    SELECT p.id, coalesce(nullif(btrim(p.full_name),''), 'Staff') AS name, lower(btrim(p.role)) AS role
    FROM public.user_profiles p
    WHERE p.active = true AND (lower(btrim(p.role)) = 'manager'
      OR EXISTS (SELECT 1 FROM public.lwb_party_mobile_base() b WHERE b.owner_id = p.id)
      OR EXISTS (SELECT 1 FROM public.lwb_tasks t WHERE t.auto_key = 'PARTY_MOBILE' AND t.assigned_to = p.id)
      OR EXISTS (SELECT 1 FROM public.lwb_party_mobile_fills f WHERE f.filled_by = p.id))
  ), tk AS (
    SELECT DISTINCT ON (t.assigned_to) t.assigned_to, t.id, t.status, t.due_date FROM public.lwb_tasks t
    WHERE t.auto_key = 'PARTY_MOBILE' ORDER BY t.assigned_to, (t.status IN ('OPEN','IN_PROGRESS')) DESC, t.id DESC
  )
  SELECT x.id, x.name, public.lwb_task_role_label(x.role),
    CASE WHEN x.role = 'manager' THEN (SELECT count(*)::int FROM public.lwb_party_mobile_base() b WHERE b.owner_id IS NULL)
      ELSE (SELECT count(*)::int FROM public.lwb_party_mobile_base() b WHERE b.owner_id = x.id) END,
    (SELECT count(*)::int FROM public.lwb_party_mobile_fills f WHERE f.filled_by = x.id),
    (SELECT count(*)::int FROM public.lwb_party_mobile_fills f WHERE f.filled_by = x.id
       AND (f.filled_at AT TIME ZONE 'Asia/Kolkata')::date = v_today),
    tk.id, tk.status, tk.due_date
  FROM ppl x LEFT JOIN tk ON tk.assigned_to = x.id
  ORDER BY public.lwb_task_rank(x.role), 4 DESC, 2;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_party_mobile_pending(), public.lwb_party_mobile_pending_count(),
  public.lwb_party_mobile_set(uuid,text), public.lwb_party_mobile_tasks_give(date), public.lwb_party_mobile_progress(),
  public.lwb_party_mobile_after_change() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_mobile_pending(), public.lwb_party_mobile_pending_count(),
  public.lwb_party_mobile_set(uuid,text), public.lwb_party_mobile_tasks_give(date), public.lwb_party_mobile_progress(),
  public.lwb_mobile_ok(text) TO authenticated;

-- Give the tasks now (Mohit asked). Run again = only people without an open mobile task.
SELECT public.lwb_party_mobile_tasks_give();

COMMIT;

NOTIFY pgrst, 'reload schema';
