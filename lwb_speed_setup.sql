-- LUXURY WRIST BRAND ERP — database speed fix (Mohit, 17 Nov 2026).
-- Runs by itself on merge (Supabase apply workflow). Safe to run again. Who can see or change what stays exactly the same.
-- If anything fails, the whole file is rolled back and nothing changes.
--
-- 1. Indexes for the reads every page does all day: orders by date / status / newest first,
--    the items of an order, the bell list of a user, and the vehicle of an order.
-- 2. Security rules (RLS) that ask "what is my role?" through a function like lwb_is_field_salesman()
--    or auth.uid() were asking it again for every row (5,000 orders = 5,000 checks). Each such call is
--    wrapped as (SELECT fn()), which Postgres works out once per read. Same answer, same rule, only
--    faster (the way Supabase recommends). Only functions without inputs that cannot change during
--    one read (STABLE / IMMUTABLE) are wrapped. Rules that already have it are left as they are.
--    The NOTICE lines list each rule that was changed.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Indexes (a column that does not exist on this database is skipped)
-- ---------------------------------------------------------------------------
DO $idx$
DECLARE
  r record;
  ok boolean;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('lwb_orders_order_date_idx',          'orders',               'order_date',            ARRAY['order_date']),
    ('lwb_orders_status_idx',              'orders',               'status',                ARRAY['status']),
    ('lwb_orders_created_at_idx',          'orders',               'created_at DESC',       ARRAY['created_at']),
    ('lwb_orders_created_by_idx',          'orders',               'created_by',            ARRAY['created_by']),
    ('lwb_order_items_order_id_idx',       'order_items',          'order_id',              ARRAY['order_id']),
    ('lwb_erp_notifications_user_idx',     'erp_notifications',    'user_id, created_at DESC', ARRAY['user_id','created_at']),
    ('lwb_dispatch_assignments_order_idx', 'dispatch_assignments', 'order_id',              ARRAY['order_id'])
  ) AS t(name, tbl, cols, need)
  LOOP
    SELECT count(*) = cardinality(r.need) INTO ok
      FROM information_schema.columns c
     WHERE c.table_schema = 'public' AND c.table_name = r.tbl AND c.column_name = ANY (r.need);
    IF ok THEN
      EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON public.%I (%s)', r.name, r.tbl, r.cols);
    ELSE
      RAISE NOTICE 'Skipped index % (table/column not found)', r.name;
    END IF;
  END LOOP;
END
$idx$;

-- ---------------------------------------------------------------------------
-- 2. Security rules: ask "my role" once per read, not once per row
-- ---------------------------------------------------------------------------
-- With an empty search_path every function shows with its schema (public.x(), auth.uid()).
SET LOCAL search_path = '';

DO $rls$
DECLARE
  pol record;
  fn record;
  q text;
  c text;
  pat text;
  changed int := 0;
BEGIN
  FOR pol IN
    SELECT p.polname, n.nspname AS sch, t.relname AS tbl,
           pg_get_expr(p.polqual, p.polrelid) AS qual,
           pg_get_expr(p.polwithcheck, p.polrelid) AS chk
      FROM pg_policy p
      JOIN pg_class t ON t.oid = p.polrelid
      JOIN pg_namespace n ON n.oid = t.relnamespace
     WHERE n.nspname = 'public'
  LOOP
    q := pol.qual;
    c := pol.chk;
    -- Every function without inputs, in public or auth, that gives the same answer during one read.
    FOR fn IN
      SELECT DISTINCT pn.nspname AS sch, pr.proname AS name
        FROM pg_proc pr JOIN pg_namespace pn ON pn.oid = pr.pronamespace
       WHERE pn.nspname IN ('public','auth') AND pr.pronargs = 0 AND pr.provolatile IN ('s','i')
         AND pr.prokind = 'f' AND NOT pr.proretset
    LOOP
      -- schema.fn() that is not already inside "SELECT schema.fn()"
      pat := '(?<!SELECT )\m' || fn.sch || '\.' || fn.name || '\(\)';
      IF q IS NOT NULL THEN q := regexp_replace(q, pat, '(SELECT ' || fn.sch || '.' || fn.name || '())', 'g'); END IF;
      IF c IS NOT NULL THEN c := regexp_replace(c, pat, '(SELECT ' || fn.sch || '.' || fn.name || '())', 'g'); END IF;
    END LOOP;
    IF q IS DISTINCT FROM pol.qual OR c IS DISTINCT FROM pol.chk THEN
      EXECUTE format('ALTER POLICY %I ON %I.%I', pol.polname, pol.sch, pol.tbl)
           || CASE WHEN q IS NOT NULL THEN format(' USING (%s)', q) ELSE '' END
           || CASE WHEN c IS NOT NULL THEN format(' WITH CHECK (%s)', c) ELSE '' END;
      changed := changed + 1;
      RAISE NOTICE 'Faster rule: % on %', pol.polname, pol.tbl;
    END IF;
  END LOOP;
  RAISE NOTICE 'Security rules made faster: %', changed;
END
$rls$;

COMMIT;

ANALYZE public.orders;
ANALYZE public.order_items;
ANALYZE public.erp_notifications;
