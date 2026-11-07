-- LUXURY WRIST BRAND ERP — "SHOW PROFIT" ON PO SCREENS (Admin always, others only when Admin allows)
--
-- Runs by itself when merged to main (after lwb_rajni_rate_limit_setup.sql and lwb_cc_rate_limit_setup.sql).
-- Safe to run again. Nothing is dropped. Read only: no order, rate, stock, ledger or Tally data is written.
--
-- Mohit asked (7 Nov 2026): on Order Review / New PO, Admin sees the profit of every SKU line
-- (sale rate − landing, e.g. landing 440, sale 465 → ₹25 per case) in a different colour, with a top-bar
-- "Profit" ON/OFF switch on every page. A Sales Head (or any other login) sees it only when Admin allows
-- that person (same list as "Who can see Landing & Profit": lwb_price_viewers).
--
--   * lwb_profit_landing(): for Admin or an allowed person, the landing per SKU (lwb_sku_price_limits:
--     Rajnigandha Rate List + Coca-Cola Rate & Scheme sync); for Admin also the allowed people.
--     Everyone else gets NULL (never the landing).

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_profit_landing()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_admin boolean := public.lwb_price_admin();
BEGIN
  IF NOT public.lwb_price_can_see() THEN RETURN NULL; END IF;
  RETURN jsonb_build_object(
    'admin', v_admin,
    'landing', coalesce((SELECT jsonb_object_agg(x.k, x.landing) FROM (
        SELECT DISTINCT ON (upper(btrim(l.sku_key))) upper(btrim(l.sku_key)) AS k, l.landing
        FROM public.lwb_sku_price_limits l WHERE l.landing IS NOT NULL
        ORDER BY upper(btrim(l.sku_key)), l.updated_at DESC NULLS LAST) x), '{}'::jsonb),
    'viewers', CASE WHEN v_admin THEN coalesce((SELECT jsonb_agg(v.user_id) FROM public.lwb_price_viewers v), '[]'::jsonb)
                    ELSE '[]'::jsonb END);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_profit_landing() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_profit_landing() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
