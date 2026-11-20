-- LUXURY WRIST BRAND ERP — WHEN THE TRANSPORT (DRIVER / VEHICLE / GODOWN MANAGER) CAN BE CHANGED
--
-- Applied automatically on merge (Supabase apply workflow). Safe to run again.
--
-- Mohit (19 Nov 2026): after the transport is assigned, Sales Head / Manager must be able to change
-- the driver, vehicle, delivery type and Godown Manager any time BEFORE loading is confirmed
-- (also while loading has started). Once loading is confirmed (Loaded, Tally bill, out for
-- delivery, delivered) only Admin can change them. Every change is already logged with who /
-- when / old -> new in public.lwb_change_log (lwb_change_history_setup.sql), shown in PO History.
--
-- - Only these columns are guarded: driver_name, driver_mobile, vehicle_no, transporter_name,
--   loading_person, loading_manager_id. Times, remarks, trip and other system updates are not touched.
-- - System jobs (no login) are never blocked.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_transport_after_loaded_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_st text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF NEW.driver_name IS NOT DISTINCT FROM OLD.driver_name
     AND NEW.driver_mobile IS NOT DISTINCT FROM OLD.driver_mobile
     AND NEW.vehicle_no IS NOT DISTINCT FROM OLD.vehicle_no
     AND NEW.transporter_name IS NOT DISTINCT FROM OLD.transporter_name
     AND NEW.loading_person IS NOT DISTINCT FROM OLD.loading_person
     AND NEW.loading_manager_id IS NOT DISTINCT FROM OLD.loading_manager_id THEN
    RETURN NEW;
  END IF;
  SELECT lower(btrim(coalesce(o.status::text,''))) INTO v_st FROM public.orders o WHERE o.id = NEW.order_id;
  IF v_st IN ('loaded','invoiced','dispatched','out_for_delivery','delivered','partially_delivered')
     AND NOT public.lwb_role_in(ARRAY['admin']) THEN
    RAISE EXCEPTION 'Loading is confirmed on this PO. Only Admin can change the driver, vehicle or Godown Manager now.';
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_transport_after_loaded_guard() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_lwb_transport_after_loaded_guard ON public.dispatch_assignments;
CREATE TRIGGER trg_lwb_transport_after_loaded_guard
BEFORE UPDATE ON public.dispatch_assignments
FOR EACH ROW EXECUTE FUNCTION public.lwb_transport_after_loaded_guard();

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Check: 1 row, true
SELECT 'transport_after_loaded_guard' AS item,
  EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_transport_after_loaded_guard') AS ok;
