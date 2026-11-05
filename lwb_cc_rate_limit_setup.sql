-- LUXURY WRIST BRAND ERP — COCA-COLA MIN RATE (Rate & Scheme) AND ADMIN RATE OK FOR NORMAL POs
--
-- Runs by itself when merged to main (after lwb_rate_scheme_setup.sql, lwb_order_rates_setup.sql and
-- lwb_rajni_rate_limit_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (2 Nov 2026), Phase 2 of the rate limit: Coca-Cola landing changes with every company scheme
-- (Chair / GR, MEPD, OMS, QPS, ROI), all already on Rate & Scheme. Admin sets one "Min margin" per pack;
-- Min rate = Landing (excl. ROI) + Min margin. A Sales Head can not approve a PO with a rate below the min:
-- the PO stays pending and goes to Admin, who only presses "Approve"; then it goes on the normal way
-- (transport, loading, Tally bill).
--
--   * lwb_rate_packs.min_margin (Admin only).
--   * lwb_pack_limits_sync(p): the Rate & Scheme page sends each pack's landing (the page works it out with
--     MEPD schemes etc.) after every save; the min rate of every SKU linked to the pack is written into
--     lwb_sku_price_limits (same table as the Rajnigandha Rate List), so min, landing, approval and
--     profit work the same for both brands.
--   * Deferred trigger on orders: a non-Admin PO that becomes approved (Sales Head's own PO or his approval
--     of a salesman's PO) with a rate below min goes back to pending at commit, waiting for Admin's rate OK
--     (RATE_APPROVAL bell). Rajnigandha slip POs keep their own check (lwb_rajni_rate_limit_setup.sql).
--   * After approval only Admin can lower a line below min.
--   * lwb_rate_approve(order): a normal PO becomes approved by Admin; a slip PO makes the slip (as before).
-- No Tally, ledger, payment, stock or bill amount is written here.

BEGIN;

ALTER TABLE public.lwb_rate_packs ADD COLUMN IF NOT EXISTS min_margin numeric(12,2)
  CHECK (min_margin IS NULL OR min_margin >= 0);

-- ---------------------------------------------------------------------------
-- 1. Pack min rate -> SKU limits
-- ---------------------------------------------------------------------------
-- p = [{pack_id, landing, min_margin}]. Admin sets min_margin (null = no limit); a Sales Head's save only
-- refreshes the landing (his min_margin is ignored).
CREATE OR REPLACE FUNCTION public.lwb_pack_limits_sync(p jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r jsonb; v_pack public.lwb_rate_packs%ROWTYPE; v_land numeric; v_margin numeric; v_min numeric;
        v_admin boolean := public.lwb_price_admin(); v_n integer := 0; v_key text;
        v_old public.lwb_sku_price_limits%ROWTYPE;
BEGIN
  IF NOT public.lwb_rate_editor() THEN RAISE EXCEPTION 'Only Admin or Sales Head can save rates.'; END IF;
  IF jsonb_typeof(p) IS DISTINCT FROM 'array' THEN RETURN 0; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p) LOOP
    SELECT * INTO v_pack FROM public.lwb_rate_packs WHERE id = nullif(r->>'pack_id','')::uuid FOR UPDATE;
    IF NOT FOUND THEN CONTINUE; END IF;
    IF v_admin AND r ? 'min_margin' THEN
      v_margin := nullif(btrim(coalesce(r->>'min_margin','')),'')::numeric;
      IF v_margin < 0 THEN RAISE EXCEPTION '%: Min margin can not be below 0.', v_pack.pack_name; END IF;
      UPDATE public.lwb_rate_packs SET min_margin = v_margin WHERE id = v_pack.id;
    ELSE
      v_margin := v_pack.min_margin;
    END IF;
    v_land := round(nullif(btrim(coalesce(r->>'landing','')),'')::numeric, 2);
    v_min := CASE WHEN v_land IS NOT NULL AND v_margin IS NOT NULL THEN v_land + v_margin END;
    FOR v_key IN SELECT s.sku_key FROM public.lwb_rate_pack_skus s WHERE s.pack_id = v_pack.id LOOP
      SELECT * INTO v_old FROM public.lwb_sku_price_limits WHERE sku_key = v_key;
      IF FOUND AND v_old.landing IS NOT DISTINCT FROM v_land AND v_old.min_rate IS NOT DISTINCT FROM v_min THEN CONTINUE; END IF;
      IF NOT FOUND AND v_land IS NULL AND v_min IS NULL THEN CONTINUE; END IF;
      INSERT INTO public.lwb_sku_price_limits (sku_key, landing, min_rate, std_rate, updated_at, updated_by)
      VALUES (v_key, v_land, v_min, NULL, now(), auth.uid())
      ON CONFLICT (sku_key) DO UPDATE SET landing = EXCLUDED.landing, min_rate = EXCLUDED.min_rate,
        updated_at = now(), updated_by = auth.uid();
      INSERT INTO public.lwb_sku_price_history (sku_key, landing, min_rate, std_rate, created_by)
      VALUES (v_key, v_land, v_min, (SELECT std_rate FROM public.lwb_sku_price_limits WHERE sku_key = v_key), auth.uid());
      v_n := v_n + 1;
    END LOOP;
  END LOOP;
  RETURN v_n;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. Normal PO: approved below min by a non-Admin -> back to pending, waiting for Admin (at commit,
--    so the SKU lines saved after the header are checked too).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_rate_po_route()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_b jsonb; v_msg text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.id;
  IF NOT FOUND OR lower(btrim(coalesce(v_o.status,''))) NOT IN ('approved','approved_next','manager_approved','warehouse_approved') THEN
    RETURN NULL;
  END IF;
  IF public.lwb_quick_slip_company(v_o.id) IS NOT NULL THEN RETURN NULL; END IF;  -- Rajnigandha slip: own check
  IF public.lwb_price_admin() THEN
    -- Admin approved the PO himself (PO Approval page): that is the rate OK too.
    UPDATE public.lwb_rate_approvals SET status = 'APPROVED', approved_by = auth.uid(), approved_at = now()
     WHERE order_id = v_o.id AND status = 'WAITING';
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_rate_approvals a WHERE a.order_id = v_o.id AND a.status = 'APPROVED') THEN RETURN NULL; END IF;
  v_b := public.lwb_rate_breaches(v_o.id);
  IF jsonb_array_length(v_b) = 0 THEN RETURN NULL; END IF;

  UPDATE public.orders SET status = 'pending_approval', approved_by = NULL, approved_at = NULL WHERE id = v_o.id;
  INSERT INTO public.lwb_rate_approvals (order_id, status, slip, requested_by, requested_at)
  VALUES (v_o.id, 'WAITING', '{}'::jsonb, auth.uid(), now())
  ON CONFLICT (order_id) DO UPDATE SET status = 'WAITING', requested_by = auth.uid(), requested_at = now(),
    approved_by = NULL, approved_at = NULL;
  v_msg := coalesce(v_o.order_no,'PO') || ' · ' || coalesce(btrim(v_o.customer_name),'') || ' · ' || coalesce(v_o.sales_person,'') || ' · ' ||
    (SELECT string_agg((x->>'sku') || ' ₹' || (x->>'rate') || ' (min ₹' || (x->>'min_rate') || ')', ', ') FROM jsonb_array_elements(v_b) x);
  BEGIN
    UPDATE public.erp_notifications SET is_read = true WHERE order_id = v_o.id AND is_read = false
      AND notification_type IN ('PO_APPROVED_LOADING','PO_APPROVED_BILL','PO_RATE_APPROVAL');
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, 'Rate below min — Admin OK needed', v_msg, 'PO_RATE_APPROVAL', v_o.id
    FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'admin';
  EXCEPTION WHEN others THEN NULL;  -- a popup never stops the PO
  END;
  RETURN NULL;
