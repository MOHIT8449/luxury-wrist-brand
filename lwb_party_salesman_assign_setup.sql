-- LUXURY WRIST BRAND ERP — ASSIGN ANY SALESMAN TO A PARTY (PARTY MASTER + SALES TEAM SETUP)
--
-- RUN ONCE in Supabase SQL Editor, after lwb_sales_team_setup.sql. Safe to run again.
--
-- * Party Assignment and Party Master (form, bulk add and Excel "Salesman" column)
--   can pick any active SALES login. A salesman not set up yet in Sales Team
--   Setup > Salesmen is set up as FIELD (own parties only) on his first party.
--
-- No order, stock, bill, payment, ledger or Tally data is changed.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_assign_parties(p_customer_ids uuid[], p_salesman_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_n integer;
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF p_customer_ids IS NULL OR cardinality(p_customer_ids) = 0 THEN RAISE EXCEPTION 'Select at least one party'; END IF;
  IF p_salesman_id IS NULL THEN
    DELETE FROM public.lwb_party_salesman WHERE customer_id = ANY(p_customer_ids);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_salesmen s WHERE s.user_id = p_salesman_id) THEN
    IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_salesman_id
                   AND p.active = true AND lower(btrim(p.role)) IN ('sales','salesman')) THEN
      RAISE EXCEPTION 'This user is not an active SALES login';
    END IF;
    INSERT INTO public.lwb_salesmen(user_id, kind, updated_at, updated_by)
    VALUES (p_salesman_id, 'FIELD', now(), auth.uid());
  END IF;
  INSERT INTO public.lwb_party_salesman(customer_id, salesman_id, assigned_at, assigned_by)
  SELECT m.id, p_salesman_id, now(), auth.uid() FROM public.lwb_customer_master m WHERE m.id = ANY(p_customer_ids)
  ON CONFLICT (customer_id) DO UPDATE SET salesman_id = excluded.salesman_id, assigned_at = now(), assigned_by = auth.uid();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_assign_parties(uuid[], uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_assign_parties(uuid[], uuid) TO authenticated;

COMMIT;
