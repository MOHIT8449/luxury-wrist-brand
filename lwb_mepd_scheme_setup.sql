-- LUXURY WRIST BRAND ERP — MEPD SCHEME BY CATEGORY AND DATE
--
-- RUN ONCE in Supabase SQL Editor, AFTER lwb_rate_scheme_setup.sql. Safe to run again.
--
-- Company gives MEPD % for chosen SKU categories for a period (a day, a week
-- or a month). Admin / Manager enter it on Rate & Scheme > "MEPD Scheme".
-- Landing on Rate & Scheme and PO Entry use the scheme of the SKU's category
-- for that date; with no scheme, the pack MEPD % or the main MEPD % is used.
-- No order, bill, stock or Tally data is changed.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_mepd_schemes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  categories text[] NOT NULL CHECK (cardinality(categories) > 0),
  mepd_pct numeric(7,3) NOT NULL CHECK (mepd_pct >= 0 AND mepd_pct <= 100),
  valid_from date NOT NULL,
  valid_to date NOT NULL,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid DEFAULT auth.uid(),
  CHECK (valid_to >= valid_from)
);

ALTER TABLE public.lwb_mepd_schemes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_mepd_schemes_read ON public.lwb_mepd_schemes;
CREATE POLICY lwb_mepd_schemes_read ON public.lwb_mepd_schemes
  FOR SELECT TO authenticated USING (public.lwb_rate_editor());
DROP POLICY IF EXISTS lwb_mepd_schemes_insert ON public.lwb_mepd_schemes;
CREATE POLICY lwb_mepd_schemes_insert ON public.lwb_mepd_schemes
  FOR INSERT TO authenticated WITH CHECK (public.lwb_rate_editor());
DROP POLICY IF EXISTS lwb_mepd_schemes_delete ON public.lwb_mepd_schemes;
CREATE POLICY lwb_mepd_schemes_delete ON public.lwb_mepd_schemes
  FOR DELETE TO authenticated USING (public.lwb_rate_editor());

REVOKE ALL ON TABLE public.lwb_mepd_schemes FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.lwb_mepd_schemes TO authenticated;

COMMIT;
