-- LUXURY WRIST BRAND ERP — SALES TEAM: SALESMEN, PARTY ASSIGNMENT,
-- SKU VISIBILITY, MONTHLY TARGETS AND MORNING PLAN NOTIFICATION.
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- Roles stay the same: Sales Head = MANAGER, salesmen = SALES.
-- A SALES user is set as FIELD (own parties only) or OFFICE (all parties)
-- on the Sales Team page. A SALES user who is not set up yet keeps the old
-- behaviour (sees all parties), so nothing breaks before the setup is done.
--
-- FIELD salesman, enforced in the database:
--   * Party Master: only the parties assigned to him.
--   * Orders: only his own orders and orders of his parties; a new order
--     is accepted only for his own party.
--   * Party Ledger / outstanding / payments: hidden (Admin & Sales Head only).
-- Any SALES user: SKUs blocked for him on the Sales Team page are hidden.
--
-- No order, bill, stock, payment, ledger or Tally data is changed.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_salesmen (
  user_id uuid PRIMARY KEY REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  kind text NOT NULL DEFAULT 'FIELD' CHECK (kind IN ('FIELD','OFFICE')),
  area text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

-- One salesman per party. A party with no row is handled by the office.
CREATE TABLE IF NOT EXISTS public.lwb_party_salesman (
  customer_id uuid PRIMARY KEY REFERENCES public.lwb_customer_master(id) ON DELETE CASCADE,
  salesman_id uuid NOT NULL REFERENCES public.lwb_salesmen(user_id) ON DELETE CASCADE,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  assigned_by uuid
);
CREATE INDEX IF NOT EXISTS lwb_party_salesman_sm_idx ON public.lwb_party_salesman(salesman_id);

-- SKU visibility per salesman. sku_key = upper(trim(sku_name)), same as Rate & Scheme links.
--   ONLY: the SKU is shown only to the salesmen that have an ONLY row.
--   HIDE: the SKU is hidden from this salesman.
CREATE TABLE IF NOT EXISTS public.lwb_sku_salesman_rules (
  sku_key text NOT NULL CHECK (sku_key = upper(btrim(sku_key)) AND sku_key <> ''),
  salesman_id uuid NOT NULL REFERENCES public.lwb_salesmen(user_id) ON DELETE CASCADE,
  rule text NOT NULL CHECK (rule IN ('ONLY','HIDE')),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  PRIMARY KEY (sku_key, salesman_id)
);

-- Monthly targets. salesman_id NULL = company (distributor) target.
CREATE TABLE IF NOT EXISTS public.lwb_sales_targets (
  id bigserial PRIMARY KEY,
  month date NOT NULL CHECK (extract(day FROM month) = 1),
  salesman_id uuid REFERENCES public.lwb_salesmen(user_id) ON DELETE CASCADE,
  target_amount numeric(16,2) NOT NULL DEFAULT 0 CHECK (target_amount >= 0),
  target_cases numeric(14,2) NOT NULL DEFAULT 0 CHECK (target_cases >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_sales_targets_uidx
  ON public.lwb_sales_targets (month, coalesce(salesman_id,'00000000-0000-0000-0000-000000000000'::uuid));

-- Sales Head's note for the morning plan. salesman_id NULL = note for every salesman.
CREATE TABLE IF NOT EXISTS public.lwb_sales_plan_notes (
  id bigserial PRIMARY KEY,
  plan_date date NOT NULL,
  salesman_id uuid REFERENCES public.lwb_salesmen(user_id) ON DELETE CASCADE,
  note text NOT NULL CHECK (btrim(note) <> '' AND length(note) <= 500),
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);
CREATE INDEX IF NOT EXISTS lwb_sales_plan_notes_day_idx ON public.lwb_sales_plan_notes(plan_date);

-- Plan settings (single row).
CREATE TABLE IF NOT EXISTS public.lwb_sales_settings (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  due_after_days integer NOT NULL DEFAULT 3 CHECK (due_after_days BETWEEN 1 AND 60),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
INSERT INTO public.lwb_sales_settings(id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_sales_head()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager'));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_is_sales_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND lower(btrim(p.role)) IN ('sales','salesman'));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_is_field_salesman()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    JOIN public.lwb_salesmen s ON s.user_id = p.id
    WHERE p.id = auth.uid() AND lower(btrim(p.role)) IN ('sales','salesman') AND s.kind = 'FIELD');
$fn$;

-- Party names (upper, trimmed) assigned to the signed-in salesman.
CREATE OR REPLACE FUNCTION public.lwb_my_party_names()
RETURNS SETOF text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT upper(btrim(m.customer_name)) FROM public.lwb_party_salesman a
  JOIN public.lwb_customer_master m ON m.id = a.customer_id
  WHERE a.salesman_id = auth.uid();
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_party_visible(p_customer_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT NOT public.lwb_is_field_salesman()
    OR EXISTS (SELECT 1 FROM public.lwb_party_salesman a WHERE a.customer_id = p_customer_id AND a.salesman_id = auth.uid());
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_party_name_visible(p_name text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT NOT public.lwb_is_field_salesman()
    OR upper(btrim(coalesce(p_name,''))) IN (SELECT public.lwb_my_party_names());
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_sku_visible(p_sku_name text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT NOT public.lwb_is_sales_user() OR (
    NOT EXISTS (SELECT 1 FROM public.lwb_sku_salesman_rules r
      WHERE r.sku_key = upper(btrim(coalesce(p_sku_name,''))) AND r.salesman_id = auth.uid() AND r.rule = 'HIDE')
    AND (NOT EXISTS (SELECT 1 FROM public.lwb_sku_salesman_rules r
           WHERE r.sku_key = upper(btrim(coalesce(p_sku_name,''))) AND r.rule = 'ONLY')
         OR EXISTS (SELECT 1 FROM public.lwb_sku_salesman_rules r
           WHERE r.sku_key = upper(btrim(coalesce(p_sku_name,''))) AND r.rule = 'ONLY' AND r.salesman_id = auth.uid())));
$fn$;

REVOKE ALL ON FUNCTION public.lwb_sales_head(), public.lwb_is_sales_user(), public.lwb_is_field_salesman(),
  public.lwb_my_party_names(), public.lwb_party_visible(uuid), public.lwb_party_name_visible(text),
  public.lwb_sku_visible(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sales_head(), public.lwb_is_sales_user(), public.lwb_is_field_salesman(),
  public.lwb_my_party_names(), public.lwb_party_visible(uuid), public.lwb_party_name_visible(text),
  public.lwb_sku_visible(text) TO authenticated;

-- Field salesmen no longer see Party Ledger / outstanding (Admin & Sales Head only).
CREATE OR REPLACE FUNCTION public.lwb_ledger_viewer()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN
        ('admin','accounts','manager','sales','salesman','collector')
  ) AND NOT public.lwb_is_field_salesman();
$function$;

-- ---------------------------------------------------------------------------
-- 3. Read access on the new tables
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_salesmen ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_party_salesman ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_sku_salesman_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_sales_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_sales_plan_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_sales_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lwb_salesmen_read ON public.lwb_salesmen;
CREATE POLICY lwb_salesmen_read ON public.lwb_salesmen FOR SELECT TO authenticated
  USING (public.lwb_sales_head() OR user_id = auth.uid());
DROP POLICY IF EXISTS lwb_party_salesman_read ON public.lwb_party_salesman;
CREATE POLICY lwb_party_salesman_read ON public.lwb_party_salesman FOR SELECT TO authenticated
  USING (public.lwb_sales_head() OR salesman_id = auth.uid() OR (public.lwb_is_sales_user() AND NOT public.lwb_is_field_salesman()));
DROP POLICY IF EXISTS lwb_sku_rules_read ON public.lwb_sku_salesman_rules;
CREATE POLICY lwb_sku_rules_read ON public.lwb_sku_salesman_rules FOR SELECT TO authenticated
  USING (public.lwb_sales_head());
DROP POLICY IF EXISTS lwb_sales_targets_read ON public.lwb_sales_targets;
CREATE POLICY lwb_sales_targets_read ON public.lwb_sales_targets FOR SELECT TO authenticated
  USING (public.lwb_sales_head() OR salesman_id = auth.uid());
DROP POLICY IF EXISTS lwb_sales_plan_notes_read ON public.lwb_sales_plan_notes;
CREATE POLICY lwb_sales_plan_notes_read ON public.lwb_sales_plan_notes FOR SELECT TO authenticated
  USING (public.lwb_sales_head() OR salesman_id = auth.uid() OR (salesman_id IS NULL AND public.lwb_is_sales_user()));
DROP POLICY IF EXISTS lwb_sales_settings_read ON public.lwb_sales_settings;
CREATE POLICY lwb_sales_settings_read ON public.lwb_sales_settings FOR SELECT TO authenticated USING (true);

-- Writes only through the RPCs below.
REVOKE ALL ON TABLE public.lwb_salesmen, public.lwb_party_salesman, public.lwb_sku_salesman_rules,
  public.lwb_sales_targets, public.lwb_sales_plan_notes, public.lwb_sales_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_salesmen, public.lwb_party_salesman, public.lwb_sku_salesman_rules,
  public.lwb_sales_targets, public.lwb_sales_plan_notes, public.lwb_sales_settings TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Restrict existing tables for salesmen. Other roles are not affected.
--    A table without RLS gets RLS plus an "all signed-in users" policy, which
--    keeps today's access for every other role.
-- ---------------------------------------------------------------------------
DO $guard$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['lwb_customer_master','orders','order_items','sku_master'] LOOP
    IF NOT (SELECT c.relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relname = t) THEN
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
      EXECUTE format('DROP POLICY IF EXISTS lwb_signed_in_all ON public.%I', t);
      EXECUTE format('CREATE POLICY lwb_signed_in_all ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
      -- Same driver guard as lwb_driver_delivery_setup.sql.
      EXECUTE format('DROP POLICY IF EXISTS lwb_driver_disallow_other_modules ON public.%I', t);
      EXECUTE format(
        'CREATE POLICY lwb_driver_disallow_other_modules ON public.%I AS RESTRICTIVE FOR ALL TO authenticated
         USING (NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND lower(btrim(p.role)) = ''driver''))
         WITH CHECK (NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND lower(btrim(p.role)) = ''driver''))', t);
    END IF;
  END LOOP;
END
$guard$;

DROP POLICY IF EXISTS lwb_sales_party_scope ON public.lwb_customer_master;
CREATE POLICY lwb_sales_party_scope ON public.lwb_customer_master AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.lwb_party_visible(id));

DROP POLICY IF EXISTS lwb_sales_order_scope ON public.orders;
CREATE POLICY lwb_sales_order_scope ON public.orders AS RESTRICTIVE FOR SELECT TO authenticated
  USING (NOT public.lwb_is_field_salesman() OR created_by = auth.uid() OR public.lwb_party_name_visible(customer_name));
DROP POLICY IF EXISTS lwb_sales_order_insert_scope ON public.orders;
CREATE POLICY lwb_sales_order_insert_scope ON public.orders AS RESTRICTIVE FOR INSERT TO authenticated
  WITH CHECK (public.lwb_party_name_visible(customer_name));

DROP POLICY IF EXISTS lwb_sales_item_scope ON public.order_items;
CREATE POLICY lwb_sales_item_scope ON public.order_items AS RESTRICTIVE FOR SELECT TO authenticated
  USING (NOT public.lwb_is_field_salesman() OR EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id));

DROP POLICY IF EXISTS lwb_sales_sku_scope ON public.sku_master;
CREATE POLICY lwb_sales_sku_scope ON public.sku_master AS RESTRICTIVE FOR SELECT TO authenticated
  USING (public.lwb_sku_visible(sku_name));

CREATE OR REPLACE FUNCTION public.lwb_po_entry_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager','sales')
  );
$function$;
REVOKE ALL ON FUNCTION public.lwb_po_entry_user() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_entry_user() TO authenticated;

-- A field salesman cannot read all orders any more, so the next PO number comes from here.
CREATE OR REPLACE FUNCTION public.lwb_next_order_no()
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_max bigint;
BEGIN
  IF NOT public.lwb_po_entry_user() THEN RAISE EXCEPTION 'Only Admin, Manager or Salesman can create a PO'; END IF;
  SELECT max(substring(o.order_no FROM '^LXY-([0-9]+)$')::bigint) INTO v_max
    FROM public.orders o WHERE o.order_no ~ '^LXY-[0-9]+$';
  RETURN 'LXY-' || lpad((coalesce(v_max, 0) + 1)::text, 5, '0');
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_next_order_no() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_next_order_no() TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Sales Team page RPCs (Admin & Sales Head)
-- ---------------------------------------------------------------------------
-- All SALES users with their setup and party count.
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
    WHERE lower(btrim(p.role)) IN ('sales','salesman') OR s.user_id IS NOT NULL
    ORDER BY p.active DESC, p.full_name;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_save_salesman(p_user_id uuid, p_kind text, p_area text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_kind text := upper(btrim(coalesce(p_kind,'')));
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user_id AND lower(btrim(p.role)) IN ('sales','salesman')) THEN
    RAISE EXCEPTION 'Give this user the SALES role in Manage Users first';
  END IF;
  IF v_kind NOT IN ('FIELD','OFFICE') THEN RAISE EXCEPTION 'Type must be Field or Office'; END IF;
  IF length(coalesce(p_area,'')) > 120 THEN RAISE EXCEPTION 'Area is too long'; END IF;
  INSERT INTO public.lwb_salesmen(user_id, kind, area, updated_at, updated_by)
  VALUES (p_user_id, v_kind, nullif(btrim(p_area),''), now(), auth.uid())
  ON CONFLICT (user_id) DO UPDATE SET kind = excluded.kind, area = excluded.area, updated_at = now(), updated_by = auth.uid();
END;
$fn$;

-- Assign parties to a salesman, or to the office (p_salesman_id NULL).
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
    RAISE EXCEPTION 'Set up this salesman (Field / Office) first';
  END IF;
  INSERT INTO public.lwb_party_salesman(customer_id, salesman_id, assigned_at, assigned_by)
  SELECT m.id, p_salesman_id, now(), auth.uid() FROM public.lwb_customer_master m WHERE m.id = ANY(p_customer_ids)
  ON CONFLICT (customer_id) DO UPDATE SET salesman_id = excluded.salesman_id, assigned_at = now(), assigned_by = auth.uid();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;

-- SKU visibility: p_mode ALL (no rule), ONLY (only p_salesmen see it), HIDE (hidden from p_salesmen).
CREATE OR REPLACE FUNCTION public.lwb_set_sku_visibility(p_sku_name text, p_mode text, p_salesmen uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_key text := upper(btrim(coalesce(p_sku_name,''))); v_mode text := upper(btrim(coalesce(p_mode,'')));
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF v_key = '' THEN RAISE EXCEPTION 'Select an SKU'; END IF;
  IF v_mode NOT IN ('ALL','ONLY','HIDE') THEN RAISE EXCEPTION 'Invalid visibility'; END IF;
  IF v_mode <> 'ALL' AND (p_salesmen IS NULL OR cardinality(p_salesmen) = 0) THEN RAISE EXCEPTION 'Select at least one salesman'; END IF;
  DELETE FROM public.lwb_sku_salesman_rules WHERE sku_key = v_key;
  IF v_mode <> 'ALL' THEN
    INSERT INTO public.lwb_sku_salesman_rules(sku_key, salesman_id, rule, updated_at, updated_by)
    SELECT v_key, s.user_id, v_mode, now(), auth.uid() FROM public.lwb_salesmen s WHERE s.user_id = ANY(p_salesmen);
  END IF;
END;
$fn$;

-- Targets for one month: [{salesman_id|null, target_amount, target_cases}].
CREATE OR REPLACE FUNCTION public.lwb_save_sales_targets(p_month date, p_rows jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_month date := date_trunc('month', p_month)::date; r jsonb; v_sm uuid; v_n integer := 0;
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF p_month IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'Select a month'; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_sm := nullif(r->>'salesman_id','')::uuid;
    IF v_sm IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_salesmen s WHERE s.user_id = v_sm) THEN
      RAISE EXCEPTION 'Set up the salesman first';
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

CREATE OR REPLACE FUNCTION public.lwb_save_sales_settings(p_due_after_days integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF p_due_after_days IS NULL OR p_due_after_days NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION 'Days must be 1 to 60'; END IF;
  UPDATE public.lwb_sales_settings SET due_after_days = p_due_after_days, updated_at = now(), updated_by = auth.uid() WHERE id = 1;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_add_sales_plan_note(p_date date, p_salesman_id uuid, p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF btrim(coalesce(p_note,'')) = '' THEN RAISE EXCEPTION 'Enter the note'; END IF;
  INSERT INTO public.lwb_sales_plan_notes(plan_date, salesman_id, note, created_by)
  VALUES (coalesce(p_date, (now() AT TIME ZONE 'Asia/Kolkata')::date), p_salesman_id, left(btrim(p_note),500), auth.uid());
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_delete_sales_plan_note(p_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  DELETE FROM public.lwb_sales_plan_notes WHERE id = p_id;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 6. Party activity: last order date per party (no-order list, plan, coverage).
--    Field salesman gets only his parties.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_activity()
RETURNS TABLE (customer_id uuid, customer_name text, city text, salesman_id uuid, salesman_name text,
               last_order_date date, last_order_no text, orders_30d bigint, amount_30d numeric, orders_total bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
#variable_conflict use_column
DECLARE v_field boolean := public.lwb_is_field_salesman();
BEGIN
  IF NOT (public.lwb_sales_head() OR public.lwb_po_entry_user()) THEN RAISE EXCEPTION 'Sales team only'; END IF;
  RETURN QUERY
    WITH o AS (
      SELECT upper(btrim(x.customer_name)) AS k, timezone('Asia/Kolkata', x.order_date::timestamptz)::date AS d, x.order_no, x.total_amount::numeric AS total_amount
      FROM public.orders x
      WHERE lower(btrim(coalesce(x.status,''))) NOT IN ('cancelled','canceled','rejected')
    ), last AS (
      SELECT DISTINCT ON (o.k) o.k, o.d, o.order_no FROM o ORDER BY o.k, o.d DESC, o.order_no DESC
    ), agg AS (
      SELECT o.k, count(*) AS n_all,
        count(*) FILTER (WHERE o.d > (now() AT TIME ZONE 'Asia/Kolkata')::date - 30) AS n30,
        coalesce(sum(o.total_amount) FILTER (WHERE o.d > (now() AT TIME ZONE 'Asia/Kolkata')::date - 30),0) AS a30
      FROM o GROUP BY o.k
    )
    SELECT m.id, m.customer_name::text, m.city::text, a.salesman_id, p.full_name::text,
      l.d, l.order_no::text, coalesce(g.n30,0), coalesce(g.a30,0), coalesce(g.n_all,0)
    FROM public.lwb_customer_master m
    LEFT JOIN public.lwb_party_salesman a ON a.customer_id = m.id
    LEFT JOIN public.user_profiles p ON p.id = a.salesman_id
    LEFT JOIN last l ON l.k = upper(btrim(m.customer_name))
    LEFT JOIN agg g ON g.k = upper(btrim(m.customer_name))
    WHERE m.is_active IS TRUE AND (NOT v_field OR a.salesman_id = auth.uid())
    ORDER BY m.customer_name;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 7. Morning plan notification (🔔 bell). One per salesman per day.
--    Lists his parties with no order for N+ days (Sales settings) + Sales Head notes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_build_sales_plan(p_salesman_id uuid, p_date date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_days integer; v_kind text;
BEGIN
  SELECT due_after_days INTO v_days FROM public.lwb_sales_settings WHERE id = 1;
  v_days := coalesce(v_days, 3);
  SELECT s.kind INTO v_kind FROM public.lwb_salesmen s WHERE s.user_id = p_salesman_id;
  RETURN jsonb_build_object(
    'date', p_date, 'due_after_days', v_days, 'kind', v_kind,
    'parties', coalesce((
      SELECT jsonb_agg(jsonb_build_object('name', x.customer_name, 'city', x.city, 'days', x.days, 'last_order_date', x.d) ORDER BY x.days DESC NULLS FIRST, x.customer_name)
      FROM (
        SELECT m.customer_name, m.city, l.d, (p_date - l.d) AS days
        FROM public.lwb_party_salesman a
        JOIN public.lwb_customer_master m ON m.id = a.customer_id AND m.is_active IS TRUE
        LEFT JOIN LATERAL (
          SELECT max(timezone('Asia/Kolkata', o.order_date::timestamptz)::date) AS d FROM public.orders o
          WHERE upper(btrim(o.customer_name)) = upper(btrim(m.customer_name))
            AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected')
        ) l ON true
        WHERE a.salesman_id = p_salesman_id AND (l.d IS NULL OR p_date - l.d >= v_days)
      ) x), '[]'::jsonb),
    'notes', coalesce((
      SELECT jsonb_agg(n.note ORDER BY n.created_at) FROM public.lwb_sales_plan_notes n
      WHERE n.plan_date = p_date AND (n.salesman_id IS NULL OR n.salesman_id = p_salesman_id)), '[]'::jsonb));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_build_sales_plan(uuid, date) FROM PUBLIC, anon, authenticated;

-- Internal: send today's plan to every active salesman who has not got it yet.
-- p_force = true sends again (after the Sales Head adds a note).
CREATE OR REPLACE FUNCTION public.lwb_send_sales_plans_internal(p_force boolean DEFAULT false, p_only uuid DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date; s record; v_plan jsonb; v_n integer := 0;
  v_parties integer; v_top text; v_notes text;
BEGIN
  FOR s IN
    SELECT p.id FROM public.user_profiles p JOIN public.lwb_salesmen m ON m.user_id = p.id
    WHERE p.active = true AND lower(btrim(p.role)) IN ('sales','salesman') AND (p_only IS NULL OR p.id = p_only)
  LOOP
    IF NOT p_force AND EXISTS (SELECT 1 FROM public.erp_notifications e WHERE e.user_id = s.id
         AND e.notification_type = 'SALES_PLAN' AND (e.created_at AT TIME ZONE 'Asia/Kolkata')::date = v_today) THEN
      CONTINUE;
    END IF;
    v_plan := public.lwb_build_sales_plan(s.id, v_today);
    v_parties := jsonb_array_length(v_plan->'parties');
    SELECT string_agg((t.v->>'name') || ' (' || coalesce((t.v->>'days') || ' days', 'no order yet') || ')', ', ')
      INTO v_top FROM (SELECT e.v FROM jsonb_array_elements(v_plan->'parties') AS e(v) LIMIT 8) t;
    SELECT string_agg(n.txt, ' | ') INTO v_notes FROM jsonb_array_elements_text(v_plan->'notes') AS n(txt);
    IF v_parties = 0 AND v_notes IS NULL THEN CONTINUE; END IF;
    INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
    VALUES (s.id, 'Today''s Sales Plan',
      concat_ws(' ',
        CASE WHEN v_parties > 0 THEN 'Bring orders from ' || v_parties || CASE WHEN v_parties = 1 THEN ' party' ELSE ' parties' END
          || ' with no order for ' || (v_plan->>'due_after_days') || '+ days: ' || v_top
          || CASE WHEN v_parties > 8 THEN ' and ' || (v_parties - 8) || ' more' ELSE '' END || '.' END,
        CASE WHEN v_notes IS NOT NULL THEN 'Sales Head: ' || v_notes || '.' END,
        'Open My Sales for the full list.'),
      'SALES_PLAN');
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_send_sales_plans_internal(boolean, uuid) FROM PUBLIC, anon, authenticated;

-- Sales Head: send now (p_force = send again with the latest notes).
CREATE OR REPLACE FUNCTION public.lwb_send_sales_plans(p_force boolean DEFAULT false)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  RETURN public.lwb_send_sales_plans_internal(coalesce(p_force,false), NULL);
END;
$fn$;

-- Salesman: today's plan for My Sales; also sends the morning bell if not sent yet.
CREATE OR REPLACE FUNCTION public.lwb_my_sales_plan()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  IF NOT public.lwb_is_sales_user() THEN RAISE EXCEPTION 'Salesman login only'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_salesmen s WHERE s.user_id = auth.uid()) THEN
    RETURN jsonb_build_object('setup', false);
  END IF;
  PERFORM public.lwb_send_sales_plans_internal(false, auth.uid());
  RETURN public.lwb_build_sales_plan(auth.uid(), v_today) || jsonb_build_object('setup', true);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_sales_team(), public.lwb_save_salesman(uuid,text,text),
  public.lwb_assign_parties(uuid[],uuid), public.lwb_set_sku_visibility(text,text,uuid[]),
  public.lwb_save_sales_targets(date,jsonb), public.lwb_save_sales_settings(integer),
  public.lwb_add_sales_plan_note(date,uuid,text), public.lwb_delete_sales_plan_note(bigint),
  public.lwb_party_activity(), public.lwb_send_sales_plans(boolean), public.lwb_my_sales_plan()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sales_team(), public.lwb_save_salesman(uuid,text,text),
  public.lwb_assign_parties(uuid[],uuid), public.lwb_set_sku_visibility(text,text,uuid[]),
  public.lwb_save_sales_targets(date,jsonb), public.lwb_save_sales_settings(integer),
  public.lwb_add_sales_plan_note(date,uuid,text), public.lwb_delete_sales_plan_note(bigint),
  public.lwb_party_activity(), public.lwb_send_sales_plans(boolean), public.lwb_my_sales_plan()
  TO authenticated;

COMMIT;

-- Morning bell at 8:30 AM IST (03:00 UTC), if pg_cron is turned on
-- (Supabase > Database > Extensions > pg_cron). Without pg_cron the plan is
-- still sent when the salesman opens the ERP, or by "Send today's plan".
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'lwb_morning_sales_plan';
    PERFORM cron.schedule('lwb_morning_sales_plan', '0 3 * * *', 'SELECT public.lwb_send_sales_plans_internal(false, NULL)');
  END IF;
END
$cron$;

NOTIFY pgrst, 'reload schema';

-- Check: each line should say true.
SELECT 'tables' AS item, count(*) = 6 AS ok FROM information_schema.tables
  WHERE table_schema = 'public' AND table_name IN ('lwb_salesmen','lwb_party_salesman','lwb_sku_salesman_rules','lwb_sales_targets','lwb_sales_plan_notes','lwb_sales_settings')
UNION ALL
SELECT 'salesman limits', count(*) = 5 FROM pg_policies
  WHERE schemaname = 'public' AND policyname IN ('lwb_sales_party_scope','lwb_sales_order_scope','lwb_sales_order_insert_scope','lwb_sales_item_scope','lwb_sales_sku_scope')
UNION ALL
SELECT 'morning bell at 8:30 (pg_cron)', EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron');
