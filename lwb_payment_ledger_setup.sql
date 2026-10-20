-- LUXURY WRIST BRAND - Payment collection and invoice outstanding (Phase 1).
-- RUN ONCE in Supabase SQL Editor. Safe for existing orders and invoices.
-- This is an INDEPENDENT ERP ledger. Tally is an entirely separate system.
-- No Tally import, copy/paste, invoice-number matching or sync is required.
-- NO invoice, order or inventory rows are modified.
-- Original returns and credit-note adjustments will be linked in the next phase.
BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_payment_collections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id uuid NOT NULL REFERENCES public.tax_invoices(id) ON DELETE RESTRICT,
  collection_date date NOT NULL DEFAULT current_date,
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  payment_mode text NOT NULL CHECK (payment_mode IN ('CASH','BANK','UPI','CHEQUE','OTHER')),
  reference_no text,
  remarks text,
  status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','POSTED','REJECTED')),
  submitted_by uuid NOT NULL DEFAULT auth.uid(),
  submitted_at timestamptz NOT NULL DEFAULT now(),
  reviewed_by uuid,
  reviewed_at timestamptz,
  review_note text
);

CREATE INDEX IF NOT EXISTS lwb_payment_collections_invoice_idx
  ON public.lwb_payment_collections(invoice_id,status);
CREATE INDEX IF NOT EXISTS lwb_payment_collections_status_date_idx
  ON public.lwb_payment_collections(status,submitted_at DESC);

-- One bank/UPI/cheque reference cannot be reused, except after a rejection.
-- CASH may be entered multiple times, each with its own receipt record.
CREATE UNIQUE INDEX IF NOT EXISTS lwb_payment_collections_electronic_ref_uidx
  ON public.lwb_payment_collections(payment_mode,upper(btrim(reference_no)))
  WHERE reference_no IS NOT NULL AND btrim(reference_no) <> ''
    AND payment_mode IN ('BANK','UPI','CHEQUE')
    AND status <> 'REJECTED';

ALTER TABLE public.lwb_payment_collections ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lwb_collections_active_read ON public.lwb_payment_collections;
CREATE POLICY lwb_collections_active_read
  ON public.lwb_payment_collections FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles p
      WHERE p.id=auth.uid() AND p.active=true
      AND lower(btrim(p.role)) IN ('admin','accounts','manager','sales','salesman','collector')
    )
  );

DROP POLICY IF EXISTS lwb_collections_submit ON public.lwb_payment_collections;
CREATE POLICY lwb_collections_submit
  ON public.lwb_payment_collections FOR INSERT TO authenticated
  WITH CHECK (
    submitted_by=auth.uid() AND status='PENDING'
    AND reviewed_by IS NULL AND reviewed_at IS NULL
    AND EXISTS (
      SELECT 1 FROM public.user_profiles p
      WHERE p.id=auth.uid() AND p.active=true
      AND lower(btrim(p.role)) IN ('admin','manager','sales','salesman','collector')
    )
  );

-- Accounts is read-only; no direct UPDATE or DELETE grants.
-- Do NOT grant UPDATE or DELETE: only Admin verification RPC may post/reject.
REVOKE ALL ON TABLE public.lwb_payment_collections FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT ON TABLE public.lwb_payment_collections TO authenticated;

-- Outstanding reflects only ADMIN-VERIFIED / POSTED receipts. Pending collections have no effect.
-- Approved return credits are NOT included until Phase 2.
CREATE OR REPLACE VIEW public.lwb_invoice_outstanding
WITH (security_invoker = true) AS
SELECT i.id AS invoice_id,
       i.order_id,
       i.invoice_no,
       i.invoice_date,
       o.order_no,
       o.customer_name,
       COALESCE(i.payment_terms,'CREDIT') AS payment_terms,
       COALESCE(i.grand_total,0)::numeric(14,2) AS invoice_amount,
       COALESCE(p.posted_amount,0)::numeric(14,2) AS paid_amount,
       GREATEST(
         0,
         COALESCE(i.grand_total,0)-COALESCE(p.posted_amount,0)
       )::numeric(14,2) AS outstanding_amount
FROM public.tax_invoices i
JOIN public.orders o ON o.id=i.order_id
LEFT JOIN (
 SELECT invoice_id,sum(amount) AS posted_amount
 FROM public.lwb_payment_collections
 WHERE status='POSTED'
 GROUP BY invoice_id
) p ON p.invoice_id=i.id;

REVOKE ALL ON TABLE public.lwb_invoice_outstanding FROM PUBLIC,anon;
GRANT SELECT ON TABLE public.lwb_invoice_outstanding TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_review_collection(
  p_collection_id uuid,
  p_action text,
  p_note text DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  v_receipt public.lwb_payment_collections%ROWTYPE;
  v_invoice_amount numeric(14,2);
  v_paid numeric(14,2);
  v_remaining numeric(14,2);
  v_action text := upper(btrim(COALESCE(p_action,'')));
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id=auth.uid() AND active=true
    AND lower(btrim(role)) IN ('admin')
  ) THEN
    RAISE EXCEPTION 'Only an active Admin can verify a collection. Accounts is view-only.';
  END IF;
  IF v_action NOT IN ('POST','REJECT') THEN
    RAISE EXCEPTION 'Review action must be POST or REJECT';
  END IF;

  SELECT * INTO v_receipt FROM public.lwb_payment_collections
   WHERE id=p_collection_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Collection not found'; END IF;
  IF v_receipt.status<>'PENDING' THEN
    RAISE EXCEPTION 'Collection was already reviewed';
  END IF;

  IF v_action='REJECT' THEN
    IF length(btrim(COALESCE(p_note,''))) < 3 THEN
      RAISE EXCEPTION 'Rejection reason is required';
    END IF;
    UPDATE public.lwb_payment_collections
      SET status='REJECTED',reviewed_by=auth.uid(),reviewed_at=now(),
          review_note=btrim(p_note)
      WHERE id=p_collection_id;
    RETURN NULL;
  END IF;

  -- Serialize posting for *all* receipts on the same invoice.
  SELECT grand_total INTO v_invoice_amount
  FROM public.tax_invoices WHERE id=v_receipt.invoice_id FOR UPDATE;
  IF NOT FOUND OR v_invoice_amount IS NULL OR v_invoice_amount<=0 THEN
    RAISE EXCEPTION 'ERP invoice record has no valid grand total';
  END IF;
  SELECT COALESCE(sum(amount),0) INTO v_paid
  FROM public.lwb_payment_collections
  WHERE invoice_id=v_receipt.invoice_id AND status='POSTED';

  v_remaining:=round(v_invoice_amount-v_paid,2);
  IF v_remaining<=0 OR v_receipt.amount>v_remaining THEN
    RAISE EXCEPTION 'Payment exceeds unpaid invoice amount (remaining: %)',v_remaining;
  END IF;
  UPDATE public.lwb_payment_collections
    SET status='POSTED',reviewed_by=auth.uid(),reviewed_at=now(),
        review_note=NULLIF(btrim(COALESCE(p_note,'')),'')
  WHERE id=p_collection_id;
  RETURN round(v_remaining-v_receipt.amount,2);
END;
$$;

REVOKE ALL ON FUNCTION public.lwb_review_collection(uuid,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lwb_review_collection(uuid,text,text) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Read-only setup confirmation:
SELECT table_name
FROM information_schema.tables
WHERE table_schema='public'
AND table_name IN ('lwb_payment_collections','lwb_invoice_outstanding')
ORDER BY table_name;
