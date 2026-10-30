-- LUXURY WRIST BRAND ERP — GODOWN MANAGER CAN ADD / EDIT DRIVERS
--
-- Runs by itself when merged to main (after lwb_fleet_master_setup.sql and lwb_fleet_vehicle_godown_edit.sql).
-- Safe to run again.
--
-- Mohit (30 Oct 2026): Godown (warehouse role) could only read Driver Master. Now Godown can add and edit
-- drivers, same as vehicles. Delete stays Admin / Manager only (mark a driver Inactive instead).
-- Only the lwb_drivers insert / update rules change. No data is changed.

BEGIN;

-- Same rule as vehicles: active Admin, Manager or Godown (warehouse).
CREATE OR REPLACE FUNCTION public.lwb_vehicle_editor()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager','warehouse')
  );
$function$;
REVOKE ALL ON FUNCTION public.lwb_vehicle_editor() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_vehicle_editor() TO authenticated;

ALTER POLICY lwb_drivers_insert ON public.lwb_drivers
  WITH CHECK (public.lwb_vehicle_editor());
ALTER POLICY lwb_drivers_update ON public.lwb_drivers
  USING (public.lwb_vehicle_editor()) WITH CHECK (public.lwb_vehicle_editor());

COMMIT;
