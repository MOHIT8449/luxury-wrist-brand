-- LUXURY WRIST BRAND ERP — ORDER PRIORITY + APPROVAL / DELIVERY TIME LIMITS
--
-- RUN ONCE in Supabase SQL Editor (after lwb_po_approval_summary_setup.sql and
-- lwb_order_flow_popups_setup.sql). Safe to run again.
-- Mohit asked (30 Oct 2026):
--   1. Total Pending Delivery also shows the total weight (KG) of all pending orders.
--   2. Every order is approved within 12 hours of being taken; later = "Approval late".
--   3. Every order is delivered within 36 hours of being taken; later = "Delivery delayed".
--   4. Salesman / Sales Head can mark an order HIGH or URGENT so it is approved, loaded and
--      delivered first. Sales Head, Admin and the Godown get a bell when it is marked.
-- Adds one column (orders.priority, default NORMAL). Nothing is deleted. No stock, bill,
-- payment, ledger or Tally data is changed.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Priority column
-- ---------------------------------------------------------------------------
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS priority text NOT NULL DEFAULT 'NORMAL';
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS priority_set_by uuid;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS priority_set_at timestamptz;

DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.orders'::regclass AND conname = 'orders_priority_check') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_priority_check
      CHECK (priority IN ('NORMAL','HIGH','URGENT'));
  END IF;
END;
$do$;

