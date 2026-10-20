-- Luxury Wrist Brand ERP: per-SKU pallet conversion for PO Entry.
-- Safe to rerun. Does not remove any existing orders, SKUs, or inventory.
-- Existing quantities and statuses remain unchanged.
BEGIN;
ALTER TABLE public.sku_master
  ADD COLUMN IF NOT EXISTS cases_per_pallet integer;
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS entry_uom text NOT NULL DEFAULT 'CS';
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS ordered_pallet_qty integer;
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS cases_per_pallet_snapshot integer;
-- Business-supplied value: 300ML THUMSUP 1X28 = 117 cases per pallet.
-- Leave any existing pallet master value unchanged.
UPDATE public.sku_master
SET cases_per_pallet = 117
WHERE upper(trim(sku_name)) = '300ML THUMSUP 1X28 MRP 20'
  AND cases_per_pallet IS NULL;
COMMIT;
NOTIFY pgrst, 'reload schema';
SELECT sku_name, cases_per_pallet
FROM public.sku_master
WHERE upper(trim(sku_name)) = '300ML THUMSUP 1X28 MRP 20';