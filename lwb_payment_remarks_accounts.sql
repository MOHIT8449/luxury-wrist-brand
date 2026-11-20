-- Payment remarks: Accounts can write too (Mohit, 20 Nov 2026)
-- Party Due popup on PO / Sales: Admin, Sales Head and Accounts write a remark (Accounts answers e.g.
-- "payment aa gaya"). Same function as lwb_payment_remarks_setup.sql, only the role check changes.
-- The bell still goes to Accounts, Cashier, Admin and Sales Head, never to the writer.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_payment_remark_add(p_party text, p_order_id uuid DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text; v_name text;
  v_party text := left(nullif(btrim(coalesce(p_party,'')),''), 200);
  v_note text := left(nullif(btrim(coalesce(p_note,'')),''), 300);
  v_no text; v_bill text;
  v_row public.lwb_payment_remarks;
BEGIN
  SELECT lower(btrim(p.role)), coalesce(nullif(btrim(p.full_name),''), 'User') INTO v_role, v_name
  FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
  IF v_role IS NULL OR v_role NOT IN ('admin','manager','accounts') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can write a remark.';
  END IF;
  IF v_note IS NULL THEN RAISE EXCEPTION 'Write the remark first.'; END IF;
  IF p_order_id IS NOT NULL THEN
    SELECT o.order_no::text, coalesce(v_party, btrim(o.customer_name::text)) INTO v_no, v_party FROM public.orders o WHERE o.id = p_order_id;
    IF v_no IS NULL THEN RAISE EXCEPTION 'PO not found.'; END IF;
    SELECT t.invoice_no INTO v_bill FROM public.lwb_tally_invoices t WHERE t.order_id = p_order_id;
  END IF;
  IF v_party IS NULL THEN RAISE EXCEPTION 'Choose a party.'; END IF;

  INSERT INTO public.lwb_payment_remarks (party, order_id, note, created_by, created_by_name, created_by_role)
  VALUES (v_party, p_order_id, v_note, auth.uid(), v_name, v_role)
  RETURNING * INTO v_row;

  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, left('Payment remark: ' || v_party, 200),
         left(concat_ws(' · ', v_no, 'Bill ' || v_bill, v_note, 'by ' || v_name), 600), 'PAYMENT_FOLLOWUP', p_order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('accounts','cashier','admin','manager') AND p.id IS DISTINCT FROM auth.uid();

  RETURN jsonb_build_object('id', v_row.id, 'party', v_row.party, 'order_id', v_row.order_id, 'order_no', v_no,
                            'note', v_row.note, 'by_name', v_row.created_by_name, 'by_role', v_row.created_by_role,
                            'created_at', v_row.created_at);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_payment_remark_add(text,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_payment_remark_add(text,uuid,text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'write remark' AS item, (to_regprocedure('public.lwb_payment_remark_add(text,uuid,text)') IS NOT NULL)::text AS ok;
