-- LUXURY WRIST BRAND ERP — EVERY SALESMAN IN SALES TEAM SETUP, AND A SALESMAN
-- SEES ONLY HIS OWN (ASSIGNED) PARTIES EVERYWHERE.
--
-- Run after lwb_sales_team_setup.sql, lwb_order_entry_rules_setup.sql and
-- lwb_complaint_box_setup.sql. Safe to run again.
--
-- 1. Every SALES login is listed in lwb_salesmen (as FIELD = own parties only,
--    which is already how a not-set-up salesman is treated), and a new SALES
--    login is added by itself. So every salesman shows in the SKU Visibility,
--    Monthly Targets and Morning Plan tick boxes, not only the ones that
--    already had a party. A salesman set to OFFICE stays OFFICE.
-- 2. SKU visibility / targets / plan notes accept any active SALES login.
-- 3. Field salesman, in the database:
--    * Tax invoices, sales returns (+ items) and payment collections: only the
--      ones of his own orders / parties (he submitted the collection, or the
--      invoice's order is visible to him).
--    * Complaint Box: the party must be one of his parties and the PO number
--      one of his orders.
--    Party Master, orders, order items, Party Call List, Party Ledger and
--    outstanding were already limited by lwb_sales_team_setup.sql.
--
-- Other roles (Admin, Sales Head, Accounts, Godown, Driver...) are not affected.
-- No order, bill, stock, payment, ledger or Tally data is changed.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Every SALES login in lwb_salesmen
-- ---------------------------------------------------------------------------
INSERT INTO public.lwb_salesmen(user_id, kind, updated_at)
SELECT p.id, 'FIELD', now() FROM public.user_profiles p
WHERE lower(btrim(coalesce(p.role,''))) IN ('sales','salesman')
ON CONFLICT (user_id) DO NOTHING;

-- Adds the salesman row for a SALES login (no-op for other roles / existing rows).
CREATE OR REPLACE FUNCTION public.lwb_ensure_salesman(p_user_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF p_user_id IS NULL THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_salesmen s WHERE s.user_id = p_user_id) THEN RETURN true; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user_id
                 AND lower(btrim(coalesce(p.role,''))) IN ('sales','salesman')) THEN
    RETURN false;
  END IF;
  INSERT INTO public.lwb_salesmen(user_id, kind, updated_at, updated_by)
  VALUES (p_user_id, 'FIELD', now(), auth.uid()) ON CONFLICT (user_id) DO NOTHING;
  RETURN true;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_ensure_salesman(uuid) FROM PUBLIC, anon, authenticated;

-- New SALES login (or role changed to SALES) -> salesman row. Never blocks the login save.
CREATE OR REPLACE FUNCTION public.lwb_user_salesman_autoadd()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF lower(btrim(coalesce(NEW.role,''))) IN ('sales','salesman') THEN
    BEGIN
      PERFORM public.lwb_ensure_salesman(NEW.id);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_user_salesman_autoadd() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS zz_lwb_user_salesman_autoadd ON public.user_profiles;
CREATE TRIGGER zz_lwb_user_salesman_autoadd
AFTER INSERT OR UPDATE OF role ON public.user_profiles
FOR EACH ROW EXECUTE FUNCTION public.lwb_user_salesman_autoadd();

