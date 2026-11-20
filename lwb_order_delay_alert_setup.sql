-- LUXURY WRIST BRAND ERP — DELAYED ORDER ALERT (HIGHLIGHT + BELL, NEVER BLOCK)
--
-- Runs by itself when merged to main. Safe to run again.
-- Mohit (19 Nov 2026): an order past 36 hrs (or not approved in 12 hrs) must still be delivered.
-- It is only highlighted on PO / Sales and Admin + Sales Head get a bell. Nobody is blocked:
-- the Sales Head keeps assigning transport, loading, billing and marking delivered as normal.
--
-- Adds one table (lwb_order_delay_alerts: which order already got which alert, so nobody is
-- sent the same alert twice) and two functions:
--   lwb_order_delay_notify_internal()  finds orders that crossed 12 hrs (still not approved) or
--     36 hrs (still not delivered) and sends ONE bell per order per limit to Admin + Sales Head.
--     More than 3 new ones in one run -> one combined bell instead (no flood after a holiday).
--   lwb_order_delay_notify()           same, for a logged-in Admin / Sales Head / Godown /
--     Accounts (PO / Sales calls it when the page opens, so alerts also go out without pg_cron).
-- pg_cron (when on) runs it every 30 minutes.
-- Nothing is deleted. No order, stock, bill, payment or ledger data is changed.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_order_delay_alerts (
  order_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('APPROVAL','DELIVERY')),
  hours_at_alert integer,
  sent_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (order_id, kind)
);
ALTER TABLE public.lwb_order_delay_alerts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_order_delay_alerts FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_order_delay_notify_internal()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  k text; v_limit int; v_title text; v_type text; v_n int; v_list text; v_more int;
  r record; v_msg text; v_total int := 0; v_bells int := 0; v_cnt int;
  v_out jsonb := '{}'::jsonb;
BEGIN
  -- one run at a time (page + cron at the same moment must not double-send)
  IF NOT pg_try_advisory_xact_lock(hashtext('lwb_order_delay_notify')) THEN
    RETURN jsonb_build_object('busy', true);
  END IF;

  FOREACH k IN ARRAY ARRAY['APPROVAL','DELIVERY'] LOOP
    v_limit := CASE k WHEN 'APPROVAL' THEN 12 ELSE 36 END;
    v_type  := 'ORDER_DELAY_' || k;

    CREATE TEMP TABLE IF NOT EXISTS pg_temp.lwb_delay_new (
      order_id uuid, order_no text, party text, amt numeric, st text, hrs int
    ) ON COMMIT DROP;
    DELETE FROM pg_temp.lwb_delay_new;

    INSERT INTO pg_temp.lwb_delay_new
    SELECT o.id, coalesce(o.order_no,''), coalesce(nullif(btrim(o.customer_name),''),'Party'),
           coalesce(o.total_amount,0), lower(btrim(coalesce(o.status::text,''))),
           floor(extract(epoch FROM now() - coalesce(o.created_at, o.order_date::timestamptz)) / 3600)::int
    FROM public.orders o
    WHERE regexp_replace(lower(btrim(coalesce(o.status::text,''))), '[\s-]+', '_', 'g')
            NOT IN ('cancelled','canceled','delivered','closed','completed')
      AND coalesce(o.created_at, o.order_date::timestamptz) < now() - make_interval(hours => v_limit)
      AND (k = 'DELIVERY' OR public.lwb_order_pending(o.status::text))
      AND NOT EXISTS (SELECT 1 FROM public.lwb_delivery_reports d
                      WHERE d.order_id = o.id AND d.delivery_status IN ('DELIVERED','PARTIAL'))
      AND NOT EXISTS (SELECT 1 FROM public.lwb_admin_order_marks m
                      WHERE m.order_id = o.id AND m.kind = 'DELIVERED')
      AND NOT EXISTS (SELECT 1 FROM public.lwb_order_delay_alerts a
                      WHERE a.order_id = o.id AND a.kind = k);

    SELECT count(*) INTO v_n FROM pg_temp.lwb_delay_new;
    v_out := v_out || jsonb_build_object(lower(k), v_n);
    CONTINUE WHEN v_n = 0;

    INSERT INTO public.lwb_order_delay_alerts (order_id, kind, hours_at_alert)
    SELECT order_id, k, hrs FROM pg_temp.lwb_delay_new
    ON CONFLICT DO NOTHING;
    v_total := v_total + v_n;

    IF v_n <= 3 THEN
      FOR r IN SELECT * FROM pg_temp.lwb_delay_new ORDER BY hrs DESC LOOP
        v_title := CASE k WHEN 'APPROVAL' THEN 'Approval late 12h+ · ' ELSE 'Delivery late 36h+ · ' END || r.order_no;
        v_msg := concat_ws(' · ', r.order_no, r.party, r.hrs || ' hrs since PO',
                   'Rs ' || to_char(r.amt,'FM99999999990.00'))
          || CASE k WHEN 'APPROVAL' THEN '. Not approved yet. Please approve it now.'
                    ELSE '. Not delivered yet. Please deliver it today.' END
          || ' Only highlighted: transport, loading, bill and delivery work as normal.';
        INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
        SELECT p.id, v_title, v_msg, v_type, r.order_id
        FROM public.user_profiles p
        WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager');
        GET DIAGNOSTICS v_cnt = ROW_COUNT;
        v_bells := v_bells + v_cnt;
      END LOOP;
    ELSE
      SELECT string_agg(x.order_no || ' ' || x.party || ' (' || x.hrs || 'h)', ', ')
        INTO v_list
      FROM (SELECT * FROM pg_temp.lwb_delay_new ORDER BY hrs DESC LIMIT 6) x;
      v_more := v_n - least(v_n, 6);
      v_title := v_n || CASE k WHEN 'APPROVAL' THEN ' POs approval late 12h+' ELSE ' POs delivery late 36h+' END;
      v_msg := v_list || CASE WHEN v_more > 0 THEN ' + ' || v_more || ' more' ELSE '' END
        || '. Only highlighted: transport, loading, bill and delivery work as normal.';
      INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
      SELECT p.id, v_title, left(v_msg, 900), v_type
      FROM public.user_profiles p
      WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager');
      GET DIAGNOSTICS v_cnt = ROW_COUNT;
      v_bells := v_bells + v_cnt;
    END IF;
  END LOOP;

  RETURN v_out || jsonb_build_object('new', v_total, 'bells', v_bells);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_delay_notify_internal() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_order_delay_notify()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p
                 WHERE p.id = auth.uid() AND p.active = true
                   AND lower(btrim(p.role)) IN ('admin','manager','warehouse','accounts')) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;
  RETURN public.lwb_order_delay_notify_internal();
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_delay_notify() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_delay_notify() TO authenticated;

COMMIT;

-- Every 30 minutes, only where pg_cron is on.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'lwb_order_delay_alert';
    PERFORM cron.schedule('lwb_order_delay_alert', '*/30 * * * *', 'SELECT public.lwb_order_delay_notify_internal()');
  END IF;
END
$cron$;

NOTIFY pgrst, 'reload schema';

SELECT 'delay alert table' AS item, (to_regclass('public.lwb_order_delay_alerts') IS NOT NULL)::text AS ok
UNION ALL SELECT 'delay alert job', coalesce((SELECT 'every 30 min' FROM pg_extension WHERE extname = 'pg_cron'), 'pg_cron off: sent when PO / Sales opens');
