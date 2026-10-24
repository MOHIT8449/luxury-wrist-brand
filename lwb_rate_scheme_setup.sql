-- LUXURY WRIST BRAND ERP — RATE, SLAB & SCHEME (Phase 1)
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- What it adds (same numbers as the CC PO Maker "Landing / Rate", "Slab"
-- and "Rate Ledger" tabs, now kept in the database instead of one browser):
--  1. lwb_rate_settings   : MEPD %, ROI (main) and ROI landing (one row).
--  2. lwb_rate_packs      : one row per pack: case config, GR, MEPD %, free
--                           bottle, OMS, QPS, Slab 3 MGR rate, and the Slab
--                           sheet (weight, bottle, landing, 5 margins).
--  3. lwb_rate_history    : date-wise ledger of every rate / scheme change.
--  4. lwb_save_rates()    : the only way to change rates (Admin or Manager).
--  5. lwb_import_rate_history() : one-time copy of the old PO Maker ledger.
--
-- Only active Admin and Manager (Sales head) can read or change these
-- tables. Salesman and other roles see nothing here.
-- NO order, bill, stock, ledger or Tally data is touched.

BEGIN;

-- ---------------------------------------------------------------------------
-- Helper: active Admin or Manager
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_rate_editor()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager')
  );
$function$;

REVOKE ALL ON FUNCTION public.lwb_rate_editor() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_rate_editor() TO authenticated;

