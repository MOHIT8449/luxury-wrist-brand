-- LUXURY WRIST BRAND ERP — MINIMUM ORDER WEIGHT FOR PO ENTRY
--
-- RUN ONCE in Supabase SQL Editor, after lwb_sales_team_setup.sql. Safe to run again.
--
-- PO Entry shows the order weight (KG and tons) and how far it is from the
-- minimum order weight. A salesman below the minimum is warned and must confirm
-- before he submits.
--   Default minimum: Sales Team Setup > Morning Plan (0 = no minimum).
--   One party's own minimum: Party Master > Edit (blank = default).
--
-- Only lwb_sales_settings and lwb_customer_master get a new column.
-- No order, stock, bill, ledger or Tally data is changed.

BEGIN;

ALTER TABLE public.lwb_sales_settings
  ADD COLUMN IF NOT EXISTS min_order_kg numeric(10,2) NOT NULL DEFAULT 0 CHECK (min_order_kg BETWEEN 0 AND 100000);
ALTER TABLE public.lwb_customer_master
  ADD COLUMN IF NOT EXISTS min_order_kg numeric(10,2) CHECK (min_order_kg BETWEEN 0 AND 100000);

CREATE OR REPLACE FUNCTION public.lwb_save_min_order_kg(p_kg numeric)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF p_kg IS NULL OR p_kg NOT BETWEEN 0 AND 100000 THEN RAISE EXCEPTION 'Minimum must be 0 to 100000 KG'; END IF;
  UPDATE public.lwb_sales_settings SET min_order_kg = p_kg, updated_at = now(), updated_by = auth.uid() WHERE id = 1;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_save_min_order_kg(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_save_min_order_kg(numeric) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: SELECT min_order_kg FROM public.lwb_sales_settings WHERE id = 1;
