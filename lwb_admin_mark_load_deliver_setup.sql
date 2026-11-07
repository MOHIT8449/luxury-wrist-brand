-- LUXURY WRIST BRAND ERP — ADMIN MARKS A PO LOADED / DELIVERED BY HAND (temporary)
--
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (5 Nov 2026): goods are often delivered, but the driver and the Godown Manager did not
-- press "Vehicle Loaded" / "Delivered" in the app, so the PO never moves on and Accounts cannot finish
-- the bill. For now Admin may mark such a PO Loaded and / or Delivered with a date. Every mark is kept
-- in lwb_admin_order_marks (who, when, which date, old status, note).
--   * lwb_admin_mark_order(order, loaded, delivered, date, note): Admin only.
--       Loaded:    approved .. loading -> 'loaded'. Loaded qty = approved qty (ordered when no approved
--                  qty) on lines that have no loaded qty yet. Transport row (if any) gets the loading
--                  start / end time of that date. The normal "Vehicle loaded -> make Tally bill" bell goes.
--       Delivered: loaded / invoiced / dispatched -> 'delivered' (loaded first when both are asked).
--                  Refused when a driver delivery report already says Delivered / Partial.
--   * lwb_admin_order_marks(order ids): the marks, for PO / Sales (Admin, Sales Head, Godown, Accounts)
--     and Billing & Outstanding (Bills to make).
--   * lwb_po_delivered_orders: also counts an Admin "Delivered" mark (same signature, same roles).
-- No stock, bill amount, payment, ledger or Tally row is changed by this file.
--
-- Sales Head too (7 Nov 2026, Mohit): an active Sales Head (MANAGER) may mark Loaded / Delivered the same
-- way (one PO or many selected), until Admin turns it off for him in Manage Users > Pages > "Mark PO
-- Loaded / Delivered" (unticked = 'warehouse-orders.html#mark' in lwb_user_page_access.hidden).
--   * lwb_can_mark_po(): Admin, or a Sales Head who has not been turned off.
--   * marks keep the role of who marked (marked_by_role: ADMIN / MANAGER) for the log line.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_admin_order_marks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('LOADED','DELIVERED')),
  mark_date date NOT NULL,
  old_status text,
  note text CHECK (note IS NULL OR length(note) <= 300),
  marked_by uuid NOT NULL,
  marked_by_name text,
  marked_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_admin_order_marks ADD COLUMN IF NOT EXISTS marked_by_role text;
CREATE UNIQUE INDEX IF NOT EXISTS lwb_admin_order_marks_one ON public.lwb_admin_order_marks(order_id, kind);
ALTER TABLE public.lwb_admin_order_marks ENABLE ROW LEVEL SECURITY;  -- read / write through the functions only
REVOKE ALL ON public.lwb_admin_order_marks FROM PUBLIC, anon, authenticated;

-- Page-access table (same as lwb_user_extra_pages_setup.sql), created here if missing.
CREATE TABLE IF NOT EXISTS public.lwb_user_page_access (
  user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  hidden     text[] NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

-- ---------------------------------------------------------------------------
-- Who may mark: Admin always; Sales Head unless Admin unticked "Mark PO Loaded / Delivered"
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_can_mark_po()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND (lower(btrim(p.role)) = 'admin'
           OR (lower(btrim(p.role)) = 'manager' AND NOT EXISTS (
                 SELECT 1 FROM public.lwb_user_page_access a
                 WHERE a.user_id = p.id AND 'warehouse-orders.html#mark' = ANY(a.hidden)))));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_can_mark_po() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_can_mark_po() TO authenticated;

