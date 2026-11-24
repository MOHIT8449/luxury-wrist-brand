-- LUXURY WRIST BRAND ERP — CASH HANDOVER: ONLY CHOSEN PEOPLE, @TAG, SPLIT THE AMOUNT (Mohit, 23 Nov 2026)
--
-- Cash is given only to a short list of people (Accounts, Vishal bhai, Sales, Admin). Admin keeps the list.
-- In the "Hand over the cash box" popup you tag one or more of them with @ (like WhatsApp) and split the
-- counted cash, e.g. Rs 5,00,000 = Rs 2,50,000 to one + Rs 2,50,000 to another. Every person presses
-- Received ✓ for his own part (or Admin does). Each one then holds his part.
-- Builds on lwb_acc_shift_handover_setup.sql. The cash book does not change.
--
--   lwb_acc_cash_people                  the people who may take cash (Admin sets it)
--   lwb_acc_cash_people_get()            the list (+ all active staff for Admin, to pick from)
--   lwb_acc_cash_people_set(uuid[])      Admin saves the list
--   lwb_acc_shift_give_split(parts, notes, note)   one handover, split in parts [{to, amount}]
--   lwb_acc_shift_handovers.batch_id     the parts of one handover share it

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_acc_cash_people (
  user_id   uuid PRIMARY KEY,
  sort      int NOT NULL DEFAULT 0,
  added_by  uuid,
  added_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_acc_cash_people ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_acc_cash_people FROM PUBLIC, anon, authenticated;

-- first time only: the people who could take cash till now, + Vishal bhai
INSERT INTO public.lwb_acc_cash_people (user_id, sort)
SELECT p.id, row_number() OVER (ORDER BY lower(btrim(p.role)) = 'admin', p.full_name)
FROM public.user_profiles p
WHERE p.active = true
  AND (lower(btrim(p.role)) IN ('admin','accounts','cashier') OR p.full_name ILIKE 'vishal%')
  AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_cash_people)
ON CONFLICT DO NOTHING;

-- parts of one handover
ALTER TABLE public.lwb_acc_shift_handovers ADD COLUMN IF NOT EXISTS batch_id bigint;
UPDATE public.lwb_acc_shift_handovers SET batch_id = id WHERE batch_id IS NULL;
DROP INDEX IF EXISTS public.lwb_acc_shift_one_pending;
CREATE UNIQUE INDEX IF NOT EXISTS lwb_acc_shift_batch_to ON public.lwb_acc_shift_handovers (batch_id, given_to);
CREATE INDEX IF NOT EXISTS lwb_acc_shift_pending ON public.lwb_acc_shift_handovers (status) WHERE status = 'PENDING';

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_can_take(p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.lwb_acc_cash_people c JOIN public.user_profiles p ON p.id = c.user_id
                 WHERE c.user_id = p_user AND p.active = true);
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_cash_people_get()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_admin boolean := public.lwb_acc_admin();
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  RETURN jsonb_build_object(
    'is_admin', v_admin,
    'list', coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'name', coalesce(nullif(btrim(p.full_name),''), 'User'),
              'role', lower(btrim(p.role)), 'me', p.id = auth.uid()) ORDER BY c.sort, p.full_name)
            FROM public.lwb_acc_cash_people c JOIN public.user_profiles p ON p.id = c.user_id WHERE p.active = true), '[]'::jsonb),
    'all', CASE WHEN v_admin THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'name', coalesce(nullif(btrim(p.full_name),''), 'User'),
              'role', lower(btrim(p.role)), 'on', c.user_id IS NOT NULL) ORDER BY c.user_id IS NULL, c.sort, p.full_name)
            FROM public.user_profiles p LEFT JOIN public.lwb_acc_cash_people c ON c.user_id = p.id
            WHERE p.active = true AND lower(btrim(coalesce(p.role,''))) <> 'driver'), '[]'::jsonb) END);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_cash_people_set(p_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_ids uuid[];
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can change who takes the cash'; END IF;
  SELECT coalesce(array_agg(x.id ORDER BY x.n), '{}') INTO v_ids
  FROM (SELECT DISTINCT ON (u) u AS id, n FROM unnest(coalesce(p_ids,'{}')) WITH ORDINALITY AS t(u, n) WHERE u IS NOT NULL ORDER BY u, n) x
  WHERE EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = x.id AND p.active = true);
  IF cardinality(v_ids) = 0 THEN RAISE EXCEPTION 'Keep at least one person'; END IF;
  IF cardinality(v_ids) > 10 THEN RAISE EXCEPTION 'Keep 10 people or less'; END IF;
  DELETE FROM public.lwb_acc_cash_people c WHERE NOT (c.user_id = ANY (v_ids));
  INSERT INTO public.lwb_acc_cash_people (user_id, sort, added_by)
  SELECT u, n, auth.uid() FROM unnest(v_ids) WITH ORDINALITY AS t(u, n)
  ON CONFLICT (user_id) DO UPDATE SET sort = excluded.sort;
  RETURN jsonb_build_object('ok', true, 'count', cardinality(v_ids));
