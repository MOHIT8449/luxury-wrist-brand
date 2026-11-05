-- LUXURY WRIST BRAND ERP — CHANGE HISTORY (who added / changed / deleted what, and when)
--
-- Applied automatically on merge (Supabase apply workflow). Safe to run again.
--
-- Mohit (5 Nov 2026): Admin must see the history of every add / edit / delete any employee
-- makes in the software. One log for all modules: public.lwb_change_log.
--
-- - A trigger on every ERP table writes one row per change: table, action, record, the
--   changed fields (old -> new), the login and its role at that time.
--   Changes made through RPC functions are logged too, because the trigger is on the table.
-- - Deleted rows keep the full old record, so Admin can see what was removed.
-- - Nobody can edit or delete the log (no table rights at all). Only Admin reads it,
--   through lwb_change_log_list() / lwb_change_log_meta() (page: change-history.html).
-- - A failure while writing the log never blocks the real save.
-- - Tables that only hold system / tracking data are skipped (see v_skip).
-- - lwb_change_log_attach() adds the trigger to new tables; the apply workflow calls it after
--   every SQL file, so modules added later are covered automatically.
-- - History older than 400 days is removed when attach runs (keeps the free database small).

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_change_log (
  id bigserial PRIMARY KEY,
  changed_at timestamptz NOT NULL DEFAULT now(),
  user_id uuid,
  user_role text,
  table_name text NOT NULL,
  action text NOT NULL CHECK (action IN ('INSERT','UPDATE','DELETE')),
  row_id text,
  row_label text,
  changes jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS lwb_change_log_at ON public.lwb_change_log (changed_at DESC);
CREATE INDEX IF NOT EXISTS lwb_change_log_user_at ON public.lwb_change_log (user_id, changed_at DESC);
CREATE INDEX IF NOT EXISTS lwb_change_log_table_at ON public.lwb_change_log (table_name, changed_at DESC);
ALTER TABLE public.lwb_change_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_change_log FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_change_log_id_seq FROM PUBLIC, anon, authenticated;

-- Short name of the record, for the list (PO no., party, SKU ...).
CREATE OR REPLACE FUNCTION public.lwb_change_label(r jsonb)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT left(btrim(coalesce(
    r->>'order_no', r->>'invoice_no', r->>'internal_bill_no', r->>'bill_no', r->>'slip_no',
    r->>'customer_name', r->>'party', r->>'party_name', r->>'sku_name', r->>'full_name', r->>'name',
    r->>'vehicle_no', r->>'cheque_no', r->>'title', r->>'file_name', r->>'category', r->>'message', '')), 120);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_change_label(jsonb) FROM PUBLIC, anon, authenticated;

-- Long text (notes, photo lists) is shortened so the log stays small.
CREATE OR REPLACE FUNCTION public.lwb_change_trim(d jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT coalesce(jsonb_object_agg(e.key,
    CASE WHEN octet_length(e.value::text) > 400 THEN to_jsonb(left(e.value::text, 400) || ' …') ELSE e.value END), '{}'::jsonb)
  FROM jsonb_each(d) e;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_change_trim(jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_change_log_trg()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  o jsonb; n jsonb; r jsonb; d jsonb;
  v_uid uuid;
BEGIN
  BEGIN
    IF TG_OP = 'INSERT' THEN
      n := to_jsonb(NEW); r := n; d := n;
    ELSIF TG_OP = 'DELETE' THEN
      o := to_jsonb(OLD); r := o; d := o;
    ELSE
      o := to_jsonb(OLD); n := to_jsonb(NEW); r := n;
      SELECT coalesce(jsonb_object_agg(e.key, jsonb_build_array(o -> e.key, e.value)), '{}'::jsonb) INTO d
      FROM jsonb_each(n) e
      WHERE e.value IS DISTINCT FROM o -> e.key
        AND e.key NOT IN ('updated_at','modified_at','last_seen_at','last_active_at','lease_token','leased_until');
      IF d = '{}'::jsonb THEN RETURN NULL; END IF;
    END IF;
    v_uid := auth.uid();
    INSERT INTO public.lwb_change_log (user_id, user_role, table_name, action, row_id, row_label, changes)
    VALUES (v_uid,
            (SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = v_uid),
            TG_TABLE_NAME, TG_OP,
            coalesce(r->>'id', r->>'order_id', r->>'user_id'),
            public.lwb_change_label(r),
            CASE WHEN octet_length(d::text) > 6000 THEN public.lwb_change_trim(d) ELSE d END);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'lwb_change_log skipped for %: %', TG_TABLE_NAME, SQLERRM;
  END;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_change_log_trg() FROM PUBLIC, anon, authenticated;

-- Adds the trigger to every ERP table that does not have it yet. Returns how many were added.
CREATE OR REPLACE FUNCTION public.lwb_change_log_attach()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  t record; v_added int := 0;
  v_skip text[] := ARRAY[
    'lwb_change_log','lwb_sql_apply_log','erp_notifications','order_audit_log','lwb_order_audit','lwb_cashbook_audit',
    'lwb_push_config','lwb_push_deliveries','lwb_push_jobs','lwb_push_subscriptions',
    'lwb_login_attempts','lwb_login_otp_codes','lwb_login_otp_sessions',
    'lwb_location_history','lwb_staff_location','lwb_trip_events','lwb_driver_whatsapp_log',
    'lwb_rate_history','lwb_sku_price_history','lwb_sp_history','lwb_brand_reset_rows','lwb_po_drafts'];
BEGIN
  FOR t IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r','p') AND NOT c.relispartition
      AND c.relname <> ALL (v_skip)
      AND c.relname !~ '(_log|_logs|_history|_audit_log)$'
      AND NOT EXISTS (SELECT 1 FROM pg_trigger g WHERE g.tgrelid = c.oid AND g.tgname = 'zz_lwb_change_log')
  LOOP
    BEGIN
      EXECUTE format('CREATE TRIGGER zz_lwb_change_log AFTER INSERT OR UPDATE OR DELETE ON public.%I
                      FOR EACH ROW EXECUTE FUNCTION public.lwb_change_log_trg()', t.relname);
      v_added := v_added + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'change log not added to %: %', t.relname, SQLERRM;
    END;
  END LOOP;
  DELETE FROM public.lwb_change_log WHERE changed_at < now() - interval '400 days';
  RETURN v_added;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_change_log_attach() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_change_log_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
                 WHERE p.id = auth.uid() AND p.active IS TRUE AND lower(btrim(p.role)) = 'admin');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_change_log_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_change_log_admin() TO authenticated;

-- Admin list. Dates are India dates (inclusive). p_q searches the record name and the changes.
CREATE OR REPLACE FUNCTION public.lwb_change_log_list(
  p_from date, p_to date, p_user uuid DEFAULT NULL, p_table text DEFAULT NULL,
  p_action text DEFAULT NULL, p_q text DEFAULT NULL, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_from timestamptz; v_to timestamptz; v_rows jsonb; v_total bigint;
  v_q text := nullif(btrim(coalesce(p_q, '')), '');
  v_lim int := least(greatest(coalesce(p_limit, 100), 1), 500);
BEGIN
  IF NOT public.lwb_change_log_admin() THEN RAISE EXCEPTION 'Admin only.'; END IF;
  v_from := (coalesce(p_from, (now() AT TIME ZONE 'Asia/Kolkata')::date - 6)::timestamp) AT TIME ZONE 'Asia/Kolkata';
  v_to := ((coalesce(p_to, (now() AT TIME ZONE 'Asia/Kolkata')::date) + 1)::timestamp) AT TIME ZONE 'Asia/Kolkata';
  WITH f AS (
    SELECT l.* FROM public.lwb_change_log l
    WHERE l.changed_at >= v_from AND l.changed_at < v_to
      AND (p_user IS NULL OR l.user_id = p_user)
      AND (nullif(p_table, '') IS NULL OR l.table_name = p_table)
      AND (nullif(p_action, '') IS NULL OR l.action = upper(p_action))
      AND (v_q IS NULL OR l.row_label ILIKE '%' || v_q || '%' OR l.changes::text ILIKE '%' || v_q || '%')
  )
  SELECT (SELECT count(*) FROM f),
         coalesce((SELECT jsonb_agg(x ORDER BY x.changed_at DESC, x.id DESC) FROM (
           SELECT f.id, f.changed_at, f.user_id, f.user_role, f.table_name, f.action, f.row_id, f.row_label, f.changes,
                  coalesce(p.full_name, CASE WHEN f.user_id IS NULL THEN 'System' ELSE 'Unknown login' END) AS user_name
           FROM f LEFT JOIN public.user_profiles p ON p.id = f.user_id
           ORDER BY f.changed_at DESC, f.id DESC
           LIMIT v_lim OFFSET greatest(coalesce(p_offset, 0), 0)) x), '[]'::jsonb)
  INTO v_total, v_rows;
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_change_log_list(date,date,uuid,text,text,text,integer,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_change_log_list(date,date,uuid,text,text,text,integer,integer) TO authenticated;

-- Filter lists for the page: employees and modules that have history.
CREATE OR REPLACE FUNCTION public.lwb_change_log_meta()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_change_log_admin() THEN RAISE EXCEPTION 'Admin only.'; END IF;
  RETURN jsonb_build_object(
    'users', coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'name', coalesce(p.full_name, '—'), 'role', p.role, 'active', p.active)
                                        ORDER BY p.active DESC, p.full_name)
                       FROM public.user_profiles p), '[]'::jsonb),
    'tables', coalesce((SELECT jsonb_agg(c.relname::text ORDER BY c.relname)
                        FROM pg_trigger g JOIN pg_class c ON c.oid = g.tgrelid
                        WHERE g.tgname = 'zz_lwb_change_log'), '[]'::jsonb));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_change_log_meta() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_change_log_meta() TO authenticated;

SELECT public.lwb_change_log_attach();

COMMIT;
