-- LUXURY WRIST BRAND ERP — PENDING DELIVERY COUNTS THE ADMIN "MARK DELIVERED" TOO
--
-- Runs by itself when merged to main. Safe to run again. Read-only functions: nothing is inserted,
-- changed or deleted.
--
-- Mohit (16 Nov 2026): PO / Sales showed "Pending delivery 235 POs" while the PO List tabs showed only
-- 15 (PO List) + 23 (Transport Assigned) not delivered; 197 were in Delivered. The Delivered tab
-- (lwb_po_delivered_orders) counts a driver report Delivered / Partial OR an Admin / Sales Head
-- "Mark delivered" (lwb_admin_order_marks kind DELIVERED), but the summary cards only looked at the
-- driver report and the order status, so every PO marked delivered by hand stayed "pending".
-- Now the same two sources decide "delivered" everywhere:
--   * lwb_po_approval_summary: Total pending delivery, Delivered (by mark date), Loading,
--     Approval late, Delivery late and Urgent leave out POs marked delivered.
--   * lwb_po_summary_orders: the lists behind those cards, same rule.
-- Needs lwb_admin_mark_load_deliver_setup.sql (table lwb_admin_order_marks).

BEGIN;

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
    SELECT x.order_id FROM public.lwb_delivery_reports x
    WHERE x.delivery_status IN ('DELIVERED','PARTIAL')
    UNION
    SELECT m.order_id FROM public.lwb_admin_order_marks m WHERE m.kind = 'DELIVERED'
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
    SELECT dd.order_id, coalesce(ord.total_amount,0) AS amt
    FROM (
      SELECT dr.order_id FROM public.lwb_delivery_reports dr
      WHERE dr.delivery_status IN ('DELIVERED','PARTIAL')
        AND timezone('Asia/Kolkata', dr.reported_at)::date BETWEEN d1 AND d2
      UNION
      SELECT m.order_id FROM public.lwb_admin_order_marks m
      WHERE m.kind = 'DELIVERED' AND m.mark_date BETWEEN d1 AND d2
    ) dd
    JOIN public.orders ord ON ord.id = dd.order_id
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

CREATE OR REPLACE FUNCTION public.lwb_po_summary_orders(
  p_bucket text,
  p_from date DEFAULT NULL,
  p_to date DEFAULT NULL
)
RETURNS SETOF public.orders
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  d1 date := coalesce(p_from, timezone('Asia/Kolkata', now())::date);
  d2 date := coalesce(p_to, p_from, timezone('Asia/Kolkata', now())::date);
  b text := lower(btrim(coalesce(p_bucket, '')));
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
  IF b NOT IN ('total','approved','allocated','loading','delivered','pending',
               'late_approval','late_delivery','urgent') THEN
    RAISE EXCEPTION 'Unknown summary card: %', p_bucket;
  END IF;

  IF b = 'delivered' THEN
    RETURN QUERY
      SELECT ord.*
      FROM public.orders ord
      WHERE ord.id IN (
        SELECT dr.order_id FROM public.lwb_delivery_reports dr
        WHERE dr.delivery_status IN ('DELIVERED','PARTIAL')
          AND timezone('Asia/Kolkata', dr.reported_at)::date BETWEEN d1 AND d2
        UNION
        SELECT m.order_id FROM public.lwb_admin_order_marks m
        WHERE m.kind = 'DELIVERED' AND m.mark_date BETWEEN d1 AND d2)
      ORDER BY ord.order_date DESC, ord.created_at DESC;
    RETURN;
  END IF;

  RETURN QUERY
  WITH
  done AS (
    SELECT x.order_id FROM public.lwb_delivery_reports x
    WHERE x.delivery_status IN ('DELIVERED','PARTIAL')
    UNION
    SELECT m.order_id FROM public.lwb_admin_order_marks m WHERE m.kind = 'DELIVERED'
  ),
  live AS (
    SELECT o.id, o.order_date,
           coalesce(o.priority,'NORMAL') AS prio,
           coalesce(o.created_at, o.order_date::timestamptz) AS taken_at,
           regexp_replace(lower(btrim(coalesce(o.status::text,''))), '[\s-]+', '_', 'g') AS st,
           EXISTS (SELECT 1 FROM done WHERE done.order_id = o.id) AS delivered,
           EXISTS (SELECT 1 FROM public.dispatch_assignments a WHERE a.order_id = o.id) AS allocated
    FROM public.orders o
    WHERE regexp_replace(lower(btrim(coalesce(o.status::text,''))), '[\s-]+', '_', 'g')
          NOT IN ('cancelled','canceled')
  ),
  inrange AS (
    SELECT * FROM live
    WHERE timezone('Asia/Kolkata', live.order_date::timestamptz)::date BETWEEN d1 AND d2
  ),
  pend AS (
    SELECT * FROM live
    WHERE NOT live.delivered AND live.st NOT IN ('delivered','closed','completed')
  ),
  pick AS (
    SELECT i.id FROM inrange i WHERE b = 'total'
    UNION ALL
    SELECT i.id FROM inrange i WHERE b = 'approved'
      AND i.st NOT IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new')
    UNION ALL
    SELECT i.id FROM inrange i WHERE b = 'allocated'
      AND (i.allocated OR i.st IN ('transport_allocated','allocated','loading','loaded','invoiced','dispatched','delivered'))
    UNION ALL
    SELECT i.id FROM inrange i WHERE b = 'loading'
      AND i.st IN ('loading','loaded','invoiced','dispatched') AND NOT i.delivered
    UNION ALL
    SELECT p.id FROM pend p WHERE b = 'pending'
    UNION ALL
    SELECT p.id FROM pend p WHERE b = 'late_approval'
      AND p.st IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new')
      AND p.taken_at < now() - interval '12 hours'
    UNION ALL
    SELECT p.id FROM pend p WHERE b = 'late_delivery'
      AND p.taken_at < now() - interval '36 hours'
    UNION ALL
    SELECT p.id FROM pend p WHERE b = 'urgent'
      AND p.prio IN ('HIGH','URGENT')
  )
  SELECT ord.*
  FROM public.orders ord
  WHERE ord.id IN (SELECT pick.id FROM pick)
  ORDER BY ord.order_date DESC, ord.created_at DESC;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_po_approval_summary(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_approval_summary(date, date) TO authenticated;
REVOKE ALL ON FUNCTION public.lwb_po_summary_orders(text, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_summary_orders(text, date, date) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';
