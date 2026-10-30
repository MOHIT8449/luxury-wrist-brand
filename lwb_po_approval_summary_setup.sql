-- LUXURY WRIST BRAND ERP — PO APPROVAL & DRIVER: ORDER SUMMARY CARDS
--
-- RUN ONCE in Supabase SQL Editor (after lwb_driver_delivery_setup.sql). Safe to run again.
-- Mohit asked (30 Oct 2026): on the PO Approval & Driver tab show, for a date range (Today by default):
--   * Total orders          : orders with order date in the range (cancelled left out)
--   * Approved by Sales Head: of those, orders approved or further along
--   * Transport allocated   : of those, orders with a driver / vehicle assigned
--   * Loading               : of those, orders now on the vehicle (loading … dispatched), not yet delivered
--   * Delivered             : driver delivery reports (Delivered / Partial) made in the range
-- plus, for all dates, Total pending delivery: every order not cancelled and not yet delivered
-- (count, cases, amount).
-- Dates are India time (Asia/Kolkata). Read-only: nothing is inserted or changed.

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
    SELECT DISTINCT x.order_id FROM public.lwb_delivery_reports x
    WHERE x.delivery_status IN ('DELIVERED','PARTIAL')
  ),
  live AS (
    SELECT o.id, o.order_date, coalesce(o.total_qty,0) AS qty, coalesce(o.total_amount,0) AS amt,
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
      'amount', (SELECT round(coalesce(sum(amt),0),2) FROM pend),
      'oldest', (SELECT min(timezone('Asia/Kolkata', order_date::timestamptz)::date) FROM pend))
  ) INTO r;

  RETURN r;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_po_approval_summary(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_approval_summary(date, date) TO authenticated;

COMMIT;
