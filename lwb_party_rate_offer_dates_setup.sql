-- LUXURY WRIST BRAND ERP — PARTY RATE OFFER: offer type + start / end date, and the offer rate fixed on new orders
--
-- Runs by itself when merged to main (after lwb_party_rate_offer_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (22 Nov 2026): on Party Rate Offer pick One-time offer, Continuous scheme or Start date to End date,
-- with a filter on the list. When an order of that party comes from the market and today is inside the offer
-- dates, the offer rate fills in by itself and is fixed: a salesman cannot change it; Admin and Sales Head can.
--   * lwb_party_rate_offers + offer_type (ONE_TIME / CONTINUOUS / DATED), valid_from, valid_to,
--     used_at / used_order_id / used_order_no (a one-time offer is used by the party's next order that has
--     one of its items; it then stops). Old offers become CONTINUOUS from their own date.
--   * lwb_party_rate_offer_save(p)   + offer_type, valid_from (= offer date), valid_to (DATED only)
--   * lwb_party_rate_offer_list(...) + offer_type, valid_from, valid_to, used_order_no, state
--                                      (RUNNING / UPCOMING / EXPIRED / USED / CANCELLED)
--   * lwb_party_offer_rates(party, order) -> fixed rate of each SKU for that party today (any login; order
--     entry). Offer item = Rate List pack name (its linked SKUs) or the SKU name itself. Newest offer wins.
--   * Trigger on order_items: a salesman's line with an offer SKU must be at the offer rate (raises otherwise);
--     a one-time offer is marked used by the first order that takes it.
-- Admin / Sales Head (lwb_rate_editor()) are never blocked. Accounts / godown changes to a line are not checked.

BEGIN;

ALTER TABLE public.lwb_party_rate_offers ADD COLUMN IF NOT EXISTS offer_type text;
ALTER TABLE public.lwb_party_rate_offers ADD COLUMN IF NOT EXISTS valid_from date;
ALTER TABLE public.lwb_party_rate_offers ADD COLUMN IF NOT EXISTS valid_to date;
ALTER TABLE public.lwb_party_rate_offers ADD COLUMN IF NOT EXISTS used_at timestamptz;
ALTER TABLE public.lwb_party_rate_offers ADD COLUMN IF NOT EXISTS used_order_id uuid;
ALTER TABLE public.lwb_party_rate_offers ADD COLUMN IF NOT EXISTS used_order_no text;
UPDATE public.lwb_party_rate_offers SET offer_type = 'CONTINUOUS' WHERE offer_type IS NULL;
UPDATE public.lwb_party_rate_offers SET valid_from = offer_date WHERE valid_from IS NULL;
ALTER TABLE public.lwb_party_rate_offers ALTER COLUMN offer_type SET DEFAULT 'CONTINUOUS';
ALTER TABLE public.lwb_party_rate_offers ALTER COLUMN offer_type SET NOT NULL;
ALTER TABLE public.lwb_party_rate_offers ALTER COLUMN valid_from SET NOT NULL;
DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_party_rate_offers_type_chk') THEN
    ALTER TABLE public.lwb_party_rate_offers ADD CONSTRAINT lwb_party_rate_offers_type_chk
      CHECK (offer_type IN ('ONE_TIME','CONTINUOUS','DATED')
             AND (offer_type <> 'DATED' OR (valid_to IS NOT NULL AND valid_to >= valid_from)));
  END IF;
END $do$;

-- Today in India
CREATE OR REPLACE FUNCTION public.lwb_party_rate_today()
RETURNS date LANGUAGE sql STABLE SET search_path = ''
AS $fn$ SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date $fn$;

-- RUNNING / UPCOMING / EXPIRED / USED / CANCELLED for one offer (a used one-time offer whose order is gone runs again)
CREATE OR REPLACE FUNCTION public.lwb_party_rate_state(o public.lwb_party_rate_offers)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE
    WHEN o.status = 'CANCELLED' THEN 'CANCELLED'
    WHEN o.offer_type = 'ONE_TIME' AND o.used_order_id IS NOT NULL
         AND EXISTS (SELECT 1 FROM public.orders x WHERE x.id = o.used_order_id) THEN 'USED'
    WHEN o.valid_from > public.lwb_party_rate_today() THEN 'UPCOMING'
    WHEN o.offer_type = 'DATED' AND o.valid_to < public.lwb_party_rate_today() THEN 'EXPIRED'
    ELSE 'RUNNING' END
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_rate_state(public.lwb_party_rate_offers) FROM PUBLIC, anon, authenticated;

-- p = {party_name, party_code?, offer_type?, valid_from? (or offer_date), valid_to?, note?, lines:[{item, rate, note?}]}
CREATE OR REPLACE FUNCTION public.lwb_party_rate_offer_save(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_party text := btrim(coalesce(p->>'party_name', ''));
  v_type text := upper(coalesce(nullif(btrim(p->>'offer_type'), ''), 'CONTINUOUS'));
  v_date date := coalesce(nullif(p->>'valid_from', '')::date, nullif(p->>'offer_date', '')::date, public.lwb_party_rate_today());
  v_to date := nullif(p->>'valid_to', '')::date;
  v_id bigint; v_no text; v_n integer; v_l jsonb; v_line integer := 0; v_item text; v_rate numeric;
  v_seen text[] := '{}';
BEGIN
  IF NOT public.lwb_rate_editor() THEN RAISE EXCEPTION 'Only Admin or Sales Head can give a party rate.'; END IF;
  IF v_party = '' THEN RAISE EXCEPTION 'Pick the party.'; END IF;
  IF v_type NOT IN ('ONE_TIME','CONTINUOUS','DATED') THEN RAISE EXCEPTION 'Pick the offer type.'; END IF;
  IF v_type = 'DATED' THEN
    IF v_to IS NULL THEN RAISE EXCEPTION 'Pick the end date.'; END IF;
    IF v_to < v_date THEN RAISE EXCEPTION 'End date is before the start date.'; END IF;
  ELSE v_to := NULL; END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') = 0 THEN
    RAISE EXCEPTION 'Add at least one item with its rate.';
  END IF;
  IF jsonb_array_length(p->'lines') > 100 THEN RAISE EXCEPTION 'At most 100 items in one rate offer.'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext('lwb_party_rate_offer_no'));
  SELECT count(*) + 1 INTO v_n FROM public.lwb_party_rate_offers WHERE offer_no LIKE 'RO-' || to_char(v_date, 'DDMM') || '-%'
     AND extract(year FROM offer_date) = extract(year FROM v_date);
  LOOP
    v_no := 'RO-' || to_char(v_date, 'DDMM') || '-' || lpad(v_n::text, 2, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.lwb_party_rate_offers WHERE offer_no = v_no);
    v_n := v_n + 1;
  END LOOP;

  INSERT INTO public.lwb_party_rate_offers(offer_no, party_name, party_key, party_code, offer_date, note, created_by,
                                           offer_type, valid_from, valid_to)
  VALUES (v_no, v_party, public.lwb_party_rate_key(v_party), nullif(btrim(coalesce(p->>'party_code', '')), ''),
          v_date, nullif(btrim(coalesce(p->>'note', '')), ''), auth.uid(), v_type, v_date, v_to)
  RETURNING id INTO v_id;

  FOR v_l IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    v_item := btrim(coalesce(v_l->>'item', ''));
    IF v_item = '' THEN CONTINUE; END IF;
    IF public.lwb_party_rate_key(v_item) = ANY(v_seen) THEN RAISE EXCEPTION '% is added twice.', v_item; END IF;
    v_seen := v_seen || public.lwb_party_rate_key(v_item);
    BEGIN v_rate := (v_l->>'rate')::numeric; EXCEPTION WHEN others THEN v_rate := NULL; END;
    IF v_rate IS NULL OR v_rate < 0 THEN RAISE EXCEPTION 'Enter the rate for %.', v_item; END IF;
    v_line := v_line + 1;
    INSERT INTO public.lwb_party_rate_offer_lines(offer_id, line_no, item, item_key, rate, note)
    VALUES (v_id, v_line, v_item, public.lwb_party_rate_key(v_item), round(v_rate, 2), nullif(btrim(coalesce(v_l->>'note', '')), ''));
  END LOOP;
  IF v_line = 0 THEN RAISE EXCEPTION 'Add at least one item with its rate.'; END IF;
  RETURN jsonb_build_object('id', v_id, 'offer_no', v_no);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_party_rate_offer_list(p_days integer DEFAULT 90, p_party text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_rate_editor() THEN RAISE EXCEPTION 'Only Admin or Sales Head can see party rates.'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'id', o.id, 'offer_no', o.offer_no, 'party_name', o.party_name, 'party_code', o.party_code,
      'offer_date', o.offer_date, 'note', o.note, 'status', o.status, 'cancel_note', o.cancel_note,
      'created_at', o.created_at, 'created_by', o.created_by, 'by', public.lwb_party_rate_who(o.created_by),
      'mine', o.created_by = auth.uid(),
      'offer_type', o.offer_type, 'valid_from', o.valid_from, 'valid_to', o.valid_to,
      'used_order_no', o.used_order_no, 'used_at', o.used_at, 'state', o.state,
      'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('item', l.item, 'rate', l.rate, 'note', l.note) ORDER BY l.line_no)
                FROM public.lwb_party_rate_offer_lines l WHERE l.offer_id = o.id), '[]'::jsonb))
      ORDER BY o.offer_date DESC, o.id DESC)
    FROM (SELECT o.*, public.lwb_party_rate_state(o) AS state FROM public.lwb_party_rate_offers o
           WHERE (p_party IS NULL OR o.party_key = public.lwb_party_rate_key(p_party))
             -- a running offer always shows, however old
             AND (o.offer_date >= public.lwb_party_rate_today() - greatest(coalesce(p_days, 90), 1)
                  OR public.lwb_party_rate_state(o) IN ('RUNNING','UPCOMING'))
           ORDER BY o.offer_date DESC, o.id DESC LIMIT 500) o), '[]'::jsonb);
