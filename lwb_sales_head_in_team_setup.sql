-- LUXURY WRIST BRAND ERP — SALES HEADS IN SALES TEAM SETUP.
--
-- Run after lwb_salesman_party_scope_setup.sql. Safe to run again.
--
-- Mohit: the godown / brand Sales Heads (MANAGER logins, e.g. the Rajnigandha
-- Sales Head) must show in Sales Team Setup next to the salesmen: Salesmen tab,
-- Party Assignment dropdown, SKU Visibility, Monthly Targets and Morning Plan.
-- A Sales Head gets a lwb_salesmen row as OFFICE on his first save, so parties
-- and targets can be given to him. His access does not change here (Sales Heads
-- still see every party). Salesmen are unchanged.
--
-- No order, bill, stock, payment, ledger or Tally data is changed.

BEGIN;

-- SALES logins and Sales Heads (MANAGER) with their setup and party count.
CREATE OR REPLACE FUNCTION public.lwb_sales_team()
RETURNS TABLE (user_id uuid, full_name text, role text, active boolean, mobile text, kind text, area text, parties bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
#variable_conflict use_column
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  RETURN QUERY
    SELECT p.id, p.full_name::text, lower(btrim(p.role))::text, p.active, p.mobile::text, s.kind, s.area,
      (SELECT count(*) FROM public.lwb_party_salesman a WHERE a.salesman_id = p.id)
    FROM public.user_profiles p
    LEFT JOIN public.lwb_salesmen s ON s.user_id = p.id
    WHERE lower(btrim(p.role)) IN ('sales','salesman','manager') OR s.user_id IS NOT NULL
    ORDER BY p.active DESC, CASE WHEN lower(btrim(p.role)) = 'manager' THEN 0 ELSE 1 END, p.full_name;
END;
$fn$;

-- Salesman row for a SALES login (FIELD) or a Sales Head (OFFICE). false for other roles.
CREATE OR REPLACE FUNCTION public.lwb_ensure_salesman(p_user_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_role text;
BEGIN
  IF p_user_id IS NULL THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_salesmen s WHERE s.user_id = p_user_id) THEN RETURN true; END IF;
  SELECT lower(btrim(coalesce(p.role,''))) INTO v_role FROM public.user_profiles p WHERE p.id = p_user_id;
  IF v_role IS NULL OR v_role NOT IN ('sales','salesman','manager') THEN RETURN false; END IF;
  INSERT INTO public.lwb_salesmen(user_id, kind, updated_at, updated_by)
  VALUES (p_user_id, CASE WHEN v_role = 'manager' THEN 'OFFICE' ELSE 'FIELD' END, now(), auth.uid())
  ON CONFLICT (user_id) DO NOTHING;
  RETURN true;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_ensure_salesman(uuid) FROM PUBLIC, anon, authenticated;

-- Salesmen tab Save: a Sales Head keeps OFFICE, only his area / route is saved.
CREATE OR REPLACE FUNCTION public.lwb_save_salesman(p_user_id uuid, p_kind text, p_area text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_kind text := upper(btrim(coalesce(p_kind,''))); v_role text;
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  SELECT lower(btrim(coalesce(p.role,''))) INTO v_role FROM public.user_profiles p WHERE p.id = p_user_id;
  IF v_role IS NULL OR v_role NOT IN ('sales','salesman','manager') THEN
    RAISE EXCEPTION 'Give this user the SALES or Sales Head role in Manage Users first';
  END IF;
  IF v_role = 'manager' THEN v_kind := 'OFFICE'; END IF;
  IF v_kind NOT IN ('FIELD','OFFICE') THEN RAISE EXCEPTION 'Type must be Field or Office'; END IF;
  IF length(coalesce(p_area,'')) > 120 THEN RAISE EXCEPTION 'Area is too long'; END IF;
  INSERT INTO public.lwb_salesmen(user_id, kind, area, updated_at, updated_by)
  VALUES (p_user_id, v_kind, nullif(btrim(p_area),''), now(), auth.uid())
  ON CONFLICT (user_id) DO UPDATE SET kind = excluded.kind, area = excluded.area, updated_at = now(), updated_by = auth.uid();
END;
$fn$;

-- Party Assignment: any active SALES login or Sales Head.
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
                   AND p.active = true AND lower(btrim(p.role)) IN ('sales','salesman','manager')) THEN
      RAISE EXCEPTION 'This user is not an active Salesman or Sales Head login';
    END IF;
    PERFORM public.lwb_ensure_salesman(p_salesman_id);
  END IF;
  INSERT INTO public.lwb_party_salesman(customer_id, salesman_id, assigned_at, assigned_by)
  SELECT m.id, p_salesman_id, now(), auth.uid() FROM public.lwb_customer_master m WHERE m.id = ANY(p_customer_ids)
  ON CONFLICT (customer_id) DO UPDATE SET salesman_id = excluded.salesman_id, assigned_at = now(), assigned_by = auth.uid();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sales_team(), public.lwb_save_salesman(uuid,text,text), public.lwb_assign_parties(uuid[],uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sales_team(), public.lwb_save_salesman(uuid,text,text), public.lwb_assign_parties(uuid[],uuid) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
