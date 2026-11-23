-- Read-only check (never merged): prints only counts, changes nothing.
DO $chk$
DECLARE v_admin uuid; j jsonb; n bigint; n_pp bigint; n_m bigint;
BEGIN
  SELECT id INTO v_admin FROM public.user_profiles WHERE active AND lower(btrim(role)) = 'admin' LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  j := public.lwb_party_ledger_bj();
  SELECT count(*) INTO n FROM public.lwb_party_ledger_b();
  SELECT count(*) FILTER (WHERE e->>'entry_kind' = 'PARTY_PAYMENT' AND e->>'entry_date' = '2026-11-23'),
         count(*) FILTER (WHERE e->>'entry_kind' = 'PARTY_PAYMENT' AND e->>'entry_date' = '2026-11-23' AND e->>'customer_name' ILIKE 'MANSHI MARKETING%')
    INTO n_pp, n_m FROM jsonb_array_elements(j) e;
  RAISE EXCEPTION 'LEDGERCHECK2 json_rows=% sql_rows=% today_pp_in_json=% manshi_today_in_json=%', jsonb_array_length(j), n, n_pp, n_m;
END
$chk$;
