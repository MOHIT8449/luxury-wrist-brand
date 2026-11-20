-- LUXURY WRIST BRAND ERP — CASHIER ROLE + ACCOUNTS (TALLY) SPLIT (Mohit, 20 Nov 2026)
--
-- Accounts is split by work:
--   Accounts (Tally) = role 'accounts' (Yogesh bhai): Tally bills, Bills made, bank check (verify bank /
--     UPI / cheque entries, bank statement), GST, PO changes. Also Cash In / Out, Close Day, Party payment.
--   Cashier = NEW role 'cashier': Cash In, Cash Out, Bank Deposit, Close Day, Day book, Cheques,
--     Cash handover, Staff advance, Vehicle expense, Party payment (cash / cheque / UPI received).
--     No Tally, no GST, no bank check, no bank statement, no Heads & Banks / salary setup.
--   Party & Collections (To collect, Payments, Ledger, Returns, ACRS) = Admin page.
--
-- What this file does (live functions are changed IN PLACE from their current text, so later live
-- patches are kept; a function that is not there is skipped):
--   1. user_profiles_role_check also allows 'cashier'; lwb_admin_set_user_role / lwb_admin_create_user take it.
--   2. lwb_acc_user() (cash book RPCs) = Admin / Accounts / Cashier. New lwb_acc_tally_user() = Admin / Accounts,
--      lwb_acc_cashier() = Cashier.
--   3. Tally-only: Heads & Banks, salary setup, bank statement (lwb_bank_*) and bank check use lwb_acc_tally_user().
--   4. Bank check is no longer Admin only: Accounts (Tally) verifies bank / UPI / cheque entries and books the
--      bank statement too (Mohit: "bank ki entry verify karte hain"). The bell goes to Admin + Accounts.
--      lwb_acc_dashboard returns can_check.
--   5. Party payment for the Cashier: lwb_party_billing / lwb_party_receive / lwb_party_return_list.
--   6. Hired vehicle list readable by the Cashier (Vehicles tab).

BEGIN;

-- 1. role check ---------------------------------------------------------------------------------------
DO $cashier_role$
DECLARE v_expr text;
BEGIN
  SELECT pg_get_expr(c.conbin, c.conrelid) INTO v_expr
  FROM pg_constraint c
  WHERE c.conrelid = 'public.user_profiles'::regclass AND c.conname = 'user_profiles_role_check' AND c.contype = 'c';
  IF v_expr IS NOT NULL AND position('cashier' IN v_expr) = 0 THEN
    EXECUTE 'ALTER TABLE public.user_profiles DROP CONSTRAINT user_profiles_role_check';
    EXECUTE format('ALTER TABLE public.user_profiles ADD CONSTRAINT user_profiles_role_check CHECK ((%s) OR (lower(btrim(role)) = %L))',
                   v_expr, 'cashier');
  END IF;
END
$cashier_role$;

-- 2. who is who -----------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin','cashier'));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_tally_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin'));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_cashier()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) = 'cashier');
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_user(), public.lwb_acc_tally_user(), public.lwb_acc_cashier() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_user(), public.lwb_acc_tally_user(), public.lwb_acc_cashier() TO authenticated;

-- In-place text change of every public function with this name (all overloads). Returns how many changed.
-- A function that already has the new text is left as it is (running the file again changes nothing).
CREATE OR REPLACE FUNCTION public.lwb_tmp_fn_patch(p_name text, p_from text, p_to text)
RETURNS integer LANGUAGE plpgsql SET search_path = ''
AS $fn$
DECLARE f record; v_def text; v_n integer := 0;
BEGIN
  FOR f IN SELECT p.oid FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = p_name AND p.prokind = 'f' LOOP
    v_def := pg_get_functiondef(f.oid);
    -- (only matters when the new text holds the old one, e.g. can_check added after is_admin)
    IF position(p_from IN v_def) > 0 AND NOT (position(p_from IN p_to) > 0 AND position(p_to IN v_def) > 0) THEN
      EXECUTE replace(v_def, p_from, p_to);
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END
$fn$;

