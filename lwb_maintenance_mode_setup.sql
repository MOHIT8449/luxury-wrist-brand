-- LUXURY WRIST BRAND ERP — MAINTENANCE MODE (Admin-only main switch, Mohit 18 Nov 2026)
--
-- Runs by itself on merge (Supabase apply workflow). Safe to run again.
--
-- Admin turns "Maintenance" ON from the wrench button in the top bar. While it is ON:
--   * every logged-in user who is not Admin gets NOTHING from the database: no parties, routes,
--     deliveries, orders, stock, bills ... and cannot add, edit or delete anything. Every table read
--     and every RPC through the Supabase API is refused by lwb_maintenance_gate() (PostgREST
--     pre-request hook), so it holds for the website, the phone app and any other client.
--   * Realtime (bell / chat live messages) and Storage (photos, PDFs) are refused for them too
--     (restrictive RLS policies below).
--   * Admin keeps full access. Login pages, the mpin / OTP login functions (anon) and Edge Functions
--     (service role) keep working, so Admin can always log in.
-- Turning it OFF opens everything again at once. Nothing else is changed, no data is deleted.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_maintenance (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  is_on boolean NOT NULL DEFAULT false,
  message text NOT NULL DEFAULT '',
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by uuid,
  changed_by_name text
);
INSERT INTO public.lwb_maintenance(id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.lwb_maintenance ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_maintenance FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_maintenance_log (
  id bigserial PRIMARY KEY,
  is_on boolean NOT NULL,
  message text,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by uuid,
  changed_by_name text
);
ALTER TABLE public.lwb_maintenance_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_maintenance_log FROM PUBLIC, anon, authenticated;

-- true while Maintenance is ON.
CREATE OR REPLACE FUNCTION public.lwb_maintenance_on()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce((SELECT m.is_on FROM public.lwb_maintenance m WHERE m.id = 1), false);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_maintenance_on() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lwb_maintenance_on() TO anon, authenticated, service_role;

-- true when this login may see / change data now: Maintenance OFF, or the login is Admin.
CREATE OR REPLACE FUNCTION public.lwb_data_open()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT NOT public.lwb_maintenance_on() OR public.lwb_is_admin();
$fn$;
REVOKE ALL ON FUNCTION public.lwb_data_open() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lwb_data_open() TO anon, authenticated, service_role;

-- What the pages show. Anyone (also the Login page before login) may ask; names only for Admin.
CREATE OR REPLACE FUNCTION public.lwb_maintenance_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  m public.lwb_maintenance;
  v_admin boolean := auth.uid() IS NOT NULL AND public.lwb_is_admin();
BEGIN
  SELECT * INTO m FROM public.lwb_maintenance WHERE id = 1;
  RETURN jsonb_build_object(
    'on', coalesce(m.is_on, false),
    'message', CASE WHEN coalesce(m.is_on, false) THEN nullif(m.message, '') END,
    'since', CASE WHEN coalesce(m.is_on, false) THEN m.changed_at END,
    'admin', v_admin,
    'changed_at', CASE WHEN v_admin THEN m.changed_at END,
    'changed_by', CASE WHEN v_admin THEN m.changed_by_name END);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_maintenance_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lwb_maintenance_status() TO anon, authenticated;

-- Admin only: turn Maintenance ON / OFF.
CREATE OR REPLACE FUNCTION public.lwb_set_maintenance(p_on boolean, p_message text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_msg text := left(btrim(coalesce(p_message, '')), 300);
  v_name text;
BEGIN
  IF NOT public.lwb_is_admin() THEN RAISE EXCEPTION 'Only Admin can turn Maintenance on or off'; END IF;
  IF p_on IS NULL THEN RAISE EXCEPTION 'Choose ON or OFF'; END IF;
  SELECT coalesce(nullif(btrim(p.full_name), ''), 'Admin') INTO v_name FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.lwb_maintenance(id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  UPDATE public.lwb_maintenance
     SET is_on = p_on, message = CASE WHEN p_on THEN v_msg ELSE '' END,
         changed_at = now(), changed_by = auth.uid(), changed_by_name = v_name
   WHERE id = 1;
  INSERT INTO public.lwb_maintenance_log(is_on, message, changed_by, changed_by_name)
  VALUES (p_on, CASE WHEN p_on THEN v_msg END, auth.uid(), v_name);
  RETURN public.lwb_maintenance_status();
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_set_maintenance(boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_maintenance(boolean, text) TO authenticated;

-- PostgREST pre-request hook: runs before EVERY API request (tables and RPCs), as the caller's role.
-- Logged-in non-Admin users are refused with HTTP 423 while Maintenance is ON. Anon (login screens)
-- and service_role (Edge Functions) pass. If anything inside the check itself fails, the request is
-- let through, so a fault here can never lock the whole ERP.
CREATE OR REPLACE FUNCTION public.lwb_maintenance_gate()
RETURNS void LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path = ''
AS $fn$
DECLARE
  v_block boolean := false;
  v_path text;
BEGIN
  IF current_user <> 'authenticated' THEN RETURN; END IF;
  BEGIN
    v_path := coalesce(current_setting('request.path', true), '');
    v_block := public.lwb_maintenance_on()
      AND v_path NOT LIKE '%/rpc/lwb_maintenance_status'
      -- Pages first read the login's own profile (role, name); allowed so they open and show the
      -- maintenance screen instead of logging the user out. Only the own row (policy below).
      AND NOT (v_path LIKE '%/user_profiles' AND current_setting('request.method', true) IN ('GET', 'HEAD')
               AND coalesce((SELECT c.relrowsecurity FROM pg_catalog.pg_class c WHERE c.oid = 'public.user_profiles'::regclass), false))
      AND NOT public.lwb_is_admin();
  EXCEPTION WHEN OTHERS THEN
    v_block := false;
  END;
  IF v_block THEN
    RAISE SQLSTATE 'PT423' USING
      MESSAGE = 'System under maintenance. Please try again later.',
      HINT = 'lwb_maintenance';
  END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_maintenance_gate() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lwb_maintenance_gate() TO anon, authenticated, service_role;

-- Realtime (bell, team chat ...) checks SELECT rules: no live rows for non-Admin while ON.
-- Applied to every public table in the supabase_realtime publication that already has RLS on.
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.relname
    FROM pg_publication_tables pt
    JOIN pg_class c ON c.relname = pt.tablename
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = pt.schemaname
    WHERE pt.pubname = 'supabase_realtime' AND pt.schemaname = 'public' AND c.relrowsecurity
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS lwb_maintenance_block ON public.%I', r.relname);
    EXECUTE format('CREATE POLICY lwb_maintenance_block ON public.%I AS RESTRICTIVE FOR SELECT TO authenticated USING ((SELECT public.lwb_data_open()))', r.relname);
  END LOOP;
END $$;

-- Own profile only (name, role) for non-Admin while ON; the team list stays hidden.
DO $$
BEGIN
  IF (SELECT c.relrowsecurity FROM pg_class c WHERE c.oid = 'public.user_profiles'::regclass) THEN
    DROP POLICY IF EXISTS lwb_maintenance_block ON public.user_profiles;
    CREATE POLICY lwb_maintenance_block ON public.user_profiles AS RESTRICTIVE FOR SELECT TO authenticated
      USING ((SELECT public.lwb_data_open()) OR id = (SELECT auth.uid()));
  END IF;
END $$;

-- Storage (photos, PDFs, bills): no view / upload / delete for non-Admin while ON.
DO $$
BEGIN
  IF to_regclass('storage.objects') IS NOT NULL THEN
    DROP POLICY IF EXISTS lwb_maintenance_block ON storage.objects;
    CREATE POLICY lwb_maintenance_block ON storage.objects AS RESTRICTIVE FOR ALL TO authenticated
      USING ((SELECT public.lwb_data_open())) WITH CHECK ((SELECT public.lwb_data_open()));
  END IF;
END $$;

-- Turn the hook on. Refuses to replace a different pre-request hook if one was ever set.
DO $$
DECLARE v_old text;
BEGIN
  SELECT split_part(cfg, '=', 2) INTO v_old
  FROM pg_db_role_setting s, unnest(s.setconfig) cfg
  WHERE s.setrole = 'authenticator'::regrole AND s.setdatabase = 0 AND cfg LIKE 'pgrst.db_pre_request=%';
  IF v_old IS NOT NULL AND v_old NOT IN ('public.lwb_maintenance_gate', 'lwb_maintenance_gate') THEN
    RAISE EXCEPTION 'Another PostgREST pre-request hook (%) is already set; not replacing it', v_old;
  END IF;
END $$;
ALTER ROLE authenticator SET pgrst.db_pre_request TO 'public.lwb_maintenance_gate';

COMMIT;

NOTIFY pgrst, 'reload config';
NOTIFY pgrst, 'reload schema';
