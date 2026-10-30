-- LUXURY WRIST BRAND ERP — MERGE DUPLICATE PARTIES (CUSTOMER / PARTY MASTER)
--
-- Runs by itself when merged to main. Safe to run again.
-- Nothing is dropped or deleted.
--
-- Mohit asked (30 Oct 2026): the Party Master has duplicate parties from the
-- first import. Party Master now suggests likely duplicates; Admin picks the
-- party to keep and merges the other one into it:
--   1. Every record that carries the duplicate's name (POs, ERP bills, party
--      payments, opening balance, call list, complaints, sheet & pallet,
--      accounts entries, Tally name links) gets the kept party's name.
--      Records linked by party id (salesman, call list, group party links)
--      move to the kept party where the kept party has none of its own.
--   2. A Tally name link is added (duplicate name -> kept party), so Tally
--      bills still made in the old name land on the kept party's ledger.
--   3. Details the kept party is missing (mobile, address, city, pincode,
--      contact, PAN, GSTIN) are copied from the duplicate.
--   4. The duplicate is NOT deleted: it is set Inactive and marked
--      "merged into" the kept party. Every merge is written to lwb_party_merges.
--
-- lwb_party_usage(ids): number of POs and the last PO date of each party,
-- so Party Master can suggest which one to keep.

BEGIN;

ALTER TABLE public.lwb_customer_master
  ADD COLUMN IF NOT EXISTS merged_into uuid REFERENCES public.lwb_customer_master(id),
  ADD COLUMN IF NOT EXISTS merged_at timestamptz;

CREATE TABLE IF NOT EXISTS public.lwb_party_merges (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  keep_id    uuid NOT NULL,
  keep_name  text NOT NULL,
  drop_id    uuid NOT NULL,
  drop_code  text,
  drop_name  text NOT NULL,
  moved      jsonb NOT NULL DEFAULT '{}'::jsonb,
  merged_by  uuid,
  merged_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_party_merges ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_party_merges FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_party_merge_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND active = true AND lower(btrim(role)) = 'admin');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_merge_admin() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. POs per party (by name), for the duplicate suggestions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_usage(p_ids uuid[])
