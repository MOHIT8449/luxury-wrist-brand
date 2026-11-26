-- LUXURY WRIST BRAND ERP — ONE TRANSPORT ROW PER PO (26 Nov 2026)
--
-- Mohit: Print PO on LXY-00691 (Edit PO popup) said
--   "Could not print PO: JSON object requested, multiple (or no) rows returned."
-- The PO had two dispatch_assignments rows (driver / vehicle saved twice, e.g. from the
-- Transport page with an old list and from the PO popup). Every screen reads one row per PO,
-- so print and the transport box failed.
--
-- This file:
--  1. copies every extra row to public.lwb_dispatch_assignments_dup_backup (nothing is lost),
--  2. keeps one row per PO: the one a delivery report uses, else the newest assigned,
--     and removes the extra rows that nothing else points to,
--  3. adds a unique index on order_id so a PO can never get a second row again
--     (only when no duplicate is left; otherwise it waits and the screens still pick the newest).
-- Applied automatically on merge. Safe to run again.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_dispatch_assignments_dup_backup
  (LIKE public.dispatch_assignments INCLUDING DEFAULTS);
ALTER TABLE public.lwb_dispatch_assignments_dup_backup
  ADD COLUMN IF NOT EXISTS lwb_backed_up_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS lwb_kept_id uuid;
ALTER TABLE public.lwb_dispatch_assignments_dup_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_dispatch_assignments_dup_backup FROM anon, authenticated;

DO $dedupe$
DECLARE
  v_ref text := 'false';
  v_cols text;
  v_left integer;
BEGIN
  -- Rows other tables point to (delivery report / driver WhatsApp log) are never removed.
  IF to_regclass('public.lwb_delivery_reports') IS NOT NULL THEN
    v_ref := v_ref || ' OR EXISTS (SELECT 1 FROM public.lwb_delivery_reports d WHERE d.assignment_id = a.id)';
  END IF;
  IF to_regclass('public.lwb_driver_whatsapp_log') IS NOT NULL THEN
    v_ref := v_ref || ' OR EXISTS (SELECT 1 FROM public.lwb_driver_whatsapp_log w WHERE w.assignment_id = a.id)';
  END IF;

  SELECT string_agg(quote_ident(c.column_name), ', ' ORDER BY c.ordinal_position) INTO v_cols
  FROM information_schema.columns c
  WHERE c.table_schema = 'public' AND c.table_name = 'dispatch_assignments';

  EXECUTE format($q$
    CREATE TEMP TABLE lwb_da_ranked ON COMMIT DROP AS
    SELECT a.id, a.order_id, (%1$s) AS referenced,
           row_number() OVER (PARTITION BY a.order_id
             ORDER BY (%1$s) DESC, a.assigned_at DESC NULLS LAST, a.id) AS rn
    FROM public.dispatch_assignments a
    WHERE a.order_id IS NOT NULL
      AND a.order_id IN (SELECT order_id FROM public.dispatch_assignments
                         WHERE order_id IS NOT NULL GROUP BY order_id HAVING count(*) > 1)
  $q$, v_ref);

  EXECUTE format($q$
    INSERT INTO public.lwb_dispatch_assignments_dup_backup (%1$s, lwb_kept_id)
    SELECT %2$s, k.id
    FROM public.dispatch_assignments a
    JOIN lwb_da_ranked r ON r.id = a.id AND r.rn > 1 AND NOT r.referenced
    JOIN lwb_da_ranked k ON k.order_id = r.order_id AND k.rn = 1
    WHERE NOT EXISTS (SELECT 1 FROM public.lwb_dispatch_assignments_dup_backup b WHERE b.id = a.id)
  $q$, v_cols, (SELECT string_agg('a.' || x, ', ') FROM unnest(string_to_array(v_cols, ', ')) x));

  DELETE FROM public.dispatch_assignments a
  USING lwb_da_ranked r
  WHERE r.id = a.id AND r.rn > 1 AND NOT r.referenced;

  SELECT count(*) INTO v_left FROM (
    SELECT order_id FROM public.dispatch_assignments
    WHERE order_id IS NOT NULL GROUP BY order_id HAVING count(*) > 1) t;

  IF v_left = 0 THEN
    CREATE UNIQUE INDEX IF NOT EXISTS lwb_dispatch_assignments_order_unique
      ON public.dispatch_assignments (order_id);
  ELSE
    RAISE NOTICE '% PO(s) still have two transport rows used by delivery reports; unique index not added', v_left;
  END IF;
END
$dedupe$;

COMMIT;
