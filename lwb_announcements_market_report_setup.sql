-- LUXURY WRIST BRAND ERP — DASHBOARD ANNOUNCEMENTS + OUTSIDE MARKET STOCK REPORT
--
-- RUN ONCE in Supabase SQL Editor, after lwb_sales_team_setup.sql. Safe to run again.
--
-- 1. Announcements (focus messages)
--    Admin / Sales Head post a short message, e.g. "300ml Thums Up stock arrived
--    today, push it". It shows at the top of the Dashboard for EVERY role until
--    its end date (or until removed), and each active user gets a 📢 bell.
--
-- 2. Outside Market Stock (complaint)
--    A salesman reports goods coming into his market from outside: outlet, SKU,
--    cases lying there, outside rate, note and photos (outlet / stock / vehicle).
--    Every field is optional, but the report must say something. Admin and the
--    Sales Head get a 🚩 bell (and a popup), and can mark it Seen / Action Taken;
--    the salesman is told.
--
-- Only the two new tables, one private photo bucket and erp_notifications are written.
-- No order, stock, bill, payment, ledger or Tally data is changed.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Announcements
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_announcements (
  id bigserial PRIMARY KEY,
  message text NOT NULL CHECK (length(btrim(message)) BETWEEN 1 AND 300),
  sku_name text,
  valid_until date,                       -- NULL = until removed
  active boolean NOT NULL DEFAULT true,
  created_by uuid NOT NULL DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  removed_by uuid,
  removed_at timestamptz
);
CREATE INDEX IF NOT EXISTS lwb_announcements_live_idx ON public.lwb_announcements(active, created_at DESC);

ALTER TABLE public.lwb_announcements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_announcements_read ON public.lwb_announcements;
CREATE POLICY lwb_announcements_read ON public.lwb_announcements FOR SELECT TO authenticated
  USING (public.lwb_sales_head()
    OR (active AND (valid_until IS NULL OR valid_until >= (now() AT TIME ZONE 'Asia/Kolkata')::date)));
