-- LUXURY WRIST BRAND ERP — BRAND DATA RESET (fresh start for one brand)
--
-- Applied automatically on merge (Supabase apply workflow). Safe to run again.
-- This file only creates the tables and functions below. It deletes NOTHING by itself.
--
-- Mohit (4 Nov 2026): remove everything done till today in Rajnigandha (POs / slips,
-- bills, payments, purchase bills, stock, company payments) so opening outstanding,
-- payments and stock can be entered fresh.
--
-- Page brand-reset.html (Admin only, Settings > Brand Data Reset):
-- 1. lwb_brand_reset_preview(company)  counts what would go. Read only.
-- 2. lwb_brand_reset_start(company, typed_name)  Admin types the brand name; freezes the list.
-- 3. lwb_brand_reset_step(reset_id)  called again and again by the page; each call removes a
--    small part (all or nothing per call) and says what is left. A failed call changes nothing
--    and can simply be called again.
-- 4. Every removed row is first copied to lwb_brand_reset_rows (backup, Admin download with
--    lwb_brand_reset_backup), so nothing is lost for good.
--
-- What is removed for the brand (company) B:
--  * POs whose every SKU line is an SKU of B, with every linked row (SKU lines, slips, rate OK,
--    loading, delivery, returns, bills, credit notes, PO payments, bells ...), found the same way
--    as Admin "Delete PO" does (database foreign keys + any order_id column).
--  * Party payments (no PO) and opening balances of parties who bought ONLY brand B.
--  * Purchase bills (Goods Inward) whose every line is an SKU of B, with claims / checks.
--  * Every stock movement of B's SKUs (opening, inward, dispatch, returns ...), stock transfers /
--    damage, night audit lines and goods in transit of B's SKUs  ->  B stock becomes 0.
--  * Payments made to company B (Company / Brand > Pay company). Accounts Dashboard cash / bank
--    entries are NOT touched (real money that went out stays in the cash book).
-- Kept: SKU Master, rate lists, party master, other brands, parties that also buy another brand
-- (their party payments / opening stay; shown on the page to check by hand).
-- A PO or purchase bill with SKUs of B AND another brand stops the reset (shown on the page).

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_brand_resets (
  id bigserial PRIMARY KEY,
  company_id uuid NOT NULL REFERENCES public.lwb_companies(id),
  company_name text NOT NULL,
  status text NOT NULL DEFAULT 'RUNNING' CHECK (status IN ('RUNNING','DONE')),
  sku_ids text[] NOT NULL DEFAULT '{}',
  sku_keys text[] NOT NULL DEFAULT '{}',
  order_ids uuid[] NOT NULL DEFAULT '{}',
  inward_ids uuid[] NOT NULL DEFAULT '{}',
  party_keys text[] NOT NULL DEFAULT '{}',
  counts jsonb NOT NULL DEFAULT '{}'::jsonb,
  started_by uuid,
  started_by_name text,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_brand_resets_running_uidx ON public.lwb_brand_resets(company_id) WHERE status = 'RUNNING';

-- Backup: one row per removed database row.
CREATE TABLE IF NOT EXISTS public.lwb_brand_reset_rows (
  id bigserial PRIMARY KEY,
  reset_id bigint NOT NULL REFERENCES public.lwb_brand_resets(id),
  tbl text NOT NULL,
  row_data jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_brand_reset_rows_reset_idx ON public.lwb_brand_reset_rows(reset_id, id);

ALTER TABLE public.lwb_brand_resets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_brand_reset_rows ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_brand_resets, public.lwb_brand_reset_rows FROM PUBLIC, anon, authenticated;

-- Active Admin only.
CREATE OR REPLACE FUNCTION public.lwb_brand_reset_admin()
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p
                 WHERE p.id = auth.uid() AND p.active IS TRUE AND lower(btrim(p.role)) = 'admin') THEN
    RAISE EXCEPTION 'Only an active Admin can reset brand data.';
  END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_brand_reset_admin() FROM PUBLIC, anon, authenticated;

-- Has table t a column c? (tables made by hand in Supabase may differ)
CREATE OR REPLACE FUNCTION public.lwb_brand_has_col(p_tbl text, p_col text)
RETURNS boolean LANGUAGE sql STABLE SET search_path = ''
AS $fn$
  SELECT to_regclass(p_tbl) IS NOT NULL AND EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = to_regclass(p_tbl) AND a.attname = p_col AND a.attnum > 0 AND NOT a.attisdropped);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_brand_has_col(text, text) FROM PUBLIC, anon, authenticated;

