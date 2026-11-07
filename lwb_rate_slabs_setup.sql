-- LUXURY WRIST BRAND ERP — SLAB LIST (Coca-Cola): slabs set once, one Base rate per pack
--
-- Runs by itself when merged to main (after lwb_rate_scheme_setup.sql, lwb_order_rates_setup.sql and
-- lwb_rate_check_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (6 Nov 2026): direct vehicle, 11 pallet vehicle, below 3 ton, 3 & 4 ton, self pickup,
-- Shree Jagdish ... all these slabs in one place. Each slab = a rule (party / transport / weight / pallets)
-- and a ₹ difference from the Base rate (lwb_rate_packs.slab3_rate). Top to bottom, the first rule that
-- matches the order is its slab. A pack can have its own rate for one slab (lwb_rate_slab_rates).
--   * lwb_rate_slabs: the list. Seeded once with today's rule, so nothing changes:
--       s4 Shree Jagdish (party) −5, s2 Self pickup −5, s1 Below 3 ton +5, s3 3 & 4 ton = Base.
--       Direct vehicle (−5) and 11 pallet vehicle (−10) are added OFF, for Admin to switch on.
--   * lwb_rate_slab_rates: own rate of one pack for one slab (blank = Base ± difference).
--   * lwb_rate_slabs_save(slabs, rates): Admin / Sales Head.
--   * lwb_order_slab_rates(): [{sku, code, rate}] own rates per SKU, for PO Entry (no landing).
--   * lwb_rate_slab_pick(...): the slab of an order; lwb_rate_check_reasons now uses the list.
-- No rate, order, stock, bill, ledger or Tally data is changed.

BEGIN;

ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS ordered_pallet_qty integer;
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS cases_per_pallet_snapshot integer;
ALTER TABLE public.sku_master ADD COLUMN IF NOT EXISTS cases_per_pallet integer;

CREATE TABLE IF NOT EXISTS public.lwb_rate_slabs (
  code text PRIMARY KEY CHECK (code ~ '^s[0-9]+$'),
  sort_no integer NOT NULL DEFAULT 0,
  name text NOT NULL CHECK (btrim(name) <> ''),
  party text,            -- party name contains this (e.g. JAGDISH)
  transport text,        -- SELF PICKUP / DELIVERY / DIRECT VEHICLE
  min_kg numeric(12,2),  -- order weight from (kg)
  below_kg numeric(12,2),-- order weight below (kg)
  min_pallets numeric(12,2),
  diff numeric(12,2) NOT NULL DEFAULT 0,  -- ₹ per case vs Base
  is_base boolean NOT NULL DEFAULT false,
  in_image boolean NOT NULL DEFAULT true, -- column on the WhatsApp rate list image
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
CREATE TABLE IF NOT EXISTS public.lwb_rate_slab_rates (
  pack_id uuid NOT NULL REFERENCES public.lwb_rate_packs(id) ON DELETE CASCADE,
  code text NOT NULL REFERENCES public.lwb_rate_slabs(code) ON DELETE CASCADE,
  rate numeric(12,2) NOT NULL CHECK (rate > 0),
  PRIMARY KEY (pack_id, code)
);

INSERT INTO public.lwb_rate_slabs (code, sort_no, name, party, transport, min_kg, below_kg, min_pallets, diff, is_base, in_image, active)
SELECT * FROM (VALUES
  ('s4', 1, 'SHREE JAGDISH TRADERS', 'JAGDISH', NULL, NULL::numeric, NULL::numeric, NULL::numeric, -5, false, false, true),
  ('s2', 2, 'SELF PICKUP', NULL, 'SELF PICKUP', NULL, NULL, NULL, -5, false, true, true),
  ('s6', 3, '11 PALLET VEHICLE', NULL, 'DIRECT VEHICLE', NULL, NULL, 11, -10, false, true, false),
  ('s5', 4, 'DIRECT VEHICLE', NULL, 'DIRECT VEHICLE', NULL, NULL, NULL, -5, false, true, false),
  ('s1', 5, 'BELOW 3 TON', NULL, NULL, NULL, 3000, NULL, 5, false, true, true),
  ('s3', 6, '3 & 4 TON', NULL, NULL, 3000, NULL, NULL, 0, true, true, true)
) v(code, sort_no, name, party, transport, min_kg, below_kg, min_pallets, diff, is_base, in_image, active)
WHERE NOT EXISTS (SELECT 1 FROM public.lwb_rate_slabs);

ALTER TABLE public.lwb_rate_slabs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_rate_slab_rates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_rate_slabs_read ON public.lwb_rate_slabs;
CREATE POLICY lwb_rate_slabs_read ON public.lwb_rate_slabs
  FOR SELECT TO authenticated USING (public.lwb_rate_editor() OR public.lwb_po_entry_user());
DROP POLICY IF EXISTS lwb_rate_slab_rates_read ON public.lwb_rate_slab_rates;
CREATE POLICY lwb_rate_slab_rates_read ON public.lwb_rate_slab_rates
  FOR SELECT TO authenticated USING (public.lwb_rate_editor());
REVOKE ALL ON TABLE public.lwb_rate_slabs, public.lwb_rate_slab_rates FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_rate_slabs, public.lwb_rate_slab_rates TO authenticated;

-- Save the whole list and the own rates. p_slabs = [{code, name, party, transport, min_kg, below_kg,
-- min_pallets, diff, is_base, in_image, active}] in order; p_rates = [{pack_id, code, rate}].
CREATE OR REPLACE FUNCTION public.lwb_rate_slabs_save(p_slabs jsonb, p_rates jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v jsonb; i integer := 0; v_codes text[] := '{}'; v_tr text;
BEGIN
  IF NOT public.lwb_rate_editor() THEN RAISE EXCEPTION 'Only Admin or Sales Head can change the slab list.'; END IF;
  IF jsonb_typeof(p_slabs) <> 'array' OR jsonb_array_length(p_slabs) = 0 THEN RAISE EXCEPTION 'Slab list is empty.'; END IF;
  IF (SELECT count(*) FROM jsonb_array_elements(p_slabs) x WHERE (x->>'is_base')::boolean AND coalesce((x->>'active')::boolean, true)) <> 1 THEN
    RAISE EXCEPTION 'Mark exactly one slab (ON) as Base.';
  END IF;
  FOR v IN SELECT x FROM jsonb_array_elements(p_slabs) x LOOP
    i := i + 1;
    IF coalesce(v->>'code','') !~ '^s[0-9]+$' THEN RAISE EXCEPTION 'Wrong slab code %.', v->>'code'; END IF;
    IF btrim(coalesce(v->>'name','')) = '' THEN RAISE EXCEPTION 'Slab % has no name.', i; END IF;
    IF (v->>'code') = ANY(v_codes) THEN RAISE EXCEPTION 'Slab % is twice in the list.', v->>'code'; END IF;
    v_tr := nullif(upper(btrim(coalesce(v->>'transport',''))), '');
    IF v_tr IS NOT NULL AND v_tr NOT IN ('SELF PICKUP','DELIVERY','DIRECT VEHICLE') THEN RAISE EXCEPTION 'Wrong transport %.', v_tr; END IF;
    v_codes := v_codes || (v->>'code');
    INSERT INTO public.lwb_rate_slabs AS s (code, sort_no, name, party, transport, min_kg, below_kg, min_pallets, diff, is_base, in_image, active, updated_at, updated_by)
    VALUES (v->>'code', i, upper(btrim(v->>'name')), nullif(upper(btrim(coalesce(v->>'party',''))), ''), v_tr,
      nullif(v->>'min_kg','')::numeric, nullif(v->>'below_kg','')::numeric, nullif(v->>'min_pallets','')::numeric,
      CASE WHEN (v->>'is_base')::boolean THEN 0 ELSE coalesce(nullif(v->>'diff','')::numeric, 0) END,
      coalesce((v->>'is_base')::boolean, false), coalesce((v->>'in_image')::boolean, true), coalesce((v->>'active')::boolean, true), now(), auth.uid())
    ON CONFLICT (code) DO UPDATE SET sort_no = EXCLUDED.sort_no, name = EXCLUDED.name, party = EXCLUDED.party, transport = EXCLUDED.transport,
      min_kg = EXCLUDED.min_kg, below_kg = EXCLUDED.below_kg, min_pallets = EXCLUDED.min_pallets, diff = EXCLUDED.diff,
      is_base = EXCLUDED.is_base, in_image = EXCLUDED.in_image, active = EXCLUDED.active, updated_at = now(), updated_by = auth.uid();
  END LOOP;
  DELETE FROM public.lwb_rate_slabs WHERE NOT (code = ANY(v_codes));
  DELETE FROM public.lwb_rate_slab_rates;
  INSERT INTO public.lwb_rate_slab_rates (pack_id, code, rate)
  SELECT DISTINCT ON ((x->>'pack_id')::uuid, x->>'code') (x->>'pack_id')::uuid, x->>'code', (x->>'rate')::numeric
  FROM jsonb_array_elements(coalesce(p_rates, '[]'::jsonb)) x
  WHERE nullif(x->>'rate','')::numeric > 0 AND (x->>'code') = ANY(v_codes)
    AND EXISTS (SELECT 1 FROM public.lwb_rate_packs p WHERE p.id = (x->>'pack_id')::uuid);
END;
$fn$;

-- Own slab rates per SKU for PO Entry: [{sku, code, rate}] (only the rate, never landing).
CREATE OR REPLACE FUNCTION public.lwb_order_slab_rates()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_po_entry_user() THEN RAISE EXCEPTION 'Only Admin, Manager or Salesman can read PO rates'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('sku', l.sku_key, 'code', r.code, 'rate', r.rate) ORDER BY l.sku_key, r.code)
    FROM public.lwb_rate_pack_skus l
    JOIN public.lwb_rate_packs p ON p.id = l.pack_id AND p.active
    JOIN public.lwb_rate_slab_rates r ON r.pack_id = p.id
  ), '[]'::jsonb);
