-- LUXURY WRIST BRAND ERP — PARTY PAYMENT ON A MAIN PARTY THAT IS ONLY A GROUP NAME
--
-- Runs by itself when merged to main. Safe to run again. Changes one check function only;
-- no order, bill, payment, party or link row is changed or deleted.
--
-- Mohit (5 Nov 2026): Billing & Outstanding > Party payment for RG. RAJDHANI (SLABATPURA),
-- UPI Rs 48,298 against bill LXY-00121, said "Party RG. RAJDHANI (SLABATPURA) is not in the
-- Party Master" and did not save.
--
-- Why: the bill's PO is in the name RAJDHANI (SLABATPURA). A group link (lwb_tally_party_map,
-- made by the duplicate-party merge) puts that name under the main party RG. RAJDHANI (SLABATPURA),
-- so Billing & Outstanding shows the bill under that main party and the payment is saved on it.
-- But the save check (lwb_party_known) only looked for the main party's own name in POs or the
-- Party Master. After the duplicate was deleted, no PO or Party Master row carries that exact name,
-- so every payment of the group was refused. The same happens to any main party whose name is only
-- the target of a group link.
--
-- Now a name is known when it is in a PO or the Party Master (as before), OR when a group link
-- puts a known name under it (up to 3 steps, same as lwb_party_parent). A typed name with no PO,
-- no Party Master row and no link is still refused.
--
-- Run after lwb_party_group_billing_setup.sql (it defines the old version). If that file is
-- run again, run this file again after it.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_party_known(p_name text)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_keys text[] := ARRAY[public.lwb_party_key(p_name)];
  v_new text[];
  v boolean := false;
  i int := 0;
BEGIN
  IF v_keys[1] = '' THEN RETURN false; END IF;
  LOOP
    IF EXISTS (SELECT 1 FROM public.orders o WHERE public.lwb_party_key(o.customer_name) = ANY (v_keys)) THEN
      RETURN true;
    END IF;
    IF to_regclass('public.lwb_customer_master') IS NOT NULL THEN
      EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.lwb_customer_master m WHERE public.lwb_party_key(m.customer_name::text) = ANY ($1))'
        INTO v USING v_keys;
      IF v THEN RETURN true; END IF;
    END IF;
    EXIT WHEN i >= 3 OR to_regclass('public.lwb_tally_party_map') IS NULL;
    -- names a group link puts under one of these names
    SELECT array_agg(DISTINCT m.tally_key) INTO v_new
    FROM public.lwb_tally_party_map m
    WHERE nullif(btrim(m.customer_name),'') IS NOT NULL
      AND public.lwb_party_key(m.customer_name) = ANY (v_keys)
      AND NOT (m.tally_key = ANY (v_keys));
    EXIT WHEN v_new IS NULL;
    v_keys := v_new;
    i := i + 1;
  END LOOP;
  RETURN false;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_known(text) FROM PUBLIC, anon, authenticated;

COMMIT;
