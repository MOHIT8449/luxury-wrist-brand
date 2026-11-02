-- LUXURY WRIST BRAND ERP — DELETE / CANCEL / MODIFY A SALES ORDER (PO) AT ANY STAGE
--
-- Applied automatically on merge (Supabase apply workflow). Safe to run again.
--
-- Mohit (2 Nov 2026): Admin must be able to delete any sales order / PO
-- (dummy and duplicate data). Everyone else only Cancels. If the market
-- cancels after our vehicle is loading or loaded, the Sales Head must still be
-- able to Modify or Cancel the order.
--
-- 1. lwb_order_delete_preview(ids) / lwb_admin_delete_orders(ids, reason)
--    Admin only. Deletes the orders AND every row linked to them: SKU lines,
--    transport / loading, delivery reports, returns, bills, payments, bells ...
--    Linked rows are found from the database's own foreign keys (any depth),
--    plus any table with an order_id uuid column that has no foreign key.
--    A copy of each deleted order (order + SKU lines + linked counts) is kept
--    in lwb_order_audit, so a mistake can still be looked up.
-- 2. lwb_head_cancel_order(id, reason, note)
--    Admin / Sales Head: cancel at any stage until the goods are delivered
--    (pending, approved, transport assigned, loading, loaded, billed).
--    Godown Manager, Driver and (after loading) Accounts get a bell.
-- 3. lwb_head_modify_order(id, items, note, reason)
--    Admin / Sales Head: change SKU / cases / rate / weight while the vehicle
--    is loading, loaded or billed (before delivery). Loaded cases above the new
--    cases are cut down to the new cases. Same people get a bell.
--
-- Only the chosen orders and their own linked rows are changed / deleted.

BEGIN;

