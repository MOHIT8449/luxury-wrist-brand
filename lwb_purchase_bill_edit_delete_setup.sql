-- LUXURY WRIST BRAND ERP — EDIT / DELETE AN OLD PURCHASE BILL (Goods Inward) (6 Nov 2026)
--
-- Runs by itself when merged to main. Safe to run again. Deletes nothing by itself.
--
-- Mohit (6 Nov 2026): an old purchase bill could not be changed or removed (the "Edit" on the
-- Purchase List only edits the vehicle check). Admin now gets:
--   * lwb_purchase_bill_preview(bill)  what a delete / edit will do: SKU lines, stock now, stock
--                                      after, linked check / claim / photos, and if it is allowed.
--   * lwb_purchase_bill_delete(bill, reason)
--        removes the bill, its SKU lines and the stock rows it added (so live stock goes down by
--        exactly what the bill added, carton fix rows too), cancels its vehicle-check stock moves,
--        removes the check / claim, hides its photos, cancels open photo tasks, removes the
--        "received from company" pallet / sheet entry it made. All in one transaction.
--   * lwb_purchase_bill_edit(bill, reason, header, items)
--        posts the corrected bill through the same lwb_post_goods_inward(_mrp) as Goods Inward
--        (same GST, carton and stock rules), moves the check / claim, photos, tasks, vehicle time
--        and godown manager to it, then removes the old bill and its stock rows. One transaction:
--        if anything fails, nothing changes.
-- Every delete / edit keeps a full copy of the old bill, lines and stock rows in
-- lwb_purchase_bill_log (who, when, reason).
--
-- Stock rows: lwb_inventory_movements was made outside this repo, so its link to the bill is found
-- by column name (inward_id / goods_inward_id / reference_id / ref_id / source_id / ..., or a link
-- to the bill's lines). If no link column exists, rows of type PURCHASE / INWARD whose reference
-- no. is the invoice no. and SKU is on the bill are used. When no stock row is found and live
-- stock does not read the bill lines itself, the delete is refused (nothing changed).

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_purchase_bill_log (
  id bigserial PRIMARY KEY,
  action text NOT NULL CHECK (action IN ('DELETE','EDIT')),
  inward_id uuid NOT NULL,
  new_inward_id uuid,
  invoice_no text,
  supplier_name text,
  reason text NOT NULL,
  bill jsonb,
  items jsonb,
  stock_rows jsonb,
  other jsonb,
  done_by uuid DEFAULT auth.uid(),
  done_by_name text,
  done_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_purchase_bill_log_inward_idx ON public.lwb_purchase_bill_log (inward_id);
ALTER TABLE public.lwb_purchase_bill_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_purchase_bill_log FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_purchase_bill_log_id_seq FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_pbe_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) = 'admin');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pbe_admin() FROM PUBLIC, anon, authenticated;

