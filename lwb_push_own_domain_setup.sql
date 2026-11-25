-- Phone alerts only from https://luxurywristbrand.com (Mohit, 24 Nov 2026).
-- Old phone alerts were still coming with the old address luxury-wrist-brand.pages.dev, because
-- browsers that once enabled alerts on that address kept their own subscription. A browser push
-- subscription belongs to the address it was made on, so it can never move to the new domain.
-- Now:
--  * every subscription remembers its address (origin); the ERP page sends it on each open;
--  * lwb-web-push sends only to subscriptions made on https://luxurywristbrand.com;
--  * phones using luxurywristbrand.com are tagged automatically the next time the ERP opens
--    (no new permission prompt), so nobody has to turn alerts on again;
--  * subscriptions with no / another address that are not refreshed for 3 days are deleted
--    by the every-minute push cron (these are the old pages.dev ones).
-- No orders, stock, payments or bell notifications are changed.
BEGIN;
ALTER TABLE public.lwb_push_subscriptions ADD COLUMN IF NOT EXISTS origin text;
ALTER TABLE public.lwb_push_config ALTER COLUMN site_url SET DEFAULT 'https://luxurywristbrand.com';
UPDATE public.lwb_push_config SET site_url='https://luxurywristbrand.com' WHERE id=1 AND site_url IS DISTINCT FROM 'https://luxurywristbrand.com';

DROP FUNCTION IF EXISTS public.lwb_push_subscribe(jsonb,text);
CREATE OR REPLACE FUNCTION public.lwb_push_subscribe(p_subscription jsonb,p_device text DEFAULT '',p_origin text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e text:=p_subscription->>'endpoint'; k text:=p_subscription#>>'{keys,p256dh}'; a text:=p_subscription#>>'{keys,auth}'; v uuid;
 o text:=CASE WHEN p_origin='https://luxurywristbrand.com' THEN p_origin END;
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.user_profiles WHERE id=auth.uid() AND active=true) THEN RAISE EXCEPTION 'Active ERP login required'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.lwb_push_config WHERE id=1 AND enabled AND vapid_public IS NOT NULL) THEN RAISE EXCEPTION 'Phone alerts are not ready yet'; END IF;
 IF e IS NULL OR length(e)>4096 OR e !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com)/[^[:space:]#]+$'
    OR k IS NULL OR k !~ '^[A-Za-z0-9_-]{87}$' OR a IS NULL OR a !~ '^[A-Za-z0-9_-]{22}$' THEN RAISE EXCEPTION 'Invalid browser push subscription'; END IF;
 -- A shared phone may switch users, but knowing only an endpoint is not enough to claim it.
 IF EXISTS(SELECT 1 FROM public.lwb_push_subscriptions s WHERE s.endpoint=e AND (s.p256dh<>k OR s.auth<>a)) THEN RAISE EXCEPTION 'Subscription keys changed. Turn alerts off and on again'; END IF;
 INSERT INTO public.lwb_push_subscriptions(user_id,endpoint,p256dh,auth,device_label,origin)
 VALUES(auth.uid(),e,k,a,left(coalesce(p_device,''),240),o)
 ON CONFLICT(endpoint) DO UPDATE SET user_id=auth.uid(),p256dh=excluded.p256dh,auth=excluded.auth,device_label=excluded.device_label,
  origin=coalesce(excluded.origin,public.lwb_push_subscriptions.origin),updated_at=now()
 RETURNING id INTO v;
 RETURN v;
END $$;
REVOKE ALL ON FUNCTION public.lwb_push_subscribe(jsonb,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.lwb_push_subscribe(jsonb,text,text) TO authenticated;

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
 -- Old-address (pages.dev) subscriptions are never refreshed by the ERP page: drop them after 3 days.
 DELETE FROM public.lwb_push_subscriptions
 WHERE origin IS DISTINCT FROM 'https://luxurywristbrand.com' AND updated_at<now()-interval '3 days';
END $$;
REVOKE ALL ON FUNCTION public.lwb_push_flush() FROM PUBLIC,anon,authenticated;
COMMIT;
SELECT 'push_own_domain_ready' AS status;
