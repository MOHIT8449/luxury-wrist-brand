-- LUXURY WRIST BRAND ERP — NEW PARTY: PAN OPTIONAL + SHOP LOCATION
--
-- RUN ONCE in Supabase SQL Editor, after lwb_party_details_rule_setup.sql and
-- lwb_live_tracking_setup.sql. Safe to run again.
--
-- 1. PO Entry "Add new party": only name, mobile and billing address are needed.
--    PAN / GSTIN can be left empty (the party often gives it later). The party
--    still shows "Party details missing: PAN / GSTIN" with the "Fill details"
--    button, and the few-orders rule of lwb_party_details_rule_setup.sql stays.
-- 2. "📍 Shop location" on the same popup saves the phone's GPS on the party
--    (lwb_customer_master.geo_lat / geo_lng / geo_set_at, the same columns that
--    Live Tracking and the trip / area suggestion already use).
--    "Fill details" can add the location only when the party has none yet;
--    a saved location is changed only from the Live Tracking map pin.
--
-- Only lwb_customer_master, lwb_party_salesman, lwb_salesmen and
-- erp_notifications are written. No order, stock, bill, ledger or Tally data.

BEGIN;

ALTER TABLE public.lwb_customer_master
  ADD COLUMN IF NOT EXISTS geo_lat double precision,
  ADD COLUMN IF NOT EXISTS geo_lng double precision,
  ADD COLUMN IF NOT EXISTS geo_set_at timestamptz;

-- A lat/lng pair must be both given, in range, and not 0,0.
CREATE OR REPLACE FUNCTION public.lwb_check_party_geo(p_lat double precision, p_lng double precision)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $fn$
BEGIN
  IF p_lat IS NULL AND p_lng IS NULL THEN RETURN false; END IF;
  IF p_lat IS NULL OR p_lng IS NULL OR p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180
     OR (p_lat = 0 AND p_lng = 0) THEN
    RAISE EXCEPTION 'Shop location is not valid. Tap 📍 again.';
  END IF;
  RETURN true;
END;
$fn$;