END;
$fn$;

-- The slab of an order: first ON slab (top to bottom) whose rule matches. Weight rules need a weight.
CREATE OR REPLACE FUNCTION public.lwb_rate_slab_pick(p_party text, p_transport text, p_kg numeric, p_pallets numeric)
RETURNS public.lwb_rate_slabs LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT s.* FROM public.lwb_rate_slabs s
  WHERE s.active
    AND (s.party IS NULL OR upper(coalesce(p_party,'')) LIKE '%' || s.party || '%')
    AND (s.transport IS NULL OR upper(btrim(split_part(coalesce(p_transport,''), '|', 1))) = s.transport)
    AND (s.min_kg IS NULL OR coalesce(p_kg,0) >= s.min_kg)
    AND (s.below_kg IS NULL OR (coalesce(p_kg,0) > 0 AND p_kg < s.below_kg))
    AND (s.min_pallets IS NULL OR coalesce(p_pallets,0) >= s.min_pallets)
    AND (s.party IS NOT NULL OR s.transport IS NOT NULL OR s.min_pallets IS NOT NULL OR coalesce(p_kg,0) > 0)
  ORDER BY s.sort_no, s.code LIMIT 1;
$fn$;

-- Same reasons as lwb_rate_check_setup.sql, the slab now from the Slab List.
CREATE OR REPLACE FUNCTION public.lwb_rate_check_reasons(p_order uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_margin numeric; v_s public.lwb_rate_slabs%ROWTYPE; v_kg numeric; v_pal numeric; v_why text;
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = p_order;
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;
  SELECT s.check_margin INTO v_margin FROM public.lwb_rate_settings s WHERE s.id = 1;
  v_kg := coalesce(v_o.total_weight, 0);
  -- pallets: typed pallets, else cases / cases per pallet (line snapshot, else SKU Master)
  SELECT coalesce(sum(coalesce(i.ordered_pallet_qty::numeric, i.ordered_qty / nullif(coalesce(i.cases_per_pallet_snapshot,
           (SELECT max(m.cases_per_pallet) FROM public.sku_master m WHERE upper(btrim(m.sku_name)) = upper(btrim(i.sku_name)))), 0))), 0) INTO v_pal
    FROM public.order_items i WHERE i.order_id = p_order;
  v_s := public.lwb_rate_slab_pick(v_o.customer_name, v_o.transportation, v_kg, v_pal);
  v_why := CASE WHEN v_s.code IS NULL THEN NULL
    WHEN v_s.min_kg IS NOT NULL OR v_s.below_kg IS NOT NULL THEN initcap(v_s.name) || ' order, ' || to_char(v_kg,'FM999999990') || ' kg'
    WHEN v_s.min_pallets IS NOT NULL THEN initcap(v_s.name) || ', ' || to_char(v_pal,'FM99990.##') || ' pallets'
    ELSE initcap(v_s.name) END;
  RETURN coalesce((
    SELECT jsonb_agg(x ORDER BY x->>'sku', x->>'kind') FROM (
      SELECT jsonb_build_object('sku', upper(btrim(i.sku_name)), 'rate', i.rate, 'kind', 'margin',
               'need', round(l.landing + v_margin, 2),
               'why', 'margin ₹' || to_char(i.rate - l.landing,'FM9999990.00') || ' (check below ₹' || to_char(v_margin,'FM9999990.##') || ')') x
      FROM public.order_items i
      JOIN public.lwb_sku_price_limits l ON l.sku_key = upper(btrim(i.sku_name))
      WHERE i.order_id = p_order AND v_margin IS NOT NULL AND l.landing IS NOT NULL AND i.rate IS NOT NULL
        AND i.rate < l.landing + v_margin
      UNION ALL
      SELECT jsonb_build_object('sku', upper(btrim(i.sku_name)), 'rate', i.rate, 'kind', 'slab', 'need', t.need,
               'why', v_why || ' needs ₹' || to_char(t.need,'FM9999990.##'))
      FROM public.order_items i
      JOIN public.lwb_rate_pack_skus k ON k.sku_key = upper(btrim(i.sku_name))
      JOIN public.lwb_rate_packs p ON p.id = k.pack_id AND p.active IS DISTINCT FROM false AND coalesce(p.slab3_rate,0) > 0
      LEFT JOIN public.lwb_rate_slab_rates o ON o.pack_id = p.id AND o.code = v_s.code
      CROSS JOIN LATERAL (SELECT coalesce(o.rate, p.slab3_rate + v_s.diff) AS need) t
      WHERE i.order_id = p_order AND v_s.code IS NOT NULL AND i.rate IS NOT NULL AND i.rate < t.need
    ) t
  ), '[]'::jsonb);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_rate_check_reasons(uuid), public.lwb_rate_slab_pick(text, text, numeric, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_rate_slabs_save(jsonb, jsonb), public.lwb_order_slab_rates() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_rate_slabs_save(jsonb, jsonb), public.lwb_order_slab_rates() TO authenticated;

COMMIT;