-- ---------------------------------------------------------------------------
-- 2. Sales Team Setup saves accept any SALES login
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_set_sku_visibility(p_sku_name text, p_mode text, p_salesmen uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_key text := upper(btrim(coalesce(p_sku_name,''))); v_mode text := upper(btrim(coalesce(p_mode,''))); v_id uuid;
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF v_key = '' THEN RAISE EXCEPTION 'Select an SKU'; END IF;
  IF v_mode NOT IN ('ALL','ONLY','HIDE') THEN RAISE EXCEPTION 'Invalid visibility'; END IF;
  IF v_mode <> 'ALL' AND (p_salesmen IS NULL OR cardinality(p_salesmen) = 0) THEN RAISE EXCEPTION 'Select at least one salesman'; END IF;
  IF v_mode <> 'ALL' THEN
    FOREACH v_id IN ARRAY p_salesmen LOOP
      IF NOT public.lwb_ensure_salesman(v_id) THEN RAISE EXCEPTION 'This user is not a SALES login'; END IF;
    END LOOP;
  END IF;
  DELETE FROM public.lwb_sku_salesman_rules WHERE sku_key = v_key;
  IF v_mode <> 'ALL' THEN
    INSERT INTO public.lwb_sku_salesman_rules(sku_key, salesman_id, rule, updated_at, updated_by)
    SELECT v_key, s.user_id, v_mode, now(), auth.uid() FROM public.lwb_salesmen s WHERE s.user_id = ANY(p_salesmen);
  END IF;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_save_sales_targets(p_month date, p_rows jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_month date := date_trunc('month', p_month)::date; r jsonb; v_sm uuid; v_n integer := 0;
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF p_month IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'Select a month'; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_sm := nullif(r->>'salesman_id','')::uuid;
    IF v_sm IS NOT NULL AND NOT public.lwb_ensure_salesman(v_sm) THEN
      RAISE EXCEPTION 'This user is not a SALES login';
    END IF;
    IF coalesce((r->>'target_amount')::numeric,0) < 0 OR coalesce((r->>'target_cases')::numeric,0) < 0 THEN
      RAISE EXCEPTION 'Target cannot be negative';
    END IF;
    DELETE FROM public.lwb_sales_targets t WHERE t.month = v_month AND t.salesman_id IS NOT DISTINCT FROM v_sm;
    INSERT INTO public.lwb_sales_targets(month, salesman_id, target_amount, target_cases, updated_at, updated_by)
    VALUES (v_month, v_sm, coalesce((r->>'target_amount')::numeric,0), coalesce((r->>'target_cases')::numeric,0), now(), auth.uid());
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_add_sales_plan_note(p_date date, p_salesman_id uuid, p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF btrim(coalesce(p_note,'')) = '' THEN RAISE EXCEPTION 'Enter the note'; END IF;
  IF p_salesman_id IS NOT NULL AND NOT public.lwb_ensure_salesman(p_salesman_id) THEN
    RAISE EXCEPTION 'This user is not a SALES login';
  END IF;
  INSERT INTO public.lwb_sales_plan_notes(plan_date, salesman_id, note, created_by)
  VALUES (coalesce(p_date, (now() AT TIME ZONE 'Asia/Kolkata')::date), p_salesman_id, left(btrim(p_note),500), auth.uid());
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. Field salesman: invoices, sales returns and payment collections of his own parties only
-- ---------------------------------------------------------------------------
-- An order the signed-in user may see (runs the orders RLS of the caller).
CREATE OR REPLACE FUNCTION public.lwb_order_visible(p_order_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path = ''
AS $fn$
  SELECT p_order_id IS NOT NULL AND EXISTS (SELECT 1 FROM public.orders o WHERE o.id = p_order_id);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_visible(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_visible(uuid) TO authenticated;

DO $scope$
DECLARE t text;
  -- table, restrictive USING for a field salesman
  v_rules text[][] := ARRAY[
    ['tax_invoices',          'public.lwb_order_visible(order_id)'],
    ['sales_returns',         'public.lwb_order_visible(order_id)'],
    ['sales_return_items',    'EXISTS (SELECT 1 FROM public.sales_returns r WHERE r.id = sales_return_id)'],
    ['lwb_payment_collections','submitted_by = auth.uid() OR EXISTS (SELECT 1 FROM public.tax_invoices i WHERE i.id = invoice_id)']];
  v_cols text[][] := ARRAY[['tax_invoices','order_id'],['sales_returns','order_id'],
    ['sales_return_items','sales_return_id'],['lwb_payment_collections','invoice_id']];
  i int;
BEGIN
  FOR i IN 1 .. array_length(v_rules, 1) LOOP
    t := v_rules[i][1];
    IF to_regclass('public.' || t) IS NULL THEN CONTINUE; END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns c
                   WHERE c.table_schema = 'public' AND c.table_name = t AND c.column_name = v_cols[i][2]) THEN
      RAISE NOTICE 'skip %: no % column', t, v_cols[i][2];
      CONTINUE;
    END IF;
    IF NOT (SELECT c.relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relname = t) THEN
      -- Keep today's access for every signed-in role, only the salesman limit is added.
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
      EXECUTE format('DROP POLICY IF EXISTS lwb_signed_in_all ON public.%I', t);
      EXECUTE format('CREATE POLICY lwb_signed_in_all ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
    END IF;
    EXECUTE format('DROP POLICY IF EXISTS lwb_sales_party_scope ON public.%I', t);
    EXECUTE format('CREATE POLICY lwb_sales_party_scope ON public.%I AS RESTRICTIVE FOR SELECT TO authenticated
      USING (NOT public.lwb_is_field_salesman() OR %s)', t, v_rules[i][2]);
  END LOOP;
END
$scope$;

-- ---------------------------------------------------------------------------
-- 4. Complaint Box: a field salesman can name only his own party / PO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_complaint_add(p jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_complaint_role();
  v_cat text := upper(btrim(coalesce(p->>'category','')));
  v_subject text := nullif(btrim(coalesce(p->>'subject','')),'');
  v_details text := nullif(btrim(coalesce(p->>'details','')),'');
  v_party text := left(nullif(btrim(coalesce(p->>'party_name','')),''),150);
  v_order text := upper(nullif(btrim(coalesce(p->>'order_no','')),''));
  v_name text;
  r public.lwb_complaints%ROWTYPE;
BEGIN
  IF v_role = '' THEN RAISE EXCEPTION 'Login is not active'; END IF;
  IF v_cat NOT IN ('MARKET','GODOWN','DRIVER','ACCOUNTS','OTHER') THEN RAISE EXCEPTION 'Please select what the complaint is about'; END IF;
  IF v_subject IS NULL THEN RAISE EXCEPTION 'Please enter the problem in short'; END IF;
  IF nullif(p->>'photo_path','') IS NOT NULL AND split_part(p->>'photo_path','/',1) <> auth.uid()::text THEN
    RAISE EXCEPTION 'Invalid photo';
  END IF;
  IF public.lwb_is_field_salesman() THEN
    IF v_party IS NOT NULL AND NOT public.lwb_party_name_visible(v_party) THEN
      RAISE EXCEPTION 'Select one of your own parties';
    END IF;
    IF v_order IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.orders o WHERE upper(btrim(o.order_no)) = v_order
         AND (o.created_by = auth.uid() OR public.lwb_party_name_visible(o.customer_name))) THEN
      RAISE EXCEPTION 'PO % is not one of your orders', v_order;
    END IF;
  END IF;
  SELECT coalesce(nullif(btrim(u.full_name),''), 'Staff') INTO v_name FROM public.user_profiles u WHERE u.id = auth.uid();
  INSERT INTO public.lwb_complaints(category, subject, details, order_no, party_name, photo_path, urgent, created_by, created_by_name, created_by_role)
  VALUES (v_cat, left(v_subject,150), left(v_details,2000), v_order, v_party,
    nullif(p->>'photo_path',''), coalesce((p->>'urgent')::boolean,false), auth.uid(), v_name, v_role)
  RETURNING * INTO r;
  PERFORM public.lwb_complaint_notify_office(
    CASE WHEN r.urgent THEN 'URGENT · ' ELSE '' END || 'New complaint: ' || public.lwb_complaint_label(r.category),
    'CMP-' || r.id || ' · ' || r.subject || coalesce(' · ' || r.order_no, '') || coalesce(' · ' || r.party_name, '')
      || ' · by ' || v_name || ' (' || upper(v_role) || ').',
    'COMPLAINT_NEW');
  RETURN r.id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_complaint_add(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_complaint_add(jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: every SALES login has a salesman row (0 = OK).
-- SELECT count(*) FROM public.user_profiles p WHERE lower(btrim(p.role)) IN ('sales','salesman')
--   AND NOT EXISTS (SELECT 1 FROM public.lwb_salesmen s WHERE s.user_id = p.id);
