-- LUXURY WRIST BRAND ERP — DASHBOARD BANNER POSTS
--
-- RUN ONCE in Supabase SQL Editor, after lwb_announcements_market_report_setup.sql. Safe to run again.
--
-- Admin / Sales Head can now post a wide banner photo (best size 1600 x 300 px, 16:3)
-- with the focus message. Every role sees the active banners as a sliding banner strip
-- at the top of the Dashboard until the end date (or until removed). Text is optional
-- when a photo is posted. Old text-only posts keep working as before.
--
-- Only lwb_announcements (one new column), one private photo bucket and
-- erp_notifications are written. No order, stock, bill, payment or ledger data is changed.

BEGIN;

ALTER TABLE public.lwb_announcements ADD COLUMN IF NOT EXISTS image_path text;

-- A post needs a message or a banner photo.
ALTER TABLE public.lwb_announcements DROP CONSTRAINT IF EXISTS lwb_announcements_message_check;
ALTER TABLE public.lwb_announcements DROP CONSTRAINT IF EXISTS lwb_announcements_text_or_banner;
ALTER TABLE public.lwb_announcements ADD CONSTRAINT lwb_announcements_text_or_banner
  CHECK (length(message) <= 300 AND (length(btrim(message)) > 0 OR image_path IS NOT NULL));

CREATE OR REPLACE FUNCTION public.lwb_post_announcement(p_message text, p_sku text, p_until date, p_image text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_msg text := btrim(coalesce(p_message,''));
  v_sku text := nullif(btrim(coalesce(p_sku,'')),'');
  v_img text := nullif(btrim(coalesce(p_image,'')),'');
  v_id bigint;
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head only'; END IF;
  IF v_msg = '' AND v_img IS NULL THEN RAISE EXCEPTION 'Write the message or add a banner photo'; END IF;
  IF length(v_msg) > 300 THEN RAISE EXCEPTION 'Keep the message under 300 letters'; END IF;
  IF v_img IS NOT NULL AND (split_part(v_img,'/',1) <> auth.uid()::text OR v_img !~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,80}$') THEN
    RAISE EXCEPTION 'Invalid banner photo';
  END IF;
  IF p_until IS NOT NULL AND p_until < (now() AT TIME ZONE 'Asia/Kolkata')::date THEN
    RAISE EXCEPTION 'The end date is already over';
  END IF;
  INSERT INTO public.lwb_announcements(message, sku_name, valid_until, image_path, created_by)
  VALUES (v_msg, v_sku, p_until, v_img, auth.uid()) RETURNING id INTO v_id;

  INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
  SELECT p.id, CASE WHEN v_img IS NULL THEN 'Focus' ELSE 'New banner' END || coalesce(': ' || v_sku, ''),
    left(coalesce(nullif(v_msg,''), 'See the new banner on the Dashboard.'), 300), 'ANNOUNCEMENT'
  FROM public.user_profiles p
  WHERE p.active = true AND p.id IS DISTINCT FROM auth.uid();
  RETURN v_id;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_post_announcement(text,text,date,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_post_announcement(text,text,date,text) TO authenticated;

-- Private banner bucket: Admin / Sales Head upload into their own folder; every signed-in user can view.
INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lwb-banners', 'lwb-banners', false, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

DROP POLICY IF EXISTS lwb_banner_upload ON storage.objects;
CREATE POLICY lwb_banner_upload ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'lwb-banners' AND (storage.foldername(name))[1] = auth.uid()::text AND public.lwb_sales_head());
DROP POLICY IF EXISTS lwb_banner_read ON storage.objects;
CREATE POLICY lwb_banner_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'lwb-banners');

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: all three lines should say true.
SELECT 'banner column' AS item, EXISTS (SELECT 1 FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'lwb_announcements' AND column_name = 'image_path') AS ok
UNION ALL
SELECT 'banner post function', to_regprocedure('public.lwb_post_announcement(text,text,date,text)') IS NOT NULL
UNION ALL
SELECT 'banner bucket', EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'lwb-banners');
