-- LUXURY WRIST BRAND ERP — COMPLAINT BOX (staff queries / problems)
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- Any active ERP login (salesman, godown manager, driver, accountant, transport,
-- Sales Head, Admin) can raise a complaint or query:
--   MARKET · GODOWN · DRIVER (delivery / vehicle) · ACCOUNTS (payment / bill) · OTHER
-- Admin and Sales Head (MANAGER) see every complaint, reply, and mark it Solved.
-- The person who raised it sees only his own complaints, the replies and the status,
-- can reply back, or say "Problem solved". A reply on a solved complaint opens it again.
--
-- 🔔 New complaint / staff reply   -> every active Admin and Sales Head (not the sender)
--    Office reply / solved          -> the person who raised it
-- Status: OPEN (waiting for office) -> ANSWERED (office replied) -> RESOLVED
--
-- Complaints only. Orders, stock, bills, payments and Tally are NOT changed.

BEGIN;

-- Logged-in active user's role ('' when not active).
CREATE OR REPLACE FUNCTION public.lwb_complaint_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce((SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true), '');
$fn$;
CREATE OR REPLACE FUNCTION public.lwb_complaint_reviewer()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT public.lwb_complaint_role() IN ('admin','manager');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_complaint_role(), public.lwb_complaint_reviewer() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_complaint_role(), public.lwb_complaint_reviewer() TO authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_complaints (
  id bigserial PRIMARY KEY,
  category text NOT NULL CHECK (category IN ('MARKET','GODOWN','DRIVER','ACCOUNTS','OTHER')),
  subject text NOT NULL CHECK (length(subject) BETWEEN 1 AND 150),
  details text CHECK (details IS NULL OR length(details) <= 2000),
  order_no text,
  party_name text,
  photo_path text,
  urgent boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','ANSWERED','RESOLVED')),
  created_by uuid NOT NULL DEFAULT auth.uid(),
  created_by_name text,
  created_by_role text,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_activity_at timestamptz NOT NULL DEFAULT now(),
  reply_count integer NOT NULL DEFAULT 0,
  resolved_by uuid,
  resolved_by_name text,
  resolved_at timestamptz
);
CREATE INDEX IF NOT EXISTS lwb_complaints_activity_idx ON public.lwb_complaints(last_activity_at DESC);
CREATE INDEX IF NOT EXISTS lwb_complaints_by_idx ON public.lwb_complaints(created_by, last_activity_at DESC);
CREATE INDEX IF NOT EXISTS lwb_complaints_status_idx ON public.lwb_complaints(status);

CREATE TABLE IF NOT EXISTS public.lwb_complaint_replies (
  id bigserial PRIMARY KEY,
  complaint_id bigint NOT NULL REFERENCES public.lwb_complaints(id) ON DELETE CASCADE,
  body text NOT NULL CHECK (length(body) BETWEEN 1 AND 2000),
  by_user uuid NOT NULL DEFAULT auth.uid(),
  by_name text,
  by_office boolean NOT NULL DEFAULT false,
  status_after text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_complaint_replies_c_idx ON public.lwb_complaint_replies(complaint_id, created_at);

-- Read: own complaints, or all for Admin / Sales Head. Writes only through the functions below.
ALTER TABLE public.lwb_complaints ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_complaint_replies ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_complaints_read ON public.lwb_complaints;
CREATE POLICY lwb_complaints_read ON public.lwb_complaints FOR SELECT TO authenticated
  USING ((created_by = auth.uid() AND public.lwb_complaint_role() <> '') OR public.lwb_complaint_reviewer());
DROP POLICY IF EXISTS lwb_complaint_replies_read ON public.lwb_complaint_replies;
CREATE POLICY lwb_complaint_replies_read ON public.lwb_complaint_replies FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.lwb_complaints c WHERE c.id = complaint_id
    AND ((c.created_by = auth.uid() AND public.lwb_complaint_role() <> '') OR public.lwb_complaint_reviewer())));
REVOKE ALL ON TABLE public.lwb_complaints, public.lwb_complaint_replies FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_complaints, public.lwb_complaint_replies TO authenticated;
REVOKE ALL ON SEQUENCE public.lwb_complaints_id_seq, public.lwb_complaint_replies_id_seq FROM PUBLIC, anon, authenticated;

