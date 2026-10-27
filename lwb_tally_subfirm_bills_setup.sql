-- LUXURY WRIST BRAND ERP — ONE PO, TALLY BILLS IN SUB-FIRM NAMES
--
-- RUN ONCE in Supabase SQL Editor, after lwb_tally_bill_flow_setup.sql. Safe to run again.
--
-- A PO comes in the main party's name (e.g. SHREE JAGDISH TRADERS) but Accounts may make the Tally
-- bill(s) in its sub-firms (Priya Traders, Rohit Traders ...). Accounts now enters one line per Tally
-- bill: firm + invoice no. + amount. The money, returns, notes and Cashbook stay under the ONE main
-- party (the PO's party). A sub-firm used here is linked to the main party in the Tally party links
-- (the same links Tally Bill Check uses), so the nightly Sales Register matches it to the main party.
--
-- Nothing is posted to Tally, the party ledger, stock or GST here.

BEGIN;

ALTER TABLE public.lwb_tally_invoices
  ADD COLUMN IF NOT EXISTS bills jsonb NOT NULL DEFAULT '[]'::jsonb;

-- p_bills: [{"firm": "PRIYA TRADERS", "no": "2255", "amount": 54405}, ...]  (1 to 20 lines)
-- firm empty = the PO's own party name.
CREATE OR REPLACE FUNCTION public.lwb_save_tally_bills(p_order_id uuid, p_invoice_date date, p_bills jsonb, p_note text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_party text;
  v_lines jsonb := '[]'::jsonb;
  v_nos text[] := '{}';
  v_seen text[] := '{}';
  v_total numeric := 0;
  v_line jsonb;
  v_firm text;
  v_no text;
  v_amt numeric;
  v_key text;
  v_linked text;
  v_other text;
  v_res text;
BEGIN
  IF NOT public.lwb_tally_staff() THEN
    RAISE EXCEPTION 'Only active Accounts or Admin can enter the Tally bill';
  END IF;
  IF p_bills IS NULL OR jsonb_typeof(p_bills) <> 'array' OR jsonb_array_length(p_bills) = 0 THEN
    RAISE EXCEPTION 'Enter at least one Tally bill';
  END IF;
  IF jsonb_array_length(p_bills) > 20 THEN RAISE EXCEPTION 'At most 20 Tally bills for one PO'; END IF;
  SELECT btrim(o.customer_name::text) INTO v_party FROM public.orders o WHERE o.id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_bills) LOOP
    v_firm := coalesce(nullif(btrim(coalesce(v_line->>'firm','')), ''), v_party);
    v_no := btrim(coalesce(v_line->>'no',''));
    BEGIN
      v_amt := round((v_line->>'amount')::numeric, 2);
    EXCEPTION WHEN others THEN v_amt := NULL;
    END;
    IF v_no = '' THEN RAISE EXCEPTION 'Enter the invoice no. for %', v_firm; END IF;
    IF length(v_no) > 100 OR length(v_firm) > 200 THEN RAISE EXCEPTION 'Invoice no. or firm name is too long'; END IF;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'Enter the amount of bill %', v_no; END IF;
    -- each firm has its own bill numbers in Tally, so a number repeats only within the same firm
    v_key := btrim(regexp_replace(upper(v_firm), '[^A-Z0-9]+', ' ', 'g'));
    IF (v_key || '|' || upper(v_no)) = ANY (v_seen) THEN
      RAISE EXCEPTION 'Invoice no. % of % is entered twice', v_no, v_firm;
    END IF;
    v_seen := v_seen || (v_key || '|' || upper(v_no));
    -- the same firm + bill no. already given to another PO (older rows without firm lines: the PO's party)
    SELECT o.order_no::text INTO v_other
    FROM public.lwb_tally_invoices t JOIN public.orders o ON o.id = t.order_id
    WHERE t.order_id <> p_order_id
      AND t.invoice_date > p_invoice_date - 400
      AND (EXISTS (SELECT 1 FROM jsonb_array_elements(t.bills) b
                   WHERE upper(btrim(b->>'no')) = upper(v_no)
                     AND btrim(regexp_replace(upper(b->>'firm'), '[^A-Z0-9]+', ' ', 'g')) = v_key)
           OR (jsonb_array_length(t.bills) = 0
               AND btrim(regexp_replace(upper(o.customer_name::text), '[^A-Z0-9]+', ' ', 'g')) = v_key
               AND upper(v_no) = ANY (SELECT upper(btrim(x)) FROM unnest(string_to_array(t.invoice_no, ',')) x)))
    LIMIT 1;
    IF v_other IS NOT NULL THEN
      RAISE EXCEPTION 'Invoice no. % of % is already entered for PO %', v_no, v_firm, v_other;
    END IF;
    -- a sub-firm must belong to this party only (one ledger per main party)
    IF v_key <> btrim(regexp_replace(upper(v_party), '[^A-Z0-9]+', ' ', 'g')) THEN
      SELECT m.customer_name INTO v_linked FROM public.lwb_tally_party_map m WHERE m.tally_key = v_key;
      IF FOUND AND v_linked IS NOT NULL AND upper(btrim(v_linked)) <> upper(v_party) THEN
        RAISE EXCEPTION 'Firm % is linked to party %, not %. Change the link in Tally Bill Check first.', v_firm, v_linked, v_party;
      END IF;
    END IF;
    v_nos := v_nos || v_no;
    v_total := v_total + v_amt;
    v_lines := v_lines || jsonb_build_object('firm', v_firm, 'no', v_no, 'amount', v_amt);
  END LOOP;

  IF length(array_to_string(v_nos, ', ')) > 200 THEN RAISE EXCEPTION 'Invoice numbers are too long'; END IF;
  v_res := public.lwb_save_tally_invoice(p_order_id, array_to_string(v_nos, ', '), p_invoice_date, p_note);
  UPDATE public.lwb_tally_invoices SET amount = v_total, bills = v_lines WHERE order_id = p_order_id;

  -- link each new sub-firm to the main party (Tally Bill Check matches the register with these links)
  FOR v_line IN SELECT * FROM jsonb_array_elements(v_lines) LOOP
    v_key := btrim(regexp_replace(upper(v_line->>'firm'), '[^A-Z0-9]+', ' ', 'g'));
    IF v_key <> btrim(regexp_replace(upper(v_party), '[^A-Z0-9]+', ' ', 'g')) THEN
      INSERT INTO public.lwb_tally_party_map AS m (tally_key, tally_name, customer_name, updated_at, updated_by)
      VALUES (v_key, v_line->>'firm', v_party, now(), auth.uid())
      ON CONFLICT (tally_key) DO UPDATE SET customer_name = excluded.customer_name, updated_at = now(), updated_by = auth.uid()
        WHERE m.customer_name IS NULL;
    END IF;
  END LOOP;
  RETURN v_res;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_save_tally_bills(uuid,date,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_save_tally_bills(uuid,date,jsonb,text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: both rows true.
SELECT 'sub-firm bills column' AS item,
  EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
          AND table_name = 'lwb_tally_invoices' AND column_name = 'bills')::text AS ok
UNION ALL SELECT 'save sub-firm bills', (to_regprocedure('public.lwb_save_tally_bills(uuid,date,jsonb,text)') IS NOT NULL)::text;