END
$fn$;

-- the people a cash box can go to = the list
CREATE OR REPLACE FUNCTION public.lwb_acc_shift_people()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  RETURN public.lwb_acc_cash_people_get()->'list';
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_count(p_notes jsonb)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = ''
AS $fn$
DECLARE v_counted numeric := 0; k text; v numeric;
BEGIN
  IF p_notes IS NULL OR jsonb_typeof(p_notes) <> 'object' THEN RAISE EXCEPTION 'Count the notes'; END IF;
  FOR k, v IN SELECT e.key, nullif(e.value::text,'null')::numeric FROM jsonb_each(p_notes) e LOOP
    IF k NOT IN ('500','200','100','50','20','10','coins') OR v IS NULL OR v < 0 THEN RAISE EXCEPTION 'Check the note count'; END IF;
    v_counted := v_counted + CASE WHEN k = 'coins' THEN v ELSE k::numeric * floor(v) END;
  END LOOP;
  RETURN round(v_counted, 2);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_give_split(p_parts jsonb, p_notes jsonb, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_counted numeric; v_book numeric := 0; v_batch bigint; v_first bigint; v_id bigint; v_sum numeric := 0; v_n int := 0;
  v_note text := nullif(btrim(coalesce(p_note,'')),''); r record; v_names text;
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_acc_shift_give'));
  IF EXISTS (SELECT 1 FROM public.lwb_acc_shift_handovers h WHERE h.status = 'PENDING') THEN
    RAISE EXCEPTION 'A handover is already waiting. It must be received or cancelled first.'; END IF;
  v_counted := public.lwb_acc_shift_count(p_notes);
  IF p_parts IS NULL OR jsonb_typeof(p_parts) <> 'array' OR jsonb_array_length(p_parts) = 0 THEN
    RAISE EXCEPTION 'Choose the person who takes the cash'; END IF;
  IF jsonb_array_length(p_parts) > 10 THEN RAISE EXCEPTION 'Split in 10 parts or less'; END IF;
  FOR r IN SELECT nullif(e->>'to','')::uuid AS uid, round(nullif(e->>'amount','')::numeric, 2) AS amt FROM jsonb_array_elements(p_parts) e LOOP
    IF r.uid IS NULL OR r.uid = auth.uid() THEN RAISE EXCEPTION 'Choose the person who takes the cash'; END IF;
    IF NOT public.lwb_acc_shift_can_take(r.uid) THEN
      RAISE EXCEPTION 'Cash can go only to the people Admin has chosen (% is not in the list)', public.lwb_acc_shift_name(r.uid); END IF;
    IF r.amt IS NULL OR r.amt <= 0 THEN RAISE EXCEPTION 'Write the amount for %', public.lwb_acc_shift_name(r.uid); END IF;
    v_sum := v_sum + r.amt; v_n := v_n + 1;
  END LOOP;
  IF (SELECT count(DISTINCT e->>'to') FROM jsonb_array_elements(p_parts) e) <> v_n THEN RAISE EXCEPTION 'The same person is tagged twice'; END IF;
  IF abs(v_sum - v_counted) >= 0.01 THEN
    RAISE EXCEPTION 'The parts add up to Rs % but the counted cash is Rs %. Make them equal.',
      to_char(v_sum, 'FM99999999990.00'), to_char(v_counted, 'FM99999999990.00'); END IF;
  SELECT coalesce(c.amount, 0) INTO v_book FROM public.lwb_acc_cash_at(public.lwb_acc_today() + 1) c;
  IF abs(v_counted - v_book) >= 1 AND v_note IS NULL THEN
    RAISE EXCEPTION 'Cash is % by Rs %. Write a note why.', CASE WHEN v_counted < v_book THEN 'short' ELSE 'extra' END,
      to_char(abs(v_counted - v_book), 'FM99999999990.00'); END IF;
  v_batch := nextval('public.lwb_acc_shift_handovers_id_seq');
  SELECT string_agg(public.lwb_acc_shift_name(nullif(e->>'to','')::uuid) || ' Rs ' || to_char(round((e->>'amount')::numeric,2), 'FM99999999990'), ', ')
    INTO v_names FROM jsonb_array_elements(p_parts) e;
  FOR r IN SELECT nullif(e->>'to','')::uuid AS uid, round((e->>'amount')::numeric, 2) AS amt FROM jsonb_array_elements(p_parts) e LOOP
    INSERT INTO public.lwb_acc_shift_handovers (batch_id, given_by, given_to, book_cash, counted, counted_notes, note)
    VALUES (v_batch, auth.uid(), r.uid, round(v_book, 2), r.amt, p_notes, v_note) RETURNING id INTO v_id;
    v_first := coalesce(v_first, v_id);
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
    VALUES (r.uid, 'Cash handover: Rs ' || to_char(r.amt, 'FM99999999990') || ' from ' || public.lwb_acc_shift_name(auth.uid()),
            public.lwb_acc_shift_name(auth.uid()) || ' is handing you Rs ' || to_char(r.amt, 'FM99999999990.00')
            || CASE WHEN v_n > 1 THEN ' (cash split: ' || v_names || ')' ELSE '' END
            || '. Count it and press Received ✓ on the Cashier page.', 'ACC_SHIFT_HANDOVER');
  END LOOP;
  RETURN jsonb_build_object('id', v_first, 'batch', v_batch, 'counted', v_counted, 'book', round(v_book, 2), 'parts', v_n);
END
$fn$;

-- old single-person call: same as one part with the whole cash
CREATE OR REPLACE FUNCTION public.lwb_acc_shift_give(p_to uuid, p_notes jsonb, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  RETURN public.lwb_acc_shift_give_split(jsonb_build_array(jsonb_build_object('to', p_to, 'amount', public.lwb_acc_shift_count(p_notes))), p_notes, p_note);
END
$fn$;

-- the tagged person (from his own login, even Sales) or Admin accepts his part
CREATE OR REPLACE FUNCTION public.lwb_acc_shift_receive(p_id bigint, p_amount numeric DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_acc_shift_handovers%ROWTYPE; v_amt numeric; v_note text := nullif(btrim(coalesce(p_note,'')),'');
BEGIN
  SELECT * INTO h FROM public.lwb_acc_shift_handovers WHERE id = p_id FOR UPDATE;
  IF h.id IS NULL OR h.status <> 'PENDING' THEN RAISE EXCEPTION 'This handover is not waiting any more'; END IF;
  IF h.given_to IS DISTINCT FROM auth.uid() AND NOT public.lwb_acc_admin() THEN
    RAISE EXCEPTION 'Only % (or Admin) can accept this cash', public.lwb_acc_shift_name(h.given_to); END IF;
  v_amt := round(coalesce(p_amount, h.counted), 2);
  IF v_amt < 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'Check the amount'; END IF;
  IF abs(v_amt - h.counted) >= 1 AND v_note IS NULL THEN RAISE EXCEPTION 'The amount is different from what was handed. Write a note why.'; END IF;
  UPDATE public.lwb_acc_shift_handovers SET status = 'RECEIVED', received_amount = v_amt, received_by = auth.uid(),
    received_at = now(), receive_note = v_note WHERE id = p_id;
  UPDATE public.erp_notifications SET is_read = true
  WHERE user_id = h.given_to AND notification_type = 'ACC_SHIFT_HANDOVER' AND is_read = false;
  IF abs(v_amt - h.counted) >= 1 THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
    SELECT p.id, 'Cash handover ' || CASE WHEN v_amt < h.counted THEN 'short' ELSE 'extra' END || ' Rs ' || to_char(abs(v_amt - h.counted), 'FM99999999990'),
           public.lwb_acc_shift_name(h.given_by) || ' handed Rs ' || to_char(h.counted, 'FM99999999990.00') || ', '
           || public.lwb_acc_shift_name(auth.uid()) || ' received Rs ' || to_char(v_amt, 'FM99999999990.00') || '. ' || v_note,
           'ACC_SHIFT_HANDOVER'
    FROM public.user_profiles p WHERE p.active = true AND (lower(btrim(p.role)) = 'admin' OR p.id = h.given_by);
  END IF;
  RETURN jsonb_build_object('ok', true, 'amount', v_amt);
END
$fn$;

-- cancel = every part still waiting in that handover (parts already received stay)
CREATE OR REPLACE FUNCTION public.lwb_acc_shift_cancel(p_id bigint, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_acc_shift_handovers%ROWTYPE;
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  SELECT * INTO h FROM public.lwb_acc_shift_handovers WHERE id = p_id FOR UPDATE;
  IF h.id IS NULL OR h.status <> 'PENDING' THEN RAISE EXCEPTION 'This handover is not waiting any more'; END IF;
  IF h.given_by <> auth.uid() AND NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only the person who handed it (or Admin) can cancel'; END IF;
  UPDATE public.erp_notifications n SET is_read = true
  WHERE n.notification_type = 'ACC_SHIFT_HANDOVER' AND n.is_read = false
    AND n.user_id IN (SELECT x.given_to FROM public.lwb_acc_shift_handovers x WHERE x.batch_id = h.batch_id AND x.status = 'PENDING');
  UPDATE public.lwb_acc_shift_handovers SET status = 'CANCELLED', cancelled_by = auth.uid(), cancelled_at = now(),
    receive_note = nullif(btrim(coalesce(p_note,'')),'') WHERE batch_id = h.batch_id AND status = 'PENDING';
  RETURN jsonb_build_object('ok', true);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_list(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_from date := coalesce(p_from, public.lwb_acc_today()); v_to date := coalesce(p_to, public.lwb_acc_today());
  v_staff boolean := public.lwb_acc_shift_ok(auth.uid()); v_hb bigint; v_pb bigint; r jsonb;
BEGIN
  IF NOT v_staff AND NOT public.lwb_acc_shift_can_take(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  -- holders: the received parts of the last handover that has any received part
  SELECT h.batch_id INTO v_hb FROM public.lwb_acc_shift_handovers h WHERE h.status = 'RECEIVED'
  GROUP BY h.batch_id ORDER BY max(h.given_at) DESC, h.batch_id DESC LIMIT 1;
  SELECT h.batch_id INTO v_pb FROM public.lwb_acc_shift_handovers h WHERE h.status = 'PENDING' ORDER BY h.given_at DESC LIMIT 1;
  WITH x AS (
    SELECT h.*, public.lwb_acc_shift_name(h.given_by) AS by_name, public.lwb_acc_shift_name(h.given_to) AS to_name,
           (h.given_at AT TIME ZONE 'Asia/Kolkata')::date AS day,
           sum(h.counted) FILTER (WHERE h.status <> 'CANCELLED') OVER (PARTITION BY h.batch_id) AS batch_total,
           count(*) FILTER (WHERE h.status <> 'CANCELLED') OVER (PARTITION BY h.batch_id) AS batch_parts
    FROM public.lwb_acc_shift_handovers h),
  hs AS (
    SELECT jsonb_agg(jsonb_build_object('id', x.given_to, 'name', x.to_name, 'since', x.received_at, 'amount', x.received_amount,
             'mobile', public.lwb_acc_shift_mobile(x.given_to), 'role', public.lwb_acc_shift_role(x.given_to),
             'today', (x.received_at AT TIME ZONE 'Asia/Kolkata')::date = public.lwb_acc_today()) ORDER BY x.id) AS a
    FROM x WHERE x.batch_id = v_hb AND x.status = 'RECEIVED'),
  ps AS (
    SELECT jsonb_agg(jsonb_build_object('id', x.id, 'to', x.given_to, 'to_name', x.to_name, 'to_mobile', public.lwb_acc_shift_mobile(x.given_to),
             'amount', x.counted, 'status', x.status, 'received', x.received_amount, 'received_at', x.received_at) ORDER BY x.id) AS a,
           (array_agg(x.id ORDER BY x.id) FILTER (WHERE x.status = 'PENDING'))[1] AS first_id
    FROM x WHERE x.batch_id = v_pb AND x.status <> 'CANCELLED')
  SELECT jsonb_build_object(
    'me', auth.uid(),
    'is_admin', public.lwb_acc_admin(),
    'can_give', v_staff,
    'holders', coalesce((SELECT hs.a FROM hs), '[]'::jsonb),
    'holder', (SELECT hs.a->0 FROM hs),
    'pending', (SELECT jsonb_build_object('id', ps.first_id, 'batch', x.batch_id, 'by', x.given_by, 'by_name', x.by_name,
                  'to', x.given_to, 'to_name', (SELECT string_agg(e->>'to_name', ' + ') FROM jsonb_array_elements(ps.a) e WHERE e->>'status' = 'PENDING'),
                  'to_mobile', public.lwb_acc_shift_mobile(x.given_to), 'by_mobile', public.lwb_acc_shift_mobile(x.given_by),
                  'at', x.given_at, 'counted', x.batch_total, 'book', x.book_cash, 'note', x.note, 'parts', ps.a)
                FROM x, ps WHERE x.id = ps.first_id),
    'last_entry', CASE WHEN v_staff THEN (SELECT jsonb_build_object('id', l.created_by, 'name', public.lwb_acc_shift_name(l.created_by), 'at', l.at,
                  'mobile', public.lwb_acc_shift_mobile(l.created_by), 'role', public.lwb_acc_shift_role(l.created_by))
                FROM public.lwb_acc_lines() l
                WHERE l.book_date = public.lwb_acc_today() AND l.cash_effect <> 0 AND l.created_by IS NOT NULL
                ORDER BY l.at DESC LIMIT 1) END,
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'batch', x.batch_id, 'batch_total', x.batch_total, 'batch_parts', x.batch_parts,
                  'day', x.day, 'at', x.given_at, 'by_name', x.by_name,
                  'to_name', x.to_name, 'book', x.book_cash, 'counted', x.counted, 'notes', x.counted_notes, 'note', x.note,
                  'status', x.status, 'received', x.received_amount, 'received_at', x.received_at, 'receive_note', x.receive_note,
                  'cancelled_at', x.cancelled_at) ORDER BY x.given_at DESC, x.id)
              FROM x WHERE x.day BETWEEN v_from AND v_to AND (v_staff OR x.given_to = auth.uid())), '[]'::jsonb))
  INTO r;
  RETURN r;
END
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_shift_can_take(uuid), public.lwb_acc_shift_count(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_acc_cash_people_get(), public.lwb_acc_cash_people_set(uuid[]),
  public.lwb_acc_shift_give_split(jsonb,jsonb,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_cash_people_get(), public.lwb_acc_cash_people_set(uuid[]),
  public.lwb_acc_shift_give_split(jsonb,jsonb,text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true; then the people who may take cash now.
SELECT 'cash people table' AS item, (to_regclass('public.lwb_acc_cash_people') IS NOT NULL)::text AS ok
UNION ALL SELECT 'split give', (to_regprocedure('public.lwb_acc_shift_give_split(jsonb,jsonb,text)') IS NOT NULL)::text
UNION ALL SELECT 'batch column', EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
  AND table_name = 'lwb_acc_shift_handovers' AND column_name = 'batch_id')::text;
SELECT p.full_name, p.role FROM public.lwb_acc_cash_people c JOIN public.user_profiles p ON p.id = c.user_id ORDER BY c.sort;
