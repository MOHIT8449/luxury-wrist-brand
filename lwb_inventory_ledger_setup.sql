-- LUXURY WRIST BRAND ERP — INVENTORY: OPENING + IN − OUT = CLOSING, AND A STOCK CHECK (6 Nov 2026)
--
-- Runs by itself when merged to main. Safe to run again. READ ONLY: no table is created, changed or deleted.
--
-- Mohit asked (6 Nov 2026): Inventory (Rajnigandha) looks wrong. Stock In, Stock Out and opening do not
-- add up: Stock Out showed 0 POs although POs were loaded, and the page never showed the opening of the
-- period or the closing, so nobody could check the saleable number.
--
-- lwb_inventory_ledger(p_from, p_to) gives the Inventory page one consistent picture per SKU (pieces):
--   * now_pcs         saleable stock now (lwb_live_stock, the number PO Entry also uses).
--   * opening_pcs     what the system had on the morning of p_from = now − every stock change since p_from.
--   * opening_entry   Opening Stock entries made inside the dates (fresh start, e.g. 4 Nov for Rajnigandha).
--   * in_pcs          purchase (Goods Inward) inside the dates.
--   * return_pcs      party returns into saleable (approved Driver Return), net. A PO change after loading
--                     is already in the loaded qty, so it is not counted twice (it still moves system stock).
--   * other_pcs       stock transfer / damage / loss / found (approved), and any other stock row, net.
--   * out_pcs         IC / CS actually loaded on vehicles inside the dates, × pcs per IC / CS.
--   * book_pcs        opening + opening entry + in + returns + other − out  (what the stock SHOULD be on p_to).
--   * system_pcs      what the system had at the end of p_to (now − changes after p_to).
--   * booked_pcs      POs given but not loaded yet (pending / approved / transport / loading; drafts never).
--   * diff_pcs        system − book. 0 = stock is right. Plus = the system did not take the sale out.
-- out_lines: every loaded PO line inside the dates (vehicle loaded time from Loading & Dispatch, else the
-- Admin "Loaded" mark date). Status after loading (loaded, invoiced, dispatched, delivered, closed ...) all
-- count; only cancelled / rejected POs are left out. Self pickup and Admin-marked POs are included.
-- link: does the live stock take loaded qty out by itself (view reads order_items, a trigger writes
-- stock rows on loading, or stock rows carry an order)? Shown on the page as a warning when it does not.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_inventory_ledger(p_from date, p_to date)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_from timestamptz; v_to timestamptz;
  v_base regclass := coalesce(to_regclass('public.lwb_live_stock_base'), to_regclass('public.lwb_live_stock'));
  v_def text := '';
  v_view_uses_orders boolean := false;
  v_trigger boolean := false;
  v_mv_orders boolean := false;
  v_mv_out boolean := false;
  v_rows jsonb; v_out jsonb; v_types jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','warehouse','accounts')) THEN
    RAISE EXCEPTION 'Inventory: Admin, Sales Head, Godown or Accounts only';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN RAISE EXCEPTION 'Select a valid From and To date'; END IF;
  IF p_to - p_from > 400 THEN RAISE EXCEPTION 'Choose 400 days or less'; END IF;
  v_from := p_from::timestamp AT TIME ZONE 'Asia/Kolkata';
  v_to := (p_to + 1)::timestamp AT TIME ZONE 'Asia/Kolkata';   -- end of p_to (exclusive)

  -- Does live stock follow loading by itself?
  IF v_base IS NOT NULL THEN
    v_def := coalesce(pg_get_viewdef(v_base), '');
    WITH RECURSIVE dep(oid) AS (
      SELECT v_base::oid
      UNION
      SELECT d.refobjid FROM dep
      JOIN pg_rewrite r ON r.ev_class = dep.oid
      JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid AND d.refclassid = 'pg_class'::regclass
      WHERE d.refobjid <> dep.oid)
    SELECT EXISTS (SELECT 1 FROM dep WHERE dep.oid IN (coalesce(to_regclass('public.order_items'),0::oid), coalesce(to_regclass('public.dispatch_assignments'),0::oid)))
      INTO v_view_uses_orders;
    v_view_uses_orders := v_view_uses_orders OR v_def ~* '(order_items|loaded_qty|dispatch_assignments)';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM pg_trigger t JOIN pg_proc f ON f.oid = t.tgfoid
    WHERE NOT t.tgisinternal
      AND t.tgrelid IN (coalesce(to_regclass('public.order_items'),0::oid), coalesce(to_regclass('public.orders'),0::oid),
                        coalesce(to_regclass('public.dispatch_assignments'),0::oid))
      AND f.prosrc ~* 'lwb_inventory_movements')
    INTO v_trigger;

  -- Stock rows (Opening, purchase, anything else) as they are saved.
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.lwb_inv_mv(sku_id uuid, mtype text, pcs numeric, at timestamptz, has_order boolean) ON COMMIT DROP;
  DELETE FROM pg_temp.lwb_inv_mv WHERE true;  -- scratch rows of an earlier call (WHERE: Supabase safeupdate refuses a bare DELETE)
  IF to_regclass('public.lwb_inventory_movements') IS NOT NULL THEN
    INSERT INTO pg_temp.lwb_inv_mv
    SELECT nullif(j->>'sku_id','')::uuid,
           upper(btrim(coalesce(j->>'movement_type',''))),
           coalesce(nullif(j->>'quantity_pcs','')::numeric, nullif(j->>'qty_pcs','')::numeric, nullif(j->>'pcs','')::numeric, 0),
           coalesce(nullif(j->>'created_at','')::timestamptz, nullif(j->>'movement_at','')::timestamptz,
                    (nullif(j->>'movement_date','')::date)::timestamp AT TIME ZONE 'Asia/Kolkata'),
           nullif(j->>'order_id','') IS NOT NULL
    FROM public.lwb_inventory_movements m, LATERAL to_jsonb(m) j
    WHERE upper(coalesce(j->>'stock_bucket','SALEABLE')) = 'SALEABLE';
  END IF;
  SELECT EXISTS (SELECT 1 FROM pg_temp.lwb_inv_mv WHERE has_order),
         EXISTS (SELECT 1 FROM pg_temp.lwb_inv_mv WHERE pcs < 0 AND mtype ~ '(DISPATCH|SALE|LOAD|OUT)')
    INTO v_mv_orders, v_mv_out;
  SELECT coalesce(jsonb_agg(jsonb_build_object('type', t.mtype, 'rows', t.n, 'pcs', t.pcs) ORDER BY t.mtype), '[]'::jsonb)
    INTO v_types
    FROM (SELECT mtype, count(*) n, sum(pcs) pcs FROM pg_temp.lwb_inv_mv GROUP BY 1) t;

  -- Approved stock transfer / return / PO change moves that touch saleable.
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.lwb_inv_sx(sku_id uuid, kind text, pcs numeric, at timestamptz) ON COMMIT DROP;
  DELETE FROM pg_temp.lwb_inv_sx WHERE true;  -- scratch rows of an earlier call (WHERE: Supabase safeupdate refuses a bare DELETE)
  IF to_regclass('public.lwb_stock_moves') IS NOT NULL THEN
    INSERT INTO pg_temp.lwb_inv_sx
    SELECT m.sku_id, CASE WHEN m.kind = 'BILL_CHANGE' THEN 'BILL_CHANGE'
                          WHEN m.from_bucket = 'PARTY' OR m.to_bucket = 'PARTY' THEN 'RETURN' ELSE 'OTHER' END,
           CASE WHEN m.to_bucket = 'SALEABLE' THEN m.qty_pcs ELSE -m.qty_pcs END,
           coalesce(m.decided_at, m.move_date::timestamp AT TIME ZONE 'Asia/Kolkata')
    FROM public.lwb_stock_moves m
    WHERE m.status = 'APPROVED' AND (m.to_bucket = 'SALEABLE' OR m.from_bucket = 'SALEABLE');
  END IF;

  -- Loaded PO lines (cases / IC) with the time the vehicle was loaded.
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.lwb_inv_out(order_id uuid, order_no text, party text, status text, sku_id uuid,
    sku_name text, cases numeric, pcs numeric, at timestamptz) ON COMMIT DROP;
  DELETE FROM pg_temp.lwb_inv_out WHERE true;  -- scratch rows of an earlier call (WHERE: Supabase safeupdate refuses a bare DELETE)
  INSERT INTO pg_temp.lwb_inv_out
  SELECT o.id, o.order_no::text, o.customer_name::text, o.status::text, s.id, coalesce(s.sku_name, j->>'sku_name'),
         nullif(j->>'loaded_qty','')::numeric,
         nullif(j->>'loaded_qty','')::numeric * greatest(coalesce(s.pcs_per_case,1),1), w.at
  FROM public.orders o
  CROSS JOIN LATERAL (
    SELECT coalesce(
      (SELECT max(a.loading_completed_at) FROM public.dispatch_assignments a WHERE a.order_id = o.id),
      (SELECT CASE WHEN mk.mark_date = (mk.marked_at AT TIME ZONE 'Asia/Kolkata')::date THEN mk.marked_at
                   ELSE (mk.mark_date + time '12:00') AT TIME ZONE 'Asia/Kolkata' END
         FROM public.lwb_admin_order_marks mk WHERE mk.order_id = o.id AND mk.kind = 'LOADED' LIMIT 1)) AS at) w
  JOIN public.order_items i ON i.order_id = o.id
  CROSS JOIN LATERAL to_jsonb(i) j
  LEFT JOIN LATERAL (
    SELECT x.id, x.sku_name, x.pcs_per_case FROM public.sku_master x
    WHERE x.id::text = j->>'sku_id' OR upper(btrim(x.sku_name)) = upper(btrim(coalesce(j->>'sku_name','')))
    ORDER BY coalesce(x.id::text = j->>'sku_id', false) DESC, coalesce(x.is_active, true) DESC LIMIT 1) s ON true
  WHERE w.at IS NOT NULL AND w.at >= v_from
    AND lower(btrim(coalesce(o.status::text,''))) NOT IN ('cancelled','canceled','rejected','draft','deleted')
    AND coalesce(nullif(j->>'loaded_qty','')::numeric, 0) > 0;

  -- Booked: POs given (pending approval, approved, transport given, loading) but not loaded yet.
  -- Drafts are not POs (own table), so they never count. Qty = approved qty, else ordered qty, less what is loaded.
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.lwb_inv_bk(sku_id uuid, pcs numeric) ON COMMIT DROP;
  DELETE FROM pg_temp.lwb_inv_bk WHERE true;  -- scratch rows of an earlier call (WHERE: Supabase safeupdate refuses a bare DELETE)
  INSERT INTO pg_temp.lwb_inv_bk
  SELECT s.id, greatest(coalesce(nullif(j->>'approved_qty','')::numeric, nullif(j->>'ordered_qty','')::numeric, 0)
                        - coalesce(nullif(j->>'loaded_qty','')::numeric, 0), 0) * greatest(coalesce(s.pcs_per_case,1),1)
  FROM public.orders o
  JOIN public.order_items i ON i.order_id = o.id
  CROSS JOIN LATERAL to_jsonb(i) j
  JOIN LATERAL (
    SELECT x.id, x.pcs_per_case FROM public.sku_master x
    WHERE x.id::text = j->>'sku_id' OR upper(btrim(x.sku_name)) = upper(btrim(coalesce(j->>'sku_name','')))
    ORDER BY coalesce(x.id::text = j->>'sku_id', false) DESC, coalesce(x.is_active, true) DESC LIMIT 1) s ON true
  WHERE lower(btrim(coalesce(o.status::text,''))) NOT IN ('cancelled','canceled','rejected','draft','deleted',
          'loaded','invoiced','dispatched','delivered','partially_delivered','partial','closed','completed','returned')
    AND NOT EXISTS (SELECT 1 FROM public.dispatch_assignments a WHERE a.order_id = o.id AND a.loading_completed_at IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM public.lwb_admin_order_marks mk WHERE mk.order_id = o.id AND mk.kind = 'LOADED');

  SELECT coalesce(jsonb_agg(jsonb_build_object('order_no', x.order_no, 'party', x.party, 'status', x.status,
           'sku_id', x.sku_id, 'sku_name', x.sku_name, 'cases', x.cases, 'pcs', x.pcs, 'at', x.at) ORDER BY x.at DESC), '[]'::jsonb)
    INTO v_out FROM pg_temp.lwb_inv_out x WHERE x.at < v_to;

  WITH live AS (
    SELECT l.sku_id::uuid AS sku_id, sum(coalesce(l.saleable_pcs,0))::numeric AS now_pcs FROM public.lwb_live_stock l
    WHERE l.sku_id IS NOT NULL GROUP BY 1),
  mv AS (
    SELECT sku_id,
      sum(pcs) FILTER (WHERE at >= v_from) AS since_from,
      sum(pcs) FILTER (WHERE at >= v_to) AS after_to,
      sum(pcs) FILTER (WHERE at >= v_from AND at < v_to AND mtype = 'OPENING') AS opening_entry,
      sum(pcs) FILTER (WHERE at >= v_from AND at < v_to AND mtype <> 'OPENING' AND mtype ~ '(PURCHASE|INWARD)') AS in_pcs,
      sum(pcs) FILTER (WHERE at >= v_from AND at < v_to AND mtype <> 'OPENING' AND mtype !~ '(PURCHASE|INWARD)'
                         AND NOT (has_order OR (pcs < 0 AND mtype ~ '(DISPATCH|SALE|LOAD|OUT)'))) AS other_pcs
    FROM pg_temp.lwb_inv_mv WHERE sku_id IS NOT NULL GROUP BY 1),
  sx AS (
    SELECT sku_id,
      sum(pcs) FILTER (WHERE at >= v_from) AS since_from,
      sum(pcs) FILTER (WHERE at >= v_to) AS after_to,
      sum(pcs) FILTER (WHERE at >= v_from AND at < v_to AND kind = 'RETURN') AS return_pcs,
      sum(pcs) FILTER (WHERE at >= v_from AND at < v_to AND kind = 'OTHER') AS other_pcs
    FROM pg_temp.lwb_inv_sx GROUP BY 1),
  ot AS (
    SELECT sku_id,
      sum(pcs) AS since_from,
      sum(pcs) FILTER (WHERE at >= v_to) AS after_to,
      sum(pcs) FILTER (WHERE at < v_to) AS out_pcs
    FROM pg_temp.lwb_inv_out WHERE sku_id IS NOT NULL GROUP BY 1),
  bk AS (SELECT sku_id, sum(pcs) AS booked_pcs FROM pg_temp.lwb_inv_bk GROUP BY 1),
  ids AS (SELECT sku_id FROM live UNION SELECT sku_id FROM mv UNION SELECT sku_id FROM sx UNION SELECT sku_id FROM ot),
  r AS (
    SELECT ids.sku_id, coalesce(live.now_pcs,0) AS now_pcs,
      -- system changes = stock rows + approved moves (+ loaded qty, when the live view reads it itself)
      coalesce(mv.since_from,0) + coalesce(sx.since_from,0) - CASE WHEN v_view_uses_orders THEN coalesce(ot.since_from,0) ELSE 0 END AS sys_since_from,
      coalesce(mv.after_to,0) + coalesce(sx.after_to,0) - CASE WHEN v_view_uses_orders THEN coalesce(ot.after_to,0) ELSE 0 END AS sys_after_to,
      coalesce(mv.opening_entry,0) AS opening_entry, coalesce(mv.in_pcs,0) AS in_pcs,
      coalesce(sx.return_pcs,0) AS return_pcs, coalesce(mv.other_pcs,0) + coalesce(sx.other_pcs,0) AS other_pcs,
      coalesce(ot.out_pcs,0) AS out_pcs, coalesce(bk.booked_pcs,0) AS booked_pcs
    FROM ids LEFT JOIN live USING (sku_id) LEFT JOIN mv USING (sku_id) LEFT JOIN sx USING (sku_id) LEFT JOIN ot USING (sku_id) LEFT JOIN bk USING (sku_id))
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'sku_id', r.sku_id, 'now_pcs', r.now_pcs,
      'opening_pcs', r.now_pcs - r.sys_since_from,
      'opening_entry', r.opening_entry, 'in_pcs', r.in_pcs, 'return_pcs', r.return_pcs, 'other_pcs', r.other_pcs,
      'out_pcs', r.out_pcs, 'booked_pcs', r.booked_pcs,
      'book_pcs', r.now_pcs - r.sys_since_from + r.opening_entry + r.in_pcs + r.return_pcs + r.other_pcs - r.out_pcs,
      'system_pcs', r.now_pcs - r.sys_after_to)), '[]'::jsonb)
    INTO v_rows FROM r;

  RETURN jsonb_build_object(
    'from', p_from, 'to', p_to,
    'link', jsonb_build_object('view_reads_orders', v_view_uses_orders, 'loading_trigger', v_trigger,
                               'stock_rows_with_order', v_mv_orders, 'stock_rows_out', v_mv_out,
                               'follows_loading', v_view_uses_orders OR v_trigger OR v_mv_orders OR v_mv_out,
                               'movement_types', v_types),
    'rows', v_rows, 'out_lines', v_out);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_inventory_ledger(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_inventory_ledger(date, date) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'inventory ledger' AS item, (to_regprocedure('public.lwb_inventory_ledger(date,date)') IS NOT NULL)::text AS ok;
