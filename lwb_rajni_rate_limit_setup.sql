-- LUXURY WRIST BRAND ERP — RAJNIGANDHA RATE LIMIT, ADMIN RATE OK AND PROFIT
--
-- Runs by itself when merged to main (after lwb_quick_slip_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (2 Nov 2026): Rajnigandha gives a flat landing per box. Admin sets per SKU the landing, the
-- lowest sale rate (min) and the normal sale rate (std). A Salesman / Sales Head who gives a rate below the
-- min cannot make the slip: the PO goes to Admin, who sees the rate given and only presses "Approve"
-- (then the slip is made and the PO goes to Accounts for the Tally bill). Admin sees the profit
-- (rate − landing) of every slip. Sales roles never see landing / profit unless Admin ticks that person.
--
--   * lwb_sku_price_limits (sku_key = upper SKU name): landing, min_rate, std_rate. History in
--     lwb_sku_price_history. Read / written only through the functions below.
--   * lwb_price_viewers: people Admin lets see landing + profit (Admin always sees it).
--   * lwb_rate_approvals: PO waiting for Admin's rate OK, with the driver / vehicle typed on save.
--   * lwb_order_landing: landing of each slip line, kept when the slip is made (later landing changes do
--     not change old profit).
--   * Trigger on lwb_quick_slips: no slip below the min rate unless Admin made it or approved it.
--   * Trigger on order_items: after a slip is made only Admin can put a line below the min rate.
-- No Tally, ledger, payment, stock or bill amount is written here.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Tables (no direct access; functions only)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_sku_price_limits (
  sku_key    text PRIMARY KEY CHECK (sku_key = upper(btrim(sku_key)) AND sku_key <> ''),
  landing    numeric(14,2) CHECK (landing IS NULL OR landing >= 0),
  min_rate   numeric(14,2) CHECK (min_rate IS NULL OR min_rate >= 0),
  std_rate   numeric(14,2) CHECK (std_rate IS NULL OR std_rate >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
CREATE TABLE IF NOT EXISTS public.lwb_sku_price_history (
  id         bigserial PRIMARY KEY,
  sku_key    text NOT NULL,
  landing    numeric(14,2),
  min_rate   numeric(14,2),
  std_rate   numeric(14,2),
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);
CREATE INDEX IF NOT EXISTS lwb_sku_price_history_sku_idx ON public.lwb_sku_price_history (sku_key, created_at DESC);
CREATE TABLE IF NOT EXISTS public.lwb_price_viewers (
  user_id  uuid PRIMARY KEY,
  added_by uuid,
  added_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.lwb_rate_approvals (
  order_id     uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  status       text NOT NULL DEFAULT 'WAITING' CHECK (status IN ('WAITING','APPROVED')),
  slip         jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {driver_name, vehicle_no, driver_mobile}
  note         text,
  requested_by uuid,
  requested_at timestamptz NOT NULL DEFAULT now(),
  approved_by  uuid,
  approved_at  timestamptz
);
CREATE TABLE IF NOT EXISTS public.lwb_order_landing (
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  sku_key  text NOT NULL,
  landing  numeric(14,2) NOT NULL,
  PRIMARY KEY (order_id, sku_key)
);
ALTER TABLE public.lwb_sku_price_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_sku_price_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_price_viewers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_rate_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_order_landing ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_sku_price_limits, public.lwb_sku_price_history, public.lwb_price_viewers,
  public.lwb_rate_approvals, public.lwb_order_landing FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_price_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) = 'admin');
$fn$;

-- Admin, or a person Admin ticked: may see landing and profit.
CREATE OR REPLACE FUNCTION public.lwb_price_can_see()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT public.lwb_price_admin()
      OR EXISTS (SELECT 1 FROM public.lwb_price_viewers v JOIN public.user_profiles p ON p.id = v.user_id
                 WHERE v.user_id = auth.uid() AND p.active = true);
$fn$;

-- Lines of an order whose rate is below the min rate.
CREATE OR REPLACE FUNCTION public.lwb_rate_breaches(p_order_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(jsonb_agg(jsonb_build_object('sku', i.sku_name, 'rate', i.rate, 'min_rate', l.min_rate) ORDER BY i.sku_name), '[]'::jsonb)
  FROM public.order_items i
  JOIN public.lwb_sku_price_limits l ON l.sku_key = upper(btrim(i.sku_name))
  WHERE i.order_id = p_order_id AND l.min_rate IS NOT NULL AND coalesce(i.rate, 0) < l.min_rate;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. Rates for the PO form (every active login): min + std rate, never the landing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_sale_rates()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true)
    THEN coalesce((SELECT jsonb_agg(jsonb_build_object('sku_key', l.sku_key, 'min_rate', l.min_rate, 'std_rate', l.std_rate))
                   FROM public.lwb_sku_price_limits l WHERE l.min_rate IS NOT NULL OR l.std_rate IS NOT NULL), '[]'::jsonb)
    ELSE '[]'::jsonb END;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. Rate list page (Admin edits; a ticked person reads)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_price_limits_get()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_price_can_see() THEN RAISE EXCEPTION 'Only Admin can see the landing rate list.'; END IF;
  RETURN jsonb_build_object(
    'can_edit', public.lwb_price_admin(),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('sku_key', l.sku_key, 'landing', l.landing, 'min_rate', l.min_rate,
               'std_rate', l.std_rate, 'updated_at', l.updated_at,
               'updated_by', (SELECT coalesce(nullif(btrim(p.full_name),''), p.role) FROM public.user_profiles p WHERE p.id = l.updated_by)))
             FROM public.lwb_sku_price_limits l), '[]'::jsonb),
    'viewers', CASE WHEN public.lwb_price_admin() THEN
      coalesce((SELECT jsonb_agg(v.user_id) FROM public.lwb_price_viewers v), '[]'::jsonb) ELSE '[]'::jsonb END);
