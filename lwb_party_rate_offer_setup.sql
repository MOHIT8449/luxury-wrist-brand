-- LUXURY WRIST BRAND ERP — PARTY RATE OFFER: rate given to one party, category-wise, with history
--
-- Runs by itself when merged to main (after lwb_rate_scheme_setup.sql). Safe to run again. Nothing is dropped.
--
-- Mohit asked (16 Nov 2026): like making a PO, pick a party, add categories / packs with the rate per case
-- (e.g. 2.25L 650, 150ml Tetra 265, 250ml Maaza 465, 850ml Maaza 580, 1L Kinley 165), save it as the rate
-- given to that party and send it as an image on WhatsApp. An (i) on each line shows what rate this party
-- was given before (date, rate, who) against the rate now.
--   * lwb_party_rate_offers       : one offer (RO-DDMM-NN, party, date, note, who, ACTIVE / CANCELLED)
--   * lwb_party_rate_offer_lines  : its lines (item = pack / category name, rate per case, note)
--   * lwb_party_rate_offer_save(p)          -> {id, offer_no}
--   * lwb_party_rate_offer_list(days, party) -> offers with lines and who made them
--   * lwb_party_rate_last(party)             -> last rate of each item for one party (active offers)
--   * lwb_party_rate_history(party, item)    -> every rate this party got for one item, newest first
--   * lwb_party_rate_offer_cancel(id, note)  -> Admin, or the person who made it
-- Admin and Sales Head only (lwb_rate_editor()). No direct table access.
-- No order, rate list, stock, bill, ledger or Tally data is changed.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_party_rate_offers (
  id bigserial PRIMARY KEY,
  offer_no text NOT NULL UNIQUE,
  party_name text NOT NULL CHECK (btrim(party_name) <> ''),
  party_key text NOT NULL,
  party_code text,
  offer_date date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Kolkata')::date),
  note text CHECK (note IS NULL OR length(note) <= 500),
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','CANCELLED')),
  cancel_note text,
  cancelled_at timestamptz,
  cancelled_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);
CREATE INDEX IF NOT EXISTS lwb_party_rate_offers_party_idx
  ON public.lwb_party_rate_offers (party_key, offer_date DESC, id DESC);

CREATE TABLE IF NOT EXISTS public.lwb_party_rate_offer_lines (
  id bigserial PRIMARY KEY,
  offer_id bigint NOT NULL REFERENCES public.lwb_party_rate_offers(id) ON DELETE CASCADE,
  line_no integer NOT NULL,
  item text NOT NULL CHECK (btrim(item) <> '' AND length(item) <= 120),
  item_key text NOT NULL,
  rate numeric(12,2) NOT NULL CHECK (rate >= 0),
  note text CHECK (note IS NULL OR length(note) <= 200)
);
CREATE INDEX IF NOT EXISTS lwb_party_rate_offer_lines_offer_idx ON public.lwb_party_rate_offer_lines (offer_id, line_no);
CREATE INDEX IF NOT EXISTS lwb_party_rate_offer_lines_item_idx ON public.lwb_party_rate_offer_lines (item_key);

ALTER TABLE public.lwb_party_rate_offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_party_rate_offer_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_party_rate_offers, public.lwb_party_rate_offer_lines FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_party_rate_offers_id_seq, public.lwb_party_rate_offer_lines_id_seq FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_party_rate_key(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT upper(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g')) $fn$;

-- Name of a login (full name, else role)
CREATE OR REPLACE FUNCTION public.lwb_party_rate_who(p uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$ SELECT coalesce(nullif(btrim(u.full_name), ''), u.role) FROM public.user_profiles u WHERE u.id = p $fn$;
REVOKE ALL ON FUNCTION public.lwb_party_rate_who(uuid) FROM PUBLIC, anon, authenticated;

-- p = {party_name, party_code?, offer_date?, note?, lines:[{item, rate, note?}]}
CREATE OR REPLACE FUNCTION public.lwb_party_rate_offer_save(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_party text := btrim(coalesce(p->>'party_name', ''));
  v_date date := coalesce(nullif(p->>'offer_date', '')::date, (now() AT TIME ZONE 'Asia/Kolkata')::date);
  v_id bigint; v_no text; v_n integer; v_l jsonb; v_line integer := 0; v_item text; v_rate numeric;
  v_seen text[] := '{}';
BEGIN
  IF NOT public.lwb_rate_editor() THEN RAISE EXCEPTION 'Only Admin or Sales Head can give a party rate.'; END IF;
  IF v_party = '' THEN RAISE EXCEPTION 'Pick the party.'; END IF;
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

  INSERT INTO public.lwb_party_rate_offers(offer_no, party_name, party_key, party_code, offer_date, note, created_by)
  VALUES (v_no, v_party, public.lwb_party_rate_key(v_party), nullif(btrim(coalesce(p->>'party_code', '')), ''),
          v_date, nullif(btrim(coalesce(p->>'note', '')), ''), auth.uid())
  RETURNING id INTO v_id;

  FOR v_l IN SELECT * FROM jsonb_array_elements(p->'lines') LOOP
    v_item := btrim(coalesce(v_l->>'item', ''));
    IF v_item = '' THEN CONTINUE; END IF;
    IF public.lwb_party_rate_key(v_item) = ANY(v_seen) THEN RAISE EXCEPTION '% is added twice.', v_item; END IF;
    v_seen := v_seen || public.lwb_party_rate_key(v_item);
    BEGIN v_rate := (v_l->>'rate')::numeric; EXCEPTION WHEN others THEN v_rate := NULL; END;
    IF v_rate IS NULL OR v_rate < 0 THEN RAISE EXCEPTION 'Enter the rate for %.', v_item; END IF;
    v_line := v_line + 1;
    INSERT INTO public.lwb_party_rate_offer_lines(offer_id, line_no, item, item_key, rate, note)
    VALUES (v_id, v_line, v_item, public.lwb_party_rate_key(v_item), round(v_rate, 2), nullif(btrim(coalesce(v_l->>'note', '')), ''));
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
      'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('item', l.item, 'rate', l.rate, 'note', l.note) ORDER BY l.line_no)
                FROM public.lwb_party_rate_offer_lines l WHERE l.offer_id = o.id), '[]'::jsonb))
      ORDER BY o.offer_date DESC, o.id DESC)
    FROM (SELECT * FROM public.lwb_party_rate_offers o
           WHERE (p_party IS NULL OR o.party_key = public.lwb_party_rate_key(p_party))
             AND o.offer_date >= (now() AT TIME ZONE 'Asia/Kolkata')::date - greatest(coalesce(p_days, 90), 1)
           ORDER BY o.offer_date DESC, o.id DESC LIMIT 500) o), '[]'::jsonb);
