-- LUXURY WRIST BRAND ERP — PO: OUT FOR DELIVERY (marked by Accounts after the Tally bill)
--
-- Runs by itself when merged to main. Safe to run again. Nothing is deleted; the orders table is not changed.
--
-- Mohit asked (25 Nov 2026): PO / Sales List steps are Loading (Godown Manager) → Loaded → Out for delivery
-- → Delivered. Accounts makes the Tally bill, gives it with the vehicle and then presses "Out for delivery".
-- A PO can go Out for delivery only after its Tally bill is saved (lwb_tally_invoices). Admin / Accounts see a
-- "Bill pending" tab with how long each loaded PO is waiting for its bill.
--   * lwb_po_out_delivery: one row per PO marked out for delivery (who / when).
--   * lwb_mark_out_for_delivery(order ids): Accounts / Admin; every PO must be loaded and billed.
--   * lwb_undo_out_for_delivery(order id): Accounts / Admin, a PO marked by mistake goes back to Loaded.
--   * lwb_po_flow_flags(order ids): bill no. / bill time / loaded time / out for delivery time of each PO,
--     for Admin, Sales Head, Godown Manager and Accounts (no amounts).

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_po_out_delivery (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  out_at timestamptz NOT NULL DEFAULT now(),
  out_by uuid,
  out_by_name text
);
ALTER TABLE public.lwb_po_out_delivery ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_po_out_delivery FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_mark_out_for_delivery(p_ids uuid[])
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_name text;
  v_bad text;
  v_n integer;
BEGIN
  SELECT coalesce(nullif(btrim(p.full_name),''), 'Accounts') INTO v_name FROM public.user_profiles p
  WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','accounts');
  IF NOT FOUND THEN RAISE EXCEPTION 'Only Accounts / Admin can mark Out for delivery.'; END IF;
  IF coalesce(cardinality(p_ids), 0) = 0 THEN RAISE EXCEPTION 'Pick a PO.'; END IF;
  IF cardinality(p_ids) > 200 THEN RAISE EXCEPTION 'Max 200 POs at a time.'; END IF;

  SELECT string_agg(coalesce(o.order_no, o.id::text), ', ') INTO v_bad
  FROM public.orders o
  WHERE o.id = ANY(p_ids)
    AND lower(btrim(coalesce(o.status::text,''))) NOT IN ('loaded','invoiced','dispatched');
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'Not loaded yet (or already delivered / cancelled): %', v_bad; END IF;

  SELECT string_agg(coalesce(o.order_no, o.id::text), ', ') INTO v_bad
  FROM public.orders o
  WHERE o.id = ANY(p_ids)
    AND NOT EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = o.id);
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'Make the Tally bill first: %', v_bad; END IF;

  INSERT INTO public.lwb_po_out_delivery(order_id, out_by, out_by_name)
  SELECT o.id, auth.uid(), v_name FROM public.orders o WHERE o.id = ANY(p_ids)
  ON CONFLICT (order_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_undo_out_for_delivery(p_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','accounts')) THEN
    RAISE EXCEPTION 'Only Accounts / Admin can change Out for delivery.';
  END IF;
  DELETE FROM public.lwb_po_out_delivery WHERE order_id = p_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_po_flow_flags(p_ids uuid[])
RETURNS TABLE(order_id uuid, bill_no text, bill_at timestamptz, loaded_at timestamptz,
  out_at timestamptz, out_by_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','warehouse','accounts')) THEN
    RAISE EXCEPTION 'Admin / Sales Head / Godown Manager / Accounts only.';
  END IF;
  IF coalesce(cardinality(p_ids), 0) > 1000 THEN RAISE EXCEPTION 'Max 1000 orders at a time.'; END IF;
  RETURN QUERY
    SELECT o.id, t.invoice_no, coalesce(t.updated_at, t.entered_at),
           nullif(da.j->>'loading_completed_at','')::timestamptz,
           od.out_at, od.out_by_name
    FROM (SELECT DISTINCT x FROM unnest(p_ids) AS x) ids
    JOIN public.orders o ON o.id = ids.x
    LEFT JOIN public.lwb_tally_invoices t ON t.order_id = o.id
    LEFT JOIN public.lwb_po_out_delivery od ON od.order_id = o.id
    LEFT JOIN LATERAL (
      SELECT to_jsonb(a) AS j FROM public.dispatch_assignments a
      WHERE a.order_id = o.id
      ORDER BY (to_jsonb(a)->>'assigned_at') DESC NULLS LAST
      LIMIT 1) da ON true;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_mark_out_for_delivery(uuid[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_undo_out_for_delivery(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_po_flow_flags(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_mark_out_for_delivery(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_undo_out_for_delivery(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_po_flow_flags(uuid[]) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
