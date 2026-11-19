-- LUXURY WRIST BRAND ERP — MISSING PURCHASE BILLS (company statement vs Purchase) (19 Nov 2026)
--
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (19 Nov 2026): after "Match Bills" (company AR Statement PDF / Excel) shows the invoices that
-- are not entered in Purchase, press Submit so Admin, Sales Head and Accounts see the missing bills
-- on the Purchase List and enter them.
--   * lwb_purchase_missing: one row per company invoice no. (key = lwb_inv_key), with date, amount, who sent it.
--     A row counts as done by itself once a purchase bill with that invoice no. is saved
--     (the page and lwb_purchase_missing_list() check lwb_goods_inward).
--   * lwb_purchase_missing_submit(items)  Admin / Sales Head / Accounts: add / update the list, bell to
--     every active Admin, Sales Head and Accounts user ("N purchase bills not entered").
--   * lwb_purchase_missing_list()          open rows only (not entered yet, not removed).
--   * lwb_purchase_missing_remove(key, reason) Admin / Sales Head / Accounts: take a wrong row off the list.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_purchase_missing (
  inv_key text PRIMARY KEY,
  invoice_no text NOT NULL,
  invoice_date text,
  amount numeric(14,2),
  source text,
  submitted_by uuid DEFAULT auth.uid(),
  submitted_by_name text,
  submitted_at timestamptz NOT NULL DEFAULT now(),
  removed_at timestamptz,
  removed_by uuid,
  removed_reason text
);
ALTER TABLE public.lwb_purchase_missing ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_purchase_missing FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_purchase_missing_list()
RETURNS SETOF public.lwb_purchase_missing LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.lwb_pr_role() NOT IN ('admin','manager','accounts','warehouse') THEN RAISE EXCEPTION 'Not allowed'; END IF;
  RETURN QUERY SELECT m.* FROM public.lwb_purchase_missing m
    WHERE m.removed_at IS NULL
      AND NOT EXISTS (SELECT 1 FROM public.lwb_goods_inward g WHERE public.lwb_inv_key(g.invoice_no) = m.inv_key)
    ORDER BY m.invoice_date NULLS LAST, m.invoice_no;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_missing_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_missing_list() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_purchase_missing_submit(p_items jsonb, p_source text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  x jsonb;
  k text;
  v_by text;
  v_n integer := 0;
  v_open integer;
  v_amt numeric;
BEGIN
  IF public.lwb_pr_role() NOT IN ('admin','manager','accounts') THEN RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can submit missing bills'; END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'No missing bills to submit'; END IF;
  IF jsonb_array_length(p_items) > 2000 THEN RAISE EXCEPTION 'Too many lines'; END IF;
  SELECT coalesce(nullif(btrim(p.full_name),''), 'Staff') INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();
  FOR x IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    k := public.lwb_inv_key(x->>'invoice_no');
    CONTINUE WHEN k = '' OR length(k) > 40;
    v_amt := CASE WHEN coalesce(x->>'amount','') ~ '^-?\d+(\.\d+)?$' THEN (x->>'amount')::numeric END;
    INSERT INTO public.lwb_purchase_missing(inv_key, invoice_no, invoice_date, amount, source, submitted_by_name)
    VALUES (k, left(btrim(x->>'invoice_no'), 60), left(nullif(btrim(coalesce(x->>'invoice_date','')),''), 20), v_amt, left(p_source, 120), v_by)
    ON CONFLICT (inv_key) DO UPDATE SET invoice_date = coalesce(EXCLUDED.invoice_date, lwb_purchase_missing.invoice_date),
      amount = coalesce(EXCLUDED.amount, lwb_purchase_missing.amount), source = EXCLUDED.source,
      submitted_by = auth.uid(), submitted_by_name = v_by, submitted_at = now(),
      removed_at = NULL, removed_by = NULL, removed_reason = NULL;
    v_n := v_n + 1;
  END LOOP;
  SELECT count(*)::int INTO v_open FROM public.lwb_purchase_missing_list();
  IF v_open > 0 THEN
    INSERT INTO public.erp_notifications(user_id, title, message, notification_type, ref_type, ref_id)
    SELECT p.id, left(v_open || ' purchase bill' || CASE WHEN v_open > 1 THEN 's' ELSE '' END || ' not entered', 150),
           left('Company statement has ' || v_open || ' invoice' || CASE WHEN v_open > 1 THEN 's' ELSE '' END
                || ' not entered in Purchase. Please enter the bill' || CASE WHEN v_open > 1 THEN 's' ELSE '' END
                || '. Sent by ' || v_by || '.', 600),
           'PURCHASE_MISSING', 'PURCHASE_MISSING', to_char(now() AT TIME ZONE 'Asia/Kolkata', 'YYYY-MM-DD')
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager','accounts') AND p.id IS DISTINCT FROM auth.uid();
  END IF;
  RETURN jsonb_build_object('saved', v_n, 'open', v_open);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_missing_submit(jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_missing_submit(jsonb, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_purchase_missing_remove(p_key text, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.lwb_pr_role() NOT IN ('admin','manager','accounts') THEN RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can remove a missing bill'; END IF;
  IF length(btrim(coalesce(p_reason,''))) < 3 THEN RAISE EXCEPTION 'Write the reason'; END IF;
  UPDATE public.lwb_purchase_missing SET removed_at = now(), removed_by = auth.uid(), removed_reason = left(btrim(p_reason), 300)
  WHERE inv_key = public.lwb_inv_key(p_key);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_missing_remove(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_missing_remove(text, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT to_regclass('public.lwb_purchase_missing') IS NOT NULL AS missing_bills_ready;
