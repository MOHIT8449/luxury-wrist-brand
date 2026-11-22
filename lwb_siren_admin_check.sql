-- One-off check for the urgent-task siren on the Admin phone (22 Nov 2026). Changes nothing.
-- Ends with an ERROR on purpose: the Actions log shows only errors, so the counts travel in it.
DO $$
DECLARE r text;
BEGIN
  SELECT concat_ws(' | ',
    'admins='||(SELECT count(*) FROM public.user_profiles WHERE lower(btrim(role))='admin' AND active),
    'admin_phones='||(SELECT count(*) FROM public.lwb_push_subscriptions s JOIN public.user_profiles p ON p.id=s.user_id WHERE lower(btrim(p.role))='admin' AND p.active),
    'admin_phone_labels='||coalesce((SELECT string_agg(left(regexp_replace(s.device_label,'[^A-Za-z0-9 ]','','g'),25)||' updated '||to_char(s.updated_at AT TIME ZONE 'Asia/Kolkata','DD Mon HH24:MI'),'; ') FROM public.lwb_push_subscriptions s JOIN public.user_profiles p ON p.id=s.user_id WHERE lower(btrim(p.role))='admin' AND p.active),'none'),
    'push_enabled='||coalesce((SELECT enabled::text FROM public.lwb_push_config WHERE id=1),'no row'),
    'siren_cron='||(SELECT count(*) FROM cron.job WHERE jobname='lwb-task-siren' AND active),
    'siren_tasks_on='||(SELECT count(*) FROM public.lwb_tasks WHERE siren AND status IN ('OPEN','IN_PROGRESS')),
    'last_demo_jobs='||coalesce((SELECT string_agg(j.state||'/try'||j.attempts||'/sent_to='||(SELECT count(*) FROM public.lwb_push_deliveries d WHERE d.notification_id=j.notification_id)||coalesce('/'||left(j.last_error,40),''),'; ')
       FROM (SELECT n.id FROM public.erp_notifications n WHERE n.notification_type='TASK_SIREN' AND n.created_at>now()-interval '2 hours' ORDER BY n.id DESC LIMIT 3) n
       JOIN public.lwb_push_jobs j ON j.notification_id=n.id::text),'none'))
  INTO r;
  RAISE EXCEPTION 'SIREN CHECK: %', r;
END $$;
