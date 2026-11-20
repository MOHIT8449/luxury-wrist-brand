-- Read-only check (ends in an error on purpose, so nothing is kept). Not for main.
DO $diag$
DECLARE r record; v text := ''; v_id uuid;
BEGIN
  SELECT id INTO v_id FROM public.user_profiles WHERE lower(btrim(role))='accounts' LIMIT 1;
  SELECT count(*) c, to_char(min(entered_at) AT TIME ZONE 'Asia/Kolkata','HH24:MI') a, to_char(max(entered_at) AT TIME ZONE 'Asia/Kolkata','HH24:MI') b
    INTO r FROM public.lwb_tally_invoices WHERE entered_by=v_id AND entered_at > now()-interval '1 day';
  v := v || format('yog_bills_today=%s first=%s last=%s ', r.c, r.a, r.b);
  SELECT count(*) c INTO r FROM public.lwb_tally_invoices WHERE entered_at > now()-interval '1 day' AND entered_by<>v_id;
  v := v || format('others_today=%s ', r.c);
  FOR r IN SELECT o.order_no, (t.order_id IS NOT NULL) has_bill, to_char(t.entered_at AT TIME ZONE 'Asia/Kolkata','HH24:MI') at_, (t.entered_by=v_id) by_yog
           FROM public.orders o LEFT JOIN public.lwb_tally_invoices t ON t.order_id=o.id
           WHERE o.customer_name ILIKE 'LIMBU TOBACCO%' AND o.created_at > now()-interval '10 days' LOOP
    v := v || format('[%s bill=%s at=%s yog=%s] ', r.order_no, r.has_bill, r.at_, r.by_yog);
  END LOOP;
  RAISE EXCEPTION 'DIAG %', v;
END
$diag$;
