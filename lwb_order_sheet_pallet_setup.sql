-- LUXURY WRIST BRAND ERP — PALLET & SHEET COUNT ON THE PO (returnable packaging)
--
-- RUN ONCE in Supabase SQL Editor, after lwb_sheet_pallet_setup.sql. Safe to run again.
-- Mohit asked (3 Nov 2026): on a Direct Vehicle / pallet order the vehicle also takes
-- pallets and sheets to the party. Pallets are usually fixed (e.g. 11), sheets vary.
--   1. New Sales Order asks "Pallet" and "Sheet" for these orders and saves them on the PO.
--   2. The PO print shows them.
--   3. The Sheet & Pallet Ledger gets a "Given to Party" row for that party by itself
--      (marked "From PO"), so nobody has to type it again later.
-- Change the numbers on the order and the ledger row changes. Cancel or delete the order
-- and its ledger row is removed. Hand-typed ledger rows are never touched.
-- Adds two columns to orders (sp_pallets, sp_sheets) and one to lwb_sp_entries (source).
-- No stock, bill, payment or Tally data is changed.

BEGIN;

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS sp_pallets integer;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS sp_sheets integer;
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.orders'::regclass AND conname = 'orders_sp_qty_check') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_sp_qty_check
      CHECK (coalesce(sp_pallets,0) BETWEEN 0 AND 999 AND coalesce(sp_sheets,0) BETWEEN 0 AND 9999);
  END IF;
END;
$do$;

-- source = 'ORDER' : made from the PO. NULL : typed on the Sheet & Pallet page.
ALTER TABLE public.lwb_sp_entries ADD COLUMN IF NOT EXISTS source text;
CREATE UNIQUE INDEX IF NOT EXISTS lwb_sp_entries_order_auto_uq
  ON public.lwb_sp_entries (order_id) WHERE source = 'ORDER';

