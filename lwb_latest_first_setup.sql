-- LUXURY WRIST BRAND ERP — LATEST ADDED / EDITED RECORD FIRST IN EVERY LIST
--
-- Mohit asked (31 Oct 2026): in every list (sales, purchase, SKU master, inventory,
-- employees, party master, driver / vehicle master, ...) the record that was added,
-- edited, modified or cancelled last must be shown first.
--
-- What this does (safe to run again):
-- 1. Every list table below gets an  updated_at  column if it does not have one yet.
--    Old rows keep NULL there (no mass UPDATE, so no other trigger fires); the
--    pages then use created_at for them. A missing created_at is added the same way.
-- 2. A BEFORE UPDATE trigger  zz_lwb_touch_updated_at  sets updated_at = now() on
--    every real change (edit, cancel, approve, deactivate ...). It is named zz_ so it
--    runs after the table's own BEFORE triggers (e.g. Sheet & Pallet history).
-- 3. lwb_emp_list() (Masters > Employee Master) also returns created_at / updated_at.
--
-- The pages sort with erp-recent.js. No data is changed, nothing is dropped.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $function$
BEGIN
  -- only a real change moves the row to the top (a save with nothing changed does not)
  IF (to_jsonb(NEW) - 'updated_at') IS DISTINCT FROM (to_jsonb(OLD) - 'updated_at') THEN
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$function$;
REVOKE ALL ON FUNCTION public.lwb_touch_updated_at() FROM PUBLIC, anon, authenticated;

DO $do$
DECLARE
  t text;
  v_type text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    -- masters
    'sku_master', 'lwb_customer_master', 'lwb_supplier_master', 'lwb_vehicles', 'lwb_drivers',
    'lwb_acc_staff', 'user_profiles', 'lwb_transport_master', 'lwb_companies', 'lwb_rate_packs',
    'lwb_mepd_schemes',
    -- sales / dispatch
    'orders', 'order_items', 'dispatch_assignments', 'sales', 'sales_returns', 'tax_invoices',
    'lwb_tally_invoices', 'lwb_internal_bills', 'lwb_payment_collections', 'lwb_delivery_reports',
    'lwb_driver_delivery_returns',
    -- purchase / stock
    'lwb_goods_inward', 'lwb_goods_inward_items', 'lwb_purchase_checks', 'lwb_stock_transit',
    'lwb_stock_moves', 'lwb_sp_entries',
    -- reports / follow-up
    'lwb_market_reports', 'lwb_godown_reports', 'lwb_party_calls', 'lwb_tasks', 'lwb_complaints'
  ] LOOP
    -- skip a table that does not exist on this database, or is a view
    IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname = 'public' AND c.relname = t AND c.relkind IN ('r','p')) THEN
      RAISE NOTICE 'latest-first: % not found, skipped', t;
      CONTINUE;
    END IF;

    -- created_at: new rows get the time; old rows stay NULL (their real time is unknown)
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = t AND column_name = 'created_at') THEN
      EXECUTE format('ALTER TABLE public.%I ADD COLUMN created_at timestamptz', t);
      EXECUTE format('ALTER TABLE public.%I ALTER COLUMN created_at SET DEFAULT now()', t);
    END IF;

    -- updated_at: NULL until the row is edited
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'public' AND table_name = t AND column_name = 'updated_at') THEN
      EXECUTE format('ALTER TABLE public.%I ADD COLUMN updated_at timestamptz', t);
    END IF;

    SELECT data_type INTO v_type FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = t AND column_name = 'updated_at';
    IF v_type NOT IN ('timestamp with time zone', 'timestamp without time zone') THEN
      RAISE NOTICE 'latest-first: %.updated_at is %, trigger not added', t, v_type;
      CONTINUE;
    END IF;

    EXECUTE format('DROP TRIGGER IF EXISTS zz_lwb_touch_updated_at ON public.%I', t);
    EXECUTE format('CREATE TRIGGER zz_lwb_touch_updated_at BEFORE UPDATE ON public.%I
                    FOR EACH ROW EXECUTE FUNCTION public.lwb_touch_updated_at()', t);
  END LOOP;
END;
$do$;

-- Masters > Employee Master: same as lwb_employee_master_setup.sql, plus created_at /
-- updated_at so the page can show the latest added / edited employee first.
CREATE OR REPLACE FUNCTION public.lwb_emp_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_m date := date_trunc('month', public.lwb_acc_today())::date;
BEGIN
  IF NOT public.lwb_emp_editor() THEN RAISE EXCEPTION 'Employee Master is for Admin, Manager, Godown and Accounts'; END IF;
  RETURN jsonb_build_object('month', v_m, 'next_code', public.lwb_emp_next_code(), 'rows', coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', s.id, 'emp_code', s.emp_code, 'name', s.name, 'mobile', s.mobile,
      'designation', s.designation, 'monthly_salary', s.monthly_salary, 'joining_date', s.joining_date, 'note', s.note,
      'is_active', s.active, 'month_cap', public.lwb_emp_month_cap(s.id, v_m), 'month_upad', t.upad, 'month_paid', t.paid,
      'created_at', s.created_at, 'updated_at', s.updated_at)
      ORDER BY greatest(s.updated_at, s.created_at) DESC NULLS LAST, s.emp_code, s.name)
    FROM public.lwb_acc_staff s CROSS JOIN LATERAL public.lwb_emp_month_taken(s.id, v_m) t), '[]'::jsonb));
END;
$fn$;

COMMIT;