END;
$fn$;

-- p = [{sku_key, landing, min_rate, std_rate}]. A row with all three empty is removed. Changed rows go to history.
CREATE OR REPLACE FUNCTION public.lwb_price_limits_save(p jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r jsonb; v_key text; v_l numeric; v_m numeric; v_s numeric; v_old public.lwb_sku_price_limits%ROWTYPE; v_n integer := 0;
BEGIN
  IF NOT public.lwb_price_admin() THEN RAISE EXCEPTION 'Only Admin can change the rate list.'; END IF;
  IF jsonb_typeof(p) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Nothing to save.'; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p) LOOP
    v_key := upper(btrim(coalesce(r->>'sku_key','')));
    IF v_key = '' THEN CONTINUE; END IF;
    v_l := nullif(btrim(coalesce(r->>'landing','')),'')::numeric;
    v_m := nullif(btrim(coalesce(r->>'min_rate','')),'')::numeric;
    v_s := nullif(btrim(coalesce(r->>'std_rate','')),'')::numeric;
    IF v_l < 0 OR v_m < 0 OR v_s < 0 THEN RAISE EXCEPTION '%: rate cannot be below 0.', v_key; END IF;
    IF v_m IS NOT NULL AND v_s IS NOT NULL AND v_s < v_m THEN
      RAISE EXCEPTION '%: Std sale ₹% is below Min sale ₹%.', v_key, v_s, v_m;
    END IF;
    SELECT * INTO v_old FROM public.lwb_sku_price_limits WHERE sku_key = v_key;
    IF FOUND AND v_old.landing IS NOT DISTINCT FROM v_l AND v_old.min_rate IS NOT DISTINCT FROM v_m
       AND v_old.std_rate IS NOT DISTINCT FROM v_s THEN CONTINUE; END IF;
    IF NOT FOUND AND v_l IS NULL AND v_m IS NULL AND v_s IS NULL THEN CONTINUE; END IF;
    IF v_l IS NULL AND v_m IS NULL AND v_s IS NULL THEN
      DELETE FROM public.lwb_sku_price_limits WHERE sku_key = v_key;
    ELSE
      INSERT INTO public.lwb_sku_price_limits (sku_key, landing, min_rate, std_rate, updated_at, updated_by)
      VALUES (v_key, v_l, v_m, v_s, now(), auth.uid())
      ON CONFLICT (sku_key) DO UPDATE SET landing = EXCLUDED.landing, min_rate = EXCLUDED.min_rate,
        std_rate = EXCLUDED.std_rate, updated_at = now(), updated_by = auth.uid();
    END IF;
    INSERT INTO public.lwb_sku_price_history (sku_key, landing, min_rate, std_rate, created_by) VALUES (v_key, v_l, v_m, v_s, auth.uid());
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_price_history(p_sku text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_price_can_see() THEN RAISE EXCEPTION 'Only Admin can see the rate history.'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('landing', h.landing, 'min_rate', h.min_rate, 'std_rate', h.std_rate,
            'at', h.created_at, 'by', (SELECT coalesce(nullif(btrim(p.full_name),''), p.role) FROM public.user_profiles p WHERE p.id = h.created_by))
            ORDER BY h.created_at DESC)
          FROM (SELECT * FROM public.lwb_sku_price_history WHERE sku_key = upper(btrim(p_sku)) ORDER BY created_at DESC LIMIT 100) h), '[]'::jsonb);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_price_viewer_set(p_user uuid, p_on boolean)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_price_admin() THEN RAISE EXCEPTION 'Only Admin can choose who sees landing and profit.'; END IF;
  IF p_on THEN
    INSERT INTO public.lwb_price_viewers (user_id, added_by) VALUES (p_user, auth.uid()) ON CONFLICT (user_id) DO NOTHING;
  ELSE
    DELETE FROM public.lwb_price_viewers WHERE user_id = p_user;
  END IF;
  RETURN p_on;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 5. Guards: no slip below min rate without Admin; landing kept with each slip.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_rate_slip_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_b jsonb := public.lwb_rate_breaches(NEW.order_id);
