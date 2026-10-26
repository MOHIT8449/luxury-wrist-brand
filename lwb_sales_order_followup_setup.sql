-- LUXURY WRIST BRAND ERP — SALESMAN ORDER FOLLOW-UP: STATUS, DELIVERY BELL, EDIT, CANCEL
--
-- RUN ONCE in Supabase SQL Editor, after lwb_sales_team_setup.sql. Safe to run again.
--
-- * My Sales > My Orders: a salesman sees his orders (Field: also orders of his
--   parties) with the live stage: waiting for approval, approved, driver
--   assigned, loading, loaded, billed, delivered / part delivered / not delivered,
--   or cancelled with the reason.
-- * 🔔 Delivery: when the driver saves the delivery report, the salesman who
--   took the order (and the party's Field salesman) gets a bell.
-- * Edit: the salesman who took the order can change cases or remove a line
--   only while it is still waiting for Sales Head approval. After approval /
--   driver assignment only the Sales Head (PO Approval page) controls it.
-- * Cancel: the salesman can cancel his own order while it is waiting for
--   approval, and must give a reason. The Sales Head gets a bell. When the
--   Sales Head cancels an order, the salesman gets a bell with the reason.
--
-- No stock, bill, payment, ledger or Tally data is changed.

BEGIN;

-- Already present on the live project; listed so the functions below always compile.
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS cancel_reason text;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS cancelled_by uuid;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS cancelled_at timestamptz;
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS unit_weight numeric;
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS total_weight numeric;
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS entry_uom text NOT NULL DEFAULT 'CS';
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS ordered_pallet_qty integer;
ALTER TABLE public.order_items ADD COLUMN IF NOT EXISTS cases_per_pallet_snapshot integer;

-- Same "waiting for approval" list as the PO Approval page.
CREATE OR REPLACE FUNCTION public.lwb_order_pending(p_status text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT coalesce(lower(btrim(p_status)),'') IN
    ('','pending','submitted','pending_manager','pending_approval','pending_review','new');
$fn$;

-- The signed-in salesman's orders of the last p_days days, newest first.
CREATE OR REPLACE FUNCTION public.lwb_my_orders(p_days integer DEFAULT 45)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_field boolean := public.lwb_is_field_salesman();
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required.'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(x.j ORDER BY x.d DESC)
    FROM (
      SELECT coalesce(o.order_date, o.created_at) AS d,
        jsonb_build_object(
          'id', o.id, 'order_no', o.order_no, 'order_date', coalesce(o.order_date, o.created_at),
          'customer_name', o.customer_name, 'status', o.status,
          'total_qty', o.total_qty, 'total_amount', o.total_amount,
          'mine', o.created_by = auth.uid(),
          'can_edit', o.created_by = auth.uid() AND public.lwb_order_pending(o.status),
          'cancel_reason', o.cancel_reason, 'cancelled_at', o.cancelled_at,
          'driver_name', a.driver_name, 'vehicle_no', a.vehicle_no,
          'delivery_status', r.delivery_status, 'delivered_at', r.reported_at,
          'received_by', r.received_by, 'delivery_note', r.delivery_note,
          'items', (SELECT coalesce(jsonb_agg(jsonb_build_object(
              'id', i.id, 'sku_name', i.sku_name, 'ordered_qty', i.ordered_qty,
              'approved_qty', i.approved_qty, 'loaded_qty', i.loaded_qty, 'rate', i.rate,
              'entry_uom', i.entry_uom, 'ordered_pallet_qty', i.ordered_pallet_qty) ORDER BY i.id), '[]'::jsonb)
            FROM public.order_items i WHERE i.order_id = o.id)
        ) AS j
      FROM public.orders o
      LEFT JOIN LATERAL (SELECT da.driver_name, da.vehicle_no FROM public.dispatch_assignments da
        WHERE da.order_id = o.id ORDER BY da.id DESC LIMIT 1) a ON true
      LEFT JOIN public.lwb_delivery_reports r ON r.order_id = o.id
      WHERE coalesce(o.order_date, o.created_at) >= now() - make_interval(days => greatest(1, least(coalesce(p_days,45), 400)))
        AND (o.created_by = auth.uid()
             OR (v_field AND upper(btrim(coalesce(o.customer_name,''))) IN (SELECT public.lwb_my_party_names())))
    ) x
  ), '[]'::jsonb);
