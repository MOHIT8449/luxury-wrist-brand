-- LUXURY WRIST BRAND ERP — PARTY MONEY BRAND-WISE (Rajnigandha and Coca-Cola never mixed)
--
-- Runs by itself when merged to main (after lwb_party_group_billing_setup.sql,
-- lwb_party_auto_adjust_setup.sql, lwb_party_ledger_setup.sql, lwb_company_brand_setup.sql,
-- lwb_bank_statement_setup.sql). Safe to run again. No row is deleted, no amount is changed.
--
-- Mohit (4 Nov 2026): one party buys Rajnigandha and Coca-Cola. Their outstanding is separate and
-- must stay separate. When a payment comes, we must say for which brand (like a PO has a brand),
-- and every screen needs All / Rajnigandha / Coca-Cola.
--
--  1. Brand of a PO = the company of its SKU lines (sku_master.company_id). A PO with two brands
--     (old ones only; new ones are refused) has no single brand: lwb_order_company() = NULL.
--  2. lwb_tally_payments.company_id: a party payment (no PO) is for one brand. Its money goes only
--     to that brand's bills; what is left is that brand's advance.
--     Old party payments: set by itself when the party bought only one brand, else empty
--     ("brand not chosen") until Accounts / Admin picks it (lwb_party_receipt_brand).
--  3. lwb_party_opening_balances.company_id: one opening balance per party per brand.
--     Old openings: same rule as 2.
--  4. lwb_party_receive(.., p_company_id), lwb_party_adjust(.., p_company_id),
--     lwb_set_party_opening_balance(.., p_company_id): brand is needed when the party is not
--     one-brand. The bank statement "Party payment" passes p->>'company_id'.
--  5. New bill: the party's advance OF THAT BRAND is set against it by itself.
--  6. lwb_party_billing(): + company_id on every bill and receipt, advance_b / openings_b
--     (per party per brand) and companies. lwb_party_ledger_b(): ledger rows with company_id.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Brand of a PO / of a party
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_order_company(p_order_id uuid)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE WHEN count(DISTINCT s.company_id) = 1 THEN (array_agg(DISTINCT s.company_id) FILTER (WHERE s.company_id IS NOT NULL))[1] END
  FROM public.order_items i
  JOIN public.sku_master s ON upper(btrim(s.sku_name)) = upper(btrim(i.sku_name))
  WHERE i.order_id = p_order_id;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_company(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_company(uuid) TO authenticated;

-- The only brand a main party (with its bill names) ever bought; NULL when two or none.
-- With only one active company, that company.
CREATE OR REPLACE FUNCTION public.lwb_party_only_company(p_parent text)
RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE
    WHEN (SELECT count(*) FROM public.lwb_companies c WHERE c.active) = 1
      THEN (SELECT c.id FROM public.lwb_companies c WHERE c.active LIMIT 1)
    ELSE (SELECT CASE WHEN count(DISTINCT s.company_id) = 1 THEN (array_agg(DISTINCT s.company_id) FILTER (WHERE s.company_id IS NOT NULL))[1] END
          FROM public.orders o
          JOIN public.order_items i ON i.order_id = o.id
          JOIN public.sku_master s ON upper(btrim(s.sku_name)) = upper(btrim(i.sku_name))
          WHERE public.lwb_party_key(public.lwb_party_parent(o.customer_name)) = public.lwb_party_key(p_parent)
            AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected'))
  END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_only_company(text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Columns + fill old rows
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_tally_payments ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES public.lwb_companies(id);
ALTER TABLE public.lwb_party_opening_balances ADD COLUMN IF NOT EXISTS company_id uuid REFERENCES public.lwb_companies(id);
CREATE INDEX IF NOT EXISTS lwb_tally_payments_company_idx ON public.lwb_tally_payments(company_id) WHERE order_id IS NULL;

-- old party payments: the party's only brand (rows of one receipt get the same brand)
UPDATE public.lwb_tally_payments p SET company_id = x.c
FROM (SELECT q.receipt_id, public.lwb_party_only_company(public.lwb_party_parent(min(q.party))) AS c
      FROM public.lwb_tally_payments q WHERE q.order_id IS NULL AND q.company_id IS NULL GROUP BY q.receipt_id) x
WHERE p.receipt_id = x.receipt_id AND p.order_id IS NULL AND p.company_id IS NULL AND x.c IS NOT NULL;

UPDATE public.lwb_party_opening_balances b
SET company_id = public.lwb_party_only_company(public.lwb_party_parent(b.customer_name))
WHERE b.company_id IS NULL AND public.lwb_party_only_company(public.lwb_party_parent(b.customer_name)) IS NOT NULL;

-- one opening balance per party per brand (was one per party)
CREATE UNIQUE INDEX IF NOT EXISTS lwb_party_opening_balances_party_co_uidx
  ON public.lwb_party_opening_balances (upper(btrim(customer_name)), coalesce(company_id, '00000000-0000-0000-0000-000000000000'::uuid));
DROP INDEX IF EXISTS public.lwb_party_opening_balances_party_uidx;

-- ---------------------------------------------------------------------------
-- 3. Advance and split, per brand
-- ---------------------------------------------------------------------------
-- Money of a party's payments of one brand (NULL = brand not chosen) not split yet. Internal.
CREATE OR REPLACE FUNCTION public.lwb_party_receipt_free_b(p_parent text, p_company uuid)
RETURNS TABLE (receipt_id uuid, pay_date date, created_at timestamptz, total numeric, free numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT r.receipt_id, r.pay_date, r.created_at, r.total,
         round(r.total - COALESCE((SELECT sum(a.amount) FROM public.lwb_party_allocs a
                                   WHERE a.receipt_id = r.receipt_id AND a.cancelled_at IS NULL),0), 2)
  FROM (SELECT p.receipt_id, min(p.pay_date) AS pay_date, min(p.created_at) AS created_at, sum(p.amount) AS total
        FROM public.lwb_tally_payments p
        WHERE p.order_id IS NULL AND p.cancelled_at IS NULL
          AND p.company_id IS NOT DISTINCT FROM p_company
          AND public.lwb_party_key(public.lwb_party_parent(p.party)) = public.lwb_party_key(p_parent)
        GROUP BY p.receipt_id) r
  ORDER BY r.pay_date, r.created_at;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_receipt_free_b(text, uuid) FROM PUBLIC, anon, authenticated;

-- Split the advance of one brand over that brand's bills. Internal: callers check the role and lock.
-- p_allocs NULL = oldest bill of the brand first. Money with no brand is never split by itself.
-- A PO with two brands (old) may take money of either brand when picked by hand.
CREATE OR REPLACE FUNCTION public.lwb_party_apply_b(p_parent text, p_company uuid, p_allocs jsonb)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_free numeric; v_left numeric; v_want jsonb := '[]'::jsonb; v_line jsonb;
  v_order uuid; v_amt numeric; v_due numeric; v_party text; v_no text; v_oc uuid;
  v_seen uuid[] := '{}'; v_total numeric := 0; v_take numeric; v_bname text; r record;
BEGIN
  SELECT COALESCE(sum(f.free),0) INTO v_free FROM public.lwb_party_receipt_free_b(p_parent, p_company) f;
  SELECT c.name INTO v_bname FROM public.lwb_companies c WHERE c.id = p_company;

  IF p_allocs IS NULL THEN
    IF p_company IS NULL THEN RETURN 0; END IF;
    v_left := v_free;
    FOR r IN
      SELECT t.order_id, public.lwb_order_tally_due(t.order_id) AS due
      FROM public.lwb_tally_invoices t JOIN public.orders o ON o.id = t.order_id
      WHERE t.amount IS NOT NULL
        AND public.lwb_party_key(public.lwb_party_parent(o.customer_name)) = public.lwb_party_key(p_parent)
        AND public.lwb_order_company(t.order_id) = p_company
      ORDER BY t.invoice_date, t.entered_at, o.order_no
    LOOP
      EXIT WHEN v_left < 0.01;
      CONTINUE WHEN r.due IS NULL OR r.due < 0.01;
      v_take := least(r.due, v_left);
      v_want := v_want || jsonb_build_object('order_id', r.order_id, 'amount', v_take);
      v_left := v_left - v_take;
    END LOOP;
  ELSE
    IF jsonb_typeof(p_allocs) <> 'array' THEN RAISE EXCEPTION 'Bad split list'; END IF;
    IF jsonb_array_length(p_allocs) > 200 THEN RAISE EXCEPTION 'Too many bills in one split'; END IF;
    v_want := p_allocs;
  END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(v_want) LOOP
    BEGIN
      v_order := (v_line->>'order_id')::uuid;
      v_amt := round(coalesce(nullif(v_line->>'amount',''),'0')::numeric, 2);
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'Bad bill or amount in the split';
    END;
    CONTINUE WHEN v_amt = 0;
    IF v_amt < 0 THEN RAISE EXCEPTION 'Split amount can not be less than zero'; END IF;
    IF v_order = ANY (v_seen) THEN RAISE EXCEPTION 'A bill is in the split twice'; END IF;
    v_seen := v_seen || v_order;
    SELECT o.customer_name, o.order_no::text INTO v_party, v_no FROM public.orders o WHERE o.id = v_order;
    IF NOT FOUND THEN RAISE EXCEPTION 'Bill not found'; END IF;
    IF public.lwb_party_key(public.lwb_party_parent(v_party)) <> public.lwb_party_key(p_parent) THEN
      RAISE EXCEPTION 'PO % (%) is not under %', v_no, v_party, p_parent;
    END IF;
    v_oc := public.lwb_order_company(v_order);
    IF p_company IS NOT NULL AND v_oc IS NOT NULL AND v_oc <> p_company THEN
      RAISE EXCEPTION 'PO % is of another brand. % money can not go to it.', v_no, coalesce(v_bname,'This');
    END IF;
    PERFORM 1 FROM public.lwb_tally_invoices t WHERE t.order_id = v_order FOR UPDATE;
    v_due := public.lwb_order_tally_due(v_order);
    IF v_due IS NULL THEN RAISE EXCEPTION 'PO % has no Tally bill amount yet', v_no; END IF;
    IF v_amt > v_due + 1 THEN
      RAISE EXCEPTION 'Rs % on PO % is more than its due Rs %', v_amt, v_no, greatest(v_due,0);
    END IF;
    v_total := v_total + v_amt;
    IF v_total > v_free + 0.5 THEN
      RAISE EXCEPTION 'Split Rs % is more than the % money of % not split yet (Rs %)', v_total, coalesce(v_bname,'no-brand'), p_parent, v_free;
    END IF;
    v_left := v_amt;
    FOR r IN SELECT f.receipt_id, f.free FROM public.lwb_party_receipt_free_b(p_parent, p_company) f WHERE f.free > 0.004 LOOP
      EXIT WHEN v_left < 0.005;
      v_take := least(r.free, v_left);
      INSERT INTO public.lwb_party_allocs (receipt_id, order_id, amount, created_by)
      VALUES (r.receipt_id, v_order, round(v_take,2), auth.uid());
      v_left := v_left - v_take;
    END LOOP;
    IF v_left > 0.5 THEN RAISE EXCEPTION 'Not enough advance for PO %', v_no; END IF;
  END LOOP;
  RETURN round(v_total, 2);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_apply_b(text, uuid, jsonb) FROM PUBLIC, anon, authenticated;

-- Old internal name: oldest bill first now runs brand by brand (never across brands).
CREATE OR REPLACE FUNCTION public.lwb_party_apply(p_parent text, p_allocs jsonb)
RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_total numeric := 0; c record;
BEGIN
  IF p_allocs IS NOT NULL THEN
    RETURN public.lwb_party_apply_b(p_parent, NULL, p_allocs);
  END IF;
  FOR c IN SELECT DISTINCT p.company_id FROM public.lwb_tally_payments p
           WHERE p.order_id IS NULL AND p.cancelled_at IS NULL AND p.company_id IS NOT NULL
             AND public.lwb_party_key(public.lwb_party_parent(p.party)) = public.lwb_party_key(p_parent) LOOP
    v_total := v_total + public.lwb_party_apply_b(p_parent, c.company_id, NULL);
  END LOOP;
  RETURN v_total;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_apply(text, jsonb) FROM PUBLIC, anon, authenticated;

-- Brand to use when the screen sent none: the party's only brand, else an error.
CREATE OR REPLACE FUNCTION public.lwb_party_brand_check(p_parent text, p_company uuid)
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v uuid := p_company;
BEGIN
  IF v IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.lwb_companies c WHERE c.id = v) THEN RAISE EXCEPTION 'Brand not found'; END IF;
    RETURN v;
  END IF;
  RETURN public.lwb_party_only_company(p_parent);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_brand_check(text, uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Party payment with brand. p_company_id NULL: the party's only brand; a party of two brands
--    (only the bank statement can send none) keeps the money as "brand not chosen", not split.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.lwb_party_receive(text, date, jsonb, jsonb, text);
CREATE OR REPLACE FUNCTION public.lwb_party_receive(p_party text, p_pay_date date, p_lines jsonb,
                                                   p_allocs jsonb DEFAULT NULL, p_remark text DEFAULT NULL,
                                                   p_company_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_parent text := public.lwb_party_parent(p_party);
  v_receipt uuid := gen_random_uuid();
  v_remark text := nullif(btrim(coalesce(p_remark,'')),'');
  v_line jsonb; v_mode text; v_amt numeric; v_ref text; v_notes jsonb; v_clean jsonb;
  v_key text; v_cnt numeric; v_total numeric := 0; v_cash numeric := 0;
  v_rows jsonb := '[]'::jsonb; v_modes text[] := '{}';
  v_split numeric := 0; v_adv numeric; v_co uuid;
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can enter a party payment';
  END IF;
  IF v_parent = '' THEN RAISE EXCEPTION 'Choose the party'; END IF;
  IF length(v_parent) > 200 THEN RAISE EXCEPTION 'Party name is too long'; END IF;
  IF NOT public.lwb_party_known(v_parent) THEN
    RAISE EXCEPTION 'Party % is not in the Party Master', v_parent;
  END IF;
  IF p_pay_date IS NULL OR p_pay_date > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1 THEN
    RAISE EXCEPTION 'Enter a valid payment date';
  END IF;
  IF length(coalesce(v_remark,'')) > 300 THEN RAISE EXCEPTION 'Remark is too long'; END IF;
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Enter at least one payment mode';
  END IF;
  IF jsonb_array_length(p_lines) > 8 THEN RAISE EXCEPTION 'Too many payment lines'; END IF;
  v_co := public.lwb_party_brand_check(v_parent, p_company_id);

  PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(v_parent)));

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_mode := upper(btrim(coalesce(v_line->>'mode','')));
    v_ref := nullif(btrim(coalesce(v_line->>'ref','')),'');
    v_clean := NULL;
    IF v_mode NOT IN ('CASH','UPI','BANK','CHEQUE') THEN RAISE EXCEPTION 'Select Cash, UPI, Bank or Cheque'; END IF;
    IF v_mode = ANY(v_modes) THEN RAISE EXCEPTION '% is entered twice. Put it in one line.', initcap(v_mode); END IF;
    v_modes := v_modes || v_mode;
    IF length(coalesce(v_ref,'')) > 100 THEN RAISE EXCEPTION 'Reference is too long'; END IF;
    IF v_mode = 'CASH' AND jsonb_typeof(v_line->'notes') = 'object' AND v_line->'notes' <> '{}'::jsonb THEN
      v_notes := v_line->'notes';
      v_clean := '{}'::jsonb; v_amt := 0;
      FOR v_key IN SELECT jsonb_object_keys(v_notes) LOOP
        IF v_key NOT IN ('500','200','100','50','20','10','coins') THEN RAISE EXCEPTION 'Unknown note %', v_key; END IF;
        BEGIN
          v_cnt := coalesce(nullif(v_notes->>v_key,''),'0')::numeric;
        EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter a number for %', v_key;
        END;
        IF v_cnt < 0 OR v_cnt > 100000 OR (v_key <> 'coins' AND v_cnt <> trunc(v_cnt)) THEN
          RAISE EXCEPTION 'Check the count of %', v_key;
        END IF;
        IF v_cnt > 0 THEN
          v_clean := v_clean || jsonb_build_object(v_key, v_cnt);
          v_amt := v_amt + CASE WHEN v_key = 'coins' THEN round(v_cnt,2) ELSE v_key::numeric * v_cnt END;
        END IF;
      END LOOP;
      IF v_clean = '{}'::jsonb THEN v_clean := NULL; END IF;
    ELSE
      BEGIN
        v_amt := round(coalesce(nullif(v_line->>'amount',''),'0')::numeric, 2);
      EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter the % amount', initcap(v_mode);
      END;
      IF v_mode = 'CHEQUE' AND v_ref IS NULL THEN RAISE EXCEPTION 'Enter the cheque number'; END IF;
      IF v_mode <> 'CASH' AND v_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.lwb_tally_payments x WHERE x.mode = v_mode
            AND upper(btrim(x.ref_no)) = upper(v_ref) AND x.cancelled_at IS NULL) THEN
        RAISE EXCEPTION '% reference % is already entered', initcap(v_mode), v_ref;
      END IF;
    END IF;
    IF v_amt <= 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'Enter the % amount', initcap(v_mode); END IF;
    IF v_mode = 'CASH' THEN v_cash := v_cash + v_amt; END IF;
    v_total := v_total + v_amt;
    v_rows := v_rows || jsonb_build_object('mode', v_mode, 'amount', v_amt, 'ref', v_ref, 'notes', v_clean);
  END LOOP;

  IF v_cash >= 200000 THEN
    RAISE EXCEPTION 'Cash of Rs 2 lakh or more in one receipt is not allowed (Income Tax 269ST).';
  END IF;

  INSERT INTO public.lwb_tally_payments (receipt_id, order_id, party, pay_date, mode, amount, ref_no, cash_notes, remark, created_by, company_id)
  SELECT v_receipt, NULL, v_parent, p_pay_date, r->>'mode', (r->>'amount')::numeric, r->>'ref',
         CASE WHEN jsonb_typeof(r->'notes') = 'object' THEN r->'notes' END, v_remark, auth.uid(), v_co
  FROM jsonb_array_elements(v_rows) r;

  IF v_co IS NOT NULL THEN
    v_split := public.lwb_party_apply_b(v_parent, v_co, p_allocs);
  END IF;
  SELECT COALESCE(sum(f.free),0) INTO v_adv FROM public.lwb_party_receipt_free_b(v_parent, v_co) f;
  RETURN jsonb_build_object('receipt_id', v_receipt, 'party', v_parent, 'amount', round(v_total,2),
                            'split', v_split, 'advance', round(v_adv,2), 'company_id', v_co);
END;
$fn$;

-- Adjust the advance of one brand over that brand's bills (p_allocs NULL = oldest bill first).
DROP FUNCTION IF EXISTS public.lwb_party_adjust(text, jsonb);
CREATE OR REPLACE FUNCTION public.lwb_party_adjust(p_party text, p_allocs jsonb DEFAULT NULL, p_company_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_parent text := public.lwb_party_parent(p_party);
  v_co uuid; v_split numeric; v_adv numeric;
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can adjust a payment';
  END IF;
  IF v_parent = '' THEN RAISE EXCEPTION 'Choose the party'; END IF;
  v_co := public.lwb_party_brand_check(v_parent, p_company_id);
  IF v_co IS NULL THEN RAISE EXCEPTION 'Choose the brand (Rajnigandha / Coca-Cola) of the advance'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(v_parent)));
  v_split := public.lwb_party_apply_b(v_parent, v_co, p_allocs);
  IF v_split = 0 THEN RAISE EXCEPTION 'Nothing to adjust: no advance or no bill due of this brand for %', v_parent; END IF;
  SELECT COALESCE(sum(f.free),0) INTO v_adv FROM public.lwb_party_receipt_free_b(v_parent, v_co) f;
  RETURN jsonb_build_object('party', v_parent, 'split', v_split, 'advance', round(v_adv,2), 'company_id', v_co);
END;
$fn$;

-- Choose / change the brand of a party payment. Its splits to bills of another brand must be undone
-- first. The rest is then set against that brand's bills, oldest first.
CREATE OR REPLACE FUNCTION public.lwb_party_receipt_brand(p_receipt_id uuid, p_company_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_parent text; v_no text; v_split numeric := 0; v_adv numeric;
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can change a payment';
  END IF;
  IF p_company_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.lwb_companies c WHERE c.id = p_company_id) THEN
    RAISE EXCEPTION 'Choose the brand';
  END IF;
  SELECT public.lwb_party_parent(min(p.party)) INTO v_parent FROM public.lwb_tally_payments p
  WHERE p.receipt_id = p_receipt_id AND p.order_id IS NULL AND p.cancelled_at IS NULL;
  IF v_parent IS NULL THEN RAISE EXCEPTION 'Party payment not found'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(v_parent)));
  SELECT o.order_no::text INTO v_no FROM public.lwb_party_allocs a JOIN public.orders o ON o.id = a.order_id
  WHERE a.receipt_id = p_receipt_id AND a.cancelled_at IS NULL
    AND public.lwb_order_company(a.order_id) IS NOT NULL AND public.lwb_order_company(a.order_id) <> p_company_id
  LIMIT 1;
  IF v_no IS NOT NULL THEN
    RAISE EXCEPTION 'This payment is set against PO % of the other brand. Undo that split first.', v_no;
  END IF;
  UPDATE public.lwb_tally_payments SET company_id = p_company_id
  WHERE receipt_id = p_receipt_id AND order_id IS NULL;
  BEGIN
    v_split := public.lwb_party_apply_b(v_parent, p_company_id, NULL);
  EXCEPTION WHEN others THEN v_split := 0;
  END;
  SELECT COALESCE(sum(f.free),0) INTO v_adv FROM public.lwb_party_receipt_free_b(v_parent, p_company_id) f;
  RETURN jsonb_build_object('party', v_parent, 'split', v_split, 'advance', round(v_adv,2), 'company_id', p_company_id);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_party_receive(text,date,jsonb,jsonb,text,uuid), public.lwb_party_adjust(text,jsonb,uuid),
  public.lwb_party_receipt_brand(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_receive(text,date,jsonb,jsonb,text,uuid), public.lwb_party_adjust(text,jsonb,uuid),
  public.lwb_party_receipt_brand(uuid,uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. New bill: that brand's advance goes against it by itself (never blocks saving the bill)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_auto_adjust()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_parent text; v_co uuid;
BEGIN
  IF NEW.amount IS NULL OR auth.uid() IS NULL THEN RETURN NULL; END IF;
  SELECT public.lwb_party_parent(o.customer_name) INTO v_parent FROM public.orders o WHERE o.id = NEW.order_id;
  IF v_parent IS NULL OR v_parent = '' THEN RETURN NULL; END IF;
  v_co := public.lwb_order_company(NEW.order_id);
  IF v_co IS NULL THEN RETURN NULL; END IF;
  BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(v_parent)));
    PERFORM public.lwb_party_apply_b(v_parent, v_co, NULL);
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_auto_adjust() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_party_auto_adjust ON public.lwb_tally_invoices;
CREATE TRIGGER trg_lwb_party_auto_adjust AFTER INSERT OR UPDATE OF amount ON public.lwb_tally_invoices
  FOR EACH ROW EXECUTE FUNCTION public.lwb_party_auto_adjust();

