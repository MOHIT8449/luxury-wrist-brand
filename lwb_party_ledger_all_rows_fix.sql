-- LUXURY WRIST BRAND ERP — PARTY LEDGER: EVERY ROW REACHES THE SCREEN (no 1000-row cut)
--
-- Runs by itself when merged to main (after lwb_brand_money_setup.sql). Safe to run again. Read only.
--
-- Mohit (23 Nov 2026): MANSHI MARKETING (KATARGAM) Rs 1,11,600 cash party payment was in the Day book
-- but not in the party ledger; "such mistakes keep repeating".
-- Cause: lwb_party_ledger_b() returns one row per ledger entry. The website API (PostgREST) sends at most
-- 1000 rows of such a call. The whole ledger grew to 1039 rows on 23 Nov 2026, so the last rows (the newest
-- party payments, credit notes, payment collections, driver money ...) were silently cut: 12 of the 31
-- party payments of 23 Nov were missing from Ledger & Outstanding, Party & Collections, Party Ledger and
-- Sales Outstanding. The data itself was always saved correctly (lwb_tally_payments).
-- Fix: the same rows as ONE json value (one row = no cut), whatever the ledger size.
--   lwb_party_ledger_bj()  = jsonb array of lwb_party_ledger_b()  (same columns, same viewer rule)

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_party_ledger_bj()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $fn$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'entry_date', l.entry_date, 'entry_kind', l.entry_kind, 'customer_name', l.customer_name,
           'ref_no', l.ref_no, 'order_no', l.order_no, 'debit', l.debit, 'credit', l.credit,
           'note', l.note, 'created_at', l.created_at, 'company_id', l.company_id)), '[]'::jsonb)
  FROM public.lwb_party_ledger_b() l;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_ledger_bj() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_ledger_bj() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