END;
$fn$;

-- Salesman changes cases / removes lines of his own order while it waits for approval.
-- p_items: [{"id": <order_items.id>, "cases": <new whole cases, 0 = remove>}]
CREATE OR REPLACE FUNCTION public.lwb_sales_edit_order(p_order_id uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_i public.order_items%ROWTYPE;
  v_new integer;
  v_changes text[] := '{}';
  v_left integer;
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF v_o.created_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Only the salesman who took this order can edit it here.';
  END IF;
  IF NOT public.lwb_order_pending(v_o.status) THEN
    RAISE EXCEPTION 'Order % is already approved / assigned. Ask the Sales Head to change it.', v_o.order_no;
  END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'No changes sent.'; END IF;

  FOR v_i IN SELECT * FROM public.order_items WHERE order_id = p_order_id ORDER BY id LOOP
    SELECT CASE WHEN (e.v->>'cases') ~ '^\d{1,6}$' THEN (e.v->>'cases')::integer END INTO v_new
    FROM jsonb_array_elements(p_items) AS e(v) WHERE (e.v->>'id') = v_i.id::text LIMIT 1;
    IF NOT FOUND THEN CONTINUE; END IF;
    IF v_new IS NULL THEN RAISE EXCEPTION 'Enter whole cases for %.', v_i.sku_name; END IF;
    IF v_new = coalesce(v_i.ordered_qty,0) THEN CONTINUE; END IF;
    IF v_new = 0 THEN
      DELETE FROM public.order_items WHERE id = v_i.id;
      v_changes := v_changes || (v_i.sku_name || ' removed');
    ELSE
      -- A line entered in pallets becomes a plain cases line once its cases are changed.
      UPDATE public.order_items SET ordered_qty = v_new,
        amount = v_new * coalesce(rate,0),
        total_weight = v_new * coalesce(unit_weight,0),
        entry_uom = 'CS', ordered_pallet_qty = NULL, cases_per_pallet_snapshot = NULL
      WHERE id = v_i.id;
      v_changes := v_changes || (v_i.sku_name || ' ' || coalesce(v_i.ordered_qty,0) || '→' || v_new);
    END IF;
  END LOOP;

  SELECT count(*) INTO v_left FROM public.order_items WHERE order_id = p_order_id;
  IF v_left = 0 THEN RAISE EXCEPTION 'An order needs at least one SKU. To drop the whole order, use Cancel.'; END IF;
  IF cardinality(v_changes) = 0 THEN RETURN jsonb_build_object('changed', 0); END IF;

  UPDATE public.orders o SET
    total_qty = t.q, total_amount = t.a, total_weight = t.w
  FROM (SELECT sum(coalesce(ordered_qty,0)) q, sum(coalesce(amount,0)) a, sum(coalesce(total_weight,0)) w
        FROM public.order_items WHERE order_id = p_order_id) t
  WHERE o.id = p_order_id;

  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, 'Salesman Edited Order',
    concat_ws(' · ', v_o.order_no, v_o.customer_name, array_to_string(v_changes, ', ')) || '. Changed before approval.',
    'ORDER_EDITED', p_order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') AND p.id IS DISTINCT FROM auth.uid();

  RETURN jsonb_build_object('changed', cardinality(v_changes), 'changes', to_jsonb(v_changes));
END;
$fn$;

-- Salesman cancels his own order while it waits for approval. A reason is required.
CREATE OR REPLACE FUNCTION public.lwb_sales_cancel_order(p_order_id uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
BEGIN
  IF v_reason IS NULL OR length(v_reason) < 3 THEN RAISE EXCEPTION 'Write the reason for cancelling.'; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF v_o.created_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Only the salesman who took this order can cancel it here.';
  END IF;
  IF NOT public.lwb_order_pending(v_o.status) THEN
    RAISE EXCEPTION 'Order % is already approved / assigned. Ask the Sales Head to cancel it.', v_o.order_no;
  END IF;
  UPDATE public.orders SET status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(),
    cancel_reason = left(v_reason, 500)
  WHERE id = p_order_id;
END;
$fn$;

-- 🔔 on cancel: salesman cancelled → Admin + Sales Head; someone else cancelled → the salesman.
CREATE OR REPLACE FUNCTION public.lwb_notify_order_cancelled()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_msg text;
BEGIN
  IF lower(btrim(coalesce(NEW.status,''))) NOT IN ('cancelled','canceled')
     OR lower(btrim(coalesce(OLD.status,''))) IN ('cancelled','canceled') THEN
    RETURN NEW;
  END IF;
  v_msg := concat_ws(' · ', NEW.order_no, NEW.customer_name,
    CASE WHEN NEW.total_qty IS NOT NULL THEN to_char(NEW.total_qty,'FM999999990') || ' cases' END)
    || '. Reason: ' || coalesce(nullif(btrim(NEW.cancel_reason),''), 'not given') || '.';
  IF NEW.created_by IS NOT NULL AND NEW.created_by = auth.uid() THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, 'Salesman Cancelled Order', v_msg, 'ORDER_CANCELLED', NEW.id
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') AND p.id IS DISTINCT FROM auth.uid();
  ELSIF NEW.created_by IS NOT NULL THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, 'Your Order Was Cancelled', v_msg, 'ORDER_CANCELLED', NEW.id
    FROM public.user_profiles p
    WHERE p.id = NEW.created_by AND p.active = true;
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_notify_order_cancelled() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_notify_order_cancelled ON public.orders;
CREATE TRIGGER trg_lwb_notify_order_cancelled
AFTER UPDATE OF status ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.lwb_notify_order_cancelled();

-- 🔔 on delivery report: the salesman who took the order + the party's Field salesman.
CREATE OR REPLACE FUNCTION public.lwb_notify_order_delivered()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT DISTINCT p.id,
    CASE NEW.delivery_status WHEN 'DELIVERED' THEN 'Order Delivered'
      WHEN 'PARTIAL' THEN 'Order Part Delivered' ELSE 'Order Not Delivered' END,
    concat_ws(' · ', v_o.order_no, v_o.customer_name,
      CASE WHEN nullif(btrim(NEW.received_by),'') IS NOT NULL THEN 'Received by ' || btrim(NEW.received_by) END,
      nullif(btrim(NEW.delivery_note),'')) || '.',
    'ORDER_' || NEW.delivery_status, NEW.order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('sales','salesman')
    AND (p.id = v_o.created_by OR p.id IN (
      SELECT a.salesman_id FROM public.lwb_party_salesman a
      JOIN public.lwb_customer_master m ON m.id = a.customer_id
      WHERE upper(btrim(m.customer_name)) = upper(btrim(coalesce(v_o.customer_name,'')))));
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_notify_order_delivered() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_notify_order_delivered ON public.lwb_delivery_reports;
CREATE TRIGGER trg_lwb_notify_order_delivered
AFTER INSERT ON public.lwb_delivery_reports
FOR EACH ROW EXECUTE FUNCTION public.lwb_notify_order_delivered();

REVOKE ALL ON FUNCTION public.lwb_order_pending(text), public.lwb_my_orders(integer),
  public.lwb_sales_edit_order(uuid, jsonb), public.lwb_sales_cancel_order(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_pending(text), public.lwb_my_orders(integer),
  public.lwb_sales_edit_order(uuid, jsonb), public.lwb_sales_cancel_order(uuid, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check (all should be true):
-- SELECT to_regprocedure('public.lwb_my_orders(integer)') IS NOT NULL AS my_orders,
--        to_regprocedure('public.lwb_sales_edit_order(uuid,jsonb)') IS NOT NULL AS edit_ready,
--        EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_notify_order_delivered') AS delivery_bell;
