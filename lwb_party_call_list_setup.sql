-- LUXURY WRIST BRAND ERP — PARTY CALL LIST (parties with no order in time)
--
-- RUN ONCE in Supabase SQL Editor (after lwb_sales_team_setup.sql). Safe to run again.
--
-- Admin / Sales Head set per party: "order should come every N days" (1, 2, 3 ... 90).
-- Blank = the party is not on the call list.
--
-- Every day the call list (party-calls.html + Dashboard) shows each party whose last
-- order is N or more days old (or that never ordered):
--   * Salesman (SALES login): only the parties assigned to him (Sales Team Setup).
--   * Admin / Sales Head (MANAGER): every party; parties without a salesman are theirs.
-- The caller taps Call (phone dialer opens), talks to the party and saves the result:
--   ORDER_TAKEN   order taken (make the PO as usual)
--   WILL_ORDER    party will order on a date -> hidden from the list until that date
--   NO_ORDER      no order -> reason is required
--   NOT_REACHABLE phone not picked / switched off
-- A party called today moves to "Called today"; if it still has not ordered it comes
-- back on the list the next day. A new PO removes it automatically.
-- Admin / Sales Head read every call result and reason (Call Report).
--
-- Only call records and the per-party days are saved.
-- Orders, stock, bills, payments, ledger and Tally are NOT changed.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Per-party order frequency + call log
-- ---------------------------------------------------------------------------
ALTER TABLE public.lwb_customer_master
  ADD COLUMN IF NOT EXISTS order_every_days integer CHECK (order_every_days IS NULL OR order_every_days BETWEEN 1 AND 90);

