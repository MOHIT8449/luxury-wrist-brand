-- LUXURY WRIST BRAND ERP — "PLEASE CHECK THIS ORDER" WARNING (Coca-Cola market orders)
--
-- Runs by itself when merged to main (after lwb_rate_scheme_setup.sql, lwb_order_rates_setup.sql and
-- lwb_cc_rate_limit_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (6 Nov 2026): the order is never stopped for its rate (Admin has other profit too, and
-- sometimes a salesman gives a lower rate for his target), but Admin and the Sales Head must get a
-- warning popup: "this order came from the market, please check it once". Two reasons:
--   1. LOW MARGIN : rate < landing (excl. ROI) + "Check margin" (one ₹ amount for all packs, set by
--                   Admin on Rate & Scheme; blank = off).
--   2. WRONG SLAB : rate < the rate of the slab this order should get, e.g. a 1,500 kg order (below
--                   3 ton) with the 3 & 4 ton rate. Same slab rule as PO Entry:
--                   Shree Jagdish party = Slab 4, Self pickup = Slab 2, below 3,000 kg = Slab 1, else Slab 3
--                   (Slab 1 = Slab 3 + 5, Slab 2 and 4 = Slab 3 − 5).
--   * lwb_rate_settings.check_margin + lwb_rate_check_margin_set(p) (Admin only).
--   * lwb_rate_check_reasons(order) -> [{sku, rate, kind, need, why}].
--   * Deferred trigger on order_items: when a non-Admin saves / changes a Coca-Cola PO line, Admin and
--     the Sales Head (not the person who saved it) get one ORDER_RATE_CHECK bell / phone push. A newer
--     unread one replaces the older one. The PO itself goes on exactly as before.
--   * lwb_rate_checks: the last reasons per order (for the red mark on the order list).
-- Only erp_notifications and lwb_rate_checks rows are written. No order, stock, bill, ledger or Tally change.

BEGIN;

ALTER TABLE public.lwb_rate_settings ADD COLUMN IF NOT EXISTS check_margin numeric(12,2)
  CHECK (check_margin IS NULL OR check_margin >= 0);

CREATE TABLE IF NOT EXISTS public.lwb_rate_checks (
  order_id uuid PRIMARY KEY,
  reasons jsonb NOT NULL DEFAULT '[]'::jsonb,
  checked_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_rate_checks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_rate_checks_read ON public.lwb_rate_checks;
CREATE POLICY lwb_rate_checks_read ON public.lwb_rate_checks
  FOR SELECT TO authenticated USING (public.lwb_rate_editor());
REVOKE ALL ON TABLE public.lwb_rate_checks FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_rate_checks TO authenticated;

-- Admin sets the one "Check margin" for all packs (null = no low margin warning).
CREATE OR REPLACE FUNCTION public.lwb_rate_check_margin_set(p_margin numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_price_admin() THEN RAISE EXCEPTION 'Only Admin can set the check margin.'; END IF;
  IF p_margin < 0 THEN RAISE EXCEPTION 'Check margin can not be below 0.'; END IF;
  UPDATE public.lwb_rate_settings SET check_margin = p_margin, updated_at = now(), updated_by = auth.uid() WHERE id = 1;
END;
$fn$;

-- Why this order should be checked. Empty array = nothing to check.
CREATE OR REPLACE FUNCTION public.lwb_rate_check_reasons(p_order uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_margin numeric; v_slab integer; v_slab_name text; v_kg numeric;
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = p_order;
  IF NOT FOUND THEN RETURN '[]'::jsonb; END IF;
  SELECT s.check_margin INTO v_margin FROM public.lwb_rate_settings s WHERE s.id = 1;
  v_kg := coalesce(v_o.total_weight, 0);
  IF upper(coalesce(v_o.customer_name,'')) LIKE '%JAGDISH%' THEN v_slab := 4; v_slab_name := 'Shree Jagdish party (Slab 4)';
  ELSIF upper(btrim(coalesce(v_o.transportation,''))) = 'SELF PICKUP' THEN v_slab := 2; v_slab_name := 'Self pickup (Slab 2)';
  ELSIF v_kg > 0 AND v_kg < 3000 THEN v_slab := 1; v_slab_name := 'Below 3 ton order, ' || to_char(v_kg,'FM999999990') || ' kg (Slab 1)';
  ELSIF v_kg >= 3000 THEN v_slab := 3; v_slab_name := '3 & 4 ton order (Slab 3)';
  END IF;
  RETURN coalesce((
    SELECT jsonb_agg(x ORDER BY x->>'sku', x->>'kind') FROM (
      -- 1. low margin over landing
      SELECT jsonb_build_object('sku', upper(btrim(i.sku_name)), 'rate', i.rate, 'kind', 'margin',
               'need', round(l.landing + v_margin, 2),
               'why', 'margin ₹' || to_char(i.rate - l.landing,'FM9999990.00') || ' (check below ₹' || to_char(v_margin,'FM9999990.##') || ')') x
      FROM public.order_items i
      JOIN public.lwb_sku_price_limits l ON l.sku_key = upper(btrim(i.sku_name))
      WHERE i.order_id = p_order AND v_margin IS NOT NULL AND l.landing IS NOT NULL AND i.rate IS NOT NULL
        AND i.rate < l.landing + v_margin
      UNION ALL
      -- 2. rate below the rate of the slab this order should get
      SELECT jsonb_build_object('sku', upper(btrim(i.sku_name)), 'rate', i.rate, 'kind', 'slab',
               'need', CASE v_slab WHEN 1 THEN p.slab3_rate + 5 WHEN 3 THEN p.slab3_rate ELSE p.slab3_rate - 5 END,
               'why', v_slab_name || ' needs ₹' || to_char(CASE v_slab WHEN 1 THEN p.slab3_rate + 5 WHEN 3 THEN p.slab3_rate ELSE p.slab3_rate - 5 END,'FM9999990.##'))
      FROM public.order_items i
      JOIN public.lwb_rate_pack_skus k ON k.sku_key = upper(btrim(i.sku_name))
      JOIN public.lwb_rate_packs p ON p.id = k.pack_id AND p.active IS DISTINCT FROM false AND coalesce(p.slab3_rate,0) > 0
      WHERE i.order_id = p_order AND v_slab IS NOT NULL AND i.rate IS NOT NULL
        AND i.rate < CASE v_slab WHEN 1 THEN p.slab3_rate + 5 WHEN 3 THEN p.slab3_rate ELSE p.slab3_rate - 5 END
    ) t
  ), '[]'::jsonb);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_rate_check_po()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_r jsonb; v_old jsonb; v_msg text; v_by text;
BEGIN
  IF auth.uid() IS NULL OR public.lwb_price_admin() THEN RETURN NULL; END IF;  -- Admin's own PO: nothing to warn
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  IF NOT FOUND OR lower(btrim(coalesce(v_o.status,''))) IN ('cancelled','canceled','rejected') THEN RETURN NULL; END IF;
  IF public.lwb_quick_slip_company(v_o.id) IS NOT NULL THEN RETURN NULL; END IF;  -- Rajnigandha slip: own check
  BEGIN
    v_r := public.lwb_rate_check_reasons(v_o.id);
    SELECT c.reasons INTO v_old FROM public.lwb_rate_checks c WHERE c.order_id = v_o.id;
    IF v_old IS NOT DISTINCT FROM v_r OR (v_old IS NULL AND jsonb_array_length(v_r) = 0) THEN RETURN NULL; END IF;  -- told already
    INSERT INTO public.lwb_rate_checks (order_id, reasons, checked_at) VALUES (v_o.id, v_r, now())
    ON CONFLICT (order_id) DO UPDATE SET reasons = EXCLUDED.reasons, checked_at = now();
    DELETE FROM public.erp_notifications WHERE order_id = v_o.id AND notification_type = 'ORDER_RATE_CHECK' AND is_read = false;
    IF jsonb_array_length(v_r) = 0 THEN RETURN NULL; END IF;  -- rate corrected: old warning removed
    SELECT full_name INTO v_by FROM public.user_profiles WHERE id = auth.uid();
    v_msg := concat_ws(' · ', v_o.order_no, btrim(v_o.customer_name), coalesce(v_o.sales_person, v_by),
      (SELECT string_agg((x->>'sku') || ' ₹' || to_char((x->>'rate')::numeric,'FM9999990.##') || ' — ' || (x->>'why'), ' | ') FROM jsonb_array_elements(v_r) x));
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, 'Market order — please check once', v_msg, 'ORDER_RATE_CHECK', v_o.id
    FROM public.user_profiles p
    WHERE p.active = true AND p.id IS DISTINCT FROM auth.uid() AND lower(btrim(p.role)) IN ('admin','manager');
  EXCEPTION WHEN others THEN NULL;  -- a warning never stops the PO
  END;
  RETURN NULL;
END;
$fn$;
DROP TRIGGER IF EXISTS lwb_rate_check_po ON public.order_items;
CREATE CONSTRAINT TRIGGER lwb_rate_check_po AFTER INSERT OR UPDATE OF rate, sku_name ON public.order_items
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.lwb_rate_check_po();

REVOKE ALL ON FUNCTION public.lwb_rate_check_po(), public.lwb_rate_check_reasons(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_rate_check_margin_set(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_rate_check_margin_set(numeric) TO authenticated;

COMMIT;
