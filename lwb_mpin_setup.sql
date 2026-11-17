-- LUXURY WRIST BRAND ERP — MPIN QUICK LOGIN (like a bank app)
-- After one full login (password + OTP) the user sets a 4-digit MPIN on this phone. When the ERP
-- is locked (Logout, or 15 minutes without work) the login page shows an MPIN pad, plus the
-- fingerprint button when fingerprint unlock is on (quick-unlock.js).
--
-- - The MPIN is kept here only as a bcrypt hash, one per user per phone (device id made by the phone).
-- - The wrong-MPIN count is kept here too: after 5 wrong tries the MPIN of that phone is deleted and
--   the user must log in with password + OTP and set a new one.
-- - Easy MPINs (1111, 1234, 4321 ...) are refused.
-- - Admin can reset a user's MPIN on all phones (Manage Users > Reset MPIN), e.g. for a lost phone.
-- - Nobody reads the table directly; only the functions below. Safe to run again.

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS public.lwb_user_mpin(
  user_id      uuid NOT NULL,
  device_id    text NOT NULL CHECK (device_id ~ '^[A-Za-z0-9_-]{16,64}$'),
  pin_hash     text NOT NULL,
  fails        int  NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  PRIMARY KEY (user_id, device_id)
);
ALTER TABLE public.lwb_user_mpin ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_user_mpin FROM PUBLIC, anon, authenticated;

-- 0000-9999 with all digits the same, or 4 digits in a row up or down (0123 ... 6789, 9876 ... 3210).
CREATE OR REPLACE FUNCTION public.lwb_mpin_weak(p_pin text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT p_pin ~ '^(\d)\1{3}$'
      OR position(p_pin IN '0123456789') > 0
      OR position(p_pin IN '9876543210') > 0;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_mpin_set(p_device text, p_pin text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Login first.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = v_uid AND p.active IS TRUE) THEN
    RAISE EXCEPTION 'This login is not active. Please ask Admin.';
  END IF;
  IF coalesce(p_device, '') !~ '^[A-Za-z0-9_-]{16,64}$' THEN RAISE EXCEPTION 'Phone could not be identified. Reload and try again.'; END IF;
  IF coalesce(p_pin, '') !~ '^[0-9]{4}$' THEN RAISE EXCEPTION 'MPIN must be 4 digits.'; END IF;
  IF public.lwb_mpin_weak(p_pin) THEN RAISE EXCEPTION 'This MPIN is too easy (like 1111 or 1234). Choose another.'; END IF;
  INSERT INTO public.lwb_user_mpin(user_id, device_id, pin_hash)
  VALUES (v_uid, p_device, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)))
  ON CONFLICT (user_id, device_id) DO UPDATE
    SET pin_hash = excluded.pin_hash, fails = 0, created_at = now(), last_used_at = NULL;
  -- At most 5 phones per user: the oldest is removed.
  DELETE FROM public.lwb_user_mpin m
  WHERE m.user_id = v_uid AND m.device_id NOT IN (
    SELECT x.device_id FROM public.lwb_user_mpin x WHERE x.user_id = v_uid
    ORDER BY coalesce(x.last_used_at, x.created_at) DESC LIMIT 5);
  RETURN true;
END;
$fn$;

-- {ok:true} | {ok:false,left:n} | {ok:false,blocked:true} (5 wrong tries, or no MPIN on this phone)
CREATE OR REPLACE FUNCTION public.lwb_mpin_verify(p_device text, p_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_uid uuid := auth.uid(); r public.lwb_user_mpin;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Login first.'; END IF;
  SELECT * INTO r FROM public.lwb_user_mpin m WHERE m.user_id = v_uid AND m.device_id = p_device FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'blocked', true); END IF;
  IF coalesce(p_pin, '') ~ '^[0-9]{4}$' AND r.pin_hash = extensions.crypt(p_pin, r.pin_hash) THEN
    UPDATE public.lwb_user_mpin SET fails = 0, last_used_at = now() WHERE user_id = v_uid AND device_id = p_device;
    RETURN jsonb_build_object('ok', true);
  END IF;
  IF r.fails + 1 >= 5 THEN
    DELETE FROM public.lwb_user_mpin WHERE user_id = v_uid AND device_id = p_device;
    RETURN jsonb_build_object('ok', false, 'blocked', true);
  END IF;
  UPDATE public.lwb_user_mpin SET fails = r.fails + 1 WHERE user_id = v_uid AND device_id = p_device;
  RETURN jsonb_build_object('ok', false, 'left', 5 - (r.fails + 1));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_mpin_status(p_device text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.lwb_user_mpin m WHERE m.user_id = auth.uid() AND m.device_id = p_device);
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_mpin_remove(p_device text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login first.'; END IF;
  DELETE FROM public.lwb_user_mpin WHERE user_id = auth.uid() AND device_id = p_device;
  RETURN true;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_mpin_is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active IS TRUE AND lower(btrim(p.role)) = 'admin');
$fn$;

-- Manage Users: which users have an MPIN on at least one phone (Admin only).
CREATE OR REPLACE FUNCTION public.lwb_admin_mpin_users()
RETURNS SETOF uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_mpin_is_admin() THEN RAISE EXCEPTION 'Only Admin can see MPIN status.'; END IF;
  RETURN QUERY SELECT DISTINCT m.user_id FROM public.lwb_user_mpin m;
END;
$fn$;

-- Manage Users > Reset MPIN: removes the user's MPIN on every phone (lost phone / forgotten MPIN).
CREATE OR REPLACE FUNCTION public.lwb_admin_reset_mpin(p_user_id uuid)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE n int;
BEGIN
  IF NOT public.lwb_mpin_is_admin() THEN RAISE EXCEPTION 'Only Admin can reset an MPIN.'; END IF;
  DELETE FROM public.lwb_user_mpin WHERE user_id = p_user_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_mpin_weak(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_mpin_set(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_mpin_verify(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_mpin_status(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_mpin_remove(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_mpin_is_admin() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_admin_mpin_users() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_admin_reset_mpin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_mpin_set(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_mpin_verify(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_mpin_status(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_mpin_remove(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_admin_mpin_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_admin_reset_mpin(uuid) TO authenticated;
