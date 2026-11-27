-- READ ONLY diagnostic (never merged). Collects numbers only (no names) and stops with an error
-- so nothing is ever written. Run by hand: Actions > Supabase apply > Run workflow on this branch.
DO $d$
DECLARE o text := ''; r record;
BEGIN
  FOR r IN SELECT p.receipt_id, min(p.created_at AT TIME ZONE 'Asia/Kolkata') c, min(p.pay_date) pd,
                  string_agg(p.mode||':'||p.amount::text, '+' ORDER BY p.created_at) l, count(*) FILTER (WHERE p.cancelled_at IS NOT NULL) cx
           FROM public.lwb_tally_payments p
           WHERE p.party ILIKE '%NAVDURGA%' AND p.pay_date >= DATE '2026-11-25'
           GROUP BY p.receipt_id ORDER BY 2 LOOP
    o := o || ' |RC pd=' || r.pd || ' at=' || to_char(r.c,'DD HH24:MI') || ' ' || r.l || ' cx=' || r.cx;
    o := o || coalesce((SELECT string_agg(' ED at=' || to_char(e.changed_at AT TIME ZONE 'Asia/Kolkata','DD HH24:MI') || ' ' || e.action
              || ' b=' || coalesce(e.before->>'total','') || '/' || coalesce(e.before->>'pay_date','')
              || ' a=' || coalesce(e.after->>'total','') || '/' || coalesce(e.after->>'pay_date','')
              || ' by=' || coalesce((SELECT lower(u.role) FROM public.user_profiles u WHERE u.id = e.changed_by),'?'), '' ORDER BY e.changed_at)
              FROM public.lwb_ledger_edit_log e WHERE e.ref_id = r.receipt_id), ' noedit');
  END LOOP;
  FOR r IN SELECT * FROM public.lwb_acc_day_close c WHERE c.close_date >= DATE '2026-11-20' ORDER BY c.close_date LOOP
    o := o || ' |DC ' || r.close_date || ' st=' || r.is_start || ' exp=' || coalesce(r.expected::text,'') || ' cnt=' || coalesce(r.counted::text,'')
      || ' ret=' || coalesce(r.returned_amount::text,'-') || ' cx=' || (r.cancelled_at IS NOT NULL);
  END LOOP;
  FOR r IN SELECT h.* FROM public.lwb_acc_shift_handovers h WHERE h.given_at >= TIMESTAMPTZ '2026-11-25 18:30+00' ORDER BY h.given_at LOOP
    o := o || ' |HO ' || to_char(r.given_at AT TIME ZONE 'Asia/Kolkata','DD HH24:MI') || ' b' || coalesce(r.batch_id::text,'') || ' book=' || r.book_cash
      || ' cnt=' || r.counted || ' ' || r.status || ' rec=' || coalesce(r.received_amount::text,'-');
  END LOOP;
  FOR r IN SELECT d.*, e.entry_date ed, e.cancelled_at ecx FROM public.lwb_acc_cash_diff d LEFT JOIN public.lwb_acc_entries e ON e.id = d.entry_id
           WHERE d.day >= DATE '2026-11-24' ORDER BY d.created_at LOOP
    o := o || ' |CD ' || r.day || ' ' || r.kind || ' ' || r.amount || ' b' || coalesce(r.batch_id::text,'') || ' ed=' || coalesce(r.ed::text,'')
      || ' cx=' || (r.cancelled_at IS NOT NULL) || '/' || (r.ecx IS NOT NULL);
  END LOOP;
  FOR r IN SELECT g::date dd, (SELECT c.amount FROM public.lwb_acc_cash_at(g::date) c) amt FROM generate_series(DATE '2026-11-25', DATE '2026-11-28', '1 day') g LOOP
    o := o || ' |CA ' || r.dd || '=' || coalesce(r.amt::text,'');
  END LOOP;
  RAISE EXCEPTION 'DIAG%', left(o, 3500);
END $d$;
