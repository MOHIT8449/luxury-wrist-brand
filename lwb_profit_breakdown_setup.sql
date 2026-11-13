-- LUXURY WRIST BRAND ERP — PROFIT BREAKDOWN ON PO SCREENS (what makes up the landing of each SKU)
--
-- Runs by itself when merged to main (after lwb_profit_view_setup.sql, lwb_rate_scheme_setup.sql,
-- lwb_order_rates_setup.sql, lwb_mepd_scheme_setup.sql and lwb_sku_category_setup.sql). Safe to run again.
-- Nothing is dropped. Read only: no order, rate, stock, ledger or Tally data is written.
--
-- Mohit asked (13 Nov 2026): in Order Review the Admin sees the profit (sale − landing) but not what was
-- counted in the landing. lwb_profit_landing() now also gives, per Coca-Cola SKU, the Rate & Scheme parts
-- of its pack: GR (chair), MEPD % used today (MEPD scheme of the SKU category, else the pack %, else the
-- default %), free bottle / OMS, QPS and ROI. The page works out each rupee with the same formula as
-- Rate & Scheme and shows it in a "Profit breakdown" popup. Same people as before: Admin always, others
-- only when Admin allowed them (lwb_price_viewers). Everyone else still gets NULL.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_profit_landing()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_admin boolean := public.lwb_price_admin();
        v_day date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
        v_set public.lwb_rate_settings%ROWTYPE;
        v_parts jsonb := '{}'::jsonb;
BEGIN
  IF NOT public.lwb_price_can_see() THEN RETURN NULL; END IF;
  SELECT * INTO v_set FROM public.lwb_rate_settings WHERE id = 1;
  SELECT coalesce(jsonb_object_agg(x.k, x.v), '{}'::jsonb) INTO v_parts FROM (
    SELECT s.sku_key AS k, jsonb_build_object(
      'pack', p.pack_name, 'category', c.category,
      'case_config', p.case_config, 'gr', p.gr, 'free_bottle', p.free_bottle, 'oms', p.oms, 'qps', p.qps,
      'slab3_rate', p.slab3_rate, 'roi', coalesce(v_set.roi_main, 0),
      'mepd_pct', coalesce(m.mepd_pct, p.mepd_pct, v_set.mepd_pct, 0),
      'mepd_from', CASE WHEN m.mepd_pct IS NOT NULL THEN 'scheme' WHEN p.mepd_pct IS NOT NULL THEN 'pack' ELSE 'default' END,
      'scheme_to', m.valid_to, 'scheme_note', m.note) AS v
    FROM public.lwb_rate_pack_skus s
    JOIN public.lwb_rate_packs p ON p.id = s.pack_id AND p.active IS NOT FALSE
    LEFT JOIN LATERAL (SELECT sm.category FROM public.sku_master sm
                       WHERE upper(btrim(sm.sku_name)) = s.sku_key AND nullif(btrim(sm.category), '') IS NOT NULL
                       LIMIT 1) c ON true
    LEFT JOIN LATERAL (SELECT ms.mepd_pct, ms.valid_to, ms.note FROM public.lwb_mepd_schemes ms
                       WHERE c.category IS NOT NULL AND v_day BETWEEN ms.valid_from AND ms.valid_to
                         AND EXISTS (SELECT 1 FROM unnest(ms.categories) x
                                     WHERE upper(regexp_replace(btrim(x), '\s+', ' ', 'g'))
                                         = upper(regexp_replace(btrim(c.category), '\s+', ' ', 'g')))
                       ORDER BY ms.created_at DESC LIMIT 1) m ON true) x;
  RETURN jsonb_build_object(
    'admin', v_admin,
    'landing', coalesce((SELECT jsonb_object_agg(x.k, x.landing) FROM (
        SELECT DISTINCT ON (upper(btrim(l.sku_key))) upper(btrim(l.sku_key)) AS k, l.landing
        FROM public.lwb_sku_price_limits l WHERE l.landing IS NOT NULL
        ORDER BY upper(btrim(l.sku_key)), l.updated_at DESC NULLS LAST) x), '{}'::jsonb),
    'parts', v_parts,
    'viewers', CASE WHEN v_admin THEN coalesce((SELECT jsonb_agg(v.user_id) FROM public.lwb_price_viewers v), '[]'::jsonb)
                    ELSE '[]'::jsonb END);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_profit_landing() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_profit_landing() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
