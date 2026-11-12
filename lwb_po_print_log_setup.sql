-- LUXURY WRIST BRAND ERP — PO PRINT LOG: WAS THIS PO PRINTED, AND CHANGED AFTER THE PRINT?
--
-- Runs by itself when merged to main. Safe to run again. Adds one table and two functions; nothing is
-- changed or deleted in other tables.
--
-- Mohit asked (12 Nov 2026): on the PO / Sales List nobody can see whether a PO was already printed, or
-- printed, then changed and printed again. Every PO / challan print from the PO list now saves one row:
--   * lwb_po_prints: order, kind (PO / CHALLAN), when, who, and a fingerprint (sig) of the PO lines
--     at print time (SKU + qty + rate, in SKU order).
--   * lwb_po_print_mark(order, kind): saves one print. The fingerprint is made here, from the saved lines.
--   * lwb_po_print_info(order ids): per order the number of prints, the last print time / person and
--     changed = the PO lines are not the same as at the last print (reprint needed).
-- Admin, Sales Head (MANAGER), Godown Manager (WAREHOUSE) and Accounts; max 500 orders per call.
-- 12 Nov 2026 (Mohit): tap the 🖨 badge = the full history of that PO: every print and every change
--   (who, role, when, which field old -> new) from the Change History log (lwb_change_log) of the order,
--   its lines, transport and other rows that carry its order_id.
--   * lwb_po_history(order): prints for the four roles above; the changes only for Admin (the Change
--     History log is Admin only).

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_po_prints (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  kind        text NOT NULL DEFAULT 'PO' CHECK (kind IN ('PO', 'CHALLAN')),
  sig         text,
  printed_at  timestamptz NOT NULL DEFAULT now(),
  printed_by  uuid,
  printed_by_name text
);
CREATE INDEX IF NOT EXISTS lwb_po_prints_order ON public.lwb_po_prints (order_id, printed_at DESC);
ALTER TABLE public.lwb_po_prints ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_po_prints FROM PUBLIC, anon, authenticated;

-- Fingerprint of the saved PO lines (same for the same SKU / qty / rate, whatever the line order).
CREATE OR REPLACE FUNCTION public.lwb_po_lines_sig(p_order uuid)
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT md5(coalesce(string_agg(
    lower(trim(coalesce(i.sku_name, ''))) || '|' ||
    coalesce(i.approved_qty, i.ordered_qty, 0)::numeric::text || '|' ||
    coalesce(i.rate, 0)::numeric::text, ';'
    ORDER BY lower(trim(coalesce(i.sku_name, ''))), coalesce(i.approved_qty, i.ordered_qty, 0), coalesce(i.rate, 0)), ''))
  FROM public.order_items i
  WHERE i.order_id = p_order AND coalesce(i.approved_qty, i.ordered_qty, 0) > 0
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_lines_sig(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_po_print_ok()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
    AND lower(trim(coalesce(p.role, ''))) IN ('admin', 'manager', 'warehouse', 'accounts'))
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_print_ok() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_po_print_mark(p_order_id uuid, p_kind text DEFAULT 'PO')
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_kind text := upper(trim(coalesce(p_kind, 'PO')));
  v_name text;
  v_n integer;
BEGIN
  IF NOT public.lwb_po_print_ok() THEN RAISE EXCEPTION 'Only Admin, Sales Head, Godown Manager and Accounts can print POs.'; END IF;
  IF v_kind NOT IN ('PO', 'CHALLAN') THEN v_kind := 'PO'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.id = p_order_id) THEN RAISE EXCEPTION 'PO not found.'; END IF;
  SELECT coalesce(nullif(trim(p.full_name), ''), '') INTO v_name FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.lwb_po_prints(order_id, kind, sig, printed_by, printed_by_name)
  VALUES (p_order_id, v_kind, public.lwb_po_lines_sig(p_order_id), auth.uid(), v_name);
  SELECT count(*) INTO v_n FROM public.lwb_po_prints x WHERE x.order_id = p_order_id;
  RETURN jsonb_build_object('order_id', p_order_id, 'prints', v_n);
END
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_print_mark(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_print_mark(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_po_print_info(p_ids uuid[])
RETURNS TABLE(order_id uuid, prints integer, po_prints integer, challan_prints integer,
  last_at timestamptz, last_by text, changed boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_po_print_ok() THEN RAISE EXCEPTION 'Only Admin, Sales Head, Godown Manager and Accounts can see PO prints.'; END IF;
  IF coalesce(array_length(p_ids, 1), 0) > 500 THEN RAISE EXCEPTION 'At most 500 orders at a time.'; END IF;
  RETURN QUERY
  SELECT x.order_id, count(*)::integer, count(*) FILTER (WHERE x.kind = 'PO')::integer,
    count(*) FILTER (WHERE x.kind = 'CHALLAN')::integer,
    max(x.printed_at),
    (array_agg(x.printed_by_name ORDER BY x.printed_at DESC))[1],
    coalesce((array_agg(x.sig ORDER BY x.printed_at DESC))[1], '') IS DISTINCT FROM public.lwb_po_lines_sig(x.order_id)
  FROM public.lwb_po_prints x
  WHERE x.order_id = ANY (SELECT DISTINCT unnest(p_ids))
  GROUP BY x.order_id;
END
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_print_info(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_print_info(uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_po_history(p_order_id uuid)
RETURNS TABLE(at timestamptz, kind text, who text, who_role text, tbl text, label text, changes jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_admin boolean;
  v_id text := p_order_id::text;
BEGIN
  IF NOT public.lwb_po_print_ok() THEN RAISE EXCEPTION 'Only Admin, Sales Head, Godown Manager and Accounts can see PO history.'; END IF;
  SELECT lower(trim(coalesce(p.role, ''))) = 'admin' INTO v_admin FROM public.user_profiles p WHERE p.id = auth.uid();

  RETURN QUERY
  SELECT x.printed_at, 'PRINT'::text, coalesce(nullif(x.printed_by_name, ''), 'Unknown'), up.role,
    'lwb_po_prints'::text, x.kind, '{}'::jsonb
  FROM public.lwb_po_prints x LEFT JOIN public.user_profiles up ON up.id = x.printed_by
  WHERE x.order_id = p_order_id;

  IF NOT coalesce(v_admin, false) OR to_regclass('public.lwb_change_log') IS NULL THEN RETURN; END IF;

  RETURN QUERY EXECUTE $q$
    WITH rows AS (
      SELECT 'orders'::text AS t, $1 AS r
      UNION SELECT 'order_items', i.id::text FROM public.order_items i WHERE i.order_id::text = $1
      UNION SELECT l.table_name, l.row_id FROM public.lwb_change_log l
        WHERE l.table_name <> 'lwb_po_prints' AND l.row_id IS NOT NULL
          AND (l.changes->>'order_id' = $1 OR l.changes->'order_id'->>1 = $1)
    )
    SELECT l.changed_at, l.action, coalesce(nullif(trim(u.full_name), ''), 'Unknown'), l.user_role,
      l.table_name, l.row_label, l.changes
    FROM public.lwb_change_log l
    JOIN rows ON rows.t = l.table_name AND rows.r = l.row_id
    LEFT JOIN public.user_profiles u ON u.id = l.user_id
    ORDER BY l.changed_at DESC LIMIT 300 $q$ USING v_id;
END
$fn$;
REVOKE ALL ON FUNCTION public.lwb_po_history(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_po_history(uuid) TO authenticated;

COMMIT;
