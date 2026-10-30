-- LUXURY WRIST BRAND ERP — ACCOUNTS DASHBOARD: CHEQUE REGISTER + CHEQUE REMINDERS
--
-- Runs by itself when merged to main (after lwb_accounts_vehicle_setup.sql). Safe to run again.
-- Nothing is dropped or deleted.
--
-- Mohit asked (30 Oct 2026): for every cheque keep the cheque date and a photo; know which cheques are
-- still in hand (to deposit), which are deposited but not yet in the bank, cleared or bounced; and remind
-- Sales Head, Accounts and Admin until each cheque is in the bank.
--
-- Every Cash In line with mode CHEQUE (Cash In entry, Payment Collection, Party payment, driver cheque)
-- gets a row here when its details are added or it is deposited. Status:
--   IN_HAND   no deposit yet (cheque date in the future = post-dated)
--   DEPOSITED deposited in our bank, waiting for Admin's bank check
--   CLEARED   Admin verified it in the bank (lwb_acc_verify VERIFIED)
--   BOUNCED   Admin marked it not in bank (lwb_acc_verify REJECTED)

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_acc_cheques (
  src             text NOT NULL,
  src_id          uuid NOT NULL,
  cheque_no       text CHECK (cheque_no IS NULL OR length(cheque_no) <= 30),
  cheque_date     date,
  drawn_on        text CHECK (drawn_on IS NULL OR length(drawn_on) <= 80),
  photo_paths     text[] NOT NULL DEFAULT '{}',
  note            text CHECK (note IS NULL OR length(note) <= 300),
  deposited_on    date,
  deposit_bank_id bigint REFERENCES public.lwb_acc_banks(id),
  deposited_by    uuid,
  deposited_at    timestamptz,
  updated_by      uuid,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (src, src_id)
);
ALTER TABLE public.lwb_acc_cheques ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_acc_cheques FROM PUBLIC, anon, authenticated;

-- All cheque lines with their details and status (internal).
CREATE OR REPLACE FUNCTION public.lwb_acc_cheque_rows()
RETURNS TABLE (src text, id uuid, book_date date, at timestamptz, amount numeric, party text, order_no text,
               cheque_no text, cheque_date date, drawn_on text, photos text[], note text,
               deposited_on date, deposit_bank_id bigint, status text, verify_note text, verified_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT l.src, l.id, l.book_date, l.at, l.amount, l.party, l.order_no,
         coalesce(c.cheque_no, l.ref), coalesce(c.cheque_date, l.book_date), c.drawn_on, coalesce(c.photo_paths, '{}'), c.note,
         c.deposited_on, c.deposit_bank_id,
         CASE WHEN v.status = 'VERIFIED' THEN 'CLEARED' WHEN v.status = 'REJECTED' THEN 'BOUNCED'
              WHEN c.deposited_on IS NOT NULL THEN 'DEPOSITED' ELSE 'IN_HAND' END,
         v.note, v.verified_at
  FROM public.lwb_acc_lines() l
  LEFT JOIN public.lwb_acc_cheques c ON c.src = l.src AND c.src_id = l.id
  LEFT JOIN public.lwb_acc_verify v ON v.src = l.src AND v.src_id = l.id
  WHERE l.kind = 'IN' AND l.mode = 'CHEQUE';
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_cheque_rows() FROM PUBLIC, anon, authenticated;

-- Cheques tab: every cheque not yet cleared + cleared / bounced ones of the last 60 days.
CREATE OR REPLACE FUNCTION public.lwb_acc_cheque_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts Dashboard is for active Accounts or Admin only'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('src', r.src, 'id', r.id, 'date', r.book_date, 'at', r.at, 'amount', r.amount,
      'party', r.party, 'order_no', r.order_no, 'cheque_no', r.cheque_no, 'cheque_date', r.cheque_date, 'drawn_on', r.drawn_on,
      'photos', to_jsonb(r.photos), 'note', r.note, 'deposited_on', r.deposited_on, 'deposit_bank_id', r.deposit_bank_id,
      'status', r.status, 'verify_note', r.verify_note, 'verified_at', r.verified_at)
      ORDER BY CASE r.status WHEN 'IN_HAND' THEN 1 WHEN 'DEPOSITED' THEN 2 WHEN 'BOUNCED' THEN 3 ELSE 4 END, r.cheque_date, r.at)
    FROM public.lwb_acc_cheque_rows() r
    WHERE r.status IN ('IN_HAND','DEPOSITED') OR r.verified_at > now() - interval '60 days'), '[]'::jsonb);
END;
$fn$;

