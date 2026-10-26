-- LUXURY WRIST BRAND ERP — PHOTOS FOR DRIVER DELIVERY RETURNS
--
-- RUN ONCE in Supabase SQL Editor, after lwb_driver_delivery_return_setup.sql
-- and lwb_driver_return_review_setup.sql. Safe to run again.
--
-- The driver takes 1 to 6 photos of the leakage / breakage / damage goods
-- with the phone camera (Driver Delivery > Return tab). Photos go to the
-- private bucket lwb-return-photos (resized to about 200 KB each), and the
-- return is saved only together with its photos.
-- Office staff (admin, accounts, manager, warehouse) see the photos on
-- Driver Returns Approval. Nothing else changes: no stock, GST, Tally,
-- credit note, ledger or payment rows.

BEGIN;

ALTER TABLE public.lwb_driver_delivery_returns
  ADD COLUMN IF NOT EXISTS photo_paths text[] NOT NULL DEFAULT '{}';

-- Who may upload / view return photos.
CREATE OR REPLACE FUNCTION public.lwb_return_photo_driver()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'driver');
$$;

CREATE OR REPLACE FUNCTION public.lwb_return_photo_viewer()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','accounts','manager','warehouse'));
$$;

REVOKE ALL ON FUNCTION public.lwb_return_photo_driver() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_return_photo_viewer() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_return_photo_driver() TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_return_photo_viewer() TO authenticated;

-- ---------------------------------------------------------------------------
-- Private photo bucket: a driver uploads into his own folder (<user id>/<order id>/...),
-- reads his own photos; office staff read all.
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lwb-return-photos', 'lwb-return-photos', false, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

DROP POLICY IF EXISTS lwb_return_photo_upload ON storage.objects;
CREATE POLICY lwb_return_photo_upload ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'lwb-return-photos' AND (storage.foldername(name))[1] = auth.uid()::text AND public.lwb_return_photo_driver());
DROP POLICY IF EXISTS lwb_return_photo_read ON storage.objects;
CREATE POLICY lwb_return_photo_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'lwb-return-photos' AND ((storage.foldername(name))[1] = auth.uid()::text OR public.lwb_return_photo_viewer()));

-- ---------------------------------------------------------------------------
-- Driver: save the return together with its uploaded photos (all or nothing).
-- Uses the existing lwb_driver_submit_delivery_return for every quantity / rate rule.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_driver_submit_delivery_return_with_photos(
  p_order_id uuid, p_lines jsonb, p_note text, p_photo_paths text[]
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $$
DECLARE
  v_prefix text;
  v_paths text[];
  v_path text;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR p_order_id IS NULL THEN
    RAISE EXCEPTION 'Login again and retry';
  END IF;
  v_prefix := auth.uid()::text || '/' || p_order_id::text || '/';

  SELECT COALESCE(array_agg(DISTINCT btrim(x)), '{}') INTO v_paths
  FROM unnest(COALESCE(p_photo_paths, '{}')) AS x
  WHERE btrim(x) <> '';

  IF cardinality(v_paths) < 1 THEN
    RAISE EXCEPTION 'Take at least one photo of the returned goods';
  END IF;
  IF cardinality(v_paths) > 6 THEN
    RAISE EXCEPTION 'Maximum 6 photos per return';
  END IF;

  FOREACH v_path IN ARRAY v_paths LOOP
    IF left(v_path, length(v_prefix)) <> v_prefix OR position('..' IN v_path) > 0
       OR NOT EXISTS (SELECT 1 FROM storage.objects o
                      WHERE o.bucket_id = 'lwb-return-photos' AND o.name = v_path) THEN
      RAISE EXCEPTION 'Return photo not found. Take the photo again.';
    END IF;
  END LOOP;

  v_result := public.lwb_driver_submit_delivery_return(p_order_id, p_lines, p_note);

  UPDATE public.lwb_driver_delivery_returns
  SET photo_paths = v_paths
  WHERE id = (v_result->>'return_id')::uuid;

  RETURN v_result || jsonb_build_object('photo_count', cardinality(v_paths));
END;
$$;

-- ---------------------------------------------------------------------------
-- Office: photo paths of the returns shown on Driver Returns Approval.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_office_driver_return_photos(p_return_ids uuid[])
RETURNS TABLE(return_id uuid, photo_paths text[])
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.lwb_return_photo_viewer() THEN
    RAISE EXCEPTION 'Only active office staff can view return photos';
  END IF;
  RETURN QUERY
    SELECT r.id, r.photo_paths
    FROM public.lwb_driver_delivery_returns r
    WHERE r.id = ANY(COALESCE(p_return_ids, '{}')) AND cardinality(r.photo_paths) > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.lwb_driver_submit_delivery_return_with_photos(uuid,jsonb,text,text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_office_driver_return_photos(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_driver_submit_delivery_return_with_photos(uuid,jsonb,text,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_office_driver_return_photos(uuid[]) TO authenticated;

COMMIT;

-- Expected: 3 rows, all true.
SELECT 'photo column' AS item, EXISTS (SELECT 1 FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'lwb_driver_delivery_returns' AND column_name = 'photo_paths') AS ok
UNION ALL SELECT 'return photo bucket', EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'lwb-return-photos')
UNION ALL SELECT 'submit with photos function', to_regprocedure('public.lwb_driver_submit_delivery_return_with_photos(uuid,jsonb,text,text[])') IS NOT NULL;
