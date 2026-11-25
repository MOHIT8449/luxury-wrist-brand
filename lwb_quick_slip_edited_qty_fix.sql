-- LUXURY WRIST BRAND ERP — PRINT PO (Rajnigandha slip) SHOWS THE EDITED QTY
--
-- Mohit, 24 Nov 2026 (PO LXY-00606): a SKU raised 0 -> 20 in Edit PO still printed 0 on Print PO.
-- The slip (lwb_quick_slip_get) took coalesce(loaded_qty, approved_qty, ...). A line added / raised after
-- the slip was made has loaded_qty 0 (not NULL), so the slip printed 0 and the total stayed old.
-- Now the slip uses the same rule as Print PO: loaded qty when above 0, else approved qty; 0-qty lines are
-- not printed. Only this read function changes. Nothing is dropped, no data is changed. Safe to run again.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_quick_slip_get(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_s public.lwb_quick_slips%ROWTYPE; v_c public.lwb_companies%ROWTYPE; v_lines jsonb;
        v_pm text; v_pa text;
BEGIN
  IF NOT public.lwb_quick_slip_reader(p_order_id) THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Accounts, Godown or the salesman of this order can see the slip.';
  END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  SELECT * INTO v_s FROM public.lwb_quick_slips WHERE order_id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PO % has no slip (driver and vehicle not entered).', v_o.order_no; END IF;
  IF NOT public.lwb_company_ok(v_s.company_id) THEN RAISE EXCEPTION 'Order not found.'; END IF;
  SELECT * INTO v_c FROM public.lwb_companies WHERE id = v_s.company_id;
  -- Qty rule = Print PO (Mohit, 20 / 24 Nov 2026): loaded qty when it is above 0, else the approved qty
  -- (else ordered). A line added or raised in Edit PO after the slip has loaded_qty 0, so it printed 0.
  -- Lines with qty 0 are left out, like Print PO.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'sku', q.sku_name, 'qty', q.qty, 'rate', q.rate, 'amount', round(q.qty * q.rate, 2))
         ORDER BY q.sku_name), '[]'::jsonb)
    INTO v_lines
  FROM (SELECT i.sku_name,
               CASE WHEN coalesce(i.loaded_qty, 0) > 0 THEN i.loaded_qty
                    ELSE coalesce(i.approved_qty, i.ordered_qty, 0) END::numeric AS qty,
               coalesce(i.rate, 0)::numeric AS rate
        FROM public.order_items i WHERE i.order_id = p_order_id) q
  WHERE q.qty > 0;
  -- Party mobile + address from Party Master (same name, active first).
  SELECT nullif(btrim(m.mobile),''),
         nullif(concat_ws(', ', nullif(btrim(m.billing_address),''), nullif(btrim(m.city),''), nullif(btrim(m.pincode),'')),'')
    INTO v_pm, v_pa
  FROM public.lwb_customer_master m
  WHERE upper(btrim(m.customer_name)) = upper(btrim(v_o.customer_name))
  ORDER BY m.is_active DESC NULLS LAST LIMIT 1;
  RETURN jsonb_build_object(
    'order_id', v_o.id, 'order_no', v_o.order_no, 'order_date', v_o.order_date, 'party', btrim(v_o.customer_name),
    'party_mobile', v_pm, 'party_address', v_pa, 'sales_person', v_o.sales_person, 'status', v_o.status,
    'brand', v_c.name, 'unit', coalesce(v_c.pack_unit, 'CASE'),
    'driver_name', v_s.driver_name, 'driver_mobile', v_s.driver_mobile, 'vehicle_no', v_s.vehicle_no,
    'slip_at', v_s.created_at, 'print_count', v_s.print_count, 'lines', v_lines,
    'total_qty', (SELECT coalesce(sum((x->>'qty')::numeric), 0) FROM jsonb_array_elements(v_lines) x),
    'total_amount', (SELECT coalesce(sum((x->>'amount')::numeric), 0) FROM jsonb_array_elements(v_lines) x));
END;
$fn$;

COMMIT;

NOTIFY pgrst, 'reload schema';
