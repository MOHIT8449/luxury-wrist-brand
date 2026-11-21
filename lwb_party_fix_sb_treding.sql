-- LUXURY WRIST BRAND ERP — ONE-TIME DATA FIX: S B TREDING COMPANY -> S B TRADING COMPANY (GODADRA)
--
-- Runs by itself when merged to main. Runs once; safe to run again (does nothing the second time).
--
-- Mohit (21 Nov 2026): "S B TREDING COMPANY" and "S B TRADING COMPANY (GODADRA)" are the same
-- customer. Keep GODADRA as the main party and move every entry of S B TREDING COMPANY into it
-- (POs, bills, receipts, returns, opening balance, outstanding), so the ledger shows one balance.
-- Same method as lwb_party_fix_shree_dev_trading.sql, plus:
--   * S B TREDING may or may not be in Party Master (ledger names also come from POs / Tally).
--     If both are in Party Master, the Party Master "Merge" runs; otherwise only the Tally name
--     link is added. Either way future Tally bills in the old name land on GODADRA.
--   * If both parties have an opening balance for the same brand, the old one is added to
--     GODADRA's and removed (backed up first).
--   * Ledger check: GODADRA's ledger balance after = GODADRA before + S B TREDING before
--     (to the paisa), and S B TREDING has nothing left. Otherwise everything is rolled back.
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
  c_fix   constant text := 'sb-treding-into-sb-trading-godadra-2026-11-21';
  c_keep  constant text := 'S B TRADING COMPANY GODADRA';  -- lwb_party_key form
  c_drop  constant text := 'S B TREDING COMPANY';
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
  v_ob_folded int := 0;
  v_led boolean := to_regprocedure('public.lwb_party_ledger()') IS NOT NULL;
  lbk numeric := 0; lbd numeric := 0; lak numeric := 0; lad numeric := 0;
  lck bigint := 0; lcd bigint := 0; lcak bigint := 0; lcad bigint := 0;
  bk bigint; bd bigint; ak bigint; ad bigint;
  t record; ob record;
