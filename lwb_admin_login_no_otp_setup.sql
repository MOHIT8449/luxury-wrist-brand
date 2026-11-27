-- Admin login without OTP (Mohit, 27 Nov 2026).
-- Admin opens the ERP with Mobile / Email + Password only: no WhatsApp OTP, no Authenticator code.
-- Every other role still needs the OTP after the password (unchanged).
-- Admin also has no MPIN / fingerprint quick login any more: this phone-level MPIN of every Admin
-- is removed here (login.html and erp-shell.js no longer offer MPIN or fingerprint to Admin).
BEGIN;

-- True when this login passed an OTP (Authenticator aal2 or WhatsApp), or the login is an active Admin.
-- login.html and erp-shell.js (otpGuard) ask this before opening the ERP.
CREATE OR REPLACE FUNCTION public.lwb_login_otp_ok()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
      OR EXISTS (SELECT 1 FROM public.lwb_login_otp_sessions s
                 WHERE s.user_id = auth.uid()
                   AND s.session_id::text = coalesce(auth.jwt() ->> 'session_id', ''))
      OR EXISTS (SELECT 1 FROM public.user_profiles p
                 WHERE p.id = auth.uid() AND p.active IS TRUE AND lower(btrim(p.role)) = 'admin');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_login_otp_ok() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_login_otp_ok() TO authenticated;

-- Admin's MPINs are removed (no MPIN login for Admin).
DELETE FROM public.lwb_user_mpin m
 USING public.user_profiles p
 WHERE p.id = m.user_id AND lower(btrim(p.role)) = 'admin';

COMMIT;
