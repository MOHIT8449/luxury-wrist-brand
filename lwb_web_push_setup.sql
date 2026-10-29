-- LWB phone push. Run once in Supabase SQL Editor, then deploy lwb-web-push.
-- No existing orders / stock / payments are modified. No historical notifications are queued.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

CREATE TABLE IF NOT EXISTS public.lwb_push_config (
 id integer PRIMARY KEY CHECK (id=1), enabled boolean NOT NULL DEFAULT false,
 project_url text NOT NULL DEFAULT 'https://txkbhadzdbxpieunfvox.supabase.co',
 site_url text NOT NULL DEFAULT 'https://luxury-wrist-brand.pages.dev',
 webhook_secret text NOT NULL DEFAULT encode(extensions.gen_random_bytes(32),'hex'),
 vapid_public text, vapid_private text,
 CHECK ((vapid_public IS NULL) = (vapid_private IS NULL))
);
INSERT INTO public.lwb_push_config(id) VALUES(1) ON CONFLICT DO NOTHING;
ALTER TABLE public.lwb_push_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_push_config FROM PUBLIC, anon, authenticated;
GRANT SELECT,UPDATE ON public.lwb_push_config TO service_role;

CREATE TABLE IF NOT EXISTS public.lwb_push_subscriptions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
 endpoint text NOT NULL UNIQUE, p256dh text NOT NULL, auth text NOT NULL,
 device_label text NOT NULL DEFAULT '', last_test_at timestamptz, updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_push_user_idx ON public.lwb_push_subscriptions(user_id);
ALTER TABLE public.lwb_push_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_push_subscriptions FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.lwb_push_subscriptions TO service_role;

CREATE TABLE IF NOT EXISTS public.lwb_push_jobs (
 notification_id text PRIMARY KEY, state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','sending','sent','failed')),
 attempts integer NOT NULL DEFAULT 0, retry_at timestamptz NOT NULL DEFAULT now(),
 lease_token uuid, leased_until timestamptz, created_at timestamptz NOT NULL DEFAULT now(), last_error text
);
CREATE TABLE IF NOT EXISTS public.lwb_push_deliveries (
 notification_id text NOT NULL REFERENCES public.lwb_push_jobs(notification_id) ON DELETE CASCADE,
 subscription_id uuid NOT NULL REFERENCES public.lwb_push_subscriptions(id) ON DELETE CASCADE,
 state text NOT NULL CHECK(state IN ('sent','gone')), sent_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(notification_id,subscription_id)
);
ALTER TABLE public.lwb_push_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_push_deliveries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_push_jobs, public.lwb_push_deliveries FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.lwb_push_jobs, public.lwb_push_deliveries TO service_role;

CREATE OR REPLACE FUNCTION public.lwb_push_public_config()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT jsonb_build_object('enabled',c.enabled,'public_key',c.vapid_public)
 FROM public.lwb_push_config c WHERE c.id=1 AND EXISTS (
 SELECT 1 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active=true)
