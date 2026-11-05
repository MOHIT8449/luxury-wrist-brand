-- LUXURY WRIST BRAND ERP — HIRED VEHICLES: FIXED RENT + RENT LEDGER
--
-- Runs by itself when merged to main (after lwb_fleet_master_setup.sql, lwb_accounts_vehicle_setup.sql,
-- lwb_employee_roles_setup.sql). Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (5 Nov 2026): pickups / Bolero of outside owners work for us all the time on a fixed rent
-- (per month, per route or per trip). They are not staff, so they stay in Vehicle Master (ownership
-- Transporter) with a rent setup, and every hired vehicle gets a rent ledger:
--
--   balance to pay = old balance + rent (month / trips / extra) − rent paid − expenses cut from rent
--
--   * Monthly: the month's rent is added on the 1st of every month from the start date
--     (first month counted for the days from the start date). Added when the Accounts page opens.
--   * Per trip / per route: trips are added from "+ Trip" (Transport Assignment days of that vehicle
--     are shown to pick from). Rate = trip rate, or the route's rate.
--   * Extra: + halt / loading charge, or − days off.
--   * Rent paid = Cash Out with the vehicle and head "Vehicle rent". If "cut from rent" is on, every other
--     Cash Out on that vehicle (diesel, advance ...) from the start date is cut from the rent.
-- Payments stay normal Cash Out entries, so the cash book stays right.

BEGIN;

INSERT INTO public.lwb_acc_categories (kind, name, sort)
SELECT 'OUT', 'Vehicle rent', 91
WHERE NOT EXISTS (SELECT 1 FROM public.lwb_acc_categories c WHERE c.kind = 'OUT' AND lower(btrim(c.name)) = 'vehicle rent');

