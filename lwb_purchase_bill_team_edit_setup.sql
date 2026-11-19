-- LUXURY WRIST BRAND ERP — SALES HEAD + ACCOUNTS MAY EDIT A PURCHASE BILL AND CHECK THE VEHICLE (19 Nov 2026)
--
-- Runs by itself when merged to main (after lwb_purchase_bill_edit_delete_setup.sql and
-- lwb_purchase_register_setup.sql). Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (19 Nov 2026): "Admin cannot do all the work". On the Purchase List the Sales Head
-- (MANAGER) and Accounts get the same work rights as Admin; Admin only verifies:
--   * Edit an old purchase bill (✏️ Bill): lwb_purchase_bill_preview / lwb_purchase_bill_edit now allow
--     an active Admin, Sales Head or Accounts (lwb_pbe_editor). DELETE of a bill stays Admin only.
--     Every edit is still kept in lwb_purchase_bill_log (who, when, reason, full old copy).
--   * Accounts cannot post a NEW Goods Inward. Only while lwb_purchase_bill_edit re-posts the corrected
--     bill (flag lwb.pbe_edit, local to that one transaction) lwb_post_goods_inward(_mrp) also accept
--     Accounts. The flag cannot be set from the website.
--   * Vehicle check (Check / Verify again, vehicle Time In / Out): lwb_pc_checker() now also Accounts.
--   * Bill PDF upload / replace / download: already allowed for Accounts and Sales Head
--     (lwb_documents_setup.sql, PURCHASE_BILL), nothing to change.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_pbe_editor()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','accounts'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pbe_editor() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_pc_checker()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT public.lwb_pr_role() IN ('admin','manager','warehouse','accounts');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pc_checker() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_pc_checker() TO authenticated;

DO $do$
DECLARE
  f regprocedure;
  d text;
  n text;
BEGIN
  -- Preview + Edit: Admin -> Admin / Sales Head / Accounts. Edit raises the one-transaction flag first.
  FOR f IN
    SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
    WHERE s.nspname = 'public' AND p.proname IN ('lwb_purchase_bill_preview','lwb_purchase_bill_edit')
  LOOP
    d := pg_get_functiondef(f);
    n := replace(d, 'public.lwb_pbe_admin()', 'public.lwb_pbe_editor()');
    n := replace(n, 'Only Admin can edit or delete a purchase bill', 'Only Admin, Sales Head or Accounts can edit a purchase bill');
    n := replace(n, 'Only Admin can edit a purchase bill', 'Only Admin, Sales Head or Accounts can edit a purchase bill');
    IF f::text LIKE 'lwb_purchase_bill_edit(%' AND n !~ 'lwb\.pbe_edit' THEN
      n := regexp_replace(n, '(IF NOT public\.lwb_pbe_editor\(\) THEN RAISE EXCEPTION [^;]*; END IF;)',
                          E'\\1\n  PERFORM set_config(''lwb.pbe_edit'', ''on'', true);');
    END IF;
    IF n <> d THEN EXECUTE n; RAISE NOTICE '% updated', f; END IF;
  END LOOP;

  -- Goods Inward posting: Accounts only while a bill edit is running.
  FOR f IN
    SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
    WHERE s.nspname = 'public' AND p.proname IN ('lwb_post_goods_inward','lwb_post_goods_inward_mrp')
  LOOP
    d := pg_get_functiondef(f);
    IF d ~ 'lwb\.pbe_edit' THEN CONTINUE; END IF;
    n := regexp_replace(d, '(IN\s*\(\s*''admin''\s*,\s*''manager''(\s*,\s*''warehouse'')?)(\s*\))',
                        E'\\1, CASE WHEN current_setting(''lwb.pbe_edit'', true) = ''on'' THEN ''accounts'' END\\3', 'i');
    IF n = d THEN RAISE WARNING '% has no IN (''admin'',''manager'') check: not changed', f; CONTINUE; END IF;
    EXECUTE n;
    RAISE NOTICE '% accepts Accounts during a bill edit', f;
  END LOOP;
END $do$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say "yes".
SELECT p.proname AS function_name,
       CASE WHEN p.proname IN ('lwb_purchase_bill_preview','lwb_purchase_bill_edit')
            THEN CASE WHEN pg_get_functiondef(p.oid) ~ 'lwb_pbe_editor' THEN 'yes' ELSE 'no' END
            ELSE CASE WHEN pg_get_functiondef(p.oid) ~ 'lwb\.pbe_edit' THEN 'yes' ELSE 'no' END END AS sales_head_accounts_ok
FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
WHERE s.nspname = 'public'
  AND p.proname IN ('lwb_purchase_bill_preview','lwb_purchase_bill_edit','lwb_post_goods_inward','lwb_post_goods_inward_mrp')
ORDER BY 1;
