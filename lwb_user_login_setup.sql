-- LUXURY WRIST BRAND ERP — ADMIN CREATES LOGINS; LOGIN WITH MOBILE OR EMAIL
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- * Manage Users > Add New User: Admin enters name, mobile and/or email,
--   password and role. The login is ready at once (no email confirmation).
--   A user with no email gets an internal login email m<mobile>@staff.lwb-erp.in;
--   nobody needs to know it.
-- * Login page: type the mobile number OR the email, plus the password.
--   A mobile number is looked up here only when the password is correct,
--   and 8 wrong tries lock that login for 15 minutes.
-- * Admin can change any user's login mobile or password.
--
-- No order, stock, bill, payment, ledger or Tally data is changed.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.lwb_is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'admin');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_is_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_is_admin() TO authenticated;

-- 10-digit Indian mobile, or NULL.
CREATE OR REPLACE FUNCTION public.lwb_mobile10(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE WHEN d ~ '^[6-9][0-9]{9}$' THEN d END
  FROM (SELECT CASE WHEN length(x) = 12 AND x LIKE '91%' THEN right(x, 10)
                    WHEN length(x) = 11 AND x LIKE '0%' THEN right(x, 10)
                    ELSE x END AS d
        FROM (SELECT regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') AS x) a) b;
$fn$;

CREATE TABLE IF NOT EXISTS public.lwb_login_attempts (
  login text PRIMARY KEY,
  fails integer NOT NULL DEFAULT 0,
  last_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_login_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_login_attempts FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Users list for Manage Users (Admin).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_admin_users()
RETURNS TABLE (user_id uuid, email text, full_name text, erp_role text, is_active boolean,
               mobile text, has_profile boolean, last_sign_in_at timestamptz, created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
#variable_conflict use_column
BEGIN
  IF NOT public.lwb_is_admin() THEN RAISE EXCEPTION 'Admin permission required'; END IF;
  RETURN QUERY
    SELECT u.id,
      CASE WHEN u.email::text LIKE '%@staff.lwb-erp.in' THEN NULL ELSE u.email::text END,
      p.full_name::text, lower(btrim(p.role))::text, p.active, p.mobile::text, (p.id IS NOT NULL),
      u.last_sign_in_at, u.created_at
    FROM auth.users u
    LEFT JOIN public.user_profiles p ON p.id = u.id
    ORDER BY u.created_at DESC;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Create a login (Admin).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_admin_create_user(
  p_full_name text, p_mobile text, p_email text, p_password text, p_role text, p_active boolean DEFAULT true)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_id uuid := gen_random_uuid();
  v_name text := btrim(coalesce(p_full_name, ''));
  v_mobile text := public.lwb_mobile10(p_mobile);
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_role text := lower(btrim(coalesce(p_role, '')));
BEGIN
  IF NOT public.lwb_is_admin() THEN RAISE EXCEPTION 'Only an active Admin can create logins'; END IF;
  IF v_name = '' OR length(v_name) > 150 THEN RAISE EXCEPTION 'Enter the full name'; END IF;
  IF btrim(coalesce(p_mobile, '')) <> '' AND v_mobile IS NULL THEN RAISE EXCEPTION 'Enter a valid 10-digit mobile number'; END IF;
  IF v_email <> '' AND v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN RAISE EXCEPTION 'Enter a valid email'; END IF;
  IF v_mobile IS NULL AND v_email = '' THEN RAISE EXCEPTION 'Enter a mobile number or an email'; END IF;
  IF length(coalesce(p_password, '')) < 6 THEN RAISE EXCEPTION 'Password must be at least 6 characters'; END IF;
  IF v_role NOT IN ('admin','accounts','manager','sales','warehouse','transport','driver') THEN RAISE EXCEPTION 'Select a role'; END IF;
  IF v_mobile IS NOT NULL AND EXISTS (SELECT 1 FROM public.user_profiles p WHERE public.lwb_mobile10(p.mobile) = v_mobile) THEN
    RAISE EXCEPTION 'Mobile % is already used by another login', v_mobile;
  END IF;
  IF v_email = '' THEN v_email := 'm' || v_mobile || '@staff.lwb-erp.in'; END IF;
  IF EXISTS (SELECT 1 FROM auth.users u WHERE lower(u.email) = v_email) THEN
    RAISE EXCEPTION 'A login with % already exists', v_email;
  END IF;

  INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change)
  VALUES ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', v_name),
    now(), now(), '', '', '', '');

  INSERT INTO auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  VALUES (gen_random_uuid(), v_id::text, v_id,
    jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true, 'phone_verified', false),
    'email', now(), now(), now());

  INSERT INTO public.user_profiles (id, full_name, role, active, mobile)
  VALUES (v_id, v_name, v_role, coalesce(p_active, true), v_mobile)
  ON CONFLICT (id) DO UPDATE SET full_name = excluded.full_name, role = excluded.role,
    active = excluded.active, mobile = excluded.mobile;
  RETURN v_id;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Change login mobile and/or password (Admin). NULL / blank = leave as is.
-- p_clear_mobile = true removes the login mobile.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_admin_set_login(
  p_user_id uuid, p_mobile text, p_password text, p_clear_mobile boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_mobile text := public.lwb_mobile10(p_mobile);
BEGIN
  IF NOT public.lwb_is_admin() THEN RAISE EXCEPTION 'Only an active Admin can change logins'; END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN RAISE EXCEPTION 'Login not found'; END IF;
  IF btrim(coalesce(p_mobile, '')) <> '' THEN
    IF v_mobile IS NULL THEN RAISE EXCEPTION 'Enter a valid 10-digit mobile number'; END IF;
    IF EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id <> p_user_id AND public.lwb_mobile10(p.mobile) = v_mobile) THEN
      RAISE EXCEPTION 'Mobile % is already used by another login', v_mobile;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user_id) THEN
      RAISE EXCEPTION 'Assign a role first, then set the mobile';
    END IF;
    UPDATE public.user_profiles SET mobile = v_mobile WHERE id = p_user_id;
  ELSIF p_clear_mobile THEN
    IF EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id AND u.email LIKE '%@staff.lwb-erp.in') THEN
      RAISE EXCEPTION 'This login has no email, so the mobile cannot be removed';
    END IF;
    UPDATE public.user_profiles SET mobile = NULL WHERE id = p_user_id;
  END IF;
  IF coalesce(p_password, '') <> '' THEN
    IF length(p_password) < 6 THEN RAISE EXCEPTION 'Password must be at least 6 characters'; END IF;
    UPDATE auth.users SET encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
    WHERE id = p_user_id;
  END IF;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Login page: mobile number -> login email, only when the password matches.
