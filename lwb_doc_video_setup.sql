-- LUXURY WRIST BRAND ERP — VIDEOS AS PURCHASE DAMAGE PROOF (18 Nov 2026)
--
-- Mohit asked (18 Nov 2026): the Godown Manager should also upload videos of damaged / gasless goods
-- when checking a purchase vehicle (Goods Inward, Purchase List -> Verify, vehicle-arrived popup).
--
--   * Bucket lwb-documents also takes MP4 / MOV / WEBM / 3GP, files up to 50 MB (was 10 MB; the app
--     still keeps photos and PDF at 10 MB).
--   * lwb_doc_add accepts these video types, only for PURCHASE_BILL / DAMAGE.
--
-- Needs: lwb_documents_setup.sql. Safe to run again. Nothing is dropped or deleted.

BEGIN;

UPDATE storage.buckets
SET file_size_limit = 52428800,
    allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp','application/pdf','video/mp4','video/quicktime','video/webm','video/3gpp']
WHERE id = 'lwb-documents';

CREATE OR REPLACE FUNCTION public.lwb_doc_add(p_entity text, p_entity_id text, p_doc_type text, p_path text,
  p_file_name text DEFAULT NULL, p_mime text DEFAULT NULL, p_size integer DEFAULT 0, p_note text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_id bigint;
  v_prefix text;
  v_count int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login again and retry'; END IF;
  IF NOT public.lwb_doc_access(p_entity, p_doc_type, 'edit') THEN
    RAISE EXCEPTION 'You can not upload % for this record', coalesce(p_doc_type, 'documents');
  END IF;
  IF coalesce(p_entity_id, '') !~ '^[A-Za-z0-9-]{1,64}$' THEN RAISE EXCEPTION 'Save the record first, then add documents'; END IF;
  IF p_entity = 'COMPANY' AND NOT public.lwb_cdoc_file_ok(p_entity_id, 'edit') THEN RAISE EXCEPTION 'You can not upload files for this document'; END IF;
  v_prefix := p_entity || '/' || p_entity_id || '/' || p_doc_type || '/' || replace(auth.uid()::text, '-', '') || '-';
  IF left(coalesce(p_path, ''), length(v_prefix)) <> v_prefix OR position('..' IN p_path) > 0 OR position('/' IN substr(p_path, length(v_prefix) + 1)) > 0 THEN
    RAISE EXCEPTION 'Wrong file path';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'lwb-documents' AND o.name = p_path) THEN
    RAISE EXCEPTION 'File not found. Upload it again.';
  END IF;
  IF coalesce(p_mime, '') NOT IN ('image/jpeg','image/png','image/webp','application/pdf',
                                 'video/mp4','video/quicktime','video/webm','video/3gpp') THEN
    RAISE EXCEPTION 'Only photos (JPG / PNG), PDF files and videos (MP4 / MOV)';
  END IF;
  -- Videos only as purchase damage proof.
  IF p_mime LIKE 'video/%' AND NOT (p_entity = 'PURCHASE_BILL' AND p_doc_type = 'DAMAGE') THEN
    RAISE EXCEPTION 'Videos can only be added as purchase damage proof';
  END IF;
  SELECT count(*) INTO v_count FROM public.lwb_documents d
  WHERE d.entity_type = p_entity AND d.entity_id = p_entity_id AND d.doc_type = p_doc_type AND d.removed_at IS NULL;
  IF v_count >= 10 THEN RAISE EXCEPTION 'Maximum 10 files of one kind per record. Remove an old one first.'; END IF;

  INSERT INTO public.lwb_documents(entity_type, entity_id, doc_type, path, file_name, mime, size_bytes, note, uploaded_by)
  VALUES (p_entity, p_entity_id, p_doc_type, p_path, left(nullif(btrim(coalesce(p_file_name, '')), ''), 150), p_mime,
          greatest(coalesce(p_size, 0), 0), left(nullif(btrim(coalesce(p_note, '')), ''), 300), auth.uid())
  ON CONFLICT (path) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN SELECT d.id INTO v_id FROM public.lwb_documents d WHERE d.path = p_path; END IF;
  RETURN v_id;
END;
$fn$;

COMMIT;

-- Check (all true):
SELECT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'lwb-documents' AND 'video/mp4' = ANY(allowed_mime_types) AND file_size_limit = 52428800) AS bucket_video,
       position('video/mp4' in pg_get_functiondef('public.lwb_doc_add(text,text,text,text,text,text,integer,text)'::regprocedure)) > 0 AS add_video;
