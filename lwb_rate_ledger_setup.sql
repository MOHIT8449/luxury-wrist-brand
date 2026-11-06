-- LUXURY WRIST BRAND ERP — RATE LEDGER: "VALID FROM" DATE, WHO SAVED, COMPANY CIRCULAR
--
-- Runs by itself when merged to main (after lwb_rate_scheme_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (6 Nov 2026): every company scheme change (e.g. free bottle 3.2 -> 2.5 on one pack) must be
-- on record: which scheme, from which date, who saved it, with the company's circular; and for any date
-- he must see which scheme was running that day (to check the POs punched that day).
--   * lwb_rate_history.valid_from (date the scheme starts; blank = the day it was saved)
--   * lwb_rate_history.files (circular photos / PDFs in the private bucket lwb-rate-circulars)
--   * lwb_rate_history_meta(valid_from, files): fills them on the entry this login just saved
--     (own entry, last 15 minutes). Older entries can not be changed, as before.
--   * lwb_rate_history_people(): names of the people who saved entries (Admin / Sales Head only).
-- No rate, order, stock, bill, ledger or Tally data is changed.

BEGIN;

ALTER TABLE public.lwb_rate_history ADD COLUMN IF NOT EXISTS valid_from date;
ALTER TABLE public.lwb_rate_history ADD COLUMN IF NOT EXISTS files text[] NOT NULL DEFAULT '{}';

-- Private bucket for company circulars: upload into your own folder; Admin / Sales Head read.
INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lwb-rate-circulars', 'lwb-rate-circulars', false, 10485760,
        ARRAY['image/jpeg','image/png','image/webp','application/pdf'])
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
DROP POLICY IF EXISTS lwb_rate_circular_upload ON storage.objects;
CREATE POLICY lwb_rate_circular_upload ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'lwb-rate-circulars' AND (storage.foldername(name))[1] = auth.uid()::text AND public.lwb_rate_editor());
DROP POLICY IF EXISTS lwb_rate_circular_read ON storage.objects;
CREATE POLICY lwb_rate_circular_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'lwb-rate-circulars' AND public.lwb_rate_editor());

CREATE OR REPLACE FUNCTION public.lwb_rate_history_meta(p_valid_from date, p_files text[])
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id bigint; v_f text;
BEGIN
  IF NOT public.lwb_rate_editor() THEN RAISE EXCEPTION 'Only Admin or Sales Head can change the rate ledger.'; END IF;
  FOREACH v_f IN ARRAY coalesce(p_files, '{}') LOOP
    IF split_part(v_f, '/', 1) <> auth.uid()::text THEN RAISE EXCEPTION 'Circular file is not yours.'; END IF;
  END LOOP;
  SELECT h.id INTO v_id FROM public.lwb_rate_history h
   WHERE h.created_by = auth.uid() AND h.created_at > now() - interval '15 minutes'
   ORDER BY h.created_at DESC LIMIT 1 FOR UPDATE;
  IF v_id IS NULL THEN RAISE EXCEPTION 'No ledger entry saved by you in the last 15 minutes.'; END IF;
  UPDATE public.lwb_rate_history SET valid_from = coalesce(p_valid_from, valid_from),
    files = (SELECT coalesce(array_agg(DISTINCT x), '{}') FROM unnest(files || coalesce(p_files, '{}')) x)
   WHERE id = v_id;
  RETURN v_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_rate_history_people()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_rate_editor() THEN RETURN '{}'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_object_agg(p.id::text, coalesce(nullif(btrim(p.full_name),''), p.role))
    FROM public.user_profiles p WHERE p.id IN (SELECT DISTINCT h.created_by FROM public.lwb_rate_history h WHERE h.created_by IS NOT NULL)), '{}'::jsonb);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_rate_history_meta(date, text[]), public.lwb_rate_history_people() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_rate_history_meta(date, text[]), public.lwb_rate_history_people() TO authenticated;

COMMIT;
