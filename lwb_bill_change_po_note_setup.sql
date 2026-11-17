-- PO change (Billing "± Qty / Items") -> shown on the PO and followed everywhere (17 Nov 2026, Mohit:
-- "PO update ho to vahan likhna chahiye kya update hua, qty less / plus, amount change; ledger, accounts,
-- sales side, sales team sab jagah change hona chahiye").
--
-- 1. After loading a change moves loaded_qty. Most sales screens (My Orders, dashboards, Sales Tracking
--    "Booked", Party Buying, targets) count approved qty, so they kept the old qty. Now the approved qty
--    moves by the same +/- as the loaded qty (never below 0), once per change (lwb_bill_changes.ok_synced).
--    A short at loading (approved > loaded) stays as it was. Godown stock is not touched by this: the
--    "booked" stock only counts POs not loaded yet.
-- 2. orders.bill_changes (jsonb) keeps the approved changes of the PO, so every page that can read the PO
--    can show "what changed" (SKU qty old -> new, rate, old -> new value, who / when) without new rights.
-- Old approved changes are brought up to date once at the end. Safe to run again.

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS bill_changes jsonb;
ALTER TABLE public.lwb_bill_changes ADD COLUMN IF NOT EXISTS ok_synced boolean NOT NULL DEFAULT false;

-- approved qty follows the loaded qty change (+/-) of one applied change, once
CREATE OR REPLACE FUNCTION public.lwb_bill_change_ok_follow(p_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  c public.lwb_bill_changes%ROWTYPE;
  l jsonb;
  v_d numeric;
BEGIN
  SELECT * INTO c FROM public.lwb_bill_changes WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR c.ok_synced THEN RETURN; END IF;
  IF c.qty_col = 'loaded_qty' THEN
    FOR l IN SELECT * FROM jsonb_array_elements(c.lines) LOOP
      CONTINUE WHEN coalesce(l->>'item_id','') = '';   -- a new line was added with approved = loaded already
      v_d := coalesce((l->>'qty')::numeric,0) - coalesce((l->>'qty_old')::numeric,0);
      CONTINUE WHEN v_d = 0;
      UPDATE public.order_items
         SET approved_qty = greatest(coalesce(approved_qty, ordered_qty, 0) + v_d, 0)
       WHERE order_id = c.order_id AND id::text = l->>'item_id';
    END LOOP;
  END IF;
  UPDATE public.lwb_bill_changes SET ok_synced = true WHERE id = p_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_change_ok_follow(uuid) FROM PUBLIC, anon, authenticated;

-- orders.bill_changes = the approved changes of this PO, oldest first
CREATE OR REPLACE FUNCTION public.lwb_bill_change_po_note(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  UPDATE public.orders o SET bill_changes = (
    SELECT nullif(coalesce(jsonb_agg(jsonb_build_object(
             'no', c.change_no, 'at', coalesce(c.decided_at, c.requested_at),
             'by', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = c.requested_by),
             'ok_by', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = c.decided_by),
             'reason', c.reason, 'old', c.old_value, 'new', c.new_value, 'diff', c.diff, 'col', c.qty_col,
             'lines', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                         'item_id', x->>'item_id', 'sku_old', x->>'sku_old', 'sku', x->>'sku',
                         'qty_old', (x->>'qty_old')::numeric, 'qty', (x->>'qty')::numeric,
                         'rate_old', (x->>'rate_old')::numeric, 'rate', (x->>'rate')::numeric)), '[]'::jsonb)
                       FROM jsonb_array_elements(c.lines) x))
           ORDER BY coalesce(c.decided_at, c.requested_at)), '[]'::jsonb), '[]'::jsonb)
    FROM public.lwb_bill_changes c WHERE c.order_id = p_order_id AND c.status = 'APPROVED')
  WHERE o.id = p_order_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_change_po_note(uuid) FROM PUBLIC, anon, authenticated;

-- applied (lwb_bill_change_apply writes bill_applied): approved follows, then line amounts + PO header
CREATE OR REPLACE FUNCTION public.lwb_bill_change_po_sync_trg()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  PERFORM public.lwb_bill_change_ok_follow(NEW.id);
  PERFORM public.lwb_bill_change_po_sync(NEW.order_id, NEW.qty_col);
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_change_po_sync_trg() FROM PUBLIC, anon, authenticated;

-- approved (status set after the apply): the PO keeps the note
CREATE OR REPLACE FUNCTION public.lwb_bill_change_po_note_trg()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NEW.status = 'APPROVED' OR OLD.status = 'APPROVED' THEN
    PERFORM public.lwb_bill_change_po_note(NEW.order_id);
  END IF;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_change_po_note_trg() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS lwb_bill_change_po_note ON public.lwb_bill_changes;
CREATE TRIGGER lwb_bill_change_po_note AFTER UPDATE OF status ON public.lwb_bill_changes
  FOR EACH ROW EXECUTE FUNCTION public.lwb_bill_change_po_note_trg();

-- Old approved changes: approved qty follows (oldest first), header + note brought up to date.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.id FROM public.lwb_bill_changes c WHERE c.status = 'APPROVED' AND NOT c.ok_synced
           ORDER BY coalesce(c.decided_at, c.requested_at) LOOP
    PERFORM public.lwb_bill_change_ok_follow(r.id);
  END LOOP;
  FOR r IN SELECT DISTINCT ON (c.order_id) c.order_id, c.qty_col
           FROM public.lwb_bill_changes c WHERE c.status = 'APPROVED'
           ORDER BY c.order_id, coalesce(c.decided_at, c.requested_at) DESC LOOP
    PERFORM public.lwb_bill_change_po_sync(r.order_id, r.qty_col);
    PERFORM public.lwb_bill_change_po_note(r.order_id);
  END LOOP;
END $$;