-- Rent setup, one row per hired vehicle (no grants: only through the functions below).
CREATE TABLE IF NOT EXISTS public.lwb_hired_vehicles (
  vehicle_id      uuid PRIMARY KEY REFERENCES public.lwb_vehicles(id) ON DELETE RESTRICT,
  rent_type       text NOT NULL CHECK (rent_type IN ('MONTHLY','TRIP','ROUTE')),
  monthly_rent    numeric(14,2) NOT NULL DEFAULT 0 CHECK (monthly_rent >= 0),
  trip_rate       numeric(14,2) NOT NULL DEFAULT 0 CHECK (trip_rate >= 0),
  start_date      date NOT NULL,
  opening_balance numeric(14,2) NOT NULL DEFAULT 0,
  cut_expenses    boolean NOT NULL DEFAULT true,
  active          boolean NOT NULL DEFAULT true,
  updated_by      uuid,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.lwb_hired_routes (
  id         bigserial PRIMARY KEY,
  vehicle_id uuid NOT NULL REFERENCES public.lwb_hired_vehicles(vehicle_id) ON DELETE CASCADE,
  name       text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 60),
  rate       numeric(14,2) NOT NULL CHECK (rate > 0),
  active     boolean NOT NULL DEFAULT true,
  sort       integer NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_hired_routes_name_uidx ON public.lwb_hired_routes (vehicle_id, lower(btrim(name)));

-- Rent added to the ledger: MONTH (one per month), TRIP (trips × rate + extra), EXTRA (+ or −).
CREATE TABLE IF NOT EXISTS public.lwb_hired_charges (
  id           bigserial PRIMARY KEY,
  vehicle_id   uuid NOT NULL REFERENCES public.lwb_hired_vehicles(vehicle_id) ON DELETE RESTRICT,
  charge_date  date NOT NULL,
  kind         text NOT NULL CHECK (kind IN ('MONTH','TRIP','EXTRA')),
  month        date,
  route_name   text CHECK (route_name IS NULL OR length(route_name) <= 60),
  trips        integer CHECK (trips IS NULL OR trips BETWEEN 1 AND 99),
  rate         numeric(14,2),
  extra        numeric(14,2) NOT NULL DEFAULT 0,
  amount       numeric(14,2) NOT NULL CHECK (amount <> 0),
  order_nos    text[],
  remark       text CHECK (remark IS NULL OR length(remark) <= 300),
  created_by   uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  cancelled_by uuid,
  cancelled_at timestamptz,
  cancel_note  text,
  CHECK (kind <> 'MONTH' OR month IS NOT NULL)
);
-- A cancelled month is not added again.
CREATE UNIQUE INDEX IF NOT EXISTS lwb_hired_charges_month_uidx ON public.lwb_hired_charges (vehicle_id, month) WHERE kind = 'MONTH';
CREATE INDEX IF NOT EXISTS lwb_hired_charges_v_idx ON public.lwb_hired_charges (vehicle_id, charge_date);

ALTER TABLE public.lwb_hired_vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_hired_routes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_hired_charges ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_hired_vehicles, public.lwb_hired_routes, public.lwb_hired_charges FROM PUBLIC, anon, authenticated;

-- Who: Accounts / Admin (ledger, trips, pay) and Admin / Manager (rent setup in Vehicle Master).
CREATE OR REPLACE FUNCTION public.lwb_hired_reader()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin','manager'));
$fn$;

-- Money given to the vehicle: PAID (head Vehicle rent) or CUT (other heads, when cut_expenses is on).
CREATE OR REPLACE FUNCTION public.lwb_hired_money(p_vehicle uuid)
RETURNS TABLE(id uuid, entry_date date, entry_time time, created_at timestamptz, kind text, head text, mode text,
              amount numeric, ref_no text, remark text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT e.id, e.entry_date, e.entry_time, e.created_at,
         CASE WHEN lower(btrim(coalesce(c.name,''))) = 'vehicle rent' THEN 'PAID' ELSE 'CUT' END,
         c.name, e.mode, e.amount, e.ref_no, e.remark
  FROM public.lwb_acc_entries e
  JOIN public.lwb_hired_vehicles h ON h.vehicle_id = e.vehicle_id
  LEFT JOIN public.lwb_acc_categories c ON c.id = e.category_id
  WHERE e.vehicle_id = p_vehicle AND e.kind = 'OUT' AND e.cancelled_at IS NULL AND e.entry_date >= h.start_date
    AND (h.cut_expenses OR lower(btrim(coalesce(c.name,''))) = 'vehicle rent');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_hired_money(uuid) FROM PUBLIC, anon, authenticated;

-- Add the missing monthly rent rows up to this month. Called by the Accounts page; safe to call often.
CREATE OR REPLACE FUNCTION public.lwb_hired_post_months()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r record; m date; v_today date := public.lwb_acc_today(); v_n integer := 0; v_days integer; v_amt numeric;
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin only'; END IF;
  FOR r IN SELECT h.* FROM public.lwb_hired_vehicles h JOIN public.lwb_vehicles v ON v.id = h.vehicle_id
           WHERE h.active AND h.rent_type = 'MONTHLY' AND h.monthly_rent > 0 AND h.start_date <= v_today LOOP
    m := date_trunc('month', r.start_date)::date;
    WHILE m <= v_today LOOP
      IF NOT EXISTS (SELECT 1 FROM public.lwb_hired_charges c WHERE c.vehicle_id = r.vehicle_id AND c.kind = 'MONTH' AND c.month = m) THEN
        v_days := extract(day FROM (m + interval '1 month' - interval '1 day'))::integer;
        v_amt := CASE WHEN m < r.start_date
                      THEN round(r.monthly_rent * (v_days - extract(day FROM r.start_date)::integer + 1) / v_days, 0)
                      ELSE r.monthly_rent END;
        IF v_amt > 0 THEN
          INSERT INTO public.lwb_hired_charges (vehicle_id, charge_date, kind, month, rate, amount, remark, created_by)
          VALUES (r.vehicle_id, greatest(m, r.start_date), 'MONTH', m, r.monthly_rent, v_amt,
                  'Rent for ' || to_char(m, 'FMMonth YYYY') ||
                  CASE WHEN m < r.start_date THEN ' (from ' || to_char(r.start_date, 'DD/MM') || ')' ELSE '' END, auth.uid())
          ON CONFLICT DO NOTHING;
          v_n := v_n + 1;
        END IF;
      END IF;
      m := (m + interval '1 month')::date;
    END LOOP;
  END LOOP;
  RETURN v_n;
END;
$fn$;

-- Rent setups (Vehicle Master popup + Accounts list).
CREATE OR REPLACE FUNCTION public.lwb_hired_setups()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin / Manager only'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('vehicle_id', h.vehicle_id, 'rent_type', h.rent_type,
      'monthly_rent', h.monthly_rent, 'trip_rate', h.trip_rate, 'start_date', h.start_date, 'opening_balance', h.opening_balance,
      'cut_expenses', h.cut_expenses, 'active', h.active,
      'routes', coalesce((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'rate', r.rate) ORDER BY r.sort, r.id)
                          FROM public.lwb_hired_routes r WHERE r.vehicle_id = h.vehicle_id AND r.active), '[]'::jsonb)))
    FROM public.lwb_hired_vehicles h), '[]'::jsonb);
