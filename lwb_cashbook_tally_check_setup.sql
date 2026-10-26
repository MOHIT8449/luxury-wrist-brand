-- LUXURY WRIST BRAND ERP — PRIVATE CASHBOOK + TALLY BILL CHECK
--
-- RUN ONCE in Supabase SQL Editor (after lwb_user_extra_pages_setup.sql). Safe to run again.
--
-- 1. Cashbook (cashbook.html)
--    The Cashbook data is kept in lwb_cashbook. Nobody can read or change the table directly:
--    only the functions below, and they open ONLY for
--      * an active ADMIN who has not unticked "Cashbook" in Manage Users > Pages, or
--      * a user whom Admin ticked "Cashbook" for in Manage Users > Pages.
--    Every other login (and the public key) gets nothing, even with the page link.
--    An earlier copy is kept every 15 minutes and always before the data is cleared
--    (password 3) or restored, so Admin can bring it back from Cashbook > Backup.
--
-- 2. Tally Bill Check (tally-check.html, Admin + Accounts)
--    The Tally Sales Register file is read in the browser and compared there. Tally rows are
--    NOT saved in the ERP. Only the Tally party name -> ERP party name links are saved
--    (lwb_tally_party_map), so the same name is matched next time.
--
-- No order, stock, bill, payment, ledger or Tally data is changed.

BEGIN;

-- Page-access table (same as lwb_user_extra_pages_setup.sql), created here if missing.
CREATE TABLE IF NOT EXISTS public.lwb_user_page_access (
  user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  hidden     text[] NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
ALTER TABLE public.lwb_user_page_access ADD COLUMN IF NOT EXISTS extra text[] NOT NULL DEFAULT '{}';
ALTER TABLE public.lwb_user_page_access ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 1. CASHBOOK
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_cashbook (
  id         smallint PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  data       jsonb NOT NULL DEFAULT '{"books":[]}'::jsonb,
  version    bigint NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
CREATE TABLE IF NOT EXISTS public.lwb_cashbook_copies (
  id       bigserial PRIMARY KEY,
  version  bigint NOT NULL,
  data     jsonb NOT NULL,
  reason   text NOT NULL,
  saved_at timestamptz NOT NULL DEFAULT now(),
  saved_by uuid
);
ALTER TABLE public.lwb_cashbook ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_cashbook_copies ENABLE ROW LEVEL SECURITY;
-- No policies and no grants: the tables can be reached only through the functions below.
REVOKE ALL ON TABLE public.lwb_cashbook, public.lwb_cashbook_copies FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_cashbook_copies_id_seq FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_cashbook_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    LEFT JOIN public.lwb_user_page_access a ON a.user_id = p.id
    WHERE p.id = auth.uid() AND p.active = true
      AND ((lower(btrim(p.role)) = 'admin' AND NOT ('cashbook.html' = ANY (coalesce(a.hidden, '{}'))))
        OR 'cashbook.html' = ANY (coalesce(a.extra, '{}'))));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_cashbook_erp_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT public.lwb_cashbook_user() AND EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'admin');
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_cashbook_load()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v public.lwb_cashbook%ROWTYPE;
BEGIN
  IF NOT public.lwb_cashbook_user() THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  SELECT * INTO v FROM public.lwb_cashbook WHERE id = 1;
  RETURN jsonb_build_object(
    'data', coalesce(v.data, '{"books":[]}'::jsonb),
    'version', coalesce(v.version, 0),
    'erp_admin', public.lwb_cashbook_erp_admin());
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_cashbook_version()
RETURNS bigint LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_user() THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  RETURN coalesce((SELECT c.version FROM public.lwb_cashbook c WHERE c.id = 1), 0);
END;
$fn$;

-- Saves the whole Cashbook. p_version = the version the page loaded; if someone else saved
-- after that, nothing is saved and the page reloads the newer data (CONFLICT).
CREATE OR REPLACE FUNCTION public.lwb_cashbook_save(p_data jsonb, p_version bigint)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_old public.lwb_cashbook%ROWTYPE;
  v_cleared boolean;
