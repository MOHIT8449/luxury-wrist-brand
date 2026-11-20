-- LUXURY WRIST BRAND ERP — ONE BALANCE PER PARTY PER BRAND (Outstanding = Ledger)
--
-- Runs by itself when merged to main (after lwb_brand_money_setup.sql, lwb_cashier_role_setup.sql).
-- Safe to run again. Nothing is deleted; no payment or bill amount is changed.
--
-- Mohit (20 Nov 2026): RAVI SALES (GOPI PURA) showed "₹3,601 due, Part paid" on Outstanding while its
-- ledger ended at −₹3,591 (we hold its money). Cause: a party payment entered with "Choose bills" or
-- "Keep as advance" set only part of the money against bills; the rest stayed as advance of that
-- brand while another bill of the SAME brand was still due. The ledger (bills − payments) nets them,
-- the bill-wise list does not, so one screen said + and the other −.
--
--  1. lwb_party_receive (patched in place, the live text keeps its Cashier rule): after the split
--     chosen on the screen, money still free of that brand goes to that brand's bills, oldest first.
--     So a brand never has advance and a bill due at the same time. Coca-Cola money never goes to a
--     Rajnigandha bill and the other way round (lwb_party_apply_b checks the brand of every PO).
--  2. One-time fix of old data: every party + brand that has free money and a bill due of the same
--     brand gets it set, oldest bill first (same function as the screen).
--     Backup first: lwb_party_settle_backup (free money and bill due per party + brand before) and
--     lwb_party_settle_log (each new split, so it can be undone with lwb_party_unadjust).
--  3. Check: the file stops (nothing kept) if any party + brand still has both.
--
-- Money with no brand chosen (bank statement on a two-brand party) is not touched: Accounts picks
-- the brand on Party & Collections > Payments, then it is set by itself (lwb_party_receipt_brand).

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Backup tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_party_settle_backup (
  id         bigserial PRIMARY KEY,
  run_at     timestamptz NOT NULL DEFAULT now(),
  parent     text NOT NULL,
  company_id uuid,
  free       numeric(14,2) NOT NULL,
  bills_due  numeric(14,2) NOT NULL,
  allocs     jsonb NOT NULL DEFAULT '[]'::jsonb
);
CREATE TABLE IF NOT EXISTS public.lwb_party_settle_log (
  id         bigserial PRIMARY KEY,
  run_at     timestamptz NOT NULL DEFAULT now(),
  parent     text NOT NULL,
  company_id uuid,
  alloc_id   uuid NOT NULL,
  order_id   uuid NOT NULL,
  amount     numeric(14,2) NOT NULL
);
ALTER TABLE public.lwb_party_settle_backup ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_party_settle_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_party_settle_backup, public.lwb_party_settle_log FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Party payment: rest of the money goes to the same brand's other bills
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE d text;
  v_old text := 'v_split := public.lwb_party_apply_b(v_parent, v_co, p_allocs);';
  v_new text := 'v_split := public.lwb_party_apply_b(v_parent, v_co, p_allocs);
    -- one balance per brand (20 Nov 2026): money left after the chosen split pays the oldest due bill of the same brand
    IF p_allocs IS NOT NULL THEN v_split := v_split + public.lwb_party_apply_b(v_parent, v_co, NULL); END IF;';
BEGIN
  d := pg_get_functiondef('public.lwb_party_receive(text,date,jsonb,jsonb,text,uuid)'::regprocedure);
  IF position('one balance per brand' IN d) = 0 THEN
    IF position(v_old IN d) = 0 THEN RAISE EXCEPTION 'lwb_party_receive: split line not found, not patched'; END IF;
    EXECUTE replace(d, v_old, v_new);
  END IF;
END
$patch$;

