DO $do$ DECLARE r text; BEGIN
SELECT string_agg(split_part(p.full_name,' ',1)||' '||left(split_part(p.full_name,' ',2),3)||'.. ['||lower(btrim(p.role))||'] act='||p.active::text||' brands='||(SELECT count(*) FROM public.lwb_user_companies c WHERE c.user_id=p.id), ' | ' ORDER BY p.full_name)
 INTO r FROM public.user_profiles p WHERE lower(btrim(p.role)) IN ('manager','warehouse');
RAISE EXCEPTION 'DIAG %', r; END $do$;
