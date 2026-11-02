-- LUXURY WRIST BRAND ERP — RAJNIGANDHA QUICK SLIP (kachcha parchi) FLOW
--
-- Runs by itself when merged to main (after lwb_company_brand_setup.sql, lwb_head_po_auto_approval_setup.sql,
-- lwb_loading_workflow_setup.sql and lwb_bill_before_loading_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (2 Nov 2026): Coca-Cola POs keep the full flow. A Rajnigandha PO (Sales Head Vinesh) is made,
-- the driver name and vehicle no. are typed at once, a small thermal slip (3x4 / 2x4 inch) is printed with
-- date, party, driver, vehicle, SKU, rate, qty and total, and the PO goes straight to Accounts for the Tally
-- bill. No approval, transport assignment or loading in between.
--
--   * lwb_companies.quick_slip: brands that use this flow (set ON for RAJNIGANDHA when the column is added;
--     Admin can change it later).
--   * lwb_quick_slips: one row per PO: driver, vehicle (driver mobile optional, not on the slip), prints.
--     The slip shows the party name, mobile and address from Party Master (Mohit, 2 Nov 2026).
--   * lwb_quick_slip_dispatch(order, p): Admin / Sales Head, on an approved PO whose every SKU is of one
--     quick-slip brand. Saves the driver + vehicle, sets loaded_qty = approved qty and status = 'loaded'
--     (stock goes out the same way as a normal loading), so Accounts gets the "Make Tally bill" popup and
--     the PO shows on Billing / Tally bill pages. Called again on a slip PO it only corrects driver / vehicle.
--   * lwb_quick_slip_get(order), lwb_quick_slip_printed(order), lwb_quick_slip_list(from, to): slip page.
-- No Tally, ledger, payment or bill amount is written here.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Which brands use the quick slip flow
-- ---------------------------------------------------------------------------
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                 AND table_name = 'lwb_companies' AND column_name = 'quick_slip') THEN
    ALTER TABLE public.lwb_companies ADD COLUMN quick_slip boolean NOT NULL DEFAULT false;
    UPDATE public.lwb_companies SET quick_slip = true WHERE upper(btrim(name)) = 'RAJNIGANDHA';
  END IF;
END
$do$;

-- ---------------------------------------------------------------------------
-- 2. Slip table (read and written only through the functions below)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_quick_slips (
  order_id        uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  company_id      uuid REFERENCES public.lwb_companies(id),
  driver_name     text NOT NULL CHECK (length(btrim(driver_name)) BETWEEN 1 AND 80),
  driver_mobile   text CHECK (driver_mobile IS NULL OR driver_mobile ~ '^[6-9][0-9]{9}$'),
  vehicle_no      text NOT NULL CHECK (length(vehicle_no) BETWEEN 4 AND 20),
  print_count     integer NOT NULL DEFAULT 0,
  last_printed_at timestamptz,
  created_by      uuid NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid,
  updated_at      timestamptz
);
CREATE INDEX IF NOT EXISTS lwb_quick_slips_created_idx ON public.lwb_quick_slips (created_at DESC);
ALTER TABLE public.lwb_quick_slips ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_quick_slips FROM PUBLIC, anon, authenticated;

-- Role of the active login ('' when none).
CREATE OR REPLACE FUNCTION public.lwb_quick_slip_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce((SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true), '');
$fn$;

-- The one quick-slip brand of an order, or NULL (no lines, an SKU without brand, mixed brands, or a brand
-- that does not use quick slips).
CREATE OR REPLACE FUNCTION public.lwb_quick_slip_company(p_order_id uuid)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  WITH l AS (
    SELECT (SELECT s.company_id FROM public.sku_master s
            WHERE upper(btrim(s.sku_name)) = upper(btrim(i.sku_name)) AND s.company_id IS NOT NULL LIMIT 1) AS cid
    FROM public.order_items i WHERE i.order_id = p_order_id
  )
  SELECT CASE WHEN count(*) > 0 AND count(l.cid) = count(*) AND count(DISTINCT l.cid) = 1
              AND bool_and(coalesce(c.quick_slip, false)) THEN min(l.cid::text)::uuid END
  FROM l LEFT JOIN public.lwb_companies c ON c.id = l.cid;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. Slip data for printing
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_quick_slip_get(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_s public.lwb_quick_slips%ROWTYPE; v_c public.lwb_companies%ROWTYPE; v_lines jsonb;
        v_pm text; v_pa text;
BEGIN
  IF public.lwb_quick_slip_role() NOT IN ('admin','manager','accounts','warehouse') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Accounts or Godown can see slips.';
  END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  SELECT * INTO v_s FROM public.lwb_quick_slips WHERE order_id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PO % has no slip (driver and vehicle not entered).', v_o.order_no; END IF;
  IF NOT public.lwb_company_ok(v_s.company_id) THEN RAISE EXCEPTION 'Order not found.'; END IF;
  SELECT * INTO v_c FROM public.lwb_companies WHERE id = v_s.company_id;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'sku', i.sku_name,
           'qty', coalesce(i.loaded_qty, i.approved_qty, i.ordered_qty, 0),
           'rate', coalesce(i.rate, 0),
           'amount', round(coalesce(i.loaded_qty, i.approved_qty, i.ordered_qty, 0)::numeric * coalesce(i.rate, 0)::numeric, 2))
         ORDER BY i.sku_name), '[]'::jsonb)
    INTO v_lines FROM public.order_items i WHERE i.order_id = p_order_id;
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

