-- LUXURY WRIST BRAND ERP — ORDER FLOW POPUPS + VERIFY QUICK ACTIONS
--
-- RUN ONCE in Supabase SQL Editor (after lwb_loading_workflow_setup.sql and
-- lwb_tally_bill_flow_setup.sql). Safe to run again.
-- Mohit asked (28 Oct 2026): every step of an order pops up for the right people.
--   1. Salesman saves an order          → Sales Head + Admin
--   2. Driver / vehicle assigned        → Godown Manager + Driver        (already: lwb_loading_workflow_setup.sql)
--   3. Vehicle loaded                   → Accounts                       (already: lwb_loading_workflow_setup.sql)
--   4. Tally bill made                  → Driver, Salesman, Godown Manager (Sales Head / Admin already)
--   5. Driver collects money            → Salesman, Godown Manager (Accounts / Sales Head already)
--   6. Driver takes a return            → Accounts, Salesman (Godown / Sales Head already)
--   7. Sales return / credit / debit note → Accounts
--   8. Accounts verify the money        → Sales Head, Salesman
--   9. lwb_my_verify_queue(): what this login has to verify / do now (Dashboard Quick Actions).
--  10. 🔔 arrives instantly (Supabase Realtime) instead of waiting for the next 30-second check.
-- Only erp_notifications rows are added. No order, stock, bill, payment, ledger or Tally data is changed.
-- Tally invoice / note numbers are never put in these messages (only Accounts and Admin see them).

BEGIN;

