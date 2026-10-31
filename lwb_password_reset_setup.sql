-- LUXURY WRIST BRAND ERP — FORGOT PASSWORD WITH THE EMAIL CODE ONLY
-- Login page > Forgot password: the user types the code from the email and a new password.
-- Supabase's own updateUser() asks for the Google Authenticator code (AAL2) when the user has the
-- app set up, so the page asked for two codes. This function saves the new password with the email
-- code alone. Opening the ERP afterwards still needs the normal password + OTP login.
-- Allowed only for a session opened by an email code (amr "recovery" / "otp") in the last 15 minutes,
-- for the user's own login, and only for an active ERP user. Safe to run again.

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.lwb_reset_own_password(p_password text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_amr jsonb := coalesce(auth.jwt() -> 'amr', '[]'::jsonb);
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Session not found. Please enter the email code again.'; END IF;
  IF jsonb_typeof(v_amr) <> 'array' OR NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_amr) a
       WHERE a ->> 'method' IN ('recovery', 'otp')
         AND (a ->> 'timestamp') ~ '^[0-9]+$'
         AND (a ->> 'timestamp')::bigint >= extract(epoch FROM now())::bigint - 900) THEN
    RAISE EXCEPTION 'The email code has expired. Please tap Resend Code and try again.';
  END IF;
  IF length(coalesce(p_password, '')) < 6 THEN RAISE EXCEPTION 'Password must be at least 6 characters'; END IF;
  IF length(p_password) > 72 THEN RAISE EXCEPTION 'Password is too long (max 72 characters)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = v_uid AND p.active IS TRUE) THEN
    RAISE EXCEPTION 'This login is not active. Please ask Admin.';
  END IF;
  UPDATE auth.users SET encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
  WHERE id = v_uid;
  RETURN true;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_reset_own_password(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_reset_own_password(text) TO authenticated;
