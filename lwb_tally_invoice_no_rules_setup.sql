-- LUXURY WRIST BRAND ERP — ONE INVOICE NO. PER BILL LINE, NO INVOICE NO. TWICE (17 Nov 2026)
--
-- Runs by itself when merged to main (after lwb_bill_change_setup.sql and lwb_brand_money_setup.sql).
-- Safe to run again. Nothing is dropped, deleted or changed in the saved bills.
--
-- Mohit (Billing & Outstanding > Bills made): Accounts typed 3 Tally invoice numbers in one bill line
-- ("3673,3674,3675") with one merged amount. Rules now:
--   1. One bill line = ONE invoice no. + its own amount. Commas, ";", "&", "+", "|" or two numbers with a
--      space between them are refused. Several bills on one PO = "+ Another bill", one line each.
--   2. An invoice no. can be entered only once: same brand (company of the PO's SKUs), same financial
--      year (April to March, Tally starts the numbers again). Coca-Cola and Rajnigandha have their own
--      number series, so the same number in the other brand is allowed. A PO whose brand is not known
--      (no SKU brand / two brands) is checked against every brand.
--   The check is a trigger on lwb_tally_invoices, so every way of saving a bill obeys it. It looks only at
--   numbers that are NEW on the row: old merged / repeated bills already saved are not blocked, so other
--   fields of those bills (date, amount) can still be fixed; their numbers must be fixed through Edit.
--   A unique index is not used because bills are kept as a jsonb list per PO and old repeats exist.
--   3. lwb_tally_no_check(order, date, numbers) = live check while typing (which numbers are used, where).
--   4. lwb_tally_no_problems() = old bills to fix: merged lines and numbers used twice (Bills made banner).

BEGIN;

-- number as compared: upper case, no spaces, no leading zeros on a plain number
CREATE OR REPLACE FUNCTION public.lwb_tally_no_key(p_no text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE WHEN x ~ '^[0-9]+$' THEN coalesce(nullif(ltrim(x, '0'), ''), '0') ELSE x END
  FROM (SELECT upper(regexp_replace(coalesce(p_no, ''), '\s+', '', 'g')) AS x) s;
$fn$;

-- true when one box holds more than one invoice no. ("3673,3674", "3661 & 3662", "3673 3674", "3673-3675")
CREATE OR REPLACE FUNCTION public.lwb_tally_no_merged(p_no text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT coalesce(p_no, '') ~ '[,;&+|]'
      OR coalesce(p_no, '') ~ '[0-9]\s+[0-9]'
      OR coalesce(p_no, '') ~* '[0-9]\s*(and|to)\s*[0-9]'
      OR btrim(coalesce(p_no, '')) ~ '^[0-9]+\s*-\s*[0-9]+$';
$fn$;

-- financial year (April start) of a bill date
CREATE OR REPLACE FUNCTION public.lwb_tally_fy(p_date date)
RETURNS int LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT extract(year FROM (p_date - interval '3 months'))::int;
$fn$;

-- bill numbers of one saved row: the bill lines, or the old single box split at commas
CREATE OR REPLACE FUNCTION public.lwb_tally_row_nos(p_bills jsonb, p_invoice_no text)
RETURNS TABLE(no text, firm text, amount numeric)
LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT btrim(b->>'no'), b->>'firm', nullif(b->>'amount','')::numeric
  FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_bills) = 'array' THEN p_bills ELSE '[]'::jsonb END) b
  WHERE coalesce(btrim(b->>'no'), '') <> ''
  UNION ALL
  SELECT btrim(x), NULL::text, NULL::numeric
  FROM unnest(string_to_array(coalesce(p_invoice_no, ''), ',')) x
  WHERE (p_bills IS NULL OR jsonb_typeof(p_bills) <> 'array' OR jsonb_array_length(p_bills) = 0) AND btrim(x) <> '';
$fn$;

-- other saved bills that already use these numbers (same brand, same financial year)
CREATE OR REPLACE FUNCTION public.lwb_tally_no_used(p_order_id uuid, p_date date, p_keys text[])
RETURNS TABLE(no_key text, no text, order_id uuid, order_no text, party text, invoice_date date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  WITH me AS (SELECT public.lwb_order_company(p_order_id) AS c)
  SELECT DISTINCT ON (public.lwb_tally_no_key(n.no)) public.lwb_tally_no_key(n.no), n.no, t.order_id, o.order_no::text,
         coalesce(n.firm, o.customer_name::text), t.invoice_date
  FROM public.lwb_tally_invoices t
  JOIN public.orders o ON o.id = t.order_id
  CROSS JOIN LATERAL public.lwb_tally_row_nos(t.bills, t.invoice_no) n
  WHERE t.order_id IS DISTINCT FROM p_order_id
    AND public.lwb_tally_fy(t.invoice_date) = public.lwb_tally_fy(coalesce(p_date, (now() AT TIME ZONE 'Asia/Kolkata')::date))
    AND public.lwb_tally_no_key(n.no) = ANY (p_keys)
    AND ((SELECT c FROM me) IS NULL OR public.lwb_order_company(t.order_id) IS NULL
         OR public.lwb_order_company(t.order_id) = (SELECT c FROM me))
  ORDER BY public.lwb_tally_no_key(n.no), t.invoice_date DESC;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_tally_no_used(uuid,date,text[]) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1 + 2. Trigger: every save of a Tally bill obeys the rules
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_tally_invoice_no_guard()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_old text[] := '{}';
  v_new text[] := '{}';
  v_seen text[] := '{}';
  r record;
  u record;
  k text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    SELECT coalesce(array_agg(public.lwb_tally_no_key(n.no)), '{}') INTO v_old
    FROM public.lwb_tally_row_nos(OLD.bills, OLD.invoice_no) n;
    -- nothing about the numbers changed (amount / date / note edits): no check
    IF NEW.bills IS NOT DISTINCT FROM OLD.bills AND NEW.invoice_no IS NOT DISTINCT FROM OLD.invoice_no
       AND public.lwb_tally_fy(NEW.invoice_date) = public.lwb_tally_fy(OLD.invoice_date) THEN
      RETURN NEW;
    END IF;
  END IF;
  -- while lwb_save_tally_bills writes the joined numbers first, the bill lines are still the old ones;
  -- the next UPDATE (bills) is checked in full
  FOR r IN SELECT * FROM public.lwb_tally_row_nos(NEW.bills, NEW.invoice_no) LOOP
    IF r.no IS NULL OR r.no = '' THEN CONTINUE; END IF;
    k := public.lwb_tally_no_key(r.no);
    IF k = ANY (v_old) AND public.lwb_tally_fy(NEW.invoice_date) = public.lwb_tally_fy(coalesce(OLD.invoice_date, NEW.invoice_date)) THEN
      CONTINUE; -- already on this bill before (old data is not blocked)
    END IF;
    IF public.lwb_tally_no_merged(r.no) THEN
      RAISE EXCEPTION 'Bill no. "%" has more than one invoice no. Enter one invoice no. per bill with its own amount (use + Another bill).', r.no
        USING ERRCODE = 'check_violation';
    END IF;
    IF k = ANY (v_seen) THEN
      RAISE EXCEPTION 'Invoice no. % is entered twice in this PO.', r.no USING ERRCODE = 'unique_violation';
    END IF;
    v_seen := v_seen || k;
    v_new := v_new || k;
  END LOOP;
  IF cardinality(v_new) = 0 THEN RETURN NEW; END IF;

  -- two people saving the same number at once: one waits for the other
  PERFORM pg_advisory_xact_lock(hashtext('lwb_tally_no|' || public.lwb_tally_fy(NEW.invoice_date)));
  SELECT * INTO u FROM public.lwb_tally_no_used(NEW.order_id, NEW.invoice_date, v_new) LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Duplicate: invoice no. % already exists in PO % (%, %). One invoice no. can be entered only once.',
      u.no, u.order_no, u.party, to_char(u.invoice_date, 'DD/MM/YYYY') USING ERRCODE = 'unique_violation';
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_tally_invoice_no_guard() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS lwb_tally_invoice_no_guard ON public.lwb_tally_invoices;
CREATE TRIGGER lwb_tally_invoice_no_guard
  BEFORE INSERT OR UPDATE ON public.lwb_tally_invoices
  FOR EACH ROW EXECUTE FUNCTION public.lwb_tally_invoice_no_guard();

-- ---------------------------------------------------------------------------
-- Save bills (same as lwb_bill_change_setup.sql) with the new rules; the cross-PO check moved to the trigger
-- ---------------------------------------------------------------------------
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
    IF public.lwb_tally_no_merged(v_no) THEN
      RAISE EXCEPTION 'Bill no. "%" has more than one invoice no. Enter one invoice no. per bill with its own amount (use + Another bill).', v_no;
    END IF;
    v_key := btrim(regexp_replace(upper(v_firm), '[^A-Z0-9]+', ' ', 'g'));
    IF public.lwb_tally_no_key(v_no) = ANY (v_seen) THEN
      RAISE EXCEPTION 'Invoice no. % is entered twice in this PO.', v_no;
    END IF;
    v_seen := v_seen || public.lwb_tally_no_key(v_no);
    -- the same number on another PO (any bill name, same brand, same financial year) is refused by the
    -- trigger lwb_tally_invoice_no_guard on lwb_tally_invoices (was: same bill name, last 400 days)
    -- a name that is linked by hand to ANOTHER main party is refused (one ledger per main party)
    IF v_key <> btrim(regexp_replace(upper(v_party), '[^A-Z0-9]+', ' ', 'g')) THEN
      SELECT m.customer_name INTO v_linked FROM public.lwb_tally_party_map m WHERE m.tally_key = v_key;
      IF FOUND AND v_linked IS NOT NULL
         AND public.lwb_party_key(public.lwb_party_parent(v_linked)) <> public.lwb_party_key(public.lwb_party_parent(v_party)) THEN
        RAISE EXCEPTION 'Bill name % is under party %, not %. Change it in Billing & Outstanding > Party groups first.',
          v_firm, public.lwb_party_parent(v_linked), public.lwb_party_parent(v_party);
      END IF;
    END IF;
    v_nos := v_nos || v_no;
    v_total := v_total + v_amt;
    v_lines := v_lines || jsonb_build_object('firm', v_firm, 'no', v_no, 'amount', v_amt);
  END LOOP;

  IF length(array_to_string(v_nos, ', ')) > 200 THEN RAISE EXCEPTION 'Invoice numbers are too long'; END IF;
  v_res := public.lwb_save_tally_invoice(p_order_id, array_to_string(v_nos, ', '), p_invoice_date, p_note);
  UPDATE public.lwb_tally_invoices SET amount = v_total, bills = v_lines WHERE order_id = p_order_id;
  -- No lwb_tally_party_map row: the bill name lives only on this bill line, under the PO's main party.
  RETURN v_res;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. Live check while typing: [{no, order_no, party, date}] for numbers already used elsewhere
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_tally_no_check(p_order_id uuid, p_date date, p_nos text[])
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN RAISE EXCEPTION 'Only active Accounts or Admin can check Tally bill numbers'; END IF;
  IF p_nos IS NULL OR cardinality(p_nos) = 0 THEN RETURN '[]'::jsonb; END IF;
  IF cardinality(p_nos) > 20 THEN RAISE EXCEPTION 'At most 20 numbers'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('key', u.no_key, 'no', u.no, 'order_id', u.order_id, 'order_no', u.order_no,
                                        'party', u.party, 'date', u.invoice_date))
    FROM public.lwb_tally_no_used(p_order_id, p_date,
           ARRAY(SELECT DISTINCT public.lwb_tally_no_key(x) FROM unnest(p_nos) x WHERE btrim(coalesce(x,'')) <> '')) u
  ), '[]'::jsonb);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_tally_no_check(uuid,date,text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_tally_no_check(uuid,date,text[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Old bills to fix: merged lines + numbers used on two POs (same brand, same financial year)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_tally_no_problems()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN RAISE EXCEPTION 'Only active Accounts or Admin can see this list'; END IF;
  RETURN jsonb_build_object(
    'merged', coalesce((
      SELECT jsonb_agg(jsonb_build_object('order_id', t.order_id, 'order_no', o.order_no, 'party', coalesce(n.firm, o.customer_name::text),
                                          'no', n.no, 'amount', coalesce(n.amount, t.amount), 'date', t.invoice_date)
                       ORDER BY t.invoice_date DESC, o.order_no)
      FROM public.lwb_tally_invoices t
      JOIN public.orders o ON o.id = t.order_id
      CROSS JOIN LATERAL (
        SELECT btrim(b->>'no') AS no, b->>'firm' AS firm, nullif(b->>'amount','')::numeric AS amount
        FROM jsonb_array_elements(t.bills) b
        UNION ALL
        SELECT t.invoice_no, NULL, NULL WHERE jsonb_array_length(t.bills) = 0) n
      WHERE public.lwb_tally_no_merged(n.no)), '[]'::jsonb),
    'dupes', coalesce((
      WITH x AS (
        SELECT public.lwb_tally_no_key(n.no) AS k, n.no, public.lwb_tally_fy(t.invoice_date) AS fy,
               public.lwb_order_company(t.order_id) AS c, t.order_id, o.order_no::text AS order_no,
               coalesce(n.firm, o.customer_name::text) AS party, coalesce(n.amount, t.amount) AS amount, t.invoice_date
        FROM public.lwb_tally_invoices t
        JOIN public.orders o ON o.id = t.order_id
        CROSS JOIN LATERAL public.lwb_tally_row_nos(t.bills, t.invoice_no) n
        WHERE NOT public.lwb_tally_no_merged(n.no)),
      g AS (
        SELECT k, fy, c, jsonb_agg(jsonb_build_object('order_id', order_id, 'order_no', order_no, 'party', party, 'no', no,
                                                      'amount', amount, 'date', invoice_date) ORDER BY invoice_date, order_no) AS rows
        FROM x GROUP BY k, fy, c HAVING count(DISTINCT order_id) > 1)
      SELECT jsonb_agg(jsonb_build_object('no', g.rows->0->>'no', 'rows', g.rows) ORDER BY g.rows->0->>'no') FROM g), '[]'::jsonb));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_tally_no_problems() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_tally_no_problems() TO authenticated;

COMMIT;

SELECT 'invoice no. guard' AS step, (SELECT count(*) FROM pg_trigger WHERE tgname = 'lwb_tally_invoice_no_guard')::text AS ok
UNION ALL SELECT 'live check', (to_regprocedure('public.lwb_tally_no_check(uuid,date,text[])') IS NOT NULL)::text
UNION ALL SELECT 'fix list', (to_regprocedure('public.lwb_tally_no_problems()') IS NOT NULL)::text;
