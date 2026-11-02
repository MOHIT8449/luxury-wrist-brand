-- Luxury Wrist Brand ERP: deny SALESMAN access to live GPS and delivery-tracking map.
-- Additive security patch; does not change orders, dispatch, POD, payments or stock.
-- Execute through an approved Supabase migration process after review.
-- Existing Admin, Sales Head and Godown Manager access stays unchanged.
CREATE OR REPLACE FUNCTION public.lwb_track_viewer()
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE v_role text;
BEGIN
  SELECT lower(btrim(p.role)) INTO v_role
  FROM public.user_profiles p
  WHERE p.id = auth.uid() AND p.active = true;

  -- Do not permit an explicit page-permission override for sales staff.
  IF v_role IS NULL OR v_role = 'sales' THEN
    RETURN false;
  END IF;

  IF v_role IN ('admin', 'manager', 'warehouse') THEN
    RETURN true;
  END IF;

  IF to_regprocedure('public.lwb_has_page(text)') IS NOT NULL THEN
    RETURN public.lwb_has_page('live-tracking.html');
  END IF;
  RETURN false;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_track_viewer() FROM PUBLIC, anon, authenticated;

-- Security verification after migration:
-- 1) A sales-role login calling lwb_live_map() must be denied.
-- 2) Admin/manager/warehouse roles can still call lwb_live_map().
-- 3) Confirm that any other delivery-status RPCs and Realtime policies are
--    separately authorized; this patch only controls lwb_track_viewer().