-- ---------------------------------------------------------------------------
-- 1. Settings (single row)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_rate_settings (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  mepd_pct numeric(8,4) NOT NULL DEFAULT 1.25,
  roi_main numeric(12,2) NOT NULL DEFAULT 0,
  roi_landing numeric(12,2) NOT NULL DEFAULT 5,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
INSERT INTO public.lwb_rate_settings(id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Packs (Landing / Rate + Slab sheet)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_rate_packs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sort_no integer NOT NULL DEFAULT 0,
  pack_name text NOT NULL CHECK (btrim(pack_name) <> ''),
  case_config numeric(10,2) NOT NULL DEFAULT 0 CHECK (case_config >= 0),
  gr numeric(12,2) NOT NULL DEFAULT 0,
  mepd_pct numeric(8,4),            -- NULL = use the global MEPD %
  free_bottle numeric(10,2) NOT NULL DEFAULT 0,
  oms numeric(12,2),                -- NULL = formula (free bottle packs)
  qps numeric(12,2) NOT NULL DEFAULT 0,
  slab3_rate numeric(12,2) NOT NULL DEFAULT 0,  -- Slab 3 MGR rate
  unit_weight numeric(10,3),        -- Slab sheet: KG per case
  bottle numeric(10,2),             -- Slab sheet: bottles per case
  slab_landing numeric(12,4),       -- Slab sheet: landing
  slab_margins numeric(12,2)[] NOT NULL DEFAULT ARRAY[NULL,NULL,NULL,NULL,NULL]::numeric(12,2)[],
  active boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_rate_packs_name_uidx
  ON public.lwb_rate_packs (upper(btrim(pack_name)));

-- ---------------------------------------------------------------------------
-- 3. History (Rate / scheme ledger). Rows are never edited or deleted.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_rate_history (
  id bigserial PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid,
  note text,
  settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  rows jsonb NOT NULL DEFAULT '[]'::jsonb   -- per pack: GR, MEPD, OMS, QPS, ROI, landing, slab rates
);
CREATE INDEX IF NOT EXISTS lwb_rate_history_created_idx
  ON public.lwb_rate_history (created_at DESC);

-- ---------------------------------------------------------------------------
-- Read access: Admin + Manager only. No direct writes for anyone.
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_rate_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_rate_packs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_rate_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lwb_rate_settings_read ON public.lwb_rate_settings;
CREATE POLICY lwb_rate_settings_read ON public.lwb_rate_settings
  FOR SELECT TO authenticated USING (public.lwb_rate_editor());
DROP POLICY IF EXISTS lwb_rate_packs_read ON public.lwb_rate_packs;
CREATE POLICY lwb_rate_packs_read ON public.lwb_rate_packs
  FOR SELECT TO authenticated USING (public.lwb_rate_editor());
DROP POLICY IF EXISTS lwb_rate_history_read ON public.lwb_rate_history;
CREATE POLICY lwb_rate_history_read ON public.lwb_rate_history
  FOR SELECT TO authenticated USING (public.lwb_rate_editor());

REVOKE ALL ON TABLE public.lwb_rate_settings, public.lwb_rate_packs, public.lwb_rate_history
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_rate_settings, public.lwb_rate_packs, public.lwb_rate_history
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Save rates: settings + all packs in one transaction, plus one ledger
--    entry when p_snapshot is given (the page sends it only when rates or
--    scheme actually changed).
--    p_packs: [{id?, sort_no, pack_name, case_config, gr, mepd_pct, free_bottle,
--               oms, qps, slab3_rate, unit_weight, bottle, slab_landing,
--               slab_margins:[5], active}]
--    A pack missing from p_packs is NOT deleted (use active=false).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_save_rates(
  p_settings jsonb,
  p_packs jsonb,
  p_note text DEFAULT NULL,
  p_snapshot jsonb DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_pack jsonb;
  v_count integer := 0;
  v_name text;
  v_id uuid;
  v_margins numeric(12,2)[];
BEGIN
  IF NOT public.lwb_rate_editor() THEN
    RAISE EXCEPTION 'Only an active Admin or Manager can change rates';
  END IF;
  IF jsonb_typeof(COALESCE(p_packs,'null'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Pack list is missing';
  END IF;

  UPDATE public.lwb_rate_settings SET
    mepd_pct = COALESCE((p_settings->>'mepd_pct')::numeric, mepd_pct),
    roi_main = COALESCE((p_settings->>'roi_main')::numeric, roi_main),
    roi_landing = COALESCE((p_settings->>'roi_landing')::numeric, roi_landing),
    updated_at = now(),
    updated_by = auth.uid()
  WHERE id = 1;

  FOR v_pack IN SELECT * FROM jsonb_array_elements(p_packs) LOOP
    v_name := btrim(COALESCE(v_pack->>'pack_name',''));
    IF v_name = '' THEN
      RAISE EXCEPTION 'Pack name is required (row %)', v_count + 1;
    END IF;
    SELECT COALESCE(array_agg(CASE WHEN x IN ('', 'null') THEN NULL ELSE x::numeric END ORDER BY i), ARRAY[]::numeric(12,2)[])
      INTO v_margins
      FROM jsonb_array_elements_text(COALESCE(v_pack->'slab_margins','[]'::jsonb)) WITH ORDINALITY AS t(x, i);
    WHILE COALESCE(array_length(v_margins,1),0) < 5 LOOP
      v_margins := v_margins || NULL::numeric(12,2);
    END LOOP;

    v_id := NULLIF(v_pack->>'id','')::uuid;
    IF v_id IS NULL THEN
      SELECT id INTO v_id FROM public.lwb_rate_packs
        WHERE upper(btrim(pack_name)) = upper(v_name);
    END IF;

    IF v_id IS NULL THEN
      INSERT INTO public.lwb_rate_packs(
        sort_no, pack_name, case_config, gr, mepd_pct, free_bottle, oms, qps,
        slab3_rate, unit_weight, bottle, slab_landing, slab_margins, active, updated_by)
      VALUES (
        COALESCE((v_pack->>'sort_no')::integer, v_count),
        v_name,
        COALESCE((v_pack->>'case_config')::numeric, 0),
        COALESCE((v_pack->>'gr')::numeric, 0),
        NULLIF(v_pack->>'mepd_pct','')::numeric,
        COALESCE((v_pack->>'free_bottle')::numeric, 0),
        NULLIF(v_pack->>'oms','')::numeric,
        COALESCE((v_pack->>'qps')::numeric, 0),
        COALESCE((v_pack->>'slab3_rate')::numeric, 0),
        NULLIF(v_pack->>'unit_weight','')::numeric,
        NULLIF(v_pack->>'bottle','')::numeric,
        NULLIF(v_pack->>'slab_landing','')::numeric,
        v_margins[1:5],
        COALESCE((v_pack->>'active')::boolean, true),
        auth.uid());
    ELSE
      UPDATE public.lwb_rate_packs SET
        sort_no = COALESCE((v_pack->>'sort_no')::integer, sort_no),
        pack_name = v_name,
        case_config = COALESCE((v_pack->>'case_config')::numeric, 0),
        gr = COALESCE((v_pack->>'gr')::numeric, 0),
        mepd_pct = NULLIF(v_pack->>'mepd_pct','')::numeric,
        free_bottle = COALESCE((v_pack->>'free_bottle')::numeric, 0),
        oms = NULLIF(v_pack->>'oms','')::numeric,
        qps = COALESCE((v_pack->>'qps')::numeric, 0),
        slab3_rate = COALESCE((v_pack->>'slab3_rate')::numeric, 0),
        unit_weight = NULLIF(v_pack->>'unit_weight','')::numeric,
        bottle = NULLIF(v_pack->>'bottle','')::numeric,
        slab_landing = NULLIF(v_pack->>'slab_landing','')::numeric,
        slab_margins = v_margins[1:5],
        active = COALESCE((v_pack->>'active')::boolean, active),
        updated_at = now(),
        updated_by = auth.uid()
      WHERE id = v_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Pack % not found. Refresh the page.', v_name;
      END IF;
    END IF;
    v_count := v_count + 1;
  END LOOP;

  IF p_snapshot IS NOT NULL AND jsonb_typeof(p_snapshot) = 'array' THEN
    INSERT INTO public.lwb_rate_history(created_by, note, settings, rows)
    VALUES (
      auth.uid(),
      NULLIF(btrim(COALESCE(p_note,'')),''),
      COALESCE(p_settings,'{}'::jsonb),
      p_snapshot);
  END IF;

  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_save_rates(jsonb,jsonb,text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_save_rates(jsonb,jsonb,text,jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. One-time import of the old PO Maker "Rate Ledger" (Admin only, and only
--    while the history is still empty, so it cannot be used to rewrite it).
--    p_entries: [{dt:'2026-10-20T10:30', note, rows:[...]}]
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_import_rate_history(p_entries jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_e jsonb;
  v_count integer := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND active = true AND lower(btrim(role)) = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only an active Admin can import the old rate ledger';
  END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_rate_history) THEN
    RAISE EXCEPTION 'Rate history already has entries; old ledger can only be imported once, before the first save';
  END IF;
  IF jsonb_typeof(COALESCE(p_entries,'null'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Ledger list is missing';
  END IF;
  FOR v_e IN SELECT * FROM jsonb_array_elements(p_entries) LOOP
    INSERT INTO public.lwb_rate_history(created_at, created_by, note, settings, rows)
    VALUES (
      COALESCE(NULLIF(v_e->>'dt','')::timestamp AT TIME ZONE 'Asia/Kolkata', now()),
      auth.uid(),
      'PO Maker: ' || COALESCE(NULLIF(btrim(v_e->>'note'),''), 'rate entry'),
      COALESCE(v_e->'settings','{}'::jsonb),
      COALESCE(v_e->'rows','[]'::jsonb));
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.lwb_import_rate_history(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_import_rate_history(jsonb) TO authenticated;

COMMIT;