BEGIN
  IF jsonb_array_length(v_b) > 0 AND NOT public.lwb_price_admin()
     AND NOT EXISTS (SELECT 1 FROM public.lwb_rate_approvals a WHERE a.order_id = NEW.order_id AND a.status = 'APPROVED') THEN
    RAISE EXCEPTION 'RATE_BELOW_MIN: % — rate below the allowed min. Send it to Admin for rate OK.',
      (SELECT string_agg((x->>'sku') || ' ₹' || (x->>'rate') || ' (min ₹' || (x->>'min_rate') || ')', ', ') FROM jsonb_array_elements(v_b) x);
  END IF;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS lwb_rate_slip_guard ON public.lwb_quick_slips;
CREATE TRIGGER lwb_rate_slip_guard BEFORE INSERT ON public.lwb_quick_slips
  FOR EACH ROW EXECUTE FUNCTION public.lwb_rate_slip_guard();

CREATE OR REPLACE FUNCTION public.lwb_rate_slip_landing()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  INSERT INTO public.lwb_order_landing (order_id, sku_key, landing)
  SELECT DISTINCT ON (upper(btrim(i.sku_name))) NEW.order_id, upper(btrim(i.sku_name)), l.landing
  FROM public.order_items i JOIN public.lwb_sku_price_limits l ON l.sku_key = upper(btrim(i.sku_name))
  WHERE i.order_id = NEW.order_id AND l.landing IS NOT NULL
  ON CONFLICT (order_id, sku_key) DO NOTHING;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS lwb_rate_slip_landing ON public.lwb_quick_slips;
CREATE TRIGGER lwb_rate_slip_landing AFTER INSERT ON public.lwb_quick_slips
  FOR EACH ROW EXECUTE FUNCTION public.lwb_rate_slip_landing();