END;
$fn$;

-- Save the rent setup of one vehicle (Admin / Manager). p: {rent_type, monthly_rent, trip_rate, start_date,
-- opening_balance, cut_expenses, active, routes:[{name, rate}]}. active false = not hired any more (ledger kept).
CREATE OR REPLACE FUNCTION public.lwb_hired_save(p_vehicle uuid, p jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_type text := upper(btrim(coalesce(p->>'rent_type',''))); v_on boolean := coalesce((p->>'active')::boolean, true);
        v_month numeric; v_trip numeric; v_start date; v_open numeric; x jsonb; v_names text[] := '{}'; v_i integer := 0; v_old date;
BEGIN
  IF NOT public.lwb_fleet_editor() THEN RAISE EXCEPTION 'Only Admin / Manager can set the vehicle rent'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_vehicles v WHERE v.id = p_vehicle) THEN RAISE EXCEPTION 'Vehicle not found in Vehicle Master'; END IF;
  IF NOT v_on THEN
    UPDATE public.lwb_hired_vehicles SET active = false, updated_by = auth.uid(), updated_at = now() WHERE vehicle_id = p_vehicle;
    RETURN;
  END IF;
  IF v_type NOT IN ('MONTHLY','TRIP','ROUTE') THEN RAISE EXCEPTION 'Choose how the rent is counted: Monthly fixed, Per trip or Per route'; END IF;
  BEGIN
    v_month := coalesce(nullif(p->>'monthly_rent','')::numeric, 0);
    v_trip := coalesce(nullif(p->>'trip_rate','')::numeric, 0);
    v_open := coalesce(nullif(p->>'opening_balance','')::numeric, 0);
    v_start := nullif(p->>'start_date','')::date;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the rent amounts and the start date';
  END;
  IF v_start IS NULL THEN RAISE EXCEPTION 'Enter the rent start date'; END IF;
  IF v_start > public.lwb_acc_today() + 31 THEN RAISE EXCEPTION 'Start date is too far ahead'; END IF;
  IF v_month < 0 OR v_trip < 0 OR abs(v_open) > 10000000 OR v_month > 1000000 OR v_trip > 100000 THEN RAISE EXCEPTION 'Check the rent amounts'; END IF;
  IF v_type = 'MONTHLY' AND v_month <= 0 THEN RAISE EXCEPTION 'Enter the monthly rent'; END IF;
  IF v_type = 'TRIP' AND v_trip <= 0 THEN RAISE EXCEPTION 'Enter the rent for one trip'; END IF;
  IF v_type = 'ROUTE' AND jsonb_array_length(coalesce(p->'routes','[]'::jsonb)) = 0 THEN RAISE EXCEPTION 'Add at least one route with its rate'; END IF;

  SELECT h.start_date INTO v_old FROM public.lwb_hired_vehicles h WHERE h.vehicle_id = p_vehicle;
  IF v_old IS NOT NULL AND v_start > v_old AND EXISTS (SELECT 1 FROM public.lwb_hired_charges c
       WHERE c.vehicle_id = p_vehicle AND c.cancelled_at IS NULL AND c.charge_date < v_start) THEN
    RAISE EXCEPTION 'Rent is already added before %. Cancel those lines in the ledger first, or keep the start date.', to_char(v_start,'DD/MM/YYYY');
  END IF;

  INSERT INTO public.lwb_hired_vehicles AS h (vehicle_id, rent_type, monthly_rent, trip_rate, start_date, opening_balance, cut_expenses, active, updated_by)
  VALUES (p_vehicle, v_type, v_month, v_trip, v_start, v_open, coalesce((p->>'cut_expenses')::boolean, true), true, auth.uid())
  ON CONFLICT (vehicle_id) DO UPDATE SET rent_type = EXCLUDED.rent_type, monthly_rent = EXCLUDED.monthly_rent,
    trip_rate = EXCLUDED.trip_rate, start_date = EXCLUDED.start_date, opening_balance = EXCLUDED.opening_balance,
    cut_expenses = EXCLUDED.cut_expenses, active = true, updated_by = auth.uid(), updated_at = now();
  UPDATE public.lwb_vehicles SET ownership = 'TRANSPORTER' WHERE id = p_vehicle AND ownership <> 'TRANSPORTER';

  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p->'routes','[]'::jsonb)) LOOP
    v_i := v_i + 1;
    IF length(btrim(coalesce(x->>'name',''))) < 2 THEN RAISE EXCEPTION 'Write the route name (e.g. Rajkot to Gondal)'; END IF;
    IF coalesce(nullif(x->>'rate','')::numeric, 0) <= 0 THEN RAISE EXCEPTION 'Enter the rate of route %', btrim(x->>'name'); END IF;
    IF lower(btrim(x->>'name')) = ANY (v_names) THEN RAISE EXCEPTION 'Route % is written twice', btrim(x->>'name'); END IF;
    v_names := v_names || lower(btrim(x->>'name'));
    INSERT INTO public.lwb_hired_routes AS r (vehicle_id, name, rate, active, sort)
    VALUES (p_vehicle, btrim(x->>'name'), (x->>'rate')::numeric, true, v_i)
    ON CONFLICT (vehicle_id, lower(btrim(name))) DO UPDATE SET name = EXCLUDED.name, rate = EXCLUDED.rate, active = true, sort = EXCLUDED.sort;
  END LOOP;
  UPDATE public.lwb_hired_routes r SET active = false WHERE r.vehicle_id = p_vehicle AND NOT (lower(btrim(r.name)) = ANY (v_names));
