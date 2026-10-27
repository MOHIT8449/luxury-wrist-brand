-- LUXURY WRIST BRAND ERP — TALLY BILLS FROM ACCOUNTS SHOW IN THE CASHBOOK AUTOMATICALLY
--
-- RUN ONCE in Supabase SQL Editor, after lwb_tally_subfirm_bills_setup.sql. Safe to run again.
--
-- When Accounts submits the Tally invoice no. + amount (also bills made in sub-firm names), the Cashbook
-- shows the bill under the PO's MAIN party (e.g. SHREE JAGDISH TRADERS) as a pending bill, the same way
-- an imported Tally bill shows. Payments entered against it in the Cashbook reduce it.
-- Read only: the Cashbook code word is checked as usual. Nothing is written.

CREATE OR REPLACE FUNCTION public.lwb_cashbook_erp_bills(p_key text)
RETURNS SETOF jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  RETURN QUERY
  SELECT jsonb_build_object(
           'order_id', t.order_id, 'order_no', o.order_no, 'party', btrim(o.customer_name::text),
           'invoice_no', t.invoice_no, 'invoice_date', t.invoice_date, 'amount', t.amount,
           'bills', coalesce(t.bills, '[]'::jsonb),
           'credit_notes', coalesce((SELECT sum(n.amount) FROM public.lwb_tally_notes n
                                     WHERE n.order_id = t.order_id AND n.kind = 'CREDIT' AND n.cancelled_at IS NULL), 0),
           'debit_notes', coalesce((SELECT sum(n.amount) FROM public.lwb_tally_notes n
                                    WHERE n.order_id = t.order_id AND n.kind = 'DEBIT' AND n.cancelled_at IS NULL), 0))
  FROM public.lwb_tally_invoices t
  JOIN public.orders o ON o.id = t.order_id
  WHERE t.amount IS NOT NULL
    AND t.invoice_date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - 365
  ORDER BY t.invoice_date, o.order_no;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_cashbook_erp_bills(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_cashbook_erp_bills(text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Result: one row, true.
SELECT 'cashbook ERP bills' AS item, (to_regprocedure('public.lwb_cashbook_erp_bills(text)') IS NOT NULL)::text AS ok;