-- ---------------------------------------------------------------------------
-- 6. Opening balance per party per brand (Admin). Amount 0 removes that brand's opening.
--    p_company_id NULL is allowed only for a one-brand party, or to remove an old row with no brand.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.lwb_set_party_opening_balance(text, numeric, date, text);
CREATE OR REPLACE FUNCTION public.lwb_set_party_opening_balance(
  p_customer_name text, p_amount numeric, p_as_of_date date, p_remarks text DEFAULT NULL, p_company_id uuid DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_name text := btrim(COALESCE(p_customer_name,''));
  v_amount numeric(14,2) := round(COALESCE(p_amount,0),2);
  v_master_name text;
  v_co uuid := p_company_id;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND active = true AND lower(btrim(role)) = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only an active Admin can set an Opening Balance';
  END IF;
  IF v_name = '' THEN RAISE EXCEPTION 'Select a party'; END IF;
  IF to_regclass('public.lwb_customer_master') IS NOT NULL THEN
    EXECUTE 'SELECT btrim(m.customer_name::text) FROM public.lwb_customer_master m WHERE upper(btrim(m.customer_name::text)) = upper($1) LIMIT 1'
      INTO v_master_name USING v_name;
  END IF;
  v_name := COALESCE(v_master_name, v_name);
  IF v_master_name IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.orders o WHERE upper(btrim(o.customer_name)) = upper(v_name)
  ) THEN
    RAISE EXCEPTION 'Party % not found in Customer Master or orders', v_name;
  END IF;
  IF v_co IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_companies c WHERE c.id = v_co) THEN
    RAISE EXCEPTION 'Brand not found';
  END IF;

  IF v_amount = 0 THEN
    DELETE FROM public.lwb_party_opening_balances
    WHERE upper(btrim(customer_name)) = upper(v_name) AND company_id IS NOT DISTINCT FROM v_co;
    RETURN;
  END IF;
  IF v_co IS NULL THEN
    v_co := public.lwb_party_only_company(public.lwb_party_parent(v_name));
    IF v_co IS NULL THEN RAISE EXCEPTION 'Choose the brand (Rajnigandha / Coca-Cola) of this opening balance'; END IF;
  END IF;
  IF p_as_of_date IS NULL THEN RAISE EXCEPTION 'Opening Balance date is required'; END IF;

  INSERT INTO public.lwb_party_opening_balances(customer_name, as_of_date, amount, remarks, updated_by, company_id)
  VALUES (v_name, p_as_of_date, v_amount, NULLIF(btrim(COALESCE(p_remarks,'')),''), auth.uid(), v_co)
  ON CONFLICT ((upper(btrim(customer_name))), (coalesce(company_id, '00000000-0000-0000-0000-000000000000'::uuid))) DO UPDATE
    SET as_of_date = EXCLUDED.as_of_date, amount = EXCLUDED.amount, remarks = EXCLUDED.remarks,
        updated_by = EXCLUDED.updated_by, updated_at = now();