END;
$fn$;

-- Hired vehicles for the Accounts page: rent / paid / cut in the dates, and balance on p_to.
CREATE OR REPLACE FUNCTION public.lwb_hired_list(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin only'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN RAISE EXCEPTION 'Check the dates'; END IF;
  RETURN coalesce((SELECT jsonb_agg(x ORDER BY x.active DESC, x.no) FROM (
    SELECT h.vehicle_id AS id, v.vehicle_no AS no, v.vehicle_type AS type, v.transporter_name AS owner, v.owner_mobile AS mobile,
      h.rent_type, h.monthly_rent, h.trip_rate, h.start_date, h.cut_expenses, (h.active AND v.is_active) AS active,
      coalesce((SELECT jsonb_agg(jsonb_build_object('name', r.name, 'rate', r.rate) ORDER BY r.sort, r.id)
                FROM public.lwb_hired_routes r WHERE r.vehicle_id = h.vehicle_id AND r.active), '[]'::jsonb) AS routes,
      coalesce((SELECT sum(c.amount) FROM public.lwb_hired_charges c WHERE c.vehicle_id = h.vehicle_id AND c.cancelled_at IS NULL
                AND c.charge_date BETWEEN p_from AND p_to), 0) AS rent,
      coalesce((SELECT sum(c.trips) FROM public.lwb_hired_charges c WHERE c.vehicle_id = h.vehicle_id AND c.cancelled_at IS NULL
                AND c.kind = 'TRIP' AND c.charge_date BETWEEN p_from AND p_to), 0) AS trips,
      coalesce((SELECT sum(m.amount) FROM public.lwb_hired_money(h.vehicle_id) m WHERE m.kind = 'PAID' AND m.entry_date BETWEEN p_from AND p_to), 0) AS paid,
      coalesce((SELECT sum(m.amount) FROM public.lwb_hired_money(h.vehicle_id) m WHERE m.kind = 'CUT' AND m.entry_date BETWEEN p_from AND p_to), 0) AS cut,
      h.opening_balance
        + coalesce((SELECT sum(c.amount) FROM public.lwb_hired_charges c WHERE c.vehicle_id = h.vehicle_id AND c.cancelled_at IS NULL AND c.charge_date <= p_to), 0)
        - coalesce((SELECT sum(m.amount) FROM public.lwb_hired_money(h.vehicle_id) m WHERE m.entry_date <= p_to), 0) AS balance
    FROM public.lwb_hired_vehicles h JOIN public.lwb_vehicles v ON v.id = h.vehicle_id
    WHERE (h.active AND v.is_active) OR EXISTS (SELECT 1 FROM public.lwb_hired_charges c WHERE c.vehicle_id = h.vehicle_id AND c.cancelled_at IS NULL)
  ) x), '[]'::jsonb);
END;
$fn$;

-- One vehicle's rent ledger for the dates: balance before p_from, then every line (rent + / paid −).
CREATE OR REPLACE FUNCTION public.lwb_hired_ledger(p_vehicle uuid, p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_hired_vehicles;
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin only'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN RAISE EXCEPTION 'Check the dates'; END IF;
  SELECT * INTO h FROM public.lwb_hired_vehicles x WHERE x.vehicle_id = p_vehicle;
  IF h.vehicle_id IS NULL THEN RAISE EXCEPTION 'This vehicle has no rent setup. Set it in Vehicle Master (Ownership = Hired).'; END IF;
  RETURN jsonb_build_object(
    'vehicle', (SELECT jsonb_build_object('id', v.id, 'no', v.vehicle_no, 'type', v.vehicle_type, 'owner', v.transporter_name,
                 'mobile', v.owner_mobile, 'rent_type', h.rent_type, 'monthly_rent', h.monthly_rent, 'trip_rate', h.trip_rate,
                 'start_date', h.start_date, 'cut_expenses', h.cut_expenses) FROM public.lwb_vehicles v WHERE v.id = p_vehicle),
    'opening', h.opening_balance
       + coalesce((SELECT sum(c.amount) FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.cancelled_at IS NULL AND c.charge_date < p_from), 0)
       - coalesce((SELECT sum(m.amount) FROM public.lwb_hired_money(p_vehicle) m WHERE m.entry_date < p_from), 0),
    'lines', coalesce((SELECT jsonb_agg(l ORDER BY l.date, l.ord, l.at) FROM (
        SELECT c.charge_date AS date, 0 AS ord, c.created_at AS at, 'CHARGE' AS src, c.id::text AS id, c.kind, c.route_name AS route,
               c.trips, c.rate, c.extra, c.amount, c.remark, c.order_nos, NULL::text AS head, NULL::text AS mode, NULL::text AS ref
        FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.cancelled_at IS NULL AND c.charge_date BETWEEN p_from AND p_to
        UNION ALL
        SELECT m.entry_date, 1, m.created_at, 'MONEY', m.id::text, m.kind, NULL, NULL, NULL, NULL, -m.amount, m.remark, NULL, m.head, m.mode, m.ref_no
        FROM public.lwb_hired_money(p_vehicle) m WHERE m.entry_date BETWEEN p_from AND p_to) l), '[]'::jsonb)
  );
END;
$fn$;

-- Transport Assignment days of a hired vehicle (for "+ Trip"): date, orders, trips already added that day.
CREATE OR REPLACE FUNCTION public.lwb_hired_dispatch_days(p_vehicle uuid, p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_no text;
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin only'; END IF;
  SELECT v.vehicle_no INTO v_no FROM public.lwb_vehicles v WHERE v.id = p_vehicle;
  IF v_no IS NULL OR p_from IS NULL OR p_to IS NULL OR p_to - p_from > 62 THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('date', d.day, 'orders', d.orders,
      'added', coalesce((SELECT sum(c.trips) FROM public.lwb_hired_charges c WHERE c.vehicle_id = p_vehicle AND c.kind = 'TRIP'
                         AND c.cancelled_at IS NULL AND c.charge_date = d.day), 0)) ORDER BY d.day DESC)
    FROM (SELECT (a.assigned_at AT TIME ZONE 'Asia/Kolkata')::date AS day, array_agg(DISTINCT o.order_no) AS orders
          FROM public.dispatch_assignments a JOIN public.orders o ON o.id = a.order_id
          WHERE upper(regexp_replace(coalesce(a.vehicle_no,''), '[^A-Za-z0-9]', '', 'g')) = v_no
            AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected')
            AND (a.assigned_at AT TIME ZONE 'Asia/Kolkata')::date BETWEEN p_from AND p_to
          GROUP BY 1) d), '[]'::jsonb);
