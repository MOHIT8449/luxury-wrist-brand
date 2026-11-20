-- LUXURY WRIST BRAND ERP — ORDER REVIEW ⓘ QTY / RATE HISTORY: ACCOUNTS CAN READ IT TOO
--
-- Runs by itself when merged to main (after lwb_po_review_line_history_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (19 Nov 2026): Sales Head and Accounts both must see the ⓘ last 5 orders (date, qty, rate)
-- in Order Review. Sales Head already could (lwb_po_entry_user). This lets an active Accounts user read
-- lwb_po_line_history as well. Same output as before. Read only. No order, rate, stock, bill, ledger or Tally change.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_po_line_history(p_order_id text, p_sku text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_sku text := upper(btrim(coalesce(p_sku,''))); v_party text;
BEGIN
  IF NOT (public.lwb_po_entry_user() OR EXISTS (SELECT 1 FROM public.user_profiles p
      WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'accounts')) THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Accounts or Salesman can read party rates'; END IF;
  SELECT upper(btrim(coalesce(o.customer_name,''))) INTO v_party FROM public.orders o WHERE o.id::text = btrim(coalesce(p_order_id,''));
  IF coalesce(v_party,'') = '' OR v_sku = '' OR NOT public.lwb_party_name_visible(v_party) THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('order_no', x.order_no, 'order_date', x.order_date, 'qty', x.qty,
             'rate', x.rate, 'status', x.status) ORDER BY x.order_date DESC, x.created_at DESC)
    FROM (
      SELECT o.order_no, o.order_date, o.created_at, i.rate, sum(coalesce(i.approved_qty, i.ordered_qty)) AS qty, o.status
      FROM public.orders o
      JOIN public.order_items i ON i.order_id = o.id
      WHERE upper(btrim(o.customer_name)) = v_party
        AND o.id::text <> btrim(p_order_id)
        AND upper(btrim(i.sku_name)) = v_sku
        AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected')
        AND i.rate > 0 AND coalesce(i.approved_qty, i.ordered_qty, 0) > 0
      GROUP BY o.id, o.order_no, o.order_date, o.created_at, i.rate, o.status
      ORDER BY o.order_date DESC, o.created_at DESC
      LIMIT 5
    ) x
  ), '[]'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_line_history(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_line_history(text, text) TO authenticated;

COMMIT;
