-- LUXURY WRIST BRAND ERP — SKU LAST SALE (non-moving stock on Inventory) (17 Nov 2026)
--
-- Applied automatically when the PR is merged. Safe to run again. Read only: nothing is written.
--
-- Mohit: on Inventory, highlight items that have not sold for many days.
-- lwb_sku_last_sale() = per SKU name (upper, trimmed): last PO date it was on, cases / IC on POs in
-- the last 30 and 90 days. Qty = loaded, else approved, else ordered. Cancelled / rejected / draft /
-- deleted POs do not count. Only SKU names, dates and totals (no party, rate or amount).
-- Readable by the roles that open Inventory: Admin, Sales Head, Godown Manager, Accounts.

CREATE OR REPLACE FUNCTION public.lwb_sku_last_sale()
RETURNS TABLE(sku_key text, last_date date, qty_30 numeric, qty_90 numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  WITH l AS (
    SELECT upper(btrim(j->>'sku_name')) AS k,
           coalesce(nullif(oj->>'order_date','')::timestamptz AT TIME ZONE 'Asia/Kolkata',
                    nullif(oj->>'created_at','')::timestamptz AT TIME ZONE 'Asia/Kolkata')::date AS d,
           greatest(coalesce(nullif(j->>'loaded_qty','')::numeric, nullif(j->>'approved_qty','')::numeric,
                             nullif(j->>'ordered_qty','')::numeric, 0), 0) AS q
    FROM public.orders o
    JOIN public.order_items i ON i.order_id = o.id
    CROSS JOIN LATERAL to_jsonb(o) oj
    CROSS JOIN LATERAL to_jsonb(i) j
    WHERE EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                    AND lower(btrim(p.role)) IN ('admin','manager','warehouse','accounts'))
      AND lower(btrim(coalesce(o.status::text,''))) NOT IN ('cancelled','canceled','rejected','draft','deleted')
      AND btrim(coalesce(j->>'sku_name','')) <> ''
  )
  SELECT l.k, max(l.d),
         coalesce(sum(l.q) FILTER (WHERE l.d > (now() AT TIME ZONE 'Asia/Kolkata')::date - 30), 0),
         coalesce(sum(l.q) FILTER (WHERE l.d > (now() AT TIME ZONE 'Asia/Kolkata')::date - 90), 0)
  FROM l WHERE l.q > 0 GROUP BY l.k;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sku_last_sale() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sku_last_sale() TO authenticated;