END;
$fn$;

-- Add trips or an extra line. p: {vehicle_id, date, kind TRIP|EXTRA, route, trips, extra, amount (EXTRA), remark, orders[]}.
CREATE OR REPLACE FUNCTION public.lwb_hired_add(p jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_hired_vehicles; v_kind text := upper(coalesce(p->>'kind','TRIP')); v_date date; v_trips integer;
        v_rate numeric; v_extra numeric; v_amt numeric; v_route text; v_id bigint; v_orders text[];
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin only'; END IF;
  BEGIN
    SELECT * INTO h FROM public.lwb_hired_vehicles x WHERE x.vehicle_id = (p->>'vehicle_id')::uuid;
    v_date := (p->>'date')::date;
    v_trips := coalesce(nullif(p->>'trips','')::integer, 1);
    v_extra := coalesce(nullif(p->>'extra','')::numeric, 0);
    v_amt := nullif(p->>'amount','')::numeric;
    v_orders := CASE WHEN jsonb_typeof(p->'orders') = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(p->'orders')) END;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the date, trips and amount';
  END;
  IF h.vehicle_id IS NULL OR NOT h.active THEN RAISE EXCEPTION 'This vehicle is not hired on rent (Vehicle Master)'; END IF;
  IF v_date IS NULL OR v_date > public.lwb_acc_today() THEN RAISE EXCEPTION 'Choose a date up to today'; END IF;
  IF v_date < h.start_date THEN RAISE EXCEPTION 'Rent of this vehicle starts on %', to_char(h.start_date,'DD/MM/YYYY'); END IF;
  IF v_kind = 'EXTRA' THEN
    IF v_amt IS NULL OR v_amt = 0 OR abs(v_amt) > 500000 THEN RAISE EXCEPTION 'Enter the amount (+ extra, − cut)'; END IF;
    IF length(btrim(coalesce(p->>'remark',''))) < 2 THEN RAISE EXCEPTION 'Write what the amount is for'; END IF;
    INSERT INTO public.lwb_hired_charges (vehicle_id, charge_date, kind, amount, remark, created_by)
    VALUES (h.vehicle_id, v_date, 'EXTRA', round(v_amt, 2), btrim(p->>'remark'), auth.uid()) RETURNING id INTO v_id;
    RETURN v_id;
  END IF;
  IF v_kind <> 'TRIP' THEN RAISE EXCEPTION 'Unknown line'; END IF;
  IF h.rent_type = 'MONTHLY' THEN RAISE EXCEPTION 'This vehicle is on monthly rent: add an Extra line instead of trips'; END IF;
  IF v_trips < 1 OR v_trips > 99 THEN RAISE EXCEPTION 'Trips: 1 to 99'; END IF;
  IF v_extra < 0 OR v_extra > 100000 THEN RAISE EXCEPTION 'Check the extra amount'; END IF;
  IF h.rent_type = 'ROUTE' THEN
    SELECT r.name, r.rate INTO v_route, v_rate FROM public.lwb_hired_routes r
    WHERE r.vehicle_id = h.vehicle_id AND r.active AND lower(btrim(r.name)) = lower(btrim(coalesce(p->>'route','')));
    IF v_route IS NULL THEN RAISE EXCEPTION 'Choose the route'; END IF;
  ELSE v_rate := h.trip_rate;
  END IF;
  INSERT INTO public.lwb_hired_charges (vehicle_id, charge_date, kind, route_name, trips, rate, extra, amount, order_nos, remark, created_by)
  VALUES (h.vehicle_id, v_date, 'TRIP', v_route, v_trips, v_rate, round(v_extra, 2), round(v_trips * v_rate + v_extra, 2),
          v_orders, nullif(btrim(coalesce(p->>'remark','')), ''), auth.uid()) RETURNING id INTO v_id;
  RETURN v_id;
