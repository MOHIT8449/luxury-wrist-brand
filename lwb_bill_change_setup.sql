-- LUXURY WRIST BRAND ERP — BILL NAMES STAY ON THE BILL; PO ITEM CHANGES GO TO ADMIN
--
-- Runs by itself when merged to main (after lwb_party_group_billing_setup.sql and
-- lwb_bill_before_loading_setup.sql). Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (3 Nov 2026), Billing & Outstanding:
--   1. A Tally bill name typed by Accounts (often a spelling variant) must not become a party / group link.
--      lwb_save_tally_bills keeps the name only on the bill line (lwb_tally_invoices.bills); it no longer
--      adds rows to lwb_tally_party_map. Money stays on the PO's main party as before. Links made by hand
--      in Party groups / Tally Party Mapping still work.
--   2. One PO can have many Tally bills (name + invoice no. + amount each) — unchanged, already allowed.
--   3. Items of a PO (qty + / −, rate, SKU replaced, SKU added / removed) are changed by Accounts only
--      through Admin: lwb_bill_change_request saves the change as WAITING and bells Admin with the value
--      difference. Admin approves (lwb_bill_change_decide) -> the PO lines change, and when the Tally bill
--      is entered its amount (and the chosen bill line) moves by the same difference, so To collect follows
--      the approved value. Send back -> nothing changes. A change made by Admin is applied at once.
--      Before loading the approved qty is changed; after loading the loaded qty (what reached the party).

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Tally bills: bill name stays on the bill line, no party link is made
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
-- 2. PO item changes waiting for Admin
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_bill_changes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  change_no     bigint GENERATED BY DEFAULT AS IDENTITY,
  order_id      uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  status        text NOT NULL DEFAULT 'WAITING' CHECK (status IN ('WAITING','APPROVED','SENT_BACK','REPLACED')),
  qty_col       text NOT NULL CHECK (qty_col IN ('approved_qty','loaded_qty')),
  lines         jsonb NOT NULL DEFAULT '[]'::jsonb,
  old_value     numeric(14,2) NOT NULL,
  new_value     numeric(14,2) NOT NULL,
  diff          numeric(14,2) NOT NULL,
  reason        text,
  note          text,
  bill_no       text,
  bill_applied  jsonb,
  requested_by  uuid,
  requested_at  timestamptz NOT NULL DEFAULT now(),
  decided_by    uuid,
  decided_at    timestamptz,
  reply         text
);
CREATE INDEX IF NOT EXISTS lwb_bill_changes_order ON public.lwb_bill_changes(order_id, requested_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_bill_changes_one_waiting ON public.lwb_bill_changes(order_id) WHERE status = 'WAITING';
ALTER TABLE public.lwb_bill_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_bill_changes FROM PUBLIC, anon, authenticated;

-- quantity the bill counts: approved qty before loading, loaded qty after
CREATE OR REPLACE FUNCTION public.lwb_bill_qty_col(p_status text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE WHEN coalesce(lower(btrim(p_status)),'') IN ('loaded','invoiced','dispatched','delivered')
              THEN 'loaded_qty' ELSE 'approved_qty' END;
$fn$;

-- Items of a PO for the Billing popup: lines, SKU list, earlier changes. Accounts / Admin.
CREATE OR REPLACE FUNCTION public.lwb_bill_change_items(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o record;
  v_col text;
  v_skus jsonb := '[]'::jsonb;
BEGIN
  IF NOT public.lwb_tally_staff() THEN RAISE EXCEPTION 'Active Admin / Accounts role required.'; END IF;
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

-- Applies a saved change to the PO lines and the Tally bill. Internal (called by request / decide).
CREATE OR REPLACE FUNCTION public.lwb_bill_change_apply(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  c public.lwb_bill_changes%ROWTYPE;
  l jsonb;
  v_cur record;
  v_qty numeric;
  v_t record;
  v_idx int := 0;
  v_i int := 0;
  v_b jsonb;
  v_new jsonb := '[]'::jsonb;
  v_applied jsonb;
  v_snap jsonb;
BEGIN
  SELECT * INTO c FROM public.lwb_bill_changes WHERE id = p_id FOR UPDATE;
  -- the PO must still be as it was when the change was asked
  FOR l IN SELECT * FROM jsonb_array_elements(c.lines) LOOP
    CONTINUE WHEN coalesce(l->>'item_id','') = '';
    SELECT btrim(i.sku_name::text) AS sku, coalesce(i.rate,0) AS rate,
           CASE WHEN c.qty_col = 'loaded_qty' THEN coalesce(i.loaded_qty,0) ELSE coalesce(i.approved_qty, i.ordered_qty, 0) END AS qty
      INTO v_cur FROM public.order_items i WHERE i.order_id = c.order_id AND i.id::text = l->>'item_id';
    IF NOT FOUND OR upper(v_cur.sku) <> upper(l->>'sku_old') OR v_cur.qty <> (l->>'qty_old')::numeric
       OR v_cur.rate <> (l->>'rate_old')::numeric THEN
      RAISE EXCEPTION 'STALE: PO lines changed after this request (%). Accounts should send the change again.', l->>'sku_old';
    END IF;
  END LOOP;

  -- after loading: godown stock follows the change (lwb_bill_change_stock_setup.sql)
  IF to_regprocedure('public.lwb_bill_change_stock_before(uuid)') IS NOT NULL THEN
    EXECUTE 'SELECT public.lwb_bill_change_stock_before($1)' INTO v_snap USING p_id;
  END IF;

  FOR l IN SELECT * FROM jsonb_array_elements(c.lines) LOOP
    v_qty := (l->>'qty')::numeric;
    IF coalesce(l->>'item_id','') = '' THEN
      INSERT INTO public.order_items (order_id, sku_name, ordered_qty, approved_qty, loaded_qty, rate, unit_weight, amount, total_weight, entry_uom)
      VALUES (c.order_id, l->>'sku', 0, v_qty, CASE WHEN c.qty_col = 'loaded_qty' THEN v_qty ELSE 0 END,
              (l->>'rate')::numeric, 0, v_qty * (l->>'rate')::numeric, 0, 'CS');
    ELSIF c.qty_col = 'loaded_qty' THEN
      UPDATE public.order_items SET sku_name = l->>'sku', rate = (l->>'rate')::numeric, loaded_qty = v_qty
      WHERE order_id = c.order_id AND id::text = l->>'item_id';
    ELSE
      UPDATE public.order_items SET sku_name = l->>'sku', rate = (l->>'rate')::numeric, approved_qty = v_qty,
             amount = v_qty * (l->>'rate')::numeric
      WHERE order_id = c.order_id AND id::text = l->>'item_id';
    END IF;
  END LOOP;
  IF v_snap IS NOT NULL THEN
    EXECUTE 'SELECT public.lwb_bill_change_stock_after($1, $2)' USING p_id, v_snap;
  END IF;

  -- Tally bill already entered: its amount follows the approved value (the chosen bill line takes the difference)
  SELECT t.amount, t.bills INTO v_t FROM public.lwb_tally_invoices t WHERE t.order_id = c.order_id FOR UPDATE;
  IF FOUND AND v_t.amount IS NOT NULL AND c.diff <> 0 THEN
    IF round(v_t.amount + c.diff, 2) <= 0 THEN
      RAISE EXCEPTION 'The Tally bill % would go to zero or below. Use a credit note instead.', v_t.amount;
    END IF;
    IF jsonb_array_length(coalesce(v_t.bills,'[]'::jsonb)) > 0 THEN
      FOR v_b IN SELECT * FROM jsonb_array_elements(v_t.bills) LOOP
        IF c.bill_no IS NOT NULL AND upper(btrim(v_b->>'no')) = upper(btrim(c.bill_no)) THEN v_idx := v_i; END IF;
        v_i := v_i + 1;
      END LOOP;
      v_i := 0;
      FOR v_b IN SELECT * FROM jsonb_array_elements(v_t.bills) LOOP
        IF v_i = v_idx THEN
          IF round((v_b->>'amount')::numeric + c.diff, 2) <= 0 THEN
            RAISE EXCEPTION 'Bill % would go to zero or below. Choose another bill or use a credit note.', v_b->>'no';
          END IF;
          v_applied := jsonb_build_object('no', v_b->>'no', 'firm', v_b->>'firm', 'from', (v_b->>'amount')::numeric,
                                          'to', round((v_b->>'amount')::numeric + c.diff, 2));
          v_b := jsonb_set(v_b, '{amount}', to_jsonb(round((v_b->>'amount')::numeric + c.diff, 2)));
        END IF;
        v_new := v_new || v_b;
        v_i := v_i + 1;
      END LOOP;
    ELSE
      v_applied := jsonb_build_object('no', NULL, 'from', v_t.amount, 'to', round(v_t.amount + c.diff, 2));
    END IF;
    UPDATE public.lwb_tally_invoices
       SET amount = round(amount + c.diff, 2),
           bills = CASE WHEN jsonb_array_length(coalesce(bills,'[]'::jsonb)) > 0 THEN v_new ELSE bills END
     WHERE order_id = c.order_id;
  END IF;
  UPDATE public.lwb_bill_changes SET bill_applied = v_applied WHERE id = p_id;
  RETURN v_applied;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_change_apply(uuid) FROM PUBLIC, anon, authenticated;

-- Accounts / Admin: p_items = the full new list of lines [{item_id (blank = new SKU), sku_name, qty, rate}].
-- A line left out is removed (qty 0). Accounts -> WAITING for Admin; Admin -> applied at once.
CREATE OR REPLACE FUNCTION public.lwb_bill_change_request(p_order_id uuid, p_items jsonb, p_reason text DEFAULT NULL,
                                                         p_note text DEFAULT NULL, p_bill_no text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o record;
  v_col text;
  v_admin boolean := public.lwb_price_admin_safe();
  e jsonb;
  r record;
  v_lines jsonb := '[]'::jsonb;
  v_ids text[] := '{}';
  v_seen text[] := '{}';
  v_sku text; v_qty numeric; v_rate numeric;
  v_old numeric := 0; v_newv numeric := 0;
  v_id uuid;
  v_kind text[];
  v_msg text;
  v_res jsonb;
BEGIN
  IF NOT public.lwb_tally_staff() THEN RAISE EXCEPTION 'Only active Accounts or Admin can change PO items.'; END IF;
  SELECT o.id, o.order_no::text AS order_no, btrim(o.customer_name::text) AS party, lower(btrim(coalesce(o.status::text,''))) AS status
    INTO v_o FROM public.orders o WHERE o.id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF v_o.status IN ('pending','cancelled','canceled','rejected','draft') OR v_o.status = '' THEN
    RAISE EXCEPTION 'PO % is %. Only an approved PO can be changed here.', v_o.order_no, coalesce(nullif(v_o.status,''),'not approved');
  END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'A PO needs at least one SKU line.';
  END IF;
  IF jsonb_array_length(p_items) > 100 THEN RAISE EXCEPTION 'At most 100 lines.'; END IF;
  v_col := public.lwb_bill_qty_col(v_o.status);

  FOR e IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_sku := btrim(coalesce(e->>'sku_name',''));
    IF v_sku = '' THEN RAISE EXCEPTION 'Every line needs an SKU.'; END IF;
    IF coalesce(e->>'qty','') !~ '^\d{1,6}$' THEN RAISE EXCEPTION 'Enter whole cases for %.', v_sku; END IF;
    IF coalesce(e->>'rate','') !~ '^\d{1,7}(\.\d{1,2})?$' THEN RAISE EXCEPTION 'Enter the rate for %.', v_sku; END IF;
    v_qty := (e->>'qty')::numeric; v_rate := (e->>'rate')::numeric;
    IF (v_qty > 0) AND upper(v_sku) = ANY (v_seen) THEN RAISE EXCEPTION '% is on two lines. Put all its cases on one line.', v_sku; END IF;
    IF v_qty > 0 THEN v_seen := v_seen || upper(v_sku); END IF;

    IF coalesce(e->>'item_id','') <> '' THEN
      SELECT btrim(i.sku_name::text) AS sku, coalesce(i.rate,0) AS rate,
             CASE WHEN v_col = 'loaded_qty' THEN coalesce(i.loaded_qty,0) ELSE coalesce(i.approved_qty, i.ordered_qty, 0) END AS qty
        INTO r FROM public.order_items i WHERE i.order_id = p_order_id AND i.id::text = e->>'item_id';
      IF NOT FOUND THEN RAISE EXCEPTION 'A line of % is not on this PO any more. Open the PO again.', v_sku; END IF;
      IF e->>'item_id' = ANY (v_ids) THEN RAISE EXCEPTION 'A PO line is sent twice.'; END IF;
      v_ids := v_ids || (e->>'item_id');
      IF upper(r.sku) <> upper(v_sku) AND to_regclass('public.sku_master') IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM public.sku_master s WHERE upper(btrim(s.sku_name)) = upper(v_sku) AND s.is_active IS TRUE) THEN
        RAISE EXCEPTION 'SKU % is not in the SKU Master.', v_sku;
      END IF;
      v_old := v_old + r.qty * r.rate;
      v_newv := v_newv + v_qty * v_rate;
      v_kind := '{}';
      IF upper(r.sku) <> upper(v_sku) THEN v_kind := v_kind || 'SKU'::text; END IF;
      IF r.qty <> v_qty THEN v_kind := v_kind || CASE WHEN v_qty = 0 THEN 'REMOVE' ELSE 'QTY' END; END IF;
      IF r.rate <> v_rate THEN v_kind := v_kind || 'RATE'::text; END IF;
      IF cardinality(v_kind) > 0 THEN
        v_lines := v_lines || jsonb_build_object('item_id', e->>'item_id', 'sku_old', r.sku, 'sku', v_sku,
          'qty_old', r.qty, 'qty', v_qty, 'rate_old', r.rate, 'rate', v_rate, 'kind', to_jsonb(v_kind),
          'diff', round(v_qty * v_rate - r.qty * r.rate, 2));
      END IF;
    ELSE
      CONTINUE WHEN v_qty = 0;
      IF to_regclass('public.sku_master') IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM public.sku_master s WHERE upper(btrim(s.sku_name)) = upper(v_sku) AND s.is_active IS TRUE) THEN
        RAISE EXCEPTION 'SKU % is not in the SKU Master.', v_sku;
      END IF;
      v_newv := v_newv + v_qty * v_rate;
      v_lines := v_lines || jsonb_build_object('item_id', NULL, 'sku_old', NULL, 'sku', v_sku, 'qty_old', 0, 'qty', v_qty,
        'rate_old', NULL, 'rate', v_rate, 'kind', '["ADD"]'::jsonb, 'diff', round(v_qty * v_rate, 2));
    END IF;
  END LOOP;

  -- lines not sent = removed
  FOR r IN SELECT i.id::text AS id, btrim(i.sku_name::text) AS sku, coalesce(i.rate,0) AS rate,
                  CASE WHEN v_col = 'loaded_qty' THEN coalesce(i.loaded_qty,0) ELSE coalesce(i.approved_qty, i.ordered_qty, 0) END AS qty
           FROM public.order_items i WHERE i.order_id = p_order_id AND NOT (i.id::text = ANY (v_ids)) LOOP
    v_old := v_old + r.qty * r.rate;
    CONTINUE WHEN r.qty = 0;
    v_lines := v_lines || jsonb_build_object('item_id', r.id, 'sku_old', r.sku, 'sku', r.sku, 'qty_old', r.qty, 'qty', 0,
      'rate_old', r.rate, 'rate', r.rate, 'kind', '["REMOVE"]'::jsonb, 'diff', round(-r.qty * r.rate, 2));
  END LOOP;

  IF jsonb_array_length(v_lines) = 0 THEN RAISE EXCEPTION 'Nothing changed.'; END IF;
  IF v_newv <= 0 THEN RAISE EXCEPTION 'The PO would have no value left. Cancel the PO instead.'; END IF;
  IF NOT v_admin AND nullif(btrim(coalesce(p_reason,'')),'') IS NULL THEN RAISE EXCEPTION 'Choose the reason for the change.'; END IF;

  -- a newer request replaces the one still waiting
  UPDATE public.lwb_bill_changes SET status = 'REPLACED', decided_at = now(), decided_by = auth.uid()
   WHERE order_id = p_order_id AND status = 'WAITING';
  INSERT INTO public.lwb_bill_changes (order_id, status, qty_col, lines, old_value, new_value, diff, reason, note, bill_no, requested_by)
  VALUES (p_order_id, 'WAITING', v_col, v_lines, round(v_old,2), round(v_newv,2), round(v_newv - v_old,2),
          left(nullif(btrim(coalesce(p_reason,'')),''),120), left(nullif(btrim(coalesce(p_note,'')),''),500),
          nullif(btrim(coalesce(p_bill_no,'')),''), auth.uid())
  RETURNING id INTO v_id;

  IF v_admin THEN
    v_res := public.lwb_bill_change_apply(v_id);
    UPDATE public.lwb_bill_changes SET status = 'APPROVED', decided_by = auth.uid(), decided_at = now() WHERE id = v_id;
    RETURN jsonb_build_object('id', v_id, 'status', 'APPROVED', 'diff', round(v_newv - v_old,2), 'bill', v_res);
  END IF;

  v_msg := v_o.order_no || ' · ' || v_o.party || ' · Rs ' || to_char(round(v_old,2),'FM9999999990.00') || ' -> Rs ' ||
           to_char(round(v_newv,2),'FM9999999990.00') || ' (' || CASE WHEN v_newv >= v_old THEN '+' ELSE '-' END ||
           'Rs ' || to_char(abs(round(v_newv - v_old,2)),'FM9999999990.00') || ')' ||
           coalesce(' · ' || nullif(btrim(coalesce(p_reason,'')),''), '');
  BEGIN
    UPDATE public.erp_notifications SET is_read = true
     WHERE order_id = p_order_id AND is_read = false AND notification_type = 'BILL_CHANGE_APPROVAL';
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, 'PO change — Admin OK needed', v_msg, 'BILL_CHANGE_APPROVAL', p_order_id
    FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'admin';
  EXCEPTION WHEN others THEN NULL;  -- a bell never stops the request
  END;
  RETURN jsonb_build_object('id', v_id, 'status', 'WAITING', 'diff', round(v_newv - v_old,2));
END;
$fn$;

-- Admin: approve (the change is applied) or send back (nothing changes).
CREATE OR REPLACE FUNCTION public.lwb_bill_change_decide(p_id uuid, p_approve boolean, p_reply text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  c public.lwb_bill_changes%ROWTYPE;
  v_o record;
  v_res jsonb;
BEGIN
  IF NOT public.lwb_price_admin_safe() THEN RAISE EXCEPTION 'Only Admin can approve a PO change.'; END IF;
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

-- List for the Billing page: waiting ones + the last p_days days. Accounts / Admin.
CREATE OR REPLACE FUNCTION public.lwb_bill_change_list(p_days integer DEFAULT 30)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_staff() THEN RAISE EXCEPTION 'Active Admin / Accounts role required.'; END IF;
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

-- Admin check that works even if lwb_rajni_rate_limit_setup.sql was not run.
CREATE OR REPLACE FUNCTION public.lwb_price_admin_safe()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) = 'admin');
$fn$;

REVOKE ALL ON FUNCTION public.lwb_bill_qty_col(text), public.lwb_bill_change_items(uuid),
  public.lwb_bill_change_request(uuid,jsonb,text,text,text), public.lwb_bill_change_decide(uuid,boolean,text),
  public.lwb_bill_change_list(integer), public.lwb_price_admin_safe() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_bill_qty_col(text), public.lwb_bill_change_items(uuid),
  public.lwb_bill_change_request(uuid,jsonb,text,text,text), public.lwb_bill_change_decide(uuid,boolean,text),
  public.lwb_bill_change_list(integer), public.lwb_price_admin_safe() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'PO change table' AS item, (to_regclass('public.lwb_bill_changes') IS NOT NULL)::text AS ok
UNION ALL SELECT 'send change to Admin', (to_regprocedure('public.lwb_bill_change_request(uuid,jsonb,text,text,text)') IS NOT NULL)::text
UNION ALL SELECT 'Admin approve', (to_regprocedure('public.lwb_bill_change_decide(uuid,boolean,text)') IS NOT NULL)::text;
