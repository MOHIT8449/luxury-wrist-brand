-- LUXURY WRIST BRAND ERP — PAYMENT COLLECTION ON TALLY BILLS + PARTY OUTSTANDING FROM TALLY BILLS
--
-- RUN ONCE in Supabase SQL Editor, after lwb_tally_bill_flow_setup.sql, lwb_tally_subfirm_bills_setup.sql
-- and lwb_driver_money_ledger_setup.sql. Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (30 Oct 2026), Accounts > Tally Bill & Invoice No. > Money to collect:
--  1. Payment Collection beside Credit note: money the party paid, split over Cash / UPI / Bank / Cheque.
--     Cash is entered as notes (500 x count, 200 x count ... + coins) and adds up by itself.
--     Saved at once (Accounts / Admin receive it), a wrong entry is cancelled, never deleted.
--  2. Money due per Tally bill = bill − credit notes + debit notes − driver money − Payment Collection.
--     Example: bill 50,000, credit note 1,000, cash 10,000 → due 39,000.
--  3. Party Ledger: a PO with a Tally bill amount now goes in by its Tally bill (debit), credit notes
--     (credit), old debit notes (debit), driver money and Payment Collection (credit). Its ERP bill and
--     its returns are left out of the ledger (the credit note is what reduces the bill), so nothing
--     counts twice. POs with no Tally bill amount stay exactly as before.
-- Debit notes are no longer offered for parties (only purchase suppliers get one); old ones still count.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Payment Collection rows: one row per mode, rows of one receipt share receipt_id
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_tally_payments (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  receipt_id   uuid NOT NULL,
  order_id     uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  pay_date     date NOT NULL,
  mode         text NOT NULL CHECK (mode IN ('CASH','UPI','BANK','CHEQUE')),
  amount       numeric(14,2) NOT NULL CHECK (amount > 0),
  ref_no       text CHECK (ref_no IS NULL OR length(ref_no) <= 100),
  cash_notes   jsonb,
  remark       text CHECK (remark IS NULL OR length(remark) <= 300),
  created_by   uuid NOT NULL REFERENCES auth.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  cancelled_by uuid REFERENCES auth.users(id),
  cancelled_at timestamptz
);
CREATE INDEX IF NOT EXISTS lwb_tally_payments_order_idx ON public.lwb_tally_payments(order_id);
CREATE INDEX IF NOT EXISTS lwb_tally_payments_receipt_idx ON public.lwb_tally_payments(receipt_id);
ALTER TABLE public.lwb_tally_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_tally_payments FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_tally_payments TO authenticated;
DROP POLICY IF EXISTS lwb_tally_payments_read ON public.lwb_tally_payments;
CREATE POLICY lwb_tally_payments_read ON public.lwb_tally_payments FOR SELECT TO authenticated
  USING (public.lwb_tally_staff());

-- Payment Collection money of one order (not cancelled). Internal use only.
CREATE OR REPLACE FUNCTION public.lwb_order_office_paid(p_order_id uuid)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT round(COALESCE(sum(p.amount),0),2) FROM public.lwb_tally_payments p
  WHERE p.order_id = p_order_id AND p.cancelled_at IS NULL;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_office_paid(uuid) FROM PUBLIC, anon, authenticated;

