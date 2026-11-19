-- LUXURY WRIST BRAND ERP — PALLET & SHEET ON A PO AFTER DELIVERY (given + returned)
--
-- RUN ONCE in Supabase SQL Editor, after lwb_sheet_pallet_setup.sql and
-- lwb_order_sheet_pallet_setup.sql. Safe to run again.
-- Mohit asked (17 Nov 2026): after a PO is delivered, Admin / Accounts / Godown must be able to
-- write how many pallets and sheets went to the party, and how many the party gave back,
-- straight from the PO list, so each party's pallet / sheet account is kept.
--   Given    = orders.sp_pallets / sp_sheets (same as before) -> ledger PARTY_OUT row, source 'ORDER'
--   Returned = orders.sp_ret_pallets / sp_ret_sheets (new)   -> ledger PARTY_IN row,  source 'ORDER_RETURN'
-- Count only: no money, stock, bill, payment or Tally data is changed.
-- Change the numbers and the same ledger rows change. Cancel or delete the PO and its rows go.
-- Hand-typed ledger rows are never touched.

BEGIN;

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS sp_ret_pallets integer;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS sp_ret_sheets integer;
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = 'public.orders'::regclass AND conname = 'orders_sp_ret_qty_check') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_sp_ret_qty_check
      CHECK (coalesce(sp_ret_pallets,0) BETWEEN 0 AND 999 AND coalesce(sp_ret_sheets,0) BETWEEN 0 AND 9999);
  END IF;
END;
$do$;

CREATE UNIQUE INDEX IF NOT EXISTS lwb_sp_entries_order_ret_uq
  ON public.lwb_sp_entries (order_id) WHERE source = 'ORDER_RETURN';

-- Write the "Returned by party" ledger row for one PO (or remove it). Internal only.
-- The date is the day it was first written; later changes keep that date.
CREATE OR REPLACE FUNCTION public.lwb_sp_sync_order_return(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_st text;
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id;
  v_st := lower(btrim(coalesce(v_o.status,'')));
  IF NOT FOUND OR v_st IN ('cancelled','canceled')
     OR coalesce(v_o.sp_ret_pallets,0) + coalesce(v_o.sp_ret_sheets,0) = 0
     OR length(btrim(coalesce(v_o.customer_name,''))) = 0 THEN
    DELETE FROM public.lwb_sp_entries WHERE order_id = p_order_id AND source = 'ORDER_RETURN';
    RETURN;
  END IF;
  UPDATE public.lwb_sp_entries SET
      party_name = btrim(v_o.customer_name),
      pallets = coalesce(v_o.sp_ret_pallets,0), sheets = coalesce(v_o.sp_ret_sheets,0),
      ref_no = v_o.order_no
    WHERE order_id = p_order_id AND source = 'ORDER_RETURN'
      AND (pallets, sheets, party_name, ref_no) IS DISTINCT FROM
          (coalesce(v_o.sp_ret_pallets,0), coalesce(v_o.sp_ret_sheets,0), btrim(v_o.customer_name), v_o.order_no);
  IF NOT EXISTS (SELECT 1 FROM public.lwb_sp_entries WHERE order_id = p_order_id AND source = 'ORDER_RETURN') THEN
    INSERT INTO public.lwb_sp_entries (entry_date, entry_type, party_name, pallets, sheets, order_id, ref_no, note, source)
    VALUES ((now() AT TIME ZONE 'Asia/Kolkata')::date, 'PARTY_IN', btrim(v_o.customer_name),
            coalesce(v_o.sp_ret_pallets,0), coalesce(v_o.sp_ret_sheets,0), v_o.id, v_o.order_no, 'Returned · from PO', 'ORDER_RETURN');
  END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sp_sync_order_return(uuid) FROM PUBLIC, anon, authenticated;

-- Save given + returned pallet / sheet on a PO (any stage, also after delivery).
-- Admin / Sales Head (manager) / Accounts / Godown (lwb_sp_user). Not on a cancelled PO.
CREATE OR REPLACE FUNCTION public.lwb_set_order_sp(p_order_id uuid, p_pallets integer, p_sheets integer,
  p_ret_pallets integer, p_ret_sheets integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_p integer := nullif(coalesce(p_pallets,0),0);
  v_s integer := nullif(coalesce(p_sheets,0),0);
  v_rp integer := nullif(coalesce(p_ret_pallets,0),0);
  v_rs integer := nullif(coalesce(p_ret_sheets,0),0);
  v_changed boolean;
BEGIN
  IF NOT public.lwb_sp_user() THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Accounts or the Godown can write pallet / sheet after delivery.';
  END IF;
  IF least(coalesce(p_pallets,0), coalesce(p_sheets,0), coalesce(p_ret_pallets,0), coalesce(p_ret_sheets,0)) < 0
     OR greatest(coalesce(p_pallets,0), coalesce(p_ret_pallets,0)) > 999
     OR greatest(coalesce(p_sheets,0), coalesce(p_ret_sheets,0)) > 9999 THEN
    RAISE EXCEPTION 'Pallet must be 0 to 999 and Sheet 0 to 9999.';
  END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF lower(btrim(coalesce(v_o.status,''))) IN ('cancelled','canceled') THEN
    RAISE EXCEPTION 'Order % is cancelled.', v_o.order_no;
  END IF;

  v_changed := (v_o.sp_pallets, v_o.sp_sheets, v_o.sp_ret_pallets, v_o.sp_ret_sheets) IS DISTINCT FROM (v_p, v_s, v_rp, v_rs);
  IF v_changed THEN
    UPDATE public.orders SET sp_pallets = v_p, sp_sheets = v_s, sp_ret_pallets = v_rp, sp_ret_sheets = v_rs
      WHERE id = v_o.id;
  END IF;
  PERFORM public.lwb_sp_sync_order(v_o.id);
  PERFORM public.lwb_sp_sync_order_return(v_o.id);
  RETURN jsonb_build_object('id', v_o.id, 'pallets', coalesce(v_p,0), 'sheets', coalesce(v_s,0),
    'ret_pallets', coalesce(v_rp,0), 'ret_sheets', coalesce(v_rs,0), 'changed', v_changed);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_set_order_sp(uuid, integer, integer, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_order_sp(uuid, integer, integer, integer, integer) TO authenticated;

-- Keep both ledger rows in step when the PO is cancelled, renamed, re-dated or deleted
-- (same trigger as lwb_order_sheet_pallet_setup.sql, now also for the returned row).
CREATE OR REPLACE FUNCTION public.lwb_sp_order_changed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.lwb_sp_entries WHERE order_id = OLD.id AND source IN ('ORDER','ORDER_RETURN');
    RETURN OLD;
  END IF;
  IF coalesce(NEW.sp_pallets,0) + coalesce(NEW.sp_sheets,0) + coalesce(OLD.sp_pallets,0) + coalesce(OLD.sp_sheets,0) > 0 THEN
    PERFORM public.lwb_sp_sync_order(NEW.id);
  END IF;
  IF coalesce(NEW.sp_ret_pallets,0) + coalesce(NEW.sp_ret_sheets,0) + coalesce(OLD.sp_ret_pallets,0) + coalesce(OLD.sp_ret_sheets,0) > 0 THEN
    PERFORM public.lwb_sp_sync_order_return(NEW.id);
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sp_order_changed() FROM PUBLIC, anon, authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';
