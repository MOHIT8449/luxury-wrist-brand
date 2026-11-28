-- LUXURY WRIST BRAND ERP — ADMIN: TAKE BACK "DELIVERED" ON A PO MARKED BY MISTAKE (25 Nov 2026)
--
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped.
--
-- Mohit (25 Nov 2026): some POs were only Loaded but got marked Delivered by mistake (about 5 today). Admin needs a
-- button to put such a PO back to Loaded (or Out for delivery), with a confirm and a log line.
--   * lwb_admin_undo_delivered(order, to, reason): Admin only. to = 'LOADED' or 'OUT' (Out for delivery; needs the
--       Tally bill). Reason is required.
--       - the "Delivered" mark (lwb_admin_order_marks kind DELIVERED) is removed,
--       - a driver delivery report Delivered / Partial with no money collected is removed (with money: refused,
--         the driver's cash is already in his ledger),
--       - orders.status delivered / closed / completed -> 'loaded',
--       - OUT keeps / adds the Out for delivery row; LOADED removes it.
--       Every undo is kept in lwb_po_undo_delivered (what was removed, as jsonb, who, when, reason).
--       Bells raised by the status change itself ("Vehicle Loaded", "make Tally bill") are marked read at once, so
--       no phone push goes out for them.
--   * lwb_po_undo_delivered_log(order ids): the undo lines, for the PO popup (same readers as the marks).
-- Stock, loaded qty, Tally bill, payments and ledger are not touched (stock already went out at loading).

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_po_undo_delivered (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  old_status text,
  to_step text NOT NULL CHECK (to_step IN ('LOADED','OUT')),
  mark_before jsonb,
  report_before jsonb,
  reason text NOT NULL CHECK (length(reason) BETWEEN 1 AND 300),
  undone_by uuid NOT NULL,
  undone_by_name text,
  undone_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_po_undo_delivered_order ON public.lwb_po_undo_delivered(order_id, undone_at DESC);
ALTER TABLE public.lwb_po_undo_delivered ENABLE ROW LEVEL SECURITY;  -- read / write through the functions only
REVOKE ALL ON public.lwb_po_undo_delivered FROM PUBLIC, anon, authenticated;

-- Out for delivery table (lwb_po_out_for_delivery_setup.sql), here too if that file has not run yet.
CREATE TABLE IF NOT EXISTS public.lwb_po_out_delivery (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  out_at timestamptz NOT NULL DEFAULT now(),
  out_by uuid,
  out_by_name text
);
ALTER TABLE public.lwb_po_out_delivery ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_po_out_delivery FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_admin_undo_delivered(p_order_id uuid, p_to text, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_me text;
  v_o public.orders%ROWTYPE;
  v_st text;
  v_to text := upper(btrim(coalesce(p_to, '')));
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_mark jsonb;
  v_rep jsonb;
  v_cash numeric;
BEGIN
  SELECT coalesce(nullif(btrim(p.full_name), ''), 'Admin') INTO v_me FROM public.user_profiles p
  WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'admin';
  IF NOT FOUND THEN RAISE EXCEPTION 'Only Admin can take back Delivered'; END IF;
  IF v_to NOT IN ('LOADED','OUT') THEN RAISE EXCEPTION 'Choose Loaded or Out for delivery'; END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Write the reason'; END IF;
  IF length(v_reason) > 300 THEN RAISE EXCEPTION 'Reason is too long'; END IF;

  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  v_st := lower(btrim(coalesce(v_o.status::text, '')));

  SELECT to_jsonb(m) INTO v_mark FROM public.lwb_admin_order_marks m WHERE m.order_id = v_o.id AND m.kind = 'DELIVERED';
  SELECT to_jsonb(d) INTO v_rep FROM public.lwb_delivery_reports d
  WHERE d.order_id = v_o.id AND d.delivery_status IN ('DELIVERED','PARTIAL');

  IF v_st NOT IN ('delivered','closed','completed') AND v_mark IS NULL AND v_rep IS NULL THEN
    RAISE EXCEPTION 'PO % is not delivered', v_o.order_no;
  END IF;
  IF v_st NOT IN ('delivered','closed','completed','loaded','invoiced','dispatched') THEN
    RAISE EXCEPTION 'PO % is % now, it cannot go back to Loaded', v_o.order_no, coalesce(nullif(v_st, ''), '-');
  END IF;
  v_cash := coalesce(nullif(v_rep ->> 'cash_reported', '')::numeric, 0);
  IF v_cash > 0 THEN
    RAISE EXCEPTION 'PO %: the driver reported Delivered with Rs % collected. Sort out the driver money first', v_o.order_no, v_cash;
  END IF;
  IF v_to = 'OUT' AND NOT EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = v_o.id) THEN
    RAISE EXCEPTION 'PO % has no Tally bill, so it can only go back to Loaded', v_o.order_no;
  END IF;

  DELETE FROM public.lwb_admin_order_marks WHERE order_id = v_o.id AND kind = 'DELIVERED';
  IF v_rep IS NOT NULL THEN
    DELETE FROM public.lwb_delivery_reports WHERE order_id = v_o.id AND delivery_status IN ('DELIVERED','PARTIAL');
  END IF;
  IF v_st IN ('delivered','closed','completed') THEN
    UPDATE public.orders SET status = 'loaded' WHERE id = v_o.id;
  END IF;
  IF v_to = 'OUT' THEN
    INSERT INTO public.lwb_po_out_delivery(order_id, out_by, out_by_name) VALUES (v_o.id, auth.uid(), v_me)
    ON CONFLICT (order_id) DO NOTHING;
  ELSE
    DELETE FROM public.lwb_po_out_delivery WHERE order_id = v_o.id;
  END IF;

  -- Bells made just now by the status change (Vehicle Loaded / make Tally bill / Order Loaded / Out for delivery):
  -- read at once, so no new popup or phone push for a PO that was already loaded.
  UPDATE public.erp_notifications SET is_read = true
  WHERE order_id = v_o.id AND is_read = false AND created_at >= now();
  -- the old "Delivered" bells of this PO are no longer true
  UPDATE public.erp_notifications SET is_read = true
  WHERE order_id = v_o.id AND is_read = false AND notification_type LIKE '%ORDER_DELIVERED%';

  INSERT INTO public.lwb_po_undo_delivered(order_id, old_status, to_step, mark_before, report_before, reason, undone_by, undone_by_name)
  VALUES (v_o.id, v_st, v_to, v_mark, v_rep, v_reason, auth.uid(), v_me);

  RETURN jsonb_build_object('order_id', v_o.id, 'order_no', v_o.order_no, 'old_status', v_st,
    'status', CASE WHEN v_st IN ('delivered','closed','completed') THEN 'loaded' ELSE v_st END, 'to', v_to,
    'mark_removed', v_mark IS NOT NULL, 'report_removed', v_rep IS NOT NULL);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_admin_undo_delivered(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_admin_undo_delivered(uuid,text,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_po_undo_delivered_log(p_ids uuid[])
RETURNS TABLE(order_id uuid, old_status text, to_step text, was_marked_by text, was_mark_date date, had_driver_report boolean,
              reason text, undone_by_name text, undone_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','warehouse','transport','accounts')) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;
  IF coalesce(cardinality(p_ids), 0) > 1000 THEN RAISE EXCEPTION 'Max 1000 orders at a time.'; END IF;
  RETURN QUERY
    SELECT u.order_id, u.old_status, u.to_step, u.mark_before ->> 'marked_by_name',
           nullif(u.mark_before ->> 'mark_date', '')::date, u.report_before IS NOT NULL,
           u.reason, u.undone_by_name, u.undone_at
    FROM public.lwb_po_undo_delivered u
    WHERE u.order_id = ANY(p_ids)
    ORDER BY u.undone_at DESC;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_undo_delivered_log(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_undo_delivered_log(uuid[]) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';
