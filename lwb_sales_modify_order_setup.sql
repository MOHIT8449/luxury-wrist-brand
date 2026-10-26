-- LUXURY WRIST BRAND ERP — SALESMAN MODIFIES HIS WHOLE ORDER BEFORE APPROVAL
--
-- RUN ONCE in Supabase SQL Editor, after lwb_sales_order_followup_setup.sql. Safe to run again.
--
-- My Orders > Modify opens the order in PO Entry as it was taken. The salesman
-- can add SKUs, remove SKUs, change cases / rate and transportation, and save
-- it back to the SAME order (same Order No). Only the salesman who took it, and
-- only while it is waiting for Sales Head approval. Admin and Sales Head get a
-- bell listing what changed. The party and order date do not change.
--
-- Only this order's orders / order_items rows and erp_notifications are written.
-- No stock, bill, payment, ledger or Tally data is changed.

BEGIN;

-- p_items: [{sku_name, ordered_qty, rate, unit_weight, entry_uom, ordered_pallet_qty, cases_per_pallet_snapshot}]
CREATE OR REPLACE FUNCTION public.lwb_sales_modify_order(p_order_id uuid, p_transportation text, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_old public.order_items%ROWTYPE;
  e jsonb;
  v_sku text;
  v_qty integer;
  v_rate numeric;
  v_wt numeric;
  v_uom text;
  v_pal integer;
  v_cpp integer;
  v_seen text[] := '{}';
  v_changes text[] := '{}';
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF v_o.created_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Only the salesman who took this order can modify it.';
  END IF;
  IF NOT public.lwb_order_pending(v_o.status) THEN
    RAISE EXCEPTION 'Order % is already approved / assigned. Ask the Sales Head to change it.', v_o.order_no;
  END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'An order needs at least one SKU. To drop the whole order, use Cancel.';
  END IF;
  IF coalesce(btrim(p_transportation),'') <> '' AND split_part(btrim(p_transportation), ' |', 1) NOT IN ('SELF PICKUP','DELIVERY','DIRECT VEHICLE') THEN
    RAISE EXCEPTION 'Select a valid Transportation option.';
  END IF;

  -- Check every line first.
  FOR e IN SELECT v FROM jsonb_array_elements(p_items) AS t(v) LOOP
    v_sku := btrim(coalesce(e->>'sku_name',''));
    IF v_sku = '' THEN RAISE EXCEPTION 'Every line needs an SKU.'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.sku_master s WHERE upper(btrim(s.sku_name)) = upper(v_sku) AND s.is_active IS TRUE)
       OR NOT public.lwb_sku_visible(v_sku) THEN
      RAISE EXCEPTION 'SKU % is not in your SKU list.', v_sku;
    END IF;
    IF upper(v_sku) = ANY(v_seen) THEN RAISE EXCEPTION '% is on two lines. Put all its cases on one line.', v_sku; END IF;
    v_seen := v_seen || upper(v_sku);
    IF coalesce(e->>'ordered_qty','') !~ '^\d{1,6}$' OR (e->>'ordered_qty')::integer < 1 THEN
      RAISE EXCEPTION 'Enter whole cases for %.', v_sku;
    END IF;
    IF coalesce(e->>'rate','') !~ '^\d{1,7}(\.\d{1,2})?$' THEN RAISE EXCEPTION 'Enter the rate for %.', v_sku; END IF;
  END LOOP;

  -- Lines no longer in the order.
  FOR v_old IN SELECT * FROM public.order_items WHERE order_id = p_order_id ORDER BY id LOOP
    IF NOT upper(btrim(v_old.sku_name)) = ANY(v_seen) THEN
      DELETE FROM public.order_items WHERE id = v_old.id;
      v_changes := v_changes || (v_old.sku_name || ' removed');
    END IF;
  END LOOP;

  -- Changed lines keep their row; new SKUs get a new row.
  FOR e IN SELECT v FROM jsonb_array_elements(p_items) AS t(v) LOOP
    v_sku := btrim(e->>'sku_name');
    v_qty := (e->>'ordered_qty')::integer;
    v_rate := (e->>'rate')::numeric;
    v_wt := CASE WHEN coalesce(e->>'unit_weight','') ~ '^\d+(\.\d+)?$' THEN (e->>'unit_weight')::numeric ELSE 0 END;
    v_uom := CASE WHEN e->>'entry_uom' = 'PALLET' THEN 'PALLET' ELSE 'CS' END;
    v_pal := CASE WHEN v_uom = 'PALLET' AND coalesce(e->>'ordered_pallet_qty','') ~ '^\d{1,5}$' THEN (e->>'ordered_pallet_qty')::integer END;
    v_cpp := CASE WHEN v_uom = 'PALLET' AND coalesce(e->>'cases_per_pallet_snapshot','') ~ '^\d{1,5}$' THEN (e->>'cases_per_pallet_snapshot')::integer END;
    IF v_uom = 'PALLET' AND (v_pal IS NULL OR v_cpp IS NULL) THEN v_uom := 'CS'; v_pal := NULL; v_cpp := NULL; END IF;

    SELECT * INTO v_old FROM public.order_items
    WHERE order_id = p_order_id AND upper(btrim(sku_name)) = upper(v_sku) ORDER BY id LIMIT 1;
    IF FOUND THEN
      IF coalesce(v_old.ordered_qty,0) <> v_qty OR coalesce(v_old.rate,0) <> v_rate THEN
        v_changes := v_changes || (v_sku || ' ' || coalesce(v_old.ordered_qty,0) || '→' || v_qty ||
          CASE WHEN coalesce(v_old.rate,0) <> v_rate THEN ' @ ₹' || v_rate ELSE '' END);
      END IF;
      UPDATE public.order_items SET ordered_qty = v_qty, rate = v_rate, unit_weight = v_wt,
        amount = v_qty * v_rate, total_weight = v_qty * v_wt,
        entry_uom = v_uom, ordered_pallet_qty = v_pal, cases_per_pallet_snapshot = v_cpp
      WHERE id = v_old.id;
    ELSE
      INSERT INTO public.order_items (order_id, sku_name, ordered_qty, approved_qty, loaded_qty, rate, unit_weight,
        amount, total_weight, entry_uom, ordered_pallet_qty, cases_per_pallet_snapshot)
      VALUES (p_order_id, v_sku, v_qty, NULL, 0, v_rate, v_wt, v_qty * v_rate, v_qty * v_wt, v_uom, v_pal, v_cpp);
      v_changes := v_changes || (v_sku || ' added ' || v_qty);
    END IF;
  END LOOP;

  IF coalesce(v_o.transportation,'') IS DISTINCT FROM coalesce(nullif(btrim(p_transportation),''),'') THEN
    v_changes := v_changes || ('Transport ' || coalesce(nullif(split_part(btrim(p_transportation), ' |', 1),''), 'not set'));
  END IF;

  UPDATE public.orders o SET
    transportation = nullif(btrim(coalesce(p_transportation,'')),''),
    total_qty = t.q, total_amount = t.a, total_weight = t.w
  FROM (SELECT sum(coalesce(ordered_qty,0)) q, sum(coalesce(amount,0)) a, sum(coalesce(total_weight,0)) w
        FROM public.order_items WHERE order_id = p_order_id) t
  WHERE o.id = p_order_id;

  IF cardinality(v_changes) > 0 THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, 'Salesman Modified Order',
      concat_ws(' · ', v_o.order_no, v_o.customer_name, array_to_string(v_changes, ', ')) || '. Changed before approval.',
      'ORDER_EDITED', p_order_id
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') AND p.id IS DISTINCT FROM auth.uid();
  END IF;

  RETURN jsonb_build_object('order_no', v_o.order_no, 'changed', cardinality(v_changes), 'changes', to_jsonb(v_changes));
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_sales_modify_order(uuid, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sales_modify_order(uuid, text, jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: SELECT to_regprocedure('public.lwb_sales_modify_order(uuid,text,jsonb)') IS NOT NULL AS modify_ready;