END;
$fn$;
DROP TRIGGER IF EXISTS lwb_rate_po_route ON public.orders;
CREATE CONSTRAINT TRIGGER lwb_rate_po_route AFTER INSERT OR UPDATE OF status ON public.orders
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.lwb_rate_po_route();

-- 2b. Salesman punches a PO below min (5 Nov 2026, Mohit: "special rate PO punch karein to notification nahi
--     aata"). Before this the Admin bell came only after the Sales Head approved the PO, so a salesman's PO
--     never told Admin anything. Now Admin gets the PO_RATE_APPROVAL bell as soon as the SKU lines are saved
--     (the lines are saved after the header, in their own request, so this runs on order_items). Admin can
--     approve the rate right away; else the Sales Head's approval sends it to Admin again (2.).
CREATE OR REPLACE FUNCTION public.lwb_rate_po_punch()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_b jsonb; v_msg text;
BEGIN
  IF auth.uid() IS NULL OR public.lwb_price_admin() THEN RETURN NULL; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  IF NOT FOUND OR lower(btrim(coalesce(v_o.status,''))) NOT IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new') THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_rate_approvals a WHERE a.order_id = v_o.id) THEN RETURN NULL; END IF;  -- already told / OK
  IF public.lwb_quick_slip_company(v_o.id) IS NOT NULL THEN RETURN NULL; END IF;  -- Rajnigandha slip: own flow
  v_b := public.lwb_rate_breaches(v_o.id);
  IF jsonb_array_length(v_b) = 0 THEN RETURN NULL; END IF;

  INSERT INTO public.lwb_rate_approvals (order_id, status, slip, requested_by, requested_at)
  VALUES (v_o.id, 'WAITING', '{}'::jsonb, auth.uid(), now()) ON CONFLICT (order_id) DO NOTHING;
  v_msg := coalesce(v_o.order_no,'PO') || ' · ' || coalesce(btrim(v_o.customer_name),'') || ' · ' || coalesce(v_o.sales_person,'') || ' · ' ||
    (SELECT string_agg((x->>'sku') || ' ₹' || (x->>'rate') || ' (min ₹' || (x->>'min_rate') || ')', ', ') FROM jsonb_array_elements(v_b) x);
  BEGIN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, 'Rate below min — Admin OK needed', v_msg, 'PO_RATE_APPROVAL', v_o.id
    FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'admin';
  EXCEPTION WHEN others THEN NULL;  -- a popup never stops the PO
  END;
  RETURN NULL;
END;
$fn$;
DROP TRIGGER IF EXISTS lwb_rate_po_punch ON public.order_items;
CREATE CONSTRAINT TRIGGER lwb_rate_po_punch AFTER INSERT OR UPDATE OF rate, sku_name ON public.order_items
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.lwb_rate_po_punch();

-- ---------------------------------------------------------------------------
-- 3. Line guard: after a slip, or on a PO approved earlier (not in this same save), only Admin can put a
--    line below min.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_rate_item_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_min numeric; v_o public.orders%ROWTYPE; v_locked boolean;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.rate IS NOT DISTINCT FROM OLD.rate AND NEW.sku_name IS NOT DISTINCT FROM OLD.sku_name THEN RETURN NEW; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  v_locked := EXISTS (SELECT 1 FROM public.lwb_quick_slips s WHERE s.order_id = NEW.order_id)
    OR (FOUND AND lower(btrim(coalesce(v_o.status,''))) NOT IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new','cancelled','canceled')
        AND v_o.approved_at IS DISTINCT FROM now());
  IF NOT v_locked THEN RETURN NEW; END IF;
  SELECT l.min_rate INTO v_min FROM public.lwb_sku_price_limits l WHERE l.sku_key = upper(btrim(NEW.sku_name));
  IF v_min IS NOT NULL AND coalesce(NEW.rate, 0) < v_min AND auth.uid() IS NOT NULL AND NOT public.lwb_price_admin()
     AND (TG_OP = 'INSERT' OR coalesce(NEW.rate, 0) < coalesce(OLD.rate, 0) OR NEW.sku_name IS DISTINCT FROM OLD.sku_name) THEN
    RAISE EXCEPTION 'RATE_BELOW_MIN: % ₹% is below the min ₹%. Only Admin can give this rate.', NEW.sku_name, coalesce(NEW.rate, 0), v_min;
  END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_quick_slips s WHERE s.order_id = NEW.order_id) THEN
    INSERT INTO public.lwb_order_landing (order_id, sku_key, landing)
    SELECT NEW.order_id, l.sku_key, l.landing FROM public.lwb_sku_price_limits l
    WHERE l.sku_key = upper(btrim(NEW.sku_name)) AND l.landing IS NOT NULL
    ON CONFLICT (order_id, sku_key) DO NOTHING;
  END IF;
  RETURN NEW;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. Waiting list (both brands) and Admin's Approve
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_rate_waiting()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_admin boolean := public.lwb_price_admin(); v_see boolean := public.lwb_price_can_see();
        v_role text := public.lwb_quick_slip_role();
