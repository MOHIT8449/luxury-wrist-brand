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

-- 2. Submit function: same function, only the receiver-name check is removed.
-- Matches loosely (any spacing / case). If the live function has no receiver check,
-- nothing is changed; if it has one in an unknown form, the error shows those lines.
DO $do$
DECLARE
  v_def text := pg_get_functiondef(
    'public.lwb_driver_submit_delivery(uuid,text,text,text,text,numeric,text,text)'::regprocedure);
  v_new text;
  v_lines text;
BEGIN
  v_new := regexp_replace(v_def, 'v_recipient\s+IS\s+NULL\s+OR\s+', '', 'gi');
  v_new := regexp_replace(v_new, '\s+OR\s+v_recipient\s+IS\s+NULL', '', 'gi');
  v_new := regexp_replace(v_new, 'Receiver\s+Name\s+and\s+POD\s+Photo\s+are\s+required',
                                 'POD Photo is required', 'gi');
  -- Any other test of the receiver name still left (other than its length check)?
  IF EXISTS(SELECT 1 FROM regexp_split_to_table(v_new, E'\n') AS l
            WHERE l ~* '(v_recipient|p_received_by)'
              AND l ~* '(is\s+null|is\s+not\s+null|=\s*''''|<>\s*''''|nullif|coalesce)'
              AND l !~* 'length\s*\('
              AND l !~* '^\s*v_recipient\s+text') THEN
    SELECT string_agg(btrim(l), ' | ') INTO v_lines
    FROM regexp_split_to_table(v_def, E'\n') AS l
    WHERE l ~* 'recipient|receiver|received_by';
    RAISE EXCEPTION 'Receiver check not in the expected form; nothing changed. Lines: %', v_lines;
  END IF;
  IF v_new <> v_def THEN EXECUTE v_new; END IF;
END
$do$;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Expected: 2 rows, both true.
SELECT 'submit without receiver name' AS item,
  pg_get_functiondef(
    'public.lwb_driver_submit_delivery(uuid,text,text,text,text,numeric,text,text)'::regprocedure)
    !~* 'v_recipient\s+IS\s+NULL' AS ok
UNION ALL SELECT 'table rule needs only POD photo',
  position('received_by' IN pg_get_constraintdef(c.oid)) = 0
  FROM pg_constraint c WHERE c.conname = 'lwb_delivery_proof_required';
