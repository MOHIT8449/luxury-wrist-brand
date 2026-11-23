-- LUXURY WRIST BRAND ERP — 🚨 SIREN FOR URGENT TASKS (Mohit, 22 Nov 2026)
--
-- Mohit asked: when a task is Urgent, the person's phone must ring a siren every 20 minutes
-- until the task is done, and reminders go out only between 9 AM and 8 PM (India time).
--
--   * A new task with priority URGENT (given by a person, not an auto task) gets siren = true.
--     The first siren rings at once (or at 9 AM on the due date / next morning when outside hours).
--   * Every minute pg_cron runs lwb_task_siren_tick(): for every pending siren task whose time
--     has come it makes one TASK_SIREN bell (-> phone push, lwb_web_push_setup.sql) and sets the
--     next ring 20 minutes later. Outside 9:00-20:00 IST nothing rings; the next ring is 9:00 AM.
--   * The siren stops by itself when the task is Done or Cancelled (status not pending).
--   * The giver / Admin can turn the siren off or on for one task (lwb_task_siren_set).
--   * The person taps "Remind in 20 min" on the full-screen alarm: lwb_task_siren_seen() records that
--     he saw it (Admin sees "rang 5 times, seen 10:20").
--   * lwb_task_siren_test(): Admin sends a demo siren to his own phone.
--
-- Tasks only. Orders, stock, bills, payments and Tally are NOT changed. Safe to run again.

BEGIN;

ALTER TABLE public.lwb_tasks
  ADD COLUMN IF NOT EXISTS siren boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS siren_next_at timestamptz,
  ADD COLUMN IF NOT EXISTS siren_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS siren_seen_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS siren_last_at timestamptz,
  ADD COLUMN IF NOT EXISTS siren_seen_at timestamptz;
CREATE INDEX IF NOT EXISTS lwb_tasks_siren_idx ON public.lwb_tasks(siren_next_at) WHERE siren;