-- ---------------------------------------------------------------------------
-- Who gets it. p_who: admin, manager, accounts, godown (the order's Godown Manager,
-- or all godown staff when none was chosen), driver (by the order's driver mobile),
-- salesman (who took the order). The person doing the step is never notified.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_flow_send(p_order_id uuid, p_who text[], p_title text, p_message text,
                                                p_type text, p_replace boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_mgr uuid; v_mobile text; v_salesman uuid;
BEGIN
  SELECT a.loading_manager_id, a.driver_mobile INTO v_mgr, v_mobile
  FROM public.dispatch_assignments a WHERE a.order_id = p_order_id LIMIT 1;
  SELECT o.created_by INTO v_salesman FROM public.orders o WHERE o.id = p_order_id;

  -- A newer note of the same step replaces the unread older one (e.g. payment edited).
  IF p_replace THEN
    DELETE FROM public.erp_notifications n
    WHERE n.order_id = p_order_id AND n.notification_type = p_type AND n.is_read = false;
  END IF;

  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT DISTINCT p.id, p_title, p_message, p_type, p_order_id
  FROM public.user_profiles p
  WHERE p.active = true AND p.id IS DISTINCT FROM auth.uid()
    AND (   (lower(btrim(p.role)) = 'admin' AND 'admin' = ANY(p_who))
         OR (lower(btrim(p.role)) = 'manager' AND 'manager' = ANY(p_who))
         OR (lower(btrim(p.role)) = 'accounts' AND 'accounts' = ANY(p_who))
         OR (lower(btrim(p.role)) = 'warehouse' AND 'godown' = ANY(p_who)
             AND (v_mgr IS NULL OR p.id = v_mgr OR NOT EXISTS (
               SELECT 1 FROM public.user_profiles m WHERE m.id = v_mgr AND m.active = true)))
         OR (lower(btrim(p.role)) = 'driver' AND 'driver' = ANY(p_who)
             AND coalesce(btrim(v_mobile),'') <> '' AND public.lwb_driver_phone_matches(p.mobile, v_mobile))
         OR (lower(btrim(p.role)) IN ('sales','salesman') AND 'salesman' = ANY(p_who) AND p.id = v_salesman));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_flow_send(uuid,text[],text,text,text,boolean) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. New order → Sales Head + Admin
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_flow_order_new()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_by text;
BEGIN
  IF NOT public.lwb_order_pending(NEW.status) THEN RETURN NEW; END IF;
  SELECT full_name INTO v_by FROM public.user_profiles WHERE id = coalesce(NEW.created_by, auth.uid());
  PERFORM public.lwb_flow_send(NEW.id, ARRAY['manager','admin'], 'New Order — Approve',
    concat_ws(' · ', NEW.order_no, NEW.customer_name,
      CASE WHEN NEW.total_qty IS NOT NULL THEN to_char(NEW.total_qty,'FM999999990') || ' CS' END,
      CASE WHEN NEW.total_amount IS NOT NULL THEN 'Rs ' || to_char(NEW.total_amount,'FM9999999990.00') END,
      CASE WHEN NEW.total_weight IS NOT NULL THEN to_char(NEW.total_weight,'FM999999990.0') || ' KG' END,
      'By ' || coalesce(v_by, NEW.sales_person, 'Salesman'))
      || '. Open PO Approval & Driver to approve it.',
    'ORDER_NEW');
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_flow_order_new() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_flow_order_new ON public.orders;
CREATE TRIGGER trg_lwb_flow_order_new
AFTER INSERT ON public.orders
FOR EACH ROW EXECUTE FUNCTION public.lwb_flow_order_new();

-- ---------------------------------------------------------------------------
-- 4. Tally bill made → Driver, Salesman, Godown Manager (no invoice number)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_flow_bill_made()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_vehicle text;
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  SELECT a.vehicle_no INTO v_vehicle FROM public.dispatch_assignments a WHERE a.order_id = NEW.order_id LIMIT 1;
  PERFORM public.lwb_flow_send(NEW.order_id, ARRAY['driver','salesman','godown'], 'Bill Made',
    concat_ws(' · ', v_o.order_no, v_o.customer_name, 'Vehicle ' || nullif(btrim(v_vehicle),''))
      || ': Accounts made the bill. The vehicle can leave with the bill.',
    'TALLY_BILL_DONE');
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_flow_bill_made() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_flow_bill_made ON public.lwb_tally_invoices;
CREATE TRIGGER trg_lwb_flow_bill_made
AFTER INSERT ON public.lwb_tally_invoices
FOR EACH ROW EXECUTE FUNCTION public.lwb_flow_bill_made();

-- ---------------------------------------------------------------------------
-- 5. Driver collected money → Salesman, Godown Manager   (DELIVERY_COLLECTION_INFO)
-- 8. Accounts verified it    → Sales Head, Salesman       (DELIVERY_COLLECTION_RECEIVED)
--    Named DELIVERY_COLLECTION_* so the Sales Head copy is not doubled.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_flow_driver_money()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_driver text; v_amt text;
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  SELECT full_name INTO v_driver FROM public.user_profiles WHERE id = NEW.driver_user_id;
  v_amt := 'Rs ' || to_char(coalesce(NEW.cash_reported,0),'FM9999999990.00');

  IF NEW.payment_saved_at IS NOT NULL AND coalesce(NEW.cash_reported,0) > 0
     AND (TG_OP = 'INSERT' OR NEW.payment_saved_at IS DISTINCT FROM OLD.payment_saved_at) THEN
    PERFORM public.lwb_flow_send(NEW.order_id, ARRAY['salesman','godown'], 'Driver Collected Payment',
      concat_ws(' · ', v_o.order_no, v_o.customer_name, coalesce(v_driver,'Driver') || ' collected ' || v_amt,
        nullif(NEW.payment_mode,'')) || '. Accounts will verify it when the vehicle is back.',
      'DELIVERY_COLLECTION_INFO', true);
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.payment_status = 'VERIFIED' AND OLD.payment_status IS DISTINCT FROM 'VERIFIED' THEN
    PERFORM public.lwb_flow_send(NEW.order_id, ARRAY['manager','salesman'], 'Payment Received',
      concat_ws(' · ', v_o.order_no, v_o.customer_name, v_amt || ' received and verified by Accounts') || '.',
      'DELIVERY_COLLECTION_RECEIVED', true);
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_flow_driver_money() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_flow_driver_money ON public.lwb_delivery_reports;
CREATE TRIGGER trg_lwb_flow_driver_money
AFTER INSERT OR UPDATE OF payment_saved_at, payment_status ON public.lwb_delivery_reports
FOR EACH ROW EXECUTE FUNCTION public.lwb_flow_driver_money();

-- ---------------------------------------------------------------------------
-- 6. Driver took a return → Accounts (for the credit note) + Salesman.
--    Godown Manager / Sales Head get DELIVERY_RETURN_OPERATIONS from
--    lwb_delivery_return_manager_notifications.sql; if that is not set up, they get this one.
--    The return RPC saves the total at the end, so this fires on that update.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_flow_driver_return()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_who text[] := ARRAY['accounts','salesman'];
BEGIN
  IF NEW.status <> 'PENDING_OFFICE' OR coalesce(NEW.total_return_amount,0) <= 0
     OR NEW.total_return_amount IS NOT DISTINCT FROM OLD.total_return_amount THEN
    RETURN NEW;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_trigger WHERE tgname = 'trg_lwb_notify_return_operations') THEN
    v_who := v_who || ARRAY['godown','manager'];
  END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  PERFORM public.lwb_flow_send(NEW.order_id, v_who, 'Driver Took a Return',
    concat_ws(' · ', v_o.order_no, v_o.customer_name, 'Return Rs ' || to_char(NEW.total_return_amount,'FM9999999990.00'))
      || '. Godown Manager checks it on Driver Returns; once approved, make the credit note.',
    'DELIVERY_RETURN_INFO', true);
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_flow_driver_return() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_flow_driver_return ON public.lwb_driver_delivery_returns;
CREATE TRIGGER trg_lwb_flow_driver_return
AFTER UPDATE OF total_return_amount ON public.lwb_driver_delivery_returns
FOR EACH ROW EXECUTE FUNCTION public.lwb_flow_driver_return();

-- ---------------------------------------------------------------------------
-- 7. Credit / debit note entered → other Accounts logins + Admin (no note number)
--    Sales return entered          → Accounts + Admin
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_flow_tally_note()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_by text;
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  SELECT full_name INTO v_by FROM public.user_profiles WHERE id = NEW.created_by;
  PERFORM public.lwb_flow_send(NEW.order_id, ARRAY['accounts','admin'],
    initcap(NEW.kind) || ' Note Entered',
    concat_ws(' · ', v_o.order_no, v_o.customer_name, initcap(NEW.kind) || ' note Rs ' || to_char(NEW.amount,'FM9999999990.00'),
      nullif(btrim(NEW.reason),''), 'By ' || v_by) || '. Party ledger uses it.',
    'TALLY_NOTE_' || NEW.kind);
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_flow_tally_note() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_flow_tally_note ON public.lwb_tally_notes;
CREATE TRIGGER trg_lwb_flow_tally_note
AFTER INSERT ON public.lwb_tally_notes
FOR EACH ROW EXECUTE FUNCTION public.lwb_flow_tally_note();

CREATE OR REPLACE FUNCTION public.lwb_flow_sales_return()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE;
BEGIN
  IF NEW.order_id IS NULL THEN RETURN NEW; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  PERFORM public.lwb_flow_send(NEW.order_id, ARRAY['accounts','admin'], 'Sales Return Entered',
    concat_ws(' · ', v_o.order_no, v_o.customer_name, NEW.return_no,
      'Rs ' || to_char(coalesce(NEW.total_amount,0),'FM9999999990.00'), nullif(btrim(NEW.reason),''))
      || '. Make the credit note in Tally once it is approved.',
    'SALES_RETURN_NEW');
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_flow_sales_return() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_flow_sales_return ON public.sales_returns;
CREATE TRIGGER trg_lwb_flow_sales_return
AFTER INSERT ON public.sales_returns
FOR EACH ROW EXECUTE FUNCTION public.lwb_flow_sales_return();

-- ---------------------------------------------------------------------------
-- 9. Verify / to-do queue of the logged-in user (Dashboard Quick Actions).
--    Admin sees every queue. Each part is skipped if its table is not set up.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_my_verify_queue()
RETURNS TABLE (item text, label text, cnt integer, amount numeric, page text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_role text;
  v_all boolean;
  v_since date := (now() AT TIME ZONE 'Asia/Kolkata')::date - 45;
BEGIN
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
  IF v_role IS NULL THEN RAISE EXCEPTION 'Login is not active'; END IF;
  v_all := v_role = 'admin';

  -- Sales Head: orders waiting for approval
  IF v_all OR v_role = 'manager' THEN BEGIN
    RETURN QUERY SELECT 'ORDER_APPROVAL'::text, 'Approve new orders'::text, count(*)::int, sum(o.total_amount)::numeric, 'warehouse-orders.html'::text
      FROM public.orders o WHERE public.lwb_order_pending(o.status);
  EXCEPTION WHEN undefined_table OR undefined_column OR undefined_function THEN NULL; END; END IF;

  -- Godown Manager: vehicles to load (his own, or not given to anyone)
  IF v_all OR v_role IN ('manager','warehouse') THEN BEGIN
    RETURN QUERY SELECT 'LOADING'::text, 'Load vehicle & confirm'::text, count(*)::int, sum(o.total_amount)::numeric, 'loading-dispatch.html'::text
      FROM public.orders o JOIN public.dispatch_assignments a ON a.order_id = o.id
      WHERE lower(btrim(coalesce(o.status,''))) IN ('transport_allocated','loading')
        AND (v_role <> 'warehouse' OR a.loading_manager_id IS NULL OR a.loading_manager_id = auth.uid());
  EXCEPTION WHEN undefined_table OR undefined_column THEN NULL; END; END IF;

  -- Godown Manager / Sales Head: driver returns to approve, approved returns to receive
  IF v_all OR v_role IN ('manager','warehouse') THEN BEGIN
    RETURN QUERY SELECT 'RETURN_APPROVE'::text, 'Verify driver returns'::text, count(*)::int, sum(r.total_return_amount)::numeric, 'driver-returns.html'::text
      FROM public.lwb_driver_delivery_returns r WHERE r.status = 'PENDING_OFFICE';
    RETURN QUERY SELECT 'RETURN_RECEIVE'::text, 'Receive return goods'::text, count(*)::int, sum(r.total_return_amount)::numeric, 'driver-returns.html'::text
      FROM public.lwb_driver_delivery_returns r WHERE r.status = 'APPROVED' AND r.goods_received_at IS NULL;
  EXCEPTION WHEN undefined_table OR undefined_column THEN NULL; END; END IF;

  -- Accounts: loaded vehicles without a Tally bill
  IF v_all OR v_role = 'accounts' THEN BEGIN
    RETURN QUERY SELECT 'TALLY_BILL'::text, 'Make Tally bill (vehicle loaded)'::text, count(*)::int, sum(o.total_amount)::numeric, 'accounts-invoice.html'::text
      FROM public.orders o
      WHERE lower(btrim(coalesce(o.status,''))) = 'loaded' AND o.order_date::date >= v_since
        AND NOT EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = o.id);
  EXCEPTION WHEN undefined_table OR undefined_column THEN NULL; END; END IF;

  -- Accounts: driver payments to verify
  IF v_all OR v_role = 'accounts' THEN BEGIN
    RETURN QUERY SELECT 'DRIVER_PAYMENT'::text, 'Verify driver payments'::text, count(*)::int, sum(d.cash_reported)::numeric, 'driver-collections.html'::text
      FROM public.lwb_delivery_reports d WHERE d.payment_status = 'PENDING' AND coalesce(d.cash_reported,0) > 0;
  EXCEPTION WHEN undefined_table OR undefined_column THEN NULL; END; END IF;

  -- Accounts: office payment entries to post
  IF v_all OR v_role = 'accounts' THEN BEGIN
    RETURN QUERY SELECT 'OFFICE_PAYMENT'::text, 'Verify payment entries'::text, count(*)::int, sum(c.amount)::numeric, 'payment-collection.html'::text
      FROM public.lwb_payment_collections c WHERE c.status = 'PENDING';
  EXCEPTION WHEN undefined_table OR undefined_column THEN NULL; END; END IF;

  -- Accounts: approved driver returns on a billed PO with no credit note yet
  IF v_all OR v_role = 'accounts' THEN BEGIN
    RETURN QUERY SELECT 'CREDIT_NOTE'::text, 'Make credit note (return approved)'::text, count(*)::int, sum(x.amt)::numeric, 'accounts-invoice.html'::text
      FROM (SELECT r.order_id, sum(r.total_return_amount) amt
            FROM public.lwb_driver_delivery_returns r
            WHERE r.status = 'APPROVED' AND r.reviewed_at >= v_since
              AND EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = r.order_id)
              AND NOT EXISTS (SELECT 1 FROM public.lwb_tally_notes n WHERE n.order_id = r.order_id
                              AND n.kind = 'CREDIT' AND n.cancelled_at IS NULL)
            GROUP BY r.order_id) x;
  EXCEPTION WHEN undefined_table OR undefined_column THEN NULL; END; END IF;

  -- Admin: sales returns waiting for approval
  IF v_all THEN BEGIN
    RETURN QUERY SELECT 'SALES_RETURN'::text, 'Approve sales returns'::text, count(*)::int, sum(s.total_amount)::numeric, 'sales-return.html'::text
      FROM public.sales_returns s WHERE lower(btrim(coalesce(s.approval_status,''))) = 'pending';
  EXCEPTION WHEN undefined_table OR undefined_column THEN NULL; END; END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_my_verify_queue() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_my_verify_queue() TO authenticated;

COMMIT;

-- ---------------------------------------------------------------------------
-- 10. 🔔 instantly: send new notification rows to the open ERP pages (RLS still applies).
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
     AND NOT EXISTS (SELECT 1 FROM pg_publication_tables
                     WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'erp_notifications') THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.erp_notifications;
  END IF;
END
$do$;
NOTIFY pgrst, 'reload schema';

-- Check: 8 rows, all ok = true
SELECT 'new_order_popup' AS item, EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_flow_order_new') AS ok
UNION ALL SELECT 'bill_made_popup', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_flow_bill_made')
UNION ALL SELECT 'driver_money_popup', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_flow_driver_money')
UNION ALL SELECT 'driver_return_popup', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_flow_driver_return')
UNION ALL SELECT 'credit_debit_note_popup', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_flow_tally_note')
UNION ALL SELECT 'sales_return_popup', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_flow_sales_return')
UNION ALL SELECT 'verify_queue', to_regprocedure('public.lwb_my_verify_queue()') IS NOT NULL
UNION ALL SELECT 'instant_bell', EXISTS (SELECT 1 FROM pg_publication_tables
  WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'erp_notifications');
