-- lwb:no-auto-run
-- Superseded for automatic deployment by lwb_driver_background_tracking_setup.sql.
-- Strict tracking allowlist, including Accounts. Page overrides cannot grant tracking.
CREATE OR REPLACE FUNCTION public.lwb_track_viewer()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid()
    AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager','warehouse','accounts'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_track_viewer() FROM PUBLIC, anon, authenticated;
