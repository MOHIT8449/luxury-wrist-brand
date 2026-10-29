-- LUXURY WRIST BRAND ERP — LOGIN OTP (AUTHENTICATOR APP) ADMIN TOOLS
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- * Login page: after the password, every user types the 6-digit code from
--   Google Authenticator. The first time they scan a QR on the login page.
-- * Manage Users: Admin sees who has OTP set, and can "Reset OTP" for a user
--   who lost or changed their phone. That user scans a new QR at next login.
--
-- No order, stock, bill, payment, ledger or Tally data is changed.

BEGIN;

-- Users who already have a working Authenticator OTP (Admin only).
CREATE OR REPLACE FUNCTION public.lwb_admin_otp_users()
RETURNS SETOF uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_is_admin() THEN RAISE EXCEPTION 'Admin permission required'; END IF;
  RETURN QUERY SELECT DISTINCT f.user_id FROM auth.mfa_factors f
    WHERE f.factor_type = 'totp' AND f.status = 'verified';
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_admin_otp_users() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_admin_otp_users() TO authenticated;

-- Remove a user's Authenticator OTP so they set it again with a new QR (Admin only).
CREATE OR REPLACE FUNCTION public.lwb_admin_reset_otp(p_user_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_count integer;
BEGIN
  IF NOT public.lwb_is_admin() THEN RAISE EXCEPTION 'Admin permission required'; END IF;
  DELETE FROM auth.mfa_factors WHERE user_id = p_user_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  -- Log the user out everywhere, so the next login asks for the new QR.
  DELETE FROM auth.sessions WHERE user_id = p_user_id;
  RETURN v_count;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_admin_reset_otp(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_admin_reset_otp(uuid) TO authenticated;

COMMIT;
