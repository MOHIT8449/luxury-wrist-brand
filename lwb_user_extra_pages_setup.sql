-- LUXURY WRIST BRAND ERP — TICK ANY PAGE FOR ANY USER
--
-- RUN ONCE in Supabase SQL Editor, after lwb_user_page_access_setup.sql. Safe to run again.
--
-- Manage Users > Pages: Admin can now tick pages of OTHER roles for one user
-- (e.g. My Sales for a Sales Head, Purchase Register for Accounts). Those pages
-- are stored in lwb_user_page_access.extra; they appear in the user's menu and
-- open for him. Unticking a page of his own role still goes to "hidden".
--
-- lwb_has_page('page.html') tells database checks that a user was given a page.
-- The access checks below also let a ticked user read / save on that page:
--   Sales Team Setup, Sales Tracking (Sales Head checks) · PO Entry · Godown Report ·
--   Outside Market Stock · Goods in Transit · Purchase Claims · Sheet & Pallet Ledger.
-- Run after lwb_live_stock_po_setup.sql and lwb_announcements_market_report_setup.sql.
--
-- Only lwb_user_page_access is written. No order, stock, bill, payment, ledger or Tally data is changed.

BEGIN;

ALTER TABLE public.lwb_user_page_access
  ADD COLUMN IF NOT EXISTS extra text[] NOT NULL DEFAULT '{}';

CREATE OR REPLACE FUNCTION public.lwb_has_page(p_page text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.lwb_user_page_access a
    JOIN public.user_profiles p ON p.id = a.user_id AND p.active = true
    WHERE a.user_id = auth.uid()
      AND EXISTS (SELECT 1 FROM unnest(a.extra) AS e(h) WHERE split_part(e.h, '#', 1) = split_part(p_page, '#', 1)));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_has_page(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_has_page(text) TO authenticated;

-- Admin saves one user's pages: hidden = own-role pages unticked, extra = other-role pages ticked.
CREATE OR REPLACE FUNCTION public.lwb_admin_set_pages(p_user_id uuid, p_hidden text[], p_extra text[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text;
  v_hidden text[];
  v_extra text[];
BEGIN
  IF NOT public.lwb_is_admin() THEN
    RAISE EXCEPTION 'Only an active Admin can change page access.';
  END IF;
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found.';
  END IF;

  SELECT coalesce(array_agg(DISTINCT k ORDER BY k), '{}') INTO v_hidden
  FROM unnest(coalesce(p_hidden, '{}')) AS u(k)
  WHERE k ~ '^[a-z0-9-]+\.html(#[a-z0-9-]+)?$'
    AND NOT (v_role = 'admin' AND k = 'users.html');

  SELECT coalesce(array_agg(DISTINCT k ORDER BY k), '{}') INTO v_extra
  FROM unnest(coalesce(p_extra, '{}')) AS u(k)
  WHERE k ~ '^[a-z0-9-]+\.html(#[a-z0-9-]+)?$';

  INSERT INTO public.lwb_user_page_access AS a (user_id, hidden, extra, updated_at, updated_by)
  VALUES (p_user_id, v_hidden, v_extra, now(), auth.uid())
  ON CONFLICT (user_id) DO UPDATE
    SET hidden = excluded.hidden, extra = excluded.extra, updated_at = now(), updated_by = auth.uid();
  RETURN jsonb_build_object('hidden', to_jsonb(v_hidden), 'extra', to_jsonb(v_extra));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_admin_set_pages(uuid, text[], text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_admin_set_pages(uuid, text[], text[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- A ticked page also passes that page's own access check in the database.
-- (Same rules as before, plus "OR lwb_has_page(...)".)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_sales_head()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager'))
    OR public.lwb_has_page('sales-team.html') OR public.lwb_has_page('sales-tracking.html');
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_po_entry_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager','sales')
  ) OR public.lwb_has_page('order-entry.html');
$function$;

CREATE OR REPLACE FUNCTION public.lwb_godown_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager','warehouse'))
    OR public.lwb_has_page('godown-report.html');
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_market_reporter()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager','sales','salesman'))
    OR public.lwb_has_page('market-report.html');
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_stock_keeper()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager','warehouse'))
    OR public.lwb_has_page('stock-transit.html');
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_can_view_stock()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND (lower(btrim(p.role)) = 'admin'
        OR lower(btrim(p.role)) = ANY (coalesce((SELECT s.stock_view_roles FROM public.lwb_sales_settings s WHERE s.id = 1), ARRAY['admin','manager','warehouse']))
        OR (lower(btrim(p.role)) = 'salesman' AND 'sales' = ANY (coalesce((SELECT s.stock_view_roles FROM public.lwb_sales_settings s WHERE s.id = 1), '{}')))))
    OR public.lwb_has_page('stock-transit.html');
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_pc_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager')
  ) OR public.lwb_has_page('purchase-claims.html');
$function$;

CREATE OR REPLACE FUNCTION public.lwb_sp_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager','accounts','warehouse')
  ) OR public.lwb_has_page('sheet-pallet.html');
$function$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: other database rules that still check the ROLE only (not the ticked page).
-- Please send this list (Download > CSV, or a screenshot) so those pages can be opened up too.
SELECT 'policy' AS kind, tablename AS on_what, policyname AS name, cmd AS action
FROM pg_policies
WHERE schemaname = 'public' AND (coalesce(qual,'') || coalesce(with_check,'')) ~* 'role'
UNION ALL
SELECT 'function', n.nspname, p.proname, ''
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prokind = 'f'
  AND p.proname NOT IN ('lwb_has_page','lwb_sales_head','lwb_po_entry_user','lwb_godown_user','lwb_market_reporter','lwb_stock_keeper',
    'lwb_can_view_stock','lwb_pc_user','lwb_sp_user','lwb_is_admin','lwb_admin_set_pages','lwb_admin_set_page_access')
  AND pg_get_functiondef(p.oid) ~* 'p\.role|\mrole\M *(=|in|<>)'
ORDER BY 1, 2, 3;
