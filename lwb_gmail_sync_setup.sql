-- LUXURY WRIST BRAND ERP — DIAL BOOK: AUTO SYNC TO GMAIL / GOOGLE CONTACTS (28 Nov 2026)
--
-- Mohit asked (27-28 Nov 2026): the Dial Book numbers should save themselves in the Gmail (Google Contacts)
-- of the company account, every day, without downloading a file.
--
--   Admin: Dial Book > "Gmail sync" > paste the Google Client ID + Secret once > "Connect Gmail" > allow.
--   Edge Function lwb-google-contacts keeps the Google login (refresh token, never sent to the browser)
--   and puts every Dial Book contact (same list and names as the Admin contacts file) in the contact label
--   "LWB ERP": new numbers are added, changed ones updated, removed ones deleted. Contacts outside the
--   "LWB ERP" label are never touched. Runs every night at 2:00 AM IST and on "Sync now".
--
--   lwb_gsync_config       one row: Google client, login, last sync (service_role only, no browser access)
--   lwb_gsync_map          Dial Book contact -> Google contact (resource name, hash of what was sent)
--   lwb_gsync_status()     Admin: is it set up / connected, last sync result (no secrets)
--   lwb_gsync_set_client() Admin: save the Google Client ID + Secret
--   lwb_gsync_contacts()   service_role: the contacts to sync (as the Admin who connected Gmail)
--   lwb_gsync_tick()       cron: calls the Edge Function with the secret
--
-- Safe to run again. Nothing is dropped or deleted.

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS public.lwb_gsync_config (
  id integer PRIMARY KEY CHECK (id = 1),
  project_url text NOT NULL DEFAULT 'https://qstgwhbgbznxemajtave.supabase.co',
  webhook_secret text NOT NULL DEFAULT encode(extensions.gen_random_bytes(32), 'hex'),
  client_id text, client_secret text,
  refresh_token text, google_email text, group_rn text,
  connected_by uuid, connected_at timestamptz,
  oauth_state text, oauth_state_by uuid, oauth_state_at timestamptz,
  last_sync_at timestamptz, last_result jsonb, running_until timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.lwb_gsync_config(id) VALUES (1) ON CONFLICT DO NOTHING;
ALTER TABLE public.lwb_gsync_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_gsync_config FROM PUBLIC, anon, authenticated;
GRANT SELECT, UPDATE ON TABLE public.lwb_gsync_config TO service_role;

CREATE TABLE IF NOT EXISTS public.lwb_gsync_map (
  key text PRIMARY KEY,            -- kind|ref of the Dial Book contact
  resource_name text NOT NULL,     -- people/c123...
  hash text NOT NULL,
  synced_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_gsync_map ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_gsync_map FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.lwb_gsync_map TO service_role;

CREATE OR REPLACE FUNCTION public.lwb_gsync_is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'admin')
$$;
REVOKE ALL ON FUNCTION public.lwb_gsync_is_admin() FROM PUBLIC, anon, authenticated;

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
    'redirect_uri', 'https://luxurywristbrand.com/dial-book.html');
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_gsync_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_gsync_status() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_gsync_set_client(p_client_id text, p_client_secret text)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_id text := btrim(coalesce(p_client_id, '')); v_sec text := btrim(coalesce(p_client_secret, ''));
BEGIN
  IF NOT public.lwb_gsync_is_admin() THEN RAISE EXCEPTION 'Only Admin can set up Gmail sync'; END IF;
  IF v_id !~ '^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$' THEN
    RAISE EXCEPTION 'Client ID looks wrong. It ends with .apps.googleusercontent.com';
  END IF;
  IF length(v_sec) < 10 OR length(v_sec) > 100 OR v_sec ~ '\s' THEN RAISE EXCEPTION 'Client secret looks wrong'; END IF;
  UPDATE public.lwb_gsync_config SET client_id = v_id, client_secret = v_sec,
    -- a new Google client needs a new login
    refresh_token = CASE WHEN client_id IS DISTINCT FROM v_id THEN NULL ELSE refresh_token END,
    updated_at = now() WHERE id = 1;
  RETURN public.lwb_gsync_status();
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_gsync_set_client(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_gsync_set_client(text, text) TO authenticated;

-- The contacts to sync: the Admin contacts file list (every number once), as the Admin who connected Gmail.
CREATE OR REPLACE FUNCTION public.lwb_gsync_contacts()
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE u uuid; v jsonb;
BEGIN
  SELECT c.connected_by INTO u FROM public.lwb_gsync_config c WHERE c.id = 1;
  IF u IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = u AND p.active = true AND lower(btrim(p.role)) = 'admin') THEN
    RAISE EXCEPTION 'Gmail sync: the Admin who connected Gmail is not an active Admin any more. Connect again.';
  END IF;
  PERFORM set_config('request.jwt.claim.sub', u::text, true);
  WITH a AS (SELECT x.*, CASE x.kind WHEN 'PARTY' THEN 1 WHEN 'TEAM' THEN 2 WHEN 'STAFF' THEN 3 WHEN 'DRIVER' THEN 4 ELSE 5 END AS o FROM public.lwb_dial_all() x),
       nums AS (
         SELECT a.kind, a.ref, a.o, a.name, a.mobile, 0::bigint AS k, 'Primary'::text AS label FROM a
         UNION ALL
         SELECT a.kind, a.ref, a.o, a.name, n.mobile, n.id, coalesce(n.label, 'Extra') FROM a JOIN public.lwb_contact_numbers n ON n.kind = a.kind AND n.ref = a.ref),
       firsts AS (SELECT DISTINCT ON (mobile) * FROM nums WHERE mobile IS NOT NULL ORDER BY mobile, o, name, k),
       c AS (SELECT a.kind, a.ref, a.o, a.save_as, a.sub,
               (SELECT jsonb_agg(jsonb_build_object('mobile', f.mobile, 'label', f.label) ORDER BY f.k) FROM firsts f WHERE f.kind = a.kind AND f.ref = a.ref) AS numbers
             FROM a)
  SELECT coalesce(jsonb_agg(jsonb_build_object('key', c.kind || '|' || c.ref, 'kind', c.kind, 'name', c.save_as, 'sub', c.sub,
           'numbers', c.numbers, 'hash', md5(concat_ws('|', c.save_as, c.sub, c.numbers::text))) ORDER BY c.o, c.save_as), '[]'::jsonb)
    INTO v FROM c WHERE c.numbers IS NOT NULL;
  RETURN v;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_gsync_contacts() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_gsync_contacts() TO service_role;

-- Nightly: ask the Edge Function to sync (only when Gmail is connected).
CREATE OR REPLACE FUNCTION public.lwb_gsync_tick()
RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE c public.lwb_gsync_config;
BEGIN
  SELECT * INTO c FROM public.lwb_gsync_config WHERE id = 1;
  IF c.refresh_token IS NULL OR to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') IS NULL THEN RETURN false; END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := $3, params := ''{}''::jsonb, headers := $2, timeout_milliseconds := 150000)'
    USING c.project_url || '/functions/v1/lwb-google-contacts',
          jsonb_build_object('Content-Type', 'application/json', 'x-lwb-gsync-secret', c.webhook_secret),
          jsonb_build_object('action', 'sync', 'by', 'nightly');
  RETURN true;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_gsync_tick() FROM PUBLIC, anon, authenticated;

DO $c$ BEGIN
  IF to_regclass('cron.job') IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'lwb_gmail_sync_nightly') THEN
      PERFORM cron.schedule('lwb_gmail_sync_nightly', '30 20 * * *', 'SELECT public.lwb_gsync_tick()');  -- 2:00 AM IST
    END IF;
  END IF;
END $c$;

COMMIT;
NOTIFY pgrst, 'reload schema';
