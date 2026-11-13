-- LUXURY WRIST BRAND ERP — SKU product photo (Mohit 13 Nov 2026)
-- One photo per SKU, shown as a small thumbnail next to the SKU name (Order Review, SKU search,
-- SKU Master). Safe to run again.
--
--   sku_master.image_url   public URL of the photo in bucket lwb-sku-photos (NULL = no photo)
--   bucket lwb-sku-photos  public read (product photos are not secret; thumbnails load fast,
--                          no signed links). Files: <sku id>/<time>.jpg, max 1 MB, JPEG / PNG / WebP.
--   Upload / change / remove: Admin and Sales Head (manager), same people who edit SKU Master.

ALTER TABLE public.sku_master ADD COLUMN IF NOT EXISTS image_url text;

DO $c$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'sku_master_image_url_ok') THEN
    ALTER TABLE public.sku_master ADD CONSTRAINT sku_master_image_url_ok
      CHECK (image_url IS NULL OR (length(image_url) <= 500 AND image_url ~ '^https://[^\s"''<>]+$'));
  END IF;
END $c$;

-- Who may add / change a SKU photo: active Admin or Sales Head.
CREATE OR REPLACE FUNCTION public.lwb_sku_photo_editor()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active IS TRUE AND lower(btrim(p.role)) IN ('admin', 'manager'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sku_photo_editor() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sku_photo_editor() TO authenticated;

-- Upload path must be <sku uuid>/<name>.<jpg|jpeg|png|webp> of a SKU that exists.
CREATE OR REPLACE FUNCTION public.lwb_sku_photo_path_ok(p_name text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(p_name ~* '^[0-9a-f-]{36}/[A-Za-z0-9_-]{1,64}\.(jpg|jpeg|png|webp)$'
    AND EXISTS (SELECT 1 FROM public.sku_master s WHERE s.id::text = lower(split_part(p_name, '/', 1))), false);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sku_photo_path_ok(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sku_photo_path_ok(text) TO authenticated;

INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lwb-sku-photos', 'lwb-sku-photos', true, 1048576, ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE SET public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

DROP POLICY IF EXISTS lwb_sku_photos_upload ON storage.objects;
CREATE POLICY lwb_sku_photos_upload ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'lwb-sku-photos'
    AND public.lwb_sku_photo_editor()
    AND public.lwb_sku_photo_path_ok(name));
DROP POLICY IF EXISTS lwb_sku_photos_change ON storage.objects;
CREATE POLICY lwb_sku_photos_change ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'lwb-sku-photos' AND public.lwb_sku_photo_editor())
  WITH CHECK (bucket_id = 'lwb-sku-photos' AND public.lwb_sku_photo_editor());
DROP POLICY IF EXISTS lwb_sku_photos_remove ON storage.objects;
CREATE POLICY lwb_sku_photos_remove ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'lwb-sku-photos' AND public.lwb_sku_photo_editor());
-- Read: the bucket is public, so the photo URL works for every login and the phone app.
-- Storage also needs a SELECT rule to remove / replace a file through the API.
DROP POLICY IF EXISTS lwb_sku_photos_read ON storage.objects;
CREATE POLICY lwb_sku_photos_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'lwb-sku-photos');

-- Check
SELECT 'image_url column' AS item, EXISTS (SELECT 1 FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'sku_master' AND column_name = 'image_url') AS ok
UNION ALL SELECT 'sku photos bucket', EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'lwb-sku-photos');
