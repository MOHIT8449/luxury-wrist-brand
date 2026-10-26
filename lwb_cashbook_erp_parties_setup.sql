-- LUXURY WRIST BRAND ERP — PARTY MASTER PARTIES IN THE CASHBOOK
--
-- RUN ONCE in Supabase SQL Editor (after lwb_cashbook_secure_setup.sql). Safe to run again.
--
-- Mohit (26 Oct 2026): new ERP Party Master parties should show in the Cashbook party list.
-- The Cashbook reads the party names through this function (Cashbook users with the link key
-- only) and adds the ones it does not have yet to its Cash In list. Nothing is written here.

CREATE OR REPLACE FUNCTION public.lwb_cashbook_erp_parties(p_key text)
RETURNS TABLE (customer_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  RETURN QUERY
  SELECT DISTINCT btrim(m.customer_name::text) FROM public.lwb_customer_master m
  WHERE nullif(btrim(m.customer_name::text), '') IS NOT NULL
  ORDER BY 1;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_cashbook_erp_parties(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_cashbook_erp_parties(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Result: one row, true.
SELECT 'party master for cashbook' AS item,
  (to_regprocedure('public.lwb_cashbook_erp_parties(text)') IS NOT NULL)::text AS ok;
