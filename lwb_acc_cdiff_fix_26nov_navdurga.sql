-- LUXURY WRIST BRAND ERP — ONE-TIME FIX: 26/11 Cash difference Short ₹3,653 -> ₹653
--
-- Runs by itself when merged to main (after lwb_receipt_past_edit_setup.sql). Safe to run again (does nothing
-- the second time).
--
-- Mohit (27 Nov 2026, decision card "Haan: fix + naya process"): NAVDURGA TRADERS (AMROLI) 26/11 cash was entered
-- ₹33,220 (11:59), really ₹30,220. The 15:50 handover (book ₹57,421, counted ₹53,768) booked Short ₹3,653 =
-- ₹3,000 of this mistake + ₹653 real short. On 27/11 4:55 PM Accounts edited the payment to ₹30,220, so the
-- ₹3,000 came off twice and the book (27/11 opening ₹2,14,855) went ₹3,000 below the counted cash (₹2,17,855).
-- Fix: that Short (and its Cash Out "Cash difference" entry) becomes ₹653. Old row in lwb_receipt_cash_adjust.
-- Stops (changes nothing) unless exactly one such Short and exactly one such edited payment exist.

BEGIN;

DO $fix$
DECLARE c public.lwb_acc_cash_diff%ROWTYPE; v_n int; v_rc uuid; v_pn int;
BEGIN
  IF EXISTS (SELECT 1 FROM public.lwb_receipt_cash_adjust a WHERE a.note LIKE 'One-time fix 26/11 NAVDURGA%') THEN
    RAISE NOTICE 'Already fixed'; RETURN;
  END IF;
  SELECT count(*) INTO v_n FROM public.lwb_acc_cash_diff d
  WHERE d.day = DATE '2026-11-26' AND d.kind = 'SHORT' AND d.amount = 3653 AND d.cancelled_at IS NULL;
  IF v_n <> 1 THEN RAISE EXCEPTION 'Expected one 26/11 Short of Rs 3653, found %', v_n; END IF;
  SELECT * INTO c FROM public.lwb_acc_cash_diff d
  WHERE d.day = DATE '2026-11-26' AND d.kind = 'SHORT' AND d.amount = 3653 AND d.cancelled_at IS NULL;

  SELECT count(DISTINCT p.receipt_id), min(p.receipt_id::text)::uuid INTO v_pn, v_rc
  FROM public.lwb_tally_payments p
  JOIN public.lwb_ledger_edit_log e ON e.ref_id = p.receipt_id AND e.kind = 'RECEIPT' AND e.action = 'EDIT'
       AND (e.before->>'total')::numeric = 33220 AND (e.after->>'total')::numeric = 30220
  WHERE p.party ILIKE '%NAVDURGA%' AND p.pay_date = DATE '2026-11-26' AND p.cancelled_at IS NULL AND p.mode = 'CASH' AND p.amount = 30220;
  IF v_pn <> 1 THEN RAISE EXCEPTION 'Expected one edited NAVDURGA 26/11 payment (33220 -> 30220), found %', v_pn; END IF;

  UPDATE public.lwb_acc_cash_diff SET amount = 653,
         note = left(coalesce(note,'') || ' · Rs 3,000 of it was the NAVDURGA 33,220 -> 30,220 mistake (fixed 27/11)', 300)
  WHERE id = c.id;
  UPDATE public.lwb_acc_entries SET amount = 653,
         remark = left(coalesce(remark,'') || ' · was Rs 3653; Rs 3000 = NAVDURGA 26/11 entered 33,220, really 30,220 (fixed 27/11)', 300)
  WHERE id = c.entry_id AND cancelled_at IS NULL AND amount = 3653;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cash difference entry not found / not Rs 3653'; END IF;
  INSERT INTO public.lwb_receipt_cash_adjust (receipt_id, diff_id, entry_id, kind, amount_old, amount_new, note)
  VALUES (v_rc, c.id, c.entry_id, 'SHORT', 3653, 653, 'One-time fix 26/11 NAVDURGA 33,220 -> 30,220 (Mohit OK 27/11)');
END $fix$;

COMMIT;
