-- LUXURY WRIST BRAND | DELIVERY-TIME DRIVER RETURN
-- Deploy once using Supabase SQL Editor AFTER review.
-- Reads loaded ERP order lines, not a legally verified Tally invoice.
-- DRIVER intake only; amount is provisional. Does not post GST, Credit Note,
-- inventory, outstanding, or cash/collection adjustments.
BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_driver_delivery_returns (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 order_id uuid NOT NULL REFERENCES public.orders(id),
 driver_user_id uuid NOT NULL REFERENCES auth.users(id),
 note text,
 status text NOT NULL DEFAULT 'PENDING_OFFICE'
  CHECK (status IN ('PENDING_OFFICE','APPROVED','REJECTED')),
 total_return_amount numeric(16,2) NOT NULL DEFAULT 0
  CHECK (total_return_amount >= 0),
 created_at timestamptz NOT NULL DEFAULT now(),
 reviewed_by uuid REFERENCES auth.users(id),
 reviewed_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.lwb_driver_delivery_return_items (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 return_id uuid NOT NULL REFERENCES public.lwb_driver_delivery_returns(id),
 order_item_id uuid NOT NULL REFERENCES public.order_items(id),
 sku_name text NOT NULL,
 reason text NOT NULL
  CHECK (reason IN ('LEAKAGE','BREAKAGE','DAMAGE','GASLESS','LOW_FILL')),
 uom text NOT NULL CHECK (uom IN ('CS','PCS')),
 qty integer NOT NULL CHECK (qty > 0),
 pcs_per_case integer,
 qty_cases numeric(18,8) NOT NULL CHECK (qty_cases > 0),
 rate_per_case numeric(16,2) NOT NULL CHECK (rate_per_case >= 0),
 return_amount numeric(16,2) NOT NULL CHECK (return_amount >= 0)
);

CREATE INDEX IF NOT EXISTS lwb_driver_returns_order_idx
 ON public.lwb_driver_delivery_returns(order_id,created_at DESC);
CREATE INDEX IF NOT EXISTS lwb_driver_return_lines_item_idx
 ON public.lwb_driver_delivery_return_items(order_item_id);

ALTER TABLE public.lwb_driver_delivery_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_driver_delivery_return_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_driver_delivery_returns FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.lwb_driver_delivery_return_items FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_driver_return_access(p_order_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $$
 SELECT EXISTS (
  SELECT 1
  FROM public.user_profiles p
  JOIN public.dispatch_assignments a
    ON a.order_id = p_order_id
  JOIN public.orders o ON o.id = a.order_id
  WHERE p.id = auth.uid()
    AND p.active = true
    AND lower(btrim(p.role)) = 'driver'
    AND public.lwb_driver_phone_matches(p.mobile,a.driver_mobile)
    AND lower(btrim(o.status)) IN ('loaded','invoiced')
 );
$$;

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
    'pcs_per_case', sm.pcs_per_case,
    'rate_per_case', i.rate,
    'returned_cases', used.qty_cases,
    'available_cases', GREATEST(0, i.loaded_qty::numeric - used.qty_cases)
  ) ORDER BY i.sku_name), '[]'::jsonb)
 INTO v_items
 FROM public.order_items i
 LEFT JOIN LATERAL (
    SELECT m.pcs_per_case
    FROM public.sku_master m
    WHERE lower(btrim(m.sku_name))=lower(btrim(i.sku_name))
    ORDER BY m.is_active DESC
    LIMIT 1
 ) sm ON true
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

  SELECT m.pcs_per_case INTO v_pack FROM public.sku_master m
  WHERE lower(btrim(m.sku_name))=lower(btrim(v_item.sku_name))
  ORDER BY m.is_active DESC LIMIT 1;
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

REVOKE ALL ON FUNCTION public.lwb_driver_return_access(uuid)
 FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.lwb_driver_return_options(uuid)
 FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.lwb_driver_submit_delivery_return(uuid,jsonb,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_driver_return_options(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_driver_submit_delivery_return(uuid,jsonb,text) TO authenticated;
-- Database wrapper function must be callable only by its definer.
COMMIT;
