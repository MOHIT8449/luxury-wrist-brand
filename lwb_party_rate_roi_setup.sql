-- LUXURY WRIST BRAND ERP — PARTY RATE OFFER: ROI rate marked per line, ROI report, "rate changed, recheck" alert
--
-- Runs by itself when merged to main (after lwb_party_rate_offer_dates_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (22 Nov 2026): the company gives ROI (₹5 a case) on the month's purchase of every category except 1-2.
-- Many parties are given landing − ₹5 (the ROI passed on), but nobody can see which ones. And when a pack's rate
-- changes, every party that has an offer on that pack should get "rate updated, please recheck".
--   * lwb_party_roi_settings (one row): ROI ₹ per case + categories with no ROI. Admin changes it.
--   * lwb_party_rate_offer_lines + roi (₹ / case passed on to the party, NULL = no ROI), landing (landing excl. ROI
--     at save time), recheck_at / recheck_note (pack rate changed after the offer), checked_at / checked_by.
--   * lwb_party_rate_offer_save(p)  + lines[].roi, lines[].landing
--   * lwb_party_rate_offer_list(..) + lines[].roi / landing / recheck_note, offer roi_lines / recheck_lines
--   * lwb_party_rate_last(party)    + roi
--   * lwb_party_roi_settings_save(roi, categories)  -> Admin only
--   * lwb_party_rate_recheck_done(offer_id)          -> clears the recheck flag of one offer (Admin / Sales Head)
--   * lwb_party_roi_report(month)  -> ROI earned (month's purchase cases, ROI categories × ₹ / case)
--                                     against ROI given (cases sold that month on ROI offer lines × ₹ / case), per party
--   * lwb_party_roi_orders(ids)    -> PO List: orders with a line on an ROI offer (marked green there)
--   * Trigger on lwb_rate_packs: GR, MEPD %, free bottle, OMS, QPS, case config or list (Slab 3) rate changed
--     -> every running / later offer line of that pack (pack name or one of its SKUs) is flagged for recheck.
-- Admin and Sales Head only (lwb_rate_editor()). No order, rate list, stock, bill, ledger or Tally data is changed.

BEGIN;

-- ---------- ROI setting ----------
CREATE TABLE IF NOT EXISTS public.lwb_party_roi_settings (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  roi_per_case numeric(12,2) NOT NULL DEFAULT 5 CHECK (roi_per_case >= 0),
  no_roi_categories text[] NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
INSERT INTO public.lwb_party_roi_settings(id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.lwb_party_roi_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_party_roi_settings FROM PUBLIC, anon, authenticated;
DROP POLICY IF EXISTS lwb_party_roi_settings_read ON public.lwb_party_roi_settings;
CREATE POLICY lwb_party_roi_settings_read ON public.lwb_party_roi_settings
  FOR SELECT TO authenticated USING (public.lwb_rate_editor());
GRANT SELECT ON TABLE public.lwb_party_roi_settings TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_party_roi_settings_save(p_roi numeric, p_categories text[])
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles u WHERE u.id = auth.uid() AND u.active = true AND lower(btrim(u.role)) = 'admin') THEN
    RAISE EXCEPTION 'Only Admin can change the ROI setting.';
  END IF;
  IF p_roi IS NULL OR p_roi < 0 OR p_roi > 1000 THEN RAISE EXCEPTION 'Enter ROI ₹ per case.'; END IF;
  UPDATE public.lwb_party_roi_settings SET roi_per_case = round(p_roi, 2),
    no_roi_categories = coalesce((SELECT array_agg(DISTINCT upper(btrim(c))) FROM unnest(coalesce(p_categories, '{}')) c WHERE btrim(c) <> ''), '{}'),
    updated_at = now(), updated_by = auth.uid()
  WHERE id = 1;
  RETURN true;
END;
$fn$;

-- ---------- offer line: ROI + recheck ----------
ALTER TABLE public.lwb_party_rate_offer_lines ADD COLUMN IF NOT EXISTS roi numeric(12,2) CHECK (roi IS NULL OR roi >= 0);
ALTER TABLE public.lwb_party_rate_offer_lines ADD COLUMN IF NOT EXISTS landing numeric(12,2);
ALTER TABLE public.lwb_party_rate_offer_lines ADD COLUMN IF NOT EXISTS recheck_at timestamptz;
ALTER TABLE public.lwb_party_rate_offer_lines ADD COLUMN IF NOT EXISTS recheck_note text;
ALTER TABLE public.lwb_party_rate_offer_lines ADD COLUMN IF NOT EXISTS checked_at timestamptz;
ALTER TABLE public.lwb_party_rate_offer_lines ADD COLUMN IF NOT EXISTS checked_by uuid;
CREATE INDEX IF NOT EXISTS lwb_party_rate_offer_lines_recheck_idx ON public.lwb_party_rate_offer_lines (offer_id) WHERE recheck_at IS NOT NULL;

-- p = {party_name, party_code?, offer_type?, valid_from?, valid_to?, note?, lines:[{item, rate, note?, roi?, landing?}]}
CREATE OR REPLACE FUNCTION public.lwb_party_rate_offer_save(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_party text := btrim(coalesce(p->>'party_name', ''));
  v_type text := upper(coalesce(nullif(btrim(p->>'offer_type'), ''), 'CONTINUOUS'));
  v_date date := coalesce(nullif(p->>'valid_from', '')::date, nullif(p->>'offer_date', '')::date, public.lwb_party_rate_today());
  v_to date := nullif(p->>'valid_to', '')::date;
  v_id bigint; v_no text; v_n integer; v_l jsonb; v_line integer := 0; v_item text; v_rate numeric; v_roi numeric; v_land numeric;
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
    BEGIN v_roi := nullif(v_l->>'roi', '')::numeric; EXCEPTION WHEN others THEN v_roi := NULL; END;
    IF v_roi IS NOT NULL AND v_roi <= 0 THEN v_roi := NULL; END IF;
    BEGIN v_land := nullif(v_l->>'landing', '')::numeric; EXCEPTION WHEN others THEN v_land := NULL; END;
    v_line := v_line + 1;
    INSERT INTO public.lwb_party_rate_offer_lines(offer_id, line_no, item, item_key, rate, note, roi, landing)
    VALUES (v_id, v_line, v_item, public.lwb_party_rate_key(v_item), round(v_rate, 2), nullif(btrim(coalesce(v_l->>'note', '')), ''),
            round(v_roi, 2), round(v_land, 2));
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
      'roi_lines', (SELECT count(*) FROM public.lwb_party_rate_offer_lines l WHERE l.offer_id = o.id AND l.roi > 0),
      'recheck_lines', CASE WHEN o.state IN ('RUNNING','UPCOMING')
                            THEN (SELECT count(*) FROM public.lwb_party_rate_offer_lines l WHERE l.offer_id = o.id AND l.recheck_at IS NOT NULL)
                            ELSE 0 END,
      'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('item', l.item, 'rate', l.rate, 'note', l.note, 'roi', l.roi,
                                  'landing', l.landing, 'recheck_at', l.recheck_at, 'recheck_note', l.recheck_note) ORDER BY l.line_no)
                FROM public.lwb_party_rate_offer_lines l WHERE l.offer_id = o.id), '[]'::jsonb))
      ORDER BY o.offer_date DESC, o.id DESC)
    FROM (SELECT o.*, public.lwb_party_rate_state(o) AS state FROM public.lwb_party_rate_offers o
           WHERE (p_party IS NULL OR o.party_key = public.lwb_party_rate_key(p_party))
             AND (o.offer_date >= public.lwb_party_rate_today() - greatest(coalesce(p_days, 90), 1)
                  OR public.lwb_party_rate_state(o) IN ('RUNNING','UPCOMING'))
           ORDER BY o.offer_date DESC, o.id DESC LIMIT 500) o), '[]'::jsonb);
