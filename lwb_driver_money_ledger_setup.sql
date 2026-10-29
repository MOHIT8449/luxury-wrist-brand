-- LUXURY WRIST BRAND ERP — DRIVER MONEY POSTS TO PARTY LEDGER
--
-- RUN ONCE in Supabase SQL Editor, after lwb_party_ledger_setup.sql, lwb_daily_summary_setup.sql
-- and lwb_office_receive_driver_money.sql. Safe to run again.
--
-- Mohit decided (29 Oct 2026): money that Accounts receives from the driver on Driver Collections
-- (status VERIFIED) reduces the party's outstanding automatically. Nobody enters it again on
-- Payment Collection.
--  1. Party Ledger: one "Driver Payment" credit per verified delivery, against the order's ERP bill
--     (or old invoice). Orders without an ERP bill / old invoice are not in the ledger yet; their
--     driver money appears there as soon as the bill is made.
--  2. Bill-wise outstanding (Party Ledger, Payment Collection) counts it as paid, so Payment
--     Collection cannot take the same money a second time.
--  3. Admin posting a Payment Collection checks the unpaid amount after driver money too, and
--     receiving driver money checks the amount already posted on Payment Collection.
--  4. Daily Summary "Payments Received" includes driver money received at office that day.
-- Nothing is stored twice: the ledger reads the delivery report itself, so a later correction of
-- the report shows at once. No order, bill, stock or Tally row is changed.

BEGIN;

