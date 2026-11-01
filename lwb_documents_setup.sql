-- LUXURY WRIST BRAND ERP — DOCUMENTS AND PHOTOS FOR EVERY RECORD
--
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (31 Oct 2026): photo of every staff member (employee, driver, salesman: compulsory),
-- Aadhaar + bank details of employees, driving licence + Aadhaar of drivers, PAN / GST / shop photo
-- of parties, vehicle photo, fixed asset photos, the purchase bill as PDF / scan, and damage /
-- leakage / breakage photos taken by the Godown Manager.
--
-- One private bucket  lwb-documents  holds every file at
--     <ENTITY>/<record id>/<DOC TYPE>/<user id>-<time>-<random>.<jpg|png|webp|pdf>
-- and table  lwb_documents  has one row per file. Files are never deleted from a record: "Remove"
-- only hides the row (removed_at / removed_by kept for Admin).
-- lwb_doc_info keeps the numbers that go with the documents (Aadhaar no., PAN, bank account, IFSC).
--
-- Who may upload / view, by record type (+ users who were given that page by Admin):
--   STAFF (Employee Master)      admin, manager, warehouse, accounts
--   DRIVER (Driver Master)       upload admin, manager; view + transport, warehouse, accounts
--                                (Aadhaar / bank / PAN of a driver: admin, manager, accounts only)
--   USER (ERP logins)            upload admin, manager; view + accounts
--   VEHICLE                      upload admin, manager, warehouse; view + transport, accounts
--   PARTY                        admin, manager, sales, accounts
--   SUPPLIER                     upload admin, manager, accounts; view + warehouse
--   PURCHASE_BILL (Goods Inward) admin, manager, accounts, warehouse
--   ASSET (Fixed Assets)         upload admin, manager, accounts; view + warehouse
--   STOCK_MOVE / ORDER (godown damage, loading photos)
--                                upload admin, manager, warehouse; view + accounts (+ transport for ORDER)
-- Nothing here changes stock, orders, ledgers, Tally or payments.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_documents (
  id bigserial PRIMARY KEY,
  entity_type text NOT NULL,
  entity_id text NOT NULL CHECK (entity_id ~ '^[A-Za-z0-9-]{1,64}$'),
  doc_type text NOT NULL CHECK (doc_type ~ '^[A-Z_]{2,20}$'),
  path text NOT NULL UNIQUE,
  file_name text CHECK (file_name IS NULL OR length(file_name) <= 150),
  mime text NOT NULL,
  size_bytes integer NOT NULL DEFAULT 0,
  note text CHECK (note IS NULL OR length(note) <= 300),
  uploaded_by uuid DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  removed_at timestamptz,
  removed_by uuid
);
CREATE INDEX IF NOT EXISTS lwb_documents_entity_idx ON public.lwb_documents (entity_type, entity_id) WHERE removed_at IS NULL;
ALTER TABLE public.lwb_documents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_documents FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_documents_id_seq FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_doc_info (
  entity_type text NOT NULL,
  entity_id text NOT NULL,
  info jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (entity_type, entity_id)
);
ALTER TABLE public.lwb_doc_info ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_doc_info FROM PUBLIC, anon, authenticated;