REVOKE ALL ON TABLE public.lwb_announcements FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_announcements TO authenticated;
REVOKE ALL ON SEQUENCE public.lwb_announcements_id_seq FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_post_announcement(p_message text, p_sku text, p_until date)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_msg text := btrim(coalesce(p_message,''));
  v_sku text := nullif(btrim(coalesce(p_sku,'')),'');
  v_id bigint;
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head only'; END IF;
  IF v_msg = '' THEN RAISE EXCEPTION 'Write the message'; END IF;
  IF length(v_msg) > 300 THEN RAISE EXCEPTION 'Keep the message under 300 letters'; END IF;
  IF p_until IS NOT NULL AND p_until < (now() AT TIME ZONE 'Asia/Kolkata')::date THEN
    RAISE EXCEPTION 'The end date is already over';
  END IF;
  INSERT INTO public.lwb_announcements(message, sku_name, valid_until, created_by)
  VALUES (v_msg, v_sku, p_until, auth.uid()) RETURNING id INTO v_id;

  INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
  SELECT p.id, 'Focus' || coalesce(': ' || v_sku, ''), left(v_msg, 300), 'ANNOUNCEMENT'
  FROM public.user_profiles p
  WHERE p.active = true AND p.id IS DISTINCT FROM auth.uid();
  RETURN v_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_remove_announcement(p_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head only'; END IF;
  UPDATE public.lwb_announcements SET active = false, removed_by = auth.uid(), removed_at = now()
  WHERE id = p_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'Message not found or already removed'; END IF;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_post_announcement(text,text,date), public.lwb_remove_announcement(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_post_announcement(text,text,date), public.lwb_remove_announcement(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Outside Market Stock reports
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_market_reporter()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager','sales','salesman'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_market_reporter() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_market_reporter() TO authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_market_reports (
  id bigserial PRIMARY KEY,
  report_date date NOT NULL DEFAULT (now() AT TIME ZONE 'Asia/Kolkata')::date,
  outlet_name text,
  sku_name text,
  cases integer CHECK (cases IS NULL OR cases >= 0),
  outside_rate numeric(12,2) CHECK (outside_rate IS NULL OR outside_rate >= 0),
  note text CHECK (note IS NULL OR length(note) <= 1000),
  photo_paths text[] NOT NULL DEFAULT '{}',
  created_by uuid NOT NULL DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  review_status text NOT NULL DEFAULT 'OPEN' CHECK (review_status IN ('OPEN','SEEN','ACTION_TAKEN')),
  review_note text,
  reviewed_by uuid,
  reviewed_at timestamptz
);
CREATE INDEX IF NOT EXISTS lwb_market_reports_day_idx ON public.lwb_market_reports(report_date DESC, created_at DESC);
CREATE INDEX IF NOT EXISTS lwb_market_reports_by_idx ON public.lwb_market_reports(created_by, created_at DESC);

ALTER TABLE public.lwb_market_reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_market_reports_read ON public.lwb_market_reports;
CREATE POLICY lwb_market_reports_read ON public.lwb_market_reports FOR SELECT TO authenticated
  USING (created_by = auth.uid() OR public.lwb_sales_head());
REVOKE ALL ON TABLE public.lwb_market_reports FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_market_reports TO authenticated;
REVOKE ALL ON SEQUENCE public.lwb_market_reports_id_seq FROM PUBLIC, anon, authenticated;

-- p: {outlet_name, sku_name, cases, outside_rate, note, photo_paths: [..]}
CREATE OR REPLACE FUNCTION public.lwb_add_market_report(p jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_outlet text := left(nullif(btrim(coalesce(p->>'outlet_name','')),''), 150);
  v_sku text := left(nullif(btrim(coalesce(p->>'sku_name','')),''), 150);
  v_note text := left(nullif(btrim(coalesce(p->>'note','')),''), 1000);
  v_cases integer;
  v_rate numeric;
  v_photos text[] := '{}';
  v_path text;
  v_id bigint;
  v_by text;
BEGIN
  IF NOT public.lwb_market_reporter() THEN RAISE EXCEPTION 'Salesman, Sales Head or Admin only'; END IF;
  IF coalesce(p->>'cases','') <> '' THEN
    IF p->>'cases' !~ '^\d{1,6}$' THEN RAISE EXCEPTION 'Enter whole cases'; END IF;
    v_cases := (p->>'cases')::integer;
  END IF;
  IF coalesce(p->>'outside_rate','') <> '' THEN
    IF p->>'outside_rate' !~ '^\d{1,7}(\.\d{1,2})?$' THEN RAISE EXCEPTION 'Enter the outside rate in rupees'; END IF;
    v_rate := (p->>'outside_rate')::numeric;
  END IF;
  IF jsonb_typeof(p->'photo_paths') = 'array' THEN
    FOR v_path IN SELECT jsonb_array_elements_text(p->'photo_paths') LOOP
      IF split_part(v_path,'/',1) <> auth.uid()::text THEN RAISE EXCEPTION 'Invalid photo'; END IF;
      v_photos := v_photos || v_path;
    END LOOP;
    IF cardinality(v_photos) > 6 THEN RAISE EXCEPTION 'Up to 6 photos'; END IF;
  END IF;
  IF v_outlet IS NULL AND v_sku IS NULL AND v_cases IS NULL AND v_rate IS NULL AND v_note IS NULL AND cardinality(v_photos) = 0 THEN
    RAISE EXCEPTION 'Fill at least one detail or add a photo';
  END IF;

  INSERT INTO public.lwb_market_reports(outlet_name, sku_name, cases, outside_rate, note, photo_paths, created_by)
  VALUES (v_outlet, v_sku, v_cases, v_rate, v_note, v_photos, auth.uid())
  RETURNING id INTO v_id;

  SELECT coalesce(p2.full_name, 'Salesman') INTO v_by FROM public.user_profiles p2 WHERE p2.id = auth.uid();
  INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
  SELECT u.id, 'Outside market stock',
    left(concat_ws(' · ', 'MKT-' || v_id, v_outlet, v_sku,
      CASE WHEN v_cases IS NOT NULL THEN v_cases || ' CS' END,
      CASE WHEN v_rate IS NOT NULL THEN 'Outside rate ₹' || v_rate END,
      CASE WHEN cardinality(v_photos) > 0 THEN cardinality(v_photos) || ' photo' || CASE WHEN cardinality(v_photos) > 1 THEN 's' ELSE '' END END,
      v_note, 'by ' || coalesce(v_by,'Salesman')) || '.', 600),
    'MARKET_REPORT'
  FROM public.user_profiles u
  WHERE u.active = true AND lower(btrim(u.role)) IN ('admin','manager') AND u.id IS DISTINCT FROM auth.uid();
  RETURN v_id;
END;
$fn$;

-- Admin / Sales Head: mark Seen or Action Taken; the salesman is told.
CREATE OR REPLACE FUNCTION public.lwb_review_market_report(p_id bigint, p_status text, p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_status text := upper(btrim(coalesce(p_status,''))); r public.lwb_market_reports%ROWTYPE;
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head only'; END IF;
  IF v_status NOT IN ('SEEN','ACTION_TAKEN','OPEN') THEN RAISE EXCEPTION 'Invalid status'; END IF;
  UPDATE public.lwb_market_reports SET review_status = v_status, review_note = left(nullif(btrim(coalesce(p_note,'')),''), 500),
    reviewed_by = auth.uid(), reviewed_at = now()
  WHERE id = p_id RETURNING * INTO r;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Report not found'; END IF;
  IF v_status <> 'OPEN' AND r.created_by IS DISTINCT FROM auth.uid() THEN
    INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
    VALUES (r.created_by, CASE WHEN v_status = 'ACTION_TAKEN' THEN 'Action taken on your market report' ELSE 'Sales Head has seen your market report' END,
      concat_ws(' · ', 'MKT-' || r.id, r.outlet_name, r.sku_name, r.review_note) || '.', 'MARKET_REVIEW');
  END IF;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_add_market_report(jsonb), public.lwb_review_market_report(bigint,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_add_market_report(jsonb), public.lwb_review_market_report(bigint,text,text) TO authenticated;

-- Private photo bucket: upload into your own folder; the uploader and Admin / Sales Head can view.
INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lwb-market-photos', 'lwb-market-photos', false, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

DROP POLICY IF EXISTS lwb_market_photo_upload ON storage.objects;
CREATE POLICY lwb_market_photo_upload ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'lwb-market-photos' AND (storage.foldername(name))[1] = auth.uid()::text AND public.lwb_market_reporter());
DROP POLICY IF EXISTS lwb_market_photo_read ON storage.objects;
CREATE POLICY lwb_market_photo_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'lwb-market-photos' AND ((storage.foldername(name))[1] = auth.uid()::text OR public.lwb_sales_head()));

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: all three lines should say true.
SELECT 'announcements' AS item, to_regclass('public.lwb_announcements') IS NOT NULL AS ok
UNION ALL
SELECT 'market reports', to_regclass('public.lwb_market_reports') IS NOT NULL
UNION ALL
SELECT 'market photo bucket', EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'lwb-market-photos');