-- PO Entry: the party's details status (now also says whether a location is saved).
CREATE OR REPLACE FUNCTION public.lwb_party_kyc(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  m public.lwb_customer_master%ROWTYPE;
  v_limit integer;
BEGIN
  IF NOT public.lwb_po_entry_user() THEN RAISE EXCEPTION 'Only Admin, Manager or Salesman can read party details'; END IF;
  SELECT * INTO m FROM public.lwb_customer_master WHERE id = p_customer_id;
  IF NOT FOUND OR NOT public.lwb_party_visible(m.id) THEN RETURN NULL; END IF;
  v_limit := coalesce(m.kyc_free_orders, (SELECT s.kyc_free_orders FROM public.lwb_sales_settings s WHERE s.id = 1), 3);
  RETURN jsonb_build_object(
    'missing', to_jsonb(public.lwb_party_missing(m.mobile, m.billing_address, m.pan, m.gstin)),
    'used', m.kyc_orders_used, 'limit', v_limit,
    'enforced', public.lwb_is_sales_user(),
    'mobile', m.mobile, 'address', m.billing_address, 'city', m.city, 'pincode', m.pincode,
    'pan', m.pan, 'gstin', m.gstin,
    'has_location', m.geo_lat IS NOT NULL AND m.geo_lng IS NOT NULL);
END;
$fn$;

-- PO Entry: fill a party's EMPTY fields (+ location when it has none).
DROP FUNCTION IF EXISTS public.lwb_sales_fill_party_details(uuid,text,text,text,text,text,text);
CREATE OR REPLACE FUNCTION public.lwb_sales_fill_party_details(p_customer_id uuid, p_mobile text, p_address text,
  p_city text, p_pincode text, p_pan text, p_gstin text,
  p_lat double precision DEFAULT NULL, p_lng double precision DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  m public.lwb_customer_master%ROWTYPE;
  v_mobile text := nullif(regexp_replace(coalesce(p_mobile,''), '\D', '', 'g'), '');
  v_pan text := nullif(upper(btrim(coalesce(p_pan,''))), '');
  v_gstin text := nullif(upper(btrim(coalesce(p_gstin,''))), '');
  v_geo boolean;
BEGIN
  IF NOT public.lwb_po_entry_user() THEN RAISE EXCEPTION 'Only Admin, Manager or Salesman can fill party details'; END IF;
  SELECT * INTO m FROM public.lwb_customer_master WHERE id = p_customer_id FOR UPDATE;
  IF NOT FOUND OR NOT public.lwb_party_visible(m.id) THEN RAISE EXCEPTION 'Party not found in your list.'; END IF;
  PERFORM public.lwb_check_party_fields(v_mobile, v_pan, v_gstin);
  v_geo := public.lwb_check_party_geo(p_lat, p_lng) AND m.geo_lat IS NULL;
  v_mobile := right(v_mobile, 10);
  UPDATE public.lwb_customer_master SET
    mobile = CASE WHEN length(regexp_replace(coalesce(mobile,''), '\D', '', 'g')) < 10 THEN coalesce(v_mobile, mobile) ELSE mobile END,
    billing_address = coalesce(nullif(btrim(billing_address),''), nullif(btrim(coalesce(p_address,'')),'')),
    city = coalesce(nullif(btrim(city),''), nullif(btrim(coalesce(p_city,'')),'')),
    pincode = coalesce(nullif(btrim(pincode),''), nullif(btrim(coalesce(p_pincode,'')),'')),
    gstin = coalesce(nullif(btrim(gstin),''), v_gstin),
    pan = coalesce(nullif(btrim(pan),''), v_pan, CASE WHEN v_gstin IS NOT NULL THEN substr(v_gstin, 3, 10) END),
    gst_registration_status = CASE WHEN coalesce(nullif(btrim(gstin),''), v_gstin) IS NOT NULL THEN 'REGISTERED' ELSE gst_registration_status END,
    geo_lat = CASE WHEN v_geo THEN p_lat ELSE geo_lat END,
    geo_lng = CASE WHEN v_geo THEN p_lng ELSE geo_lng END,
    geo_set_at = CASE WHEN v_geo THEN now() ELSE geo_set_at END
  WHERE id = m.id;
  RETURN public.lwb_party_kyc(m.id);
END;
$fn$;

-- PO Entry: a salesman adds a new party (PAN / GSTIN optional, location optional).
DROP FUNCTION IF EXISTS public.lwb_sales_create_party(text,text,text,text,text,text,text);
CREATE OR REPLACE FUNCTION public.lwb_sales_create_party(p_name text, p_mobile text, p_address text,
  p_city text, p_pincode text, p_pan text, p_gstin text,
  p_lat double precision DEFAULT NULL, p_lng double precision DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_name text := upper(regexp_replace(btrim(coalesce(p_name,'')), '\s+', ' ', 'g'));
  v_mobile text := right(regexp_replace(coalesce(p_mobile,''), '\D', '', 'g'), 10);
  v_pan text := nullif(upper(btrim(coalesce(p_pan,''))), '');
  v_gstin text := nullif(upper(btrim(coalesce(p_gstin,''))), '');
  v_geo boolean;
  v_need text[];
  v_dup record;
  v_row public.lwb_customer_master%ROWTYPE;
  v_me text;
BEGIN
  IF NOT public.lwb_po_entry_user() THEN RAISE EXCEPTION 'Only Admin, Manager or Salesman can add a party'; END IF;
  IF length(v_name) < 2 THEN RAISE EXCEPTION 'Enter the party name.'; END IF;
  PERFORM public.lwb_check_party_fields(p_mobile, v_pan, v_gstin);
  v_geo := public.lwb_check_party_geo(p_lat, p_lng);
  v_need := array_remove(public.lwb_party_missing(v_mobile, p_address, v_pan, v_gstin), 'PAN / GSTIN');
  IF cardinality(v_need) > 0 THEN
    RAISE EXCEPTION 'Fill %: a new party needs mobile and address.', array_to_string(v_need, ', ');
  END IF;
  -- Same name ignoring spaces and punctuation = same party (Party Master "Duplicates only" uses this rule).
  SELECT customer_code, customer_name INTO v_dup FROM public.lwb_customer_master
  WHERE regexp_replace(upper(coalesce(customer_name,'')), '[^A-Z0-9]', '', 'g') = regexp_replace(v_name, '[^A-Z0-9]', '', 'g')
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Party "%"% already exists. Ask the Sales Head to assign it to you.', v_dup.customer_name, coalesce(' (' || v_dup.customer_code || ')', '');
  END IF;

  INSERT INTO public.lwb_customer_master (customer_name, gst_registration_status, pan, gstin, billing_address, city, state,
    pincode, mobile, credit_days, is_active, geo_lat, geo_lng, geo_set_at)
  VALUES (v_name, CASE WHEN v_gstin IS NULL THEN 'UNREGISTERED' ELSE 'REGISTERED' END,
    coalesce(v_pan, substr(v_gstin, 3, 10)), v_gstin, btrim(p_address), nullif(btrim(coalesce(p_city,'')),''), 'Gujarat',
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

  SELECT coalesce(nullif(btrim(full_name),''), 'A salesman') INTO v_me FROM public.user_profiles WHERE id = auth.uid();
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
  SELECT p.id, 'New Party Added',
    concat_ws(' · ', v_row.customer_name, v_row.city, v_mobile) || '. Added by ' || coalesce(v_me,'a salesman') || ' from PO Entry.'
      || CASE WHEN v_pan IS NULL AND v_gstin IS NULL THEN ' PAN / GSTIN not given yet.' ELSE '' END
      || CASE WHEN v_geo THEN ' Shop location saved.' ELSE '' END
      || ' Check it in Party Master.',
    'PARTY_CREATED'
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') AND p.id IS DISTINCT FROM auth.uid();

  RETURN jsonb_build_object('id', v_row.id, 'customer_code', v_row.customer_code, 'customer_name', v_row.customer_name);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_party_kyc(uuid),
  public.lwb_sales_fill_party_details(uuid,text,text,text,text,text,text,double precision,double precision),
  public.lwb_sales_create_party(text,text,text,text,text,text,text,double precision,double precision) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_kyc(uuid),
  public.lwb_sales_fill_party_details(uuid,text,text,text,text,text,text,double precision,double precision),
  public.lwb_sales_create_party(text,text,text,text,text,text,text,double precision,double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_check_party_geo(double precision,double precision) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check (all true):
-- SELECT to_regprocedure('public.lwb_sales_create_party(text,text,text,text,text,text,text,double precision,double precision)') IS NOT NULL AS new_party_ready,
--        to_regprocedure('public.lwb_sales_fill_party_details(uuid,text,text,text,text,text,text,double precision,double precision)') IS NOT NULL AS fill_ready;