END;
$fn$;

-- Last active rate of each item for one party (+ ROI)
CREATE OR REPLACE FUNCTION public.lwb_party_rate_last(p_party text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_rate_editor() THEN RAISE EXCEPTION 'Only Admin or Sales Head can see party rates.'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('item', x.item, 'item_key', x.item_key, 'rate', x.rate, 'roi', x.roi, 'offer_date', x.offer_date,
                                        'offer_no', x.offer_no, 'by', public.lwb_party_rate_who(x.created_by)) ORDER BY x.line_no)
    FROM (SELECT DISTINCT ON (l.item_key) l.item, l.item_key, l.rate, l.roi, l.line_no, o.offer_date, o.offer_no, o.created_by
            FROM public.lwb_party_rate_offer_lines l JOIN public.lwb_party_rate_offers o ON o.id = l.offer_id
           WHERE o.party_key = public.lwb_party_rate_key(p_party) AND o.status = 'ACTIVE'
           ORDER BY l.item_key, o.offer_date DESC, o.id DESC) x), '[]'::jsonb);
END;
$fn$;

-- Rate checked: clear the recheck flag on every line of one offer
CREATE OR REPLACE FUNCTION public.lwb_party_rate_recheck_done(p_id bigint)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_n integer;
BEGIN
  IF NOT public.lwb_rate_editor() THEN RAISE EXCEPTION 'Only Admin or Sales Head can do this.'; END IF;
  UPDATE public.lwb_party_rate_offer_lines SET recheck_at = NULL, checked_at = now(), checked_by = auth.uid()
   WHERE offer_id = p_id AND recheck_at IS NOT NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;