-- Cheque no., cheque date, party's bank, photos (camera / gallery; up to 5), note.
-- p: {"src":"ENTRY","id":"<uuid>","cheque_no":"004512","cheque_date":"2026-11-05","drawn_on":"SBI Udhna","photos":[...],"note":""}
CREATE OR REPLACE FUNCTION public.lwb_acc_save_cheque(p jsonb)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r record; v_old text[]; v_photos text[] := '{}'; v_x text; v_date date; v_no text;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts Dashboard is for active Accounts or Admin only'; END IF;
  SELECT * INTO r FROM public.lwb_acc_cheque_rows() x WHERE x.src = p->>'src' AND x.id::text = p->>'id';
  IF r.id IS NULL THEN RAISE EXCEPTION 'Cheque not found'; END IF;
  IF r.status = 'CLEARED' AND NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'This cheque is already cleared; only Admin can change it'; END IF;
  BEGIN v_date := nullif(p->>'cheque_date','')::date;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Enter the cheque date as DD/MM/YYYY';
  END;
  IF v_date IS NOT NULL AND (v_date < r.book_date - 200 OR v_date > r.book_date + 200) THEN
    RAISE EXCEPTION 'Check the cheque date';
  END IF;
  v_no := nullif(btrim(coalesce(p->>'cheque_no','')),'');
  IF v_no IS NOT NULL AND v_no !~ '^[0-9A-Za-z/-]{1,30}$' THEN RAISE EXCEPTION 'Cheque no.: only numbers / letters'; END IF;
  SELECT c.photo_paths INTO v_old FROM public.lwb_acc_cheques c WHERE c.src = r.src AND c.src_id = r.id;
  IF jsonb_typeof(p->'photos') = 'array' THEN
    FOR v_x IN SELECT jsonb_array_elements_text(p->'photos') LOOP
      IF NOT (v_x = ANY (coalesce(v_old,'{}')) OR v_x ~ ('^' || auth.uid()::text || '/[A-Za-z0-9_.-]{1,80}$')) THEN
        RAISE EXCEPTION 'Bad photo';
      END IF;
      v_photos := v_photos || v_x;
    END LOOP;
  ELSE v_photos := coalesce(v_old,'{}');
  END IF;
  IF cardinality(v_photos) > 5 THEN RAISE EXCEPTION 'Up to 5 photos'; END IF;

  INSERT INTO public.lwb_acc_cheques (src, src_id, cheque_no, cheque_date, drawn_on, photo_paths, note, updated_by, updated_at)
  VALUES (r.src, r.id, v_no, v_date, left(nullif(btrim(coalesce(p->>'drawn_on','')),''),80), v_photos,
          left(nullif(btrim(coalesce(p->>'note','')),''),300), auth.uid(), now())
  ON CONFLICT (src, src_id) DO UPDATE SET cheque_no = EXCLUDED.cheque_no, cheque_date = EXCLUDED.cheque_date,
    drawn_on = EXCLUDED.drawn_on, photo_paths = EXCLUDED.photo_paths, note = EXCLUDED.note,
    updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at;
  RETURN 'saved';
END;
$fn$;

