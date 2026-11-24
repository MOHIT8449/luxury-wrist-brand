-- LUXURY WRIST BRAND ERP — BILLS TO MAKE: PO MISSING UNDER A BRAND
--
-- Runs by itself when merged to main (after lwb_brand_money_setup.sql, lwb_sku_alias_setup.sql and
-- lwb_bill_before_loading_setup.sql). Safe to run again. Nothing is dropped or deleted.
--
-- Mohit (23 Nov 2026): LXY-00560 (KISMAT TOBECO, Rajnigandha, loaded, Sales Head marked Delivered) shows
-- "Tally bill pending (Accounts)" but was not in Accounts > Bills to make with Rajnigandha picked.
-- Reason: the brand of a PO on the billing pages (lwb_order_company) matched SKU lines to SKU Master only by the
-- exact name. The PO list matches like LWBBrand.skuMap: exact name, else the SKU's current name after a rename
-- (lwb_sku_alias), else the same words in another order. A PO line saved with an old / re-ordered SKU name gave
-- NULL brand, so the PO showed under "All brands" only.
--   * lwb_order_company: same three-step match as the PO list (a line whose exact name has no company falls
--     through to the next step). Still NULL when the lines are of two brands or of none.
--   * lwb_bills_before_loading: + company_id, so approved POs not loaded yet can be filtered by brand too
--     (they were hidden whenever a brand was picked).
-- No order, stock, bill amount, payment, ledger or Tally data is changed by this file.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_order_company(p_order_id uuid)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  WITH l AS (
    SELECT coalesce(
             (SELECT s.company_id FROM public.sku_master s
              WHERE upper(btrim(s.sku_name)) = upper(btrim(i.sku_name)) AND s.company_id IS NOT NULL LIMIT 1),
             (SELECT s.company_id FROM public.lwb_sku_alias a JOIN public.sku_master s ON s.id = a.sku_id
              WHERE a.alias_key = upper(btrim(i.sku_name)) AND s.company_id IS NOT NULL LIMIT 1),
             (SELECT s.company_id FROM public.sku_master s
              WHERE public.lwb_sku_words(s.sku_name) = public.lwb_sku_words(i.sku_name) AND s.company_id IS NOT NULL LIMIT 1)) AS c
    FROM public.order_items i
    WHERE i.order_id = p_order_id AND nullif(btrim(coalesce(i.sku_name,'')),'') IS NOT NULL
  )
  SELECT CASE WHEN count(DISTINCT c) = 1 THEN (array_agg(DISTINCT c) FILTER (WHERE c IS NOT NULL))[1] END FROM l;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_company(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_company(uuid) TO authenticated;

-- Approved POs not billed yet (Accounts / Admin): Bills to make, before loading. + company_id.
CREATE OR REPLACE FUNCTION public.lwb_bills_before_loading()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN RAISE EXCEPTION 'Active Admin / Accounts role required.'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'order_id', o.id, 'order_no', o.order_no, 'party', btrim(o.customer_name::text),
      'status', lower(btrim(coalesce(o.status::text,''))), 'order_date', o.order_date::date,
      'approved_at', o.approved_at, 'priority', o.priority,
      'company_id', public.lwb_order_company(o.id),
      'qty', (SELECT coalesce(sum(coalesce(i.approved_qty, i.ordered_qty)),0) FROM public.order_items i WHERE i.order_id = o.id),
      'erp_amount', (SELECT coalesce(round(sum(coalesce(i.approved_qty, i.ordered_qty, 0)::numeric * coalesce(i.rate,0)::numeric),2),0)
                     FROM public.order_items i WHERE i.order_id = o.id),
      'vehicle_no', a.vehicle_no, 'driver_name', a.driver_name)
      ORDER BY o.approved_at DESC NULLS LAST, o.order_date DESC, o.order_no)
    FROM public.orders o
    LEFT JOIN LATERAL (SELECT x.vehicle_no, x.driver_name FROM public.dispatch_assignments x
                       WHERE x.order_id = o.id LIMIT 1) a ON true
    WHERE lower(btrim(coalesce(o.status::text,''))) IN
          ('approved','approved_next','manager_approved','warehouse_approved','transport_allocated','allocated','loading')
      AND o.order_date::date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - 60
      AND NOT EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = o.id)), '[]'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bills_before_loading() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_bills_before_loading() TO authenticated;

COMMIT;
