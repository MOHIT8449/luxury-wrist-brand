-- LUXURY WRIST BRAND ERP — PO ENTRY RATES (Phase 2)
--
-- RUN ONCE in Supabase SQL Editor, AFTER lwb_rate_scheme_setup.sql.
-- Safe to run again.
--
-- What it adds:
--  1. lwb_rate_pack_skus     : which Rate & Scheme pack each ERP SKU uses
--                              (SKU Master name -> pack). Admin / Manager set
--                              it on the Rate & Scheme page, "SKU Link" tab.
--  2. lwb_link_rate_skus()   : save those links (Admin or Manager only).
--  3. lwb_order_rates()      : Slab 3 rate for every linked SKU, for the PO
--                              entry page. Salesman gets only the sale rate,
--                              never landing, GR or scheme.
--  4. lwb_party_last_rates() : the last PO rate of each SKU for one party,
--                              so a new PO starts from the party's last rate.
--
-- Read only for orders. NO order, bill, stock, ledger or Tally data is changed.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. SKU -> rate pack link (keyed by SKU name, like order_items.sku_name)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_rate_pack_skus (
  sku_key text PRIMARY KEY CHECK (sku_key <> '' AND sku_key = upper(btrim(sku_key))),
  pack_id uuid NOT NULL REFERENCES public.lwb_rate_packs(id) ON DELETE CASCADE,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

ALTER TABLE public.lwb_rate_pack_skus ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_rate_pack_skus_read ON public.lwb_rate_pack_skus;
CREATE POLICY lwb_rate_pack_skus_read ON public.lwb_rate_pack_skus
  FOR SELECT TO authenticated USING (public.lwb_rate_editor());
REVOKE ALL ON TABLE public.lwb_rate_pack_skus FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_rate_pack_skus TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Save links: p_links = [{sku_name, pack_id}] ; pack_id null = remove link
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_link_rate_skus(p_links jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_link jsonb;
  v_key text;
  v_pack uuid;
  v_count integer := 0;
BEGIN
  IF NOT public.lwb_rate_editor() THEN
    RAISE EXCEPTION 'Only an active Admin or Manager can link SKUs to rates';
  END IF;
  IF jsonb_typeof(COALESCE(p_links,'null'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Link list is missing';
  END IF;

  FOR v_link IN SELECT * FROM jsonb_array_elements(p_links) LOOP
    v_key := upper(btrim(COALESCE(v_link->>'sku_name','')));
    IF v_key = '' THEN CONTINUE; END IF;
    v_pack := NULLIF(v_link->>'pack_id','')::uuid;
    IF v_pack IS NULL THEN
      DELETE FROM public.lwb_rate_pack_skus WHERE sku_key = v_key;
    ELSE
      IF NOT EXISTS (SELECT 1 FROM public.lwb_rate_packs WHERE id = v_pack) THEN
        RAISE EXCEPTION 'Rate pack not found for SKU %', v_key;
      END IF;
      INSERT INTO public.lwb_rate_pack_skus(sku_key, pack_id, updated_at, updated_by)
      VALUES (v_key, v_pack, now(), auth.uid())
      ON CONFLICT (sku_key) DO UPDATE
        SET pack_id = excluded.pack_id, updated_at = now(), updated_by = auth.uid();
    END IF;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_link_rate_skus(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_link_rate_skus(jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- Helper: active PO entry user (Admin, Manager or Salesman)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_po_entry_user()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager','sales')
  );
$function$;

REVOKE ALL ON FUNCTION public.lwb_po_entry_user() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_entry_user() TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Sale rate per SKU: [{sku, slab3_rate}]. Slab 1 = +5, Slab 2/4 = -5
--    (same as PO Maker); the page works the slab out.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_order_rates()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NOT public.lwb_po_entry_user() THEN
    RAISE EXCEPTION 'Only Admin, Manager or Salesman can read PO rates';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('sku', l.sku_key, 'slab3_rate', p.slab3_rate) ORDER BY l.sku_key)
    FROM public.lwb_rate_pack_skus l
    JOIN public.lwb_rate_packs p ON p.id = l.pack_id
    WHERE p.active
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_order_rates() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_rates() TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Party's last rate per SKU from its latest non-cancelled PO:
--    [{sku, rate, order_no, order_date}]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_last_rates(p_customer text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_party text := upper(btrim(COALESCE(p_customer,'')));
BEGIN
  IF NOT public.lwb_po_entry_user() THEN
    RAISE EXCEPTION 'Only Admin, Manager or Salesman can read party rates';
  END IF;
  IF v_party = '' THEN
    RETURN '[]'::jsonb;
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('sku', x.sku, 'rate', x.rate, 'order_no', x.order_no, 'order_date', x.order_date) ORDER BY x.sku)
    FROM (
      SELECT DISTINCT ON (upper(btrim(i.sku_name)))
        upper(btrim(i.sku_name)) AS sku, i.rate, o.order_no, o.order_date
      FROM public.orders o
      JOIN public.order_items i ON i.order_id = o.id
      WHERE upper(btrim(o.customer_name)) = v_party
        AND lower(btrim(COALESCE(o.status,''))) NOT IN ('cancelled','canceled','rejected')
        AND i.rate > 0
        AND COALESCE(i.ordered_qty,0) > 0
      ORDER BY upper(btrim(i.sku_name)), o.order_date DESC, o.created_at DESC
    ) x
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_party_last_rates(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_last_rates(text) TO authenticated;

COMMIT;
