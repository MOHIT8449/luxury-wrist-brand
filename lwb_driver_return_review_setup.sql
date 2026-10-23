-- LUXURY WRIST BRAND ERP — OFFICE REVIEW OF DRIVER DELIVERY RETURNS
--
-- RUN ONCE in Supabase SQL Editor, after lwb_driver_delivery_return_setup.sql
-- and lwb_party_ledger_setup.sql. Safe to run again.
--
-- Driver records leakage / breakage / damage returns as PENDING_OFFICE.
-- This adds:
--  1. lwb_office_list_driver_returns(status): read-only list for office
--     (admin, accounts, manager, warehouse).
--  2. lwb_review_driver_return(id, action, note): Admin or Accounts
--     APPROVES or REJECTS a pending return, once.
--
-- APPROVED returns reduce the party's ERP outstanding (lwb_party_ledger /
-- lwb_party_bills already count them). REJECTED returns free the quantity
-- so the driver can record it again correctly.
-- NO stock, GST, Tally, credit note or payment rows are changed.

BEGIN;

ALTER TABLE public.lwb_driver_delivery_returns
  ADD COLUMN IF NOT EXISTS review_note text;

CREATE OR REPLACE FUNCTION public.lwb_office_list_driver_returns(
  p_status text DEFAULT 'PENDING_OFFICE'
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_status text := upper(btrim(COALESCE(p_status,'PENDING_OFFICE')));
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','accounts','manager','warehouse')
  ) THEN
    RAISE EXCEPTION 'Only active office staff can view driver returns';
  END IF;
  IF v_status NOT IN ('PENDING_OFFICE','APPROVED','REJECTED') THEN
    RAISE EXCEPTION 'Unknown return status %', v_status;
  END IF;

  SELECT COALESCE(jsonb_agg(x ORDER BY x->>'created_at' DESC), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT jsonb_build_object(
      'id', r.id,
      'order_id', r.order_id,
      'order_no', o.order_no,
      'party_name', o.customer_name,
      'driver_name', COALESCE(dp.full_name, a.driver_name),
      'driver_mobile', a.driver_mobile,
      'vehicle_no', a.vehicle_no,
      'note', r.note,
      'status', r.status,
      'total_return_amount', r.total_return_amount,
      'created_at', r.created_at,
      'reviewed_at', r.reviewed_at,
      'reviewed_by_name', rp.full_name,
      'review_note', r.review_note,
      'items', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'sku', li.sku_name,
          'reason', li.reason,
          'uom', li.uom,
          'qty', li.qty,
          'qty_cases', li.qty_cases,
          'rate_per_case', li.rate_per_case,
          'return_amount', li.return_amount
        ) ORDER BY li.sku_name), '[]'::jsonb)
        FROM public.lwb_driver_delivery_return_items li
        WHERE li.return_id = r.id
      )
    ) AS x
    FROM public.lwb_driver_delivery_returns r
    JOIN public.orders o ON o.id = r.order_id
    LEFT JOIN public.user_profiles dp ON dp.id = r.driver_user_id
    LEFT JOIN public.user_profiles rp ON rp.id = r.reviewed_by
    LEFT JOIN LATERAL (
      SELECT d.driver_name, d.driver_mobile, d.vehicle_no
      FROM public.dispatch_assignments d
      WHERE d.order_id = r.order_id
      ORDER BY d.assigned_at DESC NULLS LAST
      LIMIT 1
    ) a ON true
    WHERE r.status = v_status
    ORDER BY r.created_at DESC
    LIMIT 300
  ) t;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_office_list_driver_returns(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_office_list_driver_returns(text) TO authenticated;

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
      AND lower(btrim(p.role)) IN ('admin','accounts')
  ) THEN
    RAISE EXCEPTION 'Only active Admin or Accounts can approve or reject a driver return';
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

REVOKE ALL ON FUNCTION public.lwb_review_driver_return(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_review_driver_return(uuid,text,text) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Read-only confirmation, expect 2 rows:
SELECT p.proname AS ready
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('lwb_office_list_driver_returns','lwb_review_driver_return')
ORDER BY 1;
