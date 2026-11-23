-- LUXURY WRIST BRAND ERP — ONE-TIME DATA FIX: SHREE JAGDISH TRADER (BARDOLI) · COCA-COLA opening -> Credit
--
-- Runs by itself when merged to main. Safe to run again (does nothing the second time).
--
-- Mohit (23 Nov 2026): the opening balance of SHREE JAGDISH TRADER (BARDOLI), brand COCA-COLA, dated
-- 14/11/2026 was entered as Debit ₹3,21,227. The party had an ADVANCE, so it must be Credit.
-- Opening amount sign: + = Debit (party owes), − = Credit (advance). Flip +321227 to −321227.
-- Amount and date are not changed. Old row is copied to lwb_party_fix_backup first.
-- Fails (rolls back, nothing changed) if the data is not exactly as expected.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_party_fix_backup (
  id       bigserial PRIMARY KEY,
  fix      text NOT NULL,
  tbl      text NOT NULL,
  row_data jsonb NOT NULL,
  saved_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_party_fix_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_party_fix_backup FROM PUBLIC, anon, authenticated;

DO $fix$
DECLARE
  c_fix constant text := 'jagdish-bardoli-coca-opening-cr-2026-11-23';
  v_co  uuid;
  v_id  uuid;
  v_amt numeric;
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

  SELECT ob.id, ob.amount INTO v_id, v_amt FROM public.lwb_party_opening_balances ob
  WHERE ob.company_id = v_co
    AND upper(btrim(public.lwb_party_parent(ob.customer_name))) = 'SHREE JAGDISH TRADER (BARDOLI)';

  IF v_amt = -321227 THEN
    RAISE NOTICE 'Already Credit ₹3,21,227 — nothing to do';
    RETURN;
  END IF;
  IF v_amt <> 321227 THEN
    RAISE EXCEPTION 'Opening amount is % (expected Debit 321227); not changed', v_amt;
  END IF;

  INSERT INTO public.lwb_party_fix_backup(fix, tbl, row_data)
  SELECT c_fix, 'lwb_party_opening_balances', to_jsonb(ob) FROM public.lwb_party_opening_balances ob WHERE ob.id = v_id;

  UPDATE public.lwb_party_opening_balances
     SET amount = -321227,
         remarks = left(coalesce(remarks || ' · ', '') || 'Dr -> Cr (advance) 23/11/2026', 300),
         updated_at = now()
   WHERE id = v_id;

  IF (SELECT amount FROM public.lwb_party_opening_balances WHERE id = v_id) <> -321227 THEN
    RAISE EXCEPTION 'Update check failed';
  END IF;
END;
$fix$;

COMMIT;
