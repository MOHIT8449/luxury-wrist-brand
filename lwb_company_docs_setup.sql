-- LUXURY WRIST BRAND ERP — COMPANY DOCUMENTS: KYC, LICENCES, GST RETURNS, RENEWAL REMINDERS, SHARE LINKS
--
-- Runs by itself when merged to main (with lwb_documents_setup.sql, which allows the COMPANY files).
-- Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (11 Nov 2026): one list of the company's documents (GSTR-1, GSTR-3B, PAN, Aadhaar,
-- GST certificate, licences ...), licence renewal with reminders, and a quick way to send the
-- Aadhaar / PAN / GST certificate to a market party.
--
--   lwb_company_docs        one row per document (group, name, number, issue / expiry date, reminder days,
--                           GST return month + filed date). Files: lwb_documents  COMPANY/<id>/FILE/...
--   lwb_company_doc_packs   saved sets, e.g. "KYC Pack" = GST certificate + PAN + cancelled cheque
--   lwb_company_doc_shares  one row per share: the watermarked copies (COMPANY/<id>/SHARE/...), party,
--                           link token, valid till, opened count. The party opens share.html?t=<token>,
--                           which asks Edge Function lwb-doc-share for short signed links. No login.
--   lwb_company_doc_reminders  which reminder was already sent (one bell per document per step)
--
-- Who: Admin and Accounts add / edit / share (+ logins Admin ticked documents.html for). An "Only Admin"
-- document (e.g. owner Aadhaar) is seen by Admin only.
-- Reminders: bell (+ phone alert) to the document's roles 60 / 30 / 7 / 1 days before expiry (chosen per
-- document), on the day, then every 7 days till renewed. GST: GSTR-1 (11th) and GSTR-3B (20th) of last
-- month, 3 days and 1 day before, on the day and every 2 days after, till "Filed" is saved.
-- Runs 9:00 India time (pg_cron), and from the page ("Send reminders now").
-- Nothing here changes stock, orders, ledgers, Tally or payments.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_company_docs (
  id            bigserial PRIMARY KEY,
  grp           text NOT NULL CHECK (grp IN ('COMPANY','OWNER','LICENSE','GST','BANK','OTHER')),
  name          text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 120),
  doc_no        text CHECK (doc_no IS NULL OR length(doc_no) <= 80),
  holder        text CHECK (holder IS NULL OR length(holder) <= 80),
  issue_date    date,
  expiry_date   date,
  remind_days   integer[] NOT NULL DEFAULT '{60,30,7,1}',
  remind_roles  text[] NOT NULL DEFAULT '{admin,accounts}',
  gst_type      text CHECK (gst_type IS NULL OR gst_type IN ('GSTR1','GSTR3B','GSTR9','OTHER')),
  gst_period    date,
  filed_on      date,
  fees          numeric(12,2) CHECK (fees IS NULL OR fees >= 0),
  contact       text CHECK (contact IS NULL OR length(contact) <= 120),
  shareable     boolean NOT NULL DEFAULT true,
  admin_only    boolean NOT NULL DEFAULT false,
  note          text CHECK (note IS NULL OR length(note) <= 500),
  created_by    uuid DEFAULT auth.uid(),
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    uuid,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  removed_at    timestamptz,
  removed_by    uuid
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_company_docs_gst_uidx ON public.lwb_company_docs (gst_type, gst_period)
  WHERE gst_type IN ('GSTR1','GSTR3B') AND removed_at IS NULL;
