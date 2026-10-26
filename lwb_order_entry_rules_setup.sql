-- LUXURY WRIST BRAND ERP — SALESMAN PO ENTRY: OWN PARTIES ONLY, RATE FOLLOWS RATE LIST
--
-- RUN ONCE in Supabase SQL Editor, after lwb_sales_team_setup.sql and
-- lwb_order_rates_setup.sql. Safe to run again.
--
-- 1. Parties: every SALES login sees and orders only the parties the Sales Head /
--    Admin assigned to him (Sales Team Setup > Parties). Only a salesman set as
--    OFFICE there sees all parties. Before this, a salesman not set up yet saw all.
-- 2. Rate: PO Entry starts from the party's last bill rate of that SKU, moved by
--    every Rate & Scheme change made since that bill. Example: last bill ₹590 when
--    Slab 3 was ₹600; Slab 3 is now ₹620 → new PO rate ₹610. A cut works the same
--    way. The party's own difference (here ₹10 below list) stays.
--
-- No order, stock, bill, payment, ledger or Tally data is changed.

BEGIN;

-- "Restricted salesman": a SALES login that is not set up as OFFICE.
-- (Name kept: every party / order rule already uses this function.)
CREATE OR REPLACE FUNCTION public.lwb_is_field_salesman()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND lower(btrim(p.role)) IN ('sales','salesman')
      AND NOT EXISTS (SELECT 1 FROM public.lwb_salesmen s WHERE s.user_id = p.id AND s.kind = 'OFFICE'));
$fn$;

-- Party's last rate per SKU from its latest non-cancelled PO, plus the Slab 3
-- rate that Rate & Scheme had at that time (slab3_then, from Rate History),
-- so PO Entry can add the change since then: [{sku, rate, order_no, order_date, slab3_then}]
CREATE OR REPLACE FUNCTION public.lwb_party_last_rates(p_customer text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_party text := upper(btrim(COALESCE(p_customer,'')));
BEGIN
  IF NOT public.lwb_po_entry_user() THEN
    RAISE EXCEPTION 'Only Admin, Manager or Salesman can read party rates';
  END IF;
  IF v_party = '' OR NOT public.lwb_party_name_visible(v_party) THEN
    RETURN '[]'::jsonb;
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('sku', x.sku, 'rate', x.rate, 'order_no', x.order_no,
      'order_date', x.order_date, 'slab3_then', th.s3) ORDER BY x.sku)
    FROM (
      SELECT DISTINCT ON (upper(btrim(i.sku_name)))
        upper(btrim(i.sku_name)) AS sku, i.rate, o.order_no, o.order_date
      FROM public.orders o
      JOIN public.order_items i ON i.order_id = o.id
      WHERE upper(btrim(o.customer_name)) = v_party
        AND lower(btrim(COALESCE(o.status,''))) NOT IN ('cancelled','canceled','rejected')
        AND i.rate > 0
        AND COALESCE(i.ordered_qty,0) > 0
      ORDER BY upper(btrim(i.sku_name)), o.order_date DESC, o.created_at DESC
    ) x
    LEFT JOIN public.lwb_rate_pack_skus l ON l.sku_key = x.sku
    LEFT JOIN public.lwb_rate_packs p ON p.id = l.pack_id
    LEFT JOIN LATERAL (
      SELECT NULLIF(r.v->>'s3','')::numeric AS s3
      FROM public.lwb_rate_history h
      CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(h.rows) = 'array' THEN h.rows ELSE '[]'::jsonb END) AS r(v)
      WHERE h.created_at <= x.order_date
        AND upper(btrim(r.v->>'name')) = upper(btrim(p.pack_name))
      ORDER BY h.created_at DESC, h.id DESC
      LIMIT 1
    ) th ON p.id IS NOT NULL
  ), '[]'::jsonb);
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_is_field_salesman(), public.lwb_party_last_rates(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_is_field_salesman(), public.lwb_party_last_rates(text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: a salesman who is not OFFICE now counts as restricted (run as that user to see true).
-- SELECT to_regprocedure('public.lwb_party_last_rates(text)') IS NOT NULL AS rates_ready;
