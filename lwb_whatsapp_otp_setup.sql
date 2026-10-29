-- LUXURY WRIST BRAND ERP — WHATSAPP OTP ON LOGIN
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- * After the password, the login-whatsapp-otp Edge Function sends a 6-digit
--   code to the user's Login Mobile on WhatsApp. Codes are stored only as a
--   hash, last 5 minutes, and allow 5 tries.
-- * A login session that passed the WhatsApp OTP is saved here, and ERP pages
--   ask lwb_login_otp_ok() before opening.
-- * Users without a Login Mobile (or while WhatsApp is not set up) keep using
--   the Authenticator app OTP.
--
-- No order, stock, bill, payment, ledger or Tally data is changed.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_login_otp_codes (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  code_hash text,
  expires_at timestamptz,
  tries integer NOT NULL DEFAULT 0,
  sent_at timestamptz,
  window_start timestamptz,
  send_count integer NOT NULL DEFAULT 0
);
ALTER TABLE public.lwb_login_otp_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_login_otp_codes FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_login_otp_sessions (
  session_id uuid PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  verified_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_login_otp_sessions_user ON public.lwb_login_otp_sessions(user_id);
ALTER TABLE public.lwb_login_otp_sessions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_login_otp_sessions FROM PUBLIC, anon, authenticated;

-- True when this login passed an OTP: the Authenticator app (aal2) or WhatsApp.
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

-- Old verified sessions are cleaned up after 30 days.
DELETE FROM public.lwb_login_otp_sessions WHERE verified_at < now() - interval '30 days';

COMMIT;
