-- LUXURY WRIST BRAND ERP — GODOWN MANAGER CAN ADD / EDIT VEHICLES
--
-- Runs by itself when merged to main (after lwb_fleet_master_setup.sql). Safe to run again.
--
-- Masters > Vehicle Master: Godown (warehouse role) could only read the list.
-- Now Godown can also add and edit vehicles. Delete stays Admin / Manager only
-- (mark a vehicle Inactive instead). Driver Master is unchanged (Admin / Manager edit).
-- Only the lwb_vehicles insert / update rules change. No data is changed.

BEGIN;

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

ALTER POLICY lwb_vehicles_insert ON public.lwb_vehicles
  WITH CHECK (public.lwb_vehicle_editor());
ALTER POLICY lwb_vehicles_update ON public.lwb_vehicles
  USING (public.lwb_vehicle_editor()) WITH CHECK (public.lwb_vehicle_editor());

COMMIT;
