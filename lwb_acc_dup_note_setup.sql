-- LUXURY WRIST BRAND ERP — DUPLICATE / TORN NOTE FROM A PARTY (Mohit, 26 Nov 2026)
--
-- Mohit: a party pays cash and one note is duplicate (fake) or torn. We give that note back to the party on the
-- next vehicle trip and take a good note. Until then:
--   * the party ledger / outstanding must show it is still pending ("1 duplicate ₹500 note pending");
--   * Admin and the office staff get a popup "this party gave a duplicate note";
--   * the party's next PO shows a reminder: take the note back, collect the good one on this trip;
--   * only today's cashier (the person holding the cash box) enters it;
--   * it is never in cash in hand.
--
-- How the money works: the cashier enters only the GOOD cash in the party payment (e.g. ₹9,500 of ₹10,000) and the
-- duplicate note apart (₹500). The ledger credits only the good cash, so the ₹500 stays due on the party by itself.
-- When the party gives the good note, the cashier presses "✓ Collected": a normal party payment of ₹500 is saved
-- (cash in hand +₹500, ledger −₹500) and this note is closed with that payment.
--
--   lwb_dup_notes                         one row per duplicate / torn note lot from a party
--   lwb_acc_dup_add(p jsonb)              cashier of the day: {party, company_id, kind, notes {"500":1}, receipt_id, note}
--   lwb_acc_dup_collect(id, receipt, note) cashier / Admin: closes it with the party payment of the good note
--   lwb_acc_dup_cancel(id, reason)        entered by mistake / party will never replace it: who entered it (same day) or Admin
--   lwb_acc_dup_list(days)                Accounts / Cashier / Sales Head / Admin: all rows (pending first)
--   lwb_dup_pending()                     office staff (not salesmen): pending rows with every bill name of the party (PO list / print)
--   lwb_dup_for_party(name)               any active login: pending rows of one party (New PO screen)
-- Nothing else is changed: no ledger, bill, cash book or Tally row is written by this file.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_dup_notes (
  id bigserial PRIMARY KEY,
  party text NOT NULL,                                   -- main party (lwb_party_parent)
  company_id uuid,                                       -- brand of the payment it came with
  kind text NOT NULL DEFAULT 'DUPLICATE' CHECK (kind IN ('DUPLICATE','TORN')),
  notes jsonb NOT NULL DEFAULT '{}'::jsonb,              -- {"500": 1, "100": 2}
  amount numeric(14,2) NOT NULL CHECK (amount > 0),
  day date NOT NULL,
  receipt_id uuid,                                       -- party payment it came with (optional)
  note text,
  status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','COLLECTED','CANCELLED')),
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  done_by uuid,
  done_at timestamptz,
  done_note text,
  collect_receipt_id uuid                                -- party payment of the good note
);
CREATE INDEX IF NOT EXISTS lwb_dup_notes_pending_idx ON public.lwb_dup_notes(party) WHERE status = 'PENDING';
ALTER TABLE public.lwb_dup_notes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_dup_notes FROM PUBLIC, anon, authenticated;

