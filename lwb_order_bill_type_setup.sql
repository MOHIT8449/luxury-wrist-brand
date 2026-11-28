-- LUXURY WRIST BRAND ERP — GST or CASH bill on every PO (Mohit, 28 Nov 2026)
--
-- Mohit: an order comes from a party; it must be clear whether its bill is a GST bill or a Cash bill.
--   * The Salesman does NOT choose. He only writes a note ("party wants cash bill").
--   * Sales Head (role manager) and Admin choose GST / Cash. A party has a default that fills new POs by itself.
--   * Accounts sees GST / Cash on Bills to make. Making the other kind asks a reason, keeps it on record, Admin gets a bell.
--   * Payment against a bill: GST bill should come by Bank / UPI / Cheque, Cash bill in cash. A different mode asks
--     what happened, is kept on record, and Admin + Sales Head get a bell. Admin OKs each one on "GST / Cash check".
--
-- Adds columns + one small table + RPCs. Nothing is dropped or deleted. No stock, bill amount, payment, ledger or
-- Tally data is changed. Safe to run again.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_customer_master
  ADD COLUMN IF NOT EXISTS bill_type text;
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS bill_type text,
  ADD COLUMN IF NOT EXISTS bill_type_set_by uuid,
  ADD COLUMN IF NOT EXISTS bill_type_set_at timestamptz,
  ADD COLUMN IF NOT EXISTS bill_note text,
  ADD COLUMN IF NOT EXISTS bill_made_as text;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_customer_master_bill_type_check') THEN
    ALTER TABLE public.lwb_customer_master ADD CONSTRAINT lwb_customer_master_bill_type_check CHECK (bill_type IS NULL OR bill_type IN ('GST','CASH'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'orders_bill_type_check') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_bill_type_check CHECK (bill_type IS NULL OR bill_type IN ('GST','CASH'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'orders_bill_made_as_check') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_bill_made_as_check CHECK (bill_made_as IS NULL OR bill_made_as IN ('GST','CASH'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'orders_bill_note_len') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_bill_note_len CHECK (bill_note IS NULL OR length(bill_note) <= 300);
  END IF;
END $$;

-- POs made from this day need GST / Cash before the bill; older POs are billed as before (no block).
CREATE TABLE IF NOT EXISTS public.lwb_bill_type_settings (
  id int PRIMARY KEY CHECK (id = 1),
  start_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.lwb_bill_type_settings(id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.lwb_bill_type_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_bill_type_settings FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Who is who
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_bt_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bt_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_bt_role() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_bt_name()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(nullif(btrim(p.full_name), ''), 'User') FROM public.user_profiles p WHERE p.id = auth.uid();
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bt_name() FROM PUBLIC, anon;

-- ---------------------------------------------------------------------------
-- 3. Guard on orders: new PO takes the party default; only Sales Head / Admin change it
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_orders_bill_type_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_bt_role();
  v_head boolean := v_role IN ('admin','manager');
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- A Salesman (or anyone not Sales Head / Admin) can not set it; the party default fills it.
    IF NEW.bill_type IS NULL OR (auth.uid() IS NOT NULL AND NOT v_head) THEN
      NEW.bill_type := (SELECT c.bill_type FROM public.lwb_customer_master c
                        WHERE upper(btrim(c.customer_name)) = upper(btrim(coalesce(NEW.customer_name, '')))
                        ORDER BY c.is_active DESC NULLS LAST LIMIT 1);
      NEW.bill_type_set_by := NULL; NEW.bill_type_set_at := NULL;
    ELSE
      NEW.bill_type_set_by := auth.uid(); NEW.bill_type_set_at := now();
    END IF;
    NEW.bill_made_as := NULL;
    RETURN NEW;
  END IF;

  IF NEW.bill_made_as IS DISTINCT FROM OLD.bill_made_as AND auth.uid() IS NOT NULL
     AND coalesce(current_setting('lwb.bt_rpc', true), '') <> '1' THEN
    RAISE EXCEPTION 'Bill made as GST / Cash is saved only from Bills to make' USING ERRCODE = '42501';
  END IF;

  IF NEW.bill_type IS DISTINCT FROM OLD.bill_type THEN
    IF auth.uid() IS NOT NULL THEN
      IF NOT v_head THEN
        RAISE EXCEPTION 'Only Sales Head or Admin can choose GST / Cash bill' USING ERRCODE = '42501';
      END IF;
      IF EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = NEW.id)
         AND coalesce(current_setting('lwb.bt_rpc', true), '') <> '1' THEN
        RAISE EXCEPTION 'The bill of this PO is already made. Admin changes GST / Cash with a reason.' USING ERRCODE = '42501';
      END IF;
    END IF;
    NEW.bill_type_set_by := auth.uid(); NEW.bill_type_set_at := now();
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_orders_bill_type_guard() FROM PUBLIC, anon;
DROP TRIGGER IF EXISTS trg_lwb_orders_bill_type_guard ON public.orders;
CREATE TRIGGER trg_lwb_orders_bill_type_guard BEFORE INSERT OR UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.lwb_orders_bill_type_guard();

-- ---------------------------------------------------------------------------
-- 4. Log of every GST / Cash change
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_bill_type_log (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  order_id uuid REFERENCES public.orders(id) ON DELETE CASCADE,
  party text,
  old_type text,
  new_type text,
  reason text CHECK (reason IS NULL OR length(reason) <= 300),
  by_id uuid,
  by_name text,
  at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_bill_type_log_order_idx ON public.lwb_bill_type_log(order_id);
ALTER TABLE public.lwb_bill_type_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_bill_type_log FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Sales Head / Admin set GST / Cash on a PO (and the party default if asked)
--    After the bill is made: Admin only, with a reason; Accounts get a bell.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_set_order_bill_type(p_order_id uuid, p_type text, p_reason text DEFAULT NULL,
                                                         p_party_default boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_bt_role();
  v_type text := upper(btrim(coalesce(p_type, '')));
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_o public.orders%ROWTYPE;
  v_billed boolean;
  v_name text := public.lwb_bt_name();
BEGIN
  IF v_role IS NULL OR v_role NOT IN ('admin','manager') THEN
    RAISE EXCEPTION 'Only Sales Head or Admin can choose GST / Cash bill' USING ERRCODE = '42501';
  END IF;
  IF v_type NOT IN ('GST','CASH') THEN RAISE EXCEPTION 'Choose GST or Cash'; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PO not found'; END IF;
  v_billed := EXISTS (SELECT 1 FROM public.lwb_tally_invoices t WHERE t.order_id = p_order_id);
  IF v_billed AND v_o.bill_type IS DISTINCT FROM v_type THEN
    IF v_role <> 'admin' THEN RAISE EXCEPTION 'The bill of this PO is already made. Only Admin can change GST / Cash now.' USING ERRCODE = '42501'; END IF;
    IF v_reason IS NULL OR length(v_reason) < 3 THEN RAISE EXCEPTION 'Write the reason for changing GST / Cash after the bill is made'; END IF;
  END IF;

  IF v_o.bill_type IS DISTINCT FROM v_type THEN
    PERFORM set_config('lwb.bt_rpc', '1', true);
    UPDATE public.orders SET bill_type = v_type WHERE id = p_order_id;
    PERFORM set_config('lwb.bt_rpc', '', true);
    INSERT INTO public.lwb_bill_type_log(order_id, party, old_type, new_type, reason, by_id, by_name)
    VALUES (p_order_id, v_o.customer_name, v_o.bill_type, v_type, left(v_reason, 300), auth.uid(), v_name);
    -- Accounts must know when the kind changes once the PO is with them (loaded / billed) or was set before.
    IF v_billed OR v_o.bill_type IS NOT NULL THEN
      INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
      SELECT p.id, left('Bill type changed: ' || coalesce(v_o.order_no, 'PO') || ' → ' || v_type, 200),
             left(concat_ws(' · ', v_o.customer_name, coalesce(v_o.bill_type, 'not set') || ' → ' || v_type,
                            CASE WHEN v_billed THEN 'bill already made' END, v_reason, 'by ' || v_name), 600),
             'BILL_TYPE_CHANGED', p_order_id
      FROM public.user_profiles p
      WHERE p.active = true AND lower(btrim(p.role)) IN ('accounts','admin') AND p.id IS DISTINCT FROM auth.uid();
    END IF;
  END IF;

  IF p_party_default THEN
    UPDATE public.lwb_customer_master SET bill_type = v_type
    WHERE upper(btrim(customer_name)) = upper(btrim(coalesce(v_o.customer_name, '')));
  END IF;

  RETURN jsonb_build_object('order_id', p_order_id, 'bill_type', v_type, 'billed', v_billed,
                            'party_default', CASE WHEN p_party_default THEN v_type END);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_set_order_bill_type(uuid, text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_order_bill_type(uuid, text, text, boolean) TO authenticated;

-- Party default only (Party Master / approve screen).
CREATE OR REPLACE FUNCTION public.lwb_set_party_bill_type(p_party text, p_type text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_type text := nullif(upper(btrim(coalesce(p_type, ''))), '');
BEGIN
  IF coalesce(public.lwb_bt_role(), '') NOT IN ('admin','manager') THEN
    RAISE EXCEPTION 'Only Sales Head or Admin can set the party GST / Cash default' USING ERRCODE = '42501';
  END IF;
  IF v_type IS NOT NULL AND v_type NOT IN ('GST','CASH') THEN RAISE EXCEPTION 'Choose GST or Cash'; END IF;
  UPDATE public.lwb_customer_master SET bill_type = v_type WHERE upper(btrim(customer_name)) = upper(btrim(coalesce(p_party, '')));
  IF NOT FOUND THEN RAISE EXCEPTION 'Party not found'; END IF;
  RETURN v_type;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_set_party_bill_type(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_party_bill_type(text, text) TO authenticated;

-- Salesman's note on his PO (or Sales Head / Admin on any PO).
CREATE OR REPLACE FUNCTION public.lwb_set_order_bill_note(p_order_id uuid, p_note text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_note text := nullif(left(regexp_replace(btrim(coalesce(p_note, '')), '\s+', ' ', 'g'), 300), '');
        v_by uuid;
BEGIN
  SELECT created_by INTO v_by FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PO not found'; END IF;
  IF auth.uid() IS NULL OR (v_by IS DISTINCT FROM auth.uid() AND coalesce(public.lwb_bt_role(), '') NOT IN ('admin','manager')) THEN
    RAISE EXCEPTION 'Only the person who made this PO, Sales Head or Admin can write its bill note' USING ERRCODE = '42501';
  END IF;
  UPDATE public.orders SET bill_note = v_note WHERE id = p_order_id;
  RETURN v_note;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_set_order_bill_note(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_order_bill_note(uuid, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Read GST / Cash of many POs (Bills to make, payment popups, PO list)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_order_bill_types(p_ids uuid[])
RETURNS TABLE(order_id uuid, bill_type text, bill_made_as text, bill_note text, set_by text, set_at timestamptz,
              party_default text, required boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT o.id, o.bill_type, o.bill_made_as, o.bill_note,
         CASE WHEN o.bill_type_set_by IS NULL THEN NULL ELSE coalesce(nullif(btrim(u.full_name), ''), 'Sales Head') END,
         o.bill_type_set_at,
         (SELECT c.bill_type FROM public.lwb_customer_master c WHERE upper(btrim(c.customer_name)) = upper(btrim(coalesce(o.customer_name, ''))) LIMIT 1),
         coalesce(o.created_at, now()) >= (SELECT s.start_at FROM public.lwb_bill_type_settings s WHERE s.id = 1)
  FROM public.orders o
  LEFT JOIN public.user_profiles u ON u.id = o.bill_type_set_by
  WHERE o.id = ANY(coalesce(p_ids, '{}'))
    AND coalesce(public.lwb_bt_role(), '') IN ('admin','manager','accounts','cashier','warehouse');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_order_bill_types(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_order_bill_types(uuid[]) TO authenticated;

-- ---------------------------------------------------------------------------
-- 7. Mismatch record: bill made as the other kind, or payment mode not matching the bill
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_bill_type_flags (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('BILL','PAYMENT')),
  order_id uuid REFERENCES public.orders(id) ON DELETE CASCADE,
  order_no text,
  party text,
  bill_type text,
  got text,                       -- BILL: kind the bill was made as · PAYMENT: CASH / UPI / BANK / CHEQUE
  amount numeric(14,2),
  reason text CHECK (reason IS NULL OR length(reason) <= 300),
  created_by uuid,
  created_by_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  ok_by uuid,
  ok_by_name text,
  ok_at timestamptz,
  ok_note text CHECK (ok_note IS NULL OR length(ok_note) <= 300)
);
CREATE INDEX IF NOT EXISTS lwb_bill_type_flags_open_idx ON public.lwb_bill_type_flags(created_at DESC) WHERE ok_at IS NULL;
ALTER TABLE public.lwb_bill_type_flags ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_bill_type_flags FROM PUBLIC, anon, authenticated;

-- Accounts made the bill as the other kind (or the same again = clears it).
CREATE OR REPLACE FUNCTION public.lwb_bill_made_as(p_order_id uuid, p_made_as text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_bt_role();
  v_as text := upper(btrim(coalesce(p_made_as, '')));
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_o public.orders%ROWTYPE;
  v_amt numeric;
  v_name text := public.lwb_bt_name();
  v_flag bigint;
BEGIN
  IF coalesce(v_role, '') NOT IN ('accounts','admin') THEN
    RAISE EXCEPTION 'Only Accounts or Admin make the bill' USING ERRCODE = '42501';
  END IF;
  IF v_as NOT IN ('GST','CASH') THEN RAISE EXCEPTION 'Choose GST or Cash'; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PO not found'; END IF;
  IF v_o.bill_type IS NULL THEN RAISE EXCEPTION 'Sales Head / Admin has not chosen GST or Cash for this PO yet'; END IF;
  PERFORM set_config('lwb.bt_rpc', '1', true);
  UPDATE public.orders SET bill_made_as = CASE WHEN v_as = v_o.bill_type THEN NULL ELSE v_as END WHERE id = p_order_id;
  PERFORM set_config('lwb.bt_rpc', '', true);
  IF v_as = v_o.bill_type THEN RETURN jsonb_build_object('mismatch', false); END IF;

  IF v_reason IS NULL OR length(v_reason) < 3 THEN RAISE EXCEPTION 'Write why the bill is made as % (PO is %)', v_as, v_o.bill_type; END IF;
  SELECT t.amount INTO v_amt FROM public.lwb_tally_invoices t WHERE t.order_id = p_order_id;
  INSERT INTO public.lwb_bill_type_flags(kind, order_id, order_no, party, bill_type, got, amount, reason, created_by, created_by_name)
  VALUES ('BILL', p_order_id, v_o.order_no, v_o.customer_name, v_o.bill_type, v_as, coalesce(v_amt, v_o.total_amount), left(v_reason, 300), auth.uid(), v_name)
  RETURNING id INTO v_flag;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, left('⚠ ' || v_as || ' bill on a ' || v_o.bill_type || ' PO: ' || coalesce(v_o.order_no, ''), 200),
         left(concat_ws(' · ', v_o.customer_name, 'PO set ' || v_o.bill_type || ', bill made ' || v_as, v_reason, 'by ' || v_name), 600),
         'BILL_TYPE_MISMATCH', p_order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') AND p.id IS DISTINCT FROM auth.uid();
  RETURN jsonb_build_object('mismatch', true, 'flag_id', v_flag);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_made_as(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_bill_made_as(uuid, text, text) TO authenticated;

-- Payment mode not matching the bill (one row per bill). Mode CASH vs GST bill, or UPI / BANK / CHEQUE vs Cash bill.
-- p_rows: [{"order_id": "...", "mode": "CASH", "amount": 21600}]  p_reason: what happened (chosen in the popup)
CREATE OR REPLACE FUNCTION public.lwb_bill_pay_mismatch(p_rows jsonb, p_reason text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text := public.lwb_bt_role();
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_name text := public.lwb_bt_name();
  r jsonb; v_o public.orders%ROWTYPE; v_mode text; v_type text; v_n int := 0; v_txt text := '';
BEGIN
  IF coalesce(v_role, '') NOT IN ('accounts','cashier','admin','manager') THEN
    RAISE EXCEPTION 'Only Accounts, Cashier, Sales Head or Admin' USING ERRCODE = '42501';
  END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Choose what happened'; END IF;
  IF jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) = 0 OR jsonb_array_length(p_rows) > 50 THEN
    RAISE EXCEPTION 'Nothing to record';
  END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    SELECT * INTO v_o FROM public.orders WHERE id = (r->>'order_id')::uuid;
    IF NOT FOUND THEN CONTINUE; END IF;
    v_type := coalesce(v_o.bill_made_as, v_o.bill_type);
    v_mode := upper(btrim(coalesce(r->>'mode', '')));
    -- only a real mismatch is kept
    IF v_type IS NULL OR v_mode NOT IN ('CASH','UPI','BANK','CHEQUE','OTHER')
       OR (v_type = 'GST' AND v_mode <> 'CASH') OR (v_type = 'CASH' AND v_mode = 'CASH') THEN CONTINUE; END IF;
    INSERT INTO public.lwb_bill_type_flags(kind, order_id, order_no, party, bill_type, got, amount, reason, created_by, created_by_name)
    VALUES ('PAYMENT', v_o.id, v_o.order_no, v_o.customer_name, v_type, v_mode, nullif(r->>'amount', '')::numeric, left(v_reason, 300), auth.uid(), v_name);
    v_n := v_n + 1;
    v_txt := left(concat_ws(', ', nullif(v_txt, ''), coalesce(v_o.order_no, '') || ' ' || v_type || ' bill / ' || v_mode), 400);
  END LOOP;
  IF v_n > 0 THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, left('⚠ Payment mode not matching the bill: ' || coalesce(v_o.customer_name, ''), 200),
           left(concat_ws(' · ', v_txt, v_reason, 'by ' || v_name), 600), 'BILL_TYPE_MISMATCH', CASE WHEN v_n = 1 THEN v_o.id END
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') AND p.id IS DISTINCT FROM auth.uid();
  END IF;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_pay_mismatch(jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_bill_pay_mismatch(jsonb, text) TO authenticated;

-- List (Accounts, Cashier, Sales Head, Admin): open ones always, OK'd ones of the last p_days.
CREATE OR REPLACE FUNCTION public.lwb_bill_type_flag_list(p_days integer DEFAULT 60)
RETURNS SETOF public.lwb_bill_type_flags
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF coalesce(public.lwb_bt_role(), '') NOT IN ('accounts','cashier','admin','manager') THEN
    RAISE EXCEPTION 'Not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT * FROM public.lwb_bill_type_flags f
    WHERE f.ok_at IS NULL OR f.created_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 60), 800)))
    ORDER BY (f.ok_at IS NULL) DESC, f.created_at DESC LIMIT 1000;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_type_flag_list(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_bill_type_flag_list(integer) TO authenticated;

-- Admin / Sales Head checked it: OK.
CREATE OR REPLACE FUNCTION public.lwb_bill_type_flag_ok(p_ids bigint[], p_note text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_n int;
BEGIN
  IF coalesce(public.lwb_bt_role(), '') NOT IN ('admin','manager') THEN
    RAISE EXCEPTION 'Only Sales Head or Admin can OK it' USING ERRCODE = '42501';
  END IF;
  UPDATE public.lwb_bill_type_flags SET ok_by = auth.uid(), ok_by_name = public.lwb_bt_name(), ok_at = now(),
         ok_note = nullif(left(btrim(coalesce(p_note, '')), 300), '')
  WHERE id = ANY(coalesce(p_ids, '{}')) AND ok_at IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_type_flag_ok(bigint[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_bill_type_flag_ok(bigint[], text) TO authenticated;

-- Accounts asks Sales Head / Admin to choose GST / Cash on a PO.
CREATE OR REPLACE FUNCTION public.lwb_bill_type_ask(p_order_id uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_n int;
BEGIN
  IF coalesce(public.lwb_bt_role(), '') NOT IN ('accounts','cashier','admin') THEN
    RAISE EXCEPTION 'Only Accounts or Admin' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PO not found'; END IF;
  IF v_o.bill_type IS NOT NULL THEN RAISE EXCEPTION 'GST / Cash is already chosen: %', v_o.bill_type; END IF;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
  SELECT p.id, left('GST or Cash bill? ' || coalesce(v_o.order_no, ''), 200),
         left(concat_ws(' · ', v_o.customer_name, 'Accounts is waiting to make the bill', nullif(v_o.bill_note, ''), 'by ' || public.lwb_bt_name()), 600),
         'BILL_TYPE_ASK', p_order_id
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') AND p.id IS DISTINCT FROM auth.uid();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_bill_type_ask(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_bill_type_ask(uuid) TO authenticated;

COMMIT;
