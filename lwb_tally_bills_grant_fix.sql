-- LUXURY WRIST BRAND ERP — FIX "permission denied for function lwb_save_tally_bills" (17 Nov 2026)
--
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped or changed in saved bills.
--
-- Mohit: on Billing & Outstanding > Bills made, Accounts (Yogesh Patel) split one bill into 2 bills and Save
-- said "Could not save the bill: permission denied for function lwb_save_tally_bills". The function was
-- re-made today (lwb_tally_invoice_no_rules_setup.sql) without its own GRANT line, and on live the logged-in
-- role (authenticated) had no EXECUTE on it. Who may save is still checked inside the function
-- (lwb_tally_staff() = active Accounts or Admin), so the grant only lets the app reach that check.
--
-- 1. EXECUTE to authenticated (not anon) on every version of the Tally bill save + live check functions.
-- 2. Check as the authenticated role, with a real active Accounts login, that the save now gets past the
--    permission step (it is called with a PO id that does not exist, so it stops at "Order not found" and
--    nothing is written). The file fails if permission is still denied.

BEGIN;

DO $do$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS fn
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('lwb_save_tally_bills', 'lwb_save_tally_bill', 'lwb_save_tally_invoice',
                        'lwb_tally_staff', 'lwb_tally_no_check', 'lwb_tally_no_problems')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', r.fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', r.fn);
  END LOOP;
END
$do$;

-- the trigger function must still not be called by the app
DO $do$
BEGIN
  IF to_regprocedure('public.lwb_tally_invoice_no_guard()') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public.lwb_tally_invoice_no_guard() FROM PUBLIC, anon, authenticated;
  END IF;
END
$do$;

-- 2. check
DO $do$
DECLARE
  v_uid uuid;
  v_state text;
  v_msg text;
BEGIN
  IF to_regprocedure('public.lwb_save_tally_bills(uuid,date,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'lwb_save_tally_bills(uuid,date,jsonb,text) is missing on live';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.lwb_save_tally_bills(uuid,date,jsonb,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated still has no EXECUTE on lwb_save_tally_bills';
  END IF;

  SELECT p.id INTO v_uid FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) = 'accounts' ORDER BY p.id LIMIT 1;
  IF v_uid IS NULL THEN RETURN; END IF;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);
    SET LOCAL ROLE authenticated;
    PERFORM public.lwb_save_tally_bills('00000000-0000-0000-0000-000000000000'::uuid, current_date,
              '[{"firm":"TEST","no":"TEST-1","amount":1}]'::jsonb, NULL);
    v_state := 'none';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  RESET ROLE;

  IF v_state = '42501' AND v_msg ILIKE '%lwb_save_tally_bills%' THEN
    RAISE EXCEPTION 'Accounts login still gets: %', v_msg;
  END IF;
  IF v_msg ILIKE 'Only active Accounts%' THEN
    RAISE EXCEPTION 'Accounts login is refused by the role check: %', v_msg;
  END IF;
  -- expected: 'Order not found' (permission and role check passed, nothing written)
  -- 42501 on SET ROLE itself (runner may not switch role) is not a failure: the grant check above passed
END
$do$;

COMMIT;

SELECT 'save bills grant' AS step,
       has_function_privilege('authenticated', 'public.lwb_save_tally_bills(uuid,date,jsonb,text)', 'EXECUTE')::text AS ok;
