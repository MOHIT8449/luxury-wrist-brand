-- Luxury Wrist Brand ERP — Sales Head Driver Dropdown
-- Sync active DRIVER users (name + mobile) from the existing user_profiles table.
-- Does NOT create drivers, change orders/roles, or touch payment/Tally.
-- Execute in Supabase SQL Editor, then hard-refresh warehouse-orders.html.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_sales_head_active_drivers()
RETURNS TABLE (
  driver_user_id uuid,
  driver_name text,
  driver_mobile text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.user_profiles p
    WHERE p.id = auth.uid()
      AND p.active IS TRUE
      AND lower(btrim(coalesce(p.role,''))) IN ('admin','manager')
  ) THEN
    RAISE EXCEPTION 'Only active Admin / Sales Head can view Driver Directory';
  END IF;

  RETURN QUERY
    SELECT
      p.id AS driver_user_id,
      btrim(p.full_name)::text AS driver_name,
      regexp_replace(p.mobile,'[^0-9]','','g')::text AS driver_mobile
    FROM public.user_profiles p
    WHERE p.active IS TRUE
      AND lower(btrim(coalesce(p.role,''))) = 'driver'
      AND nullif(btrim(coalesce(p.full_name,'')),'') IS NOT NULL
      AND regexp_replace(coalesce(p.mobile,''),'[^0-9]','','g')
        ~ '^(91)?[6-9][0-9]{9}$'
    ORDER BY btrim(p.full_name),p.id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_sales_head_active_drivers()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_sales_head_active_drivers()
  TO authenticated;

COMMIT;
NOTIFY pgrst,'reload schema';

-- Read-only verification: one row means the RPC exists.
SELECT routine_name
FROM information_schema.routines
WHERE routine_schema='public'
  AND routine_name='lwb_sales_head_active_drivers';