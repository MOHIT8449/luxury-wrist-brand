-- LUXURY WRIST BRAND ERP — DIRECT VEHICLE: party advance, final quantity and balance (23 Nov 2026)
--
-- Mohit asked (23 Nov 2026): a Direct Vehicle PO = the company's truck (our ECRS / purchase order to the
-- company) goes straight to the party. The party pays before (e.g. ₹50 lakh), the company often sends
-- a bit more or less (+/- cases), so the final goods value differs (e.g. ₹55 lakh) and the rest
-- (₹5 lakh) is still to collect. Needs its own place: page direct-vehicle.html.
--
--   lwb_direct_vehicle      one row per Direct Vehicle PO (orders.transportation 'DIRECT VEHICLE...'):
--                           company truck (lwb_ecrs_trucks, optional), final cases per PO line,
--                           final amount (final cases x PO rate, worked out here), note, closed.
--   lwb_direct_vehicle_pay  money from the party for that PO: date, mode, amount, ref.
--                           mode REFUND = money given back to the party (counts as minus).
--
-- Who: Admin, Manager (Sales Head) and Accounts read and write. Delete of a money line: Admin / Accounts.
-- Only these two new tables are written. No order, order line, stock, bill, ledger or Tally data is changed.
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped or deleted.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_dv_staff()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','accounts'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_dv_staff() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dv_staff() TO authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_direct_vehicle (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  truck_id bigint,
  truck_label text,
  final_lines jsonb NOT NULL DEFAULT '[]'::jsonb,   -- [{item_id, cs}]
  final_amount numeric(14,2),
  final_cases numeric(14,2),
  final_at timestamptz,
  note text,
  closed boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid DEFAULT auth.uid(),
  updated_by_name text
);

CREATE TABLE IF NOT EXISTS public.lwb_direct_vehicle_pay (
  id bigserial PRIMARY KEY,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  pay_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata')::date),
  mode text NOT NULL DEFAULT 'RTGS' CHECK (mode IN ('CASH','RTGS','UPI','CHEQUE','REFUND','OTHER')),
  amount numeric(14,2) NOT NULL CHECK (amount > 0 AND amount <= 100000000),
  ref text,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid DEFAULT auth.uid(),
  created_by_name text
);
CREATE INDEX IF NOT EXISTS lwb_direct_vehicle_pay_order_idx ON public.lwb_direct_vehicle_pay(order_id, pay_date);

ALTER TABLE public.lwb_direct_vehicle ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_direct_vehicle_pay ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_direct_vehicle, public.lwb_direct_vehicle_pay FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_direct_vehicle_pay_id_seq FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_direct_vehicle, public.lwb_direct_vehicle_pay TO authenticated;

DROP POLICY IF EXISTS lwb_direct_vehicle_read ON public.lwb_direct_vehicle;
CREATE POLICY lwb_direct_vehicle_read ON public.lwb_direct_vehicle FOR SELECT TO authenticated USING (public.lwb_dv_staff());
DROP POLICY IF EXISTS lwb_direct_vehicle_pay_read ON public.lwb_direct_vehicle_pay;
CREATE POLICY lwb_direct_vehicle_pay_read ON public.lwb_direct_vehicle_pay FOR SELECT TO authenticated USING (public.lwb_dv_staff());

CREATE OR REPLACE FUNCTION public.lwb_dv_me()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT coalesce(nullif(btrim(p.full_name),''), 'User') FROM public.user_profiles p WHERE p.id = auth.uid(); $fn$;
REVOKE ALL ON FUNCTION public.lwb_dv_me() FROM PUBLIC, anon, authenticated;

