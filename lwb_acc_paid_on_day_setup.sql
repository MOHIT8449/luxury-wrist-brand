-- LUXURY WRIST BRAND ERP — Day book: party payment on its "paid on" date (23 Nov 2026)
--
-- Mohit: MAA TRADERS (BOMBY MARKET) ₹32,000 cash was entered on 23/11 with "paid on 07/11/2026" and showed in
-- today's Day book, "Collected today" and today's cash. Money collected on an old day and entered late must
-- count on the day it was collected (paid on date), not on the day it was typed.
--
-- Change (Accounts Dashboard money lines, used by Day book, Collected, Cash In, Cash in hand, Finance Home):
-- * Party payment / Payment collection (lwb_tally_payments) book day = paid on date (pay_date), never later
--   than the day it was entered. Was: the day it was entered.
-- * If that day was already CLOSED (Close Day done) before the payment was entered, it goes to the first
--   open day after the close, same rule as before. A closed day's counted cash never changes after the fact.
-- * lwb_acc_lines(): a party payment entered on / after the fresh start date still shows (bank check list)
--   even when its paid on date is before the start date. It does not move cash of a closed day.
-- * Driver money and old Payment Collection rows are unchanged (they have no separate paid on date).
--
-- Live functions are patched in place from their current text (lwb_acc_lines_all), so other changes stay.
-- Safe to run again.

BEGIN;

-- Book day of a party payment: paid on date (not after the entry day); a day closed before the entry was made
-- is skipped to the next open day.
CREATE OR REPLACE FUNCTION public.lwb_acc_pay_day(p_pay date, p_at timestamptz)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  WITH d AS (SELECT least(coalesce(p_pay, (p_at AT TIME ZONE 'Asia/Kolkata')::date),
                          (p_at AT TIME ZONE 'Asia/Kolkata')::date) AS day)
  SELECT coalesce((SELECT max(c.close_date) + 1 FROM public.lwb_acc_day_close c
                   WHERE c.cancelled_at IS NULL AND c.close_date >= d.day AND c.closed_at <= p_at), d.day)
  FROM d;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_pay_day(date, timestamptz) FROM PUBLIC, anon, authenticated;

DO $patch$
DECLARE
  v_def text;
  v_old text := 'public.lwb_acc_book_day(p.created_at), p.created_at, ''IN''::text, p.mode';
  v_new text := 'public.lwb_acc_pay_day(p.pay_date, p.created_at), p.created_at, ''IN''::text, p.mode';
BEGIN
  v_def := pg_get_functiondef('public.lwb_acc_lines_all()'::regprocedure);
  IF position(v_new IN v_def) > 0 THEN
    RAISE NOTICE 'lwb_acc_lines_all already uses the paid on date';
  ELSIF position(v_old IN v_def) > 0 THEN
    EXECUTE replace(v_def, v_old, v_new);
  ELSE
    RAISE EXCEPTION 'lwb_acc_lines_all: party payment line not found, nothing changed';
  END IF;
END
$patch$;

-- What the dashboard counts: from the start date (book day), plus ERP money entered on / after it.
CREATE OR REPLACE FUNCTION public.lwb_acc_lines()
RETURNS TABLE (src text, id uuid, book_date date, at timestamptz, kind text, mode text, amount numeric,
               category text, party text, ref text, remark text, order_no text, bank_id bigint,
               cash_effect numeric, needs_verify boolean, created_by uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT l.* FROM public.lwb_acc_lines_all() l
  WHERE l.book_date >= public.lwb_acc_start_date()
     OR (l.src = 'PAYMENT' AND (l.at AT TIME ZONE 'Asia/Kolkata')::date >= public.lwb_acc_start_date());
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_lines_all(), public.lwb_acc_lines() FROM PUBLIC, anon, authenticated;

-- Check
DO $chk$
BEGIN
  IF position('lwb_acc_pay_day(p.pay_date' IN pg_get_functiondef('public.lwb_acc_lines_all()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'lwb_acc_lines_all was not changed';
  END IF;
END
$chk$;

COMMIT;
