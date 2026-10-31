-- LUXURY WRIST BRAND ERP — SAVE SUPPLIER (Supplier / Company Master)
--
-- Safe to run again. Runs by itself on merge to main (Supabase apply).
--
-- Saving a supplier from the browser failed with "permission denied for table
-- lwb_supplier_master" once the Company / Brand column was added (the live table only
-- lets the browser write the columns it was set up with). Admin now saves through
-- lwb_supplier_save(p), which checks for an active Admin and writes every column of the
-- form, including company_id. Reading the table is unchanged.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_supplier_save(p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_id uuid := nullif(p->>'id','')::uuid;
  v_name text := regexp_replace(btrim(coalesce(p->>'supplier_name','')),'\s+',' ','g');
  v_company uuid := nullif(p->>'company_id','')::uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles u WHERE u.id = auth.uid() AND u.active = true AND lower(btrim(u.role)) = 'admin') THEN
    RAISE EXCEPTION 'Only an active Admin can add or edit Suppliers';
  END IF;
  IF v_name = '' OR length(v_name) > 150 THEN RAISE EXCEPTION 'Enter Supplier / Company Name (up to 150 characters)'; END IF;
  IF v_company IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_companies c WHERE c.id = v_company) THEN
    RAISE EXCEPTION 'Company / Brand not found';
  END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_supplier_master s WHERE lower(btrim(s.supplier_name)) = lower(v_name) AND s.id IS DISTINCT FROM v_id) THEN
    RAISE EXCEPTION 'Supplier already exists: %', v_name USING ERRCODE = '23505';
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO public.lwb_supplier_master(supplier_name, gstin, pan, contact_person, mobile, email, address, city, state, pincode,
      payment_terms, is_active, company_id)
    VALUES (v_name, nullif(upper(btrim(p->>'gstin')),''), nullif(upper(btrim(p->>'pan')),''), nullif(btrim(p->>'contact_person'),''),
      nullif(btrim(p->>'mobile'),''), nullif(btrim(p->>'email'),''), nullif(btrim(p->>'address'),''), nullif(btrim(p->>'city'),''),
      nullif(btrim(p->>'state'),''), nullif(btrim(p->>'pincode'),''), nullif(btrim(p->>'payment_terms'),''),
      coalesce((p->>'is_active')::boolean, true), v_company)
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.lwb_supplier_master s SET supplier_name = v_name, gstin = nullif(upper(btrim(p->>'gstin')),''),
      pan = nullif(upper(btrim(p->>'pan')),''), contact_person = nullif(btrim(p->>'contact_person'),''),
      mobile = nullif(btrim(p->>'mobile'),''), email = nullif(btrim(p->>'email'),''), address = nullif(btrim(p->>'address'),''),
      city = nullif(btrim(p->>'city'),''), state = nullif(btrim(p->>'state'),''), pincode = nullif(btrim(p->>'pincode'),''),
      payment_terms = nullif(btrim(p->>'payment_terms'),''), is_active = coalesce((p->>'is_active')::boolean, s.is_active),
      company_id = CASE WHEN p ? 'company_id' THEN v_company ELSE s.company_id END
    WHERE s.id = v_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Supplier not found'; END IF;
  END IF;
  RETURN v_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_supplier_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_supplier_save(jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