-- p_lines: [{"mode":"CASH","notes":{"500":10,"200":5,"coins":20}},
--           {"mode":"UPI","amount":5000,"ref":"UTR123"}, {"mode":"CHEQUE","amount":10000,"ref":"001234"}]
-- Cash amount = notes x count + coins. Returns the receipt id.
CREATE OR REPLACE FUNCTION public.lwb_save_tally_payment(p_order_id uuid, p_pay_date date, p_lines jsonb,
                                                         p_remark text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_receipt uuid := gen_random_uuid();
  v_remark text := nullif(btrim(coalesce(p_remark,'')),'');
  v_bill numeric; v_cr numeric; v_dr numeric; v_drv numeric; v_due numeric;
  v_line jsonb; v_mode text; v_amt numeric; v_ref text; v_notes jsonb; v_clean jsonb;
  v_key text; v_cnt numeric; v_total numeric := 0; v_cash numeric := 0;
  v_rows jsonb := '[]'::jsonb;
  v_modes text[] := '{}';
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can enter a payment';
  END IF;
  IF p_pay_date IS NULL OR p_pay_date > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1 THEN
    RAISE EXCEPTION 'Enter a valid payment date';
  END IF;
  IF length(coalesce(v_remark,'')) > 300 THEN RAISE EXCEPTION 'Remark is too long'; END IF;
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Enter at least one payment mode';
  END IF;
  IF jsonb_array_length(p_lines) > 8 THEN RAISE EXCEPTION 'Too many payment lines'; END IF;

  -- Lock the Tally bill so two receipts on the same bill are checked one at a time.
  SELECT t.amount INTO v_bill FROM public.lwb_tally_invoices t WHERE t.order_id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Enter the Tally bill of this PO first'; END IF;
  IF v_bill IS NULL THEN RAISE EXCEPTION 'Enter the Tally bill amount of this PO first'; END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_mode := upper(btrim(coalesce(v_line->>'mode','')));
    v_ref := nullif(btrim(coalesce(v_line->>'ref','')),'');
    v_clean := NULL;
    IF v_mode NOT IN ('CASH','UPI','BANK','CHEQUE') THEN RAISE EXCEPTION 'Select Cash, UPI, Bank or Cheque'; END IF;
    IF v_mode = ANY(v_modes) THEN RAISE EXCEPTION '% is entered twice. Put it in one line.', initcap(v_mode); END IF;
    v_modes := v_modes || v_mode;
    IF length(coalesce(v_ref,'')) > 100 THEN RAISE EXCEPTION 'Reference is too long'; END IF;
    IF v_mode = 'CASH' THEN
      -- Cash = notes x count + coins (same notes as the driver phone)
      v_notes := coalesce(v_line->'notes','{}'::jsonb);
      IF jsonb_typeof(v_notes) <> 'object' THEN RAISE EXCEPTION 'Enter the cash notes'; END IF;
      v_clean := '{}'::jsonb; v_amt := 0;
      FOR v_key IN SELECT jsonb_object_keys(v_notes) LOOP
        IF v_key NOT IN ('500','200','100','50','20','10','coins') THEN RAISE EXCEPTION 'Unknown note %', v_key; END IF;
        BEGIN
          v_cnt := coalesce(nullif(v_notes->>v_key,''),'0')::numeric;
        EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter a number for %', v_key;
        END;
        IF v_cnt < 0 OR v_cnt > 100000 OR (v_key <> 'coins' AND v_cnt <> trunc(v_cnt)) THEN
          RAISE EXCEPTION 'Check the count of %', v_key;
        END IF;
        IF v_cnt > 0 THEN
          v_clean := v_clean || jsonb_build_object(v_key, v_cnt);
          v_amt := v_amt + CASE WHEN v_key = 'coins' THEN round(v_cnt,2) ELSE v_key::numeric * v_cnt END;
        END IF;
      END LOOP;
      v_cash := v_cash + v_amt;
    ELSE
      BEGIN
        v_amt := round(coalesce(nullif(v_line->>'amount',''),'0')::numeric, 2);
      EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter the % amount', initcap(v_mode);
      END;
      IF v_mode = 'CHEQUE' AND v_ref IS NULL THEN RAISE EXCEPTION 'Enter the cheque number'; END IF;
      IF v_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.lwb_tally_payments x WHERE x.mode = v_mode
            AND upper(btrim(x.ref_no)) = upper(v_ref) AND x.cancelled_at IS NULL) THEN
        RAISE EXCEPTION '% reference % is already entered', initcap(v_mode), v_ref;
      END IF;
    END IF;
    IF v_amt <= 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'Enter the % amount', initcap(v_mode); END IF;
    v_total := v_total + v_amt;
    v_rows := v_rows || jsonb_build_object('mode', v_mode, 'amount', v_amt, 'ref', v_ref, 'notes', v_clean);
  END LOOP;

  IF v_cash >= 200000 THEN
    RAISE EXCEPTION 'Cash of Rs 2 lakh or more in one receipt is not allowed (Income Tax 269ST).';
  END IF;

  SELECT coalesce(sum(n.amount) FILTER (WHERE n.kind = 'CREDIT'),0), coalesce(sum(n.amount) FILTER (WHERE n.kind = 'DEBIT'),0)
    INTO v_cr, v_dr FROM public.lwb_tally_notes n WHERE n.order_id = p_order_id AND n.cancelled_at IS NULL;
  SELECT coalesce(sum(d.cash_reported) FILTER (WHERE coalesce(d.payment_status,'') <> 'REJECTED'),0)
    INTO v_drv FROM public.lwb_delivery_reports d WHERE d.order_id = p_order_id;
  v_due := round(v_bill - v_cr + v_dr - v_drv - public.lwb_order_office_paid(p_order_id), 2);
  IF v_total > v_due + 1 THEN
    RAISE EXCEPTION 'Payment Rs % is more than the money due Rs %', v_total, greatest(v_due,0);
  END IF;

  INSERT INTO public.lwb_tally_payments (receipt_id, order_id, pay_date, mode, amount, ref_no, cash_notes, remark, created_by)
  SELECT v_receipt, p_order_id, p_pay_date, r->>'mode', (r->>'amount')::numeric, r->>'ref',
         CASE WHEN jsonb_typeof(r->'notes') = 'object' THEN r->'notes' END, v_remark, auth.uid()
  FROM jsonb_array_elements(v_rows) r;
  RETURN v_receipt;
