-- LUXURY WRIST BRAND ERP — ONE-TIME DATA FIX: SHREE JAGDISH TRADER (BARDOLI) · COCA-COLA opening amount
--
-- Runs by itself when merged to main. Safe to run again (does nothing the second time).
--
-- Mohit (23 Nov 2026, after lwb_party_fix_jagdish_opening_cr.sql): the amount was wrong. The correct
-- opening is ₹1,09,243 Credit (advance), dated 14/11/2026. Sign: + = Debit, − = Credit.
-- Old row is copied to lwb_party_fix_backup first. Rolls back if the row is not as expected.

BEGIN;

DO $fix$
DECLARE
  c_fix constant text := 'jagdish-bardoli-coca-opening-amount-2026-11-23';
  v_co  uuid;
  v_id  uuid;
  v_amt numeric;
  v_dt  date;
  v_n   int;
BEGIN
  SELECT c.id INTO v_co FROM public.lwb_companies c
  WHERE upper(regexp_replace(c.name::text, '[^A-Za-z]', '', 'g')) = 'COCACOLA';
  IF v_co IS NULL THEN RAISE EXCEPTION 'Brand COCA-COLA not found'; END IF;

  SELECT count(*) INTO v_n FROM public.lwb_party_opening_balances ob
  WHERE ob.company_id = v_co
    AND upper(btrim(public.lwb_party_parent(ob.customer_name))) = 'SHREE JAGDISH TRADER (BARDOLI)';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'Expected 1 COCA-COLA opening for SHREE JAGDISH TRADER (BARDOLI), found %', v_n;
  END IF;

  SELECT ob.id, ob.amount, ob.as_of_date INTO v_id, v_amt, v_dt FROM public.lwb_party_opening_balances ob
  WHERE ob.company_id = v_co
    AND upper(btrim(public.lwb_party_parent(ob.customer_name))) = 'SHREE JAGDISH TRADER (BARDOLI)';

  IF v_amt = -109243 AND v_dt = DATE '2026-11-14' THEN
    RAISE NOTICE 'Already Credit ₹1,09,243 on 14/11/2026 — nothing to do';
    RETURN;
  END IF;
  IF v_amt NOT IN (-321227, 321227, -109243, 109243) THEN
    RAISE EXCEPTION 'Opening amount is % (expected 321227 or 109243); not changed', v_amt;
  END IF;

  INSERT INTO public.lwb_party_fix_backup(fix, tbl, row_data)
  SELECT c_fix, 'lwb_party_opening_balances', to_jsonb(ob) FROM public.lwb_party_opening_balances ob WHERE ob.id = v_id;

  UPDATE public.lwb_party_opening_balances
     SET amount = -109243,
         as_of_date = DATE '2026-11-14',
         remarks = left(coalesce(remarks || ' · ', '') || 'amount -> Cr 109243 (23/11/2026)', 300),
         updated_at = now()
   WHERE id = v_id;

  IF NOT EXISTS (SELECT 1 FROM public.lwb_party_opening_balances
                 WHERE id = v_id AND amount = -109243 AND as_of_date = DATE '2026-11-14') THEN
    RAISE EXCEPTION 'Update check failed';
  END IF;
END;
$fix$;

COMMIT;
