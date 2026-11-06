-- LUXURY WRIST BRAND ERP — RAJNIGANDHA PURCHASE IN CARTONS, NOT IC (6 Nov 2026)
--
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped or deleted.
--
-- Mohit (6 Nov 2026): Rajnigandha purchase bills give the qty in CARTONS. Goods Inward saved that
-- number as IC (2.2GM 10 carton -> 10 IC), so Stock In was far too small and Closing went minus.
-- Goods Inward now has a Carton box (carton x "IC per Carton" from SKU Master). This file fixes the
-- bills already saved: for every purchase stock row of an IC (BOX) SKU saved before this file first
-- ran, one extra stock row of the same type adds the missing part: qty x (IC per Carton - 1).
--   * Only SKUs whose "IC per Carton" (sku_master.cases_per_pallet) is set and > 1.
--   * Each original row is fixed once (lwb_purchase_carton_fix keeps the list). Rows saved after the
--     first run are never touched (they come through the new Carton box).
--   * The purchase bill itself (amount, GST) is not changed.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_purchase_carton_fix (
  movement_id text PRIMARY KEY,
  sku_id uuid,
  sku_name text,
  cartons numeric,
  ic_per_carton int,
  added_pcs numeric,
  fixed_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.lwb_purchase_carton_fix_run (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  first_run_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_purchase_carton_fix ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_purchase_carton_fix_run ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_purchase_carton_fix, public.lwb_purchase_carton_fix_run FROM PUBLIC, anon, authenticated;
INSERT INTO public.lwb_purchase_carton_fix_run(id) VALUES (1) ON CONFLICT (id) DO NOTHING;

DO $do$
DECLARE
  v_cut timestamptz := (SELECT first_run_at FROM public.lwb_purchase_carton_fix_run WHERE id = 1);
  v_qty text;     -- name of the pieces column of lwb_inventory_movements
  v_cols text;    -- columns copied into the new row (all but id / generated)
  r record;
  v_new jsonb;
  v_id text;
BEGIN
  IF to_regclass('public.lwb_inventory_movements') IS NULL THEN RETURN; END IF;
  SELECT c.column_name INTO v_qty FROM information_schema.columns c
  WHERE c.table_schema = 'public' AND c.table_name = 'lwb_inventory_movements'
    AND c.column_name IN ('quantity_pcs','qty_pcs','pcs')
  ORDER BY array_position(ARRAY['quantity_pcs','qty_pcs','pcs'], c.column_name::text) LIMIT 1;
  IF v_qty IS NULL THEN RETURN; END IF;
  SELECT string_agg(quote_ident(c.column_name), ',' ORDER BY c.ordinal_position) INTO v_cols
  FROM information_schema.columns c
  WHERE c.table_schema = 'public' AND c.table_name = 'lwb_inventory_movements'
    AND c.column_name <> 'id' AND c.is_generated = 'NEVER' AND c.is_identity = 'NO';

  FOR r IN
    SELECT j, (j->>'id') AS mid, s.id AS sku_id, s.sku_name, s.cases_per_pallet::int AS k,
           greatest(coalesce(s.pcs_per_case,1),1) AS per, (j->>v_qty)::numeric AS pcs
    FROM public.lwb_inventory_movements m
    CROSS JOIN LATERAL to_jsonb(m) j
    JOIN public.sku_master s ON s.id::text = j->>'sku_id'
    LEFT JOIN public.lwb_companies co ON co.id = s.company_id
    WHERE upper(coalesce(j->>'movement_type','')) ~ '(PURCHASE|INWARD)'
      AND upper(coalesce(j->>'stock_bucket','SALEABLE')) = 'SALEABLE'
      AND coalesce(s.pack_unit, co.pack_unit) = 'BOX'
      AND coalesce(s.cases_per_pallet, 0) > 1
      AND (j->>v_qty)::numeric > 0
      AND coalesce(nullif(j->>'created_at','')::timestamptz, v_cut) < v_cut
      AND NOT EXISTS (SELECT 1 FROM public.lwb_purchase_carton_fix f WHERE f.movement_id = j->>'id')
      AND NOT EXISTS (SELECT 1 FROM public.lwb_purchase_carton_fix f WHERE f.movement_id = 'added:' || (j->>'id'))
  LOOP
    v_new := r.j - 'id' || jsonb_build_object(v_qty, r.pcs * (r.k - 1));
    IF v_new ? 'notes' THEN v_new := v_new || jsonb_build_object('notes', 'Carton to IC fix: ' || trim_scale(round(r.pcs / r.per, 2)) || ' carton x ' || r.k || ' IC'); END IF;
    IF v_new ? 'note' THEN v_new := v_new || jsonb_build_object('note', 'Carton to IC fix: ' || trim_scale(round(r.pcs / r.per, 2)) || ' carton x ' || r.k || ' IC'); END IF;
    EXECUTE format('INSERT INTO public.lwb_inventory_movements(%s) SELECT %s FROM jsonb_populate_record(NULL::public.lwb_inventory_movements, $1) RETURNING id::text',
                   v_cols, v_cols) USING v_new INTO v_id;
    INSERT INTO public.lwb_purchase_carton_fix(movement_id, sku_id, sku_name, cartons, ic_per_carton, added_pcs)
    VALUES (r.mid, r.sku_id, r.sku_name, r.pcs / r.per, r.k, r.pcs * (r.k - 1)),
           ('added:' || v_id, r.sku_id, r.sku_name, NULL, r.k, NULL);  -- the new row is never fixed again
  END LOOP;
END;
$do$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result (counts only, no stock figures).
SELECT 'carton fix rows' AS item, count(*)::text AS ok FROM public.lwb_purchase_carton_fix;
