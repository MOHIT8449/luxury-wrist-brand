-- LUXURY WRIST BRAND ERP — DRIVER RETURN: SEE, EDIT, CANCEL; SALES HEAD APPROVES
--
-- RUN ONCE in Supabase SQL Editor, after lwb_driver_return_photos_setup.sql and
-- lwb_driver_return_pcs_fix.sql. Safe to run again.
--
-- 1. The driver sees his returns on the order (status, lines, photos).
-- 2. Until approved, the driver can EDIT (the old return becomes CANCELLED and the
--    changed one is saved as a new PENDING return) or CANCEL a return.
-- 3. Sales Head (MANAGER) can approve / reject, like Admin and Accounts.
-- 4. Only APPROVED returns reduce the amount the driver collects
--    (lwb_driver_return_options: return_deduction = approved, pending_deduction = waiting).
-- Quantities of PENDING returns stay reserved, so the same goods cannot be returned twice.
-- No stock, GST, Tally or payment rows change. Party Ledger already counts APPROVED only.

BEGIN;

-- CANCELLED: a pending return the driver changed or withdrew. Counted nowhere.
DO $$
DECLARE c text;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
           WHERE conrelid = 'public.lwb_driver_delivery_returns'::regclass AND contype = 'c'
             AND pg_get_constraintdef(oid) ILIKE '%PENDING_OFFICE%' LOOP
    EXECUTE format('ALTER TABLE public.lwb_driver_delivery_returns DROP CONSTRAINT %I', c);
  END LOOP;
END $$;
ALTER TABLE public.lwb_driver_delivery_returns
  ADD CONSTRAINT lwb_driver_delivery_returns_status_check
  CHECK (status IN ('PENDING_OFFICE','APPROVED','REJECTED','CANCELLED'));

CREATE OR REPLACE FUNCTION public.lwb_driver_return_options(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $$
DECLARE
 v_items jsonb;
 v_gross numeric := 0;
 v_return_total numeric := 0;
 v_pending_total numeric := 0;
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

 -- Only APPROVED returns reduce what the driver collects; PENDING ones wait for approval.
 SELECT COALESCE(SUM(r.total_return_amount) FILTER (WHERE r.status='APPROVED'),0),
        COALESCE(SUM(r.total_return_amount) FILTER (WHERE r.status='PENDING_OFFICE'),0)
 INTO v_return_total, v_pending_total
 FROM public.lwb_driver_delivery_returns r
 WHERE r.order_id=p_order_id;

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
   'pending_deduction',v_pending_total,
   'provisional_net_amount',GREATEST(0,v_gross-v_return_total),
   'amount_basis','LOADED_ERP_ORDER_RATE_NOT_TALLY_BILL'
 );
END;
$$;

-- ---------------------------------------------------------------------------
-- Driver: his own returns on one order (newest first), CANCELLED left out.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_driver_list_order_returns(p_order_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', r.id,
    'status', r.status,
    'created_at', r.created_at,
    'note', r.note,
    'total_return_amount', r.total_return_amount,
    'reviewed_at', r.reviewed_at,
    'reviewed_by_name', rp.full_name,
    'review_note', r.review_note,
    'photo_paths', COALESCE(r.photo_paths, '{}'),
    'items', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'order_item_id', li.order_item_id,
        'sku', li.sku_name,
        'reason', li.reason,
        'uom', li.uom,
        'qty', li.qty,
        'qty_cases', li.qty_cases,
        'return_amount', li.return_amount
      ) ORDER BY li.sku_name, li.uom), '[]'::jsonb)
      FROM public.lwb_driver_delivery_return_items li WHERE li.return_id = r.id)
  ) ORDER BY r.created_at DESC), '[]'::jsonb)
  FROM public.lwb_driver_delivery_returns r
  LEFT JOIN public.user_profiles rp ON rp.id = r.reviewed_by
  WHERE r.order_id = p_order_id
    AND r.driver_user_id = auth.uid()
    AND r.status <> 'CANCELLED';
$$;

