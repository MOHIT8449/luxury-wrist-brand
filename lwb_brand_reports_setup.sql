-- LUXURY WRIST BRAND ERP — BRAND-WISE REPORTS (Daily Summary, its card lists, Party Call List)
--
-- Runs by itself when merged (after lwb_brand_money_setup.sql). Safe to run again. Read only: nothing is written.
-- New functions next to the old ones (old ones are not changed):
--   lwb_daily_summary_b(date, company)        = lwb_daily_summary(date) for one brand (NULL = all brands)
--   lwb_daily_summary_list_b(date, card, company)
--   lwb_party_call_list_b(p_all, company)     = parties of that brand whose last order OF THAT BRAND is late
-- A PO is of a brand when it has an SKU of that brand (same as every brand filter on the website).
-- Outstanding uses the brand-wise party ledger (lwb_party_ledger_b).

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_order_has_company(p_order_id uuid, p_company_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT p_company_id IS NULL OR EXISTS (
    SELECT 1 FROM public.order_items i
    JOIN public.sku_master s ON upper(btrim(s.sku_name)) = upper(btrim(i.sku_name))
    WHERE i.order_id = p_order_id AND s.company_id = p_company_id);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_has_company(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_has_company(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_daily_summary_b(p_date date DEFAULT NULL, p_company_id uuid DEFAULT NULL)
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
      AND public.lwb_order_has_company(o.id, p_company_id)
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
      AND public.lwb_order_has_company(dr.order_id, p_company_id)
  ),
  -- driver money received at office that day, split into cash and UPI / bank
  drv AS (
    SELECT x.*,
           coalesce(x.cash_amount, CASE WHEN x.payment_mode = 'CASH' THEN x.cash_reported ELSE 0 END) AS c_amt,
           coalesce(x.online_amount, CASE WHEN x.payment_mode IN ('UPI','BANK','CHEQUE') THEN x.cash_reported ELSE 0 END) AS u_amt
    FROM public.lwb_delivery_reports x
    WHERE x.payment_status = 'VERIFIED' AND x.cash_reported > 0
      AND timezone('Asia/Kolkata', coalesce(x.payment_reviewed_at, x.reported_at))::date = d
      AND public.lwb_order_has_company(x.order_id, p_company_id)
  ),
  pay AS (
    SELECT c.amount, c.status, c.payment_mode FROM public.lwb_payment_collections c
    LEFT JOIN public.lwb_internal_bills b ON b.id = c.internal_bill_id
    LEFT JOIN public.tax_invoices i ON i.id = c.invoice_id
    WHERE c.collection_date = d AND c.status <> 'REJECTED'
      AND (p_company_id IS NULL OR public.lwb_order_has_company(coalesce(b.order_id, i.order_id), p_company_id))
    UNION ALL
    SELECT CASE WHEN c_amt + u_amt > 0 THEN c_amt ELSE cash_reported END, 'POSTED', 'CASH (driver)'
    FROM drv WHERE c_amt > 0 OR c_amt + u_amt <= 0
    UNION ALL
    SELECT u_amt, 'POSTED', coalesce(online_mode, CASE WHEN payment_mode IN ('UPI','BANK','CHEQUE') THEN payment_mode END, 'UPI') || ' (driver)'
    FROM drv WHERE u_amt > 0
  ),
  led AS (
    SELECT btrim(l.customer_name) AS party, sum(coalesce(l.debit,0) - coalesce(l.credit,0)) AS bal
    FROM public.lwb_party_ledger_b() l
    WHERE l.entry_date <= d AND (p_company_id IS NULL OR l.company_id = p_company_id)
    GROUP BY 1
  ),
  pend AS (
    SELECT count(*) AS n, coalesce(sum(o.total_amount),0) AS amt
    FROM public.orders o
    WHERE lower(o.status) IN ('transport_allocated','allocated','loading','loaded','invoiced','dispatched')
      AND NOT EXISTS (SELECT 1 FROM public.lwb_delivery_reports x WHERE x.order_id = o.id)
      AND public.lwb_order_has_company(o.id, p_company_id)
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
      'driver', (SELECT round(coalesce(sum(cash_reported),0),2) FROM drv),
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


CREATE OR REPLACE FUNCTION public.lwb_daily_summary_list_b(p_date date, p_card text, p_company_id uuid DEFAULT NULL)
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
    WHERE timezone('Asia/Kolkata', o.order_date::timestamptz)::date = d
      AND public.lwb_order_has_company(o.id, p_company_id);

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
    WHERE timezone('Asia/Kolkata', dr.reported_at)::date = d
      AND public.lwb_order_has_company(dr.order_id, p_company_id);

  ELSIF c = 'payments' THEN
    WITH drv AS (
      SELECT x.*, o.order_no, o.customer_name,
             coalesce(x.cash_amount, CASE WHEN x.payment_mode = 'CASH' THEN x.cash_reported ELSE 0 END) AS c_amt,
             coalesce(x.online_amount, CASE WHEN x.payment_mode IN ('UPI','BANK','CHEQUE') THEN x.cash_reported ELSE 0 END) AS u_amt
      FROM public.lwb_delivery_reports x
      JOIN public.orders o ON o.id = x.order_id
      WHERE x.payment_status = 'VERIFIED' AND x.cash_reported > 0
        AND timezone('Asia/Kolkata', coalesce(x.payment_reviewed_at, x.reported_at))::date = d
        AND public.lwb_order_has_company(x.order_id, p_company_id)
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
        AND (p_company_id IS NULL OR public.lwb_order_has_company(coalesce(b.order_id, i.order_id), p_company_id))
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
      FROM public.lwb_party_ledger_b() l
      WHERE l.entry_date <= d AND (p_company_id IS NULL OR l.company_id = p_company_id)
      GROUP BY 1
    ) x
    WHERE x.bal > 0.5;

  ELSE
    RAISE EXCEPTION 'Unknown Daily Summary card: %', p_card;
  END IF;

  RETURN r;
END;
$fn$;


CREATE OR REPLACE FUNCTION public.lwb_party_call_list_b(p_all boolean DEFAULT false, p_company_id uuid DEFAULT NULL)
RETURNS TABLE (customer_id uuid, customer_name text, city text, mobile text,
               salesman_id uuid, salesman_name text, every_days integer,
               last_order_date date, last_order_no text, days_since integer,
               due boolean, called_today boolean, wait_until date, last_call jsonb, calls_7d integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
#variable_conflict use_column
DECLARE
  v_head boolean := public.lwb_sales_head();
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  IF NOT (v_head OR public.lwb_is_sales_user()) THEN RAISE EXCEPTION 'Sales team only'; END IF;
  RETURN QUERY
    WITH parties AS (
      SELECT m.id, m.customer_name, m.city, m.mobile, m.order_every_days, a.salesman_id, p.full_name AS sm_name
      FROM public.lwb_customer_master m
      LEFT JOIN public.lwb_party_salesman a ON a.customer_id = m.id
      LEFT JOIN public.user_profiles p ON p.id = a.salesman_id
      WHERE m.is_active IS TRUE AND m.order_every_days IS NOT NULL
        AND (v_head OR a.salesman_id = auth.uid())
    ), x AS (
      SELECT pt.*, lo.d AS last_d, lo.order_no AS last_no, lc.c AS last_call, lc.call_date AS lc_day,
        lc.next_date AS lc_next, lc.result AS lc_result, coalesce(n7.n, 0) AS n7
      FROM parties pt
      LEFT JOIN LATERAL (
        SELECT timezone('Asia/Kolkata', o.order_date::timestamptz)::date AS d, o.order_no
        FROM public.orders o
        WHERE upper(btrim(o.customer_name)) = upper(btrim(pt.customer_name))
          AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected')
          AND public.lwb_order_has_company(o.id, p_company_id)
        ORDER BY o.order_date DESC NULLS LAST LIMIT 1
      ) lo ON true
      LEFT JOIN LATERAL (
        SELECT c.call_date, c.next_date, c.result,
          jsonb_build_object('date', c.call_date, 'at', c.created_at, 'result', c.result, 'reason', c.reason,
            'note', c.note, 'next_date', c.next_date, 'by', c.called_by_name) AS c
        FROM public.lwb_party_calls c WHERE c.customer_id = pt.id ORDER BY c.created_at DESC LIMIT 1
      ) lc ON true
      LEFT JOIN LATERAL (
        SELECT count(*)::integer AS n FROM public.lwb_party_calls c
        WHERE c.customer_id = pt.id AND c.call_date > v_today - 7
      ) n7 ON true
    ), y AS (
      SELECT x.*,
        (x.last_d IS NULL OR v_today - x.last_d >= x.order_every_days) AS late,
        -- A call is only counted after the last order (an order resets the follow-up).
        coalesce(x.lc_day = v_today AND (x.last_d IS NULL OR x.lc_day >= x.last_d), false) AS today_call,
        CASE WHEN x.lc_result = 'WILL_ORDER' AND x.lc_next > v_today AND (x.last_d IS NULL OR x.lc_day >= x.last_d)
             THEN x.lc_next END AS wait_d
      FROM x
    )
    SELECT y.id, y.customer_name::text, y.city::text, y.mobile::text, y.salesman_id, y.sm_name::text, y.order_every_days,
      y.last_d, y.last_no::text, CASE WHEN y.last_d IS NOT NULL THEN v_today - y.last_d END,
      (y.late AND NOT y.today_call AND y.wait_d IS NULL), y.today_call, y.wait_d, y.last_call, y.n7
    FROM y
    WHERE ((p_all AND v_head) OR y.late)
      AND (p_company_id IS NULL OR y.last_d IS NOT NULL)
    ORDER BY (y.late AND NOT y.today_call AND y.wait_d IS NULL) DESC,
      CASE WHEN y.last_d IS NULL THEN 100000 ELSE (v_today - y.last_d) - y.order_every_days END DESC, y.customer_name;
END;
$fn$;


REVOKE ALL ON FUNCTION public.lwb_daily_summary_b(date, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_daily_summary_b(date, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.lwb_daily_summary_list_b(date, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_daily_summary_list_b(date, text, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.lwb_party_call_list_b(boolean, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_call_list_b(boolean, uuid) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';

SELECT 'brand-wise daily summary' AS item, (to_regprocedure('public.lwb_daily_summary_b(date,uuid)') IS NOT NULL) AS ok
UNION ALL SELECT 'brand-wise summary lists', to_regprocedure('public.lwb_daily_summary_list_b(date,text,uuid)') IS NOT NULL
UNION ALL SELECT 'brand-wise call list', to_regprocedure('public.lwb_party_call_list_b(boolean,uuid)') IS NOT NULL;
