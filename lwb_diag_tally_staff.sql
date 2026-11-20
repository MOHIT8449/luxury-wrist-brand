-- Read-only check (ends in an error on purpose, so nothing is kept). Not for main.
DO $diag$
DECLARE r record; v text := ''; v_ok boolean; v_id uuid;
BEGIN
  SELECT id INTO v_id FROM public.user_profiles WHERE lower(btrim(role))='accounts' LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_id, 'role', 'authenticated')::text, true);
  v := v || format('uid_claims_only=%s ', auth.uid() = v_id);
  v := v || format('authuid_src=%s ', left(regexp_replace((SELECT prosrc FROM pg_proc WHERE oid='auth.uid()'::regprocedure), '\s+', ' ', 'g'), 160));
  SET LOCAL ROLE authenticated;
  BEGIN v_ok := public.lwb_tally_staff(); v := v || format('staff_as_auth=%s ', v_ok);
  EXCEPTION WHEN OTHERS THEN v := v || 'staff_err=' || SQLERRM || ' '; END;
  RESET ROLE;
  FOR r IN SELECT n.nspname, p.proname, pg_get_userbyid(p.proowner) own, p.prosecdef,
                  substr(p.prosrc, greatest(position('can enter the Tally bill' IN p.prosrc)-140,1), 140) ctx
           FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
           WHERE p.prosrc LIKE '%can enter the Tally bill%' LOOP
    v := v || format('{%s.%s own=%s def=%s ctx=%s} ', r.nspname, r.proname, r.own, r.prosecdef, regexp_replace(r.ctx, '\s+', ' ', 'g'));
  END LOOP;
  FOR r IN SELECT tgname, tgrelid::regclass t, tgfoid::regproc f FROM pg_trigger WHERE tgrelid='public.lwb_tally_invoices'::regclass AND NOT tgisinternal LOOP
    v := v || format('[trg %s %s] ', r.tgname, r.f);
  END LOOP;
  v := v || format('exec_auth=%s', has_function_privilege('authenticated','public.lwb_tally_staff()','EXECUTE'));
  RAISE EXCEPTION 'DIAG %', v;
END
$diag$;