CREATE TABLE IF NOT EXISTS public.lwb_party_calls (
  id bigserial PRIMARY KEY,
  customer_id uuid NOT NULL REFERENCES public.lwb_customer_master(id) ON DELETE CASCADE,
  customer_name text NOT NULL,
  call_date date NOT NULL DEFAULT (now() AT TIME ZONE 'Asia/Kolkata')::date,
  result text NOT NULL CHECK (result IN ('ORDER_TAKEN','WILL_ORDER','NO_ORDER','NOT_REACHABLE')),
  reason text CHECK (reason IS NULL OR length(reason) <= 60),
  note text CHECK (note IS NULL OR length(note) <= 500),
  next_date date,
  every_days integer,
  last_order_date date,
  salesman_id uuid,
  called_by uuid NOT NULL DEFAULT auth.uid(),
  called_by_name text,
  called_by_role text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_party_calls_party_idx ON public.lwb_party_calls(customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS lwb_party_calls_day_idx ON public.lwb_party_calls(call_date DESC);
CREATE INDEX IF NOT EXISTS lwb_party_calls_by_idx ON public.lwb_party_calls(called_by, call_date DESC);

-- Read: Admin / Sales Head all; a salesman his own calls and calls on his parties.
-- Writes only through lwb_party_call_save.
ALTER TABLE public.lwb_party_calls ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_party_calls_read ON public.lwb_party_calls;
CREATE POLICY lwb_party_calls_read ON public.lwb_party_calls FOR SELECT TO authenticated
  USING (public.lwb_sales_head() OR called_by = auth.uid()
    OR EXISTS (SELECT 1 FROM public.lwb_party_salesman a WHERE a.customer_id = lwb_party_calls.customer_id AND a.salesman_id = auth.uid()));
REVOKE ALL ON TABLE public.lwb_party_calls FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_party_calls TO authenticated;
REVOKE ALL ON SEQUENCE public.lwb_party_calls_id_seq FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Admin / Sales Head: set "order every N days" for parties (NULL = remove from list)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_set_party_order_days(p_customer_ids uuid[], p_days integer)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_n integer;
BEGIN
  IF NOT public.lwb_sales_head() THEN RAISE EXCEPTION 'Admin or Sales Head required'; END IF;
  IF p_days IS NOT NULL AND (p_days < 1 OR p_days > 90) THEN RAISE EXCEPTION 'Days must be 1 to 90'; END IF;
  UPDATE public.lwb_customer_master SET order_every_days = p_days
  WHERE id = ANY(coalesce(p_customer_ids, '{}'));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. Call list for the logged-in user.
--    p_all = true (Admin / Sales Head only): every party that has days set, due or not
--    (for the setup screen). Otherwise only due parties + parties called today.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_call_list(p_all boolean DEFAULT false)
RETURNS TABLE (customer_id uuid, customer_name text, city text, mobile text,
               salesman_id uuid, salesman_name text, every_days integer,
               last_order_date date, last_order_no text, days_since integer,
               due boolean, called_today boolean, wait_until date, last_call jsonb, calls_7d integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
#variable_conflict use_column
DECLARE
  v_head boolean := public.lwb_sales_head();
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
BEGIN
  IF NOT (v_head OR public.lwb_is_sales_user()) THEN RAISE EXCEPTION 'Sales team only'; END IF;
  RETURN QUERY
    WITH parties AS (
      SELECT m.id, m.customer_name, m.city, m.mobile, m.order_every_days, a.salesman_id, p.full_name AS sm_name
      FROM public.lwb_customer_master m
      LEFT JOIN public.lwb_party_salesman a ON a.customer_id = m.id
      LEFT JOIN public.user_profiles p ON p.id = a.salesman_id
      WHERE m.is_active IS TRUE AND m.order_every_days IS NOT NULL
        AND (v_head OR a.salesman_id = auth.uid())
    ), x AS (
      SELECT pt.*, lo.d AS last_d, lo.order_no AS last_no, lc.c AS last_call, lc.call_date AS lc_day,
        lc.next_date AS lc_next, lc.result AS lc_result, coalesce(n7.n, 0) AS n7
      FROM parties pt
      LEFT JOIN LATERAL (
        SELECT timezone('Asia/Kolkata', o.order_date::timestamptz)::date AS d, o.order_no
        FROM public.orders o
        WHERE upper(btrim(o.customer_name)) = upper(btrim(pt.customer_name))
          AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected')
        ORDER BY o.order_date DESC NULLS LAST LIMIT 1
      ) lo ON true
      LEFT JOIN LATERAL (
        SELECT c.call_date, c.next_date, c.result,
          jsonb_build_object('date', c.call_date, 'at', c.created_at, 'result', c.result, 'reason', c.reason,
            'note', c.note, 'next_date', c.next_date, 'by', c.called_by_name) AS c
        FROM public.lwb_party_calls c WHERE c.customer_id = pt.id ORDER BY c.created_at DESC LIMIT 1
      ) lc ON true
      LEFT JOIN LATERAL (
        SELECT count(*)::integer AS n FROM public.lwb_party_calls c
        WHERE c.customer_id = pt.id AND c.call_date > v_today - 7
      ) n7 ON true
    ), y AS (
      SELECT x.*,
        (x.last_d IS NULL OR v_today - x.last_d >= x.order_every_days) AS late,
        -- A call is only counted after the last order (an order resets the follow-up).
        coalesce(x.lc_day = v_today AND (x.last_d IS NULL OR x.lc_day >= x.last_d), false) AS today_call,
        CASE WHEN x.lc_result = 'WILL_ORDER' AND x.lc_next > v_today AND (x.last_d IS NULL OR x.lc_day >= x.last_d)
             THEN x.lc_next END AS wait_d
      FROM x
    )
    SELECT y.id, y.customer_name::text, y.city::text, y.mobile::text, y.salesman_id, y.sm_name::text, y.order_every_days,
      y.last_d, y.last_no::text, CASE WHEN y.last_d IS NOT NULL THEN v_today - y.last_d END,
      (y.late AND NOT y.today_call AND y.wait_d IS NULL), y.today_call, y.wait_d, y.last_call, y.n7
    FROM y
    WHERE (p_all AND v_head) OR y.late
    ORDER BY (y.late AND NOT y.today_call AND y.wait_d IS NULL) DESC,
      CASE WHEN y.last_d IS NULL THEN 100000 ELSE (v_today - y.last_d) - y.order_every_days END DESC, y.customer_name;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 4. Save a call result. p: {customer_id, result, reason, note, next_date}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_party_call_save(p jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_cid uuid := nullif(p->>'customer_id','')::uuid;
  v_result text := upper(btrim(coalesce(p->>'result','')));
  v_reason text := left(nullif(btrim(coalesce(p->>'reason','')),''), 60);
  v_note text := left(nullif(btrim(coalesce(p->>'note','')),''), 500);
  v_next date := nullif(p->>'next_date','')::date;
  m record; v_sm uuid; v_last date; v_name text; v_role text; v_id bigint;
BEGIN
  SELECT c.id, c.customer_name, c.order_every_days INTO m FROM public.lwb_customer_master c WHERE c.id = v_cid;
  IF m.id IS NULL THEN RAISE EXCEPTION 'Party not found'; END IF;
  SELECT a.salesman_id INTO v_sm FROM public.lwb_party_salesman a WHERE a.customer_id = v_cid;
  IF NOT (public.lwb_sales_head() OR (public.lwb_is_sales_user() AND v_sm = auth.uid())) THEN
    RAISE EXCEPTION 'This party is not on your call list';
  END IF;
  IF v_result NOT IN ('ORDER_TAKEN','WILL_ORDER','NO_ORDER','NOT_REACHABLE') THEN RAISE EXCEPTION 'Please choose what the party said'; END IF;
  IF v_result = 'NO_ORDER' AND v_reason IS NULL THEN RAISE EXCEPTION 'Please choose why the party did not order'; END IF;
  IF v_result = 'WILL_ORDER' THEN
    IF v_next IS NULL OR v_next <= v_today THEN RAISE EXCEPTION 'Please choose the date the party will order'; END IF;
    IF v_next > v_today + 30 THEN RAISE EXCEPTION 'Order date must be within 30 days'; END IF;
  ELSE
    v_next := NULL;
  END IF;
  SELECT max(timezone('Asia/Kolkata', o.order_date::timestamptz)::date) INTO v_last FROM public.orders o
  WHERE upper(btrim(o.customer_name)) = upper(btrim(m.customer_name))
    AND lower(btrim(coalesce(o.status,''))) NOT IN ('cancelled','canceled','rejected');
  SELECT coalesce(nullif(btrim(u.full_name),''), 'Staff'), lower(btrim(u.role)) INTO v_name, v_role
  FROM public.user_profiles u WHERE u.id = auth.uid();

  INSERT INTO public.lwb_party_calls(customer_id, customer_name, call_date, result, reason, note, next_date,
    every_days, last_order_date, salesman_id, called_by, called_by_name, called_by_role)
  VALUES (m.id, m.customer_name, v_today, v_result, CASE WHEN v_result IN ('NO_ORDER','NOT_REACHABLE') THEN v_reason END,
    v_note, v_next, m.order_every_days, v_last, v_sm, auth.uid(), v_name, v_role)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$fn$;

-- Dashboard count: parties to call now (same rule as the list).
CREATE OR REPLACE FUNCTION public.lwb_party_call_due_count()
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT count(*)::integer FROM public.lwb_party_call_list(false) l WHERE l.due;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_set_party_order_days(uuid[], integer), public.lwb_party_call_list(boolean),
  public.lwb_party_call_save(jsonb), public.lwb_party_call_due_count() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_party_order_days(uuid[], integer), public.lwb_party_call_list(boolean),
  public.lwb_party_call_save(jsonb), public.lwb_party_call_due_count() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: 4 rows, all true.
SELECT 'party days column' AS item, EXISTS (SELECT 1 FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'lwb_customer_master' AND column_name = 'order_every_days') AS ok
UNION ALL SELECT 'call log table', to_regclass('public.lwb_party_calls') IS NOT NULL
UNION ALL SELECT 'call list function', to_regprocedure('public.lwb_party_call_list(boolean)') IS NOT NULL
UNION ALL SELECT 'save call function', to_regprocedure('public.lwb_party_call_save(jsonb)') IS NOT NULL;