-- ---------------------------------------------------------------------------
-- 2. Old data: backup, then set free money against due bills of the same brand
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE lwb_tmp_settle ON COMMIT DROP AS
WITH free AS (
  SELECT public.lwb_party_parent(min(p.party)) AS parent, (array_agg(p.company_id))[1] AS company_id,
         sum(p.amount) - coalesce((SELECT sum(a.amount) FROM public.lwb_party_allocs a
                                   WHERE a.receipt_id = p.receipt_id AND a.cancelled_at IS NULL),0) AS free,
         (array_agg(p.created_by ORDER BY p.created_at DESC))[1] AS by_user
  FROM public.lwb_tally_payments p
  WHERE p.order_id IS NULL AND p.cancelled_at IS NULL AND p.company_id IS NOT NULL
  GROUP BY p.receipt_id
), f AS (
  SELECT public.lwb_party_key(parent) AS pkey, min(parent) AS parent, company_id,
         round(sum(free),2) AS free, (array_agg(by_user))[1] AS by_user
  FROM free GROUP BY 1, 3 HAVING sum(free) > 0.5
), due AS (
  SELECT public.lwb_party_key(public.lwb_party_parent(o.customer_name)) AS pkey,
         public.lwb_order_company(t.order_id) AS company_id,
         round(sum(greatest(public.lwb_order_tally_due(t.order_id),0)),2) AS due
  FROM public.lwb_tally_invoices t JOIN public.orders o ON o.id = t.order_id
  WHERE t.amount IS NOT NULL
  GROUP BY 1, 2
)
SELECT f.parent, f.company_id, f.free, d.due, f.by_user
FROM f JOIN due d ON d.pkey = f.pkey AND d.company_id = f.company_id
WHERE d.due > 0.5;

INSERT INTO public.lwb_party_settle_backup (parent, company_id, free, bills_due, allocs)
SELECT s.parent, s.company_id, s.free, s.due,
       (SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'receipt_id', a.receipt_id, 'order_id', a.order_id, 'amount', a.amount)), '[]'::jsonb)
        FROM public.lwb_party_allocs a JOIN public.lwb_tally_payments p ON p.receipt_id = a.receipt_id AND p.order_id IS NULL
        WHERE a.cancelled_at IS NULL AND p.company_id = s.company_id
          AND public.lwb_party_key(public.lwb_party_parent(p.party)) = public.lwb_party_key(s.parent))
FROM lwb_tmp_settle s;

DO $fix$
DECLARE s record; v_who uuid;
BEGIN
  FOR s IN SELECT * FROM lwb_tmp_settle ORDER BY parent LOOP
    -- the split is written in the name of the person who took the money (created_by is required)
    v_who := coalesce(s.by_user, (SELECT u.id FROM public.user_profiles u WHERE u.active AND lower(btrim(u.role)) = 'admin' ORDER BY u.id LIMIT 1));
    PERFORM set_config('request.jwt.claim.sub', v_who::text, true);
    PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(s.parent)));
    PERFORM public.lwb_party_apply_b(s.parent, s.company_id, NULL);
  END LOOP;
  PERFORM set_config('request.jwt.claim.sub', '', true);
  INSERT INTO public.lwb_party_settle_log (parent, company_id, alloc_id, order_id, amount)
  SELECT public.lwb_party_parent(p.party), p.company_id, a.id, a.order_id, a.amount
  FROM public.lwb_party_allocs a
  JOIN LATERAL (SELECT q.party, q.company_id FROM public.lwb_tally_payments q
                WHERE q.receipt_id = a.receipt_id AND q.order_id IS NULL LIMIT 1) p ON true
  WHERE a.cancelled_at IS NULL AND a.created_at >= now()  -- made in this run (now() = start of this transaction)
    AND NOT EXISTS (SELECT 1 FROM public.lwb_party_settle_log l WHERE l.alloc_id = a.id);
END
$fix$;

-- ---------------------------------------------------------------------------
-- 3. Check: no party + brand has free money and a due bill of that brand any more
-- ---------------------------------------------------------------------------
DO $check$
DECLARE v_bad int;
BEGIN
  SELECT count(*) INTO v_bad FROM (
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
  IF v_bad > 0 THEN RAISE EXCEPTION 'Party settle: % party/brand still have advance and a due bill', v_bad; END IF;
END
$check$;

COMMIT;

-- Result rows (for a person running it by hand)
SELECT 'party/brand settled now' AS item, (SELECT count(*) FROM public.lwb_party_settle_backup WHERE run_at >= now() - interval '1 hour')::text AS value
UNION ALL
SELECT 'new splits', (SELECT count(*) FROM public.lwb_party_settle_log WHERE run_at >= now() - interval '1 hour')::text;
