-- LUXURY WRIST BRAND ERP — A BILL NEVER KEEPS MORE PARTY MONEY THAN ITS DUE
--
-- Runs by itself when merged to main (after lwb_party_brand_settle_setup.sql). Safe to run again.
-- Nothing is deleted: a split that is too big is cancelled (kept) and a smaller one written.
--
-- Mohit (20 Nov 2026, after lwb_party_brand_settle_setup.sql): RAVI SALES (GOPI PURA) Rajnigandha still
-- showed bill LXY-00480 ₹3,601 due while the ledger said advance ₹3,591. All its money was already set
-- to bills, but an older bill held MORE party money than the bill (its amount went down after the money
-- was set: bill change / credit note / Tally amount fixed). That extra (₹7,192) sat on the old bill as
-- "paid more than bill" instead of paying the new bill, so the bill list said + and the ledger said −.
--
--  1. lwb_party_trim_over(order): party money on a bill above its due is taken off (newest split first)
--     and becomes free money of that payment (same brand) again.
--  2. Runs by itself when a Tally bill amount is saved / changed (trg_lwb_party_auto_adjust) and when a
--     credit / debit note is saved or cancelled; then that brand's free money pays its oldest due bill.
--  3. One-time fix of old data, every change logged in lwb_party_trim_log (old split, new split).
--  4. Check: the file stops (nothing kept) if a bill still has party money above its bill, or a party +
--     brand still has free money and a due bill of that brand.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_party_trim_log (
  id            bigserial PRIMARY KEY,
  run_at        timestamptz NOT NULL DEFAULT now(),
  order_id      uuid NOT NULL,
  receipt_id    uuid NOT NULL,
  old_alloc_id  uuid NOT NULL,
  old_amount    numeric(14,2) NOT NULL,
  new_alloc_id  uuid,
  new_amount    numeric(14,2)
);
ALTER TABLE public.lwb_party_trim_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_party_trim_log FROM anon, authenticated;

-- 1. Take party money above the due off one bill. Internal (callers lock the party).
CREATE OR REPLACE FUNCTION public.lwb_party_trim_over(p_order_id uuid)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_over numeric; v_take numeric; v_trim numeric := 0; v_new uuid; a record;
BEGIN
  v_over := -public.lwb_order_tally_due(p_order_id);
  IF v_over IS NULL OR v_over < 0.5 THEN RETURN 0; END IF;
  FOR a IN SELECT * FROM public.lwb_party_allocs x
           WHERE x.order_id = p_order_id AND x.cancelled_at IS NULL
           ORDER BY x.created_at DESC, x.id DESC FOR UPDATE LOOP
    EXIT WHEN v_over < 0.005;
    v_take := least(a.amount, round(v_over, 2));
    UPDATE public.lwb_party_allocs SET cancelled_at = now(), cancelled_by = a.created_by WHERE id = a.id;
    v_new := NULL;
    IF a.amount - v_take >= 0.01 THEN
      INSERT INTO public.lwb_party_allocs (receipt_id, order_id, amount, created_by)
      VALUES (a.receipt_id, a.order_id, round(a.amount - v_take, 2), a.created_by) RETURNING id INTO v_new;
    END IF;
    INSERT INTO public.lwb_party_trim_log (order_id, receipt_id, old_alloc_id, old_amount, new_alloc_id, new_amount)
    VALUES (a.order_id, a.receipt_id, a.id, a.amount, v_new, CASE WHEN v_new IS NOT NULL THEN round(a.amount - v_take, 2) END);
    v_over := v_over - v_take; v_trim := v_trim + v_take;
  END LOOP;
  RETURN round(v_trim, 2);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_trim_over(uuid) FROM PUBLIC, anon, authenticated;

-- Trim one bill, then pay that brand's oldest due bills with the free money (needs a user for created_by).
CREATE OR REPLACE FUNCTION public.lwb_party_refit(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_parent text; v_co uuid;
BEGIN
  SELECT public.lwb_party_parent(o.customer_name) INTO v_parent FROM public.orders o WHERE o.id = p_order_id;
  IF v_parent IS NULL OR v_parent = '' THEN RETURN; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(v_parent)));
  PERFORM public.lwb_party_trim_over(p_order_id);
  v_co := public.lwb_order_company(p_order_id);
  IF v_co IS NOT NULL AND auth.uid() IS NOT NULL THEN
    PERFORM public.lwb_party_apply_b(v_parent, v_co, NULL);
  END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_refit(uuid) FROM PUBLIC, anon, authenticated;

-- 2. Bill amount saved / changed: trim, then that brand's free money pays its due bills (never blocks the save).
CREATE OR REPLACE FUNCTION public.lwb_party_auto_adjust()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NEW.amount IS NULL THEN RETURN NULL; END IF;
  BEGIN
    PERFORM public.lwb_party_refit(NEW.order_id);
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_auto_adjust() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_party_auto_adjust ON public.lwb_tally_invoices;
CREATE TRIGGER trg_lwb_party_auto_adjust AFTER INSERT OR UPDATE OF amount ON public.lwb_tally_invoices
  FOR EACH ROW EXECUTE FUNCTION public.lwb_party_auto_adjust();

