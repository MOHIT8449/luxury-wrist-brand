-- LUXURY WRIST BRAND ERP — FORGOT PASSWORD WITH A WHATSAPP CODE
-- Login page > Forgot password > type the Login Mobile: the lwb-forgot-password-wa Edge Function
-- sends a 6-digit code on WhatsApp, then saves the new password when the code is right.
-- Codes are kept only as a hash, last 10 minutes, 5 tries, max 5 sends per hour per user.
-- Only the Edge Function (service key) can read this table. Safe to run again.
-- No order, stock, bill, payment, ledger or Tally data is changed.

CREATE TABLE IF NOT EXISTS public.lwb_pw_reset_codes (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  code_hash text,
  expires_at timestamptz,
  tries integer NOT NULL DEFAULT 0,
  sent_at timestamptz,
  window_start timestamptz,
  send_count integer NOT NULL DEFAULT 0
);
ALTER TABLE public.lwb_pw_reset_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_pw_reset_codes FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.lwb_pw_reset_codes TO service_role;