-- "1 × ₹500 + 2 × ₹100"
CREATE OR REPLACE FUNCTION public.lwb_dup_notes_text(p_notes jsonb)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT coalesce(string_agg(e.value || ' x Rs ' || e.key, ' + ' ORDER BY e.key::int DESC), '')
  FROM jsonb_each_text(coalesce(p_notes,'{}'::jsonb)) e;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_dup_kind_text(p_kind text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT CASE p_kind WHEN 'TORN' THEN 'torn' ELSE 'duplicate' END $fn$;

CREATE OR REPLACE FUNCTION public.lwb_dup_user_name(p_user uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT coalesce((SELECT nullif(btrim(p.full_name),'') FROM public.user_profiles p WHERE p.id = p_user), 'Someone') $fn$;

-- every bill name (Tally / Party Master name) that goes to this main party, as party keys
CREATE OR REPLACE FUNCTION public.lwb_dup_party_keys(p_party text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT to_jsonb(array_agg(DISTINCT k)) FROM (
    SELECT public.lwb_party_key(p_party) AS k
    UNION SELECT m.tally_key FROM public.lwb_tally_party_map m
      WHERE public.lwb_party_key(m.customer_name) = public.lwb_party_key(p_party)
    UNION SELECT public.lwb_party_key(m.tally_name) FROM public.lwb_tally_party_map m
      WHERE public.lwb_party_key(m.customer_name) = public.lwb_party_key(p_party)) x
  WHERE k <> '';
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_dup_row(d public.lwb_dup_notes)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT jsonb_build_object('id', d.id, 'party', d.party, 'company_id', d.company_id, 'kind', d.kind, 'notes', d.notes,
    'count', (SELECT coalesce(sum(e.value::int),0) FROM jsonb_each_text(d.notes) e),
    'notes_text', public.lwb_dup_notes_text(d.notes), 'amount', d.amount, 'day', d.day, 'receipt_id', d.receipt_id,
    'note', d.note, 'status', d.status, 'by', public.lwb_dup_user_name(d.created_by), 'at', d.created_at,
    'mine', d.created_by = auth.uid(), 'done_by', CASE WHEN d.done_by IS NOT NULL THEN public.lwb_dup_user_name(d.done_by) END,
    'done_at', d.done_at, 'done_note', d.done_note, 'collect_receipt_id', d.collect_receipt_id);
$fn$;

-- bell to Admin, Accounts, Sales Heads and Cashier logins (not the person who did it)
CREATE OR REPLACE FUNCTION public.lwb_dup_bell(p_title text, p_message text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $fn$
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
  SELECT p.id, p_title, p_message, 'DUP_NOTE'
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) IN ('admin','accounts','manager','cashier')
    AND p.id IS DISTINCT FROM auth.uid();
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_dup_add(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_party text := btrim(regexp_replace(coalesce(p->>'party',''), '\s+', ' ', 'g'));
  v_kind text := upper(btrim(coalesce(p->>'kind','DUPLICATE')));
  v_notes jsonb := '{}'::jsonb; v_amt numeric := 0; e record; v_n int; d public.lwb_dup_notes;
  v_receipt uuid := nullif(btrim(coalesce(p->>'receipt_id','')),'')::uuid;
  v_co uuid := nullif(btrim(coalesce(p->>'company_id','')),'')::uuid;
BEGIN
  IF NOT public.lwb_acc_cashier() THEN
    RAISE EXCEPTION 'Only today''s cashier (the person holding the cash box) can enter a duplicate / torn note'; END IF;
  IF v_party = '' THEN RAISE EXCEPTION 'Choose the party'; END IF;
  v_party := public.lwb_party_parent(v_party);
  IF v_kind NOT IN ('DUPLICATE','TORN') THEN RAISE EXCEPTION 'Kind must be Duplicate or Torn'; END IF;
  IF jsonb_typeof(p->'notes') IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Enter how many notes'; END IF;
  FOR e IN SELECT key, value FROM jsonb_each_text(p->'notes') LOOP
    IF e.key NOT IN ('2000','500','200','100','50','20','10') THEN RAISE EXCEPTION 'Note Rs % is not a note', e.key; END IF;
    IF e.value !~ '^\s*\d+\s*$' THEN RAISE EXCEPTION 'Count of Rs % notes must be a whole number', e.key; END IF;
    v_n := e.value::int;
    IF v_n > 0 THEN v_notes := v_notes || jsonb_build_object(e.key, v_n); v_amt := v_amt + v_n * e.key::int; END IF;
  END LOOP;
  IF v_amt <= 0 THEN RAISE EXCEPTION 'Enter how many notes'; END IF;
  IF v_amt > 50000 THEN RAISE EXCEPTION 'Duplicate notes of more than Rs 50,000? Check the count.'; END IF;
  IF v_receipt IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_tally_payments t WHERE t.receipt_id = v_receipt) THEN
    RAISE EXCEPTION 'That party payment was not found'; END IF;
  INSERT INTO public.lwb_dup_notes (party, company_id, kind, notes, amount, day, receipt_id, note, created_by)
  VALUES (v_party, v_co, v_kind, v_notes, v_amt, public.lwb_acc_today(), v_receipt,
          nullif(btrim(coalesce(p->>'note','')),''), auth.uid())
  RETURNING * INTO d;
  PERFORM public.lwb_dup_bell(
    '⚠ ' || initcap(public.lwb_dup_kind_text(v_kind)) || ' note Rs ' || to_char(v_amt, 'FM99999990') || ': ' || v_party,
    v_party || ' gave ' || public.lwb_dup_notes_text(v_notes) || ' ' || public.lwb_dup_kind_text(v_kind) || ' note' ||
    CASE WHEN (SELECT sum(x.value::int) FROM jsonb_each_text(v_notes) x) > 1 THEN 's' ELSE '' END ||
    ' (Rs ' || to_char(v_amt, 'FM99999990') || '). Entered by ' || public.lwb_dup_user_name(auth.uid()) ||
    '. Still due on the party: give the note back and collect a good one on the next trip.' || coalesce(' · ' || d.note, ''));
  RETURN public.lwb_dup_row(d);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_dup_collect(p_id bigint, p_receipt_id uuid, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE d public.lwb_dup_notes; v_got numeric;
BEGIN
  IF NOT (public.lwb_acc_cashier() OR public.lwb_acc_admin()) THEN
    RAISE EXCEPTION 'Only today''s cashier or Admin can mark it collected'; END IF;
  SELECT * INTO d FROM public.lwb_dup_notes WHERE id = p_id FOR UPDATE;
  IF d.id IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  IF d.status <> 'PENDING' THEN RAISE EXCEPTION 'This note is already %', lower(d.status); END IF;
  IF p_receipt_id IS NULL THEN RAISE EXCEPTION 'Save the party payment of the good note first'; END IF;
  SELECT sum(t.amount) INTO v_got FROM public.lwb_tally_payments t WHERE t.receipt_id = p_receipt_id AND t.cancelled_at IS NULL;
  IF v_got IS NULL THEN RAISE EXCEPTION 'That party payment was not found'; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_tally_payments t WHERE t.receipt_id = p_receipt_id
             AND public.lwb_party_key(public.lwb_party_parent(t.party)) <> public.lwb_party_key(d.party)) THEN
    RAISE EXCEPTION 'That payment is of another party'; END IF;
  UPDATE public.lwb_dup_notes SET status = 'COLLECTED', done_by = auth.uid(), done_at = now(),
    done_note = nullif(btrim(coalesce(p_note,'')),''), collect_receipt_id = p_receipt_id
  WHERE id = p_id RETURNING * INTO d;
  UPDATE public.erp_notifications n SET is_read = true
  WHERE n.notification_type = 'DUP_NOTE' AND n.is_read = false AND n.title LIKE '%: ' || d.party;
  PERFORM public.lwb_dup_bell('✓ Good note collected: ' || d.party,
    d.party || ': Rs ' || to_char(d.amount, 'FM99999990') || ' ' || public.lwb_dup_kind_text(d.kind) || ' note of ' ||
    to_char(d.day, 'DD/MM') || ' replaced. Collected by ' || public.lwb_dup_user_name(auth.uid()) || '.');
  RETURN public.lwb_dup_row(d);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_dup_cancel(p_id bigint, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE d public.lwb_dup_notes; v_why text := nullif(btrim(coalesce(p_reason,'')),'');
BEGIN
  SELECT * INTO d FROM public.lwb_dup_notes WHERE id = p_id FOR UPDATE;
  IF d.id IS NULL THEN RAISE EXCEPTION 'Not found'; END IF;
  IF d.status <> 'PENDING' THEN RAISE EXCEPTION 'This note is already %', lower(d.status); END IF;
  IF NOT (public.lwb_acc_admin() OR (d.created_by = auth.uid() AND d.day = public.lwb_acc_today())) THEN
    RAISE EXCEPTION 'Only Admin (or who entered it, the same day) can cancel'; END IF;
  IF v_why IS NULL THEN RAISE EXCEPTION 'Write why'; END IF;
  UPDATE public.lwb_dup_notes SET status = 'CANCELLED', done_by = auth.uid(), done_at = now(), done_note = v_why
  WHERE id = p_id RETURNING * INTO d;
  UPDATE public.erp_notifications n SET is_read = true
  WHERE n.notification_type = 'DUP_NOTE' AND n.is_read = false AND n.title LIKE '%: ' || d.party;
  RETURN public.lwb_dup_row(d);
END
$fn$;

-- Cashier page / ledger: Admin, Accounts, Cashier (incl. today's Sales Head cashier), Sales Heads
CREATE OR REPLACE FUNCTION public.lwb_acc_dup_list(p_days int DEFAULT 120)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT (public.lwb_acc_user() OR EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
          AND lower(btrim(p.role)) IN ('admin','accounts','manager','cashier'))) THEN
    RAISE EXCEPTION 'Admin / Accounts / Cashier / Sales Head only'; END IF;
  RETURN jsonb_build_object(
    'can_add', public.lwb_acc_cashier(), 'is_admin', public.lwb_acc_admin(), 'today', public.lwb_acc_today(),
    'rows', coalesce((SELECT jsonb_agg(public.lwb_dup_row(d) || jsonb_build_object('keys', public.lwb_dup_party_keys(d.party))
                       ORDER BY (d.status = 'PENDING') DESC, d.day DESC, d.id DESC)
                      FROM public.lwb_dup_notes d
                      WHERE d.status = 'PENDING' OR d.day >= public.lwb_acc_today() - greatest(coalesce(p_days,120),1)), '[]'::jsonb));
END
$fn$;

-- PO list / PO print: pending only, office staff (a field salesman sees it on his own party in New PO only)
CREATE OR REPLACE FUNCTION public.lwb_dup_pending()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                           AND lower(btrim(p.role)) NOT IN ('sales','driver'))
    THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id', d.id, 'party', d.party, 'kind', d.kind, 'notes', d.notes,
                     'notes_text', public.lwb_dup_notes_text(d.notes), 'amount', d.amount, 'day', d.day,
                     'keys', public.lwb_dup_party_keys(d.party)) ORDER BY d.day, d.id)
                   FROM public.lwb_dup_notes d WHERE d.status = 'PENDING'), '[]'::jsonb)
    ELSE '[]'::jsonb END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_dup_for_party(p_name text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT CASE WHEN EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true)
    THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id', d.id, 'party', d.party, 'kind', d.kind, 'notes', d.notes,
                     'notes_text', public.lwb_dup_notes_text(d.notes), 'amount', d.amount, 'day', d.day) ORDER BY d.day, d.id)
                   FROM public.lwb_dup_notes d WHERE d.status = 'PENDING'
                     AND public.lwb_party_key(d.party) = public.lwb_party_key(public.lwb_party_parent(p_name))), '[]'::jsonb)
    ELSE '[]'::jsonb END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_dup_notes_text(jsonb), public.lwb_dup_kind_text(text), public.lwb_dup_user_name(uuid),
  public.lwb_dup_party_keys(text), public.lwb_dup_row(public.lwb_dup_notes), public.lwb_dup_bell(text,text),
  public.lwb_acc_dup_add(jsonb), public.lwb_acc_dup_collect(bigint,uuid,text), public.lwb_acc_dup_cancel(bigint,text),
  public.lwb_acc_dup_list(int), public.lwb_dup_pending(), public.lwb_dup_for_party(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_dup_add(jsonb), public.lwb_acc_dup_collect(bigint,uuid,text),
  public.lwb_acc_dup_cancel(bigint,text), public.lwb_acc_dup_list(int), public.lwb_dup_pending(),
  public.lwb_dup_for_party(text) TO authenticated;
REVOKE ALL ON FUNCTION public.lwb_dup_bell(text,text), public.lwb_dup_row(public.lwb_dup_notes),
  public.lwb_dup_user_name(uuid), public.lwb_dup_party_keys(text) FROM authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'table' AS item, (to_regclass('public.lwb_dup_notes') IS NOT NULL)::text AS ok
UNION ALL SELECT 'add rpc', (to_regprocedure('public.lwb_acc_dup_add(jsonb)') IS NOT NULL)::text
UNION ALL SELECT 'collect rpc', (to_regprocedure('public.lwb_acc_dup_collect(bigint,uuid,text)') IS NOT NULL)::text
UNION ALL SELECT 'pending rpc', (to_regprocedure('public.lwb_dup_pending()') IS NOT NULL)::text;
