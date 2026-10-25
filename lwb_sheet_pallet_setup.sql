-- LUXURY WRIST BRAND ERP — SHEET & PALLET LEDGER (returnable packaging, quantity only)
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- Sheets and pallets have no money value. This keeps a quantity ledger of:
--   COMPANY_IN  : received from the company (purchase bill)
--   COMPANY_OUT : returned to the company (return letter)
--   PARTY_OUT   : given to a market party (direct vehicle bill)
--   PARTY_IN    : returned by a market party
-- Balance due to company = COMPANY_IN − COMPANY_OUT
-- Pending with a party   = PARTY_OUT − PARTY_IN
-- Admin / Manager / Accounts / Warehouse can view and add. Only Admin / Manager can edit,
-- delete and mark a company return as verified (after the company confirms receipt).
-- Return letter details (company address, distributor code, letterhead footer) are kept in
-- lwb_sp_settings, so nothing private is stored in the website files.
-- Every edit and delete is copied to lwb_sp_history (who, when, old and new values).
-- Goods Inward (purchase bill) adds a COMPANY_IN row from the browser after the bill is saved.
-- No order, stock, bill, payment or Tally data is changed.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_sp_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager','accounts','warehouse')
  );
$function$;

CREATE OR REPLACE FUNCTION public.lwb_sp_editor()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager')
  );
$function$;

REVOKE ALL ON FUNCTION public.lwb_sp_user() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_sp_editor() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sp_user() TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_sp_editor() TO authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_sp_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entry_date date NOT NULL,
  entry_type text NOT NULL CHECK (entry_type IN ('COMPANY_IN','COMPANY_OUT','PARTY_OUT','PARTY_IN')),
  party_name text,
  pallets integer NOT NULL DEFAULT 0 CHECK (pallets >= 0),
  sheets integer NOT NULL DEFAULT 0 CHECK (sheets >= 0),
  order_id uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  ref_no text,
  vehicle_no text,
  transporter_name text,
  driver_mobile text,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid DEFAULT auth.uid(),
  CHECK (pallets + sheets > 0),
  CHECK (entry_type LIKE 'COMPANY%' OR length(btrim(coalesce(party_name,''))) > 0)
);
ALTER TABLE public.lwb_sp_entries ADD COLUMN IF NOT EXISTS verified_at timestamptz;
ALTER TABLE public.lwb_sp_entries ADD COLUMN IF NOT EXISTS verified_by uuid;
CREATE INDEX IF NOT EXISTS lwb_sp_entries_date_idx ON public.lwb_sp_entries (entry_date, created_at);
CREATE INDEX IF NOT EXISTS lwb_sp_entries_party_idx ON public.lwb_sp_entries (party_name);

CREATE TABLE IF NOT EXISTS public.lwb_sp_settings (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  to_address text,
  plant_text text,
  distributor_code text,
  distributor_name text,
  letter_footer text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.lwb_sp_settings (id, distributor_name) VALUES (1, 'LUXURY WRIST BRAND')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.lwb_sp_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_sp_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lwb_sp_entries_read ON public.lwb_sp_entries;
CREATE POLICY lwb_sp_entries_read ON public.lwb_sp_entries FOR SELECT TO authenticated USING (public.lwb_sp_user());
DROP POLICY IF EXISTS lwb_sp_entries_insert ON public.lwb_sp_entries;
CREATE POLICY lwb_sp_entries_insert ON public.lwb_sp_entries FOR INSERT TO authenticated WITH CHECK (public.lwb_sp_user());
DROP POLICY IF EXISTS lwb_sp_entries_verify ON public.lwb_sp_entries;
DROP POLICY IF EXISTS lwb_sp_entries_update ON public.lwb_sp_entries;
CREATE POLICY lwb_sp_entries_update ON public.lwb_sp_entries FOR UPDATE TO authenticated USING (public.lwb_sp_editor()) WITH CHECK (public.lwb_sp_editor());
DROP POLICY IF EXISTS lwb_sp_entries_delete ON public.lwb_sp_entries;
CREATE POLICY lwb_sp_entries_delete ON public.lwb_sp_entries FOR DELETE TO authenticated USING (public.lwb_sp_editor());

DROP POLICY IF EXISTS lwb_sp_settings_read ON public.lwb_sp_settings;
CREATE POLICY lwb_sp_settings_read ON public.lwb_sp_settings FOR SELECT TO authenticated USING (public.lwb_sp_user());
DROP POLICY IF EXISTS lwb_sp_settings_update ON public.lwb_sp_settings;
CREATE POLICY lwb_sp_settings_update ON public.lwb_sp_settings FOR UPDATE TO authenticated USING (public.lwb_sp_editor()) WITH CHECK (public.lwb_sp_editor());

REVOKE ALL ON TABLE public.lwb_sp_entries FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.lwb_sp_settings FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.lwb_sp_entries TO authenticated;
GRANT UPDATE (entry_date, entry_type, party_name, pallets, sheets, order_id, ref_no, vehicle_no, transporter_name, driver_mobile, note, verified_at, verified_by)
  ON TABLE public.lwb_sp_entries TO authenticated;
GRANT SELECT, UPDATE ON TABLE public.lwb_sp_settings TO authenticated;

-- ---------- history of edits and deletes ----------
CREATE TABLE IF NOT EXISTS public.lwb_sp_history (
  id bigserial PRIMARY KEY,
  action text NOT NULL CHECK (action IN ('EDIT','DELETE')),
  entry_id uuid NOT NULL,
  old_row jsonb NOT NULL,
  new_row jsonb,
  changed_at timestamptz NOT NULL DEFAULT now(),
  changed_by uuid DEFAULT auth.uid(),
  changed_by_name text
);
CREATE INDEX IF NOT EXISTS lwb_sp_history_at_idx ON public.lwb_sp_history (changed_at DESC);

CREATE OR REPLACE FUNCTION public.lwb_sp_log_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE who text;
BEGIN
  SELECT coalesce(nullif(btrim(p.full_name),''), u.email) INTO who
    FROM auth.users u LEFT JOIN public.user_profiles p ON p.id = u.id WHERE u.id = auth.uid();
  IF TG_OP = 'DELETE' THEN
    INSERT INTO public.lwb_sp_history (action, entry_id, old_row, changed_by, changed_by_name)
    VALUES ('DELETE', OLD.id, to_jsonb(OLD), auth.uid(), who);
    RETURN OLD;
  END IF;
  -- Only verification changes are not logged as edits.
  IF (to_jsonb(NEW) - 'verified_at' - 'verified_by') IS DISTINCT FROM (to_jsonb(OLD) - 'verified_at' - 'verified_by') THEN
    INSERT INTO public.lwb_sp_history (action, entry_id, old_row, new_row, changed_by, changed_by_name)
    VALUES ('EDIT', OLD.id, to_jsonb(OLD), to_jsonb(NEW), auth.uid(), who);
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.lwb_sp_log_change() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS lwb_sp_entries_history ON public.lwb_sp_entries;
CREATE TRIGGER lwb_sp_entries_history BEFORE UPDATE OR DELETE ON public.lwb_sp_entries
  FOR EACH ROW EXECUTE FUNCTION public.lwb_sp_log_change();

ALTER TABLE public.lwb_sp_history ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_sp_history_read ON public.lwb_sp_history;
CREATE POLICY lwb_sp_history_read ON public.lwb_sp_history FOR SELECT TO authenticated USING (public.lwb_sp_user());
REVOKE ALL ON TABLE public.lwb_sp_history FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_sp_history TO authenticated;

COMMIT;
