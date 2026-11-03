-- LUXURY WRIST BRAND ERP — PARTY MASTER SAVE FIX.
--
-- Mohit: Admin editing a party on Party Master got
--   "Save failed: permission denied for table lwb_customer_master".
-- The signed-in (authenticated) login has no direct write right on the table
-- any more, so the page's direct insert / update was refused.
--
-- Fix: Party Master now saves through Admin-only functions (SECURITY DEFINER),
-- the same way Sales Team Setup, Party Merge and the salesman "new party" in
-- PO Entry already do. No table grant is widened, so a salesman still cannot
-- write to the Party Master, and his party list stays limited to his own
-- assigned parties (lwb_sales_party_scope is not touched).
--
-- 1. lwb_party_master_save(p_id, p_row)  add (p_id NULL) or edit one party.
--    Only the Party Master form / Excel columns are written.
-- 2. lwb_party_master_set_active(p_ids, p_active)  Inactivate old parties.
--
-- No order, bill, stock, payment, ledger or Tally data is changed.
-- Run after lwb_sales_team_setup.sql. Safe to run again.

BEGIN;

-- Admin only (Party Master Save button is Admin only on the page too).
CREATE OR REPLACE FUNCTION public.lwb_party_master_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'admin');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_master_admin() FROM PUBLIC, anon, authenticated;

-- Add / edit one party. p_row keys outside the Party Master columns are ignored.
CREATE OR REPLACE FUNCTION public.lwb_party_master_save(p_id uuid, p_row jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_allowed text[] := ARRAY['customer_name','gst_registration_status','pan','gstin','billing_address','city',
    'state','mobile','pincode','contact_person','credit_days','is_active','kyc_free_orders','min_order_kg'];
  v_cols text[];
  v_list text;
  v_id uuid;
BEGIN
  IF NOT public.lwb_party_master_admin() THEN RAISE EXCEPTION 'Only Admin can save the Party Master'; END IF;
  IF p_row IS NULL OR jsonb_typeof(p_row) <> 'object' THEN RAISE EXCEPTION 'Nothing to save'; END IF;

  -- Keys that are Party Master columns and exist in this database.
  SELECT array_agg(c.column_name::text ORDER BY c.ordinal_position) INTO v_cols
  FROM information_schema.columns c
  WHERE c.table_schema = 'public' AND c.table_name = 'lwb_customer_master'
    AND c.column_name = ANY(v_allowed) AND p_row ? c.column_name;
  IF v_cols IS NULL THEN RAISE EXCEPTION 'Nothing to save'; END IF;
  SELECT string_agg(format('%I', x), ',') INTO v_list FROM unnest(v_cols) x;

  IF p_id IS NULL THEN
    IF btrim(coalesce(p_row->>'customer_name','')) = '' THEN RAISE EXCEPTION 'Party Name required'; END IF;
    EXECUTE format('INSERT INTO public.lwb_customer_master (%s)
                    SELECT %s FROM jsonb_populate_record(NULL::public.lwb_customer_master, $1)
                    RETURNING id', v_list, v_list)
      INTO v_id USING p_row;
  ELSE
    EXECUTE format('UPDATE public.lwb_customer_master m SET (%s) =
                    (SELECT %s FROM jsonb_populate_record(NULL::public.lwb_customer_master, $1))
                    WHERE m.id = $2 RETURNING m.id', v_list, v_list)
      INTO v_id USING p_row, p_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Party not found'; END IF;
  END IF;
  RETURN v_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_master_save(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_master_save(uuid, jsonb) TO authenticated;

-- Set many parties Active / Inactive (old parties missing from the Excel import).
CREATE OR REPLACE FUNCTION public.lwb_party_master_set_active(p_ids uuid[], p_active boolean)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_n integer;
BEGIN
  IF NOT public.lwb_party_master_admin() THEN RAISE EXCEPTION 'Only Admin can save the Party Master'; END IF;
  IF p_ids IS NULL OR cardinality(p_ids) = 0 OR p_active IS NULL THEN RETURN 0; END IF;
  UPDATE public.lwb_customer_master SET is_active = p_active WHERE id = ANY(p_ids);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_master_set_active(uuid[], boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_master_set_active(uuid[], boolean) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