-- ---------------------------------------------------------------------------
-- 2. Set priority. Admin / Sales Head: any open order. Salesman: own order while
--    it waits for approval.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_set_order_priority(p_order_id uuid, p_priority text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_role text;
  v_name text;
  v_p text := upper(btrim(coalesce(p_priority,'')));
  v_st text;
BEGIN
  IF v_p NOT IN ('NORMAL','HIGH','URGENT') THEN
    RAISE EXCEPTION 'Priority must be NORMAL, HIGH or URGENT.';
  END IF;
  SELECT lower(btrim(p.role)), p.full_name INTO v_role, v_name
  FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
  IF v_role IS NULL THEN RAISE EXCEPTION 'Login is not active.'; END IF;

  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  v_st := lower(btrim(coalesce(v_o.status,'')));
  IF v_st IN ('cancelled','canceled','delivered','closed','completed')
     OR EXISTS (SELECT 1 FROM public.lwb_delivery_reports d
                WHERE d.order_id = v_o.id AND d.delivery_status IN ('DELIVERED','PARTIAL')) THEN
    RAISE EXCEPTION 'Order % is already closed or delivered.', v_o.order_no;
  END IF;

  IF v_role IN ('admin','manager') THEN
    NULL;
  ELSIF v_role IN ('sales','salesman') AND v_o.created_by = auth.uid() AND public.lwb_order_pending(v_o.status) THEN
    NULL;
  ELSE
    RAISE EXCEPTION 'Only the Sales Head, Admin or the salesman (before approval) can change the priority.';
  END IF;

  IF v_o.priority = v_p THEN
    RETURN jsonb_build_object('id', v_o.id, 'priority', v_p, 'changed', false);
  END IF;

  UPDATE public.orders SET priority = v_p, priority_set_by = auth.uid(), priority_set_at = now()
  WHERE id = v_o.id;

  IF v_p IN ('HIGH','URGENT') THEN
    PERFORM public.lwb_flow_send(v_o.id, ARRAY['manager','admin','godown','salesman'],
      CASE WHEN v_p = 'URGENT' THEN 'URGENT Order' ELSE 'High Priority Order' END,
      concat_ws(' · ', v_o.order_no, v_o.customer_name,
        CASE WHEN v_o.total_weight IS NOT NULL THEN to_char(v_o.total_weight,'FM999999990') || ' KG' END,
        'Marked by ' || coalesce(nullif(btrim(v_name),''), 'Sales'))
        || '. Approve, load and deliver this order first.',
      'ORDER_PRIORITY', true);
  END IF;

  RETURN jsonb_build_object('id', v_o.id, 'priority', v_p, 'changed', true);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_set_order_priority(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_order_priority(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Delivered orders (for the 36-hour badge on the PO list)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_po_delivered_orders(p_ids uuid[])
RETURNS TABLE(order_id uuid, reported_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','warehouse','transport')) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;
  RETURN QUERY
    SELECT d.order_id, max(d.reported_at)
    FROM public.lwb_delivery_reports d
    WHERE d.order_id = ANY(p_ids) AND d.delivery_status IN ('DELIVERED','PARTIAL')
    GROUP BY d.order_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_delivered_orders(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_delivered_orders(uuid[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. PO Approval summary: + pending weight, late approval, delayed delivery, urgent
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_po_approval_summary(p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  d1 date := coalesce(p_from, timezone('Asia/Kolkata', now())::date);
  d2 date := coalesce(p_to, p_from, timezone('Asia/Kolkata', now())::date);
  r jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager')
  ) THEN
    RAISE EXCEPTION 'PO summary is available to Admin and Sales Head only';
  END IF;
  IF d2 < d1 THEN
    d2 := d1;
  END IF;

  WITH
  done AS (
    SELECT DISTINCT x.order_id FROM public.lwb_delivery_reports x
    WHERE x.delivery_status IN ('DELIVERED','PARTIAL')
  ),
  live AS (
    SELECT o.id, o.order_date, coalesce(o.total_qty,0) AS qty, coalesce(o.total_amount,0) AS amt,
           coalesce(o.total_weight,0) AS wt, coalesce(o.priority,'NORMAL') AS prio,
           coalesce(o.created_at, o.order_date::timestamptz) AS taken_at,
           regexp_replace(lower(btrim(coalesce(o.status::text,''))), '[\s-]+', '_', 'g') AS st,
           EXISTS (SELECT 1 FROM done WHERE done.order_id = o.id) AS delivered,
           EXISTS (SELECT 1 FROM public.dispatch_assignments a WHERE a.order_id = o.id) AS allocated
    FROM public.orders o
    WHERE regexp_replace(lower(btrim(coalesce(o.status::text,''))), '[\s-]+', '_', 'g')
          NOT IN ('cancelled','canceled')
  ),
  o AS (
    SELECT * FROM live
    WHERE timezone('Asia/Kolkata', live.order_date::timestamptz)::date BETWEEN d1 AND d2
  ),
  appr AS (
    SELECT * FROM o
    WHERE o.st NOT IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new')
  ),
  alloc AS (
    SELECT * FROM o
    WHERE o.allocated OR o.st IN ('transport_allocated','allocated','loading','loaded','invoiced','dispatched','delivered')
  ),
  load AS (
    SELECT * FROM o
    WHERE o.st IN ('loading','loaded','invoiced','dispatched') AND NOT o.delivered
  ),
  dlv AS (
    SELECT dr.order_id, coalesce(ord.total_amount,0) AS amt
    FROM public.lwb_delivery_reports dr
    JOIN public.orders ord ON ord.id = dr.order_id
    WHERE dr.delivery_status IN ('DELIVERED','PARTIAL')
      AND timezone('Asia/Kolkata', dr.reported_at)::date BETWEEN d1 AND d2
  ),
  pend AS (
    SELECT * FROM live
    WHERE NOT live.delivered AND live.st NOT IN ('delivered','closed','completed')
  ),
  late_appr AS (
    SELECT * FROM pend
    WHERE pend.st IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new')
      AND pend.taken_at < now() - interval '12 hours'
  ),
  late_dlv AS (
    SELECT * FROM pend WHERE pend.taken_at < now() - interval '36 hours'
  ),
  urgent AS (
    SELECT * FROM pend WHERE pend.prio IN ('HIGH','URGENT')
  )
  SELECT jsonb_build_object(
    'from', d1,
    'to', d2,
    'total',     jsonb_build_object('count', (SELECT count(*) FROM o),     'amount', (SELECT round(coalesce(sum(amt),0),2) FROM o)),
    'approved',  jsonb_build_object('count', (SELECT count(*) FROM appr),  'amount', (SELECT round(coalesce(sum(amt),0),2) FROM appr)),
    'allocated', jsonb_build_object('count', (SELECT count(*) FROM alloc), 'amount', (SELECT round(coalesce(sum(amt),0),2) FROM alloc)),
    'loading',   jsonb_build_object('count', (SELECT count(*) FROM load),  'amount', (SELECT round(coalesce(sum(amt),0),2) FROM load)),
    'delivered', jsonb_build_object('count', (SELECT count(DISTINCT order_id) FROM dlv), 'amount', (SELECT round(coalesce(sum(amt),0),2) FROM dlv)),
    'pending', jsonb_build_object(
      'count',  (SELECT count(*) FROM pend),
      'cases',  (SELECT round(coalesce(sum(qty),0),0) FROM pend),
      'weight', (SELECT round(coalesce(sum(wt),0),0) FROM pend),
      'amount', (SELECT round(coalesce(sum(amt),0),2) FROM pend),
      'oldest', (SELECT min(timezone('Asia/Kolkata', order_date::timestamptz)::date) FROM pend)),
    'late_approval', jsonb_build_object(
      'count',  (SELECT count(*) FROM late_appr),
      'amount', (SELECT round(coalesce(sum(amt),0),2) FROM late_appr),
      'max_hours', (SELECT floor(extract(epoch FROM now() - min(taken_at)) / 3600) FROM late_appr)),
    'late_delivery', jsonb_build_object(
      'count',  (SELECT count(*) FROM late_dlv),
      'amount', (SELECT round(coalesce(sum(amt),0),2) FROM late_dlv),
      'weight', (SELECT round(coalesce(sum(wt),0),0) FROM late_dlv),
      'max_hours', (SELECT floor(extract(epoch FROM now() - min(taken_at)) / 3600) FROM late_dlv)),
    'urgent', jsonb_build_object(
      'count',  (SELECT count(*) FROM urgent),
      'urgent', (SELECT count(*) FROM urgent WHERE prio = 'URGENT'),
      'amount', (SELECT round(coalesce(sum(amt),0),2) FROM urgent))
  ) INTO r;

  RETURN r;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_po_approval_summary(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_approval_summary(date, date) TO authenticated;

COMMIT;
