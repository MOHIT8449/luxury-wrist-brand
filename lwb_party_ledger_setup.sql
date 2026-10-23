-- LUXURY WRIST BRAND ERP — PARTY LEDGER & OUTSTANDING (Phase 2)
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
-- Needs lwb_internal_bill_setup.sql (already live). It ALSO creates the
-- Phase 1 payment tables from lwb_payment_ledger_setup.sql if they are
-- missing, so that older file does not need to be run separately.
--
-- What it adds:
--  1. Payment collections can now be entered against an ERP Internal Bill
--     (LWB-EB-...) as well as an old ERP invoice record (tax_invoices).
--  2. Optional party Opening Balance (before ERP start). Empty = ledger
--     starts from zero. Only Admin can set it, through an RPC.
--  3. lwb_party_bills(): bill-wise outstanding for ERP bills + old invoices
--     = bill amount − approved returns − Admin-POSTED payments.
--  4. lwb_party_ledger(): party-wise ledger entries (debit / credit).
--  5. lwb_review_collection() now checks the remaining amount of either kind
--     of bill, after approved returns.
--
-- Still an INDEPENDENT ERP ledger: no Tally import, sync or GST invoice.
-- NO order, order item, stock, bill, invoice or return row is modified.
-- PENDING / REJECTED collections and PENDING returns never affect balances.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Phase 1 payment collection table + invoice outstanding view
--    (same as lwb_payment_ledger_setup.sql; skipped if already present)
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 1. Collections against ERP Internal Bills
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_payment_collections
  ADD COLUMN IF NOT EXISTS internal_bill_id uuid
  REFERENCES public.lwb_internal_bills(id) ON DELETE RESTRICT;

ALTER TABLE public.lwb_payment_collections
  ALTER COLUMN invoice_id DROP NOT NULL;

-- Every collection belongs to exactly one bill: old invoice OR ERP bill.
ALTER TABLE public.lwb_payment_collections
  DROP CONSTRAINT IF EXISTS lwb_payment_collections_one_bill_chk;
ALTER TABLE public.lwb_payment_collections
  ADD CONSTRAINT lwb_payment_collections_one_bill_chk
  CHECK (num_nonnulls(invoice_id, internal_bill_id) = 1);

CREATE INDEX IF NOT EXISTS lwb_payment_collections_internal_bill_idx
  ON public.lwb_payment_collections(internal_bill_id,status);

-- ---------------------------------------------------------------------------
-- 2. Party opening balance (optional)
-- ---------------------------------------------------------------------------
-- amount > 0 : party owes us (debit). amount < 0 : party advance (credit).
CREATE TABLE IF NOT EXISTS public.lwb_party_opening_balances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_name text NOT NULL,
  as_of_date date NOT NULL,
  amount numeric(14,2) NOT NULL CHECK (amount <> 0),
  remarks text,
  updated_by uuid NOT NULL REFERENCES auth.users(id),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS lwb_party_opening_balances_party_uidx
  ON public.lwb_party_opening_balances(upper(btrim(customer_name)));

ALTER TABLE public.lwb_party_opening_balances ENABLE ROW LEVEL SECURITY;
-- No direct table access. Read through lwb_party_ledger(), write through
-- lwb_set_party_opening_balance().
REVOKE ALL ON TABLE public.lwb_party_opening_balances
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_ledger_viewer()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN
        ('admin','accounts','manager','sales','salesman','collector')
  );
$function$;

REVOKE ALL ON FUNCTION public.lwb_ledger_viewer() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_ledger_viewer() TO authenticated;

