-- LUXURY WRIST BRAND ERP — PO CHANGE AFTER LOADING / DELIVERY MOVES GODOWN STOCK (6 Nov 2026)
--
-- Runs by itself when merged to main (after lwb_bill_change_setup.sql, lwb_stock_transfer_setup.sql
-- and lwb_return_stock_setup.sql). Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (6 Nov 2026), Billing & Outstanding: Accounts may + / − qty, change rate, replace,
-- add or remove an SKU even after the PO is loaded / delivered. It waits for Admin (as before).
-- When Admin approves, godown stock follows the change:
--   * Only after loading (bill counts loaded qty). Before loading nothing has left the godown, so no stock.
--   * Less cases reached the party (qty − / line removed)  -> those cases come back to Saleable (+).
--   * More cases reached the party (qty + / SKU added)     -> those cases go out of Saleable (−).
--   * SKU replaced ("Wrong item loaded")                    -> old SKU cases back (+), new SKU cases out (−).
--   * Rate change only                                      -> no stock change.
--   Damaged / leaked goods that came back should go through Driver Return (Damage etc.), not here.
-- Each stock line = one APPROVED lwb_stock_moves row (kind BILL_CHANGE, PARTY <-> SALEABLE, source
-- BILL_CHANGE, order_id, bill_change_id), so lwb_live_stock, PO Entry stock, Stock Transfer and the
-- category ledger see it at once. If the live stock view already follows order_items.loaded_qty
-- by itself, only the part it did not move is booked (no double count).
-- SKU not found in SKU Master = no stock line (listed on the change). Orders, Tally bill and ledger
-- are changed by lwb_bill_change_apply as before.

BEGIN;

ALTER TABLE public.lwb_bill_changes ADD COLUMN IF NOT EXISTS stock_applied jsonb;
ALTER TABLE public.lwb_stock_moves ADD COLUMN IF NOT EXISTS order_id uuid;
ALTER TABLE public.lwb_stock_moves ADD COLUMN IF NOT EXISTS bill_change_id uuid;

-- Widen kind / source / bucket checks (named ones; same lists as lwb_return_stock_setup.sql).
DO $do$
DECLARE c record;
BEGIN
  FOR c IN SELECT conname, pg_get_constraintdef(oid) AS d FROM pg_constraint
           WHERE conrelid = 'public.lwb_stock_moves'::regclass AND contype = 'c' LOOP
    IF c.d ~ '\mkind\M' OR c.d ~ '\msource\M' OR (c.d ~ '\mfrom_bucket\M' AND c.d !~ '\mto_bucket\M')
       OR (c.d ~ '\mto_bucket\M' AND c.d !~ '\mfrom_bucket\M') THEN
      EXECUTE format('ALTER TABLE public.lwb_stock_moves DROP CONSTRAINT %I', c.conname);
    END IF;
  END LOOP;
END;
$do$;
ALTER TABLE public.lwb_stock_moves ADD CONSTRAINT lwb_stock_moves_kind_ck
  CHECK (kind IN ('TRANSFER','DESTROY','COMPANY_RETURN','TO_SALEABLE','RETURN_IN','BILL_CHANGE'));
ALTER TABLE public.lwb_stock_moves ADD CONSTRAINT lwb_stock_moves_source_ck
  CHECK (source IN ('MANUAL','AUDIT','RETURN','BILL_CHANGE'));
ALTER TABLE public.lwb_stock_moves ADD CONSTRAINT lwb_stock_moves_from_ck
  CHECK (from_bucket IN ('SALEABLE','DAMAGE','LEAKAGE','BREAKAGE','GASLESS','EXPIRY','LOSS','PARTY'));
ALTER TABLE public.lwb_stock_moves ADD CONSTRAINT lwb_stock_moves_to_ck
  CHECK (to_bucket IN ('SALEABLE','DAMAGE','LEAKAGE','BREAKAGE','GASLESS','EXPIRY','LOSS','DESTROYED','COMPANY_RETURN','PARTY'));
ALTER TABLE public.lwb_stock_moves ADD CONSTRAINT lwb_stock_moves_return_ck
  CHECK ((kind <> 'RETURN_IN' OR from_bucket = 'PARTY')
     AND (from_bucket <> 'PARTY' OR kind IN ('RETURN_IN','BILL_CHANGE'))
     AND (to_bucket <> 'PARTY' OR kind = 'BILL_CHANGE')
     AND (kind <> 'BILL_CHANGE' OR (from_bucket = 'PARTY' AND to_bucket = 'SALEABLE') OR (from_bucket = 'SALEABLE' AND to_bucket = 'PARTY')));
CREATE INDEX IF NOT EXISTS lwb_stock_moves_bill_change ON public.lwb_stock_moves(bill_change_id) WHERE bill_change_id IS NOT NULL;

