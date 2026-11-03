-- LUXURY WRIST BRAND ERP — PO / SALES ORDER DRAFTS
--
-- Mohit asked (3 Nov 2026): when a party's order is not confirmed yet, no PO should be made.
-- On New Sales Order, "Save Draft" (or the Esc key) keeps the order as a DRAFT. Drafts show in a
-- "Draft" tab next to Pending Review on PO / Sales List, and in "Drafts" on New Sales Order.
-- Opening a draft fills the form again; Submit makes the PO and removes the draft.
--
-- A draft is NOT an order: no PO number, no stock / rate / approval / bell / Tally effect.
-- Who sees a draft: the login that saved it, plus every active Admin / Sales Head (MANAGER).
-- Same people can change or delete it.
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again. No existing table is changed.

BEGIN;

-- Logged-in active user is Admin / Sales Head.
CREATE OR REPLACE FUNCTION public.lwb_draft_is_head()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager'));
$fn$;
-- Logged-in active user can take orders (Admin / Sales Head / Salesman).
CREATE OR REPLACE FUNCTION public.lwb_draft_can_add()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager','sales','salesman'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_draft_is_head(), public.lwb_draft_can_add() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_draft_is_head(), public.lwb_draft_can_add() TO authenticated;

CREATE TABLE IF NOT EXISTS public.lwb_po_drafts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_name text CHECK (customer_name IS NULL OR length(customer_name) <= 200),
  sales_person text CHECK (sales_person IS NULL OR length(sales_person) <= 120),
  transportation text CHECK (transportation IS NULL OR length(transportation) <= 120),
  line_count integer NOT NULL DEFAULT 0 CHECK (line_count BETWEEN 0 AND 500),
  total_qty numeric NOT NULL DEFAULT 0,
  total_amount numeric NOT NULL DEFAULT 0,
  total_weight numeric NOT NULL DEFAULT 0,
  data jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(data) = 'object' AND octet_length(data::text) <= 200000),
  created_by uuid NOT NULL DEFAULT auth.uid(),
  created_by_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid DEFAULT auth.uid(),
  updated_by_name text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_po_drafts_by_idx ON public.lwb_po_drafts(created_by, updated_at DESC);
CREATE INDEX IF NOT EXISTS lwb_po_drafts_at_idx ON public.lwb_po_drafts(updated_at DESC);

-- Names and times are set by the server (the browser cannot fake who saved it).
CREATE OR REPLACE FUNCTION public.lwb_po_draft_stamp()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_name text;
BEGIN
  SELECT coalesce(nullif(btrim(p.full_name),''), 'User') INTO v_name FROM public.user_profiles p WHERE p.id = auth.uid();
  IF TG_OP = 'INSERT' THEN
    NEW.created_by := auth.uid();
    NEW.created_by_name := v_name;
    NEW.created_at := now();
  ELSE
    NEW.created_by := OLD.created_by;
    NEW.created_by_name := OLD.created_by_name;
    NEW.created_at := OLD.created_at;
  END IF;
  NEW.updated_by := auth.uid();
  NEW.updated_by_name := v_name;
  NEW.updated_at := now();
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS lwb_po_draft_stamp ON public.lwb_po_drafts;
CREATE TRIGGER lwb_po_draft_stamp BEFORE INSERT OR UPDATE ON public.lwb_po_drafts
  FOR EACH ROW EXECUTE FUNCTION public.lwb_po_draft_stamp();

ALTER TABLE public.lwb_po_drafts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lwb_po_drafts_read ON public.lwb_po_drafts;
CREATE POLICY lwb_po_drafts_read ON public.lwb_po_drafts FOR SELECT TO authenticated
  USING (created_by = auth.uid() OR public.lwb_draft_is_head());

DROP POLICY IF EXISTS lwb_po_drafts_add ON public.lwb_po_drafts;
CREATE POLICY lwb_po_drafts_add ON public.lwb_po_drafts FOR INSERT TO authenticated
  WITH CHECK (public.lwb_draft_can_add());

DROP POLICY IF EXISTS lwb_po_drafts_edit ON public.lwb_po_drafts;
CREATE POLICY lwb_po_drafts_edit ON public.lwb_po_drafts FOR UPDATE TO authenticated
  USING (created_by = auth.uid() OR public.lwb_draft_is_head())
  WITH CHECK (created_by = auth.uid() OR public.lwb_draft_is_head());

DROP POLICY IF EXISTS lwb_po_drafts_remove ON public.lwb_po_drafts;
CREATE POLICY lwb_po_drafts_remove ON public.lwb_po_drafts FOR DELETE TO authenticated
  USING (created_by = auth.uid() OR public.lwb_draft_is_head());

REVOKE ALL ON public.lwb_po_drafts FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.lwb_po_drafts TO authenticated;

COMMIT;

-- Check: should list the table with RLS on.
SELECT relname, relrowsecurity FROM pg_class WHERE relname = 'lwb_po_drafts';
