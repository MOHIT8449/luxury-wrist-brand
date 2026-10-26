-- LUXURY WRIST BRAND ERP — GODOWN MANAGER DAILY REPORT
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- The godown managers (WAREHOUSE role) report from their phone:
--   * VEHICLE  — vehicle arrived for loading / unloading / return, then working, then done
--   * DAMAGE   — damage / leakage / breakage / shortage found in the godown (with photo)
--   * ABSENT   — driver / labour / loader did not come
--   * ISSUE    — anything else the office must know
-- Each new report sends a 🔔 notification to every active Admin and Sales Head
-- (MANAGER). Admin / Sales Head mark it Seen or Action Taken with a note, and
-- the reporter is notified.
--
-- Reports only. Stock, orders, bills, payments and Tally are NOT changed.

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

CREATE TABLE IF NOT EXISTS public.lwb_godown_reports (
  id bigserial PRIMARY KEY,
  report_date date NOT NULL DEFAULT (now() AT TIME ZONE 'Asia/Kolkata')::date,
  kind text NOT NULL CHECK (kind IN ('VEHICLE','DAMAGE','ABSENT','ISSUE')),
  -- VEHICLE
  vehicle_no text,
  driver_name text,
  driver_mobile text,
  purpose text CHECK (purpose IS NULL OR purpose IN ('LOADING','UNLOADING','RETURN','OTHER')),
  vehicle_status text CHECK (vehicle_status IS NULL OR vehicle_status IN ('ARRIVED','WORKING','DONE','LEFT')),
  arrived_at timestamptz,
  started_at timestamptz,
  done_at timestamptz,
  -- DAMAGE
  sku_name text,
  cases integer CHECK (cases IS NULL OR cases >= 0),
  pcs integer CHECK (pcs IS NULL OR pcs >= 0),
  damage_type text CHECK (damage_type IS NULL OR damage_type IN ('DAMAGE','LEAKAGE','BREAKAGE','SHORTAGE','EXPIRY','OTHER')),
  -- ABSENT
  person_type text CHECK (person_type IS NULL OR person_type IN ('DRIVER','LABOUR','LOADER','OTHER')),
  person_name text,
  -- common
  note text CHECK (note IS NULL OR length(note) <= 1000),
  photo_path text,
  urgent boolean NOT NULL DEFAULT false,
  created_by uuid NOT NULL DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  review_status text NOT NULL DEFAULT 'OPEN' CHECK (review_status IN ('OPEN','SEEN','ACTION_TAKEN')),
  review_note text,
  reviewed_by uuid,
  reviewed_at timestamptz
);
CREATE INDEX IF NOT EXISTS lwb_godown_reports_day_idx ON public.lwb_godown_reports(report_date DESC, created_at DESC);

ALTER TABLE public.lwb_godown_reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_godown_reports_read ON public.lwb_godown_reports;
CREATE POLICY lwb_godown_reports_read ON public.lwb_godown_reports FOR SELECT TO authenticated
  USING (public.lwb_godown_user());
