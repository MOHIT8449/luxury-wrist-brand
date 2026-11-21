-- LUXURY WRIST BRAND ERP — LEDGER EDIT / DUPLICATE / CANCEL / DELETE ALSO FOR ACCOUNTS
--
-- Runs by itself when merged to main (after lwb_ledger_admin_edit_setup.sql). Safe to run again.
-- Mohit (21 Nov 2026, decision card "Accounts: all"): Accounts logins may also edit, duplicate, cancel
-- and delete ledger entries (receipt, Tally bill, goods return), like Admin. Every change is still
-- written to lwb_ledger_edit_log with who did it. Manager / Cashier / others: still refused.
-- lwb_ledger_admin() is the one check every ledger edit function uses; it now allows admin + accounts.

CREATE OR REPLACE FUNCTION public.lwb_ledger_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','accounts'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_ledger_admin() FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

SELECT 'ledger edit for accounts' AS item,
  (pg_get_functiondef('public.lwb_ledger_admin()'::regprocedure) LIKE '%''accounts''%')::text AS ok;
