-- LUXURY WRIST BRAND ERP — SKU CATEGORY
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- Adds an optional "category" (e.g. 250ML CSD, JUICE, CAN CSD) to SKU Master,
-- filled from the SKU Master page (form or "Bulk Add SKUs"). Existing SKUs,
-- orders, stock and bills are not changed.

ALTER TABLE public.sku_master ADD COLUMN IF NOT EXISTS category text;
