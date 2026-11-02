-- LUXURY WRIST BRAND ERP — PO JOURNEY: WHERE HAS EACH PO REACHED
--
-- Runs by itself when merged to main. Safe to run again. Read only: nothing is changed or deleted.
--
-- Mohit asked (2 Nov 2026): on PO Approval, every PO shows its journey
--   1 PO made → 2 Approved → 3 Transport assigned → 4 Loading start → 5 Out for delivery → 6 Delivered.
-- "Out for delivery" = loading has started and Accounts has entered the Tally bill no.
-- The Tally bill table is readable only by Accounts / Admin, so the Sales Head gets the bill no. and
-- time through this function (no amounts).
--   * lwb_po_journey(order ids): per order the transport, loading times, Tally bill no. + entry time and
--     the latest driver delivery report. Admin, Sales Head (MANAGER), Godown Manager (WAREHOUSE) and
--     Accounts, max 500 orders per call.
-- 2 Nov 2026: Godown Manager and Accounts also open PO / Sales List (view only) and see the journey.
-- 2 Nov 2026 (Mohit): step 7 "Collection": how much of this bill the party has paid. Adds bill_amount,
--   collected (driver payments not rejected + office / party payments set against this PO) and due
--   (same formula as Billing & Outstanding: bill − credit notes + debit notes − collected; no Tally
--   amount yet = loaded value − approved returns). The return type changed, so the function is dropped first.

BEGIN;

DROP FUNCTION IF EXISTS public.lwb_po_journey(uuid[]);
CREATE FUNCTION public.lwb_po_journey(p_ids uuid[])
RETURNS TABLE(order_id uuid, assigned_at timestamptz, vehicle_no text, driver_name text, driver_mobile text,
  loading_person text, loading_started_at timestamptz, loading_completed_at timestamptz,
  bill_no text, bill_at timestamptz, delivery_status text, reported_at timestamptz,
  bill_amount numeric, collected numeric, due numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','warehouse','accounts')) THEN
    RAISE EXCEPTION 'Admin / Sales Head / Godown Manager / Accounts only.';
  END IF;
  IF coalesce(cardinality(p_ids), 0) > 500 THEN
    RAISE EXCEPTION 'Max 500 orders at a time.';
  END IF;
  RETURN QUERY
    SELECT o.id,
           nullif(da.j->>'assigned_at','')::timestamptz,
           da.j->>'vehicle_no', da.j->>'driver_name', da.j->>'driver_mobile', da.j->>'loading_person',
           nullif(da.j->>'loading_started_at','')::timestamptz,
           nullif(da.j->>'loading_completed_at','')::timestamptz,
           t.invoice_no, coalesce(t.updated_at, t.entered_at),
           dr.delivery_status, dr.reported_at,
           t.amount,
           round(coalesce(pay.got,0) + op.amt, 2),
           CASE WHEN t.order_id IS NULL AND bn.gross = 0 THEN NULL
                ELSE round(coalesce(t.amount, bn.net + coalesce(n.cr,0)) - coalesce(n.cr,0) + coalesce(n.dr,0)
                           - coalesce(pay.got,0) - op.amt, 2) END
    FROM (SELECT DISTINCT x FROM unnest(p_ids) AS x) ids
    JOIN public.orders o ON o.id = ids.x
    LEFT JOIN LATERAL (
      SELECT to_jsonb(a) AS j FROM public.dispatch_assignments a
      WHERE a.order_id = o.id
      ORDER BY (to_jsonb(a)->>'assigned_at') DESC NULLS LAST
      LIMIT 1) da ON true
    LEFT JOIN public.lwb_tally_invoices t ON t.order_id = o.id
    LEFT JOIN LATERAL (
      SELECT r.delivery_status, r.reported_at FROM public.lwb_delivery_reports r
      WHERE r.order_id = o.id
      ORDER BY r.reported_at DESC
      LIMIT 1) dr ON true
    CROSS JOIN LATERAL public.lwb_order_bill_numbers(o.id) bn
    CROSS JOIN LATERAL (SELECT public.lwb_order_office_paid(o.id) AS amt) op
    LEFT JOIN LATERAL (
      SELECT sum(x.amount) FILTER (WHERE x.kind = 'CREDIT' AND x.cancelled_at IS NULL) AS cr,
             sum(x.amount) FILTER (WHERE x.kind = 'DEBIT' AND x.cancelled_at IS NULL) AS dr
      FROM public.lwb_tally_notes x WHERE x.order_id = o.id) n ON true
    LEFT JOIN LATERAL (
      SELECT sum(d.cash_reported) FILTER (WHERE coalesce(d.payment_status,'') <> 'REJECTED') AS got
      FROM public.lwb_delivery_reports d WHERE d.order_id = o.id) pay ON true;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_journey(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_journey(uuid[]) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