END;
$fn$;

-- A wrong receipt is cancelled (all its modes), kept for the record.
CREATE OR REPLACE FUNCTION public.lwb_cancel_tally_payment(p_receipt_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can cancel a payment';
  END IF;
  UPDATE public.lwb_tally_payments SET cancelled_at = now(), cancelled_by = auth.uid()
  WHERE receipt_id = p_receipt_id AND cancelled_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found'; END IF;
  RETURN 'CANCELLED';
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. Money due per PO: same columns as before; Payment Collection is added to
--    "collected" (money in) and "verified", and taken off "due".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_tally_bill_rows(p_days integer)
RETURNS TABLE (order_id uuid, order_no text, party text, status text, order_date date, dispatch_date date,
               invoice_no text, invoice_date date, bill_amount numeric, erp_amount numeric,
               approved_return numeric, pending_return numeric, credit_notes numeric, debit_notes numeric,
               collected numeric, verified numeric, due numeric, credit_pending numeric, delivery text,
               notes jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  WITH o AS (
    SELECT o.id, o.order_no::text AS order_no, btrim(o.customer_name::text) AS party,
           lower(btrim(coalesce(o.status::text,''))) AS status, o.order_date::date AS order_date,
           coalesce((SELECT max(a.loading_completed_at) FROM public.dispatch_assignments a WHERE a.order_id = o.id)
                    AT TIME ZONE 'Asia/Kolkata', o.order_date::timestamp)::date AS dispatch_date
    FROM public.orders o
    WHERE lower(btrim(coalesce(o.status::text,''))) IN ('loaded','invoiced','dispatched','delivered')
      AND o.order_date::date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - least(greatest(coalesce(p_days,120),1),400)
  )
  SELECT o.id, o.order_no, o.party, o.status, o.order_date, o.dispatch_date,
         t.invoice_no, t.invoice_date, t.amount, b.gross, b.approved_return, b.pending_return,
         coalesce(n.cr,0), coalesce(n.dr,0), coalesce(c.got,0) + op.amt, coalesce(c.ok,0) + op.amt,
         round(coalesce(t.amount, b.net + coalesce(n.cr,0)) - coalesce(n.cr,0) + coalesce(n.dr,0) - coalesce(c.got,0) - op.amt, 2),
         greatest(0, round(b.approved_return - coalesce(n.cr,0), 2)),
         coalesce(c.delivery,''),
         coalesce(n.list,'[]'::jsonb)
  FROM o
  CROSS JOIN LATERAL public.lwb_order_bill_numbers(o.id) b
  CROSS JOIN LATERAL (SELECT public.lwb_order_office_paid(o.id) AS amt) op
  LEFT JOIN public.lwb_tally_invoices t ON t.order_id = o.id
  LEFT JOIN LATERAL (
    SELECT sum(x.amount) FILTER (WHERE x.kind = 'CREDIT' AND x.cancelled_at IS NULL) AS cr,
           sum(x.amount) FILTER (WHERE x.kind = 'DEBIT' AND x.cancelled_at IS NULL) AS dr,
           jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'note_no', x.note_no, 'note_date', x.note_date,
                     'amount', x.amount, 'reason', x.reason, 'cancelled', x.cancelled_at IS NOT NULL)
                     ORDER BY x.created_at) AS list
    FROM public.lwb_tally_notes x WHERE x.order_id = o.id) n ON true
  LEFT JOIN LATERAL (
    SELECT sum(d.cash_reported) FILTER (WHERE coalesce(d.payment_status,'') <> 'REJECTED') AS got,
           sum(d.cash_reported) FILTER (WHERE d.payment_status = 'VERIFIED') AS ok,
           max(d.delivery_status::text) AS delivery
    FROM public.lwb_delivery_reports d WHERE d.order_id = o.id) c ON true
  ORDER BY o.dispatch_date DESC, o.party, o.order_no;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_tally_bill_rows(integer) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Bill-wise outstanding: a PO with a Tally bill amount shows one TALLY_BILL row