-- Write the ledger row for one order (or remove it). Internal: not callable from the app.
CREATE OR REPLACE FUNCTION public.lwb_sp_sync_order(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_st text;
  v_veh text;
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id;
  v_st := lower(btrim(coalesce(v_o.status,'')));
  IF NOT FOUND OR v_st IN ('cancelled','canceled')
     OR coalesce(v_o.sp_pallets,0) + coalesce(v_o.sp_sheets,0) = 0
     OR length(btrim(coalesce(v_o.customer_name,''))) = 0 THEN
    DELETE FROM public.lwb_sp_entries WHERE order_id = p_order_id AND source = 'ORDER';
    RETURN;
  END IF;
  v_veh := nullif(upper(regexp_replace(coalesce(substring(v_o.transportation FROM 'VEHICLE:\s*([^|]+)'),''), '[^A-Za-z0-9]', '', 'g')), '');
  UPDATE public.lwb_sp_entries SET
      entry_date = (coalesce(v_o.order_date, now()) AT TIME ZONE 'Asia/Kolkata')::date,
      party_name = btrim(v_o.customer_name),
      pallets = coalesce(v_o.sp_pallets,0), sheets = coalesce(v_o.sp_sheets,0),
      ref_no = v_o.order_no,
      vehicle_no = coalesce(v_veh, vehicle_no)
    WHERE order_id = p_order_id AND source = 'ORDER'
      AND (pallets, sheets, party_name, ref_no, entry_date) IS DISTINCT FROM
          (coalesce(v_o.sp_pallets,0), coalesce(v_o.sp_sheets,0), btrim(v_o.customer_name), v_o.order_no,
           (coalesce(v_o.order_date, now()) AT TIME ZONE 'Asia/Kolkata')::date);
  IF NOT EXISTS (SELECT 1 FROM public.lwb_sp_entries WHERE order_id = p_order_id AND source = 'ORDER') THEN
    INSERT INTO public.lwb_sp_entries (entry_date, entry_type, party_name, pallets, sheets, order_id, ref_no, vehicle_no, note, source)
    VALUES ((coalesce(v_o.order_date, now()) AT TIME ZONE 'Asia/Kolkata')::date, 'PARTY_OUT', btrim(v_o.customer_name),
            coalesce(v_o.sp_pallets,0), coalesce(v_o.sp_sheets,0), v_o.id, v_o.order_no, v_veh, 'From PO', 'ORDER');
  END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sp_sync_order(uuid) FROM PUBLIC, anon, authenticated;

-- Save pallet / sheet count on a PO.
-- Admin / Manager / Accounts / Warehouse: any order that is not cancelled.
-- The person who took the order (Salesman / Sales Head): their own order until it is delivered.
CREATE OR REPLACE FUNCTION public.lwb_set_order_sheet_pallet(p_order_id uuid, p_pallets integer, p_sheets integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_st text;
  v_p integer := nullif(greatest(coalesce(p_pallets,0),0),0);
  v_s integer := nullif(greatest(coalesce(p_sheets,0),0),0);
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true) THEN
    RAISE EXCEPTION 'Login is not active.';
  END IF;
  IF coalesce(p_pallets,0) < 0 OR coalesce(p_sheets,0) < 0 OR coalesce(p_pallets,0) > 999 OR coalesce(p_sheets,0) > 9999 THEN
    RAISE EXCEPTION 'Pallet must be 0 to 999 and Sheet 0 to 9999.';
  END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  v_st := lower(btrim(coalesce(v_o.status,'')));
  IF v_st IN ('cancelled','canceled') THEN RAISE EXCEPTION 'Order % is cancelled.', v_o.order_no; END IF;
  IF NOT public.lwb_sp_user() THEN
    IF v_o.created_by IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'Only the person who took the order, Admin, Accounts or the Godown can set pallet / sheet.';
    END IF;
    IF v_st IN ('delivered','closed','completed') THEN
      RAISE EXCEPTION 'Order % is already delivered. Ask Accounts to change the Sheet & Pallet Ledger.', v_o.order_no;
    END IF;
  END IF;

  IF (v_o.sp_pallets, v_o.sp_sheets) IS NOT DISTINCT FROM (v_p, v_s) THEN
    PERFORM public.lwb_sp_sync_order(v_o.id);
    RETURN jsonb_build_object('id', v_o.id, 'pallets', coalesce(v_p,0), 'sheets', coalesce(v_s,0), 'changed', false);
  END IF;
  UPDATE public.orders SET sp_pallets = v_p, sp_sheets = v_s WHERE id = v_o.id;
  PERFORM public.lwb_sp_sync_order(v_o.id);
  RETURN jsonb_build_object('id', v_o.id, 'pallets', coalesce(v_p,0), 'sheets', coalesce(v_s,0), 'changed', true);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_set_order_sheet_pallet(uuid, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_order_sheet_pallet(uuid, integer, integer) TO authenticated;

-- Keep the ledger row in step when the order is cancelled, renamed, re-dated or deleted.
CREATE OR REPLACE FUNCTION public.lwb_sp_order_changed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.lwb_sp_entries WHERE order_id = OLD.id AND source = 'ORDER';
    RETURN OLD;
  END IF;
  IF coalesce(NEW.sp_pallets,0) + coalesce(NEW.sp_sheets,0) + coalesce(OLD.sp_pallets,0) + coalesce(OLD.sp_sheets,0) > 0 THEN
    PERFORM public.lwb_sp_sync_order(NEW.id);
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sp_order_changed() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS lwb_sp_order_delete ON public.orders;
CREATE TRIGGER lwb_sp_order_delete BEFORE DELETE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.lwb_sp_order_changed();
DROP TRIGGER IF EXISTS lwb_sp_order_update ON public.orders;
CREATE TRIGGER lwb_sp_order_update AFTER UPDATE OF status, customer_name, order_date, order_no, transportation ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.lwb_sp_order_changed();

COMMIT;
NOTIFY pgrst, 'reload schema';
