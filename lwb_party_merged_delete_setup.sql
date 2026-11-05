-- LUXURY WRIST BRAND ERP — DELETE A MERGED DUPLICATE PARTY
--
-- Runs by itself when merged to main. Safe to run again.
--
-- Mohit asked (5 Nov 2026): after "Merge", the duplicate party stays in Party
-- Master as "Merged" and Delete said "linked to other records". Now:
--   1. Admin can delete a Merged duplicate. Its POs, bills, payments and
--      ledger were already moved to the kept party by the merge. Any record
--      still linked to the duplicate by id moves to the kept party; where the
--      kept party already has its own (e.g. its own salesman), the duplicate's
--      extra copy is removed. The merge log (lwb_party_merges) stays.
--   2. Deleting the KEPT party while a merged duplicate still points to it is
--      refused with a clear message naming that duplicate.
--   3. Any other "linked" refusal now names the table it is linked to.
--
-- Changes only lwb_customer_master and the rows linked to the merged duplicate.
-- No order, bill, stock, ledger or Tally amount is changed.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_delete_customer(p_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_name text;
  v_key text;
  v_into uuid;
  v_kids text;
  v_tbl text;
  fk record;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND active = true AND lower(btrim(role)) = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only an active Admin can delete a party';
  END IF;

  SELECT btrim(customer_name) INTO v_name
  FROM public.lwb_customer_master WHERE id = p_id
  FOR UPDATE;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Party not found (already deleted?)';
  END IF;
  v_key := upper(v_name);

  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'lwb_customer_master'
               AND column_name = 'merged_into') THEN
    EXECUTE 'SELECT merged_into FROM public.lwb_customer_master WHERE id = $1' INTO v_into USING p_id;
    EXECUTE 'SELECT string_agg(coalesce(customer_code,'''') || '' '' || customer_name, '', '' ORDER BY customer_code)
             FROM public.lwb_customer_master WHERE merged_into = $1' INTO v_kids USING p_id;
    IF v_kids IS NOT NULL THEN
      RAISE EXCEPTION 'Party % is the kept party of merged duplicate %. Delete that merged party first, or keep this one (Edit > Status Active).', v_name, v_kids;
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM public.orders WHERE upper(btrim(customer_name)) = v_key) THEN
    RAISE EXCEPTION 'Party % has orders. It cannot be deleted; set it Inactive instead.', v_name;
  END IF;
  IF to_regclass('public.lwb_internal_bills') IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.lwb_internal_bills WHERE upper(btrim(customer_name)) = v_key
  ) THEN
    RAISE EXCEPTION 'Party % has ERP bills. It cannot be deleted; set it Inactive instead.', v_name;
  END IF;
  IF to_regclass('public.lwb_party_opening_balances') IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.lwb_party_opening_balances WHERE upper(btrim(customer_name)) = v_key
  ) THEN
    RAISE EXCEPTION 'Party % has an Opening Balance. Set it to 0 first, or set the party Inactive.', v_name;
  END IF;

  -- a merged duplicate: whatever is still linked by id goes to the kept party,
  -- or is removed where the kept party already has its own copy
  IF v_into IS NOT NULL THEN
    FOR fk IN
      SELECT cl.relname AS tbl, a.attname AS col
      FROM pg_constraint con
      JOIN pg_class cl ON cl.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = cl.relnamespace AND n.nspname = 'public'
      JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
      WHERE con.contype = 'f' AND con.confrelid = 'public.lwb_customer_master'::regclass
        AND array_length(con.conkey, 1) = 1
        AND cl.relname <> 'lwb_customer_master'
    LOOP
      BEGIN
        EXECUTE format('UPDATE public.%I SET %I = $1 WHERE %I = $2', fk.tbl, fk.col, fk.col)
          USING v_into, p_id;
      EXCEPTION WHEN unique_violation OR check_violation THEN
        EXECUTE format('DELETE FROM public.%I WHERE %I = $1', fk.tbl, fk.col) USING p_id;
      END;
    END LOOP;
  END IF;

  BEGIN
    DELETE FROM public.lwb_customer_master WHERE id = p_id;
  EXCEPTION WHEN foreign_key_violation THEN
    GET STACKED DIAGNOSTICS v_tbl = TABLE_NAME;
    RAISE EXCEPTION 'Party % is linked to other records (%). It cannot be deleted; set it Inactive instead.', v_name, coalesce(nullif(v_tbl, ''), 'another table');
  END;
  RETURN v_name;
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_delete_customer(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_delete_customer(uuid) TO authenticated;

COMMIT;
