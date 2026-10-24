-- LUXURY WRIST BRAND ERP — DELETE A PARTY FROM CUSTOMER / PARTY MASTER
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- Adds lwb_delete_customer(p_id): Admin only. Deletes one party from
-- lwb_customer_master, but ONLY when that party name has never been used
-- in an order, an ERP bill or an opening balance. A used party is never
-- deleted: mark it Inactive instead, so old records keep their name.
--
-- Changes only lwb_customer_master. No order, bill, stock, ledger or Tally
-- data is changed.

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

  BEGIN
    DELETE FROM public.lwb_customer_master WHERE id = p_id;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'Party % is linked to other records. It cannot be deleted; set it Inactive instead.', v_name;
  END;
  RETURN v_name;
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_delete_customer(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_delete_customer(uuid) TO authenticated;

COMMIT;
