-- DIAG dry run of the fix (rolls back)
BEGIN;


CREATE OR REPLACE FUNCTION public.lwb_bill_change_apply(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  c public.lwb_bill_changes%ROWTYPE;
  l jsonb;
  v_cur record;
  v_qty numeric;
  v_t record;
  v_idx int := 0;
  v_i int := 0;
  v_b jsonb;
  v_new jsonb := '[]'::jsonb;
  v_applied jsonb;
  v_snap jsonb;
  v_o record;
BEGIN
  SELECT * INTO c FROM public.lwb_bill_changes WHERE id = p_id FOR UPDATE;
  -- Asked before loading, PO loaded since (19 Nov 2026, LXY-00441): the change now counts the loaded qty,
  -- so the loaded qty, approved qty, godown stock and PO total all follow it (as the approval popup shows).
  SELECT o.status::text AS st INTO v_o FROM public.orders o WHERE o.id = c.order_id;
  IF c.qty_col = 'approved_qty' AND public.lwb_bill_qty_col(v_o.st) = 'loaded_qty' THEN
    FOR l IN SELECT * FROM jsonb_array_elements(c.lines) LOOP
      CONTINUE WHEN coalesce(l->>'item_id','') = '';
      SELECT btrim(i.sku_name::text) AS sku, coalesce(i.loaded_qty,0) AS qty INTO v_cur
        FROM public.order_items i WHERE i.order_id = c.order_id AND i.id::text = l->>'item_id';
      IF FOUND AND v_cur.qty <> (l->>'qty_old')::numeric THEN
        RAISE EXCEPTION 'STALE: this change was asked before loading, and % was loaded % (not %). Send it back; Accounts should send the change again on the loaded qty.',
          l->>'sku_old', v_cur.qty, l->>'qty_old';
      END IF;
    END LOOP;
    UPDATE public.lwb_bill_changes SET qty_col = 'loaded_qty' WHERE id = p_id;
    c.qty_col := 'loaded_qty';
  END IF;
  -- the PO must still be as it was when the change was asked
  FOR l IN SELECT * FROM jsonb_array_elements(c.lines) LOOP
    CONTINUE WHEN coalesce(l->>'item_id','') = '';
    SELECT btrim(i.sku_name::text) AS sku, coalesce(i.rate,0) AS rate,
           CASE WHEN c.qty_col = 'loaded_qty' THEN coalesce(i.loaded_qty,0) ELSE coalesce(i.approved_qty, i.ordered_qty, 0) END AS qty
      INTO v_cur FROM public.order_items i WHERE i.order_id = c.order_id AND i.id::text = l->>'item_id';
    IF NOT FOUND OR upper(v_cur.sku) <> upper(l->>'sku_old') OR v_cur.qty <> (l->>'qty_old')::numeric
       OR v_cur.rate <> (l->>'rate_old')::numeric THEN
      RAISE EXCEPTION 'STALE: PO lines changed after this request (%). Accounts should send the change again.', l->>'sku_old';
    END IF;
  END LOOP;

  -- after loading: godown stock follows the change (lwb_bill_change_stock_setup.sql)
  IF to_regprocedure('public.lwb_bill_change_stock_before(uuid)') IS NOT NULL THEN
    EXECUTE 'SELECT public.lwb_bill_change_stock_before($1)' INTO v_snap USING p_id;
  END IF;

  FOR l IN SELECT * FROM jsonb_array_elements(c.lines) LOOP
    v_qty := (l->>'qty')::numeric;
    IF coalesce(l->>'item_id','') = '' THEN
      INSERT INTO public.order_items (order_id, sku_name, ordered_qty, approved_qty, loaded_qty, rate, unit_weight, amount, total_weight, entry_uom)
      VALUES (c.order_id, l->>'sku', 0, v_qty, CASE WHEN c.qty_col = 'loaded_qty' THEN v_qty ELSE 0 END,
              (l->>'rate')::numeric, 0, v_qty * (l->>'rate')::numeric, 0, 'CS');
    ELSIF c.qty_col = 'loaded_qty' THEN
      UPDATE public.order_items SET sku_name = l->>'sku', rate = (l->>'rate')::numeric, loaded_qty = v_qty
      WHERE order_id = c.order_id AND id::text = l->>'item_id';
    ELSE
      UPDATE public.order_items SET sku_name = l->>'sku', rate = (l->>'rate')::numeric, approved_qty = v_qty,
             amount = v_qty * (l->>'rate')::numeric
      WHERE order_id = c.order_id AND id::text = l->>'item_id';
    END IF;
  END LOOP;
  IF v_snap IS NOT NULL THEN
    EXECUTE 'SELECT public.lwb_bill_change_stock_after($1, $2)' USING p_id, v_snap;
  END IF;

  -- Tally bill already entered: its amount follows the approved value (the chosen bill line takes the difference)
  SELECT t.amount, t.bills INTO v_t FROM public.lwb_tally_invoices t WHERE t.order_id = c.order_id FOR UPDATE;
  -- Tally bill entered after the change was asked, already at the new value: leave it as it is.
  IF FOUND AND v_t.amount IS NOT NULL AND c.diff <> 0 AND abs(v_t.amount - c.new_value) < 1 THEN
    v_applied := jsonb_build_object('no', c.bill_no, 'from', v_t.amount, 'to', v_t.amount, 'already', true);
  ELSIF FOUND AND v_t.amount IS NOT NULL AND c.diff <> 0 THEN
    IF round(v_t.amount + c.diff, 2) <= 0 THEN
      RAISE EXCEPTION 'The Tally bill % would go to zero or below. Use a credit note instead.', v_t.amount;
    END IF;
    IF jsonb_array_length(coalesce(v_t.bills,'[]'::jsonb)) > 0 THEN
      FOR v_b IN SELECT * FROM jsonb_array_elements(v_t.bills) LOOP
        IF c.bill_no IS NOT NULL AND upper(btrim(v_b->>'no')) = upper(btrim(c.bill_no)) THEN v_idx := v_i; END IF;
        v_i := v_i + 1;
      END LOOP;
      v_i := 0;
      FOR v_b IN SELECT * FROM jsonb_array_elements(v_t.bills) LOOP
        IF v_i = v_idx THEN
          IF round((v_b->>'amount')::numeric + c.diff, 2) <= 0 THEN
            RAISE EXCEPTION 'Bill % would go to zero or below. Choose another bill or use a credit note.', v_b->>'no';
          END IF;
          v_applied := jsonb_build_object('no', v_b->>'no', 'firm', v_b->>'firm', 'from', (v_b->>'amount')::numeric,
                                          'to', round((v_b->>'amount')::numeric + c.diff, 2));
          v_b := jsonb_set(v_b, '{amount}', to_jsonb(round((v_b->>'amount')::numeric + c.diff, 2)));
        END IF;
        v_new := v_new || v_b;
        v_i := v_i + 1;
      END LOOP;
    ELSE
      v_applied := jsonb_build_object('no', NULL, 'from', v_t.amount, 'to', round(v_t.amount + c.diff, 2));
    END IF;
    UPDATE public.lwb_tally_invoices
       SET amount = round(amount + c.diff, 2),
           bills = CASE WHEN jsonb_array_length(coalesce(bills,'[]'::jsonb)) > 0 THEN v_new ELSE bills END
     WHERE order_id = c.order_id;
  END IF;
  UPDATE public.lwb_bill_changes SET bill_applied = v_applied WHERE id = p_id;
  RETURN v_applied;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_change_apply(uuid) FROM PUBLIC, anon, authenticated;



DO $diag$
DECLARE v_id uuid; v_admin uuid; v_msg text; v_ctx text; v_res jsonb; v_info text;
BEGIN
  SELECT c.id INTO v_id FROM public.lwb_bill_changes c JOIN public.orders o ON o.id = c.order_id
   WHERE o.order_no = 'LXY-00441' AND c.status = 'WAITING' ORDER BY c.requested_at DESC LIMIT 1;
  SELECT p.id INTO v_admin FROM public.user_profiles p WHERE p.active AND lower(btrim(p.role)) = 'admin'
   ORDER BY (upper(p.full_name) LIKE '%MOHIT%') DESC LIMIT 1;
  SELECT 'st=' || coalesce(o.status::text,'?') || ' col=' || c.qty_col || ' lines=' ||
         (SELECT string_agg(coalesce(l->>'item_id','new') || ':' || coalesce(l->>'qty_old','') || '>' || coalesce(l->>'qty',''), ',') FROM jsonb_array_elements(c.lines) l)
         || ' cur=' || (SELECT string_agg(i.id::text || ':a' || coalesce(i.approved_qty::text,'-') || ':l' || coalesce(i.loaded_qty::text,'-'), ',') FROM public.order_items i WHERE i.order_id = c.order_id)
    INTO v_info FROM public.lwb_bill_changes c JOIN public.orders o ON o.id = c.order_id WHERE c.id = v_id;
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  SET CONSTRAINTS ALL IMMEDIATE;
  BEGIN
    v_res := public.lwb_bill_change_decide(v_id, true, NULL);
    v_msg := 'APPROVE WORKED ' || coalesce(v_res::text,'');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_ctx = PG_EXCEPTION_CONTEXT;
    v_msg := SQLSTATE || ' ' || SQLERRM || ' @@ ' || replace(coalesce(v_ctx,''), E'\n', ' | ');
  END;
  RAISE EXCEPTION 'DIAG id=% admin=% info=% RESULT: %', v_id IS NOT NULL, v_admin IS NOT NULL, v_info, replace(v_msg, E'\n', ' | ');
END
$diag$;
