-- LUXURY WRIST BRAND ERP — CUSTOMER ORDERS FROM THE WEBSITE (Mohit, 20 Nov 2026)
--
-- A shop owner opens https://luxurywristbrand.com/order.html, types his mobile number,
-- picks one brand and the products (cases) and sends the order. No login.
--
-- Where the order goes (same Orders list, no second system):
--   * Mobile matches ONE active party in Party Master  -> a normal PO is made at once
--     (orders + order_items, status pending_approval, sales person "WEBSITE ORDER").
--     It shows in PO / Sales List > Pending Review; Sales Head checks rate and approves
--     as usual. Rate = the party's last PO rate of that SKU (0 if never bought).
--     The salesman of that party (Sales Team Setup) is the PO's creator, so he sees it too.
--   * New mobile, or the number is on 2+ parties, or a slip brand (Rajnigandha)
--     -> kept as WAITING in Website Orders (web-orders.html). Admin / Sales Head press
--     "Make PO": New PO opens with the products filled in; Submit makes the PO and marks it done.
--
-- Spam stops (no login, so the database checks everything itself):
--   * valid 10-digit Indian mobile, short text fields, 1-60 lines, 1-5000 cases per line
--   * a hidden "website" field that only bots fill
--   * per mobile: 3 orders an hour, 6 a day; whole site: 40 orders in 10 minutes
--   * the same order sent twice within 10 minutes gives back the first one (double tap)
--   * the customer only gets "order received W-123", never party names or rates
--
-- WhatsApp later: an Edge Function (service role) calls lwb_web_order_intake(p, 'WHATSAPP')
-- with the same JSON, so WhatsApp orders land in the same place.
--
-- Safe to run again. Nothing existing is changed or deleted.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Website / WhatsApp order intake
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_web_orders (
  id bigserial PRIMARY KEY,
  channel text NOT NULL DEFAULT 'WEB' CHECK (channel IN ('WEB','WHATSAPP')),
  mobile text NOT NULL CHECK (mobile ~ '^[6-9][0-9]{9}$'),
  contact_name text NOT NULL CHECK (length(btrim(contact_name)) BETWEEN 2 AND 60),
  shop_name text CHECK (shop_name IS NULL OR length(shop_name) <= 100),
  city text CHECK (city IS NULL OR length(city) <= 60),
  note text CHECK (note IS NULL OR length(note) <= 300),
  company_id uuid,
  brand_name text,
  items jsonb NOT NULL CHECK (jsonb_typeof(items) = 'array'),
  total_qty numeric NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'WAITING' CHECK (status IN ('WAITING','PO_MADE','REJECTED')),
  wait_reason text,
  matched_parties jsonb NOT NULL DEFAULT '[]'::jsonb,
  customer_name text,
  order_id uuid,
  order_no text,
  handled_by uuid,
  handled_by_name text,
  handled_at timestamptz,
  reject_reason text CHECK (reject_reason IS NULL OR length(reject_reason) <= 200),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_web_orders_mobile_idx ON public.lwb_web_orders(mobile, created_at DESC);
CREATE INDEX IF NOT EXISTS lwb_web_orders_at_idx ON public.lwb_web_orders(created_at DESC);
CREATE INDEX IF NOT EXISTS lwb_web_orders_status_idx ON public.lwb_web_orders(status) WHERE status = 'WAITING';

ALTER TABLE public.lwb_web_orders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_web_orders FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.lwb_web_orders TO authenticated;
REVOKE ALL ON SEQUENCE public.lwb_web_orders_id_seq FROM PUBLIC, anon, authenticated;

-- Admin / Sales Head (active) only.
CREATE OR REPLACE FUNCTION public.lwb_web_order_staff()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager'));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_web_order_staff() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_web_order_staff() TO authenticated;

DROP POLICY IF EXISTS lwb_web_orders_read ON public.lwb_web_orders;
CREATE POLICY lwb_web_orders_read ON public.lwb_web_orders FOR SELECT TO authenticated
  USING (public.lwb_web_order_staff());

-- ---------------------------------------------------------------------------
-- 2. Product list for the public order page: active brands + active SKUs.
--    Names, pack and photo only. No rate, stock or party data.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_web_catalog()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  RETURN jsonb_build_object(
    'brands', coalesce((
      SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'color', c.color) ORDER BY c.sort_no, c.name)
      FROM public.lwb_companies c
      WHERE c.active = true
        AND EXISTS (SELECT 1 FROM public.sku_master s WHERE s.company_id = c.id AND s.is_active = true)), '[]'::jsonb),
    'skus', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
          'name', s.sku_name, 'brand', s.company_id,
          'category', nullif(btrim(coalesce(to_jsonb(s)->>'category','')),''),
          'pcs', nullif(to_jsonb(s)->>'pcs_per_case','')::numeric,
          'unit', coalesce(nullif(to_jsonb(s)->>'pack_unit',''),'CASE'),
          'img', nullif(to_jsonb(s)->>'image_url',''))
        ORDER BY coalesce(to_jsonb(s)->>'category',''), s.sku_name)
      FROM public.sku_master s
      JOIN public.lwb_companies c ON c.id = s.company_id AND c.active = true
      WHERE s.is_active = true), '[]'::jsonb));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_web_catalog() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lwb_web_catalog() TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Take one order (website or, later, WhatsApp). Not callable from the browser;
