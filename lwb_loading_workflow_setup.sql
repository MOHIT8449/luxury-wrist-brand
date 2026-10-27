-- LUXURY WRIST BRAND ERP — LOADING WORKFLOW: GODOWN MANAGER, VEHICLE LOADED, TALLY INVOICE NO.
--
-- RUN ONCE in Supabase SQL Editor (after lwb_driver_payment_setup.sql). Safe to run again.
-- Mohit asked (27 Oct 2026):
--   1. Sales Head assigns the driver / vehicle AND one Godown Manager (WAREHOUSE login) who loads it.
--      Both are notified. Only that Godown Manager (or Sales Head / Admin) can start / confirm the loading.
--   2. Godown Manager taps "Confirm Vehicle Loaded" → Accounts (make the Tally bill), Sales Head and Admin are notified.
--   3. Accounts enters the Tally invoice number(s) of the PO. Only Accounts and Admin can see them.
--      Sales Head / Admin get "Tally bill made" (without the number).
--   4. Driver sees an order only until 12 hours after he reports the delivery (no history).
--   5. Returned goods are approved by the Godown Manager (or Sales Head / Admin); Accounts only views them.
--      Driver payments (cash / UPI) are verified by Accounts (or Admin); Sales Head only views them.
--   6. Sales Head gets a copy of every order notification (loading, delivery, return, payment).
-- No stock, ledger, Cashbook or Tally data is changed.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Godown Manager on the dispatch assignment
-- ---------------------------------------------------------------------------
ALTER TABLE public.dispatch_assignments
  ADD COLUMN IF NOT EXISTS loading_manager_id uuid REFERENCES auth.users(id) ON DELETE SET NULL;

-- Active WAREHOUSE (Godown Manager) logins for the Sales Head dropdown.
CREATE OR REPLACE FUNCTION public.lwb_godown_managers()
RETURNS TABLE(user_id uuid, full_name text, mobile text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','warehouse','transport')) THEN
    RAISE EXCEPTION 'Only active Admin, Sales Head or Godown staff can view Godown Managers';
  END IF;
  RETURN QUERY
    SELECT p.id, coalesce(nullif(btrim(p.full_name),''),'Godown Manager'), p.mobile
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(p.role)) = 'warehouse'
    ORDER BY 2;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_godown_managers() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_godown_managers() TO authenticated;

-- Assignment notification: the chosen Godown Manager (or all godown staff when none is chosen),
-- Sales Head, and the driver. Dispatch rows go first so the Sales Head copy below is not doubled.
CREATE OR REPLACE FUNCTION public.lwb_notify_loading_assignment()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_order public.orders%ROWTYPE;
  v_info text;
  v_new boolean := TG_OP = 'INSERT';
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.driver_mobile IS NOT DISTINCT FROM OLD.driver_mobile
     AND NEW.driver_name IS NOT DISTINCT FROM OLD.driver_name
     AND NEW.vehicle_no IS NOT DISTINCT FROM OLD.vehicle_no
     AND NEW.loading_manager_id IS NOT DISTINCT FROM OLD.loading_manager_id THEN
    RETURN NEW;
  END IF;
  IF coalesce(btrim(NEW.driver_name),'') = '' AND coalesce(btrim(NEW.vehicle_no),'') = '' THEN
    RETURN NEW;
  END IF;

  SELECT o.* INTO v_order FROM public.orders o WHERE o.id = NEW.order_id;

  v_info := coalesce(v_order.order_no,'Order') ||
    CASE WHEN v_order.customer_name IS NOT NULL THEN ' · ' || v_order.customer_name ELSE '' END ||
    ' · Vehicle ' || coalesce(nullif(btrim(NEW.vehicle_no),''),'-') ||
    ' · Driver ' || coalesce(nullif(btrim(NEW.driver_name),''),'-') ||
    CASE WHEN coalesce(btrim(NEW.driver_mobile),'') <> '' THEN ' (' || btrim(NEW.driver_mobile) || ')' ELSE '' END ||
    CASE WHEN coalesce(btrim(NEW.loading_person),'') <> '' THEN ' · Loading: ' || btrim(NEW.loading_person) ELSE '' END ||
    CASE WHEN v_order.total_weight IS NOT NULL THEN ' · ' || to_char(v_order.total_weight,'FM999999990.0') || ' KG' ELSE '' END;

  -- Godown Manager who has to load it
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id,
    CASE WHEN v_new OR NEW.loading_manager_id IS DISTINCT FROM OLD.loading_manager_id
         THEN 'Load This Vehicle' ELSE 'Loading Vehicle / Driver Changed' END,
    v_info || '. You are assigned to load this vehicle. Open Loading & Dispatch and tap Confirm Vehicle Loaded when done.',
    'LOADING_ASSIGNMENT_DISPATCH', NEW.order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) = 'warehouse'
    AND (NEW.loading_manager_id IS NULL OR p.id = NEW.loading_manager_id)
    AND p.id IS DISTINCT FROM auth.uid();

  -- Godown Manager taken off this vehicle
  IF TG_OP = 'UPDATE' AND OLD.loading_manager_id IS NOT NULL
     AND NEW.loading_manager_id IS DISTINCT FROM OLD.loading_manager_id THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, 'Loading Moved to Another Godown Manager', v_info || '. You do not need to load it.',
      'LOADING_ASSIGNMENT_DISPATCH', NEW.order_id
    FROM public.user_profiles p
    WHERE p.id = OLD.loading_manager_id AND p.active = true AND p.id IS DISTINCT FROM auth.uid();
  END IF;

  -- Sales Head
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id,
    CASE WHEN v_new THEN 'Vehicle Assigned for Loading' ELSE 'Loading Vehicle / Driver Changed' END,
    v_info || '.', 'LOADING_ASSIGNMENT_DISPATCH', NEW.order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) = 'manager' AND p.id IS DISTINCT FROM auth.uid();

  -- Driver: matched by mobile number only, never by name
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id,
    CASE WHEN v_new THEN 'New Loading Assignment' ELSE 'Loading Assignment Updated' END,
    v_info || '. Open the Driver app to view the order.',
    'LOADING_ASSIGNMENT_DRIVER', NEW.order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) = 'driver'
    AND public.lwb_driver_phone_matches(p.mobile, NEW.driver_mobile)
    AND p.id IS DISTINCT FROM auth.uid();

  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_notify_loading_assignment() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_lwb_notify_loading_assignment ON public.dispatch_assignments;
