-- LUXURY WRIST BRAND ERP — DRIVER / BILL MONEY HISTORY (Daily Summary)
--
-- RUN ONCE in Supabase SQL Editor (after lwb_office_receive_driver_money.sql). Safe to run again.
-- Mohit asked (28 Oct 2026): on Daily Summary, tap a driver or a bill and see, bill by bill,
-- how much money came against it, when, cash / UPI + UTR, and who received it at the office.
-- Read only. Admin, Sales Head (manager) and Accounts. The Tally invoice number is shown
-- only to Accounts / Admin, as everywhere else.

CREATE OR REPLACE FUNCTION public.lwb_driver_bill_history(p_mobile text, p_from date, p_to date)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_from date := coalesce(p_from, (now() AT TIME ZONE 'Asia/Kolkata')::date - 30);
  v_to date := coalesce(p_to, (now() AT TIME ZONE 'Asia/Kolkata')::date);
  v_mobile text := nullif(btrim(coalesce(p_mobile,'')),'');
  v_tally boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','accounts')) THEN
    RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can see driver money history';
  END IF;
  IF v_to < v_from OR v_to - v_from > 366 THEN RAISE EXCEPTION 'Choose up to one year'; END IF;
  v_tally := EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid()
                     AND lower(btrim(p.role)) IN ('admin','accounts'));

  RETURN coalesce((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.delivered_at DESC)
    FROM (
      SELECT d.id AS report_id, d.order_id, o.order_no, o.customer_name AS party,
             coalesce(nullif(btrim(dp.full_name),''), a.driver_name, 'Driver') AS driver,
             coalesce(dp.mobile, a.driver_mobile) AS mobile, a.vehicle_no AS vehicle,
             d.reported_at AS delivered_at, d.delivery_status,
             b.gross AS bill, b.approved_return, b.net,
             coalesce(d.cash_amount, CASE WHEN d.payment_mode = 'CASH' THEN d.cash_reported ELSE 0 END) AS cash,
             coalesce(d.online_amount, CASE WHEN d.payment_mode IN ('UPI','BANK','CHEQUE') THEN d.cash_reported ELSE 0 END) AS online,
             coalesce(d.online_mode, CASE WHEN d.payment_mode IN ('UPI','BANK','CHEQUE') THEN d.payment_mode END) AS online_mode,
             coalesce(d.bank_ref, d.online_reference, d.payment_reference) AS utr,
             d.bank_ref IS NOT NULL AS bank_checked,
             coalesce(d.cash_reported,0) AS collected,
             coalesce(d.payment_status, CASE WHEN d.cash_reported > 0 THEN 'PENDING' ELSE 'NONE' END) AS status,
             d.office_received,
             rp.full_name AS received_by, d.payment_reviewed_at AS received_at, d.payment_review_note AS note,
             GREATEST(0, b.net - CASE WHEN d.payment_status = 'VERIFIED' THEN coalesce(d.cash_reported,0) ELSE 0 END) AS due,
             CASE WHEN v_tally THEN t.invoice_no END AS tally_invoice_no
      FROM public.lwb_delivery_reports d
      JOIN public.orders o ON o.id = d.order_id
      LEFT JOIN public.dispatch_assignments a ON a.id = d.assignment_id
      LEFT JOIN public.user_profiles dp ON dp.id = d.driver_user_id
      LEFT JOIN public.user_profiles rp ON rp.id = d.payment_reviewed_by
      LEFT JOIN public.lwb_tally_invoices t ON t.order_id = d.order_id
      CROSS JOIN LATERAL public.lwb_order_bill_numbers(d.order_id) b
      WHERE timezone('Asia/Kolkata', d.reported_at)::date BETWEEN v_from AND v_to
        AND (v_mobile IS NULL OR public.lwb_driver_phone_matches(coalesce(dp.mobile, a.driver_mobile), v_mobile))
      ORDER BY d.reported_at DESC
      LIMIT 500
    ) x), '[]'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_driver_bill_history(text,date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_driver_bill_history(text,date,date) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Check: 1 row, ok = true
SELECT 'driver_bill_history' AS item, to_regprocedure('public.lwb_driver_bill_history(text,date,date)') IS NOT NULL AS ok;
