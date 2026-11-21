-- LUXURY WRIST BRAND ERP — CHANGE THE DATE OF A RECEIPT (party payment / payment collection)
--
-- Runs by itself when merged to main. Safe to run again. Nothing is deleted.
--
-- Mohit (21 Nov 2026): V S SALES (HARI NAGAR) ₹39,000 UPI was entered by Accounts on 21/11/2026 but
-- the money came on 20/11. There was no way to fix the date, so the party ledger showed it on the
-- wrong day and the running balance was off for that day.
--
--  1. Table lwb_receipt_date_log: every date change (receipt, old date, new date, reason, who, when).
--  2. lwb_receipt_set_date(p_receipt_id, p_date, p_reason): Admin or Accounts only. Moves every mode
--     line of that receipt (lwb_tally_payments.pay_date) to the new date. Not for a cancelled receipt,
--     not a future date; Accounts can go back at most 90 days, Admin any date. Reason is optional.
--     Amount, modes, refs, brand, splits to bills, bank check and the cash book (which counts by the
--     entry time, not the receipt date) are NOT changed.
--  3. lwb_receipt_date_log_list(p_days): date changes of the last p_days days for Admin / Accounts /
--     Cashier (shown as "Date changed 21/11 → 20/11 by …" on the receipt).

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_receipt_date_log (
  id          bigserial PRIMARY KEY,
  receipt_id  uuid NOT NULL,
  party       text,
  amount      numeric(14,2),
  old_date    date NOT NULL,
  new_date    date NOT NULL,
  reason      text CHECK (reason IS NULL OR length(reason) <= 300),
  changed_by  uuid NOT NULL,
  changed_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_receipt_date_log_receipt_idx ON public.lwb_receipt_date_log(receipt_id);
ALTER TABLE public.lwb_receipt_date_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_receipt_date_log FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_receipt_set_date(p_receipt_id uuid, p_date date, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_admin boolean;
  v_old date; v_party text; v_amt numeric; v_cancel boolean;
  v_reason text := nullif(btrim(coalesce(p_reason,'')), '');
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can change the date of a payment';
  END IF;
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) = 'admin') INTO v_admin;
  IF p_receipt_id IS NULL OR p_date IS NULL THEN RAISE EXCEPTION 'Choose the new date'; END IF;
  IF p_date > v_today THEN RAISE EXCEPTION 'The date cannot be in the future'; END IF;
  IF NOT v_admin AND p_date < v_today - 90 THEN
    RAISE EXCEPTION 'Accounts can move a payment back at most 90 days. Ask Admin for an older date.';
  END IF;
  IF v_reason IS NOT NULL AND length(v_reason) > 300 THEN RAISE EXCEPTION 'Reason is too long (300 letters max)'; END IF;

  SELECT min(p.pay_date), min(coalesce(p.party, o.customer_name::text)), sum(p.amount), bool_and(p.cancelled_at IS NOT NULL)
    INTO v_old, v_party, v_amt, v_cancel
  FROM public.lwb_tally_payments p LEFT JOIN public.orders o ON o.id = p.order_id
  WHERE p.receipt_id = p_receipt_id;
  IF v_old IS NULL THEN RAISE EXCEPTION 'Payment not found'; END IF;
  IF v_cancel THEN RAISE EXCEPTION 'This payment is cancelled; its date cannot be changed'; END IF;
  IF v_old = p_date AND NOT EXISTS (SELECT 1 FROM public.lwb_tally_payments p
                                    WHERE p.receipt_id = p_receipt_id AND p.pay_date <> p_date) THEN
    RAISE EXCEPTION 'The payment is already on %', to_char(p_date, 'DD/MM/YYYY');
  END IF;

  UPDATE public.lwb_tally_payments SET pay_date = p_date
  WHERE receipt_id = p_receipt_id AND cancelled_at IS NULL;

  INSERT INTO public.lwb_receipt_date_log (receipt_id, party, amount, old_date, new_date, reason, changed_by)
  VALUES (p_receipt_id, v_party, v_amt, v_old, p_date, v_reason, auth.uid());

  RETURN jsonb_build_object('receipt_id', p_receipt_id, 'old_date', v_old, 'new_date', p_date, 'party', v_party, 'amount', v_amt);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_receipt_date_log_list(p_days integer DEFAULT 400)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'receipt_id', l.receipt_id, 'old_date', l.old_date, 'new_date', l.new_date, 'reason', l.reason,
           'by', coalesce(u.full_name, 'Staff'), 'at', l.changed_at) ORDER BY l.changed_at), '[]'::jsonb)
  FROM public.lwb_receipt_date_log l
  LEFT JOIN public.user_profiles u ON u.id = l.changed_by
  WHERE EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                AND lower(btrim(p.role)) IN ('accounts','admin','cashier'))
    AND l.changed_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 400), 3000)));
$fn$;

REVOKE ALL ON FUNCTION public.lwb_receipt_set_date(uuid,date,text), public.lwb_receipt_date_log_list(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_receipt_set_date(uuid,date,text), public.lwb_receipt_date_log_list(integer) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'receipt date change' AS item,
  (to_regclass('public.lwb_receipt_date_log') IS NOT NULL
   AND to_regprocedure('public.lwb_receipt_set_date(uuid,date,text)') IS NOT NULL
   AND to_regprocedure('public.lwb_receipt_date_log_list(integer)') IS NOT NULL)::text AS ok;
