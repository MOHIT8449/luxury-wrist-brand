-- LUXURY WRIST BRAND ERP — SALES HEAD MAY APPROVE A PO CHANGE TOO (16 Nov 2026)
--
-- Runs by itself when merged to main (after lwb_bill_change_setup.sql). Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (16 Nov 2026): a PO qty / rate / SKU change sent by Accounts from Billing & Outstanding
-- (± Qty / Items, e.g. "Less qty reached" instead of a Return) can be approved by Admin OR Sales Head
-- (MANAGER role). Same rules as before, only who may decide changes:
--   * lwb_bill_change_approver(): active Admin or Sales Head.
--   * lwb_bill_change_decide: Admin or Sales Head approves (the change is applied, stock follows) or sends back.
--   * lwb_bill_change_list / lwb_bill_change_items: Sales Head can read them too (Approvals page and its popup).
--   * The "OK needed" bell that goes to Admin now goes to every active Sales Head as well.
-- Accounts still cannot approve; a change made by Admin is still saved at once (lwb_bill_change_request unchanged).

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_bill_change_approver()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','manager'));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_bill_change_items(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o record;
  v_col text;
  v_skus jsonb := '[]'::jsonb;
BEGIN
  IF NOT (public.lwb_tally_staff() OR public.lwb_bill_change_approver()) THEN RAISE EXCEPTION 'Active Admin / Accounts / Sales Head role required.'; END IF;
  SELECT o.id, o.order_no::text AS order_no, btrim(o.customer_name::text) AS party, lower(btrim(coalesce(o.status::text,''))) AS status
    INTO v_o FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  v_col := public.lwb_bill_qty_col(v_o.status);
  IF to_regclass('public.sku_master') IS NOT NULL THEN
    EXECUTE 'SELECT coalesce(jsonb_agg(DISTINCT btrim(s.sku_name::text)), ''[]''::jsonb) FROM public.sku_master s
             WHERE s.is_active IS TRUE AND nullif(btrim(s.sku_name::text),'''') IS NOT NULL' INTO v_skus;
  END IF;
  RETURN jsonb_build_object(
    'order_id', v_o.id, 'order_no', v_o.order_no, 'party', v_o.party, 'status', v_o.status, 'qty_col', v_col,
    'items', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                'item_id', i.id::text, 'sku_name', btrim(i.sku_name::text),
                'ordered', coalesce(i.ordered_qty,0), 'approved', coalesce(i.approved_qty, i.ordered_qty, 0),
                'loaded', i.loaded_qty, 'rate', coalesce(i.rate,0),
                'qty', CASE WHEN v_col = 'loaded_qty' THEN coalesce(i.loaded_qty,0) ELSE coalesce(i.approved_qty, i.ordered_qty, 0) END)
              ORDER BY i.sku_name), '[]'::jsonb)
              FROM public.order_items i WHERE i.order_id = p_order_id),
    'bill', (SELECT jsonb_build_object('invoice_no', t.invoice_no, 'amount', t.amount, 'bills', t.bills)
             FROM public.lwb_tally_invoices t WHERE t.order_id = p_order_id),
    'changes', (SELECT coalesce(jsonb_agg(to_jsonb(c) - 'requested_by' - 'decided_by' ||
                  jsonb_build_object('by', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = c.requested_by),
                                     'decided', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = c.decided_by))
                  ORDER BY c.requested_at DESC), '[]'::jsonb)
                FROM public.lwb_bill_changes c WHERE c.order_id = p_order_id AND c.status <> 'REPLACED'),
    'skus', v_skus);
END;
$fn$;



CREATE OR REPLACE FUNCTION public.lwb_bill_change_list(p_days integer DEFAULT 30)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT (public.lwb_tally_staff() OR public.lwb_bill_change_approver()) THEN RAISE EXCEPTION 'Active Admin / Accounts / Sales Head role required.'; END IF;
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(c) - 'requested_by' - 'decided_by' || jsonb_build_object(
            'order_no', o.order_no, 'party', btrim(o.customer_name::text),
            'by', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = c.requested_by),
            'decided', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = c.decided_by),
            'mine', c.requested_by = auth.uid())
          ORDER BY (c.status = 'WAITING') DESC, c.requested_at DESC), '[]'::jsonb)
          FROM public.lwb_bill_changes c JOIN public.orders o ON o.id = c.order_id
          WHERE c.status <> 'REPLACED'
            AND (c.status = 'WAITING' OR c.requested_at >= now() - make_interval(days => least(greatest(coalesce(p_days,30),1),400))));
END;
$fn$;


CREATE OR REPLACE FUNCTION public.lwb_bill_change_decide(p_id uuid, p_approve boolean, p_reply text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  c public.lwb_bill_changes%ROWTYPE;
  v_o record;
  v_res jsonb;
BEGIN
  IF NOT public.lwb_bill_change_approver() THEN RAISE EXCEPTION 'Only Admin or Sales Head can approve a PO change.'; END IF;
  SELECT * INTO c FROM public.lwb_bill_changes WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Change not found'; END IF;
  IF c.status <> 'WAITING' THEN RAISE EXCEPTION 'This change is already %.', lower(replace(c.status,'_',' ')); END IF;
  SELECT o.order_no::text AS order_no, btrim(o.customer_name::text) AS party INTO v_o FROM public.orders o WHERE o.id = c.order_id;
  IF p_approve THEN v_res := public.lwb_bill_change_apply(p_id); END IF;
  UPDATE public.lwb_bill_changes
     SET status = CASE WHEN p_approve THEN 'APPROVED' ELSE 'SENT_BACK' END, decided_by = auth.uid(), decided_at = now(),
         reply = left(nullif(btrim(coalesce(p_reply,'')),''),500)
   WHERE id = p_id;
  BEGIN
    UPDATE public.erp_notifications SET is_read = true
     WHERE order_id = c.order_id AND is_read = false AND notification_type = 'BILL_CHANGE_APPROVAL';
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT c.requested_by, CASE WHEN p_approve THEN 'PO change approved' ELSE 'PO change sent back' END,
           v_o.order_no || ' · ' || v_o.party || ' · ' || CASE WHEN c.diff >= 0 THEN '+' ELSE '-' END || 'Rs ' ||
           to_char(abs(c.diff),'FM9999999990.00') || coalesce(' · ' || nullif(btrim(coalesce(p_reply,'')),''), ''),
           CASE WHEN p_approve THEN 'BILL_CHANGE_APPROVED' ELSE 'BILL_CHANGE_SENT_BACK' END, c.order_id
    WHERE c.requested_by IS NOT NULL AND c.requested_by IS DISTINCT FROM auth.uid();
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN jsonb_build_object('id', p_id, 'status', CASE WHEN p_approve THEN 'APPROVED' ELSE 'SENT_BACK' END, 'bill', v_res);
END;
$fn$;

-- Sales Head gets the same "OK needed" bell as Admin (one per Sales Head, per request).
CREATE OR REPLACE FUNCTION public.lwb_bill_change_bell_sales_head()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  -- only the bell statement itself (not our own insert below), and only when it holds an approval bell
  IF pg_trigger_depth() > 1 OR NOT EXISTS (SELECT 1 FROM new_bells x WHERE x.notification_type = 'BILL_CHANGE_APPROVAL') THEN
    RETURN NULL;
  END IF;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, 'PO change — OK needed', n.message, 'BILL_CHANGE_APPROVAL', n.order_id
  FROM (SELECT DISTINCT x.order_id, x.message FROM new_bells x JOIN public.user_profiles a ON a.id = x.user_id
        WHERE x.notification_type = 'BILL_CHANGE_APPROVAL' AND lower(btrim(a.role)) = 'admin') n
  CROSS JOIN public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) = 'manager'
    AND NOT EXISTS (SELECT 1 FROM public.erp_notifications e WHERE e.user_id = p.id AND e.order_id = n.order_id
                    AND e.notification_type = 'BILL_CHANGE_APPROVAL' AND e.is_read = false AND e.message = n.message);
  RETURN NULL;
END;
$fn$;
DROP TRIGGER IF EXISTS lwb_bill_change_bell_sales_head ON public.erp_notifications;
CREATE TRIGGER lwb_bill_change_bell_sales_head AFTER INSERT ON public.erp_notifications
  REFERENCING NEW TABLE AS new_bells FOR EACH STATEMENT EXECUTE FUNCTION public.lwb_bill_change_bell_sales_head();

REVOKE ALL ON FUNCTION public.lwb_bill_change_approver(), public.lwb_bill_change_bell_sales_head() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_bill_change_approver() TO authenticated;

COMMIT;