-- After the slip: a Sales Head changing the PO (lwb_head_modify_order) cannot go below min; Admin can.
CREATE OR REPLACE FUNCTION public.lwb_rate_item_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_min numeric;
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.rate IS NOT DISTINCT FROM OLD.rate AND NEW.sku_name IS NOT DISTINCT FROM OLD.sku_name THEN RETURN NEW; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_quick_slips s WHERE s.order_id = NEW.order_id) THEN RETURN NEW; END IF;
  SELECT l.min_rate INTO v_min FROM public.lwb_sku_price_limits l WHERE l.sku_key = upper(btrim(NEW.sku_name));
  IF v_min IS NOT NULL AND coalesce(NEW.rate, 0) < v_min AND auth.uid() IS NOT NULL AND NOT public.lwb_price_admin()
     AND (TG_OP = 'INSERT' OR coalesce(NEW.rate, 0) < coalesce(OLD.rate, 0) OR NEW.sku_name IS DISTINCT FROM OLD.sku_name) THEN
    RAISE EXCEPTION 'RATE_BELOW_MIN: % ₹% is below the min ₹%. Only Admin can give this rate.', NEW.sku_name, coalesce(NEW.rate, 0), v_min;
  END IF;
  -- A new SKU added to a slip PO: keep its landing too.
  INSERT INTO public.lwb_order_landing (order_id, sku_key, landing)
  SELECT NEW.order_id, l.sku_key, l.landing FROM public.lwb_sku_price_limits l
  WHERE l.sku_key = upper(btrim(NEW.sku_name)) AND l.landing IS NOT NULL
  ON CONFLICT (order_id, sku_key) DO NOTHING;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS lwb_rate_item_guard ON public.order_items;
CREATE TRIGGER lwb_rate_item_guard BEFORE INSERT OR UPDATE OF rate, sku_name ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION public.lwb_rate_item_guard();

