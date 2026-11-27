-- Read-only check (ends in an error on purpose, so nothing is kept). Not for main.
-- Prints only yes/no flags and counts (no names, no amounts).
DO $diag$
DECLARE r record; v text := '';
BEGIN
  FOR r IN
    SELECT o.order_no, o.status,
           (t.order_id IS NOT NULL) tally,
           EXISTS (SELECT 1 FROM public.lwb_internal_bills ib WHERE ib.order_id=o.id) ib,
           EXISTS (SELECT 1 FROM public.lwb_direct_vehicle d WHERE d.order_id=o.id) dv,
           (SELECT count(*) FROM public.lwb_direct_vehicle_pay p WHERE p.order_id=o.id) dvpay_n,
           (SELECT count(*) FROM public.order_items i WHERE i.order_id=o.id AND coalesce(i.loaded_qty,0)>0) loaded_lines,
           (SELECT count(*) FROM public.dispatch_assignments a WHERE a.order_id=o.id) da_n,
           (SELECT count(*) FROM public.lwb_delivery_reports d WHERE d.order_id=o.id) dr_n,
           (public.lwb_order_office_paid(o.id) > 0) office_paid
    FROM public.orders o
    LEFT JOIN public.lwb_tally_invoices t ON t.order_id=o.id
    WHERE o.transportation ILIKE 'DIRECT VEHICLE%' AND o.created_at > now()-interval '40 days'
    ORDER BY o.created_at
  LOOP
    v := v || format(' [%s %s tally=%s ib=%s dv=%s pay=%s ll=%s da=%s dr=%s op=%s]',
      r.order_no, r.status, r.tally, r.ib, r.dv, r.dvpay_n, r.loaded_lines, r.da_n, r.dr_n, r.office_paid);
  END LOOP;
  RAISE EXCEPTION 'DIAG %', v;
END
$diag$;
