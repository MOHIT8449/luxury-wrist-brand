-- LUXURY WRIST BRAND ERP — VEHICLE MASTER AND DRIVER MASTER
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- Two master lists used by Masters > Vehicle Master / Driver Master.
-- PO Approval & Driver and Transport Assignment pick driver and vehicle from them.
-- Drivers are kept unique by Indian mobile number (10 digits, starts 6-9), never by name.
-- Admin / Manager add and edit; Transport and Warehouse can only read.
-- No order, dispatch, bill, stock, payment or Tally data is changed.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_fleet_editor()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager')
  );
$function$;

CREATE OR REPLACE FUNCTION public.lwb_fleet_reader()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager','transport','warehouse')
  );
$function$;

REVOKE ALL ON FUNCTION public.lwb_fleet_editor() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_fleet_reader() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_fleet_editor() TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_fleet_reader() TO authenticated;

-- Vehicle number is stored without spaces or dashes, in capitals (GJ05FW9821).
CREATE TABLE IF NOT EXISTS public.lwb_vehicles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vehicle_no text NOT NULL UNIQUE CHECK (vehicle_no ~ '^[A-Z0-9]{4,15}$'),
  vehicle_type text,
  capacity_kg numeric(10,2) CHECK (capacity_kg IS NULL OR capacity_kg >= 0),
  ownership text NOT NULL DEFAULT 'OWN' CHECK (ownership IN ('OWN','TRANSPORTER')),
  transporter_name text,
  owner_mobile text CHECK (owner_mobile IS NULL OR owner_mobile ~ '^[6-9][0-9]{9}$'),
  insurance_expiry date,
  puc_expiry date,
  fitness_expiry date,
  permit_expiry date,
  is_active boolean NOT NULL DEFAULT true,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid DEFAULT auth.uid()
);

CREATE TABLE IF NOT EXISTS public.lwb_drivers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_name text NOT NULL CHECK (length(btrim(driver_name)) BETWEEN 1 AND 150),
  mobile text NOT NULL UNIQUE CHECK (mobile ~ '^[6-9][0-9]{9}$'),
  alt_mobile text CHECK (alt_mobile IS NULL OR alt_mobile ~ '^[6-9][0-9]{9}$'),
  license_no text,
  license_expiry date,
  default_vehicle_id uuid REFERENCES public.lwb_vehicles(id) ON DELETE SET NULL,
  transporter_name text,
  address text,
  is_active boolean NOT NULL DEFAULT true,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid DEFAULT auth.uid()
);

CREATE OR REPLACE FUNCTION public.lwb_fleet_touch()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $function$ BEGIN NEW.updated_at := now(); RETURN NEW; END; $function$;

DROP TRIGGER IF EXISTS lwb_vehicles_touch ON public.lwb_vehicles;
CREATE TRIGGER lwb_vehicles_touch BEFORE UPDATE ON public.lwb_vehicles
  FOR EACH ROW EXECUTE FUNCTION public.lwb_fleet_touch();
DROP TRIGGER IF EXISTS lwb_drivers_touch ON public.lwb_drivers;
CREATE TRIGGER lwb_drivers_touch BEFORE UPDATE ON public.lwb_drivers
  FOR EACH ROW EXECUTE FUNCTION public.lwb_fleet_touch();

ALTER TABLE public.lwb_vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_drivers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lwb_vehicles_read ON public.lwb_vehicles;
CREATE POLICY lwb_vehicles_read ON public.lwb_vehicles FOR SELECT TO authenticated USING (public.lwb_fleet_reader());
DROP POLICY IF EXISTS lwb_vehicles_insert ON public.lwb_vehicles;
CREATE POLICY lwb_vehicles_insert ON public.lwb_vehicles FOR INSERT TO authenticated WITH CHECK (public.lwb_fleet_editor());
DROP POLICY IF EXISTS lwb_vehicles_update ON public.lwb_vehicles;
CREATE POLICY lwb_vehicles_update ON public.lwb_vehicles FOR UPDATE TO authenticated USING (public.lwb_fleet_editor()) WITH CHECK (public.lwb_fleet_editor());
DROP POLICY IF EXISTS lwb_vehicles_delete ON public.lwb_vehicles;
CREATE POLICY lwb_vehicles_delete ON public.lwb_vehicles FOR DELETE TO authenticated USING (public.lwb_fleet_editor());

DROP POLICY IF EXISTS lwb_drivers_read ON public.lwb_drivers;
CREATE POLICY lwb_drivers_read ON public.lwb_drivers FOR SELECT TO authenticated USING (public.lwb_fleet_reader());
DROP POLICY IF EXISTS lwb_drivers_insert ON public.lwb_drivers;
CREATE POLICY lwb_drivers_insert ON public.lwb_drivers FOR INSERT TO authenticated WITH CHECK (public.lwb_fleet_editor());
DROP POLICY IF EXISTS lwb_drivers_update ON public.lwb_drivers;
CREATE POLICY lwb_drivers_update ON public.lwb_drivers FOR UPDATE TO authenticated USING (public.lwb_fleet_editor()) WITH CHECK (public.lwb_fleet_editor());
DROP POLICY IF EXISTS lwb_drivers_delete ON public.lwb_drivers;
CREATE POLICY lwb_drivers_delete ON public.lwb_drivers FOR DELETE TO authenticated USING (public.lwb_fleet_editor());

REVOKE ALL ON TABLE public.lwb_vehicles FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.lwb_drivers FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.lwb_vehicles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.lwb_drivers TO authenticated;

COMMIT;
