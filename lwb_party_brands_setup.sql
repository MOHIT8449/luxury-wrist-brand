-- LUXURY WRIST BRAND ERP — PARTY BRANDS (17 Nov 2026)
--
-- Applied automatically when the PR is merged (safe to run again).
-- Run AFTER lwb_company_brand_setup.sql and lwb_party_master_save_fix.sql.
--
-- Mohit: in Party Master, tick which brands a party sells (Rajnigandha only,
-- Coca-Cola only, or both), so a Rajnigandha-only party is never shown as
-- "not buying" Coca-Cola items on Party Buying.
--
-- 1. lwb_customer_master.brand_ids uuid[] (lwb_companies ids). NULL = not set
--    (Party Buying then goes by what the party bought). Unknown ids and repeats
--    are dropped on save; an empty list is kept as NULL.
-- 2. Party Master save (Admin) may now write brand_ids (patched in place, keeps the rest).
-- Nothing else is changed: no order, bill, stock, payment, ledger or Tally data.

BEGIN;

ALTER TABLE public.lwb_customer_master ADD COLUMN IF NOT EXISTS brand_ids uuid[];

CREATE OR REPLACE FUNCTION public.lwb_customer_brand_ids_clean()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NEW.brand_ids IS NOT NULL THEN
    NEW.brand_ids := (SELECT array_agg(c.id ORDER BY c.name) FROM public.lwb_companies c WHERE c.id = ANY(NEW.brand_ids));
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_customer_brand_ids_clean() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS lwb_customer_brand_ids_clean ON public.lwb_customer_master;
CREATE TRIGGER lwb_customer_brand_ids_clean
  BEFORE INSERT OR UPDATE OF brand_ids ON public.lwb_customer_master
  FOR EACH ROW EXECUTE FUNCTION public.lwb_customer_brand_ids_clean();

DO $do$
DECLARE v_def text;
BEGIN
  IF to_regprocedure('public.lwb_party_master_save(uuid,jsonb)') IS NULL THEN RETURN; END IF;
  v_def := pg_get_functiondef('public.lwb_party_master_save(uuid,jsonb)'::regprocedure);
  IF position('''brand_ids''' IN v_def) = 0 AND position('''min_order_kg''' IN v_def) > 0 THEN
    EXECUTE replace(v_def, '''min_order_kg''', '''min_order_kg'',''brand_ids''');
  END IF;
END $do$;

COMMIT;
