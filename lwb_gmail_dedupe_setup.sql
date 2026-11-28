-- LUXURY WRIST BRAND ERP — GMAIL: MORE ACCOUNTS + DUPLICATE NUMBER CLEANER (28 Nov 2026)
--
-- Mohit asked (28 Nov 2026): his phone shows the contacts of 2-3 Gmail accounts, so one number shows 3-4 times with
-- different names. He wants ONE name per number. Plan (his choice: "Haan, banao (preview ke saath)"):
--   1. Admin connects the other Gmail accounts too (Dial Book › ✉ Gmail sync › ➕ Doosra Gmail). Only to clean; the
--      ERP contacts (label LWB ERP) are still synced to the main Gmail only.
--   2. 🧹 Duplicate saaf karein: the Edge Function reads every contact of every connected Gmail and shows each number
--      saved 2+ times. Number in the ERP Dial Book: the ERP name stays (LWB ERP contact). Other numbers: Admin picks
--      the name. Nothing changes until Admin presses "Haan, saaf karo"; a backup file (CSV) is downloaded first.
--   3. Apply: the other copies are deleted. A contact that also has another number keeps that number (only the
--      duplicate number is taken off it). LWB ERP contacts are never deleted here.
--
--   lwb_gsync_accounts   extra Gmail logins (refresh token: service_role only, never to the browser)
--   lwb_gsync_config     + oauth_extra (the Google login in progress is for an extra account)
--   lwb_gdedupe_runs     each scan (the plan) and its result. service_role only.
--   lwb_gsync_status()   + extra (emails of the extra accounts), last_dedupe
--
-- Safe to run again. Nothing is dropped or deleted.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_gsync_accounts (
  email text PRIMARY KEY,
  refresh_token text NOT NULL,
  connected_by uuid,
  connected_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_gsync_accounts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_gsync_accounts FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.lwb_gsync_accounts TO service_role;

ALTER TABLE public.lwb_gsync_config ADD COLUMN IF NOT EXISTS oauth_extra boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.lwb_gdedupe_runs (
  id bigserial PRIMARY KEY,
  by_user uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  plan jsonb NOT NULL,
  applied_at timestamptz,
  result jsonb
);
ALTER TABLE public.lwb_gdedupe_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_gdedupe_runs FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.lwb_gdedupe_runs TO service_role;
GRANT USAGE ON SEQUENCE public.lwb_gdedupe_runs_id_seq TO service_role;

CREATE OR REPLACE FUNCTION public.lwb_gsync_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE c public.lwb_gsync_config;
BEGIN
  IF NOT public.lwb_gsync_is_admin() THEN RAISE EXCEPTION 'Only Admin can see Gmail sync'; END IF;
  SELECT * INTO c FROM public.lwb_gsync_config WHERE id = 1;
  RETURN jsonb_build_object('client_set', c.client_id IS NOT NULL AND c.client_secret IS NOT NULL,
    'client_id', c.client_id, 'connected', c.refresh_token IS NOT NULL, 'email', c.google_email,
    'connected_at', c.connected_at, 'last_sync_at', c.last_sync_at, 'last_result', c.last_result,
    'running', c.running_until > now(), 'synced', (SELECT count(*) FROM public.lwb_gsync_map),
    'extra', coalesce((SELECT jsonb_agg(a.email ORDER BY a.connected_at) FROM public.lwb_gsync_accounts a), '[]'::jsonb),
    'last_dedupe', (SELECT jsonb_build_object('at', r.applied_at, 'result', r.result) FROM public.lwb_gdedupe_runs r
                     WHERE r.applied_at IS NOT NULL ORDER BY r.applied_at DESC LIMIT 1),
    'redirect_uri', 'https://luxurywristbrand.com/dial-book.html');
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_gsync_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_gsync_status() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
