-- LUXURY WRIST BRAND ERP — KASAR (SMALL DIFFERENCE WRITE-OFF ON A BILL)
--
-- Runs by itself when merged to main (after lwb_cashier_role_setup.sql, lwb_tally_bill_flow_setup.sql, lwb_party_group_billing_setup.sql,
-- lwb_brand_money_setup.sql and lwb_sales_head_outstanding_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (20 Nov 2026): a party often pays Rs 5 / 10 / 20 less (or more) than the bill, e.g. Rs 1,09,985
-- on a bill of Rs 1,10,000. That difference is let go as KASAR so the bill does not stay in Outstanding /
-- reminders. Give a Kasar option, show it in the party ledger and keep a Kasar ledger (total per party / date).
--
-- How it is kept: a kasar is a credit note (party paid LESS) or debit note (party paid EXTRA) on the bill,
-- marked is_kasar = true, note no. KASAR. Every due / outstanding / ledger figure already counts credit and
-- debit notes, so the bill closes everywhere at once (Outstanding, To collect, Party ledger, brand balance).
--   * lwb_kasar_save(order, amount, kind LESS|EXTRA, date, remark)   Accounts / Admin / Cashier, max Rs 500 per entry
--   * lwb_kasar_cancel(id)                                           Accounts / Admin (kept, marked cancelled)
--   * lwb_kasar_list(days)                                           Kasar ledger rows (Admin, Accounts, Sales Head)
--   * lwb_party_receive_kasar(... , p_kasar)                          party payment + kasar in one save
-- No notification is sent for a kasar (the credit / debit note alert skips it).

BEGIN;

ALTER TABLE public.lwb_tally_notes ADD COLUMN IF NOT EXISTS is_kasar boolean NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS lwb_tally_notes_kasar_idx ON public.lwb_tally_notes(note_date) WHERE is_kasar AND cancelled_at IS NULL;

-- ---------------------------------------------------------------------------
-- 1. Save one kasar on a bill
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_kasar_save(p_order_id uuid, p_amount numeric, p_kind text DEFAULT 'LESS',
                                                 p_date date DEFAULT NULL, p_remark text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_kind text := upper(btrim(coalesce(p_kind,'LESS')));
  v_amt numeric := round(coalesce(p_amount,0), 2);
  v_date date := coalesce(p_date, (now() AT TIME ZONE 'Asia/Kolkata')::date);
  v_remark text := nullif(btrim(coalesce(p_remark,'')),'');
  v_due numeric; v_no text; v_n int; v_id uuid; v_order text;
BEGIN
  IF NOT (public.lwb_tally_staff() OR public.lwb_acc_cashier()) THEN
    RAISE EXCEPTION 'Only active Accounts, Cashier or Admin can enter kasar';
  END IF;
  IF v_kind NOT IN ('LESS','EXTRA') THEN RAISE EXCEPTION 'Kasar is LESS (party paid less) or EXTRA (party paid more)'; END IF;
  IF v_amt <= 0 THEN RAISE EXCEPTION 'Enter the kasar amount'; END IF;
  IF v_amt > 500 THEN RAISE EXCEPTION 'Kasar can be at most Rs 500 on one bill. Use a credit note for more.'; END IF;
  IF v_date > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1 THEN RAISE EXCEPTION 'Enter a valid kasar date'; END IF;
  IF length(coalesce(v_remark,'')) > 200 THEN RAISE EXCEPTION 'Remark is too long'; END IF;
  SELECT o.order_no::text INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Bill not found'; END IF;
  PERFORM 1 FROM public.lwb_tally_invoices t WHERE t.order_id = p_order_id FOR UPDATE;
  v_due := public.lwb_order_tally_due(p_order_id);
  IF v_due IS NULL THEN RAISE EXCEPTION 'PO % has no Tally bill amount yet', v_order; END IF;
  IF v_kind = 'LESS' AND v_amt > v_due + 0.01 THEN
    RAISE EXCEPTION 'Kasar Rs % on PO % is more than its due Rs %', v_amt, v_order, greatest(v_due,0);
  END IF;
  SELECT count(*) INTO v_n FROM public.lwb_tally_notes n WHERE n.order_id = p_order_id AND n.is_kasar;
  v_no := 'KASAR' || CASE WHEN v_n > 0 THEN '-' || (v_n + 1) ELSE '' END;
  INSERT INTO public.lwb_tally_notes (order_id, kind, note_no, note_date, amount, reason, created_by, is_kasar)
  VALUES (p_order_id, CASE WHEN v_kind = 'LESS' THEN 'CREDIT' ELSE 'DEBIT' END, v_no, v_date, v_amt,
          concat_ws(' · ', CASE WHEN v_kind = 'LESS' THEN 'Kasar (party paid less)' ELSE 'Kasar (party paid extra)' END, v_remark),
          auth.uid(), true)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_kasar_cancel(p_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can cancel kasar';
  END IF;
  UPDATE public.lwb_tally_notes SET cancelled_at = now(), cancelled_by = auth.uid()
  WHERE id = p_id AND is_kasar AND cancelled_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Kasar entry not found'; END IF;
  RETURN 'CANCELLED';
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. Kasar ledger (newest first)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_kasar_list(p_days integer DEFAULT 400)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_days int := least(greatest(coalesce(p_days,400),1),1000);
BEGIN
  IF NOT (public.lwb_tally_staff() OR public.lwb_outstanding_viewer()) THEN
    RAISE EXCEPTION 'Admin / Accounts / Sales Head only.';
  END IF;
  RETURN (
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', n.id, 'date', n.note_date, 'kind', CASE WHEN n.kind = 'CREDIT' THEN 'LESS' ELSE 'EXTRA' END,
             'amount', n.amount, 'order_id', n.order_id, 'order_no', o.order_no, 'invoice_no', t.invoice_no,
             'party', btrim(o.customer_name), 'parent', public.lwb_party_parent(o.customer_name),
             'company_id', public.lwb_order_company(n.order_id), 'remark', n.reason,
             'by_name', up.full_name, 'created_at', n.created_at)
           ORDER BY n.note_date DESC, n.created_at DESC), '[]'::jsonb)
    FROM public.lwb_tally_notes n
    JOIN public.orders o ON o.id = n.order_id
    LEFT JOIN public.lwb_tally_invoices t ON t.order_id = n.order_id
    LEFT JOIN public.user_profiles up ON up.id = n.created_by
    WHERE n.is_kasar AND n.cancelled_at IS NULL
      AND n.note_date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - v_days);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. Party payment + kasar in one save (Party payment popup).
