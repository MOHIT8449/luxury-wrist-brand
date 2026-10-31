-- LUXURY WRIST BRAND ERP — PO APPROVAL & DRIVER: CLICK A SUMMARY CARD → LIST OF ITS ORDERS
--
-- Runs automatically when merged (safe to run again).
-- Mohit asked (31 Oct 2026): every count card must open the list of the records behind the
-- number. The PO Approval summary cards (Total Pending Delivery, Approval late, Delivery
-- delayed, Urgent, and the Order Flow cards Total / Approved / Transport allocated / Loading /
-- Delivered) are counted in the database by lwb_po_approval_summary(). This function returns
-- the same orders for one card, using exactly the same rules, so the list always matches
-- the number on the card.
-- Read-only: nothing is inserted or changed. Admin and Sales Head only (same as the summary).

BEGIN;

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
          AND timezone('Asia/Kolkata', dr.reported_at)::date BETWEEN d1 AND d2)
      ORDER BY ord.order_date DESC, ord.created_at DESC;
    RETURN;
  END IF;

  RETURN QUERY
  WITH
  done AS (
    SELECT DISTINCT x.order_id FROM public.lwb_delivery_reports x
    WHERE x.delivery_status IN ('DELIVERED','PARTIAL')
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

REVOKE ALL ON FUNCTION public.lwb_po_summary_orders(text, date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_summary_orders(text, date, date) TO authenticated;

-- ---------------------------------------------------------------------------
-- Daily Summary cards → list. Same rules as lwb_daily_summary(): Orders Received, Deliveries,
-- Payments Received, Outstanding. Admin, Sales Head and Accounts (same as the Daily Summary).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_daily_summary_list(p_date date, p_card text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  d date := coalesce(p_date, timezone('Asia/Kolkata', now())::date);
  c text := lower(btrim(coalesce(p_card, '')));
  r jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager','accounts')
  ) THEN
    RAISE EXCEPTION 'Daily Summary is available to Admin, Manager and Accounts only';
  END IF;

  IF c = 'orders' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'order_no', o.order_no, 'order_date', o.order_date, 'customer_name', o.customer_name,
             'sales_person', o.sales_person, 'status', o.status, 'total_qty', o.total_qty,
             'total_weight', o.total_weight, 'total_amount', o.total_amount)
             ORDER BY o.order_date, o.order_no), '[]'::jsonb)
      INTO r
    FROM public.orders o
    WHERE timezone('Asia/Kolkata', o.order_date::timestamptz)::date = d;

  ELSIF c = 'deliveries' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'order_no', o.order_no, 'customer_name', o.customer_name, 'total_amount', o.total_amount,
             'delivery_status', dr.delivery_status, 'reported_at', dr.reported_at,
             'cash_reported', dr.cash_reported,
             'driver', coalesce(nullif(btrim(p.full_name),''), a.driver_name, 'Driver'),
             'vehicle_no', a.vehicle_no)
             ORDER BY dr.reported_at), '[]'::jsonb)
      INTO r
    FROM public.lwb_delivery_reports dr
    JOIN public.orders o ON o.id = dr.order_id
    LEFT JOIN public.user_profiles p ON p.id = dr.driver_user_id
    LEFT JOIN public.dispatch_assignments a ON a.id = dr.assignment_id
    WHERE timezone('Asia/Kolkata', dr.reported_at)::date = d;

  ELSIF c = 'payments' THEN
    WITH drv AS (
      SELECT x.*, o.order_no, o.customer_name,
             coalesce(x.cash_amount, CASE WHEN x.payment_mode = 'CASH' THEN x.cash_reported ELSE 0 END) AS c_amt,
             coalesce(x.online_amount, CASE WHEN x.payment_mode IN ('UPI','BANK','CHEQUE') THEN x.cash_reported ELSE 0 END) AS u_amt
      FROM public.lwb_delivery_reports x
      JOIN public.orders o ON o.id = x.order_id
      WHERE x.payment_status = 'VERIFIED' AND x.cash_reported > 0
        AND timezone('Asia/Kolkata', coalesce(x.payment_reviewed_at, x.reported_at))::date = d
    ),
    pay AS (
      SELECT coalesce(b.customer_name, o.customer_name)::text AS party,
             coalesce(b.internal_bill_no, i.invoice_no)::text AS bill,
             c.payment_mode::text AS mode, c.reference_no::text AS ref, c.amount::numeric AS amount, c.status::text AS status,
             'Payment Collection'::text AS source
      FROM public.lwb_payment_collections c
      LEFT JOIN public.lwb_internal_bills b ON b.id = c.internal_bill_id
      LEFT JOIN public.tax_invoices i ON i.id = c.invoice_id
      LEFT JOIN public.orders o ON o.id = i.order_id
      WHERE c.collection_date = d AND c.status <> 'REJECTED'
      UNION ALL
      SELECT customer_name::text, order_no::text, 'CASH (driver)', NULL::text,
             (CASE WHEN c_amt + u_amt > 0 THEN c_amt ELSE cash_reported END)::numeric, 'POSTED', 'Driver'
      FROM drv WHERE c_amt > 0 OR c_amt + u_amt <= 0
      UNION ALL
      SELECT customer_name::text, order_no::text,
             coalesce(online_mode, CASE WHEN payment_mode IN ('UPI','BANK','CHEQUE') THEN payment_mode END, 'UPI') || ' (driver)',
             coalesce(bank_ref, online_reference, payment_reference)::text, u_amt::numeric, 'POSTED', 'Driver'
      FROM drv WHERE u_amt > 0
    )
    SELECT coalesce(jsonb_agg(to_jsonb(pay) ORDER BY pay.source, pay.party), '[]'::jsonb) INTO r FROM pay;

  ELSIF c = 'outstanding' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('party', x.party, 'amount', round(x.bal,2)) ORDER BY x.bal DESC), '[]'::jsonb)
      INTO r
    FROM (
      SELECT btrim(l.customer_name) AS party, sum(coalesce(l.debit,0) - coalesce(l.credit,0)) AS bal
      FROM public.lwb_party_ledger() l
      WHERE l.entry_date <= d
      GROUP BY 1
    ) x
    WHERE x.bal > 0.5;

  ELSE
    RAISE EXCEPTION 'Unknown Daily Summary card: %', p_card;
  END IF;

  RETURN r;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_daily_summary_list(date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_daily_summary_list(date, text) TO authenticated;

COMMIT;