-- Callable without login. Returns NULL for a wrong mobile or password.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_login_email(p_login text, p_password text)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_mobile text := public.lwb_mobile10(p_login); v_email text; v_hash text; v_fails integer; v_last timestamptz;
BEGIN
  IF v_mobile IS NULL OR coalesce(p_password, '') = '' THEN RETURN NULL; END IF;
  SELECT a.fails, a.last_at INTO v_fails, v_last FROM public.lwb_login_attempts a WHERE a.login = v_mobile;
  IF v_fails >= 8 AND v_last > now() - interval '15 minutes' THEN
    RAISE EXCEPTION 'Too many wrong tries. Wait 15 minutes and try again.';
  END IF;
  SELECT u.email::text, u.encrypted_password::text INTO v_email, v_hash
  FROM public.user_profiles p JOIN auth.users u ON u.id = p.id
  WHERE p.active = true AND public.lwb_mobile10(p.mobile) = v_mobile
  LIMIT 1;
  IF v_hash IS NOT NULL AND v_hash = extensions.crypt(p_password, v_hash) THEN
    DELETE FROM public.lwb_login_attempts WHERE login = v_mobile;
    RETURN v_email;
  END IF;
  INSERT INTO public.lwb_login_attempts (login, fails, last_at) VALUES (v_mobile, 1, now())
  ON CONFLICT (login) DO UPDATE SET
    fails = CASE WHEN public.lwb_login_attempts.last_at < now() - interval '15 minutes' THEN 1 ELSE public.lwb_login_attempts.fails + 1 END,
    last_at = now();
  RETURN NULL;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_mobile10(text), public.lwb_admin_users(),
  public.lwb_admin_create_user(text,text,text,text,text,boolean), public.lwb_admin_set_login(uuid,text,text,boolean),
  public.lwb_login_email(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_mobile10(text), public.lwb_admin_users(),
  public.lwb_admin_create_user(text,text,text,text,text,boolean), public.lwb_admin_set_login(uuid,text,text,boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_login_email(text,text) TO anon, authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: both lines should say true.
SELECT 'login functions' AS item, count(*) = 4 AS ok FROM information_schema.routines
  WHERE routine_schema = 'public' AND routine_name IN ('lwb_admin_users','lwb_admin_create_user','lwb_admin_set_login','lwb_login_email')
UNION ALL
SELECT 'no duplicate mobiles', NOT EXISTS (
  SELECT 1 FROM public.user_profiles WHERE public.lwb_mobile10(mobile) IS NOT NULL
  GROUP BY public.lwb_mobile10(mobile) HAVING count(*) > 1);
