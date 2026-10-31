-- LUXURY WRIST BRAND ERP — FIXED ASSET REGISTER
--
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (31 Oct 2026): things the company buys that show as Fixed Assets (computer, printer,
-- weighing scale, pallet truck, furniture, AC, CCTV, vehicle ...) need a record with photos and the
-- purchase bill. Photos / bill files are kept by lwb_documents_setup.sql (record type ASSET).
--
-- Every asset gets an Asset ID (FA001, FA002 ... or typed by hand). Admin, Manager and Accounts add
-- and edit; Godown (warehouse) can view. Nothing is deleted: Status = Sold / Scrapped / Lost.
-- This register is for the ERP only. Depreciation and the books stay in Tally.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_fixed_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_code text UNIQUE CHECK (asset_code IS NULL OR asset_code ~ '^[A-Z0-9][A-Z0-9-]{1,14}$'),
  asset_name text NOT NULL CHECK (length(btrim(asset_name)) BETWEEN 2 AND 150),
  category text CHECK (category IS NULL OR length(category) <= 60),
  purchase_date date,
  supplier_name text CHECK (supplier_name IS NULL OR length(supplier_name) <= 150),
  bill_no text CHECK (bill_no IS NULL OR length(bill_no) <= 60),
  amount numeric(14,2) CHECK (amount IS NULL OR amount >= 0),
  gst_amount numeric(14,2) CHECK (gst_amount IS NULL OR gst_amount >= 0),
  serial_no text CHECK (serial_no IS NULL OR length(serial_no) <= 80),
  location text CHECK (location IS NULL OR length(location) <= 120),
  assigned_to text CHECK (assigned_to IS NULL OR length(assigned_to) <= 120),
  warranty_till date,
  status text NOT NULL DEFAULT 'IN_USE' CHECK (status IN ('IN_USE','REPAIR','SOLD','SCRAPPED','LOST')),
  status_date date,
  note text CHECK (note IS NULL OR length(note) <= 500),
  created_by uuid DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  updated_at timestamptz
);

CREATE OR REPLACE FUNCTION public.lwb_fa_role(p_edit boolean)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND (lower(btrim(p.role)) = ANY(CASE WHEN p_edit THEN ARRAY['admin','manager','accounts'] ELSE ARRAY['admin','manager','accounts','warehouse'] END)
           OR (lower(btrim(p.role)) <> 'driver' AND public.lwb_has_page('fixed-assets.html'))));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_fa_role(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_fa_role(boolean) TO authenticated;

-- Asset ID when left blank: FA + 3 digits after the biggest FAnnn so far.
CREATE OR REPLACE FUNCTION public.lwb_fa_fill()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NEW.asset_code IS NULL THEN
    SELECT 'FA' || lpad((coalesce(max(substring(a.asset_code FROM '^FA([0-9]{1,8})$')::bigint), 0) + 1)::text, 3, '0')
      INTO NEW.asset_code FROM public.lwb_fixed_assets a;
  END IF;
  IF TG_OP = 'UPDATE' THEN NEW.updated_at := now(); NEW.updated_by := auth.uid(); NEW.created_by := OLD.created_by; NEW.created_at := OLD.created_at; END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_fa_fill() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_fa_fill ON public.lwb_fixed_assets;
CREATE TRIGGER trg_lwb_fa_fill BEFORE INSERT OR UPDATE ON public.lwb_fixed_assets
  FOR EACH ROW EXECUTE FUNCTION public.lwb_fa_fill();

ALTER TABLE public.lwb_fixed_assets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_fixed_assets FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON public.lwb_fixed_assets TO authenticated;
DROP POLICY IF EXISTS lwb_fa_read ON public.lwb_fixed_assets;
CREATE POLICY lwb_fa_read ON public.lwb_fixed_assets FOR SELECT TO authenticated USING (public.lwb_fa_role(false));
DROP POLICY IF EXISTS lwb_fa_insert ON public.lwb_fixed_assets;
CREATE POLICY lwb_fa_insert ON public.lwb_fixed_assets FOR INSERT TO authenticated WITH CHECK (public.lwb_fa_role(true));
DROP POLICY IF EXISTS lwb_fa_update ON public.lwb_fixed_assets;
CREATE POLICY lwb_fa_update ON public.lwb_fixed_assets FOR UPDATE TO authenticated USING (public.lwb_fa_role(true)) WITH CHECK (public.lwb_fa_role(true));

COMMIT;

-- Expected: 2 rows, both true.
SELECT 'fixed asset table' AS item, to_regclass('public.lwb_fixed_assets') IS NOT NULL AS ok
UNION ALL SELECT 'asset id trigger', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_fa_fill');
