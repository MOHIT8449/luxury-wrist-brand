-- LWB ERP: Login OTP ON/OFF switch.
--
-- Run this whole file once in the Supabase SQL Editor. It turns the login OTP
-- step OFF for everyone (no Authenticator code, no WhatsApp code), so the
-- password alone opens the ERP. No website change is needed.
--
-- To turn OTP back ON later, run only this one line:
--   UPDATE public.lwb_login_otp_settings SET enabled = true;
-- To turn it OFF again:
--   UPDATE public.lwb_login_otp_settings SET enabled = false;
--
-- Saved Authenticator QR setups and WhatsApp data are kept, so nobody has to
-- scan the QR again when OTP is turned back ON.
-- No order, stock, bill, payment, ledger or Tally data is changed.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_login_otp_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  enabled boolean NOT NULL DEFAULT true
);
ALTER TABLE public.lwb_login_otp_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_login_otp_settings FROM PUBLIC, anon, authenticated;

INSERT INTO public.lwb_login_otp_settings (id, enabled) VALUES (true, false)
ON CONFLICT (id) DO UPDATE SET enabled = false;

-- Same check as before, plus: when OTP is switched OFF, every login passes.
CREATE OR REPLACE FUNCTION public.lwb_login_otp_ok()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT NOT coalesce((SELECT enabled FROM public.lwb_login_otp_settings LIMIT 1), true)
      OR coalesce(auth.jwt() ->> 'aal', '') = 'aal2'
      OR EXISTS (SELECT 1 FROM public.lwb_login_otp_sessions s
                 WHERE s.user_id = auth.uid()
                   AND s.session_id::text = coalesce(auth.jwt() ->> 'session_id', ''));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_login_otp_ok() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_login_otp_ok() TO authenticated;

COMMIT;

SELECT enabled AS login_otp_on FROM public.lwb_login_otp_settings;
