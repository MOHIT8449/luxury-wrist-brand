-- LUXURY WRIST BRAND ERP — ORDER STATUS CHAIN: LOADED → BILL → OUT FOR DELIVERY → DELIVERED (18 Nov 2026)
--
-- Mohit (18 Nov 2026): Transport assigned → the Godown Manager loads → everybody sees "Loaded" and Accounts
-- gets "make the bill" → when Accounts makes the bill it is "Out for delivery" → the driver delivers → "Delivered".
-- Until now the salesman got "Out for Delivery" already at loading (before any bill).
--
--   * Vehicle loaded  -> salesman: "Order Loaded" (bill being made) ORDER_LOADED; if the bill was made before
--                        loading: "Order Out for Delivery" ORDER_DISPATCHED. (Accounts / Sales Head / Admin bells
--                        at loading stay as they are: lwb_notify_vehicle_loaded.)
--   * Tally bill made -> on a loaded order: "Out for Delivery" to salesman, Sales Head and Admin (ORDER_DISPATCHED);
--                        "Bill Made" to driver and Godown Manager as before.
--   * lwb_my_orders gets billed_at (when Accounts entered the bill), for the salesman's PO track.
--
-- Needs: lwb_order_updates_everyone_setup.sql, lwb_order_flow_popups_setup.sql, lwb_loading_workflow_setup.sql.
-- Safe to run again. Only notifications are added; no order, stock, bill or money is changed.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_flow_sales_order_steps()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE
  v_new text := lower(btrim(coalesce(NEW.status,'')));
  v_old text := CASE WHEN TG_OP = 'UPDATE' THEN lower(btrim(coalesce(OLD.status,''))) ELSE '' END;
  v_ok text[] := ARRAY['approved','approved_next','manager_approved','warehouse_approved'];
  v_by text; v_vehicle text; v_billed boolean;
BEGIN
  IF v_new = v_old THEN RETURN NULL; END IF;
  BEGIN
    SELECT nullif(btrim(full_name),'') INTO v_by FROM public.user_profiles WHERE id = auth.uid();
    IF v_new = ANY(v_ok) AND NOT (v_old = ANY(v_ok)) THEN
      PERFORM public.lwb_order_tell(NEW.id, ARRAY['salesman'], 'PO Approved',
        public.lwb_order_line(NEW) || coalesce(' · Approved by ' || v_by, '') || '.', 'ORDER_APPROVED');
    ELSIF v_new = 'loaded' AND TG_OP = 'UPDATE' THEN
      SELECT nullif(btrim(a.vehicle_no),'') INTO v_vehicle FROM public.dispatch_assignments a WHERE a.order_id = NEW.id ORDER BY a.id DESC LIMIT 1;
      v_billed := EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = NEW.id);
      IF v_billed THEN
        PERFORM public.lwb_order_tell(NEW.id, ARRAY['salesman'], 'Order Out for Delivery',
          public.lwb_order_line(NEW) || coalesce(' · Vehicle ' || v_vehicle, '') || '. Loaded and billed, on the way to the party.', 'ORDER_DISPATCHED');
      ELSE
        PERFORM public.lwb_order_tell(NEW.id, ARRAY['salesman'], 'Order Loaded',
          public.lwb_order_line(NEW) || coalesce(' · Vehicle ' || v_vehicle, '') || '. Loaded at the godown; Accounts is making the bill.', 'ORDER_LOADED');
      END IF;
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

-- Tally bill made: driver + Godown Manager "Bill Made" (as before); a loaded order is now Out for Delivery for the sales side.
CREATE OR REPLACE FUNCTION public.lwb_flow_bill_made()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_vehicle text;
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  SELECT a.vehicle_no INTO v_vehicle FROM public.dispatch_assignments a WHERE a.order_id = NEW.order_id ORDER BY a.id DESC LIMIT 1;
  BEGIN
    IF lower(btrim(coalesce(v_o.status,''))) IN ('loaded','invoiced','dispatched') THEN
      PERFORM public.lwb_flow_send(NEW.order_id, ARRAY['driver','godown'], 'Bill Made',
        concat_ws(' · ', v_o.order_no, v_o.customer_name, 'Vehicle ' || nullif(btrim(v_vehicle),''))
          || ': Accounts made the bill. The vehicle can leave with the bill.',
        'TALLY_BILL_DONE');
      PERFORM public.lwb_order_tell(NEW.order_id, ARRAY['salesman','manager','admin'], 'Order Out for Delivery',
        public.lwb_order_line(v_o) || coalesce(' · Vehicle ' || nullif(btrim(v_vehicle),''), '') || '. Bill made, on the way to the party.',
        'ORDER_DISPATCHED');
    ELSE
      -- Bill made before loading: "Out for delivery" comes when the vehicle is loaded.
      PERFORM public.lwb_flow_send(NEW.order_id, ARRAY['driver','salesman','godown'], 'Bill Made',
        concat_ws(' · ', v_o.order_no, v_o.customer_name, 'Vehicle ' || nullif(btrim(v_vehicle),''))
          || ': Accounts made the bill. Loading is still pending.',
        'TALLY_BILL_DONE');
    END IF;
  EXCEPTION WHEN others THEN
    RAISE WARNING 'Bill made bell skipped: %', SQLERRM;  -- a bell never stops the bill
  END;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_flow_bill_made() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_flow_bill_made ON public.lwb_tally_invoices;
CREATE TRIGGER trg_lwb_flow_bill_made
AFTER INSERT ON public.lwb_tally_invoices
FOR EACH ROW EXECUTE FUNCTION public.lwb_flow_bill_made();

-- Salesman PO track: when the bill was made (no bill no. or amount).
DO $do$
DECLARE d text; n text;
BEGIN
  IF to_regprocedure('public.lwb_my_orders(integer)') IS NULL THEN RETURN; END IF;
  d := pg_get_functiondef('public.lwb_my_orders(integer)'::regprocedure);
  IF d ~ 'billed_at' THEN RETURN; END IF;
  n := replace(d, $s$'driver_name', a.driver_name,$s$,
    $s$'billed_at', (SELECT t.entered_at FROM public.lwb_tally_invoices t WHERE t.order_id = o.id), 'driver_name', a.driver_name,$s$);
  IF n <> d THEN EXECUTE n; ELSE RAISE WARNING 'lwb_my_orders: driver_name line not found, not changed'; END IF;
END $do$;

COMMIT;
