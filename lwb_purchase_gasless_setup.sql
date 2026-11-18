-- LUXURY WRIST BRAND ERP — PURCHASE VEHICLE CHECK: GASLESS TYPE (18 Nov 2026)
--
-- Mohit asked (18 Nov 2026): on Goods Inward the Damage, Leakage and Breakage columns become ONE
-- column "Damage / Leakage / Breakage" (saved as DAMAGE), and Gasless is a separate type.
--
--   * lwb_purchase_check_items.issue now also allows GASLESS (old LEAKAGE lines stay as they are).
--   * Stock: GASLESS lines move Saleable -> Gasless (the Gasless bucket already exists in Stock Transfer).
--     DAMAGE -> Damage, LEAKAGE (old) -> Leakage, SHORTAGE -> Loss: unchanged.
--   * lwb_purchase_damage_report accepts GASLESS.
--
-- Needs: lwb_purchase_damage_report_setup.sql. Safe to run again. Nothing is dropped or deleted
-- (only the issue CHECK rule is replaced by a wider one).

BEGIN;

DO $do$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.conname FROM pg_constraint c
           WHERE c.conrelid = 'public.lwb_purchase_check_items'::regclass AND c.contype = 'c'
             AND pg_get_constraintdef(c.oid) ILIKE '%issue%' LOOP
    EXECUTE format('ALTER TABLE public.lwb_purchase_check_items DROP CONSTRAINT %I', r.conname);
  END LOOP;
END
$do$;
ALTER TABLE public.lwb_purchase_check_items ADD CONSTRAINT lwb_purchase_check_items_issue_check
  CHECK (issue IN ('DAMAGE','LEAKAGE','GASLESS','SHORTAGE'));

