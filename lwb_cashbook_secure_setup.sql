-- LUXURY WRIST BRAND ERP — CASHBOOK HISTORY + SECRET LINK, TALLY QUERIES
--
-- RUN ONCE in Supabase SQL Editor (after lwb_cashbook_tally_check_setup.sql and
-- lwb_cashbook_driver_cash_setup.sql). Safe to run again.
--
-- 1. Cashbook history: every save is compared with the data before it, in the database.
--    Each added / changed / verified / deleted entry and each added / deleted book is written
--    to lwb_cashbook_audit with the ERP login, time, old and new values. Logins cannot read,
--    change or delete that table directly; the Cashbook page reads it through
--    lwb_cashbook_history only.
-- 2. Secret link: once Admin creates the link (Cashbook > Secret link), every Cashbook function
--    also needs the key from that link. Without it the Cashbook answers nothing, even for Admin.
--    Only a SHA-256 of the key is stored.
-- 3. Tally queries: each "PO but no Tally bill", "Tally bill but no PO" and "amount differs"
--    found by Tally Bill Check stays as an open query until it matches in a later check or
--    Admin closes it. Accounts writes the reason.
--
-- No order, stock, bill, payment or ledger data is changed.

BEGIN;

ALTER TABLE public.lwb_cashbook ADD COLUMN IF NOT EXISTS link_key_hash text;

-- ---------------------------------------------------------------------------
-- 1. HISTORY
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_cashbook_audit (
  id         bigserial PRIMARY KEY,
  at         timestamptz NOT NULL DEFAULT now(),
  by_user    uuid,
  by_name    text,
  action     text NOT NULL,
  book_id    text,
  book_name  text,
  entry_id   text,
  entry_type text,
  party      text,
  amount     numeric,
  entry_date text,
  changed    text[],
  before     jsonb,
  after      jsonb
);
CREATE INDEX IF NOT EXISTS lwb_cashbook_audit_entry_idx ON public.lwb_cashbook_audit (entry_id, id DESC);
CREATE INDEX IF NOT EXISTS lwb_cashbook_audit_at_idx ON public.lwb_cashbook_audit (id DESC);
ALTER TABLE public.lwb_cashbook_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_cashbook_audit FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_cashbook_audit_id_seq FROM PUBLIC, anon, authenticated;

