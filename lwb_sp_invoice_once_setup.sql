-- LUXURY WRIST BRAND ERP — SHEET & PALLET: ONE PURCHASE INVOICE = ONE "RECEIVED FROM COMPANY" ENTRY (19 Nov 2026)
--
-- Run after lwb_sheet_pallet_setup.sql. Safe to run again.
--
-- Mohit: an invoice must go into the Sheet & Pallet ledger only once (the purchase bill already
-- refuses a second bill with the same invoice no.). Here:
--   1. Exact repeats already saved (same invoice no., pallets and sheets) are removed, the first one
--      is kept. Each removed row is copied to lwb_sp_history by the existing trigger.
--   2. A trigger refuses a new / changed COMPANY_IN row whose invoice no. (letters + digits only,
--      case ignored) is already on another COMPANY_IN row. OPENING BALANCE and blank numbers are free.
-- Old repeats with different counts are left for a person to check (Company Match shows them).

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_sp_inv_key(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $function$
  SELECT nullif(upper(regexp_replace(coalesce(p,''), '[^A-Za-z0-9]', '', 'g')), '');
$function$;

-- 1. exact repeats
DELETE FROM public.lwb_sp_entries d
 USING public.lwb_sp_entries k
 WHERE d.entry_type = 'COMPANY_IN' AND k.entry_type = 'COMPANY_IN'
   AND public.lwb_sp_inv_key(d.ref_no) IS NOT NULL
   AND public.lwb_sp_inv_key(d.ref_no) <> 'OPENINGBALANCE'
   AND public.lwb_sp_inv_key(d.ref_no) = public.lwb_sp_inv_key(k.ref_no)
   AND d.pallets = k.pallets AND d.sheets = k.sheets
   AND (k.created_at, k.id::text) < (d.created_at, d.id::text);

-- 2. no second entry for the same invoice
CREATE OR REPLACE FUNCTION public.lwb_sp_invoice_once()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE k text; d date;
BEGIN
  IF NEW.entry_type <> 'COMPANY_IN' THEN RETURN NEW; END IF;
  k := public.lwb_sp_inv_key(NEW.ref_no);
  IF k IS NULL OR k = 'OPENINGBALANCE' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.entry_type = 'COMPANY_IN' AND public.lwb_sp_inv_key(OLD.ref_no) IS NOT DISTINCT FROM k THEN
    RETURN NEW;
  END IF;
  SELECT e.entry_date INTO d FROM public.lwb_sp_entries e
   WHERE e.entry_type = 'COMPANY_IN' AND e.id <> NEW.id AND public.lwb_sp_inv_key(e.ref_no) = k
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Invoice % is already in the Sheet & Pallet ledger (received %). Edit that entry instead.',
      NEW.ref_no, to_char(d, 'DD/MM/YYYY');
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.lwb_sp_invoice_once() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS lwb_sp_entries_invoice_once ON public.lwb_sp_entries;
CREATE TRIGGER lwb_sp_entries_invoice_once BEFORE INSERT OR UPDATE OF entry_type, ref_no ON public.lwb_sp_entries
  FOR EACH ROW EXECUTE FUNCTION public.lwb_sp_invoice_once();

COMMIT;
