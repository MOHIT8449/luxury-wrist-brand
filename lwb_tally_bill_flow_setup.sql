-- LUXURY WRIST BRAND ERP — TALLY BILL AMOUNT, CREDIT / DEBIT NOTES, MONEY DUE PER INVOICE
--
-- RUN ONCE in Supabase SQL Editor, after lwb_loading_workflow_setup.sql, lwb_driver_payment_setup.sql
-- and lwb_cashbook_secure_setup.sql. Safe to run again.
--
-- 1. Accounts enters the Tally invoice no. + bill AMOUNT after the vehicle is loaded
--    (= bill made in Tally and the full bill handed to the driver).
-- 2. Credit note / Debit note made in Tally is noted against that invoice (no., date, amount, reason).
--    A return approved on Driver Returns asks for a credit note.
-- 3. Money due per invoice = bill amount - credit notes + debit notes - money the driver reported.
--    Accounts / Admin see it on "Tally Bill & Invoice No."; the Cashbook sees it (code word as usual).
--
-- Nothing is posted to Tally, the party ledger, stock or GST here. Tally stays separate.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Bill amount on the Tally invoice row
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_tally_invoices
  ADD COLUMN IF NOT EXISTS amount numeric(14,2) CHECK (amount IS NULL OR amount > 0);

CREATE OR REPLACE FUNCTION public.lwb_tally_staff()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin'));
$fn$;