-- ---------------------------------------------------------------------------
-- 6. Send to Admin / Admin approves
-- ---------------------------------------------------------------------------
-- Same people as lwb_quick_slip_dispatch. Saves driver / vehicle; Admin gets a RATE_APPROVAL popup.
CREATE OR REPLACE FUNCTION public.lwb_rate_request(p_order_id uuid, p jsonb, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_o public.orders%ROWTYPE; v_role text := public.lwb_quick_slip_role(); v_b jsonb;
        v_name text := left(btrim(regexp_replace(coalesce(p->>'driver_name',''), '\s+', ' ', 'g')), 80);
        v_veh text := upper(regexp_replace(coalesce(p->>'vehicle_no',''), '[^A-Za-z0-9]', '', 'g'));
        v_msg text;
BEGIN
  IF v_role NOT IN ('admin','manager','sales','salesman') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head or the salesman of the order can send it.';
  END IF;
  IF v_name = '' THEN RAISE EXCEPTION 'Enter the driver name.'; END IF;
  IF length(v_veh) < 4 OR length(v_veh) > 20 THEN RAISE EXCEPTION 'Enter the vehicle number.'; END IF;
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF v_role IN ('sales','salesman') AND v_o.created_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Only Admin, Sales Head or the salesman of the order can send it.';
  END IF;
  IF lower(btrim(coalesce(v_o.status,''))) IN ('cancelled','canceled','loaded','invoiced','dispatched','delivered','closed','completed')
     OR EXISTS (SELECT 1 FROM public.lwb_quick_slips s WHERE s.order_id = v_o.id) THEN
    RAISE EXCEPTION 'PO % is already %.', v_o.order_no, v_o.status;
  END IF;
  IF public.lwb_quick_slip_company(v_o.id) IS NULL THEN RAISE EXCEPTION 'PO % is not a Rajnigandha slip PO.', v_o.order_no; END IF;
  v_b := public.lwb_rate_breaches(v_o.id);
  IF jsonb_array_length(v_b) = 0 THEN RAISE EXCEPTION 'PO % has no rate below the min. Make the slip directly.', v_o.order_no; END IF;

  INSERT INTO public.lwb_rate_approvals (order_id, status, slip, note, requested_by, requested_at, approved_by, approved_at)
  VALUES (v_o.id, 'WAITING', jsonb_build_object('driver_name', v_name, 'vehicle_no', v_veh, 'driver_mobile', p->>'driver_mobile'),
          nullif(left(btrim(coalesce(p_note,'')), 300),''), auth.uid(), now(), NULL, NULL)
  ON CONFLICT (order_id) DO UPDATE SET status = 'WAITING', slip = EXCLUDED.slip, note = EXCLUDED.note,
    requested_by = EXCLUDED.requested_by, requested_at = now(), approved_by = NULL, approved_at = NULL;

  v_msg := coalesce(v_o.order_no,'PO') || ' · ' || coalesce(btrim(v_o.customer_name),'') || ' · ' || coalesce(v_o.sales_person,'') || ' · ' ||
    (SELECT string_agg((x->>'sku') || ' ₹' || (x->>'rate') || ' (min ₹' || (x->>'min_rate') || ')', ', ') FROM jsonb_array_elements(v_b) x);
  BEGIN
    UPDATE public.erp_notifications SET is_read = true WHERE order_id = v_o.id AND is_read = false AND notification_type = 'RATE_APPROVAL';
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT p.id, 'Rate below min — Admin OK needed', v_msg, 'RATE_APPROVAL', v_o.id
    FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'admin';
  EXCEPTION WHEN others THEN NULL;  -- a popup never stops the request
  END;
  RETURN jsonb_build_object('order_id', v_o.id, 'order_no', v_o.order_no, 'status', 'WAITING', 'lines', v_b);
END;
$fn$;

-- Admin: POs waiting for the rate OK, with given / min / landing / profit per line.
CREATE OR REPLACE FUNCTION public.lwb_rate_waiting()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_admin boolean := public.lwb_price_admin(); v_see boolean := public.lwb_price_can_see();
        v_role text := public.lwb_quick_slip_role();
BEGIN
  IF v_role NOT IN ('admin','manager','sales','salesman') THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
      'order_id', o.id, 'order_no', o.order_no, 'order_date', o.order_date, 'party', btrim(o.customer_name),
      'sales_person', o.sales_person, 'status', o.status, 'requested_at', a.requested_at, 'note', a.note,
      'driver_name', a.slip->>'driver_name', 'vehicle_no', a.slip->>'vehicle_no', 'can_approve', v_admin,
      'lines', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'sku', i.sku_name, 'qty', coalesce(i.approved_qty, i.ordered_qty, 0), 'rate', coalesce(i.rate, 0),
                  'min_rate', l.min_rate,
                  'landing', CASE WHEN v_see THEN l.landing END) ORDER BY i.sku_name), '[]'::jsonb)
                FROM public.order_items i LEFT JOIN public.lwb_sku_price_limits l ON l.sku_key = upper(btrim(i.sku_name))
                WHERE i.order_id = o.id)) ORDER BY a.requested_at DESC)
    FROM public.lwb_rate_approvals a JOIN public.orders o ON o.id = a.order_id
    WHERE a.status = 'WAITING'
      AND NOT EXISTS (SELECT 1 FROM public.lwb_quick_slips s WHERE s.order_id = o.id)
      AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled')
      AND (v_role IN ('admin','manager') OR o.created_by = auth.uid())
      AND public.lwb_company_ok(public.lwb_quick_slip_company(o.id))), '[]'::jsonb);
END;
$fn$;

