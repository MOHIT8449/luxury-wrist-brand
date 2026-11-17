-- LUXURY WRIST BRAND ERP — ORDER REVIEW ⓘ QTY / RATE HISTORY (last 5 earlier POs of one item for the PO's party)
--
-- Runs by itself when merged to main (after lwb_party_rate_history_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (17 Nov 2026): in Order Review (PO / Sales Orders popup, "SKU Verification & Modification")
-- an ⓘ next to QTY and next to RATE, showing that party's last 5 orders of that item: date, qty, rate.
--   * lwb_po_line_history(order_id, sku) -> [{order_no, order_date, qty, rate, status}], newest first, at most 5.
--     The party is taken from the PO itself, and that same PO is left out, so only earlier history shows.
--     Qty is the approved qty (ordered qty if not approved yet). Cancelled / rejected POs are left out.
--     Same rights as lwb_party_sku_rate_history (PO Entry ⓘ): Admin, Sales Head, Salesman; a field
--     salesman only for his own parties. The page shows the ⓘ to Admin only for now.
-- Read only. No order, rate, stock, bill, ledger or Tally change.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_po_line_history(p_order_id text, p_sku text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_sku text := upper(btrim(coalesce(p_sku,''))); v_party text;
BEGIN
  IF NOT public.lwb_po_entry_user() THEN RAISE EXCEPTION 'Only Admin, Manager or Salesman can read party rates'; END IF;
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
