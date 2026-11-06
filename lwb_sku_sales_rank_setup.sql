-- LUXURY WRIST BRAND ERP — SKU LIST: BEST-SELLING FIRST
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again. Read only: nothing is written.
--
-- Mohit (6 Nov 2026): in the SKU drop-down the SKU that sells the most must come first,
-- SKUs that do not sell go last.
--
-- lwb_sku_sales_rank(p_days) = per SKU name (upper, trimmed) the cases / IC sold in the last
-- p_days days (default 90) and on how many POs. Qty = loaded, else approved, else ordered.
-- Cancelled / rejected / draft / deleted POs do not count. Any active login can read it
-- (only SKU names and totals: no party, no rate, no amount), so every salesman gets the
-- same order. The list is already split by brand on the page, so the order is per brand.

CREATE OR REPLACE FUNCTION public.lwb_sku_sales_rank(p_days integer DEFAULT 90)
RETURNS TABLE(sku_key text, qty numeric, po_count bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT upper(btrim(j->>'sku_name')),
         sum(greatest(coalesce(nullif(j->>'loaded_qty','')::numeric, nullif(j->>'approved_qty','')::numeric,
                               nullif(j->>'ordered_qty','')::numeric, 0), 0)),
         count(DISTINCT o.id)
  FROM public.orders o
  JOIN public.order_items i ON i.order_id = o.id
  CROSS JOIN LATERAL to_jsonb(o) oj
  CROSS JOIN LATERAL to_jsonb(i) j
  WHERE EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true)
    AND lower(btrim(coalesce(o.status::text,''))) NOT IN ('cancelled','canceled','rejected','draft','deleted')
    AND coalesce(nullif(oj->>'order_date','')::date, nullif(oj->>'created_at','')::timestamptz::date)
        >= (now() AT TIME ZONE 'Asia/Kolkata')::date - greatest(least(coalesce(p_days, 90), 730), 1)
    AND btrim(coalesce(j->>'sku_name','')) <> ''
  GROUP BY 1;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sku_sales_rank(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sku_sales_rank(integer) TO authenticated;