CREATE OR REPLACE FUNCTION public.lwb_pdr_stock_sync(p_inward uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_ck record;
  v_inv text;
  v_want jsonb;
  v_have jsonb;
  v_batch uuid := gen_random_uuid();
  v_n integer := 0;
BEGIN
  IF p_inward IS NULL THEN RETURN 0; END IF;
  SELECT c.id, c.verified_on, coalesce(c.updated_by, c.created_by) AS who INTO v_ck
  FROM public.lwb_purchase_checks c WHERE c.inward_id = p_inward;
  SELECT g.invoice_no || ' · ' || coalesce(g.supplier_name,'') INTO v_inv FROM public.lwb_goods_inward g WHERE g.id = p_inward;

  -- Wanted lines: one per SKU + bucket, SKU from the line or found by name in SKU Master.
  SELECT coalesce(jsonb_agg(jsonb_build_object('sku', x.sku_id, 'name', x.sku_name, 'pack', x.pack, 'to', x.bucket, 'pcs', x.pcs)
           ORDER BY x.sku_id, x.bucket), '[]'::jsonb) INTO v_want
  FROM (
    SELECT s.sku_id, max(i.sku_name) AS sku_name, max(i.pcs_per_case) AS pack,
           CASE i.issue WHEN 'DAMAGE' THEN 'DAMAGE' WHEN 'LEAKAGE' THEN 'LEAKAGE' WHEN 'GASLESS' THEN 'GASLESS' ELSE 'LOSS' END AS bucket,
           sum(i.cases * i.pcs_per_case + i.pcs)::int AS pcs
    FROM public.lwb_purchase_check_items i
    CROSS JOIN LATERAL (SELECT coalesce(i.sku_id,
        (SELECT m.id FROM public.sku_master m WHERE upper(btrim(m.sku_name)) = upper(btrim(i.sku_name))
         ORDER BY coalesce(m.is_active, true) DESC LIMIT 1)) AS sku_id) s
    WHERE v_ck.id IS NOT NULL AND i.check_id = v_ck.id AND s.sku_id IS NOT NULL
    GROUP BY s.sku_id, 4
    HAVING sum(i.cases * i.pcs_per_case + i.pcs) > 0
  ) x;

  SELECT coalesce(jsonb_agg(jsonb_build_object('sku', m.sku_id, 'to', m.to_bucket, 'pcs', m.qty_pcs) ORDER BY m.sku_id::text, m.to_bucket), '[]'::jsonb)
  INTO v_have FROM public.lwb_stock_moves m WHERE m.inward_id = p_inward AND m.status = 'APPROVED';

  IF v_have = (SELECT coalesce(jsonb_agg(jsonb_build_object('sku', w->'sku', 'to', w->'to', 'pcs', w->'pcs') ORDER BY w->>'sku', w->>'to'), '[]'::jsonb)
               FROM jsonb_array_elements(v_want) w) THEN
    RETURN jsonb_array_length(v_have);
  END IF;

  UPDATE public.lwb_stock_moves SET status = 'CANCELLED', decided_at = now(), decided_by = auth.uid(),
    decision_note = 'Purchase vehicle check changed'
  WHERE inward_id = p_inward AND status = 'APPROVED';

  INSERT INTO public.lwb_stock_moves(batch_id, kind, from_bucket, to_bucket, sku_id, sku_name, pcs_per_case, qty_pcs, requested_pcs,
    move_date, reason, note, source, status, requested_by, requested_at, decided_by, decided_at, decision_note, inward_id)
  SELECT v_batch, 'TRANSFER', 'SALEABLE', w->>'to', (w->>'sku')::uuid, w->>'name', greatest(coalesce((w->>'pack')::int,1),1),
         (w->>'pcs')::int, (w->>'pcs')::int,
         coalesce(v_ck.verified_on, (now() AT TIME ZONE 'Asia/Kolkata')::date),
         CASE w->>'to' WHEN 'LOSS' THEN 'Purchase shortage' WHEN 'LEAKAGE' THEN 'Purchase leakage' WHEN 'GASLESS' THEN 'Purchase gasless' ELSE 'Purchase damage / leakage / breakage' END,
         left('Purchase vehicle check · Inv ' || coalesce(v_inv,''), 300), 'MANUAL', 'APPROVED',
         coalesce(v_ck.who, auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid), now(), coalesce(v_ck.who, auth.uid()), now(),
         'Booked by itself from the purchase vehicle check', p_inward
  FROM jsonb_array_elements(v_want) w;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pdr_stock_sync(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_purchase_damage_report(
  p_inward_id uuid, p_verified_on date, p_note text, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_cid uuid;
  v_items jsonb := CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]'::jsonb END;
  v_dmg boolean;
  v_by text;
  v_txt text;
  v_lines text;
  v_photos integer := 0;
  v_cs numeric;
  v_n integer := 0;
BEGIN
  IF NOT public.lwb_pc_checker() THEN RAISE EXCEPTION 'Only Admin, Sales Head or Godown Manager can check purchase vehicles'; END IF;
  IF p_verified_on IS NULL OR p_verified_on > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1 THEN RAISE EXCEPTION 'Check date is wrong'; END IF;
  IF jsonb_array_length(v_items) > 200 THEN RAISE EXCEPTION 'Too many lines'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) x
             WHERE upper(coalesce(x->>'issue','')) NOT IN ('DAMAGE','LEAKAGE','GASLESS','SHORTAGE')
                OR nullif(btrim(coalesce(x->>'sku_name','')),'') IS NULL
                OR coalesce(x->>'cases','0') !~ '^\d{1,6}$' OR coalesce(x->>'pcs','0') !~ '^\d{1,7}$'
                OR coalesce((x->>'cases')::int,0) + coalesce((x->>'pcs')::int,0) = 0) THEN
    RAISE EXCEPTION 'Each line needs an SKU, a type (Damage / Leakage / Breakage, Gasless or Shortage) and cases or PCS';
  END IF;
  -- Not more than the bill brought, per SKU (all types together).
  IF EXISTS (
    SELECT 1 FROM (
      SELECT nullif(x->>'sku_id','') AS sku, sum(coalesce((x->>'cases')::int,0) * greatest(coalesce((x->>'pcs_per_case')::int,1),1) + coalesce((x->>'pcs')::int,0)) AS pcs
      FROM jsonb_array_elements(v_items) x GROUP BY 1) r
    JOIN LATERAL (
      SELECT sum(coalesce(nullif(to_jsonb(i)->>'quantity_pcs','')::numeric,
                          coalesce(nullif(to_jsonb(i)->>'cases','')::numeric,0) * greatest(coalesce(nullif(to_jsonb(s)->>'pcs_per_case','')::numeric,1),1)
                          + coalesce(nullif(to_jsonb(i)->>'pcs','')::numeric,0))) AS billed
      FROM public.lwb_goods_inward_items i LEFT JOIN public.sku_master s ON s.id = i.sku_id
      WHERE i.inward_id = p_inward_id AND i.sku_id::text = r.sku) b ON true
    WHERE r.sku IS NOT NULL AND b.billed IS NOT NULL AND r.pcs > b.billed) THEN
    RAISE EXCEPTION 'Damage / gasless / shortage is more than the bill quantity of an SKU';
  END IF;

  v_cid := public.lwb_save_purchase_check(p_inward_id, p_verified_on, p_note, v_items);
  v_dmg := jsonb_array_length(v_items) > 0;

  SELECT coalesce(nullif(btrim(p.full_name),''), 'Staff') INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();
  v_txt := public.lwb_pdr_bill_text(p_inward_id);
  -- Time In / Out (when entered): " · In 10:20 · Out 11:40 (1h 20m)"
  SELECT v_txt || coalesce(' · In ' || to_char(g.time_in AT TIME ZONE 'Asia/Kolkata', 'HH24:MI'), '')
         || coalesce(' · Out ' || to_char(g.time_out AT TIME ZONE 'Asia/Kolkata', 'HH24:MI')
              || ' (' || CASE WHEN g.time_out - g.time_in >= interval '1 hour'
                              THEN floor(extract(epoch FROM g.time_out - g.time_in) / 3600)::int || 'h ' ELSE '' END
              || (floor(extract(epoch FROM g.time_out - g.time_in) / 60)::int % 60) || 'm)', '')
  INTO v_txt FROM public.lwb_goods_inward g WHERE g.id = p_inward_id;
  IF to_regclass('public.lwb_documents') IS NOT NULL THEN
    EXECUTE 'SELECT count(*)::int FROM public.lwb_documents d WHERE d.entity_type = ''PURCHASE_BILL'' AND d.entity_id = $1 AND d.doc_type = ''DAMAGE'' AND d.removed_at IS NULL'
      INTO v_photos USING p_inward_id::text;
  END IF;
  SELECT string_agg(i.sku_name || ' ' || CASE i.issue WHEN 'DAMAGE' THEN 'Damage / Leakage / Breakage' ELSE initcap(i.issue) END || ' ' ||
           concat_ws(' + ', CASE WHEN i.cases > 0 THEN i.cases || ' cs' END, CASE WHEN i.pcs > 0 THEN i.pcs || ' pcs' END), ', ' ORDER BY i.sku_name, i.issue),
         sum(i.cases + i.pcs::numeric / greatest(i.pcs_per_case,1))
  INTO v_lines, v_cs FROM public.lwb_purchase_check_items i WHERE i.check_id = v_cid;

  INSERT INTO public.erp_notifications(user_id, title, message, notification_type, ref_type, ref_id)
  SELECT p.id,
         left(CASE WHEN v_dmg THEN 'Purchase damage: ' || trim(to_char(round(v_cs,1), 'FM999G990D9')) || ' CS'
                   ELSE 'Purchase vehicle checked: all OK' END, 150),
         left(v_txt || '. ' || CASE WHEN v_dmg THEN v_lines || '. Photos ' || v_photos || '. Kept out of saleable stock.' ELSE 'No damage, gasless or shortage.' END
              || coalesce(' Note: ' || nullif(btrim(p_note),'') || '.', '') || ' By ' || v_by || '.', 600),
         CASE WHEN v_dmg THEN 'PURCHASE_DAMAGE' ELSE 'PURCHASE_CHECK_OK' END, 'PURCHASE_BILL', p_inward_id::text
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') AND p.id IS DISTINCT FROM auth.uid();
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- The "vehicle arrived" popups of this bill are done (for every Godown Manager).
  UPDATE public.erp_notifications SET is_read = true
  WHERE ref_type = 'PURCHASE_BILL' AND ref_id = p_inward_id::text AND notification_type = 'PURCHASE_ARRIVED' AND is_read = false;

  RETURN jsonb_build_object('check_id', v_cid, 'damage', v_dmg, 'photos', v_photos, 'notified', v_n);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_damage_report(uuid, date, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_damage_report(uuid, date, text, jsonb) TO authenticated;

COMMIT;

-- Check (all true):
SELECT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conname = 'lwb_purchase_check_items_issue_check'
               AND pg_get_constraintdef(c.oid) LIKE '%GASLESS%') AS gasless_allowed,
       position('GASLESS' in pg_get_functiondef('public.lwb_pdr_stock_sync(uuid)'::regprocedure)) > 0 AS stock_sync,
       position('GASLESS' in pg_get_functiondef('public.lwb_purchase_damage_report(uuid,date,text,jsonb)'::regprocedure)) > 0 AS report_rpc;