END;
$fn$;

-- Cancel a rent line (kept with the reason). A cancelled month is not added again.
CREATE OR REPLACE FUNCTION public.lwb_hired_cancel(p_id bigint, p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_hired_reader() THEN RAISE EXCEPTION 'Hired vehicle rent is for Accounts / Admin only'; END IF;
  IF length(btrim(coalesce(p_note,''))) < 3 THEN RAISE EXCEPTION 'Write why it is cancelled'; END IF;
  UPDATE public.lwb_hired_charges SET cancelled_at = now(), cancelled_by = auth.uid(), cancel_note = left(btrim(p_note), 200)
  WHERE id = p_id AND cancelled_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Line not found or already cancelled'; END IF;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_hired_reader(), public.lwb_hired_post_months(), public.lwb_hired_setups(),
  public.lwb_hired_save(uuid,jsonb), public.lwb_hired_list(date,date), public.lwb_hired_ledger(uuid,date,date),
  public.lwb_hired_dispatch_days(uuid,date,date), public.lwb_hired_add(jsonb), public.lwb_hired_cancel(bigint,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_hired_reader(), public.lwb_hired_post_months(), public.lwb_hired_setups(),
  public.lwb_hired_save(uuid,jsonb), public.lwb_hired_list(date,date), public.lwb_hired_ledger(uuid,date,date),
  public.lwb_hired_dispatch_days(uuid,date,date), public.lwb_hired_add(jsonb), public.lwb_hired_cancel(bigint,text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'hired rent tables' AS item, (to_regclass('public.lwb_hired_charges') IS NOT NULL)::text AS ok
UNION ALL SELECT 'hired rent ledger', (to_regprocedure('public.lwb_hired_ledger(uuid,date,date)') IS NOT NULL)::text
UNION ALL SELECT 'Vehicle rent head', EXISTS (SELECT 1 FROM public.lwb_acc_categories WHERE kind = 'OUT' AND lower(name) = 'vehicle rent')::text;
