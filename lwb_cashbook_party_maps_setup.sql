-- LUXURY WRIST BRAND ERP — CASHBOOK USES THE TALLY PARTY MAPPING (sub-firm -> main party)
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- Accounts maps each Tally billing firm (Priya Traders, Rohit Traders ...) to its main party once, on
-- Accounts > Tally Party Mapping. The Cashbook Tally import then puts those firms' bills under the main
-- party by itself, so the same names are not mapped again at every import.
-- Read only: the Cashbook code word is checked as usual. Nothing is written.

CREATE OR REPLACE FUNCTION public.lwb_cashbook_party_maps(p_key text)
RETURNS TABLE (tally_key text, customer_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  RETURN QUERY
  SELECT m.tally_key::text, btrim(m.customer_name::text)
  FROM public.lwb_tally_party_map m
  WHERE m.customer_name IS NOT NULL AND btrim(m.customer_name::text) <> '';
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_cashbook_party_maps(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_cashbook_party_maps(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Result: one row, true.
SELECT 'cashbook party mapping' AS item, (to_regprocedure('public.lwb_cashbook_party_maps(text)') IS NOT NULL)::text AS ok;