-- Credit / debit note saved or cancelled: same.
CREATE OR REPLACE FUNCTION public.lwb_party_note_refit()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NEW.order_id IS NULL THEN RETURN NULL; END IF;
  BEGIN
    PERFORM public.lwb_party_refit(NEW.order_id);
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_note_refit() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_party_note_refit ON public.lwb_tally_notes;
CREATE TRIGGER trg_lwb_party_note_refit AFTER INSERT OR UPDATE OF amount, cancelled_at ON public.lwb_tally_notes
  FOR EACH ROW EXECUTE FUNCTION public.lwb_party_note_refit();

-- 3. Old data
DO $fix$
DECLARE r record; v_who uuid;
BEGIN
  -- bills holding party money above their due
  FOR r IN SELECT DISTINCT a.order_id FROM public.lwb_party_allocs a
           JOIN public.lwb_tally_invoices t ON t.order_id = a.order_id AND t.amount IS NOT NULL
           WHERE a.cancelled_at IS NULL AND public.lwb_order_tally_due(a.order_id) < -0.5 LOOP
    PERFORM public.lwb_party_trim_over(r.order_id);
  END LOOP;
  -- free money of a brand -> that brand's oldest due bills
  FOR r IN
    WITH f AS (
      SELECT public.lwb_party_key(public.lwb_party_parent(min(p.party))) AS pk, min(public.lwb_party_parent(p.party)) AS parent,
             (array_agg(p.company_id))[1] AS c, (array_agg(p.created_by ORDER BY p.created_at DESC))[1] AS by_user,
             sum(p.amount) - coalesce((SELECT sum(a.amount) FROM public.lwb_party_allocs a
                                       WHERE a.receipt_id = p.receipt_id AND a.cancelled_at IS NULL),0) AS free
      FROM public.lwb_tally_payments p
      WHERE p.order_id IS NULL AND p.cancelled_at IS NULL AND p.company_id IS NOT NULL
      GROUP BY p.receipt_id)
    SELECT pk, min(parent) AS parent, c, (array_agg(by_user))[1] AS by_user FROM f GROUP BY pk, c HAVING sum(free) > 0.5
  LOOP
    v_who := coalesce(r.by_user, (SELECT u.id FROM public.user_profiles u WHERE u.active AND lower(btrim(u.role)) = 'admin' ORDER BY u.id LIMIT 1));
    PERFORM set_config('request.jwt.claim.sub', v_who::text, true);
    PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || r.pk));
    PERFORM public.lwb_party_apply_b(r.parent, r.c, NULL);
  END LOOP;
  PERFORM set_config('request.jwt.claim.sub', '', true);
END
$fix$;

-- 4. Check
DO $check$
DECLARE v_over int; v_both int;
BEGIN
  SELECT count(DISTINCT a.order_id) INTO v_over FROM public.lwb_party_allocs a
  JOIN public.lwb_tally_invoices t ON t.order_id = a.order_id AND t.amount IS NOT NULL
  WHERE a.cancelled_at IS NULL AND public.lwb_order_tally_due(a.order_id) < -0.5;
  SELECT count(*) INTO v_both FROM (
    SELECT f.pk, f.c FROM (
      SELECT public.lwb_party_key(public.lwb_party_parent(min(p.party))) AS pk, (array_agg(p.company_id))[1] AS c,
             sum(p.amount) - coalesce((SELECT sum(a.amount) FROM public.lwb_party_allocs a
                                       WHERE a.receipt_id = p.receipt_id AND a.cancelled_at IS NULL),0) AS free
      FROM public.lwb_tally_payments p
      WHERE p.order_id IS NULL AND p.cancelled_at IS NULL AND p.company_id IS NOT NULL
      GROUP BY p.receipt_id) f
    GROUP BY f.pk, f.c HAVING sum(f.free) > 0.5) fr
  WHERE EXISTS (SELECT 1 FROM public.lwb_tally_invoices t JOIN public.orders o ON o.id = t.order_id
                WHERE t.amount IS NOT NULL AND public.lwb_order_company(t.order_id) = fr.c
                  AND public.lwb_party_key(public.lwb_party_parent(o.customer_name)) = fr.pk
                  AND public.lwb_order_tally_due(t.order_id) > 0.5);
  IF v_over > 0 OR v_both > 0 THEN
    RAISE EXCEPTION 'Party money fix: % bill(s) still over-paid by party money, % party/brand still advance + due', v_over, v_both;
  END IF;
END
$check$;

COMMIT;

SELECT 'party splits trimmed' AS item, (SELECT count(*) FROM public.lwb_party_trim_log)::text AS value;