REVOKE ALL ON TABLE public.lwb_godown_reports FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_godown_reports TO authenticated;
REVOKE ALL ON SEQUENCE public.lwb_godown_reports_id_seq FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Add a report. p: {kind, vehicle_no, driver_name, driver_mobile, purpose, sku_name,
--   cases, pcs, damage_type, person_type, person_name, note, photo_path, urgent}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_godown_add(p jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_kind text := upper(btrim(coalesce(p->>'kind','')));
  v_id bigint;
  t text := nullif(btrim(coalesce(p->>'note','')),'');
BEGIN
  IF NOT public.lwb_godown_user() THEN RAISE EXCEPTION 'Godown team, Sales Head or Admin only'; END IF;
  IF v_kind = 'VEHICLE' AND nullif(btrim(coalesce(p->>'vehicle_no','')),'') IS NULL THEN RAISE EXCEPTION 'Enter the vehicle number'; END IF;
  IF v_kind = 'DAMAGE' AND (nullif(btrim(coalesce(p->>'sku_name','')),'') IS NULL OR coalesce((p->>'cases')::int,0) + coalesce((p->>'pcs')::int,0) <= 0) THEN
    RAISE EXCEPTION 'Enter the SKU and the cases or pieces';
  END IF;
  IF v_kind = 'ABSENT' AND nullif(btrim(coalesce(p->>'person_name','')),'') IS NULL THEN RAISE EXCEPTION 'Enter who did not come'; END IF;
  IF v_kind = 'ISSUE' AND t IS NULL THEN RAISE EXCEPTION 'Write what happened'; END IF;
  IF nullif(p->>'photo_path','') IS NOT NULL AND split_part(p->>'photo_path','/',1) <> auth.uid()::text THEN
    RAISE EXCEPTION 'Invalid photo';
  END IF;
  INSERT INTO public.lwb_godown_reports(kind, vehicle_no, driver_name, driver_mobile, purpose, vehicle_status, arrived_at,
    sku_name, cases, pcs, damage_type, person_type, person_name, note, photo_path, urgent, created_by)
  VALUES (v_kind,
    upper(regexp_replace(nullif(btrim(coalesce(p->>'vehicle_no','')),''), '\s+', '', 'g')),
    nullif(btrim(coalesce(p->>'driver_name','')),''),
    public.lwb_mobile10(p->>'driver_mobile'),
    CASE WHEN v_kind = 'VEHICLE' THEN coalesce(nullif(upper(p->>'purpose'),''),'LOADING') END,
    CASE WHEN v_kind = 'VEHICLE' THEN 'ARRIVED' END,
    CASE WHEN v_kind = 'VEHICLE' THEN now() END,
    nullif(btrim(coalesce(p->>'sku_name','')),''),
    nullif(p->>'cases','')::int, nullif(p->>'pcs','')::int,
    CASE WHEN v_kind = 'DAMAGE' THEN coalesce(nullif(upper(p->>'damage_type'),''),'DAMAGE') END,
    CASE WHEN v_kind = 'ABSENT' THEN coalesce(nullif(upper(p->>'person_type'),''),'LABOUR') END,
    nullif(btrim(coalesce(p->>'person_name','')),''),
    left(t, 1000), nullif(p->>'photo_path',''), coalesce((p->>'urgent')::boolean, false), auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$fn$;

-- Vehicle: ARRIVED -> WORKING -> DONE (or LEFT without work).
CREATE OR REPLACE FUNCTION public.lwb_godown_vehicle_status(p_id bigint, p_status text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_status text := upper(btrim(coalesce(p_status,'')));
BEGIN
  IF NOT public.lwb_godown_user() THEN RAISE EXCEPTION 'Godown team, Sales Head or Admin only'; END IF;
  IF v_status NOT IN ('WORKING','DONE','LEFT') THEN RAISE EXCEPTION 'Invalid status'; END IF;
  UPDATE public.lwb_godown_reports SET vehicle_status = v_status,
    started_at = CASE WHEN v_status = 'WORKING' THEN now() ELSE started_at END,
    done_at = CASE WHEN v_status IN ('DONE','LEFT') THEN now() ELSE done_at END
  WHERE id = p_id AND kind = 'VEHICLE';
  IF NOT FOUND THEN RAISE EXCEPTION 'Vehicle entry not found'; END IF;
END;
$fn$;

-- Admin / Sales Head: mark Seen or Action Taken.
CREATE OR REPLACE FUNCTION public.lwb_godown_review(p_id bigint, p_status text, p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_status text := upper(btrim(coalesce(p_status,''))); r public.lwb_godown_reports%ROWTYPE;
BEGIN
  IF NOT public.lwb_godown_reviewer() THEN RAISE EXCEPTION 'Admin or Sales Head only'; END IF;
  IF v_status NOT IN ('SEEN','ACTION_TAKEN','OPEN') THEN RAISE EXCEPTION 'Invalid status'; END IF;
  UPDATE public.lwb_godown_reports SET review_status = v_status, review_note = left(nullif(btrim(coalesce(p_note,'')),''), 500),
    reviewed_by = auth.uid(), reviewed_at = now()
  WHERE id = p_id RETURNING * INTO r;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Report not found'; END IF;
  IF v_status <> 'OPEN' AND r.created_by IS DISTINCT FROM auth.uid() THEN
    INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
    VALUES (r.created_by, CASE WHEN v_status = 'ACTION_TAKEN' THEN 'Action taken on your godown report' ELSE 'Office has seen your godown report' END,
      'GDN-' || r.id || ' · ' || initcap(r.kind) || coalesce(' · ' || r.review_note, '') || '.', 'GODOWN_REVIEW');
  END IF;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_godown_add(jsonb), public.lwb_godown_vehicle_status(bigint,text),
  public.lwb_godown_review(bigint,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_godown_add(jsonb), public.lwb_godown_vehicle_status(bigint,text),
  public.lwb_godown_review(bigint,text,text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 🔔 New report -> every active Admin and Sales Head (not the reporter).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_notify_godown_report()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_by text; v_title text; v_msg text;
BEGIN
  SELECT coalesce(p.full_name, 'Godown') INTO v_by FROM public.user_profiles p WHERE p.id = NEW.created_by;
  v_title := CASE NEW.kind
    WHEN 'VEHICLE' THEN 'Godown: vehicle arrived'
    WHEN 'DAMAGE' THEN 'Godown: ' || lower(coalesce(NEW.damage_type,'damage')) || ' reported'
    WHEN 'ABSENT' THEN 'Godown: ' || lower(coalesce(NEW.person_type,'staff')) || ' absent'
    ELSE 'Godown: issue reported' END;
  IF NEW.urgent THEN v_title := 'URGENT · ' || v_title; END IF;
  v_msg := 'GDN-' || NEW.id || ' · ' || CASE NEW.kind
    WHEN 'VEHICLE' THEN NEW.vehicle_no || ' for ' || lower(NEW.purpose) || coalesce(' · Driver ' || NEW.driver_name, '')
    WHEN 'DAMAGE' THEN NEW.sku_name || ' · ' || coalesce(NEW.cases,0) || ' CS ' || coalesce(NEW.pcs,0) || ' PCS'
    WHEN 'ABSENT' THEN NEW.person_name
    ELSE '' END
    || coalesce(' · ' || NEW.note, '') || ' · by ' || coalesce(v_by,'Godown') || '.';
  INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
  SELECT p.id, v_title, left(v_msg, 600), 'GODOWN_' || NEW.kind
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') AND p.id IS DISTINCT FROM NEW.created_by;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_notify_godown_report() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_notify_godown_report ON public.lwb_godown_reports;
CREATE TRIGGER trg_lwb_notify_godown_report AFTER INSERT ON public.lwb_godown_reports
  FOR EACH ROW EXECUTE FUNCTION public.lwb_notify_godown_report();

-- ---------------------------------------------------------------------------
-- Private photo bucket: upload into your own folder, read by godown team / office.
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lwb-godown-photos', 'lwb-godown-photos', false, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

DROP POLICY IF EXISTS lwb_godown_photo_upload ON storage.objects;
CREATE POLICY lwb_godown_photo_upload ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'lwb-godown-photos' AND (storage.foldername(name))[1] = auth.uid()::text AND public.lwb_godown_user());
DROP POLICY IF EXISTS lwb_godown_photo_read ON storage.objects;
CREATE POLICY lwb_godown_photo_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'lwb-godown-photos' AND public.lwb_godown_user());

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: both lines should say true.
SELECT 'godown reports' AS item, EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='lwb_godown_reports') AS ok
UNION ALL
SELECT 'photo bucket', EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'lwb-godown-photos');