-- Deposited in our bank (slip / CDM). Admin then sees it in Bank check and marks Cleared or Bounced.
CREATE OR REPLACE FUNCTION public.lwb_acc_cheque_deposit(p_src text, p_id uuid, p_bank_id bigint, p_date date)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r record;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts Dashboard is for active Accounts or Admin only'; END IF;
  SELECT * INTO r FROM public.lwb_acc_cheque_rows() x WHERE x.src = p_src AND x.id = p_id;
  IF r.id IS NULL THEN RAISE EXCEPTION 'Cheque not found'; END IF;
  IF r.status IN ('CLEARED','BOUNCED') THEN RAISE EXCEPTION 'This cheque is already %', lower(r.status); END IF;
  IF p_bank_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.lwb_acc_banks b WHERE b.id = p_bank_id AND b.active) THEN
    RAISE EXCEPTION 'Choose our bank where the cheque was deposited';
  END IF;
  IF p_date IS NULL OR p_date > public.lwb_acc_today() THEN RAISE EXCEPTION 'Deposit date can not be in the future'; END IF;
  IF p_date < r.book_date - 7 THEN RAISE EXCEPTION 'Deposit date is before the cheque came'; END IF;
  INSERT INTO public.lwb_acc_cheques (src, src_id, deposited_on, deposit_bank_id, deposited_by, deposited_at, updated_by, updated_at)
  VALUES (r.src, r.id, p_date, p_bank_id, auth.uid(), now(), auth.uid(), now())
  ON CONFLICT (src, src_id) DO UPDATE SET deposited_on = EXCLUDED.deposited_on, deposit_bank_id = EXCLUDED.deposit_bank_id,
    deposited_by = EXCLUDED.deposited_by, deposited_at = EXCLUDED.deposited_at, updated_by = EXCLUDED.updated_by, updated_at = EXCLUDED.updated_at;
  RETURN 'deposited';
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_cheque_undeposit(p_src text, p_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r record;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts Dashboard is for active Accounts or Admin only'; END IF;
  SELECT * INTO r FROM public.lwb_acc_cheque_rows() x WHERE x.src = p_src AND x.id = p_id;
  IF r.id IS NULL OR r.status <> 'DEPOSITED' THEN RAISE EXCEPTION 'Only a deposited cheque not yet checked by Admin can be undone'; END IF;
  UPDATE public.lwb_acc_cheques SET deposited_on = NULL, deposit_bank_id = NULL, deposited_by = NULL, deposited_at = NULL,
    updated_by = auth.uid(), updated_at = now()
  WHERE src = p_src AND src_id = p_id;
  RETURN 'back in hand';
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Reminder to Admin, Accounts and Sales Head (manager): cheques to deposit (cheque date reached) and
-- cheques deposited but not yet in the bank. Old unread reminders are closed so the bell shows one.
-- Runs 10:00 and 18:00 India time (pg_cron), and from the Cheques tab ("Send reminder now").
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_cheque_remind_internal()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_today date := public.lwb_acc_today();
  v_hn int; v_ha numeric; v_dn int; v_da numeric; v_pn int; v_top text; v_msg text; v_title text; v_sent int := 0; u record;
BEGIN
  SELECT count(*) FILTER (WHERE status = 'IN_HAND' AND cheque_date <= v_today),
         coalesce(sum(amount) FILTER (WHERE status = 'IN_HAND' AND cheque_date <= v_today),0),
         count(*) FILTER (WHERE status = 'DEPOSITED'),
         coalesce(sum(amount) FILTER (WHERE status = 'DEPOSITED'),0),
         count(*) FILTER (WHERE status = 'IN_HAND' AND cheque_date > v_today)
    INTO v_hn, v_ha, v_dn, v_da, v_pn
  FROM public.lwb_acc_cheque_rows();

  UPDATE public.erp_notifications SET is_read = true WHERE notification_type = 'ACC_CHEQUE_REMINDER' AND is_read = false;
  IF v_hn + v_dn = 0 THEN RETURN 0; END IF;

  SELECT string_agg(x.t, '; ') INTO v_top FROM (
    SELECT coalesce(r.party,'?') || ' Rs ' || to_char(r.amount,'FM99999999990') || ' (' || to_char(r.cheque_date,'DD/MM/YYYY')
           || CASE r.status WHEN 'DEPOSITED' THEN ', deposited ' || to_char(r.deposited_on,'DD/MM') ELSE ', in hand' END || ')' AS t
    FROM public.lwb_acc_cheque_rows() r
    WHERE (r.status = 'IN_HAND' AND r.cheque_date <= v_today) OR r.status = 'DEPOSITED'
    ORDER BY r.cheque_date, r.at LIMIT 3) x;

  v_title := 'Cheques: ' || (v_hn + v_dn) || ' pending · Rs ' || to_char(v_ha + v_da,'FM99999999990');
  v_msg := concat_ws(' ',
    CASE WHEN v_hn > 0 THEN 'To deposit: ' || v_hn || ' (Rs ' || to_char(v_ha,'FM99999999990') || ').' END,
    CASE WHEN v_dn > 0 THEN 'Deposited, not yet in bank: ' || v_dn || ' (Rs ' || to_char(v_da,'FM99999999990') || ').' END,
    CASE WHEN v_pn > 0 THEN 'Post-dated: ' || v_pn || '.' END,
    'Oldest: ' || v_top || '.');
  FOR u IN SELECT p.id FROM public.user_profiles p
           WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','accounts','manager') LOOP
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type) VALUES (u.id, v_title, left(v_msg, 900), 'ACC_CHEQUE_REMINDER');
    v_sent := v_sent + 1;
  END LOOP;
  RETURN v_sent;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_acc_cheque_remind_internal() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_acc_cheque_remind_now()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts Dashboard is for active Accounts or Admin only'; END IF;
  RETURN public.lwb_acc_cheque_remind_internal();
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_cheque_list(), public.lwb_acc_save_cheque(jsonb), public.lwb_acc_cheque_deposit(text,uuid,bigint,date),
  public.lwb_acc_cheque_undeposit(text,uuid), public.lwb_acc_cheque_remind_now() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_cheque_list(), public.lwb_acc_save_cheque(jsonb), public.lwb_acc_cheque_deposit(text,uuid,bigint,date),
  public.lwb_acc_cheque_undeposit(text,uuid), public.lwb_acc_cheque_remind_now() TO authenticated;

COMMIT;

-- 10:00 and 18:00 India time (04:30 and 12:30 UTC), only where pg_cron is on.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'lwb_acc_cheque_reminder';
    PERFORM cron.schedule('lwb_acc_cheque_reminder', '30 4,12 * * *', 'SELECT public.lwb_acc_cheque_remind_internal()');
  END IF;
END
$cron$;

NOTIFY pgrst, 'reload schema';

SELECT 'cheque register' AS item, (to_regclass('public.lwb_acc_cheques') IS NOT NULL)::text AS ok
UNION ALL SELECT 'cheque reminder job', coalesce((SELECT 'scheduled' FROM pg_extension WHERE extname = 'pg_cron'), 'pg_cron off: use Send reminder now');
