-- LUXURY WRIST BRAND ERP — TAX INVOICE PRINT FROM THE ERP (Tally layout), OFF until Admin turns it on
--
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (11 Nov 2026): on a day Accounts is not in the office the bill is made in Tally by someone
-- else, and a mistake there cannot be changed. The ERP must print the same bill as the Tally print
-- (company header, Billed to / Shipped to, HSN, qty, rate incl. tax, GST %, CGST / SGST split, amount in
-- words, bank details, Scan and Pay QR, declaration), WITHOUT the sales invoice no. The option is hidden;
-- Admin turns it on (for today only or until turned off) and ticks who may use it; then they make, change
-- and print the bill from a PO. This is Mohit's new approval for an ERP tax invoice print (handover rule
-- "do not generate an official GST/Tally invoice without explicit new approval").
--
-- Tables (RPC only, no direct read / write):
--   lwb_tax_bill_settings  one row: on / off, last day, roles, seller block (header, bank, UPI, declaration)
--   lwb_tax_bills          one bill per PO: the lines / addresses as printed, so it opens again to change
-- RPCs: lwb_tax_bill_access(), lwb_tax_bill_access_set(on, until, roles, seller) [Admin],
--       lwb_tax_bill_orders(days), lwb_tax_bill_data(order), lwb_tax_bill_save(order, date, data, total)

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_tax_bill_settings (
  id smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  enabled boolean NOT NULL DEFAULT false,
  until_date date,
  roles text[] NOT NULL DEFAULT ARRAY['accounts','manager']::text[],
  seller jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.lwb_tax_bill_settings (id, seller) VALUES (1, jsonb_build_object(
  'name', 'Luxury Wrist Brand',
  'udyam', 'UDYAM-GJ-22-0022986',
  'fssai', '10724031001128',
  'address', E'401-402, UNITECH BUISSNESS HUB, OPP BBC,\nYOGI CHOWK, SURAT, GUJARAT-395010 INDIA',
  'contact', '',
  'email', '',
  'gstin', '24BMBPV2782C1Z4',
  'pan', 'BMBPV2782C',
  'state', 'Gujarat',
  'state_code', '24',
  'bank_name', 'ICICI Bank (India)',
  'ac_name', 'Luxury Wrist Brand',
  'ac_no', '',
  'ifsc', '',
  'upi', '',
  'jurisdiction', 'SURAT',
  'declaration', 'We declare that this invoice shows the actual price of the goods described and that all particulars are true and correct.'))
ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.lwb_tax_bill_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_tax_bill_settings FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_tax_bills (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE,
  bill_date date NOT NULL,
  data jsonb NOT NULL,
  grand_total numeric(14,2) NOT NULL DEFAULT 0,
  saves integer NOT NULL DEFAULT 1,
  made_by uuid,
  made_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_tax_bills ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_tax_bills FROM PUBLIC, anon, authenticated;

-- my role, '' when not an active login
CREATE OR REPLACE FUNCTION public.lwb_tax_bill_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
  SELECT coalesce((SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true), '');
$fn$;

-- true when I may make / print: Admin always; others only while it is on, not past its day, role ticked
CREATE OR REPLACE FUNCTION public.lwb_tax_bill_can()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
  SELECT public.lwb_tax_bill_role() = 'admin'
      OR EXISTS (SELECT 1 FROM public.lwb_tax_bill_settings s
                 WHERE s.id = 1 AND s.enabled
                   AND (s.until_date IS NULL OR s.until_date >= (now() AT TIME ZONE 'Asia/Kolkata')::date)
                   AND public.lwb_tax_bill_role() <> ''
                   AND public.lwb_tax_bill_role() = ANY (s.roles));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_tax_bill_access()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
  SELECT jsonb_build_object(
    'admin', public.lwb_tax_bill_role() = 'admin',
    'can', public.lwb_tax_bill_can(),
    'on', s.enabled AND (s.until_date IS NULL OR s.until_date >= (now() AT TIME ZONE 'Asia/Kolkata')::date),
    'until', s.until_date,
    'roles', to_jsonb(s.roles),
    'today', (now() AT TIME ZONE 'Asia/Kolkata')::date,
    'seller', CASE WHEN public.lwb_tax_bill_can() THEN s.seller ELSE NULL END)
  FROM public.lwb_tax_bill_settings s WHERE s.id = 1;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_tax_bill_access_set(p_enabled boolean, p_until date DEFAULT NULL,
  p_roles text[] DEFAULT NULL, p_seller jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_roles text[];
BEGIN
  IF public.lwb_tax_bill_role() <> 'admin' THEN RAISE EXCEPTION 'Only Admin can turn the tax invoice print on or off'; END IF;
  IF p_until IS NOT NULL AND p_until < v_today THEN RAISE EXCEPTION 'The last day cannot be before today'; END IF;
  IF p_roles IS NOT NULL THEN
    SELECT coalesce(array_agg(DISTINCT lower(btrim(r))), '{}') INTO v_roles FROM unnest(p_roles) r WHERE btrim(coalesce(r,'')) <> '';
    IF EXISTS (SELECT 1 FROM unnest(v_roles) r WHERE r NOT IN ('accounts','manager','warehouse')) THEN
      RAISE EXCEPTION 'Only Accounts, Sales Head or Godown can be given the tax invoice print';
    END IF;
    IF coalesce(p_enabled, false) AND cardinality(v_roles) = 0 THEN RAISE EXCEPTION 'Tick at least one who may print'; END IF;
  END IF;
  IF p_seller IS NOT NULL AND jsonb_typeof(p_seller) <> 'object' THEN RAISE EXCEPTION 'Wrong company details'; END IF;
  IF p_seller IS NOT NULL AND length(p_seller::text) > 6000 THEN RAISE EXCEPTION 'Company details are too long'; END IF;
  UPDATE public.lwb_tax_bill_settings SET
    enabled = coalesce(p_enabled, false),
    until_date = p_until,
    roles = coalesce(v_roles, roles),
    seller = CASE WHEN p_seller IS NULL THEN seller ELSE seller || p_seller END,
    updated_by = auth.uid(), updated_at = now()
  WHERE id = 1;
  RETURN public.lwb_tax_bill_access();
END
$fn$;

-- POs a bill can be made for: approved onwards, not cancelled, last p_days days (by PO date)
CREATE OR REPLACE FUNCTION public.lwb_tax_bill_orders(p_days integer DEFAULT 30)
RETURNS TABLE(order_id uuid, order_no text, order_date date, party text, status text, qty numeric, amount numeric,
              bill_total numeric, bill_saved_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
BEGIN
  IF NOT public.lwb_tax_bill_can() THEN RAISE EXCEPTION 'Tax invoice print is off. Ask Admin to turn it on.'; END IF;
  RETURN QUERY
  SELECT o.id, o.order_no::text, o.order_date::date, btrim(o.customer_name::text), lower(o.status::text),
         x.qty, x.amount, b.grand_total, b.updated_at
  FROM public.orders o
  LEFT JOIN LATERAL (
    SELECT sum(q.v) AS qty, round(sum(q.v * coalesce(q.rate,0)), 2) AS amount
    FROM (SELECT coalesce(nullif(j->>'loaded_qty','')::numeric, nullif(j->>'approved_qty','')::numeric,
                          nullif(j->>'ordered_qty','')::numeric, 0) AS v,
                 nullif(j->>'rate','')::numeric AS rate
          FROM public.order_items i, LATERAL to_jsonb(i) j WHERE i.order_id = o.id) q) x ON true
  LEFT JOIN public.lwb_tax_bills b ON b.order_id = o.id
  WHERE lower(coalesce(o.status::text,'')) NOT IN ('pending','draft','cancelled','canceled','rejected','deleted')
    AND o.order_date::date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - greatest(1, least(coalesce(p_days,30), 400))
  ORDER BY o.order_date DESC, o.order_no DESC
  LIMIT 1000;
END
$fn$;

-- Everything the bill needs for one PO: lines with HSN / GST from SKU Master, party from Party Master,
-- the company block, and the bill saved before (if any)
CREATE OR REPLACE FUNCTION public.lwb_tax_bill_data(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  o jsonb;
  v_party jsonb;
  v_items jsonb;
  v_saved jsonb;
BEGIN
  IF NOT public.lwb_tax_bill_can() THEN RAISE EXCEPTION 'Tax invoice print is off. Ask Admin to turn it on.'; END IF;
  SELECT to_jsonb(x) INTO o FROM public.orders x WHERE x.id = p_order_id;
  IF o IS NULL THEN RAISE EXCEPTION 'PO not found'; END IF;
  SELECT to_jsonb(c) INTO v_party FROM public.lwb_customer_master c
  WHERE (o ? 'customer_id' AND nullif(o->>'customer_id','') IS NOT NULL AND c.id::text = o->>'customer_id')
     OR upper(btrim(c.customer_name::text)) = upper(btrim(o->>'customer_name'))
  ORDER BY coalesce(c.id::text = o->>'customer_id', false) DESC, coalesce(to_jsonb(c)->>'is_active', 'true') = 'true' DESC
  LIMIT 1;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'sku', l.j->>'sku_name',
           'qty', l.qty,
           'rate', coalesce(nullif(l.j->>'rate','')::numeric, 0),
           'hsn', coalesce(s.j->>'hsn_code', ''),
           'gst', coalesce(nullif(s.j->>'gst_rate','')::numeric, 0),
           'cess', coalesce(nullif(s.j->>'cess_rate','')::numeric, 0)) ORDER BY l.n), '[]'::jsonb)
  INTO v_items
  FROM (SELECT j, row_number() OVER (ORDER BY length(j->>'id'), j->>'id') AS n,
               coalesce(nullif(j->>'loaded_qty','')::numeric, nullif(j->>'approved_qty','')::numeric,
                        nullif(j->>'ordered_qty','')::numeric, 0) AS qty
        FROM public.order_items i, LATERAL to_jsonb(i) j WHERE i.order_id = p_order_id) l
  LEFT JOIN LATERAL (SELECT to_jsonb(m) AS j FROM public.sku_master m
                     WHERE upper(btrim(m.sku_name::text)) = upper(btrim(l.j->>'sku_name')) LIMIT 1) s ON true
  WHERE l.qty > 0;
  SELECT jsonb_build_object('bill_date', b.bill_date, 'data', b.data, 'total', b.grand_total, 'saves', b.saves,
           'updated_at', b.updated_at,
           'by', (SELECT p.full_name FROM public.user_profiles p WHERE p.id = coalesce(b.updated_by, b.made_by)))
  INTO v_saved FROM public.lwb_tax_bills b WHERE b.order_id = p_order_id;
  RETURN jsonb_build_object(
    'order', jsonb_build_object('id', o->>'id', 'order_no', o->>'order_no', 'order_date', o->>'order_date',
                                'party', btrim(o->>'customer_name'), 'status', o->>'status'),
    'party', CASE WHEN v_party IS NULL THEN NULL ELSE jsonb_build_object(
               'name', v_party->>'customer_name', 'gstin', v_party->>'gstin', 'pan', v_party->>'pan',
               'address', v_party->>'billing_address', 'city', v_party->>'city', 'state', v_party->>'state',
               'pincode', v_party->>'pincode', 'mobile', v_party->>'mobile') END,
    'items', v_items,
    'saved', v_saved,
    'seller', (SELECT s.seller FROM public.lwb_tax_bill_settings s WHERE s.id = 1),
    'today', (now() AT TIME ZONE 'Asia/Kolkata')::date);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_tax_bill_save(p_order_id uuid, p_bill_date date, p_data jsonb, p_total numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
BEGIN
  IF NOT public.lwb_tax_bill_can() THEN RAISE EXCEPTION 'Tax invoice print is off. Ask Admin to turn it on.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.id = p_order_id) THEN RAISE EXCEPTION 'PO not found'; END IF;
  IF p_bill_date IS NULL OR p_bill_date > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1
     OR p_bill_date < (now() AT TIME ZONE 'Asia/Kolkata')::date - 400 THEN RAISE EXCEPTION 'Check the invoice date'; END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' OR jsonb_typeof(p_data->'lines') <> 'array'
     OR jsonb_array_length(p_data->'lines') = 0 THEN RAISE EXCEPTION 'Add at least one item line'; END IF;
  IF jsonb_array_length(p_data->'lines') > 60 OR length(p_data::text) > 60000 THEN RAISE EXCEPTION 'The bill is too long'; END IF;
  IF p_total IS NULL OR p_total <= 0 OR p_total > 100000000 THEN RAISE EXCEPTION 'Check the bill total'; END IF;
  INSERT INTO public.lwb_tax_bills AS b (order_id, bill_date, data, grand_total, made_by, updated_by)
  VALUES (p_order_id, p_bill_date, p_data, round(p_total, 2), auth.uid(), auth.uid())
  ON CONFLICT (order_id) DO UPDATE SET bill_date = excluded.bill_date, data = excluded.data,
    grand_total = excluded.grand_total, saves = b.saves + 1, updated_by = auth.uid(), updated_at = now();
  RETURN jsonb_build_object('ok', true, 'total', round(p_total, 2));
END
$fn$;

REVOKE ALL ON FUNCTION public.lwb_tax_bill_role(), public.lwb_tax_bill_can(), public.lwb_tax_bill_access(),
  public.lwb_tax_bill_access_set(boolean,date,text[],jsonb), public.lwb_tax_bill_orders(integer),
  public.lwb_tax_bill_data(uuid), public.lwb_tax_bill_save(uuid,date,jsonb,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_tax_bill_access(),
  public.lwb_tax_bill_access_set(boolean,date,text[],jsonb), public.lwb_tax_bill_orders(integer),
  public.lwb_tax_bill_data(uuid), public.lwb_tax_bill_save(uuid,date,jsonb,numeric) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'tax bill settings (off by default)' AS item, (to_regclass('public.lwb_tax_bill_settings') IS NOT NULL)::text AS ok
UNION ALL SELECT 'tax bills table', (to_regclass('public.lwb_tax_bills') IS NOT NULL)::text
UNION ALL SELECT 'bill data', (to_regprocedure('public.lwb_tax_bill_data(uuid)') IS NOT NULL)::text;