-- 🔔 to every active Admin and Sales Head except the sender.
CREATE OR REPLACE FUNCTION public.lwb_complaint_notify_office(p_title text, p_msg text, p_type text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $fn$
  INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
  SELECT p.id, p_title, left(p_msg, 600), p_type
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') AND p.id IS DISTINCT FROM auth.uid();
$fn$;
REVOKE ALL ON FUNCTION public.lwb_complaint_notify_office(text,text,text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_complaint_label(p_cat text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE p_cat WHEN 'MARKET' THEN 'Market' WHEN 'GODOWN' THEN 'Godown' WHEN 'DRIVER' THEN 'Driver / Delivery'
    WHEN 'ACCOUNTS' THEN 'Accounts / Payment' ELSE 'Other' END;
$fn$;

-- ---------------------------------------------------------------------------
-- Raise a complaint. p: {category, subject, details, order_no, party_name, photo_path, urgent}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_complaint_add(p jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_complaint_role();
  v_cat text := upper(btrim(coalesce(p->>'category','')));
  v_subject text := nullif(btrim(coalesce(p->>'subject','')),'');
  v_details text := nullif(btrim(coalesce(p->>'details','')),'');
  v_name text;
  r public.lwb_complaints%ROWTYPE;
BEGIN
  IF v_role = '' THEN RAISE EXCEPTION 'Login is not active'; END IF;
  IF v_cat NOT IN ('MARKET','GODOWN','DRIVER','ACCOUNTS','OTHER') THEN RAISE EXCEPTION 'Please select what the complaint is about'; END IF;
  IF v_subject IS NULL THEN RAISE EXCEPTION 'Please enter the problem in short'; END IF;
  IF nullif(p->>'photo_path','') IS NOT NULL AND split_part(p->>'photo_path','/',1) <> auth.uid()::text THEN
    RAISE EXCEPTION 'Invalid photo';
  END IF;
  SELECT coalesce(nullif(btrim(u.full_name),''), 'Staff') INTO v_name FROM public.user_profiles u WHERE u.id = auth.uid();
  INSERT INTO public.lwb_complaints(category, subject, details, order_no, party_name, photo_path, urgent, created_by, created_by_name, created_by_role)
  VALUES (v_cat, left(v_subject,150), left(v_details,2000),
    upper(nullif(btrim(coalesce(p->>'order_no','')),'')), left(nullif(btrim(coalesce(p->>'party_name','')),''),150),
    nullif(p->>'photo_path',''), coalesce((p->>'urgent')::boolean,false), auth.uid(), v_name, v_role)
  RETURNING * INTO r;
  PERFORM public.lwb_complaint_notify_office(
    CASE WHEN r.urgent THEN 'URGENT · ' ELSE '' END || 'New complaint: ' || public.lwb_complaint_label(r.category),
    'CMP-' || r.id || ' · ' || r.subject || coalesce(' · ' || r.order_no, '') || coalesce(' · ' || r.party_name, '')
      || ' · by ' || v_name || ' (' || upper(v_role) || ').',
    'COMPLAINT_NEW');
  RETURN r.id;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Reply and / or change status.
--   Admin / Sales Head: p_status ANSWERED (default with a reply), RESOLVED, or OPEN (reopen).
--   Raiser: p_status OPEN (default with a reply: back to the office) or RESOLVED ("Problem solved").
--   p_body may be empty only when the status changes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_complaint_reply(p_id bigint, p_body text, p_status text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_complaint_role();
  v_office boolean := public.lwb_complaint_reviewer();
  v_body text := left(nullif(btrim(coalesce(p_body,'')),''), 2000);
  v_status text := upper(nullif(btrim(coalesce(p_status,'')),''));
  v_name text;
  r public.lwb_complaints%ROWTYPE;
BEGIN
  IF v_role = '' THEN RAISE EXCEPTION 'Login is not active'; END IF;
  SELECT * INTO r FROM public.lwb_complaints WHERE id = p_id FOR UPDATE;
  IF r.id IS NULL OR (NOT v_office AND r.created_by IS DISTINCT FROM auth.uid()) THEN RAISE EXCEPTION 'Complaint not found'; END IF;
  -- The raiser answers as staff, even when he is Admin / Sales Head himself.
  IF r.created_by = auth.uid() THEN v_office := false; END IF;
  IF v_status IS NULL THEN v_status := CASE WHEN v_office THEN 'ANSWERED' ELSE 'OPEN' END; END IF;
  IF v_status NOT IN ('OPEN','ANSWERED','RESOLVED') OR (NOT v_office AND v_status = 'ANSWERED') THEN RAISE EXCEPTION 'Invalid status'; END IF;
  IF v_body IS NULL AND v_status = r.status THEN RAISE EXCEPTION 'Please write a reply'; END IF;
  IF v_body IS NULL AND v_status = 'ANSWERED' THEN RAISE EXCEPTION 'Please write a reply'; END IF;

  SELECT coalesce(nullif(btrim(u.full_name),''), 'Staff') INTO v_name FROM public.user_profiles u WHERE u.id = auth.uid();
  INSERT INTO public.lwb_complaint_replies(complaint_id, body, by_user, by_name, by_office, status_after)
  VALUES (r.id, coalesce(v_body, CASE v_status WHEN 'RESOLVED' THEN 'Marked solved.' ELSE 'Opened again.' END),
    auth.uid(), v_name, v_office, CASE WHEN v_status <> r.status THEN v_status END);
  UPDATE public.lwb_complaints SET status = v_status, last_activity_at = now(), reply_count = reply_count + 1,
    resolved_by = CASE WHEN v_status = 'RESOLVED' THEN auth.uid() END,
    resolved_by_name = CASE WHEN v_status = 'RESOLVED' THEN v_name END,
    resolved_at = CASE WHEN v_status = 'RESOLVED' THEN now() END
  WHERE id = r.id;

  IF v_status = 'RESOLVED' THEN
    -- Solved: the office "new complaint / reply" bells for it are done.
    UPDATE public.erp_notifications SET is_read = true
    WHERE is_read = false AND notification_type IN ('COMPLAINT_NEW','COMPLAINT_REPLY')
      AND message LIKE 'CMP-' || r.id || ' %';
  END IF;

  IF v_office THEN
    INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
    VALUES (r.created_by,
      CASE v_status WHEN 'RESOLVED' THEN 'Your complaint is solved' WHEN 'OPEN' THEN 'Your complaint is opened again' ELSE 'Reply on your complaint' END,
      left('CMP-' || r.id || ' · ' || r.subject || coalesce(' · ' || v_name || ': ' || v_body, ' · by ' || v_name) || '.', 600),
      CASE v_status WHEN 'RESOLVED' THEN 'COMPLAINT_RESOLVED' ELSE 'COMPLAINT_REPLY' END);
  ELSE
    PERFORM public.lwb_complaint_notify_office(
      CASE v_status WHEN 'RESOLVED' THEN 'Complaint closed by staff: problem solved' ELSE 'Staff replied on complaint' END,
      'CMP-' || r.id || ' · ' || r.subject || coalesce(' · ' || v_name || ': ' || v_body, ' · by ' || v_name) || '.',
      CASE v_status WHEN 'RESOLVED' THEN 'COMPLAINT_CLOSED' ELSE 'COMPLAINT_REPLY' END);
  END IF;
  RETURN v_status;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_complaint_add(jsonb), public.lwb_complaint_reply(bigint,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_complaint_add(jsonb), public.lwb_complaint_reply(bigint,text,text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Private photo bucket: upload into your own folder; you and Admin / Sales Head can see it.
-- ---------------------------------------------------------------------------
INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lwb-complaint-photos', 'lwb-complaint-photos', false, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

DROP POLICY IF EXISTS lwb_complaint_photo_upload ON storage.objects;
CREATE POLICY lwb_complaint_photo_upload ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'lwb-complaint-photos' AND (storage.foldername(name))[1] = auth.uid()::text AND public.lwb_complaint_role() <> '');
DROP POLICY IF EXISTS lwb_complaint_photo_read ON storage.objects;
CREATE POLICY lwb_complaint_photo_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'lwb-complaint-photos' AND ((storage.foldername(name))[1] = auth.uid()::text OR public.lwb_complaint_reviewer()));

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: 4 rows, all true.
SELECT 'complaints table' AS item, to_regclass('public.lwb_complaints') IS NOT NULL AS ok
UNION ALL SELECT 'replies table', to_regclass('public.lwb_complaint_replies') IS NOT NULL
UNION ALL SELECT 'reply function', to_regprocedure('public.lwb_complaint_reply(bigint,text,text)') IS NOT NULL
UNION ALL SELECT 'photo bucket', EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'lwb-complaint-photos');