-- ---------------------------------------------------------------------------
-- Admin / Sales Head: mark Loaded and / or Delivered
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_admin_mark_order(
  p_order_id uuid, p_loaded boolean, p_delivered boolean, p_date date, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_me text;
  v_role text;
  v_who text;
  v_o public.orders%ROWTYPE;
  v_st text;
  v_old text;
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_at timestamptz;
  v_note text := nullif(btrim(coalesce(p_note,'')),'');
  v_done text[] := '{}';
  v_set text;
BEGIN
  IF NOT public.lwb_can_mark_po() THEN
    RAISE EXCEPTION 'Only Admin (or a Sales Head allowed by Admin) can mark a PO loaded / delivered';
  END IF;
  SELECT p.full_name, upper(btrim(p.role)) INTO v_me, v_role FROM public.user_profiles p WHERE p.id = auth.uid();
  v_who := CASE WHEN v_role = 'MANAGER' THEN 'Sales Head' ELSE 'Admin' END;
  IF NOT coalesce(p_loaded,false) AND NOT coalesce(p_delivered,false) THEN
    RAISE EXCEPTION 'Choose Loaded or Delivered';
  END IF;
  IF p_date IS NULL OR p_date > v_today THEN RAISE EXCEPTION 'Enter a date, today or before'; END IF;
  IF p_date < v_today - 90 THEN RAISE EXCEPTION 'Date is more than 90 days old'; END IF;
  IF length(coalesce(v_note,'')) > 300 THEN RAISE EXCEPTION 'Note is too long'; END IF;

  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF p_date < v_o.order_date::date THEN RAISE EXCEPTION 'Date is before the PO date'; END IF;
  v_st := lower(btrim(coalesce(v_o.status::text,'')));
  v_old := v_st;
  -- today = now; an earlier day = 12:00 noon IST of that day
  v_at := CASE WHEN p_date = v_today THEN now() ELSE (p_date + time '12:00') AT TIME ZONE 'Asia/Kolkata' END;

  -- 1. Loaded
  IF v_st IN ('approved','approved_next','manager_approved','warehouse_approved','transport_allocated','allocated','loading') THEN
    -- "Delivered" on a PO not loaded yet marks it loaded first
    UPDATE public.order_items i SET loaded_qty = coalesce(i.approved_qty, i.ordered_qty, 0)
    WHERE i.order_id = v_o.id AND coalesce(i.loaded_qty,0) = 0;
    UPDATE public.dispatch_assignments a
    SET loading_started_at = coalesce(a.loading_started_at, v_at),
        loading_completed_at = coalesce(a.loading_completed_at, v_at)
    WHERE a.order_id = v_o.id;
    UPDATE public.orders SET status = 'loaded' WHERE id = v_o.id;
    INSERT INTO public.lwb_admin_order_marks(order_id, kind, mark_date, old_status, note, marked_by, marked_by_name, marked_by_role)
    VALUES (v_o.id, 'LOADED', p_date, v_old, v_note, auth.uid(), v_me, v_role)
    ON CONFLICT (order_id, kind) DO UPDATE SET mark_date = excluded.mark_date, old_status = excluded.old_status,
      note = excluded.note, marked_by = excluded.marked_by, marked_by_name = excluded.marked_by_name,
      marked_by_role = excluded.marked_by_role, marked_at = now();
    -- the Godown Manager's "load this vehicle" bells are done
    UPDATE public.erp_notifications SET is_read = true
    WHERE order_id = v_o.id AND is_read = false
      AND notification_type IN ('PO_APPROVED_LOADING','LOADING_ASSIGNMENT','LOADING_ASSIGNMENT_DISPATCH');
    v_done := array_append(v_done, 'LOADED'); v_st := 'loaded';
  ELSIF coalesce(p_loaded,false) AND NOT coalesce(p_delivered,false) THEN
    IF v_st IN ('loaded','invoiced','dispatched','delivered','closed','completed') THEN
      RAISE EXCEPTION 'PO % is already loaded', v_o.order_no;
    END IF;
    RAISE EXCEPTION 'PO % is not approved (status %), so it cannot be marked loaded', v_o.order_no, coalesce(nullif(v_st,''),'-');
  END IF;

  -- 2. Delivered
  IF coalesce(p_delivered,false) THEN
    IF v_st IN ('delivered','closed','completed') OR EXISTS (
         SELECT 1 FROM public.lwb_delivery_reports d
         WHERE d.order_id = v_o.id AND d.delivery_status IN ('DELIVERED','PARTIAL')) THEN
      RAISE EXCEPTION 'PO % is already delivered', v_o.order_no;
    END IF;
    IF v_st NOT IN ('loaded','invoiced','dispatched') THEN
      RAISE EXCEPTION 'PO % is not approved (status %), so it cannot be marked delivered', v_o.order_no, coalesce(nullif(v_st,''),'-');
    END IF;
    v_set := 'delivered';
    BEGIN
      UPDATE public.orders SET status = 'delivered' WHERE id = v_o.id;
    EXCEPTION WHEN check_violation THEN
      v_set := v_st;  -- the live status list has no 'delivered': keep it loaded, the mark still counts
    END;
    INSERT INTO public.lwb_admin_order_marks(order_id, kind, mark_date, old_status, note, marked_by, marked_by_name, marked_by_role)
    VALUES (v_o.id, 'DELIVERED', p_date, v_st, v_note, auth.uid(), v_me, v_role)
    ON CONFLICT (order_id, kind) DO UPDATE SET mark_date = excluded.mark_date, old_status = excluded.old_status,
      note = excluded.note, marked_by = excluded.marked_by, marked_by_name = excluded.marked_by_name,
      marked_by_role = excluded.marked_by_role, marked_at = now();
    v_done := array_append(v_done, 'DELIVERED'); v_st := v_set;
  END IF;

  -- Accounts: the PO is ready for its bill
  IF NOT EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = v_o.id) THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, v_who || ' marked ' || lower(array_to_string(v_done, ' + ')) || ' — Make Tally bill',
      coalesce(v_o.order_no,'PO') || ' · ' || coalesce(btrim(v_o.customer_name),'') || ': ' ||
      coalesce(v_me, v_who) || ' (' || v_who || ') marked it ' || lower(array_to_string(v_done, ' and ')) || ' on ' ||
      to_char(p_date,'DD/MM/YYYY') || '. Make the bill (Billing & Outstanding > Bills to make).',
      'TALLY_BILL_PENDING', v_o.id
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(p.role)) = 'accounts';
  END IF;

  RETURN jsonb_build_object('order_id', v_o.id, 'order_no', v_o.order_no, 'status', v_st,
                            'old_status', v_old, 'marked', to_jsonb(v_done));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_admin_mark_order(uuid,boolean,boolean,date,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_admin_mark_order(uuid,boolean,boolean,date,text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Marks of some POs (or of the last 90 days when p_ids is NULL)
-- ---------------------------------------------------------------------------
-- (marked_by_role added 7 Nov 2026: the result changes shape, so the old one goes first)
DROP FUNCTION IF EXISTS public.lwb_admin_order_marks(uuid[]);
CREATE OR REPLACE FUNCTION public.lwb_admin_order_marks(p_ids uuid[] DEFAULT NULL)
RETURNS TABLE(order_id uuid, kind text, mark_date date, old_status text, note text, marked_by_name text, marked_at timestamptz,
              marked_by_role text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','warehouse','transport','accounts')) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;
  RETURN QUERY
    SELECT m.order_id, m.kind, m.mark_date, m.old_status, m.note, m.marked_by_name, m.marked_at,
           coalesce(m.marked_by_role, 'ADMIN')
    FROM public.lwb_admin_order_marks m
    WHERE (p_ids IS NULL AND m.marked_at >= now() - interval '90 days') OR m.order_id = ANY(p_ids)
    ORDER BY m.marked_at DESC
    LIMIT 2000;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_admin_order_marks(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_admin_order_marks(uuid[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- PO / Sales "Delivered": driver report, or Admin mark (same as lwb_order_priority_sla_setup.sql + marks)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_po_delivered_orders(p_ids uuid[])
RETURNS TABLE(order_id uuid, reported_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager','warehouse','transport')) THEN
    RAISE EXCEPTION 'Not allowed.';
  END IF;
  RETURN QUERY
    SELECT x.order_id, max(x.at) FROM (
      SELECT d.order_id, d.reported_at AS at
      FROM public.lwb_delivery_reports d
      WHERE d.order_id = ANY(p_ids) AND d.delivery_status IN ('DELIVERED','PARTIAL')
      UNION ALL
      SELECT m.order_id, CASE WHEN m.mark_date = (m.marked_at AT TIME ZONE 'Asia/Kolkata')::date THEN m.marked_at
                              ELSE (m.mark_date + time '12:00') AT TIME ZONE 'Asia/Kolkata' END
      FROM public.lwb_admin_order_marks m
      WHERE m.order_id = ANY(p_ids) AND m.kind = 'DELIVERED') x
    GROUP BY x.order_id;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_delivered_orders(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_delivered_orders(uuid[]) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';