-- Party key of the main party of a name (group links followed).
CREATE OR REPLACE FUNCTION public.lwb_brand_party_key(p text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF to_regprocedure('public.lwb_party_parent(text)') IS NOT NULL THEN
    RETURN btrim(regexp_replace(upper(coalesce(public.lwb_party_parent(p),'')), '[^A-Z0-9]+', ' ', 'g'));
  END IF;
  RETURN btrim(regexp_replace(upper(coalesce(p,'')), '[^A-Z0-9]+', ' ', 'g'));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_brand_party_key(text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Linked-row walker (same idea as lwb_order_purge): counts (p_dry) or copies to the
-- backup and deletes the rows of p_tbl matching p_where, after doing the same for every
-- table that points at them.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_brand_purge(p_reset bigint, p_tbl regclass, p_where text, p_depth integer, p_dry boolean, p_counts jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  c record;
  v_child_where text;
  v_n bigint;
  v_key text;
BEGIN
  IF p_depth > 6 THEN
    RAISE EXCEPTION 'Linked records go too deep under %. Stopped, nothing changed.', p_tbl;
  END IF;

  FOR c IN
    SELECT k.conrelid::regclass AS child,
      (SELECT string_agg(format('%I', a.attname), ',' ORDER BY x.n)
         FROM unnest(k.conkey) WITH ORDINALITY x(att, n)
         JOIN pg_catalog.pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = x.att) AS ccols,
      (SELECT string_agg(format('%I', a.attname), ',' ORDER BY x.n)
         FROM unnest(k.confkey) WITH ORDINALITY x(att, n)
         JOIN pg_catalog.pg_attribute a ON a.attrelid = k.confrelid AND a.attnum = x.att) AS pcols
    FROM pg_catalog.pg_constraint k
    WHERE k.contype = 'f' AND k.confrelid = p_tbl AND k.conrelid <> p_tbl
      AND k.confdeltype NOT IN ('n','d')
      AND k.conrelid::regclass::text NOT IN ('lwb_order_audit','public.lwb_order_audit','lwb_brand_reset_rows','public.lwb_brand_reset_rows')
    ORDER BY 1::text
  LOOP
    v_child_where := format('(%s) IN (SELECT %s FROM %s WHERE %s)', c.ccols, c.pcols, p_tbl, p_where);
    p_counts := public.lwb_brand_purge(p_reset, c.child, v_child_where, p_depth + 1, p_dry, p_counts);
  END LOOP;

  -- Orders only: tables that keep an order_id uuid without a foreign key (bells, logs ...).
  IF p_tbl = 'public.orders'::regclass THEN
    FOR c IN
      SELECT a.attrelid::regclass AS child
      FROM pg_catalog.pg_attribute a
      JOIN pg_catalog.pg_class t ON t.oid = a.attrelid AND t.relkind IN ('r','p')
      JOIN pg_catalog.pg_namespace s ON s.oid = t.relnamespace AND s.nspname = 'public'
      WHERE a.attname = 'order_id' AND a.atttypid = 'uuid'::regtype AND NOT a.attisdropped
        AND t.relname NOT IN ('orders','lwb_order_audit','lwb_brand_reset_rows')
        AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                        WHERE k.contype = 'f' AND k.conrelid = a.attrelid AND k.confrelid = 'public.orders'::regclass
                          AND a.attnum = ANY(k.conkey))
      ORDER BY 1::text
    LOOP
      v_child_where := format('order_id IN (SELECT id FROM public.orders WHERE %s)', p_where);
      p_counts := public.lwb_brand_purge(p_reset, c.child, v_child_where, p_depth + 1, p_dry, p_counts);
    END LOOP;
  END IF;

  v_key := replace(p_tbl::text, 'public.', '');
  IF p_dry THEN
    EXECUTE format('SELECT count(*) FROM %s WHERE %s', p_tbl, p_where) INTO v_n;
    IF v_n > 0 THEN
      p_counts := jsonb_set(p_counts, ARRAY[v_key], to_jsonb(v_n + coalesce((p_counts->>v_key)::bigint, 0)));
    END IF;
  ELSE
    EXECUTE format('INSERT INTO public.lwb_brand_reset_rows(reset_id, tbl, row_data) SELECT %s, %L, to_jsonb(x) FROM %s x WHERE %s',
                   p_reset, v_key, p_tbl, p_where);
    EXECUTE format('DELETE FROM %s WHERE %s', p_tbl, p_where);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN
      p_counts := jsonb_set(p_counts, ARRAY[v_key], to_jsonb(v_n + coalesce((p_counts->>v_key)::bigint, 0)));
    END IF;
  END IF;
  RETURN p_counts;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_brand_purge(bigint, regclass, text, integer, boolean, jsonb) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- What belongs to brand p_company today.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_brand_scope(p_company uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_ids text[]; v_keys text[];
  v_orders uuid[]; v_mixed jsonb; v_parties text[]; v_mixed_parties jsonb;
  v_inwards uuid[]; v_mixed_in jsonb;
BEGIN
  SELECT coalesce(array_agg(s.id::text), '{}'), coalesce(array_agg(DISTINCT upper(btrim(s.sku_name))), '{}')
    INTO v_ids, v_keys
  FROM public.sku_master s WHERE s.company_id = p_company;

  -- POs with at least one SKU line of the brand (+ slips made for the brand).
  SELECT coalesce(array_agg(DISTINCT x), '{}') INTO v_orders FROM (
    SELECT i.order_id AS x FROM public.order_items i WHERE upper(btrim(i.sku_name)) = ANY(v_keys)
    UNION
    SELECT q.order_id FROM public.lwb_quick_slips q
    WHERE to_regclass('public.lwb_quick_slips') IS NOT NULL AND q.company_id = p_company
  ) z WHERE x IS NOT NULL;

  -- ... of which some also have another brand's SKU: these stop the reset.
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'order_no', o.order_no, 'party', o.customer_name,
           'date', o.order_date, 'other_skus', m.other) ORDER BY o.order_no), '[]'::jsonb)
    INTO v_mixed
  FROM public.orders o
  JOIN (SELECT i.order_id, string_agg(DISTINCT i.sku_name, ', ') AS other
        FROM public.order_items i
        WHERE i.order_id = ANY(v_orders) AND NOT (upper(btrim(i.sku_name)) = ANY(v_keys))
        GROUP BY i.order_id) m ON m.order_id = o.id;

  -- Parties who bought only this brand (every PO of the main party is in v_orders).
  WITH p AS (
    SELECT public.lwb_brand_party_key(o.customer_name) AS k, bool_and(o.id = ANY(v_orders)) AS only_b,
           bool_or(o.id = ANY(v_orders)) AS any_b, max(o.customer_name) AS n
    FROM public.orders o WHERE nullif(btrim(o.customer_name),'') IS NOT NULL GROUP BY 1
  )
  SELECT coalesce(array_agg(p.k) FILTER (WHERE p.only_b AND p.any_b), '{}'),
         coalesce(jsonb_agg(jsonb_build_object('key', p.k, 'party', p.n) ORDER BY p.n) FILTER (WHERE p.any_b AND NOT p.only_b), '[]'::jsonb)
    INTO v_parties, v_mixed_parties
  FROM p;

  -- Purchase bills with at least one line of the brand.
  IF to_regclass('public.lwb_goods_inward_items') IS NOT NULL THEN
    SELECT coalesce(array_agg(DISTINCT i.inward_id), '{}') INTO v_inwards
    FROM public.lwb_goods_inward_items i WHERE i.sku_id::text = ANY(v_ids);
    SELECT coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'invoice_no', g.invoice_no, 'supplier', g.supplier_name,
             'date', g.received_date) ORDER BY g.received_date), '[]'::jsonb)
      INTO v_mixed_in
    FROM public.lwb_goods_inward g
    WHERE g.id = ANY(v_inwards) AND EXISTS (SELECT 1 FROM public.lwb_goods_inward_items i
                                            WHERE i.inward_id = g.id AND NOT (i.sku_id::text = ANY(v_ids)));
  END IF;

  RETURN jsonb_build_object('sku_ids', to_jsonb(v_ids), 'sku_keys', to_jsonb(v_keys),
    'order_ids', to_jsonb(v_orders), 'mixed_orders', v_mixed,
    'party_keys', to_jsonb(v_parties), 'mixed_parties', v_mixed_parties,
    'inward_ids', to_jsonb(coalesce(v_inwards, '{}')), 'mixed_inwards', coalesce(v_mixed_in, '[]'::jsonb));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_brand_scope(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_brand_jarr_uuid(p jsonb)
RETURNS uuid[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT coalesce(array_agg(x::uuid), '{}') FROM jsonb_array_elements_text(coalesce(p,'[]'::jsonb)) x $fn$;
CREATE OR REPLACE FUNCTION public.lwb_brand_jarr_text(p jsonb)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT coalesce(array_agg(x), '{}') FROM jsonb_array_elements_text(coalesce(p,'[]'::jsonb)) x $fn$;
REVOKE ALL ON FUNCTION public.lwb_brand_jarr_uuid(jsonb), public.lwb_brand_jarr_text(jsonb) FROM PUBLIC, anon, authenticated;

-- Where-clauses for the parts that are not POs / purchase bills.
CREATE OR REPLACE FUNCTION public.lwb_brand_where(p_part text, p_company uuid, p_sku_ids text[], p_sku_keys text[], p_parties text[])
RETURNS text LANGUAGE plpgsql STABLE SET search_path = ''
AS $fn$
BEGIN
  RETURN CASE p_part
    WHEN 'party_payments' THEN format('order_id IS NULL AND public.lwb_brand_party_key(party) = ANY(%L::text[])', p_parties)
    WHEN 'opening' THEN format('public.lwb_brand_party_key(customer_name) = ANY(%L::text[])', p_parties)
    WHEN 'sku_id' THEN format('sku_id::text = ANY(%L::text[])', p_sku_ids)
    WHEN 'sku_name' THEN format('upper(btrim(sku_name)) = ANY(%L::text[])', p_sku_keys)
    WHEN 'company' THEN format('company_id = %L::uuid', p_company)
  END;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_brand_where(text, uuid, text[], text[], text[]) FROM PUBLIC, anon, authenticated;

-- Stock-type tables cleared by SKU (name of table, how it is matched).
CREATE OR REPLACE FUNCTION public.lwb_brand_stock_tables()
RETURNS TABLE (tbl text, how text) LANGUAGE sql STABLE SET search_path = ''
AS $fn$
  SELECT t.tbl, CASE WHEN public.lwb_brand_has_col(t.tbl, 'sku_id') THEN 'sku_id'
                     WHEN public.lwb_brand_has_col(t.tbl, 'sku_name') THEN 'sku_name' END
  FROM (VALUES (1,'public.lwb_stock_moves'), (2,'public.lwb_stock_audit_lines'), (3,'public.lwb_stock_transit'),
               (4,'public.lwb_inventory_movements')) t(n, tbl)
  WHERE to_regclass(t.tbl) IS NOT NULL
    AND (public.lwb_brand_has_col(t.tbl, 'sku_id') OR public.lwb_brand_has_col(t.tbl, 'sku_name'))
  ORDER BY t.n;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_brand_stock_tables() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Preview (read only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_brand_reset_preview(p_company uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_name text; s jsonb;
  v_orders uuid[]; v_inwards uuid[]; v_parties text[]; v_ids text[]; v_keys text[];
  v_linked jsonb := '{}'::jsonb; v_po jsonb; v_pay jsonb; v_ppay jsonb; v_open jsonb; v_pur jsonb; v_cpay jsonb;
  v_mixed_adv jsonb := '[]'::jsonb; v_stock jsonb := '[]'::jsonb; v_bank bigint := 0;
  t record; v_running bigint;
BEGIN
  PERFORM public.lwb_brand_reset_admin();
  SELECT c.name INTO v_name FROM public.lwb_companies c WHERE c.id = p_company;
  IF v_name IS NULL THEN RAISE EXCEPTION 'Brand not found.'; END IF;

  s := public.lwb_brand_scope(p_company);
  v_orders := public.lwb_brand_jarr_uuid(s->'order_ids');
  v_inwards := public.lwb_brand_jarr_uuid(s->'inward_ids');
  v_parties := public.lwb_brand_jarr_text(s->'party_keys');
  v_ids := public.lwb_brand_jarr_text(s->'sku_ids');
  v_keys := public.lwb_brand_jarr_text(s->'sku_keys');

  SELECT jsonb_build_object('n', count(*), 'from', min(o.order_date), 'to', max(o.order_date),
           'amount', coalesce((SELECT round(sum(coalesce((to_jsonb(i)->>'approved_qty')::numeric, (to_jsonb(i)->>'ordered_qty')::numeric, 0) * coalesce((to_jsonb(i)->>'rate')::numeric,0)),2)
                               FROM public.order_items i WHERE i.order_id = ANY(v_orders)), 0))
    INTO v_po FROM public.orders o WHERE o.id = ANY(v_orders);

  IF to_regclass('public.lwb_tally_payments') IS NOT NULL THEN
    SELECT jsonb_build_object('n', count(*), 'amount', coalesce(sum(p.amount),0)) INTO v_pay
    FROM public.lwb_tally_payments p WHERE p.order_id = ANY(v_orders) AND p.cancelled_at IS NULL;
    IF public.lwb_brand_has_col('public.lwb_tally_payments', 'party') THEN
      EXECUTE format('SELECT jsonb_build_object(''n'', count(*), ''amount'', coalesce(sum(amount) FILTER (WHERE cancelled_at IS NULL),0)) FROM public.lwb_tally_payments WHERE %s',
                     public.lwb_brand_where('party_payments', p_company, v_ids, v_keys, v_parties)) INTO v_ppay;
      -- Parties that also buy another brand: money of a party payment set against this brand's POs becomes advance again.
      IF to_regclass('public.lwb_party_allocs') IS NOT NULL THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object('party', z.party, 'amount', z.amt) ORDER BY z.party), '[]'::jsonb) INTO v_mixed_adv
        FROM (SELECT max(o.customer_name) AS party, sum(a.amount) AS amt
              FROM public.lwb_party_allocs a JOIN public.orders o ON o.id = a.order_id
              WHERE a.order_id = ANY(v_orders) AND a.cancelled_at IS NULL
                AND NOT (public.lwb_brand_party_key(o.customer_name) = ANY(v_parties))
              GROUP BY public.lwb_brand_party_key(o.customer_name)) z;
      END IF;
    END IF;
  END IF;

  IF to_regclass('public.lwb_party_opening_balances') IS NOT NULL THEN
    EXECUTE format('SELECT jsonb_build_object(''n'', count(*), ''amount'', coalesce(sum(amount),0)) FROM public.lwb_party_opening_balances WHERE %s',
                   public.lwb_brand_where('opening', p_company, v_ids, v_keys, v_parties)) INTO v_open;
  END IF;

  IF to_regclass('public.lwb_goods_inward_items') IS NOT NULL THEN
    SELECT jsonb_build_object('n', cardinality(v_inwards), 'amount', coalesce(round(sum(i.total_amount),2),0)) INTO v_pur
    FROM public.lwb_goods_inward_items i WHERE i.inward_id = ANY(v_inwards);
  END IF;

  SELECT jsonb_build_object('n', count(*), 'amount', coalesce(sum(p.amount) FILTER (WHERE p.cancelled_at IS NULL),0)) INTO v_cpay
  FROM public.lwb_company_payments p WHERE to_regclass('public.lwb_company_payments') IS NOT NULL AND p.company_id = p_company;

  -- Every row that would go, table by table.
  IF cardinality(v_orders) > 0 THEN
    v_linked := public.lwb_brand_purge(0, 'public.orders'::regclass, format('id = ANY(%L::uuid[])', v_orders), 0, true, v_linked);
  END IF;
  IF cardinality(v_parties) > 0 AND public.lwb_brand_has_col('public.lwb_tally_payments', 'party') THEN
    v_linked := public.lwb_brand_purge(0, 'public.lwb_tally_payments'::regclass,
                  public.lwb_brand_where('party_payments', p_company, v_ids, v_keys, v_parties), 0, true, v_linked);
  END IF;
  IF cardinality(v_parties) > 0 AND to_regclass('public.lwb_party_opening_balances') IS NOT NULL THEN
    v_linked := public.lwb_brand_purge(0, 'public.lwb_party_opening_balances'::regclass,
                  public.lwb_brand_where('opening', p_company, v_ids, v_keys, v_parties), 0, true, v_linked);
  END IF;
  IF cardinality(v_inwards) > 0 THEN
    v_linked := public.lwb_brand_purge(0, 'public.lwb_goods_inward'::regclass, format('id = ANY(%L::uuid[])', v_inwards), 0, true, v_linked);
  END IF;
  IF cardinality(v_ids) > 0 THEN
    FOR t IN SELECT * FROM public.lwb_brand_stock_tables() LOOP
      v_linked := public.lwb_brand_purge(0, t.tbl::regclass, public.lwb_brand_where(t.how, p_company, v_ids, v_keys, v_parties), 0, true, v_linked);
    END LOOP;
  END IF;
  IF to_regclass('public.lwb_company_payments') IS NOT NULL THEN
    v_linked := public.lwb_brand_purge(0, 'public.lwb_company_payments'::regclass, public.lwb_brand_where('company', p_company, v_ids, v_keys, v_parties), 0, true, v_linked);
  END IF;

  -- Stock today per SKU (what becomes 0).
  IF to_regclass('public.lwb_live_stock') IS NOT NULL THEN
    EXECUTE format('SELECT coalesce(jsonb_agg(jsonb_build_object(''sku'', l.sku_name, ''pcs'', l.saleable_pcs, ''per_case'', l.pcs_per_case) ORDER BY l.sku_name), ''[]''::jsonb)
                    FROM public.lwb_live_stock l WHERE upper(btrim(l.sku_name)) = ANY(%L::text[]) AND coalesce(l.saleable_pcs,0) <> 0', v_keys)
      INTO v_stock;
  END IF;

  -- Bank statement lines matched to a payment that will go (they will point at nothing).
  IF public.lwb_brand_has_col('public.lwb_bank_stmt_lines', 'link_id') AND to_regclass('public.lwb_tally_payments') IS NOT NULL THEN
    SELECT count(*) INTO v_bank FROM public.lwb_bank_stmt_lines b
    WHERE b.link_id IN (SELECT p.id FROM public.lwb_tally_payments p WHERE p.order_id = ANY(v_orders));
  END IF;

  SELECT r.id INTO v_running FROM public.lwb_brand_resets r WHERE r.company_id = p_company AND r.status = 'RUNNING';

  RETURN jsonb_build_object('company', jsonb_build_object('id', p_company, 'name', v_name),
    'skus', cardinality(v_ids), 'pos', v_po, 'po_payments', coalesce(v_pay, '{}'::jsonb),
    'party_payments', coalesce(v_ppay, '{}'::jsonb), 'opening', coalesce(v_open, '{}'::jsonb),
    'purchases', coalesce(v_pur, '{}'::jsonb), 'company_payments', coalesce(v_cpay, '{}'::jsonb),
    'only_parties', cardinality(v_parties), 'mixed_parties', s->'mixed_parties', 'mixed_advance', v_mixed_adv,
    'mixed_orders', s->'mixed_orders', 'mixed_inwards', s->'mixed_inwards',
    'stock', v_stock, 'bank_lines', v_bank, 'linked', v_linked, 'running', v_running,
    'last', (SELECT jsonb_build_object('id', r.id, 'at', r.finished_at, 'by', r.started_by_name)
             FROM public.lwb_brand_resets r WHERE r.company_id = p_company AND r.status = 'DONE' ORDER BY r.id DESC LIMIT 1));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_brand_reset_preview(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_brand_reset_preview(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Start: Admin types the brand name. Freezes what will be removed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_brand_reset_start(p_company uuid, p_typed_name text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_name text; s jsonb; v_id bigint; v_by text;
BEGIN
  PERFORM public.lwb_brand_reset_admin();
  SELECT c.name INTO v_name FROM public.lwb_companies c WHERE c.id = p_company;
  IF v_name IS NULL THEN RAISE EXCEPTION 'Brand not found.'; END IF;
  IF upper(btrim(coalesce(p_typed_name,''))) <> upper(btrim(v_name)) THEN
    RAISE EXCEPTION 'Type the brand name % exactly to confirm.', v_name;
  END IF;

  SELECT r.id INTO v_id FROM public.lwb_brand_resets r WHERE r.company_id = p_company AND r.status = 'RUNNING';
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;   -- finish the one already started

  s := public.lwb_brand_scope(p_company);
  IF jsonb_array_length(s->'mixed_orders') > 0 THEN
    RAISE EXCEPTION '% PO(s) have % and another brand together. Fix them first (see list).', jsonb_array_length(s->'mixed_orders'), v_name;
  END IF;
  IF jsonb_array_length(s->'mixed_inwards') > 0 THEN
    RAISE EXCEPTION '% purchase bill(s) have % and another brand together. Fix them first (see list).', jsonb_array_length(s->'mixed_inwards'), v_name;
  END IF;

  SELECT p.full_name INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.lwb_brand_resets(company_id, company_name, sku_ids, sku_keys, order_ids, inward_ids, party_keys, started_by, started_by_name)
  VALUES (p_company, v_name, public.lwb_brand_jarr_text(s->'sku_ids'), public.lwb_brand_jarr_text(s->'sku_keys'),
          public.lwb_brand_jarr_uuid(s->'order_ids'), public.lwb_brand_jarr_uuid(s->'inward_ids'),
          public.lwb_brand_jarr_text(s->'party_keys'), auth.uid(), v_by)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_brand_reset_start(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_brand_reset_start(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. One step. Returns {done, part, left, counts}. All or nothing per call.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_brand_reset_step(p_reset bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  r public.lwb_brand_resets%ROWTYPE;
  v_ids uuid[]; v_left bigint := 0; v_part text; v_counts jsonb := '{}'::jsonb; v_w text; t record; v_n bigint;
BEGIN
  PERFORM public.lwb_brand_reset_admin();
  SELECT * INTO r FROM public.lwb_brand_resets WHERE id = p_reset FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reset not found.'; END IF;
  IF r.status = 'DONE' THEN RETURN jsonb_build_object('done', true, 'counts', r.counts); END IF;

  -- a) POs, 40 at a time
  SELECT array_agg(o.id) INTO v_ids FROM (SELECT o.id FROM public.orders o WHERE o.id = ANY(r.order_ids) ORDER BY o.id LIMIT 40) o;
  IF v_ids IS NOT NULL THEN
    v_part := 'pos';
    v_counts := public.lwb_brand_purge(p_reset, 'public.orders'::regclass, format('id = ANY(%L::uuid[])', v_ids), 0, false, v_counts);
    SELECT count(*) INTO v_left FROM public.orders o WHERE o.id = ANY(r.order_ids);
  END IF;

  -- b) party payments + opening balances of parties who bought only this brand
  IF v_part IS NULL AND cardinality(r.party_keys) > 0 THEN
    IF public.lwb_brand_has_col('public.lwb_tally_payments', 'party') THEN
      v_w := public.lwb_brand_where('party_payments', r.company_id, r.sku_ids, r.sku_keys, r.party_keys);
      EXECUTE format('SELECT count(*) FROM public.lwb_tally_payments WHERE %s', v_w) INTO v_n;
      IF v_n > 0 THEN
        v_part := 'party_payments';
        v_counts := public.lwb_brand_purge(p_reset, 'public.lwb_tally_payments'::regclass, v_w, 0, false, v_counts);
        -- their split rows (receipt_id has no foreign key)
        IF to_regclass('public.lwb_party_allocs') IS NOT NULL THEN
          v_counts := public.lwb_brand_purge(p_reset, 'public.lwb_party_allocs'::regclass,
            format('receipt_id IN (SELECT (b.row_data->>''receipt_id'')::uuid FROM public.lwb_brand_reset_rows b WHERE b.reset_id = %s AND b.tbl = ''lwb_tally_payments'' AND b.row_data->>''receipt_id'' IS NOT NULL)', p_reset),
            0, false, v_counts);
        END IF;
      END IF;
    END IF;
    IF to_regclass('public.lwb_party_opening_balances') IS NOT NULL THEN
      v_w := public.lwb_brand_where('opening', r.company_id, r.sku_ids, r.sku_keys, r.party_keys);
      EXECUTE format('SELECT count(*) FROM public.lwb_party_opening_balances WHERE %s', v_w) INTO v_n;
      IF v_n > 0 THEN
        v_part := 'party_payments';
        v_counts := public.lwb_brand_purge(p_reset, 'public.lwb_party_opening_balances'::regclass, v_w, 0, false, v_counts);
      END IF;
    END IF;
  END IF;

  -- c) purchase bills, 40 at a time
  IF v_part IS NULL AND cardinality(r.inward_ids) > 0 THEN
    SELECT array_agg(g.id) INTO v_ids FROM (SELECT g.id FROM public.lwb_goods_inward g WHERE g.id = ANY(r.inward_ids) ORDER BY g.id LIMIT 40) g;
    IF v_ids IS NOT NULL THEN
      v_part := 'purchases';
      v_counts := public.lwb_brand_purge(p_reset, 'public.lwb_goods_inward'::regclass, format('id = ANY(%L::uuid[])', v_ids), 0, false, v_counts);
      SELECT count(*) INTO v_left FROM public.lwb_goods_inward g WHERE g.id = ANY(r.inward_ids);
    END IF;
  END IF;

  -- d) stock rows of the brand's SKUs, one table per call
  IF v_part IS NULL AND cardinality(r.sku_ids) > 0 THEN
    FOR t IN SELECT * FROM public.lwb_brand_stock_tables() LOOP
      v_w := public.lwb_brand_where(t.how, r.company_id, r.sku_ids, r.sku_keys, r.party_keys);
      EXECUTE format('SELECT count(*) FROM %s WHERE %s', t.tbl, v_w) INTO v_n;
      IF v_n > 0 THEN
        v_part := 'stock';
        v_counts := public.lwb_brand_purge(p_reset, t.tbl::regclass, v_w, 0, false, v_counts);
        v_left := 1;
        EXIT;
      END IF;
    END LOOP;
  END IF;

  -- e) payments to the company
  IF v_part IS NULL AND to_regclass('public.lwb_company_payments') IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.lwb_company_payments p WHERE p.company_id = r.company_id) THEN
    v_part := 'company_payments';
    v_counts := public.lwb_brand_purge(p_reset, 'public.lwb_company_payments'::regclass,
                  public.lwb_brand_where('company', r.company_id, r.sku_ids, r.sku_keys, r.party_keys), 0, false, v_counts);
  END IF;

  -- Cheque details / bank checks of payments removed in this step (src_id has no foreign key).
  IF v_part IS NOT NULL THEN
    FOR t IN SELECT x.tbl FROM (VALUES ('public.lwb_acc_cheques'), ('public.lwb_acc_verify')) x(tbl)
             WHERE public.lwb_brand_has_col(x.tbl, 'src_id') LOOP
      v_counts := public.lwb_brand_purge(p_reset, t.tbl::regclass,
        format('src_id::text IN (SELECT b.row_data->>''id'' FROM public.lwb_brand_reset_rows b WHERE b.reset_id = %s AND b.tbl <> %L)',
               p_reset, replace(t.tbl, 'public.', '')), 0, false, v_counts);
    END LOOP;
  END IF;

  -- add this step's counts to the total
  UPDATE public.lwb_brand_resets x SET counts = (
      SELECT coalesce(jsonb_object_agg(k, (coalesce((x.counts->>k)::bigint,0) + coalesce((v_counts->>k)::bigint,0))), '{}'::jsonb)
      FROM (SELECT jsonb_object_keys(x.counts) AS k UNION SELECT jsonb_object_keys(v_counts)) z),
    status = CASE WHEN v_part IS NULL THEN 'DONE' ELSE status END,
    finished_at = CASE WHEN v_part IS NULL THEN now() ELSE finished_at END
  WHERE x.id = p_reset
  RETURNING * INTO r;

  RETURN jsonb_build_object('done', v_part IS NULL, 'part', v_part, 'left', v_left, 'step', v_counts, 'counts', r.counts);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_brand_reset_step(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_brand_reset_step(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Backup rows of a reset (Admin download), 2000 per call.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_brand_reset_backup(p_reset bigint, p_after bigint DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  PERFORM public.lwb_brand_reset_admin();
  RETURN jsonb_build_object(
    'reset', (SELECT to_jsonb(r) - 'sku_ids' FROM public.lwb_brand_resets r WHERE r.id = p_reset),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('n', b.id, 'table', b.tbl, 'row', b.row_data) ORDER BY b.id)
                      FROM (SELECT * FROM public.lwb_brand_reset_rows WHERE reset_id = p_reset AND id > coalesce(p_after,0)
                            ORDER BY id LIMIT 2000) b), '[]'::jsonb));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_brand_reset_backup(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_brand_reset_backup(bigint, bigint) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
