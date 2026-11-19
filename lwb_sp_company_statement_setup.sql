-- LUXURY WRIST BRAND ERP — SHEET & PALLET: COMPANY STATEMENT MATCH + LEDGER START DATE (19 Nov 2026)
--
-- Run after lwb_sheet_pallet_setup.sql. Safe to run again.
--
-- Mohit: the company (ILS "Interlayer Sheets and Pallets Statement") shows the opening balance and,
-- per vehicle / invoice, the pallets and sheets it sent us (Issue) and got back (Receipt).
--   1. Upload that Excel on the Sheet & Pallet page (Company Match tab). Lines are kept in
--      lwb_sp_stmt (upload again = the same dates are replaced), opening / closing in lwb_sp_stmt_uploads.
--      Nothing from the statement is stored in the website files.
--   2. lwb_sp_start_from(date, pallets, sheets): the ledger starts on that date. Entries before it are
--      not deleted, only hidden on the page (lwb_sp_settings.start_date; set back to NULL = all shown).
--      The company opening balance on that date is written as one OPENING BALANCE row.
--   3. lwb_sp_entries.query_note: a "Query" tick an Admin / Manager can put on any entry.
-- Company pallets = Leap + Chep + Own pallets (our ledger keeps one pallet count).

BEGIN;

ALTER TABLE public.lwb_sp_settings ADD COLUMN IF NOT EXISTS start_date date;

ALTER TABLE public.lwb_sp_entries ADD COLUMN IF NOT EXISTS query_note text;
ALTER TABLE public.lwb_sp_entries ADD COLUMN IF NOT EXISTS query_at timestamptz;
ALTER TABLE public.lwb_sp_entries ADD COLUMN IF NOT EXISTS query_by uuid;
GRANT UPDATE (query_note, query_at, query_by) ON TABLE public.lwb_sp_entries TO authenticated;

-- Query tick / verify are not logged as edits (same as before for verify).
CREATE OR REPLACE FUNCTION public.lwb_sp_log_change()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE who text;
BEGIN
  SELECT coalesce(nullif(btrim(p.full_name),''), u.email) INTO who
    FROM auth.users u LEFT JOIN public.user_profiles p ON p.id = u.id WHERE u.id = auth.uid();
  IF TG_OP = 'DELETE' THEN
    INSERT INTO public.lwb_sp_history (action, entry_id, old_row, changed_by, changed_by_name)
    VALUES ('DELETE', OLD.id, to_jsonb(OLD), auth.uid(), who);
    RETURN OLD;
  END IF;
  IF (to_jsonb(NEW) - 'verified_at' - 'verified_by' - 'query_note' - 'query_at' - 'query_by')
     IS DISTINCT FROM (to_jsonb(OLD) - 'verified_at' - 'verified_by' - 'query_note' - 'query_at' - 'query_by') THEN
    INSERT INTO public.lwb_sp_history (action, entry_id, old_row, new_row, changed_by, changed_by_name)
    VALUES ('EDIT', OLD.id, to_jsonb(OLD), to_jsonb(NEW), auth.uid(), who);
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.lwb_sp_log_change() FROM PUBLIC, anon, authenticated;

-- ---------- company statement ----------
CREATE TABLE IF NOT EXISTS public.lwb_sp_stmt_uploads (
  id bigserial PRIMARY KEY,
  file_name text,
  from_date date NOT NULL,
  to_date date NOT NULL,
  opening jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {sheets, leap, chep, own}
  closing jsonb NOT NULL DEFAULT '{}'::jsonb,
  line_count integer NOT NULL DEFAULT 0,
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  uploaded_by uuid DEFAULT auth.uid(),
  uploaded_by_name text,
  CHECK (to_date >= from_date)
);

CREATE TABLE IF NOT EXISTS public.lwb_sp_stmt (
  id bigserial PRIMARY KEY,
  upload_id bigint REFERENCES public.lwb_sp_stmt_uploads(id) ON DELETE SET NULL,
  line_date date NOT NULL,
  plant text,
  ref_doc text,
  entry_type text NOT NULL,          -- Issue / Issue_Rev / Receipt / ... as the company writes it
  sheets integer NOT NULL DEFAULT 0, -- company sign: + sent to us, − got back
  leap integer NOT NULL DEFAULT 0,
  chep integer NOT NULL DEFAULT 0,
  own integer NOT NULL DEFAULT 0,
  vehicle_no text,
  inv_no text
);
CREATE INDEX IF NOT EXISTS lwb_sp_stmt_date_idx ON public.lwb_sp_stmt (line_date);

ALTER TABLE public.lwb_sp_stmt ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_sp_stmt_uploads ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_sp_stmt_read ON public.lwb_sp_stmt;
CREATE POLICY lwb_sp_stmt_read ON public.lwb_sp_stmt FOR SELECT TO authenticated USING (public.lwb_sp_user());
DROP POLICY IF EXISTS lwb_sp_stmt_uploads_read ON public.lwb_sp_stmt_uploads;
CREATE POLICY lwb_sp_stmt_uploads_read ON public.lwb_sp_stmt_uploads FOR SELECT TO authenticated USING (public.lwb_sp_user());
REVOKE ALL ON TABLE public.lwb_sp_stmt, public.lwb_sp_stmt_uploads FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_sp_stmt, public.lwb_sp_stmt_uploads TO authenticated;