END;
$function$;
REVOKE ALL ON FUNCTION public.lwb_set_party_opening_balance(text,numeric,date,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_party_opening_balance(text,numeric,date,text,uuid) TO authenticated;

-- Opening balances with brand, for the Party Ledger screen (ledger viewers).
CREATE OR REPLACE FUNCTION public.lwb_party_openings()
RETURNS TABLE (customer_name text, parent text, company_id uuid, as_of_date date, amount numeric, remarks text, updated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT btrim(b.customer_name), public.lwb_party_parent(b.customer_name), b.company_id, b.as_of_date, b.amount, b.remarks, b.updated_at
  FROM public.lwb_party_opening_balances b
  WHERE public.lwb_ledger_viewer()
  ORDER BY 2, 3;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_openings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_openings() TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. Billing & Outstanding data: same as before + brand
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_billing(p_days integer DEFAULT 400)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_days int := least(greatest(coalesce(p_days,400),30),400);
  v_rows jsonb;
  v_parties jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Active Admin / Accounts role required.';
  END IF;
  IF to_regclass('public.lwb_customer_master') IS NOT NULL THEN
    EXECUTE 'SELECT coalesce(jsonb_agg(DISTINCT btrim(m.customer_name::text)), ''[]''::jsonb)
             FROM public.lwb_customer_master m WHERE nullif(btrim(m.customer_name::text),'''') IS NOT NULL'
      INTO v_parties;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'order_id', r.order_id, 'order_no', r.order_no, 'party', r.party,
           'parent', public.lwb_party_parent(r.party), 'status', r.status,
           'company_id', public.lwb_order_company(r.order_id),
           'order_date', r.order_date, 'dispatch_date', r.dispatch_date,
           'invoice_no', r.invoice_no, 'invoice_date', r.invoice_date,
           'bill_amount', r.bill_amount, 'erp_amount', r.erp_amount,
           'approved_return', r.approved_return, 'pending_return', r.pending_return,
           'credit_notes', r.credit_notes, 'debit_notes', r.debit_notes,
           'driver', r.collected - public.lwb_order_office_paid(r.order_id),
           'office', public.lwb_order_office_paid(r.order_id),
           'due', r.due, 'credit_pending', r.credit_pending, 'delivery', r.delivery,
           'bills', coalesce(t.bills, '[]'::jsonb), 'entered_at', t.entered_at)
         ORDER BY r.dispatch_date, r.order_no), '[]'::jsonb)
    INTO v_rows
  FROM public.lwb_tally_bill_rows(v_days) r
  LEFT JOIN public.lwb_tally_invoices t ON t.order_id = r.order_id;

  RETURN jsonb_build_object(
    'today', (now() AT TIME ZONE 'Asia/Kolkata')::date,
    'orders', v_rows,
    'companies', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'color', c.color) ORDER BY c.sort_no, c.name), '[]'::jsonb)
                  FROM public.lwb_companies c WHERE c.active),
    'receipts', (
      SELECT coalesce(jsonb_agg(x ORDER BY x->>'pay_date' DESC, x->>'at' DESC), '[]'::jsonb) FROM (
        SELECT jsonb_build_object(
          'receipt_id', p.receipt_id, 'party', public.lwb_party_parent(min(p.party)), 'pay_date', min(p.pay_date), 'at', min(p.created_at),
          'company_id', (array_agg(p.company_id))[1],
          'remark', min(p.remark), 'cancelled', bool_or(p.cancelled_at IS NOT NULL),
          'total', sum(p.amount),
          'modes', jsonb_agg(jsonb_build_object('mode', p.mode, 'amount', p.amount, 'ref', p.ref_no, 'notes', p.cash_notes) ORDER BY p.mode),
          'by', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = min(p.created_by::text)::uuid),
          'allocs', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'order_id', a.order_id, 'order_no', o.order_no,
                       'invoice_no', ti.invoice_no, 'amount', a.amount, 'at', a.created_at) ORDER BY a.created_at), '[]'::jsonb)
                     FROM public.lwb_party_allocs a JOIN public.orders o ON o.id = a.order_id
                     LEFT JOIN public.lwb_tally_invoices ti ON ti.order_id = a.order_id
                     WHERE a.receipt_id = p.receipt_id AND a.cancelled_at IS NULL)) AS x
        FROM public.lwb_tally_payments p
        WHERE p.order_id IS NULL
          AND (p.cancelled_at IS NULL OR p.pay_date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - 30)
        GROUP BY p.receipt_id) q),
    'advance', (
      SELECT coalesce(jsonb_object_agg(z.parent, z.free), '{}'::jsonb) FROM (
        SELECT r.parent, round(sum(r.free),2) AS free FROM (
          SELECT public.lwb_party_parent(min(p.party)) AS parent,
                 sum(p.amount) - coalesce((SELECT sum(a.amount) FROM public.lwb_party_allocs a
                                           WHERE a.receipt_id = p.receipt_id AND a.cancelled_at IS NULL),0) AS free
          FROM public.lwb_tally_payments p
          WHERE p.order_id IS NULL AND p.cancelled_at IS NULL
          GROUP BY p.receipt_id) r
        GROUP BY r.parent) z
      WHERE abs(z.free) >= 0.01),
    'advance_b', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('parent', z.parent, 'company_id', z.c, 'amount', z.free)), '[]'::jsonb) FROM (
        SELECT r.parent, r.c, round(sum(r.free),2) AS free FROM (
          SELECT public.lwb_party_parent(min(p.party)) AS parent, (array_agg(p.company_id))[1] AS c,
                 sum(p.amount) - coalesce((SELECT sum(a.amount) FROM public.lwb_party_allocs a
                                           WHERE a.receipt_id = p.receipt_id AND a.cancelled_at IS NULL),0) AS free
          FROM public.lwb_tally_payments p
          WHERE p.order_id IS NULL AND p.cancelled_at IS NULL
          GROUP BY p.receipt_id) r
        GROUP BY r.parent, r.c) z
      WHERE abs(z.free) >= 0.01),
    'groups', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('member', m.tally_name, 'parent', btrim(m.customer_name)) ORDER BY m.customer_name, m.tally_name), '[]'::jsonb)
      FROM public.lwb_tally_party_map m
      WHERE nullif(btrim(m.customer_name),'') IS NOT NULL AND public.lwb_party_key(m.customer_name) <> m.tally_key),
    'openings', (
      SELECT coalesce(jsonb_object_agg(z.parent, z.amt), '{}'::jsonb) FROM (
        SELECT public.lwb_party_parent(b.customer_name) AS parent, sum(b.amount) AS amt
        FROM public.lwb_party_opening_balances b GROUP BY 1) z),
    'openings_b', (
      SELECT coalesce(jsonb_agg(jsonb_build_object('parent', z.parent, 'company_id', z.c, 'amount', z.amt, 'as_of', z.d)), '[]'::jsonb) FROM (
        SELECT public.lwb_party_parent(b.customer_name) AS parent, b.company_id AS c, sum(b.amount) AS amt, min(b.as_of_date) AS d
        FROM public.lwb_party_opening_balances b GROUP BY 1, 2) z),
    'parties', v_parties
  );
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_billing(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_billing(integer) TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. Party ledger rows with brand (same rows as lwb_party_ledger)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_ledger_b()
RETURNS TABLE(entry_date date, entry_kind text, customer_name text, ref_no text, order_no text,
              debit numeric, credit numeric, note text, created_at timestamptz, company_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  WITH oc AS (
    SELECT i.order_id, CASE WHEN count(DISTINCT s.company_id) = 1
                            THEN (array_agg(DISTINCT s.company_id) FILTER (WHERE s.company_id IS NOT NULL))[1] END AS c
    FROM public.order_items i
    JOIN public.sku_master s ON upper(btrim(s.sku_name)) = upper(btrim(i.sku_name))
    GROUP BY i.order_id
  ), byno AS (
    SELECT DISTINCT ON (o.order_no::text) o.order_no::text AS order_no, oc.c
    FROM public.orders o JOIN oc ON oc.order_id = o.id ORDER BY o.order_no::text
  ), op AS (
    SELECT public.lwb_party_parent(ob.customer_name) AS parent, ob.as_of_date, ob.amount, ob.updated_at, ob.company_id
    FROM public.lwb_party_opening_balances ob
  ), pp AS (
    SELECT public.lwb_party_parent(p.party) AS parent, p.pay_date, p.amount, p.created_at, p.company_id
    FROM public.lwb_tally_payments p WHERE p.order_id IS NULL AND p.cancelled_at IS NULL
  )
  SELECT l.entry_date, l.entry_kind, l.customer_name, l.ref_no, l.order_no, l.debit, l.credit, l.note, l.created_at,
         CASE l.entry_kind WHEN 'OPENING' THEN o1.company_id WHEN 'PARTY_PAYMENT' THEN p1.company_id ELSE b.c END
  FROM public.lwb_party_ledger() l
  LEFT JOIN byno b ON b.order_no = l.order_no
  LEFT JOIN LATERAL (SELECT op.company_id FROM op WHERE l.entry_kind = 'OPENING' AND op.parent = l.customer_name
                       AND op.as_of_date = l.entry_date AND op.updated_at IS NOT DISTINCT FROM l.created_at
                       AND GREATEST(op.amount,0) = l.debit AND GREATEST(-op.amount,0) = l.credit LIMIT 1) o1 ON true
  LEFT JOIN LATERAL (SELECT pp.company_id FROM pp WHERE l.entry_kind = 'PARTY_PAYMENT' AND pp.parent = l.customer_name
                       AND pp.pay_date = l.entry_date AND pp.created_at IS NOT DISTINCT FROM l.created_at
                       AND pp.amount = l.credit LIMIT 1) p1 ON true;
$function$;
REVOKE ALL ON FUNCTION public.lwb_party_ledger_b() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_ledger_b() TO authenticated;

-- ---------------------------------------------------------------------------
-- 9. Bank statement "Party payment" passes the brand picked on the screen (p->>'company_id')
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE d text;
BEGIN
  IF to_regprocedure('public.lwb_bank_stmt_assign(uuid[],jsonb)') IS NULL THEN RETURN; END IF;
  d := pg_get_functiondef('public.lwb_bank_stmt_assign(uuid[],jsonb)'::regprocedure);
  IF position('company_id'')' IN d) = 0 AND position('NULL, v_remark);' IN d) > 0 THEN
    d := replace(d, 'NULL, v_remark);', 'NULL, v_remark, nullif(p->>''company_id'','''')::uuid);');
    EXECUTE d;
  END IF;
END
$patch$;

COMMIT;

-- Result rows
SELECT 'party payments without brand' AS item,
  (SELECT count(DISTINCT receipt_id) FROM public.lwb_tally_payments WHERE order_id IS NULL AND cancelled_at IS NULL AND company_id IS NULL)::text AS value
UNION ALL
SELECT 'opening balances without brand', (SELECT count(*) FROM public.lwb_party_opening_balances WHERE company_id IS NULL)::text;
