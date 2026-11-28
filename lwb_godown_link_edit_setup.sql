-- LUXURY WRIST BRAND ERP — GODOWN GOOGLE MAPS LINK + ADDRESS: EDIT FROM LIVE TRACKING ⚙ SETTINGS (28 Nov 2026)
--
-- Mohit asked (28 Nov 2026): where do we set our location? The WhatsApp location sent to truck drivers uses the godown
-- Google Maps link and address (lwb_godown_map_link_setup.sql). Admin can now change both in Live Tracking > ⚙ Settings.
-- The message to drivers is in Hindi now, so the saved default address is written in Hindi too.
--
--   lwb_godown_link()                        Admin / Sales Head / Godown Manager / Accounts: {map_url, address}
--   lwb_godown_link_save(p_map_url, p_address) Admin only. Link must be https:// (Google Maps share link); address <= 200.
--
-- Safe to run again. Nothing is dropped or deleted.

BEGIN;

UPDATE public.lwb_tracking_settings
   SET godown_address = 'शेड नं. 15, देव कैंपस, राम कथा ग्राउंड, सिमाडा कैनाल, सूरत, गुजरात 395013'
 WHERE id = 1 AND godown_address = 'Shade No. 15, Dev Campus, Ram Katha Ground, Simada Canal, Surat, Gujarat 395013';

CREATE OR REPLACE FUNCTION public.lwb_godown_link()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles x WHERE x.id = auth.uid() AND x.active = true
                   AND lower(btrim(x.role)) IN ('admin','manager','warehouse','accounts')) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;
  SELECT jsonb_build_object('map_url', s.godown_map_url, 'address', s.godown_address) INTO v FROM public.lwb_tracking_settings s WHERE s.id = 1;
  RETURN coalesce(v, '{}'::jsonb);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_godown_link() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_godown_link() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_godown_link_save(p_map_url text, p_address text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE u text := nullif(btrim(coalesce(p_map_url, '')), ''); a text := nullif(btrim(coalesce(p_address, '')), '');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles x WHERE x.id = auth.uid() AND x.active = true AND lower(btrim(x.role)) = 'admin') THEN
    RAISE EXCEPTION 'Only Admin can change the godown location link';
  END IF;
  IF u IS NOT NULL AND (u !~ '^https://[^\s]+$' OR length(u) > 300) THEN
    RAISE EXCEPTION 'Paste the Google Maps share link (starts with https://)';
  END IF;
  IF a IS NOT NULL AND length(a) > 200 THEN RAISE EXCEPTION 'Address is too long (max 200 letters)'; END IF;
  UPDATE public.lwb_tracking_settings SET godown_map_url = u, godown_address = a WHERE id = 1;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_godown_link_save(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_godown_link_save(text, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
