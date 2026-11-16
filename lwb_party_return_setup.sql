-- LUXURY WRIST BRAND ERP — GOODS RETURN FROM A PARTY IN BILLING (CS + PCS)
--
-- Runs by itself when merged to main (after lwb_tally_bill_flow_setup.sql,
-- lwb_party_group_billing_setup.sql and lwb_bill_change_setup.sql). Safe to run again.
-- Nothing is dropped or deleted.
--
-- Mohit asked (16 Nov 2026), Billing & Outstanding:
--   1. A return can be in cases AND pieces (sometimes 2 PCS come back, sometimes 2 CS).
--      Value = (CS + PCS / PCS per case) x rate per case.
--   2. Return against a bill: the lines of that PO (rate from the PO), plus any other SKU.
--      - PO has a Tally bill  -> a credit note (RET-xxxx, or the Tally note no. typed) is saved
--        on that bill at once, so its Due and the party's To collect go down.
--      - No Tally bill yet    -> the return is kept on the PO; Bills to make shows the value
--        after the return, so the Tally bill is made for the net amount.
--   3. New return (not against a bill): any SKU from any party. Its value is a return credit
--      on the main party (like money paid earlier), so the party's balance goes down.
--   A wrong return is cancelled (kept for the record); its credit note is cancelled with it.
--   Godown stock, GST and Tally are NOT changed here.

BEGIN;

CREATE SEQUENCE IF NOT EXISTS public.lwb_party_return_no_seq;

CREATE TABLE IF NOT EXISTS public.lwb_party_returns (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  return_no    text NOT NULL UNIQUE,
  party        text NOT NULL CHECK (length(btrim(party)) BETWEEN 1 AND 200),
  order_id     uuid REFERENCES public.orders(id) ON DELETE CASCADE,
  company_id   uuid,
  return_date  date NOT NULL,
  amount       numeric(14,2) NOT NULL CHECK (amount > 0),
  note         text CHECK (note IS NULL OR length(note) <= 300),
  note_id      uuid,
  created_by   uuid NOT NULL REFERENCES auth.users(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  cancelled_by uuid REFERENCES auth.users(id),
  cancelled_at timestamptz
);
CREATE INDEX IF NOT EXISTS lwb_party_returns_order_idx ON public.lwb_party_returns(order_id) WHERE cancelled_at IS NULL;
CREATE INDEX IF NOT EXISTS lwb_party_returns_date_idx ON public.lwb_party_returns(return_date DESC);

CREATE TABLE IF NOT EXISTS public.lwb_party_return_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  return_id     uuid NOT NULL REFERENCES public.lwb_party_returns(id) ON DELETE CASCADE,
  order_item_id text,
  sku_name      text NOT NULL,
  cases         integer NOT NULL DEFAULT 0 CHECK (cases >= 0),
  pcs           integer NOT NULL DEFAULT 0 CHECK (pcs >= 0),
  pcs_per_case  integer,
  qty_cases     numeric(18,6) NOT NULL CHECK (qty_cases > 0),
  rate          numeric(14,2) NOT NULL CHECK (rate > 0),
  amount        numeric(14,2) NOT NULL CHECK (amount >= 0)
);
CREATE INDEX IF NOT EXISTS lwb_party_return_items_ret_idx ON public.lwb_party_return_items(return_id);
CREATE INDEX IF NOT EXISTS lwb_party_return_items_item_idx ON public.lwb_party_return_items(order_item_id);

ALTER TABLE public.lwb_party_returns ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_party_return_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_party_returns, public.lwb_party_return_items FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_party_return_no_seq FROM PUBLIC, anon, authenticated;

-- PCS in one case: SKU Master first, else the "1X12" part of the SKU name. Internal.
CREATE OR REPLACE FUNCTION public.lwb_pr_pcs_per_case(p_sku text)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT COALESCE(
    (SELECT m.pcs_per_case FROM public.sku_master m
      WHERE lower(btrim(m.sku_name)) = lower(btrim(p_sku)) AND m.pcs_per_case > 0
      ORDER BY m.is_active DESC NULLS LAST LIMIT 1),
    NULLIF(substring(upper(COALESCE(p_sku,'')) FROM '(?:^|[^0-9.])1 *X *([0-9]{1,3})(?:[^0-9]|$)')::integer, 0));
