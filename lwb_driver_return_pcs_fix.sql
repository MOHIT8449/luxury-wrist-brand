-- LUXURY WRIST BRAND ERP — DRIVER RETURN: PCS FOR EVERY SKU
--
-- RUN ONCE in Supabase SQL Editor, after lwb_driver_delivery_return_setup.sql.
-- Safe to run again.
--
-- Driver returns accept CS + PCS. PCS needs "PCS per Case". Until now it came
-- only from SKU Master, so a SKU with an empty PCS per Case (e.g.
-- "1.25L SPRITE 1X12 MRP 70") showed "PCS (no packing)" and PCS was locked.
-- Now: SKU Master value first; if empty, the "1X12" part of the SKU name
-- (12 PCS per case), the same rule SKU Master import uses.
-- The two driver return functions are the same as before except for this lookup.
-- No stock, GST, Tally, ledger or payment rows change.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_sku_pcs_per_case(p_sku_name text)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $$
  SELECT COALESCE(
    (SELECT m.pcs_per_case FROM public.sku_master m
      WHERE lower(btrim(m.sku_name)) = lower(btrim(p_sku_name)) AND m.pcs_per_case > 0
      ORDER BY m.is_active DESC LIMIT 1),
    NULLIF(substring(upper(COALESCE(p_sku_name,'')) FROM '(?:^|[^0-9.])1 *X *([0-9]{1,3})(?:[^0-9]|$)')::integer, 0)
  );
$$;

REVOKE ALL ON FUNCTION public.lwb_sku_pcs_per_case(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sku_pcs_per_case(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_driver_return_options(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $$
DECLARE
 v_items jsonb;
 v_gross numeric := 0;
 v_return_total numeric := 0;
 v_order_no text;
BEGIN
 IF NOT public.lwb_driver_return_access(p_order_id) THEN
  RAISE EXCEPTION 'Not your loaded/invoiced assigned order';
 END IF;

 SELECT o.order_no INTO v_order_no FROM public.orders o WHERE o.id = p_order_id;

 SELECT COALESCE(SUM(ROUND(COALESCE(i.loaded_qty,0)::numeric *
                         COALESCE(i.rate,0)::numeric,2)),0)
 INTO v_gross
 FROM public.order_items i
 WHERE i.order_id=p_order_id AND COALESCE(i.loaded_qty,0)>0;

 SELECT COALESCE(SUM(r.total_return_amount),0)
 INTO v_return_total
 FROM public.lwb_driver_delivery_returns r
 WHERE r.order_id=p_order_id
 AND r.status IN ('PENDING_OFFICE','APPROVED');

 SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'order_item_id', i.id,
    'sku', i.sku_name,
    'loaded_cases', i.loaded_qty,
    'pcs_per_case', public.lwb_sku_pcs_per_case(i.sku_name),
    'rate_per_case', i.rate,
    'returned_cases', used.qty_cases,
    'available_cases', GREATEST(0, i.loaded_qty::numeric - used.qty_cases)
  ) ORDER BY i.sku_name), '[]'::jsonb)
 INTO v_items
 FROM public.order_items i
 LEFT JOIN LATERAL (
    SELECT COALESCE(SUM(li.qty_cases),0) AS qty_cases
    FROM public.lwb_driver_delivery_return_items li
    JOIN public.lwb_driver_delivery_returns h ON h.id=li.return_id
    WHERE li.order_item_id=i.id
      AND h.status IN ('PENDING_OFFICE','APPROVED')
 ) used ON true
 WHERE i.order_id=p_order_id AND COALESCE(i.loaded_qty,0)>0;

 RETURN jsonb_build_object(
   'order_id',p_order_id,'order_no',v_order_no,
   'items',v_items,'gross_amount',v_gross,
   'return_deduction',v_return_total,
   'provisional_net_amount',GREATEST(0,v_gross-v_return_total),
   'amount_basis','LOADED_ERP_ORDER_RATE_NOT_TALLY_BILL'
 );
END;
$$;

