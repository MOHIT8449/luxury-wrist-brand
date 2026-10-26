-- LUXURY WRIST BRAND ERP — LIVE STOCK + GOODS IN TRANSIT ON PO ENTRY
--
-- RUN ONCE in Supabase SQL Editor, after lwb_sales_team_setup.sql. Safe to run again.
--
-- PO Entry shows, under each SKU in small light text:
--   Godown <cases> · On the way <cases> · Total <cases>
-- * Godown     = saleable stock from the existing lwb_live_stock view (pcs / pcs per case).
-- * On the way = Goods in Transit entries (company stock ordered / dispatched, truck not
--                received yet). Godown team, Sales Head or Admin add them on the new
--                "Goods in Transit" page and mark them Received when the truck is unloaded.
-- Only the roles ticked in Sales Team Setup > Morning Plan see stock (Admin always).
-- Default: Admin, Sales Head (manager), Godown (warehouse).
--
-- Only lwb_sales_settings (one new column) and the new lwb_stock_transit table are written.
-- Stock movements, orders, bills, payments and Tally are NOT changed.

BEGIN;

ALTER TABLE public.lwb_sales_settings
  ADD COLUMN IF NOT EXISTS stock_view_roles text[] NOT NULL DEFAULT ARRAY['admin','manager','warehouse'];

CREATE OR REPLACE FUNCTION public.lwb_can_view_stock()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND (lower(btrim(p.role)) = 'admin'
        OR lower(btrim(p.role)) = ANY (coalesce((SELECT s.stock_view_roles FROM public.lwb_sales_settings s WHERE s.id = 1), ARRAY['admin','manager','warehouse']))
        OR (lower(btrim(p.role)) = 'salesman' AND 'sales' = ANY (coalesce((SELECT s.stock_view_roles FROM public.lwb_sales_settings s WHERE s.id = 1), '{}')))));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_stock_keeper()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager','warehouse'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_can_view_stock(), public.lwb_stock_keeper() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_can_view_stock(), public.lwb_stock_keeper() TO authenticated;

-- Which roles see stock. Admin / Sales Head change it.
CREATE OR REPLACE FUNCTION public.lwb_save_stock_view_roles(p_roles text[])
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v text[];
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  SELECT coalesce(array_agg(DISTINCT r ORDER BY r), '{}') INTO v
  FROM unnest(coalesce(p_roles,'{}')) AS t(x), lower(btrim(x)) AS r
  WHERE r IN ('admin','manager','warehouse','sales','accounts','transport');
  v := (SELECT array_agg(DISTINCT r ORDER BY r) FROM unnest(v || ARRAY['admin']) AS r);
  UPDATE public.lwb_sales_settings SET stock_view_roles = v, updated_at = now(), updated_by = auth.uid() WHERE id = 1;
  RETURN v;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_save_stock_view_roles(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_save_stock_view_roles(text[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- Goods in Transit
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_stock_transit (
  id bigserial PRIMARY KEY,
  sku_name text NOT NULL,
  cases integer NOT NULL CHECK (cases > 0),
  ref_no text,                 -- company invoice / truck no.
  expected_date date,
  status text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','RECEIVED','CANCELLED')),
  created_by uuid NOT NULL DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  closed_by uuid,
  closed_at timestamptz
);
CREATE INDEX IF NOT EXISTS lwb_stock_transit_open_idx ON public.lwb_stock_transit(status, sku_name);

ALTER TABLE public.lwb_stock_transit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_stock_transit_read ON public.lwb_stock_transit;
CREATE POLICY lwb_stock_transit_read ON public.lwb_stock_transit FOR SELECT TO authenticated
  USING (public.lwb_stock_keeper() OR public.lwb_can_view_stock());
REVOKE ALL ON TABLE public.lwb_stock_transit FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_stock_transit TO authenticated;
REVOKE ALL ON SEQUENCE public.lwb_stock_transit_id_seq FROM PUBLIC, anon, authenticated;

-- p_lines: [{sku_name, cases}] — one truck / invoice can carry many SKUs.
CREATE OR REPLACE FUNCTION public.lwb_add_stock_transit(p_ref text, p_expected date, p_lines jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE e jsonb; v_sku text; v_n integer := 0;
BEGIN
  IF NOT public.lwb_stock_keeper() THEN RAISE EXCEPTION 'Godown team, Sales Head or Admin only'; END IF;
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) = 0 THEN RAISE EXCEPTION 'Add at least one SKU'; END IF;
  FOR e IN SELECT v FROM jsonb_array_elements(p_lines) AS t(v) LOOP
    SELECT s.sku_name INTO v_sku FROM public.sku_master s
    WHERE upper(btrim(s.sku_name)) = upper(btrim(coalesce(e->>'sku_name',''))) LIMIT 1;
    IF v_sku IS NULL THEN RAISE EXCEPTION 'SKU % is not in SKU Master', coalesce(e->>'sku_name','(blank)'); END IF;
    IF coalesce(e->>'cases','') !~ '^\d{1,6}$' OR (e->>'cases')::integer < 1 THEN RAISE EXCEPTION 'Enter whole cases for %', v_sku; END IF;
    INSERT INTO public.lwb_stock_transit(sku_name, cases, ref_no, expected_date, created_by)
    VALUES (v_sku, (e->>'cases')::integer, left(nullif(upper(btrim(coalesce(p_ref,''))),''), 60), p_expected, auth.uid());
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$fn$;

-- RECEIVED (truck unloaded, now in godown stock) or CANCELLED (entered by mistake).
CREATE OR REPLACE FUNCTION public.lwb_close_stock_transit(p_ids bigint[], p_status text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_status text := upper(btrim(coalesce(p_status,''))); v_n integer;
BEGIN
  IF NOT public.lwb_stock_keeper() THEN RAISE EXCEPTION 'Godown team, Sales Head or Admin only'; END IF;
  IF v_status NOT IN ('RECEIVED','CANCELLED') THEN RAISE EXCEPTION 'Invalid status'; END IF;
  UPDATE public.lwb_stock_transit SET status = v_status, closed_by = auth.uid(), closed_at = now()
  WHERE id = ANY (p_ids) AND status = 'OPEN';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_add_stock_transit(text,date,jsonb), public.lwb_close_stock_transit(bigint[],text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_add_stock_transit(text,date,jsonb), public.lwb_close_stock_transit(bigint[],text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Stock per SKU for PO Entry. Empty for roles that may not see stock.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_po_stock()
RETURNS TABLE (sku_name text, godown_cases numeric, transit_cases bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_can_view_stock() THEN RETURN; END IF;
  RETURN QUERY
  WITH g AS (
    SELECT upper(btrim(l.sku_name)) AS k, max(l.sku_name) AS n,
      floor(sum(coalesce(l.saleable_pcs,0)::numeric / nullif(l.pcs_per_case,0))) AS c
    FROM public.lwb_live_stock l GROUP BY 1
  ), t AS (
    SELECT upper(btrim(x.sku_name)) AS k, max(x.sku_name) AS n, sum(x.cases) AS c
    FROM public.lwb_stock_transit x WHERE x.status = 'OPEN' GROUP BY 1
  )
  SELECT coalesce(g.n, t.n), coalesce(g.c, 0), coalesce(t.c, 0)::bigint
  FROM g FULL JOIN t ON t.k = g.k;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_stock() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_stock() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: who sees stock, and the first few SKUs.
SELECT stock_view_roles FROM public.lwb_sales_settings WHERE id = 1;