-- One settings row: ring every N minutes, only from start hour to end hour (IST).
CREATE TABLE IF NOT EXISTS public.lwb_task_siren_config (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  every_min integer NOT NULL DEFAULT 20 CHECK (every_min BETWEEN 5 AND 240),
  start_hour integer NOT NULL DEFAULT 9 CHECK (start_hour BETWEEN 0 AND 23),
  end_hour integer NOT NULL DEFAULT 20 CHECK (end_hour BETWEEN 1 AND 24),
  CHECK (start_hour < end_hour)
);
INSERT INTO public.lwb_task_siren_config(id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.lwb_task_siren_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_task_siren_config FROM PUBLIC, anon, authenticated;

-- When may the siren ring at or after p_at? Same moment inside hours, else the next start hour (IST).
CREATE OR REPLACE FUNCTION public.lwb_task_siren_slot(p_at timestamptz)
RETURNS timestamptz LANGUAGE plpgsql STABLE SET search_path = ''
AS $fn$
DECLARE
  c public.lwb_task_siren_config%ROWTYPE;
  v_local timestamp := p_at AT TIME ZONE 'Asia/Kolkata';
  v_h integer := extract(hour FROM v_local);
BEGIN
  SELECT * INTO c FROM public.lwb_task_siren_config WHERE id = 1;
  IF c.id IS NULL THEN c.start_hour := 9; c.end_hour := 20; END IF;
  IF v_h >= c.start_hour AND v_h < c.end_hour THEN RETURN p_at; END IF;
  IF v_h < c.start_hour THEN
    RETURN (v_local::date + make_interval(hours => c.start_hour)) AT TIME ZONE 'Asia/Kolkata';
  END IF;
  RETURN (v_local::date + 1 + make_interval(hours => c.start_hour)) AT TIME ZONE 'Asia/Kolkata';
END;
$fn$;

-- First ring: now, but not before 9 AM of the due date, and only inside hours.
CREATE OR REPLACE FUNCTION public.lwb_task_siren_first(p_due date, p_now timestamptz DEFAULT now())
RETURNS timestamptz LANGUAGE sql STABLE SET search_path = ''
AS $fn$
  SELECT public.lwb_task_siren_slot(greatest(p_now, (p_due::timestamp) AT TIME ZONE 'Asia/Kolkata'));
$fn$;

-- New URGENT task from a person -> siren on.
CREATE OR REPLACE FUNCTION public.lwb_task_siren_on_insert()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $fn$
BEGIN
  IF NEW.priority = 'URGENT' AND NEW.status IN ('OPEN','IN_PROGRESS')
     AND coalesce(to_jsonb(NEW)->>'ref_type','') = '' AND coalesce(to_jsonb(NEW)->>'auto_key','') = '' THEN
    NEW.siren := true;
  END IF;
  IF NEW.siren AND NEW.siren_next_at IS NULL THEN
    NEW.siren_next_at := public.lwb_task_siren_first(NEW.due_date);
  END IF;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS trg_lwb_task_siren_ins ON public.lwb_tasks;
CREATE TRIGGER trg_lwb_task_siren_ins BEFORE INSERT ON public.lwb_tasks
  FOR EACH ROW EXECUTE FUNCTION public.lwb_task_siren_on_insert();

-- Opened again / due date changed: siren starts again from the (new) due date.
CREATE OR REPLACE FUNCTION public.lwb_task_siren_on_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $fn$
BEGIN
  IF NEW.siren AND NEW.status IN ('OPEN','IN_PROGRESS')
     AND (OLD.status NOT IN ('OPEN','IN_PROGRESS') OR NEW.due_date IS DISTINCT FROM OLD.due_date) THEN
    NEW.siren_next_at := public.lwb_task_siren_first(NEW.due_date);
  END IF;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS trg_lwb_task_siren_upd ON public.lwb_tasks;
CREATE TRIGGER trg_lwb_task_siren_upd BEFORE UPDATE OF status, due_date ON public.lwb_tasks
  FOR EACH ROW EXECUTE FUNCTION public.lwb_task_siren_on_update();

-- ---------------------------------------------------------------------------
-- Every minute (pg_cron). Returns the number of sirens sent.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_task_siren_tick(p_now timestamptz DEFAULT now())
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  c public.lwb_task_siren_config%ROWTYPE;
  t record;
  v_slot timestamptz;
  n integer := 0;
BEGIN
  SELECT * INTO c FROM public.lwb_task_siren_config WHERE id = 1;
  IF c.id IS NULL THEN c.every_min := 20; END IF;
  FOR t IN
    SELECT k.* FROM public.lwb_tasks k
    WHERE k.siren AND k.status IN ('OPEN','IN_PROGRESS') AND k.siren_next_at <= p_now
    ORDER BY k.siren_next_at LIMIT 500 FOR UPDATE SKIP LOCKED
  LOOP
    v_slot := public.lwb_task_siren_slot(p_now);
    IF v_slot > p_now THEN
      -- Outside 9 AM - 8 PM: wait for the morning.
      UPDATE public.lwb_tasks SET siren_next_at = v_slot WHERE id = t.id;
      CONTINUE;
    END IF;
    -- Only the newest siren stays unread in the bell.
    UPDATE public.erp_notifications SET is_read = true
    WHERE is_read = false AND user_id = t.assigned_to AND notification_type = 'TASK_SIREN'
      AND message LIKE 'TSK-' || t.id || ' %';
    INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
    VALUES (t.assigned_to,
      left('🚨 URGENT task · ring ' || (t.siren_count + 1) || ': ' || t.title, 150),
      left('TSK-' || t.id || ' · ' || t.title || ' · by ' || coalesce(t.assigned_by_name,'Admin')
        || ' · Open the app and mark it done. The siren rings every ' || c.every_min || ' min until it is done.', 600),
      'TASK_SIREN');
    UPDATE public.lwb_tasks SET siren_count = siren_count + 1, siren_last_at = p_now,
      siren_next_at = p_now + make_interval(mins => c.every_min)
    WHERE id = t.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_task_siren_tick(timestamptz) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The app: my sirens that rang and that I have not seen yet (full-screen alarm on any page).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_task_my_sirens()
RETURNS TABLE(id bigint, title text, details text, due_date date, assigned_by_name text, assigned_by_role text,
  status text, siren_count integer, siren_last_at timestamptz, siren_next_at timestamptz, every_min integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT t.id, t.title, t.details, t.due_date, t.assigned_by_name, public.lwb_task_role_label(t.assigned_by_role),
    t.status, t.siren_count, t.siren_last_at, t.siren_next_at,
    coalesce((SELECT c.every_min FROM public.lwb_task_siren_config c WHERE c.id = 1), 20)
  FROM public.lwb_tasks t
  WHERE public.lwb_task_my_role() <> '' AND t.assigned_to = auth.uid() AND t.siren
    AND t.status IN ('OPEN','IN_PROGRESS') AND t.siren_count > t.siren_seen_count
    AND t.siren_last_at > now() - interval '12 hours'
  ORDER BY t.siren_last_at DESC;
$fn$;

-- "Remind in 20 min": I saw the alarm. The next ring stays on its 20-minute time.
CREATE OR REPLACE FUNCTION public.lwb_task_siren_seen(p_id bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.lwb_tasks SET siren_seen_count = siren_count, siren_seen_at = now()
  WHERE id = p_id AND assigned_to = auth.uid() AND public.lwb_task_my_role() <> '';
  RETURN FOUND;
END;
$fn$;

-- Giver / Admin: siren off or on for one pending task.
CREATE OR REPLACE FUNCTION public.lwb_task_siren_set(p_id bigint, p_on boolean)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_task_my_role();
  t public.lwb_tasks%ROWTYPE;
  v_name text;
BEGIN
  IF v_role = '' THEN RAISE EXCEPTION 'Login is not active'; END IF;
  SELECT * INTO t FROM public.lwb_tasks WHERE id = p_id FOR UPDATE;
  IF t.id IS NULL OR NOT (t.assigned_by = auth.uid() OR v_role = 'admin') THEN
    RAISE EXCEPTION 'Only the giver or Admin can change the siren';
  END IF;
  IF t.status NOT IN ('OPEN','IN_PROGRESS') THEN RAISE EXCEPTION 'Task is closed'; END IF;
  IF t.siren = coalesce(p_on,false) THEN RETURN t.siren; END IF;
  SELECT coalesce(nullif(btrim(x.full_name),''), 'Staff') INTO v_name FROM public.user_profiles x WHERE x.id = auth.uid();
  UPDATE public.lwb_tasks SET siren = coalesce(p_on,false),
    siren_next_at = CASE WHEN p_on THEN public.lwb_task_siren_first(due_date) ELSE NULL END,
    last_activity_at = now(), update_count = update_count + 1
  WHERE id = t.id;
  INSERT INTO public.lwb_task_updates(task_id, body, by_user, by_name)
  VALUES (t.id, CASE WHEN p_on THEN '🚨 Siren turned on (every 20 min, 9 AM - 8 PM)' ELSE '🔕 Siren turned off' END, auth.uid(), v_name);
  IF NOT p_on THEN
    UPDATE public.erp_notifications SET is_read = true
    WHERE is_read = false AND notification_type = 'TASK_SIREN' AND message LIKE 'TSK-' || t.id || ' %';
  END IF;
  RETURN coalesce(p_on,false);
END;
$fn$;

-- Admin demo: one siren bell (-> phone push) to my own phone, no task needed.
CREATE OR REPLACE FUNCTION public.lwb_task_siren_test()
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.lwb_task_my_role() <> 'admin' THEN RAISE EXCEPTION 'Only Admin can send a demo siren'; END IF;
  INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
  VALUES (auth.uid(), '🚨 URGENT task · DEMO siren', 'TSK-DEMO · This is how an urgent task rings on the phone. Open the app to hear the siren.', 'TASK_SIREN');
  RETURN true;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_task_my_sirens(), public.lwb_task_siren_seen(bigint),
  public.lwb_task_siren_set(bigint,boolean), public.lwb_task_siren_test() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_task_my_sirens(), public.lwb_task_siren_seen(bigint),
  public.lwb_task_siren_set(bigint,boolean), public.lwb_task_siren_test() TO authenticated;
REVOKE ALL ON FUNCTION public.lwb_task_siren_slot(timestamptz), public.lwb_task_siren_first(date,timestamptz) FROM PUBLIC, anon;

-- Every minute, only where pg_cron is on.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'lwb-task-siren') THEN
      PERFORM cron.schedule('lwb-task-siren', '* * * * *', 'select public.lwb_task_siren_tick();');
    END IF;
  END IF;
END
$cron$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: all true.
SELECT 'siren columns' AS item, EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='lwb_tasks' AND column_name='siren_next_at') AS ok
UNION ALL SELECT 'siren tick function', to_regprocedure('public.lwb_task_siren_tick(timestamptz)') IS NOT NULL
UNION ALL SELECT 'my sirens function', to_regprocedure('public.lwb_task_my_sirens()') IS NOT NULL;