$$;
REVOKE ALL ON FUNCTION public.lwb_push_public_config() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.lwb_push_public_config() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_push_subscribe(p_subscription jsonb,p_device text DEFAULT '')
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e text:=p_subscription->>'endpoint'; k text:=p_subscription#>>'{keys,p256dh}'; a text:=p_subscription#>>'{keys,auth}'; v uuid;
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.user_profiles WHERE id=auth.uid() AND active=true) THEN RAISE EXCEPTION 'Active ERP login required'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.lwb_push_config WHERE id=1 AND enabled AND vapid_public IS NOT NULL) THEN RAISE EXCEPTION 'Phone alerts are not ready yet'; END IF;
 IF e IS NULL OR length(e)>4096 OR e !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com)/[^[:space:]#]+$'
    OR k IS NULL OR k !~ '^[A-Za-z0-9_-]{87}$' OR a IS NULL OR a !~ '^[A-Za-z0-9_-]{22}$' THEN RAISE EXCEPTION 'Invalid browser push subscription'; END IF;
 -- A shared phone may switch users, but knowing only an endpoint is not enough to claim it.
 IF EXISTS(SELECT 1 FROM public.lwb_push_subscriptions s WHERE s.endpoint=e AND (s.p256dh<>k OR s.auth<>a)) THEN RAISE EXCEPTION 'Subscription keys changed. Turn alerts off and on again'; END IF;
 INSERT INTO public.lwb_push_subscriptions(user_id,endpoint,p256dh,auth,device_label)
 VALUES(auth.uid(),e,k,a,left(coalesce(p_device,''),240))
 ON CONFLICT(endpoint) DO UPDATE SET user_id=auth.uid(),p256dh=excluded.p256dh,auth=excluded.auth,device_label=excluded.device_label,updated_at=now()
 RETURNING id INTO v;
 RETURN v;
END $$;
REVOKE ALL ON FUNCTION public.lwb_push_subscribe(jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.lwb_push_subscribe(jsonb,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_push_unsubscribe(p_endpoint text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
 DELETE FROM public.lwb_push_subscriptions WHERE user_id=auth.uid() AND endpoint=p_endpoint
$$;
REVOKE ALL ON FUNCTION public.lwb_push_unsubscribe(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.lwb_push_unsubscribe(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_push_notify(p_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c public.lwb_push_config;
BEGIN
 SELECT * INTO c FROM public.lwb_push_config WHERE id=1 AND enabled AND vapid_public IS NOT NULL;
 IF NOT FOUND THEN RETURN; END IF;
 PERFORM net.http_post(url:=c.project_url||'/functions/v1/lwb-web-push',
  headers:=jsonb_build_object('Content-Type','application/json','x-lwb-push-secret',c.webhook_secret),
  body:=jsonb_build_object('action','dispatch','notification_id',p_id),timeout_milliseconds:=10000);
EXCEPTION WHEN OTHERS THEN
 -- Delivery failure must never roll back an order or its bell notification; cron retries the job.
 RETURN;
END $$;
REVOKE ALL ON FUNCTION public.lwb_push_notify(text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.lwb_push_enqueue()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.lwb_push_config WHERE id=1 AND enabled AND vapid_public IS NOT NULL) THEN RETURN NEW; END IF;
 IF coalesce(NEW.is_read,false) OR upper(coalesce(NEW.notification_type,'')) LIKE 'CC\_%' ESCAPE '\' THEN RETURN NEW; END IF;
 INSERT INTO public.lwb_push_jobs(notification_id) VALUES(NEW.id::text) ON CONFLICT DO NOTHING;
 PERFORM public.lwb_push_notify(NEW.id::text);
 RETURN NEW;
EXCEPTION WHEN OTHERS THEN RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.lwb_push_enqueue() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS trg_lwb_phone_push ON public.erp_notifications;
CREATE TRIGGER trg_lwb_phone_push AFTER INSERT ON public.erp_notifications FOR EACH ROW EXECUTE FUNCTION public.lwb_push_enqueue();

CREATE OR REPLACE FUNCTION public.lwb_push_claim(p_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j public.lwb_push_jobs;
BEGIN
 UPDATE public.lwb_push_jobs SET state='sending',attempts=attempts+1,lease_token=gen_random_uuid(),leased_until=now()+interval '2 minutes'
 WHERE notification_id=p_id AND state<>'sent' AND attempts<6 AND retry_at<=now()
 AND (leased_until IS NULL OR leased_until<now()) AND created_at>now()-interval '15 minutes'
 RETURNING * INTO j;
 IF NOT FOUND THEN RETURN NULL; END IF;
 RETURN to_jsonb(j);
END $$;
REVOKE ALL ON FUNCTION public.lwb_push_claim(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_push_claim(text) TO service_role;

CREATE OR REPLACE FUNCTION public.lwb_push_flush()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE j record;
BEGIN
 FOR j IN SELECT notification_id FROM public.lwb_push_jobs
 WHERE state<>'sent' AND attempts<6 AND retry_at<=now() AND (leased_until IS NULL OR leased_until<now())
 AND created_at>now()-interval '15 minutes' ORDER BY created_at LIMIT 30 LOOP
  PERFORM public.lwb_push_notify(j.notification_id);
 END LOOP;
 DELETE FROM public.lwb_push_jobs WHERE created_at<now()-interval '7 days';
END $$;
REVOKE ALL ON FUNCTION public.lwb_push_flush() FROM PUBLIC,anon,authenticated;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobname='lwb-phone-push-retry') THEN
 PERFORM cron.schedule('lwb-phone-push-retry','* * * * *','select public.lwb_push_flush();');
 END IF;
END $$;
COMMIT;
SELECT 'phone_push_tables_ready' AS status;
