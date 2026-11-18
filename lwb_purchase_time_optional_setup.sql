-- LUXURY WRIST BRAND ERP — VEHICLE TIME IN / OUT OPTIONAL ON THE PURCHASE CHECK (18 Nov 2026)
--
-- Mohit asked (18 Nov 2026): Time In / Time Out on the vehicle check must be optional, not mandatory.
-- lwb_purchase_vehicle_time(bill, in, out) now accepts an empty Time In:
--   * both empty      -> nothing changes (times already saved stay);
--   * only Time Out   -> refused ("Enter Time In too, or leave both empty");
--   * the other checks (not in the future, Out after In, at most 3 days) are as before.
-- Run after lwb_purchase_damage_report_setup.sql. Safe to run again.
-- Only this function changes. No bill, stock, claim or Tally data is changed.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_purchase_vehicle_time(p_inward uuid, p_in timestamptz, p_out timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_pc_checker() THEN RAISE EXCEPTION 'Only Admin, Sales Head or Godown Manager can enter vehicle time'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_goods_inward g WHERE g.id = p_inward) THEN RAISE EXCEPTION 'Purchase bill not found'; END IF;
  IF p_in IS NULL AND p_out IS NULL THEN RETURN; END IF;   -- optional: nothing entered, nothing changed
  IF p_in IS NULL THEN RAISE EXCEPTION 'Enter Time In too, or leave both empty'; END IF;
  IF p_in > now() + interval '10 minutes' OR p_out > now() + interval '10 minutes' THEN RAISE EXCEPTION 'Vehicle time is in the future'; END IF;
  IF p_out IS NOT NULL AND p_out < p_in THEN RAISE EXCEPTION 'Time Out must be after Time In'; END IF;
  IF p_out - p_in > interval '3 days' THEN RAISE EXCEPTION 'Time In and Time Out are more than 3 days apart'; END IF;
  UPDATE public.lwb_goods_inward SET time_in = p_in, time_out = p_out WHERE id = p_inward;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_vehicle_time(uuid, timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_vehicle_time(uuid, timestamptz, timestamptz) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
