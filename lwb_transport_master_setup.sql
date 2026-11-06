-- LUXURY WRIST BRAND ERP — TRANSPORT MASTER (Goods Inward "Transport" search + "+ Save New").
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- Goods Inward reads lwb_transport_master (active names) and Admin / Sales Head
-- (MANAGER) / Godown Manager (WAREHOUSE) add a new name from the page. Before this file the page said
-- "Transport Master not connected"; it still works without it (transport is then
-- saved as typed text only, nothing is remembered).
--
-- If the table was made earlier by hand, missing columns, grants and rules are added;
-- existing names are kept. No bill, stock or ledger data is changed.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_transport_master (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transport_name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now(),
  created_by uuid DEFAULT auth.uid()
);
ALTER TABLE public.lwb_transport_master ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;
ALTER TABLE public.lwb_transport_master ADD COLUMN IF NOT EXISTS created_at timestamptz DEFAULT now();
ALTER TABLE public.lwb_transport_master ADD COLUMN IF NOT EXISTS created_by uuid DEFAULT auth.uid();

-- Name: trimmed, single spaces, 2..150 characters.
CREATE OR REPLACE FUNCTION public.lwb_transport_master_clean()
RETURNS trigger LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  NEW.transport_name := regexp_replace(btrim(coalesce(NEW.transport_name,'')), '\s+', ' ', 'g');
  IF length(NEW.transport_name) < 2 OR length(NEW.transport_name) > 150 THEN
    RAISE EXCEPTION 'Transport name must be 2 to 150 characters' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_lwb_transport_master_clean ON public.lwb_transport_master;
CREATE TRIGGER trg_lwb_transport_master_clean BEFORE INSERT OR UPDATE OF transport_name
  ON public.lwb_transport_master FOR EACH ROW EXECUTE FUNCTION public.lwb_transport_master_clean();

-- One row per name (ignoring case). Skipped with a notice when old duplicates exist.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM public.lwb_transport_master
             GROUP BY upper(btrim(transport_name)) HAVING count(*) > 1) THEN
    RAISE NOTICE 'lwb_transport_master: duplicate names found, unique index not added';
  ELSE
    CREATE UNIQUE INDEX IF NOT EXISTS lwb_transport_master_name_uidx
      ON public.lwb_transport_master (upper(btrim(transport_name)));
  END IF;
END $do$;

-- Rules: every active ERP login reads; Admin / Sales Head / Godown Manager add or change.
ALTER TABLE public.lwb_transport_master ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_transport_master_read ON public.lwb_transport_master;
CREATE POLICY lwb_transport_master_read ON public.lwb_transport_master FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true));
DROP POLICY IF EXISTS lwb_transport_master_insert ON public.lwb_transport_master;
CREATE POLICY lwb_transport_master_insert ON public.lwb_transport_master FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                      AND lower(btrim(p.role)) IN ('admin','manager','warehouse')));
DROP POLICY IF EXISTS lwb_transport_master_update ON public.lwb_transport_master;
CREATE POLICY lwb_transport_master_update ON public.lwb_transport_master FOR UPDATE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','warehouse')))
  WITH CHECK (true);

REVOKE ALL ON public.lwb_transport_master FROM anon;
GRANT SELECT, INSERT, UPDATE ON public.lwb_transport_master TO authenticated;

COMMIT;

-- Check: should list your saved transports (empty is fine on the first run).
SELECT transport_name, is_active FROM public.lwb_transport_master ORDER BY transport_name;