-- Allowed document types of each record type.
CREATE OR REPLACE FUNCTION public.lwb_doc_types(p_entity text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE p_entity
    WHEN 'STAFF' THEN ARRAY['PHOTO','DL','AADHAAR','PAN','BANK','OTHER']
    WHEN 'DRIVER' THEN ARRAY['PHOTO','DL','AADHAAR','PAN','BANK','OTHER']
    WHEN 'USER' THEN ARRAY['PHOTO','AADHAAR','PAN','BANK','OTHER']
    WHEN 'VEHICLE' THEN ARRAY['PHOTO','RC','INSURANCE','PUC','FITNESS','PERMIT','OTHER']
    WHEN 'PARTY' THEN ARRAY['SHOP','OWNER','PAN','GST','CHEQUE','OTHER']
    WHEN 'SUPPLIER' THEN ARRAY['GST','PAN','CHEQUE','OTHER']
    WHEN 'PURCHASE_BILL' THEN ARRAY['BILL','DAMAGE','OTHER']
    WHEN 'ASSET' THEN ARRAY['PHOTO','BILL','WARRANTY','OTHER']
    WHEN 'STOCK_MOVE' THEN ARRAY['DAMAGE','OTHER']
    WHEN 'ORDER' THEN ARRAY['LOADED','DAMAGE','OTHER']
    ELSE NULL END;
$fn$;

-- p_mode 'edit' (upload / remove) or 'view'. p_doc_type NULL = any type of that record.
CREATE OR REPLACE FUNCTION public.lwb_doc_access(p_entity text, p_doc_type text, p_mode text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text;
  v_edit text[];
  v_view text[];
  v_page text;
BEGIN
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
  IF v_role IS NULL OR public.lwb_doc_types(p_entity) IS NULL THEN RETURN false; END IF;
  IF p_doc_type IS NOT NULL AND NOT (p_doc_type = ANY(public.lwb_doc_types(p_entity))) THEN RETURN false; END IF;
  CASE p_entity
    WHEN 'STAFF' THEN v_edit := ARRAY['admin','manager','warehouse','accounts']; v_view := v_edit; v_page := 'fleet-master.html';
    WHEN 'DRIVER' THEN v_edit := ARRAY['admin','manager'];
      v_view := CASE WHEN p_doc_type IN ('AADHAAR','PAN','BANK') THEN ARRAY['admin','manager','accounts']
                     ELSE ARRAY['admin','manager','transport','warehouse','accounts'] END;
      v_page := 'fleet-master.html';
    WHEN 'USER' THEN v_edit := ARRAY['admin','manager']; v_view := ARRAY['admin','manager','accounts']; v_page := 'users.html';
    WHEN 'VEHICLE' THEN v_edit := ARRAY['admin','manager','warehouse']; v_view := ARRAY['admin','manager','warehouse','transport','accounts']; v_page := 'fleet-master.html';
    WHEN 'PARTY' THEN v_edit := ARRAY['admin','manager','sales','accounts']; v_view := v_edit; v_page := 'customer-master.html';
    WHEN 'SUPPLIER' THEN v_edit := ARRAY['admin','manager','accounts']; v_view := ARRAY['admin','manager','accounts','warehouse']; v_page := 'supplier-master.html';
    WHEN 'PURCHASE_BILL' THEN v_edit := ARRAY['admin','manager','accounts','warehouse']; v_view := v_edit; v_page := 'goods-inward.html';
    WHEN 'ASSET' THEN v_edit := ARRAY['admin','manager','accounts']; v_view := ARRAY['admin','manager','accounts','warehouse']; v_page := 'fixed-assets.html';
    WHEN 'STOCK_MOVE' THEN v_edit := ARRAY['admin','manager','warehouse']; v_view := ARRAY['admin','manager','warehouse','accounts']; v_page := 'stock-transfer.html';
    WHEN 'ORDER' THEN v_edit := ARRAY['admin','manager','warehouse']; v_view := ARRAY['admin','manager','warehouse','accounts','transport']; v_page := 'loading-dispatch.html';
  END CASE;
  IF v_role = ANY(CASE WHEN p_mode = 'edit' THEN v_edit ELSE v_view || v_edit END) THEN RETURN true; END IF;
  -- A login given the page by Admin may upload and view there (not the private driver numbers).
  IF p_entity = 'DRIVER' AND p_doc_type IN ('AADHAAR','PAN','BANK') THEN RETURN false; END IF;
  RETURN v_role <> 'driver' AND public.lwb_has_page(v_page);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_doc_access(text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_doc_access(text,text,text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Private bucket. Upload only into a folder the login may use, under his own user id.
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lwb-documents', 'lwb-documents', false, 10485760, ARRAY['image/jpeg','image/png','image/webp','application/pdf'])
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

DROP POLICY IF EXISTS lwb_documents_upload ON storage.objects;
CREATE POLICY lwb_documents_upload ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'lwb-documents'
    AND array_length(storage.foldername(name), 1) = 3
    AND (storage.foldername(name))[2] ~ '^[A-Za-z0-9-]{1,64}$'
    AND split_part(storage.filename(name), '-', 1) = replace(auth.uid()::text, '-', '')
    AND public.lwb_doc_access((storage.foldername(name))[1], (storage.foldername(name))[3], 'edit'));
DROP POLICY IF EXISTS lwb_documents_read ON storage.objects;
CREATE POLICY lwb_documents_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'lwb-documents'
    AND public.lwb_doc_access((storage.foldername(name))[1], (storage.foldername(name))[3], 'view'));

-- ---------------------------------------------------------------------------
-- Register an uploaded file on its record.
-- ---------------------------------------------------------------------------
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
  v_prefix := p_entity || '/' || p_entity_id || '/' || p_doc_type || '/' || replace(auth.uid()::text, '-', '') || '-';
  IF left(coalesce(p_path, ''), length(v_prefix)) <> v_prefix OR position('..' IN p_path) > 0 OR position('/' IN substr(p_path, length(v_prefix) + 1)) > 0 THEN
    RAISE EXCEPTION 'Wrong file path';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'lwb-documents' AND o.name = p_path) THEN
    RAISE EXCEPTION 'File not found. Upload it again.';
  END IF;
  IF coalesce(p_mime, '') NOT IN ('image/jpeg','image/png','image/webp','application/pdf') THEN
    RAISE EXCEPTION 'Only photos (JPG / PNG) and PDF files';
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

-- Files of some records (only the kinds this login may view).
CREATE OR REPLACE FUNCTION public.lwb_doc_list(p_entity text, p_entity_ids text[])
RETURNS TABLE(id bigint, entity_id text, doc_type text, path text, file_name text, mime text, size_bytes integer,
  note text, uploaded_by_name text, created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
#variable_conflict use_column
BEGIN
  IF NOT public.lwb_doc_access(p_entity, NULL, 'view') THEN
    RAISE EXCEPTION 'You can not view these documents';
  END IF;
  RETURN QUERY
    SELECT d.id, d.entity_id, d.doc_type, d.path, d.file_name, d.mime, d.size_bytes, d.note,
           coalesce(p.full_name, ''), d.created_at
    FROM public.lwb_documents d
    LEFT JOIN public.user_profiles p ON p.id = d.uploaded_by
    WHERE d.entity_type = p_entity AND d.entity_id = ANY(coalesce(p_entity_ids, '{}')) AND d.removed_at IS NULL
      AND public.lwb_doc_access(p_entity, d.doc_type, 'view')
    ORDER BY d.entity_id, d.doc_type, d.created_at;
END;
$fn$;

-- Which kinds of documents each record has (for "Photo missing" tags in lists). No file paths.
CREATE OR REPLACE FUNCTION public.lwb_doc_summary(p_entity text)
RETURNS TABLE(entity_id text, doc_types text[], files integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
#variable_conflict use_column
BEGIN
  IF NOT public.lwb_doc_access(p_entity, NULL, 'view') THEN
    RAISE EXCEPTION 'You can not view these documents';
  END IF;
  RETURN QUERY
    SELECT d.entity_id, array_agg(DISTINCT d.doc_type ORDER BY d.doc_type), count(*)::int
    FROM public.lwb_documents d
    WHERE d.entity_type = p_entity AND d.removed_at IS NULL
    GROUP BY d.entity_id;
END;
$fn$;

-- Remove = hide from the record. The row and the file stay for Admin.
CREATE OR REPLACE FUNCTION public.lwb_doc_remove(p_id bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r public.lwb_documents;
BEGIN
  SELECT * INTO r FROM public.lwb_documents d WHERE d.id = p_id AND d.removed_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'File not found'; END IF;
  IF NOT public.lwb_doc_access(r.entity_type, r.doc_type, 'edit') THEN RAISE EXCEPTION 'You can not remove this file'; END IF;
  UPDATE public.lwb_documents SET removed_at = now(), removed_by = auth.uid() WHERE id = p_id;
  RETURN true;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Aadhaar no. / PAN / bank details of staff, drivers and logins.
-- Read needs the right to view BANK documents of that record type.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_doc_info_get(p_entity text, p_entity_ids text[])
RETURNS TABLE(entity_id text, info jsonb, updated_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
#variable_conflict use_column
BEGIN
  IF p_entity NOT IN ('STAFF','DRIVER','USER') OR NOT public.lwb_doc_access(p_entity, 'BANK', 'view') THEN
    RAISE EXCEPTION 'You can not view these details';
  END IF;
  RETURN QUERY SELECT i.entity_id, i.info, i.updated_at FROM public.lwb_doc_info i
    WHERE i.entity_type = p_entity AND i.entity_id = ANY(coalesce(p_entity_ids, '{}'));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_doc_info_save(p_entity text, p_entity_id text, p_info jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v jsonb := '{}'::jsonb;
  k text;
  t text;
BEGIN
  IF p_entity NOT IN ('STAFF','DRIVER','USER') OR NOT public.lwb_doc_access(p_entity, 'BANK', 'edit') THEN
    RAISE EXCEPTION 'You can not change these details';
  END IF;
  IF coalesce(p_entity_id, '') !~ '^[A-Za-z0-9-]{1,64}$' THEN RAISE EXCEPTION 'Save the record first'; END IF;
  FOREACH k IN ARRAY ARRAY['aadhaar_no','pan_no','bank_holder','bank_name','bank_account','bank_ifsc','upi_id'] LOOP
    t := nullif(btrim(coalesce(p_info->>k, '')), '');
    IF t IS NULL THEN CONTINUE; END IF;
    IF k IN ('aadhaar_no','bank_account') THEN t := regexp_replace(t, '\D', '', 'g'); END IF;
    IF k IN ('pan_no','bank_ifsc') THEN t := upper(regexp_replace(t, '\s', '', 'g')); END IF;
    IF k = 'aadhaar_no' AND t !~ '^[2-9][0-9]{11}$' THEN RAISE EXCEPTION 'Aadhaar number must be 12 digits'; END IF;
    IF k = 'pan_no' AND t !~ '^[A-Z]{5}[0-9]{4}[A-Z]$' THEN RAISE EXCEPTION 'PAN must be 5 letters + 4 numbers + 1 letter'; END IF;
    IF k = 'bank_account' AND t !~ '^[0-9]{6,18}$' THEN RAISE EXCEPTION 'Bank account number: 6 to 18 digits'; END IF;
    IF k = 'bank_ifsc' AND t !~ '^[A-Z]{4}0[A-Z0-9]{6}$' THEN RAISE EXCEPTION 'IFSC must be 11 characters, e.g. SBIN0001234'; END IF;
    v := v || jsonb_build_object(k, left(t, 80));
  END LOOP;
  INSERT INTO public.lwb_doc_info(entity_type, entity_id, info, updated_by, updated_at)
  VALUES (p_entity, p_entity_id, v, auth.uid(), now())
  ON CONFLICT (entity_type, entity_id) DO UPDATE SET info = excluded.info, updated_by = excluded.updated_by, updated_at = now();
  RETURN v;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_doc_add(text,text,text,text,text,text,integer,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_doc_list(text,text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_doc_summary(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_doc_remove(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_doc_info_get(text,text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_doc_info_save(text,text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_doc_add(text,text,text,text,text,text,integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_doc_list(text,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_doc_summary(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_doc_remove(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_doc_info_get(text,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_doc_info_save(text,text,jsonb) TO authenticated;

COMMIT;

-- Expected: 3 rows, all true.
SELECT 'documents table' AS item, to_regclass('public.lwb_documents') IS NOT NULL AS ok
UNION ALL SELECT 'documents bucket', EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'lwb-documents')
UNION ALL SELECT 'add function', to_regprocedure('public.lwb_doc_add(text,text,text,text,text,text,integer,text)') IS NOT NULL;