-- ---------- pack rate changed -> flag running / later offers of that pack ----------
CREATE OR REPLACE FUNCTION public.lwb_party_rate_pack_changed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_note text := ''; v_keys text[];
BEGIN
  IF NEW.gr IS DISTINCT FROM OLD.gr THEN v_note := v_note || ' · GR ' || trim_scale(OLD.gr)::text || '→' || trim_scale(NEW.gr)::text; END IF;
  IF NEW.slab3_rate IS DISTINCT FROM OLD.slab3_rate THEN v_note := v_note || ' · List ' || trim_scale(OLD.slab3_rate)::text || '→' || trim_scale(NEW.slab3_rate)::text; END IF;
  IF NEW.mepd_pct IS DISTINCT FROM OLD.mepd_pct THEN v_note := v_note || ' · MEPD % ' || coalesce(trim_scale(OLD.mepd_pct)::text, '-') || '→' || coalesce(trim_scale(NEW.mepd_pct)::text, '-'); END IF;
  IF NEW.oms IS DISTINCT FROM OLD.oms THEN v_note := v_note || ' · OMS ' || coalesce(trim_scale(OLD.oms)::text, '-') || '→' || coalesce(trim_scale(NEW.oms)::text, '-'); END IF;
  IF NEW.qps IS DISTINCT FROM OLD.qps THEN v_note := v_note || ' · QPS ' || trim_scale(OLD.qps)::text || '→' || trim_scale(NEW.qps)::text; END IF;
  IF NEW.free_bottle IS DISTINCT FROM OLD.free_bottle THEN v_note := v_note || ' · Free btl ' || trim_scale(OLD.free_bottle)::text || '→' || trim_scale(NEW.free_bottle)::text; END IF;
  IF NEW.case_config IS DISTINCT FROM OLD.case_config THEN v_note := v_note || ' · Case ' || trim_scale(OLD.case_config)::text || '→' || trim_scale(NEW.case_config)::text; END IF;
  IF v_note = '' THEN RETURN NEW; END IF;
  v_note := 'Rate changed ' || to_char(public.lwb_party_rate_today(), 'DD Mon') || v_note;
  SELECT array_agg(DISTINCT k) INTO v_keys FROM (
    SELECT public.lwb_party_rate_key(NEW.pack_name) AS k
    UNION SELECT public.lwb_party_rate_key(OLD.pack_name)
    UNION SELECT public.lwb_party_rate_key(s.sku_key) FROM public.lwb_rate_pack_skus s WHERE s.pack_id = NEW.id) x;
  UPDATE public.lwb_party_rate_offer_lines l SET recheck_at = now(), recheck_note = left(v_note, 300)
    FROM public.lwb_party_rate_offers o
   WHERE o.id = l.offer_id AND l.item_key = ANY(v_keys)
     AND public.lwb_party_rate_state(o) IN ('RUNNING','UPCOMING');
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_rate_pack_changed() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS lwb_party_rate_pack_changed ON public.lwb_rate_packs;
CREATE TRIGGER lwb_party_rate_pack_changed AFTER UPDATE ON public.lwb_rate_packs
  FOR EACH ROW EXECUTE FUNCTION public.lwb_party_rate_pack_changed();