--    the browser calls lwb_web_order_submit below.
--    p = {mobile, name, shop, city, note, brand, items:[{sku, qty}], website(honeypot)}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_web_order_intake(p jsonb, p_channel text DEFAULT 'WEB')
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_mobile text := right(regexp_replace(coalesce(p->>'mobile',''), '[^0-9]', '', 'g'), 10);
  v_name text := left(btrim(regexp_replace(coalesce(p->>'name',''), '\s+', ' ', 'g')), 60);
  v_shop text := nullif(left(btrim(regexp_replace(coalesce(p->>'shop',''), '\s+', ' ', 'g')), 100), '');
  v_city text := nullif(left(btrim(regexp_replace(coalesce(p->>'city',''), '\s+', ' ', 'g')), 60), '');
  v_note text := nullif(left(btrim(coalesce(p->>'note','')), 300), '');
  v_brand uuid;
  v_brand_name text;
  v_slip boolean := false;
  v_item jsonb;
  v_sku public.sku_master%ROWTYPE;
  v_qty numeric;
  v_lines jsonb := '[]'::jsonb;
  v_seen text[] := ARRAY[]::text[];
  v_total numeric := 0;
  v_prev public.lwb_web_orders%ROWTYPE;
  v_parties jsonb;
  v_party_count integer;
  v_party record;
  v_row public.lwb_web_orders%ROWTYPE;
  v_reason text;
  v_po jsonb;
