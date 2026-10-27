-- LUXURY WRIST BRAND ERP — DRIVER POD PHOTO UPLOAD FIX
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- Bug (27 Oct 2026, LXY-00013): "POD photo upload failed: new row violates row-level
-- security policy". The POD upload rule looked up user_profiles, dispatch_assignments
-- and orders as the driver, so any read rule on those tables could hide the driver's
-- own order and block the upload. The check now runs in a SECURITY DEFINER function
-- with the same rule: active DRIVER, his own folder uid/order_id/, order assigned to
-- his login mobile, order status loaded / invoiced, no delivery report yet.
-- Nothing else changes: no orders, payments, stock or Tally rows.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_driver_can_upload_pod(p_order text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $fn$
  SELECT EXISTS(
    SELECT 1
    FROM public.user_profiles p
    JOIN public.dispatch_assignments a
      ON public.lwb_driver_phone_matches(p.mobile, a.driver_mobile)
    JOIN public.orders o ON o.id = a.order_id
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) = 'driver'
      AND o.id::text = p_order
      AND lower(btrim(o.status::text)) IN ('loaded','invoiced')
      AND NOT EXISTS(SELECT 1 FROM public.lwb_delivery_reports d WHERE d.order_id = o.id)
  );
$fn$;

REVOKE ALL ON FUNCTION public.lwb_driver_can_upload_pod(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_driver_can_upload_pod(text) TO authenticated;

DROP POLICY IF EXISTS lwb_delivery_pod_upload ON storage.objects;
CREATE POLICY lwb_delivery_pod_upload
 ON storage.objects FOR INSERT TO authenticated
 WITH CHECK(
  bucket_id = 'lwb-delivery-pod'
  AND (storage.foldername(name))[1] = auth.uid()::text
  AND public.lwb_driver_can_upload_pod((storage.foldername(name))[2])
 );

COMMIT;

-- Expected: 2 rows, both true.
SELECT 'POD upload rule' AS item, EXISTS (SELECT 1 FROM pg_policies
  WHERE schemaname = 'storage' AND tablename = 'objects'
    AND policyname = 'lwb_delivery_pod_upload'
    AND with_check LIKE '%lwb_driver_can_upload_pod%') AS ok
UNION ALL SELECT 'payment photo rule', EXISTS (SELECT 1 FROM pg_policies
  WHERE schemaname = 'storage' AND tablename = 'objects'
    AND policyname = 'lwb_delivery_pay_photo_upload');