-- ---------- ROI report for one month ----------
-- earned = purchase cases of the month (goods inward, SKUs not in a no-ROI category) × ROI ₹ / case
-- given  = cases sold that month (orders not cancelled) on an offer line marked ROI, that line's ROI ₹ / case
CREATE OR REPLACE FUNCTION public.lwb_party_roi_report(p_month date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_from date := date_trunc('month', coalesce(p_month, public.lwb_party_rate_today()))::date;
  v_to date := (date_trunc('month', coalesce(p_month, public.lwb_party_rate_today())) + interval '1 month - 1 day')::date;
  v_roi numeric; v_skip text[]; v_earned jsonb := '[]'::jsonb; v_given jsonb;
BEGIN
  IF NOT public.lwb_rate_editor() THEN RAISE EXCEPTION 'Only Admin or Sales Head can see the ROI report.'; END IF;
  SELECT roi_per_case, no_roi_categories INTO v_roi, v_skip FROM public.lwb_party_roi_settings WHERE id = 1;
  v_roi := coalesce(v_roi, 0); v_skip := coalesce(v_skip, '{}');

  IF to_regclass('public.lwb_goods_inward_items') IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object('category', c.cat, 'cases', round(c.cases, 2), 'roi', NOT (c.cat = ANY(v_skip)),
                                                 'amount', CASE WHEN c.cat = ANY(v_skip) THEN 0 ELSE round(c.cases * v_roi, 2) END)
                              ORDER BY (c.cat = ANY(v_skip)), c.cases DESC), '[]'::jsonb)
      INTO v_earned
    FROM (
      SELECT coalesce(nullif(upper(btrim(s.category)), ''), 'NO CATEGORY') AS cat,
             sum(coalesce(nullif(it->>'quantity_pcs', ''), nullif(it->>'total_pcs', ''), nullif(it->>'qty_pcs', ''), '0')::numeric
                 / greatest(coalesce(s.pcs_per_case, 1), 1)) AS cases
      FROM public.lwb_goods_inward g
      CROSS JOIN LATERAL to_jsonb(g) gj
      JOIN public.lwb_goods_inward_items ii ON ii.inward_id = g.id
      CROSS JOIN LATERAL to_jsonb(ii) it
      LEFT JOIN public.sku_master s ON s.id::text = ii.sku_id::text
      WHERE coalesce(nullif(gj->>'invoice_date', '')::date, nullif(gj->>'received_date', '')::date) BETWEEN v_from AND v_to
      GROUP BY 1
    ) c WHERE c.cases <> 0;
  END IF;

  WITH lines AS (
    SELECT i.id AS item_id, o.id AS order_id, o.order_no, o.customer_name,
           public.lwb_party_rate_key(o.customer_name) AS party_key, upper(btrim(coalesce(i.sku_name, ''))) AS sku_key, i.sku_name,
           timezone('Asia/Kolkata', o.order_date::timestamptz)::date AS d,
           coalesce(nullif(i.loaded_qty, 0), i.approved_qty, i.ordered_qty, 0)::numeric AS cases, i.rate AS sold_rate
    FROM public.orders o JOIN public.order_items i ON i.order_id = o.id
    WHERE timezone('Asia/Kolkata', o.order_date::timestamptz)::date BETWEEN v_from AND v_to
      AND lower(btrim(coalesce(o.status::text, ''))) NOT IN ('cancelled','canceled','rejected','draft','')
  ), hit AS (
    SELECT DISTINCT ON (x.item_id) x.*, l.item, l.roi, l.rate AS offer_rate, ofr.offer_no
    FROM lines x
    JOIN public.lwb_party_rate_offers ofr ON ofr.party_key = x.party_key AND ofr.status = 'ACTIVE'
      AND ofr.valid_from <= x.d AND (ofr.offer_type <> 'DATED' OR ofr.valid_to >= x.d)
      AND (ofr.offer_type <> 'ONE_TIME' OR ofr.used_order_id = x.order_id)
    JOIN public.lwb_party_rate_offer_lines l ON l.offer_id = ofr.id AND l.roi > 0
    WHERE l.item_key = x.sku_key
       OR EXISTS (SELECT 1 FROM public.lwb_rate_pack_skus ps JOIN public.lwb_rate_packs pk ON pk.id = ps.pack_id
                   WHERE public.lwb_party_rate_key(pk.pack_name) = l.item_key AND upper(btrim(ps.sku_key)) = x.sku_key)
    ORDER BY x.item_id, ofr.valid_from DESC, ofr.id DESC
  ), per_item AS (
    SELECT h.customer_name, h.item, h.roi, sum(h.cases) AS cases, sum(h.cases * h.roi) AS amount,
           count(DISTINCT h.order_id) AS orders, max(h.offer_no) AS offer_no
    FROM hit h GROUP BY h.customer_name, h.item, h.roi
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('party', p.customer_name, 'cases', round(p.cases, 2), 'amount', round(p.amount, 2),
                                               'orders', p.orders, 'items', p.items) ORDER BY p.amount DESC), '[]'::jsonb)
    INTO v_given
  FROM (SELECT customer_name, sum(cases) AS cases, sum(amount) AS amount, sum(orders) AS orders,
               jsonb_agg(jsonb_build_object('item', item, 'roi', roi, 'cases', round(cases, 2), 'amount', round(amount, 2), 'offer_no', offer_no)
                         ORDER BY amount DESC) AS items
          FROM per_item GROUP BY customer_name) p;

  RETURN jsonb_build_object(
    'from', v_from, 'to', v_to, 'roi_per_case', v_roi, 'no_roi_categories', to_jsonb(v_skip),
    'earned', v_earned,
    'earned_cases', (SELECT coalesce(sum((e->>'cases')::numeric), 0) FROM jsonb_array_elements(v_earned) e WHERE (e->>'roi')::boolean),
    'earned_amount', (SELECT coalesce(sum((e->>'amount')::numeric), 0) FROM jsonb_array_elements(v_earned) e),
    'given', v_given,
    'given_cases', (SELECT coalesce(sum((g->>'cases')::numeric), 0) FROM jsonb_array_elements(v_given) g),
    'given_amount', (SELECT coalesce(sum((g->>'amount')::numeric), 0) FROM jsonb_array_elements(v_given) g),
    'roi_parties', (SELECT count(DISTINCT o.party_key) FROM public.lwb_party_rate_offers o
                     WHERE public.lwb_party_rate_state(o) = 'RUNNING'
                       AND EXISTS (SELECT 1 FROM public.lwb_party_rate_offer_lines l WHERE l.offer_id = o.id AND l.roi > 0)));
