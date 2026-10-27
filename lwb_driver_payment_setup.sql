-- LUXURY WRIST BRAND ERP — DRIVER PAYMENT (CASH NOTES + UPI PHOTO) AND RETURN FOLLOW-UP
--
-- RUN ONCE in Supabase SQL Editor, after lwb_return_notification_cleanup.sql. Safe to run again.
--
-- PAYMENT
-- 1. The driver counts cash by notes (500 x 10, 200 x 5 ... + coins); the total is worked out here.
-- 2. UPI / Bank / Cheque: amount + photo of the payment screen (required) + optional UTR.
-- 3. Whatever is not paid stays OUTSTANDING (bill after approved returns - cash - UPI).
-- 4. Accounts, Admin and Sales Head get a notification and VERIFY or REJECT on Driver Collections.
--    Until verified the driver can change the payment; after a reject the driver corrects it.
-- RETURN FOLLOW-UP
-- 5. When a return is APPROVED, the godown team (warehouse) gets "receive the goods" and taps
--    "Goods received" on Driver Returns; Accounts / Admin get "return amount cut, collect Rs X".
--
-- Nothing is posted to the party ledger, payments, Tally, stock or GST here.
-- Party ledger posting stays on Payment Collection, as before.

BEGIN;

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_delivery_reports
  ADD COLUMN IF NOT EXISTS cash_amount numeric(14,2),
  ADD COLUMN IF NOT EXISTS cash_notes jsonb,
  ADD COLUMN IF NOT EXISTS online_amount numeric(14,2),
  ADD COLUMN IF NOT EXISTS online_mode text,
  ADD COLUMN IF NOT EXISTS online_reference text,
  ADD COLUMN IF NOT EXISTS online_photo_paths text[] NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS payment_saved_at timestamptz,
  ADD COLUMN IF NOT EXISTS payment_status text,
  ADD COLUMN IF NOT EXISTS payment_reviewed_by uuid,
  ADD COLUMN IF NOT EXISTS payment_reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS payment_review_note text;

-- Payment mode may now be cash + online together.
DO $$
DECLARE c text;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
           WHERE conrelid = 'public.lwb_delivery_reports'::regclass AND contype = 'c'
             AND pg_get_constraintdef(oid) ILIKE '%payment_mode%'
             AND pg_get_constraintdef(oid) ILIKE '%CHEQUE%'
             AND pg_get_constraintdef(oid) NOT ILIKE '%cash_reported%' LOOP
    EXECUTE format('ALTER TABLE public.lwb_delivery_reports DROP CONSTRAINT %I', c);
  END LOOP;
  FOR c IN SELECT conname FROM pg_constraint
           WHERE conrelid = 'public.lwb_delivery_reports'::regclass AND contype = 'c'
             AND pg_get_constraintdef(oid) ILIKE '%payment_status%' LOOP
    EXECUTE format('ALTER TABLE public.lwb_delivery_reports DROP CONSTRAINT %I', c);
  END LOOP;
END $$;
ALTER TABLE public.lwb_delivery_reports
  ADD CONSTRAINT lwb_delivery_reports_payment_mode_check
  CHECK (payment_mode IN ('CASH','UPI','BANK','CHEQUE','CASH+UPI','CASH+BANK','CASH+CHEQUE'));
ALTER TABLE public.lwb_delivery_reports
  ADD CONSTRAINT lwb_delivery_reports_payment_status_check
  CHECK (payment_status IN ('PENDING','VERIFIED','REJECTED'));

ALTER TABLE public.lwb_driver_delivery_returns
  ADD COLUMN IF NOT EXISTS goods_received_at timestamptz,
  ADD COLUMN IF NOT EXISTS goods_received_by uuid,
  ADD COLUMN IF NOT EXISTS goods_received_note text;

