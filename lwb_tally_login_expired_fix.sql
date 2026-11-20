-- LUXURY WRIST BRAND ERP — TALLY BILL: CLEAR "LOGIN EXPIRED" MESSAGE (Mohit, 20 Nov 2026)
--
-- Yogesh (Accounts) got "Only active Accounts or Admin can enter the Tally bill" on Save bill.
-- Checked on the live database: his login is role accounts, active, and the same id as his auth user;
-- he saved 33 Tally bills today (last 7:28 PM). The save that failed came with NO login at all
-- (the browser's login had run out, so the call went as a guest), and the role check then said "not Accounts".
--
-- This file: the Tally bill save functions first check for a login and say
--   "Login expired: please log in again"
-- instead of the wrong role message. Changed in place from the live text (later live patches kept).

BEGIN;

DO $fix$
DECLARE f record; v_def text; v_new text; v_n integer := 0;
BEGIN
  FOR f IN SELECT p.oid, p.proname FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
             AND p.proname IN ('lwb_save_tally_bills','lwb_save_tally_bill','lwb_bill_mismatch_note') LOOP
    v_def := pg_get_functiondef(f.oid);
    CONTINUE WHEN position('Login expired: please log in again' IN v_def) > 0;
    v_new := replace(v_def, 'IF NOT public.lwb_tally_staff() THEN',
      'IF auth.uid() IS NULL THEN' || chr(10) || '    RAISE EXCEPTION ''Login expired: please log in again'';' || chr(10) ||
      '  END IF;' || chr(10) || '  IF NOT public.lwb_tally_staff() THEN');
    IF v_new <> v_def THEN EXECUTE v_new; v_n := v_n + 1; END IF;
  END LOOP;
  RAISE NOTICE 'Tally functions changed: %', v_n;
END
$fix$;

-- Stop here (nothing kept) if a save function still has the role check without the login check.
DO $check$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.proname, pg_get_functiondef(p.oid) d FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
             AND p.proname IN ('lwb_save_tally_bills','lwb_save_tally_bill','lwb_bill_mismatch_note') LOOP
    IF position('lwb_tally_staff()' IN r.d) > 0 AND position('Login expired: please log in again' IN r.d) = 0 THEN
      RAISE EXCEPTION '% has no login check', r.proname;
    END IF;
  END LOOP;
  IF to_regprocedure('public.lwb_save_tally_bills(uuid,date,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'lwb_save_tally_bills not found';
  END IF;
END
$check$;

COMMIT;

NOTIFY pgrst, 'reload schema';
