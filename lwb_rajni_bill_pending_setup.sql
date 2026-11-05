-- LUXURY WRIST BRAND ERP — RAJNIGANDHA "BILL PENDING" (goods out, delivered, paid, Tally bill not made yet)
--
-- Runs by itself when merged to main (after lwb_quick_slip_setup.sql, lwb_brand_money_setup.sql,
-- lwb_bank_statement_setup.sql and lwb_accounts_fresh_start_setup.sql). Safe to run again.
-- Nothing is dropped or deleted; no bill, stock or old payment amount is changed.
--
-- Mohit (5 Nov 2026): a Rajnigandha slip PO leaves with the driver, gets delivered and the party pays, but
-- Accounts is not always in the office, so the Tally bill is made later from the slip. Until the bill is made
-- the slip must stay highlighted for Accounts as "Bill pending" with its date, like the Coca-Cola Bills to make.
-- Payment by UPI / Bank / Cheque must say into which of our banks it came (every bank has UPI).
--
--   1. lwb_quick_slips.delivered_at / delivered_by: "Delivered" tick on the Rajnigandha Slips page.
--   2. lwb_tally_payments.bank_id (our bank of a UPI / Bank / Cheque line) and slip_order_id (the slip a
--      "Mark paid" payment came for). Party payment (lwb_party_receive) now keeps bank_id of each line.
--      lwb_acc_lines_all() shows that bank, so the bank statement matches it only on that bank.
--   3. lwb_money_banks(): our active banks for the bank picker (Admin, Sales Head, Accounts).
--   4. lwb_quick_slip_delivered(order, on): Admin / Sales Head / Accounts, or the salesman of the order.
--   5. lwb_quick_slip_paid(order, p): Admin / Sales Head / Accounts. A party payment of the slip's brand.
--      No bill yet: it stays the party's advance of that brand, and is set against the bill by itself when
--      Accounts saves the Tally bill (lwb_brand_money_setup.sql). Bill made already: set against bills now.
--   6. lwb_slip_bill_rows() / lwb_slip_bill_pending(): slips without a Tally bill, oldest first, with
--      delivered, paid and days pending. Used by Rajnigandha Slips, Billing & Outstanding and the
--      Accounts Dashboard. lwb_quick_slip_list() gets the same fields plus a 'pending' list.
--   7. Daily 10:00 India time popup to Accounts and Admin (pg_cron): "N Rajnigandha bills pending".

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. New columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_quick_slips ADD COLUMN IF NOT EXISTS delivered_at timestamptz;
ALTER TABLE public.lwb_quick_slips ADD COLUMN IF NOT EXISTS delivered_by uuid;
ALTER TABLE public.lwb_tally_payments ADD COLUMN IF NOT EXISTS bank_id bigint REFERENCES public.lwb_acc_banks(id);
ALTER TABLE public.lwb_tally_payments ADD COLUMN IF NOT EXISTS slip_order_id uuid REFERENCES public.orders(id);
CREATE INDEX IF NOT EXISTS lwb_tally_payments_slip_idx ON public.lwb_tally_payments(slip_order_id) WHERE slip_order_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. Our banks for the bank picker
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_money_banks()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.lwb_quick_slip_role() NOT IN ('admin','manager','accounts') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can see the bank list.';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name,
                     'last4', nullif(right(regexp_replace(coalesce(b.account_no,''), '\D', '', 'g'), 4), '')) ORDER BY b.name)
                   FROM public.lwb_acc_banks b WHERE b.active), '[]'::jsonb);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. Party payment keeps the bank of each UPI / Bank / Cheque line (same as lwb_brand_money_setup.sql
--    otherwise; p_lines[].bank_id is optional so the bank statement booking works as before)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_receive(p_party text, p_pay_date date, p_lines jsonb,
                                                   p_allocs jsonb DEFAULT NULL, p_remark text DEFAULT NULL,
                                                   p_company_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_parent text := public.lwb_party_parent(p_party);
  v_receipt uuid := gen_random_uuid();
  v_remark text := nullif(btrim(coalesce(p_remark,'')),'');
  v_line jsonb; v_mode text; v_amt numeric; v_ref text; v_notes jsonb; v_clean jsonb;
  v_key text; v_cnt numeric; v_total numeric := 0; v_cash numeric := 0;
  v_rows jsonb := '[]'::jsonb; v_modes text[] := '{}';
  v_split numeric := 0; v_adv numeric; v_co uuid; v_bank bigint;
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can enter a party payment';
  END IF;
  IF v_parent = '' THEN RAISE EXCEPTION 'Choose the party'; END IF;
  IF length(v_parent) > 200 THEN RAISE EXCEPTION 'Party name is too long'; END IF;
  IF NOT public.lwb_party_known(v_parent) THEN
    RAISE EXCEPTION 'Party % is not in the Party Master', v_parent;
  END IF;
  IF p_pay_date IS NULL OR p_pay_date > (now() AT TIME ZONE 'Asia/Kolkata')::date + 1 THEN
    RAISE EXCEPTION 'Enter a valid payment date';
  END IF;
  IF length(coalesce(v_remark,'')) > 300 THEN RAISE EXCEPTION 'Remark is too long'; END IF;
  IF jsonb_typeof(p_lines) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'Enter at least one payment mode';
  END IF;
  IF jsonb_array_length(p_lines) > 8 THEN RAISE EXCEPTION 'Too many payment lines'; END IF;
  v_co := public.lwb_party_brand_check(v_parent, p_company_id);

  PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(v_parent)));

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_mode := upper(btrim(coalesce(v_line->>'mode','')));
    v_ref := nullif(btrim(coalesce(v_line->>'ref','')),'');
    v_clean := NULL;
    v_bank := NULL;
    -- Bank of a UPI / Bank / Cheque line (lwb_rajni_bill_pending_setup.sql): optional, must be an active bank.
    IF v_mode <> 'CASH' AND nullif(btrim(coalesce(v_line->>'bank_id','')),'') IS NOT NULL THEN
      BEGIN v_bank := (v_line->>'bank_id')::bigint;
      EXCEPTION WHEN others THEN RAISE EXCEPTION 'Choose the bank';
      END;
      IF NOT EXISTS (SELECT 1 FROM public.lwb_acc_banks k WHERE k.id = v_bank AND k.active) THEN RAISE EXCEPTION 'Bank not found'; END IF;
    END IF;
    IF v_mode NOT IN ('CASH','UPI','BANK','CHEQUE') THEN RAISE EXCEPTION 'Select Cash, UPI, Bank or Cheque'; END IF;
    IF v_mode = ANY(v_modes) THEN RAISE EXCEPTION '% is entered twice. Put it in one line.', initcap(v_mode); END IF;
    v_modes := v_modes || v_mode;
    IF length(coalesce(v_ref,'')) > 100 THEN RAISE EXCEPTION 'Reference is too long'; END IF;
    IF v_mode = 'CASH' AND jsonb_typeof(v_line->'notes') = 'object' AND v_line->'notes' <> '{}'::jsonb THEN
      v_notes := v_line->'notes';
      v_clean := '{}'::jsonb; v_amt := 0;
      FOR v_key IN SELECT jsonb_object_keys(v_notes) LOOP
        IF v_key NOT IN ('500','200','100','50','20','10','coins') THEN RAISE EXCEPTION 'Unknown note %', v_key; END IF;
        BEGIN
          v_cnt := coalesce(nullif(v_notes->>v_key,''),'0')::numeric;
        EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter a number for %', v_key;
        END;
        IF v_cnt < 0 OR v_cnt > 100000 OR (v_key <> 'coins' AND v_cnt <> trunc(v_cnt)) THEN
          RAISE EXCEPTION 'Check the count of %', v_key;
        END IF;
        IF v_cnt > 0 THEN
          v_clean := v_clean || jsonb_build_object(v_key, v_cnt);
          v_amt := v_amt + CASE WHEN v_key = 'coins' THEN round(v_cnt,2) ELSE v_key::numeric * v_cnt END;
        END IF;
      END LOOP;
      IF v_clean = '{}'::jsonb THEN v_clean := NULL; END IF;
    ELSE
      BEGIN
        v_amt := round(coalesce(nullif(v_line->>'amount',''),'0')::numeric, 2);
      EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter the % amount', initcap(v_mode);
      END;
      IF v_mode = 'CHEQUE' AND v_ref IS NULL THEN RAISE EXCEPTION 'Enter the cheque number'; END IF;
      IF v_mode <> 'CASH' AND v_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.lwb_tally_payments x WHERE x.mode = v_mode
            AND upper(btrim(x.ref_no)) = upper(v_ref) AND x.cancelled_at IS NULL) THEN
        RAISE EXCEPTION '% reference % is already entered', initcap(v_mode), v_ref;
      END IF;
    END IF;
    IF v_amt <= 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'Enter the % amount', initcap(v_mode); END IF;
    IF v_mode = 'CASH' THEN v_cash := v_cash + v_amt; END IF;
    v_total := v_total + v_amt;
    v_rows := v_rows || jsonb_build_object('mode', v_mode, 'amount', v_amt, 'ref', v_ref, 'notes', v_clean, 'bank_id', v_bank);
  END LOOP;

  IF v_cash >= 200000 THEN
    RAISE EXCEPTION 'Cash of Rs 2 lakh or more in one receipt is not allowed (Income Tax 269ST).';
  END IF;

  INSERT INTO public.lwb_tally_payments (receipt_id, order_id, party, pay_date, mode, amount, ref_no, cash_notes, remark, created_by, company_id, bank_id)
  SELECT v_receipt, NULL, v_parent, p_pay_date, r->>'mode', (r->>'amount')::numeric, r->>'ref',
         CASE WHEN jsonb_typeof(r->'notes') = 'object' THEN r->'notes' END, v_remark, auth.uid(), v_co, (r->>'bank_id')::bigint
  FROM jsonb_array_elements(v_rows) r;

  IF v_co IS NOT NULL THEN
    v_split := public.lwb_party_apply_b(v_parent, v_co, p_allocs);
  END IF;
  SELECT COALESCE(sum(f.free),0) INTO v_adv FROM public.lwb_party_receipt_free_b(v_parent, v_co) f;
  RETURN jsonb_build_object('receipt_id', v_receipt, 'party', v_parent, 'amount', round(v_total,2),
                            'split', v_split, 'advance', round(v_adv,2), 'company_id', v_co);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. Money lines of the Accounts Dashboard: a party payment shows its bank