-- Approved return credit for one order: driver returns approved by office
-- + sales returns approved by Admin. Internal use only (no grant).
CREATE OR REPLACE FUNCTION public.lwb_order_return_credit(p_order_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT round(
    COALESCE((
      SELECT sum(r.total_return_amount)
      FROM public.lwb_driver_delivery_returns r
      WHERE r.order_id = p_order_id AND r.status = 'APPROVED'
    ),0)
    + COALESCE((
      SELECT sum(COALESCE(s.total_amount,0))
      FROM public.sales_returns s
      WHERE s.order_id = p_order_id
        AND lower(btrim(COALESCE(s.approval_status,''))) = 'approved'
    ),0)
  ,2);
$function$;

REVOKE ALL ON FUNCTION public.lwb_order_return_credit(uuid)
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Bill-wise outstanding (ERP bills + old invoices)
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
  WITH bills AS (
    SELECT 'ERP_BILL'::text AS kind, b.id, b.internal_bill_no AS no,
           b.bill_date AS dt, b.order_id, b.order_no, b.customer_name,
           b.goods_amount::numeric AS amt
    FROM public.lwb_internal_bills b
    UNION ALL
    SELECT 'OLD_INVOICE', i.id, i.invoice_no, i.invoice_date::date,
           i.order_id, o.order_no, o.customer_name,
           COALESCE(i.grand_total,0)::numeric
    FROM public.tax_invoices i
    JOIN public.orders o ON o.id = i.order_id
  ),
  pay AS (
    SELECT CASE WHEN c.internal_bill_id IS NOT NULL
                THEN 'ERP_BILL' ELSE 'OLD_INVOICE' END AS kind,
           COALESCE(c.internal_bill_id, c.invoice_id) AS id,
           COALESCE(sum(c.amount) FILTER (WHERE c.status='POSTED'),0) AS posted,
           COALESCE(sum(c.amount) FILTER (WHERE c.status='PENDING'),0) AS pending
    FROM public.lwb_payment_collections c
    GROUP BY 1,2
  )
  SELECT b.kind, b.id, b.no, b.dt, b.order_id, b.order_no,
         btrim(b.customer_name),
         round(b.amt,2),
         public.lwb_order_return_credit(b.order_id),
         round(COALESCE(p.posted,0),2),
         round(COALESCE(p.pending,0),2),
         GREATEST(0, round(
           b.amt - public.lwb_order_return_credit(b.order_id)
                 - COALESCE(p.posted,0)
         ,2))
  FROM bills b
  LEFT JOIN pay p ON p.kind = b.kind AND p.id = b.id
  WHERE public.lwb_ledger_viewer()
  ORDER BY b.dt DESC, b.no DESC;
$function$;

REVOKE ALL ON FUNCTION public.lwb_party_bills() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_bills() TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Party ledger entries
-- ---------------------------------------------------------------------------
-- debit = party owes more, credit = party owes less.
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

    UNION ALL
    SELECT i.invoice_date::date, 'OLD_INVOICE', btrim(o.customer_name),
           i.invoice_no, o.order_no,
           COALESCE(i.grand_total,0)::numeric, 0::numeric,
           'Old ERP invoice record', NULL::timestamptz
    FROM public.tax_invoices i
    JOIN public.orders o ON o.id = i.order_id

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
    SELECT COALESCE(r.reviewed_at, r.created_at)::date, 'DRIVER_RETURN',
           btrim(o.customer_name), 'Driver return', o.order_no,
           0::numeric, r.total_return_amount::numeric,
           'Office approved driver return', r.reviewed_at
    FROM public.lwb_driver_delivery_returns r
    JOIN public.orders o ON o.id = r.order_id
    WHERE r.status = 'APPROVED' AND r.total_return_amount > 0

    UNION ALL
    SELECT s.return_date::date, 'SALES_RETURN', btrim(o.customer_name),
           s.return_no, o.order_no,
           0::numeric, COALESCE(s.total_amount,0)::numeric,
           'Admin approved sales return', NULL::timestamptz
    FROM public.sales_returns s
    JOIN public.orders o ON o.id = s.order_id
    WHERE lower(btrim(COALESCE(s.approval_status,''))) = 'approved'
      AND COALESCE(s.total_amount,0) > 0
  ) e
  WHERE public.lwb_ledger_viewer();
$function$;

REVOKE ALL ON FUNCTION public.lwb_party_ledger() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_ledger() TO authenticated;

