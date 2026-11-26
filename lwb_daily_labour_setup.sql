-- LUXURY WRIST BRAND ERP — DAILY LABOUR (DIHADI) REGISTER (Mohit, 26 Nov 2026)
--
-- Mohit: the Godown Manager brings one-day labour from the market. He must enter them: name + mobile (both required)
-- and today's wage (dihadi) of each one. In the morning Admin or a Sales Head can assign the day's labour to a Godown
-- Manager (how many, rate); if nobody assigns, the Godown Manager still enters them. At night today's cashier gives the
-- Godown Manager the cash: at most the register total. More than that = the amount must change, and that change needs
-- the approval of a Sales Head or Admin (Approvals page). Every day a popup: how many outside labour came, total charge.
--
--   lwb_labour_plan                    morning plan per Godown Manager per day (count, rate, note) by Admin / Sales Head
--   lwb_labour                         one row per labourer per day (name, mobile, wage, work)
--   lwb_labour_pay                     cash given to the Godown Manager (a normal Cash Out "Labour charge" entry)
--   lwb_labour_extra                   ask to pay more than the register: WAITING -> APPROVED / REJECTED
--
--   lwb_labour_day(day)                the day: per Godown Manager plan, labour, total, paid, approved extra, can pay
--   lwb_labour_plan_set(day, gm, count, rate, note)   Admin / Sales Head (bell to that Godown Manager)
--   lwb_labour_add(p) / lwb_labour_edit(id, p) / lwb_labour_remove(id, reason)
--                                      Godown Manager: own, today, until cash is given. Admin / Sales Head: any, 7 days.
--   lwb_labour_pay(day, gm, amount, note)   today's cashier (or Admin): never more than register + approved extra
--   lwb_labour_extra_ask(day, gm, amount, reason) / lwb_labour_extra_decide(id, ok, amount, note) / lwb_labour_extra_list()
--   lwb_labour_find(mobile)            repeat labourer: last name, wage, days worked (autofill)
--   lwb_labour_people(from, to)        per labourer: days, total, last day, Godown Managers
--   lwb_labour_days(from, to)          per day: labour count, total, paid
-- Also: lwb_gm_bell_ok lets LABOUR_* bells reach the Godown Manager (patched in place).
-- Nothing is dropped. Safe to run again.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_labour_plan (
  id bigserial PRIMARY KEY,
  day date NOT NULL,
  gm_id uuid NOT NULL,
  count int NOT NULL CHECK (count BETWEEN 0 AND 500),
  rate numeric(10,2) CHECK (rate IS NULL OR rate >= 0),
  note text CHECK (note IS NULL OR length(note) <= 300),
  set_by uuid NOT NULL,
  set_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (day, gm_id)
);

CREATE TABLE IF NOT EXISTS public.lwb_labour (
  id bigserial PRIMARY KEY,
  day date NOT NULL,
  gm_id uuid NOT NULL,
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 2 AND 80),
  mobile text NOT NULL CHECK (mobile ~ '^[6-9][0-9]{9}$'),
  wage numeric(10,2) NOT NULL CHECK (wage > 0 AND wage <= 10000),
  work text CHECK (work IS NULL OR length(work) <= 120),
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  updated_at timestamptz,
  removed_by uuid,
  removed_at timestamptz,
  remove_reason text
);
CREATE INDEX IF NOT EXISTS lwb_labour_day_idx ON public.lwb_labour(day, gm_id) WHERE removed_at IS NULL;
CREATE INDEX IF NOT EXISTS lwb_labour_mobile_idx ON public.lwb_labour(mobile) WHERE removed_at IS NULL;

CREATE TABLE IF NOT EXISTS public.lwb_labour_pay (
  id bigserial PRIMARY KEY,
  day date NOT NULL,
  gm_id uuid NOT NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  entry_id uuid NOT NULL,                    -- lwb_acc_entries (Cash Out "Labour charge"); cancelled there = not paid
  note text,
  paid_by uuid NOT NULL,
  paid_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_labour_pay_day_idx ON public.lwb_labour_pay(day, gm_id);

CREATE TABLE IF NOT EXISTS public.lwb_labour_extra (
  id bigserial PRIMARY KEY,
  day date NOT NULL,
  gm_id uuid NOT NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),     -- asked over the register; approved amount after decide
  asked_amount numeric(12,2) NOT NULL,
  reason text NOT NULL,
  status text NOT NULL DEFAULT 'WAITING' CHECK (status IN ('WAITING','APPROVED','REJECTED')),
  asked_by uuid NOT NULL,
  asked_at timestamptz NOT NULL DEFAULT now(),
  decided_by uuid,
  decided_at timestamptz,
  decide_note text
);
CREATE INDEX IF NOT EXISTS lwb_labour_extra_wait_idx ON public.lwb_labour_extra(status) WHERE status = 'WAITING';

ALTER TABLE public.lwb_labour_plan ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_labour ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_labour_pay ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_labour_extra ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_labour_plan, public.lwb_labour, public.lwb_labour_pay, public.lwb_labour_extra
  FROM PUBLIC, anon, authenticated;

