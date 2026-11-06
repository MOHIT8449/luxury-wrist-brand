-- LUXURY WRIST BRAND ERP — GODOWN MANAGER MAY ENTER A PURCHASE BILL (Goods Inward).
--
-- RUN ONCE in Supabase SQL Editor (after lwb_purchase_mrp_billing_setup.sql). Safe to run again.
--
-- Mohit (6 Nov 2026): when no Admin / Sales Head / purchase person is there, the
-- Godown Manager (role WAREHOUSE) enters the purchase bill himself: supplier, invoice,
-- vehicle, driver, SKU lines, photos. Stock goes up as for any Goods Inward.
--
-- lwb_post_goods_inward was made outside this repo, so its first role check
-- IN ('admin','manager') is widened to IN ('admin','manager','warehouse') in place.
-- Nothing else in the function is changed. lwb_post_goods_inward_mrp (Rajnigandha MRP bills)
-- gets the same. If a function does not have that check, it is left as it is and the
-- result below says so: send that result and it will be fixed by hand.
-- No bill, stock or ledger data is changed.

DO $do$
DECLARE
  f regprocedure;
  d text;
  n text;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
    WHERE s.nspname = 'public' AND p.proname IN ('lwb_post_goods_inward','lwb_post_goods_inward_mrp')
  LOOP
    d := pg_get_functiondef(f);
    IF d ~* '''admin''\s*,\s*''manager''\s*,\s*''warehouse''' THEN
      RAISE NOTICE '% already lets the Godown Manager post', f;
      CONTINUE;
    END IF;
    -- first IN ('admin','manager') = the "who may post" check at the top
    n := regexp_replace(d, '(IN\s*\(\s*''admin''\s*,\s*''manager'')(\s*\))', '\1,''warehouse''\2', 'i');
    IF n = d THEN
      RAISE WARNING '% has no IN (''admin'',''manager'') check: not changed', f;
      CONTINUE;
    END IF;
    n := replace(n, 'Only active Admin or Manager can post Goods Inward', 'Only active Admin, Sales Head or Godown Manager can post Goods Inward');
    EXECUTE n;
    RAISE NOTICE '% now lets the Godown Manager post', f;
  END LOOP;
END $do$;

NOTIFY pgrst, 'reload schema';

-- Result: both rows should say "yes". "no" = send this result (screenshot).
SELECT p.proname AS function_name,
       CASE WHEN pg_get_functiondef(p.oid) ~* '''admin''\s*,\s*''manager''\s*,\s*''warehouse''' THEN 'yes' ELSE 'no' END AS godown_manager_can_post,
       CASE WHEN p.prosecdef THEN 'definer' ELSE 'invoker' END AS runs_as
FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
WHERE s.nspname = 'public' AND p.proname IN ('lwb_post_goods_inward','lwb_post_goods_inward_mrp')
ORDER BY 1;
