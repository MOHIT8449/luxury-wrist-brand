-- LUXURY WRIST BRAND ERP — TASK MANAGEMENT (give a task to staff, with due date and 🔔)
--
-- Mohit asked (31 Oct 2026): any login can give a task to another login, e.g. Admin tells the
-- Sales Head "today the godown must be cleaned". The task reaches that person's Dashboard and bell.
-- Tasks go down the chain (channel wise):
--   1 Admin  >  2 Sales Head (MANAGER)  >  3 Godown Manager (WAREHOUSE)  >  4 Accounts
--   >  5 Salesman (SALES) / Driver / Transport
-- A login gives tasks to logins at his own level or below (Admin: anyone, any role).
-- A senior also sees the tasks of everyone below him (team view) and can write a note on them.
--
-- Status: OPEN (to do) -> IN_PROGRESS (started) -> DONE.  The giver can OPEN it again or CANCEL it,
-- and change the due date. Every change and note is kept in lwb_task_updates.
-- 🔔 TASK_NEW to the person who gets it; TASK_DONE / TASK_NOTE back to the giver;
--    TASK_REOPENED / TASK_CANCELLED / TASK_DUE_CHANGED to the person;
--    TASK_DUE (due today / overdue, once a day) to the person and TASK_OVERDUE (once) to the giver,
--    made when they open the Dashboard (lwb_task_due_bells).
--
-- Tasks only. Orders, stock, bills, payments and Tally are NOT changed. Safe to run again.

BEGIN;