BEGIN
  IF NOT public.lwb_cashbook_user() THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' OR jsonb_typeof(p_data -> 'books') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Cashbook data is damaged. Not saved.';
  END IF;
  INSERT INTO public.lwb_cashbook (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  SELECT * INTO v_old FROM public.lwb_cashbook WHERE id = 1 FOR UPDATE;
  IF v_old.version <> coalesce(p_version, -1) THEN
    RAISE EXCEPTION 'CONFLICT: the Cashbook was saved by someone else first.';
  END IF;

  v_cleared := jsonb_array_length(p_data -> 'books') = 0
    AND jsonb_array_length(coalesce(v_old.data -> 'books', '[]'::jsonb)) > 0;
  -- earlier copy: always before the books are cleared, otherwise at most one every 15 minutes
  IF v_old.version > 0 AND (v_cleared OR NOT EXISTS (
       SELECT 1 FROM public.lwb_cashbook_copies c
       WHERE c.reason = 'save' AND c.saved_at > now() - interval '15 minutes')) THEN
    INSERT INTO public.lwb_cashbook_copies (version, data, reason, saved_by)
    VALUES (v_old.version, v_old.data, CASE WHEN v_cleared THEN 'cleared' ELSE 'save' END, auth.uid());
    -- keep the newest 300 timed copies; copies made before a clear or restore are never removed
    DELETE FROM public.lwb_cashbook_copies c
    WHERE c.reason = 'save'
      AND c.id NOT IN (SELECT k.id FROM public.lwb_cashbook_copies k WHERE k.reason = 'save' ORDER BY k.id DESC LIMIT 300);
  END IF;

  UPDATE public.lwb_cashbook
     SET data = p_data, version = v_old.version + 1, updated_at = now(), updated_by = auth.uid()
   WHERE id = 1;
  RETURN v_old.version + 1;
END;
$fn$;

-- Admin: list of earlier copies (newest first), with the number of books and entries in each.
CREATE OR REPLACE FUNCTION public.lwb_cashbook_copies_list()
RETURNS TABLE (id bigint, saved_at timestamptz, reason text, saved_by text, books integer, entries integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_erp_admin() THEN
    RAISE EXCEPTION 'Only an ERP Admin with Cashbook access can see earlier copies.';
  END IF;
  RETURN QUERY
  SELECT c.id, c.saved_at, c.reason,
         coalesce(nullif(btrim(p.full_name), ''), '—'),
         jsonb_array_length(coalesce(c.data -> 'books', '[]'::jsonb)),
         coalesce((SELECT sum(jsonb_array_length(coalesce(b -> 'entries', '[]'::jsonb)))::integer
                   FROM jsonb_array_elements(coalesce(c.data -> 'books', '[]'::jsonb)) b), 0)
  FROM public.lwb_cashbook_copies c
  LEFT JOIN public.user_profiles p ON p.id = c.saved_by
  ORDER BY c.id DESC
  LIMIT 200;
END;
$fn$;

-- Admin: put an earlier copy back. The data before the restore is kept as a copy too.
CREATE OR REPLACE FUNCTION public.lwb_cashbook_restore(p_copy_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_copy public.lwb_cashbook_copies%ROWTYPE;
  v_old public.lwb_cashbook%ROWTYPE;
BEGIN
  IF NOT public.lwb_cashbook_erp_admin() THEN
    RAISE EXCEPTION 'Only an ERP Admin with Cashbook access can restore a copy.';
  END IF;
  SELECT * INTO v_copy FROM public.lwb_cashbook_copies WHERE id = p_copy_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Copy not found.';
  END IF;
  INSERT INTO public.lwb_cashbook (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  SELECT * INTO v_old FROM public.lwb_cashbook WHERE id = 1 FOR UPDATE;
  IF v_old.version > 0 THEN
    INSERT INTO public.lwb_cashbook_copies (version, data, reason, saved_by)
    VALUES (v_old.version, v_old.data, 'before restore', auth.uid());
  END IF;
  UPDATE public.lwb_cashbook
     SET data = v_copy.data, version = v_old.version + 1, updated_at = now(), updated_by = auth.uid()
   WHERE id = 1;
  RETURN jsonb_build_object('data', v_copy.data, 'version', v_old.version + 1);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_cashbook_user(), public.lwb_cashbook_erp_admin(), public.lwb_cashbook_load(),
  public.lwb_cashbook_version(), public.lwb_cashbook_save(jsonb, bigint), public.lwb_cashbook_copies_list(),
  public.lwb_cashbook_restore(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_cashbook_user(), public.lwb_cashbook_erp_admin(), public.lwb_cashbook_load(),
  public.lwb_cashbook_version(), public.lwb_cashbook_save(jsonb, bigint), public.lwb_cashbook_copies_list(),
  public.lwb_cashbook_restore(bigint) TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. TALLY BILL CHECK
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_tally_party_map (
  tally_key     text PRIMARY KEY,
  tally_name    text NOT NULL,
  customer_name text,              -- NULL = skip this Tally name (e.g. cash sale)
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    uuid
);
ALTER TABLE public.lwb_tally_party_map ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_tally_party_map FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_tally_check_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','accounts'))
    OR public.lwb_has_page('tally-check.html');
$fn$;

-- Dispatched orders (status loaded / invoiced / dispatched / delivered) whose loading was
-- completed between the two dates (India time; order date when the loading time is missing).
-- Amount = internal ERP bill amount, else actual loaded qty x PO rate, else the order total.
CREATE OR REPLACE FUNCTION public.lwb_tally_check_orders(p_from date, p_to date)
RETURNS TABLE (order_id uuid, order_no text, party text, order_date date, dispatch_date date,
               status text, amount numeric, amount_from text, delivery text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_check_user() THEN
    RAISE EXCEPTION 'Active Admin / Accounts role required.';
  END IF;
  RETURN QUERY
  WITH o AS (
    SELECT o.id, o.order_no::text AS order_no, btrim(o.customer_name::text) AS party, o.order_date::date AS order_date,
           lower(btrim(coalesce(o.status::text, ''))) AS status, o.total_amount,
           coalesce((SELECT max(a.loading_completed_at) FROM public.dispatch_assignments a WHERE a.order_id = o.id) AT TIME ZONE 'Asia/Kolkata',
                    o.order_date::timestamp)::date AS dispatch_date
    FROM public.orders o
    WHERE lower(btrim(coalesce(o.status::text, ''))) IN ('loaded','invoiced','dispatched','delivered')
      AND o.order_date::date BETWEEN p_from - 31 AND p_to
  )
  SELECT o.id, o.order_no, o.party, o.order_date, o.dispatch_date, o.status,
         round(coalesce(b.goods_amount, li.amt, o.total_amount, 0)::numeric, 2),
         CASE WHEN b.goods_amount IS NOT NULL THEN 'ERP bill' WHEN li.amt IS NOT NULL THEN 'Loaded qty x rate' ELSE 'Order total' END,
         coalesce(dr.delivery_status::text, '')
  FROM o
  LEFT JOIN public.lwb_internal_bills b ON b.order_id = o.id
  LEFT JOIN LATERAL (
    SELECT sum(round(i.loaded_qty::numeric * i.rate::numeric, 2)) AS amt
    FROM public.order_items i
    WHERE i.order_id = o.id AND coalesce(i.loaded_qty, 0) > 0 AND i.rate IS NOT NULL
  ) li ON true
  LEFT JOIN public.lwb_delivery_reports dr ON dr.order_id = o.id
  WHERE o.dispatch_date BETWEEN p_from AND p_to
  ORDER BY o.dispatch_date, o.party, o.order_no;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_tally_check_parties()
RETURNS TABLE (customer_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_check_user() THEN
    RAISE EXCEPTION 'Active Admin / Accounts role required.';
  END IF;
  RETURN QUERY
  SELECT DISTINCT btrim(m.customer_name::text) FROM public.lwb_customer_master m
  WHERE nullif(btrim(m.customer_name::text), '') IS NOT NULL
  ORDER BY 1;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_tally_party_maps()
RETURNS TABLE (tally_key text, tally_name text, customer_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_check_user() THEN
    RAISE EXCEPTION 'Active Admin / Accounts role required.';
  END IF;
  RETURN QUERY SELECT m.tally_key, m.tally_name, m.customer_name FROM public.lwb_tally_party_map m ORDER BY m.tally_name;
END;
$fn$;

-- p_customer_name: the ERP party; '' = skip this Tally name; NULL = remove the link.
CREATE OR REPLACE FUNCTION public.lwb_tally_set_party_map(p_tally_name text, p_customer_name text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_key text := btrim(regexp_replace(upper(coalesce(p_tally_name, '')), '[^A-Z0-9]+', ' ', 'g'));
BEGIN
  IF NOT public.lwb_tally_check_user() THEN
    RAISE EXCEPTION 'Active Admin / Accounts role required.';
  END IF;
  IF v_key = '' THEN
    RAISE EXCEPTION 'Tally party name is empty.';
  END IF;
  IF p_customer_name IS NULL THEN
    DELETE FROM public.lwb_tally_party_map WHERE tally_key = v_key;
    RETURN;
  END IF;
  INSERT INTO public.lwb_tally_party_map AS m (tally_key, tally_name, customer_name, updated_at, updated_by)
  VALUES (v_key, btrim(p_tally_name), nullif(btrim(p_customer_name), ''), now(), auth.uid())
  ON CONFLICT (tally_key) DO UPDATE
    SET tally_name = excluded.tally_name, customer_name = excluded.customer_name, updated_at = now(), updated_by = auth.uid();
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_tally_check_user(), public.lwb_tally_check_orders(date, date), public.lwb_tally_check_parties(),
  public.lwb_tally_party_maps(), public.lwb_tally_set_party_map(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_tally_check_user(), public.lwb_tally_check_orders(date, date), public.lwb_tally_check_parties(),
  public.lwb_tally_party_maps(), public.lwb_tally_set_party_map(text, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: one row each. All four should say true / a number.
SELECT 'cashbook table' AS item, (to_regclass('public.lwb_cashbook') IS NOT NULL)::text AS ok
UNION ALL SELECT 'cashbook copies table', (to_regclass('public.lwb_cashbook_copies') IS NOT NULL)::text
UNION ALL SELECT 'tally party links table', (to_regclass('public.lwb_tally_party_map') IS NOT NULL)::text
UNION ALL SELECT 'direct table access for logins (must be false)',
  (has_table_privilege('authenticated', 'public.lwb_cashbook', 'SELECT') OR has_table_privilege('anon', 'public.lwb_cashbook', 'SELECT'))::text;