--    (copy of lwb_accounts_fresh_start_setup.sql, only the PAYMENT bank_id changed)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_lines_all()
RETURNS TABLE (src text, id uuid, book_date date, at timestamptz, kind text, mode text, amount numeric,
               category text, party text, ref text, remark text, order_no text, bank_id bigint,
               cash_effect numeric, needs_verify boolean, created_by uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  RETURN QUERY
  SELECT 'ENTRY'::text, e.id, e.entry_date, e.created_at, e.kind, e.mode, e.amount,
         coalesce(c.name, CASE e.kind WHEN 'DEPOSIT' THEN 'Bank deposit' WHEN 'WITHDRAW' THEN 'Cash from bank' END),
         e.party, e.ref_no, e.remark, NULL::text, e.bank_id,
         CASE WHEN e.kind = 'IN' AND e.mode = 'CASH' THEN e.amount
              WHEN e.kind = 'OUT' AND e.mode = 'CASH' THEN -e.amount
              WHEN e.kind = 'DEPOSIT' THEN -e.amount
              WHEN e.kind = 'WITHDRAW' THEN e.amount ELSE 0 END,
         (e.kind = 'IN' AND e.mode <> 'CASH') OR e.kind = 'DEPOSIT',
         e.created_by
  FROM public.lwb_acc_entries e
  LEFT JOIN public.lwb_acc_categories c ON c.id = e.category_id
  WHERE e.cancelled_at IS NULL;

  RETURN QUERY
  SELECT 'PAYMENT'::text, p.id, public.lwb_acc_book_day(p.created_at), p.created_at, 'IN'::text, p.mode, p.amount,
         CASE WHEN p.order_id IS NULL THEN 'Party payment' ELSE 'Payment collection' END::text,
         coalesce(btrim(o.customer_name::text), public.lwb_party_parent(p.party)), p.ref_no,
         concat_ws(' · ', 'Tally bill ' || nullif(t.invoice_no,''), 'paid on ' || to_char(p.pay_date,'DD/MM/YYYY'), p.remark),
         o.order_no::text, p.bank_id,
         CASE WHEN p.mode = 'CASH' THEN p.amount ELSE 0 END, p.mode <> 'CASH', p.created_by
  FROM public.lwb_tally_payments p
  LEFT JOIN public.orders o ON o.id = p.order_id
  LEFT JOIN public.lwb_tally_invoices t ON t.order_id = p.order_id
  WHERE p.cancelled_at IS NULL;

  -- Driver money once Office received / verified it. Older rows have only cash_reported + payment_mode.
  RETURN QUERY
  WITH d AS (
    SELECT r.id, r.payment_reviewed_at AS at, r.payment_reviewed_by, btrim(o.customer_name::text) AS party,
           o.order_no::text AS order_no, coalesce(dp.full_name, 'Driver') AS driver,
           coalesce(r.cash_amount, CASE WHEN r.online_amount IS NULL AND coalesce(r.payment_mode,'CASH') = 'CASH'
                                        THEN r.cash_reported ELSE 0 END) AS cash,
           coalesce(r.online_amount, CASE WHEN r.cash_amount IS NULL AND coalesce(r.payment_mode,'CASH') <> 'CASH'
                                          THEN r.cash_reported ELSE 0 END) AS online,
           coalesce(nullif(r.online_mode,''), nullif(regexp_replace(coalesce(r.payment_mode,''), '^CASH\+?', ''), ''), 'UPI') AS omode,
           coalesce(nullif(btrim(r.bank_ref),''), nullif(btrim(r.online_reference),''), nullif(btrim(r.payment_reference),'')) AS ref
    FROM public.lwb_delivery_reports r
    JOIN public.orders o ON o.id = r.order_id
    LEFT JOIN public.user_profiles dp ON dp.id = r.driver_user_id
    WHERE r.payment_status = 'VERIFIED' AND r.payment_reviewed_at IS NOT NULL AND coalesce(r.cash_reported,0) > 0
  )
  SELECT 'DRIVER_CASH'::text, d.id, public.lwb_acc_book_day(d.at), d.at, 'IN'::text, 'CASH'::text, d.cash,
         'Driver collection'::text, d.party, NULL::text, 'Driver ' || d.driver, d.order_no, NULL::bigint,
         d.cash, false, d.payment_reviewed_by
  FROM d WHERE d.cash > 0
  UNION ALL
  SELECT 'DRIVER_ONLINE'::text, d.id, public.lwb_acc_book_day(d.at), d.at, 'IN'::text,
         CASE WHEN d.omode IN ('UPI','BANK','CHEQUE') THEN d.omode ELSE 'UPI' END, d.online,
         'Driver collection'::text, d.party, d.ref, 'Driver ' || d.driver, d.order_no, NULL::bigint,
         0::numeric, true, d.payment_reviewed_by
  FROM d WHERE d.online > 0;

  RETURN QUERY
  SELECT 'OLD'::text, c.id, public.lwb_acc_book_day(coalesce(c.reviewed_at, c.submitted_at)), coalesce(c.reviewed_at, c.submitted_at),
         'IN'::text, CASE WHEN c.payment_mode IN ('CASH','UPI','BANK','CHEQUE') THEN c.payment_mode ELSE 'BANK' END, c.amount,
         'Payment collection'::text, btrim(o.customer_name::text), c.reference_no, c.remarks, o.order_no::text, NULL::bigint,
         CASE WHEN c.payment_mode = 'CASH' THEN c.amount ELSE 0 END, c.payment_mode <> 'CASH', c.submitted_by
  FROM public.lwb_payment_collections c
  LEFT JOIN public.tax_invoices i ON i.id = c.invoice_id
  LEFT JOIN public.orders o ON o.id = i.order_id
  WHERE c.status = 'POSTED';
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_lines_all() FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Slips without a Tally bill (internal, no role check: callers check)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_slip_bill_rows()
RETURNS TABLE (order_id uuid, order_no text, party text, company_id uuid, created_by uuid, slip_at timestamptz,
               slip_date date, driver_name text, vehicle_no text, qty numeric, amount numeric, print_count integer, delivered_at timestamptz,
               paid numeric, pay_modes text, days integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT o.id, o.order_no::text, btrim(o.customer_name::text), s.company_id, o.created_by, s.created_at,
         (s.created_at AT TIME ZONE 'Asia/Kolkata')::date, s.driver_name, s.vehicle_no,
         (SELECT coalesce(sum(coalesce(i.loaded_qty,0)),0) FROM public.order_items i WHERE i.order_id = o.id),
         (SELECT coalesce(sum(round(coalesce(i.loaded_qty,0)::numeric * coalesce(i.rate,0)::numeric, 2)),0)
          FROM public.order_items i WHERE i.order_id = o.id),
         s.print_count, s.delivered_at,
         (SELECT coalesce(sum(p.amount),0) FROM public.lwb_tally_payments p WHERE p.slip_order_id = o.id AND p.cancelled_at IS NULL),
         (SELECT string_agg(DISTINCT p.mode, ' + ') FROM public.lwb_tally_payments p WHERE p.slip_order_id = o.id AND p.cancelled_at IS NULL),
         ((now() AT TIME ZONE 'Asia/Kolkata')::date - (s.created_at AT TIME ZONE 'Asia/Kolkata')::date)::integer
  FROM public.lwb_quick_slips s JOIN public.orders o ON o.id = s.order_id
  WHERE s.created_at >= now() - interval '120 days'
    AND lower(btrim(coalesce(o.status::text,''))) NOT IN ('cancelled','canceled')
    AND NOT EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = o.id)
    AND public.lwb_company_ok(s.company_id);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_slip_bill_rows() FROM PUBLIC, anon, authenticated;

-- For Accounts / Admin / Sales Head screens (Billing & Outstanding, Accounts Dashboard).
CREATE OR REPLACE FUNCTION public.lwb_slip_bill_pending()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.lwb_quick_slip_role() NOT IN ('admin','manager','accounts') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can see pending bills.';
  END IF;
  RETURN coalesce((SELECT jsonb_agg(to_jsonb(r) - 'created_by' ORDER BY r.slip_at) FROM public.lwb_slip_bill_rows() r), '[]'::jsonb);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 6. Delivered tick
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_quick_slip_delivered(p_order_id uuid, p_on boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_role text := public.lwb_quick_slip_role(); v_o public.orders%ROWTYPE; v_s public.lwb_quick_slips%ROWTYPE;
BEGIN
  IF v_role NOT IN ('admin','manager','accounts','sales','salesman') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Accounts or the salesman of the order can mark a slip delivered.';
  END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF v_role IN ('sales','salesman') AND v_o.created_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Accounts or the salesman of the order can mark a slip delivered.';
  END IF;
  IF v_role IN ('sales','salesman') AND NOT coalesce(p_on, true) THEN
    RAISE EXCEPTION 'Ask the Sales Head to undo Delivered.';
  END IF;
  SELECT * INTO v_s FROM public.lwb_quick_slips WHERE order_id = p_order_id FOR UPDATE;
  IF NOT FOUND OR NOT public.lwb_company_ok(v_s.company_id) THEN RAISE EXCEPTION 'Slip not found.'; END IF;
  IF lower(btrim(coalesce(v_o.status,''))) IN ('cancelled','canceled') THEN RAISE EXCEPTION 'PO % is cancelled.', v_o.order_no; END IF;
  IF coalesce(p_on, true) THEN
    IF v_s.delivered_at IS NULL THEN
      UPDATE public.lwb_quick_slips SET delivered_at = now(), delivered_by = auth.uid() WHERE order_id = p_order_id;
    END IF;
  ELSE
    UPDATE public.lwb_quick_slips SET delivered_at = NULL, delivered_by = NULL WHERE order_id = p_order_id;
  END IF;
  RETURN jsonb_build_object('order_id', p_order_id,
    'delivered_at', (SELECT s.delivered_at FROM public.lwb_quick_slips s WHERE s.order_id = p_order_id));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 7. Mark paid: p = {amount, mode CASH/UPI/BANK/CHEQUE, bank_id (needed for UPI/BANK/CHEQUE), ref, pay_date}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_quick_slip_paid(p_order_id uuid, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_quick_slip_role();
  v_o public.orders%ROWTYPE; v_s public.lwb_quick_slips%ROWTYPE;
  v_parent text; v_amt numeric; v_mode text := upper(btrim(coalesce(p->>'mode','')));
  v_ref text := nullif(btrim(coalesce(p->>'ref','')),''); v_bank bigint; v_date date;
  v_receipt uuid := gen_random_uuid(); v_split numeric := 0; v_adv numeric; v_billed boolean;
BEGIN
  IF v_role NOT IN ('admin','manager','accounts') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can enter a payment.';
  END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  SELECT * INTO v_s FROM public.lwb_quick_slips WHERE order_id = p_order_id;
  IF NOT FOUND OR NOT public.lwb_company_ok(v_s.company_id) THEN RAISE EXCEPTION 'Slip not found.'; END IF;
  IF lower(btrim(coalesce(v_o.status,''))) IN ('cancelled','canceled') THEN RAISE EXCEPTION 'PO % is cancelled.', v_o.order_no; END IF;

  BEGIN v_amt := round(coalesce(nullif(btrim(p->>'amount'),''),'0')::numeric, 2);
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter the amount.';
  END;
  IF v_amt <= 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'Enter the amount.'; END IF;
  IF v_mode NOT IN ('CASH','UPI','BANK','CHEQUE') THEN RAISE EXCEPTION 'Select Cash, UPI, Bank or Cheque.'; END IF;
  IF length(coalesce(v_ref,'')) > 100 THEN RAISE EXCEPTION 'Reference is too long.'; END IF;
  IF v_mode = 'CASH' AND v_amt >= 200000 THEN
    RAISE EXCEPTION 'Cash of Rs 2 lakh or more in one receipt is not allowed (Income Tax 269ST).';
  END IF;
  IF v_mode <> 'CASH' THEN
    BEGIN v_bank := nullif(btrim(coalesce(p->>'bank_id','')),'')::bigint;
    EXCEPTION WHEN others THEN v_bank := NULL;
    END;
    IF v_bank IS NULL OR NOT EXISTS (SELECT 1 FROM public.lwb_acc_banks k WHERE k.id = v_bank AND k.active) THEN
      RAISE EXCEPTION 'Choose the bank the money came into.';
    END IF;
  END IF;
  IF v_mode = 'CHEQUE' AND v_ref IS NULL THEN RAISE EXCEPTION 'Enter the cheque number.'; END IF;
  IF v_mode <> 'CASH' AND v_ref IS NOT NULL AND EXISTS (SELECT 1 FROM public.lwb_tally_payments x WHERE x.mode = v_mode
        AND upper(btrim(x.ref_no)) = upper(v_ref) AND x.cancelled_at IS NULL) THEN
    RAISE EXCEPTION '% reference % is already entered.', initcap(v_mode), v_ref;
  END IF;
  BEGIN v_date := coalesce(nullif(btrim(coalesce(p->>'pay_date','')),'')::date, (now() AT TIME ZONE 'Asia/Kolkata')::date);
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter a valid payment date.';
  END;
  IF v_date > (now() AT TIME ZONE 'Asia/Kolkata')::date OR v_date < (v_s.created_at AT TIME ZONE 'Asia/Kolkata')::date - 1 THEN
    RAISE EXCEPTION 'Enter a payment date from the slip date to today.';
  END IF;

  v_parent := public.lwb_party_parent(v_o.customer_name);
  IF coalesce(v_parent,'') = '' OR NOT public.lwb_party_known(v_parent) THEN
    RAISE EXCEPTION 'Party % is not in the Party Master. Add it first.', btrim(v_o.customer_name);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(v_parent)));
  INSERT INTO public.lwb_tally_payments (receipt_id, order_id, party, pay_date, mode, amount, ref_no, remark,
                                         created_by, company_id, bank_id, slip_order_id)
  VALUES (v_receipt, NULL, v_parent, v_date, v_mode, v_amt, v_ref, 'Slip ' || coalesce(v_o.order_no,''),
          auth.uid(), v_s.company_id, v_bank, v_o.id);

  -- Bill made already: set it against that brand's bills now. Else it stays advance until the bill is saved.
  v_billed := EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = v_o.id);
  IF v_billed AND v_s.company_id IS NOT NULL THEN
    BEGIN v_split := public.lwb_party_apply_b(v_parent, v_s.company_id, NULL);
    EXCEPTION WHEN others THEN v_split := 0;
    END;
  END IF;
  SELECT COALESCE(sum(f.free),0) INTO v_adv FROM public.lwb_party_receipt_free_b(v_parent, v_s.company_id) f;
  RETURN jsonb_build_object('receipt_id', v_receipt, 'party', v_parent, 'amount', v_amt, 'split', v_split,
    'advance', round(v_adv,2), 'billed', v_billed,
    'paid', (SELECT coalesce(sum(x.amount),0) FROM public.lwb_tally_payments x WHERE x.slip_order_id = v_o.id AND x.cancelled_at IS NULL));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 8. Slip list (same as lwb_quick_slip_setup.sql + delivered / paid / bill and the pending list)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_quick_slip_list(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_role text := public.lwb_quick_slip_role();
        v_from date := coalesce(p_from, (now() AT TIME ZONE 'Asia/Kolkata')::date);
        v_to date := coalesce(p_to, (now() AT TIME ZONE 'Asia/Kolkata')::date);
BEGIN
  IF v_role NOT IN ('admin','manager','accounts','warehouse','sales','salesman') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Accounts, Godown or Salesman can see slips.';
  END IF;
  IF v_to < v_from OR v_to - v_from > 400 THEN RAISE EXCEPTION 'Choose up to 400 days.'; END IF;
  RETURN jsonb_build_object(
    'slips', coalesce((
      SELECT jsonb_agg(r ORDER BY r->>'slip_at' DESC) FROM (
        SELECT jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'order_date', o.order_date,
                 'party', btrim(o.customer_name), 'status', o.status, 'driver_name', s.driver_name,
                 'vehicle_no', s.vehicle_no, 'slip_at', s.created_at, 'print_count', s.print_count,
                 'delivered_at', s.delivered_at,
                 'paid', (SELECT coalesce(sum(p.amount),0) FROM public.lwb_tally_payments p
                          WHERE p.slip_order_id = o.id AND p.cancelled_at IS NULL),
                 'pay_modes', (SELECT string_agg(DISTINCT p.mode, ' + ') FROM public.lwb_tally_payments p
                               WHERE p.slip_order_id = o.id AND p.cancelled_at IS NULL),
                 'bill_no', (SELECT t.invoice_no FROM public.lwb_tally_invoices t WHERE t.order_id = o.id),
                 'total_qty', (SELECT coalesce(sum(coalesce(i.loaded_qty,0)),0) FROM public.order_items i WHERE i.order_id = o.id),
                 'total_amount', (SELECT coalesce(sum(round(coalesce(i.loaded_qty,0)::numeric * coalesce(i.rate,0)::numeric, 2)),0)
                                  FROM public.order_items i WHERE i.order_id = o.id)) AS r
        FROM public.lwb_quick_slips s JOIN public.orders o ON o.id = s.order_id
        WHERE (s.created_at AT TIME ZONE 'Asia/Kolkata')::date BETWEEN v_from AND v_to
          AND public.lwb_company_ok(s.company_id)
          AND (v_role NOT IN ('sales','salesman') OR o.created_by = auth.uid())
        ORDER BY s.created_at DESC LIMIT 1000) x), '[]'::jsonb),
    -- Every slip still without a Tally bill (any date, last 120 days): the "Bill pending" tab.
    'pending', coalesce((
      SELECT jsonb_agg(to_jsonb(r) - 'created_by' ORDER BY r.slip_at) FROM public.lwb_slip_bill_rows() r
      WHERE v_role NOT IN ('sales','salesman') OR r.created_by = auth.uid()), '[]'::jsonb),
    'can_mark', v_role IN ('admin','manager','accounts'),
    'waiting', coalesce((
      SELECT jsonb_agg(jsonb_build_object('order_id', o.id, 'order_no', o.order_no, 'order_date', o.order_date,
               'party', btrim(o.customer_name), 'total_qty', o.total_qty, 'total_amount', o.total_amount) ORDER BY o.order_date DESC)
      FROM (SELECT o.* FROM public.orders o
            WHERE v_role IN ('admin','manager')
              AND lower(btrim(coalesce(o.status,''))) IN ('approved','approved_next','manager_approved','warehouse_approved')
              AND o.order_date >= now() - interval '30 days'
              AND NOT EXISTS (SELECT 1 FROM public.lwb_quick_slips s WHERE s.order_id = o.id)
              AND NOT EXISTS (SELECT 1 FROM public.dispatch_assignments a WHERE a.order_id = o.id)
              AND public.lwb_quick_slip_company(o.id) IS NOT NULL
              AND public.lwb_company_ok(public.lwb_quick_slip_company(o.id))
            ORDER BY o.order_date DESC LIMIT 200) o), '[]'::jsonb));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 9. Daily popup to Accounts and Admin. Old unread ones are closed so the bell shows one.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_slip_bill_remind_internal()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_n int; v_amt numeric; v_old int; v_top text; v_title text; v_msg text; v_sent int := 0; u record;