ALTER TABLE public.lwb_company_docs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_company_docs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_company_docs_id_seq FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_company_doc_packs (
  id          bigserial PRIMARY KEY,
  name        text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 60),
  doc_ids     bigint[] NOT NULL DEFAULT '{}',
  created_by  uuid DEFAULT auth.uid(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  removed_at  timestamptz
);
ALTER TABLE public.lwb_company_doc_packs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_company_doc_packs FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_company_doc_packs_id_seq FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_company_doc_shares (
  id              bigserial PRIMARY KEY,
  token           text NOT NULL UNIQUE CHECK (token ~ '^[0-9a-f]{32}$'),
  doc_ids         bigint[] NOT NULL,
  files           jsonb NOT NULL,
  party_name      text CHECK (party_name IS NULL OR length(party_name) <= 120),
  party_code      text CHECK (party_code IS NULL OR length(party_code) <= 40),
  mobile          text CHECK (mobile IS NULL OR mobile ~ '^[6-9][0-9]{9}$'),
  watermark       text CHECK (watermark IS NULL OR length(watermark) <= 120),
  channel         text NOT NULL DEFAULT 'LINK' CHECK (channel IN ('WHATSAPP','LINK','EMAIL','FILES')),
  expires_at      timestamptz NOT NULL,
  created_by      uuid DEFAULT auth.uid(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  revoked_at      timestamptz,
  revoked_by      uuid,
  open_count      integer NOT NULL DEFAULT 0,
  first_opened_at timestamptz,
  last_opened_at  timestamptz
);
CREATE INDEX IF NOT EXISTS lwb_company_doc_shares_at_idx ON public.lwb_company_doc_shares (created_at DESC);
ALTER TABLE public.lwb_company_doc_shares ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_company_doc_shares FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_company_doc_shares_id_seq FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_company_doc_reminders (
  doc_id   bigint NOT NULL,
  rkey     text NOT NULL,
  sent_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (doc_id, rkey)
);
ALTER TABLE public.lwb_company_doc_reminders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_company_doc_reminders FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_cdoc_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_cdoc_can()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_role text := public.lwb_cdoc_role();
BEGIN
  IF v_role IS NULL OR v_role = 'driver' THEN RETURN false; END IF;
  RETURN v_role IN ('admin','accounts') OR public.lwb_has_page('documents.html');
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_cdoc_role(), public.lwb_cdoc_can() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_cdoc_can() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_cdoc_today()
RETURNS date LANGUAGE sql STABLE SET search_path = ''
AS $fn$ SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date $fn$;

-- ---------------------------------------------------------------------------
-- List: documents this login may see, with file / share counts, packs and recent shares.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_cdoc_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_admin boolean := public.lwb_cdoc_role() = 'admin';
  v_today date := public.lwb_cdoc_today();
  v_docs jsonb; v_packs jsonb; v_shares jsonb;
BEGIN
  IF NOT public.lwb_cdoc_can() THEN RAISE EXCEPTION 'Documents are for Admin and Accounts only'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.updated_at DESC), '[]') INTO v_docs FROM (
    SELECT d.id, d.grp, d.name, d.doc_no, d.holder, d.issue_date, d.expiry_date, d.remind_days, d.remind_roles,
           d.gst_type, d.gst_period, d.filed_on, d.fees, d.contact, d.shareable, d.admin_only, d.note,
           d.created_at, d.updated_at,
           CASE WHEN d.expiry_date IS NULL THEN NULL ELSE d.expiry_date - v_today END AS days_left,
           (SELECT count(*) FROM public.lwb_documents f WHERE f.entity_type = 'COMPANY' AND f.entity_id = d.id::text
              AND f.doc_type = 'FILE' AND f.removed_at IS NULL)::int AS files,
           (SELECT count(*) FROM public.lwb_company_doc_shares s WHERE d.id = ANY(s.doc_ids))::int AS shares,
           coalesce(u.full_name, '') AS updated_by_name
    FROM public.lwb_company_docs d
    LEFT JOIN public.user_profiles u ON u.id = coalesce(d.updated_by, d.created_by)
    WHERE d.removed_at IS NULL AND (v_admin OR NOT d.admin_only)) x;
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'doc_ids', p.doc_ids) ORDER BY p.name), '[]') INTO v_packs
  FROM public.lwb_company_doc_packs p WHERE p.removed_at IS NULL;
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC), '[]') INTO v_shares FROM (
    SELECT s.id, s.token, s.doc_ids, s.party_name, s.mobile, s.channel, s.expires_at, s.created_at, s.revoked_at,
           s.open_count, s.last_opened_at, jsonb_array_length(s.files) AS file_count,
           coalesce(u.full_name, '') AS by_name,
           (s.revoked_at IS NULL AND s.expires_at > now()) AS live
    FROM public.lwb_company_doc_shares s
    LEFT JOIN public.user_profiles u ON u.id = s.created_by
    WHERE s.created_at > now() - interval '90 days'
    ORDER BY s.created_at DESC LIMIT 200) x;
  RETURN jsonb_build_object('docs', v_docs, 'packs', v_packs, 'shares', v_shares, 'today', v_today, 'admin', v_admin);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Add / edit one document. p = {id?, grp, name, doc_no, holder, issue_date, expiry_date, remind_days[],
-- remind_roles[], gst_type, gst_period, filed_on, fees, contact, shareable, admin_only, note}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_cdoc_save(p jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_id bigint := nullif(p->>'id', '')::bigint;
  v_admin boolean := public.lwb_cdoc_role() = 'admin';
  v_old public.lwb_company_docs;
  v_grp text := upper(btrim(coalesce(p->>'grp', '')));
  v_name text := regexp_replace(btrim(coalesce(p->>'name', '')), '\s+', ' ', 'g');
  v_gst text := nullif(upper(btrim(coalesce(p->>'gst_type', ''))), '');
  v_period date := date_trunc('month', nullif(p->>'gst_period', '')::date)::date;
  v_days integer[];
  v_roles text[];
  v_issue date := nullif(p->>'issue_date', '')::date;
  v_exp date := nullif(p->>'expiry_date', '')::date;
  v_admin_only boolean := coalesce((p->>'admin_only')::boolean, false);
BEGIN
  IF NOT public.lwb_cdoc_can() THEN RAISE EXCEPTION 'Documents are for Admin and Accounts only'; END IF;
  IF v_grp NOT IN ('COMPANY','OWNER','LICENSE','GST','BANK','OTHER') THEN RAISE EXCEPTION 'Choose the document group'; END IF;
  IF length(v_name) < 2 THEN RAISE EXCEPTION 'Enter the document name'; END IF;
  IF v_grp = 'GST' AND v_gst IS NULL THEN v_gst := 'OTHER'; END IF;
  IF v_grp <> 'GST' THEN v_gst := NULL; v_period := NULL; END IF;
  IF v_gst IN ('GSTR1','GSTR3B') AND v_period IS NULL THEN RAISE EXCEPTION 'Choose the return month'; END IF;
  IF v_exp IS NOT NULL AND v_issue IS NOT NULL AND v_exp < v_issue THEN RAISE EXCEPTION 'Expiry date is before the issue date'; END IF;
  IF v_admin_only AND NOT v_admin THEN RAISE EXCEPTION 'Only Admin can make a document "Only Admin"'; END IF;
  SELECT coalesce(array_agg(DISTINCT x ORDER BY x DESC), '{}') INTO v_days
  FROM (SELECT (e)::int AS x FROM jsonb_array_elements_text(coalesce(p->'remind_days', '[60,30,7,1]'::jsonb)) e) t
  WHERE x BETWEEN 0 AND 365;
  SELECT coalesce(array_agg(DISTINCT x ORDER BY x), '{}') INTO v_roles
  FROM (SELECT lower(btrim(e)) AS x FROM jsonb_array_elements_text(coalesce(p->'remind_roles', '["admin","accounts"]'::jsonb)) e) t
  WHERE x IN ('admin','accounts','manager');
  IF v_admin_only THEN v_roles := ARRAY['admin']; END IF;
  IF NOT ('admin' = ANY(v_roles)) THEN v_roles := array_append(v_roles, 'admin'); END IF;

  IF v_id IS NOT NULL THEN
    SELECT * INTO v_old FROM public.lwb_company_docs d WHERE d.id = v_id AND d.removed_at IS NULL FOR UPDATE;
    IF NOT FOUND OR (v_old.admin_only AND NOT v_admin) THEN RAISE EXCEPTION 'Document not found'; END IF;
    IF v_old.admin_only AND NOT v_admin_only AND NOT v_admin THEN RAISE EXCEPTION 'Only Admin can change this'; END IF;
    UPDATE public.lwb_company_docs SET grp = v_grp, name = v_name,
      doc_no = left(nullif(btrim(coalesce(p->>'doc_no', '')), ''), 80), holder = left(nullif(btrim(coalesce(p->>'holder', '')), ''), 80),
      issue_date = v_issue, expiry_date = v_exp, remind_days = v_days, remind_roles = v_roles,
      gst_type = v_gst, gst_period = v_period, filed_on = nullif(p->>'filed_on', '')::date,
      fees = nullif(p->>'fees', '')::numeric, contact = left(nullif(btrim(coalesce(p->>'contact', '')), ''), 120),
      shareable = coalesce((p->>'shareable')::boolean, true), admin_only = v_admin_only,
      note = left(nullif(btrim(coalesce(p->>'note', '')), ''), 500), updated_by = auth.uid(), updated_at = now()
    WHERE id = v_id;
    -- A new expiry date (renewed): reminders start again.
    IF v_old.expiry_date IS DISTINCT FROM v_exp THEN DELETE FROM public.lwb_company_doc_reminders r WHERE r.doc_id = v_id; END IF;
  ELSE
    INSERT INTO public.lwb_company_docs(grp, name, doc_no, holder, issue_date, expiry_date, remind_days, remind_roles,
      gst_type, gst_period, filed_on, fees, contact, shareable, admin_only, note, created_by, updated_by)
    VALUES (v_grp, v_name, left(nullif(btrim(coalesce(p->>'doc_no', '')), ''), 80), left(nullif(btrim(coalesce(p->>'holder', '')), ''), 80),
      v_issue, v_exp, v_days, v_roles, v_gst, v_period, nullif(p->>'filed_on', '')::date, nullif(p->>'fees', '')::numeric,
      left(nullif(btrim(coalesce(p->>'contact', '')), ''), 120), coalesce((p->>'shareable')::boolean, true), v_admin_only,
      left(nullif(btrim(coalesce(p->>'note', '')), ''), 500), auth.uid(), auth.uid())
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'This GST return month is already in the list. Open it and add the file there.';
END;
$fn$;

-- Remove = hidden from the list (row and files stay for Admin).
CREATE OR REPLACE FUNCTION public.lwb_cdoc_remove(p_id bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_admin_only boolean;
BEGIN
  IF NOT public.lwb_cdoc_can() THEN RAISE EXCEPTION 'Documents are for Admin and Accounts only'; END IF;
  SELECT d.admin_only INTO v_admin_only FROM public.lwb_company_docs d WHERE d.id = p_id AND d.removed_at IS NULL;
  IF v_admin_only IS NULL OR (v_admin_only AND public.lwb_cdoc_role() <> 'admin') THEN RAISE EXCEPTION 'Document not found'; END IF;
  UPDATE public.lwb_company_docs SET removed_at = now(), removed_by = auth.uid() WHERE id = p_id;
  RETURN true;
END;
$fn$;

-- Packs: p_id NULL = new; p_doc_ids empty = remove the pack.
CREATE OR REPLACE FUNCTION public.lwb_cdoc_pack_save(p_id bigint, p_name text, p_doc_ids bigint[])
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id bigint := p_id; v_name text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
BEGIN
  IF NOT public.lwb_cdoc_can() THEN RAISE EXCEPTION 'Documents are for Admin and Accounts only'; END IF;
  IF coalesce(array_length(p_doc_ids, 1), 0) = 0 THEN
    UPDATE public.lwb_company_doc_packs SET removed_at = now() WHERE id = p_id AND removed_at IS NULL;
    RETURN p_id;
  END IF;
  IF length(v_name) < 2 THEN RAISE EXCEPTION 'Enter a name for the pack'; END IF;
  IF v_id IS NULL THEN
    INSERT INTO public.lwb_company_doc_packs(name, doc_ids) VALUES (left(v_name, 60), p_doc_ids) RETURNING id INTO v_id;
  ELSE
    UPDATE public.lwb_company_doc_packs SET name = left(v_name, 60), doc_ids = p_doc_ids, updated_at = now()
    WHERE id = v_id AND removed_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Pack not found'; END IF;
  END IF;
  RETURN v_id;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Share. The page first uploads the watermarked copies to COMPANY/<doc id>/SHARE/, then calls this.
-- p = {doc_ids[], files:[{path,name,mime}], party_name, party_code, mobile, watermark, days (1/7/30), channel}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_cdoc_share_create(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_admin boolean := public.lwb_cdoc_role() = 'admin';
  v_ids bigint[];
  v_bad text;
  v_files jsonb := '[]'::jsonb;
  f jsonb;
  v_path text;
  v_doc text;
  v_days int := coalesce(nullif(p->>'days', '')::int, 7);
  v_mobile text := nullif(right(regexp_replace(coalesce(p->>'mobile', ''), '\D', '', 'g'), 10), '');
  v_token text := left(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 32);
  v_id bigint;
  v_exp timestamptz;
BEGIN
  IF NOT public.lwb_cdoc_can() THEN RAISE EXCEPTION 'Documents are for Admin and Accounts only'; END IF;
  IF v_days NOT IN (1, 7, 30) THEN RAISE EXCEPTION 'Link can be valid for 1, 7 or 30 days'; END IF;
  IF v_mobile IS NOT NULL AND v_mobile !~ '^[6-9][0-9]{9}$' THEN RAISE EXCEPTION 'Mobile number must be 10 digits'; END IF;
  SELECT array_agg(DISTINCT (e)::bigint) INTO v_ids FROM jsonb_array_elements_text(coalesce(p->'doc_ids', '[]')) e;
  IF coalesce(array_length(v_ids, 1), 0) = 0 THEN RAISE EXCEPTION 'Choose at least one document'; END IF;
  IF array_length(v_ids, 1) > 20 THEN RAISE EXCEPTION 'Maximum 20 documents in one share'; END IF;
  SELECT string_agg(x::text, ', ') INTO v_bad FROM unnest(v_ids) x
  WHERE NOT EXISTS (SELECT 1 FROM public.lwb_company_docs d WHERE d.id = x AND d.removed_at IS NULL AND d.shareable
                    AND (v_admin OR NOT d.admin_only));
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'These documents can not be shared: %', v_bad; END IF;

  FOR f IN SELECT * FROM jsonb_array_elements(coalesce(p->'files', '[]')) LOOP
    v_path := coalesce(f->>'path', '');
    v_doc := split_part(v_path, '/', 2);
    IF v_path !~ '^COMPANY/[0-9]{1,18}/(FILE|SHARE)/[0-9a-f]{32}-[0-9]+-[a-z0-9]{1,12}\.(jpg|png|webp|pdf)$'
       OR NOT (v_doc::bigint = ANY(v_ids)) THEN RAISE EXCEPTION 'Wrong file in the share'; END IF;
    IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'lwb-documents' AND o.name = v_path) THEN
      RAISE EXCEPTION 'A file was not uploaded. Try again.';
    END IF;
    -- An original (FILE) must be a live file of that document; a SHARE copy must be this login's own upload.
    IF split_part(v_path, '/', 3) = 'FILE' AND NOT EXISTS (SELECT 1 FROM public.lwb_documents d
         WHERE d.path = v_path AND d.entity_type = 'COMPANY' AND d.removed_at IS NULL) THEN RAISE EXCEPTION 'Wrong file in the share'; END IF;
    IF split_part(v_path, '/', 3) = 'SHARE' AND split_part(split_part(v_path, '/', 4), '-', 1) <> replace(auth.uid()::text, '-', '') THEN
      RAISE EXCEPTION 'Wrong file in the share';
    END IF;
    v_files := v_files || jsonb_build_object('path', v_path, 'doc_id', v_doc::bigint,
      'name', left(coalesce(nullif(btrim(f->>'name'), ''), 'Document'), 120),
      'mime', CASE WHEN v_path LIKE '%.pdf' THEN 'application/pdf' ELSE 'image/jpeg' END);
  END LOOP;
  IF jsonb_array_length(v_files) = 0 THEN RAISE EXCEPTION 'The chosen documents have no file yet. Upload the file first.'; END IF;
  IF jsonb_array_length(v_files) > 40 THEN RAISE EXCEPTION 'Maximum 40 files in one share'; END IF;

  v_exp := now() + make_interval(days => v_days);
  INSERT INTO public.lwb_company_doc_shares(token, doc_ids, files, party_name, party_code, mobile, watermark, channel, expires_at, created_by)
  VALUES (v_token, v_ids, v_files, left(nullif(btrim(coalesce(p->>'party_name', '')), ''), 120),
    left(nullif(btrim(coalesce(p->>'party_code', '')), ''), 40), v_mobile,
    left(nullif(btrim(coalesce(p->>'watermark', '')), ''), 120),
    CASE WHEN upper(coalesce(p->>'channel', '')) IN ('WHATSAPP','LINK','EMAIL','FILES') THEN upper(p->>'channel') ELSE 'LINK' END,
    v_exp, auth.uid())
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'token', v_token, 'expires_at', v_exp, 'files', jsonb_array_length(v_files));
END;
$fn$;

-- Stop a link before its time.
CREATE OR REPLACE FUNCTION public.lwb_cdoc_share_revoke(p_id bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cdoc_can() THEN RAISE EXCEPTION 'Documents are for Admin and Accounts only'; END IF;
  UPDATE public.lwb_company_doc_shares SET revoked_at = now(), revoked_by = auth.uid() WHERE id = p_id AND revoked_at IS NULL;
  RETURN FOUND;
END;
$fn$;

-- The party opens the link (Edge Function lwb-doc-share, service role only). NULL = no such / stopped / expired.
CREATE OR REPLACE FUNCTION public.lwb_cdoc_share_open(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE s public.lwb_company_doc_shares; v_by text; v_live jsonb;
BEGIN
  IF coalesce(p_token, '') !~ '^[0-9a-f]{32}$' THEN RETURN NULL; END IF;
  SELECT * INTO s FROM public.lwb_company_doc_shares x WHERE x.token = p_token FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF s.revoked_at IS NOT NULL OR s.expires_at <= now() THEN
    RETURN jsonb_build_object('stopped', true, 'expires_at', s.expires_at, 'revoked', s.revoked_at IS NOT NULL);
  END IF;
  -- Leave out the files of a document removed or made not-shareable after the link was sent.
  SELECT coalesce(jsonb_agg(f), '[]') INTO v_live FROM jsonb_array_elements(s.files) f
  WHERE EXISTS (SELECT 1 FROM public.lwb_company_docs d WHERE d.id = (f->>'doc_id')::bigint AND d.removed_at IS NULL AND d.shareable);
  UPDATE public.lwb_company_doc_shares SET open_count = open_count + 1, first_opened_at = coalesce(first_opened_at, now()), last_opened_at = now()
  WHERE id = s.id;
  SELECT coalesce(p.full_name, '') INTO v_by FROM public.user_profiles p WHERE p.id = s.created_by;
  IF s.first_opened_at IS NULL AND s.created_by IS NOT NULL THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
    VALUES (s.created_by, 'Documents opened: ' || coalesce(s.party_name, 'party'),
      coalesce(s.party_name, 'The party') || ' opened the ' || jsonb_array_length(v_live) || ' document file(s) you sent.', 'DOC_SHARE_OPENED');
  END IF;
  RETURN jsonb_build_object('party_name', s.party_name, 'by_name', v_by, 'watermark', s.watermark,
    'expires_at', s.expires_at, 'created_at', s.created_at, 'files', v_live);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Reminders (bell + phone alert). Each step once per document; a new expiry date starts again.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_cdoc_remind_internal()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_today date := public.lwb_cdoc_today();
  d record; u record; g record;
  v_left int; v_key text; v_title text; v_msg text; v_sent int := 0;
  v_period date := (date_trunc('month', v_today) - interval '1 month')::date;
  v_due date; v_gid bigint;
BEGIN
  FOR d IN SELECT * FROM public.lwb_company_docs x WHERE x.removed_at IS NULL AND x.expiry_date IS NOT NULL LOOP
    v_left := d.expiry_date - v_today;
    v_key := NULL;
    IF v_left > 0 AND v_left = ANY(d.remind_days) THEN v_key := 'D' || v_left || ':' || d.expiry_date;
    ELSIF v_left <= 0 AND (-v_left) % 7 = 0 THEN v_key := 'X' || (-v_left) || ':' || d.expiry_date;
    END IF;
    IF v_key IS NULL THEN CONTINUE; END IF;
    INSERT INTO public.lwb_company_doc_reminders(doc_id, rkey) VALUES (d.id, v_key) ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN CONTINUE; END IF;
    v_title := CASE WHEN v_left > 0 THEN 'Renew ' || d.name || ' in ' || v_left || CASE WHEN v_left = 1 THEN ' day' ELSE ' days' END
                    WHEN v_left = 0 THEN d.name || ' expires today' ELSE d.name || ' expired ' || (-v_left) || ' days ago' END;
    v_msg := concat_ws(' · ', 'Expiry ' || to_char(d.expiry_date, 'DD/MM/YYYY'), CASE WHEN d.doc_no IS NOT NULL THEN 'No. ' || d.doc_no END,
      CASE WHEN d.fees IS NOT NULL THEN 'Fees Rs ' || to_char(d.fees, 'FM99999999990') END, d.contact,
      'Renew it, then open Documents and save the new expiry date + file.');
    FOR u IN SELECT p.id FROM public.user_profiles p WHERE p.active = true
             AND lower(btrim(p.role)) = ANY(CASE WHEN d.admin_only THEN ARRAY['admin'] ELSE d.remind_roles END) LOOP
      INSERT INTO public.erp_notifications (user_id, title, message, notification_type) VALUES (u.id, left(v_title, 200), left(v_msg, 900), 'DOC_RENEWAL');
      v_sent := v_sent + 1;
    END LOOP;
  END LOOP;

  -- GST returns of last month: GSTR-1 due on the 11th, GSTR-3B on the 20th of this month.
  FOR g IN SELECT * FROM (VALUES ('GSTR1', 'GSTR-1', 11), ('GSTR3B', 'GSTR-3B', 20)) AS t(code, label, dueday) LOOP
    IF EXISTS (SELECT 1 FROM public.lwb_company_docs x WHERE x.removed_at IS NULL AND x.gst_type = g.code
               AND x.gst_period = v_period AND x.filed_on IS NOT NULL) THEN CONTINUE; END IF;
    v_due := (date_trunc('month', v_today) + make_interval(days => g.dueday - 1))::date;
    v_left := v_due - v_today;
    IF NOT (v_left IN (3, 1, 0) OR (v_left < 0 AND (-v_left) % 2 = 0)) THEN CONTINUE; END IF;
    v_gid := -(extract(year FROM v_period)::bigint * 100 + extract(month FROM v_period)::bigint) * 10 - CASE g.code WHEN 'GSTR1' THEN 1 ELSE 2 END;
    INSERT INTO public.lwb_company_doc_reminders(doc_id, rkey) VALUES (v_gid, 'G' || v_left) ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN CONTINUE; END IF;
    v_title := g.label || ' ' || to_char(v_period, 'Mon YYYY') || CASE WHEN v_left > 0 THEN ' due in ' || v_left || CASE WHEN v_left = 1 THEN ' day' ELSE ' days' END
                 WHEN v_left = 0 THEN ' due today' ELSE ' late by ' || (-v_left) || ' days' END;
    v_msg := 'Last date ' || to_char(v_due, 'DD/MM/YYYY') || '. After filing, open Documents > GST and save Filed + the return PDF.';
    FOR u IN SELECT p.id FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','accounts') LOOP
      INSERT INTO public.erp_notifications (user_id, title, message, notification_type) VALUES (u.id, v_title, v_msg, 'DOC_GST_DUE');
      v_sent := v_sent + 1;
    END LOOP;
  END LOOP;
  RETURN v_sent;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_cdoc_remind_internal() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_cdoc_remind_now()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cdoc_can() THEN RAISE EXCEPTION 'Documents are for Admin and Accounts only'; END IF;
  RETURN public.lwb_cdoc_remind_internal();
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_cdoc_today(), public.lwb_cdoc_list(), public.lwb_cdoc_save(jsonb), public.lwb_cdoc_remove(bigint),
  public.lwb_cdoc_pack_save(bigint,text,bigint[]), public.lwb_cdoc_share_create(jsonb), public.lwb_cdoc_share_revoke(bigint),
  public.lwb_cdoc_share_open(text), public.lwb_cdoc_remind_now() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_cdoc_list(), public.lwb_cdoc_save(jsonb), public.lwb_cdoc_remove(bigint),
  public.lwb_cdoc_pack_save(bigint,text,bigint[]), public.lwb_cdoc_share_create(jsonb), public.lwb_cdoc_share_revoke(bigint),
  public.lwb_cdoc_remind_now() TO authenticated;
REVOKE ALL ON FUNCTION public.lwb_cdoc_share_open(text) FROM authenticated;
DO $g$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT EXECUTE ON FUNCTION public.lwb_cdoc_share_open(text) TO service_role;
  END IF;
END $g$;

-- First pack, so "Share" has a one-tap choice (Admin fills the documents into it from the page).
INSERT INTO public.lwb_company_doc_packs(name, doc_ids)
SELECT 'KYC Pack', '{}' WHERE NOT EXISTS (SELECT 1 FROM public.lwb_company_doc_packs);

COMMIT;

-- Every day 9:00 India time (03:30 UTC), only where pg_cron is on.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'lwb_company_doc_reminder';
    PERFORM cron.schedule('lwb_company_doc_reminder', '30 3 * * *', 'SELECT public.lwb_cdoc_remind_internal()');
  END IF;
END
$cron$;

NOTIFY pgrst, 'reload schema';

SELECT 'company documents' AS item, (to_regclass('public.lwb_company_docs') IS NOT NULL)::text AS ok
UNION ALL SELECT 'share links', (to_regclass('public.lwb_company_doc_shares') IS NOT NULL)::text
UNION ALL SELECT 'reminder job', coalesce((SELECT 'scheduled' FROM pg_extension WHERE extname = 'pg_cron'), 'pg_cron off: use Send reminders now');
