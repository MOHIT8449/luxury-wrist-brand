-- LUXURY WRIST BRAND ERP — ACCOUNTS MONEY OVERVIEW
--
-- RUN ONCE in Supabase SQL Editor, after lwb_tally_bill_flow_setup.sql. Safe to run again.
--
-- Accounts > Money Overview shows, for every loaded PO: Tally bill, delivery, the money the driver
-- collected (on the road until Office verifies it), what Office verified and what is still due.
-- Read only: nothing is written. Admin / Accounts only.

CREATE OR REPLACE FUNCTION public.lwb_accounts_money(p_days integer DEFAULT 120)
RETURNS SETOF jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Active Admin / Accounts role required.';
  END IF;
  RETURN QUERY
  SELECT to_jsonb(r) || jsonb_build_object(
           'delivered_at', d.reported_at,
           'collected_at', coalesce(d.payment_saved_at, CASE WHEN d.cash_reported > 0 THEN d.reported_at END),
           'verified_at', CASE WHEN d.payment_status = 'VERIFIED' THEN d.payment_reviewed_at END,
           'payment_status', coalesce(d.payment_status, CASE WHEN d.cash_reported > 0 THEN 'PENDING' END),
           'driver', coalesce(nullif(btrim(dp.full_name), ''), nullif(btrim(a.driver_name::text), '')),
           'vehicle', a.vehicle_no)
  FROM public.lwb_tally_bill_rows(p_days) r
  LEFT JOIN LATERAL (SELECT y.* FROM public.lwb_delivery_reports y WHERE y.order_id = r.order_id
                     ORDER BY y.reported_at DESC LIMIT 1) d ON true
  LEFT JOIN LATERAL (SELECT x.driver_name, x.vehicle_no FROM public.dispatch_assignments x
                     WHERE x.order_id = r.order_id ORDER BY x.loading_completed_at DESC NULLS LAST LIMIT 1) a ON true
  LEFT JOIN public.user_profiles dp ON dp.id = d.driver_user_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_accounts_money(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_accounts_money(integer) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Result: one row, true.
SELECT 'accounts money overview' AS item, (to_regprocedure('public.lwb_accounts_money(integer)') IS NOT NULL)::text AS ok;
