-- LUXURY WRIST BRAND ERP — THE FULL TALLY PARTY LIST, KEPT FOR MAPPING
--
-- RUN ONCE in Supabase SQL Editor, after lwb_cashbook_tally_check_setup.sql. Safe to run again.
--
-- Accounts adds the Tally party names once (paste, or the List of Ledgers / Sales Register file) on
-- Accounts > Tally Party Mapping. The names stay saved, one row each, and Accounts sets the main ERP party
-- of each row (the links are the same lwb_tally_party_map rows Tally Bill Check uses).
-- Only names are stored. Nothing is posted to Tally, the party ledger, stock or GST.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_tally_parties (
  tally_key   text PRIMARY KEY,
  tally_name  text NOT NULL,
  added_at    timestamptz NOT NULL DEFAULT now(),
  added_by    uuid
);
ALTER TABLE public.lwb_tally_parties ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_tally_parties FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_tally_party_list()
RETURNS TABLE (tally_key text, tally_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_check_user() THEN
    RAISE EXCEPTION 'Only Accounts or Admin can see the Tally party list';
  END IF;
  RETURN QUERY SELECT p.tally_key, p.tally_name FROM public.lwb_tally_parties p ORDER BY p.tally_name;
END;
$fn$;

-- p_names: Tally party names (up to 5000). Returns how many were new.
CREATE OR REPLACE FUNCTION public.lwb_tally_add_parties(p_names text[])
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_n integer;
BEGIN
  IF NOT public.lwb_tally_check_user() THEN
    RAISE EXCEPTION 'Only Accounts or Admin can add Tally parties';
  END IF;
  IF p_names IS NULL OR cardinality(p_names) = 0 THEN RETURN 0; END IF;
  IF cardinality(p_names) > 5000 THEN RAISE EXCEPTION 'At most 5000 names at a time'; END IF;
  INSERT INTO public.lwb_tally_parties (tally_key, tally_name, added_by)
  SELECT DISTINCT ON (k) k, n, auth.uid()
  FROM (SELECT btrim(regexp_replace(x, '\s+', ' ', 'g')) AS n,
               btrim(regexp_replace(upper(x), '[^A-Z0-9]+', ' ', 'g')) AS k
        FROM unnest(p_names) x) s
  WHERE k <> '' AND length(n) <= 200
  ON CONFLICT (tally_key) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;

-- removes a name from the list and its main-party link
CREATE OR REPLACE FUNCTION public.lwb_tally_remove_party(p_name text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_key text := btrim(regexp_replace(upper(coalesce(p_name, '')), '[^A-Z0-9]+', ' ', 'g'));
BEGIN
  IF NOT public.lwb_tally_check_user() THEN
    RAISE EXCEPTION 'Only Accounts or Admin can remove Tally parties';
  END IF;
  DELETE FROM public.lwb_tally_parties WHERE tally_key = v_key;
  DELETE FROM public.lwb_tally_party_map WHERE tally_key = v_key;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_tally_party_list(), public.lwb_tally_add_parties(text[]), public.lwb_tally_remove_party(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_tally_party_list(), public.lwb_tally_add_parties(text[]), public.lwb_tally_remove_party(text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: both rows true.
SELECT 'tally party list' AS item, (to_regclass('public.lwb_tally_parties') IS NOT NULL)::text AS ok
UNION ALL SELECT 'add tally parties', (to_regprocedure('public.lwb_tally_add_parties(text[])') IS NOT NULL)::text;