-- Level in the chain: smaller = senior. Unknown roles get 99 (nobody below them).
CREATE OR REPLACE FUNCTION public.lwb_task_rank(p_role text)
RETURNS integer LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE lower(btrim(coalesce(p_role,'')))
    WHEN 'admin' THEN 1 WHEN 'manager' THEN 2 WHEN 'warehouse' THEN 3 WHEN 'accounts' THEN 4
    WHEN 'sales' THEN 5 WHEN 'driver' THEN 5 WHEN 'transport' THEN 5 ELSE 99 END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_task_role_label(p_role text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE lower(btrim(coalesce(p_role,'')))
    WHEN 'admin' THEN 'Admin' WHEN 'manager' THEN 'Sales Head' WHEN 'warehouse' THEN 'Godown Manager'
    WHEN 'accounts' THEN 'Accounts' WHEN 'sales' THEN 'Salesman' WHEN 'driver' THEN 'Driver'
    WHEN 'transport' THEN 'Transport' ELSE upper(coalesce(p_role,'')) END;
$fn$;

-- Logged-in active user's role ('' when not active).
CREATE OR REPLACE FUNCTION public.lwb_task_my_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce((SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true), '');
$fn$;

-- Today in India.
CREATE OR REPLACE FUNCTION public.lwb_task_today()
RETURNS date LANGUAGE sql STABLE SET search_path = ''
AS $fn$ SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date; $fn$;

REVOKE ALL ON FUNCTION public.lwb_task_my_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_task_my_role(), public.lwb_task_rank(text), public.lwb_task_role_label(text), public.lwb_task_today() TO authenticated;

CREATE SEQUENCE IF NOT EXISTS public.lwb_task_batch_seq;

CREATE TABLE IF NOT EXISTS public.lwb_tasks (
  id bigserial PRIMARY KEY,
  batch_id bigint,                       -- same number for one task given to many people at once
  title text NOT NULL CHECK (length(title) BETWEEN 1 AND 150),
  details text CHECK (details IS NULL OR length(details) <= 2000),
  due_date date NOT NULL,
  priority text NOT NULL DEFAULT 'NORMAL' CHECK (priority IN ('NORMAL','URGENT')),
  status text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','IN_PROGRESS','DONE','CANCELLED')),
  assigned_to uuid NOT NULL,
  assigned_to_name text,
  assigned_to_role text,
  assigned_by uuid NOT NULL DEFAULT auth.uid(),
  assigned_by_name text,
  assigned_by_role text,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_activity_at timestamptz NOT NULL DEFAULT now(),
  update_count integer NOT NULL DEFAULT 0,
  done_at timestamptz,
  closed_by uuid,
  closed_by_name text,
  reminded_on date,                      -- last TASK_DUE bell to the person
  overdue_told boolean NOT NULL DEFAULT false  -- TASK_OVERDUE bell to the giver
);
CREATE INDEX IF NOT EXISTS lwb_tasks_to_idx ON public.lwb_tasks(assigned_to, status, due_date);
CREATE INDEX IF NOT EXISTS lwb_tasks_by_idx ON public.lwb_tasks(assigned_by, last_activity_at DESC);
CREATE INDEX IF NOT EXISTS lwb_tasks_activity_idx ON public.lwb_tasks(last_activity_at DESC);

CREATE TABLE IF NOT EXISTS public.lwb_task_updates (
  id bigserial PRIMARY KEY,
  task_id bigint NOT NULL REFERENCES public.lwb_tasks(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
  by_user uuid NOT NULL DEFAULT auth.uid(),
  by_name text,
  status_after text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_task_updates_t_idx ON public.lwb_task_updates(task_id, created_at);

-- Who can see a task: the person, the giver, Admin, and anyone senior to the person.
CREATE OR REPLACE FUNCTION public.lwb_task_visible(p_to uuid, p_by uuid, p_to_role text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  WITH me AS (SELECT public.lwb_task_my_role() AS r)
  SELECT me.r <> '' AND (p_to = auth.uid() OR p_by = auth.uid() OR me.r = 'admin'
    OR public.lwb_task_rank(me.r) < public.lwb_task_rank(p_to_role))
  FROM me;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_task_visible(uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_task_visible(uuid,uuid,text) TO authenticated;

ALTER TABLE public.lwb_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_task_updates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_tasks_read ON public.lwb_tasks;
CREATE POLICY lwb_tasks_read ON public.lwb_tasks FOR SELECT TO authenticated
  USING (public.lwb_task_visible(assigned_to, assigned_by, assigned_to_role));
DROP POLICY IF EXISTS lwb_task_updates_read ON public.lwb_task_updates;
CREATE POLICY lwb_task_updates_read ON public.lwb_task_updates FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.lwb_tasks t WHERE t.id = task_id
    AND public.lwb_task_visible(t.assigned_to, t.assigned_by, t.assigned_to_role)));
REVOKE ALL ON TABLE public.lwb_tasks, public.lwb_task_updates FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_tasks, public.lwb_task_updates TO authenticated;
REVOKE ALL ON SEQUENCE public.lwb_tasks_id_seq, public.lwb_task_updates_id_seq, public.lwb_task_batch_seq FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- People this login can give a task to: active logins at his level or below (Admin: all). Self included.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_task_people()
RETURNS TABLE(id uuid, name text, role text, role_label text, rank integer, is_me boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  WITH me AS (SELECT public.lwb_task_my_role() AS r)
  SELECT p.id, coalesce(nullif(btrim(p.full_name),''), 'Staff'), lower(btrim(p.role)),
    public.lwb_task_role_label(p.role), public.lwb_task_rank(p.role), p.id = auth.uid()
  FROM public.user_profiles p, me
  WHERE me.r <> '' AND p.active = true
    AND (me.r = 'admin' OR p.id = auth.uid()
      OR (public.lwb_task_rank(p.role) < 99 AND public.lwb_task_rank(p.role) >= public.lwb_task_rank(me.r)))
  ORDER BY public.lwb_task_rank(p.role), 2;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_task_people() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_task_people() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_task_notify(p_user uuid, p_title text, p_msg text, p_type text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $fn$
  INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
  SELECT p_user, left(p_title, 150), left(p_msg, 600), p_type
  WHERE p_user IS NOT NULL AND p_user IS DISTINCT FROM auth.uid();
$fn$;
REVOKE ALL ON FUNCTION public.lwb_task_notify(uuid,text,text,text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Give a task. p: {title, details, due_date 'YYYY-MM-DD', priority NORMAL|URGENT, assignees [uuid, ...]}
-- One row per person (same batch_id). Returns the new task ids.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_task_add(p jsonb)
RETURNS bigint[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_task_my_role();
  v_title text := nullif(btrim(coalesce(p->>'title','')),'');
  v_details text := nullif(btrim(coalesce(p->>'details','')),'');
  v_pri text := upper(coalesce(nullif(btrim(p->>'priority'),''),'NORMAL'));
  v_due date;
  v_name text;
  v_batch bigint;
  v_ids bigint[] := '{}';
  v_to uuid;
  u record;
  v_id bigint;
BEGIN
  IF v_role = '' THEN RAISE EXCEPTION 'Login is not active'; END IF;
  IF v_title IS NULL THEN RAISE EXCEPTION 'Please enter the task'; END IF;
  IF v_pri NOT IN ('NORMAL','URGENT') THEN RAISE EXCEPTION 'Invalid priority'; END IF;
  BEGIN
    v_due := coalesce(nullif(p->>'due_date','')::date, public.lwb_task_today());
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Please select a valid due date';
  END;
  IF v_due < public.lwb_task_today() THEN RAISE EXCEPTION 'Due date cannot be before today'; END IF;
  IF jsonb_typeof(p->'assignees') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'assignees') = 0 THEN
    RAISE EXCEPTION 'Please select who gets the task';
  END IF;
  IF jsonb_array_length(p->'assignees') > 200 THEN RAISE EXCEPTION 'Maximum 200 people in one task'; END IF;

  SELECT coalesce(nullif(btrim(x.full_name),''), 'Staff') INTO v_name FROM public.user_profiles x WHERE x.id = auth.uid();
  v_batch := nextval('public.lwb_task_batch_seq');

  FOR v_to IN SELECT DISTINCT (e)::uuid FROM jsonb_array_elements_text(p->'assignees') e LOOP
    SELECT x.id, coalesce(nullif(btrim(x.full_name),''), 'Staff') AS name, lower(btrim(x.role)) AS role
      INTO u FROM public.user_profiles x WHERE x.id = v_to AND x.active = true;
    IF u.id IS NULL THEN RAISE EXCEPTION 'Selected login is not active'; END IF;
    IF v_role <> 'admin' AND u.id <> auth.uid()
       AND (public.lwb_task_rank(u.role) = 99 OR public.lwb_task_rank(u.role) < public.lwb_task_rank(v_role)) THEN
      RAISE EXCEPTION 'You can give a task only to staff at your level or below: % (%)', u.name, public.lwb_task_role_label(u.role);
    END IF;
    INSERT INTO public.lwb_tasks(batch_id, title, details, due_date, priority, assigned_to, assigned_to_name, assigned_to_role,
      assigned_by, assigned_by_name, assigned_by_role)
    VALUES (v_batch, left(v_title,150), left(v_details,2000), v_due, v_pri, u.id, u.name, u.role,
      auth.uid(), v_name, v_role)
    RETURNING id INTO v_id;
    v_ids := v_ids || v_id;
    PERFORM public.lwb_task_notify(u.id,
      CASE WHEN v_pri = 'URGENT' THEN 'URGENT · ' ELSE '' END || 'New task: ' || left(v_title,100),
      'TSK-' || v_id || ' · ' || v_title || ' · Due ' || to_char(v_due,'DD Mon YYYY')
        || ' · by ' || v_name || ' (' || public.lwb_task_role_label(v_role) || ').',
      'TASK_NEW');
  END LOOP;
  RETURN v_ids;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Change a task and / or write a note.
--   p_status: NULL (note only) | IN_PROGRESS | DONE   (person or giver)
--             OPEN (again, after DONE / CANCELLED) | CANCELLED   (giver or Admin)
--   p_due:    new due date (giver or Admin).
--   A senior who only sees the task (team view) can write a note.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_task_update(p_id bigint, p_status text DEFAULT NULL, p_note text DEFAULT NULL, p_due date DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_task_my_role();
  v_note text := left(nullif(btrim(coalesce(p_note,'')),''), 2000);
  v_status text := upper(nullif(btrim(coalesce(p_status,'')),''));
  v_name text;
  v_mine boolean;
  v_giver boolean;
  v_body text;
  v_tag text;
  v_due_changed boolean;
  t public.lwb_tasks%ROWTYPE;
BEGIN
  IF v_role = '' THEN RAISE EXCEPTION 'Login is not active'; END IF;
  SELECT * INTO t FROM public.lwb_tasks WHERE id = p_id FOR UPDATE;
  IF t.id IS NULL OR NOT public.lwb_task_visible(t.assigned_to, t.assigned_by, t.assigned_to_role) THEN
    RAISE EXCEPTION 'Task not found';
  END IF;
  v_mine := t.assigned_to = auth.uid();
  v_giver := t.assigned_by = auth.uid() OR v_role = 'admin';
  v_due_changed := p_due IS NOT NULL AND p_due IS DISTINCT FROM t.due_date;

  IF v_status IS NOT NULL THEN
    IF v_status NOT IN ('OPEN','IN_PROGRESS','DONE','CANCELLED') THEN RAISE EXCEPTION 'Invalid status'; END IF;
    IF v_status = t.status THEN RAISE EXCEPTION 'Task is already %', lower(replace(v_status,'_',' ')); END IF;
    IF v_status IN ('IN_PROGRESS','DONE') THEN
      IF NOT (v_mine OR v_giver) THEN RAISE EXCEPTION 'Only the person or the giver can change this task'; END IF;
      IF t.status NOT IN ('OPEN','IN_PROGRESS') THEN RAISE EXCEPTION 'Open the task again first'; END IF;
    ELSIF v_status = 'OPEN' THEN
      IF NOT v_giver THEN RAISE EXCEPTION 'Only the giver can open the task again'; END IF;
      IF t.status NOT IN ('DONE','CANCELLED') THEN RAISE EXCEPTION 'Task is already open'; END IF;
    ELSIF v_status = 'CANCELLED' THEN
      IF NOT v_giver THEN RAISE EXCEPTION 'Only the giver can cancel the task'; END IF;
      IF t.status NOT IN ('OPEN','IN_PROGRESS') THEN RAISE EXCEPTION 'Task is already closed'; END IF;
    END IF;
  END IF;
  IF v_due_changed THEN
    IF NOT v_giver THEN RAISE EXCEPTION 'Only the giver can change the due date'; END IF;
    IF p_due < public.lwb_task_today() THEN RAISE EXCEPTION 'Due date cannot be before today'; END IF;
  END IF;
  IF v_status IS NULL AND NOT v_due_changed AND v_note IS NULL THEN RAISE EXCEPTION 'Please write a note'; END IF;

  SELECT coalesce(nullif(btrim(x.full_name),''), 'Staff') INTO v_name FROM public.user_profiles x WHERE x.id = auth.uid();
  v_body := concat_ws(' · ',
    CASE v_status WHEN 'IN_PROGRESS' THEN 'Started' WHEN 'DONE' THEN 'Marked done' WHEN 'OPEN' THEN 'Opened again'
      WHEN 'CANCELLED' THEN 'Cancelled' END,
    CASE WHEN v_due_changed THEN 'Due date changed to ' || to_char(p_due,'DD Mon YYYY') END,
    v_note);
  INSERT INTO public.lwb_task_updates(task_id, body, by_user, by_name, status_after)
  VALUES (t.id, v_body, auth.uid(), v_name, v_status);

  UPDATE public.lwb_tasks SET
    status = coalesce(v_status, status),
    due_date = CASE WHEN v_due_changed THEN p_due ELSE due_date END,
    reminded_on = CASE WHEN v_due_changed OR v_status = 'OPEN' THEN NULL ELSE reminded_on END,
    overdue_told = CASE WHEN v_due_changed OR v_status = 'OPEN' THEN false ELSE overdue_told END,
    last_activity_at = now(), update_count = update_count + 1,
    done_at = CASE WHEN v_status = 'DONE' THEN now() WHEN v_status IN ('OPEN','IN_PROGRESS') THEN NULL ELSE done_at END,
    closed_by = CASE WHEN v_status IN ('DONE','CANCELLED') THEN auth.uid() WHEN v_status IS NOT NULL THEN NULL ELSE closed_by END,
    closed_by_name = CASE WHEN v_status IN ('DONE','CANCELLED') THEN v_name WHEN v_status IS NOT NULL THEN NULL ELSE closed_by_name END
  WHERE id = t.id;

  -- Closed: the bells about this task are done.
  IF v_status IN ('DONE','CANCELLED') THEN
    UPDATE public.erp_notifications SET is_read = true
    WHERE is_read = false AND notification_type LIKE 'TASK\_%' AND message LIKE 'TSK-' || t.id || ' %';
  END IF;

  v_tag := 'TSK-' || t.id || ' · ' || t.title;
  -- To the giver: the person (or a senior) worked on it.
  IF NOT (t.assigned_by = auth.uid()) AND (v_status = 'DONE' OR v_note IS NOT NULL) THEN
    PERFORM public.lwb_task_notify(t.assigned_by,
      CASE WHEN v_status = 'DONE' THEN 'Task done: ' ELSE 'Note on task: ' END || left(t.title,100),
      v_tag || ' · ' || v_name || coalesce(': ' || v_note, ' marked it done') || '.',
      CASE WHEN v_status = 'DONE' THEN 'TASK_DONE' ELSE 'TASK_NOTE' END);
  END IF;
  -- To the person: the giver (or a senior) changed it.
  IF NOT v_mine AND (v_status IN ('OPEN','CANCELLED','DONE') OR v_due_changed OR v_note IS NOT NULL) THEN
    PERFORM public.lwb_task_notify(t.assigned_to,
      CASE WHEN v_status = 'OPEN' THEN 'Task opened again: ' WHEN v_status = 'CANCELLED' THEN 'Task cancelled: '
        WHEN v_status = 'DONE' THEN 'Task closed as done: ' WHEN v_due_changed THEN 'Due date changed: ' ELSE 'Note on your task: ' END
        || left(t.title,100),
      v_tag || CASE WHEN v_due_changed THEN ' · Due ' || to_char(p_due,'DD Mon YYYY') ELSE '' END
        || ' · ' || v_name || coalesce(': ' || v_note, '') || '.',
      CASE WHEN v_status = 'OPEN' THEN 'TASK_REOPENED' WHEN v_status = 'CANCELLED' THEN 'TASK_CANCELLED'
        WHEN v_status = 'DONE' THEN 'TASK_DONE' WHEN v_due_changed THEN 'TASK_DUE_CHANGED' ELSE 'TASK_NOTE' END);
  END IF;
  RETURN (SELECT status FROM public.lwb_tasks WHERE id = t.id);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Daily reminders, made when a login opens the Dashboard:
--   my open tasks due today / overdue -> TASK_DUE to me (once a day per task);
--   tasks I gave that are past their due date and not done -> TASK_OVERDUE to me (once per task).
-- Returns the number of bells made.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_task_due_bells()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_today date := public.lwb_task_today();
  n integer := 0;
  c integer;
BEGIN
  IF public.lwb_task_my_role() = '' THEN RETURN 0; END IF;
  WITH due AS (
    UPDATE public.lwb_tasks SET reminded_on = v_today
    WHERE assigned_to = auth.uid() AND status IN ('OPEN','IN_PROGRESS') AND due_date <= v_today
      AND reminded_on IS DISTINCT FROM v_today AND assigned_by IS DISTINCT FROM auth.uid()
    RETURNING id, title, due_date, assigned_by_name
  ), ins AS (
    INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
    SELECT auth.uid(),
      left(CASE WHEN due_date = v_today THEN 'Task due today: ' ELSE 'Task overdue ' || (v_today - due_date) || ' day(s): ' END || title, 150),
      left('TSK-' || id || ' · ' || title || ' · Due ' || to_char(due_date,'DD Mon YYYY') || coalesce(' · by ' || assigned_by_name, '') || '.', 600),
      'TASK_DUE'
    FROM due RETURNING 1
  ) SELECT count(*) INTO c FROM ins;
  n := n + c;
  WITH late AS (
    UPDATE public.lwb_tasks SET overdue_told = true
    WHERE assigned_by = auth.uid() AND assigned_to IS DISTINCT FROM auth.uid()
      AND status IN ('OPEN','IN_PROGRESS') AND due_date < v_today AND NOT overdue_told
    RETURNING id, title, due_date, assigned_to_name
  ), ins AS (
    INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
    SELECT auth.uid(), left('Task not done in time: ' || title, 150),
      left('TSK-' || id || ' · ' || title || ' · ' || coalesce(assigned_to_name,'Staff') || ' · was due ' || to_char(due_date,'DD Mon YYYY') || '.', 600),
      'TASK_OVERDUE'
    FROM late RETURNING 1
  ) SELECT count(*) INTO c FROM ins;
  RETURN n + c;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_task_add(jsonb), public.lwb_task_update(bigint,text,text,date), public.lwb_task_due_bells() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_task_add(jsonb), public.lwb_task_update(bigint,text,text,date), public.lwb_task_due_bells() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: 4 rows, all true.
SELECT 'tasks table' AS item, to_regclass('public.lwb_tasks') IS NOT NULL AS ok
UNION ALL SELECT 'task updates table', to_regclass('public.lwb_task_updates') IS NOT NULL
UNION ALL SELECT 'give task function', to_regprocedure('public.lwb_task_add(jsonb)') IS NOT NULL
UNION ALL SELECT 'update task function', to_regprocedure('public.lwb_task_update(bigint,text,text,date)') IS NOT NULL;
