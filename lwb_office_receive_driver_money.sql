-- LUXURY WRIST BRAND ERP — ACCOUNTS RECEIVES THE DRIVER'S MONEY (CASH + UPI WITH BANK CHECK)
--
-- RUN ONCE in Supabase SQL Editor (after lwb_driver_payment_setup.sql and
-- lwb_order_flow_popups_setup.sql). Safe to run again.
-- Mohit asked (28 Oct 2026): on Driver Collections, Accounts must be able to
--   1. enter the cash the driver hands over (counted by notes), even when the driver
--      did not enter any payment in his app;
--   2. for UPI / bank, see the driver's screenshot AND enter the UTR / bank reference
--      after checking it in the bank, before it counts as received;
--   3. know which driver gave how much, when, and who received it.
--   4. Accounts gets "Delivered — receive money from driver" as soon as the delivery is reported.
-- Saving here = money received and verified. The driver gets "Office received Rs X from you",
-- Sales Head and Salesman get "Payment Received". The cash part shows in Cashbook as before.
-- No party ledger, Tally, stock or GST entry is made here.

BEGIN;

ALTER TABLE public.lwb_delivery_reports
  ADD COLUMN IF NOT EXISTS bank_ref text CHECK (bank_ref IS NULL OR length(bank_ref) <= 150),
  ADD COLUMN IF NOT EXISTS office_received boolean NOT NULL DEFAULT false;

