-- LUXURY WRIST BRAND ERP — PARTY CREDIT LIMIT + OLD DUE CHECK ON PO (5 Nov 2026)
--
-- Applied automatically when the PR is merged (safe to run again).
-- Run AFTER lwb_brand_money_setup.sql and lwb_party_master_save_fix.sql.
--
-- Mohit's goal: before a PO is made, everyone sees how much the party still owes
-- (brand-wise, Rajnigandha and Coca-Cola never mixed), how old the oldest unpaid bill is,
-- and whether the party is over its credit limit or past its credit days.
--
-- 1. lwb_customer_master.credit_limit (₹, NULL / 0 = no limit). One number per party,
--    checked against each brand's balance separately. Saved by Party Master (Admin).
-- 2. lwb_party_credit(party, company) -> jsonb: balance = bills due + opening − advance
--    (same as Billing & Outstanding), oldest unpaid bill date / days, credit days
--    (party + brand days, else party days, else the brand's market days), limit, flags.
--    Field salesman: only his own parties.
-- 3. lwb_order_credit(order_id): the same for a PO's party and brand (PO / Sales review).
-- Read only: no order, bill, payment, ledger, stock or Tally data is changed.

BEGIN;

ALTER TABLE public.lwb_customer_master ADD COLUMN IF NOT EXISTS credit_limit numeric(14,2);
DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_customer_master_credit_limit_ck') THEN
    ALTER TABLE public.lwb_customer_master ADD CONSTRAINT lwb_customer_master_credit_limit_ck
      CHECK (credit_limit IS NULL OR credit_limit >= 0);
  END IF;
END $do$;

-- Party Master save (Admin) may now write credit_limit (patched in place, keeps the rest).
DO $do$
DECLARE v_def text;
BEGIN
  IF to_regprocedure('public.lwb_party_master_save(uuid,jsonb)') IS NULL THEN RETURN; END IF;
  v_def := pg_get_functiondef('public.lwb_party_master_save(uuid,jsonb)'::regprocedure);
  IF position('''credit_limit''' IN v_def) = 0 AND position('''min_order_kg'']' IN v_def) > 0 THEN
    EXECUTE replace(v_def, '''min_order_kg'']', '''min_order_kg'',''credit_limit'']');
  END IF;
END $do$;

CREATE OR REPLACE FUNCTION public.lwb_party_credit(p_party text, p_company uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_party text := btrim(coalesce(p_party,''));
  v_parent text; v_key text;
  v_due numeric := 0; v_open numeric := 0; v_adv numeric := 0; v_bal numeric;
  v_oldest date; v_open_date date; v_bills int := 0;
  v_days int; v_limit numeric; v_mkt int; v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_age int;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','sales','salesman','accounts','warehouse')) THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;
  IF v_party = '' THEN RETURN NULL; END IF;
  IF NOT public.lwb_party_name_visible(v_party) THEN RAISE EXCEPTION 'Not your party'; END IF;
  v_parent := public.lwb_party_parent(v_party);
  v_key := public.lwb_party_key(v_parent);

  SELECT coalesce(sum(r.due) FILTER (WHERE r.due > 0), 0),
         min(coalesce(r.invoice_date, r.dispatch_date)) FILTER (WHERE r.due > 0.5),
         count(*) FILTER (WHERE r.due > 0.5)
    INTO v_due, v_oldest, v_bills
  FROM public.lwb_tally_bill_rows(400) r
  WHERE public.lwb_party_key(public.lwb_party_parent(r.party)) = v_key
    AND (p_company IS NULL OR public.lwb_order_company(r.order_id) IS NOT DISTINCT FROM p_company);

  SELECT coalesce(sum(b.amount), 0), min(b.as_of_date) FILTER (WHERE b.amount > 0)
    INTO v_open, v_open_date
  FROM public.lwb_party_opening_balances b
  WHERE public.lwb_party_key(public.lwb_party_parent(b.customer_name)) = v_key
    AND (p_company IS NULL OR b.company_id IS NOT DISTINCT FROM p_company);

  IF p_company IS NOT NULL THEN
    SELECT coalesce(sum(f.free), 0) INTO v_adv FROM public.lwb_party_receipt_free_b(v_parent, p_company) f WHERE f.free > 0;
  END IF;

  IF v_open > 0 AND v_open_date IS NOT NULL AND (v_oldest IS NULL OR v_open_date < v_oldest) THEN v_oldest := v_open_date; END IF;
  v_bal := round(v_due + v_open - v_adv, 2);
  IF v_bal <= 0.5 THEN v_oldest := NULL; END IF;

  SELECT nullif(m.credit_limit, 0), m.credit_days INTO v_limit, v_days
  FROM public.lwb_customer_master m
  WHERE upper(btrim(m.customer_name)) IN (upper(v_party), upper(btrim(v_parent)))
  ORDER BY (upper(btrim(m.customer_name)) = upper(btrim(v_parent))) DESC LIMIT 1;
  IF p_company IS NOT NULL THEN
    SELECT c.credit_days INTO v_mkt FROM public.lwb_party_company_credit c
    WHERE c.company_id = p_company AND c.party_key IN (upper(v_party), upper(btrim(v_parent))) LIMIT 1;
    IF v_mkt IS NOT NULL THEN v_days := v_mkt;
    ELSIF coalesce(v_days, 0) = 0 THEN
      SELECT nullif(c.market_credit_days, 0) INTO v_days FROM public.lwb_companies c WHERE c.id = p_company;
    END IF;
  END IF;

  v_age := CASE WHEN v_oldest IS NULL THEN NULL ELSE v_today - v_oldest END;
  RETURN jsonb_build_object(
    'party', v_parent, 'company_id', p_company,
    'due', round(v_due, 2), 'opening', round(v_open, 2), 'advance', round(v_adv, 2), 'balance', v_bal,
    'bills', v_bills, 'oldest_date', v_oldest, 'oldest_days', v_age,
    'credit_days', nullif(v_days, 0), 'credit_limit', v_limit,
    'over_limit', (v_limit IS NOT NULL AND v_bal > v_limit),
    'over_days', (coalesce(v_days, 0) > 0 AND v_age IS NOT NULL AND v_age > v_days));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_credit(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_credit(text, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_order_credit(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_name text;
BEGIN
  SELECT btrim(o.customer_name::text) INTO v_name FROM public.orders o WHERE o.id = p_order_id;
  IF v_name IS NULL THEN RETURN NULL; END IF;
  RETURN public.lwb_party_credit(v_name, public.lwb_order_company(p_order_id));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_credit(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_credit(uuid) TO authenticated;

COMMIT;