-- Stock rows (lwb_inventory_movements, as jsonb) that this bill added.
CREATE OR REPLACE FUNCTION public.lwb_pbe_stock_rows(p_inward uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_out jsonb := '[]'::jsonb;
  v_part jsonb;
  c text;
  v_inv text;
  v_at timestamptz;
  v_found boolean := false;
  v_one jsonb;
  l record;
BEGIN
  IF to_regclass('public.lwb_inventory_movements') IS NULL THEN RETURN v_out; END IF;
  SELECT g.invoice_no, g.created_at INTO v_inv, v_at FROM public.lwb_goods_inward g WHERE g.id = p_inward;

  -- 1. A column that holds the bill id (by name, or a foreign key to lwb_goods_inward).
  FOR c IN
    SELECT DISTINCT col FROM (
      SELECT k.column_name::text AS col FROM information_schema.columns k
      WHERE k.table_schema = 'public' AND k.table_name = 'lwb_inventory_movements'
        AND k.column_name IN ('inward_id','goods_inward_id','purchase_id','purchase_inward_id','reference_id','ref_id',
                              'source_id','document_id','reference_uuid','ref_uuid')
      UNION
      SELECT a.attname::text FROM pg_constraint f
      JOIN pg_attribute a ON a.attrelid = f.conrelid AND a.attnum = ANY(f.conkey)
      WHERE f.contype = 'f' AND f.conrelid = 'public.lwb_inventory_movements'::regclass
        AND f.confrelid = 'public.lwb_goods_inward'::regclass) x
  LOOP
    v_found := true;
    EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(m)), ''[]''::jsonb) FROM public.lwb_inventory_movements m WHERE m.%I::text = $1', c)
      INTO v_part USING p_inward::text;
    v_out := v_out || v_part;
  END LOOP;

  -- 2. A column that holds one of the bill's line ids.
  IF to_regclass('public.lwb_goods_inward_items') IS NOT NULL THEN
    FOR c IN
      SELECT DISTINCT col FROM (
        SELECT k.column_name::text AS col FROM information_schema.columns k
        WHERE k.table_schema = 'public' AND k.table_name = 'lwb_inventory_movements'
          AND k.column_name IN ('inward_item_id','goods_inward_item_id','purchase_item_id')
        UNION
        SELECT a.attname::text FROM pg_constraint f
        JOIN pg_attribute a ON a.attrelid = f.conrelid AND a.attnum = ANY(f.conkey)
        WHERE f.contype = 'f' AND f.conrelid = 'public.lwb_inventory_movements'::regclass
          AND f.confrelid = 'public.lwb_goods_inward_items'::regclass) x
    LOOP
      v_found := true;
      EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(m)), ''[]''::jsonb) FROM public.lwb_inventory_movements m
                      WHERE m.%I::text IN (SELECT i.id::text FROM public.lwb_goods_inward_items i WHERE i.inward_id = $1)', c)
        INTO v_part USING p_inward;
      v_out := v_out || v_part;
    END LOOP;
  END IF;

  -- 3. Nothing found by id: purchase rows of the bill's SKUs whose text (reference no., notes, ...)
  --    holds the invoice no.
  IF jsonb_array_length(v_out) = 0 AND length(btrim(coalesce(v_inv,''))) >= 4 THEN
    SELECT coalesce(jsonb_agg(j), '[]'::jsonb) INTO v_part
    FROM public.lwb_inventory_movements m CROSS JOIN LATERAL to_jsonb(m) j
    WHERE upper(coalesce(j->>'movement_type','')) ~ '(PURCHASE|INWARD|GRN|RECEIPT)'
      AND j->>'sku_id' IN (SELECT i.sku_id::text FROM public.lwb_goods_inward_items i WHERE i.inward_id = p_inward)
      AND EXISTS (SELECT 1 FROM jsonb_each_text(j) e
                  WHERE e.key NOT IN ('id','sku_id','sku_name','movement_type','stock_bucket','created_at','updated_at')
                    AND position(upper(btrim(v_inv)) IN upper(coalesce(e.value,''))) > 0);
    v_out := v_out || v_part;
  END IF;

  -- 4. Still nothing (no link saved at all): for each bill line, the purchase row of that SKU with the
  --    same pieces, saved within 10 minutes of the bill (closest first, each row used once).
  IF jsonb_array_length(v_out) = 0 AND v_at IS NOT NULL THEN
    FOR l IN
      SELECT i.sku_id::text AS sku,
             coalesce(nullif(to_jsonb(i)->>'quantity_pcs','')::numeric,
                      coalesce(nullif(to_jsonb(i)->>'cases','')::numeric,0) * greatest(coalesce(s.pcs_per_case,1),1)
                      + coalesce(nullif(to_jsonb(i)->>'pcs','')::numeric,0)) AS pcs
      FROM public.lwb_goods_inward_items i LEFT JOIN public.sku_master s ON s.id::text = i.sku_id::text
      WHERE i.inward_id = p_inward
    LOOP
      SELECT j INTO v_one
      FROM public.lwb_inventory_movements m CROSS JOIN LATERAL to_jsonb(m) j
      WHERE upper(coalesce(j->>'movement_type','')) ~ '(PURCHASE|INWARD|GRN|RECEIPT)'
        AND upper(coalesce(j->>'stock_bucket','SALEABLE')) = 'SALEABLE'
        AND j->>'sku_id' = l.sku
        AND coalesce(nullif(j->>'quantity_pcs','')::numeric, nullif(j->>'qty_pcs','')::numeric, nullif(j->>'pcs','')::numeric) = l.pcs
        AND coalesce(nullif(j->>'created_at','')::timestamptz, nullif(j->>'movement_at','')::timestamptz) BETWEEN v_at - interval '10 minutes' AND v_at + interval '10 minutes'
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_out) x WHERE x->>'id' = j->>'id')
      ORDER BY abs(extract(epoch FROM coalesce(nullif(j->>'created_at','')::timestamptz, nullif(j->>'movement_at','')::timestamptz) - v_at))
      LIMIT 1;
      IF v_one IS NOT NULL THEN v_out := v_out || jsonb_build_array(v_one); END IF;
      v_one := NULL;
    END LOOP;
  END IF;

  -- 5. "Carton to IC" fix rows added for a row found above (lwb_purchase_carton_fix_setup.sql).
  IF jsonb_array_length(v_out) > 0 AND to_regclass('public.lwb_purchase_carton_fix') IS NOT NULL THEN
    EXECUTE 'SELECT coalesce(jsonb_agg(to_jsonb(m)), ''[]''::jsonb) FROM public.lwb_inventory_movements m
             WHERE m.id::text IN (SELECT substr(a.movement_id, 7) FROM public.lwb_purchase_carton_fix o
                                  JOIN public.lwb_purchase_carton_fix a ON a.movement_id LIKE ''added:%'' AND a.sku_id = o.sku_id AND a.fixed_at = o.fixed_at
                                  WHERE o.movement_id IN (SELECT r->>''id'' FROM jsonb_array_elements($1) r))'
      INTO v_part USING v_out;
    v_out := v_out || v_part;
  END IF;

  -- one entry per row
  SELECT coalesce(jsonb_agg(r ORDER BY r->>'id'), '[]'::jsonb) INTO v_out
  FROM (SELECT DISTINCT ON (r->>'id') r FROM jsonb_array_elements(v_out) r ORDER BY r->>'id') d;
  RETURN v_out;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pbe_stock_rows(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_pbe_row_pcs(r jsonb)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT coalesce(nullif(r->>'quantity_pcs','')::numeric, nullif(r->>'qty_pcs','')::numeric, nullif(r->>'pcs','')::numeric, 0)
         * CASE WHEN upper(coalesce(r->>'stock_bucket','SALEABLE')) = 'SALEABLE' THEN 1 ELSE 0 END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pbe_row_pcs(jsonb) FROM PUBLIC, anon, authenticated;

-- Does live stock read the bill lines itself (then removing the lines is enough)?
CREATE OR REPLACE FUNCTION public.lwb_pbe_stock_reads_items()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_base regclass := coalesce(to_regclass('public.lwb_live_stock_base'), to_regclass('public.lwb_live_stock'));
  v boolean := false;
BEGIN
  IF v_base IS NULL OR to_regclass('public.lwb_goods_inward_items') IS NULL THEN RETURN false; END IF;
  WITH RECURSIVE dep(oid) AS (
    SELECT v_base::oid
    UNION
    SELECT d.refobjid FROM dep
    JOIN pg_rewrite r ON r.ev_class = dep.oid
    JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid AND d.refclassid = 'pg_class'::regclass
    WHERE d.refobjid <> dep.oid)
  SELECT EXISTS (SELECT 1 FROM dep WHERE dep.oid = 'public.lwb_goods_inward_items'::regclass) INTO v;
  RETURN v;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pbe_stock_reads_items() FROM PUBLIC, anon, authenticated;

-- Saleable stock of an SKU now (NULL when live stock is not there).
CREATE OR REPLACE FUNCTION public.lwb_pbe_stock_now(p_sku text)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v numeric;
BEGIN
  IF to_regclass('public.lwb_live_stock') IS NULL THEN RETURN NULL; END IF;
  EXECUTE 'SELECT sum(nullif(to_jsonb(s)->>''saleable_pcs'','''')::numeric) FROM public.lwb_live_stock s WHERE s.sku_id::text = $1'
    INTO v USING p_sku;
  RETURN v;
EXCEPTION WHEN others THEN RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pbe_stock_now(text) FROM PUBLIC, anon, authenticated;

-- What a delete / edit of this bill will do (Admin).
CREATE OR REPLACE FUNCTION public.lwb_purchase_bill_preview(p_inward uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  g jsonb;
  v_rows jsonb;
  v_lines jsonb;
  v_reads boolean := public.lwb_pbe_stock_reads_items();
  v_check jsonb := NULL;
  v_docs int := 0;
  v_ok boolean;
  v_why text := NULL;
BEGIN
  IF NOT public.lwb_pbe_admin() THEN RAISE EXCEPTION 'Only Admin can edit or delete a purchase bill'; END IF;
  SELECT to_jsonb(x) INTO g FROM public.lwb_goods_inward x WHERE x.id = p_inward;
  IF g IS NULL THEN RAISE EXCEPTION 'Purchase bill not found'; END IF;
  v_rows := public.lwb_pbe_stock_rows(p_inward);

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'sku_id', l.sku_id, 'sku_name', l.sku_name, 'pcs_per_case', l.pack, 'bill_pcs', l.bill_pcs,
           'stock_pcs', l.row_pcs, 'stock_now', l.now_pcs,
           'stock_after', CASE WHEN l.now_pcs IS NULL THEN NULL ELSE l.now_pcs - CASE WHEN v_reads AND l.row_pcs = 0 THEN l.bill_pcs ELSE l.row_pcs END END)
         ORDER BY l.sku_name), '[]'::jsonb)
  INTO v_lines
  FROM (
    SELECT b.sku_id, max(b.sku_name) AS sku_name, max(b.pack) AS pack, sum(b.pcs) AS bill_pcs,
           coalesce((SELECT sum(public.lwb_pbe_row_pcs(r)) FROM jsonb_array_elements(v_rows) r WHERE r->>'sku_id' = b.sku_id::text), 0) AS row_pcs,
           public.lwb_pbe_stock_now(b.sku_id::text) AS now_pcs
    FROM (
      SELECT i.sku_id, coalesce(s.sku_name, i.sku_id::text) AS sku_name, greatest(coalesce(s.pcs_per_case,1),1) AS pack,
             coalesce(nullif(to_jsonb(i)->>'quantity_pcs','')::numeric,
                      coalesce(nullif(to_jsonb(i)->>'cases','')::numeric,0) * greatest(coalesce(s.pcs_per_case,1),1)
                      + coalesce(nullif(to_jsonb(i)->>'pcs','')::numeric,0)) AS pcs
      FROM public.lwb_goods_inward_items i
      LEFT JOIN public.sku_master s ON s.id::text = i.sku_id::text
      WHERE i.inward_id = p_inward) b
    GROUP BY b.sku_id) l;

  IF to_regclass('public.lwb_purchase_checks') IS NOT NULL THEN
    SELECT jsonb_build_object('has_damage', c.has_damage, 'claim_status', c.claim_status) INTO v_check
    FROM public.lwb_purchase_checks c WHERE c.inward_id = p_inward;
  END IF;
  IF to_regclass('public.lwb_documents') IS NOT NULL THEN
    SELECT count(*) INTO v_docs FROM public.lwb_documents d
    WHERE d.entity_type = 'PURCHASE_BILL' AND d.entity_id = p_inward::text AND d.removed_at IS NULL;
  END IF;

  v_ok := jsonb_array_length(v_rows) > 0 OR v_reads OR to_regclass('public.lwb_inventory_movements') IS NULL;
  IF NOT v_ok THEN
    v_why := 'The stock rows of this bill were not found, so stock cannot be taken back. Nothing was changed. Send this message to the developer.'
      || E'\n\nStock columns: ' || coalesce((SELECT string_agg(k.column_name::text, ', ' ORDER BY k.ordinal_position) FROM information_schema.columns k
                                  WHERE k.table_schema = 'public' AND k.table_name = 'lwb_inventory_movements'), '-')
      || E'\nTypes: ' || coalesce((SELECT string_agg(t || ' ' || n, ', ') FROM (SELECT to_jsonb(m)->>'movement_type' AS t, count(*) AS n
                                  FROM public.lwb_inventory_movements m GROUP BY 1 ORDER BY 2 DESC LIMIT 8) x), '-')
      || E'\nStock view reads bill lines: ' || v_reads::text;
  END IF;

  RETURN jsonb_build_object(
    'id', g->>'id', 'invoice_no', g->>'invoice_no', 'supplier_name', g->>'supplier_name',
    'invoice_date', g->>'invoice_date', 'received_date', g->>'received_date',
    'lines', v_lines, 'stock_rows', jsonb_array_length(v_rows),
    'stock_reads_lines', v_reads, 'check', v_check, 'docs', v_docs,
    'can', v_ok, 'why', v_why);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_bill_preview(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_bill_preview(uuid) TO authenticated;

-- Removes the bill, its lines and stock rows. p_move_to: the corrected bill (edit) that takes over the
-- check / claim, photos and tasks; NULL = delete (those are removed / cancelled).

CREATE OR REPLACE FUNCTION public.lwb_pbe_remove(p_inward uuid, p_move_to uuid, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  g public.lwb_goods_inward%ROWTYPE;
  v_other jsonb := '{}'::jsonb;
  v_part jsonb;
  v_n int;
  f record;
  v_inv_new text;
  v_has_col boolean;
BEGIN
  SELECT * INTO g FROM public.lwb_goods_inward x WHERE x.id = p_inward;
  IF NOT FOUND THEN RAISE EXCEPTION 'Purchase bill not found'; END IF;
  IF p_move_to IS NOT NULL THEN SELECT x.invoice_no INTO v_inv_new FROM public.lwb_goods_inward x WHERE x.id = p_move_to; END IF;

  -- 1. Stock rows the bill added (live stock goes down by exactly that).
  IF jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 0 THEN
    EXECUTE 'DELETE FROM public.lwb_inventory_movements m WHERE m.id::text IN (SELECT r->>''id'' FROM jsonb_array_elements($1) r)' USING p_rows;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_other := v_other || jsonb_build_object('stock_rows_removed', v_n);
  END IF;

  -- 2. Vehicle-check stock moves (damage / leakage / shortage out of saleable).
  SELECT EXISTS (SELECT 1 FROM information_schema.columns k WHERE k.table_schema = 'public'
                 AND k.table_name = 'lwb_stock_moves' AND k.column_name = 'inward_id') INTO v_has_col;
  IF v_has_col THEN
    IF p_move_to IS NULL THEN
      EXECUTE 'UPDATE public.lwb_stock_moves SET status = ''CANCELLED'', decided_at = now(), decided_by = auth.uid(),
               decision_note = ''Purchase bill deleted'' WHERE inward_id = $1 AND status IN (''APPROVED'',''PENDING'')' USING p_inward;
    ELSE
      EXECUTE 'UPDATE public.lwb_stock_moves SET inward_id = $2 WHERE inward_id = $1' USING p_inward, p_move_to;
    END IF;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_other := v_other || jsonb_build_object('check_stock_moves', v_n);
  END IF;

  -- 3. Vehicle check / claim: kept on the corrected bill, removed with a delete (copy in the log).
  IF to_regclass('public.lwb_purchase_checks') IS NOT NULL THEN
    EXECUTE 'SELECT coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object(''items'',
               (SELECT coalesce(jsonb_agg(to_jsonb(i)), ''[]''::jsonb) FROM public.lwb_purchase_check_items i WHERE i.check_id = c.id))), ''[]''::jsonb)
             FROM public.lwb_purchase_checks c WHERE c.inward_id = $1' INTO v_part USING p_inward;
    v_other := v_other || jsonb_build_object('checks', v_part);
    IF p_move_to IS NULL THEN
      EXECUTE 'DELETE FROM public.lwb_purchase_checks WHERE inward_id = $1' USING p_inward;
    ELSE
      EXECUTE 'UPDATE public.lwb_purchase_checks SET inward_id = $2, updated_at = now() WHERE inward_id = $1' USING p_inward, p_move_to;
      -- a damage line of an SKU no longer on the bill goes
      EXECUTE 'DELETE FROM public.lwb_purchase_check_items i USING public.lwb_purchase_checks c
               WHERE c.id = i.check_id AND c.inward_id = $1 AND i.sku_id IS NOT NULL
                 AND i.sku_id::text NOT IN (SELECT x.sku_id::text FROM public.lwb_goods_inward_items x WHERE x.inward_id = $1)' USING p_move_to;
    END IF;
  END IF;

  -- 4. Bill copy / photos: moved, or hidden (files stay in storage).
  IF to_regclass('public.lwb_documents') IS NOT NULL THEN
    IF p_move_to IS NULL THEN
      EXECUTE 'UPDATE public.lwb_documents SET removed_at = now(), removed_by = auth.uid()
               WHERE entity_type = ''PURCHASE_BILL'' AND entity_id = $1 AND removed_at IS NULL' USING p_inward::text;
    ELSE
      EXECUTE 'UPDATE public.lwb_documents SET entity_id = $2 WHERE entity_type = ''PURCHASE_BILL'' AND entity_id = $1'
        USING p_inward::text, p_move_to::text;
    END IF;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_other := v_other || jsonb_build_object('documents', v_n);
  END IF;

  -- 5. Photo tasks and bells that point to the bill.
  IF EXISTS (SELECT 1 FROM information_schema.columns k WHERE k.table_schema = 'public' AND k.table_name = 'lwb_tasks' AND k.column_name = 'ref_id') THEN
    IF p_move_to IS NULL THEN
      EXECUTE 'UPDATE public.lwb_tasks SET status = ''CANCELLED'', last_activity_at = now()
               WHERE ref_type = ''PURCHASE_BILL'' AND ref_id = $1 AND status IN (''OPEN'',''IN_PROGRESS'')' USING p_inward::text;
    ELSE
      EXECUTE 'UPDATE public.lwb_tasks SET ref_id = $2 WHERE ref_type = ''PURCHASE_BILL'' AND ref_id = $1' USING p_inward::text, p_move_to::text;
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns k WHERE k.table_schema = 'public' AND k.table_name = 'erp_notifications' AND k.column_name = 'ref_id') THEN
    IF p_move_to IS NULL THEN
      EXECUTE 'DELETE FROM public.erp_notifications WHERE ref_type = ''PURCHASE_BILL'' AND ref_id = $1' USING p_inward::text;
    ELSE
      EXECUTE 'UPDATE public.erp_notifications SET ref_id = $2 WHERE ref_type = ''PURCHASE_BILL'' AND ref_id = $1' USING p_inward::text, p_move_to::text;
    END IF;
  END IF;

  -- 6. Pallets / sheets "received from company" saved with the bill.
  IF to_regclass('public.lwb_sp_entries') IS NOT NULL THEN
    IF p_move_to IS NULL THEN
      EXECUTE 'SELECT coalesce(jsonb_agg(to_jsonb(e)), ''[]''::jsonb) FROM public.lwb_sp_entries e
               WHERE e.entry_type = ''COMPANY_IN'' AND e.ref_no = $1 AND e.note = ''Purchase bill · '' || $2' INTO v_part USING g.invoice_no, g.supplier_name;
      v_other := v_other || jsonb_build_object('pallet_entries', v_part);
      EXECUTE 'DELETE FROM public.lwb_sp_entries e WHERE e.entry_type = ''COMPANY_IN'' AND e.ref_no = $1 AND e.note = ''Purchase bill · '' || $2'
        USING g.invoice_no, g.supplier_name;
    ELSIF v_inv_new IS DISTINCT FROM g.invoice_no THEN
      EXECUTE 'UPDATE public.lwb_sp_entries e SET ref_no = $3 WHERE e.entry_type = ''COMPANY_IN'' AND e.ref_no = $1 AND e.note = ''Purchase bill · '' || $2'
        USING g.invoice_no, g.supplier_name, v_inv_new;
    END IF;
  END IF;

  -- 7. Any other table that points to the bill: moved to the corrected bill, else removed.
  FOR f IN
    SELECT c.conrelid::regclass AS tbl, a.attname AS col
    FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
    WHERE c.contype = 'f' AND c.confrelid = 'public.lwb_goods_inward'::regclass AND array_length(c.conkey, 1) = 1
      AND c.conrelid <> 'public.lwb_goods_inward'::regclass
  LOOP
    IF p_move_to IS NOT NULL AND f.tbl NOT IN (to_regclass('public.lwb_goods_inward_items'), to_regclass('public.lwb_inventory_movements')) THEN
      EXECUTE format('UPDATE %s SET %I = $2 WHERE %I = $1', f.tbl, f.col, f.col) USING p_inward, p_move_to;
    ELSE
      EXECUTE format('DELETE FROM %s WHERE %I = $1', f.tbl, f.col) USING p_inward;
    END IF;
  END LOOP;

  -- 8. The lines and the bill.
  DELETE FROM public.lwb_goods_inward_items i WHERE i.inward_id = p_inward;
  DELETE FROM public.lwb_goods_inward x WHERE x.id = p_inward;
  RETURN v_other;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pbe_remove(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- Delete an old purchase bill (Admin; reason needed).
CREATE OR REPLACE FUNCTION public.lwb_purchase_bill_delete(p_inward uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  g jsonb;
  v_items jsonb;
  v_rows jsonb;
  v_pre jsonb;
  v_other jsonb;
  v_by text;
BEGIN
  IF NOT public.lwb_pbe_admin() THEN RAISE EXCEPTION 'Only Admin can delete a purchase bill'; END IF;
  IF length(btrim(coalesce(p_reason,''))) < 3 THEN RAISE EXCEPTION 'Write the reason for deleting this bill'; END IF;
  SELECT to_jsonb(x) INTO g FROM public.lwb_goods_inward x WHERE x.id = p_inward FOR UPDATE;
  IF g IS NULL THEN RAISE EXCEPTION 'Purchase bill not found (already deleted?)'; END IF;
  v_pre := public.lwb_purchase_bill_preview(p_inward);
  IF NOT (v_pre->>'can')::boolean THEN RAISE EXCEPTION '%', v_pre->>'why'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(i)), '[]'::jsonb) INTO v_items FROM public.lwb_goods_inward_items i WHERE i.inward_id = p_inward;
  v_rows := public.lwb_pbe_stock_rows(p_inward);
  v_other := public.lwb_pbe_remove(p_inward, NULL, v_rows);
  SELECT coalesce(nullif(btrim(p.full_name),''), 'Admin') INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.lwb_purchase_bill_log(action, inward_id, invoice_no, supplier_name, reason, bill, items, stock_rows, other, done_by_name)
  VALUES ('DELETE', p_inward, g->>'invoice_no', g->>'supplier_name', left(btrim(p_reason), 500), g, v_items, v_rows,
          v_other || jsonb_build_object('lines', v_pre->'lines'), v_by);
  RETURN jsonb_build_object('invoice_no', g->>'invoice_no', 'supplier_name', g->>'supplier_name',
                            'stock_rows', jsonb_array_length(v_rows), 'lines', v_pre->'lines');
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_bill_delete(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_bill_delete(uuid, text) TO authenticated;

-- Edit an old purchase bill (Admin): the corrected bill is posted like a new Goods Inward, the old
-- one is removed with its stock rows. p_header / p_items as Goods Inward sends them.
CREATE OR REPLACE FUNCTION public.lwb_purchase_bill_edit(p_inward uuid, p_reason text, p_header jsonb, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  g public.lwb_goods_inward%ROWTYPE;
  gj jsonb;
  v_items jsonb;
  v_rows jsonb;
  v_pre jsonb;
  v_res jsonb;
  v_new uuid;
  v_other jsonb;
  v_by text;
  v_mrp boolean;
  v_sup text;
  c text;
BEGIN
  IF NOT public.lwb_pbe_admin() THEN RAISE EXCEPTION 'Only Admin can edit a purchase bill'; END IF;
  IF length(btrim(coalesce(p_reason,''))) < 3 THEN RAISE EXCEPTION 'Write the reason for changing this bill'; END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'Add at least one SKU line'; END IF;
  SELECT * INTO g FROM public.lwb_goods_inward x WHERE x.id = p_inward FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Purchase bill not found (already deleted or changed?)'; END IF;
  gj := to_jsonb(g);
  v_pre := public.lwb_purchase_bill_preview(p_inward);
  IF NOT (v_pre->>'can')::boolean THEN RAISE EXCEPTION '%', v_pre->>'why'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(i)), '[]'::jsonb) INTO v_items FROM public.lwb_goods_inward_items i WHERE i.inward_id = p_inward;
  v_rows := public.lwb_pbe_stock_rows(p_inward);

  -- Old bill steps aside so the same invoice no. can be posted again.
  UPDATE public.lwb_goods_inward SET invoice_no = left(g.invoice_no, 40) || ' ~old ' || left(md5(random()::text), 6) WHERE id = p_inward;

  v_mrp := EXISTS (SELECT 1 FROM jsonb_array_elements(p_items) i WHERE upper(coalesce(i->>'billing_mode','')) = 'MRP');
  IF v_mrp THEN
    v_res := public.lwb_post_goods_inward_mrp(p_header, p_items);
  ELSE
    v_sup := coalesce((SELECT s.supplier_name FROM public.lwb_supplier_master s WHERE s.id::text = p_header->>'p_supplier_id'), p_header->>'p_supplier_name');
    EXECUTE format('SELECT to_jsonb(r) FROM public.lwb_post_goods_inward(
        p_supplier_name => %L, p_invoice_no => %L, p_invoice_date => %L, p_received_date => %L,
        p_transport_name => %L, p_vehicle_no => %L, p_lr_no => %L, p_remarks => %L, p_items => %L,
        p_driver_name => %L, p_driver_mobile => %L, p_supplier_id => %L) AS r',
      v_sup, p_header->>'p_invoice_no', p_header->>'p_invoice_date', p_header->>'p_received_date',
      coalesce(p_header->>'p_transport_name',''), coalesce(p_header->>'p_vehicle_no',''), coalesce(p_header->>'p_lr_no',''),
      coalesce(p_header->>'p_remarks',''), p_items::text,
      p_header->>'p_driver_name', p_header->>'p_driver_mobile', nullif(p_header->>'p_supplier_id',''))
    INTO v_res;
  END IF;
  -- the result can be a row, or a one-field row holding the function's jsonb
  IF jsonb_typeof(v_res) = 'object' AND v_res ? 'r' AND jsonb_typeof(v_res->'r') = 'object' THEN v_res := v_res->'r'; END IF;
  IF jsonb_typeof(v_res) = 'object' THEN
    v_new := coalesce(nullif(v_res->>'id',''), nullif(v_res->>'inward_id',''))::uuid;
  END IF;
  IF v_new IS NULL THEN
    SELECT x.id INTO v_new FROM public.lwb_goods_inward x
    WHERE x.id <> p_inward AND public.lwb_inv_key(x.invoice_no) = public.lwb_inv_key(p_header->>'p_invoice_no')
    ORDER BY x.created_at DESC LIMIT 1;
  END IF;
  IF v_new IS NULL OR v_new = p_inward THEN RAISE EXCEPTION 'Corrected bill not found after posting: nothing was changed'; END IF;

  -- Vehicle time, Godown Manager and brand stay with the bill.
  FOREACH c IN ARRAY ARRAY['time_in','time_out','godown_user_id','company_id'] LOOP
    IF gj ? c AND gj->>c IS NOT NULL THEN
      EXECUTE format('UPDATE public.lwb_goods_inward x SET %1$I = o.%1$I FROM public.lwb_goods_inward o
                      WHERE x.id = $1 AND o.id = $2 AND x.%1$I IS NULL', c) USING v_new, p_inward;
    END IF;
  END LOOP;

  v_other := public.lwb_pbe_remove(p_inward, v_new, v_rows);
  SELECT coalesce(nullif(btrim(p.full_name),''), 'Admin') INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.lwb_purchase_bill_log(action, inward_id, new_inward_id, invoice_no, supplier_name, reason, bill, items, stock_rows, other, done_by_name)
  VALUES ('EDIT', p_inward, v_new, g.invoice_no, g.supplier_name, left(btrim(p_reason), 500), gj, v_items, v_rows,
          v_other || jsonb_build_object('lines', v_pre->'lines', 'posted', v_res), v_by);
  RETURN coalesce(v_res, '{}'::jsonb) || jsonb_build_object('id', v_new, 'old_id', p_inward, 'old_stock_rows', jsonb_array_length(v_rows));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_bill_edit(uuid, text, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_bill_edit(uuid, text, jsonb, jsonb) TO authenticated;

-- Log of deleted / changed bills (Admin).
CREATE OR REPLACE FUNCTION public.lwb_purchase_bill_log_list(p_days int DEFAULT 90)
RETURNS SETOF public.lwb_purchase_bill_log LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_pbe_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  RETURN QUERY SELECT * FROM public.lwb_purchase_bill_log l
    WHERE l.done_at >= now() - make_interval(days => greatest(coalesce(p_days, 90), 1)) ORDER BY l.done_at DESC;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_bill_log_list(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_bill_log_list(int) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: how the stock rows of a bill are found (no bill or stock figures).
SELECT 'stock link' AS item,
       coalesce((SELECT string_agg(k.column_name, ', ') FROM information_schema.columns k
                 WHERE k.table_schema = 'public' AND k.table_name = 'lwb_inventory_movements'
                   AND k.column_name IN ('inward_id','goods_inward_id','purchase_id','purchase_inward_id','reference_id','ref_id',
                                         'source_id','document_id','reference_uuid','ref_uuid','inward_item_id','goods_inward_item_id',
                                         'purchase_item_id')), 'by invoice no.') AS how,
       public.lwb_pbe_stock_reads_items()::text AS live_stock_reads_bill_lines;
