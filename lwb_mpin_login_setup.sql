-- LUXURY WRIST BRAND ERP — LOGIN WITH MPIN (after the login session has ended)
-- Mohit, 18 Nov 2026: when the login on a phone has ended (Logout without MPIN, 15 idle minutes, or a
-- session that expired), a phone that has an MPIN shows the MPIN pad on the login page instead of
-- asking for the password + OTP again.
--
-- The lwb-mpin-login Edge Function calls lwb_mpin_login_check() with the server key. It checks the
-- MPIN of THIS user on THIS phone (device id made by the phone, lwb_mpin_setup.sql) with the same
-- 5-wrong-tries rule as lwb_mpin_verify(); only then does the function open a new login session.
-- Nobody else can call it (no grant to anon / authenticated). Safe to run again.

CREATE OR REPLACE FUNCTION public.lwb_mpin_login_check(p_user uuid, p_device text, p_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r public.lwb_user_mpin;
BEGIN
  IF p_user IS NULL OR coalesce(p_device, '') !~ '^[A-Za-z0-9_-]{16,64}$' THEN
    RETURN jsonb_build_object('ok', false, 'blocked', true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user AND p.active IS TRUE) THEN
    RETURN jsonb_build_object('ok', false, 'inactive', true);
  END IF;
  SELECT * INTO r FROM public.lwb_user_mpin m WHERE m.user_id = p_user AND m.device_id = p_device FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'blocked', true); END IF;
  IF coalesce(p_pin, '') ~ '^[0-9]{4}$' AND r.pin_hash = extensions.crypt(p_pin, r.pin_hash) THEN
    UPDATE public.lwb_user_mpin SET fails = 0, last_used_at = now() WHERE user_id = p_user AND device_id = p_device;
    RETURN jsonb_build_object('ok', true);
  END IF;
  IF r.fails + 1 >= 5 THEN
    DELETE FROM public.lwb_user_mpin WHERE user_id = p_user AND device_id = p_device;
    RETURN jsonb_build_object('ok', false, 'blocked', true);
  END IF;
  UPDATE public.lwb_user_mpin SET fails = r.fails + 1 WHERE user_id = p_user AND device_id = p_device;
  RETURN jsonb_build_object('ok', false, 'left', 5 - (r.fails + 1));
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_mpin_login_check(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_mpin_login_check(uuid, text, text) TO service_role;
