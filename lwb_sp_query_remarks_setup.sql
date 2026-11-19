-- LUXURY WRIST BRAND ERP — SHEET & PALLET: QUERY REMARKS + MAIL TO COMPANY (19 Nov 2026)
--
-- Run after lwb_sp_company_statement_setup.sql. Safe to run again.
--
-- Mohit: for each Query on the Company Match tab, write what happened (sheets short, damaged,
-- excess, our entry mistake) and mail the open queries to the company.
--   lwb_sp_stmt_remarks: one remark per match line (item_key, e.g. IN:7012785465 / OUT:0081163530),
--     kind, pallets, sheets, note, status OPEN / MAILED / CLOSED (CLOSED = no longer a query).
--   lwb_sp_remark_save(p), lwb_sp_remark_status(keys, status): Admin / Manager only.
--   lwb_sp_settings.company_email / company_cc: saved "To" / "Cc" of the mail.
-- No ledger entries are changed here.

BEGIN;

ALTER TABLE public.lwb_sp_settings ADD COLUMN IF NOT EXISTS company_email text;
ALTER TABLE public.lwb_sp_settings ADD COLUMN IF NOT EXISTS company_cc text;

CREATE TABLE IF NOT EXISTS public.lwb_sp_stmt_remarks (
  id bigserial PRIMARY KEY,
  item_key text NOT NULL UNIQUE CHECK (length(item_key) BETWEEN 3 AND 80),
  kind text NOT NULL CHECK (kind IN ('SHORT','DAMAGE','EXCESS','OUR_ERROR','OTHER')),
  pallets integer NOT NULL DEFAULT 0 CHECK (pallets >= 0),
  sheets integer NOT NULL DEFAULT 0 CHECK (sheets >= 0),
  note text CHECK (note IS NULL OR length(note) <= 500),
  status text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','MAILED','CLOSED')),
  mailed_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid DEFAULT auth.uid(),
  updated_by_name text
);

ALTER TABLE public.lwb_sp_stmt_remarks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_sp_stmt_remarks_read ON public.lwb_sp_stmt_remarks;
CREATE POLICY lwb_sp_stmt_remarks_read ON public.lwb_sp_stmt_remarks FOR SELECT TO authenticated USING (public.lwb_sp_user());
REVOKE ALL ON TABLE public.lwb_sp_stmt_remarks FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_sp_stmt_remarks TO authenticated;

-- p = {item_key, kind, pallets, sheets, note, status}; kind NULL / '' = remove the remark.
CREATE OR REPLACE FUNCTION public.lwb_sp_remark_save(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE k text; who text; r public.lwb_sp_stmt_remarks;
BEGIN
  IF NOT public.lwb_sp_editor() THEN RAISE EXCEPTION 'Only Admin / Manager can write a query remark'; END IF;
  k := btrim(coalesce(p->>'item_key',''));
  IF length(k) < 3 THEN RAISE EXCEPTION 'Query line not given'; END IF;
  IF coalesce(btrim(p->>'kind'),'') = '' THEN
    DELETE FROM public.lwb_sp_stmt_remarks WHERE item_key = k;
    RETURN jsonb_build_object('removed', true);
  END IF;
  SELECT coalesce(nullif(btrim(x.full_name),''), u.email) INTO who
    FROM auth.users u LEFT JOIN public.user_profiles x ON x.id = u.id WHERE u.id = auth.uid();
  INSERT INTO public.lwb_sp_stmt_remarks AS t (item_key, kind, pallets, sheets, note, status, updated_by_name)
  VALUES (k, upper(p->>'kind'), coalesce((p->>'pallets')::integer,0), coalesce((p->>'sheets')::integer,0),
          nullif(btrim(p->>'note'),''), coalesce(nullif(upper(p->>'status'),''),'OPEN'), who)
  ON CONFLICT (item_key) DO UPDATE SET kind = EXCLUDED.kind, pallets = EXCLUDED.pallets, sheets = EXCLUDED.sheets,
    note = EXCLUDED.note, status = EXCLUDED.status, updated_at = now(), updated_by = auth.uid(), updated_by_name = who
  RETURNING * INTO r;
  RETURN to_jsonb(r);
END;
$function$;
REVOKE ALL ON FUNCTION public.lwb_sp_remark_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sp_remark_save(jsonb) TO authenticated;

-- After the mail is sent: MAILED (mailed_at = now). CLOSED once the company has corrected it.
CREATE OR REPLACE FUNCTION public.lwb_sp_remark_status(p_keys text[], p_status text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE n integer; who text;
BEGIN
  IF NOT public.lwb_sp_editor() THEN RAISE EXCEPTION 'Only Admin / Manager can change a query'; END IF;
  IF upper(p_status) NOT IN ('OPEN','MAILED','CLOSED') THEN RAISE EXCEPTION 'Unknown status'; END IF;
  SELECT coalesce(nullif(btrim(x.full_name),''), u.email) INTO who
    FROM auth.users u LEFT JOIN public.user_profiles x ON x.id = u.id WHERE u.id = auth.uid();
  UPDATE public.lwb_sp_stmt_remarks
     SET status = upper(p_status), mailed_at = CASE WHEN upper(p_status) = 'MAILED' THEN now() ELSE mailed_at END,
         updated_at = now(), updated_by = auth.uid(), updated_by_name = who
   WHERE item_key = ANY (p_keys);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$function$;
REVOKE ALL ON FUNCTION public.lwb_sp_remark_status(text[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sp_remark_status(text[], text) TO authenticated;

COMMIT;