CREATE OR REPLACE FUNCTION public.lwb_driver_submit_delivery_return(
 p_order_id uuid, p_lines jsonb, p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $$
DECLARE
 v_order public.orders%ROWTYPE;
 v_item public.order_items%ROWTYPE;
 v_header_id uuid;
 v_line jsonb;
 v_item_id uuid;
 v_uom text;
 v_reason text;
 v_qty integer;
 v_pack integer;
 v_qty_cases numeric;
 v_used_cases numeric;
 v_amount numeric;
 v_total numeric := 0;
 v_count integer;
 v_note text := nullif(btrim(coalesce(p_note,'')),'');
BEGIN
 IF NOT public.lwb_driver_return_access(p_order_id) THEN
  RAISE EXCEPTION 'Only the assigned active driver of a loaded order can record return';
 END IF;

 -- Serialize competing submissions for same order to prevent over-returns.
 SELECT * INTO v_order FROM public.orders
 WHERE id=p_order_id FOR UPDATE;
 IF NOT FOUND OR v_order.status NOT IN ('loaded','invoiced') THEN
  RAISE EXCEPTION 'Order is not eligible for a delivery return';
 END IF;

 IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' THEN
  RAISE EXCEPTION 'Choose at least one return SKU';
 END IF;
 v_count := jsonb_array_length(p_lines);
 IF v_count<1 OR v_count>30 THEN
  RAISE EXCEPTION 'Choose 1 to 30 return items';
 END IF;
 IF length(coalesce(v_note,''))>1000 THEN
  RAISE EXCEPTION 'Return note is too long';
 END IF;

 INSERT INTO public.lwb_driver_delivery_returns (
   order_id,driver_user_id,note
 ) VALUES (p_order_id,auth.uid(),v_note)
 RETURNING id INTO v_header_id;

 FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines) LOOP
  IF jsonb_typeof(v_line) <> 'object'
     OR coalesce(v_line->>'qty','') !~ '^[1-9][0-9]*$' THEN
   RAISE EXCEPTION 'Return quantity must be a positive whole number';
  END IF;
  v_item_id := (v_line->>'order_item_id')::uuid;
  v_uom := upper(btrim(coalesce(v_line->>'uom','')));
  v_reason := upper(btrim(coalesce(v_line->>'reason','')));
  v_qty := (v_line->>'qty')::integer;
  IF v_qty > 1000000 THEN RAISE EXCEPTION 'Quantity is too large'; END IF;
  IF v_uom NOT IN ('CS','PCS') OR
     v_reason NOT IN ('LEAKAGE','BREAKAGE','DAMAGE','GASLESS','LOW_FILL') THEN
   RAISE EXCEPTION 'Choose a valid UOM and return reason';
  END IF;

  SELECT * INTO v_item
  FROM public.order_items
  WHERE id=v_item_id AND order_id=p_order_id
    AND COALESCE(loaded_qty,0)>0;
  IF NOT FOUND THEN
   RAISE EXCEPTION 'SKU is not in the loaded order';
  END IF;

  v_pack := public.lwb_sku_pcs_per_case(v_item.sku_name);
  IF v_uom='PCS' AND (v_pack IS NULL OR v_pack<=0) THEN
   RAISE EXCEPTION 'Set PCS per Case in SKU Master for %',v_item.sku_name;
  END IF;
  IF v_uom='PCS' THEN
   v_qty_cases := v_qty::numeric/v_pack;
  ELSE
   v_qty_cases := v_qty;
  END IF;

  SELECT COALESCE(SUM(li.qty_cases),0) INTO v_used_cases
  FROM public.lwb_driver_delivery_return_items li
  JOIN public.lwb_driver_delivery_returns h ON h.id=li.return_id
  WHERE li.order_item_id=v_item.id AND
    h.status IN ('PENDING_OFFICE','APPROVED');

  IF v_used_cases+v_qty_cases > v_item.loaded_qty::numeric+0.00000001 THEN
   RAISE EXCEPTION 'Return quantity exceeds loaded quantity for %',v_item.sku_name;
  END IF;

  IF v_item.rate IS NULL OR v_item.rate<0 THEN
   RAISE EXCEPTION 'Case rate missing for %',v_item.sku_name;
  END IF;
  v_amount := round(v_qty_cases*v_item.rate::numeric,2);

  INSERT INTO public.lwb_driver_delivery_return_items (
   return_id,order_item_id,sku_name,reason,uom,
   qty,pcs_per_case,qty_cases,rate_per_case,return_amount
  ) VALUES (
   v_header_id,v_item.id,v_item.sku_name,v_reason,v_uom,
   v_qty,v_pack,v_qty_cases,v_item.rate,v_amount
  );
  v_total:=v_total+v_amount;
 END LOOP;

 UPDATE public.lwb_driver_delivery_returns
 SET total_return_amount=round(v_total,2) WHERE id=v_header_id;

 -- Queue Accounts/Admin review; NEVER post to real Tally, ledger, stock or receipts.
 INSERT INTO public.erp_notifications
   (user_id,title,message,notification_type,order_id)
 SELECT p.id,'Delivery Return - Verify',
   'Driver recorded leakage/breakage/damage return for order ' ||
     v_order.order_no || '. Provisional deduction Rs ' ||
     round(v_total,2)::text || '. Review before issuing credit note.',
   'DELIVERY_RETURN_PENDING',p_order_id
 FROM public.user_profiles p
 WHERE p.active=true AND lower(btrim(p.role)) IN ('accounts','admin');

 RETURN jsonb_build_object(
  'return_id',v_header_id,'status','PENDING_OFFICE',
  'return_amount',round(v_total,2),
  'note','Provisional deduction only; Accounts verification pending'
 );
END;
$$;

COMMIT;

-- Expected: 1 row, pcs_per_case = 12.
SELECT '1.25L SPRITE 1X12 MRP 70' AS sku, public.lwb_sku_pcs_per_case('1.25L SPRITE 1X12 MRP 70') AS pcs_per_case;
