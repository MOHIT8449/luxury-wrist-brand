-- LUXURY WRIST BRAND ERP — CASH SHIFT HANDOVER DURING THE DAY (Mohit, 20 Nov 2026)
--
-- The cash box is kept by different people on different days or half days (Yogesh bhai, Vinesh bhai, Vishal bhai).
-- Whoever has the cash counts it and hands it to the next person; the next person accepts it from his own
-- login ("Received ✓"). Short / extra is shown. The Cashier page shows "Cash now with <name> since <time>".
-- This does not move money: the cash book (Cash In / Out / Close Day) stays as it is. Night Close Day stays.
--
--   lwb_acc_shift_handovers           one row per handover (PENDING -> RECEIVED, or CANCELLED)
--   lwb_acc_shift_people()            who can take the cash (active Admin / Accounts / Cashier)
--   lwb_acc_shift_give(to, notes, note)      count + hand over (one waiting handover at a time)
--   lwb_acc_shift_receive(id, amount, note)  the receiver (or Admin) accepts
--   lwb_acc_shift_cancel(id, note)           the giver (or Admin) takes back a waiting one
--   lwb_acc_shift_list(from, to)             holder now, waiting handover, rows of the dates

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_acc_shift_handovers (
  id            bigserial PRIMARY KEY,
  given_by      uuid NOT NULL,
  given_to      uuid NOT NULL,
  given_at      timestamptz NOT NULL DEFAULT now(),
  book_cash     numeric(14,2) NOT NULL DEFAULT 0,
  counted       numeric(14,2) NOT NULL CHECK (counted >= 0),
  counted_notes jsonb,
  note          text CHECK (note IS NULL OR length(note) <= 300),
  status        text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','RECEIVED','CANCELLED')),
  received_amount numeric(14,2) CHECK (received_amount IS NULL OR received_amount >= 0),
  received_by   uuid,
  received_at   timestamptz,
  receive_note  text CHECK (receive_note IS NULL OR length(receive_note) <= 300),
  cancelled_by  uuid,
  cancelled_at  timestamptz,
  CHECK (given_by <> given_to)
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_acc_shift_one_pending ON public.lwb_acc_shift_handovers ((true)) WHERE status = 'PENDING';
CREATE INDEX IF NOT EXISTS lwb_acc_shift_given_at ON public.lwb_acc_shift_handovers (given_at DESC);
ALTER TABLE public.lwb_acc_shift_handovers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_acc_shift_handovers FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_acc_shift_handovers_id_seq FROM PUBLIC, anon, authenticated;

-- who may keep the cash box
CREATE OR REPLACE FUNCTION public.lwb_acc_shift_ok(p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','accounts','cashier'));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_name(p_user uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(nullif(btrim(p.full_name),''), 'User') FROM public.user_profiles p WHERE p.id = p_user;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_people()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'name', coalesce(nullif(btrim(p.full_name),''), 'User'),
                    'role', lower(btrim(p.role)), 'me', p.id = auth.uid()) ORDER BY lower(btrim(p.role)) = 'admin', p.full_name)
                  FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','accounts','cashier')), '[]'::jsonb);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_give(p_to uuid, p_notes jsonb, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_counted numeric := 0; v_book numeric := 0; k text; v numeric; v_id bigint;
  v_note text := nullif(btrim(coalesce(p_note,'')),'');
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  IF p_to IS NULL OR p_to = auth.uid() THEN RAISE EXCEPTION 'Choose the person who takes the cash'; END IF;
  IF NOT public.lwb_acc_shift_ok(p_to) THEN RAISE EXCEPTION 'Cash can go only to an active Admin / Accounts / Cashier'; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_acc_shift_handovers h WHERE h.status = 'PENDING') THEN
    RAISE EXCEPTION 'A handover is already waiting. It must be received or cancelled first.'; END IF;
  IF p_notes IS NULL OR jsonb_typeof(p_notes) <> 'object' THEN RAISE EXCEPTION 'Count the notes'; END IF;
  FOR k, v IN SELECT e.key, nullif(e.value::text,'null')::numeric FROM jsonb_each(p_notes) e LOOP
    IF k NOT IN ('500','200','100','50','20','10','coins') OR v IS NULL OR v < 0 THEN RAISE EXCEPTION 'Check the note count'; END IF;
    v_counted := v_counted + CASE WHEN k = 'coins' THEN v ELSE k::numeric * floor(v) END;
  END LOOP;
  v_counted := round(v_counted, 2);
  SELECT coalesce(c.amount, 0) INTO v_book FROM public.lwb_acc_cash_at(public.lwb_acc_today() + 1) c;
  IF abs(v_counted - v_book) >= 1 AND v_note IS NULL THEN
    RAISE EXCEPTION 'Cash is % by Rs %. Write a note why.', CASE WHEN v_counted < v_book THEN 'short' ELSE 'extra' END,
      to_char(abs(v_counted - v_book), 'FM99999999990.00'); END IF;
  INSERT INTO public.lwb_acc_shift_handovers (given_by, given_to, book_cash, counted, counted_notes, note)
  VALUES (auth.uid(), p_to, round(v_book, 2), v_counted, p_notes, v_note) RETURNING id INTO v_id;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
  VALUES (p_to, 'Cash handover: Rs ' || to_char(v_counted, 'FM99999999990') || ' from ' || public.lwb_acc_shift_name(auth.uid()),
          public.lwb_acc_shift_name(auth.uid()) || ' is handing you the cash box (Rs ' || to_char(v_counted, 'FM99999999990.00')
          || '). Count it and press Received on the Cashier page.', 'ACC_SHIFT_HANDOVER');
  RETURN jsonb_build_object('id', v_id, 'counted', v_counted, 'book', round(v_book, 2));
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_receive(p_id bigint, p_amount numeric DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_acc_shift_handovers%ROWTYPE; v_amt numeric; v_note text := nullif(btrim(coalesce(p_note,'')),'');
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  SELECT * INTO h FROM public.lwb_acc_shift_handovers WHERE id = p_id FOR UPDATE;
  IF h.id IS NULL OR h.status <> 'PENDING' THEN RAISE EXCEPTION 'This handover is not waiting any more'; END IF;
  IF h.given_to <> auth.uid() AND NOT public.lwb_acc_admin() THEN
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

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_cancel(p_id bigint, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_acc_shift_handovers%ROWTYPE;
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  SELECT * INTO h FROM public.lwb_acc_shift_handovers WHERE id = p_id FOR UPDATE;
  IF h.id IS NULL OR h.status <> 'PENDING' THEN RAISE EXCEPTION 'This handover is not waiting any more'; END IF;
  IF h.given_by <> auth.uid() AND NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only the person who handed it (or Admin) can cancel'; END IF;
  UPDATE public.lwb_acc_shift_handovers SET status = 'CANCELLED', cancelled_by = auth.uid(), cancelled_at = now(),
    receive_note = nullif(btrim(coalesce(p_note,'')),'') WHERE id = p_id;
  UPDATE public.erp_notifications SET is_read = true
  WHERE user_id = h.given_to AND notification_type = 'ACC_SHIFT_HANDOVER' AND is_read = false;
  RETURN jsonb_build_object('ok', true);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_list(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_from date := coalesce(p_from, public.lwb_acc_today()); v_to date := coalesce(p_to, public.lwb_acc_today());
  r jsonb;
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  WITH x AS (
    SELECT h.*, public.lwb_acc_shift_name(h.given_by) AS by_name, public.lwb_acc_shift_name(h.given_to) AS to_name,
           (h.given_at AT TIME ZONE 'Asia/Kolkata')::date AS day
    FROM public.lwb_acc_shift_handovers h)
  SELECT jsonb_build_object(
    'me', auth.uid(),
    'is_admin', public.lwb_acc_admin(),
    'holder', (SELECT jsonb_build_object('id', x.given_to, 'name', x.to_name, 'since', x.received_at, 'amount', x.received_amount)
               FROM x WHERE x.status = 'RECEIVED' ORDER BY x.received_at DESC LIMIT 1),
    'pending', (SELECT jsonb_build_object('id', x.id, 'by', x.given_by, 'by_name', x.by_name, 'to', x.given_to, 'to_name', x.to_name,
                  'at', x.given_at, 'counted', x.counted, 'book', x.book_cash, 'note', x.note)
                FROM x WHERE x.status = 'PENDING' LIMIT 1),
    'rows', coalesce((SELECT jsonb_agg(jsonb_build_object('id', x.id, 'day', x.day, 'at', x.given_at, 'by_name', x.by_name,
                  'to_name', x.to_name, 'book', x.book_cash, 'counted', x.counted, 'notes', x.counted_notes, 'note', x.note,
                  'status', x.status, 'received', x.received_amount, 'received_at', x.received_at, 'receive_note', x.receive_note,
                  'cancelled_at', x.cancelled_at) ORDER BY x.given_at DESC)
              FROM x WHERE x.day BETWEEN v_from AND v_to), '[]'::jsonb))
  INTO r;
  RETURN r;
END
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_shift_ok(uuid), public.lwb_acc_shift_name(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_acc_shift_people(), public.lwb_acc_shift_give(uuid,jsonb,text),
  public.lwb_acc_shift_receive(bigint,numeric,text), public.lwb_acc_shift_cancel(bigint,text), public.lwb_acc_shift_list(date,date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_shift_people(), public.lwb_acc_shift_give(uuid,jsonb,text),
  public.lwb_acc_shift_receive(bigint,numeric,text), public.lwb_acc_shift_cancel(bigint,text), public.lwb_acc_shift_list(date,date)
  TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'shift handover table' AS item, (to_regclass('public.lwb_acc_shift_handovers') IS NOT NULL)::text AS ok
UNION ALL SELECT 'give', (to_regprocedure('public.lwb_acc_shift_give(uuid,jsonb,text)') IS NOT NULL)::text
UNION ALL SELECT 'list', (to_regprocedure('public.lwb_acc_shift_list(date,date)') IS NOT NULL)::text;