$fn$;

-- Cases of one PO line: loaded qty after loading, approved qty before. Internal.
CREATE OR REPLACE FUNCTION public.lwb_pr_line_cases(p_loaded numeric, p_approved numeric, p_ordered numeric)
RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT CASE WHEN coalesce(p_loaded,0) > 0 THEN p_loaded ELSE coalesce(p_approved, p_ordered, 0) END $fn$;

-- ---------------------------------------------------------------------------
-- Popup data: one PO (lines, rate, PCS per case, already returned) or a party (SKU list, last rate)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_return_form(p_order_id uuid DEFAULT NULL, p_party text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_no text;
  v_party text := nullif(btrim(coalesce(p_party,'')),'');
  v_parent text;
  v_keys text[] := '{}';
BEGIN
  IF NOT public.lwb_tally_staff() THEN RAISE EXCEPTION 'Active Admin / Accounts role required.'; END IF;
  IF p_order_id IS NOT NULL THEN
    SELECT o.order_no::text, btrim(o.customer_name::text) INTO v_no, v_party
    FROM public.orders o WHERE o.id = p_order_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  END IF;
  v_parent := CASE WHEN v_party IS NULL THEN NULL ELSE public.lwb_party_parent(v_party) END;
  IF v_parent IS NOT NULL THEN
    v_keys := ARRAY[public.lwb_party_key(v_parent)] || coalesce((SELECT array_agg(m.tally_key) FROM public.lwb_tally_party_map m
                WHERE public.lwb_party_key(m.customer_name) = public.lwb_party_key(v_parent)), '{}');
  END IF;
  RETURN jsonb_build_object(
    'order_id', p_order_id, 'order_no', v_no, 'party', v_party,
    'bill', CASE WHEN p_order_id IS NULL THEN NULL ELSE
             (SELECT jsonb_build_object('invoice_no', t.invoice_no, 'amount', t.amount)
              FROM public.lwb_tally_invoices t WHERE t.order_id = p_order_id) END,
    'items', CASE WHEN p_order_id IS NULL THEN '[]'::jsonb ELSE (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'item_id', i.id::text, 'sku_name', btrim(i.sku_name::text),
               'cases', public.lwb_pr_line_cases(i.loaded_qty, i.approved_qty, i.ordered_qty),
               'rate', coalesce(i.rate,0), 'ppc', public.lwb_pr_pcs_per_case(i.sku_name),
               'returned', coalesce((SELECT round(sum(ri.qty_cases),6) FROM public.lwb_party_return_items ri
                                     JOIN public.lwb_party_returns r ON r.id = ri.return_id
                                     WHERE ri.order_item_id = i.id::text AND r.cancelled_at IS NULL),0))
             ORDER BY i.sku_name), '[]'::jsonb)
      FROM public.order_items i WHERE i.order_id = p_order_id
        AND public.lwb_pr_line_cases(i.loaded_qty, i.approved_qty, i.ordered_qty) > 0) END,
    -- every active SKU with PCS per case and the last rate this main party (or its bill names) got
    'skus', (WITH s AS (SELECT DISTINCT btrim(m.sku_name::text) AS sku FROM public.sku_master m
                        WHERE m.is_active IS TRUE AND nullif(btrim(m.sku_name::text),'') IS NOT NULL),
                  lr AS (SELECT DISTINCT ON (upper(btrim(i.sku_name::text))) upper(btrim(i.sku_name::text)) AS k, i.rate
                         FROM public.order_items i JOIN public.orders o ON o.id = i.order_id
                         WHERE coalesce(i.rate,0) > 0 AND public.lwb_party_key(o.customer_name::text) = ANY (v_keys)
                         ORDER BY upper(btrim(i.sku_name::text)), o.order_date DESC)
             SELECT coalesce(jsonb_agg(jsonb_build_object('sku', s.sku, 'ppc', public.lwb_pr_pcs_per_case(s.sku), 'rate', lr.rate)
                    ORDER BY s.sku), '[]'::jsonb)
             FROM s LEFT JOIN lr ON lr.k = upper(s.sku)));
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Save a return. p_items: [{item_id (PO line, blank = other SKU), sku_name, cases, pcs, rate}]
-- The rate of a PO line is always the PO rate. Accounts / Admin.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_return_save(p_order_id uuid, p_party text, p_return_date date,
                                                        p_items jsonb, p_note text DEFAULT NULL, p_note_no text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_party text := nullif(btrim(coalesce(p_party,'')),'');
  v_note text := nullif(btrim(coalesce(p_note,'')),'');
  v_cn text := nullif(btrim(coalesce(p_note_no,'')),'');
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_order_no text; v_i record;
  e jsonb;
  v_sku text; v_cs int; v_pcs int; v_ppc int; v_rate numeric; v_qty numeric; v_left numeric;
  v_lines jsonb := '[]'::jsonb;
  v_total numeric := 0;
  v_skus text[] := '{}';
  v_seen text[] := '{}';
  v_no text; v_id uuid; v_note_id uuid; v_company uuid;
  v_billed boolean := false;
BEGIN
  IF NOT public.lwb_tally_staff() THEN RAISE EXCEPTION 'Only active Accounts or Admin can enter a return'; END IF;
  IF p_return_date IS NULL OR p_return_date > v_today OR p_return_date < v_today - 400 THEN
    RAISE EXCEPTION 'Enter a valid return date (not after today).';
  END IF;
  IF length(coalesce(v_note,'')) > 300 THEN RAISE EXCEPTION 'Note is too long'; END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Add at least one SKU with the cases / pieces returned.';
  END IF;
  IF jsonb_array_length(p_items) > 100 THEN RAISE EXCEPTION 'Too many lines'; END IF;

  IF p_order_id IS NOT NULL THEN
    SELECT o.order_no::text, btrim(o.customer_name::text) INTO v_order_no, v_party
    FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
    v_billed := EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = p_order_id);
  END IF;
  IF v_party IS NULL OR length(v_party) > 200 THEN RAISE EXCEPTION 'Choose the party the goods came back from.'; END IF;

  FOR e IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF coalesce(e->>'cases','0') !~ '^\d{1,6}$' OR coalesce(e->>'pcs','0') !~ '^\d{1,6}$' THEN
      RAISE EXCEPTION 'Enter whole cases and whole pieces.';
    END IF;
    v_cs := coalesce(nullif(e->>'cases',''),'0')::int;
    v_pcs := coalesce(nullif(e->>'pcs',''),'0')::int;
    CONTINUE WHEN v_cs = 0 AND v_pcs = 0;
    IF nullif(e->>'item_id','') IS NOT NULL THEN
      IF p_order_id IS NULL THEN RAISE EXCEPTION 'A bill line needs its bill.'; END IF;
      SELECT i.id::text AS id, btrim(i.sku_name::text) AS sku, coalesce(i.rate,0) AS rate,
             public.lwb_pr_line_cases(i.loaded_qty, i.approved_qty, i.ordered_qty) AS cases
        INTO v_i FROM public.order_items i WHERE i.order_id = p_order_id AND i.id::text = e->>'item_id';
      IF NOT FOUND THEN RAISE EXCEPTION 'A line of this PO was changed. Close and open the return again.'; END IF;
      v_sku := v_i.sku; v_rate := v_i.rate;
      IF v_rate <= 0 THEN RAISE EXCEPTION '% has no rate on the PO.', v_sku; END IF;
    ELSE
      v_sku := nullif(btrim(coalesce(e->>'sku_name','')),'');
      IF v_sku IS NULL THEN RAISE EXCEPTION 'Type the SKU of every new line.'; END IF;
      SELECT btrim(m.sku_name::text) INTO v_sku FROM public.sku_master m
      WHERE upper(btrim(m.sku_name::text)) = upper(v_sku) ORDER BY m.is_active DESC NULLS LAST LIMIT 1;
      IF NOT FOUND THEN RAISE EXCEPTION '% is not in SKU Master. Pick the SKU from the list.', btrim(e->>'sku_name'); END IF;
      BEGIN v_rate := round(nullif(e->>'rate','')::numeric, 2);
      EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter the rate per case of %.', v_sku; END;
      IF v_rate IS NULL OR v_rate <= 0 OR v_rate > 1000000 THEN RAISE EXCEPTION 'Enter the rate per case of %.', v_sku; END IF;
    END IF;
    IF upper(v_sku) || '|' || coalesce(e->>'item_id','') = ANY (v_seen) THEN
      RAISE EXCEPTION '% is on two lines. Put all of it on one line.', v_sku;
    END IF;
    v_seen := v_seen || (upper(v_sku) || '|' || coalesce(e->>'item_id',''));
    v_ppc := public.lwb_pr_pcs_per_case(v_sku);
    IF v_pcs > 0 AND coalesce(v_ppc,0) <= 0 THEN
      RAISE EXCEPTION '% has no PCS per case in SKU Master. Enter cases, or set PCS per case first.', v_sku;
    END IF;
    v_qty := round(v_cs + CASE WHEN v_pcs > 0 THEN v_pcs::numeric / v_ppc ELSE 0 END, 6);
    IF nullif(e->>'item_id','') IS NOT NULL THEN
      v_left := v_i.cases - coalesce((SELECT sum(ri.qty_cases) FROM public.lwb_party_return_items ri
                                      JOIN public.lwb_party_returns r ON r.id = ri.return_id
                                      WHERE ri.order_item_id = v_i.id AND r.cancelled_at IS NULL),0);
      IF v_qty > v_left + 0.000001 THEN
        RAISE EXCEPTION '%: only % CS is left to return on this bill.', v_sku, trim_scale(round(greatest(v_left,0),2));
      END IF;
    END IF;
    v_lines := v_lines || jsonb_build_object('item_id', nullif(e->>'item_id',''), 'sku', v_sku, 'cases', v_cs, 'pcs', v_pcs,
                 'ppc', v_ppc, 'qty', v_qty, 'rate', v_rate, 'amount', round(v_qty * v_rate, 2));
    v_total := v_total + round(v_qty * v_rate, 2);
    v_skus := v_skus || upper(v_sku);
  END LOOP;
  IF jsonb_array_length(v_lines) = 0 THEN RAISE EXCEPTION 'Enter the cases or pieces returned.'; END IF;
  v_total := round(v_total, 2);
  IF v_total <= 0 THEN RAISE EXCEPTION 'Return value is zero.'; END IF;

  -- brand: the only brand of these SKUs (party money of one brand never goes to another)
  SELECT CASE WHEN count(DISTINCT m.company_id) = 1 THEN (array_agg(DISTINCT m.company_id) FILTER (WHERE m.company_id IS NOT NULL))[1] END
    INTO v_company FROM public.sku_master m WHERE upper(btrim(m.sku_name::text)) = ANY (v_skus);

  v_no := 'RET-' || lpad(nextval('public.lwb_party_return_no_seq')::text, 4, '0');
  INSERT INTO public.lwb_party_returns (return_no, party, order_id, company_id, return_date, amount, note, created_by)
  VALUES (v_no, v_party, p_order_id, v_company, p_return_date, v_total, v_note, auth.uid())
  RETURNING id INTO v_id;
  INSERT INTO public.lwb_party_return_items (return_id, order_item_id, sku_name, cases, pcs, pcs_per_case, qty_cases, rate, amount)
  SELECT v_id, l->>'item_id', l->>'sku', (l->>'cases')::int, (l->>'pcs')::int, (l->>'ppc')::int,
         (l->>'qty')::numeric, (l->>'rate')::numeric, (l->>'amount')::numeric
  FROM jsonb_array_elements(v_lines) l;

  -- Billed PO: credit note on the bill at once, so Due / To collect go down.
  IF v_billed THEN
    IF v_cn IS NOT NULL AND (length(v_cn) > 100 OR EXISTS (SELECT 1 FROM public.lwb_tally_notes n WHERE n.order_id = p_order_id
               AND n.kind = 'CREDIT' AND upper(n.note_no) = upper(v_cn) AND n.cancelled_at IS NULL)) THEN
      RAISE EXCEPTION 'Credit note % is already entered on this PO.', v_cn;
    END IF;
    INSERT INTO public.lwb_tally_notes (order_id, kind, note_no, note_date, amount, reason, created_by)
    VALUES (p_order_id, 'CREDIT', coalesce(v_cn, v_no), p_return_date, v_total,
            left('Goods return ' || v_no || coalesce(' · ' || v_note, ''), 300), auth.uid())
    RETURNING id INTO v_note_id;
    UPDATE public.lwb_party_returns SET note_id = v_note_id WHERE id = v_id;
  END IF;

  RETURN jsonb_build_object('id', v_id, 'return_no', v_no, 'party', v_party, 'parent', public.lwb_party_parent(v_party),
    'order_no', v_order_no, 'amount', v_total, 'credit_note', CASE WHEN v_billed THEN coalesce(v_cn, v_no) END,
    'lines', v_lines);