-- Cases that leave the godown because of one change, per SKU (+ = more went to the party).
CREATE OR REPLACE FUNCTION public.lwb_bill_change_stock_lines(p_id uuid)
RETURNS TABLE(sku_key text, sku_name text, cases numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT upper(btrim(x.sku)), max(btrim(x.sku)), sum(x.q)
  FROM public.lwb_bill_changes c
  CROSS JOIN LATERAL jsonb_array_elements(c.lines) l
  CROSS JOIN LATERAL (
    SELECT l->>'sku_old' AS sku, -coalesce((l->>'qty_old')::numeric, 0) AS q WHERE coalesce(l->>'item_id','') <> ''
    UNION ALL
    SELECT l->>'sku', coalesce((l->>'qty')::numeric, 0)
  ) x
  WHERE c.id = p_id AND c.qty_col = 'loaded_qty' AND nullif(btrim(coalesce(x.sku,'')),'') IS NOT NULL
  GROUP BY 1
  HAVING sum(x.q) <> 0;
$fn$;

-- Before the PO lines change: SKU, case size and base stock now. NULL = no stock to move.
CREATE OR REPLACE FUNCTION public.lwb_bill_change_stock_before(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v jsonb;
BEGIN
  IF to_regclass('public.lwb_stock_moves') IS NULL OR to_regclass('public.sku_master') IS NULL
     OR to_regprocedure('public.lwb_stx_base()') IS NULL THEN RETURN NULL; END IF;
  EXECUTE $q$
    SELECT coalesce(jsonb_agg(jsonb_build_object('sku', l.sku_name, 'cases', l.cases, 'sku_id', s.id,
             'pcs', greatest(coalesce(s.pcs_per_case, 1), 1),
             'base', (SELECT b.saleable_pcs FROM public.lwb_stx_base() b WHERE b.sku_id = s.id)) ORDER BY l.sku_key), '[]'::jsonb)
    FROM public.lwb_bill_change_stock_lines($1) l
    LEFT JOIN LATERAL (SELECT x.id, x.pcs_per_case FROM public.sku_master x WHERE upper(btrim(x.sku_name)) = l.sku_key
                       ORDER BY coalesce(x.is_active, true) DESC LIMIT 1) s ON true
  $q$ INTO v USING p_id;
  RETURN v;
END;
$fn$;

-- After the PO lines changed: book what the base stock did not move by itself.
CREATE OR REPLACE FUNCTION public.lwb_bill_change_stock_after(p_id uuid, p_snap jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  c public.lwb_bill_changes%ROWTYPE;
  e jsonb;
  v_no text;
  v_batch uuid := gen_random_uuid();
  v_pcs int; v_want numeric; v_now numeric; v_rest numeric;
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF p_snap IS NULL OR jsonb_array_length(p_snap) = 0 THEN RETURN NULL; END IF;
  SELECT * INTO c FROM public.lwb_bill_changes WHERE id = p_id;
  SELECT o.order_no::text INTO v_no FROM public.orders o WHERE o.id = c.order_id;
  FOR e IN SELECT * FROM jsonb_array_elements(p_snap) LOOP
    IF e->>'sku_id' IS NULL THEN
      v_out := v_out || jsonb_build_object('sku', e->>'sku', 'cases', -(e->>'cases')::numeric, 'skipped', 'Not in SKU Master');
      CONTINUE;
    END IF;
    v_pcs := (e->>'pcs')::int;
    v_want := -(e->>'cases')::numeric * v_pcs;                       -- change saleable should get
    SELECT b.saleable_pcs INTO v_now FROM public.lwb_stx_base() b WHERE b.sku_id = (e->>'sku_id')::uuid;
    v_rest := round(v_want - (coalesce(v_now, 0) - coalesce((e->>'base')::numeric, 0)));  -- part the base view did not move
    IF v_rest <> 0 THEN
      INSERT INTO public.lwb_stock_moves(batch_id, kind, from_bucket, to_bucket, sku_id, sku_name, pcs_per_case, qty_pcs,
        requested_pcs, move_date, reason, note, source, status, requested_by, requested_at, decided_by, decided_at,
        decision_note, order_id, bill_change_id)
      VALUES (v_batch, 'BILL_CHANGE', CASE WHEN v_rest > 0 THEN 'PARTY' ELSE 'SALEABLE' END,
        CASE WHEN v_rest > 0 THEN 'SALEABLE' ELSE 'PARTY' END, (e->>'sku_id')::uuid, e->>'sku', v_pcs, abs(v_rest)::int,
        abs(v_rest)::int, public.lwb_stx_today(),
        left('PO change ' || coalesce(v_no,'') || CASE WHEN v_rest > 0 THEN ' · back to godown' ELSE ' · more to party' END
             || coalesce(' (' || c.reason || ')', ''), 300),
        left(c.note, 300), 'BILL_CHANGE', 'APPROVED', coalesce(c.requested_by, auth.uid()), c.requested_at,
        auth.uid(), now(), 'PO change approved by Admin', c.order_id, p_id);
    END IF;
    v_out := v_out || jsonb_build_object('sku', e->>'sku', 'cases', -(e->>'cases')::numeric, 'pcs', v_want);
  END LOOP;
  UPDATE public.lwb_bill_changes SET stock_applied = v_out WHERE id = p_id;
  RETURN v_out;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_bill_change_stock_lines(uuid), public.lwb_bill_change_stock_before(uuid),
  public.lwb_bill_change_stock_after(uuid, jsonb) FROM PUBLIC, anon, authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'stock on PO change' AS item, (to_regprocedure('public.lwb_bill_change_stock_after(uuid,jsonb)') IS NOT NULL)::text AS ok
UNION ALL SELECT 'apply calls stock', (pg_get_functiondef('public.lwb_bill_change_apply(uuid)'::regprocedure) LIKE '%lwb_bill_change_stock_before%')::text;
