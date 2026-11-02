-- LUXURY WRIST BRAND ERP — PURCHASE REGISTER UPGRADE (2 Nov 2026)
--
-- Mohit asked:
--   1. A Purchase List like the PO / Sales List, easy to find in the menu (also for the Sales Head and
--      the Godown Manager, who checks the vehicle).
--   2. When a Goods Inward entry says Damage / Leakage / Breakage, or "Check later" (pending), the
--      Godown Manager gets a task: "upload the photos of this vehicle". The task closes by itself
--      once the vehicle is checked and the damage photos are added.
--   3. A register of the scanned sales bill PDFs uploaded every night, searchable by invoice number.
--   4. A popup as soon as a purchase invoice number that already exists is typed.
--
-- Needs: lwb_purchase_claim_setup.sql, lwb_documents_setup.sql, lwb_task_management_setup.sql.
-- If lwb_purchase_claim_setup.sql is run again later, run this file again after it
-- (it puts back the Godown Manager rights on lwb_save_purchase_check and the check read policies).
-- Safe to run again.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Who may check a purchase vehicle: Admin, Sales Head (manager), Godown Manager (warehouse).
--    Claims (mail, approval, amount) stay Admin / Sales Head only (lwb_pc_user, unchanged).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_pr_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce((SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true), '');
$fn$;
CREATE OR REPLACE FUNCTION public.lwb_pc_checker()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT public.lwb_pr_role() IN ('admin','manager','warehouse');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_pr_role() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_pc_checker() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_pr_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_pc_checker() TO authenticated;

-- Godown Manager and Accounts can see which bills are checked (the Purchase List status column).
DROP POLICY IF EXISTS lwb_purchase_checks_read ON public.lwb_purchase_checks;
CREATE POLICY lwb_purchase_checks_read ON public.lwb_purchase_checks FOR SELECT TO authenticated
  USING (public.lwb_pc_checker() OR public.lwb_pr_role() = 'accounts');
DROP POLICY IF EXISTS lwb_purchase_check_items_read ON public.lwb_purchase_check_items;
CREATE POLICY lwb_purchase_check_items_read ON public.lwb_purchase_check_items FOR SELECT TO authenticated
  USING (public.lwb_pc_checker() OR public.lwb_pr_role() = 'accounts');

-- Same as lwb_purchase_claim_setup.sql, plus: the Godown Manager may save the vehicle check
-- while the claim has not gone to the company yet (NONE / PENDING).
CREATE OR REPLACE FUNCTION public.lwb_save_purchase_check(
  p_inward_id uuid, p_verified_on date, p_note text, p_items jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE cid uuid; dmg boolean; v_old text;
BEGIN
  IF NOT public.lwb_pc_checker() THEN RAISE EXCEPTION 'Only Admin, Sales Head or Godown Manager can check purchase vehicles'; END IF;
  IF p_verified_on IS NULL THEN RAISE EXCEPTION 'Verification date is required'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_goods_inward g WHERE g.id = p_inward_id) THEN RAISE EXCEPTION 'Purchase bill not found'; END IF;
  SELECT c.claim_status INTO v_old FROM public.lwb_purchase_checks c WHERE c.inward_id = p_inward_id;
  IF public.lwb_pr_role() = 'warehouse' AND coalesce(v_old,'NONE') NOT IN ('NONE','PENDING') THEN
    RAISE EXCEPTION 'The claim is already with the company. Ask Admin / Sales Head to change it.';
  END IF;
  dmg := jsonb_typeof(p_items) = 'array' AND jsonb_array_length(p_items) > 0;
  INSERT INTO public.lwb_purchase_checks (inward_id, verified_on, has_damage, claim_status, note, created_by, updated_by)
  VALUES (p_inward_id, p_verified_on, dmg, CASE WHEN dmg THEN 'PENDING' ELSE 'NONE' END, nullif(btrim(p_note),''), auth.uid(), auth.uid())
  ON CONFLICT (inward_id) DO UPDATE SET
    verified_on = EXCLUDED.verified_on, has_damage = EXCLUDED.has_damage, note = EXCLUDED.note,
    claim_status = CASE WHEN NOT EXCLUDED.has_damage THEN 'NONE'
                        WHEN public.lwb_purchase_checks.claim_status = 'NONE' THEN 'PENDING'
                        ELSE public.lwb_purchase_checks.claim_status END,
    updated_at = now(), updated_by = auth.uid()
  RETURNING id INTO cid;
  DELETE FROM public.lwb_purchase_check_items WHERE check_id = cid;
  IF dmg THEN
    INSERT INTO public.lwb_purchase_check_items (check_id, sku_id, sku_name, pcs_per_case, issue, cases, pcs)
    SELECT cid, nullif(x->>'sku_id','')::uuid, x->>'sku_name', greatest(coalesce((x->>'pcs_per_case')::int,1),1),
           upper(x->>'issue'), coalesce((x->>'cases')::int,0), coalesce((x->>'pcs')::int,0)
    FROM jsonb_array_elements(p_items) x;
  END IF;
  RETURN cid;  -- trg_lwb_purchase_check_task closes the photo task when nothing is left

