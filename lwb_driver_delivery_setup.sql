-- LUXURY WRIST BRAND ERP — PHASE 1: DRIVER & DELIVERY / POD / PAYMENT REPORT
-- Supabase SQL Editor: execute ONCE, then refresh schema.
--
-- 1. Existing orders/dispatch remain the source of truth.
-- 2. Driver gets ONLY his own assigned LOADED/INVOICED orders.
-- 3. Driver's delivery/POD/cash report is IMMUTABLE after submission.
-- 4. Payment reported by driver is NOT posted to ERP outstanding or Tally.
-- 5. No modifications to existing tax invoices, order status, stock or ledger.
-- 6. Existing non-driver roles keep their earlier SQL access.
BEGIN;

-- Extend existing role-management RPC: the Admin may now assign DRIVER.
CREATE OR REPLACE FUNCTION public.lwb_admin_set_user_role(
  p_user_id uuid,p_role text,p_full_name text,p_active boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $fn$
DECLARE
  v_role text := lower(btrim(coalesce(p_role,'')));
  v_email text;
  v_name text;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS(
    SELECT 1 FROM public.user_profiles p
    WHERE p.id=auth.uid() AND p.active IS TRUE AND lower(btrim(p.role))='admin'
  ) THEN RAISE EXCEPTION 'Active ERP Admin required'; END IF;
  IF p_user_id IS NULL OR p_active IS NULL THEN
    RAISE EXCEPTION 'Select existing Auth user and active status'; END IF;
  IF v_role NOT IN ('admin','accounts','manager','sales','warehouse','transport','driver') THEN
    RAISE EXCEPTION 'Invalid ERP Role: %', v_role; END IF;
  SELECT u.email::text INTO v_email FROM auth.users u WHERE u.id=p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Auth user not found'; END IF;
  IF p_user_id=auth.uid() AND (v_role<>'admin' OR p_active IS NOT TRUE) THEN
    RAISE EXCEPTION 'Cannot revoke your own active Admin access'; END IF;
  v_name:=coalesce(nullif(btrim(p_full_name),''),split_part(v_email,'@',1));
  IF length(v_name)>150 THEN RAISE EXCEPTION 'Full Name maximum 150 characters'; END IF;
  INSERT INTO public.user_profiles(id,full_name,role,active)
  VALUES(p_user_id,v_name,v_role,p_active)
  ON CONFLICT(id) DO UPDATE
  SET full_name=excluded.full_name,role=excluded.role,active=excluded.active;
END;
$fn$;

-- Admin-only: set the Driver Login mobile that must match the Sales Head's
-- saved dispatch_assignments.driver_mobile. Driver cannot self-edit mapping.
CREATE OR REPLACE FUNCTION public.lwb_admin_set_driver_mobile(
 p_user_id uuid,p_mobile text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $fn$
DECLARE v_phone text:=regexp_replace(coalesce(p_mobile,''),'[^0-9]','','g');
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(
  SELECT 1 FROM public.user_profiles p
  WHERE p.id=auth.uid() AND p.active=true AND lower(btrim(p.role))='admin'
 ) THEN RAISE EXCEPTION 'Active Admin required'; END IF;
 IF v_phone ~ '^91[6-9][0-9]{9}$' THEN v_phone:=right(v_phone,10); END IF;
 IF v_phone !~ '^[6-9][0-9]{9}$' THEN
  RAISE EXCEPTION 'Enter a valid Indian Driver Mobile (10 digits or +91)';
 END IF;
 IF NOT EXISTS(
  SELECT 1 FROM public.user_profiles p
  WHERE p.id=p_user_id AND lower(btrim(p.role))='driver'
 ) THEN RAISE EXCEPTION 'Assign the DRIVER role before mapping mobile'; END IF;
 IF EXISTS(
  SELECT 1 FROM public.user_profiles p
  WHERE p.id<>p_user_id AND p.active=true AND lower(btrim(p.role))='driver'
    AND right(regexp_replace(coalesce(p.mobile,''),'[^0-9]','','g'),10)=v_phone
 ) THEN RAISE EXCEPTION 'Another active driver login already uses that Mobile'; END IF;
 UPDATE public.user_profiles SET mobile=v_phone WHERE id=p_user_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_admin_driver_mobiles()
RETURNS TABLE(user_id uuid,mobile text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $fn$
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(
  SELECT 1 FROM public.user_profiles p
  WHERE p.id=auth.uid() AND p.active=true AND lower(btrim(p.role))='admin'
 ) THEN RAISE EXCEPTION 'Active Admin required'; END IF;
 RETURN QUERY SELECT p.id,p.mobile::text
 FROM public.user_profiles p WHERE lower(btrim(p.role))='driver';
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_admin_set_user_role(uuid,text,text,boolean)
 FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.lwb_admin_set_driver_mobile(uuid,text)
 FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.lwb_admin_driver_mobiles()
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_admin_set_user_role(uuid,text,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_admin_set_driver_mobile(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_admin_driver_mobiles() TO authenticated;

-- Comparison helper: accept local 10-digit or +91 numbers, never compare
-- only short substrings or allow blank/unverified phone numbers.
CREATE OR REPLACE FUNCTION public.lwb_driver_phone_matches(
  p_profile_mobile text,p_assignment_mobile text
) RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path=''
AS $fn$
 SELECT
  CASE
   WHEN regexp_replace(coalesce(p_profile_mobile,''),'[^0-9]','','g')
          ~ '^(91)?[6-9][0-9]{9}$'
    AND regexp_replace(coalesce(p_assignment_mobile,''),'[^0-9]','','g')
          ~ '^(91)?[6-9][0-9]{9}$'
   THEN right(regexp_replace(p_profile_mobile,'[^0-9]','','g'),10)
        =right(regexp_replace(p_assignment_mobile,'[^0-9]','','g'),10)
   ELSE false
  END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_driver_phone_matches(text,text)
 FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.lwb_driver_phone_matches(text,text) TO authenticated;

-- Private, image-only POD bucket. Metadata / images are NOT publicly readable.
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES('lwb-delivery-pod','lwb-delivery-pod',false,5242880,
 ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT(id) DO UPDATE SET
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

CREATE TABLE IF NOT EXISTS public.lwb_delivery_reports(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL UNIQUE REFERENCES public.orders(id) ON DELETE RESTRICT,
  assignment_id uuid NOT NULL REFERENCES public.dispatch_assignments(id) ON DELETE RESTRICT,
  driver_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  delivery_status text NOT NULL CHECK(delivery_status IN ('DELIVERED','PARTIAL','NOT_DELIVERED')),
  received_by text,
  pod_path text,
  delivery_note text,
  cash_reported numeric(14,2) NOT NULL DEFAULT 0 CHECK(cash_reported>=0),
  payment_mode text CHECK(payment_mode IN ('CASH','UPI','BANK','CHEQUE')),
  payment_reference text,
  collection_review_status text NOT NULL DEFAULT 'PENDING_OFFICE'
    CHECK(collection_review_status='PENDING_OFFICE'),
  reported_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lwb_delivery_collection_mode_valid CHECK (
    (cash_reported=0 AND payment_mode IS NULL AND payment_reference IS NULL)
    OR (cash_reported>0 AND payment_mode IS NOT NULL)
  ),
  CONSTRAINT lwb_delivery_proof_required CHECK(
    delivery_status='NOT_DELIVERED'
    OR (nullif(btrim(coalesce(received_by,'')),'') IS NOT NULL
        AND nullif(btrim(coalesce(pod_path,'')),'') IS NOT NULL)
  )
);
CREATE INDEX IF NOT EXISTS lwb_delivery_reports_driver_idx
  ON public.lwb_delivery_reports(driver_user_id,reported_at DESC);

ALTER TABLE public.lwb_delivery_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lwb_delivery_report_read ON public.lwb_delivery_reports;
CREATE POLICY lwb_delivery_report_read
 ON public.lwb_delivery_reports FOR SELECT TO authenticated
 USING(
  (driver_user_id=auth.uid() AND EXISTS(
    SELECT 1 FROM public.user_profiles ap
    WHERE ap.id=auth.uid() AND ap.active=true
      AND lower(btrim(ap.role))='driver'
  ))
  OR EXISTS(
    SELECT 1 FROM public.user_profiles p
    WHERE p.id=auth.uid() AND p.active=true
    AND lower(btrim(p.role)) IN ('admin','manager','accounts','warehouse')
  )
 );
REVOKE ALL ON TABLE public.lwb_delivery_reports FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.lwb_delivery_reports TO authenticated;

-- Storage objects are private. Drivers can upload only in their own
-- uid/order_id folder for a LOADED/INVOICED order assigned to their phone.
DROP POLICY IF EXISTS lwb_delivery_pod_upload ON storage.objects;
CREATE POLICY lwb_delivery_pod_upload
 ON storage.objects FOR INSERT TO authenticated
 WITH CHECK(
  bucket_id='lwb-delivery-pod'
  AND (storage.foldername(name))[1]=auth.uid()::text
  AND EXISTS(
    SELECT 1 FROM public.user_profiles p
    JOIN public.dispatch_assignments a
      ON public.lwb_driver_phone_matches(p.mobile,a.driver_mobile)
    JOIN public.orders o ON o.id=a.order_id
    WHERE p.id=auth.uid() AND p.active=true
      AND lower(btrim(p.role))='driver'
      AND o.id::text=(storage.foldername(name))[2]
      AND o.status IN ('loaded','invoiced')
  )
 );

DROP POLICY IF EXISTS lwb_delivery_pod_read ON storage.objects;
CREATE POLICY lwb_delivery_pod_read
 ON storage.objects FOR SELECT TO authenticated
 USING(
  bucket_id='lwb-delivery-pod'
  AND (
    ((storage.foldername(name))[1]=auth.uid()::text
      AND EXISTS(
        SELECT 1 FROM public.user_profiles ap
        WHERE ap.id=auth.uid() AND ap.active=true
          AND lower(btrim(ap.role))='driver'
      ))
    OR EXISTS(
      SELECT 1 FROM public.user_profiles p
      WHERE p.id=auth.uid() AND p.active=true
      AND lower(btrim(p.role)) IN ('admin','manager','accounts','warehouse')
    )
  )
 );

-- Existing permissive "authenticated can do everything" policies must
-- NOT let a DRIVER bypass the new driver-only RPC by using the API directly.
-- Add DRIVER-only restrictive guards to all existing RLS-enabled PUBLIC
-- tables, except own user profile and this controlled delivery table.
-- All non-driver roles retain the previous policy behavior.
DO $guard$
DECLARE t record;
BEGIN
 FOR t IN
  SELECT c.relname AS table_name
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relkind IN ('r','p')
    AND c.relrowsecurity
    AND c.relname NOT IN ('user_profiles','lwb_delivery_reports')
 LOOP
  EXECUTE format('DROP POLICY IF EXISTS lwb_driver_disallow_other_modules ON public.%I',t.table_name);
  EXECUTE format(
   'CREATE POLICY lwb_driver_disallow_other_modules ON public.%I AS RESTRICTIVE
    FOR ALL TO authenticated
    USING(NOT EXISTS (
      SELECT 1 FROM public.user_profiles p
      WHERE p.id=auth.uid() AND lower(btrim(p.role))=''driver''
    ))
    WITH CHECK(NOT EXISTS (
      SELECT 1 FROM public.user_profiles p
      WHERE p.id=auth.uid() AND lower(btrim(p.role))=''driver''
    ))',t.table_name);
 END LOOP;
END
$guard$;

-- Driver & Admin/Manager/Accounts read-only order list, with SKU/Loaded CS,
-- private POD metadata and optional customer-master billing address.
-- Important: NO direct database SELECT on orders required for Driver.
CREATE OR REPLACE FUNCTION public.lwb_driver_list_delivery_orders()
RETURNS SETOF jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $fn$
DECLARE v_role text; v_mobile text;
BEGIN
 SELECT lower(btrim(p.role)),p.mobile INTO v_role,v_mobile
 FROM public.user_profiles p
 WHERE p.id=auth.uid() AND p.active=true;
 IF v_role NOT IN ('driver','admin','manager','accounts') OR v_role IS NULL THEN
  RAISE EXCEPTION 'Active Driver / Manager / Accounts login required';
 END IF;
 IF v_role='driver' AND coalesce(v_mobile,'')='' THEN
  RAISE EXCEPTION 'Driver profile Mobile missing; Admin must map your Login Mobile';
 END IF;
 RETURN QUERY
 SELECT jsonb_build_object(
   'order_id',o.id,'order_no',o.order_no,
   'order_date',o.order_date,'party_name',o.customer_name,
   'party_address',cm.billing_address,
   'party_city',cm.city,'party_state',cm.state,'party_pincode',cm.pincode,
   'order_status',o.status,
   'vehicle_no',a.vehicle_no,
   'driver_name',a.driver_name,'driver_mobile',a.driver_mobile,
   'loading_person',a.loading_person,
   'transport_name',a.transporter_name,
   'loaded_skus',COALESCE((
      SELECT jsonb_agg(
       jsonb_build_object('sku',i.sku_name,'cases',i.loaded_qty,'rate',i.rate)
       ORDER BY i.sku_name)
      FROM public.order_items i
      WHERE i.order_id=o.id AND coalesce(i.loaded_qty,0)>0
   ),'[]'::jsonb),
   'loaded_cases',coalesce((
      SELECT sum(i.loaded_qty) FROM public.order_items i
      WHERE i.order_id=o.id AND coalesce(i.loaded_qty,0)>0
   ),0),
   'loaded_goods_value',coalesce((
      SELECT sum(round(i.loaded_qty::numeric * coalesce(i.rate,0)::numeric,2))
      FROM public.order_items i WHERE i.order_id=o.id AND coalesce(i.loaded_qty,0)>0
   ),0),
   'report',CASE WHEN d.id IS NULL THEN NULL ELSE jsonb_build_object(
     'id',d.id,'delivery_status',d.delivery_status,
     'received_by',d.received_by,'pod_path',d.pod_path,
     'delivery_note',d.delivery_note,'cash_reported',d.cash_reported,
     'payment_mode',d.payment_mode,'payment_reference',d.payment_reference,
     'collection_review_status',d.collection_review_status,
     'reported_at',d.reported_at
   ) END
 )
 FROM public.dispatch_assignments a
 JOIN public.orders o ON o.id=a.order_id
 LEFT JOIN public.lwb_delivery_reports d ON d.order_id=o.id
 LEFT JOIN LATERAL (
  SELECT c.billing_address,c.city,c.state,c.pincode
  FROM public.lwb_customer_master c
  WHERE lower(btrim(c.customer_name))=lower(btrim(o.customer_name))
  ORDER BY c.customer_code LIMIT 1
 ) cm ON true
 WHERE (o.status IN ('loaded','invoiced') OR d.id IS NOT NULL)
  AND (
   v_role IN ('admin','manager','accounts')
   OR public.lwb_driver_phone_matches(v_mobile,a.driver_mobile)
  )
 ORDER BY coalesce(d.reported_at,o.order_date) DESC
 LIMIT 300;
END;
$fn$;

-- Atomic submission: delivery report cannot be forged for another Driver.
-- No record is ever posted to Accounts or changed in Stock here.
CREATE OR REPLACE FUNCTION public.lwb_driver_submit_delivery(
 p_order_id uuid,p_delivery_status text,p_received_by text,
 p_pod_path text,p_delivery_note text,
 p_collection_amount numeric,p_payment_mode text,p_payment_reference text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $fn$
DECLARE
 v_role text;v_mobile text;v_a public.dispatch_assignments%ROWTYPE;
 v_order_status text;v_status text:=upper(btrim(coalesce(p_delivery_status,'')));
 v_mode text:=upper(btrim(coalesce(p_payment_mode,'')));
 v_amount numeric:=coalesce(p_collection_amount,0);
 v_proof text:=nullif(btrim(coalesce(p_pod_path,'')),'');
 v_note text:=nullif(btrim(coalesce(p_delivery_note,'')),'');
 v_recipient text:=nullif(btrim(coalesce(p_received_by,'')),'');
 v_ref text:=nullif(btrim(coalesce(p_payment_reference,'')),'');
 v_saved public.lwb_delivery_reports%ROWTYPE;
BEGIN
 SELECT lower(btrim(p.role)),p.mobile INTO v_role,v_mobile
 FROM public.user_profiles p WHERE p.id=auth.uid() AND p.active=true;
 IF coalesce(v_role,'')<>'driver' THEN
  RAISE EXCEPTION 'Only the assigned active DRIVER may submit delivery';
 END IF;
 IF v_status NOT IN('DELIVERED','PARTIAL','NOT_DELIVERED') THEN
  RAISE EXCEPTION 'Select valid delivery status'; END IF;
 IF p_order_id IS NULL THEN RAISE EXCEPTION 'Select an assigned order'; END IF;
 SELECT o.status INTO v_order_status
 FROM public.orders o WHERE o.id=p_order_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
 IF v_order_status NOT IN('loaded','invoiced') THEN
  RAISE EXCEPTION 'Order not loaded yet. Cannot submit delivery.'; END IF;
 SELECT a.* INTO v_a FROM public.dispatch_assignments a
 WHERE a.order_id=p_order_id;
 IF NOT FOUND OR NOT public.lwb_driver_phone_matches(v_mobile,v_a.driver_mobile)
 THEN RAISE EXCEPTION 'This order is not assigned to your Driver Login Mobile'; END IF;
 IF EXISTS(SELECT 1 FROM public.lwb_delivery_reports d WHERE d.order_id=p_order_id)
 THEN RAISE EXCEPTION 'Delivery report already submitted; Admin must review corrections'; END IF;
 IF length(coalesce(v_note,''))>1000 OR length(coalesce(v_recipient,''))>150 THEN
  RAISE EXCEPTION 'Receiver / Note too long'; END IF;
 IF v_status IN ('DELIVERED','PARTIAL') THEN
  IF v_recipient IS NULL OR v_proof IS NULL THEN
   RAISE EXCEPTION 'Receiver Name and POD Photo are required for delivered / partial';
  END IF;
 ELSIF v_note IS NULL THEN
  RAISE EXCEPTION 'Reason is required for NOT DELIVERED';
 END IF;
 IF v_proof IS NOT NULL THEN
  IF left(v_proof,length(auth.uid()::text)+length(p_order_id::text)+2)
       <>auth.uid()::text||'/'||p_order_id::text||'/' THEN
   RAISE EXCEPTION 'POD Photo path does not belong to this Driver + Order'; END IF;
  IF NOT EXISTS(
    SELECT 1 FROM storage.objects ob
    WHERE ob.bucket_id='lwb-delivery-pod' AND ob.name=v_proof
      AND ob.owner_id=auth.uid()::text
  ) THEN RAISE EXCEPTION 'POD Photo is not uploaded by this Driver'; END IF;
 END IF;
 IF v_amount<0 OR v_amount>99999999.99 THEN
  RAISE EXCEPTION 'Invalid reported collection amount'; END IF;
 IF v_status='NOT_DELIVERED' AND v_amount<>0 THEN
  RAISE EXCEPTION 'Collection cannot be recorded as delivered payment if delivery failed'; END IF;
 IF v_amount=0 THEN
  IF v_mode<>'' OR v_ref IS NOT NULL THEN
   RAISE EXCEPTION 'Clear Mode/Reference if no collection'; END IF;
  v_mode:=NULL;
 ELSE
  IF v_mode NOT IN('CASH','BANK','UPI','CHEQUE') THEN
   RAISE EXCEPTION 'Select collection method'; END IF;
  IF v_mode='CASH' AND v_amount>=200000 THEN
   RAISE EXCEPTION 'Cash entry >= Rs 2 lakh requires compliance review. Do not collect it in this module.';
  END IF;
  IF v_mode<>'CASH' AND v_ref IS NULL THEN
   RAISE EXCEPTION 'Provide UTR/Bank/Cheque reference'; END IF;
 END IF;
 INSERT INTO public.lwb_delivery_reports(
  order_id,assignment_id,driver_user_id,
  delivery_status,received_by,pod_path,delivery_note,
  cash_reported,payment_mode,payment_reference
 ) VALUES(
  p_order_id,v_a.id,auth.uid(),
  v_status,v_recipient,v_proof,v_note,
  v_amount,v_mode,v_ref
 ) RETURNING * INTO v_saved;
 RETURN jsonb_build_object(
  'report_id',v_saved.id,'order_id',v_saved.order_id,
  'delivery_status',v_saved.delivery_status,
  'collection_review_status',v_saved.collection_review_status,
  'payment_reported',v_saved.cash_reported,
  'reported_at',v_saved.reported_at
 );
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_driver_list_delivery_orders() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.lwb_driver_submit_delivery(uuid,text,text,text,text,numeric,text,text)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_driver_list_delivery_orders() TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_driver_submit_delivery(uuid,text,text,text,text,numeric,text,text)
 TO authenticated;

COMMIT;
NOTIFY pgrst,'reload schema';

-- Read-only verification. Expect two objects (table, private POD bucket).
SELECT 'delivery_reports_table' AS item
 WHERE to_regclass('public.lwb_delivery_reports') IS NOT NULL
UNION ALL
SELECT 'pod_private_bucket'
 WHERE EXISTS(SELECT 1 FROM storage.buckets WHERE id='lwb-delivery-pod' AND public=false);
