-- Diagnostic only (not for main): fails if the order status chain patch is missing. Reads definitions, changes nothing.
DO $$
DECLARE m text := '';
BEGIN
  IF to_regprocedure('public.lwb_flow_out_for_delivery()') IS NULL THEN m := m || ' no lwb_flow_out_for_delivery;'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_flow_out_for_delivery' AND NOT tgisinternal) THEN m := m || ' no out trigger;'; END IF;
  IF pg_get_functiondef('public.lwb_flow_sales_order_steps()'::regprocedure) !~ 'ORDER_LOADED' THEN m := m || ' loading bell old;'; END IF;
  IF pg_get_functiondef('public.lwb_flow_bill_made()'::regprocedure) ~ 'ORDER_DISPATCHED' THEN m := m || ' bill bell still says out;'; END IF;
  IF pg_get_functiondef('public.lwb_my_orders(integer)'::regprocedure) !~ 'out_at' THEN m := m || ' my_orders no out_at;'; END IF;
  IF pg_get_functiondef('public.lwb_my_orders(integer)'::regprocedure) !~ 'billed_at' THEN m := m || ' my_orders no billed_at;'; END IF;
  IF m <> '' THEN RAISE EXCEPTION 'STATUS CHAIN CHECK FAILED:%', m; END IF;
  RAISE EXCEPTION 'STATUS CHAIN CHECK OK (expected stop, nothing changed)';
END $$;
