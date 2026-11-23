-- LUXURY WRIST BRAND ERP — 🚨 URGENT TASK ALARM IN THE ANDROID APP (Mohit, 22 Nov 2026)
--
-- The Android app now checks every minute (lwb_task_my_sirens) and, for a new ring, plays an
-- alarm-clock style siren on the phone's ALARM sound (works on Silent), vibrates, and opens a
-- full-screen alarm over the lock screen until the person taps Done or Later.
--
-- This file adds the demo: Admin's "Send a demo siren to my phone" (lwb_task_siren_test) now also
-- leaves one DEMO row for 10 minutes, so the app on that phone rings the real alarm. The DEMO row
-- has id 0; "Later" / "Done" on it (lwb_task_siren_seen(0)) clears it. Real tasks are unchanged.
-- Needs lwb_task_siren_setup.sql. Safe to run again.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_task_siren_demo (
  user_id uuid PRIMARY KEY,
  rang_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_task_siren_demo ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_task_siren_demo FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_task_my_sirens()
RETURNS TABLE(id bigint, title text, details text, due_date date, assigned_by_name text, assigned_by_role text,
  status text, siren_count integer, siren_last_at timestamptz, siren_next_at timestamptz, every_min integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT * FROM (
    SELECT t.id, t.title, t.details, t.due_date, t.assigned_by_name, public.lwb_task_role_label(t.assigned_by_role),
      t.status, t.siren_count, t.siren_last_at, t.siren_next_at,
      coalesce((SELECT c.every_min FROM public.lwb_task_siren_config c WHERE c.id = 1), 20)
    FROM public.lwb_tasks t
    WHERE public.lwb_task_my_role() <> '' AND t.assigned_to = auth.uid() AND t.siren
      AND t.status IN ('OPEN','IN_PROGRESS') AND t.siren_count > t.siren_seen_count
      AND t.siren_last_at > now() - interval '12 hours'
    UNION ALL
    SELECT 0::bigint, 'DEMO: urgent task siren', 'This is how an urgent task rings on the phone. Tap Later or Done to stop it.',
      public.lwb_task_today(), 'Admin', 'Admin', 'OPEN',
      -- the ring number changes for every demo, so a second demo rings again
      (extract(epoch FROM d.rang_at)::bigint % 1000000)::integer, d.rang_at, NULL::timestamptz,
      coalesce((SELECT c.every_min FROM public.lwb_task_siren_config c WHERE c.id = 1), 20)
    FROM public.lwb_task_siren_demo d
    WHERE d.user_id = auth.uid() AND d.rang_at > now() - interval '10 minutes' AND public.lwb_task_my_role() <> ''
  ) x
  ORDER BY x.siren_last_at DESC;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_task_siren_seen(p_id bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.lwb_task_my_role() = '' THEN RETURN false; END IF;
  IF p_id = 0 THEN
    DELETE FROM public.lwb_task_siren_demo WHERE user_id = auth.uid();
    RETURN FOUND;
  END IF;
  UPDATE public.lwb_tasks SET siren_seen_count = siren_count, siren_seen_at = now()
  WHERE id = p_id AND assigned_to = auth.uid();
  RETURN FOUND;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_task_siren_test()
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.lwb_task_my_role() <> 'admin' THEN RAISE EXCEPTION 'Only Admin can send a demo siren'; END IF;
  INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
  VALUES (auth.uid(), '🚨 URGENT task · DEMO siren', 'TSK-DEMO · This is how an urgent task rings on the phone. Open the app to hear the siren.', 'TASK_SIREN');
  INSERT INTO public.lwb_task_siren_demo(user_id, rang_at) VALUES (auth.uid(), now())
  ON CONFLICT (user_id) DO UPDATE SET rang_at = now();
  RETURN true;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_task_my_sirens(), public.lwb_task_siren_seen(bigint), public.lwb_task_siren_test() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_task_my_sirens(), public.lwb_task_siren_seen(bigint), public.lwb_task_siren_test() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'siren demo table' AS item, to_regclass('public.lwb_task_siren_demo') IS NOT NULL AS ok;