END;
$fn$;

-- PO List (Mohit, 22 Nov 2026): which of these orders have a line on an ROI offer rate -> [{id, cases, amount}].
-- Not Admin / Sales Head -> [] (no error, the PO list just shows no ROI mark).
CREATE OR REPLACE FUNCTION public.lwb_party_roi_orders(p_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_rate_editor() OR p_ids IS NULL THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((
    WITH lines AS (
      SELECT i.id AS item_id, o.id AS order_id, public.lwb_party_rate_key(o.customer_name) AS party_key,
             upper(btrim(coalesce(i.sku_name, ''))) AS sku_key,
             timezone('Asia/Kolkata', o.order_date::timestamptz)::date AS d,
             coalesce(nullif(i.loaded_qty, 0), i.approved_qty, i.ordered_qty, 0)::numeric AS cases
      FROM public.orders o JOIN public.order_items i ON i.order_id = o.id
      WHERE o.id = ANY(p_ids[1:500])
    ), hit AS (
      SELECT DISTINCT ON (x.item_id) x.order_id, x.cases, l.roi
      FROM lines x
      JOIN public.lwb_party_rate_offers ofr ON ofr.party_key = x.party_key AND ofr.status = 'ACTIVE'
        AND ofr.valid_from <= x.d AND (ofr.offer_type <> 'DATED' OR ofr.valid_to >= x.d)
        AND (ofr.offer_type <> 'ONE_TIME' OR ofr.used_order_id = x.order_id)
      JOIN public.lwb_party_rate_offer_lines l ON l.offer_id = ofr.id AND l.roi > 0
      WHERE l.item_key = x.sku_key
         OR EXISTS (SELECT 1 FROM public.lwb_rate_pack_skus ps JOIN public.lwb_rate_packs pk ON pk.id = ps.pack_id
                     WHERE public.lwb_party_rate_key(pk.pack_name) = l.item_key AND upper(btrim(ps.sku_key)) = x.sku_key)
      ORDER BY x.item_id, ofr.valid_from DESC, ofr.id DESC
    )
    SELECT jsonb_agg(jsonb_build_object('id', g.order_id, 'cases', g.cases, 'amount', g.amount))
    FROM (SELECT h.order_id, round(sum(h.cases), 2) AS cases, round(sum(h.cases * h.roi), 2) AS amount FROM hit h GROUP BY h.order_id) g), '[]'::jsonb);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_party_roi_settings_save(numeric, text[]), public.lwb_party_rate_recheck_done(bigint),
  public.lwb_party_roi_report(date), public.lwb_party_roi_orders(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_roi_settings_save(numeric, text[]), public.lwb_party_rate_recheck_done(bigint),
  public.lwb_party_roi_report(date), public.lwb_party_roi_orders(uuid[]), public.lwb_party_rate_offer_save(jsonb), public.lwb_party_rate_offer_list(integer, text),
  public.lwb_party_rate_last(text) TO authenticated;

COMMIT;
