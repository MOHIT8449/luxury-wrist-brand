-- Read-only check (ends in an error on purpose, so nothing is kept). Not for main.
DO $diag$
DECLARE r record; v text := ''; v_id uuid;
BEGIN
  SELECT id INTO v_id FROM public.user_profiles WHERE lower(btrim(role))='accounts' LIMIT 1;
  FOR r IN SELECT changed_at, action, user_role, (SELECT string_agg(k, ',') FROM jsonb_object_keys(changes) k) ks
           FROM public.lwb_change_log WHERE table_name='user_profiles' AND row_id=v_id::text AND changed_at > now()-interval '3 days' ORDER BY id LOOP
    v := v || format('[up %s %s by %s: %s] ', to_char(r.changed_at AT TIME ZONE 'Asia/Kolkata','DD HH24:MI'), r.action, r.user_role, r.ks);
  END LOOP;
  SELECT to_char(max(changed_at) AT TIME ZONE 'Asia/Kolkata','DD HH24:MI') m, count(*) c INTO r FROM public.lwb_change_log WHERE user_id=v_id AND changed_at > now()-interval '1 day';
  v := v || format('yog_writes_24h=%s last=%s ', r.c, r.m);
  SELECT count(*) c, to_char(max(created_at) AT TIME ZONE 'Asia/Kolkata','DD HH24:MI') m INTO r FROM public.lwb_tally_invoices WHERE created_at > now()-interval '1 day';
  v := v || format('tally_inv_24h=%s last=%s ', r.c, r.m);
  SELECT to_char(created_at AT TIME ZONE 'Asia/Kolkata','DD HH24:MI') c, to_char(last_sign_in_at AT TIME ZONE 'Asia/Kolkata','DD HH24:MI') l INTO r FROM auth.users WHERE id=v_id;
  v := v || format('yog_auth created=%s lastsign=%s ', r.c, r.l);
  SELECT count(*) c, to_char(max(created_at) AT TIME ZONE 'Asia/Kolkata','DD HH24:MI') m INTO r FROM auth.sessions WHERE user_id=v_id;
  v := v || format('yog_sessions=%s last=%s ', r.c, r.m);
  SELECT count(*) INTO r FROM auth.users u WHERE NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id=u.id);
  v := v || format('auth_without_profile=%s ', r.count);
  SELECT count(*) INTO r FROM auth.users u WHERE u.raw_user_meta_data::text ILIKE '%yogesh%' OR u.email ILIKE '%yogesh%';
  v := v || format('auth_yogesh_like=%s ', r.count);
  v := v || format('anon_exec_save=%s anon_exec_staff=%s',
    has_function_privilege('anon','public.lwb_save_tally_bills(uuid,date,jsonb,text)','EXECUTE'),
    has_function_privilege('anon','public.lwb_tally_staff()','EXECUTE'));
  RAISE EXCEPTION 'DIAG %', v;
END
$diag$;