BEGIN
  IF v_role NOT IN ('admin','manager','sales','salesman') THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'order_id', o.id, 'order_no', o.order_no, 'order_date', o.order_date, 'party', btrim(o.customer_name),
      'sales_person', o.sales_person, 'status', o.status, 'requested_at', a.requested_at, 'note', a.note,
      'driver_name', a.slip->>'driver_name', 'vehicle_no', a.slip->>'vehicle_no', 'can_approve', v_admin,
      'slip', public.lwb_quick_slip_company(o.id) IS NOT NULL, 'transportation', o.transportation,
      'brand', (SELECT c.name FROM public.order_items i JOIN public.sku_master s ON upper(btrim(s.sku_name)) = upper(btrim(i.sku_name))
                JOIN public.lwb_companies c ON c.id = s.company_id WHERE i.order_id = o.id LIMIT 1),
      'lines', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'sku', i.sku_name, 'qty', coalesce(i.approved_qty, i.ordered_qty, 0), 'rate', coalesce(i.rate, 0),
                  'min_rate', l.min_rate,
                  'landing', CASE WHEN v_see THEN l.landing END) ORDER BY i.sku_name), '[]'::jsonb)
                FROM public.order_items i LEFT JOIN public.lwb_sku_price_limits l ON l.sku_key = upper(btrim(i.sku_name))
                WHERE i.order_id = o.id)) ORDER BY a.requested_at DESC)
    FROM public.lwb_rate_approvals a JOIN public.orders o ON o.id = a.order_id
    WHERE a.status = 'WAITING'
      AND NOT EXISTS (SELECT 1 FROM public.lwb_quick_slips s WHERE s.order_id = o.id)
      AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected')
      AND (v_role IN ('admin','manager') OR o.created_by = auth.uid())
      AND public.lwb_company_ok(public.lwb_quick_slip_company(o.id))), '[]'::jsonb);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_rate_approve(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_a public.lwb_rate_approvals%ROWTYPE; v_r jsonb; v_o public.orders%ROWTYPE; v_slip boolean;
BEGIN
  IF NOT public.lwb_price_admin() THEN RAISE EXCEPTION 'Only Admin can approve the rate.'; END IF;
  SELECT * INTO v_a FROM public.lwb_rate_approvals WHERE order_id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This PO is not waiting for a rate OK.'; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF lower(btrim(coalesce(v_o.status,''))) IN ('cancelled','canceled','rejected') THEN
    RAISE EXCEPTION 'PO % is %.', v_o.order_no, v_o.status;
  END IF;
  v_slip := public.lwb_quick_slip_company(p_order_id) IS NOT NULL;
  UPDATE public.lwb_rate_approvals SET status = 'APPROVED', approved_by = auth.uid(), approved_at = now() WHERE order_id = p_order_id;
  IF v_slip THEN
    v_r := public.lwb_quick_slip_dispatch(p_order_id, v_a.slip);
  ELSE
    UPDATE public.order_items SET approved_qty = coalesce(approved_qty, ordered_qty, 0) WHERE order_id = p_order_id;
    IF lower(btrim(coalesce(v_o.status,''))) IN ('','pending','submitted','pending_manager','pending_approval','pending_review','new') THEN
      UPDATE public.orders SET status = 'approved', approved_by = auth.uid(), approved_at = now() WHERE id = p_order_id;
    END IF;
    v_r := jsonb_build_object('order_id', v_o.id, 'order_no', v_o.order_no, 'status', 'approved');
  END IF;
  BEGIN
    UPDATE public.erp_notifications SET is_read = true WHERE order_id = p_order_id AND is_read = false AND notification_type IN ('RATE_APPROVAL','PO_RATE_APPROVAL');
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT DISTINCT u, CASE WHEN v_slip THEN 'Rate OK by Admin — slip made' ELSE 'Rate OK by Admin — PO approved' END,
           coalesce(v_o.order_no,'PO') || ' · ' || coalesce(btrim(v_o.customer_name),'') ||
           CASE WHEN v_slip THEN '. Slip ready to print, sent to Accounts.' ELSE '. Assign transport next.' END,
           CASE WHEN v_slip THEN 'RATE_APPROVED' ELSE 'PO_RATE_APPROVED' END, p_order_id
    FROM unnest(ARRAY[v_a.requested_by, v_o.created_by]) u WHERE u IS NOT NULL AND u IS DISTINCT FROM auth.uid();
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN v_r;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_rate_po_route(), public.lwb_rate_po_punch(), public.lwb_rate_item_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_pack_limits_sync(jsonb), public.lwb_rate_waiting(), public.lwb_rate_approve(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_pack_limits_sync(jsonb), public.lwb_rate_waiting(), public.lwb_rate_approve(uuid) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