END;
$fn$;

-- A wrong return is cancelled (kept), never deleted. Its credit note is cancelled too.
CREATE OR REPLACE FUNCTION public.lwb_party_return_cancel(p_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r record;
BEGIN
  IF NOT public.lwb_tally_staff() THEN RAISE EXCEPTION 'Only active Accounts or Admin can cancel a return'; END IF;
  UPDATE public.lwb_party_returns SET cancelled_at = now(), cancelled_by = auth.uid()
  WHERE id = p_id AND cancelled_at IS NULL RETURNING * INTO r;
  IF NOT FOUND THEN RAISE EXCEPTION 'Return not found or already cancelled'; END IF;
  IF r.note_id IS NOT NULL THEN
    UPDATE public.lwb_tally_notes SET cancelled_at = now(), cancelled_by = auth.uid()
    WHERE id = r.note_id AND cancelled_at IS NULL;
  END IF;
  RETURN 'CANCELLED';
END;
$fn$;

-- Returns of the last p_days (cancelled ones of the last 30 days too), newest first.
CREATE OR REPLACE FUNCTION public.lwb_party_return_list(p_days integer DEFAULT 400)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN RAISE EXCEPTION 'Active Admin / Accounts role required.'; END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id, 'return_no', r.return_no, 'party', r.party, 'parent', public.lwb_party_parent(r.party),
      'order_id', r.order_id, 'order_no', o.order_no, 'invoice_no', t.invoice_no, 'company_id', r.company_id,
      'return_date', r.return_date, 'amount', r.amount, 'note', r.note,
      'credit_note', n.note_no, 'cancelled', r.cancelled_at IS NOT NULL, 'created_at', r.created_at,
      'by', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = r.created_by),
      'items', (SELECT coalesce(jsonb_agg(jsonb_build_object('sku', i.sku_name, 'cases', i.cases, 'pcs', i.pcs, 'ppc', i.pcs_per_case,
                        'qty', i.qty_cases, 'rate', i.rate, 'amount', i.amount, 'on_bill', i.order_item_id IS NOT NULL) ORDER BY i.sku_name), '[]'::jsonb)
                FROM public.lwb_party_return_items i WHERE i.return_id = r.id))
      ORDER BY r.return_date DESC, r.created_at DESC), '[]'::jsonb)
    FROM public.lwb_party_returns r
    LEFT JOIN public.orders o ON o.id = r.order_id
    LEFT JOIN public.lwb_tally_invoices t ON t.order_id = r.order_id
    LEFT JOIN public.lwb_tally_notes n ON n.id = r.note_id
    WHERE r.return_date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - least(greatest(coalesce(p_days,400),1),2000)
      AND (r.cancelled_at IS NULL OR r.cancelled_at >= now() - interval '30 days'));
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_pr_pcs_per_case(text), public.lwb_pr_line_cases(numeric,numeric,numeric)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_party_return_form(uuid,text), public.lwb_party_return_save(uuid,text,date,jsonb,text,text),
  public.lwb_party_return_cancel(uuid), public.lwb_party_return_list(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_return_form(uuid,text), public.lwb_party_return_save(uuid,text,date,jsonb,text,text),
  public.lwb_party_return_cancel(uuid), public.lwb_party_return_list(integer) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'party return table' AS item, (to_regclass('public.lwb_party_returns') IS NOT NULL)::text AS ok
UNION ALL SELECT 'save return', (to_regprocedure('public.lwb_party_return_save(uuid,text,date,jsonb,text,text)') IS NOT NULL)::text
UNION ALL SELECT 'return list', (to_regprocedure('public.lwb_party_return_list(integer)') IS NOT NULL)::text;