-- ---------------------------------------------------------------------------
-- Accounts / Admin: money received from the driver for one delivered order.
-- p_cash_notes: {"500":10,"200":5,"coins":35}; p_bank_ref is required when p_online_amount > 0.
-- Replaces whatever the driver entered (if anything) with what the office actually got.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_office_receive_driver_payment(
  p_report_id uuid, p_cash_notes jsonb, p_online_amount numeric, p_online_mode text,
  p_bank_ref text, p_note text DEFAULT NULL
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
  v_ref text := NULLIF(btrim(COALESCE(p_bank_ref,'')),'');
  v_note text := NULLIF(btrim(COALESCE(p_note,'')),'');
  v_total numeric; v_bill record; v_out numeric;
  v_order record; v_by text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin')) THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can receive the driver''s money';
  END IF;
  SELECT * INTO v_rep FROM public.lwb_delivery_reports WHERE id = p_report_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Delivery report not found'; END IF;
  IF v_rep.delivery_status = 'NOT_DELIVERED' THEN RAISE EXCEPTION 'This order was not delivered'; END IF;
  IF v_rep.payment_status = 'VERIFIED' THEN RAISE EXCEPTION 'This payment is already received and verified'; END IF;

  FOR v_key IN SELECT jsonb_object_keys(COALESCE(p_cash_notes,'{}'::jsonb)) LOOP
    IF v_key NOT IN ('500','200','100','50','20','10','coins') THEN RAISE EXCEPTION 'Unknown note %', v_key; END IF;
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
    RAISE EXCEPTION 'Cash of Rs 2 lakh or more from one party needs compliance review. Do not take it here.';
  END IF;

  IF v_online < 0 OR v_online > 99999999 THEN RAISE EXCEPTION 'Check the UPI / bank amount'; END IF;
  IF v_online = 0 THEN
    v_mode := NULL; v_ref := NULL;
  ELSE
    IF v_mode NOT IN ('UPI','BANK','CHEQUE') THEN RAISE EXCEPTION 'Select UPI, Bank or Cheque'; END IF;
    IF length(COALESCE(v_ref,'')) < 4 THEN
      RAISE EXCEPTION 'Check the UPI / bank payment in the bank and enter its UTR / reference number';
    END IF;
    IF EXISTS (SELECT 1 FROM public.lwb_delivery_reports d
               WHERE d.id <> p_report_id AND upper(btrim(d.bank_ref)) = upper(v_ref)) THEN
      RAISE EXCEPTION 'This UTR / reference is already used on another order';
    END IF;
  END IF;
  IF length(COALESCE(v_note,'')) > 300 THEN RAISE EXCEPTION 'Note is too long'; END IF;

  v_total := v_cash + v_online;
  IF v_total <= 0 THEN RAISE EXCEPTION 'Enter the cash or UPI amount received'; END IF;
  SELECT * INTO v_bill FROM public.lwb_order_bill_numbers(v_rep.order_id);
  IF v_total > v_bill.gross + 1 THEN
    RAISE EXCEPTION 'Rs % is more than the bill Rs %', v_total, v_bill.gross;
  END IF;
  v_out := GREATEST(0, v_bill.net - v_total);

  UPDATE public.lwb_delivery_reports SET
    cash_reported = v_total,
    payment_mode = CASE WHEN v_cash > 0 AND v_online > 0 THEN 'CASH+' || v_mode
                        WHEN v_cash > 0 THEN 'CASH' ELSE v_mode END,
    collection_review_status = 'PENDING_OFFICE',
    cash_amount = v_cash, cash_notes = v_notes,
    online_amount = v_online, online_mode = v_mode,
    online_reference = CASE WHEN v_online > 0 THEN COALESCE(online_reference, v_ref) END,
    online_photo_paths = CASE WHEN v_online > 0 THEN online_photo_paths ELSE '{}' END,
    bank_ref = v_ref, office_received = true,
    payment_saved_at = COALESCE(payment_saved_at, now()),
    payment_status = 'VERIFIED', payment_reviewed_by = auth.uid(), payment_reviewed_at = now(),
    payment_review_note = v_note
  WHERE id = p_report_id;

  UPDATE public.erp_notifications SET is_read = true
  WHERE order_id = v_rep.order_id AND notification_type = 'DELIVERY_COLLECTION' AND is_read = false;

  SELECT o.order_no, o.customer_name INTO v_order FROM public.orders o WHERE o.id = v_rep.order_id;
  SELECT full_name INTO v_by FROM public.user_profiles WHERE id = auth.uid();
  IF v_rep.driver_user_id IS NOT NULL THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    VALUES (v_rep.driver_user_id, 'Payment Received by Office',
      COALESCE(v_by,'Accounts') || ' received Rs ' || to_char(v_total,'FM9999999990.00') || ' from you for ' ||
        COALESCE(v_order.order_no,'order') || ' (' || COALESCE(v_order.customer_name,'') || ')' ||
        CASE WHEN v_cash > 0 THEN ' · Cash Rs ' || to_char(v_cash,'FM9999999990.00') ELSE '' END ||
        CASE WHEN v_online > 0 THEN ' · ' || v_mode || ' Rs ' || to_char(v_online,'FM9999999990.00') ELSE '' END ||
        CASE WHEN v_out > 0 THEN ' · Still due Rs ' || to_char(v_out,'FM9999999990.00') ELSE '' END || '.',
      'DELIVERY_COLLECTION_VERIFIED', v_rep.order_id);
  END IF;

  RETURN jsonb_build_object('received', v_total, 'cash', v_cash, 'online', v_online, 'outstanding', v_out);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_office_receive_driver_payment(uuid,jsonb,numeric,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_office_receive_driver_payment(uuid,jsonb,numeric,text,text,text) TO authenticated;

-- ---------------------------------------------------------------------------
-- The driver's own "collected" popup is not needed when the office entered the money itself.
-- (Same as lwb_order_flow_popups_setup.sql, plus that one check.)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_flow_driver_money()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_driver text; v_amt text;
BEGIN
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  SELECT full_name INTO v_driver FROM public.user_profiles WHERE id = NEW.driver_user_id;
  v_amt := 'Rs ' || to_char(coalesce(NEW.cash_reported,0),'FM9999999990.00');

  IF NEW.payment_saved_at IS NOT NULL AND coalesce(NEW.cash_reported,0) > 0
     AND NEW.payment_status IS DISTINCT FROM 'VERIFIED'
     AND (TG_OP = 'INSERT' OR NEW.payment_saved_at IS DISTINCT FROM OLD.payment_saved_at) THEN
    PERFORM public.lwb_flow_send(NEW.order_id, ARRAY['salesman','godown'], 'Driver Collected Payment',
      concat_ws(' · ', v_o.order_no, v_o.customer_name, coalesce(v_driver,'Driver') || ' collected ' || v_amt,
        nullif(NEW.payment_mode,'')) || '. Accounts will verify it when the vehicle is back.',
      'DELIVERY_COLLECTION_INFO', true);
  END IF;

  IF TG_OP = 'UPDATE' AND NEW.payment_status = 'VERIFIED' AND OLD.payment_status IS DISTINCT FROM 'VERIFIED' THEN
    PERFORM public.lwb_flow_send(NEW.order_id, ARRAY['manager','salesman'], 'Payment Received',
      concat_ws(' · ', v_o.order_no, v_o.customer_name, v_amt || ' received and verified by Accounts') || '.',
      'DELIVERY_COLLECTION_RECEIVED', true);
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_flow_driver_money() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Delivered → Accounts at once: "money on the way, receive it from the driver",
-- even before the driver enters any payment. Same type as the driver's payment note
-- (DELIVERY_COLLECTION), so it keeps popping up until the money is received / verified,
-- and the driver's own payment entry replaces it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_flow_delivered_collect()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_driver text; v_bill record;
BEGIN
  IF NEW.delivery_status = 'NOT_DELIVERED' OR coalesce(NEW.cash_reported,0) > 0 THEN RETURN NEW; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = NEW.order_id;
  SELECT full_name INTO v_driver FROM public.user_profiles WHERE id = NEW.driver_user_id;
  SELECT * INTO v_bill FROM public.lwb_order_bill_numbers(NEW.order_id);
  PERFORM public.lwb_flow_send(NEW.order_id, ARRAY['accounts'], 'Delivered — Receive Money from Driver',
    coalesce(v_driver,'Driver') || ' delivered ' || coalesce(v_o.order_no,'order') || ' (' || coalesce(v_o.customer_name,'') || '). ' ||
    'To collect Rs ' || to_char(coalesce(v_bill.net,0),'FM9999999990.00') ||
    '. When the driver hands over the money, tap Receive money on Driver Collections.',
    'DELIVERY_COLLECTION', true);
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_flow_delivered_collect() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_flow_delivered_collect ON public.lwb_delivery_reports;
CREATE TRIGGER trg_lwb_flow_delivered_collect
AFTER INSERT ON public.lwb_delivery_reports
FOR EACH ROW EXECUTE FUNCTION public.lwb_flow_delivered_collect();

-- ---------------------------------------------------------------------------
-- Driver Collections list: same as before + bank_ref, office_received, received_by, driver_entered.
-- ---------------------------------------------------------------------------
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
             d.bank_ref, d.office_received,
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
REVOKE ALL ON FUNCTION public.lwb_office_list_driver_collections(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_office_list_driver_collections(text) TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Check: 4 rows, all ok = true
SELECT 'bank_ref_column' AS item, EXISTS (SELECT 1 FROM information_schema.columns
  WHERE table_schema='public' AND table_name='lwb_delivery_reports' AND column_name='bank_ref') AS ok
UNION ALL SELECT 'office_receive_function', to_regprocedure('public.lwb_office_receive_driver_payment(uuid,jsonb,numeric,text,text,text)') IS NOT NULL
UNION ALL SELECT 'delivered_popup_to_accounts', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_flow_delivered_collect')
UNION ALL SELECT 'collections_list_function', to_regprocedure('public.lwb_office_list_driver_collections(text)') IS NOT NULL;