-- The PO must exist, be a Direct Vehicle PO and not be cancelled / rejected.
CREATE OR REPLACE FUNCTION public.lwb_dv_order_ok(p_order uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE o record;
BEGIN
  IF NOT public.lwb_dv_staff() THEN RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can do this'; END IF;
  SELECT id, transportation, status INTO o FROM public.orders WHERE id = p_order;
  IF o.id IS NULL THEN RAISE EXCEPTION 'PO not found'; END IF;
  IF upper(coalesce(o.transportation,'')) NOT LIKE 'DIRECT VEHICLE%' THEN RAISE EXCEPTION 'This PO is not a Direct Vehicle PO'; END IF;
  IF lower(coalesce(o.status,'')) IN ('cancelled','canceled','rejected') THEN RAISE EXCEPTION 'This PO is cancelled'; END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_dv_order_ok(uuid) FROM PUBLIC, anon, authenticated;

-- Money from the party (advance / balance) or REFUND back to the party.
CREATE OR REPLACE FUNCTION public.lwb_dv_pay_add(p_order uuid, p_date date, p_mode text, p_amount numeric, p_ref text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id bigint; v_mode text := upper(btrim(coalesce(p_mode,'')));
BEGIN
  PERFORM public.lwb_dv_order_ok(p_order);
  IF v_mode NOT IN ('CASH','RTGS','UPI','CHEQUE','REFUND','OTHER') THEN RAISE EXCEPTION 'Choose the mode: Cash, RTGS, UPI, Cheque or Refund'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION 'Enter the amount'; END IF;
  IF p_amount > 100000000 THEN RAISE EXCEPTION 'Amount is too big'; END IF;
  IF p_date IS NULL OR p_date > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1 THEN RAISE EXCEPTION 'Date cannot be in the future'; END IF;
  INSERT INTO public.lwb_direct_vehicle_pay(order_id, pay_date, mode, amount, ref, note, created_by, created_by_name)
  VALUES (p_order, p_date, v_mode, round(p_amount, 2), nullif(left(btrim(coalesce(p_ref,'')),80),''),
          nullif(left(btrim(coalesce(p_note,'')),300),''), auth.uid(), public.lwb_dv_me())
  RETURNING id INTO v_id;
  INSERT INTO public.lwb_direct_vehicle(order_id, updated_by, updated_by_name) VALUES (p_order, auth.uid(), public.lwb_dv_me())
  ON CONFLICT (order_id) DO NOTHING;
  RETURN v_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_dv_pay_delete(p_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','accounts')) THEN
    RAISE EXCEPTION 'Only Admin or Accounts can delete a money entry';
  END IF;
  DELETE FROM public.lwb_direct_vehicle_pay WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Entry not found'; END IF;
END;
$fn$;

-- Company truck, final cases per PO line (what the company really sent), note, closed.
-- p_final = [{item_id, cs}] ; null / [] = final not entered yet (PO quantity is used).
CREATE OR REPLACE FUNCTION public.lwb_dv_save(p_order uuid, p_truck_id bigint, p_truck_label text, p_final jsonb, p_note text, p_closed boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_lines jsonb := '[]'::jsonb; v_amt numeric := NULL; v_cs numeric := NULL; v_bad int;
BEGIN
  PERFORM public.lwb_dv_order_ok(p_order);
  IF p_final IS NOT NULL AND jsonb_typeof(p_final) = 'array' AND jsonb_array_length(p_final) > 0 THEN
    SELECT count(*) INTO v_bad FROM jsonb_array_elements(p_final) e
     WHERE NOT EXISTS (SELECT 1 FROM public.order_items i WHERE i.order_id = p_order AND i.id::text = e->>'item_id')
        OR coalesce((e->>'cs')::numeric, -1) < 0 OR (e->>'cs')::numeric > 100000;
    IF v_bad > 0 THEN RAISE EXCEPTION 'Final quantity: check the cases (0 or more, only lines of this PO)'; END IF;
    SELECT jsonb_agg(jsonb_build_object('item_id', i.id::text, 'cs', coalesce(f.cs, coalesce(i.approved_qty, i.ordered_qty, 0)))),
           round(sum(coalesce(f.cs, coalesce(i.approved_qty, i.ordered_qty, 0)) * coalesce(i.rate, 0)), 2),
           sum(coalesce(f.cs, coalesce(i.approved_qty, i.ordered_qty, 0)))
      INTO v_lines, v_amt, v_cs
      FROM public.order_items i
      LEFT JOIN (SELECT e->>'item_id' AS item_id, (e->>'cs')::numeric AS cs FROM jsonb_array_elements(p_final) e) f ON f.item_id = i.id::text
     WHERE i.order_id = p_order;
  END IF;
  INSERT INTO public.lwb_direct_vehicle AS d(order_id, truck_id, truck_label, final_lines, final_amount, final_cases, final_at, note, closed, updated_at, updated_by, updated_by_name)
  VALUES (p_order, p_truck_id, nullif(left(btrim(coalesce(p_truck_label,'')),60),''), coalesce(v_lines,'[]'::jsonb), v_amt, v_cs,
          CASE WHEN v_amt IS NULL THEN NULL ELSE now() END, nullif(left(btrim(coalesce(p_note,'')),500),''), coalesce(p_closed,false),
          now(), auth.uid(), public.lwb_dv_me())
  ON CONFLICT (order_id) DO UPDATE SET truck_id = EXCLUDED.truck_id, truck_label = EXCLUDED.truck_label,
    final_lines = EXCLUDED.final_lines, final_amount = EXCLUDED.final_amount, final_cases = EXCLUDED.final_cases,
    final_at = CASE WHEN EXCLUDED.final_amount IS NULL THEN NULL
                    WHEN d.final_amount IS NOT DISTINCT FROM EXCLUDED.final_amount AND d.final_lines = EXCLUDED.final_lines THEN d.final_at
                    ELSE now() END,
    note = EXCLUDED.note, closed = EXCLUDED.closed, updated_at = now(), updated_by = auth.uid(), updated_by_name = EXCLUDED.updated_by_name;
  RETURN jsonb_build_object('final_amount', v_amt, 'final_cases', v_cs);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_dv_pay_add(uuid, date, text, numeric, text, text), public.lwb_dv_pay_delete(bigint),
  public.lwb_dv_save(uuid, bigint, text, jsonb, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dv_pay_add(uuid, date, text, numeric, text, text), public.lwb_dv_pay_delete(bigint),
  public.lwb_dv_save(uuid, bigint, text, jsonb, text, boolean) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'direct vehicle tables' AS item,
  (to_regclass('public.lwb_direct_vehicle') IS NOT NULL AND to_regclass('public.lwb_direct_vehicle_pay') IS NOT NULL)::text AS ok;
