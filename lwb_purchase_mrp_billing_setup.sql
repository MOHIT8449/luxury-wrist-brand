-- LUXURY WRIST BRAND ERP — MRP-BASED PURCHASE BILLS (Rajnigandha pan masala, cigarettes)
--
-- Safe to run again. Runs by itself on merge to main (Supabase apply).
--
-- Pan masala / tobacco purchase bills charge GST on a Deemed Taxable Value, not on the
-- amount we pay:
--   Deemed Taxable Value = Total MRP / (1 + GST%)      (rounded to the rupee, as on the bill)
--   GST                  = Deemed Taxable Value x GST%  (CGST + SGST rounded separately)
--   Line Total           = Net Sale + GST
-- e.g. DS Group bill 322HA21087, Rajnigandha 2.2G, 10 boxes: MRP 5,18,400 -> deemed 3,70,286,
-- GST 2 x 74,057.20, net sale 2,78,217.86, total 4,26,332.26.
--
-- 1. Supplier Master: company_id (supplier belongs to a brand; Goods Inward shows only
--    that brand's SKUs once the supplier is chosen). Empty = all SKUs (old behaviour).
-- 2. SKU Master: mrp_per_case (MRP of one case / box), remembered from the last bill.
-- 3. Goods Inward lines: billing_mode, net_amount, mrp_amount, mrp_per_case, deemed_value.
--    For an MRP line taxable_amount = deemed value, total_amount = net sale + GST, so the
--    Purchase Register and "money to pay company" show the real bill total.
-- 4. lwb_post_goods_inward_mrp(header, items): posts the bill through the existing
--    lwb_post_goods_inward (same stock update, same checks), then writes the MRP figures
--    on its lines, in one transaction. GST and totals are recomputed here from SKU Master
--    GST % and the supplier's GSTIN state; nothing typed in the browser is trusted for tax.
--
-- Bills with no MRP line keep using lwb_post_goods_inward directly: nothing changes for them.

BEGIN;

ALTER TABLE public.lwb_supplier_master ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES public.lwb_companies(id);
CREATE INDEX IF NOT EXISTS lwb_supplier_master_company_idx ON public.lwb_supplier_master (company_id);

ALTER TABLE public.sku_master ADD COLUMN IF NOT EXISTS mrp_per_case numeric(14,2) CHECK (mrp_per_case IS NULL OR mrp_per_case >= 0);

ALTER TABLE public.lwb_goods_inward_items ADD COLUMN IF NOT EXISTS billing_mode text CHECK (billing_mode IS NULL OR billing_mode IN ('TAXABLE','MRP'));
ALTER TABLE public.lwb_goods_inward_items ADD COLUMN IF NOT EXISTS net_amount numeric(14,2);
ALTER TABLE public.lwb_goods_inward_items ADD COLUMN IF NOT EXISTS mrp_amount numeric(14,2);
ALTER TABLE public.lwb_goods_inward_items ADD COLUMN IF NOT EXISTS mrp_per_case numeric(14,2);
ALTER TABLE public.lwb_goods_inward_items ADD COLUMN IF NOT EXISTS deemed_value numeric(14,2);

-- GST on an amount, the way Goods Inward shows it: CGST + SGST each rounded to the paisa
-- (intrastate) or one IGST rounding (interstate).
CREATE OR REPLACE FUNCTION public.lwb_purchase_gst(p_amount numeric, p_rate numeric, p_interstate boolean)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE WHEN p_interstate THEN round(p_amount * p_rate / 100, 2)
              ELSE 2 * round(p_amount * p_rate / 200, 2) END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_post_goods_inward_mrp(p_header jsonb, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_supplier public.lwb_supplier_master%ROWTYPE;
  v_inter boolean;
  v_item jsonb;
  v_sku record;
  v_mode text;
  v_net numeric; v_mrp numeric; v_mrp_case numeric; v_deemed numeric; v_tax numeric; v_gst numeric; v_rate numeric;
  v_cases bigint; v_pcs bigint;
  v_lines jsonb := '[]'::jsonb;   -- what we pass to lwb_post_goods_inward
  v_fix jsonb := '[]'::jsonb;     -- MRP figures written back afterwards
  v_res jsonb;
  v_id uuid;
  v_n integer;
BEGIN
  IF NOT (EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                  AND lower(btrim(p.role)) IN ('admin','manager'))
          OR public.lwb_has_page('goods-inward.html')) THEN
    RAISE EXCEPTION 'Only active Admin or Manager can post Goods Inward';
  END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Add at least one SKU line';
  END IF;

  SELECT * INTO v_supplier FROM public.lwb_supplier_master s WHERE s.id = nullif(p_header->>'p_supplier_id','')::uuid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Select a Supplier from Supplier Master'; END IF;
  -- Our GSTIN is Gujarat (24): another state's GSTIN = IGST, else CGST + SGST (same rule as the page).
  v_inter := left(btrim(coalesce(v_supplier.gstin,'')),2) ~ '^\d{2}$' AND left(btrim(v_supplier.gstin),2) <> '24';

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT s.id, s.sku_name, s.gst_rate, s.cess_rate, s.company_id INTO v_sku
    FROM public.sku_master s WHERE s.id::text = v_item->>'sku_id';
    IF NOT FOUND THEN RAISE EXCEPTION 'SKU not found in SKU Master'; END IF;
    IF v_supplier.company_id IS NOT NULL AND v_sku.company_id IS DISTINCT FROM v_supplier.company_id THEN
      RAISE EXCEPTION '% is not an SKU of this supplier''s company', v_sku.sku_name;
    END IF;
    v_rate := v_sku.gst_rate;
    IF v_rate IS NULL OR v_rate < 0 OR v_rate > 100 THEN RAISE EXCEPTION 'GST %% missing in SKU Master for %', v_sku.sku_name; END IF;
    IF coalesce(v_sku.cess_rate,0) <> 0 THEN RAISE EXCEPTION 'Nonzero Cess in SKU Master for %', v_sku.sku_name; END IF;
    v_cases := (v_item->>'cases')::bigint; v_pcs := (v_item->>'pcs')::bigint;
    v_mode := upper(coalesce(nullif(v_item->>'billing_mode',''),'TAXABLE'));

    IF v_mode = 'MRP' THEN
      v_net := round(nullif(btrim(v_item->>'net_amount'),'')::numeric, 2);
      v_deemed := round(nullif(btrim(v_item->>'deemed_value'),'')::numeric, 2);
      v_mrp := round(nullif(v_item->>'mrp_amount','')::numeric, 2);
      v_mrp_case := round(nullif(v_item->>'mrp_per_case','')::numeric, 2);
      IF v_net IS NULL OR v_net <= 0 THEN RAISE EXCEPTION 'Enter Net Sale amount for %', v_sku.sku_name; END IF;
      IF v_deemed IS NULL OR v_deemed <= 0 THEN RAISE EXCEPTION 'Enter Deemed Taxable Value for %', v_sku.sku_name; END IF;
      v_gst := public.lwb_purchase_gst(v_deemed, v_rate, v_inter);
      v_lines := v_lines || jsonb_build_object('sku_id', v_item->>'sku_id', 'cases', v_cases, 'pcs', v_pcs, 'rate_per_case', null,
        'taxable_amount', to_char(v_deemed,'FM999999999990.00'), 'total_amount', to_char(v_deemed + v_gst,'FM999999999990.00'));
      v_fix := v_fix || jsonb_build_object('sku_id', v_item->>'sku_id', 'net', v_net, 'mrp', v_mrp, 'mrp_case', v_mrp_case,
        'deemed', v_deemed, 'total', v_net + v_gst);
    ELSIF v_mode = 'TAXABLE' THEN
      v_tax := round(nullif(btrim(v_item->>'taxable_amount'),'')::numeric, 2);
      IF v_tax IS NULL OR v_tax < 0 THEN RAISE EXCEPTION 'Enter Taxable Amount for %', v_sku.sku_name; END IF;
      v_gst := public.lwb_purchase_gst(v_tax, v_rate, v_inter);
      v_lines := v_lines || jsonb_build_object('sku_id', v_item->>'sku_id', 'cases', v_cases, 'pcs', v_pcs, 'rate_per_case', null,
        'taxable_amount', to_char(v_tax,'FM999999999990.00'), 'total_amount', to_char(v_tax + v_gst,'FM999999999990.00'));
    ELSE
      RAISE EXCEPTION 'Unknown billing type %', v_mode;
    END IF;
  END LOOP;

  -- Same posting as a normal bill (stock, duplicate-invoice check, its own permission check).
  -- Arguments go as untyped literals so they match whatever types that function declares.
  EXECUTE format('SELECT to_jsonb(r) FROM public.lwb_post_goods_inward(
      p_supplier_name => %L, p_invoice_no => %L, p_invoice_date => %L, p_received_date => %L,
      p_transport_name => %L, p_vehicle_no => %L, p_lr_no => %L, p_remarks => %L, p_items => %L,
      p_driver_name => %L, p_driver_mobile => %L, p_supplier_id => %L) AS r',
    v_supplier.supplier_name, p_header->>'p_invoice_no', p_header->>'p_invoice_date', p_header->>'p_received_date',
    coalesce(p_header->>'p_transport_name',''), coalesce(p_header->>'p_vehicle_no',''), coalesce(p_header->>'p_lr_no',''),
    coalesce(p_header->>'p_remarks',''), v_lines::text,
    p_header->>'p_driver_name', p_header->>'p_driver_mobile', v_supplier.id::text)
  INTO v_res;

  IF jsonb_typeof(v_res) = 'object' THEN
    v_id := coalesce(nullif(v_res->>'id',''), nullif(v_res->>'inward_id',''))::uuid;
  END IF;
  IF v_id IS NULL THEN
    SELECT g.id INTO v_id FROM public.lwb_goods_inward g
    WHERE g.invoice_no = btrim(p_header->>'p_invoice_no') AND g.supplier_name = v_supplier.supplier_name
    ORDER BY g.created_at DESC LIMIT 1;
  END IF;
  IF v_id IS NULL THEN RAISE EXCEPTION 'Saved bill not found after posting'; END IF;

  UPDATE public.lwb_goods_inward_items i SET billing_mode = 'TAXABLE'
  WHERE i.inward_id = v_id AND i.billing_mode IS NULL;

  FOR v_item IN SELECT * FROM jsonb_array_elements(v_fix) LOOP
    UPDATE public.lwb_goods_inward_items i
       SET billing_mode = 'MRP', net_amount = (v_item->>'net')::numeric, mrp_amount = (v_item->>'mrp')::numeric,
           mrp_per_case = (v_item->>'mrp_case')::numeric, deemed_value = (v_item->>'deemed')::numeric,
           total_amount = (v_item->>'total')::numeric
     WHERE i.inward_id = v_id AND i.sku_id::text = v_item->>'sku_id';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n <> 1 THEN RAISE EXCEPTION 'Could not write MRP figures on the saved bill line'; END IF;
    -- Remember this MRP for the next bill of the SKU.
    IF (v_item->>'mrp_case')::numeric > 0 THEN
      UPDATE public.sku_master s SET mrp_per_case = (v_item->>'mrp_case')::numeric WHERE s.id::text = v_item->>'sku_id';
    END IF;
  END LOOP;

  RETURN coalesce(CASE WHEN jsonb_typeof(v_res) = 'object' THEN v_res END, '{}'::jsonb)
    || jsonb_build_object('id', v_id,
         'invoice_total', (SELECT round(sum(coalesce(i.total_amount,0)),2) FROM public.lwb_goods_inward_items i WHERE i.inward_id = v_id));
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_purchase_gst(numeric,numeric,boolean), public.lwb_post_goods_inward_mrp(jsonb,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_gst(numeric,numeric,boolean), public.lwb_post_goods_inward_mrp(jsonb,jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