CREATE TRIGGER trg_lwb_notify_loading_assignment
AFTER INSERT OR UPDATE OF driver_mobile, driver_name, vehicle_no, loading_manager_id
ON public.dispatch_assignments
FOR EACH ROW EXECUTE FUNCTION public.lwb_notify_loading_assignment();

-- Only the assigned Godown Manager can start / confirm loading (Sales Head and Admin can always).
CREATE OR REPLACE FUNCTION public.lwb_orders_loading_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_role text; v_mgr uuid; v_name text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status OR NEW.status NOT IN ('loading','loaded') OR auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = auth.uid();
  IF v_role IS DISTINCT FROM 'warehouse' THEN RETURN NEW; END IF;
  SELECT a.loading_manager_id INTO v_mgr FROM public.dispatch_assignments a WHERE a.order_id = NEW.id LIMIT 1;
  IF v_mgr IS NOT NULL AND v_mgr <> auth.uid() THEN
    SELECT full_name INTO v_name FROM public.user_profiles WHERE id = v_mgr;
    RAISE EXCEPTION 'This vehicle is assigned to % for loading. Ask the Sales Head to change it.', coalesce(v_name,'another Godown Manager');
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_orders_loading_guard() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_orders_loading_guard ON public.orders;
CREATE TRIGGER trg_lwb_orders_loading_guard
BEFORE UPDATE OF status ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.lwb_orders_loading_guard();

