-- 23 Nov 2026: owner asked to switch the location lock off for now.
-- Pauses the "Location off" alert to Admin (no more bell / phone pushes).
-- The function stays, so it can be switched on again by re-running
-- lwb_staff_location_alert_setup.sql. No data is removed.
DROP TRIGGER IF EXISTS lwb_staff_location_off_alert ON public.lwb_staff_location;
