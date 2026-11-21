-- LUXURY WRIST BRAND ERP — SALESMAN: OFFICE ORDERS OF HIS PARTIES SHOW ONLY TOTAL QTY + TOTAL AMOUNT
--
-- Mohit (21 Nov 2026): a salesman works only on the parties given to him. The office also takes
-- orders for those parties. For such an order (taken by office / anyone else) the salesman may see
-- only the total quantity and the total amount: no rate, no SKU lines, no driver / vehicle, nothing else.
-- Nothing extra (profit / loss, other parties, rates of office orders) may reach a salesman.
--
-- Field salesman = any SALES login not set to OFFICE in Sales Team Setup (lwb_is_field_salesman()).
-- Admin, Sales Head, Accounts, Godown and OFFICE logins are not changed.
--
-- 1. order_items (database rule, RLS): a field salesman reads SKU lines (rate, qty) only of the
--    POs he took himself. The PO header (PO no., party, date, status, total qty, total amount) of his
--    parties' office POs stays readable, so My Sales / target achievement keep counting them.
-- 2. lwb_my_orders (My Orders, Dashboard): an office PO comes back with total qty + total amount
--    + status only ('office' = true, items empty, no driver / vehicle / receiver / notes / reason);
--    'brands' (brand ids of its SKUs) lets the brand filter keep it without showing the SKUs.
-- 3. Last rate / rate history in PO Entry (lwb_party_last_rates, lwb_party_sku_rate_history,
--    lwb_po_line_history): a field salesman gets rates only from his own POs, never from office POs.
--    Patched in place from the live text (same signature, same grants).
--
-- Reads / changes no data. Runs by itself when merged to main. Safe to run again.

BEGIN;

-- 1. SKU lines: own POs only for a field salesman.
DROP POLICY IF EXISTS lwb_sales_item_scope ON public.order_items;
CREATE POLICY lwb_sales_item_scope ON public.order_items AS RESTRICTIVE FOR SELECT TO authenticated
  USING (NOT public.lwb_is_field_salesman()
         OR EXISTS (SELECT 1 FROM public.orders o WHERE o.id = order_id AND o.created_by = auth.uid()));

-- 2. My Orders: office POs of my parties = totals only.
DO $do$
BEGIN
  IF to_regclass('public.lwb_admin_order_marks') IS NULL THEN
    RAISE EXCEPTION 'lwb_admin_order_marks missing: run lwb_admin_mark_load_deliver_setup.sql first';
  END IF;
  EXECUTE $sql$