-- ---------------------------------------------------------------------------
-- Driver: withdraw his own PENDING return.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_driver_cancel_delivery_return(p_return_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $$
DECLARE
  v_return public.lwb_driver_delivery_returns%ROWTYPE;
BEGIN
  SELECT * INTO v_return FROM public.lwb_driver_delivery_returns
  WHERE id = p_return_id FOR UPDATE;
  IF NOT FOUND OR v_return.driver_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Return not found';
  END IF;
  IF v_return.status <> 'PENDING_OFFICE' THEN
    RAISE EXCEPTION 'This return is already %; it cannot be changed', v_return.status;
  END IF;
  UPDATE public.lwb_driver_delivery_returns
  SET status = 'CANCELLED', review_note = 'Cancelled by driver', reviewed_at = now()
  WHERE id = p_return_id;
  RETURN 'CANCELLED';
END;
$$;

-- ---------------------------------------------------------------------------
-- Driver: change his own PENDING return. The old one becomes CANCELLED and the
-- changed lines / note / photos are saved as a new PENDING return (all checks again).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_driver_edit_delivery_return(
  p_return_id uuid, p_lines jsonb, p_note text, p_photo_paths text[]
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $$
DECLARE
  v_order_id uuid;
BEGIN
  PERFORM public.lwb_driver_cancel_delivery_return(p_return_id);
  UPDATE public.lwb_driver_delivery_returns SET review_note = 'Changed by driver'
  WHERE id = p_return_id RETURNING order_id INTO v_order_id;
  RETURN public.lwb_driver_submit_delivery_return_with_photos(v_order_id, p_lines, p_note, p_photo_paths)
         || jsonb_build_object('replaced_return_id', p_return_id);
END;
$$;

-- ---------------------------------------------------------------------------
-- Office review: Sales Head (MANAGER) may approve / reject too.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_review_driver_return(
  p_return_id uuid,
  p_action text,
  p_note text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_return public.lwb_driver_delivery_returns%ROWTYPE;
  v_action text := upper(btrim(COALESCE(p_action,'')));
  v_note text := NULLIF(btrim(COALESCE(p_note,'')),'');
  v_status text;
  v_order_no text;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','accounts','manager')
  ) THEN
    RAISE EXCEPTION 'Only active Admin, Accounts or Sales Head can approve or reject a driver return';
  END IF;
  IF v_action NOT IN ('APPROVE','REJECT') THEN
    RAISE EXCEPTION 'Action must be APPROVE or REJECT';
  END IF;
  IF v_action = 'REJECT' AND length(COALESCE(v_note,'')) < 3 THEN
    RAISE EXCEPTION 'Rejection reason is required';
  END IF;
  IF length(COALESCE(v_note,'')) > 500 THEN
    RAISE EXCEPTION 'Note is too long';
  END IF;

  SELECT * INTO v_return
  FROM public.lwb_driver_delivery_returns
  WHERE id = p_return_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Driver return not found'; END IF;
  IF v_return.status <> 'PENDING_OFFICE' THEN
    RAISE EXCEPTION 'This return was already reviewed (%)', v_return.status;
  END IF;

  v_status := CASE WHEN v_action = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END;

  UPDATE public.lwb_driver_delivery_returns
  SET status = v_status,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      review_note = v_note
  WHERE id = p_return_id;

  -- Tell the driver who recorded it.
  SELECT o.order_no INTO v_order_no
  FROM public.orders o WHERE o.id = v_return.order_id;

  INSERT INTO public.erp_notifications
    (user_id, title, message, notification_type, order_id)
  VALUES (
    v_return.driver_user_id,
    'Delivery Return ' || initcap(v_status),
    'Office ' || lower(v_status) || ' your return on ' ||
      COALESCE(v_order_no,'order') || ' (Rs ' ||
      to_char(v_return.total_return_amount,'FM9999999990.00') || ')' ||
      COALESCE('. Note: ' || v_note, ''),
    'DELIVERY_RETURN_' || v_status,
    v_return.order_id
  );

  RETURN v_status;
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_driver_list_order_returns(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_driver_cancel_delivery_return(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_driver_edit_delivery_return(uuid,jsonb,text,text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_review_driver_return(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_driver_list_order_returns(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_driver_cancel_delivery_return(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_driver_edit_delivery_return(uuid,jsonb,text,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_review_driver_return(uuid,text,text) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Expected: 3 rows, all true.
SELECT 'cancelled status' AS item, EXISTS (SELECT 1 FROM pg_constraint
  WHERE conname = 'lwb_driver_delivery_returns_status_check' AND pg_get_constraintdef(oid) LIKE '%CANCELLED%') AS ok
UNION ALL SELECT 'driver edit function', to_regprocedure('public.lwb_driver_edit_delivery_return(uuid,jsonb,text,text[])') IS NOT NULL
UNION ALL SELECT 'driver return list', to_regprocedure('public.lwb_driver_list_order_returns(uuid)') IS NOT NULL;
