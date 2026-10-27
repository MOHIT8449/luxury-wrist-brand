-- LUXURY WRIST BRAND ERP — RECEIVER NAME OPTIONAL ON DRIVER DELIVERY
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- Mohit asked (27 Oct 2026): "Received By (Party Person)" should be optional.
-- The POD photo stays required for Delivered / Partial; Partial and Not Delivered
-- still need their note. Nothing else changes: no orders, payments, stock or Tally rows.

BEGIN;

-- 1. Table rule: Delivered / Partial need only the POD photo.
-- NOT VALID: old reports saved before this rule (some without a POD photo) are kept
-- as they are; the rule applies to new and changed reports only.
ALTER TABLE public.lwb_delivery_reports DROP CONSTRAINT IF EXISTS lwb_delivery_proof_required;
ALTER TABLE public.lwb_delivery_reports ADD CONSTRAINT lwb_delivery_proof_required CHECK(
  delivery_status = 'NOT_DELIVERED'
  OR nullif(btrim(coalesce(pod_path,'')),'') IS NOT NULL
) NOT VALID;

-- 2. Submit function: same function, only the receiver check is removed.
DO $do$
DECLARE
  v_def text := pg_get_functiondef(
    'public.lwb_driver_submit_delivery(uuid,text,text,text,text,numeric,text,text)'::regprocedure);
  v_new text;
BEGIN
  v_new := replace(v_def,
    'IF v_recipient IS NULL OR v_proof IS NULL THEN',
    'IF v_proof IS NULL THEN');
  v_new := replace(v_new,
    'Receiver Name and POD Photo are required for delivered / partial',
    'POD Photo is required for delivered / partial');
  IF v_new = v_def AND position('IF v_proof IS NULL THEN' IN v_def) = 0 THEN
    RAISE EXCEPTION 'lwb_driver_submit_delivery was not in the expected form; nothing changed';
  END IF;
  IF v_new <> v_def THEN EXECUTE v_new; END IF;
END
$do$;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Expected: 2 rows, both true.
SELECT 'submit without receiver name' AS item,
  position('v_recipient IS NULL' IN pg_get_functiondef(
    'public.lwb_driver_submit_delivery(uuid,text,text,text,text,numeric,text,text)'::regprocedure)) = 0 AS ok
UNION ALL SELECT 'table rule needs only POD photo',
  position('received_by' IN pg_get_constraintdef(c.oid)) = 0
  FROM pg_constraint c WHERE c.conname = 'lwb_delivery_proof_required';