-- ---------------------------------------------------------------------------
-- 2. Vehicle Loaded → Accounts (make Tally bill), Sales Head, Admin
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_notify_vehicle_loaded()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_vehicle text; v_cases numeric; v_value numeric; v_by text; v_info text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status OR NEW.status <> 'loaded' THEN RETURN NEW; END IF;
  SELECT a.vehicle_no INTO v_vehicle FROM public.dispatch_assignments a WHERE a.order_id = NEW.id LIMIT 1;
  SELECT coalesce(sum(i.loaded_qty),0), coalesce(sum(round(coalesce(i.loaded_qty,0)::numeric * coalesce(i.rate,0)::numeric,2)),0)
    INTO v_cases, v_value FROM public.order_items i WHERE i.order_id = NEW.id;
  SELECT full_name INTO v_by FROM public.user_profiles WHERE id = auth.uid();
  v_info := coalesce(NEW.order_no,'Order') || ' · ' || coalesce(NEW.customer_name,'') ||
    ' · Vehicle ' || coalesce(nullif(btrim(v_vehicle),''),'-') ||
    ' · ' || to_char(v_cases,'FM9999990') || ' CS · Rs ' || to_char(v_value,'FM9999999990.00') ||
    coalesce(' · Loaded by ' || v_by, '');

  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, 'Vehicle Loaded — Make Tally Bill',
    v_info || '. Make the bill in Tally, then enter the invoice number on Tally Bill & Invoice No.',
    'TALLY_BILL_PENDING', NEW.id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) = 'accounts' AND p.id IS DISTINCT FROM auth.uid();

  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, 'Vehicle Loaded', v_info || '. Sent to Accounts for the Tally bill.', 'VEHICLE_LOADED', NEW.id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('manager','admin') AND p.id IS DISTINCT FROM auth.uid();
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_notify_vehicle_loaded() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_notify_vehicle_loaded ON public.orders;
CREATE TRIGGER trg_lwb_notify_vehicle_loaded
AFTER UPDATE OF status ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.lwb_notify_vehicle_loaded();

-- ---------------------------------------------------------------------------
-- 3. Tally invoice number(s) per PO — Accounts and Admin only
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_tally_invoices (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  invoice_no text NOT NULL CHECK (length(btrim(invoice_no)) BETWEEN 1 AND 200),
  invoice_date date NOT NULL,
  note text CHECK (note IS NULL OR length(note) <= 300),
  entered_by uuid NOT NULL REFERENCES auth.users(id),
  entered_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users(id),
  updated_at timestamptz
);
ALTER TABLE public.lwb_tally_invoices ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_tally_invoices FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_tally_invoices TO authenticated;
DROP POLICY IF EXISTS lwb_tally_invoices_read ON public.lwb_tally_invoices;
CREATE POLICY lwb_tally_invoices_read ON public.lwb_tally_invoices FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin')));