END;
$fn$;

-- Fixed rate per SKU for one party today: [{sku_key, item, rate, offer_id, offer_no, offer_type, valid_to}].
-- p_order = the order being made / changed: a one-time offer used by this same order still counts.
CREATE OR REPLACE FUNCTION public.lwb_party_offer_rate_rows(p_party text, p_order uuid DEFAULT NULL)
RETURNS TABLE(sku_key text, item text, rate numeric, offer_id bigint, offer_no text, offer_type text, valid_to date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT DISTINCT ON (s.sku_key) s.sku_key, s.item, s.rate, s.offer_id, s.offer_no, s.offer_type, s.valid_to
  FROM (
    SELECT k.sku_key, l.item, l.rate, o.id AS offer_id, o.offer_no, o.offer_type, o.valid_to, o.offer_date
    FROM public.lwb_party_rate_offers o
    JOIN public.lwb_party_rate_offer_lines l ON l.offer_id = o.id
    CROSS JOIN LATERAL (
      SELECT l.item_key AS sku_key
      UNION
      SELECT ps.sku_key FROM public.lwb_rate_pack_skus ps JOIN public.lwb_rate_packs pk ON pk.id = ps.pack_id
       WHERE public.lwb_party_rate_key(pk.pack_name) = l.item_key AND pk.active IS NOT FALSE
    ) k
    WHERE o.party_key = public.lwb_party_rate_key(p_party) AND btrim(coalesce(p_party, '')) <> ''
      AND o.status = 'ACTIVE'
      AND o.valid_from <= public.lwb_party_rate_today()
      AND (o.offer_type <> 'DATED' OR o.valid_to >= public.lwb_party_rate_today())
      AND (o.offer_type <> 'ONE_TIME' OR o.used_order_id IS NULL OR o.used_order_id = p_order
           OR NOT EXISTS (SELECT 1 FROM public.orders x WHERE x.id = o.used_order_id))
  ) s
  ORDER BY s.sku_key, s.offer_date DESC, s.offer_id DESC
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_offer_rate_rows(text, uuid) FROM PUBLIC, anon, authenticated;

-- Order entry (any login): fixed rates for this party today, plus whether this login may change them.
CREATE OR REPLACE FUNCTION public.lwb_party_offer_rates(p_customer text, p_order uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Login needed.'; END IF;
  RETURN jsonb_build_object('can_change', public.lwb_rate_editor(), 'rates', coalesce((
    SELECT jsonb_agg(jsonb_build_object('sku_key', r.sku_key, 'item', r.item, 'rate', r.rate, 'offer_no', r.offer_no,
                                        'offer_type', r.offer_type, 'valid_to', r.valid_to) ORDER BY r.sku_key)
    FROM public.lwb_party_offer_rate_rows(p_customer, p_order) r), '[]'::jsonb));
END;
$fn$;

-- Order line saved: a salesman must keep the offer rate; a one-time offer is marked used by this order.
CREATE OR REPLACE FUNCTION public.lwb_party_offer_item_lock()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_party text; v_no text; r record; v_role text;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.rate IS NOT DISTINCT FROM OLD.rate AND NEW.sku_name IS NOT DISTINCT FROM OLD.sku_name THEN RETURN NEW; END IF;
  SELECT o.customer_name, o.order_no INTO v_party, v_no FROM public.orders o WHERE o.id = NEW.order_id;
  IF btrim(coalesce(v_party, '')) = '' THEN RETURN NEW; END IF;
  SELECT * INTO r FROM public.lwb_party_offer_rate_rows(v_party, NEW.order_id) x WHERE x.sku_key = upper(btrim(coalesce(NEW.sku_name, '')));
  IF NOT FOUND THEN RETURN NEW; END IF;
  SELECT lower(btrim(coalesce(u.role, ''))) INTO v_role FROM public.user_profiles u WHERE u.id = auth.uid();
  IF auth.uid() IS NOT NULL AND v_role IN ('sales','salesman') AND NOT public.lwb_rate_editor()
     AND coalesce(NEW.rate, -1) <> r.rate THEN
    RAISE EXCEPTION 'OFFER_RATE_FIXED: % rate is fixed at ₹% for this party (%). Only Admin or Sales Head can change it.',
      NEW.sku_name, r.rate, r.offer_no;
  END IF;
  IF TG_OP = 'INSERT' AND r.offer_type = 'ONE_TIME' THEN
    UPDATE public.lwb_party_rate_offers SET used_at = now(), used_order_id = NEW.order_id, used_order_no = v_no
     WHERE id = r.offer_id AND used_order_id IS DISTINCT FROM NEW.order_id;
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_offer_item_lock() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS lwb_party_offer_item_lock ON public.order_items;
CREATE TRIGGER lwb_party_offer_item_lock BEFORE INSERT OR UPDATE OF rate, sku_name ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION public.lwb_party_offer_item_lock();

REVOKE ALL ON FUNCTION public.lwb_party_offer_rates(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_offer_rates(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_party_rate_offer_save(jsonb), public.lwb_party_rate_offer_list(integer, text) TO authenticated;

COMMIT;
