-- LUXURY WRIST BRAND ERP — Cashier: Friend swap (bank <-> cash with a friend) (23 Nov 2026)
--
-- Mohit: in the friend circle someone sends money to our bank and we hand him the same amount in cash,
-- or he gives cash and we send the money from our bank. It is not sales, not collection, not an expense:
-- only cash in hand and the bank change.
--
-- A swap is saved as a normal money entry (lwb_acc_entries) through lwb_acc_add_entry, so every cash and
-- bank figure (Cash in hand, Close Day, bank-wise, bank check) already counts it the right way:
--   B2C "Got in bank, gave cash"  = kind DEPOSIT  (cash -, bank + after the bank check)
--   C2B "Got cash, sent from bank" = kind WITHDRAW (cash +, bank -)
-- The person is the entry's party and a row in lwb_acc_swaps marks it as a swap. The money lines
-- (lwb_acc_lines_all, patched in place from its live text) show head "Friend swap" for these entries, so
-- the pages keep them out of Cash In / Cash Out / Bank deposit / Collected.
-- Cancel = the normal "Cancel this entry". Nothing is dropped or deleted. Safe to run again.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_acc_swaps (
  entry_id   uuid PRIMARY KEY REFERENCES public.lwb_acc_entries(id),
  person     text NOT NULL CHECK (length(btrim(person)) BETWEEN 2 AND 80),
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_acc_swaps ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_acc_swaps FROM PUBLIC, anon, authenticated;

-- p: date, dir ('B2C' | 'C2B'), bank_id, amount, person, ref, remark
CREATE OR REPLACE FUNCTION public.lwb_acc_swap_add(p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_id uuid;
  v_dir text := upper(btrim(coalesce(p->>'dir','')));
  v_person text := upper(regexp_replace(btrim(coalesce(p->>'person','')), '\s+', ' ', 'g'));
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only active Accounts, Cashier or Admin can enter money'; END IF;
  IF v_dir NOT IN ('B2C','C2B') THEN RAISE EXCEPTION 'Choose: got in bank, gave cash  OR  got cash, sent from bank'; END IF;
  IF length(v_person) < 2 OR length(v_person) > 80 THEN RAISE EXCEPTION 'Enter the friend / person name'; END IF;
  v_id := public.lwb_acc_add_entry(jsonb_build_object(
    'date', p->>'date', 'kind', CASE v_dir WHEN 'B2C' THEN 'DEPOSIT' ELSE 'WITHDRAW' END, 'mode', 'CASH',
    'bank_id', p->>'bank_id', 'amount', p->>'amount', 'party', v_person,
    'ref', p->>'ref', 'remark', p->>'remark'));
  INSERT INTO public.lwb_acc_swaps (entry_id, person, created_by) VALUES (v_id, v_person, auth.uid());
  RETURN v_id;
END;
$fn$;

-- Names used in the last 120 days, latest first (suggestions in the popup)
CREATE OR REPLACE FUNCTION public.lwb_acc_swap_names()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE WHEN public.lwb_acc_user() THEN coalesce((
    SELECT jsonb_agg(x.person ORDER BY x.last DESC) FROM (
      SELECT s.person, max(s.created_at) AS last
      FROM public.lwb_acc_swaps s JOIN public.lwb_acc_entries e ON e.id = s.entry_id
      WHERE e.cancelled_at IS NULL AND s.created_at > now() - interval '120 days'
      GROUP BY s.person ORDER BY max(s.created_at) DESC LIMIT 12) x), '[]'::jsonb) ELSE '[]'::jsonb END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_swap_add(jsonb), public.lwb_acc_swap_names() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_swap_add(jsonb), public.lwb_acc_swap_names() TO authenticated;

-- Money lines: head "Friend swap" for swap entries (patched in place, other changes stay)
DO $patch$
DECLARE
  v_def text;
  v_old text := 'coalesce(c.name, CASE e.kind WHEN ''DEPOSIT''';
  v_new text := 'coalesce(c.name, CASE WHEN EXISTS (SELECT 1 FROM public.lwb_acc_swaps sw WHERE sw.entry_id = e.id) THEN ''Friend swap'' END, CASE e.kind WHEN ''DEPOSIT''';
BEGIN
  v_def := pg_get_functiondef('public.lwb_acc_lines_all()'::regprocedure);
  IF position('''Friend swap''' IN v_def) > 0 THEN
    RAISE NOTICE 'lwb_acc_lines_all already shows Friend swap';
  ELSIF position(v_old IN v_def) > 0 THEN
    EXECUTE replace(v_def, v_old, v_new);
  ELSE
    RAISE EXCEPTION 'lwb_acc_lines_all: entry head not found, nothing changed';
  END IF;
END
$patch$;

COMMIT;
