-- lwb:no-auto-run  (record / read-only script, never applied automatically)
-- LUXURY WRIST BRAND | Permissions audit (READ-ONLY).
-- Does NOT create, delete, update or alter any database data.
-- Run in Supabase SQL Editor and share results before enforcing Accounts read-only at database level.
-- Important: UI-only view mode is not equivalent to backend write protection.

-- 1. Existing table RLS and authenticated-role privileges.
SELECT c.relname AS erp_table,
       c.relrowsecurity AS rls_enabled,
       has_table_privilege('authenticated',c.oid,'SELECT') AS select_granted,
       has_table_privilege('authenticated',c.oid,'INSERT') AS insert_granted,
       has_table_privilege('authenticated',c.oid,'UPDATE') AS update_granted,
       has_table_privilege('authenticated',c.oid,'DELETE') AS delete_granted
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public'
  AND c.relkind IN ('r','p')
  AND c.relname IN (
      'user_profiles','orders','order_items','tax_invoices',
      'sales_returns','sales_return_items','sku_master','lwb_customer_master',
      'lwb_payment_collections'
  )
ORDER BY c.relname;

-- 2. Existing row-level security policy detail.
SELECT tablename, policyname, cmd, roles,
       qual AS using_condition,
       with_check AS write_condition
FROM pg_policies
WHERE schemaname='public'
  AND tablename IN (
      'orders','order_items','tax_invoices','sales_returns',
      'sales_return_items','sku_master','lwb_customer_master',
      'lwb_payment_collections'
  )
ORDER BY tablename, cmd, policyname;

-- 3. Existing user profile permissions / possible per-user flags.
SELECT column_name,data_type
FROM information_schema.columns
WHERE table_schema='public' AND table_name='user_profiles'
ORDER BY ordinal_position;
