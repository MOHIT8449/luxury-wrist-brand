-- LUXURY WRIST BRAND ERP — ONE-TIME DATA FIX: opening cash 21/11/2026 -> 22/11/2026
--
-- Runs by itself when merged to main. Safe to run again (does nothing the second time).
--
-- Mohit (23 Nov 2026): the cash set as "Opening cash" on 21/11/2026 was the CLOSING cash of 21/11,
-- so it is the opening cash of 22/11. The opening row is stored as a start close on the day before
-- (close_date = 20/11). Move it to close_date = 21/11 so the opening shows on 22/11 and entries of
-- 21/11 no longer count in the cash. Amount is not changed. Fails (rolls back) if the data is not as expected.

BEGIN;
DO $fix$
DECLARE v_id bigint; v_n int;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('lwb_acc_day_close'));
  -- already moved: nothing to do
  IF EXISTS (SELECT 1 FROM public.lwb_acc_day_close c
             WHERE c.cancelled_at IS NULL AND c.is_start AND c.close_date = DATE '2026-11-21') THEN
    RAISE NOTICE 'Opening cash is already on 22/11/2026';
    RETURN;
  END IF;
  SELECT count(*) INTO v_n FROM public.lwb_acc_day_close c WHERE c.cancelled_at IS NULL;
  SELECT c.id INTO v_id FROM public.lwb_acc_day_close c
  WHERE c.cancelled_at IS NULL AND c.is_start AND c.close_date = DATE '2026-11-20';
  IF v_id IS NULL OR v_n <> 1 THEN
    RAISE EXCEPTION 'Expected only the opening cash of 21/11/2026 (found % active day closes)', v_n;
  END IF;
  UPDATE public.lwb_acc_day_close
     SET close_date = DATE '2026-11-21',
         note = left(coalesce(note,'Opening cash') || ' · moved 21/11 -> 22/11 (was closing of 21/11)', 300)
   WHERE id = v_id;
END;
$fix$;
COMMIT;
