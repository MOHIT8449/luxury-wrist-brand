-- Read-only check (ends in an error on purpose, so nothing is kept). Not for main.
-- Prints only yes/no flags (no names, no amounts); bill no. only for the one PO asked about.
DO $diag$
DECLARE r record; v text := '';
BEGIN
  FOR r IN
    SELECT o.order_no,
           CASE WHEN o.order_no = 'LXY-00628' THEN t.invoice_no || ' ' || to_char(t.invoice_date,'DD/MM') || ' ' || to_char(t.entered_at AT TIME ZONE 'Asia/Kolkata','DD/MM HH24:MI') END b,
           (t.amount IS NOT NULL) has_amt,
           round(100*(coalesce(t.amount,0) - o.total_amount)/nullif(o.total_amount,0),2) bill_eq_po,
           abs(bn.gross - coalesce(o.total_amount,0)) < 1 loaded_eq_po,
           sign(round(coalesce(t.amount, bn.net) - public.lwb_order_office_paid(o.id))) due_sign,
           EXISTS (SELECT 1 FROM public.lwb_tally_payments p WHERE p.order_id=o.id AND p.cancelled_at IS NULL) tp,
           EXISTS (SELECT 1 FROM public.lwb_party_allocs a WHERE a.order_id=o.id AND a.cancelled_at IS NULL) pa
    FROM public.orders o
    LEFT JOIN public.lwb_tally_invoices t ON t.order_id=o.id
    CROSS JOIN LATERAL public.lwb_order_bill_numbers(o.id) bn
    WHERE o.transportation ILIKE 'DIRECT VEHICLE%' AND o.created_at > now()-interval '40 days'
    ORDER BY o.created_at
  LOOP
    v := v || format(' [%s %s amt=%s diffpct=%s ldiffpct=%s due=%s tp=%s pa=%s]',
      r.order_no, coalesce(r.b,''), r.has_amt, r.bill_eq_po, r.loaded_eq_po, r.due_sign, r.tp, r.pa);
  END LOOP;
  RAISE EXCEPTION 'DIAG %', v;
END
$diag$;
