-- LUXURY WRIST BRAND ERP — POD PHOTO OPTIONAL ON DRIVER DELIVERY
--
-- RUN ONCE in Supabase SQL Editor, after lwb_driver_receiver_optional.sql. Safe to run again.
--
-- Mohit asked (27 Oct 2026): POD photo optional too (receiver name already optional).
-- Delivered / Partial can be submitted without a photo. A photo that is sent must still
-- be the driver's own upload for that order. Partial and Not Delivered still need their note.
-- Nothing else changes: no orders, payments, stock or Tally rows.

BEGIN;

-- 1. Table rule needing a POD photo is removed.
ALTER TABLE public.lwb_delivery_reports DROP CONSTRAINT IF EXISTS lwb_delivery_proof_required;

-- 2. Submit function: same function, only the "photo required" test is switched off.
DO $do$
DECLARE
  v_def text := pg_get_functiondef(
    'public.lwb_driver_submit_delivery(uuid,text,text,text,text,numeric,text,text)'::regprocedure);
  v_new text;
  v_lines text;
BEGIN
  v_new := regexp_replace(v_def, 'IF\s+v_proof\s+IS\s+NULL\s+THEN', 'IF false THEN', 'gi');
  v_new := regexp_replace(v_new, 'v_proof\s+IS\s+NULL\s+OR\s+', '', 'gi');
  v_new := regexp_replace(v_new, '\s+OR\s+v_proof\s+IS\s+NULL', '', 'gi');
  IF v_new ~* 'v_proof\s+IS\s+NULL' THEN
    SELECT string_agg(btrim(l), ' | ') INTO v_lines
    FROM regexp_split_to_table(v_def, E'\n') AS l
    WHERE l ~* 'proof|pod';
    RAISE EXCEPTION 'POD check not in the expected form; nothing changed. Lines: %', v_lines;
  END IF;
  IF v_new <> v_def THEN EXECUTE v_new; END IF;
END
$do$;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Expected: 2 rows, both true.
SELECT 'submit without POD photo' AS item,
  pg_get_functiondef(
    'public.lwb_driver_submit_delivery(uuid,text,text,text,text,numeric,text,text)'::regprocedure)
    !~* 'v_proof\s+IS\s+NULL' AS ok
UNION ALL SELECT 'no table rule needing POD photo', NOT EXISTS (
  SELECT 1 FROM pg_constraint WHERE conname = 'lwb_delivery_proof_required');
