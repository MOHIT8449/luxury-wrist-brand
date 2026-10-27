-- LUXURY WRIST BRAND ERP — STAFF SEE ONLY TODAY'S DELIVERED ORDERS (INTERNAL ACCESS CONTROL)
--
-- RUN ONCE in Supabase SQL Editor (after lwb_tally_subfirm_bills_setup.sql). Safe to run again.
-- Run it again after re-running any older file that re-creates one of the list functions in step 6.
-- Mohit asked (27 Oct 2026):
--   1. Every login except Admin (Sales Head, salesman, godown, transport, driver, accounts) sees open /
--      pending orders as today. Once an order is delivered and its work is finished, it stays visible
--      until 12 midnight (India time) of that day and is hidden from them after that.
--   2. Full history stays in the database and Admin always sees it. Nothing is deleted.
--   3. Admin can show old orders again to one login for a date range and a number of days.
-- "Work finished" = delivery report DELIVERED or PARTIAL, no driver payment waiting for verification,
-- no driver return waiting for approval, approved returned goods received in the godown, and the
-- Tally invoice no. entered (when the Tally bill table exists). An order that gets new work again
-- (for example a new return) shows again until that work is finished.
-- This only controls what staff logins can read. Stock, ledgers, Cashbook and Tally data are not changed.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Switch, Admin grants and the "work finished" date of each order
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_visibility_settings (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  hide_closed boolean NOT NULL DEFAULT true,
  updated_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.lwb_visibility_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.lwb_history_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  from_date date,
  to_date date,
  valid_until timestamptz NOT NULL,
  note text CHECK (note IS NULL OR length(note) <= 300),
  granted_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  granted_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  revoked_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  CHECK (from_date IS NULL OR to_date IS NULL OR from_date <= to_date)
);
CREATE INDEX IF NOT EXISTS lwb_history_grants_user_idx ON public.lwb_history_grants(user_id, valid_until);

CREATE TABLE IF NOT EXISTS public.lwb_order_closed (
  order_id uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  closed_at timestamptz NOT NULL DEFAULT now()
);

-- Only the functions below read these tables.
ALTER TABLE public.lwb_visibility_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_history_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_order_closed ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_visibility_settings, public.lwb_history_grants, public.lwb_order_closed
  FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Who sees what
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_history_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
                 WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'admin');
$fn$;

-- true = this login sees every order (Admin, or the switch is off).
CREATE OR REPLACE FUNCTION public.lwb_sees_all_orders()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT public.lwb_history_admin()
      OR NOT coalesce((SELECT s.hide_closed FROM public.lwb_visibility_settings s WHERE s.id = 1), true);
$fn$;

-- true = order is finished before today (India time) and this login has no Admin grant covering it.
-- Does not check Admin: policies call lwb_sees_all_orders() once per query and this one per row.
CREATE OR REPLACE FUNCTION public.lwb_order_hidden(p_order_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.lwb_order_closed c
    WHERE c.order_id = p_order_id
      AND timezone('Asia/Kolkata', c.closed_at)::date < timezone('Asia/Kolkata', now())::date
      AND NOT EXISTS (
        SELECT 1 FROM public.lwb_history_grants g
        WHERE g.user_id = auth.uid() AND g.revoked_at IS NULL AND g.valid_until > now()
          AND (g.from_date IS NULL OR timezone('Asia/Kolkata', c.closed_at)::date >= g.from_date)
          AND (g.to_date IS NULL OR timezone('Asia/Kolkata', c.closed_at)::date <= g.to_date)));
$fn$;