-- old Cashbook data vs new Cashbook data -> history rows
CREATE OR REPLACE FUNCTION public.lwb_cashbook_audit_diff(p_old jsonb, p_new jsonb, p_note text DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_name text := (SELECT nullif(btrim(p.full_name), '') FROM public.user_profiles p WHERE p.id = auth.uid());
  v_n integer;
BEGIN
  WITH
  pn AS (
    SELECT x ->> 'id' AS id, x ->> 'name' AS name
    FROM jsonb_array_elements(coalesce(p_new -> 'parties', '[]'::jsonb) || coalesce(p_old -> 'parties', '[]'::jsonb)) x
  ),
  ob AS (SELECT b ->> 'id' AS bid, b ->> 'name' AS bname, b FROM jsonb_array_elements(coalesce(p_old -> 'books', '[]'::jsonb)) b),
  nb AS (SELECT b ->> 'id' AS bid, b ->> 'name' AS bname, b FROM jsonb_array_elements(coalesce(p_new -> 'books', '[]'::jsonb)) b),
  oe AS (SELECT ob.bid, ob.bname, e ->> 'id' AS eid, e FROM ob, jsonb_array_elements(coalesce(ob.b -> 'entries', '[]'::jsonb)) e),
  ne AS (SELECT nb.bid, nb.bname, e ->> 'id' AS eid, e FROM nb, jsonb_array_elements(coalesce(nb.b -> 'entries', '[]'::jsonb)) e),
  d AS (
    SELECT coalesce(ne.bid, oe.bid) AS bid, coalesce(ne.bname, oe.bname) AS bname, coalesce(ne.eid, oe.eid) AS eid,
           oe.e AS old_e, ne.e AS new_e,
           ARRAY(SELECT k FROM (SELECT jsonb_object_keys(coalesce(oe.e, '{}'::jsonb)) UNION SELECT jsonb_object_keys(coalesce(ne.e, '{}'::jsonb))) s(k)
                 WHERE k NOT IN ('updated') AND (oe.e -> k) IS DISTINCT FROM (ne.e -> k)
                   -- an empty box saved as "", 0 or false where nothing was before is not a change
                   AND NOT (coalesce((oe.e -> k)::text, 'null') IN ('null', '""', '0', 'false')
                        AND coalesce((ne.e -> k)::text, 'null') IN ('null', '""', '0', 'false'))
                 ORDER BY k) AS keys
    FROM oe FULL JOIN ne ON ne.eid = oe.eid
    WHERE oe.e IS DISTINCT FROM ne.e
  ),
  rows AS (
    SELECT
      CASE
        WHEN d.old_e IS NULL THEN 'added'
        WHEN d.new_e IS NULL THEN 'deleted'
        WHEN d.keys <@ ARRAY['verified','verifiedAt','flag'] AND (d.new_e ->> 'verified') = 'true' AND (d.old_e ->> 'verified') IS DISTINCT FROM 'true' THEN 'verified'
        WHEN d.keys <@ ARRAY['flag'] THEN 'reported'
        WHEN d.keys <@ ARRAY['req'] AND d.new_e ? 'req' THEN 'change requested'
        WHEN d.keys <@ ARRAY['req','reqDone'] AND NOT d.new_e ? 'req' AND (d.new_e -> 'reqDone' ->> 'ok') = 'false' THEN 'request rejected'
        ELSE 'changed'
      END AS action,
      d.*
    FROM d
    WHERE cardinality(d.keys) > 0
  ),
  books AS (
    SELECT CASE WHEN ob.bid IS NULL THEN 'book added' ELSE 'book deleted' END AS action,
           coalesce(nb.bid, ob.bid) AS bid, coalesce(nb.bname, ob.bname) AS bname,
           jsonb_array_length(coalesce(coalesce(ob.b, nb.b) -> 'entries', '[]'::jsonb)) AS n
    FROM ob FULL JOIN nb ON nb.bid = ob.bid
    WHERE ob.bid IS NULL OR nb.bid IS NULL
  ),
  ins AS (
    INSERT INTO public.lwb_cashbook_audit (by_user, by_name, action, book_id, book_name, entry_id, entry_type, party, amount, entry_date, changed, before, after)
    SELECT auth.uid(), v_name, r.action, r.bid, r.bname, r.eid,
           coalesce(r.new_e, r.old_e) ->> 'type',
           (SELECT pn.name FROM pn WHERE pn.id = coalesce(r.new_e, r.old_e) ->> 'party' LIMIT 1),
           CASE WHEN coalesce(r.new_e, r.old_e) ->> 'amount' ~ '^-?[0-9.]+$' THEN (coalesce(r.new_e, r.old_e) ->> 'amount')::numeric END,
           coalesce(r.new_e, r.old_e) ->> 'date',
           r.keys, r.old_e, r.new_e
    FROM rows r
    UNION ALL
    SELECT auth.uid(), v_name, b.action, b.bid, b.bname, NULL, NULL, NULL, NULL, NULL, ARRAY[b.n || ' entries'], NULL, NULL
    FROM books b
    UNION ALL
    SELECT auth.uid(), v_name, p_note, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    WHERE p_note IS NOT NULL
    RETURNING 1
  )
  SELECT count(*) INTO v_n FROM ins;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_cashbook_audit_diff(jsonb, jsonb, text) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. SECRET LINK — every Cashbook function now takes the link key
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_cashbook_ok(p_key text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT public.lwb_cashbook_user() AND coalesce(
    (SELECT c.link_key_hash IS NULL OR c.link_key_hash = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex')
     FROM public.lwb_cashbook c WHERE c.id = 1), true);
$fn$;
REVOKE ALL ON FUNCTION public.lwb_cashbook_ok(text) FROM PUBLIC, anon, authenticated;

-- the versions without a key are removed, so nothing opens without it
DROP FUNCTION IF EXISTS public.lwb_cashbook_load();
DROP FUNCTION IF EXISTS public.lwb_cashbook_version();
DROP FUNCTION IF EXISTS public.lwb_cashbook_save(jsonb, bigint);
DROP FUNCTION IF EXISTS public.lwb_cashbook_copies_list();
DROP FUNCTION IF EXISTS public.lwb_cashbook_restore(bigint);
DROP FUNCTION IF EXISTS public.lwb_cashbook_driver_cash(integer);

CREATE OR REPLACE FUNCTION public.lwb_cashbook_load(p_key text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v public.lwb_cashbook%ROWTYPE;
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  SELECT * INTO v FROM public.lwb_cashbook WHERE id = 1;
  RETURN jsonb_build_object(
    'data', coalesce(v.data, '{"books":[]}'::jsonb),
    'version', coalesce(v.version, 0),
    'erp_admin', public.lwb_cashbook_erp_admin(),
    'has_link', v.link_key_hash IS NOT NULL,
    'name', (SELECT coalesce(nullif(btrim(p.full_name), ''), 'User') FROM public.user_profiles p WHERE p.id = auth.uid()));
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_cashbook_version(p_key text)
RETURNS bigint LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  RETURN coalesce((SELECT c.version FROM public.lwb_cashbook c WHERE c.id = 1), 0);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_cashbook_save(p_data jsonb, p_version bigint, p_key text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_old public.lwb_cashbook%ROWTYPE;
  v_cleared boolean;
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' OR jsonb_typeof(p_data -> 'books') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Cashbook data is damaged. Not saved.';
  END IF;
  INSERT INTO public.lwb_cashbook (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  SELECT * INTO v_old FROM public.lwb_cashbook WHERE id = 1 FOR UPDATE;
  IF v_old.version <> coalesce(p_version, -1) THEN
    RAISE EXCEPTION 'CONFLICT: the Cashbook was saved by someone else first.';
  END IF;

  v_cleared := jsonb_array_length(p_data -> 'books') = 0
    AND jsonb_array_length(coalesce(v_old.data -> 'books', '[]'::jsonb)) > 0;
  IF v_old.version > 0 AND (v_cleared OR NOT EXISTS (
       SELECT 1 FROM public.lwb_cashbook_copies c
       WHERE c.reason = 'save' AND c.saved_at > now() - interval '15 minutes')) THEN
    INSERT INTO public.lwb_cashbook_copies (version, data, reason, saved_by)
    VALUES (v_old.version, v_old.data, CASE WHEN v_cleared THEN 'cleared' ELSE 'save' END, auth.uid());
    DELETE FROM public.lwb_cashbook_copies c
    WHERE c.reason = 'save'
      AND c.id NOT IN (SELECT k.id FROM public.lwb_cashbook_copies k WHERE k.reason = 'save' ORDER BY k.id DESC LIMIT 300);
  END IF;

  PERFORM public.lwb_cashbook_audit_diff(v_old.data, p_data, NULL);

  UPDATE public.lwb_cashbook
     SET data = p_data, version = v_old.version + 1, updated_at = now(), updated_by = auth.uid()
   WHERE id = 1;
  RETURN v_old.version + 1;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_cashbook_copies_list(p_key text)
RETURNS TABLE (id bigint, saved_at timestamptz, reason text, saved_by text, books integer, entries integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) OR NOT public.lwb_cashbook_erp_admin() THEN
    RAISE EXCEPTION 'Only an ERP Admin with Cashbook access can see earlier copies.';
  END IF;
  RETURN QUERY
  SELECT c.id, c.saved_at, c.reason,
         coalesce(nullif(btrim(p.full_name), ''), '—'),
         jsonb_array_length(coalesce(c.data -> 'books', '[]'::jsonb)),
         coalesce((SELECT sum(jsonb_array_length(coalesce(b -> 'entries', '[]'::jsonb)))::integer
                   FROM jsonb_array_elements(coalesce(c.data -> 'books', '[]'::jsonb)) b), 0)
  FROM public.lwb_cashbook_copies c
  LEFT JOIN public.user_profiles p ON p.id = c.saved_by
  ORDER BY c.id DESC
  LIMIT 200;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_cashbook_restore(p_copy_id bigint, p_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_copy public.lwb_cashbook_copies%ROWTYPE;
  v_old public.lwb_cashbook%ROWTYPE;
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) OR NOT public.lwb_cashbook_erp_admin() THEN
    RAISE EXCEPTION 'Only an ERP Admin with Cashbook access can restore a copy.';
  END IF;
  SELECT * INTO v_copy FROM public.lwb_cashbook_copies WHERE id = p_copy_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Copy not found.';
  END IF;
  INSERT INTO public.lwb_cashbook (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  SELECT * INTO v_old FROM public.lwb_cashbook WHERE id = 1 FOR UPDATE;
  IF v_old.version > 0 THEN
    INSERT INTO public.lwb_cashbook_copies (version, data, reason, saved_by)
    VALUES (v_old.version, v_old.data, 'before restore', auth.uid());
  END IF;
  PERFORM public.lwb_cashbook_audit_diff(v_old.data, v_copy.data, 'restored copy of ' || to_char(v_copy.saved_at AT TIME ZONE 'Asia/Kolkata', 'DD-MM HH24:MI'));
  UPDATE public.lwb_cashbook
     SET data = v_copy.data, version = v_old.version + 1, updated_at = now(), updated_by = auth.uid()
   WHERE id = 1;
  RETURN jsonb_build_object('data', v_copy.data, 'version', v_old.version + 1);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_cashbook_driver_cash(p_days integer, p_key text)
RETURNS TABLE (report_id uuid, report_date date, report_time text, order_no text, party text,
               driver text, amount numeric, mode text, reference text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  RETURN QUERY
  SELECT dr.id,
         timezone('Asia/Kolkata', dr.reported_at)::date,
         to_char(timezone('Asia/Kolkata', dr.reported_at), 'HH24:MI'),
         o.order_no::text,
         btrim(o.customer_name::text),
         coalesce(nullif(btrim(a.driver_name::text), ''), nullif(btrim(p.full_name), ''), 'Driver'),
         dr.cash_reported,
         coalesce(dr.payment_mode, 'CASH'),
         coalesce(dr.payment_reference, '')
  FROM public.lwb_delivery_reports dr
  JOIN public.orders o ON o.id = dr.order_id
  LEFT JOIN public.dispatch_assignments a ON a.id = dr.assignment_id
  LEFT JOIN public.user_profiles p ON p.id = dr.driver_user_id
  WHERE dr.cash_reported > 0
    AND dr.reported_at >= now() - make_interval(days => least(greatest(coalesce(p_days, 15), 1), 90))
  ORDER BY dr.reported_at DESC;
END;
$fn$;

-- history for the Cashbook page: optional party name, entry id, newest first
CREATE OR REPLACE FUNCTION public.lwb_cashbook_history(p_key text, p_party text DEFAULT NULL, p_entry text DEFAULT NULL, p_limit integer DEFAULT 500)
RETURNS TABLE (id bigint, at timestamptz, by_name text, action text, book_name text, entry_id text, entry_type text,
               party text, amount numeric, entry_date text, changed text[], before jsonb, after jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) THEN
    RAISE EXCEPTION 'NO_ACCESS: Cashbook is private.';
  END IF;
  RETURN QUERY
  SELECT a.id, a.at, coalesce(a.by_name, '—'), a.action, a.book_name, a.entry_id, a.entry_type,
         a.party, a.amount, a.entry_date, a.changed, a.before, a.after
  FROM public.lwb_cashbook_audit a
  WHERE (p_entry IS NULL OR a.entry_id = p_entry)
    AND (nullif(btrim(coalesce(p_party, '')), '') IS NULL OR a.party = p_party)
  ORDER BY a.id DESC
  LIMIT least(greatest(coalesce(p_limit, 500), 1), 5000);
END;
$fn$;

-- Admin creates or changes the secret link. p_key = the key of the link in use now
-- (anything while no link exists), p_new_key = new random key from the page.
CREATE OR REPLACE FUNCTION public.lwb_cashbook_set_link(p_key text, p_new_key text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_cashbook_ok(p_key) OR NOT public.lwb_cashbook_erp_admin() THEN
    RAISE EXCEPTION 'Only an ERP Admin inside the Cashbook can change the secret link.';
  END IF;
  IF length(coalesce(p_new_key, '')) < 20 THEN
    RAISE EXCEPTION 'The link key is too short.';
  END IF;
  INSERT INTO public.lwb_cashbook (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
  UPDATE public.lwb_cashbook SET link_key_hash = encode(sha256(convert_to(p_new_key, 'UTF8')), 'hex') WHERE id = 1;
  INSERT INTO public.lwb_cashbook_audit (by_user, by_name, action)
  VALUES (auth.uid(), (SELECT nullif(btrim(p.full_name), '') FROM public.user_profiles p WHERE p.id = auth.uid()), 'secret link changed');
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_cashbook_load(text), public.lwb_cashbook_version(text), public.lwb_cashbook_save(jsonb, bigint, text),
  public.lwb_cashbook_copies_list(text), public.lwb_cashbook_restore(bigint, text), public.lwb_cashbook_driver_cash(integer, text),
  public.lwb_cashbook_history(text, text, text, integer), public.lwb_cashbook_set_link(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_cashbook_load(text), public.lwb_cashbook_version(text), public.lwb_cashbook_save(jsonb, bigint, text),
  public.lwb_cashbook_copies_list(text), public.lwb_cashbook_restore(bigint, text), public.lwb_cashbook_driver_cash(integer, text),
  public.lwb_cashbook_history(text, text, text, integer), public.lwb_cashbook_set_link(text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. TALLY QUERIES
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lwb_tally_queries (
  id           bigserial PRIMARY KEY,
  qkey         text NOT NULL UNIQUE,
  kind         text NOT NULL CHECK (kind IN ('no_tally','no_po','amount')),
  qdate        date,
  party        text,
  order_nos    text,
  tally_bills  text,
  erp_amount   numeric,
  tally_amount numeric,
  status       text NOT NULL DEFAULT 'open' CHECK (status IN ('open','answered','closed')),
  reason       text,
  answered_by  uuid,
  answered_at  timestamptz,
  closed_by    uuid,
  closed_at    timestamptz,
  close_note   text,
  first_seen   timestamptz NOT NULL DEFAULT now(),
  last_seen    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_tally_queries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_tally_queries FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_tally_queries_id_seq FROM PUBLIC, anon, authenticated;

-- After a check: p_items = the mismatches found now [{qkey, kind, qdate, party, order_nos, tally_bills, erp_amount, tally_amount}].
-- New ones are added, known ones updated (a closed query reopens only if it shows again after Admin closed it
-- by "matched"). Open / answered queries dated inside p_from..p_to that are not found any more are closed as matched.
CREATE OR REPLACE FUNCTION public.lwb_tally_queries_sync(p_from date, p_to date, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_new integer; v_closed integer;
BEGIN
  IF NOT public.lwb_tally_check_user() THEN
    RAISE EXCEPTION 'Active Admin / Accounts role required.';
  END IF;
  WITH i AS (
    SELECT x ->> 'qkey' AS qkey, x ->> 'kind' AS kind, nullif(x ->> 'qdate', '')::date AS qdate, x ->> 'party' AS party,
           x ->> 'order_nos' AS order_nos, x ->> 'tally_bills' AS tally_bills,
           nullif(x ->> 'erp_amount', '')::numeric AS erp_amount, nullif(x ->> 'tally_amount', '')::numeric AS tally_amount
    FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x
    WHERE x ->> 'kind' IN ('no_tally','no_po','amount') AND nullif(x ->> 'qkey', '') IS NOT NULL
  ), up AS (
    INSERT INTO public.lwb_tally_queries AS q (qkey, kind, qdate, party, order_nos, tally_bills, erp_amount, tally_amount)
    SELECT * FROM i
    ON CONFLICT (qkey) DO UPDATE
      SET kind = excluded.kind, qdate = excluded.qdate, party = excluded.party, order_nos = excluded.order_nos,
          tally_bills = excluded.tally_bills, erp_amount = excluded.erp_amount, tally_amount = excluded.tally_amount, last_seen = now(),
          status = CASE WHEN q.status = 'closed' AND q.close_note LIKE 'Matched%' THEN 'open' ELSE q.status END,
          closed_at = CASE WHEN q.status = 'closed' AND q.close_note LIKE 'Matched%' THEN NULL ELSE q.closed_at END,
          close_note = CASE WHEN q.status = 'closed' AND q.close_note LIKE 'Matched%' THEN NULL ELSE q.close_note END
    RETURNING (xmax = 0) AS inserted
  )
  SELECT count(*) FILTER (WHERE inserted) INTO v_new FROM up;

  UPDATE public.lwb_tally_queries q
     SET status = 'closed', closed_at = now(), closed_by = auth.uid(),
         close_note = 'Matched in the check of ' || to_char(now() AT TIME ZONE 'Asia/Kolkata', 'DD-MM-YYYY HH24:MI')
   WHERE q.status <> 'closed' AND q.qdate BETWEEN p_from AND p_to
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x WHERE x ->> 'qkey' = q.qkey);
  GET DIAGNOSTICS v_closed = ROW_COUNT;
  RETURN jsonb_build_object('new', v_new, 'closed', v_closed);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_tally_queries_list(p_all boolean DEFAULT false)
RETURNS TABLE (id bigint, kind text, qdate date, party text, order_nos text, tally_bills text, erp_amount numeric, tally_amount numeric,
               status text, reason text, answered_by text, answered_at timestamptz, closed_by text, closed_at timestamptz, close_note text,
               first_seen timestamptz, last_seen timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_check_user() THEN
    RAISE EXCEPTION 'Active Admin / Accounts role required.';
  END IF;
  RETURN QUERY
  SELECT q.id, q.kind, q.qdate, q.party, q.order_nos, q.tally_bills, q.erp_amount, q.tally_amount, q.status, q.reason,
         pa.full_name, q.answered_at, pc.full_name, q.closed_at, q.close_note, q.first_seen, q.last_seen
  FROM public.lwb_tally_queries q
  LEFT JOIN public.user_profiles pa ON pa.id = q.answered_by
  LEFT JOIN public.user_profiles pc ON pc.id = q.closed_by
  WHERE p_all OR q.status <> 'closed' OR q.closed_at > now() - interval '7 days'
  ORDER BY (q.status = 'closed'), q.qdate DESC NULLS LAST, q.id DESC
  LIMIT 2000;
END;
$fn$;

-- Accounts / Admin: write why (reason). Admin: p_close = true closes the query as verified.
CREATE OR REPLACE FUNCTION public.lwb_tally_query_update(p_id bigint, p_reason text, p_close boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_tally_check_user() THEN
    RAISE EXCEPTION 'Active Admin / Accounts role required.';
  END IF;
  IF p_close AND NOT public.lwb_is_admin() THEN
    RAISE EXCEPTION 'Only Admin can close a query.';
  END IF;
  UPDATE public.lwb_tally_queries q
     SET reason = coalesce(nullif(btrim(p_reason), ''), q.reason),
         status = CASE WHEN p_close THEN 'closed' WHEN nullif(btrim(p_reason), '') IS NOT NULL AND q.status = 'open' THEN 'answered' ELSE q.status END,
         answered_by = CASE WHEN nullif(btrim(p_reason), '') IS NOT NULL THEN auth.uid() ELSE q.answered_by END,
         answered_at = CASE WHEN nullif(btrim(p_reason), '') IS NOT NULL THEN now() ELSE q.answered_at END,
         closed_by = CASE WHEN p_close THEN auth.uid() ELSE q.closed_by END,
         closed_at = CASE WHEN p_close THEN now() ELSE q.closed_at END,
         close_note = CASE WHEN p_close THEN 'Verified by Admin' ELSE q.close_note END
   WHERE q.id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Query not found.';
  END IF;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_tally_queries_sync(date, date, jsonb), public.lwb_tally_queries_list(boolean),
  public.lwb_tally_query_update(bigint, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_tally_queries_sync(date, date, jsonb), public.lwb_tally_queries_list(boolean),
  public.lwb_tally_query_update(bigint, text, boolean) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: four rows. The first three must say true, the last one false.
SELECT 'cashbook history table' AS item, (to_regclass('public.lwb_cashbook_audit') IS NOT NULL)::text AS ok
UNION ALL SELECT 'tally queries table', (to_regclass('public.lwb_tally_queries') IS NOT NULL)::text
UNION ALL SELECT 'cashbook needs the link key', (to_regprocedure('public.lwb_cashbook_load(text)') IS NOT NULL)::text
UNION ALL SELECT 'old Cashbook function without key still there (must be false)', (to_regprocedure('public.lwb_cashbook_load()') IS NOT NULL)::text;
