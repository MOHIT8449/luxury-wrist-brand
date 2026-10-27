-- LUXURY WRIST BRAND ERP — DRIVER UPI / BANK PAYMENT PHOTO UPLOAD FIX
--
-- RUN ONCE in Supabase SQL Editor, after lwb_driver_payment_setup.sql. Safe to run again.
--
-- Bug (27 Oct 2026): "Payment photo upload failed: new row violates row-level security policy".
-- The old POD upload policy allows a driver to upload only while the order status is
-- loaded / invoiced. Payment screenshots are also added or corrected after delivery,
-- when the order can have another status, so the upload was blocked.
-- This adds one more upload rule, only for payment photos (file name upi-*):
-- the driver's own folder uid/order_id/, an order assigned to his phone or already
-- reported by him, and the payment is not yet verified by Accounts.
-- Nothing else changes: no orders, payments, ledger, stock or Tally rows.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_driver_can_upload_pay_photo(p_order text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $fn$
  SELECT EXISTS(
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) = 'driver'
      AND (
        EXISTS(SELECT 1 FROM public.dispatch_assignments a
               WHERE a.order_id::text = p_order
                 AND public.lwb_driver_phone_matches(p.mobile, a.driver_mobile))
        OR EXISTS(SELECT 1 FROM public.lwb_delivery_reports r
                  WHERE r.order_id::text = p_order AND r.driver_user_id = auth.uid())
      )
  )
  AND NOT EXISTS(
    SELECT 1 FROM public.lwb_delivery_reports r
    WHERE r.order_id::text = p_order AND r.payment_status = 'VERIFIED'
  );
$fn$;

REVOKE ALL ON FUNCTION public.lwb_driver_can_upload_pay_photo(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_driver_can_upload_pay_photo(text) TO authenticated;

DROP POLICY IF EXISTS lwb_delivery_pay_photo_upload ON storage.objects;
CREATE POLICY lwb_delivery_pay_photo_upload
 ON storage.objects FOR INSERT TO authenticated
 WITH CHECK(
  bucket_id = 'lwb-delivery-pod'
  AND (storage.foldername(name))[1] = auth.uid()::text
  AND storage.filename(name) LIKE 'upi-%'
  AND public.lwb_driver_can_upload_pay_photo((storage.foldername(name))[2])
 );

COMMIT;

-- Expected: 1 row, true.
SELECT 'payment photo upload rule' AS item, EXISTS (SELECT 1 FROM pg_policies
  WHERE schemaname = 'storage' AND tablename = 'objects'
    AND policyname = 'lwb_delivery_pay_photo_upload') AS ok;