DO $patch$
DECLARE n text;
BEGIN
  -- 1. role setters take 'cashier'
  PERFORM public.lwb_tmp_fn_patch('lwb_admin_set_user_role', '''transport'',''driver'')', '''transport'',''driver'',''cashier'')');
  PERFORM public.lwb_tmp_fn_patch('lwb_admin_create_user',   '''transport'',''driver'')', '''transport'',''driver'',''cashier'')');

  -- 3. Tally only (not the Cashier)
  FOREACH n IN ARRAY ARRAY['lwb_acc_save_bank','lwb_acc_save_category','lwb_acc_reopen_day','lwb_acc_verify_line',
      'lwb_acc_unverify_line','lwb_acc_save_staff','lwb_acc_save_salaries','lwb_bank_automatch','lwb_bank_candidates',
      'lwb_bank_link','lwb_bank_stmt_assign','lwb_bank_stmt_import','lwb_bank_stmt_list','lwb_bank_stmt_remove_import',
      'lwb_bank_stmt_undo','lwb_bank_stmt_open_count'] LOOP
    PERFORM public.lwb_tmp_fn_patch(n, 'public.lwb_acc_user()', 'public.lwb_acc_tally_user()');
  END LOOP;

  -- 4. bank check: Admin or Accounts
  FOREACH n IN ARRAY ARRAY['lwb_acc_verify_line','lwb_acc_unverify_line','lwb_bank_stmt_import','lwb_bank_stmt_remove_import',
      'lwb_bank_stmt_assign','lwb_bank_stmt_undo','lwb_bank_stmt_list'] LOOP
    PERFORM public.lwb_tmp_fn_patch(n, 'public.lwb_acc_admin()', 'public.lwb_acc_tally_user()');
  END LOOP;
  PERFORM public.lwb_tmp_fn_patch('lwb_acc_verify_line', 'Only Admin checks the bank', 'Only Admin / Accounts check the bank');
  PERFORM public.lwb_tmp_fn_patch('lwb_acc_unverify_line', 'Only Admin checks the bank', 'Only Admin / Accounts check the bank');
  PERFORM public.lwb_tmp_fn_patch('lwb_bank_stmt_import', 'Only Admin uploads', 'Only Admin / Accounts upload');
  PERFORM public.lwb_tmp_fn_patch('lwb_bank_stmt_remove_import', 'Only Admin can remove', 'Only Admin / Accounts can remove');
  PERFORM public.lwb_tmp_fn_patch('lwb_bank_stmt_assign', 'Only Admin books', 'Only Admin / Accounts book');
  PERFORM public.lwb_tmp_fn_patch('lwb_bank_stmt_undo', 'Only Admin can undo', 'Only Admin / Accounts can undo');
  PERFORM public.lwb_tmp_fn_patch('lwb_acc_dashboard', '''is_admin'', public.lwb_acc_admin(),',
    '''is_admin'', public.lwb_acc_admin(), ''can_check'', public.lwb_acc_tally_user(), ''is_cashier'', public.lwb_acc_cashier(),');
  PERFORM public.lwb_tmp_fn_patch('lwb_acc_ping_admins', 'lower(btrim(p.role)) = ''admin'' LOOP',
    'lower(btrim(p.role)) IN (''admin'',''accounts'') LOOP');

  -- 5. Party payment by the Cashier
  FOREACH n IN ARRAY ARRAY['lwb_party_billing','lwb_party_receive','lwb_party_return_list'] LOOP
    PERFORM public.lwb_tmp_fn_patch(n, 'NOT public.lwb_tally_staff()', 'NOT (public.lwb_tally_staff() OR public.lwb_acc_cashier())');
  END LOOP;

  -- 6. Vehicles tab: hired vehicles
  PERFORM public.lwb_tmp_fn_patch('lwb_hired_reader', '(''accounts'',''admin'',''manager'')', '(''accounts'',''admin'',''manager'',''cashier'')');
END
$patch$;

-- Stop here (nothing kept) if a function that exists still has the old rule.
DO $check$
DECLARE r record; v_bad text := '';
BEGIN
  FOR r IN SELECT p.proname, pg_get_functiondef(p.oid) d FROM pg_proc p
           WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f' AND p.proname IN
             ('lwb_acc_verify_line','lwb_acc_unverify_line','lwb_acc_save_bank','lwb_acc_save_category','lwb_bank_stmt_list',
              'lwb_bank_stmt_import','lwb_bank_stmt_assign','lwb_party_billing','lwb_party_receive','lwb_admin_set_user_role',
              'lwb_admin_create_user','lwb_acc_dashboard') LOOP
    IF r.proname IN ('lwb_acc_verify_line','lwb_acc_unverify_line','lwb_bank_stmt_import','lwb_bank_stmt_assign')
       AND position('lwb_acc_admin()' IN r.d) > 0 THEN v_bad := v_bad || r.proname || ' still Admin only; '; END IF;
    IF r.proname IN ('lwb_acc_save_bank','lwb_acc_save_category','lwb_bank_stmt_list') AND position('lwb_acc_user()' IN r.d) > 0
      THEN v_bad := v_bad || r.proname || ' still open to Cashier; '; END IF;
    IF r.proname IN ('lwb_party_billing','lwb_party_receive') AND position('lwb_acc_cashier()' IN r.d) = 0
      THEN v_bad := v_bad || r.proname || ' not open to Cashier; '; END IF;
    IF r.proname IN ('lwb_admin_set_user_role','lwb_admin_create_user') AND position('''cashier''' IN r.d) = 0
      THEN v_bad := v_bad || r.proname || ' does not take cashier; '; END IF;
    IF r.proname = 'lwb_acc_dashboard' AND position('can_check' IN r.d) = 0
      THEN v_bad := v_bad || 'lwb_acc_dashboard has no can_check; '; END IF;
  END LOOP;
  IF v_bad <> '' THEN RAISE EXCEPTION 'Cashier setup not complete: %', v_bad; END IF;
END
$check$;

REVOKE ALL ON FUNCTION public.lwb_tmp_fn_patch(text,text,text) FROM PUBLIC, anon, authenticated;
DROP FUNCTION public.lwb_tmp_fn_patch(text,text,text);

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'role check allows cashier' AS item,
       (NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = 'public.user_profiles'::regclass
                    AND c.conname = 'user_profiles_role_check')
        OR EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = 'public.user_profiles'::regclass
                   AND c.conname = 'user_profiles_role_check' AND pg_get_constraintdef(c.oid) LIKE '%cashier%'))::text AS ok
UNION ALL SELECT 'tally user helper', (to_regprocedure('public.lwb_acc_tally_user()') IS NOT NULL)::text
UNION ALL SELECT 'cashier helper', (to_regprocedure('public.lwb_acc_cashier()') IS NOT NULL)::text;
