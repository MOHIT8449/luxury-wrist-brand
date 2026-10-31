-- LUXURY WRIST BRAND ERP — COMPANY / BRAND (Rajnigandha, Coca-Cola, more later)
--
-- Safe to run again. Runs by itself on merge to main (Supabase apply).
--
-- 1. Company master lwb_companies: name, colour, credit the company gives us
--    (days before we must pay it, e.g. Rajnigandha 4) and market credit days
--    (udhari we give parties, e.g. 1 or 2 days). SKU Master gets company_id.
-- 2. Monthly target per company: company total + per salesman (lwb_company_targets).
-- 3. Brand-wise team: a Sales Head (MANAGER) or Salesman (SALES) can be tied to one
--    or more companies (lwb_user_companies). Such a login sees only those SKUs and
--    only orders that have an SKU of those companies (or that he made himself).
--    No company ticked = all companies (old behaviour). Admin, Accounts and
--    Godown Manager always see every company.
--    An SKU with no company is shown to everyone until its company is set.
-- 4. Party udhari per company (lwb_party_company_credit), else the company's market days.
-- 5. Money to pay the company: purchase bills (Goods Inward, SKU-wise) of the company,
--    due on invoice date + company credit days, less payments made to it
--    (lwb_company_payments; oldest bill first).
--    Pack unit: company BOX / CASE (Rajnigandha BOX), SKU may override; quantities
--    are reported as cases and boxes separately.
--    Purchase bill type: TAXABLE (GST on taxable amount) or MRP (GST on Deemed
--    Taxable Value; Rajnigandha). Used by Goods Inward.
-- 6. lwb_company_overview(from, to): per company sales, cases / boxes, month target,
--    outstanding (bill due split by the bill's SKU value), overdue, to pay company.
--
-- Nothing is deleted. No order, bill, stock or ledger amount is changed.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_companies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (btrim(name) <> '' AND length(name) <= 80),
  color text NOT NULL DEFAULT '#2362a4' CHECK (color ~ '^#[0-9a-fA-F]{6}$'),
  supplier_credit_days integer NOT NULL DEFAULT 0 CHECK (supplier_credit_days BETWEEN 0 AND 365),
  market_credit_days integer NOT NULL DEFAULT 0 CHECK (market_credit_days BETWEEN 0 AND 365),
  active boolean NOT NULL DEFAULT true,
  sort_no integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_companies_name_uidx ON public.lwb_companies (upper(btrim(name)));

INSERT INTO public.lwb_companies(name, color, supplier_credit_days, market_credit_days, sort_no)
SELECT v.n, v.c, v.s, v.m, v.o FROM (VALUES ('RAJNIGANDHA','#9a5b00',4,1,1), ('COCA-COLA','#b3263f',0,0,2)) v(n,c,s,m,o)
WHERE NOT EXISTS (SELECT 1 FROM public.lwb_companies x WHERE upper(btrim(x.name)) = v.n);

ALTER TABLE public.sku_master ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES public.lwb_companies(id);
CREATE INDEX IF NOT EXISTS lwb_sku_master_company_idx ON public.sku_master (company_id);
CREATE INDEX IF NOT EXISTS lwb_sku_master_key_idx ON public.sku_master (upper(btrim(sku_name)));

-- Pack unit: Rajnigandha sells in BOX, Coca-Cola in CASE. Company default, SKU can override
-- (sku_master.pack_unit NULL = company's unit). Quantities stay numbers of that unit.
DO $unit$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'lwb_companies' AND column_name = 'pack_unit') THEN
    ALTER TABLE public.lwb_companies ADD COLUMN pack_unit text NOT NULL DEFAULT 'CASE' CHECK (pack_unit IN ('CASE','BOX'));
    UPDATE public.lwb_companies SET pack_unit = 'BOX' WHERE upper(btrim(name)) = 'RAJNIGANDHA';
  END IF;
END
$unit$;
ALTER TABLE public.sku_master ADD COLUMN IF NOT EXISTS pack_unit text CHECK (pack_unit IN ('CASE','BOX'));

-- Purchase bill type (Goods Inward). TAXABLE: GST on the bill's taxable amount (Coca-Cola).
-- MRP: GST on the Deemed Taxable Value = MRP / (1 + GST%) and Total = Net Sale + GST
-- (Rajnigandha pan masala, cigarettes). Set once to MRP for Rajnigandha when the column is added.
DO $billing$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'lwb_companies' AND column_name = 'purchase_billing') THEN
    ALTER TABLE public.lwb_companies ADD COLUMN purchase_billing text NOT NULL DEFAULT 'TAXABLE' CHECK (purchase_billing IN ('TAXABLE','MRP'));
    UPDATE public.lwb_companies SET purchase_billing = 'MRP' WHERE upper(btrim(name)) = 'RAJNIGANDHA';
  END IF;
END
$billing$;

