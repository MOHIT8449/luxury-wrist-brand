-- LUXURY WRIST BRAND ERP — GODOWN 3D: PALLET LINES (LANES) AND SPACE
--
-- Safe to run again. Adds one table and two functions. Stock, orders, bills,
-- payments, SKU Master and Tally are NOT changed.
--
-- Page godown-3d.html shows the main godown in 3D. Every straight line of pallets
-- (lane) has a code painted on the floor (A01-A25, B01-B25, C1, C2, D1, D2, see
-- godown-layout.js) and holds ONE SKU. The page counts pallets from live stock:
--   pallets of an SKU = saleable cases (lwb_live_stock) / cases per pallet (SKU Master)
-- and fills that SKU's lines in order, so it shows how much space is used and free,
-- line by line.
--
-- lwb_godown_lanes   one row per line: slots (pallet places on the floor), levels
--                    (pallets one on top of another), the SKU kept in it.
-- lwb_godown_lane_set(code, sku, levels, note)  Admin / Sales Head (manager) only.
-- Godown team (warehouse) can read the lines.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_godown_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager','warehouse'));
$fn$;
CREATE OR REPLACE FUNCTION public.lwb_godown_reviewer()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_godown_user(), public.lwb_godown_reviewer() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_godown_user(), public.lwb_godown_reviewer() TO authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_godown_lanes (
  lane_code text PRIMARY KEY CHECK (lane_code ~ '^[A-Z][0-9]{1,3}$'),
  zone text NOT NULL,
  sort_no integer NOT NULL DEFAULT 0,
  slots integer NOT NULL CHECK (slots BETWEEN 1 AND 200),
  levels integer NOT NULL DEFAULT 2 CHECK (levels BETWEEN 1 AND 5),
  sku_id uuid,
  note text CHECK (note IS NULL OR length(note) <= 300),
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- The lines of the main godown (same as godown-layout.js). Existing rows (SKU, levels) are kept.
INSERT INTO public.lwb_godown_lanes(lane_code, zone, sort_no, slots)
SELECT 'A' || lpad(g::text, 2, '0'), 'A', g, 10 FROM generate_series(1, 25) g
UNION ALL SELECT 'B' || lpad(g::text, 2, '0'), 'B', 100 + g, 11 FROM generate_series(1, 25) g
UNION ALL SELECT 'C' || g, 'C', 200 + g, 30 FROM generate_series(1, 2) g
UNION ALL SELECT 'D' || g, 'D', 300 + g, 14 FROM generate_series(1, 2) g
ON CONFLICT (lane_code) DO NOTHING;

ALTER TABLE public.lwb_godown_lanes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_godown_lanes_read ON public.lwb_godown_lanes;
CREATE POLICY lwb_godown_lanes_read ON public.lwb_godown_lanes FOR SELECT TO authenticated
  USING (public.lwb_godown_user());
REVOKE ALL ON TABLE public.lwb_godown_lanes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_godown_lanes TO authenticated;

-- Set the SKU (or none), levels and note of one line. Admin / Sales Head only.
CREATE OR REPLACE FUNCTION public.lwb_godown_lane_set(p_code text, p_sku uuid, p_levels integer DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_godown_reviewer() THEN
    RAISE EXCEPTION 'Only Admin or Sales Head can change the godown lines';
  END IF;
  IF p_levels IS NOT NULL AND (p_levels < 1 OR p_levels > 5) THEN
    RAISE EXCEPTION 'Levels must be 1 to 5';
  END IF;
  UPDATE public.lwb_godown_lanes
     SET sku_id = p_sku,
         levels = coalesce(p_levels, levels),
         note = nullif(btrim(coalesce(p_note, note, '')), ''),
         updated_by = auth.uid(), updated_at = now()
   WHERE lane_code = upper(btrim(p_code));
  IF NOT FOUND THEN RAISE EXCEPTION 'Line % not found', p_code; END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_godown_lane_set(text, uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_godown_lane_set(text, uuid, integer, text) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';
