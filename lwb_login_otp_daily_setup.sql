-- WhatsApp OTP once a day (Mohit, 27 Nov 2026).
-- Admin, Sales Head (manager) and Accounts: the first login of the day on a phone / computer needs
-- Password + WhatsApp OTP (or the Authenticator code). Later logins the same day (India time) on the
-- SAME phone / computer need only the Password. A new phone / computer always needs the OTP.
-- Other roles: OTP at every login, as before.
-- Admin has no MPIN / fingerprint login any more: every Admin MPIN is removed here.
BEGIN;

-- Undo the short "Admin needs no OTP" rule: OTP check is the same for every role again.
CREATE OR REPLACE FUNCTION public.lwb_login_otp_ok()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
      OR EXISTS (SELECT 1 FROM public.lwb_login_otp_sessions s
                 WHERE s.user_id = auth.uid()
                   AND s.session_id::text = coalesce(auth.jwt() ->> 'session_id', ''));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_login_otp_ok() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_login_otp_ok() TO authenticated;

-- Phone / computer (login.html device id) that passed the OTP today.
CREATE TABLE IF NOT EXISTS public.lwb_login_otp_days(
  user_id   uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  device_id text NOT NULL CHECK (device_id ~ '^[A-Za-z0-9_-]{16,64}$'),
  day       date NOT NULL,
  at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, device_id, day)
);
ALTER TABLE public.lwb_login_otp_days ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_login_otp_days FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_login_otp_daily_role()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active IS TRUE
      AND lower(btrim(p.role)) IN ('admin','manager','accounts'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_login_otp_daily_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_login_otp_daily_role() TO authenticated;

-- After the OTP passed on this login: remember this phone / computer for today.
CREATE OR REPLACE FUNCTION public.lwb_login_otp_remember(p_device text)
RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF auth.uid() IS NULL OR NOT public.lwb_login_otp_ok() OR NOT public.lwb_login_otp_daily_role()
     OR coalesce(p_device,'') !~ '^[A-Za-z0-9_-]{16,64}$' THEN
    RETURN false;
  END IF;
  INSERT INTO public.lwb_login_otp_days(user_id, device_id, day)
  VALUES (auth.uid(), p_device, (now() AT TIME ZONE 'Asia/Kolkata')::date)
  ON CONFLICT DO NOTHING;
  DELETE FROM public.lwb_login_otp_days WHERE day < (now() AT TIME ZONE 'Asia/Kolkata')::date - 7;
  RETURN true;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_login_otp_remember(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_login_otp_remember(text) TO authenticated;

-- Password login later today on the same phone / computer: this login counts as OTP-verified.
CREATE OR REPLACE FUNCTION public.lwb_login_otp_today(p_device text)
RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE sid text := coalesce(auth.jwt() ->> 'session_id', '');
BEGIN
  IF auth.uid() IS NULL OR sid !~ '^[0-9a-fA-F-]{36}$' OR NOT public.lwb_login_otp_daily_role() THEN RETURN false; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_login_otp_days d
                 WHERE d.user_id = auth.uid() AND d.device_id = coalesce(p_device,'')
                   AND d.day = (now() AT TIME ZONE 'Asia/Kolkata')::date) THEN
    RETURN false;
  END IF;
  INSERT INTO public.lwb_login_otp_sessions(session_id, user_id) VALUES (sid::uuid, auth.uid())
  ON CONFLICT (session_id) DO NOTHING;
  RETURN true;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_login_otp_today(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_login_otp_today(text) TO authenticated;

-- Admin's MPINs are removed (no MPIN login for Admin).
DELETE FROM public.lwb_user_mpin m
 USING public.user_profiles p
 WHERE p.id = m.user_id AND lower(btrim(p.role)) = 'admin';

COMMIT;
