-- LUXURY WRIST BRAND ERP — CASHBOOK CODE WORD
--
-- RUN ONCE in Supabase SQL Editor (after lwb_cashbook_secure_setup.sql). Safe to run again.
--
-- Mohit (26 Oct 2026): open the Cashbook with a short code word (e.g. 401) typed in the ERP
-- Module Search or on the Cashbook page, instead of a long secret link. The code is the same
-- key as the link: only its SHA-256 is stored, every Cashbook function checks it, and the
-- login must still be Admin or ticked for Cashbook. This only lowers the minimum length to 3.
-- Admin changes it in Cashbook > Code word.

CREATE OR REPLACE FUNCTION public.lwb_cashbook_set_link(p_key text, p_new_key text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) OR NOT public.lwb_cashbook_erp_admin() THEN
    RAISE EXCEPTION 'Only an ERP Admin inside the Cashbook can change the code word.';
  END IF;
  IF coalesce(p_new_key, '') !~ '^[A-Za-z0-9_-]{3,64}$' THEN
    RAISE EXCEPTION 'The code word must be 3 to 64 letters or numbers.';
  END IF;
  INSERT INTO public.lwb_cashbook (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  UPDATE public.lwb_cashbook SET link_key_hash = encode(sha256(convert_to(p_new_key, 'UTF8')), 'hex') WHERE id = 1;
  INSERT INTO public.lwb_cashbook_audit (by_user, by_name, action)
  VALUES (auth.uid(), (SELECT nullif(btrim(p.full_name), '') FROM public.user_profiles p WHERE p.id = auth.uid()), 'code word changed');
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_cashbook_set_link(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_cashbook_set_link(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Result: one row, true.
SELECT 'cashbook code word' AS item, (to_regprocedure('public.lwb_cashbook_set_link(text, text)') IS NOT NULL)::text AS ok;