-- Same for a driver return (its items have no order_id).
CREATE OR REPLACE FUNCTION public.lwb_return_hidden(p_return_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.lwb_driver_delivery_returns r
                 WHERE r.id = p_return_id AND public.lwb_order_hidden(r.order_id));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_order_visible_to_me(p_order_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT p_order_id IS NULL OR public.lwb_sees_all_orders() OR NOT public.lwb_order_hidden(p_order_id);
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_order_no_visible_to_me(p_order_no text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT nullif(btrim(p_order_no), '') IS NULL OR public.lwb_sees_all_orders()
      OR NOT EXISTS (SELECT 1 FROM public.orders o
                     WHERE o.order_no::text = btrim(p_order_no) AND public.lwb_order_hidden(o.id));
$fn$;

-- true = this login may read data of that India date (today, Admin, or an Admin grant for it).
CREATE OR REPLACE FUNCTION public.lwb_date_visible_to_me(p_date date)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT p_date IS NULL OR p_date >= timezone('Asia/Kolkata', now())::date OR public.lwb_sees_all_orders()
      OR EXISTS (SELECT 1 FROM public.lwb_history_grants g
                 WHERE g.user_id = auth.uid() AND g.revoked_at IS NULL AND g.valid_until > now()
                   AND (g.from_date IS NULL OR p_date >= g.from_date)
                   AND (g.to_date IS NULL OR p_date <= g.to_date));
$fn$;

REVOKE ALL ON FUNCTION public.lwb_history_admin(), public.lwb_sees_all_orders(), public.lwb_order_hidden(uuid),
  public.lwb_return_hidden(uuid), public.lwb_order_visible_to_me(uuid), public.lwb_order_no_visible_to_me(text), public.lwb_date_visible_to_me(date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_history_admin(), public.lwb_sees_all_orders(), public.lwb_order_hidden(uuid),
  public.lwb_return_hidden(uuid), public.lwb_order_visible_to_me(uuid), public.lwb_order_no_visible_to_me(text), public.lwb_date_visible_to_me(date)
  TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Keep lwb_order_closed up to date
-- ---------------------------------------------------------------------------
-- p_need_tally = false only for the one-time fill of old orders (made before Tally invoice nos. were entered).
-- A missing Tally invoice no. stops an order from closing but never reopens a closed one.
CREATE OR REPLACE FUNCTION public.lwb_refresh_order_closed(p_order_id uuid, p_need_tally boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_delivered boolean;
  v_open boolean;
  v_tally boolean := true;
BEGIN
  IF p_order_id IS NULL THEN RETURN; END IF;

  SELECT EXISTS (SELECT 1 FROM public.lwb_delivery_reports d
                 WHERE d.order_id = p_order_id AND d.delivery_status IN ('DELIVERED','PARTIAL'))
    INTO v_delivered;

  v_open := EXISTS (SELECT 1 FROM public.lwb_delivery_reports d
                    WHERE d.order_id = p_order_id AND d.payment_status = 'PENDING')
         OR EXISTS (SELECT 1 FROM public.lwb_driver_delivery_returns r
                    WHERE r.order_id = p_order_id
                      AND (r.status = 'PENDING_OFFICE' OR (r.status = 'APPROVED' AND r.goods_received_at IS NULL)));

  IF NOT v_delivered OR v_open THEN
    DELETE FROM public.lwb_order_closed WHERE order_id = p_order_id;
    RETURN;
  END IF;

  IF p_need_tally AND to_regclass('public.lwb_tally_invoices') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = $1)'
      INTO v_tally USING p_order_id;
  END IF;
  IF v_tally THEN
    INSERT INTO public.lwb_order_closed (order_id, closed_at) VALUES (p_order_id, now())
    ON CONFLICT (order_id) DO NOTHING;
  END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_refresh_order_closed(uuid, boolean) FROM PUBLIC, anon, authenticated;

-- Never blocks the save that fired it.
CREATE OR REPLACE FUNCTION public.lwb_order_closed_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  BEGIN
    IF TG_OP <> 'INSERT' THEN PERFORM public.lwb_refresh_order_closed(OLD.order_id); END IF;
    IF TG_OP <> 'DELETE' AND (TG_OP = 'INSERT' OR NEW.order_id IS DISTINCT FROM OLD.order_id) THEN
      PERFORM public.lwb_refresh_order_closed(NEW.order_id);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'lwb_order_closed_trigger: %', SQLERRM;
  END;
  RETURN NULL;
END;
$fn$;

DO $trg$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['lwb_delivery_reports','lwb_driver_delivery_returns','lwb_tally_invoices'] LOOP
    IF to_regclass('public.' || t) IS NOT NULL THEN
      EXECUTE format('DROP TRIGGER IF EXISTS trg_lwb_order_closed ON public.%I', t);
      EXECUTE format('CREATE TRIGGER trg_lwb_order_closed AFTER INSERT OR UPDATE OR DELETE ON public.%I
                      FOR EACH ROW EXECUTE FUNCTION public.lwb_order_closed_trigger()', t);
    END IF;
  END LOOP;
END
$trg$;

-- One-time fill: orders already delivered with finished work are closed on their delivery day,
-- so they are hidden from staff from tomorrow (today's deliveries stay until midnight).
INSERT INTO public.lwb_order_closed (order_id, closed_at)
SELECT d.order_id, max(d.reported_at)
FROM public.lwb_delivery_reports d
WHERE d.delivery_status IN ('DELIVERED','PARTIAL')
GROUP BY d.order_id
ON CONFLICT (order_id) DO NOTHING;
DO $fill$
DECLARE r record;
BEGIN
  FOR r IN SELECT order_id FROM public.lwb_order_closed LOOP
    PERFORM public.lwb_refresh_order_closed(r.order_id, false);
  END LOOP;
END
$fill$;

-- ---------------------------------------------------------------------------
-- 4. Admin: switch, grants, list
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_admin_visibility()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_history_admin() THEN RAISE EXCEPTION 'Only an active Admin can open this.'; END IF;
  RETURN jsonb_build_object(
    'hide_closed', coalesce((SELECT s.hide_closed FROM public.lwb_visibility_settings s WHERE s.id = 1), true),
    'hidden_orders', (SELECT count(*) FROM public.lwb_order_closed c
                      WHERE timezone('Asia/Kolkata', c.closed_at)::date < timezone('Asia/Kolkata', now())::date),
    'closing_today', (SELECT count(*) FROM public.lwb_order_closed c
                      WHERE timezone('Asia/Kolkata', c.closed_at)::date = timezone('Asia/Kolkata', now())::date),
    'grants', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', g.id, 'user_id', g.user_id,
               'user_name', coalesce(nullif(btrim(p.full_name),''), p.mobile, 'User'),
               'role', p.role, 'from_date', g.from_date, 'to_date', g.to_date,
               'valid_until', g.valid_until, 'note', g.note, 'granted_at', g.granted_at,
               'granted_by_name', gp.full_name, 'revoked_at', g.revoked_at,
               'active', g.revoked_at IS NULL AND g.valid_until > now())
             ORDER BY (g.revoked_at IS NULL AND g.valid_until > now()) DESC, g.granted_at DESC)
      FROM (SELECT * FROM public.lwb_history_grants ORDER BY granted_at DESC LIMIT 100) g
      LEFT JOIN public.user_profiles p ON p.id = g.user_id
      LEFT JOIN public.user_profiles gp ON gp.id = g.granted_by), '[]'::jsonb));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_admin_set_hide_closed(p_on boolean)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_history_admin() THEN RAISE EXCEPTION 'Only an active Admin can change this.'; END IF;
  UPDATE public.lwb_visibility_settings
     SET hide_closed = coalesce(p_on, true), updated_by = auth.uid(), updated_at = now()
   WHERE id = 1;
  RETURN 'SAVED';
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_admin_grant_history(
  p_user_id uuid, p_from date, p_to date, p_days int, p_note text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id uuid;
BEGIN
  IF NOT public.lwb_history_admin() THEN RAISE EXCEPTION 'Only an active Admin can give access.'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user_id AND p.active = true) THEN
    RAISE EXCEPTION 'Choose an active login.';
  END IF;
  IF p_days IS NULL OR p_days < 1 OR p_days > 90 THEN RAISE EXCEPTION 'Days must be 1 to 90.'; END IF;
  IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to THEN RAISE EXCEPTION 'From date is after To date.'; END IF;
  INSERT INTO public.lwb_history_grants (user_id, from_date, to_date, valid_until, note, granted_by)
  VALUES (p_user_id, p_from, p_to, now() + make_interval(days => p_days),
          nullif(btrim(coalesce(p_note,'')),''), auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_admin_revoke_history(p_grant_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_history_admin() THEN RAISE EXCEPTION 'Only an active Admin can stop access.'; END IF;
  UPDATE public.lwb_history_grants SET revoked_at = now(), revoked_by = auth.uid()
   WHERE id = p_grant_id AND revoked_at IS NULL;
  RETURN 'STOPPED';
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_admin_visibility(), public.lwb_admin_set_hide_closed(boolean),
  public.lwb_admin_grant_history(uuid,date,date,int,text), public.lwb_admin_revoke_history(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_admin_visibility(), public.lwb_admin_set_hide_closed(boolean),
  public.lwb_admin_grant_history(uuid,date,date,int,text), public.lwb_admin_revoke_history(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5. Table reads: hide finished orders of earlier days (RESTRICTIVE, SELECT only)
--    A table without RLS gets RLS plus an "all signed-in users" policy first, like lwb_sales_team_setup.sql.
-- ---------------------------------------------------------------------------
DO $pol$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['orders','order_items','dispatch_assignments','lwb_delivery_reports',
                           'lwb_driver_delivery_returns','lwb_internal_bills','tax_invoices','sales_returns',
                           'lwb_tally_invoices','lwb_tally_notes','erp_notifications','lwb_driver_delivery_return_items'] LOOP
    CONTINUE WHEN to_regclass('public.' || t) IS NULL;
    CONTINUE WHEN t <> 'orders' AND t <> 'lwb_driver_delivery_return_items' AND NOT EXISTS (
      SELECT 1 FROM information_schema.columns c
      WHERE c.table_schema = 'public' AND c.table_name = t AND c.column_name = 'order_id');
    CONTINUE WHEN t = 'lwb_driver_delivery_return_items' AND NOT EXISTS (
      SELECT 1 FROM information_schema.columns c
      WHERE c.table_schema = 'public' AND c.table_name = t AND c.column_name = 'return_id');

    IF NOT (SELECT c.relrowsecurity FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relname = t) THEN
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
      EXECUTE format('DROP POLICY IF EXISTS lwb_signed_in_all ON public.%I', t);
      EXECUTE format('CREATE POLICY lwb_signed_in_all ON public.%I FOR ALL TO authenticated USING (true) WITH CHECK (true)', t);
    END IF;

    EXECUTE format('DROP POLICY IF EXISTS lwb_hide_closed_orders ON public.%I', t);
    IF t = 'orders' THEN
      EXECUTE 'CREATE POLICY lwb_hide_closed_orders ON public.orders AS RESTRICTIVE FOR SELECT TO authenticated
               USING ((SELECT public.lwb_sees_all_orders()) OR NOT public.lwb_order_hidden(id))';
    ELSIF t = 'lwb_driver_delivery_return_items' THEN
      EXECUTE 'CREATE POLICY lwb_hide_closed_orders ON public.lwb_driver_delivery_return_items AS RESTRICTIVE
               FOR SELECT TO authenticated
               USING ((SELECT public.lwb_sees_all_orders()) OR NOT public.lwb_return_hidden(return_id))';
    ELSE
      EXECUTE format('CREATE POLICY lwb_hide_closed_orders ON public.%I AS RESTRICTIVE FOR SELECT TO authenticated
                      USING ((SELECT public.lwb_sees_all_orders()) OR order_id IS NULL OR NOT public.lwb_order_hidden(order_id))', t);
    END IF;
  END LOOP;
END
$pol$;

-- ---------------------------------------------------------------------------
-- 6. List functions that read orders with owner rights (they skip table rules):
--    the original is kept as <name>__full (not callable by logins) and <name> filters its rows.
--    Cashbook functions are not changed (Cashbook is Admin's private book).
-- ---------------------------------------------------------------------------
DO $wrap$
DECLARE
  w record;
  v_oid oid;
  v_full oid;
  v_args text;
  v_ident text;
  v_result text;
  v_call text;
  v_n int;
  v_auth boolean;
  v_body text;
  v_vol text;
BEGIN
  FOR w IN SELECT * FROM (VALUES
      -- name, identity args, kind, key
      ('lwb_my_orders', 'integer', 'jsonb_array', 'id'),
      ('lwb_office_list_driver_collections', 'text', 'jsonb_array', 'order_id'),
      ('lwb_office_list_driver_returns', 'text', 'jsonb_array', 'order_id'),
      ('lwb_driver_my_delivery_orders', '', 'setof_jsonb', 'order_id'),
      ('lwb_tally_bill_rows', 'integer', 'table', 'order_id'),
      ('lwb_tally_check_orders', 'date, date', 'table', 'order_id'),
      ('lwb_party_bills', '', 'table', 'order_id'),
      ('lwb_party_ledger', '', 'table_order_no', 'order_no'),
      ('lwb_daily_summary', 'date', 'date_arg', '')
    ) AS x(fname, fargs, kind, fkey)
  LOOP
    v_oid := to_regprocedure(format('public.%I(%s)', w.fname, w.fargs));
    CONTINUE WHEN v_oid IS NULL;
    v_full := to_regprocedure(format('public.%I(%s)', w.fname || '__full', w.fargs));

    -- Already our wrapper: keep the saved original. Otherwise (first run, or an older file re-created
    -- the function) the current definition becomes the original.
    IF v_full IS NOT NULL AND position('__full' IN (SELECT prosrc FROM pg_proc WHERE oid = v_oid)) > 0 THEN
      NULL;
    ELSE
      IF v_full IS NOT NULL THEN
        EXECUTE format('DROP FUNCTION public.%I(%s)', w.fname || '__full', w.fargs);
      END IF;
      v_auth := has_function_privilege('authenticated', v_oid, 'EXECUTE');
      EXECUTE format('ALTER FUNCTION public.%I(%s) RENAME TO %I', w.fname, w.fargs, w.fname || '__full');
      v_full := to_regprocedure(format('public.%I(%s)', w.fname || '__full', w.fargs));
      EXECUTE format('COMMENT ON FUNCTION public.%I(%s) IS %L', w.fname || '__full', w.fargs,
                     'lwb_wrap_auth=' || v_auth::text);
    END IF;

    v_auth := coalesce(obj_description(v_full, 'pg_proc'), '') LIKE '%lwb_wrap_auth=true%';
    v_args := pg_get_function_arguments(v_full);
    v_result := pg_get_function_result(v_full);
    SELECT pronargs, CASE provolatile WHEN 'v' THEN 'VOLATILE' ELSE 'STABLE' END
      INTO v_n, v_vol FROM pg_proc WHERE oid = v_full;
    SELECT format('public.%I(%s)', w.fname || '__full',
                  coalesce(string_agg('$' || i, ', ' ORDER BY i), ''))
      INTO v_call FROM generate_series(1, v_n) i;

    v_body := CASE w.kind
      WHEN 'jsonb_array' THEN format(
        'SELECT CASE WHEN jsonb_typeof(a) = %L THEN coalesce((SELECT jsonb_agg(e ORDER BY n)
           FROM jsonb_array_elements(a) WITH ORDINALITY t(e, n)
           WHERE public.lwb_order_visible_to_me(nullif(e->>%L, %L)::uuid)), %L::jsonb) ELSE a END
         FROM (SELECT %s AS a) s', 'array', w.fkey, '', '[]', v_call)
      WHEN 'setof_jsonb' THEN format(
        'SELECT e FROM %s e WHERE public.lwb_order_visible_to_me(nullif(e->>%L, %L)::uuid)', v_call, w.fkey, '')
      WHEN 'table' THEN format(
        'SELECT r.* FROM %s r WHERE public.lwb_order_visible_to_me(r.%I)', v_call, w.fkey)
      WHEN 'table_order_no' THEN format(
        'SELECT r.* FROM %s r WHERE public.lwb_order_no_visible_to_me(r.%I::text)', v_call, w.fkey)
      WHEN 'date_arg' THEN format(
        'BEGIN
           IF NOT public.lwb_date_visible_to_me($1) THEN
             RAISE EXCEPTION %L;
           END IF;
           RETURN %s;
         END;', 'Old days are visible to Admin only. Ask Admin for access.', v_call)
    END;

    EXECUTE format('CREATE OR REPLACE FUNCTION public.%I(%s) RETURNS %s
                    LANGUAGE %s %s SECURITY DEFINER SET search_path = %L AS %L',
                   w.fname, v_args, v_result, CASE WHEN w.kind = 'date_arg' THEN 'plpgsql' ELSE 'sql' END,
                   v_vol, '', v_body);
    EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM PUBLIC, anon, authenticated', w.fname || '__full', w.fargs);
    EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM PUBLIC, anon', w.fname, w.fargs);
    IF v_auth THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO authenticated', w.fname, w.fargs);
    ELSE
      EXECUTE format('REVOKE ALL ON FUNCTION public.%I(%s) FROM authenticated', w.fname, w.fargs);
    END IF;
  END LOOP;
END
$wrap$;

COMMIT;

-- Check: 6 rows, all true.
SELECT 'settings' AS item, to_regclass('public.lwb_visibility_settings') IS NOT NULL AS ok
UNION ALL SELECT 'grants', to_regclass('public.lwb_history_grants') IS NOT NULL
UNION ALL SELECT 'closed_orders', to_regclass('public.lwb_order_closed') IS NOT NULL
UNION ALL SELECT 'orders_policy', EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                                          AND tablename = 'orders' AND policyname = 'lwb_hide_closed_orders')
UNION ALL SELECT 'my_orders_wrapped', to_regprocedure('public.lwb_my_orders__full(integer)') IS NOT NULL
UNION ALL SELECT 'admin_screen', to_regprocedure('public.lwb_admin_visibility()') IS NOT NULL;
