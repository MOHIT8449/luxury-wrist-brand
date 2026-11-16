-- LUXURY WRIST BRAND ERP — ECRS ORDER PAGE (16 Nov 2026)
--
-- Mohit asked (16 Nov 2026): the company (Coca-Cola) gives a daily allowed quantity per SKU in
-- ECRS (cases / petti). We can order only from that list, often less (cash limit). Trucks are
-- 24 pallets (sometimes 23). Needs per day: ECRS total, what we ordered (truck-wise, Order 1, 2, 3),
-- pending, GR, payment = GR − the day's discount %, RTGS paid and balance.
--
--   lwb_ecrs_days   one row per date: RTGS paid + the ECRS lines
--                   lines = [{sku_id, name, cs, gr, disc, ppp}]   (cs = ECRS cases)
--   lwb_ecrs_trucks one row per truck ordered on that date (Order no. = position in the day)
--                   rows  = [{sku_id, name, pal}]
--
-- SKUs come from sku_master (cases_per_pallet, unit_weight_kg); GR from Rate & Scheme
-- (lwb_rate_packs.gr via lwb_rate_pack_skus). Admin / Manager only (same as Rate & Scheme).
-- Safe to run again. Nothing is dropped or deleted.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_ecrs_days (
  day date PRIMARY KEY,
  rtgs numeric(14,2),
  lines jsonb NOT NULL DEFAULT '[]'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid DEFAULT auth.uid()
);

CREATE TABLE IF NOT EXISTS public.lwb_ecrs_trucks (
  id bigserial PRIMARY KEY,
  day date NOT NULL,
  cap integer NOT NULL DEFAULT 24 CHECK (cap > 0 AND cap <= 60),
  rows jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid DEFAULT auth.uid(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_ecrs_trucks_day_idx ON public.lwb_ecrs_trucks (day, id);

ALTER TABLE public.lwb_ecrs_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_ecrs_trucks ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.lwb_ecrs_days, public.lwb_ecrs_trucks FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.lwb_ecrs_days, public.lwb_ecrs_trucks TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.lwb_ecrs_trucks_id_seq TO authenticated;

DROP POLICY IF EXISTS lwb_ecrs_days_rw ON public.lwb_ecrs_days;
CREATE POLICY lwb_ecrs_days_rw ON public.lwb_ecrs_days
  FOR ALL TO authenticated
  USING (public.lwb_rate_editor()) WITH CHECK (public.lwb_rate_editor());

DROP POLICY IF EXISTS lwb_ecrs_trucks_rw ON public.lwb_ecrs_trucks;
CREATE POLICY lwb_ecrs_trucks_rw ON public.lwb_ecrs_trucks
  FOR ALL TO authenticated
  USING (public.lwb_rate_editor()) WITH CHECK (public.lwb_rate_editor());

COMMIT;

NOTIFY pgrst, 'reload schema';
