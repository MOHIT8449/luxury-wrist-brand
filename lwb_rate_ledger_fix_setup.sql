-- LUXURY WRIST BRAND ERP — RATE LEDGER: ADMIN FIXES A WRONG OLD ENTRY (13 Nov 2026)
--
-- Runs by itself when merged to main (after lwb_rate_scheme_setup.sql and lwb_rate_ledger_setup.sql).
-- Safe to run again. Nothing is dropped.
--
-- Mohit asked (13 Nov 2026): sometimes a wrong amount or free bottle qty goes into the Rate List; he must be
-- able to correct it date-wise, so the ledger (and the STTS check, PO Entry rates on a day, profit) is right.
--   * lwb_rate_history_fix(entry, pack, values, valid_from, reason): Admin only. Changes the numbers of one
--     pack in one ledger entry (GR, MEPD, free bottle, OMS, QPS, ROI, landing, slab rates) and / or the entry's
--     "valid from" date. A reason is required.
--   * Every fix is kept in lwb_rate_history_fixes (old and new values, who, when, reason), never removed.
--   * lwb_rate_history.fixed_at / fix_count show on the page that an entry was corrected.
-- The live Rate List (lwb_rate_packs) is not touched: fix today's rates with a normal Save.

BEGIN;

ALTER TABLE public.lwb_rate_history ADD COLUMN IF NOT EXISTS fixed_at timestamptz;
ALTER TABLE public.lwb_rate_history ADD COLUMN IF NOT EXISTS fix_count integer NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS public.lwb_rate_history_fixes (
  id bigserial PRIMARY KEY,
  history_id bigint NOT NULL REFERENCES public.lwb_rate_history(id) ON DELETE CASCADE,
  pack_name text,
  old_row jsonb,
  new_row jsonb,
  old_valid_from date,
  new_valid_from date,
  reason text NOT NULL CHECK (btrim(reason) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);
CREATE INDEX IF NOT EXISTS lwb_rate_history_fixes_hist_idx ON public.lwb_rate_history_fixes (history_id, created_at DESC);
ALTER TABLE public.lwb_rate_history_fixes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_rate_history_fixes_read ON public.lwb_rate_history_fixes;
CREATE POLICY lwb_rate_history_fixes_read ON public.lwb_rate_history_fixes
  FOR SELECT TO authenticated USING (public.lwb_rate_editor());
REVOKE ALL ON TABLE public.lwb_rate_history_fixes FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_rate_history_fixes TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_rate_history_fix(
  p_id bigint, p_pack text, p_values jsonb, p_valid_from date, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_h public.lwb_rate_history%ROWTYPE;
  v_rows jsonb := '[]'::jsonb; v_r jsonb; v_old jsonb; v_new jsonb; v_k text; v_v jsonb;
  v_found boolean := false; v_vf date;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) = 'admin') THEN
    RAISE EXCEPTION 'Only Admin can fix an old Rate Ledger entry.';
  END IF;
  IF btrim(coalesce(p_reason, '')) = '' THEN RAISE EXCEPTION 'Write why this entry is being fixed.'; END IF;
  SELECT * INTO v_h FROM public.lwb_rate_history WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Rate Ledger entry not found.'; END IF;
  v_vf := coalesce(p_valid_from, v_h.valid_from);
  IF v_vf IS NOT NULL AND v_vf > (now() AT TIME ZONE 'Asia/Kolkata')::date + 60 THEN
    RAISE EXCEPTION 'Valid from date is too far ahead.';
  END IF;

  IF nullif(btrim(coalesce(p_pack, '')), '') IS NOT NULL THEN
    IF jsonb_typeof(coalesce(p_values, 'null'::jsonb)) <> 'object' THEN RAISE EXCEPTION 'New values are missing.'; END IF;
    FOR v_r IN SELECT * FROM jsonb_array_elements(coalesce(v_h.rows, '[]'::jsonb)) LOOP
      IF NOT v_found AND upper(btrim(v_r->>'name')) = upper(btrim(p_pack)) THEN
        v_found := true; v_old := v_r; v_new := v_r;
        FOR v_k, v_v IN SELECT * FROM jsonb_each(p_values) LOOP
          IF v_k NOT IN ('gr','mepd','fb','oms','qps','roi','land') AND v_k !~ '^s[0-9]+$' THEN
            RAISE EXCEPTION 'Unknown field %', v_k;
          END IF;
          IF jsonb_typeof(v_v) <> 'number' OR (v_v)::text::numeric < 0 THEN
            RAISE EXCEPTION 'Enter a number 0 or more for %', v_k;
          END IF;
          v_new := jsonb_set(v_new, ARRAY[v_k], v_v, true);
        END LOOP;
        v_r := v_new;
      END IF;
      v_rows := v_rows || jsonb_build_array(v_r);
    END LOOP;
    IF NOT v_found THEN RAISE EXCEPTION 'Pack % is not in this ledger entry.', p_pack; END IF;
  ELSE
    v_rows := v_h.rows;
  END IF;

  IF v_old IS NOT DISTINCT FROM v_new AND v_vf IS NOT DISTINCT FROM v_h.valid_from THEN
    RAISE EXCEPTION 'Nothing changed.';
  END IF;

  UPDATE public.lwb_rate_history SET rows = v_rows, valid_from = v_vf, fixed_at = now(), fix_count = fix_count + 1
   WHERE id = p_id;
  INSERT INTO public.lwb_rate_history_fixes(history_id, pack_name, old_row, new_row, old_valid_from, new_valid_from, reason, created_by)
  VALUES (p_id, nullif(btrim(coalesce(p_pack, '')), ''), v_old, v_new, v_h.valid_from, v_vf, btrim(p_reason), auth.uid());
  RETURN jsonb_build_object('id', p_id, 'row', v_new, 'valid_from', v_vf);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_rate_history_fix(bigint, text, jsonb, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_rate_history_fix(bigint, text, jsonb, date, text) TO authenticated;

COMMIT;