-- p = {file_name, from_date, to_date, opening:{sheets,leap,chep,own}, closing:{...},
--      lines:[{line_date, plant, ref_doc, entry_type, sheets, leap, chep, own, vehicle_no, inv_no}]}
CREATE OR REPLACE FUNCTION public.lwb_sp_stmt_upload(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  d1 date; d2 date; up bigint; n integer; who text;
BEGIN
  IF NOT public.lwb_sp_editor() THEN RAISE EXCEPTION 'Only Admin / Manager can upload the company statement'; END IF;
  d1 := (p->>'from_date')::date; d2 := (p->>'to_date')::date;
  IF d1 IS NULL OR d2 IS NULL OR d2 < d1 THEN RAISE EXCEPTION 'Statement dates not found'; END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'No statement lines'; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p->'lines') l
             WHERE (l->>'line_date')::date NOT BETWEEN d1 AND d2) THEN
    RAISE EXCEPTION 'A line is outside the statement dates';
  END IF;
  SELECT coalesce(nullif(btrim(x.full_name),''), u.email) INTO who
    FROM auth.users u LEFT JOIN public.user_profiles x ON x.id = u.id WHERE u.id = auth.uid();
  INSERT INTO public.lwb_sp_stmt_uploads (file_name, from_date, to_date, opening, closing, line_count, uploaded_by_name)
  VALUES (left(p->>'file_name', 200), d1, d2, coalesce(p->'opening','{}'::jsonb), coalesce(p->'closing','{}'::jsonb),
          jsonb_array_length(p->'lines'), who)
  RETURNING id INTO up;
  DELETE FROM public.lwb_sp_stmt WHERE line_date BETWEEN d1 AND d2;
  INSERT INTO public.lwb_sp_stmt (upload_id, line_date, plant, ref_doc, entry_type, sheets, leap, chep, own, vehicle_no, inv_no)
  SELECT up, (l->>'line_date')::date, left(nullif(btrim(l->>'plant'),''),60), left(nullif(btrim(l->>'ref_doc'),''),40),
         left(coalesce(nullif(btrim(l->>'entry_type'),''),'?'),30),
         coalesce((l->>'sheets')::numeric,0)::integer, coalesce((l->>'leap')::numeric,0)::integer,
         coalesce((l->>'chep')::numeric,0)::integer, coalesce((l->>'own')::numeric,0)::integer,
         left(upper(regexp_replace(coalesce(l->>'vehicle_no',''),'[^A-Za-z0-9]','','g')),15),
         left(nullif(btrim(l->>'inv_no'),''),40)
    FROM jsonb_array_elements(p->'lines') l;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN jsonb_build_object('upload_id', up, 'lines', n);
END;
$function$;
REVOKE ALL ON FUNCTION public.lwb_sp_stmt_upload(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sp_stmt_upload(jsonb) TO authenticated;

-- Ledger starts on p_date with the company opening balance (pallets, sheets).
-- Entries before p_date stay in the table (hidden on the page). Company OPENING rows on or after
-- p_date are replaced by the new one (a copy goes to History); party rows are not touched.
-- p_date NULL = show everything again (opening rows are left as they are).
CREATE OR REPLACE FUNCTION public.lwb_sp_start_from(p_date date, p_pallets integer, p_sheets integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE hidden integer; removed integer;
BEGIN
  IF NOT public.lwb_sp_editor() THEN RAISE EXCEPTION 'Only Admin / Manager can change the ledger start'; END IF;
  IF p_date IS NULL THEN
    UPDATE public.lwb_sp_settings SET start_date = NULL, updated_at = now() WHERE id = 1;
    RETURN jsonb_build_object('start_date', NULL);
  END IF;
  IF coalesce(p_pallets,0) < 0 OR coalesce(p_sheets,0) < 0 THEN RAISE EXCEPTION 'Opening cannot be below 0'; END IF;
  DELETE FROM public.lwb_sp_entries
   WHERE entry_type = 'COMPANY_IN' AND ref_no = 'OPENING BALANCE' AND entry_date >= p_date;
  GET DIAGNOSTICS removed = ROW_COUNT;
  IF coalesce(p_pallets,0) + coalesce(p_sheets,0) > 0 THEN
    INSERT INTO public.lwb_sp_entries (entry_date, entry_type, party_name, pallets, sheets, ref_no, note)
    VALUES (p_date, 'COMPANY_IN', NULL, coalesce(p_pallets,0), coalesce(p_sheets,0), 'OPENING BALANCE', 'As per company statement');
  END IF;
  UPDATE public.lwb_sp_settings SET start_date = p_date, updated_at = now() WHERE id = 1;
  SELECT count(*) INTO hidden FROM public.lwb_sp_entries WHERE entry_date < p_date;
  RETURN jsonb_build_object('start_date', p_date, 'hidden', hidden, 'old_opening_replaced', removed);
END;
$function$;
REVOKE ALL ON FUNCTION public.lwb_sp_start_from(date, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sp_start_from(date, integer, integer) TO authenticated;

COMMIT;