-- Admin sets / changes / clears (amount 0) one party's opening balance.
CREATE OR REPLACE FUNCTION public.lwb_set_party_opening_balance(
  p_customer_name text,
  p_amount numeric,
  p_as_of_date date,
  p_remarks text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_name text := btrim(COALESCE(p_customer_name,''));
  v_amount numeric(14,2) := round(COALESCE(p_amount,0),2);
  v_master_name text;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND active = true AND lower(btrim(role)) = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only an active Admin can set an Opening Balance';
  END IF;
  IF v_name = '' THEN
    RAISE EXCEPTION 'Select a party';
  END IF;
  -- Keep the party name exactly as written in Customer Master.
  SELECT btrim(m.customer_name) INTO v_master_name
  FROM public.lwb_customer_master m
  WHERE upper(btrim(m.customer_name)) = upper(v_name)
  LIMIT 1;
  v_name := COALESCE(v_master_name, v_name);
  IF v_master_name IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.orders o
    WHERE upper(btrim(o.customer_name)) = upper(v_name)
  ) THEN
    RAISE EXCEPTION 'Party % not found in Customer Master or orders', v_name;
  END IF;

  IF v_amount = 0 THEN
    DELETE FROM public.lwb_party_opening_balances
    WHERE upper(btrim(customer_name)) = upper(v_name);
    RETURN;
  END IF;
  IF p_as_of_date IS NULL THEN
    RAISE EXCEPTION 'Opening Balance date is required';
  END IF;

  INSERT INTO public.lwb_party_opening_balances(
    customer_name, as_of_date, amount, remarks, updated_by
  ) VALUES (
    v_name, p_as_of_date, v_amount,
    NULLIF(btrim(COALESCE(p_remarks,'')),''), auth.uid()
  )
  ON CONFLICT ((upper(btrim(customer_name)))) DO UPDATE
    SET as_of_date = EXCLUDED.as_of_date,
        amount = EXCLUDED.amount,
        remarks = EXCLUDED.remarks,
        updated_by = EXCLUDED.updated_by,
        updated_at = now();
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_set_party_opening_balance(text,numeric,date,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_party_opening_balance(text,numeric,date,text)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Admin POST / REJECT for both kinds of bill (same signature as before)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_review_collection(
  p_collection_id uuid,
  p_action text,
  p_note text DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_receipt public.lwb_payment_collections%ROWTYPE;
  v_order_id uuid;
  v_bill_amount numeric(14,2);
  v_paid numeric(14,2);
  v_remaining numeric(14,2);
  v_action text := upper(btrim(COALESCE(p_action,'')));
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND active = true AND lower(btrim(role)) = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only an active Admin can verify a collection. Accounts is view-only.';
  END IF;
  IF v_action NOT IN ('POST','REJECT') THEN
    RAISE EXCEPTION 'Review action must be POST or REJECT';
  END IF;

  SELECT * INTO v_receipt FROM public.lwb_payment_collections
   WHERE id = p_collection_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Collection not found'; END IF;
  IF v_receipt.status <> 'PENDING' THEN
    RAISE EXCEPTION 'Collection was already reviewed';
  END IF;

  IF v_action = 'REJECT' THEN
    IF length(btrim(COALESCE(p_note,''))) < 3 THEN
      RAISE EXCEPTION 'Rejection reason is required';
    END IF;
    UPDATE public.lwb_payment_collections
      SET status = 'REJECTED', reviewed_by = auth.uid(), reviewed_at = now(),
          review_note = btrim(p_note)
      WHERE id = p_collection_id;
    RETURN NULL;
  END IF;

  -- Lock the bill so receipts on the same bill post one at a time.
  IF v_receipt.internal_bill_id IS NOT NULL THEN
    SELECT b.goods_amount, b.order_id INTO v_bill_amount, v_order_id
    FROM public.lwb_internal_bills b
    WHERE b.id = v_receipt.internal_bill_id FOR UPDATE;
  ELSE
    SELECT i.grand_total, i.order_id INTO v_bill_amount, v_order_id
    FROM public.tax_invoices i
    WHERE i.id = v_receipt.invoice_id FOR UPDATE;
  END IF;
  IF NOT FOUND OR v_bill_amount IS NULL OR v_bill_amount <= 0 THEN
    RAISE EXCEPTION 'ERP bill / invoice record has no valid amount';
  END IF;

  SELECT COALESCE(sum(c.amount),0) INTO v_paid
  FROM public.lwb_payment_collections c
  WHERE c.status = 'POSTED'
    AND c.internal_bill_id IS NOT DISTINCT FROM v_receipt.internal_bill_id
    AND c.invoice_id IS NOT DISTINCT FROM v_receipt.invoice_id;

  v_remaining := round(
    v_bill_amount - public.lwb_order_return_credit(v_order_id) - v_paid, 2);
  IF v_remaining <= 0 OR v_receipt.amount > v_remaining THEN
    RAISE EXCEPTION 'Payment exceeds unpaid bill amount after returns (remaining: %)', v_remaining;
  END IF;

  UPDATE public.lwb_payment_collections
    SET status = 'POSTED', reviewed_by = auth.uid(), reviewed_at = now(),
        review_note = NULLIF(btrim(COALESCE(p_note,'')),'')
  WHERE id = p_collection_id;
  RETURN round(v_remaining - v_receipt.amount, 2);
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_review_collection(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_review_collection(uuid,text,text) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Read-only confirmation, expect 5 rows:
SELECT p.proname AS ready
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('lwb_party_bills','lwb_party_ledger',
    'lwb_set_party_opening_balance','lwb_review_collection',
    'lwb_order_return_credit')
ORDER BY 1;