-- ---------------------------------------------------------------------------
-- 4. Make the slip: driver + vehicle, PO goes straight to "loaded" (= Accounts makes the Tally bill)
-- ---------------------------------------------------------------------------
-- p = {driver_name, vehicle_no, driver_mobile (optional, not printed; Mohit: slip shows party mobile instead)}
CREATE OR REPLACE FUNCTION public.lwb_quick_slip_dispatch(p_order_id uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_st text;
  v_cid uuid;
  v_name text := left(btrim(regexp_replace(coalesce(p->>'driver_name',''), '\s+', ' ', 'g')), 80);
  v_mob text := regexp_replace(coalesce(p->>'driver_mobile',''), '\D', '', 'g');
  v_veh text := upper(regexp_replace(coalesce(p->>'vehicle_no',''), '[^A-Za-z0-9]', '', 'g'));
  v_info text;
BEGIN
  IF public.lwb_quick_slip_role() NOT IN ('admin','manager') THEN
    RAISE EXCEPTION 'Only Admin or Sales Head can make a slip.';
  END IF;
  IF v_name = '' THEN RAISE EXCEPTION 'Enter the driver name.'; END IF;
  IF length(v_veh) < 4 THEN RAISE EXCEPTION 'Enter the vehicle number.'; END IF;
  IF length(v_veh) > 20 THEN RAISE EXCEPTION 'Vehicle number is too long.'; END IF;
  IF v_mob ~ '^(91|0)[6-9][0-9]{9}$' THEN v_mob := right(v_mob, 10); END IF;
  IF v_mob <> '' AND v_mob !~ '^[6-9][0-9]{9}$' THEN RAISE EXCEPTION 'Driver mobile must be a 10-digit mobile number.'; END IF;

  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  v_st := lower(btrim(coalesce(v_o.status,'')));

  -- Slip made already: only correct the driver / vehicle (until delivered or cancelled).
  IF EXISTS (SELECT 1 FROM public.lwb_quick_slips WHERE order_id = v_o.id) THEN
    IF v_st IN ('cancelled','canceled','delivered','closed','completed') THEN
      RAISE EXCEPTION 'PO % is already %.', v_o.order_no, v_st;
    END IF;
    UPDATE public.lwb_quick_slips SET driver_name = v_name, driver_mobile = nullif(v_mob,''), vehicle_no = v_veh,
      updated_by = auth.uid(), updated_at = now() WHERE order_id = v_o.id;
    RETURN public.lwb_quick_slip_get(v_o.id);
  END IF;

  IF v_st NOT IN ('approved','approved_next','manager_approved','warehouse_approved') THEN
    RAISE EXCEPTION 'PO % is % — a slip is made right after the PO is approved.', v_o.order_no, coalesce(nullif(v_st,''),'-');
  END IF;
  v_cid := public.lwb_quick_slip_company(v_o.id);
  IF v_cid IS NULL THEN
    RAISE EXCEPTION 'PO % is not a quick-slip brand PO (every SKU must be of one brand like Rajnigandha). Use the normal transport and loading.', v_o.order_no;
  END IF;
  IF NOT public.lwb_company_ok(v_cid) THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF EXISTS (SELECT 1 FROM public.dispatch_assignments a WHERE a.order_id = v_o.id) THEN
    RAISE EXCEPTION 'Transport is already assigned to PO %. Use Loading & Dispatch for it.', v_o.order_no;
  END IF;

  INSERT INTO public.lwb_quick_slips (order_id, company_id, driver_name, driver_mobile, vehicle_no, created_by)
  VALUES (v_o.id, v_cid, v_name, nullif(v_mob,''), v_veh, auth.uid());

  -- Goods leave with the slip: loaded = approved quantity, same as a full loading.
  UPDATE public.order_items SET loaded_qty = coalesce(approved_qty, ordered_qty, 0) WHERE order_id = v_o.id;
  UPDATE public.orders SET status = 'loaded' WHERE id = v_o.id;

  -- Popups: Godown does not load this PO; Accounts' "make bill" names the slip, driver and vehicle.
  v_info := coalesce(v_o.order_no,'PO') || ' · ' || coalesce(btrim(v_o.customer_name),'') ||
    ' · Driver ' || v_name || ' · Vehicle ' || v_veh ||
    ' · Rs ' || to_char(coalesce((SELECT sum(round(coalesce(i.loaded_qty,0)::numeric * coalesce(i.rate,0)::numeric, 2))
                                  FROM public.order_items i WHERE i.order_id = v_o.id), 0), 'FM9999999990.00');
  BEGIN
    UPDATE public.erp_notifications SET is_read = true
    WHERE order_id = v_o.id AND is_read = false AND notification_type IN ('PO_APPROVED_LOADING','PO_APPROVED_BILL');
    UPDATE public.erp_notifications SET title = 'Rajnigandha Slip — Make Tally Bill',
      message = v_info || '. Slip given to the driver. Make the bill in Tally, then enter the invoice number.'
    WHERE order_id = v_o.id AND is_read = false AND notification_type = 'TALLY_BILL_PENDING';
    UPDATE public.erp_notifications SET title = 'Rajnigandha Slip Printed', message = v_info || '. Sent to Accounts for the Tally bill.'
    WHERE order_id = v_o.id AND is_read = false AND notification_type = 'VEHICLE_LOADED';
  EXCEPTION WHEN others THEN NULL;  -- a popup never stops the slip
  END;

  RETURN public.lwb_quick_slip_get(v_o.id);
END;
$fn$;

-- One more print of the slip (for the reprint count on the slip).
CREATE OR REPLACE FUNCTION public.lwb_quick_slip_printed(p_order_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_n integer;
BEGIN
  IF public.lwb_quick_slip_role() NOT IN ('admin','manager','accounts','warehouse') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Accounts or Godown can print slips.';
  END IF;
  UPDATE public.lwb_quick_slips SET print_count = print_count + 1, last_printed_at = now()
  WHERE order_id = p_order_id AND public.lwb_company_ok(company_id)
  RETURNING print_count INTO v_n;
  IF v_n IS NULL THEN RAISE EXCEPTION 'Slip not found.'; END IF;
  RETURN v_n;
END;
$fn$;

-- Slips made between two dates (IST), newest first, max 1000; plus approved quick-slip POs still waiting
-- for driver / vehicle (made by a salesman and approved on PO / Sales List).
CREATE OR REPLACE FUNCTION public.lwb_quick_slip_list(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_from date := coalesce(p_from, (now() AT TIME ZONE 'Asia/Kolkata')::date);
        v_to date := coalesce(p_to, (now() AT TIME ZONE 'Asia/Kolkata')::date);
BEGIN
  IF public.lwb_quick_slip_role() NOT IN ('admin','manager','accounts','warehouse') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Accounts or Godown can see slips.';
  END IF;
  IF v_to < v_from OR v_to - v_from > 400 THEN RAISE EXCEPTION 'Choose up to 400 days.'; END IF;
  RETURN jsonb_build_object(
    'slips', coalesce((
      SELECT jsonb_agg(r ORDER BY r->>'slip_at' DESC) FROM (
        SELECT jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'order_date', o.order_date,
                 'party', btrim(o.customer_name), 'status', o.status, 'driver_name', s.driver_name,
                 'vehicle_no', s.vehicle_no, 'slip_at', s.created_at, 'print_count', s.print_count,
                 'total_qty', (SELECT coalesce(sum(coalesce(i.loaded_qty,0)),0) FROM public.order_items i WHERE i.order_id = o.id),
                 'total_amount', (SELECT coalesce(sum(round(coalesce(i.loaded_qty,0)::numeric * coalesce(i.rate,0)::numeric, 2)),0)
                                  FROM public.order_items i WHERE i.order_id = o.id)) AS r
        FROM public.lwb_quick_slips s JOIN public.orders o ON o.id = s.order_id
        WHERE (s.created_at AT TIME ZONE 'Asia/Kolkata')::date BETWEEN v_from AND v_to
          AND public.lwb_company_ok(s.company_id)
        ORDER BY s.created_at DESC LIMIT 1000) x), '[]'::jsonb),
    'waiting', coalesce((
      SELECT jsonb_agg(jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'order_date', o.order_date,
               'party', btrim(o.customer_name), 'total_qty', o.total_qty, 'total_amount', o.total_amount) ORDER BY o.order_date DESC)
      FROM (SELECT o.* FROM public.orders o
            WHERE lower(btrim(coalesce(o.status,''))) IN ('approved','approved_next','manager_approved','warehouse_approved')
              AND o.order_date >= now() - interval '30 days'
              AND NOT EXISTS (SELECT 1 FROM public.lwb_quick_slips s WHERE s.order_id = o.id)
              AND NOT EXISTS (SELECT 1 FROM public.dispatch_assignments a WHERE a.order_id = o.id)
              AND public.lwb_quick_slip_company(o.id) IS NOT NULL
              AND public.lwb_company_ok(public.lwb_quick_slip_company(o.id))
            ORDER BY o.order_date DESC LIMIT 200) o), '[]'::jsonb));
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_quick_slip_role(), public.lwb_quick_slip_company(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_quick_slip_get(uuid), public.lwb_quick_slip_dispatch(uuid, jsonb),
  public.lwb_quick_slip_printed(uuid), public.lwb_quick_slip_list(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_quick_slip_get(uuid), public.lwb_quick_slip_dispatch(uuid, jsonb),
  public.lwb_quick_slip_printed(uuid), public.lwb_quick_slip_list(date, date) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