--    (bill_id = order id) instead of its ERP bill / old invoice. Same columns as before.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_bills()
RETURNS TABLE(
  bill_kind text,
  bill_id uuid,
  bill_no text,
  bill_date date,
  order_id uuid,
  order_no text,
  customer_name text,
  bill_amount numeric,
  return_credit numeric,
  paid_amount numeric,
  pending_amount numeric,
  outstanding_amount numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  WITH tb AS (
    SELECT t.order_id, t.invoice_no, t.invoice_date, t.amount
    FROM public.lwb_tally_invoices t WHERE t.amount IS NOT NULL
  ),
  bills AS (
    SELECT 'ERP_BILL'::text AS kind, b.id, b.internal_bill_no AS no,
           b.bill_date AS dt, b.order_id, b.order_no, b.customer_name,
           b.goods_amount::numeric AS amt
    FROM public.lwb_internal_bills b
    WHERE NOT EXISTS (SELECT 1 FROM tb WHERE tb.order_id = b.order_id)
    UNION ALL
    SELECT 'OLD_INVOICE', i.id, i.invoice_no, i.invoice_date::date,
           i.order_id, o.order_no, o.customer_name,
           COALESCE(i.grand_total,0)::numeric
    FROM public.tax_invoices i
    JOIN public.orders o ON o.id = i.order_id
    WHERE NOT EXISTS (SELECT 1 FROM tb WHERE tb.order_id = i.order_id)
  ),
  pay AS (
    SELECT CASE WHEN c.internal_bill_id IS NOT NULL
                THEN 'ERP_BILL' ELSE 'OLD_INVOICE' END AS kind,
           COALESCE(c.internal_bill_id, c.invoice_id) AS id,
           COALESCE(sum(c.amount) FILTER (WHERE c.status='POSTED'),0) AS posted,
           COALESCE(sum(c.amount) FILTER (WHERE c.status='PENDING'),0) AS pending
    FROM public.lwb_payment_collections c
    GROUP BY 1,2
  ),
  -- the one bill of each order that carries the driver money
  main AS (
    SELECT DISTINCT ON (x.order_id) x.kind, x.id, x.order_id
    FROM bills x WHERE x.order_id IS NOT NULL
    ORDER BY x.order_id, (x.kind = 'ERP_BILL') DESC, x.dt, x.id
  ),
  drv AS (
    SELECT m.kind, m.id, public.lwb_order_driver_received(m.order_id) AS amt
    FROM main m
  ),
  -- Payment Collection money still PENDING on the old bills of a Tally-billed order
  tpend AS (
    SELECT COALESCE(b.order_id, i.order_id) AS order_id, sum(c.amount) AS amt
    FROM public.lwb_payment_collections c
    LEFT JOIN public.lwb_internal_bills b ON b.id = c.internal_bill_id
    LEFT JOIN public.tax_invoices i ON i.id = c.invoice_id
    WHERE c.status = 'PENDING'
    GROUP BY 1
  ),
  tnotes AS (
    SELECT n.order_id,
           COALESCE(sum(n.amount) FILTER (WHERE n.kind = 'CREDIT'),0) AS cr,
           COALESCE(sum(n.amount) FILTER (WHERE n.kind = 'DEBIT'),0) AS dr
    FROM public.lwb_tally_notes n WHERE n.cancelled_at IS NULL
    GROUP BY 1
  ),
  tally AS (
    SELECT tb.order_id, tb.invoice_no, tb.invoice_date, o.order_no::text AS order_no, o.customer_name,
           round(tb.amount + COALESCE(tn.dr,0),2) AS amt,
           round(COALESCE(tn.cr,0),2) AS cr,
           round(public.lwb_order_posted_collections(tb.order_id) + public.lwb_order_driver_received(tb.order_id)
                 + public.lwb_order_office_paid(tb.order_id),2) AS paid,
           round(COALESCE(tp.amt,0),2) AS pending
    FROM tb
    JOIN public.orders o ON o.id = tb.order_id
    LEFT JOIN tnotes tn ON tn.order_id = tb.order_id
    LEFT JOIN tpend tp ON tp.order_id = tb.order_id
  )
  SELECT * FROM (
    SELECT b.kind, b.id, b.no, b.dt, b.order_id, b.order_no,
           btrim(b.customer_name),
           round(b.amt,2),
           public.lwb_order_return_credit(b.order_id),
           round(COALESCE(p.posted,0) + COALESCE(dv.amt,0),2),
           round(COALESCE(p.pending,0),2),
           GREATEST(0, round(
             b.amt - public.lwb_order_return_credit(b.order_id)
                   - COALESCE(p.posted,0) - COALESCE(dv.amt,0)
           ,2))
    FROM bills b
    LEFT JOIN pay p ON p.kind = b.kind AND p.id = b.id
    LEFT JOIN drv dv ON dv.kind = b.kind AND dv.id = b.id
    UNION ALL
    SELECT 'TALLY_BILL', t.order_id, t.invoice_no, t.invoice_date, t.order_id, t.order_no,
           btrim(t.customer_name), t.amt, t.cr, t.paid, t.pending,
           GREATEST(0, round(t.amt - t.cr - t.paid, 2))
    FROM tally t
  ) x
  WHERE public.lwb_ledger_viewer()
  ORDER BY 4 DESC, 3 DESC;
$function$;

REVOKE ALL ON FUNCTION public.lwb_party_bills() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_bills() TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Party ledger: Tally-billed POs by Tally bill, credit / debit notes,
--    driver money and Payment Collection. Other POs exactly as before.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_ledger()
RETURNS TABLE(
  entry_date date,
  entry_kind text,
  customer_name text,
  ref_no text,
  order_no text,
  debit numeric,
  credit numeric,
  note text,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  WITH tb AS (
    SELECT t.order_id, t.invoice_no, t.invoice_date, t.amount, t.entered_at
    FROM public.lwb_tally_invoices t WHERE t.amount IS NOT NULL
  )
  SELECT * FROM (
    SELECT ob.as_of_date, 'OPENING'::text, btrim(ob.customer_name),
           'Opening Balance'::text, NULL::text,
           GREATEST(ob.amount,0)::numeric, GREATEST(-ob.amount,0)::numeric,
           ob.remarks, ob.updated_at
    FROM public.lwb_party_opening_balances ob

    UNION ALL
    SELECT b.bill_date, 'ERP_BILL', btrim(b.customer_name),
           b.internal_bill_no, b.order_no,
           b.goods_amount::numeric, 0::numeric,
           'ERP Internal Bill', b.created_at
    FROM public.lwb_internal_bills b
    WHERE NOT EXISTS (SELECT 1 FROM tb WHERE tb.order_id = b.order_id)

    UNION ALL
    SELECT i.invoice_date::date, 'OLD_INVOICE', btrim(o.customer_name),
           i.invoice_no, o.order_no,
           COALESCE(i.grand_total,0)::numeric, 0::numeric,
           'Old ERP invoice record', NULL::timestamptz
    FROM public.tax_invoices i
    JOIN public.orders o ON o.id = i.order_id
    WHERE NOT EXISTS (SELECT 1 FROM tb WHERE tb.order_id = i.order_id)

    UNION ALL
    SELECT tb.invoice_date, 'TALLY_BILL', btrim(o.customer_name),
           tb.invoice_no, o.order_no,
           tb.amount::numeric, 0::numeric,
           'Tally bill', tb.entered_at
    FROM tb
    JOIN public.orders o ON o.id = tb.order_id

    UNION ALL
    SELECT n.note_date, CASE WHEN n.kind = 'CREDIT' THEN 'CREDIT_NOTE' ELSE 'DEBIT_NOTE' END,
           btrim(o.customer_name), n.note_no, o.order_no,
           CASE WHEN n.kind = 'DEBIT' THEN n.amount ELSE 0 END::numeric,
           CASE WHEN n.kind = 'CREDIT' THEN n.amount ELSE 0 END::numeric,
           COALESCE(n.reason, CASE WHEN n.kind = 'CREDIT' THEN 'Credit note' ELSE 'Debit note' END)
             || ' · Tally bill ' || tb.invoice_no,
           n.created_at
    FROM public.lwb_tally_notes n
    JOIN tb ON tb.order_id = n.order_id
    JOIN public.orders o ON o.id = n.order_id
    WHERE n.cancelled_at IS NULL

    UNION ALL
    SELECT c.collection_date, 'PAYMENT',
           btrim(COALESCE(b.customer_name, o.customer_name)),
           c.payment_mode || COALESCE(' ' || NULLIF(btrim(c.reference_no),''),''),
           COALESCE(b.order_no, o.order_no),
           0::numeric, c.amount::numeric,
           'Against ' || COALESCE(b.internal_bill_no, i.invoice_no),
           c.reviewed_at
    FROM public.lwb_payment_collections c
    LEFT JOIN public.lwb_internal_bills b ON b.id = c.internal_bill_id
    LEFT JOIN public.tax_invoices i ON i.id = c.invoice_id
    LEFT JOIN public.orders o ON o.id = i.order_id
    WHERE c.status = 'POSTED'

    UNION ALL
    SELECT p.pay_date, 'OFFICE_PAYMENT', btrim(o.customer_name),
           p.mode || COALESCE(' ' || NULLIF(btrim(p.ref_no),''),''), o.order_no,
           0::numeric, p.amount::numeric,
           'Payment Collection · Tally bill ' || COALESCE(t.invoice_no,'') || COALESCE(' · ' || p.remark,''),
           p.created_at
    FROM public.lwb_tally_payments p
    JOIN public.orders o ON o.id = p.order_id
    LEFT JOIN public.lwb_tally_invoices t ON t.order_id = p.order_id
    WHERE p.cancelled_at IS NULL

    UNION ALL
    SELECT timezone('Asia/Kolkata', COALESCE(d.payment_reviewed_at, d.reported_at))::date, 'DRIVER_PAYMENT',
           btrim(COALESCE(b.customer_name, o.customer_name)),
           COALESCE(NULLIF(d.payment_mode,''), 'CASH')
             || COALESCE(' ' || NULLIF(btrim(COALESCE(d.bank_ref, d.online_reference, d.payment_reference)),''),''),
           o.order_no,
           0::numeric, d.cash_reported::numeric,
           'Driver ' || COALESCE(NULLIF(btrim(dp.full_name),''), 'payment')
             || ', received by ' || COALESCE(NULLIF(btrim(rp.full_name),''), 'office'),
           d.payment_reviewed_at
    FROM public.lwb_delivery_reports d
    JOIN public.orders o ON o.id = d.order_id
    LEFT JOIN public.lwb_internal_bills b ON b.order_id = d.order_id
    LEFT JOIN public.user_profiles dp ON dp.id = d.driver_user_id
    LEFT JOIN public.user_profiles rp ON rp.id = d.payment_reviewed_by
    WHERE d.payment_status = 'VERIFIED' AND d.cash_reported > 0
      AND (b.id IS NOT NULL OR EXISTS (SELECT 1 FROM public.tax_invoices t WHERE t.order_id = d.order_id)
           OR EXISTS (SELECT 1 FROM tb WHERE tb.order_id = d.order_id))

    UNION ALL
    SELECT COALESCE(r.reviewed_at, r.created_at)::date, 'DRIVER_RETURN',
           btrim(o.customer_name), 'Driver return', o.order_no,
           0::numeric, r.total_return_amount::numeric,
           'Office approved driver return', r.reviewed_at
    FROM public.lwb_driver_delivery_returns r
    JOIN public.orders o ON o.id = r.order_id
    WHERE r.status = 'APPROVED' AND r.total_return_amount > 0
      AND NOT EXISTS (SELECT 1 FROM tb WHERE tb.order_id = r.order_id)

    UNION ALL
    SELECT s.return_date::date, 'SALES_RETURN', btrim(o.customer_name),
           s.return_no, o.order_no,
           0::numeric, COALESCE(s.total_amount,0)::numeric,
           'Admin approved sales return', NULL::timestamptz
    FROM public.sales_returns s
    JOIN public.orders o ON o.id = s.order_id
    WHERE lower(btrim(COALESCE(s.approval_status,''))) = 'approved'
      AND COALESCE(s.total_amount,0) > 0
      AND NOT EXISTS (SELECT 1 FROM tb WHERE tb.order_id = s.order_id)
  ) e
  WHERE public.lwb_ledger_viewer();
$function$;

REVOKE ALL ON FUNCTION public.lwb_party_ledger() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_ledger() TO authenticated;

REVOKE ALL ON FUNCTION public.lwb_save_tally_payment(uuid,date,jsonb,text), public.lwb_cancel_tally_payment(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_save_tally_payment(uuid,date,jsonb,text), public.lwb_cancel_tally_payment(uuid)
  TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'payment collection table' AS item, (to_regclass('public.lwb_tally_payments') IS NOT NULL)::text AS ok
UNION ALL SELECT 'save payment', (to_regprocedure('public.lwb_save_tally_payment(uuid,date,jsonb,text)') IS NOT NULL)::text
UNION ALL SELECT 'cancel payment', (to_regprocedure('public.lwb_cancel_tally_payment(uuid)') IS NOT NULL)::text
UNION ALL SELECT 'party ledger', (to_regprocedure('public.lwb_party_ledger()') IS NOT NULL)::text;
