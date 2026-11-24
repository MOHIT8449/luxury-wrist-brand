-- LUXURY WRIST BRAND ERP — ONE-TIME DATA FIX: ₹1,00,000 "Other expense" of 23/11/2026 -> Friend swap
--
-- Mohit (24 Nov 2026): on 23/11 ₹1,00,000 came in our bank and we gave ₹1,00,000 cash. It was entered as
-- Cash Out, head "Other expense", so the Admin dashboard shows it in Expenses and Net profit. It is not an
-- expense: it is a Friend swap (lwb_acc_friend_swap_setup.sql), "Got in bank, gave cash".
--
-- The entry is changed in place to a Friend swap (kind DEPOSIT, head removed, marked in lwb_acc_swaps):
--   * cash in hand of 23/11 does not change (cash -1,00,000 before and after), so a closed day stays right;
--   * Expenses / Net profit no longer count it (only Cash Out entries are expenses);
--   * the bank side shows in Bank check as "waiting"; Admin / Accounts picks the bank there if not set.
-- The old row is saved in lwb_acc_swap_fix_log first. It stops (changes nothing) unless exactly one entry
-- matches: not cancelled, 23/11/2026, Cash Out, cash, head "Other expense", ₹1,00,000, no staff / vehicle /
-- company payment / trip rent link. Runs once; safe to run again (does nothing the second time).

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_acc_swap_fix_log (
  id       bigserial PRIMARY KEY,
  fix      text NOT NULL,
  entry_id uuid NOT NULL,
  before   jsonb NOT NULL,
  saved_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_acc_swap_fix_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_acc_swap_fix_log FROM PUBLIC, anon, authenticated;

DO $fix$
DECLARE
  v_fix text := 'swap_23nov_1lakh';
  v_n int; v_e public.lwb_acc_entries%ROWTYPE; v_bank bigint; v_person text;
BEGIN
  IF EXISTS (SELECT 1 FROM public.lwb_acc_swap_fix_log WHERE fix = v_fix) THEN
    RAISE NOTICE 'Already fixed, nothing to do';
    RETURN;
  END IF;

  SELECT count(*) INTO v_n
  FROM public.lwb_acc_entries e
  JOIN public.lwb_acc_categories c ON c.id = e.category_id
  WHERE e.cancelled_at IS NULL AND e.entry_date = DATE '2026-11-23' AND e.kind = 'OUT' AND e.mode = 'CASH'
    AND lower(btrim(c.name)) = 'other expense' AND e.amount = 100000
    AND e.staff_id IS NULL AND e.vehicle_id IS NULL
    AND NOT EXISTS (SELECT 1 FROM public.lwb_company_payments p WHERE p.acc_entry_id = e.id AND p.cancelled_at IS NULL)
    AND NOT EXISTS (SELECT 1 FROM public.lwb_vehicle_trips t WHERE t.acc_entry_id = e.id)
    AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_swaps s WHERE s.entry_id = e.id);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'Expected exactly 1 entry (23/11, Cash Out, Other expense, Rs 1,00,000), found %. Nothing changed.', v_n;
  END IF;

  SELECT e.* INTO v_e
  FROM public.lwb_acc_entries e
  JOIN public.lwb_acc_categories c ON c.id = e.category_id
  WHERE e.cancelled_at IS NULL AND e.entry_date = DATE '2026-11-23' AND e.kind = 'OUT' AND e.mode = 'CASH'
    AND lower(btrim(c.name)) = 'other expense' AND e.amount = 100000
    AND e.staff_id IS NULL AND e.vehicle_id IS NULL;

  INSERT INTO public.lwb_acc_swap_fix_log (fix, entry_id, before) VALUES (v_fix, v_e.id, to_jsonb(v_e));

  -- one active bank = that bank; several = Admin / Accounts picks it in Bank check
  SELECT CASE WHEN count(*) = 1 THEN min(b.id) END INTO v_bank FROM public.lwb_acc_banks b WHERE b.active;
  v_person := upper(regexp_replace(coalesce(nullif(btrim(v_e.party), ''), 'FRIEND (23/11)'), '\s+', ' ', 'g'));
  IF length(v_person) > 80 THEN v_person := left(v_person, 80); END IF;
  IF length(v_person) < 2 THEN v_person := 'FRIEND (23/11)'; END IF;

  UPDATE public.lwb_acc_entries
  SET kind = 'DEPOSIT', category_id = NULL, mode = 'CASH', bank_id = coalesce(bank_id, v_bank), party = v_person,
      gst_bill = false, gst_amount = NULL, gstin = NULL,
      remark = left(concat_ws(' · ', nullif(btrim(remark), ''), 'Was Cash Out / Other expense; made Friend swap 24/11'), 300)
  WHERE id = v_e.id;

  INSERT INTO public.lwb_acc_swaps (entry_id, person, created_by, created_at)
  VALUES (v_e.id, v_person, v_e.created_by, v_e.created_at);

  -- check: it is now a Friend swap line with the same cash effect
  IF NOT EXISTS (SELECT 1 FROM public.lwb_acc_lines_all() l
                 WHERE l.src = 'ENTRY' AND l.id = v_e.id AND l.category = 'Friend swap' AND l.cash_effect = -100000) THEN
    RAISE EXCEPTION 'Check failed: entry is not a Friend swap with cash -1,00,000. Rolled back.';
  END IF;
END
$fix$;

COMMIT;