-- The Cash Out head the payment goes to (it is one of the starting heads; added if missing).
INSERT INTO public.lwb_acc_categories (kind, name, sort)
SELECT 'OUT', 'Labour charge', 60
WHERE NOT EXISTS (SELECT 1 FROM public.lwb_acc_categories c WHERE c.kind = 'OUT' AND lower(btrim(c.name)) = 'labour charge');

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_lab_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true $fn$;

-- Admin / Sales Head: plan, approve extra, change any row
CREATE OR REPLACE FUNCTION public.lwb_lab_head()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT coalesce(public.lwb_lab_role() IN ('admin','manager'), false) $fn$;

-- sees every Godown Manager: Admin, Sales Head, Accounts, Cashier (also today's Sales Head cashier)
CREATE OR REPLACE FUNCTION public.lwb_lab_all()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT coalesce(public.lwb_lab_role() IN ('admin','manager','accounts','cashier'), false) OR public.lwb_acc_cashier() $fn$;

CREATE OR REPLACE FUNCTION public.lwb_lab_can_pay()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT public.lwb_acc_cashier() OR public.lwb_acc_admin() $fn$;

CREATE OR REPLACE FUNCTION public.lwb_lab_name(p_user uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT coalesce((SELECT nullif(btrim(p.full_name),'') FROM public.user_profiles p WHERE p.id = p_user), 'Someone') $fn$;

CREATE OR REPLACE FUNCTION public.lwb_lab_is_gm(p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user AND p.active = true AND lower(btrim(p.role)) = 'warehouse') $fn$;

CREATE OR REPLACE FUNCTION public.lwb_lab_mobile(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT right(regexp_replace(coalesce(p,''), '\D', '', 'g'), 10) $fn$;

CREATE OR REPLACE FUNCTION public.lwb_lab_money(n numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT 'Rs ' || to_char(coalesce(n,0), 'FM99,99,99,990') $fn$;

-- cash given (entries not cancelled), register total, approved extra
CREATE OR REPLACE FUNCTION public.lwb_lab_paid(p_day date, p_gm uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(sum(p.amount),0) FROM public.lwb_labour_pay p JOIN public.lwb_acc_entries e ON e.id = p.entry_id
  WHERE p.day = p_day AND p.gm_id = p_gm AND e.cancelled_at IS NULL;
$fn$;
CREATE OR REPLACE FUNCTION public.lwb_lab_total(p_day date, p_gm uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT coalesce(sum(l.wage),0) FROM public.lwb_labour l WHERE l.day = p_day AND l.gm_id = p_gm AND l.removed_at IS NULL $fn$;
CREATE OR REPLACE FUNCTION public.lwb_lab_extra_ok(p_day date, p_gm uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT coalesce(sum(x.amount),0) FROM public.lwb_labour_extra x WHERE x.day = p_day AND x.gm_id = p_gm AND x.status = 'APPROVED' $fn$;

CREATE OR REPLACE FUNCTION public.lwb_lab_bell(p_users uuid[], p_type text, p_title text, p_message text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $fn$
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
  SELECT DISTINCT u, p_title, p_message, p_type FROM unnest(p_users) u
  WHERE u IS NOT NULL AND u IS DISTINCT FROM auth.uid();
$fn$;
CREATE OR REPLACE FUNCTION public.lwb_lab_heads()
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT coalesce(array_agg(p.id), '{}') FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','manager') $fn$;

-- may this login enter / change labour of this Godown Manager on this day?
CREATE OR REPLACE FUNCTION public.lwb_lab_check_edit(p_day date, p_gm uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF p_day IS NULL OR p_day > public.lwb_acc_today() THEN RAISE EXCEPTION 'Enter a valid day (not a future day)'; END IF;
  IF public.lwb_lab_head() THEN
    IF p_day < public.lwb_acc_today() - 7 THEN RAISE EXCEPTION 'Only the last 7 days can be changed'; END IF;
    IF NOT public.lwb_lab_is_gm(p_gm) THEN RAISE EXCEPTION 'Choose the Godown Manager'; END IF;
    RETURN;
  END IF;
  IF public.lwb_lab_role() IS DISTINCT FROM 'warehouse' THEN
    RAISE EXCEPTION 'Only the Godown Manager, a Sales Head or Admin can enter daily labour'; END IF;
  IF p_gm IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'You can enter only your own labour'; END IF;
  IF p_day <> public.lwb_acc_today() THEN RAISE EXCEPTION 'Only today''s labour can be entered. Ask a Sales Head for an old day.'; END IF;
  IF public.lwb_lab_paid(p_day, p_gm) > 0 THEN
    RAISE EXCEPTION 'Cash for today''s labour is already given. Ask a Sales Head or Admin to change it.'; END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_lab_row(l public.lwb_labour)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT jsonb_build_object('id', l.id, 'day', l.day, 'gm_id', l.gm_id, 'name', l.name, 'mobile', l.mobile, 'wage', l.wage,
    'work', l.work, 'by', public.lwb_lab_name(l.created_by), 'at', l.created_at,
    'edited', l.updated_at IS NOT NULL,
    -- other days this mobile worked before (repeat labourer)
    'days_before', (SELECT count(DISTINCT x.day) FROM public.lwb_labour x WHERE x.mobile = l.mobile AND x.removed_at IS NULL AND x.day < l.day));
$fn$;

-- ---------------------------------------------------------------------------
-- read: one day
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_labour_day(p_day date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_day date := coalesce(p_day, public.lwb_acc_today()); v_role text := public.lwb_lab_role(); v_all boolean := public.lwb_lab_all();
        v_gms jsonb;
BEGIN
  IF v_role IS NULL OR NOT (v_all OR v_role = 'warehouse') THEN
    RAISE EXCEPTION 'Daily labour: Admin / Sales Head / Godown Manager / Accounts / Cashier only'; END IF;
  WITH g AS (
    SELECT p.id FROM public.user_profiles p
    WHERE v_all AND p.active = true AND lower(btrim(p.role)) = 'warehouse'
    UNION SELECT l.gm_id FROM public.lwb_labour l WHERE v_all AND l.day = v_day AND l.removed_at IS NULL
    UNION SELECT x.gm_id FROM public.lwb_labour_plan x WHERE v_all AND x.day = v_day
    UNION SELECT y.gm_id FROM public.lwb_labour_pay y WHERE v_all AND y.day = v_day
    UNION SELECT auth.uid() WHERE v_role = 'warehouse'
  ), r AS (
    SELECT g.id AS gm,
      public.lwb_lab_name(g.id) AS name,
      (SELECT p.mobile FROM public.user_profiles p WHERE p.id = g.id) AS mobile,
      (SELECT to_jsonb(x) - 'gm_id' - 'set_by' || jsonb_build_object('by', public.lwb_lab_name(x.set_by),
              'budget', CASE WHEN x.rate IS NOT NULL THEN x.rate * x.count END)
         FROM public.lwb_labour_plan x WHERE x.day = v_day AND x.gm_id = g.id) AS plan,
      coalesce((SELECT jsonb_agg(public.lwb_lab_row(l) ORDER BY l.id) FROM public.lwb_labour l
                WHERE l.day = v_day AND l.gm_id = g.id AND l.removed_at IS NULL), '[]'::jsonb) AS rows,
      (SELECT count(*) FROM public.lwb_labour l WHERE l.day = v_day AND l.gm_id = g.id AND l.removed_at IS NULL) AS cnt,
      public.lwb_lab_total(v_day, g.id) AS total,
      public.lwb_lab_paid(v_day, g.id) AS paid,
      public.lwb_lab_extra_ok(v_day, g.id) AS extra_ok,
      coalesce((SELECT sum(x.amount) FROM public.lwb_labour_extra x WHERE x.day = v_day AND x.gm_id = g.id AND x.status = 'WAITING'),0) AS extra_wait,
      coalesce((SELECT jsonb_agg(jsonb_build_object('id', y.id, 'amount', y.amount, 'note', y.note, 'by', public.lwb_lab_name(y.paid_by),
                  'at', y.paid_at, 'entry_id', y.entry_id, 'cancelled', e.cancelled_at IS NOT NULL) ORDER BY y.id)
                FROM public.lwb_labour_pay y JOIN public.lwb_acc_entries e ON e.id = y.entry_id
                WHERE y.day = v_day AND y.gm_id = g.id), '[]'::jsonb) AS pays,
      coalesce((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'amount', x.amount, 'asked', x.asked_amount, 'reason', x.reason,
                  'status', x.status, 'by', public.lwb_lab_name(x.asked_by), 'at', x.asked_at,
                  'decided_by', CASE WHEN x.decided_by IS NOT NULL THEN public.lwb_lab_name(x.decided_by) END, 'note', x.decide_note) ORDER BY x.id)
                FROM public.lwb_labour_extra x WHERE x.day = v_day AND x.gm_id = g.id), '[]'::jsonb) AS extras
    FROM g WHERE g.id IS NOT NULL
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('gm_id', r.gm, 'name', r.name, 'mobile', r.mobile, 'plan', r.plan, 'rows', r.rows,
      'count', r.cnt, 'total', r.total, 'paid', r.paid, 'extra_ok', r.extra_ok, 'extra_wait', r.extra_wait,
      'limit', r.total + r.extra_ok, 'due', greatest(r.total + r.extra_ok - r.paid, 0), 'pays', r.pays, 'extras', r.extras,
      'locked', r.paid > 0,
      'over_plan', r.plan IS NOT NULL AND (r.cnt > (r.plan->>'count')::int
                   OR (r.plan->>'budget' IS NOT NULL AND r.total > (r.plan->>'budget')::numeric)))
      ORDER BY (r.cnt > 0 OR r.plan IS NOT NULL) DESC, r.total DESC, r.name), '[]'::jsonb)
  INTO v_gms FROM r;
  RETURN jsonb_build_object('day', v_day, 'today', public.lwb_acc_today(), 'role', v_role, 'me', auth.uid(),
    'can_plan', public.lwb_lab_head(), 'can_pay', public.lwb_lab_can_pay(), 'can_all', v_all, 'is_gm', v_role = 'warehouse',
    'gms', v_gms,
    'count', (SELECT coalesce(sum((x->>'count')::int),0) FROM jsonb_array_elements(v_gms) x),
    'total', (SELECT coalesce(sum((x->>'total')::numeric),0) FROM jsonb_array_elements(v_gms) x),
    'paid', (SELECT coalesce(sum((x->>'paid')::numeric),0) FROM jsonb_array_elements(v_gms) x),
    'due', (SELECT coalesce(sum((x->>'due')::numeric),0) FROM jsonb_array_elements(v_gms) x));
END
$fn$;

-- ---------------------------------------------------------------------------
-- morning plan (Admin / Sales Head)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_labour_plan_set(p_day date, p_gm uuid, p_count int, p_rate numeric DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE x public.lwb_labour_plan; v_note text := nullif(btrim(coalesce(p_note,'')),'');
BEGIN
  IF NOT public.lwb_lab_head() THEN RAISE EXCEPTION 'Only Admin or a Sales Head can assign daily labour'; END IF;
  IF p_day IS NULL OR p_day < public.lwb_acc_today() - 7 OR p_day > public.lwb_acc_today() + 1 THEN
    RAISE EXCEPTION 'Assign for today or tomorrow'; END IF;
  IF NOT public.lwb_lab_is_gm(p_gm) THEN RAISE EXCEPTION 'Choose the Godown Manager'; END IF;
  IF p_count IS NULL OR p_count < 0 OR p_count > 500 THEN RAISE EXCEPTION 'Enter how many labour'; END IF;
  IF p_rate IS NOT NULL AND (p_rate < 0 OR p_rate > 10000) THEN RAISE EXCEPTION 'Check the rate'; END IF;
  INSERT INTO public.lwb_labour_plan (day, gm_id, count, rate, note, set_by)
  VALUES (p_day, p_gm, p_count, nullif(p_rate,0), v_note, auth.uid())
  ON CONFLICT (day, gm_id) DO UPDATE SET count = EXCLUDED.count, rate = EXCLUDED.rate, note = EXCLUDED.note,
    set_by = EXCLUDED.set_by, set_at = now()
  RETURNING * INTO x;
  PERFORM public.lwb_lab_bell(ARRAY[p_gm], 'LABOUR_PLAN',
    '👷 Labour for ' || to_char(p_day,'DD/MM') || ': ' || p_count || CASE WHEN p_count = 1 THEN ' labour' ELSE ' labour' END,
    public.lwb_lab_name(auth.uid()) || ' assigned ' || p_count || ' labour for ' || to_char(p_day,'DD/MM/YYYY') ||
    CASE WHEN x.rate IS NOT NULL THEN ' at ' || public.lwb_lab_money(x.rate) || ' each (' || public.lwb_lab_money(x.rate * p_count) || ')' ELSE '' END ||
    '. Enter each one''s name, mobile and wage in Daily Labour.' || coalesce(' · ' || v_note, ''));
  RETURN to_jsonb(x);
END
$fn$;

-- ---------------------------------------------------------------------------
-- labour rows
-- ---------------------------------------------------------------------------
-- p: {day, gm_id, name, mobile, wage, work}
CREATE OR REPLACE FUNCTION public.lwb_labour_add(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_day date; v_gm uuid; v_wage numeric; l public.lwb_labour; v_other text;
  v_name text := upper(btrim(regexp_replace(coalesce(p->>'name',''), '\s+', ' ', 'g')));
  v_mob text := public.lwb_lab_mobile(p->>'mobile');
  v_work text := nullif(btrim(coalesce(p->>'work','')),'');
BEGIN
  BEGIN
    v_day := coalesce(nullif(p->>'day','')::date, public.lwb_acc_today());
    v_gm := coalesce(nullif(p->>'gm_id','')::uuid, auth.uid());
    v_wage := round(nullif(p->>'wage','')::numeric, 2);
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the day and wage';
  END;
  PERFORM public.lwb_lab_check_edit(v_day, v_gm);
  IF length(v_name) < 2 THEN RAISE EXCEPTION 'Enter the labour name'; END IF;
  IF length(v_name) > 80 THEN RAISE EXCEPTION 'Name is too long'; END IF;
  IF v_mob !~ '^[6-9][0-9]{9}$' THEN RAISE EXCEPTION 'Enter a 10 digit mobile number of %', v_name; END IF;
  IF v_wage IS NULL OR v_wage <= 0 THEN RAISE EXCEPTION 'Enter today''s wage of %', v_name; END IF;
  IF v_wage > 10000 THEN RAISE EXCEPTION 'Wage of more than Rs 10,000 for one day? Check it.'; END IF;
  IF length(coalesce(v_work,'')) > 120 THEN RAISE EXCEPTION 'Work text is too long'; END IF;
  SELECT public.lwb_lab_name(x.gm_id) INTO v_other FROM public.lwb_labour x
  WHERE x.day = v_day AND x.mobile = v_mob AND x.removed_at IS NULL LIMIT 1;
  IF v_other IS NOT NULL THEN RAISE EXCEPTION 'Mobile % is already entered today (by %)', v_mob, v_other; END IF;
  INSERT INTO public.lwb_labour (day, gm_id, name, mobile, wage, work, created_by)
  VALUES (v_day, v_gm, v_name, v_mob, v_wage, v_work, auth.uid()) RETURNING * INTO l;
  RETURN public.lwb_lab_row(l);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_labour_edit(p_id bigint, p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE l public.lwb_labour; v_wage numeric; v_other text;
  v_name text := upper(btrim(regexp_replace(coalesce(p->>'name',''), '\s+', ' ', 'g')));
  v_mob text := public.lwb_lab_mobile(p->>'mobile');
  v_work text := nullif(btrim(coalesce(p->>'work','')),'');
BEGIN
  SELECT * INTO l FROM public.lwb_labour WHERE id = p_id AND removed_at IS NULL FOR UPDATE;
  IF l.id IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  PERFORM public.lwb_lab_check_edit(l.day, l.gm_id);
  BEGIN v_wage := round(nullif(p->>'wage','')::numeric, 2); EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the wage'; END;
  IF length(v_name) < 2 OR length(v_name) > 80 THEN RAISE EXCEPTION 'Enter the labour name'; END IF;
  IF v_mob !~ '^[6-9][0-9]{9}$' THEN RAISE EXCEPTION 'Enter a 10 digit mobile number of %', v_name; END IF;
  IF v_wage IS NULL OR v_wage <= 0 OR v_wage > 10000 THEN RAISE EXCEPTION 'Enter today''s wage of %', v_name; END IF;
  SELECT public.lwb_lab_name(x.gm_id) INTO v_other FROM public.lwb_labour x
  WHERE x.day = l.day AND x.mobile = v_mob AND x.removed_at IS NULL AND x.id <> l.id LIMIT 1;
  IF v_other IS NOT NULL THEN RAISE EXCEPTION 'Mobile % is already entered today (by %)', v_mob, v_other; END IF;
  UPDATE public.lwb_labour SET name = v_name, mobile = v_mob, wage = v_wage, work = v_work, updated_by = auth.uid(), updated_at = now()
  WHERE id = p_id RETURNING * INTO l;
  RETURN public.lwb_lab_row(l);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_labour_remove(p_id bigint, p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE l public.lwb_labour;
BEGIN
  SELECT * INTO l FROM public.lwb_labour WHERE id = p_id AND removed_at IS NULL FOR UPDATE;
  IF l.id IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  PERFORM public.lwb_lab_check_edit(l.day, l.gm_id);
  UPDATE public.lwb_labour SET removed_at = now(), removed_by = auth.uid(), remove_reason = left(nullif(btrim(coalesce(p_reason,'')),''),200)
  WHERE id = p_id;
  RETURN 'REMOVED';
END
$fn$;

-- ---------------------------------------------------------------------------
-- night cash (today's cashier / Admin)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_labour_pay(p_day date, p_gm uuid, p_amount numeric, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_amt numeric := round(coalesce(p_amount,0), 2); v_total numeric; v_extra numeric; v_paid numeric; v_due numeric;
        v_cat bigint; v_entry uuid; v_cnt int; v_note text := nullif(btrim(coalesce(p_note,'')),''); y public.lwb_labour_pay;
BEGIN
  IF NOT public.lwb_lab_can_pay() THEN
    RAISE EXCEPTION 'Only today''s cashier (or Admin) can give the labour cash'; END IF;
  IF p_day IS NULL OR p_day > public.lwb_acc_today() OR p_day < public.lwb_acc_today() - 7 THEN
    RAISE EXCEPTION 'Choose a day of the last 7 days'; END IF;
  IF p_gm IS NULL THEN RAISE EXCEPTION 'Choose the Godown Manager'; END IF;
  IF v_amt <= 0 THEN RAISE EXCEPTION 'Enter the amount'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_labour_pay:' || p_day || ':' || p_gm));
  v_total := public.lwb_lab_total(p_day, p_gm); v_extra := public.lwb_lab_extra_ok(p_day, p_gm); v_paid := public.lwb_lab_paid(p_day, p_gm);
  v_due := v_total + v_extra - v_paid;
  IF v_total <= 0 AND v_extra <= 0 THEN RAISE EXCEPTION 'No labour entered for % on %', public.lwb_lab_name(p_gm), to_char(p_day,'DD/MM'); END IF;
  IF v_amt > v_due THEN
    RAISE EXCEPTION 'You can give at most % (labour % + approved extra % − already given %). For more, change the amount: ask a Sales Head / Admin to approve the extra.',
      public.lwb_lab_money(greatest(v_due,0)), public.lwb_lab_money(v_total), public.lwb_lab_money(v_extra), public.lwb_lab_money(v_paid);
  END IF;
  SELECT c.id INTO v_cat FROM public.lwb_acc_categories c WHERE c.kind = 'OUT' AND lower(btrim(c.name)) = 'labour charge' AND c.active ORDER BY c.id LIMIT 1;
  IF v_cat IS NULL THEN RAISE EXCEPTION 'Cash Out head "Labour charge" is switched off. Ask Admin.'; END IF;
  SELECT count(*) INTO v_cnt FROM public.lwb_labour l WHERE l.day = p_day AND l.gm_id = p_gm AND l.removed_at IS NULL;
  v_entry := public.lwb_acc_add_entry(jsonb_build_object('date', public.lwb_acc_today(), 'kind', 'OUT', 'category_id', v_cat,
    'mode', 'CASH', 'amount', v_amt, 'party', public.lwb_lab_name(p_gm),
    'remark', left('Daily labour ' || to_char(p_day,'DD/MM') || ': ' || v_cnt || ' labour' || coalesce(' · ' || v_note, ''), 300)));
  INSERT INTO public.lwb_labour_pay (day, gm_id, amount, entry_id, note, paid_by)
  VALUES (p_day, p_gm, v_amt, v_entry, v_note, auth.uid()) RETURNING * INTO y;
  PERFORM public.lwb_lab_bell(ARRAY[p_gm], 'LABOUR_PAID', '💵 Labour cash ' || public.lwb_lab_money(v_amt) || ' given',
    public.lwb_lab_name(auth.uid()) || ' gave you ' || public.lwb_lab_money(v_amt) || ' for ' || v_cnt || ' labour of ' || to_char(p_day,'DD/MM') || '.');
  RETURN jsonb_build_object('id', y.id, 'entry_id', v_entry, 'amount', v_amt, 'due', v_due - v_amt);
END
$fn$;

-- more than the register: the extra waits for a Sales Head / Admin
CREATE OR REPLACE FUNCTION public.lwb_labour_extra_ask(p_day date, p_gm uuid, p_amount numeric, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE x public.lwb_labour_extra; v_amt numeric := round(coalesce(p_amount,0),2); v_why text := nullif(btrim(coalesce(p_reason,'')),'');
BEGIN
  IF NOT (public.lwb_lab_can_pay() OR public.lwb_lab_head() OR (public.lwb_lab_role() = 'warehouse' AND p_gm = auth.uid())) THEN
    RAISE EXCEPTION 'Only the cashier, the Godown Manager, a Sales Head or Admin can ask'; END IF;
  IF p_day IS NULL OR p_day > public.lwb_acc_today() OR p_day < public.lwb_acc_today() - 7 THEN RAISE EXCEPTION 'Choose a day of the last 7 days'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_gm) THEN RAISE EXCEPTION 'Choose the Godown Manager'; END IF;
  IF v_amt <= 0 OR v_amt > 50000 THEN RAISE EXCEPTION 'Enter the extra amount'; END IF;
  IF v_why IS NULL THEN RAISE EXCEPTION 'Write why more is needed'; END IF;
  INSERT INTO public.lwb_labour_extra (day, gm_id, amount, asked_amount, reason, asked_by)
  VALUES (p_day, p_gm, v_amt, v_amt, left(v_why,300), auth.uid()) RETURNING * INTO x;
  PERFORM public.lwb_lab_bell(public.lwb_lab_heads(), 'LABOUR_EXTRA',
    '👷 Labour extra ' || public.lwb_lab_money(v_amt) || ': ' || public.lwb_lab_name(p_gm),
    public.lwb_lab_name(auth.uid()) || ' asks to give ' || public.lwb_lab_money(v_amt) || ' more than the labour register (' ||
    public.lwb_lab_money(public.lwb_lab_total(p_day, p_gm)) || ') to ' || public.lwb_lab_name(p_gm) || ' for ' || to_char(p_day,'DD/MM') ||
    '. Why: ' || v_why || '. Approve on Approvals.');
  RETURN to_jsonb(x);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_labour_extra_decide(p_id bigint, p_ok boolean, p_amount numeric DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE x public.lwb_labour_extra; v_amt numeric; v_note text := nullif(btrim(coalesce(p_note,'')),'');
BEGIN
  IF NOT public.lwb_lab_head() THEN RAISE EXCEPTION 'Only a Sales Head or Admin can approve the labour extra'; END IF;
  SELECT * INTO x FROM public.lwb_labour_extra WHERE id = p_id FOR UPDATE;
  IF x.id IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  IF x.status <> 'WAITING' THEN RAISE EXCEPTION 'Already %', lower(x.status); END IF;
  IF x.asked_by = auth.uid() AND NOT public.lwb_acc_admin() THEN
    RAISE EXCEPTION 'You asked for this extra: another Sales Head or Admin must approve it'; END IF;
  v_amt := round(coalesce(p_amount, x.amount), 2);
  IF p_ok AND (v_amt <= 0 OR v_amt > x.asked_amount) THEN RAISE EXCEPTION 'Approve between Rs 1 and the asked %', public.lwb_lab_money(x.asked_amount); END IF;
  IF NOT p_ok AND v_note IS NULL THEN RAISE EXCEPTION 'Write why it is rejected'; END IF;
  UPDATE public.lwb_labour_extra SET status = CASE WHEN p_ok THEN 'APPROVED' ELSE 'REJECTED' END,
    amount = CASE WHEN p_ok THEN v_amt ELSE amount END, decided_by = auth.uid(), decided_at = now(), decide_note = v_note
  WHERE id = p_id RETURNING * INTO x;
  UPDATE public.erp_notifications n SET is_read = true
  WHERE n.notification_type = 'LABOUR_EXTRA' AND n.is_read = false AND n.title LIKE '%: ' || public.lwb_lab_name(x.gm_id)
    AND NOT EXISTS (SELECT 1 FROM public.lwb_labour_extra w WHERE w.gm_id = x.gm_id AND w.status = 'WAITING');
  PERFORM public.lwb_lab_bell(ARRAY[x.asked_by, x.gm_id], 'LABOUR_EXTRA_DONE',
    CASE WHEN p_ok THEN '✅ Labour extra ' || public.lwb_lab_money(x.amount) || ' approved' ELSE '❌ Labour extra rejected' END,
    public.lwb_lab_name(auth.uid()) || CASE WHEN p_ok THEN ' approved ' || public.lwb_lab_money(x.amount) ||
      CASE WHEN x.amount < x.asked_amount THEN ' (of ' || public.lwb_lab_money(x.asked_amount) || ' asked)' ELSE '' END ||
      ' more for ' || public.lwb_lab_name(x.gm_id) || '''s labour of ' || to_char(x.day,'DD/MM') || '. The cashier can give it now.'
      ELSE ' rejected the extra ' || public.lwb_lab_money(x.asked_amount) || ' for ' || to_char(x.day,'DD/MM') END ||
    coalesce(' · ' || v_note, ''));
  RETURN to_jsonb(x);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_labour_extra_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_lab_head() THEN RAISE EXCEPTION 'Admin / Sales Head only'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'day', x.day, 'gm_id', x.gm_id, 'gm', public.lwb_lab_name(x.gm_id),
      'amount', x.amount, 'reason', x.reason, 'by', public.lwb_lab_name(x.asked_by), 'at', x.asked_at,
      'mine', x.asked_by = auth.uid(), 'can_decide', x.asked_by IS DISTINCT FROM auth.uid() OR public.lwb_acc_admin(),
      'count', (SELECT count(*) FROM public.lwb_labour l WHERE l.day = x.day AND l.gm_id = x.gm_id AND l.removed_at IS NULL),
      'total', public.lwb_lab_total(x.day, x.gm_id), 'paid', public.lwb_lab_paid(x.day, x.gm_id),
      'extra_ok', public.lwb_lab_extra_ok(x.day, x.gm_id),
      'plan', (SELECT jsonb_build_object('count', pl.count, 'rate', pl.rate) FROM public.lwb_labour_plan pl WHERE pl.day = x.day AND pl.gm_id = x.gm_id))
      ORDER BY x.asked_at) FROM public.lwb_labour_extra x WHERE x.status = 'WAITING'), '[]'::jsonb);
END
$fn$;

-- ---------------------------------------------------------------------------
-- repeat labourer + history
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_labour_find(p_mobile text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_mob text := public.lwb_lab_mobile(p_mobile); r jsonb;
BEGIN
  IF NOT (public.lwb_lab_all() OR public.lwb_lab_role() = 'warehouse') THEN RAISE EXCEPTION 'Not allowed'; END IF;
  IF length(v_mob) <> 10 THEN RETURN NULL; END IF;
  SELECT jsonb_build_object('mobile', v_mob, 'name', l.name, 'wage', l.wage, 'work', l.work, 'last_day', l.day,
      'last_gm', public.lwb_lab_name(l.gm_id),
      'days', (SELECT count(DISTINCT x.day) FROM public.lwb_labour x WHERE x.mobile = v_mob AND x.removed_at IS NULL),
      'total', (SELECT sum(x.wage) FROM public.lwb_labour x WHERE x.mobile = v_mob AND x.removed_at IS NULL))
  INTO r FROM public.lwb_labour l WHERE l.mobile = v_mob AND l.removed_at IS NULL ORDER BY l.day DESC, l.id DESC LIMIT 1;
  RETURN r;
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_labour_people(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_all boolean := public.lwb_lab_all();
BEGIN
  IF NOT (v_all OR public.lwb_lab_role() = 'warehouse') THEN RAISE EXCEPTION 'Not allowed'; END IF;
  RETURN coalesce((SELECT jsonb_agg(z ORDER BY (z->>'days')::int DESC, (z->>'total')::numeric DESC) FROM (
    SELECT jsonb_build_object('mobile', l.mobile,
      'name', (array_agg(l.name ORDER BY l.day DESC, l.id DESC))[1],
      'days', count(DISTINCT l.day), 'total', sum(l.wage), 'avg', round(sum(l.wage) / greatest(count(*),1)),
      'first_day', min(l.day), 'last_day', max(l.day),
      'gms', (SELECT jsonb_agg(DISTINCT public.lwb_lab_name(g)) FROM unnest(array_agg(l.gm_id)) g),
      'all_days', (SELECT count(DISTINCT x.day) FROM public.lwb_labour x WHERE x.mobile = l.mobile AND x.removed_at IS NULL)) AS z
    FROM public.lwb_labour l
    WHERE l.removed_at IS NULL AND l.day BETWEEN p_from AND p_to AND (v_all OR l.gm_id = auth.uid())
    GROUP BY l.mobile) q), '[]'::jsonb);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_labour_days(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_all boolean := public.lwb_lab_all();
BEGIN
  IF NOT (v_all OR public.lwb_lab_role() = 'warehouse') THEN RAISE EXCEPTION 'Not allowed'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('day', d.day, 'gm_id', d.gm_id, 'gm', public.lwb_lab_name(d.gm_id),
      'count', d.cnt, 'total', d.total, 'paid', public.lwb_lab_paid(d.day, d.gm_id), 'extra_ok', public.lwb_lab_extra_ok(d.day, d.gm_id),
      'plan', (SELECT pl.count FROM public.lwb_labour_plan pl WHERE pl.day = d.day AND pl.gm_id = d.gm_id))
      ORDER BY d.day DESC, d.total DESC)
    FROM (SELECT l.day, l.gm_id, count(*) AS cnt, sum(l.wage) AS total FROM public.lwb_labour l
          WHERE l.removed_at IS NULL AND l.day BETWEEN p_from AND p_to AND (v_all OR l.gm_id = auth.uid())
          GROUP BY l.day, l.gm_id) d), '[]'::jsonb);
END
$fn$;

-- ---------------------------------------------------------------------------
-- Godown Manager bells: LABOUR_* is his own work (lwb_gm_notify_scope_setup.sql drops other bells)
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_def text;
BEGIN
  IF to_regprocedure('public.lwb_gm_bell_ok(uuid,text,uuid,text,text,text)') IS NULL THEN RETURN; END IF;
  v_def := pg_get_functiondef('public.lwb_gm_bell_ok(uuid,text,uuid,text,text,text)'::regprocedure);
  IF position('LABOUR' IN v_def) > 0 THEN RETURN; END IF;
  IF position('t IN (''CHAT_MSG'',''ANNOUNCEMENT'')' IN v_def) = 0 THEN
    RAISE EXCEPTION 'lwb_gm_bell_ok text has changed: LABOUR bells not added';
  END IF;
  v_def := replace(v_def, 't IN (''CHAT_MSG'',''ANNOUNCEMENT'')', 't IN (''CHAT_MSG'',''ANNOUNCEMENT'') OR t LIKE ''LABOUR\_%''');
  EXECUTE v_def;
END
$do$;

REVOKE ALL ON FUNCTION public.lwb_lab_role(), public.lwb_lab_head(), public.lwb_lab_all(), public.lwb_lab_can_pay(),
  public.lwb_lab_name(uuid), public.lwb_lab_is_gm(uuid), public.lwb_lab_mobile(text), public.lwb_lab_money(numeric),
  public.lwb_lab_paid(date,uuid), public.lwb_lab_total(date,uuid), public.lwb_lab_extra_ok(date,uuid),
  public.lwb_lab_bell(uuid[],text,text,text), public.lwb_lab_heads(), public.lwb_lab_check_edit(date,uuid),
  public.lwb_lab_row(public.lwb_labour), public.lwb_labour_day(date), public.lwb_labour_plan_set(date,uuid,int,numeric,text),
  public.lwb_labour_add(jsonb), public.lwb_labour_edit(bigint,jsonb), public.lwb_labour_remove(bigint,text),
  public.lwb_labour_pay(date,uuid,numeric,text), public.lwb_labour_extra_ask(date,uuid,numeric,text),
  public.lwb_labour_extra_decide(bigint,boolean,numeric,text), public.lwb_labour_extra_list(),
  public.lwb_labour_find(text), public.lwb_labour_people(date,date), public.lwb_labour_days(date,date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_lab_bell(uuid[],text,text,text), public.lwb_lab_check_edit(date,uuid),
  public.lwb_lab_row(public.lwb_labour), public.lwb_lab_paid(date,uuid), public.lwb_lab_total(date,uuid),
  public.lwb_lab_extra_ok(date,uuid), public.lwb_lab_heads() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_labour_day(date), public.lwb_labour_plan_set(date,uuid,int,numeric,text),
  public.lwb_labour_add(jsonb), public.lwb_labour_edit(bigint,jsonb), public.lwb_labour_remove(bigint,text),
  public.lwb_labour_pay(date,uuid,numeric,text), public.lwb_labour_extra_ask(date,uuid,numeric,text),
  public.lwb_labour_extra_decide(bigint,boolean,numeric,text), public.lwb_labour_extra_list(),
  public.lwb_labour_find(text), public.lwb_labour_people(date,date), public.lwb_labour_days(date,date) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'tables' AS item, (to_regclass('public.lwb_labour') IS NOT NULL AND to_regclass('public.lwb_labour_extra') IS NOT NULL)::text AS ok
UNION ALL SELECT 'day rpc', (to_regprocedure('public.lwb_labour_day(date)') IS NOT NULL)::text
UNION ALL SELECT 'pay rpc', (to_regprocedure('public.lwb_labour_pay(date,uuid,numeric,text)') IS NOT NULL)::text
UNION ALL SELECT 'labour charge head', EXISTS (SELECT 1 FROM public.lwb_acc_categories c WHERE c.kind = 'OUT' AND lower(btrim(c.name)) = 'labour charge')::text
UNION ALL SELECT 'gm gets labour bells', (to_regprocedure('public.lwb_gm_bell_ok(uuid,text,uuid,text,text,text)') IS NULL
  OR position('LABOUR' IN pg_get_functiondef('public.lwb_gm_bell_ok(uuid,text,uuid,text,text,text)'::regprocedure)) > 0)::text;