END;
$function$;

-- ---------------------------------------------------------------------------
-- 2. Godown Manager photo task, linked to the purchase bill.
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_tasks ADD COLUMN IF NOT EXISTS ref_type text;
ALTER TABLE public.lwb_tasks ADD COLUMN IF NOT EXISTS ref_id text;
CREATE INDEX IF NOT EXISTS lwb_tasks_ref_idx ON public.lwb_tasks (ref_type, ref_id) WHERE ref_type IS NOT NULL;

-- What is still to do on a bill: CHECK (vehicle not checked), PHOTO (damage saved, no damage photo), or ''.
CREATE OR REPLACE FUNCTION public.lwb_purchase_todo(p_inward uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE
    WHEN c.id IS NULL THEN 'CHECK'
    WHEN c.has_damage AND NOT EXISTS (SELECT 1 FROM public.lwb_documents d
           WHERE d.entity_type = 'PURCHASE_BILL' AND d.entity_id = p_inward::text AND d.doc_type = 'DAMAGE' AND d.removed_at IS NULL)
      THEN 'PHOTO'
    ELSE '' END
  FROM (SELECT p_inward AS id) g LEFT JOIN public.lwb_purchase_checks c ON c.inward_id = g.id;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_todo(uuid) FROM PUBLIC, anon, authenticated;

-- Closes the bill's open photo tasks once nothing is left to do.
CREATE OR REPLACE FUNCTION public.lwb_purchase_task_sync(p_inward uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  n integer := 0;
  t record;
  v_by text;
BEGIN
  IF p_inward IS NULL OR public.lwb_purchase_todo(p_inward) <> '' THEN RETURN 0; END IF;
  SELECT coalesce(nullif(btrim(x.full_name),''), 'Staff') INTO v_by FROM public.user_profiles x WHERE x.id = auth.uid();
  FOR t IN SELECT * FROM public.lwb_tasks
           WHERE ref_type = 'PURCHASE_BILL' AND ref_id = p_inward::text AND status IN ('OPEN','IN_PROGRESS') FOR UPDATE LOOP
    UPDATE public.lwb_tasks SET status = 'DONE', done_at = now(), closed_by = auth.uid(),
      closed_by_name = coalesce(v_by, 'Auto'), last_activity_at = now(), update_count = update_count + 1
    WHERE id = t.id;
    INSERT INTO public.lwb_task_updates(task_id, body, by_user, by_name, status_after)
    VALUES (t.id, 'Done by itself: vehicle checked and photos added on the Purchase List.',
            coalesce(auth.uid(), t.assigned_to), coalesce(v_by, 'Auto'), 'DONE');
    PERFORM public.lwb_task_notify(t.assigned_by, 'Task done: ' || left(t.title, 100),
      'TSK-' || t.id || ' · ' || t.title || ' · photos added' || coalesce(' by ' || v_by, '') || '.', 'TASK_DONE');
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_task_sync(uuid) FROM PUBLIC, anon, authenticated;

-- Gives the photo task to the Godown Managers (active WAREHOUSE logins, or the ones picked).
-- Called by Goods Inward after saving (Damage / Check later) and by the Purchase List after a damage check.
-- Does nothing when the bill needs nothing, or when an open task for the bill already exists.
CREATE OR REPLACE FUNCTION public.lwb_purchase_photo_task(p_inward uuid, p_assignees uuid[] DEFAULT NULL)
RETURNS bigint[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_pr_role();
  v_todo text;
  g record;
  u record;
  v_name text;
  v_title text;
  v_details text;
  v_batch bigint;
  v_id bigint;
  v_ids bigint[] := '{}';
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  IF v_role NOT IN ('admin','manager') THEN RAISE EXCEPTION 'Only Admin / Sales Head give purchase photo tasks'; END IF;
  SELECT x.id, x.invoice_no, x.supplier_name, x.vehicle_no, x.received_date INTO g FROM public.lwb_goods_inward x WHERE x.id = p_inward;
  IF g.id IS NULL THEN RAISE EXCEPTION 'Purchase bill not found'; END IF;
  v_todo := public.lwb_purchase_todo(p_inward);
  IF v_todo = '' THEN RETURN v_ids; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_tasks t WHERE t.ref_type = 'PURCHASE_BILL' AND t.ref_id = p_inward::text
             AND t.status IN ('OPEN','IN_PROGRESS')) THEN RETURN v_ids; END IF;

  SELECT coalesce(nullif(btrim(x.full_name),''), 'Staff') INTO v_name FROM public.user_profiles x WHERE x.id = auth.uid();
  v_title := left(CASE WHEN v_todo = 'PHOTO' THEN 'Damage photos: vehicle ' ELSE 'Check vehicle + photos: ' END
             || coalesce(nullif(btrim(g.vehicle_no),''), 'no vehicle no.') || ' · Inv ' || g.invoice_no, 150);
  v_details := left(concat_ws(E'\n',
    'Purchase bill ' || g.invoice_no || ' · ' || g.supplier_name || ' · received ' || to_char(g.received_date, 'DD Mon YYYY'),
    CASE WHEN v_todo = 'PHOTO'
      THEN 'Damage / leakage / breakage is entered on this bill. Upload clear photos of every damaged case.'
      ELSE 'Unload and check this vehicle. Enter damage / leakage / shortage (or No Damage) and upload photos of any damage.' END,
    'Open the bill: Purchase List > ' || g.invoice_no || ' > Verify (the button below opens it).'), 2000);
  v_batch := nextval('public.lwb_task_batch_seq');

  FOR u IN SELECT p.id, coalesce(nullif(btrim(p.full_name),''), 'Staff') AS name, lower(btrim(p.role)) AS role
           FROM public.user_profiles p
           WHERE p.active = true AND lower(btrim(p.role)) = 'warehouse'
             AND (p_assignees IS NULL OR cardinality(p_assignees) = 0 OR p.id = ANY(p_assignees))
           ORDER BY p.full_name LOOP
    INSERT INTO public.lwb_tasks(batch_id, title, details, due_date, priority, assigned_to, assigned_to_name, assigned_to_role,
      assigned_by, assigned_by_name, assigned_by_role, ref_type, ref_id)
    VALUES (v_batch, v_title, v_details, v_today, CASE WHEN v_todo = 'PHOTO' THEN 'URGENT' ELSE 'NORMAL' END,
      u.id, u.name, u.role, auth.uid(), v_name, v_role, 'PURCHASE_BILL', p_inward::text)
    RETURNING id INTO v_id;
    v_ids := v_ids || v_id;
    PERFORM public.lwb_task_notify(u.id,
      CASE WHEN v_todo = 'PHOTO' THEN 'URGENT · ' ELSE '' END || 'New task: ' || left(v_title, 100),
      'TSK-' || v_id || ' · ' || v_title || ' · ' || g.supplier_name || ' · Due today · by ' || coalesce(v_name,'Staff') || '.',
      'TASK_NEW');
  END LOOP;
  RETURN v_ids;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_photo_task(uuid, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_photo_task(uuid, uuid[]) TO authenticated;

-- Close the task by itself when the check is saved (any page) or a damage photo is added.
CREATE OR REPLACE FUNCTION public.lwb_purchase_task_sync_trg()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF TG_TABLE_NAME = 'lwb_purchase_checks' THEN
    PERFORM public.lwb_purchase_task_sync(NEW.inward_id);
  ELSIF NEW.entity_type = 'PURCHASE_BILL' AND NEW.doc_type = 'DAMAGE' AND NEW.removed_at IS NULL
        AND NEW.entity_id ~ '^[0-9a-fA-F-]{36}$' THEN
    PERFORM public.lwb_purchase_task_sync(NEW.entity_id::uuid);
  END IF;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_task_sync_trg() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_purchase_check_task ON public.lwb_purchase_checks;
CREATE TRIGGER trg_lwb_purchase_check_task AFTER INSERT OR UPDATE ON public.lwb_purchase_checks
  FOR EACH ROW EXECUTE FUNCTION public.lwb_purchase_task_sync_trg();
DROP TRIGGER IF EXISTS trg_lwb_purchase_doc_task ON public.lwb_documents;
CREATE TRIGGER trg_lwb_purchase_doc_task AFTER INSERT ON public.lwb_documents
  FOR EACH ROW EXECUTE FUNCTION public.lwb_purchase_task_sync_trg();

-- Open photo tasks per bill, for the Purchase List "Photo task" column.
CREATE OR REPLACE FUNCTION public.lwb_purchase_open_tasks()
RETURNS TABLE(inward_id text, tasks integer, people text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT t.ref_id, count(*)::int, string_agg(DISTINCT t.assigned_to_name, ', ')
  FROM public.lwb_tasks t
  WHERE public.lwb_pr_role() IN ('admin','manager','warehouse','accounts')
    AND t.ref_type = 'PURCHASE_BILL' AND t.status IN ('OPEN','IN_PROGRESS')
  GROUP BY t.ref_id;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_open_tasks() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_open_tasks() TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Duplicate purchase invoice number: same number, ignoring spaces, "/", "-" and case.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_inv_key(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT upper(regexp_replace(coalesce(p,''), '[^A-Za-z0-9]', '', 'g')); $fn$;
GRANT EXECUTE ON FUNCTION public.lwb_inv_key(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_purchase_invoice_find(p_invoice text)
RETURNS TABLE(id uuid, invoice_no text, supplier_id uuid, supplier_name text, invoice_date date, received_date date, vehicle_no text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.lwb_pr_role() NOT IN ('admin','manager','warehouse','accounts') THEN RAISE EXCEPTION 'Not allowed'; END IF;
  IF length(public.lwb_inv_key(p_invoice)) = 0 THEN RETURN; END IF;
  RETURN QUERY
    SELECT g.id, g.invoice_no::text, nullif(to_jsonb(g)->>'supplier_id','')::uuid, g.supplier_name::text, g.invoice_date, g.received_date, g.vehicle_no::text
    FROM public.lwb_goods_inward g
    WHERE public.lwb_inv_key(g.invoice_no) = public.lwb_inv_key(p_invoice)
    ORDER BY g.created_at DESC LIMIT 10;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_invoice_find(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_invoice_find(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Sales bill PDF register: the scanned sales bills uploaded every night.
--    Upload / remove: Admin, Accounts. View / search: Admin, Accounts, Sales Head.
--    Files in the private bucket lwb-sales-bills at  <YYYY-MM-DD>/<user id without ->-<name>
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_sbs_can(p_mode text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT public.lwb_pr_role() = ANY(CASE WHEN p_mode = 'edit' THEN ARRAY['admin','accounts'] ELSE ARRAY['admin','accounts','manager'] END);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sbs_can(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sbs_can(text) TO authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_sales_bill_scans (
  id bigserial PRIMARY KEY,
  bill_date date NOT NULL,
  invoice_text text CHECK (invoice_text IS NULL OR length(invoice_text) <= 4000),  -- as typed, e.g. "LWB/101-LWB/140, 145"
  invoice_nos text[] NOT NULL DEFAULT '{}',                                         -- every invoice number in the PDF
  invoice_keys text[] NOT NULL DEFAULT '{}',                                        -- same, lwb_inv_key() of each
  path text NOT NULL UNIQUE,
  file_name text,
  size_bytes integer NOT NULL DEFAULT 0,
  note text CHECK (note IS NULL OR length(note) <= 300),
  uploaded_by uuid NOT NULL DEFAULT auth.uid(),
  uploaded_by_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  removed_at timestamptz,
  removed_by uuid
);
CREATE INDEX IF NOT EXISTS lwb_sales_bill_scans_date_idx ON public.lwb_sales_bill_scans (bill_date DESC) WHERE removed_at IS NULL;
CREATE INDEX IF NOT EXISTS lwb_sales_bill_scans_keys_idx ON public.lwb_sales_bill_scans USING gin (invoice_keys);
ALTER TABLE public.lwb_sales_bill_scans ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_sales_bill_scans FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_sales_bill_scans TO authenticated;
DROP POLICY IF EXISTS lwb_sales_bill_scans_read ON public.lwb_sales_bill_scans;
CREATE POLICY lwb_sales_bill_scans_read ON public.lwb_sales_bill_scans FOR SELECT TO authenticated
  USING (removed_at IS NULL AND public.lwb_sbs_can('view'));

INSERT INTO storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lwb-sales-bills', 'lwb-sales-bills', false, 31457280, ARRAY['application/pdf','image/jpeg','image/png'])
ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

DROP POLICY IF EXISTS lwb_sales_bills_upload ON storage.objects;
CREATE POLICY lwb_sales_bills_upload ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'lwb-sales-bills'
    AND array_length(storage.foldername(name), 1) = 1
    AND (storage.foldername(name))[1] ~ '^\d{4}-\d{2}-\d{2}$'
    AND split_part(storage.filename(name), '-', 1) = replace(auth.uid()::text, '-', '')
    AND public.lwb_sbs_can('edit'));
DROP POLICY IF EXISTS lwb_sales_bills_read ON storage.objects;
CREATE POLICY lwb_sales_bills_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'lwb-sales-bills' AND public.lwb_sbs_can('view'));

-- Register an uploaded PDF. p: {bill_date, path, file_name, size, invoice_text, invoice_nos[], note}
CREATE OR REPLACE FUNCTION public.lwb_sbs_add(p jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_date date;
  v_path text := btrim(coalesce(p->>'path',''));
  v_nos text[];
  v_name text;
  v_id bigint;
BEGIN
  IF NOT public.lwb_sbs_can('edit') THEN RAISE EXCEPTION 'Only Admin / Accounts can upload sales bill PDFs'; END IF;
  BEGIN v_date := (p->>'bill_date')::date;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Select the bill date'; END;
  IF v_date IS NULL THEN RAISE EXCEPTION 'Select the bill date'; END IF;
  IF v_date > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1 THEN RAISE EXCEPTION 'Bill date is in the future'; END IF;
  IF left(v_path, 11 + 32 + 1) <> to_char(v_date,'YYYY-MM-DD') || '/' || replace(auth.uid()::text,'-','') || '-'
     OR position('..' IN v_path) > 0 THEN
    RAISE EXCEPTION 'Wrong file path';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'lwb-sales-bills' AND o.name = v_path) THEN
    RAISE EXCEPTION 'File not found. Upload it again.';
  END IF;
  SELECT coalesce(array_agg(DISTINCT left(btrim(x),60)) FILTER (WHERE public.lwb_inv_key(x) <> ''), '{}') INTO v_nos
  FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p->'invoice_nos') = 'array' THEN p->'invoice_nos' ELSE '[]'::jsonb END) x;
  IF cardinality(v_nos) = 0 THEN RAISE EXCEPTION 'Enter the invoice numbers in this PDF (e.g. 101-140)'; END IF;
  IF cardinality(v_nos) > 2000 THEN RAISE EXCEPTION 'Maximum 2000 invoice numbers in one PDF'; END IF;
  SELECT coalesce(nullif(btrim(x.full_name),''), 'Staff') INTO v_name FROM public.user_profiles x WHERE x.id = auth.uid();
  INSERT INTO public.lwb_sales_bill_scans(bill_date, invoice_text, invoice_nos, invoice_keys, path, file_name, size_bytes, note, uploaded_by, uploaded_by_name)
  VALUES (v_date, left(nullif(btrim(coalesce(p->>'invoice_text','')),''), 4000), v_nos,
          (SELECT array_agg(DISTINCT public.lwb_inv_key(x)) FROM unnest(v_nos) x),
          v_path, left(nullif(btrim(coalesce(p->>'file_name','')),''),150), greatest(coalesce((p->>'size')::int,0),0),
          left(nullif(btrim(coalesce(p->>'note','')),''),300), auth.uid(), v_name)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sbs_add(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sbs_add(jsonb) TO authenticated;

-- Change the invoice list / note of a PDF, or remove it (Admin / Accounts).
CREATE OR REPLACE FUNCTION public.lwb_sbs_update(p_id bigint, p_invoice_text text, p_invoice_nos text[], p_note text, p_remove boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_nos text[];
BEGIN
  IF NOT public.lwb_sbs_can('edit') THEN RAISE EXCEPTION 'Only Admin / Accounts can change sales bill PDFs'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_sales_bill_scans s WHERE s.id = p_id AND s.removed_at IS NULL) THEN RAISE EXCEPTION 'PDF not found'; END IF;
  IF p_remove THEN
    UPDATE public.lwb_sales_bill_scans SET removed_at = now(), removed_by = auth.uid() WHERE id = p_id;
    RETURN;
  END IF;
  SELECT coalesce(array_agg(DISTINCT left(btrim(x),60)) FILTER (WHERE public.lwb_inv_key(x) <> ''), '{}') INTO v_nos FROM unnest(coalesce(p_invoice_nos,'{}')) x;
  IF cardinality(v_nos) = 0 THEN RAISE EXCEPTION 'Enter the invoice numbers in this PDF'; END IF;
  IF cardinality(v_nos) > 2000 THEN RAISE EXCEPTION 'Maximum 2000 invoice numbers in one PDF'; END IF;
  UPDATE public.lwb_sales_bill_scans SET invoice_text = left(nullif(btrim(coalesce(p_invoice_text,'')),''),4000), invoice_nos = v_nos,
    invoice_keys = (SELECT array_agg(DISTINCT public.lwb_inv_key(x)) FROM unnest(v_nos) x),
    note = left(nullif(btrim(coalesce(p_note,'')),''),300)
  WHERE id = p_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sbs_update(bigint, text, text[], text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sbs_update(bigint, text, text[], text, boolean) TO authenticated;

-- Search by invoice number: exact (ignoring spaces / "/" / "-" / case) first, then partial ("145" finds "LWB/145").
CREATE OR REPLACE FUNCTION public.lwb_sbs_find(p_q text)
RETURNS TABLE(id bigint, bill_date date, invoice_no text, exact boolean, path text, file_name text, invoice_count integer, uploaded_by_name text, created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE k text := public.lwb_inv_key(p_q);
BEGIN
  IF NOT public.lwb_sbs_can('view') THEN RAISE EXCEPTION 'Not allowed'; END IF;
  IF length(k) = 0 THEN RETURN; END IF;
  RETURN QUERY
    SELECT s.id, s.bill_date, n.no, public.lwb_inv_key(n.no) = k, s.path, s.file_name, cardinality(s.invoice_nos), s.uploaded_by_name, s.created_at
    FROM public.lwb_sales_bill_scans s
    CROSS JOIN LATERAL unnest(s.invoice_nos) AS n(no)
    WHERE s.removed_at IS NULL AND public.lwb_inv_key(n.no) LIKE '%' || k || '%'
    ORDER BY (public.lwb_inv_key(n.no) = k) DESC, s.bill_date DESC, n.no
    LIMIT 50;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_sbs_find(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sbs_find(text) TO authenticated;

COMMIT;

-- Check (all true):
SELECT to_regprocedure('public.lwb_purchase_photo_task(uuid,uuid[])') IS NOT NULL AS photo_task,
       to_regprocedure('public.lwb_purchase_invoice_find(text)') IS NOT NULL AS dup_find,
       to_regclass('public.lwb_sales_bill_scans') IS NOT NULL AS sales_bill_register,
       EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'lwb-sales-bills') AS sales_bill_bucket;