--    p_kasar = [{order_id, amount, kind: LESS|EXTRA}]. Kasar is put on the bills first, then the money is split
--    (p_allocs as sent by the screen, already counting the kasar).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_receive_kasar(p_party text, p_pay_date date, p_lines jsonb,
                                                         p_allocs jsonb DEFAULT NULL, p_remark text DEFAULT NULL,
                                                         p_company_id uuid DEFAULT NULL, p_kasar jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_parent text := public.lwb_party_parent(p_party);
  v_line jsonb; v_order uuid; v_party text; v_total numeric := 0; v_res jsonb;
BEGIN
  IF NOT (public.lwb_tally_staff() OR public.lwb_acc_cashier()) THEN
    RAISE EXCEPTION 'Only active Accounts, Cashier or Admin can enter a party payment';
  END IF;
  IF p_kasar IS NOT NULL AND jsonb_typeof(p_kasar) <> 'array' THEN RAISE EXCEPTION 'Bad kasar list'; END IF;
  IF jsonb_array_length(coalesce(p_kasar,'[]'::jsonb)) > 50 THEN RAISE EXCEPTION 'Too many kasar lines'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(v_parent)));
  FOR v_line IN SELECT * FROM jsonb_array_elements(coalesce(p_kasar,'[]'::jsonb)) LOOP
    BEGIN v_order := (v_line->>'order_id')::uuid;
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'Bad bill in the kasar list'; END;
    SELECT o.customer_name INTO v_party FROM public.orders o WHERE o.id = v_order;
    IF NOT FOUND OR public.lwb_party_key(public.lwb_party_parent(v_party)) <> public.lwb_party_key(v_parent) THEN
      RAISE EXCEPTION 'Kasar bill is not of %', v_parent;
    END IF;
    PERFORM public.lwb_kasar_save(v_order, (v_line->>'amount')::numeric, coalesce(v_line->>'kind','LESS'), p_pay_date, 'with payment');
    v_total := v_total + round((v_line->>'amount')::numeric, 2);
  END LOOP;
  v_res := public.lwb_party_receive(p_party, p_pay_date, p_lines, p_allocs, p_remark, p_company_id);
  RETURN v_res || jsonb_build_object('kasar', round(v_total,2));
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_kasar_save(uuid,numeric,text,date,text), public.lwb_kasar_cancel(uuid),
  public.lwb_kasar_list(integer), public.lwb_party_receive_kasar(text,date,jsonb,jsonb,text,uuid,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_kasar_save(uuid,numeric,text,date,text), public.lwb_kasar_cancel(uuid),
  public.lwb_kasar_list(integer), public.lwb_party_receive_kasar(text,date,jsonb,jsonb,text,uuid,jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. No "Credit Note Entered" alert for a kasar (patch the alert, keep the rest as it is)
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE d text;
BEGIN
  IF to_regprocedure('public.lwb_flow_tally_note()') IS NULL THEN RETURN; END IF;
  d := pg_get_functiondef('public.lwb_flow_tally_note()'::regprocedure);
  IF position('is_kasar' IN d) = 0 AND position(E'BEGIN\n' IN d) > 0 THEN
    d := regexp_replace(d, E'BEGIN\n', E'BEGIN\n  IF NEW.is_kasar THEN RETURN NEW; END IF;\n');
    EXECUTE d;
  END IF;
END
$patch$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result rows (all true)
SELECT 'kasar column' AS item, EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
         AND table_name = 'lwb_tally_notes' AND column_name = 'is_kasar')::text AS ok
UNION ALL SELECT 'kasar functions', (to_regprocedure('public.lwb_kasar_save(uuid,numeric,text,date,text)') IS NOT NULL
         AND to_regprocedure('public.lwb_party_receive_kasar(text,date,jsonb,jsonb,text,uuid,jsonb)') IS NOT NULL)::text
UNION ALL SELECT 'no alert for kasar', (to_regprocedure('public.lwb_flow_tally_note()') IS NULL
         OR pg_get_functiondef('public.lwb_flow_tally_note()'::regprocedure) LIKE '%is_kasar%')::text;