BEGIN
  IF p_channel NOT IN ('WEB','WHATSAPP') THEN RAISE EXCEPTION 'Invalid channel'; END IF;
  IF jsonb_typeof(p) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid order'; END IF;
  -- Hidden field: a person never fills it.
  IF coalesce(btrim(p->>'website'),'') <> '' THEN RAISE EXCEPTION 'Order not accepted'; END IF;
  IF v_mobile !~ '^[6-9][0-9]{9}$' THEN RAISE EXCEPTION 'Enter a valid 10-digit mobile number'; END IF;
  IF length(v_name) < 2 THEN RAISE EXCEPTION 'Enter your name'; END IF;
  IF v_name ~ '(https?://|www\.)' OR coalesce(v_shop,'') ~ '(https?://|www\.)' OR coalesce(v_note,'') ~ '(https?://|www\.)' THEN
    RAISE EXCEPTION 'Links are not allowed';
  END IF;

  -- Too many orders: per mobile, and the whole site.
  IF (SELECT count(*) FROM public.lwb_web_orders w WHERE w.mobile = v_mobile AND w.created_at > now() - interval '1 hour') >= 3
     OR (SELECT count(*) FROM public.lwb_web_orders w WHERE w.mobile = v_mobile AND w.created_at > now() - interval '1 day') >= 6 THEN
    RAISE EXCEPTION 'Too many orders from this number. Please call or WhatsApp us.';
  END IF;
  IF (SELECT count(*) FROM public.lwb_web_orders w WHERE w.created_at > now() - interval '10 minutes') >= 40 THEN
    RAISE EXCEPTION 'Too many orders right now. Please try again in a few minutes.';
  END IF;

  -- Brand: one brand per order.
  BEGIN v_brand := nullif(p->>'brand','')::uuid; EXCEPTION WHEN invalid_text_representation THEN v_brand := NULL; END;
  SELECT c.name, coalesce((to_jsonb(c)->>'quick_slip')::boolean, false) INTO v_brand_name, v_slip
    FROM public.lwb_companies c WHERE c.id = v_brand AND c.active = true;
  IF v_brand_name IS NULL THEN RAISE EXCEPTION 'Select a brand'; END IF;

  IF jsonb_typeof(p->'items') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'items') NOT BETWEEN 1 AND 60 THEN
    RAISE EXCEPTION 'Add 1 to 60 products';
  END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p->'items') LOOP
    IF jsonb_typeof(v_item) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid product line'; END IF;
    SELECT * INTO v_sku FROM public.sku_master s
      WHERE upper(btrim(s.sku_name)) = upper(btrim(coalesce(v_item->>'sku',''))) AND s.is_active = true LIMIT 1;
    IF NOT FOUND OR v_sku.company_id IS DISTINCT FROM v_brand THEN RAISE EXCEPTION 'Product not available: %', left(coalesce(v_item->>'sku',''), 80); END IF;
    IF upper(btrim(v_sku.sku_name)) = ANY(v_seen) THEN CONTINUE; END IF;
    v_seen := array_append(v_seen, upper(btrim(v_sku.sku_name)));
    IF coalesce(v_item->>'qty','') !~ '^[0-9]{1,4}$' THEN RAISE EXCEPTION 'Enter whole cases for %', v_sku.sku_name; END IF;
    v_qty := (v_item->>'qty')::numeric;
    IF v_qty NOT BETWEEN 1 AND 5000 THEN RAISE EXCEPTION 'Enter 1 to 5000 cases for %', v_sku.sku_name; END IF;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('sku', v_sku.sku_name, 'qty', v_qty));
    v_total := v_total + v_qty;
  END LOOP;
  IF v_total > 20000 THEN RAISE EXCEPTION 'Order is too big. Please call us.'; END IF;

  -- Same order tapped twice: give back the first one.
  SELECT * INTO v_prev FROM public.lwb_web_orders w
    WHERE w.mobile = v_mobile AND w.items = v_lines AND w.company_id = v_brand AND w.created_at > now() - interval '10 minutes'
    ORDER BY w.id DESC LIMIT 1;
  IF FOUND THEN RETURN jsonb_build_object('ref', 'W-' || v_prev.id, 'again', true); END IF;

  -- Who is it? Active parties with this mobile (last 10 digits).
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.customer_name, 'city', c.city) ORDER BY c.customer_name), '[]'::jsonb), count(*)
    INTO v_parties, v_party_count
    FROM public.lwb_customer_master c
    WHERE c.is_active = true AND right(regexp_replace(coalesce(c.mobile,''), '[^0-9]', '', 'g'), 10) = v_mobile;

  v_reason := CASE WHEN v_party_count = 0 THEN 'NEW_CUSTOMER'
                   WHEN v_party_count > 1 THEN 'MANY_PARTIES'
                   WHEN v_slip THEN 'SLIP_BRAND' END;

  INSERT INTO public.lwb_web_orders(channel, mobile, contact_name, shop_name, city, note, company_id, brand_name,
      items, total_qty, status, wait_reason, matched_parties)
  VALUES (p_channel, v_mobile, v_name, v_shop, v_city, v_note, v_brand, v_brand_name,
      v_lines, v_total, 'WAITING', v_reason, v_parties)
  RETURNING * INTO v_row;

  IF v_reason IS NULL THEN
    -- Known party: make the PO now.
    SELECT * INTO v_party FROM jsonb_to_record(v_parties->0) AS x(id uuid, name text, city text);
    v_po := public.lwb_web_order_po(v_row.id, v_party.id);
  ELSE
    BEGIN
      INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
      SELECT u.id, 'Website order — make PO',
        concat_ws(' · ', 'W-' || v_row.id, coalesce(v_shop, v_name), v_city, v_mobile, v_brand_name,
          to_char(v_total, 'FM999990') || ' CS',
          CASE v_reason WHEN 'NEW_CUSTOMER' THEN 'New customer' WHEN 'MANY_PARTIES' THEN 'Number on ' || v_party_count || ' parties' ELSE 'Slip brand' END)
          || '. Open Website Orders.',
        'WEB_ORDER'
      FROM public.user_profiles u WHERE u.active = true AND lower(btrim(u.role)) IN ('admin','manager');
    EXCEPTION WHEN others THEN NULL;  -- a bell never stops the order
    END;
  END IF;

  RETURN jsonb_build_object('ref', 'W-' || v_row.id);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_web_order_intake(jsonb, text) FROM PUBLIC, anon, authenticated;