CREATE OR REPLACE FUNCTION public.lwb_save_tally_invoice(p_order_id uuid, p_invoice_no text, p_invoice_date date, p_note text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_no text := regexp_replace(btrim(coalesce(p_invoice_no,'')), '\s*,\s*', ', ', 'g');
  v_note text := nullif(btrim(coalesce(p_note,'')),'');
  v_order public.orders%ROWTYPE;
  v_old public.lwb_tally_invoices%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin')) THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can enter the Tally invoice number';
  END IF;
  IF v_no = '' THEN RAISE EXCEPTION 'Enter the Tally invoice number'; END IF;
  IF length(v_no) > 200 THEN RAISE EXCEPTION 'Invoice number is too long'; END IF;
  IF p_invoice_date IS NULL OR p_invoice_date > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1 THEN
    RAISE EXCEPTION 'Enter a valid invoice date';
  END IF;
  IF length(coalesce(v_note,'')) > 300 THEN RAISE EXCEPTION 'Note is too long'; END IF;
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF lower(btrim(coalesce(v_order.status,''))) NOT IN ('loaded','invoiced','dispatched','delivered') THEN
    RAISE EXCEPTION 'The vehicle is not loaded yet for %', v_order.order_no;
  END IF;

  SELECT * INTO v_old FROM public.lwb_tally_invoices WHERE order_id = p_order_id FOR UPDATE;
  IF FOUND THEN
    UPDATE public.lwb_tally_invoices
    SET invoice_no = v_no, invoice_date = p_invoice_date, note = v_note, updated_by = auth.uid(), updated_at = now()
    WHERE order_id = p_order_id;
    RETURN 'UPDATED';
  END IF;

  INSERT INTO public.lwb_tally_invoices (order_id, invoice_no, invoice_date, note, entered_by)
  VALUES (p_order_id, v_no, p_invoice_date, v_note, auth.uid());

  UPDATE public.erp_notifications SET is_read = true
  WHERE order_id = p_order_id AND notification_type = 'TALLY_BILL_PENDING' AND is_read = false;

  -- Sales Head / Admin: bill made (the number stays with Accounts)
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, 'Tally Bill Made',
    coalesce(v_order.order_no,'Order') || ' · ' || coalesce(v_order.customer_name,'') || ': Accounts made the Tally bill.',
    'TALLY_BILL_DONE', p_order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('manager','admin') AND p.id IS DISTINCT FROM auth.uid();
  RETURN 'SAVED';
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_save_tally_invoice(uuid,text,date,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_save_tally_invoice(uuid,text,date,text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Driver: only current orders, delivered ones until 12 hours after the report
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_driver_my_delivery_orders()
RETURNS SETOF jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_role text;
BEGIN
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
  RETURN QUERY
    SELECT x FROM public.lwb_driver_list_delivery_orders() x
    WHERE v_role IS DISTINCT FROM 'driver'
       OR x->'report' IS NULL OR jsonb_typeof(x->'report') = 'null'
       OR (x->'report'->>'reported_at')::timestamptz > now() - interval '12 hours';
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_driver_my_delivery_orders() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_driver_my_delivery_orders() TO authenticated;
-- The old list (full history) is now only reachable through the function above.
REVOKE EXECUTE ON FUNCTION public.lwb_driver_list_delivery_orders() FROM PUBLIC, anon, authenticated;

-- Driver cannot read his old delivery reports directly either.
DROP POLICY IF EXISTS lwb_delivery_report_driver_12h ON public.lwb_delivery_reports;
CREATE POLICY lwb_delivery_report_driver_12h ON public.lwb_delivery_reports AS RESTRICTIVE
  FOR SELECT TO authenticated
  USING (reported_at > now() - interval '12 hours' OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND lower(btrim(p.role)) = 'driver'));

-- ---------------------------------------------------------------------------
-- 5a. Driver return: approved by Godown Manager / Sales Head / Admin (Accounts views only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_review_driver_return(
  p_return_id uuid,
  p_action text,
  p_note text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_return public.lwb_driver_delivery_returns%ROWTYPE;
  v_action text := upper(btrim(COALESCE(p_action,'')));
  v_note text := NULLIF(btrim(COALESCE(p_note,'')),'');
  v_status text;
  v_order_no text;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager','warehouse')
  ) THEN
    RAISE EXCEPTION 'Only active Godown Manager, Sales Head or Admin can approve or reject a driver return';
  END IF;
  IF v_action NOT IN ('APPROVE','REJECT') THEN RAISE EXCEPTION 'Action must be APPROVE or REJECT'; END IF;
  IF v_action = 'REJECT' AND length(COALESCE(v_note,'')) < 3 THEN RAISE EXCEPTION 'Rejection reason is required'; END IF;
  IF length(COALESCE(v_note,'')) > 500 THEN RAISE EXCEPTION 'Note is too long'; END IF;

  SELECT * INTO v_return FROM public.lwb_driver_delivery_returns WHERE id = p_return_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Driver return not found'; END IF;
  IF v_return.status <> 'PENDING_OFFICE' THEN
    RAISE EXCEPTION 'This return was already reviewed (%)', v_return.status;
  END IF;

  v_status := CASE WHEN v_action = 'APPROVE' THEN 'APPROVED' ELSE 'REJECTED' END;
  UPDATE public.lwb_driver_delivery_returns
  SET status = v_status, reviewed_by = auth.uid(), reviewed_at = now(), review_note = v_note
  WHERE id = p_return_id;

  SELECT o.order_no INTO v_order_no FROM public.orders o WHERE o.id = v_return.order_id;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  VALUES (v_return.driver_user_id, 'Delivery Return ' || initcap(v_status),
    'Office ' || lower(v_status) || ' your return on ' || COALESCE(v_order_no,'order') || ' (Rs ' ||
      to_char(v_return.total_return_amount,'FM9999999990.00') || ')' || COALESCE('. Note: ' || v_note, ''),
    'DELIVERY_RETURN_' || v_status, v_return.order_id);
  RETURN v_status;
END;
$function$;
REVOKE ALL ON FUNCTION public.lwb_review_driver_return(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_review_driver_return(uuid,text,text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5b. Driver payment: verified by Accounts / Admin (Sales Head views only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_review_driver_collection(p_report_id uuid, p_action text, p_note text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_rep public.lwb_delivery_reports%ROWTYPE;
  v_action text := upper(btrim(COALESCE(p_action,'')));
  v_note text := NULLIF(btrim(COALESCE(p_note,'')),'');
  v_status text;
  v_order_no text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','accounts')) THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can verify a driver payment';
  END IF;
  IF v_action NOT IN ('VERIFY','REJECT') THEN RAISE EXCEPTION 'Action must be VERIFY or REJECT'; END IF;
  IF v_action = 'REJECT' AND length(COALESCE(v_note,'')) < 3 THEN RAISE EXCEPTION 'Rejection reason is required'; END IF;
  IF length(COALESCE(v_note,'')) > 500 THEN RAISE EXCEPTION 'Note is too long'; END IF;

  SELECT * INTO v_rep FROM public.lwb_delivery_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Delivery report not found'; END IF;
  IF COALESCE(v_rep.payment_status, CASE WHEN v_rep.cash_reported > 0 THEN 'PENDING' END) IS DISTINCT FROM 'PENDING' THEN
    RAISE EXCEPTION 'This payment is not waiting for verification';
  END IF;
  v_status := CASE WHEN v_action = 'VERIFY' THEN 'VERIFIED' ELSE 'REJECTED' END;

  UPDATE public.lwb_delivery_reports
  SET payment_status = v_status, payment_reviewed_by = auth.uid(), payment_reviewed_at = now(), payment_review_note = v_note
  WHERE id = p_report_id;

  UPDATE public.erp_notifications SET is_read = true
  WHERE order_id = v_rep.order_id AND notification_type = 'DELIVERY_COLLECTION' AND is_read = false;

  SELECT o.order_no INTO v_order_no FROM public.orders o WHERE o.id = v_rep.order_id;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  VALUES (v_rep.driver_user_id, 'Payment ' || initcap(v_status),
    'Office ' || lower(v_status) || ' your payment on ' || COALESCE(v_order_no,'order') ||
      ' (Rs ' || to_char(v_rep.cash_reported,'FM9999999990.00') || ')' ||
      CASE WHEN v_status = 'REJECTED' THEN '. Correct it in Driver Delivery' ELSE '' END ||
      COALESCE('. Note: ' || v_note, ''),
    'DELIVERY_COLLECTION_' || v_status, v_rep.order_id);
  RETURN v_status;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_review_driver_collection(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_review_driver_collection(uuid,text,text) TO authenticated;

-- Accounts no longer approve returns, so they do not get the "return waiting" alert
-- (they still get "Return amount cut" once it is approved).
CREATE OR REPLACE FUNCTION public.lwb_notification_route_filter()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
BEGIN
  IF NEW.notification_type = 'DELIVERY_RETURN_PENDING' AND EXISTS (
     SELECT 1 FROM public.user_profiles p WHERE p.id = NEW.user_id AND lower(btrim(p.role)) = 'accounts') THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_notification_route_filter() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_notification_route_filter ON public.erp_notifications;
CREATE TRIGGER trg_lwb_notification_route_filter
BEFORE INSERT ON public.erp_notifications
FOR EACH ROW EXECUTE FUNCTION public.lwb_notification_route_filter();

-- ---------------------------------------------------------------------------
-- 6. Sales Head copy of every order notification
--    Runs at the end of the transaction, so when the Sales Head already got a notification of the
--    same kind for the order (e.g. LOADING_ASSIGNMENT_*), no copy is added. Copies are typed
--    CC_<type>: they open the same page but never pop up. Never blocks the original save.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_notify_sales_head_copy()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_kind text := substring(NEW.notification_type FROM '^[A-Z]+_[A-Z]+');
BEGIN
  IF NEW.order_id IS NULL OR NEW.notification_type IS NULL
     OR NEW.notification_type LIKE 'CC\_%'
     OR NEW.notification_type IN ('TALLY_BILL_PENDING','SALES_PLAN','ANNOUNCEMENT') THEN
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
DROP TRIGGER IF EXISTS trg_lwb_notify_sales_head_copy ON public.erp_notifications;
CREATE CONSTRAINT TRIGGER trg_lwb_notify_sales_head_copy
AFTER INSERT ON public.erp_notifications
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.lwb_notify_sales_head_copy();

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Check: 6 rows, all true
SELECT 'loading_manager_column' AS item, EXISTS (SELECT 1 FROM information_schema.columns
  WHERE table_schema='public' AND table_name='dispatch_assignments' AND column_name='loading_manager_id') AS ok
UNION ALL SELECT 'tally_invoices_table', to_regclass('public.lwb_tally_invoices') IS NOT NULL
UNION ALL SELECT 'driver_12h_list', to_regprocedure('public.lwb_driver_my_delivery_orders()') IS NOT NULL
UNION ALL SELECT 'vehicle_loaded_trigger', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_lwb_notify_vehicle_loaded')
UNION ALL SELECT 'sales_head_copy_trigger', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='trg_lwb_notify_sales_head_copy')
UNION ALL SELECT 'godown_managers', (SELECT count(*) FROM public.user_profiles WHERE active AND lower(btrim(role))='warehouse') > 0;