RETURNS TABLE (customer_id uuid, orders bigint, last_order date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
#variable_conflict use_column
BEGIN
  IF NOT public.lwb_party_merge_admin() THEN
    RAISE EXCEPTION 'Only an active Admin can check duplicate parties';
  END IF;
  RETURN QUERY
    SELECT m.id, count(o.id), max(o.order_date)::date
    FROM public.lwb_customer_master m
    LEFT JOIN public.orders o
      ON regexp_replace(upper(btrim(o.customer_name)), '\s+', ' ', 'g')
       = regexp_replace(upper(btrim(m.customer_name)), '\s+', ' ', 'g')
    WHERE m.id = ANY(coalesce(p_ids, '{}'))
    GROUP BY m.id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_usage(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_usage(uuid[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Merge one duplicate party into the party to keep
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_merge_party(p_keep uuid, p_drop uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  k public.lwb_customer_master%ROWTYPE;
  d public.lwb_customer_master%ROWTYPE;
  v_drop_key text;
  v_n bigint;
  v_moved jsonb := '{}'::jsonb;
  v_skip text[] := '{}';
  t record;
  fk record;
BEGIN
  IF NOT public.lwb_party_merge_admin() THEN
    RAISE EXCEPTION 'Only an active Admin can merge parties';
  END IF;
  IF p_keep IS NULL OR p_drop IS NULL OR p_keep = p_drop THEN
    RAISE EXCEPTION 'Choose two different parties';
  END IF;

  -- lock both rows (same order every time, so two merges never wait on each other)
  PERFORM 1 FROM public.lwb_customer_master WHERE id IN (p_keep, p_drop) ORDER BY id FOR UPDATE;
  SELECT * INTO k FROM public.lwb_customer_master WHERE id = p_keep;
  SELECT * INTO d FROM public.lwb_customer_master WHERE id = p_drop;
  IF k.id IS NULL OR d.id IS NULL THEN RAISE EXCEPTION 'Party not found. Click Refresh.'; END IF;
  IF k.merged_into IS NOT NULL THEN
    RAISE EXCEPTION 'Party % is already merged into another party. Keep that party instead.', k.customer_name;
  END IF;
  IF d.merged_into IS NOT NULL THEN
    RAISE EXCEPTION 'Party % is already merged.', d.customer_name;
  END IF;

  v_drop_key := regexp_replace(upper(btrim(d.customer_name)), '\s+', ' ', 'g');

  -- opening balance: only one per party name (unique index)
  IF to_regclass('public.lwb_party_opening_balances') IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.lwb_party_opening_balances
                 WHERE regexp_replace(upper(btrim(customer_name)), '\s+', ' ', 'g') = v_drop_key)
     AND EXISTS (SELECT 1 FROM public.lwb_party_opening_balances
                 WHERE upper(btrim(customer_name)) = upper(btrim(k.customer_name))) THEN
    RAISE EXCEPTION 'Both parties have an Opening Balance. Keep the opening balance on one party only (Party Ledger), then merge.';
  END IF;

  -- a. records that carry the party name
  FOR t IN SELECT * FROM (VALUES
      ('orders','customer_name'), ('lwb_internal_bills','customer_name'),
      ('lwb_tally_payments','party'), ('lwb_party_opening_balances','customer_name'),
      ('lwb_party_calls','customer_name'), ('lwb_complaints','party_name'),
      ('lwb_sp_entries','party_name'), ('lwb_acc_entries','party'),
      ('lwb_tally_party_map','customer_name')) AS x(tbl, col)
  LOOP
    CONTINUE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns c
      WHERE c.table_schema = 'public' AND c.table_name = t.tbl AND c.column_name = t.col);
    BEGIN
      EXECUTE format('UPDATE public.%I SET %I = $1 WHERE regexp_replace(upper(btrim(%I)), ''\s+'', '' '', ''g'') = $2',
                     t.tbl, t.col, t.col)
        USING k.customer_name, v_drop_key;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN v_moved := v_moved || jsonb_build_object(t.tbl, v_n); END IF;
    EXCEPTION WHEN unique_violation OR check_violation THEN
      v_skip := v_skip || t.tbl;
    END;
  END LOOP;

  -- company-wise credit days (keyed by upper party name); the kept party's own rows win
  IF to_regclass('public.lwb_party_company_credit') IS NOT NULL THEN
    UPDATE public.lwb_party_company_credit c SET party_key = upper(btrim(k.customer_name))
    WHERE c.party_key = upper(btrim(d.customer_name))
      AND NOT EXISTS (SELECT 1 FROM public.lwb_party_company_credit x
                      WHERE x.party_key = upper(btrim(k.customer_name)) AND x.company_id = c.company_id);
  END IF;

  -- b. records linked by party id (salesman, call list, group party links ...)
  FOR fk IN
    SELECT cl.relname AS tbl, a.attname AS col
    FROM pg_constraint con
    JOIN pg_class cl ON cl.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = cl.relnamespace AND n.nspname = 'public'
    JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
    WHERE con.contype = 'f' AND con.confrelid = 'public.lwb_customer_master'::regclass
      AND array_length(con.conkey, 1) = 1
      AND cl.relname NOT IN ('lwb_customer_master')
  LOOP
    BEGIN
      EXECUTE format('UPDATE public.%I SET %I = $1 WHERE %I = $2', fk.tbl, fk.col, fk.col)
        USING p_keep, p_drop;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN v_moved := v_moved || jsonb_build_object(fk.tbl || '.' || fk.col, v_n); END IF;
    EXCEPTION WHEN unique_violation OR check_violation THEN
      -- the kept party already has its own row here (e.g. its own salesman): keep that one
      v_skip := v_skip || (fk.tbl || '.' || fk.col);
    END;
  END LOOP;

  -- c. Tally name link: bills still made in the old name go to the kept party
  IF to_regclass('public.lwb_tally_party_map') IS NOT NULL
     AND to_regprocedure('public.lwb_party_key(text)') IS NOT NULL
     AND public.lwb_party_key(d.customer_name) <> public.lwb_party_key(k.customer_name) THEN
    INSERT INTO public.lwb_tally_party_map(tally_key, tally_name, customer_name, updated_at, updated_by)
    VALUES (public.lwb_party_key(d.customer_name), btrim(d.customer_name), k.customer_name, now(), auth.uid())
    ON CONFLICT (tally_key) DO UPDATE SET customer_name = excluded.customer_name,
      updated_at = now(), updated_by = auth.uid();
  END IF;

  -- d. fill the kept party's missing details; set the duplicate Inactive
  UPDATE public.lwb_customer_master SET
    pan = CASE WHEN nullif(btrim(k.pan),'') IS NULL THEN NULL ELSE pan END,
    gstin = CASE WHEN nullif(btrim(k.gstin),'') IS NULL THEN NULL ELSE gstin END,
    gst_registration_status = CASE WHEN nullif(btrim(k.gstin),'') IS NULL THEN 'UNREGISTERED' ELSE gst_registration_status END,
    is_active = false, merged_into = p_keep, merged_at = now()
  WHERE id = p_drop;
  UPDATE public.lwb_customer_master SET
    mobile          = coalesce(nullif(btrim(k.mobile),''), d.mobile),
    billing_address = coalesce(nullif(btrim(k.billing_address),''), d.billing_address),
    city            = coalesce(nullif(btrim(k.city),''), d.city),
    pincode         = coalesce(nullif(btrim(k.pincode),''), d.pincode),
    contact_person  = coalesce(nullif(btrim(k.contact_person),''), d.contact_person),
    pan             = coalesce(nullif(btrim(k.pan),''), d.pan),
    gstin           = coalesce(nullif(btrim(k.gstin),''), d.gstin),
    gst_registration_status = CASE WHEN nullif(btrim(k.gstin),'') IS NULL AND nullif(btrim(d.gstin),'') IS NOT NULL
                                   THEN 'REGISTERED' ELSE k.gst_registration_status END
  WHERE id = p_keep;

  INSERT INTO public.lwb_party_merges(keep_id, keep_name, drop_id, drop_code, drop_name, moved, merged_by)
  VALUES (p_keep, k.customer_name, p_drop, d.customer_code, d.customer_name,
          v_moved || jsonb_build_object('kept_own', to_jsonb(v_skip)), auth.uid());

  RETURN jsonb_build_object('kept', k.customer_name, 'merged', d.customer_name, 'moved', v_moved, 'kept_own', to_jsonb(v_skip));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_merge_party(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_merge_party(uuid, uuid) TO authenticated;

COMMIT;