BEGIN
  IF EXISTS (SELECT 1 FROM public.lwb_party_fix_log WHERE fix = c_fix AND step = 'done') THEN
    RAISE NOTICE 'Party fix % already done', c_fix;
    RETURN;
  END IF;

  -- Party Master rows (at most one of each; the old one may not be in Party Master at all)
  SELECT count(*) INTO v_n FROM public.lwb_customer_master WHERE public.lwb_party_key(customer_name) = c_keep;
  IF v_n > 1 THEN RAISE EXCEPTION 'Party fix: % rows of S B TRADING COMPANY (GODADRA) in Party Master', v_n; END IF;
  SELECT count(*) INTO v_n FROM public.lwb_customer_master WHERE public.lwb_party_key(customer_name) = c_drop;
  IF v_n > 1 THEN RAISE EXCEPTION 'Party fix: % rows of S B TREDING COMPANY in Party Master', v_n; END IF;
  SELECT id, btrim(customer_name) INTO v_keep, v_keep_name FROM public.lwb_customer_master WHERE public.lwb_party_key(customer_name) = c_keep;
  SELECT id, btrim(customer_name) INTO v_drop, v_drop_name FROM public.lwb_customer_master WHERE public.lwb_party_key(customer_name) = c_drop;
  IF v_keep_name IS NULL THEN
    SELECT btrim(o.customer_name) INTO v_keep_name FROM public.orders o
    WHERE public.lwb_party_key(o.customer_name) = c_keep ORDER BY o.order_date DESC NULLS LAST LIMIT 1;
  END IF;
  IF v_keep_name IS NULL THEN RAISE EXCEPTION 'Party fix: S B TRADING COMPANY (GODADRA) not found'; END IF;
  IF v_drop IS NOT NULL AND v_keep IS NULL THEN
    RAISE EXCEPTION 'Party fix: S B TREDING is in Party Master but GODADRA is not. Nothing changed.';
  END IF;
  v_drop_name := coalesce(v_drop_name, 'S B TREDING COMPANY');

  -- run as an active Admin (merge / delete / ledger functions check the user); Mohit first
  SELECT p.id INTO v_admin FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) = 'admin'
  ORDER BY (coalesce(p.full_name,'') ILIKE '%mohit%') DESC, p.id LIMIT 1;
  IF v_admin IS NULL THEN RAISE EXCEPTION 'Party fix: no active Admin found'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);

  -- ledger balance (Dr - Cr, all brands, all dates) of both parties before
  IF v_led THEN
    SELECT coalesce(sum(l.debit - l.credit) FILTER (WHERE public.lwb_party_key(l.customer_name) = c_keep), 0),
           coalesce(sum(l.debit - l.credit) FILTER (WHERE public.lwb_party_key(l.customer_name) = c_drop), 0),
           count(*) FILTER (WHERE public.lwb_party_key(l.customer_name) = c_keep),
           count(*) FILTER (WHERE public.lwb_party_key(l.customer_name) = c_drop)
      INTO lbk, lbd, lck, lcd
    FROM public.lwb_party_ledger() l;
  END IF;

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
        USING c_fix, c_keep, c_drop, upper(v_keep_name), upper(v_drop_name);
    END IF;
  END LOOP;
  IF v_keep IS NOT NULL THEN
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
  END IF;

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
          'ledger_balance_keep_drop', jsonb_build_array(lbk, lbd), 'ledger_rows_keep_drop', jsonb_build_array(lck, lcd),
          'backup_rows', (SELECT count(*) FROM public.lwb_party_fix_backup WHERE fix = c_fix)));

  -- 3a. opening balance on both for the same brand: add the old one into GODADRA's
  IF to_regclass('public.lwb_party_opening_balances') IS NOT NULL THEN
    FOR ob IN SELECT d.* FROM public.lwb_party_opening_balances d
              WHERE public.lwb_party_key(d.customer_name) = c_drop LOOP
      UPDATE public.lwb_party_opening_balances k SET amount = k.amount + ob.amount
      WHERE public.lwb_party_key(k.customer_name) = c_keep
        AND coalesce(to_jsonb(k)->>'company_id', '') = coalesce(to_jsonb(ob)->>'company_id', '');
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n = 1 THEN
        DELETE FROM public.lwb_party_opening_balances WHERE id = ob.id;
        v_ob_folded := v_ob_folded + 1;
      ELSIF v_n > 1 THEN
        RAISE EXCEPTION 'Party fix: GODADRA has % opening balances for one brand. Nothing changed.', v_n;
      END IF;
    END LOOP;
  END IF;

  -- 3b. move every name / party key of the old party
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
          USING upper(v_keep_name), upper(v_drop_name);
        GET DIAGNOSTICS bk = ROW_COUNT;
        v_n := v_n + bk;
      END IF;
      IF v_n > 0 THEN v_moved := v_moved || jsonb_build_object(t.tbl || '.' || t.col, v_n); END IF;
    EXCEPTION WHEN unique_violation OR check_violation THEN
      v_skip := v_skip || (t.tbl || '.' || t.col);   -- the kept party already has its own row there
    END;
  END LOOP;

  -- 3c. Party Master merge (id links, Tally name link, missing details, old party marked merged),
  --     or only the Tally name link when the old name is not in Party Master
  IF v_drop IS NOT NULL THEN
    v_merge := public.lwb_merge_party(v_keep, v_drop);
  ELSIF to_regclass('public.lwb_tally_party_map') IS NOT NULL THEN
    INSERT INTO public.lwb_tally_party_map(tally_key, tally_name, customer_name, updated_at, updated_by)
    VALUES (c_drop, v_drop_name, v_keep_name, now(), v_admin)
    ON CONFLICT (tally_key) DO UPDATE SET customer_name = excluded.customer_name,
      updated_at = now(), updated_by = excluded.updated_by;
  END IF;

  -- 4. check: rows
  FOR t IN SELECT * FROM _pf_cols WHERE kind = 'name' LOOP
    EXECUTE format('SELECT count(*) FILTER (WHERE public.lwb_party_key(%1$I) = $1),
                           count(*) FILTER (WHERE public.lwb_party_key(%1$I) = $2) FROM public.%2$I', t.col, t.tbl)
      INTO ak, ad USING c_keep, c_drop;
    IF ak + ad > 0 THEN
      v_after := v_after || jsonb_build_object(t.tbl || '.' || t.col, jsonb_build_array(ak, ad));
    END IF;
    bk := coalesce((v_before -> (t.tbl || '.' || t.col) ->> 0)::bigint, 0);
    bd := coalesce((v_before -> (t.tbl || '.' || t.col) ->> 1)::bigint, 0);
    IF t.tbl = 'lwb_party_opening_balances' THEN bd := bd - v_ob_folded; END IF;
    -- money / order tables must move completely
    IF t.tbl IN ('orders', 'lwb_internal_bills', 'lwb_tally_payments', 'lwb_acc_entries',
                 'lwb_party_opening_balances', 'lwb_party_payments', 'lwb_party_returns',
                 'lwb_bank_statement_lines', 'lwb_payment_collections')
       AND (ad <> 0 OR ak <> bk + bd) THEN
      RAISE EXCEPTION 'Party fix check failed on %.%: before keep % + old %, after keep % + old %. Nothing changed.',
        t.tbl, t.col, bk, bd, ak, ad;
    END IF;
  END LOOP;
  IF v_drop IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_customer_master
                                        WHERE id = v_drop AND merged_into = v_keep AND is_active = false) THEN
    RAISE EXCEPTION 'Party fix: old party was not marked merged. Nothing changed.';
  END IF;

  -- 4b. check: ledger balance = sum of both, nothing left on the old name
  IF v_led THEN
    SELECT coalesce(sum(l.debit - l.credit) FILTER (WHERE public.lwb_party_key(l.customer_name) = c_keep), 0),
           coalesce(sum(l.debit - l.credit) FILTER (WHERE public.lwb_party_key(l.customer_name) = c_drop), 0),
           count(*) FILTER (WHERE public.lwb_party_key(l.customer_name) = c_keep),
           count(*) FILTER (WHERE public.lwb_party_key(l.customer_name) = c_drop)
      INTO lak, lad, lcak, lcad
    FROM public.lwb_party_ledger() l;
    IF lcad <> 0 OR abs(lak - (lbk + lbd)) > 0.01 THEN
      RAISE EXCEPTION 'Party fix ledger check failed: before % + %, after % (old name left % rows). Nothing changed.',
        lbk, lbd, lak, lcad;
    END IF;
  END IF;

  -- 5. remove the old party from Party Master
  IF v_drop IS NOT NULL THEN
    BEGIN
      PERFORM public.lwb_delete_customer(v_drop);
      v_deleted := true;
    EXCEPTION WHEN OTHERS THEN
      v_del_msg := SQLERRM;   -- stays Inactive + Merged
    END;
  END IF;

  INSERT INTO public.lwb_party_fix_log(fix, step, data)
  VALUES (c_fix, 'done', jsonb_build_object('moved', v_moved, 'kept_own', to_jsonb(v_skip), 'merge', v_merge,
          'opening_folded', v_ob_folded, 'counts_keep_drop_after', v_after,
          'ledger_balance_after', lak, 'ledger_rows_after', lcak,
          'old_party_deleted', v_deleted, 'delete_note', v_del_msg));
END
$fix$;

COMMIT;
