-- LUXURY WRIST BRAND ERP — ORDER UPDATES FOR SALESMAN, SALES HEAD AND ADMIN; "MARK DELIVERED" IN THE DAILY REPORT
--
-- Runs by itself when merged to main. Safe to run again. Only erp_notifications rows are added (and old unread
-- salesman order bells from before 17 Nov 2026 are marked read once). No order, stock, bill or money is changed.
--
-- Mohit (17 Nov 2026): the salesman, the Sales Head and Admin must all hear what happens to an order, delivery too.
-- Until now:
--   * lwb_driver_background_tracking_setup.sql (13 Nov) dropped EVERY order bell for a salesman (approved, bill made,
--     delivered, payment received, cancelled), so the salesman heard nothing.
--   * "Order delivered" went only to the salesman, so after that nobody got it, and an Admin / Sales Head
--     "Mark delivered" (the way deliveries are recorded now) sent no delivered bell at all.
--   * Daily Report counted only driver reports, so a day of "Mark delivered" showed 0 deliveries.
-- Now:
--   1. Salesman gets order bells again. Still blocked for him: live GPS / tracking and the vehicle-loading
--      assignment bells (driver / vehicle details), as before.
--   2. PO approved            -> salesman (who took it + the party's field salesman)          ORDER_APPROVED
--   3. Vehicle loaded         -> salesman: "out for delivery"                                    ORDER_DISPATCHED
--   4. Driver report          -> salesman + Sales Head + Admin                                   ORDER_DELIVERED / _PARTIAL / _NOT_DELIVERED
--   5. Admin / Sales Head "Mark delivered" -> salesman + Sales Head + Admin (not the one who marked) ORDER_DELIVERED
--   Bill made, payment received and cancelled bells to the salesman already exist; they now reach him again.
--   6. Daily Report (lwb_daily_summary, _b, _list, _list_b): a "Mark delivered" on that date counts as Delivered,
--      under the PO's driver from its transport assignment. The live functions are patched in place.
-- Needs lwb_admin_mark_load_deliver_setup.sql (table lwb_admin_order_marks).

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Salesman: only live tracking and loading-assignment bells stay blocked
--    (same function is used by the insert trigger and by the read policy on erp_notifications)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_sales_order_alert(p_order uuid, p_type text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $fn$
 SELECT upper(coalesce(p_type,'')) ~ '^(CC_)?(LIVE_|GPS_|TRACK|LOADING_ASSIGNMENT)';
$fn$;

-- Bells made before 13 Nov that were hidden since then: mark read once so the salesman does not get a flood.
UPDATE public.erp_notifications n SET is_read = true
FROM public.user_profiles p
WHERE p.id = n.user_id AND lower(btrim(p.role)) IN ('sales','salesman')
  AND n.is_read = false AND n.created_at < timestamptz '2026-11-17 00:00+05:30'
  AND (n.order_id IS NOT NULL OR upper(coalesce(n.notification_type,'')) ~ '^(CC_)?(ORDER_|PO_|TALLY_|VEHICLE_|LOADING_|DELIVERY_|SALES_RETURN)');

-- ---------------------------------------------------------------------------
-- 2. Who sells this PO: who took it (if a salesman) + the party's field salesman
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_order_salesmen(p_order_id uuid)
RETURNS SETOF uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT DISTINCT p.id
  FROM public.orders o
  JOIN public.user_profiles p ON p.active = true AND lower(btrim(p.role)) IN ('sales','salesman')
  WHERE o.id = p_order_id
    AND (p.id = o.created_by OR p.id IN (
      SELECT a.salesman_id FROM public.lwb_party_salesman a
      JOIN public.lwb_customer_master m ON m.id = a.customer_id
      WHERE upper(btrim(m.customer_name)) = upper(btrim(coalesce(o.customer_name,'')))));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_salesmen(uuid) FROM PUBLIC, anon, authenticated;

-- One bell per person, PO and kind (a PO that goes back for rate approval and is approved again: no second bell).
-- p_who: 'salesman', 'manager', 'admin'. The person doing the step is never told.
CREATE OR REPLACE FUNCTION public.lwb_order_tell(p_order_id uuid, p_who text[], p_title text, p_message text, p_type text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT u.id, p_title, p_message, p_type, p_order_id
  FROM (
    SELECT s AS id FROM public.lwb_order_salesmen(p_order_id) s WHERE 'salesman' = ANY(p_who)
    UNION
    SELECT p.id FROM public.user_profiles p
    WHERE p.active = true
      AND ((lower(btrim(p.role)) = 'manager' AND 'manager' = ANY(p_who))
        OR (lower(btrim(p.role)) = 'admin' AND 'admin' = ANY(p_who)))
  ) u
  WHERE u.id IS DISTINCT FROM auth.uid()
    AND NOT EXISTS (SELECT 1 FROM public.erp_notifications e
                    WHERE e.user_id = u.id AND e.order_id = p_order_id AND e.notification_type = p_type);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_tell(uuid,text[],text,text,text) FROM PUBLIC, anon, authenticated;

-- "LXY-1 · PARTY · 15 CS · Rs 12000.00" (the bell card reads PO no., party and ₹ from this)
CREATE OR REPLACE FUNCTION public.lwb_order_line(o public.orders)
RETURNS text LANGUAGE sql STABLE SET search_path = '' AS $fn$
  SELECT concat_ws(' · ', coalesce(o.order_no,'PO'), nullif(btrim(coalesce(o.customer_name,'')),''),
    CASE WHEN o.total_qty IS NOT NULL THEN to_char(o.total_qty,'FM999999990') || ' CS' END,
    CASE WHEN o.total_amount IS NOT NULL THEN 'Rs ' || to_char(o.total_amount,'FM9999999990.00') END);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_line(public.orders) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. PO approved / vehicle loaded -> salesman
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_flow_sales_order_steps()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE
  v_new text := lower(btrim(coalesce(NEW.status,'')));
  v_old text := CASE WHEN TG_OP = 'UPDATE' THEN lower(btrim(coalesce(OLD.status,''))) ELSE '' END;
  v_ok text[] := ARRAY['approved','approved_next','manager_approved','warehouse_approved'];
  v_by text; v_vehicle text;
BEGIN
  IF v_new = v_old THEN RETURN NULL; END IF;
  BEGIN
    SELECT nullif(btrim(full_name),'') INTO v_by FROM public.user_profiles WHERE id = auth.uid();
    IF v_new = ANY(v_ok) AND NOT (v_old = ANY(v_ok)) THEN
      PERFORM public.lwb_order_tell(NEW.id, ARRAY['salesman'], 'PO Approved',
        public.lwb_order_line(NEW) || coalesce(' · Approved by ' || v_by, '') || '.', 'ORDER_APPROVED');
    ELSIF v_new = 'loaded' AND TG_OP = 'UPDATE' THEN
      SELECT nullif(btrim(a.vehicle_no),'') INTO v_vehicle FROM public.dispatch_assignments a WHERE a.order_id = NEW.id LIMIT 1;
      PERFORM public.lwb_order_tell(NEW.id, ARRAY['salesman'], 'Order Out for Delivery',
        public.lwb_order_line(NEW) || coalesce(' · Vehicle ' || v_vehicle, '') || '. Loaded, on the way to the party.', 'ORDER_DISPATCHED');
    END IF;
  EXCEPTION WHEN others THEN
    RAISE WARNING 'Salesman order bell skipped: %', SQLERRM;  -- a bell never stops the save
  END;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_flow_sales_order_steps() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_flow_sales_order_steps ON public.orders;
CREATE TRIGGER trg_lwb_flow_sales_order_steps AFTER INSERT OR UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.lwb_flow_sales_order_steps();

-- ---------------------------------------------------------------------------
-- 4. Driver delivery report -> salesman + Sales Head + Admin (same trigger name as before, replaced)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_notify_order_delivered()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_o public.orders%ROWTYPE;
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  BEGIN
    PERFORM public.lwb_order_tell(NEW.order_id, ARRAY['salesman','manager','admin'],
      CASE NEW.delivery_status WHEN 'DELIVERED' THEN 'Order Delivered'
        WHEN 'PARTIAL' THEN 'Order Part Delivered' ELSE 'Order Not Delivered' END,
      public.lwb_order_line(v_o) ||
        coalesce(' · Received by ' || nullif(btrim(NEW.received_by),''), '') ||
        coalesce(' · ' || nullif(btrim(NEW.delivery_note),''), '') || '.',
      'ORDER_' || NEW.delivery_status);
  EXCEPTION WHEN others THEN
    RAISE WARNING 'Delivered bell skipped: %', SQLERRM;
  END;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_notify_order_delivered() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_notify_order_delivered ON public.lwb_delivery_reports;
CREATE TRIGGER trg_lwb_notify_order_delivered AFTER INSERT ON public.lwb_delivery_reports
  FOR EACH ROW EXECUTE FUNCTION public.lwb_notify_order_delivered();

-- ---------------------------------------------------------------------------
-- 5. Admin / Sales Head "Mark delivered" -> salesman + Sales Head + Admin
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_notify_order_mark_delivered()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_who text;
BEGIN
  IF NEW.kind <> 'DELIVERED' THEN RETURN NULL; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_who := coalesce(nullif(btrim(NEW.marked_by_name),''),
                    CASE WHEN upper(coalesce(NEW.marked_by_role,'')) = 'MANAGER' THEN 'Sales Head' ELSE 'Admin' END);
  BEGIN
    PERFORM public.lwb_order_tell(NEW.order_id, ARRAY['salesman','manager','admin'], 'Order Delivered',
      public.lwb_order_line(v_o) || ' · Delivered on ' || to_char(NEW.mark_date,'DD/MM/YYYY') ||
        ' · Marked by ' || v_who || coalesce(' · ' || nullif(btrim(NEW.note),''), '') || '.',
      'ORDER_DELIVERED');
  EXCEPTION WHEN others THEN
    RAISE WARNING 'Mark delivered bell skipped: %', SQLERRM;
  END;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_notify_order_mark_delivered() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_notify_order_mark_delivered ON public.lwb_admin_order_marks;
CREATE TRIGGER trg_lwb_notify_order_mark_delivered AFTER INSERT ON public.lwb_admin_order_marks
  FOR EACH ROW EXECUTE FUNCTION public.lwb_notify_order_mark_delivered();

-- Sales Head copy (CC_<type>, lwb_loading_workflow_setup.sql): same as before, but no copy of the salesman's
-- "PO approved" / "out for delivery" bells (the Sales Head approves POs and already gets "Vehicle loaded").
CREATE OR REPLACE FUNCTION public.lwb_notify_sales_head_copy()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_kind text := substring(NEW.notification_type FROM '^[A-Z]+_[A-Z]+');
BEGIN
  IF NEW.order_id IS NULL OR NEW.notification_type IS NULL
     OR NEW.notification_type LIKE 'CC\_%'
     OR NEW.notification_type IN ('TALLY_BILL_PENDING','SALES_PLAN','ANNOUNCEMENT','ORDER_APPROVED','ORDER_DISPATCHED') THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.user_profiles r WHERE r.id = NEW.user_id AND lower(btrim(r.role)) = 'manager') THEN
    RETURN NULL;
  END IF;
  BEGIN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, NEW.title, NEW.message, 'CC_' || NEW.notification_type, NEW.order_id
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(p.role)) = 'manager'
      AND p.id IS DISTINCT FROM auth.uid()
      AND NOT EXISTS (
        SELECT 1 FROM public.erp_notifications n
        WHERE n.user_id = p.id AND n.order_id = NEW.order_id
          AND n.created_at >= NEW.created_at - interval '30 seconds'
          AND (n.notification_type = 'CC_' || NEW.notification_type
               OR (v_kind IS NOT NULL AND regexp_replace(n.notification_type,'^CC_','') LIKE v_kind || '%')));
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Sales Head copy skipped: %', SQLERRM;
  END;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_notify_sales_head_copy() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Daily Report: delivery rows of a day = driver reports + "Mark delivered" of that date
--    Same row shape as lwb_delivery_reports. A marked PO comes as DELIVERED at the mark time (or 12:00 IST of
--    a back date), with no driver login, no money, and the driver / vehicle of its transport assignment.
--    A driver report Delivered / Partial wins over a mark; a "Not delivered" report on the same date as a mark
--    is left out (the PO was delivered that day).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_day_delivery_rows(p_day date)
RETURNS SETOF public.lwb_delivery_reports LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT r.* FROM public.lwb_delivery_reports r
  WHERE timezone('Asia/Kolkata', r.reported_at)::date = p_day
    AND NOT (r.delivery_status = 'NOT_DELIVERED' AND EXISTS (
      SELECT 1 FROM public.lwb_admin_order_marks m
      WHERE m.order_id = r.order_id AND m.kind = 'DELIVERED' AND m.mark_date = p_day))
  UNION ALL
  SELECT (jsonb_populate_record(NULL::public.lwb_delivery_reports, jsonb_build_object(
      'order_id', m.order_id,
      'assignment_id', (SELECT a.id FROM public.dispatch_assignments a WHERE a.order_id = m.order_id LIMIT 1),
      'delivery_status', 'DELIVERED',
      'delivery_note', 'Marked delivered by ' || coalesce(nullif(btrim(m.marked_by_name),''), 'office'),
      'cash_reported', 0,
      'collection_review_status', 'NO_COLLECTION',
      'reported_at', CASE WHEN timezone('Asia/Kolkata', m.marked_at)::date = m.mark_date THEN m.marked_at
                          ELSE (m.mark_date + time '12:00') AT TIME ZONE 'Asia/Kolkata' END))).*
  FROM public.lwb_admin_order_marks m
  WHERE m.kind = 'DELIVERED' AND m.mark_date = p_day
    AND NOT EXISTS (SELECT 1 FROM public.lwb_delivery_reports r
                    WHERE r.order_id = m.order_id AND r.delivery_status IN ('DELIVERED','PARTIAL'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_day_delivery_rows(date) FROM PUBLIC, anon, authenticated;

-- Patch the live Daily Report functions in place: their delivery rows come from lwb_day_delivery_rows(d), and
-- "pending delivery" leaves out POs marked delivered. Everything else in them stays exactly as it is live.
DO $do$
DECLARE
  f text; def text; n int := 0;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.lwb_daily_summary(date)', 'public.lwb_daily_summary_b(date,uuid)',
                           'public.lwb_daily_summary_list(date,text)', 'public.lwb_daily_summary_list_b(date,text,uuid)'] LOOP
    IF to_regprocedure(f) IS NULL THEN
      RAISE NOTICE '% not found: skipped', f; CONTINUE;
    END IF;
    def := pg_get_functiondef(to_regprocedure(f));
    IF position('FROM public.lwb_delivery_reports dr' IN def) = 0 THEN
      RAISE NOTICE '% already patched or changed: skipped', f; CONTINUE;
    END IF;
    def := replace(def, 'FROM public.lwb_delivery_reports dr', 'FROM public.lwb_day_delivery_rows(d) dr');
    def := replace(def, 'AND NOT EXISTS (SELECT 1 FROM public.lwb_delivery_reports x WHERE x.order_id = o.id)',
      'AND NOT EXISTS (SELECT 1 FROM public.lwb_delivery_reports x WHERE x.order_id = o.id)' ||
      ' AND NOT EXISTS (SELECT 1 FROM public.lwb_admin_order_marks mk WHERE mk.order_id = o.id AND mk.kind = ''DELIVERED'')');
    EXECUTE def;
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'Daily Report functions patched: %', n;
END;
$do$;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Check: all ok = true
SELECT 'salesman gets order bells' AS item, NOT public.lwb_sales_order_alert(gen_random_uuid(), 'ORDER_DELIVERED') AS ok
UNION ALL SELECT 'live tracking still blocked for salesman', public.lwb_sales_order_alert(NULL, 'LIVE_GPS')
UNION ALL SELECT 'approved / out for delivery bell', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_flow_sales_order_steps')
UNION ALL SELECT 'mark delivered bell', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_notify_order_mark_delivered')
UNION ALL SELECT 'daily report counts marks',
  coalesce(pg_get_functiondef(to_regprocedure('public.lwb_daily_summary(date)')) LIKE '%lwb_day_delivery_rows%', false);
