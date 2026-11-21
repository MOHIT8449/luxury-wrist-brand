-- LUXURY WRIST BRAND ERP — NEW PARTY FROM THE PO FORM: NAME, ADDRESS, MOBILE + NO DUPLICATES
--
-- Mohit (21 Nov 2026): whoever makes a PO (sales, accounts, anyone with PO Entry)
-- must be able to add a missing party right from the PO form with "+ New Party",
-- and a new party always needs name, address and mobile.
--
-- Replaces lwb_sales_create_party (same 9 arguments as
-- lwb_party_pan_optional_location_setup.sql; PAN / GSTIN and shop location stay optional):
--   * name (2+ letters), billing address and a valid 10-digit Indian mobile
--     (starts 6-9) are required;
--   * a party with the same name (ignoring spaces / punctuation) OR the same
--     10-digit mobile is refused, and the message names the existing party so the
--     user can pick it from the list instead.
-- Who may call it is unchanged (lwb_po_entry_user: Admin, Manager, Sales, or anyone
-- given the PO Entry page). Only lwb_customer_master, lwb_party_salesman,
-- lwb_salesmen and erp_notifications are written. No order, stock, bill, ledger or
-- Tally data. Run after lwb_party_pan_optional_location_setup.sql. Safe to run again.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_sales_create_party(p_name text, p_mobile text, p_address text,
  p_city text, p_pincode text, p_pan text, p_gstin text,
  p_lat double precision DEFAULT NULL, p_lng double precision DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_name text := upper(regexp_replace(btrim(coalesce(p_name,'')), '\s+', ' ', 'g'));
  v_digits text := regexp_replace(coalesce(p_mobile,''), '\D', '', 'g');
  v_mobile text;
  v_address text := nullif(btrim(coalesce(p_address,'')), '');
  v_pan text := nullif(upper(btrim(coalesce(p_pan,''))), '');
  v_gstin text := nullif(upper(btrim(coalesce(p_gstin,''))), '');
  v_geo boolean;
  v_need text[] := '{}';
  v_dup record;
  v_row public.lwb_customer_master%ROWTYPE;
  v_me text;
BEGIN
  IF NOT public.lwb_po_entry_user() THEN RAISE EXCEPTION 'Only Admin, Manager or Salesman can add a party'; END IF;
  IF length(v_name) < 2 THEN v_need := v_need || 'Party name'::text; END IF;
  IF v_address IS NULL THEN v_need := v_need || 'Address'::text; END IF;
  IF v_digits = '' THEN v_need := v_need || 'Mobile'::text; END IF;
  IF cardinality(v_need) > 0 THEN
    RAISE EXCEPTION 'Fill %: a new party needs name, address and mobile.', array_to_string(v_need, ', ');
  END IF;
  IF v_digits !~ '^(91|0)?[6-9][0-9]{9}$' THEN
    RAISE EXCEPTION 'Mobile must be a 10-digit number starting with 6, 7, 8 or 9.';
  END IF;
  v_mobile := right(v_digits, 10);
  PERFORM public.lwb_check_party_fields(v_mobile, v_pan, v_gstin);
  v_geo := public.lwb_check_party_geo(p_lat, p_lng);

  -- Same name ignoring spaces and punctuation, or the same 10-digit mobile = same party.
  SELECT id, customer_code, customer_name,
         regexp_replace(upper(coalesce(customer_name,'')), '[^A-Z0-9]', '', 'g') = regexp_replace(v_name, '[^A-Z0-9]', '', 'g') AS same_name
    INTO v_dup
  FROM public.lwb_customer_master
  WHERE regexp_replace(upper(coalesce(customer_name,'')), '[^A-Z0-9]', '', 'g') = regexp_replace(v_name, '[^A-Z0-9]', '', 'g')
     OR (length(regexp_replace(coalesce(mobile,''), '\D', '', 'g')) >= 10
         AND right(regexp_replace(coalesce(mobile,''), '\D', '', 'g'), 10) = v_mobile)
  ORDER BY 4 DESC, is_active DESC NULLS LAST
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Party "%"% already has this %. %', v_dup.customer_name, coalesce(' (' || v_dup.customer_code || ')', ''),
      CASE WHEN v_dup.same_name THEN 'name' ELSE 'mobile number ' || v_mobile END,
      CASE WHEN public.lwb_party_visible(v_dup.id) THEN 'Select it from the party list.'
           ELSE 'Ask the Sales Head to assign it to you.' END;
  END IF;

  INSERT INTO public.lwb_customer_master (customer_name, gst_registration_status, pan, gstin, billing_address, city, state,
    pincode, mobile, credit_days, is_active, geo_lat, geo_lng, geo_set_at)
  VALUES (v_name, CASE WHEN v_gstin IS NULL THEN 'UNREGISTERED' ELSE 'REGISTERED' END,
    coalesce(v_pan, substr(v_gstin, 3, 10)), v_gstin, v_address, nullif(btrim(coalesce(p_city,'')),''), 'Gujarat',
    nullif(btrim(coalesce(p_pincode,'')),''), v_mobile, 0, true,
    CASE WHEN v_geo THEN p_lat END, CASE WHEN v_geo THEN p_lng END, CASE WHEN v_geo THEN now() END)
  RETURNING * INTO v_row;

  IF public.lwb_is_sales_user() THEN
    INSERT INTO public.lwb_salesmen (user_id, kind, updated_at, updated_by)
    VALUES (auth.uid(), 'FIELD', now(), auth.uid()) ON CONFLICT (user_id) DO NOTHING;
    INSERT INTO public.lwb_party_salesman (customer_id, salesman_id, assigned_at, assigned_by)
    VALUES (v_row.id, auth.uid(), now(), auth.uid())
    ON CONFLICT (customer_id) DO UPDATE SET salesman_id = excluded.salesman_id, assigned_at = now(), assigned_by = auth.uid();
  END IF;

  SELECT coalesce(nullif(btrim(full_name),''), 'A user') INTO v_me FROM public.user_profiles WHERE id = auth.uid();
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
  SELECT p.id, 'New Party Added',
    concat_ws(' · ', v_row.customer_name, v_row.city, v_mobile) || '. Added by ' || coalesce(v_me,'a user') || ' from PO Entry.'
      || CASE WHEN v_pan IS NULL AND v_gstin IS NULL THEN ' PAN / GSTIN not given yet.' ELSE '' END
      || CASE WHEN v_geo THEN ' Shop location saved.' ELSE '' END
      || ' Check it in Party Master.',
    'PARTY_CREATED'
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') AND p.id IS DISTINCT FROM auth.uid();

  RETURN jsonb_build_object('id', v_row.id, 'customer_code', v_row.customer_code, 'customer_name', v_row.customer_name);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_sales_create_party(text,text,text,text,text,text,text,double precision,double precision) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sales_create_party(text,text,text,text,text,text,text,double precision,double precision) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check (true):
-- SELECT pg_get_functiondef('public.lwb_sales_create_party(text,text,text,text,text,text,text,double precision,double precision)'::regprocedure) LIKE '%same 10-digit mobile%' AS new_party_rule_ready;
