-- LUXURY WRIST BRAND ERP — DRIVER RETURN GOODS GO INTO STOCK (5 Nov 2026)
--
-- Applied automatically when the PR is merged (safe to run again).
-- Run AFTER lwb_stock_transfer_setup.sql and lwb_driver_payment_setup.sql.
-- If lwb_driver_payment_setup.sql is run again, run this file again after it
-- (it brings back the old lwb_receive_return_goods that does not move stock).
--
-- Before: Godown "Goods received" on an approved driver return only stamped the time.
-- The goods were back in the godown but no stock changed.
-- Now: on receive the Godown Manager (or Sales Head / Admin) picks, per SKU line,
-- where the goods go: Saleable, Damage, Leakage, Breakage, Gasless or Expiry.
-- Each line becomes an APPROVED lwb_stock_moves row (kind RETURN_IN, from PARTY), so
-- lwb_live_stock (saleable / damaged), Stock Transfer status and the category ledger
-- see it at once. The return was already approved by the office, so no second approval.
-- Default per line = the driver's reason. Damage / Leakage / Breakage / Low fill -> Damage (one option, OLN; 5 Nov 2026).
-- Returns received before this file are NOT back-filled.
-- Orders, bills, payments, party ledger and Tally are NOT changed.

BEGIN;

ALTER TABLE public.lwb_stock_moves ADD COLUMN IF NOT EXISTS order_id uuid;
ALTER TABLE public.lwb_stock_moves ADD COLUMN IF NOT EXISTS return_item_id uuid;

-- Widen the kind / source / from_bucket checks (replaced by named ones; safe to re-run).
DO $do$
DECLARE c record;
BEGIN
  FOR c IN SELECT conname, pg_get_constraintdef(oid) AS d FROM pg_constraint
           WHERE conrelid = 'public.lwb_stock_moves'::regclass AND contype = 'c' LOOP
    IF c.d ~ '\mkind\M' OR c.d ~ '\msource\M' OR (c.d ~ '\mfrom_bucket\M' AND c.d !~ '\mto_bucket\M') THEN
      EXECUTE format('ALTER TABLE public.lwb_stock_moves DROP CONSTRAINT %I', c.conname);
    END IF;
  END LOOP;
END;
$do$;
ALTER TABLE public.lwb_stock_moves ADD CONSTRAINT lwb_stock_moves_kind_ck
  CHECK (kind IN ('TRANSFER','DESTROY','COMPANY_RETURN','TO_SALEABLE','RETURN_IN','BILL_CHANGE'));
ALTER TABLE public.lwb_stock_moves ADD CONSTRAINT lwb_stock_moves_source_ck
  CHECK (source IN ('MANUAL','AUDIT','RETURN','BILL_CHANGE'));
ALTER TABLE public.lwb_stock_moves ADD CONSTRAINT lwb_stock_moves_from_ck
  CHECK (from_bucket IN ('SALEABLE','DAMAGE','LEAKAGE','BREAKAGE','GASLESS','EXPIRY','LOSS','PARTY'));
ALTER TABLE public.lwb_stock_moves ADD CONSTRAINT lwb_stock_moves_return_ck
  CHECK ((kind <> 'RETURN_IN' OR from_bucket = 'PARTY')
     AND (from_bucket <> 'PARTY' OR kind IN ('RETURN_IN','BILL_CHANGE'))
     AND (to_bucket <> 'PARTY' OR kind = 'BILL_CHANGE')
     AND (kind <> 'BILL_CHANGE' OR (from_bucket = 'PARTY' AND to_bucket = 'SALEABLE') OR (from_bucket = 'SALEABLE' AND to_bucket = 'PARTY')));
-- PO change after loading (lwb_bill_change_stock_setup.sql) also moves SALEABLE <-> PARTY.

-- One stock line per return line.
CREATE UNIQUE INDEX IF NOT EXISTS lwb_stock_moves_return_item_uq
  ON public.lwb_stock_moves(return_item_id) WHERE return_item_id IS NOT NULL AND status = 'APPROVED';

