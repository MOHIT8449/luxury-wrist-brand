-- LUXURY WRIST BRAND ERP — ORDER HISTORY DAYS: HOW LONG A DELIVERED ORDER STAYS IN EACH ROLE'S LISTS
--
-- Runs by itself when merged to main. Safe to run again. Adds one table and four functions; nothing is
-- changed or deleted in other tables, and no order is ever deleted.
--
-- Mohit asked (13 Nov 2026): Admin sets, per role, for how many days after delivery an order (and its
-- history) is still shown to that role: Salesman, Sales Head, Driver, Accounts and the others.
--   * lwb_order_visibility: one row per role; days = number of days after delivery.
--     No row / days NULL = no limit (shown as before). 0 = hidden as soon as it is delivered.
--   * Delivered time = driver delivery report (DELIVERED / PARTIAL) or Admin "Delivered" mark, the same
--     rule as lwb_po_delivered_orders (lwb_admin_mark_load_deliver_setup.sql). Not delivered = always shown.
--   * lwb_order_visibility_list() / lwb_order_visibility_save(rows): Admin only (Settings > Order History Days).
--   * lwb_order_visibility_mine(): the caller's own limit (NULL for Admin = everything).
--   * lwb_order_hidden_ids(order ids): of these orders, the ones the caller should no longer see.
--     Pages (erp-order-days.js) drop these from their order lists. Admin is never limited.
--   * Driver: his delivery list kept delivered orders only 12 hours. Now Admin's Driver days when set
--     (empty = 12 hours as before): lwb_driver_my_delivery_orders + policy lwb_delivery_report_driver_12h.
-- Ledgers, outstanding, stock and reports are not touched: only the order lists of the role hide old POs.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_order_visibility (
  role        text PRIMARY KEY CHECK (role IN ('manager','sales','driver','accounts','warehouse','transport')),
  days        integer CHECK (days IS NULL OR days BETWEEN 0 AND 3650),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid
);
ALTER TABLE public.lwb_order_visibility ENABLE ROW LEVEL SECURITY;  -- read / write through the functions only
REVOKE ALL ON public.lwb_order_visibility FROM PUBLIC, anon, authenticated;

-- The caller's role as stored here ('salesman' is the same as 'sales'); NULL when not an active login.
CREATE OR REPLACE FUNCTION public.lwb_order_visibility_role()
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE WHEN r = 'salesman' THEN 'sales' ELSE r END
  FROM (SELECT lower(btrim(p.role)) AS r FROM public.user_profiles p
        WHERE p.id = auth.uid() AND p.active = true) x;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_visibility_role() FROM PUBLIC, anon;

