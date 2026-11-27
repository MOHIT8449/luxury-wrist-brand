-- lwb:no-auto-run
-- Read-only check (ends in an error on purpose, so nothing is kept). Not for main.
DO $diag$
DECLARE r record; v text := ''; v_admin uuid;
BEGIN
  SELECT id INTO v_admin FROM public.user_profiles WHERE lower(btrim(role))='admin' AND active LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role','authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  FOR r IN
    SELECT o.order_no, o.status, o.transportation tp, o.total_amount amt,
           (SELECT sum(coalesce(i.loaded_qty,0)) FROM public.order_items i WHERE i.order_id=o.id) lq,
           (SELECT sum(coalesce(i.approved_qty,i.ordered_qty,0)) FROM public.order_items i WHERE i.order_id=o.id) aq,
           to_jsonb(t) tj, (SELECT full_name FROM public.user_profiles WHERE id=t.entered_by) tby,
           (SELECT to_jsonb(ib)-'items' FROM public.lwb_internal_bills ib WHERE ib.order_id=o.id) ib,
           (SELECT to_jsonb(d)-'final_lines' FROM public.lwb_direct_vehicle d WHERE d.order_id=o.id) dv,
           (SELECT sum(CASE WHEN p.mode='REFUND' THEN -p.amount ELSE p.amount END) FROM public.lwb_direct_vehicle_pay p WHERE p.order_id=o.id) dvpay,
           (SELECT count(*) FROM public.lwb_direct_vehicle_pay p WHERE p.order_id=o.id) dvn,
           (SELECT to_jsonb(j) - 'driver_mobile' - 'driver_name' FROM public.lwb_po_journey(ARRAY[o.id]) j) jr,
           (SELECT to_jsonb(b) FROM public.lwb_order_bill_numbers(o.id) b) bn,
           public.lwb_order_office_paid(o.id) op,
           (SELECT count(*) FROM public.dispatch_assignments a WHERE a.order_id=o.id) dan,
           (SELECT count(*) FROM public.lwb_delivery_reports d WHERE d.order_id=o.id) drn
    FROM public.orders o
    WHERE o.transportation ILIKE 'DIRECT VEHICLE%' AND o.created_at > now()-interval '40 days'
    ORDER BY o.created_at
  LOOP
    v := v || format(E'\n[%s st=%s amt=%s aq=%s lq=%s | tally=%s by=%s | ib=%s | dv=%s dvpay=%s n=%s | jr=%s | bn=%s op=%s da=%s dr=%s]',
      r.order_no, r.status, r.amt, r.aq, r.lq, r.tj, r.tby, r.ib, r.dv, r.dvpay, r.dvn, r.jr, r.bn, r.op, r.dan, r.drn);
  END LOOP;
  RAISE EXCEPTION 'DIAG %', v;
END
$diag$;
