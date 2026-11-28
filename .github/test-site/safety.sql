-- Runs on the TEST database only, after every copy / SQL apply.
-- Keeps the test database from reaching real people: phone push off and
-- pointed at the test project, no saved phones, no cron jobs.
-- Needs: set lwb.test_url / lwb.test_site first (the workflow does it).
DO $$
BEGIN
  IF to_regclass('public.lwb_push_config') IS NOT NULL THEN
    UPDATE public.lwb_push_config SET enabled = false, vapid_public = NULL, vapid_private = NULL,
      project_url = current_setting('lwb.test_url'), site_url = current_setting('lwb.test_site');
  END IF;
  IF to_regclass('public.lwb_push_subscriptions') IS NOT NULL THEN DELETE FROM public.lwb_push_subscriptions; END IF;
  IF to_regclass('cron.job') IS NOT NULL THEN
    PERFORM cron.unschedule(jobid) FROM cron.job;
  END IF;
END $$;