-- Verified driver money of one order.
CREATE OR REPLACE FUNCTION public.lwb_order_driver_received(p_order_id uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT round(COALESCE(sum(d.cash_reported),0),2)
  FROM public.lwb_delivery_reports d
  WHERE d.order_id = p_order_id AND d.payment_status = 'VERIFIED' AND d.cash_reported > 0;
$function$;
REVOKE ALL ON FUNCTION public.lwb_order_driver_received(uuid) FROM PUBLIC, anon, authenticated;

-- Payment Collection money already POSTED on the bills of one order.
CREATE OR REPLACE FUNCTION public.lwb_order_posted_collections(p_order_id uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT round(COALESCE(sum(c.amount),0),2)
  FROM public.lwb_payment_collections c
  LEFT JOIN public.lwb_internal_bills b ON b.id = c.internal_bill_id
  LEFT JOIN public.tax_invoices i ON i.id = c.invoice_id
  WHERE c.status = 'POSTED' AND COALESCE(b.order_id, i.order_id) = p_order_id;
$function$;
REVOKE ALL ON FUNCTION public.lwb_order_posted_collections(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Bill-wise outstanding: driver money is paid on the order's ERP bill
--    (or, with no ERP bill, its first old invoice). Same columns as before.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_bills()
RETURNS TABLE(
  bill_kind text,
  bill_id uuid,
  bill_no text,
  bill_date date,
  order_id uuid,
  order_no text,
  customer_name text,
  bill_amount numeric,
  return_credit numeric,
  paid_amount numeric,
  pending_amount numeric,
  outstanding_amount numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  WITH bills AS (
    SELECT 'ERP_BILL'::text AS kind, b.id, b.internal_bill_no AS no,
           b.bill_date AS dt, b.order_id, b.order_no, b.customer_name,
           b.goods_amount::numeric AS amt
    FROM public.lwb_internal_bills b
    UNION ALL
    SELECT 'OLD_INVOICE', i.id, i.invoice_no, i.invoice_date::date,
           i.order_id, o.order_no, o.customer_name,
           COALESCE(i.grand_total,0)::numeric
    FROM public.tax_invoices i
    JOIN public.orders o ON o.id = i.order_id
  ),
  pay AS (
    SELECT CASE WHEN c.internal_bill_id IS NOT NULL
                THEN 'ERP_BILL' ELSE 'OLD_INVOICE' END AS kind,
           COALESCE(c.internal_bill_id, c.invoice_id) AS id,
           COALESCE(sum(c.amount) FILTER (WHERE c.status='POSTED'),0) AS posted,
           COALESCE(sum(c.amount) FILTER (WHERE c.status='PENDING'),0) AS pending
    FROM public.lwb_payment_collections c
    GROUP BY 1,2
  ),
  -- the one bill of each order that carries the driver money
  main AS (
    SELECT DISTINCT ON (x.order_id) x.kind, x.id, x.order_id
    FROM bills x WHERE x.order_id IS NOT NULL
    ORDER BY x.order_id, (x.kind = 'ERP_BILL') DESC, x.dt, x.id
  ),
  drv AS (
    SELECT m.kind, m.id, public.lwb_order_driver_received(m.order_id) AS amt
    FROM main m
  )
  SELECT b.kind, b.id, b.no, b.dt, b.order_id, b.order_no,
         btrim(b.customer_name),
         round(b.amt,2),
         public.lwb_order_return_credit(b.order_id),
         round(COALESCE(p.posted,0) + COALESCE(dv.amt,0),2),
         round(COALESCE(p.pending,0),2),
         GREATEST(0, round(
           b.amt - public.lwb_order_return_credit(b.order_id)
                 - COALESCE(p.posted,0) - COALESCE(dv.amt,0)
         ,2))
  FROM bills b
  LEFT JOIN pay p ON p.kind = b.kind AND p.id = b.id
  LEFT JOIN drv dv ON dv.kind = b.kind AND dv.id = b.id
  WHERE public.lwb_ledger_viewer()
  ORDER BY b.dt DESC, b.no DESC;
$function$;

REVOKE ALL ON FUNCTION public.lwb_party_bills() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_bills() TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Party ledger: + DRIVER_PAYMENT credits (rest unchanged)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_ledger()
RETURNS TABLE(
  entry_date date,
  entry_kind text,
  customer_name text,
  ref_no text,
  order_no text,
  debit numeric,
  credit numeric,
  note text,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT * FROM (
    SELECT ob.as_of_date, 'OPENING'::text, btrim(ob.customer_name),
           'Opening Balance'::text, NULL::text,
           GREATEST(ob.amount,0)::numeric, GREATEST(-ob.amount,0)::numeric,
           ob.remarks, ob.updated_at
    FROM public.lwb_party_opening_balances ob

    UNION ALL
    SELECT b.bill_date, 'ERP_BILL', btrim(b.customer_name),
           b.internal_bill_no, b.order_no,
           b.goods_amount::numeric, 0::numeric,
           'ERP Internal Bill', b.created_at
    FROM public.lwb_internal_bills b

    UNION ALL
    SELECT i.invoice_date::date, 'OLD_INVOICE', btrim(o.customer_name),
           i.invoice_no, o.order_no,
           COALESCE(i.grand_total,0)::numeric, 0::numeric,
           'Old ERP invoice record', NULL::timestamptz
    FROM public.tax_invoices i
    JOIN public.orders o ON o.id = i.order_id

    UNION ALL
    SELECT c.collection_date, 'PAYMENT',
           btrim(COALESCE(b.customer_name, o.customer_name)),
           c.payment_mode || COALESCE(' ' || NULLIF(btrim(c.reference_no),''),''),
           COALESCE(b.order_no, o.order_no),
           0::numeric, c.amount::numeric,
           'Against ' || COALESCE(b.internal_bill_no, i.invoice_no),
           c.reviewed_at
    FROM public.lwb_payment_collections c
    LEFT JOIN public.lwb_internal_bills b ON b.id = c.internal_bill_id
    LEFT JOIN public.tax_invoices i ON i.id = c.invoice_id
    LEFT JOIN public.orders o ON o.id = i.order_id
    WHERE c.status = 'POSTED'

    UNION ALL
    SELECT timezone('Asia/Kolkata', COALESCE(d.payment_reviewed_at, d.reported_at))::date, 'DRIVER_PAYMENT',
           btrim(COALESCE(b.customer_name, o.customer_name)),
           COALESCE(NULLIF(d.payment_mode,''), 'CASH')
             || COALESCE(' ' || NULLIF(btrim(COALESCE(d.bank_ref, d.online_reference, d.payment_reference)),''),''),
           o.order_no,
           0::numeric, d.cash_reported::numeric,
           'Driver ' || COALESCE(NULLIF(btrim(dp.full_name),''), 'payment')
             || ', received by ' || COALESCE(NULLIF(btrim(rp.full_name),''), 'office'),
           d.payment_reviewed_at
    FROM public.lwb_delivery_reports d
    JOIN public.orders o ON o.id = d.order_id
    LEFT JOIN public.lwb_internal_bills b ON b.order_id = d.order_id
    LEFT JOIN public.user_profiles dp ON dp.id = d.driver_user_id
    LEFT JOIN public.user_profiles rp ON rp.id = d.payment_reviewed_by
    WHERE d.payment_status = 'VERIFIED' AND d.cash_reported > 0
      AND (b.id IS NOT NULL OR EXISTS (SELECT 1 FROM public.tax_invoices t WHERE t.order_id = d.order_id))

    UNION ALL
    SELECT COALESCE(r.reviewed_at, r.created_at)::date, 'DRIVER_RETURN',
           btrim(o.customer_name), 'Driver return', o.order_no,
           0::numeric, r.total_return_amount::numeric,
           'Office approved driver return', r.reviewed_at
    FROM public.lwb_driver_delivery_returns r
    JOIN public.orders o ON o.id = r.order_id
    WHERE r.status = 'APPROVED' AND r.total_return_amount > 0

    UNION ALL
    SELECT s.return_date::date, 'SALES_RETURN', btrim(o.customer_name),
           s.return_no, o.order_no,
           0::numeric, COALESCE(s.total_amount,0)::numeric,
           'Admin approved sales return', NULL::timestamptz
    FROM public.sales_returns s
    JOIN public.orders o ON o.id = s.order_id
    WHERE lower(btrim(COALESCE(s.approval_status,''))) = 'approved'
      AND COALESCE(s.total_amount,0) > 0
  ) e
  WHERE public.lwb_ledger_viewer();
$function$;

REVOKE ALL ON FUNCTION public.lwb_party_ledger() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_ledger() TO authenticated;

-- ---------------------------------------------------------------------------
-- 3a. Admin POST of a Payment Collection: unpaid amount also minus driver money
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_review_collection(
  p_collection_id uuid,
  p_action text,
  p_note text DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_receipt public.lwb_payment_collections%ROWTYPE;
  v_order_id uuid;
  v_bill_amount numeric(14,2);
  v_paid numeric(14,2);
  v_driver numeric(14,2);
  v_remaining numeric(14,2);
  v_action text := upper(btrim(COALESCE(p_action,'')));
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND active = true AND lower(btrim(role)) = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only an active Admin can verify a collection. Accounts is view-only.';
  END IF;
  IF v_action NOT IN ('POST','REJECT') THEN
    RAISE EXCEPTION 'Review action must be POST or REJECT';
  END IF;

  SELECT * INTO v_receipt FROM public.lwb_payment_collections
   WHERE id = p_collection_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Collection not found'; END IF;
  IF v_receipt.status <> 'PENDING' THEN
    RAISE EXCEPTION 'Collection was already reviewed';
  END IF;

  IF v_action = 'REJECT' THEN
    IF length(btrim(COALESCE(p_note,''))) < 3 THEN
      RAISE EXCEPTION 'Rejection reason is required';
    END IF;
    UPDATE public.lwb_payment_collections
      SET status = 'REJECTED', reviewed_by = auth.uid(), reviewed_at = now(),
          review_note = btrim(p_note)
      WHERE id = p_collection_id;
    RETURN NULL;
  END IF;

  -- Lock the bill so receipts on the same bill post one at a time.
  IF v_receipt.internal_bill_id IS NOT NULL THEN
    SELECT b.goods_amount, b.order_id INTO v_bill_amount, v_order_id
    FROM public.lwb_internal_bills b
    WHERE b.id = v_receipt.internal_bill_id FOR UPDATE;
  ELSE
    SELECT i.grand_total, i.order_id INTO v_bill_amount, v_order_id
    FROM public.tax_invoices i
    WHERE i.id = v_receipt.invoice_id FOR UPDATE;
  END IF;
  IF NOT FOUND OR v_bill_amount IS NULL OR v_bill_amount <= 0 THEN
    RAISE EXCEPTION 'ERP bill / invoice record has no valid amount';
  END IF;

  SELECT COALESCE(sum(c.amount),0) INTO v_paid
  FROM public.lwb_payment_collections c
  WHERE c.status = 'POSTED'
    AND c.internal_bill_id IS NOT DISTINCT FROM v_receipt.internal_bill_id
    AND c.invoice_id IS NOT DISTINCT FROM v_receipt.invoice_id;
  v_driver := public.lwb_order_driver_received(v_order_id);

  v_remaining := round(
    v_bill_amount - public.lwb_order_return_credit(v_order_id) - v_paid - v_driver, 2);
  IF v_remaining <= 0 OR v_receipt.amount > v_remaining THEN
    RAISE EXCEPTION 'Payment exceeds unpaid bill amount after returns% (remaining: %)',
      CASE WHEN v_driver > 0 THEN ' and Rs ' || v_driver || ' received from the driver' ELSE '' END, v_remaining;
  END IF;

  UPDATE public.lwb_payment_collections
    SET status = 'POSTED', reviewed_by = auth.uid(), reviewed_at = now(),
        review_note = NULLIF(btrim(COALESCE(p_note,'')),'')
  WHERE id = p_collection_id;
  RETURN round(v_remaining - v_receipt.amount, 2);
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_review_collection(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_review_collection(uuid,text,text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3b. Receiving driver money: not more than the bill still unpaid after Payment Collection
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_driver_money_not_twice()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_posted numeric; v_gross numeric; v_left numeric;
BEGIN
  v_posted := public.lwb_order_posted_collections(NEW.order_id);
  IF v_posted > 0 AND COALESCE(NEW.cash_reported,0) > 0 THEN
    -- the bill the ledger uses: ERP bill, else old invoice, else loaded qty x rate
    v_gross := COALESCE(
      (SELECT b.goods_amount FROM public.lwb_internal_bills b WHERE b.order_id = NEW.order_id),
      (SELECT sum(i.grand_total) FROM public.tax_invoices i WHERE i.order_id = NEW.order_id),
      (SELECT n.gross FROM public.lwb_order_bill_numbers(NEW.order_id) n));
    v_left := GREATEST(0, round(COALESCE(v_gross,0) - public.lwb_order_return_credit(NEW.order_id) - v_posted
              - COALESCE((SELECT sum(d.cash_reported) FROM public.lwb_delivery_reports d
                          WHERE d.order_id = NEW.order_id AND d.id <> NEW.id AND d.payment_status = 'VERIFIED'),0), 2));
    IF NEW.cash_reported > v_left + 1 THEN
      RAISE EXCEPTION 'Rs % is already posted on Payment Collection for this bill. Only Rs % is left to receive.',
        v_posted, v_left;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.lwb_driver_money_not_twice() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_lwb_driver_money_not_twice ON public.lwb_delivery_reports;
CREATE TRIGGER trg_lwb_driver_money_not_twice
  BEFORE UPDATE OF payment_status, cash_reported ON public.lwb_delivery_reports
  FOR EACH ROW
  WHEN (NEW.payment_status = 'VERIFIED'
        AND (OLD.payment_status IS DISTINCT FROM 'VERIFIED' OR NEW.cash_reported IS DISTINCT FROM OLD.cash_reported))
  EXECUTE FUNCTION public.lwb_driver_money_not_twice();

-- ---------------------------------------------------------------------------
-- 4. Daily Summary: Payments Received also counts driver money received at office that day
--    (same as lwb_daily_summary_setup.sql except the "pay" part)
-- ---------------------------------------------------------------------------
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
  -- driver money received at office that day, split into cash and UPI / bank
  drv AS (
    SELECT x.*,
           coalesce(x.cash_amount, CASE WHEN x.payment_mode = 'CASH' THEN x.cash_reported ELSE 0 END) AS c_amt,
           coalesce(x.online_amount, CASE WHEN x.payment_mode IN ('UPI','BANK','CHEQUE') THEN x.cash_reported ELSE 0 END) AS u_amt
    FROM public.lwb_delivery_reports x
    WHERE x.payment_status = 'VERIFIED' AND x.cash_reported > 0
      AND timezone('Asia/Kolkata', coalesce(x.payment_reviewed_at, x.reported_at))::date = d
  ),
  pay AS (
    SELECT c.amount, c.status, c.payment_mode FROM public.lwb_payment_collections c
    WHERE c.collection_date = d AND c.status <> 'REJECTED'
    UNION ALL
    SELECT CASE WHEN c_amt + u_amt > 0 THEN c_amt ELSE cash_reported END, 'POSTED', 'CASH (driver)'
    FROM drv WHERE c_amt > 0 OR c_amt + u_amt <= 0
    UNION ALL
    SELECT u_amt, 'POSTED', coalesce(online_mode, CASE WHEN payment_mode IN ('UPI','BANK','CHEQUE') THEN payment_mode END, 'UPI') || ' (driver)'
    FROM drv WHERE u_amt > 0
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

REVOKE ALL ON FUNCTION public.lwb_daily_summary(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_daily_summary(date) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Check: 4 rows, all ok = true
SELECT 'ledger has driver payments' AS item,
       (pg_get_functiondef('public.lwb_party_ledger()'::regprocedure) LIKE '%DRIVER_PAYMENT%') AS ok
UNION ALL
SELECT 'bill outstanding counts driver money',
       (pg_get_functiondef('public.lwb_party_bills()'::regprocedure) LIKE '%lwb_order_driver_received%')
UNION ALL
SELECT 'no double receipt check',
       EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_driver_money_not_twice')
UNION ALL
SELECT 'daily summary counts driver money',
       (pg_get_functiondef('public.lwb_daily_summary(date)'::regprocedure) LIKE '%(driver)%');
