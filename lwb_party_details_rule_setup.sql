-- LUXURY WRIST BRAND ERP — PARTY DETAILS RULE + SALESMAN NEW PARTY
--
-- RUN ONCE in Supabase SQL Editor, after lwb_sales_team_setup.sql and
-- lwb_party_salesman_assign_setup.sql. Safe to run again.
--
-- 1. A party's details are complete when it has a mobile (10 digits), a billing
--    address and a PAN or GSTIN. While something is missing, a salesman may punch
--    only a few orders for that party (default 3; Sales Team Setup > Daily Plan
--    sets the default, Party Master can set a different number for one party).
--    After that, his order is refused until the details are filled.
--    Admin and Sales Head orders are never blocked or counted.
-- 2. A salesman fills the missing details from PO Entry. He can only fill empty
--    fields; details already saved are changed only in Party Master.
-- 3. A salesman can add a new party from PO Entry (full details needed). It is
--    assigned to him, and Admin and Sales Head get a notification.
--
-- Only lwb_customer_master, lwb_party_salesman, lwb_salesmen, lwb_sales_settings
-- and erp_notifications are written. No order, stock, bill, ledger or Tally data.

BEGIN;

ALTER TABLE public.lwb_sales_settings
  ADD COLUMN IF NOT EXISTS kyc_free_orders integer NOT NULL DEFAULT 3 CHECK (kyc_free_orders BETWEEN 0 AND 50);
-- kyc_free_orders: this party's own limit (blank = the default above).
-- kyc_orders_used: salesman orders punched while its details were missing.
ALTER TABLE public.lwb_customer_master
  ADD COLUMN IF NOT EXISTS kyc_free_orders integer CHECK (kyc_free_orders BETWEEN 0 AND 50),
  ADD COLUMN IF NOT EXISTS kyc_orders_used integer NOT NULL DEFAULT 0;

-- What is missing: {Mobile, Address, PAN / GSTIN}; empty = complete.
CREATE OR REPLACE FUNCTION public.lwb_party_missing(p_mobile text, p_address text, p_pan text, p_gstin text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT array_remove(ARRAY[
    CASE WHEN length(regexp_replace(coalesce(p_mobile,''), '\D', '', 'g')) < 10 THEN 'Mobile' END,
    CASE WHEN btrim(coalesce(p_address,'')) = '' THEN 'Address' END,
    CASE WHEN btrim(coalesce(p_pan,'')) = '' AND btrim(coalesce(p_gstin,'')) = '' THEN 'PAN / GSTIN' END
  ], NULL);
$fn$;

-- PO Entry: the party's details status for the signed-in user.
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
    'pan', m.pan, 'gstin', m.gstin);
END;
$fn$;

-- Shared checks for what a salesman types.
CREATE OR REPLACE FUNCTION public.lwb_check_party_fields(p_mobile text, p_pan text, p_gstin text)
RETURNS void LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $fn$
BEGIN
  IF btrim(coalesce(p_mobile,'')) <> '' AND regexp_replace(p_mobile, '\D', '', 'g') !~ '^(91)?[6-9][0-9]{9}$' THEN
    RAISE EXCEPTION 'Mobile must be a 10-digit number.';
  END IF;
  IF btrim(coalesce(p_pan,'')) <> '' AND upper(btrim(p_pan)) !~ '^[A-Z]{5}[0-9]{4}[A-Z]$' THEN
    RAISE EXCEPTION 'PAN format must be 5 letters + 4 numbers + 1 letter.';
  END IF;
  IF btrim(coalesce(p_gstin,'')) <> '' AND upper(btrim(p_gstin)) !~ '^[0-9]{2}[A-Z0-9]{13}$' THEN
    RAISE EXCEPTION 'GSTIN must contain 15 valid-format characters.';
  END IF;
END;
$fn$;

