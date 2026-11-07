-- LUXURY WRIST BRAND ERP — PARTY ↔ GODOWN DISTANCE
--
-- RUN ONCE in Supabase SQL Editor, after lwb_live_tracking_setup.sql and
-- lwb_party_pan_optional_location_setup.sql. Safe to run again.
--
-- The godown location is set once by Admin / Sales Head in
-- Live Tracking > ⚙ Settings ("📍 Godown = my location now" or "🗺 Pick godown on map").
-- PO Entry then shows how far a party's shop is from the godown:
--   * lwb_godown_point(): the godown lat/lng for PO Entry users (no other settings).
--   * lwb_party_kyc(): also returns godown_km (straight line, 1 decimal; road km is usually more).
--
-- Read only. Nothing is written.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_godown_point()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE g record;
BEGIN
  IF NOT public.lwb_po_entry_user() THEN RAISE EXCEPTION 'Only Admin, Manager or Salesman can read the godown location'; END IF;
  SELECT s.godown_lat, s.godown_lng INTO g FROM public.lwb_tracking_settings s WHERE s.id = 1;
  IF g.godown_lat IS NULL OR g.godown_lng IS NULL THEN RETURN NULL; END IF;
  RETURN jsonb_build_object('lat', g.godown_lat, 'lng', g.godown_lng);
END;
$fn$;

-- PO Entry: the party's details status + straight-line km from the godown.
CREATE OR REPLACE FUNCTION public.lwb_party_kyc(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  m public.lwb_customer_master%ROWTYPE;
  v_limit integer;
  g record;
BEGIN
  IF NOT public.lwb_po_entry_user() THEN RAISE EXCEPTION 'Only Admin, Manager or Salesman can read party details'; END IF;
  SELECT * INTO m FROM public.lwb_customer_master WHERE id = p_customer_id;
  IF NOT FOUND OR NOT public.lwb_party_visible(m.id) THEN RETURN NULL; END IF;
  SELECT s.godown_lat, s.godown_lng INTO g FROM public.lwb_tracking_settings s WHERE s.id = 1;
  v_limit := coalesce(m.kyc_free_orders, (SELECT s.kyc_free_orders FROM public.lwb_sales_settings s WHERE s.id = 1), 3);
  RETURN jsonb_build_object(
    'missing', to_jsonb(public.lwb_party_missing(m.mobile, m.billing_address, m.pan, m.gstin)),
    'used', m.kyc_orders_used, 'limit', v_limit,
    'enforced', public.lwb_is_sales_user(),
    'mobile', m.mobile, 'address', m.billing_address, 'city', m.city, 'pincode', m.pincode,
    'pan', m.pan, 'gstin', m.gstin,
    'has_location', m.geo_lat IS NOT NULL AND m.geo_lng IS NOT NULL,
    'godown_km', round((public.lwb_geo_m(m.geo_lat, m.geo_lng, g.godown_lat, g.godown_lng) / 1000)::numeric, 1),
    'blocking', to_jsonb(array_remove(public.lwb_party_missing(m.mobile, m.billing_address, m.pan, m.gstin), 'PAN / GSTIN')));
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_godown_point(), public.lwb_party_kyc(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_godown_point(), public.lwb_party_kyc(uuid) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: SELECT godown_lat IS NOT NULL AS godown_set FROM public.lwb_tracking_settings WHERE id = 1;
