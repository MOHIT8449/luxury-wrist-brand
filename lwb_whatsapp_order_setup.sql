-- LUXURY WRIST BRAND ERP — CUSTOMER ORDERS ON WHATSAPP (Mohit, 21 Nov 2026)
--
-- The Edge Function lwb-wa-order (Meta WhatsApp Cloud API webhook, number 99926 99905) chats with the
-- customer: brand > products > cases > Send. The order goes to lwb_web_order_intake(p, 'WHATSAPP')
-- (lwb_web_order_setup.sql), the same place as website orders: known party = pending PO, else Website Orders.
--
--   lwb_wa_sessions : the half-made order per customer mobile (Edge Function only).
--   lwb_wa_seen     : Meta message ids already handled (Meta may send one again). Kept 3 days.
--   lwb_wa_party(m) : how many active parties have this mobile, and the name when it is one.
-- Only the Edge Function (service role) uses these; the browser cannot.
-- Safe to run again. Nothing existing is changed.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_wa_sessions (
  mobile text PRIMARY KEY CHECK (mobile ~ '^[6-9][0-9]{9}$'),
  state jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(state) = 'object' AND octet_length(state::text) <= 50000),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.lwb_wa_seen (
  msg_id text PRIMARY KEY CHECK (length(msg_id) BETWEEN 1 AND 200),
  mobile text,
  at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_wa_seen_at_idx ON public.lwb_wa_seen(at);

ALTER TABLE public.lwb_wa_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_wa_seen ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_wa_sessions, public.lwb_wa_seen FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.lwb_wa_sessions, public.lwb_wa_seen TO service_role;

-- Old message ids go away by themselves.
CREATE OR REPLACE FUNCTION public.lwb_wa_seen_cleanup()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF random() < 0.02 THEN DELETE FROM public.lwb_wa_seen WHERE at < now() - interval '3 days'; END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_wa_seen_cleanup() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS lwb_wa_seen_cleanup ON public.lwb_wa_seen;
CREATE TRIGGER lwb_wa_seen_cleanup AFTER INSERT ON public.lwb_wa_seen
  FOR EACH ROW EXECUTE FUNCTION public.lwb_wa_seen_cleanup();

-- The sender's own number (WhatsApp proves it), so the chat can greet the party by name.
CREATE OR REPLACE FUNCTION public.lwb_wa_party(p_mobile text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT jsonb_build_object('count', count(*), 'name', CASE WHEN count(*) = 1 THEN min(c.customer_name) END)
  FROM public.lwb_customer_master c
  WHERE c.is_active = true
    AND right(regexp_replace(coalesce(p_mobile,''), '[^0-9]', '', 'g'), 10) ~ '^[6-9][0-9]{9}$'
    AND right(regexp_replace(coalesce(c.mobile,''), '[^0-9]', '', 'g'), 10) = right(regexp_replace(coalesce(p_mobile,''), '[^0-9]', '', 'g'), 10);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_wa_party(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_wa_party(text) TO service_role;

-- The Edge Function takes orders through the same intake as the website.
GRANT EXECUTE ON FUNCTION public.lwb_web_order_intake(jsonb, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.lwb_web_catalog() TO service_role;

COMMIT;
