-- LUXURY WRIST BRAND ERP — PO ENTRY ⓘ RATE HISTORY (last 5 rates of one item for one party)
--
-- Runs by itself when merged to main (after lwb_order_rates_setup.sql and lwb_sales_team_setup.sql).
-- Safe to run again. Nothing is dropped.
--
-- Mohit asked (17 Nov 2026): next to the rate box in PO Entry an ⓘ button, so the salesman sees which
-- rates this party got for this item the last 5 times.
--   * lwb_party_sku_rate_history(party, sku) -> [{order_no, order_date, qty, rate, status}], newest first,
--     at most 5. Cancelled / rejected POs are left out. Same rights as lwb_party_last_rates: Admin,
--     Sales Head, Salesman; a field salesman only for his own parties. Rate only, never landing / margin.
-- Read only. No order, rate, stock, bill, ledger or Tally change.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_party_sku_rate_history(p_customer text, p_sku text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_party text := upper(btrim(coalesce(p_customer,''))); v_sku text := upper(btrim(coalesce(p_sku,'')));
BEGIN
  IF NOT public.lwb_po_entry_user() THEN RAISE EXCEPTION 'Only Admin, Manager or Salesman can read party rates'; END IF;
  IF v_party = '' OR v_sku = '' OR NOT public.lwb_party_name_visible(v_party) THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('order_no', x.order_no, 'order_date', x.order_date, 'qty', x.qty,
             'rate', x.rate, 'status', x.status) ORDER BY x.order_date DESC, x.created_at DESC)
    FROM (
      SELECT o.order_no, o.order_date, o.created_at, i.rate, i.ordered_qty AS qty, o.status
      FROM public.orders o
      JOIN public.order_items i ON i.order_id = o.id
      WHERE upper(btrim(o.customer_name)) = v_party
        AND upper(btrim(i.sku_name)) = v_sku
        AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected')
        AND i.rate > 0 AND coalesce(i.ordered_qty,0) > 0
      ORDER BY o.order_date DESC, o.created_at DESC
      LIMIT 5
    ) x
  ), '[]'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_sku_rate_history(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_sku_rate_history(text, text) TO authenticated;

COMMIT;