CREATE OR REPLACE FUNCTION public.lwb_my_orders(p_days integer DEFAULT 45)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_field boolean := public.lwb_is_field_salesman();
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required.'; END IF;
  -- Own POs: full detail (status, delivery, SKU lines, edit / cancel before approval).
  -- Office POs of a field salesman's parties (lwb_salesman_office_order_hide_setup.sql): PO no., date,
  -- party, status, total qty, total amount and delivered or not. Nothing else.
  RETURN coalesce((
    SELECT jsonb_agg(x.j ORDER BY x.d DESC)
    FROM (
      SELECT coalesce(o.order_date, o.created_at) AS d,
        CASE WHEN o.created_by = auth.uid() THEN jsonb_build_object(
          'id', o.id, 'order_no', o.order_no, 'order_date', coalesce(o.order_date, o.created_at),
          'customer_name', o.customer_name, 'status', o.status,
          'total_qty', o.total_qty, 'total_amount', o.total_amount,
          'mine', true, 'office', false,
          'can_edit', public.lwb_order_pending(o.status),
          'cancel_reason', o.cancel_reason, 'cancelled_at', o.cancelled_at,
          'driver_name', a.driver_name, 'vehicle_no', a.vehicle_no,
          'delivery_status', ds.st, 'delivered_at', ds.at,
          'delivery_marked', r.delivery_status IS DISTINCT FROM 'DELIVERED' AND r.delivery_status IS DISTINCT FROM 'PARTIAL'
              AND (m.at IS NOT NULL OR lower(btrim(coalesce(o.status,''))) IN ('delivered','closed','completed')),
          'received_by', r.received_by,
          'delivery_note', CASE WHEN r.delivery_status IN ('DELIVERED','PARTIAL') THEN r.delivery_note
              WHEN m.at IS NOT NULL THEN coalesce(nullif(btrim(m.note),''), 'Marked delivered by office')
              ELSE r.delivery_note END,
          'brands', br.ids,
          'items', (SELECT coalesce(jsonb_agg(jsonb_build_object(
              'id', i.id, 'sku_name', i.sku_name, 'ordered_qty', i.ordered_qty,
              'approved_qty', i.approved_qty, 'loaded_qty', i.loaded_qty, 'rate', i.rate,
              'entry_uom', i.entry_uom, 'ordered_pallet_qty', i.ordered_pallet_qty) ORDER BY i.id), '[]'::jsonb)
            FROM public.order_items i WHERE i.order_id = o.id))
        ELSE jsonb_build_object(
          'id', o.id, 'order_no', o.order_no, 'order_date', coalesce(o.order_date, o.created_at),
          'customer_name', o.customer_name, 'status', o.status,
          'total_qty', o.total_qty, 'total_amount', o.total_amount,
          'mine', false, 'office', true, 'can_edit', false,
          'delivery_status', ds.st, 'delivered_at', ds.at,
          'delivery_marked', r.delivery_status IS DISTINCT FROM 'DELIVERED' AND r.delivery_status IS DISTINCT FROM 'PARTIAL'
              AND (m.at IS NOT NULL OR lower(btrim(coalesce(o.status,''))) IN ('delivered','closed','completed')),
          'brands', br.ids, 'items', '[]'::jsonb)
        END AS j
      FROM public.orders o
      LEFT JOIN LATERAL (SELECT da.driver_name, da.vehicle_no FROM public.dispatch_assignments da
        WHERE da.order_id = o.id ORDER BY da.id DESC LIMIT 1) a ON true
      LEFT JOIN public.lwb_delivery_reports r ON r.order_id = o.id
      LEFT JOIN LATERAL (
        SELECT CASE WHEN mk.mark_date = (mk.marked_at AT TIME ZONE 'Asia/Kolkata')::date THEN mk.marked_at
                    ELSE (mk.mark_date + time '12:00') AT TIME ZONE 'Asia/Kolkata' END AS at, mk.note
        FROM public.lwb_admin_order_marks mk
        WHERE mk.order_id = o.id AND mk.kind = 'DELIVERED' LIMIT 1) m ON true
      LEFT JOIN LATERAL (SELECT
          CASE WHEN r.delivery_status IN ('DELIVERED','PARTIAL') THEN r.delivery_status
               WHEN m.at IS NOT NULL OR lower(btrim(coalesce(o.status,''))) IN ('delivered','closed','completed') THEN 'DELIVERED'
               ELSE r.delivery_status END AS st,
          CASE WHEN r.delivery_status IN ('DELIVERED','PARTIAL') THEN r.reported_at
               WHEN m.at IS NOT NULL THEN m.at
               ELSE r.reported_at END AS at) ds ON true
      LEFT JOIN LATERAL (SELECT coalesce(jsonb_agg(DISTINCT s.company_id) FILTER (WHERE s.company_id IS NOT NULL), '[]'::jsonb) AS ids
        FROM public.order_items i
        JOIN public.sku_master s ON upper(btrim(s.sku_name)) = upper(btrim(i.sku_name))
        WHERE i.order_id = o.id) br ON true
      WHERE coalesce(o.order_date, o.created_at) >= now() - make_interval(days => greatest(1, least(coalesce(p_days,45), 400)))
        AND (o.created_by = auth.uid()
             OR (v_field AND upper(btrim(coalesce(o.customer_name,''))) IN (SELECT public.lwb_my_party_names())))
    ) x
  ), '[]'::jsonb);
END;
$fn$;
  $sql$;
END;
$do$;
REVOKE ALL ON FUNCTION public.lwb_my_orders(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_my_orders(integer) TO authenticated;

-- 3. Rates shown in PO Entry: a field salesman only sees rates of his own POs.
DO $do$
DECLARE f text; p regprocedure; d text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.lwb_party_last_rates(text)', 'public.lwb_party_sku_rate_history(text,text)',
                           'public.lwb_po_line_history(text,text)'] LOOP
    p := to_regprocedure(f);
    IF p IS NULL THEN RAISE NOTICE '% not installed: skipped', f; CONTINUE; END IF;
    d := pg_get_functiondef(p);
    IF position('lwb_office_rate_hidden' IN d) > 0 THEN CONTINUE; END IF;  -- already patched
    IF position('AND i.rate > 0' IN d) = 0 THEN RAISE EXCEPTION '% changed on live: patch it by hand', f; END IF;
    d := replace(d, 'AND i.rate > 0',
      'AND (NOT public.lwb_is_field_salesman() OR o.created_by = auth.uid()) /* lwb_office_rate_hidden */ AND i.rate > 0');
    EXECUTE d;
  END LOOP;
END;
$do$;

COMMIT;

NOTIFY pgrst, 'reload schema';
