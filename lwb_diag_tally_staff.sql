-- Read-only check (ends in an error on purpose, so nothing is kept). Not for main.
DO $diag$
DECLARE r record; v text := ''; v_ok boolean;
BEGIN
  FOR r IN SELECT p.id, lower(btrim(p.role)) AS role, p.active, length(p.role) AS rl,
                  (SELECT count(*) FROM auth.users u WHERE u.id = p.id) AS au
           FROM public.user_profiles p
           WHERE p.full_name ILIKE '%yogesh%' OR lower(btrim(p.role)) IN ('accounts','cashier') LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', r.id, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', r.id::text, true);
    BEGIN v_ok := public.lwb_tally_staff(); EXCEPTION WHEN OTHERS THEN v_ok := NULL; END;
    v := v || format('[role=%s len=%s active=%s auth=%s uid_ok=%s staff=%s] ', r.role, r.rl, r.active, r.au,
                     (auth.uid() = r.id), v_ok);
  END LOOP;
  FOR r IN SELECT p.proname, pg_get_userbyid(p.proowner) AS own, p.prosecdef, pg_get_function_identity_arguments(p.oid) AS args,
                  position('accounts' IN p.prosrc) AS has_acc, position('active' IN p.prosrc) AS has_act, md5(p.prosrc) AS h
           FROM pg_proc p WHERE p.pronamespace='public'::regnamespace AND p.proname IN ('lwb_tally_staff','lwb_save_tally_bills') LOOP
    v := v || format('{%s(%s) own=%s def=%s acc=%s act=%s h=%s} ', r.proname, r.args, r.own, r.prosecdef, r.has_acc, r.has_act, left(r.h,8));
  END LOOP;
  SELECT c.relrowsecurity, c.relforcerowsecurity, pg_get_userbyid(c.relowner) AS own INTO r FROM pg_class c WHERE c.oid='public.user_profiles'::regclass;
  v := v || format('up rls=%s force=%s own=%s ', r.relrowsecurity, r.relforcerowsecurity, r.own);
  SELECT rolbypassrls INTO v_ok FROM pg_roles WHERE rolname = (SELECT pg_get_userbyid(proowner) FROM pg_proc WHERE oid='public.lwb_tally_staff()'::regprocedure);
  v := v || format('fnowner_bypass=%s', v_ok);
  RAISE EXCEPTION 'DIAG %', v;
END
$diag$;
