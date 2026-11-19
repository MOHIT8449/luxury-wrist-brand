-- LUXURY WRIST BRAND ERP — MARKET RETURN: CHECKED BY THE ASSIGNED GODOWN MANAGER (18 Nov 2026)
--
-- Mohit (18 Nov 2026): when the vehicle comes back from the market with a party return (damage, leakage, ...),
-- the return goes to the Godown Manager the vehicle was given to. He counts each SKU in cases + pcs
-- (good / damaged and the damage type), submits, and the sales side (salesman of the order, Sales Head, Admin)
-- gets a notification of what came back.
--
--   * lwb_return_gm(order)              -> the loading Godown Manager of the order (NULL = nobody given).
--   * "Receive return goods" bell + Pending Work for a Godown login: only his own returns (or nobody's).
--   * lwb_receive_return_goods3(return, lines, note)
--       lines = [{item_id, good_cs, good_pcs, bad_cs, bad_pcs, bad_bucket}] ; good + bad <= the driver's qty,
--       the rest is reported as short. Good -> saleable stock, bad -> its damage place (as before).
--       Sends RETURN_CHECKED to the salesman, Sales Head and Admin.
--
-- Needs: lwb_return_stock_setup.sql, lwb_driver_payment_setup.sql, lwb_order_flow_popups_setup.sql.
-- Safe to run again. Nothing is dropped or deleted.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_return_gm(p_order uuid)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v uuid;
BEGIN
  SELECT a.loading_manager_id INTO v FROM public.dispatch_assignments a
  WHERE a.order_id = p_order AND a.loading_manager_id IS NOT NULL ORDER BY a.id DESC LIMIT 1;
  RETURN v;
EXCEPTION WHEN undefined_column OR undefined_table THEN RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_return_gm(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_return_gm(uuid) TO authenticated;

-- "Receive Return Goods" bell: only the order's Godown Manager (everybody in the godown when nobody was given).
DO $do$
DECLARE d text; n text;
BEGIN
  IF to_regprocedure('public.lwb_return_approved_notify()') IS NULL THEN RETURN; END IF;
  d := pg_get_functiondef('public.lwb_return_approved_notify()'::regprocedure);
  IF d ~ 'lwb_return_gm' THEN RETURN; END IF;
  n := regexp_replace(d, $re$(WHERE p\.active = true AND lower\(btrim\(p\.role\)\) = 'warehouse')\s*;$re$,
         $r$\1 AND (public.lwb_return_gm(NEW.order_id) IS NULL OR p.id = public.lwb_return_gm(NEW.order_id));$r$);
  IF n <> d THEN EXECUTE n; ELSE RAISE WARNING 'lwb_return_approved_notify: godown line not found, not changed'; END IF;
END $do$;

-- Pending Work (Verify / Receive returns) for a Godown login: only his own returns (or nobody's).
DO $do$
DECLARE d text; n text;
BEGIN
  IF to_regprocedure('public.lwb_my_verify_queue()') IS NULL THEN RETURN; END IF;
  d := pg_get_functiondef('public.lwb_my_verify_queue()'::regprocedure);
  IF d ~ 'lwb_return_gm' THEN RETURN; END IF;
  n := replace(d, $s$FROM public.lwb_driver_delivery_returns r WHERE r.status = 'PENDING_OFFICE';$s$,
    $s$FROM public.lwb_driver_delivery_returns r WHERE r.status = 'PENDING_OFFICE'
        AND (v_role <> 'warehouse' OR public.lwb_return_gm(r.order_id) IS NULL OR public.lwb_return_gm(r.order_id) = auth.uid());$s$);
  n := replace(n, $s$FROM public.lwb_driver_delivery_returns r WHERE r.status = 'APPROVED' AND r.goods_received_at IS NULL;$s$,
    $s$FROM public.lwb_driver_delivery_returns r WHERE r.status = 'APPROVED' AND r.goods_received_at IS NULL
        AND (v_role <> 'warehouse' OR public.lwb_return_gm(r.order_id) IS NULL OR public.lwb_return_gm(r.order_id) = auth.uid());$s$);
  IF n <> d THEN EXECUTE n; ELSE RAISE WARNING 'lwb_my_verify_queue: return lines not found, not changed'; END IF;
END $do$;

-- Text of a quantity in pcs: "6 case + 4 pcs".
CREATE OR REPLACE FUNCTION public.lwb_rc_qty(p_pcs bigint, p_per integer)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE WHEN coalesce(p_pcs,0) <= 0 THEN '0'
    ELSE concat_ws(' + ', CASE WHEN p_pcs / greatest(p_per,1) > 0 THEN (p_pcs / greatest(p_per,1))::text || ' case' END,
                          CASE WHEN p_pcs % greatest(p_per,1) > 0 THEN (p_pcs % greatest(p_per,1))::text || ' pcs' END) END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_receive_return_goods3(p_return_id uuid, p_lines jsonb DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_return public.lwb_driver_delivery_returns%ROWTYPE;
  v_role text; v_gm uuid;
  v_note text := NULLIF(btrim(COALESCE(p_note,'')),'');
  v_o jsonb; v_order_no text; v_party text; v_sales uuid; v_by text;
  v_batch uuid := gen_random_uuid();
  v_bad_ok constant text[] := ARRAY['DAMAGE','LEAKAGE','BREAKAGE','GASLESS','EXPIRY'];
  l record; e jsonb; v_good bigint; v_bad bigint; v_short bigint; v_bucket text;
  v_moved integer := 0; v_skipped text[] := '{}'; v_tg bigint := 0; v_tb bigint := 0; v_ts bigint := 0;
  v_txt text[] := '{}'; v_msg text; v_rid uuid;
BEGIN
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
  IF v_role IS NULL OR v_role NOT IN ('warehouse','manager','admin') THEN
    RAISE EXCEPTION 'Only Godown, Sales Head or Admin can receive return goods';
  END IF;
  IF length(COALESCE(v_note,'')) > 300 THEN RAISE EXCEPTION 'Note is too long'; END IF;
  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) <> 'array' THEN RAISE EXCEPTION 'Lines must be a list'; END IF;
  SELECT * INTO v_return FROM public.lwb_driver_delivery_returns WHERE id = p_return_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Return not found'; END IF;
  IF v_return.status <> 'APPROVED' THEN RAISE EXCEPTION 'Only approved returns are received'; END IF;
  IF v_return.goods_received_at IS NOT NULL THEN RAISE EXCEPTION 'Goods already received'; END IF;
  v_gm := public.lwb_return_gm(v_return.order_id);
  IF v_role = 'warehouse' AND v_gm IS NOT NULL AND v_gm <> auth.uid() THEN
    RAISE EXCEPTION 'This vehicle was given to another Godown Manager';
  END IF;
  SELECT to_jsonb(o) INTO v_o FROM public.orders o WHERE o.id = v_return.order_id;
  v_order_no := coalesce(v_o->>'order_no','order'); v_party := v_o->>'customer_name';
  v_sales := nullif(v_o->>'created_by','')::uuid;

  FOR l IN SELECT * FROM public.lwb_return_receive_lines(p_return_id) LOOP
    e := NULL;
    SELECT x INTO e FROM jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) x WHERE x->>'item_id' = l.item_id::text LIMIT 1;
    IF e IS NULL THEN  -- not sent: all of it to its default place
      IF l.default_bucket = 'SALEABLE' THEN v_good := l.qty_pcs; v_bad := 0; ELSE v_good := 0; v_bad := l.qty_pcs; END IF;
      v_bucket := CASE WHEN l.default_bucket = ANY (v_bad_ok) THEN l.default_bucket ELSE 'DAMAGE' END;
    ELSE
      IF EXISTS (SELECT 1 FROM unnest(ARRAY['good_cs','good_pcs','bad_cs','bad_pcs']) k
                 WHERE coalesce(nullif(btrim(e->>k),''),'0') !~ '^[0-9]{1,6}$') THEN
        RAISE EXCEPTION 'Enter whole cases and pcs for %', l.sku_name;
      END IF;
      v_good := coalesce(nullif(btrim(e->>'good_cs'),''),'0')::bigint * l.pcs_per_case + coalesce(nullif(btrim(e->>'good_pcs'),''),'0')::bigint;
      v_bad  := coalesce(nullif(btrim(e->>'bad_cs'),''),'0')::bigint * l.pcs_per_case + coalesce(nullif(btrim(e->>'bad_pcs'),''),'0')::bigint;
      v_bucket := upper(btrim(coalesce(nullif(e->>'bad_bucket',''), CASE WHEN l.default_bucket = ANY (v_bad_ok) THEN l.default_bucket ELSE 'DAMAGE' END)));
      IF NOT (v_bucket = ANY (v_bad_ok)) THEN RAISE EXCEPTION 'Choose Damage, Gasless or Expiry for %', l.sku_name; END IF;
    END IF;
    IF v_good + v_bad > l.qty_pcs THEN
      RAISE EXCEPTION '% : % entered, but the driver returned only %', l.sku_name,
        public.lwb_rc_qty(v_good + v_bad, l.pcs_per_case), public.lwb_rc_qty(l.qty_pcs, l.pcs_per_case);
    END IF;
    v_short := l.qty_pcs - v_good - v_bad;
    v_tg := v_tg + v_good; v_tb := v_tb + v_bad; v_ts := v_ts + v_short;
    v_txt := v_txt || (btrim(l.sku_name) || ': ' || concat_ws(', ',
      CASE WHEN v_good > 0 THEN 'good ' || public.lwb_rc_qty(v_good, l.pcs_per_case) END,
      CASE WHEN v_bad > 0 THEN initcap(lower(v_bucket)) || ' ' || public.lwb_rc_qty(v_bad, l.pcs_per_case) END,
      CASE WHEN v_short > 0 THEN 'SHORT ' || public.lwb_rc_qty(v_short, l.pcs_per_case) END));
    IF l.sku_id IS NULL THEN v_skipped := v_skipped || l.sku_name; CONTINUE; END IF;
    -- One stock line per return line carries the return line id (unique index); a split line's second part has none.
    v_rid := l.item_id;
    IF v_good > 0 THEN
      INSERT INTO public.lwb_stock_moves(batch_id, kind, from_bucket, to_bucket, sku_id, sku_name, pcs_per_case, qty_pcs,
        requested_pcs, move_date, reason, note, source, status, requested_by, requested_at, decided_by, decided_at,
        decision_note, order_id, return_item_id)
      VALUES (v_batch, 'RETURN_IN', 'PARTY', 'SALEABLE', l.sku_id, l.sku_name, l.pcs_per_case, v_good, v_good,
        public.lwb_stx_today(), left('Party return ' || v_order_no || ' (checked good)', 300),
        v_note, 'RETURN', 'APPROVED', auth.uid(), now(), auth.uid(), now(), 'Checked by Godown Manager', v_return.order_id, v_rid);
      v_moved := v_moved + 1; v_rid := NULL;
    END IF;
    IF v_bad > 0 THEN
      INSERT INTO public.lwb_stock_moves(batch_id, kind, from_bucket, to_bucket, sku_id, sku_name, pcs_per_case, qty_pcs,
        requested_pcs, move_date, reason, note, source, status, requested_by, requested_at, decided_by, decided_at,
        decision_note, order_id, return_item_id)
      VALUES (v_batch, 'RETURN_IN', 'PARTY', v_bucket, l.sku_id, l.sku_name, l.pcs_per_case, v_bad, v_bad,
        public.lwb_stx_today(), left('Party return ' || v_order_no || ' (' || initcap(lower(v_bucket)) || ')', 300),
        v_note, 'RETURN', 'APPROVED', auth.uid(), now(), auth.uid(), now(), 'Checked by Godown Manager', v_return.order_id, v_rid);
      v_moved := v_moved + 1;
    END IF;
  END LOOP;

  UPDATE public.lwb_driver_delivery_returns
  SET goods_received_at = now(), goods_received_by = auth.uid(),
      goods_received_note = left(concat_ws(' · ', v_note,
        CASE WHEN v_ts > 0 THEN 'Short at godown' END,
        CASE WHEN cardinality(v_skipped) > 0 THEN 'Not in SKU Master, stock not changed: ' || array_to_string(v_skipped, ', ') END), 300)
  WHERE id = p_return_id;
  UPDATE public.erp_notifications SET is_read = true
  WHERE order_id = v_return.order_id AND notification_type = 'DELIVERY_RETURN_RECEIVE' AND is_read = false;

  -- Sales side: salesman of the order, Sales Head, Admin.
  SELECT nullif(btrim(p.full_name),'') INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();
  v_msg := left(coalesce(v_party,'') || ' · ' || array_to_string(v_txt, ' · ') || '.'
           || coalesce(' Checked by ' || v_by || '.', '') || coalesce(' Note: ' || v_note, ''), 600);
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, left(CASE WHEN v_ts > 0 THEN 'Return checked (SHORT): ' ELSE 'Return checked at godown: ' END || v_order_no, 150),
         v_msg, 'RETURN_CHECKED', v_return.order_id
  FROM public.user_profiles p
  WHERE p.active = true AND p.id <> auth.uid()
    AND (lower(btrim(p.role)) IN ('admin','manager') OR p.id = v_sales);

  RETURN jsonb_build_object('status','RECEIVED','lines',v_moved,'saleable_pcs',v_tg,'held_pcs',v_tb,'short_pcs',v_ts,'skipped',to_jsonb(v_skipped));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_receive_return_goods3(uuid,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_receive_return_goods3(uuid,jsonb,text) TO authenticated;

COMMIT;