-- Record of every delete / late cancel / late modify (no grants; read in SQL editor).
CREATE TABLE IF NOT EXISTS public.lwb_order_audit (
  id bigserial PRIMARY KEY,
  order_id uuid NOT NULL,
  order_no text,
  action text NOT NULL CHECK (action IN ('DELETE','CANCEL','MODIFY')),
  reason text,
  details jsonb,
  done_by uuid,
  done_by_name text,
  done_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_order_audit_order_idx ON public.lwb_order_audit(order_id);
ALTER TABLE public.lwb_order_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_order_audit FROM PUBLIC, anon, authenticated;

-- Signed-in role, lower case ('' when inactive / unknown).
CREATE OR REPLACE FUNCTION public.lwb_order_actor_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce((SELECT lower(btrim(p.role)) FROM public.user_profiles p
                   WHERE p.id = auth.uid() AND p.active IS TRUE), '');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_actor_role() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Linked-row walker: counts (p_dry) or deletes the rows of p_tbl matching
-- p_where, after doing the same for every table that points at them.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_order_purge(p_tbl regclass, p_where text, p_depth integer, p_dry boolean, p_counts jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  c record;
  v_child_where text;
  v_n bigint;
  v_key text;
BEGIN
  IF p_depth > 6 THEN
    RAISE EXCEPTION 'Linked records go too deep under %. Delete stopped, nothing changed.', p_tbl;
  END IF;

  -- Tables with a foreign key to this table (ON DELETE SET NULL / SET DEFAULT are left to the database).
  FOR c IN
    SELECT k.conrelid::regclass AS child,
      (SELECT string_agg(format('%I', a.attname), ',' ORDER BY x.n)
         FROM unnest(k.conkey) WITH ORDINALITY x(att, n)
         JOIN pg_catalog.pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = x.att) AS ccols,
      (SELECT string_agg(format('%I', a.attname), ',' ORDER BY x.n)
         FROM unnest(k.confkey) WITH ORDINALITY x(att, n)
         JOIN pg_catalog.pg_attribute a ON a.attrelid = k.confrelid AND a.attnum = x.att) AS pcols
    FROM pg_catalog.pg_constraint k
    WHERE k.contype = 'f' AND k.confrelid = p_tbl AND k.conrelid <> p_tbl
      AND k.confdeltype NOT IN ('n','d')
      AND k.conrelid <> 'public.lwb_order_audit'::regclass
    ORDER BY 1::text
  LOOP
    v_child_where := format('(%s) IN (SELECT %s FROM %s WHERE %s)', c.ccols, c.pcols, p_tbl, p_where);
    p_counts := public.lwb_order_purge(c.child, v_child_where, p_depth + 1, p_dry, p_counts);
  END LOOP;

  -- Orders only: tables that keep an order_id uuid without a foreign key (bells, logs ...).
  IF p_tbl = 'public.orders'::regclass THEN
    FOR c IN
      SELECT a.attrelid::regclass AS child
      FROM pg_catalog.pg_attribute a
      JOIN pg_catalog.pg_class t ON t.oid = a.attrelid AND t.relkind IN ('r','p')
      JOIN pg_catalog.pg_namespace s ON s.oid = t.relnamespace AND s.nspname = 'public'
      WHERE a.attname = 'order_id' AND a.atttypid = 'uuid'::regtype AND NOT a.attisdropped
        AND a.attrelid NOT IN ('public.orders'::regclass, 'public.lwb_order_audit'::regclass)
        AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k
                        WHERE k.contype = 'f' AND k.conrelid = a.attrelid AND k.confrelid = 'public.orders'::regclass
                          AND a.attnum = ANY(k.conkey))
      ORDER BY 1::text
    LOOP
      v_child_where := format('order_id IN (SELECT id FROM public.orders WHERE %s)', p_where);
      p_counts := public.lwb_order_purge(c.child, v_child_where, p_depth + 1, p_dry, p_counts);
    END LOOP;
  END IF;

  v_key := replace(p_tbl::text, 'public.', '');
  IF p_dry THEN
    EXECUTE format('SELECT count(*) FROM %s WHERE %s', p_tbl, p_where) INTO v_n;
    IF v_n > 0 THEN
      p_counts := jsonb_set(p_counts, ARRAY[v_key], to_jsonb(greatest(v_n, coalesce((p_counts->>v_key)::bigint, 0))));
    END IF;
  ELSE
    EXECUTE format('DELETE FROM %s WHERE %s', p_tbl, p_where);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN
      p_counts := jsonb_set(p_counts, ARRAY[v_key], to_jsonb(v_n + coalesce((p_counts->>v_key)::bigint, 0)));
    END IF;
  END IF;
  RETURN p_counts;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_purge(regclass, text, integer, boolean, jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_order_ids_where(p_ids uuid[])
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT format('id = ANY (%L::uuid[])', p_ids);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_ids_where(uuid[]) FROM PUBLIC, anon, authenticated;

-- What a delete would remove: {orders: [{id, order_no, customer_name, status}], linked: {table: rows}}
CREATE OR REPLACE FUNCTION public.lwb_order_delete_preview(p_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_ids uuid[];
  v_counts jsonb;
BEGIN
  IF public.lwb_order_actor_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an active Admin can delete orders. Use Cancel instead.';
  END IF;
  SELECT array_agg(DISTINCT x) INTO v_ids FROM unnest(p_ids) x WHERE x IS NOT NULL;
  IF v_ids IS NULL THEN RAISE EXCEPTION 'Select at least one order.'; END IF;
  IF cardinality(v_ids) > 200 THEN RAISE EXCEPTION 'Delete at most 200 orders at a time.'; END IF;
  v_counts := public.lwb_order_purge('public.orders'::regclass, public.lwb_order_ids_where(v_ids), 0, true, '{}'::jsonb);
  RETURN jsonb_build_object(
    'orders', coalesce((SELECT jsonb_agg(jsonb_build_object('id', o.id, 'order_no', o.order_no,
        'customer_name', o.customer_name, 'status', o.status) ORDER BY o.order_no)
      FROM public.orders o WHERE o.id = ANY(v_ids)), '[]'::jsonb),
    'linked', v_counts - 'orders');
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_delete_preview(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_delete_preview(uuid[]) TO authenticated;

-- Permanently delete orders and everything linked to them. All or nothing.
CREATE OR REPLACE FUNCTION public.lwb_admin_delete_orders(p_ids uuid[], p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_ids uuid[];
  v_found uuid[];
  v_counts jsonb;
  v_name text;
  v_nos text[];
BEGIN
  IF public.lwb_order_actor_role() <> 'admin' THEN
    RAISE EXCEPTION 'Only an active Admin can delete orders. Use Cancel instead.';
  END IF;
  IF length(btrim(coalesce(p_reason,''))) < 3 THEN
    RAISE EXCEPTION 'Write why these orders are deleted (e.g. dummy / duplicate).';
  END IF;
  SELECT array_agg(DISTINCT x) INTO v_ids FROM unnest(p_ids) x WHERE x IS NOT NULL;
  IF v_ids IS NULL THEN RAISE EXCEPTION 'Select at least one order.'; END IF;
  IF cardinality(v_ids) > 200 THEN RAISE EXCEPTION 'Delete at most 200 orders at a time.'; END IF;

  SELECT array_agg(o.id ORDER BY o.id), array_agg(o.order_no ORDER BY o.order_no)
    INTO v_found, v_nos
  FROM (SELECT id, order_no FROM public.orders WHERE id = ANY(v_ids) FOR UPDATE) o;
  IF v_found IS NULL OR cardinality(v_found) <> cardinality(v_ids) THEN
    RAISE EXCEPTION 'Some selected orders are already deleted. Refresh the page.';
  END IF;

  SELECT full_name INTO v_name FROM public.user_profiles WHERE id = auth.uid();
  v_counts := public.lwb_order_purge('public.orders'::regclass, public.lwb_order_ids_where(v_ids), 0, true, '{}'::jsonb);

  INSERT INTO public.lwb_order_audit (order_id, order_no, action, reason, details, done_by, done_by_name)
  SELECT o.id, o.order_no, 'DELETE', btrim(p_reason),
    jsonb_build_object('order', to_jsonb(o),
      'items', coalesce((SELECT jsonb_agg(to_jsonb(i)) FROM public.order_items i WHERE i.order_id = o.id), '[]'::jsonb),
      'linked_in_batch', v_counts - 'orders', 'batch_size', cardinality(v_ids)),
    auth.uid(), v_name
  FROM public.orders o WHERE o.id = ANY(v_ids);

  v_counts := public.lwb_order_purge('public.orders'::regclass, public.lwb_order_ids_where(v_ids), 0, false, '{}'::jsonb);
  IF coalesce((v_counts->>'orders')::int, 0) <> cardinality(v_ids) THEN
    RAISE EXCEPTION 'Delete did not finish. Nothing changed. Refresh and try again.';
  END IF;
  RETURN jsonb_build_object('deleted', to_jsonb(v_nos), 'linked', v_counts - 'orders');
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_admin_delete_orders(uuid[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_admin_delete_orders(uuid[], text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Bell to the people working on this order: Godown Manager + Driver of the
-- vehicle, Accounts (when asked), and the other Admin / Sales Head logins.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_order_crew_notify(p_order_id uuid, p_title text, p_msg text, p_type text, p_accounts boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_mgr uuid;
  v_mobile text;
BEGIN
  IF to_regclass('public.dispatch_assignments') IS NOT NULL THEN
    EXECUTE 'SELECT loading_manager_id, driver_mobile FROM public.dispatch_assignments WHERE order_id = $1 LIMIT 1'
      INTO v_mgr, v_mobile USING p_order_id;
  END IF;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT DISTINCT p.id, p_title, p_msg, p_type, p_order_id
  FROM public.user_profiles p
  WHERE p.active IS TRUE AND p.id IS DISTINCT FROM auth.uid() AND (
       lower(btrim(p.role)) IN ('admin','manager')
    OR p.id = v_mgr
    OR (p_accounts AND lower(btrim(p.role)) = 'accounts')
    OR (lower(btrim(p.role)) = 'driver' AND nullif(btrim(v_mobile),'') IS NOT NULL
        AND public.lwb_driver_phone_matches(p.mobile, v_mobile)));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_crew_notify(uuid, text, text, text, boolean) FROM PUBLIC, anon, authenticated;

-- Goods already handed over? (driver reported DELIVERED / PARTIAL, or status says delivered)
CREATE OR REPLACE FUNCTION public.lwb_order_is_delivered(p_order_id uuid, p_status text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_hit boolean := false;
BEGIN
  IF lower(btrim(coalesce(p_status,''))) IN ('delivered','closed','completed') THEN RETURN true; END IF;
  IF to_regclass('public.lwb_delivery_reports') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.lwb_delivery_reports WHERE order_id = $1 AND delivery_status IN (''DELIVERED'',''PARTIAL''))'
      INTO v_hit USING p_order_id;
  END IF;
  RETURN v_hit;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_is_delivered(uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_order_stage_name(p_status text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE lower(btrim(coalesce(p_status,'')))
    WHEN 'transport_allocated' THEN 'transport assigned' WHEN 'allocated' THEN 'transport assigned'
    WHEN 'loading' THEN 'loading' WHEN 'loaded' THEN 'vehicle loaded'
    WHEN 'invoiced' THEN 'billed' WHEN 'dispatched' THEN 'dispatched'
    ELSE coalesce(nullif(lower(btrim(p_status)),''),'pending') END;
$fn$;

-- ---------------------------------------------------------------------------
-- Cancel: Admin / Sales Head, any stage before delivery.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_head_cancel_order(p_order_id uuid, p_reason text, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_st text;
  v_by text;
  v_crew boolean;
  v_msg text;
BEGIN
  IF public.lwb_order_actor_role() NOT IN ('admin','manager') THEN
    RAISE EXCEPTION 'Only Admin or Sales Head can cancel this order.';
  END IF;
  IF length(btrim(coalesce(p_reason,''))) < 3 THEN RAISE EXCEPTION 'Cancellation reason is required.'; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found (deleted?). Refresh the page.'; END IF;
  v_st := lower(btrim(coalesce(v_o.status,'')));
  IF v_st IN ('cancelled','canceled') THEN RAISE EXCEPTION 'Order % is already cancelled.', v_o.order_no; END IF;
  IF public.lwb_order_is_delivered(p_order_id, v_o.status) THEN
    RAISE EXCEPTION 'Order % is already delivered. Use Sales Return instead of Cancel.', v_o.order_no;
  END IF;

  UPDATE public.orders SET status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(),
    cancel_reason = btrim(p_reason),
    manager_note = CASE WHEN p_note IS NULL THEN manager_note ELSE nullif(btrim(p_note),'') END
  WHERE id = p_order_id;

  SELECT full_name INTO v_by FROM public.user_profiles WHERE id = auth.uid();
  INSERT INTO public.lwb_order_audit (order_id, order_no, action, reason, details, done_by, done_by_name)
  VALUES (p_order_id, v_o.order_no, 'CANCEL', btrim(p_reason), jsonb_build_object('status_before', v_o.status), auth.uid(), v_by);

  -- Vehicle side already working on it: tell Godown Manager, Driver (+ Accounts after loading).
  v_crew := v_st IN ('transport_allocated','allocated','loading','loaded','invoiced','dispatched');
  IF v_crew THEN
    v_msg := concat_ws(' · ', v_o.order_no, v_o.customer_name,
      'cancelled at ' || public.lwb_order_stage_name(v_o.status), 'by ' || coalesce(v_by, 'Sales Head'))
      || '. Reason: ' || btrim(p_reason) || '.'
      || CASE WHEN v_st IN ('loading','loaded','invoiced','dispatched')
           THEN ' Do not deliver: bring the goods back to the godown.' ELSE ' Do not load this order.' END;
    PERFORM public.lwb_order_crew_notify(p_order_id, 'Order Cancelled — Do Not Deliver', v_msg, 'ORDER_CANCELLED',
      v_st IN ('loaded','invoiced','dispatched'));
  END IF;
  RETURN jsonb_build_object('order_no', v_o.order_no, 'status_before', v_o.status);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_head_cancel_order(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_head_cancel_order(uuid, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Modify while loading / loaded / billed (before delivery): Admin / Sales Head.
-- p_items: [{id (existing line) or null, sku_name, approved_qty, rate, unit_weight}]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_head_modify_order(p_order_id uuid, p_items jsonb, p_note text, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_st text;
  v_old public.order_items%ROWTYPE;
  e jsonb;
  v_id uuid;
  v_sku text;
  v_qty numeric;
  v_rate numeric;
  v_wt numeric;
  v_keep uuid[] := '{}';
  v_seen text[] := '{}';
  v_changes text[] := '{}';
  v_any boolean := false;
  v_by text;
  v_msg text;
BEGIN
  IF public.lwb_order_actor_role() NOT IN ('admin','manager') THEN
    RAISE EXCEPTION 'Only Admin or Sales Head can modify an order after loading starts.';
  END IF;
  IF length(btrim(coalesce(p_reason,''))) < 3 THEN RAISE EXCEPTION 'Write why the order is changed (e.g. market cancelled 5 CS).'; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found (deleted?). Refresh the page.'; END IF;
  v_st := lower(btrim(coalesce(v_o.status,'')));
  IF v_st NOT IN ('loading','loaded','invoiced') THEN
    RAISE EXCEPTION 'Order % is %. This change is only for loading / loaded orders; refresh the page.', v_o.order_no, coalesce(v_o.status,'pending');
  END IF;
  IF public.lwb_order_is_delivered(p_order_id, v_o.status) THEN
    RAISE EXCEPTION 'Order % is already delivered. Use Sales Return instead.', v_o.order_no;
  END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'An order needs at least one SKU. To drop the whole order, use Cancel Order.';
  END IF;

  -- Check every line first.
  FOR e IN SELECT v FROM jsonb_array_elements(p_items) AS t(v) LOOP
    v_sku := btrim(coalesce(e->>'sku_name',''));
    IF v_sku = '' THEN RAISE EXCEPTION 'Every line needs an SKU.'; END IF;
    IF upper(v_sku) = ANY(v_seen) THEN RAISE EXCEPTION '% is on two lines. Put all its cases on one line.', v_sku; END IF;
    v_seen := v_seen || upper(v_sku);
    IF coalesce(e->>'approved_qty','') !~ '^\d{1,6}$' THEN RAISE EXCEPTION 'Enter whole cases for %.', v_sku; END IF;
    IF coalesce(e->>'rate','') !~ '^\d{1,7}(\.\d+)?$' THEN RAISE EXCEPTION 'Enter a valid rate for %.', v_sku; END IF;
    IF coalesce(e->>'unit_weight','0') !~ '^\d{1,6}(\.\d+)?$' THEN RAISE EXCEPTION 'Enter a valid weight for %.', v_sku; END IF;
    IF (e->>'approved_qty')::int > 0 THEN v_any := true; END IF;
    v_id := CASE WHEN coalesce(e->>'id','') ~* '^[0-9a-f-]{36}$' THEN (e->>'id')::uuid END;
    IF v_id IS NOT NULL THEN
      SELECT * INTO v_old FROM public.order_items WHERE id = v_id AND order_id = p_order_id;
      IF NOT FOUND THEN RAISE EXCEPTION 'A SKU line of this order was changed by someone else. Refresh the page.'; END IF;
      v_keep := v_keep || v_id;
    END IF;
    IF (v_id IS NULL OR upper(btrim(v_old.sku_name)) <> upper(v_sku))
       AND NOT EXISTS (SELECT 1 FROM public.sku_master s WHERE upper(btrim(s.sku_name)) = upper(v_sku)) THEN
      RAISE EXCEPTION 'Select % from SKU Master.', v_sku;
    END IF;
  END LOOP;
  IF NOT v_any THEN RAISE EXCEPTION 'At least one SKU needs cases above 0. To drop the whole order, use Cancel Order.'; END IF;

  -- Lines taken off the order.
  FOR v_old IN SELECT * FROM public.order_items WHERE order_id = p_order_id AND NOT (id = ANY(v_keep)) ORDER BY id LOOP
    DELETE FROM public.order_items WHERE id = v_old.id;
    v_changes := v_changes || (v_old.sku_name || ' removed (' || coalesce(v_old.approved_qty, v_old.ordered_qty, 0) || ' CS)');
  END LOOP;

  FOR e IN SELECT v FROM jsonb_array_elements(p_items) AS t(v) LOOP
    v_sku := btrim(e->>'sku_name');
    v_qty := (e->>'approved_qty')::int;
    v_rate := (e->>'rate')::numeric;
    v_wt := coalesce(nullif(e->>'unit_weight',''),'0')::numeric;
    v_id := CASE WHEN coalesce(e->>'id','') ~* '^[0-9a-f-]{36}$' THEN (e->>'id')::uuid END;
    IF v_id IS NOT NULL THEN
      SELECT * INTO v_old FROM public.order_items WHERE id = v_id;
      IF coalesce(v_old.approved_qty, 0) <> v_qty OR coalesce(v_old.rate, 0) <> v_rate
         OR upper(btrim(v_old.sku_name)) <> upper(v_sku) THEN
        v_changes := v_changes || (v_sku || ' ' || coalesce(v_old.approved_qty, 0) || '→' || v_qty || ' CS' ||
          CASE WHEN coalesce(v_old.rate, 0) <> v_rate THEN ' @ ₹' || v_rate ELSE '' END ||
          CASE WHEN coalesce(v_old.loaded_qty, 0) > v_qty THEN ' (loaded ' || v_old.loaded_qty || '→' || v_qty || ')' ELSE '' END);
      END IF;
      UPDATE public.order_items SET sku_name = v_sku, approved_qty = v_qty, rate = v_rate, unit_weight = v_wt,
        amount = v_qty * v_rate, total_weight = v_qty * v_wt,
        loaded_qty = CASE WHEN coalesce(loaded_qty, 0) > v_qty THEN v_qty ELSE loaded_qty END
      WHERE id = v_id;
    ELSE
      INSERT INTO public.order_items (order_id, sku_name, ordered_qty, approved_qty, loaded_qty, rate, unit_weight, amount, total_weight)
      VALUES (p_order_id, v_sku, 0, v_qty, 0, v_rate, v_wt, v_qty * v_rate, v_qty * v_wt);
      v_changes := v_changes || (v_sku || ' added ' || v_qty || ' CS');
    END IF;
  END LOOP;

  UPDATE public.orders o SET total_qty = t.q, total_amount = t.a, total_weight = t.w,
    manager_note = CASE WHEN p_note IS NULL THEN o.manager_note ELSE nullif(btrim(p_note),'') END
  FROM (SELECT sum(coalesce(approved_qty,0)) q, sum(coalesce(amount,0)) a, sum(coalesce(total_weight,0)) w
        FROM public.order_items WHERE order_id = p_order_id) t
  WHERE o.id = p_order_id;

  IF cardinality(v_changes) > 0 THEN
    SELECT full_name INTO v_by FROM public.user_profiles WHERE id = auth.uid();
    INSERT INTO public.lwb_order_audit (order_id, order_no, action, reason, details, done_by, done_by_name)
    VALUES (p_order_id, v_o.order_no, 'MODIFY', btrim(p_reason),
      jsonb_build_object('status', v_o.status, 'changes', to_jsonb(v_changes)), auth.uid(), v_by);
    v_msg := concat_ws(' · ', v_o.order_no, v_o.customer_name,
      'changed at ' || public.lwb_order_stage_name(v_o.status), 'by ' || coalesce(v_by, 'Sales Head'))
      || ': ' || array_to_string(v_changes, ', ') || '. Reason: ' || btrim(p_reason) || '.'
      || ' Load / deliver only the new cases.';
    PERFORM public.lwb_order_crew_notify(p_order_id, 'Order Changed During Loading', v_msg, 'ORDER_EDITED',
      v_st IN ('loaded','invoiced'));
  END IF;
  RETURN jsonb_build_object('order_no', v_o.order_no, 'changed', cardinality(v_changes), 'changes', to_jsonb(v_changes));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_head_modify_order(uuid, jsonb, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_head_modify_order(uuid, jsonb, text, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: SELECT to_regprocedure('public.lwb_admin_delete_orders(uuid[],text)') IS NOT NULL AS delete_ready,
--               to_regprocedure('public.lwb_head_cancel_order(uuid,text,text)') IS NOT NULL AS cancel_ready,
--               to_regprocedure('public.lwb_head_modify_order(uuid,jsonb,text,text)') IS NOT NULL AS modify_ready;
-- Deleted orders: SELECT order_no, reason, done_by_name, done_at FROM public.lwb_order_audit WHERE action = 'DELETE' ORDER BY done_at DESC;
