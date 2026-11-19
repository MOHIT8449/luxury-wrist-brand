-- LUXURY WRIST BRAND ERP — MARKET ORDER CHECK: "WRONG SLAB" WARNING REMOVED
--
-- Runs by itself when merged to main (after lwb_rate_check_setup.sql and lwb_rate_slabs_setup.sql).
-- Safe to run again. Nothing is dropped.
--
-- Mohit asked (17 Nov 2026): remove the "Below 3 Ton order, 1729 kg needs ₹620" / "3 & 4 Ton order ...
-- needs ₹615" lines from Approvals > Market order check. Only the LOW MARGIN reason stays
-- (rate < landing + "Check margin"; blank Check margin = off).
--   * lwb_rate_check_reasons(order): margin reasons only. The slab list, slab rates and PO Entry
--     are not touched.
--   * Orders already warned: reasons worked out again. Only slab reasons -> the unread bell is removed
--     and the red mark goes. Margin reasons too -> the unread bell keeps only the margin lines.
-- Only erp_notifications and lwb_rate_checks rows are changed. No order, stock, bill, ledger or Tally change.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_rate_check_reasons(p_order uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_margin numeric;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.orders WHERE id = p_order) THEN RETURN '[]'::jsonb; END IF;
  SELECT s.check_margin INTO v_margin FROM public.lwb_rate_settings s WHERE s.id = 1;
  IF v_margin IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(x ORDER BY x->>'sku') FROM (
      SELECT jsonb_build_object('sku', upper(btrim(i.sku_name)), 'rate', i.rate, 'kind', 'margin',
               'need', round(l.landing + v_margin, 2),
               'why', 'margin ₹' || to_char(i.rate - l.landing,'FM9999990.00') || ' (check below ₹' || to_char(v_margin,'FM9999990.##') || ')') x
      FROM public.order_items i
      JOIN public.lwb_sku_price_limits l ON l.sku_key = upper(btrim(i.sku_name))
      WHERE i.order_id = p_order AND l.landing IS NOT NULL AND i.rate IS NOT NULL
        AND i.rate < l.landing + v_margin
    ) t
  ), '[]'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_rate_check_reasons(uuid) FROM PUBLIC, anon, authenticated;

-- Clean the warnings that were already sent with a slab reason.
DO $do$
DECLARE c record; v_r jsonb; v_o public.orders%ROWTYPE; v_why text;
BEGIN
  FOR c IN SELECT order_id FROM public.lwb_rate_checks
           WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(reasons) x WHERE x->>'kind' = 'slab') LOOP
    v_r := public.lwb_rate_check_reasons(c.order_id);
    UPDATE public.lwb_rate_checks SET reasons = v_r, checked_at = now() WHERE order_id = c.order_id;
    IF jsonb_array_length(v_r) = 0 THEN
      DELETE FROM public.erp_notifications
      WHERE order_id = c.order_id AND notification_type = 'ORDER_RATE_CHECK' AND is_read = false;
    ELSE
      SELECT * INTO v_o FROM public.orders WHERE id = c.order_id;
      v_why := (SELECT string_agg((x->>'sku') || ' ₹' || to_char((x->>'rate')::numeric,'FM9999990.##') || ' — ' || (x->>'why'), ' | ')
                FROM jsonb_array_elements(v_r) x);
      -- keep "PO · party · salesman" from the old message, only the reasons change
      UPDATE public.erp_notifications n
      SET message = concat_ws(' · ', nullif(array_to_string((string_to_array(n.message, ' · '))[1:3], ' · '), ''), v_why)
      WHERE n.order_id = c.order_id AND n.notification_type = 'ORDER_RATE_CHECK' AND n.is_read = false;
    END IF;
  END LOOP;
END;
$do$;

COMMIT;