-- Brand-wise Sales Head / Salesman. No row = all companies.
CREATE TABLE IF NOT EXISTS public.lwb_user_companies (
  user_id uuid NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  company_id uuid NOT NULL REFERENCES public.lwb_companies(id) ON DELETE CASCADE,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  PRIMARY KEY (user_id, company_id)
);

-- Monthly target per company. salesman_id NULL = company total.
CREATE TABLE IF NOT EXISTS public.lwb_company_targets (
  id bigserial PRIMARY KEY,
  month date NOT NULL CHECK (extract(day FROM month) = 1),
  company_id uuid NOT NULL REFERENCES public.lwb_companies(id) ON DELETE CASCADE,
  salesman_id uuid REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  target_amount numeric(16,2) NOT NULL DEFAULT 0 CHECK (target_amount >= 0),
  target_cases numeric(14,2) NOT NULL DEFAULT 0 CHECK (target_cases >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_company_targets_uidx
  ON public.lwb_company_targets (month, company_id, coalesce(salesman_id,'00000000-0000-0000-0000-000000000000'::uuid));

-- Party udhari days for one company (party key = upper(trim(party name)), as orders keep the name).
CREATE TABLE IF NOT EXISTS public.lwb_party_company_credit (
  party_key text NOT NULL CHECK (party_key = upper(btrim(party_key)) AND party_key <> ''),
  company_id uuid NOT NULL REFERENCES public.lwb_companies(id) ON DELETE CASCADE,
  credit_days integer NOT NULL CHECK (credit_days BETWEEN 0 AND 365),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  PRIMARY KEY (party_key, company_id)
);

-- Money we paid to the company.
CREATE TABLE IF NOT EXISTS public.lwb_company_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.lwb_companies(id),
  pay_date date NOT NULL,
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  mode text NOT NULL DEFAULT 'BANK' CHECK (mode IN ('BANK','UPI','CHEQUE','CASH','CREDIT_NOTE')),
  ref_no text CHECK (length(ref_no) <= 80),
  note text CHECK (length(note) <= 300),
  created_by uuid DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  cancelled_at timestamptz,
  cancelled_by uuid
);
CREATE INDEX IF NOT EXISTS lwb_company_payments_c_idx ON public.lwb_company_payments (company_id, pay_date);

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_company_user_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
$fn$;

-- Companies the signed-in login is limited to; NULL = all companies.
CREATE OR REPLACE FUNCTION public.lwb_my_companies()
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE WHEN lower(btrim(coalesce(p.role,''))) IN ('manager','sales','salesman')
              THEN (SELECT array_agg(u.company_id ORDER BY u.company_id) FROM public.lwb_user_companies u WHERE u.user_id = p.id)
         END
  FROM public.user_profiles p WHERE p.id = auth.uid();
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_company_ok(p_company_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT p_company_id IS NULL OR public.lwb_my_companies() IS NULL OR p_company_id = ANY(public.lwb_my_companies());
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_sku_company(p_sku_name text)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT s.company_id FROM public.sku_master s
  WHERE upper(btrim(s.sku_name)) = upper(btrim(coalesce(p_sku_name,''))) AND s.company_id IS NOT NULL LIMIT 1;
$fn$;

-- Order visible to a brand-limited login: his own order, an order with no lines yet,
-- or an order with a line of his company (or an SKU without company).
CREATE OR REPLACE FUNCTION public.lwb_order_company_ok(p_order_id uuid, p_created_by uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_my uuid[] := public.lwb_my_companies();
BEGIN
  IF v_my IS NULL OR p_created_by = auth.uid() THEN RETURN true; END IF;
  RETURN NOT EXISTS (SELECT 1 FROM public.order_items i WHERE i.order_id = p_order_id)
      OR EXISTS (SELECT 1 FROM public.order_items i
                 LEFT JOIN public.sku_master s ON upper(btrim(s.sku_name)) = upper(btrim(i.sku_name))
                 WHERE i.order_id = p_order_id AND (s.company_id IS NULL OR s.company_id = ANY(v_my)));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_company_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT coalesce(public.lwb_company_user_role() = 'admin', false); $fn$;

REVOKE ALL ON FUNCTION public.lwb_company_user_role(), public.lwb_my_companies(), public.lwb_company_ok(uuid),
  public.lwb_sku_company(text), public.lwb_order_company_ok(uuid,uuid), public.lwb_company_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_company_user_role(), public.lwb_my_companies(), public.lwb_company_ok(uuid),
  public.lwb_sku_company(text), public.lwb_order_company_ok(uuid,uuid), public.lwb_company_admin() TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Read rules. Writes only through the RPCs below.
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_user_companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_company_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_party_company_credit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_company_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lwb_companies_read ON public.lwb_companies;
CREATE POLICY lwb_companies_read ON public.lwb_companies FOR SELECT TO authenticated
  USING (public.lwb_company_ok(id));
DROP POLICY IF EXISTS lwb_user_companies_read ON public.lwb_user_companies;
CREATE POLICY lwb_user_companies_read ON public.lwb_user_companies FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.lwb_company_user_role() IN ('admin','manager'));
DROP POLICY IF EXISTS lwb_company_targets_read ON public.lwb_company_targets;
CREATE POLICY lwb_company_targets_read ON public.lwb_company_targets FOR SELECT TO authenticated
  USING (salesman_id = auth.uid() OR (public.lwb_company_user_role() IN ('admin','manager','accounts') AND public.lwb_company_ok(company_id)));
DROP POLICY IF EXISTS lwb_party_company_credit_read ON public.lwb_party_company_credit;
CREATE POLICY lwb_party_company_credit_read ON public.lwb_party_company_credit FOR SELECT TO authenticated
  USING (public.lwb_company_ok(company_id));
DROP POLICY IF EXISTS lwb_company_payments_read ON public.lwb_company_payments;
CREATE POLICY lwb_company_payments_read ON public.lwb_company_payments FOR SELECT TO authenticated
  USING (public.lwb_company_user_role() IN ('admin','accounts'));

REVOKE ALL ON TABLE public.lwb_companies, public.lwb_user_companies, public.lwb_company_targets,
  public.lwb_party_company_credit, public.lwb_company_payments FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_companies, public.lwb_user_companies, public.lwb_company_targets,
  public.lwb_party_company_credit, public.lwb_company_payments TO authenticated;

-- Brand-limited Sales Head / Salesman: only SKUs and orders of his companies.
-- (SELECT ...) runs the login check once per query; other roles pass straight away.
DROP POLICY IF EXISTS lwb_brand_sku_scope ON public.sku_master;
CREATE POLICY lwb_brand_sku_scope ON public.sku_master AS RESTRICTIVE FOR SELECT TO authenticated
  USING ((SELECT public.lwb_my_companies()) IS NULL OR company_id IS NULL OR company_id = ANY(((SELECT public.lwb_my_companies()))::uuid[]));
DROP POLICY IF EXISTS lwb_brand_order_scope ON public.orders;
CREATE POLICY lwb_brand_order_scope ON public.orders AS RESTRICTIVE FOR SELECT TO authenticated
  USING ((SELECT public.lwb_my_companies()) IS NULL OR public.lwb_order_company_ok(id, created_by));

-- ---------------------------------------------------------------------------
-- 4. Company master, SKU company, team brands (Admin; Sales Head for salesmen)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_company_save(p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id uuid := nullif(p->>'id','')::uuid; v_name text := upper(regexp_replace(btrim(coalesce(p->>'name','')),'\s+',' ','g'));
BEGIN
  IF NOT public.lwb_company_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF v_name = '' THEN RAISE EXCEPTION 'Enter the company name'; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_companies c WHERE upper(btrim(c.name)) = v_name AND c.id IS DISTINCT FROM v_id) THEN
    RAISE EXCEPTION 'Company % already exists', v_name;
  END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.lwb_companies(name, color, pack_unit, purchase_billing, supplier_credit_days, market_credit_days, active, sort_no, updated_by)
    VALUES (v_name, coalesce(nullif(p->>'color',''),'#2362a4'), coalesce(nullif(upper(p->>'pack_unit'),''),'CASE'),
      coalesce(nullif(upper(p->>'purchase_billing'),''),'TAXABLE'), coalesce((p->>'supplier_credit_days')::int,0),
      coalesce((p->>'market_credit_days')::int,0), coalesce((p->>'active')::boolean,true),
      coalesce((p->>'sort_no')::int,(SELECT coalesce(max(sort_no),0)+1 FROM public.lwb_companies)), auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.lwb_companies SET name = v_name, color = coalesce(nullif(p->>'color',''), color),
      pack_unit = coalesce(nullif(upper(p->>'pack_unit'),''), pack_unit),
      purchase_billing = coalesce(nullif(upper(p->>'purchase_billing'),''), purchase_billing),
      supplier_credit_days = coalesce((p->>'supplier_credit_days')::int, supplier_credit_days),
      market_credit_days = coalesce((p->>'market_credit_days')::int, market_credit_days),
      active = coalesce((p->>'active')::boolean, active), sort_no = coalesce((p->>'sort_no')::int, sort_no),
      updated_at = now(), updated_by = auth.uid()
    WHERE id = v_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Company not found'; END IF;
  END IF;
  RETURN v_id;
END;
$fn$;

-- Set the company of many SKUs at once (NULL = no company).
CREATE OR REPLACE FUNCTION public.lwb_set_sku_company(p_sku_ids uuid[], p_company_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_n integer;
BEGIN
  IF coalesce(public.lwb_company_user_role(),'') NOT IN ('admin','manager') THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF p_company_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_companies c WHERE c.id = p_company_id) THEN RAISE EXCEPTION 'Company not found'; END IF;
  IF p_company_id IS NOT NULL AND NOT public.lwb_company_ok(p_company_id) THEN RAISE EXCEPTION 'This company is not yours'; END IF;
  UPDATE public.sku_master s SET company_id = p_company_id
  WHERE s.id = ANY(coalesce(p_sku_ids,'{}')) AND public.lwb_company_ok(s.company_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;

-- Sales Heads and Salesmen with their companies.
CREATE OR REPLACE FUNCTION public.lwb_brand_team()
RETURNS TABLE (user_id uuid, full_name text, role text, active boolean, company_ids uuid[])
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
#variable_conflict use_column
BEGIN
  IF coalesce(public.lwb_company_user_role(),'') NOT IN ('admin','manager') THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  RETURN QUERY
    SELECT p.id, p.full_name::text, lower(btrim(p.role))::text, p.active,
      coalesce((SELECT array_agg(u.company_id) FROM public.lwb_user_companies u WHERE u.user_id = p.id), '{}'::uuid[])
    FROM public.user_profiles p
    WHERE lower(btrim(p.role)) IN ('manager','sales','salesman')
    ORDER BY p.active DESC, CASE WHEN lower(btrim(p.role)) = 'manager' THEN 0 ELSE 1 END, p.full_name;
END;
$fn$;

-- Admin: any Sales Head / Salesman. Sales Head: salesmen only, within his own companies.
CREATE OR REPLACE FUNCTION public.lwb_set_user_companies(p_user_id uuid, p_company_ids uuid[])
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_me text := coalesce(public.lwb_company_user_role(),''); v_role text; v_my uuid[] := public.lwb_my_companies(); v_n integer;
BEGIN
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = p_user_id;
  IF v_role IS NULL OR v_role NOT IN ('manager','sales','salesman') THEN RAISE EXCEPTION 'Only a Sales Head or Salesman can be set brand-wise'; END IF;
  IF v_me = 'admin' THEN NULL;
  ELSIF v_me = 'manager' THEN
    IF v_role = 'manager' THEN RAISE EXCEPTION 'Only Admin can set a Sales Head''s companies'; END IF;
    IF v_my IS NOT NULL AND (cardinality(coalesce(p_company_ids,'{}')) = 0 OR NOT (p_company_ids <@ v_my)) THEN
      RAISE EXCEPTION 'You can give only your own companies';
    END IF;
    IF v_my IS NOT NULL AND EXISTS (SELECT 1 FROM public.lwb_user_companies u WHERE u.user_id = p_user_id AND NOT (u.company_id = ANY(v_my))) THEN
      RAISE EXCEPTION 'This salesman also has another company; ask Admin';
    END IF;
  ELSE RAISE EXCEPTION 'Admin or Sales Head required';
  END IF;
  DELETE FROM public.lwb_user_companies WHERE user_id = p_user_id;
  INSERT INTO public.lwb_user_companies(user_id, company_id, updated_by)
  SELECT p_user_id, c.id, auth.uid() FROM public.lwb_companies c WHERE c.id = ANY(coalesce(p_company_ids,'{}'));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. Targets per company
-- ---------------------------------------------------------------------------
-- p_rows: [{salesman_id|null, target_amount, target_cases}] for one company and month.
CREATE OR REPLACE FUNCTION public.lwb_save_company_targets(p_month date, p_company_id uuid, p_rows jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_month date := date_trunc('month', p_month)::date; r jsonb; v_sm uuid; v_amt numeric; v_cs numeric; v_n integer := 0;
BEGIN
  IF coalesce(public.lwb_company_user_role(),'') NOT IN ('admin','manager') THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF p_month IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN RAISE EXCEPTION 'Select a month'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_companies c WHERE c.id = p_company_id) OR NOT public.lwb_company_ok(p_company_id) THEN
    RAISE EXCEPTION 'Select your company';
  END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    v_sm := nullif(r->>'salesman_id','')::uuid;
    v_amt := coalesce(nullif(r->>'target_amount','')::numeric,0); v_cs := coalesce(nullif(r->>'target_cases','')::numeric,0);
    IF v_sm IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = v_sm AND lower(btrim(p.role)) IN ('sales','salesman')) THEN
      RAISE EXCEPTION 'Target can be given to a salesman only';
    END IF;
    IF v_amt < 0 OR v_cs < 0 THEN RAISE EXCEPTION 'Target cannot be negative'; END IF;
    DELETE FROM public.lwb_company_targets t WHERE t.month = v_month AND t.company_id = p_company_id AND t.salesman_id IS NOT DISTINCT FROM v_sm;
    IF v_amt > 0 OR v_cs > 0 THEN
      INSERT INTO public.lwb_company_targets(month, company_id, salesman_id, target_amount, target_cases, updated_by)
      VALUES (v_month, p_company_id, v_sm, v_amt, v_cs, auth.uid());
    END IF;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$fn$;

-- One month: targets + sales per company and salesman (order taken by that login).
-- A salesman gets only his own rows.
CREATE OR REPLACE FUNCTION public.lwb_company_month(p_month date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_role text := coalesce(public.lwb_company_user_role(),''); v_my uuid[] := public.lwb_my_companies();
  v_from date := date_trunc('month', coalesce(p_month,(now() AT TIME ZONE 'Asia/Kolkata')::date))::date;
  v_to date := (date_trunc('month', coalesce(p_month,(now() AT TIME ZONE 'Asia/Kolkata')::date)) + interval '1 month')::date;
  v_self uuid;
BEGIN
  IF v_role IN ('sales','salesman') THEN v_self := auth.uid();
  ELSIF v_role NOT IN ('admin','manager','accounts') THEN RAISE EXCEPTION 'Not allowed';
  END IF;
  RETURN jsonb_build_object(
    'month', v_from,
    'targets', (SELECT coalesce(jsonb_agg(jsonb_build_object('company_id', t.company_id, 'salesman_id', t.salesman_id,
                  'target_amount', t.target_amount, 'target_cases', t.target_cases)), '[]'::jsonb)
                FROM public.lwb_company_targets t
                WHERE t.month = v_from AND (v_my IS NULL OR t.company_id = ANY(v_my))
                  AND (v_self IS NULL OR t.salesman_id = v_self)),
    'sales', (SELECT coalesce(jsonb_agg(jsonb_build_object('company_id', x.c, 'salesman_id', x.sm, 'amount', round(x.amt,2), 'cases', x.cs, 'boxes', x.bx, 'orders', x.n)), '[]'::jsonb)
              FROM (
                SELECT l.c, l.sm, sum(l.amt) AS amt, coalesce(sum(l.cs) FILTER (WHERE l.u = 'CASE'),0) AS cs,
                       coalesce(sum(l.cs) FILTER (WHERE l.u = 'BOX'),0) AS bx, count(DISTINCT l.oid) AS n FROM (
                  SELECT o.id AS oid, s.company_id AS c, o.created_by AS sm,
                    CASE WHEN sum(coalesce(i.approved_qty, i.ordered_qty) * i.rate) OVER (PARTITION BY o.id) > 0 AND coalesce(o.total_amount,0) > 0
                      THEN o.total_amount * coalesce(i.approved_qty, i.ordered_qty) * i.rate / sum(coalesce(i.approved_qty, i.ordered_qty) * i.rate) OVER (PARTITION BY o.id)
                      ELSE coalesce(i.amount, coalesce(i.approved_qty, i.ordered_qty) * i.rate, 0) END AS amt,
                    coalesce(i.approved_qty, i.ordered_qty, 0) AS cs, coalesce(s.pack_unit, co.pack_unit, 'CASE') AS u
                  FROM public.orders o
                  JOIN public.order_items i ON i.order_id = o.id
                  LEFT JOIN public.sku_master s ON upper(btrim(s.sku_name)) = upper(btrim(i.sku_name))
                  LEFT JOIN public.lwb_companies co ON co.id = s.company_id
                  WHERE timezone('Asia/Kolkata', o.order_date::timestamptz)::date >= v_from
                    AND timezone('Asia/Kolkata', o.order_date::timestamptz)::date < v_to
                    AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected')
                    AND (v_self IS NULL OR o.created_by = v_self)) l
                WHERE v_my IS NULL OR l.c IS NULL OR l.c = ANY(v_my)
                GROUP BY l.c, l.sm) x)
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 6. Party udhari per company
-- ---------------------------------------------------------------------------
-- p_days NULL = remove (company market days apply).
CREATE OR REPLACE FUNCTION public.lwb_set_party_company_credit(p_party text, p_company_id uuid, p_days integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_key text := upper(btrim(coalesce(p_party,'')));
BEGIN
  IF coalesce(public.lwb_company_user_role(),'') NOT IN ('admin','manager','accounts') THEN RAISE EXCEPTION 'Admin, Sales Head or Accounts required'; END IF;
  IF v_key = '' THEN RAISE EXCEPTION 'Select a party'; END IF;
  IF NOT public.lwb_company_ok(p_company_id) OR NOT EXISTS (SELECT 1 FROM public.lwb_companies c WHERE c.id = p_company_id) THEN RAISE EXCEPTION 'Select your company'; END IF;
  IF p_days IS NULL THEN
    DELETE FROM public.lwb_party_company_credit WHERE party_key = v_key AND company_id = p_company_id;
  ELSE
    IF p_days NOT BETWEEN 0 AND 365 THEN RAISE EXCEPTION 'Days must be 0 to 365'; END IF;
    INSERT INTO public.lwb_party_company_credit(party_key, company_id, credit_days, updated_by)
    VALUES (v_key, p_company_id, p_days, auth.uid())
    ON CONFLICT (party_key, company_id) DO UPDATE SET credit_days = excluded.credit_days, updated_at = now(), updated_by = auth.uid();
  END IF;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 7. Money to pay the company (Admin, Accounts)
-- ---------------------------------------------------------------------------
-- Purchase bills split by SKU company, oldest first, with what is still to pay.
CREATE OR REPLACE FUNCTION public.lwb_company_bill_rows(p_company_id uuid)
RETURNS TABLE (inward_id uuid, invoice_no text, invoice_date date, supplier_name text, amount numeric,
               due_date date, paid numeric, balance numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
#variable_conflict use_column
DECLARE v_days integer; v_paid numeric;
BEGIN
  SELECT c.supplier_credit_days INTO v_days FROM public.lwb_companies c WHERE c.id = p_company_id;
  SELECT coalesce(sum(p.amount),0) INTO v_paid FROM public.lwb_company_payments p WHERE p.company_id = p_company_id AND p.cancelled_at IS NULL;
  RETURN QUERY
    WITH b AS (
      SELECT g.id, g.invoice_no::text AS no, coalesce(g.invoice_date, g.received_date)::date AS d, g.supplier_name::text AS sup,
             round(sum(coalesce(i.total_amount,0))::numeric, 2) AS amt
      FROM public.lwb_goods_inward g
      JOIN public.lwb_goods_inward_items i ON i.inward_id = g.id
      JOIN public.sku_master s ON s.id::text = i.sku_id::text
      WHERE s.company_id = p_company_id
      GROUP BY g.id, g.invoice_no, g.invoice_date, g.received_date, g.supplier_name
    ), c AS (
      SELECT b.*, coalesce(sum(b.amt) OVER (ORDER BY b.d, b.no, b.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0) AS before FROM b
    )
    SELECT c.id, c.no, c.d, c.sup, c.amt, c.d + coalesce(v_days,0),
           least(c.amt, greatest(0, v_paid - c.before)), c.amt - least(c.amt, greatest(0, v_paid - c.before))
    FROM c ORDER BY c.d, c.no;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_company_bill_rows(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_company_payables(p_company_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_bills jsonb; v_err text;
BEGIN
  IF coalesce(public.lwb_company_user_role(),'') NOT IN ('admin','accounts') THEN RAISE EXCEPTION 'Admin or Accounts required'; END IF;
  BEGIN
    SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.invoice_date, r.invoice_no), '[]'::jsonb) INTO v_bills FROM public.lwb_company_bill_rows(p_company_id) r;
  EXCEPTION WHEN undefined_table OR undefined_column THEN v_bills := '[]'::jsonb; v_err := 'Purchase bills could not be read: ' || SQLERRM;
  END;
  RETURN jsonb_build_object(
    'today', (now() AT TIME ZONE 'Asia/Kolkata')::date,
    'bills', v_bills, 'error', v_err,
    'payments', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'pay_date', p.pay_date, 'amount', p.amount, 'mode', p.mode,
                   'ref_no', p.ref_no, 'note', p.note, 'cancelled', p.cancelled_at IS NOT NULL,
                   'by', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = p.created_by)) ORDER BY p.pay_date DESC, p.created_at DESC), '[]'::jsonb)
                 FROM public.lwb_company_payments p WHERE p.company_id = p_company_id));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_company_pay(p_company_id uuid, p_date date, p_amount numeric, p_mode text, p_ref text, p_note text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id uuid; v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  IF coalesce(public.lwb_company_user_role(),'') NOT IN ('admin','accounts') THEN RAISE EXCEPTION 'Admin or Accounts required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_companies c WHERE c.id = p_company_id) THEN RAISE EXCEPTION 'Select the company'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter the amount'; END IF;
  IF p_date IS NULL OR p_date > v_today OR p_date < v_today - 400 THEN RAISE EXCEPTION 'Enter a valid date'; END IF;
  INSERT INTO public.lwb_company_payments(company_id, pay_date, amount, mode, ref_no, note, created_by)
  VALUES (p_company_id, p_date, round(p_amount,2), upper(btrim(coalesce(nullif(p_mode,''),'BANK'))), nullif(btrim(p_ref),''), nullif(btrim(p_note),''), auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_company_pay_cancel(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_company_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  UPDATE public.lwb_company_payments SET cancelled_at = now(), cancelled_by = auth.uid() WHERE id = p_id AND cancelled_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found or already cancelled'; END IF;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 8. Brand-wise overview (Admin, Sales Head, Accounts)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_company_overview(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := coalesce(public.lwb_company_user_role(),'');
  v_my uuid[] := public.lwb_my_companies();
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_from date := coalesce(p_from, date_trunc('month', (now() AT TIME ZONE 'Asia/Kolkata'))::date);
  v_to date := coalesce(p_to, (now() AT TIME ZONE 'Asia/Kolkata')::date);
  v_m0 date; v_m1 date;
  v_sales jsonb; v_month jsonb; v_out jsonb; v_pay jsonb := '{}'::jsonb; v_comp jsonb; v_t jsonb; v_c record; v_err text;
BEGIN
  IF v_role NOT IN ('admin','manager','accounts') THEN RAISE EXCEPTION 'Admin, Sales Head or Accounts required'; END IF;
  IF v_to < v_from THEN RAISE EXCEPTION 'To date is before From date'; END IF;
  v_m0 := date_trunc('month', v_to)::date; v_m1 := (v_m0 + interval '1 month')::date;

  SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'color', c.color,
           'supplier_credit_days', c.supplier_credit_days, 'market_credit_days', c.market_credit_days, 'pack_unit', c.pack_unit) ORDER BY c.sort_no, c.name), '[]'::jsonb)
    INTO v_comp FROM public.lwb_companies c WHERE c.active AND (v_my IS NULL OR c.id = ANY(v_my));

  -- Order value split by line value; the order total stays the same as on every other screen.
  WITH l AS (
    SELECT o.id AS oid, timezone('Asia/Kolkata', o.order_date::timestamptz)::date AS d, s.company_id AS c,
      CASE WHEN sum(coalesce(i.approved_qty, i.ordered_qty) * i.rate) OVER (PARTITION BY o.id) > 0 AND coalesce(o.total_amount,0) > 0
        THEN o.total_amount * coalesce(i.approved_qty, i.ordered_qty) * i.rate / sum(coalesce(i.approved_qty, i.ordered_qty) * i.rate) OVER (PARTITION BY o.id)
        ELSE coalesce(i.amount, coalesce(i.approved_qty, i.ordered_qty) * i.rate, 0) END AS amt,
      coalesce(i.approved_qty, i.ordered_qty, 0) AS cs, coalesce(s.pack_unit, co.pack_unit, 'CASE') AS u
    FROM public.orders o
    JOIN public.order_items i ON i.order_id = o.id
    LEFT JOIN public.sku_master s ON upper(btrim(s.sku_name)) = upper(btrim(i.sku_name))
    LEFT JOIN public.lwb_companies co ON co.id = s.company_id
    WHERE timezone('Asia/Kolkata', o.order_date::timestamptz)::date >= least(v_from, v_m0)
      AND timezone('Asia/Kolkata', o.order_date::timestamptz)::date < greatest(v_to + 1, v_m1)
      AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected')
  ), f AS (SELECT * FROM l WHERE v_my IS NULL OR l.c IS NULL OR l.c = ANY(v_my))
  SELECT
    (SELECT coalesce(jsonb_object_agg(coalesce(x.c::text,'none'), jsonb_build_object('amount', round(x.a,2), 'cases', x.q, 'boxes', x.b, 'orders', x.n)), '{}'::jsonb)
       FROM (SELECT f.c, sum(f.amt) a, coalesce(sum(f.cs) FILTER (WHERE f.u = 'CASE'),0) q, coalesce(sum(f.cs) FILTER (WHERE f.u = 'BOX'),0) b,
                    count(DISTINCT f.oid) n FROM f WHERE f.d BETWEEN v_from AND v_to GROUP BY f.c) x),
    (SELECT coalesce(jsonb_object_agg(coalesce(x.c::text,'none'), jsonb_build_object('amount', round(x.a,2), 'cases', x.q, 'boxes', x.b)), '{}'::jsonb)
       FROM (SELECT f.c, sum(f.amt) a, coalesce(sum(f.cs) FILTER (WHERE f.u = 'CASE'),0) q, coalesce(sum(f.cs) FILTER (WHERE f.u = 'BOX'),0) b
             FROM f WHERE f.d >= v_m0 AND f.d < v_m1 GROUP BY f.c) x)
  INTO v_sales, v_month;

  -- Month target: company total, else sum of salesman targets.
  SELECT coalesce(jsonb_object_agg(z.c::text, jsonb_build_object('amount', z.a, 'cases', z.q)), '{}'::jsonb) INTO v_t FROM (
    SELECT t.company_id AS c,
      coalesce(max(t.target_amount) FILTER (WHERE t.salesman_id IS NULL), sum(t.target_amount) FILTER (WHERE t.salesman_id IS NOT NULL), 0) AS a,
      coalesce(max(t.target_cases) FILTER (WHERE t.salesman_id IS NULL), sum(t.target_cases) FILTER (WHERE t.salesman_id IS NOT NULL), 0) AS q
    FROM public.lwb_company_targets t WHERE t.month = v_m0 AND (v_my IS NULL OR t.company_id = ANY(v_my)) GROUP BY t.company_id) z;

  -- Outstanding: each billed PO's due split by its loaded SKU value; overdue after party / company udhari days.
  BEGIN
    WITH r AS (SELECT * FROM public.lwb_tally_bill_rows(400) b WHERE b.due > 0.005),
    l AS (
      SELECT r.order_id, r.party, r.due, coalesce(r.invoice_date, r.dispatch_date, r.order_date) AS bd, s.company_id AS c,
        sum(coalesce(nullif(i.loaded_qty,0), i.approved_qty, i.ordered_qty, 0) * coalesce(i.rate,0)) AS v
      FROM r JOIN public.order_items i ON i.order_id = r.order_id
      LEFT JOIN public.sku_master s ON upper(btrim(s.sku_name)) = upper(btrim(i.sku_name))
      GROUP BY r.order_id, r.party, r.due, r.invoice_date, r.dispatch_date, r.order_date, s.company_id
    ), sh AS (
      SELECT l.*, CASE WHEN sum(l.v) OVER (PARTITION BY l.order_id) > 0 THEN l.due * l.v / sum(l.v) OVER (PARTITION BY l.order_id)
                       ELSE l.due / count(*) OVER (PARTITION BY l.order_id) END AS part,
        l.bd + coalesce((SELECT pc.credit_days FROM public.lwb_party_company_credit pc WHERE pc.party_key = upper(btrim(l.party)) AND pc.company_id = l.c),
                        (SELECT co.market_credit_days FROM public.lwb_companies co WHERE co.id = l.c), 0) AS due_date
      FROM l
    )
    SELECT coalesce(jsonb_object_agg(coalesce(x.c::text,'none'), jsonb_build_object('due', round(x.a,2), 'overdue', round(x.o,2), 'bills', x.n, 'parties', x.p)), '{}'::jsonb)
      INTO v_out
    FROM (SELECT sh.c, sum(sh.part) a, coalesce(sum(sh.part) FILTER (WHERE sh.due_date < v_today),0) o,
                 count(DISTINCT sh.order_id) n, count(DISTINCT upper(btrim(sh.party))) p
          FROM sh WHERE v_my IS NULL OR sh.c IS NULL OR sh.c = ANY(v_my) GROUP BY sh.c) x;
  EXCEPTION WHEN undefined_function OR undefined_table OR undefined_column THEN v_out := NULL; v_err := SQLERRM;
  END;

  -- To pay the company (Admin / Accounts).
  IF v_role IN ('admin','accounts') THEN
    BEGIN
      FOR v_c IN SELECT x.id FROM public.lwb_companies x WHERE x.active LOOP
        v_pay := v_pay || jsonb_build_object(v_c.id::text, (
          SELECT jsonb_build_object('balance', coalesce(round(sum(b.balance),2),0),
                   'overdue', coalesce(round(sum(b.balance) FILTER (WHERE b.due_date < v_today),2),0),
                   'today', coalesce(round(sum(b.balance) FILTER (WHERE b.due_date = v_today),2),0),
                   'next_due', min(b.due_date) FILTER (WHERE b.balance > 0.005 AND b.due_date >= v_today))
          FROM public.lwb_company_bill_rows(v_c.id) b));
      END LOOP;
    EXCEPTION WHEN undefined_table OR undefined_column THEN v_pay := NULL; v_err := coalesce(v_err || ' · ','') || SQLERRM;
    END;
  ELSE
    v_pay := NULL;
  END IF;

  RETURN jsonb_build_object('today', v_today, 'from', v_from, 'to', v_to, 'month', v_m0, 'limited', v_my IS NOT NULL,
    'companies', v_comp, 'sales', v_sales, 'month_sales', v_month, 'targets', v_t,
    'outstanding', v_out, 'payable', v_pay, 'error', v_err,
    'skus_without_company', (SELECT count(*) FROM public.sku_master s WHERE s.company_id IS NULL AND s.is_active IS NOT FALSE));
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_company_save(jsonb), public.lwb_set_sku_company(uuid[],uuid), public.lwb_brand_team(),
  public.lwb_set_user_companies(uuid,uuid[]), public.lwb_save_company_targets(date,uuid,jsonb), public.lwb_company_month(date),
  public.lwb_set_party_company_credit(text,uuid,integer), public.lwb_company_payables(uuid),
  public.lwb_company_pay(uuid,date,numeric,text,text,text), public.lwb_company_pay_cancel(uuid),
  public.lwb_company_overview(date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_company_save(jsonb), public.lwb_set_sku_company(uuid[],uuid), public.lwb_brand_team(),
  public.lwb_set_user_companies(uuid,uuid[]), public.lwb_save_company_targets(date,uuid,jsonb), public.lwb_company_month(date),
  public.lwb_set_party_company_credit(text,uuid,integer), public.lwb_company_payables(uuid),
  public.lwb_company_pay(uuid,date,numeric,text,text,text), public.lwb_company_pay_cancel(uuid),
  public.lwb_company_overview(date,date) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