-- Make the pending PO for a known party (inside the intake call).
-- Rate per SKU = this party's last PO rate (0 if never bought); Sales Head checks it on approval.
CREATE OR REPLACE FUNCTION public.lwb_web_order_po(p_web_id bigint, p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  w public.lwb_web_orders%ROWTYPE;
  v_party public.lwb_customer_master%ROWTYPE;
  v_salesman uuid;
  v_lines jsonb;
  v_qty numeric; v_amount numeric; v_weight numeric;
  v_order public.orders%ROWTYPE;
  v_try integer := 0;
BEGIN
  SELECT * INTO w FROM public.lwb_web_orders WHERE id = p_web_id FOR UPDATE;
  IF NOT FOUND OR w.status <> 'WAITING' THEN RAISE EXCEPTION 'Website order not waiting'; END IF;
  SELECT * INTO v_party FROM public.lwb_customer_master WHERE id = p_customer_id AND is_active = true;
  IF NOT FOUND THEN RAISE EXCEPTION 'Party not found'; END IF;
  SELECT a.salesman_id INTO v_salesman FROM public.lwb_party_salesman a
    JOIN public.user_profiles u ON u.id = a.salesman_id AND u.active = true
    WHERE a.customer_id = v_party.id;

  SELECT jsonb_agg(jsonb_build_object('sku', s.sku_name, 'qty', (x.value->>'qty')::numeric,
           'rate', coalesce(lr.rate, 0), 'wt', coalesce(s.unit_weight_kg, 0)) ORDER BY x.ordinality)
    INTO v_lines
    FROM jsonb_array_elements(w.items) WITH ORDINALITY x
    JOIN public.sku_master s ON upper(btrim(s.sku_name)) = upper(btrim(x.value->>'sku')) AND s.is_active = true
    LEFT JOIN LATERAL (
      SELECT i.rate FROM public.orders o JOIN public.order_items i ON i.order_id = o.id
      WHERE upper(btrim(o.customer_name)) = upper(btrim(v_party.customer_name))
        AND upper(btrim(i.sku_name)) = upper(btrim(s.sku_name))
        AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected')
        AND i.rate > 0
      ORDER BY o.order_date DESC NULLS LAST, o.created_at DESC NULLS LAST LIMIT 1) lr ON true;
  IF v_lines IS NULL OR jsonb_array_length(v_lines) = 0 THEN RAISE EXCEPTION 'No active product left in this order'; END IF;

  SELECT sum((l->>'qty')::numeric), sum((l->>'qty')::numeric * (l->>'rate')::numeric), sum((l->>'qty')::numeric * (l->>'wt')::numeric)
    INTO v_qty, v_amount, v_weight FROM jsonb_array_elements(v_lines) l;

  -- Next LXY- number (same rule as lwb_next_order_no); two orders at the same moment: try again.
  LOOP
    BEGIN
      INSERT INTO public.orders(order_no, order_date, customer_name, transportation, sales_person, status,
          total_qty, total_amount, total_weight, created_by)
      VALUES ((SELECT 'LXY-' || lpad((coalesce(max(substring(o.order_no FROM '^LXY-([0-9]+)$')::bigint), 0) + 1)::text, 5, '0')
                 FROM public.orders o WHERE o.order_no ~ '^LXY-[0-9]+$'),
              now(), v_party.customer_name, 'DELIVERY', 'WEBSITE ORDER', 'pending_approval',
              v_qty, v_amount, v_weight, v_salesman)
      RETURNING * INTO v_order;
      EXIT;
    EXCEPTION WHEN unique_violation THEN
      v_try := v_try + 1;
      IF v_try >= 3 THEN RAISE; END IF;
    END;
  END LOOP;

  INSERT INTO public.order_items(order_id, sku_name, ordered_qty, approved_qty, loaded_qty, rate, unit_weight, amount, total_weight)
  SELECT v_order.id, l->>'sku', (l->>'qty')::numeric, (l->>'qty')::numeric, 0, (l->>'rate')::numeric, (l->>'wt')::numeric,
         (l->>'qty')::numeric * (l->>'rate')::numeric, (l->>'qty')::numeric * (l->>'wt')::numeric
  FROM jsonb_array_elements(v_lines) l;

  UPDATE public.lwb_web_orders SET status = 'PO_MADE', customer_name = v_party.customer_name,
    order_id = v_order.id, order_no = v_order.order_no, handled_at = now(), handled_by_name = 'Auto (mobile matched)'
  WHERE id = w.id;

  RETURN jsonb_build_object('order_id', v_order.id, 'order_no', v_order.order_no);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_web_order_po(bigint, uuid) FROM PUBLIC, anon, authenticated;

-- The public order page calls this (no login).
CREATE OR REPLACE FUNCTION public.lwb_web_order_submit(p jsonb)
RETURNS jsonb LANGUAGE sql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT public.lwb_web_order_intake(p, 'WEB'); $fn$;
REVOKE ALL ON FUNCTION public.lwb_web_order_submit(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lwb_web_order_submit(jsonb) TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Staff: after New PO is submitted from a waiting website order, or to reject one.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_web_order_done(p_id bigint, p_order_id uuid)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE;
BEGIN
  IF NOT public.lwb_web_order_staff() THEN RAISE EXCEPTION 'Admin or Sales Head required' USING ERRCODE = '42501'; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PO not found'; END IF;
  UPDATE public.lwb_web_orders SET status = 'PO_MADE', order_id = v_o.id, order_no = v_o.order_no,
    customer_name = v_o.customer_name, handled_by = auth.uid(), handled_at = now(),
    handled_by_name = (SELECT full_name FROM public.user_profiles WHERE id = auth.uid())
  WHERE id = p_id AND status = 'WAITING';
  DELETE FROM public.erp_notifications WHERE notification_type = 'WEB_ORDER' AND is_read = false
    AND message LIKE 'W-' || p_id || ' ·%';
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_web_order_done(bigint, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_web_order_done(bigint, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_web_order_reject(p_id bigint, p_reason text)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_web_order_staff() THEN RAISE EXCEPTION 'Admin or Sales Head required' USING ERRCODE = '42501'; END IF;
  UPDATE public.lwb_web_orders SET status = 'REJECTED', reject_reason = nullif(left(btrim(coalesce(p_reason,'')), 200), ''),
    handled_by = auth.uid(), handled_at = now(),
    handled_by_name = (SELECT full_name FROM public.user_profiles WHERE id = auth.uid())
  WHERE id = p_id AND status = 'WAITING';
  IF NOT FOUND THEN RAISE EXCEPTION 'This website order is not waiting any more'; END IF;
  DELETE FROM public.erp_notifications WHERE notification_type = 'WEB_ORDER' AND is_read = false
    AND message LIKE 'W-' || p_id || ' ·%';
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_web_order_reject(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_web_order_reject(bigint, text) TO authenticated;

COMMIT;