CREATE OR REPLACE FUNCTION public.lwb_stx_label(p_bucket text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE p_bucket WHEN 'COMPANY_RETURN' THEN 'Return to company' WHEN 'DESTROYED' THEN 'Destroyed'
    WHEN 'PARTY' THEN 'Party return' ELSE initcap(lower(p_bucket)) END;
$fn$;
GRANT EXECUTE ON FUNCTION public.lwb_stx_label(text) TO authenticated;

-- Default stock place for a driver return reason.
CREATE OR REPLACE FUNCTION public.lwb_return_default_bucket(p_reason text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  -- Damage, Leakage and Breakage are one return option (OLN / claim): all go to Damage.
  SELECT CASE upper(btrim(coalesce(p_reason,''))) WHEN 'GASLESS' THEN 'GASLESS' ELSE 'DAMAGE' END;
$fn$;
GRANT EXECUTE ON FUNCTION public.lwb_return_default_bucket(text) TO authenticated;

-- Lines of one return for the receive popup: SKU, qty in pieces, default place,
-- whether the SKU is found in SKU Master (no SKU = cannot go into stock).
CREATE OR REPLACE FUNCTION public.lwb_return_receive_lines(p_return_id uuid)
RETURNS TABLE(item_id uuid, sku_name text, reason text, uom text, qty integer, qty_cases numeric,
  pcs_per_case integer, qty_pcs integer, default_bucket text, sku_id uuid, received_bucket text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('warehouse','manager','admin','accounts')) THEN
    RAISE EXCEPTION 'Only office staff can view return lines';
  END IF;
  RETURN QUERY
  SELECT li.id, li.sku_name::text, li.reason::text, li.uom::text, li.qty, li.qty_cases::numeric,
    greatest(coalesce(li.pcs_per_case, s.pcs_per_case, 1), 1)::integer,
    greatest(round(li.qty_cases * greatest(coalesce(li.pcs_per_case, s.pcs_per_case, 1), 1)), 1)::integer,
    public.lwb_return_default_bucket(li.reason), s.id,
    (SELECT m.to_bucket FROM public.lwb_stock_moves m WHERE m.return_item_id = li.id AND m.status = 'APPROVED' LIMIT 1)
  FROM public.lwb_driver_delivery_return_items li
  LEFT JOIN LATERAL (
    SELECT x.id, x.pcs_per_case FROM public.sku_master x
    WHERE upper(btrim(x.sku_name)) = upper(btrim(li.sku_name))
    ORDER BY coalesce(x.is_active, true) DESC LIMIT 1
  ) s ON true
  WHERE li.return_id = p_return_id
  ORDER BY li.sku_name;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_return_receive_lines(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_return_receive_lines(uuid) TO authenticated;

-- Receive the goods of an approved return and put each line into stock.
-- p_lines: [{item_id, bucket}] ; a line left out uses its default place.
CREATE OR REPLACE FUNCTION public.lwb_receive_return_goods2(p_return_id uuid, p_lines jsonb DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_return public.lwb_driver_delivery_returns%ROWTYPE;
  v_note text := NULLIF(btrim(COALESCE(p_note,'')),'');
  v_order_no text;
  v_batch uuid := gen_random_uuid();
  v_ok constant text[] := ARRAY['SALEABLE','DAMAGE','LEAKAGE','BREAKAGE','GASLESS','EXPIRY'];
  l record; v_bucket text; v_moved integer := 0; v_skipped text[] := '{}'; v_saleable bigint := 0; v_held bigint := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('warehouse','manager','admin')) THEN
    RAISE EXCEPTION 'Only Godown, Sales Head or Admin can receive return goods';
  END IF;
  IF length(COALESCE(v_note,'')) > 300 THEN RAISE EXCEPTION 'Note is too long'; END IF;
  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) <> 'array' THEN RAISE EXCEPTION 'Lines must be a list'; END IF;
  SELECT * INTO v_return FROM public.lwb_driver_delivery_returns WHERE id = p_return_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Return not found'; END IF;
  IF v_return.status <> 'APPROVED' THEN RAISE EXCEPTION 'Only approved returns are received'; END IF;
  IF v_return.goods_received_at IS NOT NULL THEN RAISE EXCEPTION 'Goods already received'; END IF;
  SELECT o.order_no::text INTO v_order_no FROM public.orders o WHERE o.id = v_return.order_id;

  FOR l IN SELECT * FROM public.lwb_return_receive_lines(p_return_id) LOOP
    v_bucket := upper(btrim(coalesce((SELECT e->>'bucket' FROM jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) e
                                      WHERE e->>'item_id' = l.item_id::text LIMIT 1), l.default_bucket)));
    IF NOT (v_bucket = ANY (v_ok)) THEN RAISE EXCEPTION 'Choose Saleable, Damage, Leakage, Breakage, Gasless or Expiry for %', l.sku_name; END IF;
    IF l.sku_id IS NULL THEN v_skipped := v_skipped || l.sku_name; CONTINUE; END IF;
    INSERT INTO public.lwb_stock_moves(batch_id, kind, from_bucket, to_bucket, sku_id, sku_name, pcs_per_case, qty_pcs,
      requested_pcs, move_date, reason, note, source, status, requested_by, requested_at, decided_by, decided_at,
      decision_note, order_id, return_item_id)
    VALUES (v_batch, 'RETURN_IN', 'PARTY', v_bucket, l.sku_id, l.sku_name, l.pcs_per_case, l.qty_pcs, l.qty_pcs,
      public.lwb_stx_today(), left('Party return ' || coalesce(v_order_no,'') || ' (' || initcap(lower(l.reason)) || ')', 300),
      v_note, 'RETURN', 'APPROVED', auth.uid(), now(), auth.uid(), now(), 'Driver return approved by office',
      v_return.order_id, l.item_id);
    v_moved := v_moved + 1;
    IF v_bucket = 'SALEABLE' THEN v_saleable := v_saleable + l.qty_pcs; ELSE v_held := v_held + l.qty_pcs; END IF;
  END LOOP;

  UPDATE public.lwb_driver_delivery_returns
  SET goods_received_at = now(), goods_received_by = auth.uid(),
      goods_received_note = left(concat_ws(' · ', v_note,
        CASE WHEN cardinality(v_skipped) > 0 THEN 'Not in SKU Master, stock not changed: ' || array_to_string(v_skipped, ', ') END), 300)
  WHERE id = p_return_id;
  UPDATE public.erp_notifications SET is_read = true
  WHERE order_id = v_return.order_id AND notification_type = 'DELIVERY_RETURN_RECEIVE' AND is_read = false
    AND created_at >= v_return.reviewed_at AND created_at < v_return.reviewed_at + interval '5 seconds';
  RETURN jsonb_build_object('status','RECEIVED','lines',v_moved,'saleable_pcs',v_saleable,'held_pcs',v_held,'skipped',to_jsonb(v_skipped));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_receive_return_goods2(uuid,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_receive_return_goods2(uuid,jsonb,text) TO authenticated;

-- The old one-tap receive (old app / cached page) now also moves stock, each line to its default place.
CREATE OR REPLACE FUNCTION public.lwb_receive_return_goods(p_return_id uuid, p_note text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
BEGIN
  PERFORM public.lwb_receive_return_goods2(p_return_id, NULL, p_note);
  RETURN 'RECEIVED';
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_receive_return_goods(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_receive_return_goods(uuid,text) TO authenticated;

COMMIT;
