-- LUXURY WRIST BRAND ERP — READ-ONLY CHECK of party money (changes nothing).
-- (Not kept on main.) Run by hand from Actions > Supabase apply > Run workflow with this file name. It always stops with an
-- ERROR line that shows only COUNTS (no party names, no amounts), because this repo's logs are public.
--   over        bills holding more party money than their due
--   both        party + brand with free money and a due bill of that brand
--   lines       Tally bills whose amount is not the sum of their bill lines (ledger shows the lines)
--   ravi_*      the same three for RAVI SALES (GOPI PURA) only
DO $diag$
DECLARE v_over int; v_both int; v_lines int; r_over int; r_lines int; r_free int;
BEGIN
  SELECT count(DISTINCT a.order_id) INTO v_over FROM public.lwb_party_allocs a
  JOIN public.lwb_tally_invoices t ON t.order_id = a.order_id AND t.amount IS NOT NULL
  WHERE a.cancelled_at IS NULL AND public.lwb_order_tally_due(a.order_id) < -0.5;
  SELECT count(*) INTO v_both FROM (
    SELECT public.lwb_party_key(public.lwb_party_parent(min(p.party))) AS pk, (array_agg(p.company_id))[1] AS c,
           sum(p.amount) - coalesce((SELECT sum(a.amount) FROM public.lwb_party_allocs a WHERE a.receipt_id = p.receipt_id AND a.cancelled_at IS NULL),0) AS free
    FROM public.lwb_tally_payments p WHERE p.order_id IS NULL AND p.cancelled_at IS NULL AND p.company_id IS NOT NULL
    GROUP BY p.receipt_id) f
  WHERE f.free > 0.5 AND EXISTS (SELECT 1 FROM public.lwb_tally_invoices t JOIN public.orders o ON o.id = t.order_id
        WHERE public.lwb_order_company(t.order_id) = f.c AND public.lwb_party_key(public.lwb_party_parent(o.customer_name)) = f.pk
          AND public.lwb_order_tally_due(t.order_id) > 0.5);
  SELECT count(*) INTO v_lines FROM public.lwb_tally_invoices t
  WHERE t.amount IS NOT NULL AND jsonb_typeof(t.bills) = 'array' AND jsonb_array_length(t.bills) > 0
    AND abs(t.amount - (SELECT coalesce(sum((b->>'amount')::numeric),0) FROM jsonb_array_elements(t.bills) b)) > 0.5;
  SELECT count(*) FILTER (WHERE public.lwb_order_tally_due(t.order_id) < -0.5),
         count(*) FILTER (WHERE jsonb_typeof(t.bills) = 'array' AND jsonb_array_length(t.bills) > 0
                            AND abs(t.amount - (SELECT coalesce(sum((b->>'amount')::numeric),0) FROM jsonb_array_elements(t.bills) b)) > 0.5)
    INTO r_over, r_lines
  FROM public.lwb_tally_invoices t JOIN public.orders o ON o.id = t.order_id
  WHERE t.amount IS NOT NULL AND public.lwb_party_key(public.lwb_party_parent(o.customer_name)) = public.lwb_party_key('RAVI SALES (GOPI PURA)');
  SELECT count(*) INTO r_free FROM (
    SELECT sum(p.amount) - coalesce((SELECT sum(a.amount) FROM public.lwb_party_allocs a WHERE a.receipt_id = p.receipt_id AND a.cancelled_at IS NULL),0) AS free
    FROM public.lwb_tally_payments p WHERE p.order_id IS NULL AND p.cancelled_at IS NULL
      AND public.lwb_party_key(public.lwb_party_parent(p.party)) = public.lwb_party_key('RAVI SALES (GOPI PURA)')
    GROUP BY p.receipt_id) f WHERE f.free > 0.5;
  RAISE EXCEPTION 'CHECK ONLY (nothing changed): over=% both=% lines=% ravi_over=% ravi_lines=% ravi_free_receipts=%',
    v_over, v_both, v_lines, r_over, r_lines, r_free;
END
$diag$;
