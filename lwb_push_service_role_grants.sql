-- Phone alerts: let the lwb-web-push Edge Function (service_role) read who a
-- notification is for and whether that login is active.
-- Without these, Test said "Active ERP login required (403)" and real ERP
-- notifications could not be read for sending. Read-only; safe to re-run.
GRANT SELECT (id, active, role) ON public.user_profiles TO service_role;
GRANT SELECT (id, user_id, title, message, notification_type, order_id, is_read, created_at)
  ON public.erp_notifications TO service_role;

-- Check: both should be true.
SELECT has_column_privilege('service_role','public.user_profiles','active','SELECT') AS profiles_ok,
       has_column_privilege('service_role','public.erp_notifications','user_id','SELECT') AS notifications_ok;
