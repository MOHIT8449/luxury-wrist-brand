-- LUXURY WRIST BRAND ERP — GODOWN DAMAGE REPORT FOR PURCHASE VEHICLES (6 Nov 2026)
--
-- Mohit asked (6 Nov 2026): when a purchase vehicle comes to the godown (purchase entry is made by
-- Sales Head / Admin), the Godown Manager gets a popup "vehicle arrived". If anything is damaged /
-- leaking / short he enters SKU, quantity, type and photos. After Submit the report goes to Admin
-- and the Sales Head.
--
--   1. Purchase Entry picks the Godown Manager; lwb_purchase_arrived(bill, manager) sends the
--      PURCHASE_ARRIVED bell to that person only (Mohit: "jisko main assign karun usi ko aana chahiye").
--      The page shows it as a popup until the vehicle is checked (or "Later", 15 min).
--   2. lwb_purchase_damage_report(inward, date, note, items): the Godown Manager / Admin / Sales Head
--      submits the check (same rules as lwb_save_purchase_check). Admin + Sales Head get
--      PURCHASE_DAMAGE (or PURCHASE_CHECK_OK when all fine). The arrived bells of that bill are marked read.
--   3. Stock: damaged / leaked goods must not be sold. When a check is saved (any page), its lines
--      move godown stock at once (APPROVED lwb_stock_moves, kind TRANSFER, source MANUAL, inward_id set):
--         DAMAGE   Saleable -> Damage
--         LEAKAGE  Saleable -> Leakage
--         SHORTAGE Saleable -> Loss      (billed but never came: not in the godown)
--      Changing the check cancels the old lines and books the new ones; removing the check cancels them.
--      Later steps stay in Stock Transfer as before (Damage -> Return to company / Destroy, with approval).
--      Checks saved before this file are not back-filled.
--
--   4. Vehicle Time In / Time Out (lwb_goods_inward.time_in / time_out) entered with the check.
--
-- Needs: lwb_purchase_claim_setup.sql, lwb_purchase_register_setup.sql, lwb_stock_transfer_setup.sql.
-- If lwb_purchase_register_setup.sql runs again, nothing here needs to run again.
-- Safe to run again. Nothing is dropped or deleted.

BEGIN;

-- Notification link to a non-order record (here: the purchase bill). Old rows stay NULL.
ALTER TABLE public.erp_notifications ADD COLUMN IF NOT EXISTS ref_type text;
ALTER TABLE public.erp_notifications ADD COLUMN IF NOT EXISTS ref_id text;
CREATE INDEX IF NOT EXISTS erp_notifications_ref_idx ON public.erp_notifications (ref_type, ref_id) WHERE ref_type IS NOT NULL;

-- Vehicle Time In / Time Out at the godown, the Godown Manager who checks the vehicle.
ALTER TABLE public.lwb_goods_inward ADD COLUMN IF NOT EXISTS time_in timestamptz;
ALTER TABLE public.lwb_goods_inward ADD COLUMN IF NOT EXISTS time_out timestamptz;
ALTER TABLE public.lwb_goods_inward ADD COLUMN IF NOT EXISTS godown_user_id uuid;