-- Admin: every role with its days (NULL = no limit), who changed it last and when.
CREATE OR REPLACE FUNCTION public.lwb_order_visibility_list()
RETURNS TABLE(role text, days integer, updated_at timestamptz, updated_by_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.lwb_order_visibility_role() IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Only Admin can see the order history days.';
  END IF;
  RETURN QUERY
    SELECT r.k, v.days, v.updated_at, p.full_name
    FROM unnest(ARRAY['sales','manager','driver','accounts','warehouse','transport']) WITH ORDINALITY AS r(k, n)
    LEFT JOIN public.lwb_order_visibility v ON v.role = r.k
    LEFT JOIN public.user_profiles p ON p.id = v.updated_by
    ORDER BY r.n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_visibility_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_visibility_list() TO authenticated;

-- Admin: save. p_rows = [{"role":"sales","days":30}, {"role":"driver","days":null}, ...]
CREATE OR REPLACE FUNCTION public.lwb_order_visibility_save(p_rows jsonb)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  e jsonb; v_role text; v_txt text; v_days integer; n integer := 0;
BEGIN
  IF public.lwb_order_visibility_role() IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Only Admin can change the order history days.';
  END IF;
  IF jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Nothing to save.'; END IF;
  FOR e IN SELECT x FROM jsonb_array_elements(p_rows) AS t(x) LOOP
    v_role := lower(btrim(coalesce(e->>'role','')));
    IF v_role = 'salesman' THEN v_role := 'sales'; END IF;
    IF v_role NOT IN ('manager','sales','driver','accounts','warehouse','transport') THEN
      RAISE EXCEPTION 'Unknown role %.', coalesce(nullif(v_role,''),'-');
    END IF;
    v_txt := nullif(btrim(coalesce(e->>'days','')),'');
    IF v_txt IS NOT NULL AND v_txt !~ '^\d{1,4}$' THEN
      RAISE EXCEPTION 'Enter whole days (0 to 3650) for %, or leave it empty for no limit.', v_role;
    END IF;
    v_days := v_txt::integer;
    IF v_days > 3650 THEN RAISE EXCEPTION 'At most 3650 days for %.', v_role; END IF;
    INSERT INTO public.lwb_order_visibility(role, days, updated_at, updated_by)
    VALUES (v_role, v_days, now(), auth.uid())
    ON CONFLICT (role) DO UPDATE SET days = excluded.days, updated_at = now(), updated_by = auth.uid()
      WHERE public.lwb_order_visibility.days IS DISTINCT FROM excluded.days;
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_visibility_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_visibility_save(jsonb) TO authenticated;

-- The caller's own limit in days; NULL = no limit (Admin, or not set for the role).
CREATE OR REPLACE FUNCTION public.lwb_order_visibility_mine()
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT v.days FROM public.lwb_order_visibility v WHERE v.role = public.lwb_order_visibility_role();
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_visibility_mine() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_visibility_mine() TO authenticated;

-- Of p_ids, the orders delivered more than <my days> ago (empty when there is no limit). Max 2000 ids.
CREATE OR REPLACE FUNCTION public.lwb_order_hidden_ids(p_ids uuid[])
RETURNS uuid[]
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_days integer := public.lwb_order_visibility_mine();
  v_ids uuid[] := p_ids[1:2000];
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login required.'; END IF;
  IF v_days IS NULL OR v_ids IS NULL OR cardinality(v_ids) = 0 THEN RETURN '{}'::uuid[]; END IF;
  RETURN coalesce((
    SELECT array_agg(x.order_id) FROM (
      SELECT y.order_id, max(y.at) AS at FROM (
        SELECT d.order_id, d.reported_at AS at
        FROM public.lwb_delivery_reports d
        WHERE d.order_id = ANY(v_ids) AND d.delivery_status IN ('DELIVERED','PARTIAL')
        UNION ALL
        SELECT m.order_id, CASE WHEN m.mark_date = (m.marked_at AT TIME ZONE 'Asia/Kolkata')::date THEN m.marked_at
                                ELSE (m.mark_date + time '12:00') AT TIME ZONE 'Asia/Kolkata' END
        FROM public.lwb_admin_order_marks m
        WHERE m.order_id = ANY(v_ids) AND m.kind = 'DELIVERED') y
      GROUP BY y.order_id) x
    WHERE x.at < now() - make_interval(days => v_days)), '{}'::uuid[]);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_hidden_ids(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_hidden_ids(uuid[]) TO authenticated;


-- ---------------------------------------------------------------------------
-- Driver: delivered orders stayed only 12 hours after the report (lwb_loading_workflow_setup.sql, part 4).
-- Now: Admin's Driver days when set, otherwise 12 hours as before. Same function and policy names, so
-- these replace the ones of lwb_loading_workflow_setup.sql (keep them the same if that file is edited).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_driver_keep()
RETURNS interval
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce((SELECT make_interval(days => v.days) FROM public.lwb_order_visibility v
                   WHERE v.role = 'driver' AND v.days IS NOT NULL), interval '12 hours');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_driver_keep() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_driver_keep() TO authenticated;

DO $do$
BEGIN
  IF to_regprocedure('public.lwb_driver_list_delivery_orders()') IS NULL THEN
    RAISE NOTICE 'lwb_driver_list_delivery_orders() missing: driver list not changed';
    RETURN;
  END IF;
  EXECUTE $sql$
CREATE OR REPLACE FUNCTION public.lwb_driver_my_delivery_orders()
RETURNS SETOF jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_role text; v_keep interval := public.lwb_driver_keep();
BEGIN
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
  RETURN QUERY
    SELECT x FROM public.lwb_driver_list_delivery_orders() x
    WHERE v_role IS DISTINCT FROM 'driver'
       OR x->'report' IS NULL OR jsonb_typeof(x->'report') = 'null'
       OR (x->'report'->>'reported_at')::timestamptz > now() - v_keep;
END;
$fn$;
  $sql$;
  REVOKE ALL ON FUNCTION public.lwb_driver_my_delivery_orders() FROM PUBLIC, anon;
  GRANT EXECUTE ON FUNCTION public.lwb_driver_my_delivery_orders() TO authenticated;
END;
$do$;

DO $do$
BEGIN
  IF to_regclass('public.lwb_delivery_reports') IS NULL THEN RETURN; END IF;
  DROP POLICY IF EXISTS lwb_delivery_report_driver_12h ON public.lwb_delivery_reports;
  CREATE POLICY lwb_delivery_report_driver_12h ON public.lwb_delivery_reports AS RESTRICTIVE
    FOR SELECT TO authenticated
    USING (reported_at > now() - public.lwb_driver_keep() OR NOT EXISTS (
      SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND lower(btrim(p.role)) = 'driver'));
END;
$do$;

COMMIT;
