-- Read-only check (prints status only, no names / numbers): why did the Day Book PDF not arrive?
DO $d$
DECLARE m text; n text;
BEGIN
  SELECT string_agg(format('[log %s %s %s test=%s %s]', l.id, l.kind, l.status, l.test,
           regexp_replace(left(coalesce(l.error,''), 220), '\d{5,}', '#', 'g')), ' ' ORDER BY l.id DESC)
    INTO m FROM (SELECT * FROM public.lwb_daily_wa_log ORDER BY id DESC LIMIT 6) l;
  m := coalesce(m,'no log');
  IF to_regclass('net._http_response') IS NOT NULL THEN
    EXECUTE $q$SELECT string_agg(format('[net %s code=%s timeout=%s err=%s body=%s]', r.id, r.status_code, r.timed_out,
               left(coalesce(r.error_msg,''),120), regexp_replace(left(coalesce(r.content,''),200), '\d{5,}', '#', 'g')), ' ' ORDER BY r.id DESC)
             FROM (SELECT * FROM net._http_response ORDER BY id DESC LIMIT 4) r$q$ INTO n;
  END IF;
  RAISE EXCEPTION 'DIAG % || %', m, coalesce(n,'no net');
END $d$;
