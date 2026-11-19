-- LUXURY WRIST BRAND ERP — BATCH NO. ON DAMAGE / GASLESS / SHORTAGE LINES (19 Nov 2026)
--
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (19 Nov 2026): the company claim mail needs the BATCH NO of the damaged / leakage /
-- gasless goods (his Gmail format: SKU · QTY · INVOICE DATE · INVOICE NO. · BATCH NO · type).
--   * lwb_purchase_check_items.batch_no (text, up to 30 characters, optional).
--   * lwb_purchase_check_batches(bill, items) writes the batch no. on the lines of that bill's check:
--       items = [{id, batch_no}]                                  (by line id, Purchase Claims page)
--            or [{sku_name, issue, cases, pcs, batch_no}]         (right after the vehicle check is saved,
--                                                                   which writes the lines fresh)
--     Who: same as the vehicle check (Admin, Sales Head, Accounts, Godown Manager).

BEGIN;

ALTER TABLE public.lwb_purchase_check_items ADD COLUMN IF NOT EXISTS batch_no text;
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_purchase_check_items_batch_len') THEN
    ALTER TABLE public.lwb_purchase_check_items ADD CONSTRAINT lwb_purchase_check_items_batch_len CHECK (batch_no IS NULL OR length(batch_no) <= 30);
  END IF;
END $do$;

CREATE OR REPLACE FUNCTION public.lwb_purchase_check_batches(p_inward uuid, p_items jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_cid uuid;
  x jsonb;
  v_b text;
  v_line uuid;
  v_n integer := 0;
BEGIN
  IF NOT public.lwb_pc_checker() THEN RAISE EXCEPTION 'Only Admin, Sales Head, Accounts or Godown Manager can enter the batch no.'; END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN RETURN 0; END IF;
  SELECT c.id INTO v_cid FROM public.lwb_purchase_checks c WHERE c.inward_id = p_inward;
  IF v_cid IS NULL THEN RAISE EXCEPTION 'This bill has no vehicle check yet'; END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_b := nullif(upper(btrim(coalesce(x->>'batch_no',''))), '');
    IF length(v_b) > 30 THEN RAISE EXCEPTION 'Batch no. is too long (max 30): %', v_b; END IF;
    v_line := NULL;
    IF nullif(x->>'id','') IS NOT NULL THEN
      SELECT i.id INTO v_line FROM public.lwb_purchase_check_items i WHERE i.check_id = v_cid AND i.id::text = x->>'id';
    ELSE
      -- the first matching line that has no batch yet (lines were just written fresh by the check)
      SELECT i.id INTO v_line FROM public.lwb_purchase_check_items i
      WHERE i.check_id = v_cid AND i.sku_name = x->>'sku_name' AND i.issue = upper(x->>'issue')
        AND i.cases = coalesce(nullif(x->>'cases','')::int, 0) AND i.pcs = coalesce(nullif(x->>'pcs','')::int, 0)
        AND i.batch_no IS NULL
      ORDER BY i.id LIMIT 1;
    END IF;
    IF v_line IS NOT NULL THEN
      UPDATE public.lwb_purchase_check_items SET batch_no = v_b WHERE id = v_line;
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_check_batches(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_check_batches(uuid, jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result (true): the column is there.
SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
               AND table_name = 'lwb_purchase_check_items' AND column_name = 'batch_no') AS batch_no_ready;
