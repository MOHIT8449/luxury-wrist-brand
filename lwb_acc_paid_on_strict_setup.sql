-- LUXURY WRIST BRAND ERP — Day book: party payment ALWAYS on its "paid on" date (23 Nov 2026, follow-up)
--
-- Mohit: opening cash was counted on 22/11. Old payments (collected before that) entered later must stay on
-- their paid on date and never add to the cash after the count; the counted cash already had that money.
-- lwb_acc_paid_on_day_setup.sql moved such a payment to the first open day when the day had been closed /
-- opening set BEFORE the entry was typed, which added it to cash again (book cash too high, ~Rs 18,000 seen).
--
-- Now: book day = paid on date (never later than the day it was entered). A payment dated on / before a
-- closed day sits in that day of the Day book and does not change cash after the close. Safe to run again.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_acc_pay_day(p_pay date, p_at timestamptz)
RETURNS date LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT least(coalesce(p_pay, (p_at AT TIME ZONE 'Asia/Kolkata')::date), (p_at AT TIME ZONE 'Asia/Kolkata')::date);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_pay_day(date, timestamptz) FROM PUBLIC, anon, authenticated;

-- Day book strip: party payments ENTERED in these dates with an older paid on date (where they went, cash or not).
-- in_cash = the paid on day is after the last closed day (opening / Close Day), so it moves the cash now.
CREATE OR REPLACE FUNCTION public.lwb_acc_late_lines(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_last date;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts Dashboard is for active Accounts or Admin only'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > 400 THEN RAISE EXCEPTION 'Choose 400 days or less'; END IF;
  SELECT max(c.close_date) INTO v_last FROM public.lwb_acc_day_close c WHERE c.cancelled_at IS NULL;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id', l.id, 'party', l.party, 'mode', l.mode, 'amount', l.amount, 'ref', l.ref, 'order_no', l.order_no,
      'paid', l.book_date, 'at', l.at, 'by', cp.full_name,
      'in_cash', l.mode = 'CASH' AND (v_last IS NULL OR l.book_date > v_last) AND l.book_date >= public.lwb_acc_start_date())
      ORDER BY l.at DESC)
    FROM public.lwb_acc_lines_all() l
    LEFT JOIN public.user_profiles cp ON cp.id = l.created_by
    WHERE l.src = 'PAYMENT' AND (l.at AT TIME ZONE 'Asia/Kolkata')::date BETWEEN p_from AND p_to
      AND l.book_date < (l.at AT TIME ZONE 'Asia/Kolkata')::date), '[]'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_late_lines(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_late_lines(date, date) TO authenticated;

DO $chk$
BEGIN
  IF position('lwb_acc_pay_day(p.pay_date' IN pg_get_functiondef('public.lwb_acc_lines_all()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'lwb_acc_lines_all does not use lwb_acc_pay_day; run lwb_acc_paid_on_day_setup.sql first';
  END IF;
END
$chk$;

COMMIT;