BEGIN
  UPDATE public.erp_notifications SET is_read = true WHERE notification_type = 'SLIP_BILL_PENDING' AND is_read = false;
  SELECT count(*), coalesce(sum(r.amount),0), coalesce(max(r.days),0) INTO v_n, v_amt, v_old FROM public.lwb_slip_bill_rows() r;
  IF v_n = 0 THEN RETURN 0; END IF;
  SELECT string_agg(x.t, '; ') INTO v_top FROM (
    SELECT r.order_no || ' ' || r.party || ' Rs ' || to_char(r.amount,'FM99999999990') || ' (' || r.days || ' day' ||
           CASE WHEN r.days = 1 THEN '' ELSE 's' END || ')' AS t
    FROM public.lwb_slip_bill_rows() r ORDER BY r.slip_at LIMIT 3) x;
  v_title := 'Rajnigandha bills pending: ' || v_n || ' · Rs ' || to_char(v_amt,'FM99999999990');
  v_msg := 'Goods are out but the Tally bill is not made. Oldest ' || v_old || ' day' || CASE WHEN v_old = 1 THEN '' ELSE 's' END ||
           ': ' || v_top || '. Make the bills in Billing & Outstanding > Bills to make.';
  FOR u IN SELECT p.id FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','accounts') LOOP
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type) VALUES (u.id, v_title, left(v_msg, 900), 'SLIP_BILL_PENDING');
    v_sent := v_sent + 1;
  END LOOP;
  RETURN v_sent;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_slip_bill_remind_internal() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.lwb_money_banks(), public.lwb_slip_bill_pending(), public.lwb_quick_slip_delivered(uuid, boolean),
  public.lwb_quick_slip_paid(uuid, jsonb), public.lwb_quick_slip_list(date, date),
  public.lwb_party_receive(text,date,jsonb,jsonb,text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_money_banks(), public.lwb_slip_bill_pending(), public.lwb_quick_slip_delivered(uuid, boolean),
  public.lwb_quick_slip_paid(uuid, jsonb), public.lwb_quick_slip_list(date, date),
  public.lwb_party_receive(text,date,jsonb,jsonb,text,uuid) TO authenticated;

COMMIT;

-- 10:00 India time (04:30 UTC), only where pg_cron is on.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'lwb_slip_bill_reminder';
    PERFORM cron.schedule('lwb_slip_bill_reminder', '30 4 * * *', 'SELECT public.lwb_slip_bill_remind_internal()');
  END IF;
END
$cron$;

NOTIFY pgrst, 'reload schema';