-- Admin presses Approve: the slip is made with the saved driver / vehicle (PO goes to Accounts).
CREATE OR REPLACE FUNCTION public.lwb_rate_approve(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_a public.lwb_rate_approvals%ROWTYPE; v_r jsonb; v_o public.orders%ROWTYPE;
BEGIN
  IF NOT public.lwb_price_admin() THEN RAISE EXCEPTION 'Only Admin can approve the rate.'; END IF;
  SELECT * INTO v_a FROM public.lwb_rate_approvals WHERE order_id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'This PO is not waiting for a rate OK.'; END IF;
  UPDATE public.lwb_rate_approvals SET status = 'APPROVED', approved_by = auth.uid(), approved_at = now() WHERE order_id = p_order_id;
  v_r := public.lwb_quick_slip_dispatch(p_order_id, v_a.slip);
  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id;
  BEGIN
    UPDATE public.erp_notifications SET is_read = true WHERE order_id = p_order_id AND is_read = false AND notification_type = 'RATE_APPROVAL';
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type, order_id)
    SELECT DISTINCT u, 'Rate OK by Admin — slip made', coalesce(v_o.order_no,'PO') || ' · ' || coalesce(btrim(v_o.customer_name),'') ||
           '. Slip ready to print, sent to Accounts.', 'RATE_APPROVED', p_order_id
    FROM unnest(ARRAY[v_a.requested_by, v_o.created_by]) u WHERE u IS NOT NULL AND u IS DISTINCT FROM auth.uid();
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN v_r;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 7. Profit of slips (Admin / ticked person): amount, landing, profit per PO.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_slip_profit(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_from date := coalesce(p_from, (now() AT TIME ZONE 'Asia/Kolkata')::date);
        v_to date := coalesce(p_to, (now() AT TIME ZONE 'Asia/Kolkata')::date);
BEGIN
  IF NOT public.lwb_price_can_see() THEN RETURN NULL; END IF;
  IF v_to < v_from OR v_to - v_from > 400 THEN RAISE EXCEPTION 'Choose up to 400 days.'; END IF;
  RETURN coalesce((
    SELECT jsonb_object_agg(x.order_id::text, jsonb_build_object('landing', x.landing, 'profit', x.amount - x.landing,
             'missing', x.missing, 'rate_ok_by_admin', x.ok))
    FROM (
      SELECT s.order_id,
             sum(round(coalesce(i.loaded_qty,0)::numeric * coalesce(i.rate,0)::numeric, 2)) AS amount,
             sum(round(coalesce(i.loaded_qty,0)::numeric * coalesce(ol.landing, 0), 2)) AS landing,
             count(*) FILTER (WHERE ol.landing IS NULL AND coalesce(i.loaded_qty,0) > 0) AS missing,
             EXISTS (SELECT 1 FROM public.lwb_rate_approvals a WHERE a.order_id = s.order_id AND a.status = 'APPROVED') AS ok
      FROM public.lwb_quick_slips s
      JOIN public.order_items i ON i.order_id = s.order_id
      LEFT JOIN public.lwb_order_landing ol ON ol.order_id = s.order_id AND ol.sku_key = upper(btrim(i.sku_name))
      WHERE (s.created_at AT TIME ZONE 'Asia/Kolkata')::date BETWEEN v_from AND v_to
        AND public.lwb_company_ok(s.company_id)
      GROUP BY s.order_id) x), '{}'::jsonb);
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_price_admin(), public.lwb_price_can_see(), public.lwb_rate_breaches(uuid),
  public.lwb_rate_slip_guard(), public.lwb_rate_slip_landing(), public.lwb_rate_item_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_sale_rates(), public.lwb_price_limits_get(), public.lwb_price_limits_save(jsonb),
  public.lwb_price_history(text), public.lwb_price_viewer_set(uuid, boolean), public.lwb_rate_request(uuid, jsonb, text),
  public.lwb_rate_waiting(), public.lwb_rate_approve(uuid), public.lwb_slip_profit(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sale_rates(), public.lwb_price_limits_get(), public.lwb_price_limits_save(jsonb),
  public.lwb_price_history(text), public.lwb_price_viewer_set(uuid, boolean), public.lwb_rate_request(uuid, jsonb, text),
  public.lwb_rate_waiting(), public.lwb_rate_approve(uuid), public.lwb_slip_profit(date, date) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
