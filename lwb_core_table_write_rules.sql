-- LUXURY WRIST BRAND ERP — WHO MAY CHANGE ORDERS, SKU, BILLS AND DISPATCH (direct table writes)
--
-- Applied automatically on merge (Supabase apply workflow). Safe to run again.
--
-- Security review (5 Nov 2026): the live database still had the first-day rules
-- "every signed-in user may do everything" on orders, order_items, tax_invoices,
-- dispatch_assignments and order_audit_log, and "every signed-in user may add / change SKU"
-- on sku_master. Only Drivers (no access) and Accounts (no writes) were limited.
-- So a salesman could change a SKU rate or delete a PO from the browser console.
--
-- This file adds RESTRICTIVE rules only: no one gets more access than today.
-- Reading is not changed. Database functions (RPC) are not changed, they check roles themselves.
-- Roles below are the same as the ERP side menu (erp-shell.js):
--   sku_master            add / change   : Admin, Sales Head (manager)            -- SKU Master page
--   orders                add            : Admin, Sales Head, Salesman            -- New PO page
--                         change         : Admin, Sales Head, Warehouse           -- PO List, Loading
--                         delete         : Admin; or the creator of his own PO while it is still
--                                          pending approval (New PO page removes a PO whose lines failed)
--   order_items           add            : Admin, Sales Head, Salesman, Warehouse
--                         change / delete: Admin, Sales Head, Warehouse
--   tax_invoices          add / change / delete : Admin, Sales Head (the ERP writes bills through RPC)
--   dispatch_assignments  add / change   : Admin, Sales Head, Warehouse, Transport
--                         delete         : Admin
--   order_audit_log       change / delete: nobody (history must not be edited); adding stays as today

BEGIN;

-- Role of the signed-in user, only when the login is active. NULL otherwise.
CREATE OR REPLACE FUNCTION public.lwb_active_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT lower(btrim(p.role)) FROM public.user_profiles p
  WHERE p.id = auth.uid() AND p.active IS TRUE;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_active_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_active_role() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_role_in(p_roles text[])
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(public.lwb_active_role() = ANY (p_roles), false);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_role_in(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_role_in(text[]) TO authenticated;

DO $rules$
DECLARE
  -- table, command, rule
  r text[];
  v_rules text[][] := ARRAY[
    ['sku_master',           'INSERT', $$public.lwb_role_in(ARRAY['admin','manager'])$$],
    ['sku_master',           'UPDATE', $$public.lwb_role_in(ARRAY['admin','manager'])$$],
    ['sku_master',           'DELETE', $$public.lwb_role_in(ARRAY['admin'])$$],
    ['orders',               'INSERT', $$public.lwb_role_in(ARRAY['admin','manager','sales','salesman'])$$],
    ['orders',               'UPDATE', $$public.lwb_role_in(ARRAY['admin','manager','warehouse'])$$],
    ['orders',               'DELETE', $$public.lwb_role_in(ARRAY['admin']) OR (created_by = auth.uid() AND status = 'pending_approval' AND public.lwb_role_in(ARRAY['admin','manager','sales','salesman']))$$],
    ['order_items',          'INSERT', $$public.lwb_role_in(ARRAY['admin','manager','sales','salesman','warehouse'])$$],
    ['order_items',          'UPDATE', $$public.lwb_role_in(ARRAY['admin','manager','warehouse'])$$],
    ['order_items',          'DELETE', $$public.lwb_role_in(ARRAY['admin','manager','warehouse'])$$],
    ['tax_invoices',         'INSERT', $$public.lwb_role_in(ARRAY['admin','manager'])$$],
    ['tax_invoices',         'UPDATE', $$public.lwb_role_in(ARRAY['admin','manager'])$$],
    ['tax_invoices',         'DELETE', $$public.lwb_role_in(ARRAY['admin','manager'])$$],
    ['dispatch_assignments', 'INSERT', $$public.lwb_role_in(ARRAY['admin','manager','warehouse','transport'])$$],
    ['dispatch_assignments', 'UPDATE', $$public.lwb_role_in(ARRAY['admin','manager','warehouse','transport'])$$],
    ['dispatch_assignments', 'DELETE', $$public.lwb_role_in(ARRAY['admin'])$$],
    ['order_audit_log',      'UPDATE', 'false'],
    ['order_audit_log',      'DELETE', 'false']];
  v_name text;
BEGIN
  FOREACH r SLICE 1 IN ARRAY v_rules LOOP
    IF to_regclass('public.' || r[1]) IS NULL THEN
      RAISE NOTICE 'skip %: table not found', r[1];
      CONTINUE;
    END IF;
    v_name := 'lwb_write_role_' || lower(r[2]);
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', v_name, r[1]);
    IF r[2] = 'INSERT' THEN
      EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (%s)', v_name, r[1], r[3]);
    ELSIF r[2] = 'UPDATE' THEN
      EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR UPDATE TO authenticated USING (%s) WITH CHECK (%s)', v_name, r[1], r[3], r[3]);
    ELSE
      EXECUTE format('CREATE POLICY %I ON public.%I AS RESTRICTIVE FOR DELETE TO authenticated USING (%s)', v_name, r[1], r[3]);
    END IF;
  END LOOP;
END
$rules$;

COMMIT;

-- Check after apply: every row below should be listed.
SELECT tablename, policyname, cmd FROM pg_policies
WHERE schemaname = 'public' AND policyname LIKE 'lwb_write_role_%'
ORDER BY tablename, cmd;
