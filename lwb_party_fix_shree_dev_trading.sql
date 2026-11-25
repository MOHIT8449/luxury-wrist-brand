-- LUXURY WRIST BRAND ERP — ONE-TIME DATA FIX: SHREE DEV TRADING (SACHIN) -> SHREE BHERUNATH TREDING-(SACHIN)
--
-- Runs by itself when merged to main. Runs once; safe to run again (does nothing the second time).
--
-- Mohit (20 Nov 2026): "SHREE DEV TRADING (SACHIN)" and "SHREE BHERUNATH TREDING-(SACHIN)" are the
-- same shop. Bills were made under both names. Move everything of SHREE DEV TRADING (SACHIN) to
-- SHREE BHERUNATH TREDING-(SACHIN) so POs, bills, payments, ledger and outstanding sit under one
-- party, and remove SHREE DEV TRADING (SACHIN) from Party Master.
-- "SHREE DEV COLDRINK (SAYAN)" is a different party and is NOT touched (exact name match only).
--
-- Steps (one transaction; any problem = nothing is changed):
--   1. Backup: every row that carries either party (by name, party key or party id) is copied as
--      JSON into lwb_party_fix_backup, plus both Party Master rows.
--   2. Before counts per table/column are written to lwb_party_fix_log.
--   3. Every name column (customer_name / party / party_name) and party_key column of
--      SHREE DEV TRADING (SACHIN) gets SHREE BHERUNATH's name; then lwb_merge_party (the Party
--      Master "Merge") moves id links, adds the Tally name link and marks the old party merged.
--   4. Check: no PO / ERP bill / payment / ledger row is left on the old name, and the kept party
--      has exactly (its own + the old party's) rows. Otherwise everything is rolled back.
--   5. The old party is deleted from Party Master (lwb_delete_customer). If it is still linked
--      somewhere, it stays Inactive + "Merged" instead.
-- History tables (*_log, *history*, *_audit, backups) are not rewritten.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_party_fix_backup (
  id       bigserial PRIMARY KEY,
  fix      text NOT NULL,
  tbl      text NOT NULL,
  row_data jsonb NOT NULL,
  saved_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_party_fix_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_party_fix_backup FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_party_fix_log (
  id     bigserial PRIMARY KEY,
  fix    text NOT NULL,
  step   text NOT NULL,
  data   jsonb NOT NULL DEFAULT '{}'::jsonb,
  at     timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_party_fix_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_party_fix_log FROM PUBLIC, anon, authenticated;

DO $fix$
DECLARE
  c_fix   constant text := 'shree-dev-trading-into-bherunath-2026-11-20';
  c_keep  constant text := 'SHREE BHERUNATH TREDING SACHIN';  -- lwb_party_key form
  c_drop  constant text := 'SHREE DEV TRADING SACHIN';
  v_keep  uuid; v_drop uuid; v_keep_name text; v_drop_name text;
  v_admin uuid;
  v_n     bigint;
  v_before jsonb := '{}'::jsonb;
  v_after  jsonb := '{}'::jsonb;
  v_moved  jsonb := '{}'::jsonb;
  v_skip   text[] := '{}';
  v_merge  jsonb;
  v_deleted boolean := false;
  v_del_msg text;
  bk bigint; bd bigint; ak bigint; ad bigint;
  t record;
BEGIN
  IF EXISTS (SELECT 1 FROM public.lwb_party_fix_log WHERE fix = c_fix AND step = 'done') THEN
    RAISE NOTICE 'Party fix % already done', c_fix;
    RETURN;
  END IF;

  -- exactly one party of each name, nothing else
  SELECT count(*) INTO v_n FROM public.lwb_customer_master WHERE public.lwb_party_key(customer_name) = c_keep;
  IF v_n <> 1 THEN RAISE EXCEPTION 'Party fix: expected 1 SHREE BHERUNATH TREDING-(SACHIN) in Party Master, found %', v_n; END IF;
  SELECT count(*) INTO v_n FROM public.lwb_customer_master WHERE public.lwb_party_key(customer_name) = c_drop;
  IF v_n <> 1 THEN RAISE EXCEPTION 'Party fix: expected 1 SHREE DEV TRADING (SACHIN) in Party Master, found %', v_n; END IF;
  SELECT id, customer_name INTO v_keep, v_keep_name FROM public.lwb_customer_master WHERE public.lwb_party_key(customer_name) = c_keep;
  SELECT id, customer_name INTO v_drop, v_drop_name FROM public.lwb_customer_master WHERE public.lwb_party_key(customer_name) = c_drop;

  -- run as an active Admin (the merge / delete functions are Admin only); Mohit first
  SELECT p.id INTO v_admin FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) = 'admin'
  ORDER BY (coalesce(p.full_name,'') ILIKE '%mohit%') DESC, p.id LIMIT 1;
  IF v_admin IS NULL THEN RAISE EXCEPTION 'Party fix: no active Admin found'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);

  -- the tables / columns that carry a party (temp list)
  CREATE TEMP TABLE _pf_cols ON COMMIT DROP AS
  SELECT c.table_name::text AS tbl, c.column_name::text AS col,
         CASE WHEN c.column_name = 'party_key' THEN 'key' ELSE 'name' END AS kind
  FROM information_schema.columns c
  JOIN information_schema.tables tb ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
                                   AND tb.table_type = 'BASE TABLE'
  WHERE c.table_schema = 'public'
    AND c.data_type IN ('text', 'character varying')
    AND c.column_name IN ('customer_name', 'party', 'party_name', 'party_key')
    AND c.table_name NOT IN ('lwb_customer_master', 'lwb_party_merges', 'lwb_party_fix_backup', 'lwb_party_fix_log')
    AND c.table_name !~ '(_log$|_logs$|history|_audit|backup)';

  -- 1. backup
  INSERT INTO public.lwb_party_fix_backup(fix, tbl, row_data)
  SELECT c_fix, 'lwb_customer_master', to_jsonb(m) FROM public.lwb_customer_master m WHERE m.id IN (v_keep, v_drop);
  FOR t IN SELECT * FROM _pf_cols LOOP
    IF t.kind = 'name' THEN
      EXECUTE format('INSERT INTO public.lwb_party_fix_backup(fix, tbl, row_data)
                      SELECT $1, %L, to_jsonb(x) FROM public.%I x WHERE public.lwb_party_key(x.%I) IN ($2, $3)',
                     t.tbl || '.' || t.col, t.tbl, t.col)
        USING c_fix, c_keep, c_drop;
    ELSE
      EXECUTE format('INSERT INTO public.lwb_party_fix_backup(fix, tbl, row_data)
                      SELECT $1, %L, to_jsonb(x) FROM public.%I x WHERE x.%I IN ($2, $3, $4, $5)',
                     t.tbl || '.' || t.col, t.tbl, t.col)
        USING c_fix, c_keep, c_drop, upper(btrim(v_keep_name)), upper(btrim(v_drop_name));
    END IF;
  END LOOP;
  FOR t IN
    SELECT cl.relname::text AS tbl, a.attname::text AS col
    FROM pg_constraint con
    JOIN pg_class cl ON cl.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = cl.relnamespace AND n.nspname = 'public'
    JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
    WHERE con.contype = 'f' AND con.confrelid = 'public.lwb_customer_master'::regclass
      AND array_length(con.conkey, 1) = 1 AND cl.relname <> 'lwb_customer_master'
  LOOP
    EXECUTE format('INSERT INTO public.lwb_party_fix_backup(fix, tbl, row_data)
                    SELECT $1, %L, to_jsonb(x) FROM public.%I x WHERE x.%I IN ($2, $3)',
                   t.tbl || '.' || t.col, t.tbl, t.col)
      USING c_fix, v_keep, v_drop;
  END LOOP;

  -- 2. before counts (name columns)
  FOR t IN SELECT * FROM _pf_cols WHERE kind = 'name' LOOP
    EXECUTE format('SELECT count(*) FILTER (WHERE public.lwb_party_key(%1$I) = $1),
                           count(*) FILTER (WHERE public.lwb_party_key(%1$I) = $2) FROM public.%2$I', t.col, t.tbl)
      INTO bk, bd USING c_keep, c_drop;
    IF bk + bd > 0 THEN
      v_before := v_before || jsonb_build_object(t.tbl || '.' || t.col, jsonb_build_array(bk, bd));
    END IF;
  END LOOP;
  INSERT INTO public.lwb_party_fix_log(fix, step, data)
  VALUES (c_fix, 'before', jsonb_build_object('keep', v_keep_name, 'keep_id', v_keep, 'drop', v_drop_name,
          'drop_id', v_drop, 'run_as', v_admin, 'counts_keep_drop', v_before,
          'backup_rows', (SELECT count(*) FROM public.lwb_party_fix_backup WHERE fix = c_fix)));

  -- 3a. move every name / party key of the old party
  FOR t IN SELECT * FROM _pf_cols LOOP
    BEGIN
      IF t.kind = 'name' THEN
        EXECUTE format('UPDATE public.%I SET %I = $1 WHERE public.lwb_party_key(%I) = $2', t.tbl, t.col, t.col)
          USING v_keep_name, c_drop;
        GET DIAGNOSTICS v_n = ROW_COUNT;
      ELSE
        EXECUTE format('UPDATE public.%I SET %I = $1 WHERE %I = $2', t.tbl, t.col, t.col)
          USING c_keep, c_drop;
        GET DIAGNOSTICS v_n = ROW_COUNT;
        EXECUTE format('UPDATE public.%I SET %I = $1 WHERE %I = $2', t.tbl, t.col, t.col)
          USING upper(btrim(v_keep_name)), upper(btrim(v_drop_name));
        GET DIAGNOSTICS bk = ROW_COUNT;
        v_n := v_n + bk;
      END IF;
      IF v_n > 0 THEN v_moved := v_moved || jsonb_build_object(t.tbl || '.' || t.col, v_n); END IF;
    EXCEPTION WHEN unique_violation OR check_violation THEN
      v_skip := v_skip || (t.tbl || '.' || t.col);   -- the kept party already has its own row there
    END;
  END LOOP;

  -- 3b. Party Master merge: id links, Tally name link, missing details, old party marked merged
  v_merge := public.lwb_merge_party(v_keep, v_drop);

  -- 4. check
  FOR t IN SELECT * FROM _pf_cols WHERE kind = 'name' LOOP
    EXECUTE format('SELECT count(*) FILTER (WHERE public.lwb_party_key(%1$I) = $1),
                           count(*) FILTER (WHERE public.lwb_party_key(%1$I) = $2) FROM public.%2$I', t.col, t.tbl)
      INTO ak, ad USING c_keep, c_drop;
    IF ak + ad > 0 THEN
      v_after := v_after || jsonb_build_object(t.tbl || '.' || t.col, jsonb_build_array(ak, ad));
    END IF;
    bk := coalesce((v_before -> (t.tbl || '.' || t.col) ->> 0)::bigint, 0);
    bd := coalesce((v_before -> (t.tbl || '.' || t.col) ->> 1)::bigint, 0);
    -- money / order tables must move completely
    IF t.tbl IN ('orders', 'lwb_internal_bills', 'lwb_tally_payments', 'lwb_acc_entries',
                 'lwb_party_opening_balances', 'lwb_party_payments', 'lwb_party_returns',
                 'lwb_bank_statement_lines', 'lwb_payment_collections')
       AND (ad <> 0 OR ak <> bk + bd) THEN
      RAISE EXCEPTION 'Party fix check failed on %.%: before keep % + old %, after keep % + old %. Nothing changed.',
        t.tbl, t.col, bk, bd, ak, ad;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_customer_master WHERE id = v_drop AND merged_into = v_keep AND is_active = false) THEN
    RAISE EXCEPTION 'Party fix: old party was not marked merged. Nothing changed.';
  END IF;

  -- 5. remove the old party from Party Master
  BEGIN
    PERFORM public.lwb_delete_customer(v_drop);
    v_deleted := true;
  EXCEPTION WHEN OTHERS THEN
    v_del_msg := SQLERRM;   -- stays Inactive + Merged
  END;

  INSERT INTO public.lwb_party_fix_log(fix, step, data)
  VALUES (c_fix, 'done', jsonb_build_object('moved', v_moved, 'kept_own', to_jsonb(v_skip), 'merge', v_merge,
          'counts_keep_drop_after', v_after, 'old_party_deleted', v_deleted, 'delete_note', v_del_msg));
END
$fix$;

COMMIT;
