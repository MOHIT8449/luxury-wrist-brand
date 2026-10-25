-- LUXURY WRIST BRAND ERP — DAILY SUMMARY (orders, deliveries, money, outstanding)
--
-- RUN ONCE in Supabase SQL Editor, AFTER lwb_party_ledger_setup.sql. Safe to run again.
--
-- Read-only report for Reports > Daily Summary. Admin, Manager and Accounts only.
-- Dates are India time (Asia/Kolkata).
--   * Orders received: orders with order_date on the day
--   * Deliveries: driver delivery reports on the day, per driver
--   * Driver cash: driver-reported collection (report only, office has not verified)
--   * Payments received: payment receipts dated that day, Verified (POSTED) and Pending separately
--   * Outstanding: party ledger balance up to that day (bills − returns − verified payments + opening)
-- Nothing is inserted or changed.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_daily_summary(p_date date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  d date := coalesce(p_date, timezone('Asia/Kolkata', now())::date);
  r jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager','accounts')
  ) THEN
    RAISE EXCEPTION 'Daily Summary is available to Admin, Manager and Accounts only';
  END IF;

  WITH
  o AS (
    SELECT o.* FROM public.orders o
    WHERE timezone('Asia/Kolkata', o.order_date::timestamptz)::date = d
  ),
  dr AS (
    SELECT dr.*, o.order_no, o.customer_name, coalesce(o.total_amount,0) AS order_amount,
           coalesce(nullif(btrim(p.full_name),''), a.driver_name, 'Driver') AS driver,
           coalesce(p.mobile, a.driver_mobile) AS mobile
    FROM public.lwb_delivery_reports dr
    JOIN public.orders o ON o.id = dr.order_id
    LEFT JOIN public.user_profiles p ON p.id = dr.driver_user_id
    LEFT JOIN public.dispatch_assignments a ON a.id = dr.assignment_id
    WHERE timezone('Asia/Kolkata', dr.reported_at)::date = d
  ),
  pay AS (
    SELECT c.* FROM public.lwb_payment_collections c
    WHERE c.collection_date = d AND c.status <> 'REJECTED'
  ),
  led AS (
    SELECT btrim(l.customer_name) AS party, sum(coalesce(l.debit,0) - coalesce(l.credit,0)) AS bal
    FROM public.lwb_party_ledger() l
    WHERE l.entry_date <= d
    GROUP BY 1
  ),
  pend AS (
    SELECT count(*) AS n, coalesce(sum(o.total_amount),0) AS amt
    FROM public.orders o
    WHERE lower(o.status) IN ('transport_allocated','allocated','loading','loaded','invoiced','dispatched')
      AND NOT EXISTS (SELECT 1 FROM public.lwb_delivery_reports x WHERE x.order_id = o.id)
  )
  SELECT jsonb_build_object(
    'date', d,
    'orders', jsonb_build_object(
      'count', (SELECT count(*) FROM o),
      'amount', (SELECT round(coalesce(sum(total_amount),0),2) FROM o),
      'cases', (SELECT round(coalesce(sum(total_qty),0),0) FROM o),
      'by_sales', (SELECT coalesce(jsonb_agg(x ORDER BY x.amount DESC),'[]') FROM (
         SELECT coalesce(nullif(btrim(sales_person),''),'-') AS name, count(*) AS count,
                round(coalesce(sum(total_amount),0),2) AS amount
         FROM o GROUP BY 1) x)),
    'delivery', jsonb_build_object(
      'delivered', (SELECT count(*) FROM dr WHERE delivery_status = 'DELIVERED'),
      'partial', (SELECT count(*) FROM dr WHERE delivery_status = 'PARTIAL'),
      'not_delivered', (SELECT count(*) FROM dr WHERE delivery_status = 'NOT_DELIVERED'),
      'amount', (SELECT round(coalesce(sum(order_amount) FILTER (WHERE delivery_status <> 'NOT_DELIVERED'),0),2) FROM dr),
      'driver_cash', (SELECT round(coalesce(sum(cash_reported),0),2) FROM dr),
      'pending_count', (SELECT n FROM pend),
      'pending_amount', (SELECT round(amt,2) FROM pend),
      'by_driver', (SELECT coalesce(jsonb_agg(x ORDER BY x.delivered DESC, x.driver),'[]') FROM (
         SELECT driver, mobile,
                count(*) FILTER (WHERE delivery_status = 'DELIVERED') AS delivered,
                count(*) FILTER (WHERE delivery_status = 'PARTIAL') AS partial,
                count(*) FILTER (WHERE delivery_status = 'NOT_DELIVERED') AS not_delivered,
                round(coalesce(sum(order_amount) FILTER (WHERE delivery_status <> 'NOT_DELIVERED'),0),2) AS amount,
                round(coalesce(sum(cash_reported),0),2) AS cash,
                string_agg(order_no, ', ' ORDER BY order_no) AS orders
         FROM dr GROUP BY driver, mobile) x)),
    'payments', jsonb_build_object(
      'verified', (SELECT round(coalesce(sum(amount) FILTER (WHERE status = 'POSTED'),0),2) FROM pay),
      'pending', (SELECT round(coalesce(sum(amount) FILTER (WHERE status = 'PENDING'),0),2) FROM pay),
      'count', (SELECT count(*) FROM pay),
      'by_mode', (SELECT coalesce(jsonb_agg(x ORDER BY x.amount DESC),'[]') FROM (
         SELECT payment_mode AS mode, count(*) AS count, round(sum(amount),2) AS amount
         FROM pay GROUP BY 1) x)),
    'outstanding', jsonb_build_object(
      'total', (SELECT round(coalesce(sum(bal) FILTER (WHERE bal > 0.5),0),2) FROM led),
      'parties', (SELECT count(*) FILTER (WHERE bal > 0.5) FROM led),
      'top', (SELECT coalesce(jsonb_agg(x ORDER BY x.amount DESC),'[]') FROM (
         SELECT party, round(bal,2) AS amount FROM led WHERE bal > 0.5 ORDER BY bal DESC LIMIT 10) x))
  ) INTO r;

  RETURN r;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_daily_summary(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_daily_summary(date) TO authenticated;

COMMIT;
