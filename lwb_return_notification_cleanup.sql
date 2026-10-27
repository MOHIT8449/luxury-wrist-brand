-- LUXURY WRIST BRAND ERP — DRIVER RETURN NOTIFICATIONS FOLLOW THE RETURN
--
-- RUN ONCE in Supabase SQL Editor, after lwb_driver_return_edit_setup.sql. Safe to run again.
--
-- When a driver edits or cancels a pending return, the old return becomes CANCELLED.
-- Its "Return · LXY-… · Verify / Warehouse check" notifications are then removed,
-- so the Sales Head / Accounts see only the current return (no duplicates).
-- When a return is approved or rejected, those notifications are marked read for
-- everybody, so the "Driver return waiting" popup stops on every office login.
-- The notifications of a return are the ones written in the same save:
-- same order, return type, created within 5 seconds of the return.
-- Nothing else changes: no stock, GST, Tally, ledger or payment rows.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_return_notifications_follow_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $fn$
BEGIN
  IF OLD.status <> 'PENDING_OFFICE' OR NEW.status = 'PENDING_OFFICE' THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'CANCELLED' THEN
    DELETE FROM public.erp_notifications n
    WHERE n.order_id = NEW.order_id
      AND n.notification_type IN ('DELIVERY_RETURN_PENDING','DELIVERY_RETURN_OPERATIONS')
      AND n.created_at >= NEW.created_at
      AND n.created_at <  NEW.created_at + interval '5 seconds';
  ELSE
    UPDATE public.erp_notifications n
    SET is_read = true
    WHERE n.order_id = NEW.order_id
      AND n.notification_type IN ('DELIVERY_RETURN_PENDING','DELIVERY_RETURN_OPERATIONS')
      AND n.created_at >= NEW.created_at
      AND n.created_at <  NEW.created_at + interval '5 seconds'
      AND n.is_read = false;
  END IF;
  RETURN NEW;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_return_notifications_follow_status() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_lwb_return_notifications_follow_status
  ON public.lwb_driver_delivery_returns;
CREATE TRIGGER trg_lwb_return_notifications_follow_status
AFTER UPDATE OF status ON public.lwb_driver_delivery_returns
FOR EACH ROW
EXECUTE FUNCTION public.lwb_return_notifications_follow_status();

-- One-time clean-up of the notifications already sent for old returns.
DELETE FROM public.erp_notifications n
USING public.lwb_driver_delivery_returns r
WHERE r.status = 'CANCELLED'
  AND n.order_id = r.order_id
  AND n.notification_type IN ('DELIVERY_RETURN_PENDING','DELIVERY_RETURN_OPERATIONS')
  AND n.created_at >= r.created_at
  AND n.created_at <  r.created_at + interval '5 seconds';

UPDATE public.erp_notifications n
SET is_read = true
FROM public.lwb_driver_delivery_returns r
WHERE r.status IN ('APPROVED','REJECTED')
  AND n.is_read = false
  AND n.order_id = r.order_id
  AND n.notification_type IN ('DELIVERY_RETURN_PENDING','DELIVERY_RETURN_OPERATIONS')
  AND n.created_at >= r.created_at
  AND n.created_at <  r.created_at + interval '5 seconds';

COMMIT;

-- Expected: 2 rows, both true.
SELECT 'notification trigger' AS item, EXISTS (SELECT 1 FROM pg_trigger
  WHERE tgname = 'trg_lwb_return_notifications_follow_status' AND NOT tgisinternal) AS ok
UNION ALL SELECT 'no notification left for cancelled returns', NOT EXISTS (
  SELECT 1 FROM public.erp_notifications n JOIN public.lwb_driver_delivery_returns r
    ON n.order_id = r.order_id
  WHERE r.status = 'CANCELLED'
    AND n.notification_type IN ('DELIVERY_RETURN_PENDING','DELIVERY_RETURN_OPERATIONS')
    AND n.created_at >= r.created_at AND n.created_at < r.created_at + interval '5 seconds');