END;
$fn$;

-- Last active rate of each item for one party: [{item, rate, offer_date, offer_no, by}]
CREATE OR REPLACE FUNCTION public.lwb_party_rate_last(p_party text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_rate_editor() THEN RAISE EXCEPTION 'Only Admin or Sales Head can see party rates.'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('item', x.item, 'item_key', x.item_key, 'rate', x.rate, 'offer_date', x.offer_date,
                                        'offer_no', x.offer_no, 'by', public.lwb_party_rate_who(x.created_by)) ORDER BY x.line_no)
    FROM (SELECT DISTINCT ON (l.item_key) l.item, l.item_key, l.rate, l.line_no, o.offer_date, o.offer_no, o.created_by
            FROM public.lwb_party_rate_offer_lines l JOIN public.lwb_party_rate_offers o ON o.id = l.offer_id
           WHERE o.party_key = public.lwb_party_rate_key(p_party) AND o.status = 'ACTIVE'
           ORDER BY l.item_key, o.offer_date DESC, o.id DESC) x), '[]'::jsonb);
END;
$fn$;

-- Every rate one party got for one item, newest first, with the change from the one before:
-- [{offer_date, rate, change, offer_no, by, status, created_at}]
CREATE OR REPLACE FUNCTION public.lwb_party_rate_history(p_party text, p_item text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_rate_editor() THEN RAISE EXCEPTION 'Only Admin or Sales Head can see party rates.'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('offer_date', h.offer_date, 'rate', h.rate, 'change', h.change, 'offer_no', h.offer_no,
                                        'by', public.lwb_party_rate_who(h.created_by), 'status', h.status, 'created_at', h.created_at,
                                        'note', h.note)
                     ORDER BY h.offer_date DESC, h.id DESC)
    FROM (SELECT o.id, o.offer_date, o.offer_no, o.created_by, o.status, o.created_at, l.rate, l.note,
                 CASE WHEN o.status = 'ACTIVE' THEN l.rate - lag(l.rate) OVER (PARTITION BY o.status ORDER BY o.offer_date, o.id) END AS change
            FROM public.lwb_party_rate_offer_lines l JOIN public.lwb_party_rate_offers o ON o.id = l.offer_id
           WHERE o.party_key = public.lwb_party_rate_key(p_party) AND l.item_key = public.lwb_party_rate_key(p_item)
           ORDER BY o.offer_date DESC, o.id DESC LIMIT 200) h), '[]'::jsonb);
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_party_rate_offer_cancel(p_id bigint, p_note text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_by uuid; v_status text; v_admin boolean;
BEGIN
  IF NOT public.lwb_rate_editor() THEN RAISE EXCEPTION 'Only Admin or Sales Head can cancel a party rate.'; END IF;
  IF btrim(coalesce(p_note, '')) = '' THEN RAISE EXCEPTION 'Write why it is cancelled.'; END IF;
  SELECT created_by, status INTO v_by, v_status FROM public.lwb_party_rate_offers WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Rate offer not found.'; END IF;
  IF v_status = 'CANCELLED' THEN RETURN false; END IF;
  SELECT lower(btrim(role)) = 'admin' INTO v_admin FROM public.user_profiles WHERE id = auth.uid();
  IF NOT coalesce(v_admin, false) AND v_by IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Only Admin or the person who made it can cancel this rate offer.';
  END IF;
  UPDATE public.lwb_party_rate_offers SET status = 'CANCELLED', cancel_note = left(btrim(p_note), 300),
         cancelled_at = now(), cancelled_by = auth.uid() WHERE id = p_id;
  RETURN true;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_party_rate_offer_save(jsonb), public.lwb_party_rate_offer_list(integer, text),
  public.lwb_party_rate_last(text), public.lwb_party_rate_history(text, text), public.lwb_party_rate_offer_cancel(bigint, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_party_rate_offer_save(jsonb), public.lwb_party_rate_offer_list(integer, text),
  public.lwb_party_rate_last(text), public.lwb_party_rate_history(text, text), public.lwb_party_rate_offer_cancel(bigint, text)
  TO authenticated;

COMMIT;