-- ---------------------------------------------------------------------------
-- Bill numbers of one order: gross (loaded x ERP rate), approved / pending returns.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_order_bill_numbers(p_order_id uuid)
RETURNS TABLE(gross numeric, approved_return numeric, pending_return numeric, net numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $$
  WITH g AS (
    SELECT COALESCE(SUM(ROUND(COALESCE(i.loaded_qty,0)::numeric * COALESCE(i.rate,0)::numeric,2)),0) AS gross
    FROM public.order_items i WHERE i.order_id = p_order_id AND COALESCE(i.loaded_qty,0) > 0),
  r AS (
    SELECT COALESCE(SUM(x.total_return_amount) FILTER (WHERE x.status = 'APPROVED'),0) AS ok,
           COALESCE(SUM(x.total_return_amount) FILTER (WHERE x.status = 'PENDING_OFFICE'),0) AS wait
    FROM public.lwb_driver_delivery_returns x WHERE x.order_id = p_order_id)
  SELECT g.gross, r.ok, r.wait, GREATEST(0, g.gross - r.ok) FROM g, r;
$$;
REVOKE ALL ON FUNCTION public.lwb_order_bill_numbers(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Driver: save (or change) the payment of a delivered order.
-- p_cash_notes: {"500":10,"200":5,"100":0,"50":0,"20":0,"10":0,"coins":35}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_driver_save_payment(
  p_order_id uuid, p_cash_notes jsonb, p_online_amount numeric, p_online_mode text,
  p_online_reference text, p_online_photo_paths text[]
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_rep public.lwb_delivery_reports%ROWTYPE;
  v_notes jsonb := '{}'::jsonb;
  v_key text; v_cnt numeric; v_cash numeric := 0;
  v_online numeric := round(COALESCE(p_online_amount,0),2);
  v_mode text := upper(btrim(COALESCE(p_online_mode,'')));
  v_ref text := NULLIF(btrim(COALESCE(p_online_reference,'')),'');
  v_paths text[];
  v_prefix text;
  v_path text;
  v_total numeric;
  v_bill record;
  v_out numeric;
  v_order record;
  v_driver text;
BEGIN
  IF auth.uid() IS NULL OR p_order_id IS NULL THEN RAISE EXCEPTION 'Login again and retry'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) = 'driver') THEN
    RAISE EXCEPTION 'Only the driver can enter the payment';
  END IF;
  SELECT * INTO v_rep FROM public.lwb_delivery_reports d WHERE d.order_id = p_order_id FOR UPDATE;
  IF NOT FOUND OR v_rep.driver_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Submit the delivery report of this order first';
  END IF;
  IF v_rep.payment_status = 'VERIFIED' THEN
    RAISE EXCEPTION 'Office already verified this payment. Ask Accounts to change it.';
  END IF;

  -- Cash = notes x count + coins.
  FOR v_key IN SELECT jsonb_object_keys(COALESCE(p_cash_notes,'{}'::jsonb)) LOOP
    IF v_key NOT IN ('500','200','100','50','20','10','coins') THEN
      RAISE EXCEPTION 'Unknown note %', v_key;
    END IF;
    BEGIN
      v_cnt := COALESCE(NULLIF(p_cash_notes->>v_key,''),'0')::numeric;
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter a number for %', v_key;
    END;
    IF v_cnt < 0 OR v_cnt > 100000 OR (v_key <> 'coins' AND v_cnt <> trunc(v_cnt)) THEN
      RAISE EXCEPTION 'Check the count of %', v_key;
    END IF;
    IF v_cnt > 0 THEN
      v_notes := v_notes || jsonb_build_object(v_key, v_cnt);
      v_cash := v_cash + CASE WHEN v_key = 'coins' THEN round(v_cnt,2) ELSE v_key::numeric * v_cnt END;
    END IF;
  END LOOP;
  IF v_cash >= 200000 THEN
    RAISE EXCEPTION 'Cash of Rs 2 lakh or more needs compliance review. Do not collect it in this module.';
  END IF;

  -- Online (UPI / Bank / Cheque): amount + photo of the payment screen.
  IF v_online < 0 OR v_online > 99999999 THEN RAISE EXCEPTION 'Check the UPI amount'; END IF;
  SELECT COALESCE(array_agg(DISTINCT btrim(x)), '{}') INTO v_paths
  FROM unnest(COALESCE(p_online_photo_paths,'{}')) AS x WHERE btrim(x) <> '';
  IF v_online = 0 THEN
    v_mode := NULL; v_ref := NULL; v_paths := '{}';
  ELSE
    IF v_mode NOT IN ('UPI','BANK','CHEQUE') THEN RAISE EXCEPTION 'Select UPI, Bank or Cheque'; END IF;
    IF cardinality(v_paths) < 1 THEN RAISE EXCEPTION 'Take a photo of the UPI / payment screen'; END IF;
    IF cardinality(v_paths) > 3 THEN RAISE EXCEPTION 'Maximum 3 payment photos'; END IF;
    IF length(COALESCE(v_ref,'')) > 150 THEN RAISE EXCEPTION 'Reference is too long'; END IF;
    v_prefix := auth.uid()::text || '/' || p_order_id::text || '/';
    FOREACH v_path IN ARRAY v_paths LOOP
      IF left(v_path, length(v_prefix)) <> v_prefix OR position('..' IN v_path) > 0
         OR NOT EXISTS (SELECT 1 FROM storage.objects o
                        WHERE o.bucket_id = 'lwb-delivery-pod' AND o.name = v_path) THEN
        RAISE EXCEPTION 'Payment photo not found. Take the photo again.';
      END IF;
    END LOOP;
  END IF;

  v_total := v_cash + v_online;
  IF v_rep.delivery_status = 'NOT_DELIVERED' AND v_total > 0 THEN
    RAISE EXCEPTION 'Order was not delivered, so no payment can be entered';
  END IF;
  SELECT * INTO v_bill FROM public.lwb_order_bill_numbers(p_order_id);
  IF v_total > v_bill.gross + 1 THEN
    RAISE EXCEPTION 'Payment Rs % is more than the bill Rs %', v_total, v_bill.gross;
  END IF;
  v_out := GREATEST(0, v_bill.net - v_total);

  UPDATE public.lwb_delivery_reports SET
    cash_reported = v_total,
    payment_mode = CASE WHEN v_total = 0 THEN NULL
                        WHEN v_cash > 0 AND v_online > 0 THEN 'CASH+' || v_mode
                        WHEN v_cash > 0 THEN 'CASH' ELSE v_mode END,
    payment_reference = CASE WHEN v_total = 0 THEN NULL ELSE v_ref END,
    collection_review_status = CASE WHEN v_total > 0 THEN 'PENDING_OFFICE' ELSE 'NO_COLLECTION' END,
    cash_amount = v_cash, cash_notes = v_notes,
    online_amount = v_online, online_mode = v_mode, online_reference = v_ref, online_photo_paths = v_paths,
    payment_saved_at = now(), payment_status = 'PENDING',
    payment_reviewed_by = NULL, payment_reviewed_at = NULL, payment_review_note = NULL
  WHERE id = v_rep.id;

  -- Tell Accounts, Admin and Sales Head (replaces the older unread note of this order).
  SELECT o.order_no, o.customer_name INTO v_order FROM public.orders o WHERE o.id = p_order_id;
  SELECT full_name INTO v_driver FROM public.user_profiles WHERE id = auth.uid();
  DELETE FROM public.erp_notifications n
  WHERE n.order_id = p_order_id AND n.notification_type = 'DELIVERY_COLLECTION' AND n.is_read = false;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, 'Driver Collection - Verify',
    COALESCE(v_driver,'Driver') || ' on ' || COALESCE(v_order.order_no,'order') || ' (' || COALESCE(v_order.customer_name,'') || '): ' ||
    'Collected Rs ' || to_char(v_total,'FM9999999990.00') ||
    CASE WHEN v_total = 0 THEN ' (nothing paid)'
         ELSE ' = Cash Rs ' || to_char(v_cash,'FM9999999990.00') ||
              CASE WHEN v_online > 0 THEN ' + ' || v_mode || ' Rs ' || to_char(v_online,'FM9999999990.00') ELSE '' END END ||
    '. Outstanding Rs ' || to_char(v_out,'FM9999999990.00') || '.',
    'DELIVERY_COLLECTION', p_order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','accounts','manager');

  RETURN jsonb_build_object('order_id', p_order_id, 'cash', v_cash, 'online', v_online, 'collected', v_total,
    'net', v_bill.net, 'outstanding', v_out, 'payment_status', 'PENDING');
END;
$fn$;

-- Delivery report + payment in one save (the old RPC stays for the delivery part).
CREATE OR REPLACE FUNCTION public.lwb_driver_submit_delivery_with_payment(
  p_order_id uuid, p_delivery_status text, p_received_by text, p_pod_path text, p_delivery_note text,
  p_cash_notes jsonb, p_online_amount numeric, p_online_mode text, p_online_reference text, p_online_photo_paths text[]
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v jsonb;
BEGIN
  v := public.lwb_driver_submit_delivery(p_order_id, p_delivery_status, p_received_by, p_pod_path,
                                         p_delivery_note, 0, NULL, NULL);
  IF upper(btrim(COALESCE(p_delivery_status,''))) = 'NOT_DELIVERED' THEN RETURN v; END IF;
  RETURN v || public.lwb_driver_save_payment(p_order_id, p_cash_notes, p_online_amount, p_online_mode,
                                             p_online_reference, p_online_photo_paths);
END;
$fn$;

-- Driver: payment of one order (for the form and the order card).
CREATE OR REPLACE FUNCTION public.lwb_driver_order_payment(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_rep public.lwb_delivery_reports%ROWTYPE;
  v_bill record;
  v_reviewer text;
  v_collected numeric;
BEGIN
  SELECT * INTO v_rep FROM public.lwb_delivery_reports d WHERE d.order_id = p_order_id;
  IF NOT ((FOUND AND v_rep.driver_user_id = auth.uid()) OR public.lwb_driver_return_access(p_order_id)) THEN
    RAISE EXCEPTION 'Not your order';
  END IF;
  SELECT * INTO v_bill FROM public.lwb_order_bill_numbers(p_order_id);
  SELECT full_name INTO v_reviewer FROM public.user_profiles WHERE id = v_rep.payment_reviewed_by;
  v_collected := COALESCE(v_rep.cash_reported, 0);
  RETURN jsonb_build_object(
    'gross', v_bill.gross, 'approved_return', v_bill.approved_return, 'pending_return', v_bill.pending_return,
    'net', v_bill.net, 'reported', v_rep.id IS NOT NULL,
    'cash_amount', COALESCE(v_rep.cash_amount, CASE WHEN v_rep.payment_mode = 'CASH' THEN v_rep.cash_reported ELSE 0 END),
    'cash_notes', COALESCE(v_rep.cash_notes, '{}'::jsonb),
    'online_amount', COALESCE(v_rep.online_amount, CASE WHEN v_rep.payment_mode IN ('UPI','BANK','CHEQUE') THEN v_rep.cash_reported ELSE 0 END),
    'online_mode', COALESCE(v_rep.online_mode, CASE WHEN v_rep.payment_mode IN ('UPI','BANK','CHEQUE') THEN v_rep.payment_mode END),
    'online_reference', COALESCE(v_rep.online_reference, v_rep.payment_reference),
    'online_photo_paths', COALESCE(v_rep.online_photo_paths, '{}'),
    'collected', v_collected,
    'outstanding', GREATEST(0, v_bill.net - v_collected),
    'payment_status', COALESCE(v_rep.payment_status, CASE WHEN v_collected > 0 THEN 'PENDING' END),
    'reviewed_by_name', v_reviewer, 'reviewed_at', v_rep.payment_reviewed_at, 'review_note', v_rep.payment_review_note
  );
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Office: Driver Collections list + verify / reject.
-- p_status: PENDING | VERIFIED | REJECTED | OUTSTANDING (any status, outstanding > 0)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_office_payment_viewer()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','accounts','manager'));
$$;
REVOKE ALL ON FUNCTION public.lwb_office_payment_viewer() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_office_payment_viewer() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_office_list_driver_collections(p_status text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_status text := upper(btrim(COALESCE(p_status,'PENDING')));
BEGIN
  IF NOT public.lwb_office_payment_viewer() THEN
    RAISE EXCEPTION 'Only active Admin, Accounts or Sales Head can view driver collections';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(row_to_json(x)::jsonb ORDER BY x.reported_at DESC)
    FROM (
      SELECT d.id AS report_id, d.order_id, o.order_no, o.customer_name AS party_name,
             COALESCE(NULLIF(btrim(dp.full_name),''), a.driver_name, 'Driver') AS driver_name, a.vehicle_no,
             d.reported_at, d.delivery_status, d.payment_saved_at,
             b.gross, b.approved_return, b.pending_return, b.net,
             COALESCE(d.cash_amount, CASE WHEN d.payment_mode = 'CASH' THEN d.cash_reported ELSE 0 END) AS cash_amount,
             COALESCE(d.cash_notes, '{}'::jsonb) AS cash_notes,
             COALESCE(d.online_amount, CASE WHEN d.payment_mode IN ('UPI','BANK','CHEQUE') THEN d.cash_reported ELSE 0 END) AS online_amount,
             COALESCE(d.online_mode, CASE WHEN d.payment_mode IN ('UPI','BANK','CHEQUE') THEN d.payment_mode END) AS online_mode,
             COALESCE(d.online_reference, d.payment_reference) AS online_reference,
             COALESCE(d.online_photo_paths, '{}') AS online_photo_paths,
             d.cash_reported AS collected,
             GREATEST(0, b.net - d.cash_reported) AS outstanding,
             st.status, rp.full_name AS reviewed_by_name, d.payment_reviewed_at AS reviewed_at,
             d.payment_review_note AS review_note
      FROM public.lwb_delivery_reports d
      JOIN public.orders o ON o.id = d.order_id
      LEFT JOIN public.dispatch_assignments a ON a.id = d.assignment_id
      LEFT JOIN public.user_profiles dp ON dp.id = d.driver_user_id
      LEFT JOIN public.user_profiles rp ON rp.id = d.payment_reviewed_by
      CROSS JOIN LATERAL public.lwb_order_bill_numbers(d.order_id) b
      CROSS JOIN LATERAL (SELECT COALESCE(d.payment_status,
               CASE WHEN d.cash_reported > 0 THEN 'PENDING' ELSE 'NONE' END) AS status) st
      WHERE d.delivery_status <> 'NOT_DELIVERED'
        AND d.reported_at >= now() - interval '120 days'
        AND (st.status = v_status OR (v_status = 'OUTSTANDING' AND b.net - d.cash_reported > 0.5))
      ORDER BY d.reported_at DESC
      LIMIT 300
    ) x), '[]'::jsonb);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_review_driver_collection(p_report_id uuid, p_action text, p_note text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_rep public.lwb_delivery_reports%ROWTYPE;
  v_action text := upper(btrim(COALESCE(p_action,'')));
  v_note text := NULLIF(btrim(COALESCE(p_note,'')),'');
  v_status text;
  v_order_no text;
BEGIN
  IF NOT public.lwb_office_payment_viewer() THEN
    RAISE EXCEPTION 'Only active Admin, Accounts or Sales Head can verify a driver collection';
  END IF;
  IF v_action NOT IN ('VERIFY','REJECT') THEN RAISE EXCEPTION 'Action must be VERIFY or REJECT'; END IF;
  IF v_action = 'REJECT' AND length(COALESCE(v_note,'')) < 3 THEN RAISE EXCEPTION 'Rejection reason is required'; END IF;
  IF length(COALESCE(v_note,'')) > 500 THEN RAISE EXCEPTION 'Note is too long'; END IF;

  SELECT * INTO v_rep FROM public.lwb_delivery_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Delivery report not found'; END IF;
  IF COALESCE(v_rep.payment_status, CASE WHEN v_rep.cash_reported > 0 THEN 'PENDING' END) IS DISTINCT FROM 'PENDING' THEN
    RAISE EXCEPTION 'This payment is not waiting for verification';
  END IF;
  v_status := CASE WHEN v_action = 'VERIFY' THEN 'VERIFIED' ELSE 'REJECTED' END;

  UPDATE public.lwb_delivery_reports
  SET payment_status = v_status, payment_reviewed_by = auth.uid(), payment_reviewed_at = now(), payment_review_note = v_note
  WHERE id = p_report_id;

  UPDATE public.erp_notifications SET is_read = true
  WHERE order_id = v_rep.order_id AND notification_type = 'DELIVERY_COLLECTION' AND is_read = false;

  SELECT o.order_no INTO v_order_no FROM public.orders o WHERE o.id = v_rep.order_id;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  VALUES (v_rep.driver_user_id,
    'Payment ' || initcap(v_status),
    'Office ' || lower(v_status) || ' your payment on ' || COALESCE(v_order_no,'order') ||
      ' (Rs ' || to_char(v_rep.cash_reported,'FM9999999990.00') || ')' ||
      CASE WHEN v_status = 'REJECTED' THEN '. Correct it in Driver Delivery' ELSE '' END ||
      COALESCE('. Note: ' || v_note, ''),
    'DELIVERY_COLLECTION_' || v_status, v_rep.order_id);
  RETURN v_status;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Return approved: godown receives the goods, Accounts learn the amount cut.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_return_approved_notify()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_order record;
  v_bill record;
  v_lines text;
  v_by text;
BEGIN
  IF OLD.status <> 'PENDING_OFFICE' OR NEW.status <> 'APPROVED' THEN RETURN NEW; END IF;
  SELECT o.order_no, o.customer_name, a.vehicle_no INTO v_order
  FROM public.orders o LEFT JOIN public.dispatch_assignments a ON a.order_id = o.id
  WHERE o.id = NEW.order_id LIMIT 1;
  SELECT * INTO v_bill FROM public.lwb_order_bill_numbers(NEW.order_id);
  SELECT string_agg(li.qty::text || ' ' || li.uom || ' ' || li.sku_name || ' (' || initcap(li.reason) || ')', ', ' ORDER BY li.sku_name)
    INTO v_lines FROM public.lwb_driver_delivery_return_items li WHERE li.return_id = NEW.id;
  SELECT full_name INTO v_by FROM public.user_profiles WHERE id = NEW.reviewed_by;

  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, 'Receive Return Goods',
    'When vehicle ' || COALESCE(v_order.vehicle_no,'') || ' comes back, receive the return of ' ||
      COALESCE(v_order.order_no,'order') || ' (' || COALESCE(v_order.customer_name,'') || '): ' ||
      COALESCE(v_lines,'') || '. Value Rs ' || to_char(NEW.total_return_amount,'FM9999999990.00') ||
      '. Then tap Goods received on Driver Returns.',
    'DELIVERY_RETURN_RECEIVE', NEW.order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) = 'warehouse';

  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, 'Return Amount Cut',
    'Return Rs ' || to_char(NEW.total_return_amount,'FM9999999990.00') || ' approved on ' ||
      COALESCE(v_order.order_no,'order') || ' (' || COALESCE(v_order.customer_name,'') || ')' ||
      COALESCE(' by ' || v_by, '') || '. Bill Rs ' || to_char(v_bill.gross,'FM9999999990.00') ||
      ', returns cut Rs ' || to_char(v_bill.approved_return,'FM9999999990.00') ||
      ', driver collects Rs ' || to_char(v_bill.net,'FM9999999990.00') || '.',
    'DELIVERY_RETURN_DEDUCTED', NEW.order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('accounts','admin');
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_return_approved_notify() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_return_approved_notify ON public.lwb_driver_delivery_returns;
CREATE TRIGGER trg_lwb_return_approved_notify
AFTER UPDATE OF status ON public.lwb_driver_delivery_returns
FOR EACH ROW EXECUTE FUNCTION public.lwb_return_approved_notify();

CREATE OR REPLACE FUNCTION public.lwb_receive_return_goods(p_return_id uuid, p_note text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_return public.lwb_driver_delivery_returns%ROWTYPE;
  v_note text := NULLIF(btrim(COALESCE(p_note,'')),'');
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('warehouse','manager','admin')) THEN
    RAISE EXCEPTION 'Only Godown, Sales Head or Admin can receive return goods';
  END IF;
  IF length(COALESCE(v_note,'')) > 300 THEN RAISE EXCEPTION 'Note is too long'; END IF;
  SELECT * INTO v_return FROM public.lwb_driver_delivery_returns WHERE id = p_return_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Return not found'; END IF;
  IF v_return.status <> 'APPROVED' THEN RAISE EXCEPTION 'Only approved returns are received'; END IF;
  IF v_return.goods_received_at IS NOT NULL THEN RAISE EXCEPTION 'Goods already received'; END IF;
  UPDATE public.lwb_driver_delivery_returns
  SET goods_received_at = now(), goods_received_by = auth.uid(), goods_received_note = v_note
  WHERE id = p_return_id;
  UPDATE public.erp_notifications SET is_read = true
  WHERE order_id = v_return.order_id AND notification_type = 'DELIVERY_RETURN_RECEIVE' AND is_read = false
    AND created_at >= v_return.reviewed_at AND created_at < v_return.reviewed_at + interval '5 seconds';
  RETURN 'RECEIVED';
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_office_return_receipts(p_return_ids uuid[])
RETURNS TABLE(return_id uuid, received_at timestamptz, received_by_name text, received_note text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
#variable_conflict use_column
BEGIN
  IF NOT public.lwb_return_photo_viewer() THEN RAISE EXCEPTION 'Only active office staff can view this'; END IF;
  RETURN QUERY
    SELECT r.id, r.goods_received_at, p.full_name, r.goods_received_note
    FROM public.lwb_driver_delivery_returns r
    LEFT JOIN public.user_profiles p ON p.id = r.goods_received_by
    WHERE r.id = ANY(COALESCE(p_return_ids,'{}')) AND r.goods_received_at IS NOT NULL;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Cashbook: only the CASH part of a driver payment is Cash In.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_cashbook_driver_cash(p_days integer, p_key text)
RETURNS TABLE (report_id uuid, report_date date, report_time text, order_no text, party text,
               driver text, amount numeric, mode text, reference text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  RETURN QUERY
  SELECT dr.id,
         timezone('Asia/Kolkata', dr.reported_at)::date,
         to_char(timezone('Asia/Kolkata', dr.reported_at), 'HH24:MI'),
         o.order_no::text,
         btrim(o.customer_name::text),
         coalesce(nullif(btrim(a.driver_name::text), ''), nullif(btrim(p.full_name), ''), 'Driver'),
         CASE WHEN dr.cash_amount IS NOT NULL THEN dr.cash_amount ELSE dr.cash_reported END,
         CASE WHEN dr.cash_amount IS NOT NULL THEN 'CASH' ELSE coalesce(dr.payment_mode, 'CASH') END,
         coalesce(dr.payment_reference, '')
  FROM public.lwb_delivery_reports dr
  JOIN public.orders o ON o.id = dr.order_id
  LEFT JOIN public.dispatch_assignments a ON a.id = dr.assignment_id
  LEFT JOIN public.user_profiles p ON p.id = dr.driver_user_id
  WHERE CASE WHEN dr.cash_amount IS NOT NULL THEN dr.cash_amount ELSE dr.cash_reported END > 0
    AND dr.reported_at >= now() - make_interval(days => least(greatest(coalesce(p_days, 15), 1), 90))
  ORDER BY dr.reported_at DESC;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_driver_save_payment(uuid,jsonb,numeric,text,text,text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_driver_submit_delivery_with_payment(uuid,text,text,text,text,jsonb,numeric,text,text,text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_driver_order_payment(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_office_list_driver_collections(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_review_driver_collection(uuid,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_receive_return_goods(uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_office_return_receipts(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_driver_save_payment(uuid,jsonb,numeric,text,text,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_driver_submit_delivery_with_payment(uuid,text,text,text,text,jsonb,numeric,text,text,text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_driver_order_payment(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_office_list_driver_collections(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_review_driver_collection(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_receive_return_goods(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_office_return_receipts(uuid[]) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Expected: 4 rows, all true.
SELECT 'payment columns' AS item, EXISTS (SELECT 1 FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'lwb_delivery_reports' AND column_name = 'cash_notes') AS ok
UNION ALL SELECT 'driver payment save', to_regprocedure('public.lwb_driver_submit_delivery_with_payment(uuid,text,text,text,text,jsonb,numeric,text,text,text[])') IS NOT NULL
UNION ALL SELECT 'office collections', to_regprocedure('public.lwb_office_list_driver_collections(text)') IS NOT NULL
UNION ALL SELECT 'return goods received', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_return_approved_notify');
