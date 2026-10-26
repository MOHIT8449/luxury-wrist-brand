-- LUXURY WRIST BRAND ERP — DRIVER CASH IN THE CASHBOOK
--
-- RUN ONCE in Supabase SQL Editor (after lwb_cashbook_tally_check_setup.sql). Safe to run again.
--
-- Cashbook shows the payments drivers reported in the Driver Portal (last 15 days), so the
-- office can add each one as Cash In with one click. Only Cashbook users (lwb_cashbook_user)
-- can read this list. Nothing is written: driver reports, payments and ledgers are not changed.

CREATE OR REPLACE FUNCTION public.lwb_cashbook_driver_cash(p_days integer DEFAULT 15)
RETURNS TABLE (report_id uuid, report_date date, report_time text, order_no text, party text,
               driver text, amount numeric, mode text, reference text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_user() THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  RETURN QUERY
  SELECT dr.id,
         timezone('Asia/Kolkata', dr.reported_at)::date,
         to_char(timezone('Asia/Kolkata', dr.reported_at), 'HH24:MI'),
         o.order_no::text,
         btrim(o.customer_name::text),
         coalesce(nullif(btrim(a.driver_name::text), ''), nullif(btrim(p.full_name), ''), 'Driver'),
         dr.cash_reported,
         coalesce(dr.payment_mode, 'CASH'),
         coalesce(dr.payment_reference, '')
  FROM public.lwb_delivery_reports dr
  JOIN public.orders o ON o.id = dr.order_id
  LEFT JOIN public.dispatch_assignments a ON a.id = dr.assignment_id
  LEFT JOIN public.user_profiles p ON p.id = dr.driver_user_id
  WHERE dr.cash_reported > 0
    AND dr.reported_at >= now() - make_interval(days => least(greatest(coalesce(p_days, 15), 1), 90))
  ORDER BY dr.reported_at DESC;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_cashbook_driver_cash(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_cashbook_driver_cash(integer) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Result: one row, true.
SELECT 'driver cash for cashbook' AS item,
  (to_regprocedure('public.lwb_cashbook_driver_cash(integer)') IS NOT NULL)::text AS ok;
