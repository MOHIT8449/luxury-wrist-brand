-- LUXURY WRIST BRAND ERP | ONE-CLICK INTERNAL BILL
--
-- RUN ONCE IN SUPABASE SQL EDITOR after checking this script.
-- A real Tally/GST invoice will STILL be created separately by Accounts.
-- NO Tally bill number / date required in ERP.
-- NO changes to orders, order_items, inventory, tax_invoices,
-- payment collections, or existing ledger views.
--
-- Internal bill record is created from ACTUAL LOADED quantities and PO rates.
-- One internal bill per PO, enforced in PostgreSQL (including parallel clicks).
-- Active accounts or admin users can CREATE this record ONLY.
-- It is not a legal GST invoice and is NOT connected to collections/outstanding yet.

BEGIN;

CREATE SEQUENCE IF NOT EXISTS public.lwb_internal_bill_no_seq
  START WITH 1 INCREMENT BY 1;

CREATE TABLE IF NOT EXISTS public.lwb_internal_bills (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  internal_bill_no text NOT NULL UNIQUE
    DEFAULT ('LWB-EB-' || lpad(nextval('public.lwb_internal_bill_no_seq')::text,6,'0')),
  bill_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata')::date),
  order_no text NOT NULL,
  customer_name text NOT NULL,
  loaded_qty numeric(16,3) NOT NULL CHECK (loaded_qty > 0),
  goods_amount numeric(16,2) NOT NULL CHECK (goods_amount >= 0),
  items jsonb NOT NULL CHECK (jsonb_typeof(items) = 'array'),
  created_by uuid NOT NULL REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lwb_internal_bills_order_unique UNIQUE(order_id)
);

CREATE INDEX IF NOT EXISTS lwb_internal_bills_created_at_idx
  ON public.lwb_internal_bills(created_at DESC);

ALTER TABLE public.lwb_internal_bills ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lwb_internal_bill_read ON public.lwb_internal_bills;
CREATE POLICY lwb_internal_bill_read
 ON public.lwb_internal_bills FOR SELECT TO authenticated
 USING (
   EXISTS (
     SELECT 1 FROM public.user_profiles p
     WHERE p.id=auth.uid()
       AND p.active IS TRUE
       AND lower(btrim(p.role)) IN ('admin','accounts')
   )
 );

-- No direct INSERT/UPDATE/DELETE grant. All bill creation passes through
-- the checked, atomic SECURITY DEFINER function below.
REVOKE ALL ON TABLE public.lwb_internal_bills FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_internal_bills TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_create_internal_bill(
  p_order_id uuid
)
RETURNS TABLE(
  bill_id uuid,
  bill_no text,
  bill_date date,
  order_id uuid,
  customer_name text,
  loaded_qty numeric,
  bill_amount numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_order public.orders%ROWTYPE;
  v_bill public.lwb_internal_bills%ROWTYPE;
  v_qty numeric(16,3);
  v_amount numeric(16,2);
  v_items jsonb;
  v_line_count integer;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.user_profiles p
    WHERE p.id=auth.uid()
      AND p.active IS TRUE
      AND lower(btrim(p.role)) IN ('admin','accounts')
  ) THEN
    RAISE EXCEPTION 'Active Accounts / Admin role required to create an internal ERP bill';
  END IF;

  IF p_order_id IS NULL THEN
    RAISE EXCEPTION 'Select an approved, loaded PO first';
  END IF;

  -- Serialization protects against concurrent duplicate submissions.
  SELECT o.* INTO v_order
  FROM public.orders o
  WHERE o.id=p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PO not found';
  END IF;

  IF lower(btrim(coalesce(v_order.status,''))) NOT IN ('loaded','invoiced') THEN
    RAISE EXCEPTION 'PO must be marked LOADED before Bill Create; current status: %',v_order.status;
  END IF;

  IF EXISTS(
    SELECT 1 FROM public.lwb_internal_bills b WHERE b.order_id=p_order_id
  ) THEN
    RAISE EXCEPTION 'ERP Internal Bill already created for PO %',v_order.order_no;
  END IF;

  -- Existing legacy invoice entry must not silently be billed twice.
  IF EXISTS(
    SELECT 1 FROM public.tax_invoices ti WHERE ti.order_id=p_order_id
  ) THEN
    RAISE EXCEPTION 'An existing ERP invoice record already exists for this PO. Review it before creating another ERP bill.';
  END IF;

  IF EXISTS(
    SELECT 1 FROM public.order_items i
    WHERE i.order_id=p_order_id
      AND (
        coalesce(i.loaded_qty,0)<0
        OR coalesce(i.loaded_qty,0)>coalesce(i.approved_qty,i.ordered_qty,0)
        OR (coalesce(i.loaded_qty,0)>0
            AND (i.rate IS NULL OR i.rate<0))
      )
  ) THEN
    RAISE EXCEPTION 'Loaded qty exceeds approved qty, or PO rate is invalid. Verify the dispatch first.';
  END IF;

  SELECT
    count(*) FILTER (WHERE coalesce(i.loaded_qty,0)>0),
    coalesce(sum(coalesce(i.loaded_qty,0)),0)::numeric(16,3),
    coalesce(sum(
      CASE WHEN coalesce(i.loaded_qty,0)>0
      THEN round(i.loaded_qty::numeric * i.rate::numeric,2)
      ELSE 0 END
    ),0)::numeric(16,2),
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'sku_name',i.sku_name,
          'approved_qty',coalesce(i.approved_qty,i.ordered_qty,0),
          'loaded_qty',i.loaded_qty,
          'rate_per_case',i.rate,
          'loaded_amount',round(i.loaded_qty::numeric * i.rate::numeric,2)
        ) ORDER BY i.sku_name
      ) FILTER(WHERE coalesce(i.loaded_qty,0)>0),
      '[]'::jsonb
    )
  INTO v_line_count,v_qty,v_amount,v_items
  FROM public.order_items i
  WHERE i.order_id=p_order_id;

  IF v_line_count=0 OR v_qty<=0 THEN
    RAISE EXCEPTION 'This PO has no Actual Loaded Quantity. Complete Dispatch Loading first.';
  END IF;

  INSERT INTO public.lwb_internal_bills(
    order_id,order_no,customer_name,loaded_qty,goods_amount,items,created_by
  ) VALUES(
    p_order_id,v_order.order_no,v_order.customer_name,
    v_qty,v_amount,v_items,auth.uid()
  )
  RETURNING * INTO v_bill;

  -- Intentionally do NOT update orders.status, tax_invoices, stock,
  -- payment collections or lwb_invoice_outstanding. Separate workflow.
  RETURN QUERY SELECT
    v_bill.id,
    v_bill.internal_bill_no,
    v_bill.bill_date,
    v_bill.order_id,
    v_bill.customer_name,
    v_bill.loaded_qty::numeric,
    v_bill.goods_amount::numeric;
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_create_internal_bill(uuid)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_create_internal_bill(uuid)
 TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Confirmation, expect two rows:
SELECT 'public.lwb_internal_bills' AS object_name
WHERE to_regclass('public.lwb_internal_bills') IS NOT NULL
UNION ALL
SELECT 'public.lwb_create_internal_bill' AS object_name
WHERE EXISTS (
  SELECT 1 FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='lwb_create_internal_bill'
);
