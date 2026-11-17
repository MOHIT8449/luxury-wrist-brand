-- PO change (Billing "± Qty / Items") -> the PO itself follows (17 Nov 2026, Mohit:
-- "account bill update kare vo PO mein update nahi ho raha").
--
-- Before this, an approved change (or Admin's own "Save change") only changed the order_items lines
-- (approved_qty before loading, loaded_qty after) and the Tally bill. The PO header totals
-- (orders.total_qty / total_amount / total_weight) were never touched, so the PO / Sales List, the PO
-- popup summary and every report reading orders.total_amount kept the old value. After loading the line
-- amount / weight were not touched either, and a new SKU line was added with weight 0.
--
-- Now, every time lwb_bill_change_apply runs (it always ends by writing lwb_bill_changes.bill_applied),
-- lwb_bill_change_po_sync(order, qty column):
--   * new line with weight 0 -> weight per case from SKU Master (unit_weight_kg) when known;
--   * each line: amount = approved qty x rate, total_weight = approved qty x weight (same meaning as before);
--   * PO header: total_qty / total_amount / total_weight = the qty the bill counts
--     (loaded qty after loading, approved qty before), so the PO value = the bill value.
-- Old approved changes are synced once at the end of this file.
-- Safe to run again.

CREATE OR REPLACE FUNCTION public.lwb_bill_change_po_sync(p_order_id uuid, p_col text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF p_order_id IS NULL THEN RETURN; END IF;

  -- a SKU added by the change came in with weight 0: take it from SKU Master when the column exists
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'sku_master' AND column_name = 'unit_weight_kg') THEN
    EXECUTE 'UPDATE public.order_items i SET unit_weight = s.w
             FROM (SELECT DISTINCT ON (upper(btrim(sku_name::text))) upper(btrim(sku_name::text)) AS k, unit_weight_kg::numeric AS w
                   FROM public.sku_master WHERE coalesce(unit_weight_kg::numeric,0) > 0
                   ORDER BY upper(btrim(sku_name::text)), is_active DESC NULLS LAST) s
             WHERE i.order_id = $1 AND coalesce(i.unit_weight,0) = 0 AND upper(btrim(i.sku_name::text)) = s.k'
      USING p_order_id;
  END IF;

  UPDATE public.order_items i
     SET amount = coalesce(i.approved_qty, i.ordered_qty, 0) * coalesce(i.rate,0),
         total_weight = coalesce(i.approved_qty, i.ordered_qty, 0) * coalesce(i.unit_weight,0)
   WHERE i.order_id = p_order_id
     AND (i.amount IS DISTINCT FROM coalesce(i.approved_qty, i.ordered_qty, 0) * coalesce(i.rate,0)
          OR i.total_weight IS DISTINCT FROM coalesce(i.approved_qty, i.ordered_qty, 0) * coalesce(i.unit_weight,0));

  UPDATE public.orders o
     SET total_qty = t.q, total_amount = round(t.a, 2), total_weight = t.w
    FROM (SELECT coalesce(sum(x.q),0) AS q, coalesce(sum(x.q * x.r),0) AS a, coalesce(sum(x.q * x.w),0) AS w
          FROM (SELECT CASE WHEN p_col = 'loaded_qty' THEN coalesce(i.loaded_qty, i.approved_qty, i.ordered_qty, 0)
                            ELSE coalesce(i.approved_qty, i.ordered_qty, 0) END AS q,
                       coalesce(i.rate,0) AS r, coalesce(i.unit_weight,0) AS w
                FROM public.order_items i WHERE i.order_id = p_order_id) x) t
   WHERE o.id = p_order_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_change_po_sync(uuid, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_bill_change_po_sync_trg()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  PERFORM public.lwb_bill_change_po_sync(NEW.order_id, NEW.qty_col);
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_change_po_sync_trg() FROM PUBLIC, anon, authenticated;

-- lwb_bill_change_apply always ends with "UPDATE lwb_bill_changes SET bill_applied = ...", only when it applied the lines.
DROP TRIGGER IF EXISTS lwb_bill_change_po_sync ON public.lwb_bill_changes;
CREATE TRIGGER lwb_bill_change_po_sync AFTER UPDATE OF bill_applied ON public.lwb_bill_changes
  FOR EACH ROW EXECUTE FUNCTION public.lwb_bill_change_po_sync_trg();

-- Changes approved before this file: bring their PO header up to date once.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT DISTINCT ON (c.order_id) c.order_id, c.qty_col
           FROM public.lwb_bill_changes c WHERE c.status = 'APPROVED'
           ORDER BY c.order_id, c.decided_at DESC NULLS LAST, c.requested_at DESC LOOP
    PERFORM public.lwb_bill_change_po_sync(r.order_id, r.qty_col);
  END LOOP;
END $$;