-- Same checks and notifications as lwb_save_tally_invoice, plus the amount (required).
CREATE OR REPLACE FUNCTION public.lwb_save_tally_bill(p_order_id uuid, p_invoice_no text, p_invoice_date date,
                                                      p_amount numeric, p_note text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_res text;
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can enter the Tally bill';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount > 100000000 THEN
    RAISE EXCEPTION 'Enter the Tally bill amount';
  END IF;
  v_res := public.lwb_save_tally_invoice(p_order_id, p_invoice_no, p_invoice_date, p_note);
  UPDATE public.lwb_tally_invoices SET amount = round(p_amount, 2) WHERE order_id = p_order_id;
  RETURN v_res;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. Credit / Debit notes against a Tally invoice
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_tally_notes (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id     uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  kind         text NOT NULL CHECK (kind IN ('CREDIT','DEBIT')),
  note_no      text NOT NULL CHECK (length(btrim(note_no)) BETWEEN 1 AND 100),
  note_date    date NOT NULL,
  amount       numeric(14,2) NOT NULL CHECK (amount > 0),
  reason       text CHECK (reason IS NULL OR length(reason) <= 300),
  created_by   uuid NOT NULL REFERENCES auth.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  cancelled_by uuid REFERENCES auth.users(id),
  cancelled_at timestamptz
);
CREATE INDEX IF NOT EXISTS lwb_tally_notes_order_idx ON public.lwb_tally_notes(order_id);
ALTER TABLE public.lwb_tally_notes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_tally_notes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_tally_notes TO authenticated;
DROP POLICY IF EXISTS lwb_tally_notes_read ON public.lwb_tally_notes;
CREATE POLICY lwb_tally_notes_read ON public.lwb_tally_notes FOR SELECT TO authenticated
  USING (public.lwb_tally_staff());

CREATE OR REPLACE FUNCTION public.lwb_save_tally_note(p_order_id uuid, p_kind text, p_note_no text, p_note_date date,
                                                      p_amount numeric, p_reason text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_kind text := upper(btrim(coalesce(p_kind,'')));
  v_no text := btrim(coalesce(p_note_no,''));
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
  v_id uuid;
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can enter a credit / debit note';
  END IF;
  IF v_kind NOT IN ('CREDIT','DEBIT') THEN RAISE EXCEPTION 'Choose Credit note or Debit note'; END IF;
  IF v_no = '' OR length(v_no) > 100 THEN RAISE EXCEPTION 'Enter the Tally note number'; END IF;
  IF p_note_date IS NULL OR p_note_date > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1 THEN
    RAISE EXCEPTION 'Enter a valid note date';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount > 100000000 THEN RAISE EXCEPTION 'Enter the note amount'; END IF;
  IF length(coalesce(v_reason,'')) > 300 THEN RAISE EXCEPTION 'Reason is too long'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_tally_invoices WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'Enter the Tally invoice no. of this PO first';
  END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_tally_notes WHERE order_id = p_order_id AND kind = v_kind
             AND upper(note_no) = upper(v_no) AND cancelled_at IS NULL) THEN
    RAISE EXCEPTION 'This note number is already entered for this PO';
  END IF;
  INSERT INTO public.lwb_tally_notes (order_id, kind, note_no, note_date, amount, reason, created_by)
  VALUES (p_order_id, v_kind, v_no, p_note_date, round(p_amount, 2), v_reason, auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$fn$;

-- A wrong note is cancelled (kept for the record), never deleted.
CREATE OR REPLACE FUNCTION public.lwb_cancel_tally_note(p_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can cancel a note';
  END IF;
  UPDATE public.lwb_tally_notes SET cancelled_at = now(), cancelled_by = auth.uid()
  WHERE id = p_id AND cancelled_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Note not found'; END IF;
  RETURN 'CANCELLED';
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. One row per loaded PO: Tally bill, returns, notes, money in, money due
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
         coalesce(n.cr,0), coalesce(n.dr,0), coalesce(c.got,0), coalesce(c.ok,0),
         round(coalesce(t.amount, b.net + coalesce(n.cr,0)) - coalesce(n.cr,0) + coalesce(n.dr,0) - coalesce(c.got,0), 2),
         greatest(0, round(b.approved_return - coalesce(n.cr,0), 2)),
         coalesce(c.delivery,''),
         coalesce(n.list,'[]'::jsonb)
  FROM o
  CROSS JOIN LATERAL public.lwb_order_bill_numbers(o.id) b
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

-- Accounts / Admin
CREATE OR REPLACE FUNCTION public.lwb_tally_bill_status(p_days integer DEFAULT 120)
RETURNS SETOF jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Active Admin / Accounts role required.';
  END IF;
  RETURN QUERY SELECT to_jsonb(r) FROM public.lwb_tally_bill_rows(p_days) r;
END;
$fn$;

-- Cashbook: invoices with money still to collect (Tally invoice no. entered, due > Rs 1)
CREATE OR REPLACE FUNCTION public.lwb_cashbook_invoice_due(p_key text)
RETURNS SETOF jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  RETURN QUERY
  SELECT jsonb_build_object('order_id', r.order_id, 'order_no', r.order_no, 'party', r.party,
           'invoice_no', r.invoice_no, 'invoice_date', r.invoice_date, 'bill_amount', r.bill_amount,
           'credit_notes', r.credit_notes, 'debit_notes', r.debit_notes, 'collected', r.collected,
           'due', r.due, 'status', r.status, 'delivery', r.delivery)
  FROM public.lwb_tally_bill_rows(180) r
  WHERE r.invoice_no IS NOT NULL AND r.due > 1;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_tally_staff(), public.lwb_save_tally_bill(uuid,text,date,numeric,text),
  public.lwb_save_tally_note(uuid,text,text,date,numeric,text), public.lwb_cancel_tally_note(uuid),
  public.lwb_tally_bill_status(integer), public.lwb_cashbook_invoice_due(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_tally_staff(), public.lwb_save_tally_bill(uuid,text,date,numeric,text),
  public.lwb_save_tally_note(uuid,text,text,date,numeric,text), public.lwb_cancel_tally_note(uuid),
  public.lwb_tally_bill_status(integer), public.lwb_cashbook_invoice_due(text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'bill amount column' AS item,
  EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
          AND table_name = 'lwb_tally_invoices' AND column_name = 'amount')::text AS ok
UNION ALL SELECT 'credit / debit notes table', (to_regclass('public.lwb_tally_notes') IS NOT NULL)::text
UNION ALL SELECT 'save bill', (to_regprocedure('public.lwb_save_tally_bill(uuid,text,date,numeric,text)') IS NOT NULL)::text
UNION ALL SELECT 'bill status', (to_regprocedure('public.lwb_tally_bill_status(integer)') IS NOT NULL)::text
UNION ALL SELECT 'cashbook money due', (to_regprocedure('public.lwb_cashbook_invoice_due(text)') IS NOT NULL)::text;