-- PO Entry: fill a party's EMPTY fields (a saved value is never overwritten here).
CREATE OR REPLACE FUNCTION public.lwb_sales_fill_party_details(p_customer_id uuid, p_mobile text, p_address text,
  p_city text, p_pincode text, p_pan text, p_gstin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  m public.lwb_customer_master%ROWTYPE;
  v_mobile text := nullif(regexp_replace(coalesce(p_mobile,''), '\D', '', 'g'), '');
  v_pan text := nullif(upper(btrim(coalesce(p_pan,''))), '');
  v_gstin text := nullif(upper(btrim(coalesce(p_gstin,''))), '');
BEGIN
  IF NOT public.lwb_po_entry_user() THEN RAISE EXCEPTION 'Only Admin, Manager or Salesman can fill party details'; END IF;
  SELECT * INTO m FROM public.lwb_customer_master WHERE id = p_customer_id FOR UPDATE;
  IF NOT FOUND OR NOT public.lwb_party_visible(m.id) THEN RAISE EXCEPTION 'Party not found in your list.'; END IF;
  PERFORM public.lwb_check_party_fields(v_mobile, v_pan, v_gstin);
  v_mobile := right(v_mobile, 10);
  UPDATE public.lwb_customer_master SET
    mobile = CASE WHEN length(regexp_replace(coalesce(mobile,''), '\D', '', 'g')) < 10 THEN coalesce(v_mobile, mobile) ELSE mobile END,
    billing_address = coalesce(nullif(btrim(billing_address),''), nullif(btrim(coalesce(p_address,'')),'')),
    city = coalesce(nullif(btrim(city),''), nullif(btrim(coalesce(p_city,'')),'')),
    pincode = coalesce(nullif(btrim(pincode),''), nullif(btrim(coalesce(p_pincode,'')),'')),
    gstin = coalesce(nullif(btrim(gstin),''), v_gstin),
    pan = coalesce(nullif(btrim(pan),''), v_pan, CASE WHEN v_gstin IS NOT NULL THEN substr(v_gstin, 3, 10) END),
    gst_registration_status = CASE WHEN coalesce(nullif(btrim(gstin),''), v_gstin) IS NOT NULL THEN 'REGISTERED' ELSE gst_registration_status END
  WHERE id = m.id;
  RETURN public.lwb_party_kyc(m.id);
END;
$fn$;

-- PO Entry: a salesman adds a new party; it becomes his party at once.
CREATE OR REPLACE FUNCTION public.lwb_sales_create_party(p_name text, p_mobile text, p_address text,
  p_city text, p_pincode text, p_pan text, p_gstin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_name text := upper(regexp_replace(btrim(coalesce(p_name,'')), '\s+', ' ', 'g'));
  v_mobile text := right(regexp_replace(coalesce(p_mobile,''), '\D', '', 'g'), 10);
  v_pan text := nullif(upper(btrim(coalesce(p_pan,''))), '');
  v_gstin text := nullif(upper(btrim(coalesce(p_gstin,''))), '');
  v_dup record;
  v_row public.lwb_customer_master%ROWTYPE;
  v_me text;
BEGIN
  IF NOT public.lwb_po_entry_user() THEN RAISE EXCEPTION 'Only Admin, Manager or Salesman can add a party'; END IF;
  IF length(v_name) < 2 THEN RAISE EXCEPTION 'Enter the party name.'; END IF;
  PERFORM public.lwb_check_party_fields(p_mobile, v_pan, v_gstin);
  IF cardinality(public.lwb_party_missing(v_mobile, p_address, v_pan, v_gstin)) > 0 THEN
    RAISE EXCEPTION 'Fill %: a new party needs mobile, address and PAN or GSTIN.',
      array_to_string(public.lwb_party_missing(v_mobile, p_address, v_pan, v_gstin), ', ');
  END IF;
  -- Same name ignoring spaces and punctuation = same party (Party Master "Duplicates only" uses this rule).
  SELECT customer_code, customer_name INTO v_dup FROM public.lwb_customer_master
  WHERE regexp_replace(upper(coalesce(customer_name,'')), '[^A-Z0-9]', '', 'g') = regexp_replace(v_name, '[^A-Z0-9]', '', 'g')
  LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Party "%"% already exists. Ask the Sales Head to assign it to you.', v_dup.customer_name, coalesce(' (' || v_dup.customer_code || ')', '');
  END IF;

  INSERT INTO public.lwb_customer_master (customer_name, gst_registration_status, pan, gstin, billing_address, city, state,
    pincode, mobile, credit_days, is_active)
  VALUES (v_name, CASE WHEN v_gstin IS NULL THEN 'UNREGISTERED' ELSE 'REGISTERED' END,
    coalesce(v_pan, substr(v_gstin, 3, 10)), v_gstin, btrim(p_address), nullif(btrim(coalesce(p_city,'')),''), 'Gujarat',
    nullif(btrim(coalesce(p_pincode,'')),''), v_mobile, 0, true)
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
    concat_ws(' · ', v_row.customer_name, v_row.city, v_mobile) || '. Added by ' || coalesce(v_me,'a salesman') || ' from PO Entry. Check it in Party Master.',
    'PARTY_CREATED'
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') AND p.id IS DISTINCT FROM auth.uid();

  RETURN jsonb_build_object('id', v_row.id, 'customer_code', v_row.customer_code, 'customer_name', v_row.customer_name);
END;
$fn$;

-- Every salesman order: count it while the party's details are missing, refuse it past the limit.
CREATE OR REPLACE FUNCTION public.lwb_orders_party_details_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  m public.lwb_customer_master%ROWTYPE;
  v_missing text[];
  v_limit integer;
BEGIN
  IF NOT public.lwb_is_sales_user() THEN RETURN NEW; END IF;
  SELECT * INTO m FROM public.lwb_customer_master
  WHERE upper(btrim(customer_name)) = upper(btrim(coalesce(NEW.customer_name,'')))
  ORDER BY is_active DESC NULLS LAST LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;
  v_missing := public.lwb_party_missing(m.mobile, m.billing_address, m.pan, m.gstin);
  IF cardinality(v_missing) = 0 THEN RETURN NEW; END IF;
  v_limit := coalesce(m.kyc_free_orders, (SELECT s.kyc_free_orders FROM public.lwb_sales_settings s WHERE s.id = 1), 3);
  IF m.kyc_orders_used >= v_limit THEN
    RAISE EXCEPTION 'Party details missing: % has no %. Fill the party details first (% orders were allowed without them).',
      m.customer_name, array_to_string(v_missing, ', '), v_limit;
  END IF;
  UPDATE public.lwb_customer_master SET kyc_orders_used = kyc_orders_used + 1 WHERE id = m.id;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS trg_lwb_orders_party_details ON public.orders;
CREATE TRIGGER trg_lwb_orders_party_details BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.lwb_orders_party_details_guard();

-- Sales Team Setup: default number of orders allowed with missing details.
CREATE OR REPLACE FUNCTION public.lwb_save_party_detail_limit(p_orders integer)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF p_orders IS NULL OR p_orders NOT BETWEEN 0 AND 50 THEN RAISE EXCEPTION 'Orders must be 0 to 50'; END IF;
  UPDATE public.lwb_sales_settings SET kyc_free_orders = p_orders, updated_at = now(), updated_by = auth.uid() WHERE id = 1;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_party_kyc(uuid), public.lwb_sales_fill_party_details(uuid,text,text,text,text,text,text),
  public.lwb_sales_create_party(text,text,text,text,text,text,text), public.lwb_orders_party_details_guard(),
  public.lwb_save_party_detail_limit(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_kyc(uuid), public.lwb_sales_fill_party_details(uuid,text,text,text,text,text,text),
  public.lwb_sales_create_party(text,text,text,text,text,text,text), public.lwb_save_party_detail_limit(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_party_missing(text,text,text,text), public.lwb_check_party_fields(text,text,text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check (all true):
-- SELECT to_regprocedure('public.lwb_party_kyc(uuid)') IS NOT NULL AS kyc_ready,
--        to_regprocedure('public.lwb_sales_create_party(text,text,text,text,text,text,text)') IS NOT NULL AS new_party_ready,
--        EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_orders_party_details') AS order_rule_ready;