-- Stock lines booked from a purchase vehicle check.
ALTER TABLE public.lwb_stock_moves ADD COLUMN IF NOT EXISTS inward_id uuid;
CREATE INDEX IF NOT EXISTS lwb_stock_moves_inward_idx ON public.lwb_stock_moves (inward_id) WHERE inward_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Bill summary text: "Vehicle GJ05AB1234 · DS GROUP · Inv 123 · 450 CS"
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_pdr_bill_text(p_inward uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT concat_ws(' · ',
    'Vehicle ' || coalesce(nullif(upper(regexp_replace(coalesce(g.vehicle_no,''), '[^A-Za-z0-9]', '', 'g')),''), 'no no.'),
    nullif(btrim(g.supplier_name),''),
    'Inv ' || g.invoice_no,
    (SELECT CASE WHEN sum(coalesce(nullif(to_jsonb(i)->>'cases','')::numeric,0)) > 0
                 THEN trim(to_char(sum(coalesce(nullif(to_jsonb(i)->>'cases','')::numeric,0)), 'FM999G999G990')) || ' CS' END
       FROM public.lwb_goods_inward_items i WHERE i.inward_id = g.id))
  FROM public.lwb_goods_inward g WHERE g.id = p_inward;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pdr_bill_text(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Vehicle arrived -> the Godown Manager chosen on Purchase Entry (only that person).
--    Called by Goods Inward after the bill is saved. No one chosen = every active Godown Manager.
--    Called again with another person = the bill moves to that person (the old popup closes).
--    Bill already checked = nothing is sent.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_lwb_pdr_arrived ON public.lwb_goods_inward;  -- first draft sent to everyone; now Goods Inward calls the RPC below

CREATE OR REPLACE FUNCTION public.lwb_purchase_arrived(p_inward uuid, p_godown uuid DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE g record; v_txt text; v_by text; v_n integer := 0;
BEGIN
  IF public.lwb_pr_role() NOT IN ('admin','manager') THEN RAISE EXCEPTION 'Only Admin / Sales Head can send the purchase vehicle to a Godown Manager'; END IF;
  SELECT x.id, x.invoice_no, x.vehicle_no INTO g FROM public.lwb_goods_inward x WHERE x.id = p_inward;
  IF g.id IS NULL THEN RAISE EXCEPTION 'Purchase bill not found'; END IF;
  IF p_godown IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_godown AND p.active = true AND lower(btrim(p.role)) = 'warehouse') THEN
    RAISE EXCEPTION 'Choose an active Godown Manager login';
  END IF;
  UPDATE public.lwb_goods_inward SET godown_user_id = p_godown WHERE id = p_inward;
  IF EXISTS (SELECT 1 FROM public.lwb_purchase_checks c WHERE c.inward_id = p_inward) THEN RETURN 0; END IF;
  -- Moved to another person: close the old popups.
  UPDATE public.erp_notifications SET is_read = true
  WHERE ref_type = 'PURCHASE_BILL' AND ref_id = p_inward::text AND notification_type = 'PURCHASE_ARRIVED' AND is_read = false
    AND p_godown IS NOT NULL AND user_id <> p_godown;
  v_txt := public.lwb_pdr_bill_text(p_inward);
  SELECT nullif(btrim(p.full_name),'') INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.erp_notifications(user_id, title, message, notification_type, ref_type, ref_id)
  SELECT p.id, left('Purchase vehicle arrived: ' || coalesce(nullif(btrim(g.vehicle_no),''), 'Inv ' || g.invoice_no), 150),
         left(v_txt || '. Check the goods. Report damage / leakage / shortage with photos, or press All OK.'
              || coalesce(' Entry by ' || v_by || '.', ''), 600),
         'PURCHASE_ARRIVED', 'PURCHASE_BILL', p_inward::text
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) = 'warehouse' AND (p_godown IS NULL OR p.id = p_godown)
    AND NOT EXISTS (SELECT 1 FROM public.erp_notifications n WHERE n.user_id = p.id AND n.ref_type = 'PURCHASE_BILL'
                    AND n.ref_id = p_inward::text AND n.notification_type = 'PURCHASE_ARRIVED' AND n.is_read = false);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_arrived(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_arrived(uuid, uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Stock follows the check lines of a bill. Returns the number of stock lines now booked.
-- ---------------------------------------------------------------------------
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
           CASE i.issue WHEN 'DAMAGE' THEN 'DAMAGE' WHEN 'LEAKAGE' THEN 'LEAKAGE' ELSE 'LOSS' END AS bucket,
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
         CASE w->>'to' WHEN 'LOSS' THEN 'Purchase shortage' WHEN 'LEAKAGE' THEN 'Purchase leakage' ELSE 'Purchase damage' END,
         left('Purchase vehicle check · Inv ' || coalesce(v_inv,''), 300), 'MANUAL', 'APPROVED',
         coalesce(v_ck.who, auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid), now(), coalesce(v_ck.who, auth.uid()), now(),
         'Booked by itself from the purchase vehicle check', p_inward
  FROM jsonb_array_elements(v_want) w;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pdr_stock_sync(uuid) FROM PUBLIC, anon, authenticated;

-- Runs at commit, so the check lines saved in the same call are there.
CREATE OR REPLACE FUNCTION public.lwb_pdr_stock_trg()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  PERFORM public.lwb_pdr_stock_sync(CASE WHEN TG_OP = 'DELETE' THEN OLD.inward_id ELSE NEW.inward_id END);
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pdr_stock_trg() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_pdr_stock ON public.lwb_purchase_checks;
CREATE CONSTRAINT TRIGGER trg_lwb_pdr_stock AFTER INSERT OR UPDATE OR DELETE ON public.lwb_purchase_checks
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.lwb_pdr_stock_trg();

-- ---------------------------------------------------------------------------
-- 2. Submit the check (Godown Manager / Admin / Sales Head) and report it to Admin + Sales Head.
--    p_items: [{sku_id, sku_name, pcs_per_case, issue DAMAGE|LEAKAGE|SHORTAGE, cases, pcs}], [] = all OK.
-- ---------------------------------------------------------------------------
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
             WHERE upper(coalesce(x->>'issue','')) NOT IN ('DAMAGE','LEAKAGE','SHORTAGE')
                OR nullif(btrim(coalesce(x->>'sku_name','')),'') IS NULL
                OR coalesce(x->>'cases','0') !~ '^\d{1,6}$' OR coalesce(x->>'pcs','0') !~ '^\d{1,7}$'
                OR coalesce((x->>'cases')::int,0) + coalesce((x->>'pcs')::int,0) = 0) THEN
    RAISE EXCEPTION 'Each line needs an SKU, a type (Damage / Leakage / Shortage) and cases or PCS';
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
    RAISE EXCEPTION 'Damage / leakage / shortage is more than the bill quantity of an SKU';
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
  SELECT string_agg(i.sku_name || ' ' || initcap(i.issue) || ' ' ||
           concat_ws(' + ', CASE WHEN i.cases > 0 THEN i.cases || ' cs' END, CASE WHEN i.pcs > 0 THEN i.pcs || ' pcs' END), ', ' ORDER BY i.sku_name, i.issue),
         sum(i.cases + i.pcs::numeric / greatest(i.pcs_per_case,1))
  INTO v_lines, v_cs FROM public.lwb_purchase_check_items i WHERE i.check_id = v_cid;

  INSERT INTO public.erp_notifications(user_id, title, message, notification_type, ref_type, ref_id)
  SELECT p.id,
         left(CASE WHEN v_dmg THEN 'Purchase damage: ' || trim(to_char(round(v_cs,1), 'FM999G990D9')) || ' CS'
                   ELSE 'Purchase vehicle checked: all OK' END, 150),
         left(v_txt || '. ' || CASE WHEN v_dmg THEN v_lines || '. Photos ' || v_photos || '. Kept out of saleable stock.' ELSE 'No damage, leakage or shortage.' END
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

-- ---------------------------------------------------------------------------
-- 4. Vehicle Time In / Time Out at the godown (Mohit, 6 Nov 2026), entered with the vehicle check.
--    Admin / Sales Head / Godown Manager. Out must be after In; not in the future.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_purchase_vehicle_time(p_inward uuid, p_in timestamptz, p_out timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_pc_checker() THEN RAISE EXCEPTION 'Only Admin, Sales Head or Godown Manager can enter vehicle time'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_goods_inward g WHERE g.id = p_inward) THEN RAISE EXCEPTION 'Purchase bill not found'; END IF;
  IF p_in IS NULL THEN RAISE EXCEPTION 'Enter the vehicle Time In'; END IF;
  IF p_in > now() + interval '10 minutes' OR p_out > now() + interval '10 minutes' THEN RAISE EXCEPTION 'Vehicle time is in the future'; END IF;
  IF p_out IS NOT NULL AND p_out < p_in THEN RAISE EXCEPTION 'Time Out must be after Time In'; END IF;
  IF p_out - p_in > interval '3 days' THEN RAISE EXCEPTION 'Time In and Time Out are more than 3 days apart'; END IF;
  UPDATE public.lwb_goods_inward SET time_in = p_in, time_out = p_out WHERE id = p_inward;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_vehicle_time(uuid, timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_vehicle_time(uuid, timestamptz, timestamptz) TO authenticated;

-- The arrived popup of a bill that someone already checked (e.g. at Goods Inward) is closed by itself.
CREATE OR REPLACE FUNCTION public.lwb_pdr_arrived_done_trg()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.erp_notifications SET is_read = true
  WHERE ref_type = 'PURCHASE_BILL' AND ref_id = NEW.inward_id::text AND notification_type = 'PURCHASE_ARRIVED' AND is_read = false;
  RETURN NULL;
EXCEPTION WHEN others THEN RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pdr_arrived_done_trg() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_pdr_arrived_done ON public.lwb_purchase_checks;
CREATE CONSTRAINT TRIGGER trg_lwb_pdr_arrived_done AFTER INSERT ON public.lwb_purchase_checks
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.lwb_pdr_arrived_done_trg();

COMMIT;

-- Check (all true):
SELECT to_regprocedure('public.lwb_purchase_damage_report(uuid,date,text,jsonb)') IS NOT NULL AS report_rpc,
       to_regprocedure('public.lwb_purchase_arrived(uuid,uuid)') IS NOT NULL AS arrived_rpc,
       EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_pdr_stock') AS stock_trigger;
