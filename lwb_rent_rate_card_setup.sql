-- Hired vehicle trip rent by VEHICLE SIZE x PARTY (rate card) + load on each trip (18 Nov 2026).
--
-- Mohit: rent is not one rate for everybody. It depends on the vehicle (2 / 3 / 4 / 11 ton ...) and the party.
-- Before this, a per party rate was kept per vehicle + party, so every new vehicle needed every party's rate again.
--
--   * lwb_vehicles.size_ton: size of the vehicle (Vehicle Master).
--   * lwb_hired_rate_card: one rate per size + party. Manager sets -> WAITING (bell to Admins), Admin -> VERIFIED.
--   * A VERIFIED card rate is used by every per party hired vehicle of that size: it is written into
--     lwb_hired_party_rates (from_card = true) and the trips waiting for that party are posted at once.
--     A rate set for one vehicle only (from_card = false, the old way) stays and wins over the card.
--   * lwb_hired_rate_list2 / lwb_hired_ledger2: same as before + vehicle size, load (KG) of the POs, card rates.
-- Run after lwb_trip_rent_setup.sql. Safe to run again. Nothing is dropped.
BEGIN;

ALTER TABLE public.lwb_vehicles ADD COLUMN IF NOT EXISTS size_ton numeric(5,1) CHECK (size_ton IS NULL OR (size_ton > 0 AND size_ton <= 60));
ALTER TABLE public.lwb_hired_party_rates ADD COLUMN IF NOT EXISTS from_card boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.lwb_hired_rate_card (
  id          bigserial PRIMARY KEY,
  size_ton    numeric(5,1) NOT NULL CHECK (size_ton > 0 AND size_ton <= 60),
  party_key   text NOT NULL CHECK (length(party_key) BETWEEN 2 AND 150),
  party_name  text NOT NULL,
  rate        numeric(14,2) NOT NULL CHECK (rate > 0 AND rate <= 100000),
  status      text NOT NULL CHECK (status IN ('WAITING','VERIFIED','SENT_BACK')),
  note        text CHECK (note IS NULL OR length(note) <= 300),
  set_by      uuid,
  set_at      timestamptz NOT NULL DEFAULT now(),
  verified_by uuid,
  verified_at timestamptz,
  UNIQUE (size_ton, party_key)
);
ALTER TABLE public.lwb_hired_rate_card ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_hired_rate_card FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_hired_rate_card_id_seq FROM PUBLIC, anon, authenticated;

-- A rate set for one vehicle by hand (Trip rent to set, the old way) is that vehicle's own rate, not a card copy.
CREATE OR REPLACE FUNCTION public.lwb_rate_card_own_trg()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $fn$
BEGIN
  IF NEW.note IS DISTINCT FROM 'Rate card' THEN NEW.from_card := false; END IF;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS trg_lwb_rate_card_own ON public.lwb_hired_party_rates;
CREATE TRIGGER trg_lwb_rate_card_own BEFORE INSERT OR UPDATE ON public.lwb_hired_party_rates
  FOR EACH ROW EXECUTE FUNCTION public.lwb_rate_card_own_trg();

-- Put the VERIFIED card rates into the per vehicle rates of every matching per party vehicle and post the
-- waiting trips. p_card NULL = all cards; p_vehicle NULL = all vehicles. A vehicle's own rate is not touched.
CREATE OR REPLACE FUNCTION public.lwb_rate_card_apply(p_card bigint, p_vehicle uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r record; v_n integer := 0;
BEGIN
  FOR r IN SELECT c.party_key, c.party_name, c.rate, c.verified_by, c.verified_at, h.vehicle_id
           FROM public.lwb_hired_rate_card c
           JOIN public.lwb_vehicles v ON v.size_ton = c.size_ton
           JOIN public.lwb_hired_vehicles h ON h.vehicle_id = v.id AND h.active AND h.rent_type = 'PARTY'
           LEFT JOIN public.lwb_hired_party_rates q ON q.vehicle_id = h.vehicle_id AND q.party_key = c.party_key
           WHERE c.status = 'VERIFIED' AND (p_card IS NULL OR c.id = p_card) AND (p_vehicle IS NULL OR h.vehicle_id = p_vehicle)
             AND (q.id IS NULL OR q.from_card OR q.status <> 'VERIFIED') LOOP
    INSERT INTO public.lwb_hired_party_rates AS q (vehicle_id, party_key, party_name, rate, status, note, set_by, set_at, verified_by, verified_at, from_card)
    VALUES (r.vehicle_id, r.party_key, r.party_name, r.rate, 'VERIFIED', 'Rate card', r.verified_by, now(), r.verified_by, coalesce(r.verified_at, now()), true)
    ON CONFLICT (vehicle_id, party_key) DO UPDATE SET rate = EXCLUDED.rate, status = 'VERIFIED', note = 'Rate card', from_card = true,
      verified_by = EXCLUDED.verified_by, verified_at = EXCLUDED.verified_at;
    v_n := v_n + public.lwb_hired_post_pending(r.vehicle_id, r.party_key);
  END LOOP;
  RETURN v_n;
END;
$fn$;

-- Vehicle size changed / vehicle put on per party rent: card rates follow by themselves (never stops the save).
CREATE OR REPLACE FUNCTION public.lwb_rate_card_vehicle_trg()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id uuid; v_size numeric;
BEGIN
  BEGIN
    IF TG_TABLE_NAME = 'lwb_vehicles' THEN
      v_id := (to_jsonb(NEW)->>'id')::uuid; v_size := (to_jsonb(NEW)->>'size_ton')::numeric;
      -- old card rates of the old size go out (the vehicle's own rates stay)
      DELETE FROM public.lwb_hired_party_rates q WHERE q.vehicle_id = v_id AND q.from_card
        AND NOT EXISTS (SELECT 1 FROM public.lwb_hired_rate_card c WHERE c.size_ton = v_size AND c.party_key = q.party_key AND c.status = 'VERIFIED');
    ELSE
      v_id := (to_jsonb(NEW)->>'vehicle_id')::uuid;
    END IF;
    PERFORM public.lwb_rate_card_apply(NULL, v_id);
  EXCEPTION WHEN others THEN RAISE WARNING 'rate card skipped: %', SQLERRM;
  END;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS trg_lwb_rate_card_vehicle ON public.lwb_vehicles;
CREATE TRIGGER trg_lwb_rate_card_vehicle AFTER UPDATE OF size_ton ON public.lwb_vehicles
  FOR EACH ROW WHEN (OLD.size_ton IS DISTINCT FROM NEW.size_ton) EXECUTE FUNCTION public.lwb_rate_card_vehicle_trg();
DROP TRIGGER IF EXISTS trg_lwb_rate_card_hired ON public.lwb_hired_vehicles;
CREATE TRIGGER trg_lwb_rate_card_hired AFTER INSERT OR UPDATE OF rent_type, active ON public.lwb_hired_vehicles
  FOR EACH ROW WHEN (NEW.active AND NEW.rent_type = 'PARTY') EXECUTE FUNCTION public.lwb_rate_card_vehicle_trg();

-- Manager / Admin sets the rate of a size for a party. Manager -> WAITING (bell to Admins); Admin -> VERIFIED (used at once).
CREATE OR REPLACE FUNCTION public.lwb_rate_card_set(p_size numeric, p_party text, p_rate numeric, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_pk text := public.lwb_hired_pkey(p_party); v_admin boolean := public.lwb_acc_admin(); v_size numeric := round(p_size, 1);
        c public.lwb_hired_rate_card; v_name text; v_n integer := 0;
BEGIN
  IF NOT public.lwb_fleet_editor() THEN RAISE EXCEPTION 'Only Admin / Manager can set the trip rent'; END IF;
  IF v_size IS NULL OR v_size <= 0 OR v_size > 60 THEN RAISE EXCEPTION 'Choose the vehicle size (ton)'; END IF;
  IF length(v_pk) < 2 THEN RAISE EXCEPTION 'Party name is missing'; END IF;
  IF p_rate IS NULL OR p_rate <= 0 OR p_rate > 100000 THEN RAISE EXCEPTION 'Enter the rent for one trip'; END IF;
  SELECT * INTO c FROM public.lwb_hired_rate_card x WHERE x.size_ton = v_size AND x.party_key = v_pk;
  IF c.status = 'VERIFIED' AND NOT v_admin THEN RAISE EXCEPTION 'This rate is already verified. Only Admin can change it.'; END IF;
  v_name := coalesce(c.party_name, (SELECT min(p.party_name) FROM public.lwb_hired_pending p WHERE p.party_key = v_pk), btrim(p_party));
  INSERT INTO public.lwb_hired_rate_card AS x (size_ton, party_key, party_name, rate, status, note, set_by, set_at, verified_by, verified_at)
  VALUES (v_size, v_pk, v_name, round(p_rate, 2), CASE WHEN v_admin THEN 'VERIFIED' ELSE 'WAITING' END, nullif(btrim(coalesce(p_note,'')), ''),
          auth.uid(), now(), CASE WHEN v_admin THEN auth.uid() END, CASE WHEN v_admin THEN now() END)
  ON CONFLICT (size_ton, party_key) DO UPDATE SET rate = EXCLUDED.rate, status = EXCLUDED.status, note = EXCLUDED.note,
    set_by = EXCLUDED.set_by, set_at = now(), verified_by = EXCLUDED.verified_by, verified_at = EXCLUDED.verified_at
  RETURNING * INTO c;
  IF v_admin THEN
    v_n := public.lwb_rate_card_apply(c.id, NULL);
    RETURN jsonb_build_object('status', 'VERIFIED', 'posted', v_n);
  END IF;
  INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
  SELECT u.id, 'Verify trip rent', trim_scale(v_size)::text || ' Ton → ' || v_name || ': ₹' || round(p_rate, 2) || ' per trip. Vehicle Master > Trip rent to set.', 'HIRED_RATE_VERIFY'
  FROM public.user_profiles u WHERE u.active AND lower(btrim(u.role)) = 'admin' AND u.id IS DISTINCT FROM auth.uid();
  RETURN jsonb_build_object('status', 'WAITING', 'posted', 0);
END;
$fn$;

-- Admin verifies (rate may be changed) or sends back a waiting card rate.
CREATE OR REPLACE FUNCTION public.lwb_rate_card_verify(p_id bigint, p_ok boolean, p_rate numeric, p_note text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE c public.lwb_hired_rate_card;
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can verify the trip rent'; END IF;
  SELECT * INTO c FROM public.lwb_hired_rate_card x WHERE x.id = p_id FOR UPDATE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'Rate not found'; END IF;
  IF c.status <> 'WAITING' THEN RAISE EXCEPTION 'This rate is not waiting for verification'; END IF;
  IF p_ok THEN
    IF p_rate IS NOT NULL AND (p_rate <= 0 OR p_rate > 100000) THEN RAISE EXCEPTION 'Check the rent'; END IF;
    UPDATE public.lwb_hired_rate_card SET status = 'VERIFIED', rate = coalesce(round(p_rate, 2), rate), verified_by = auth.uid(), verified_at = now(),
      note = coalesce(nullif(btrim(coalesce(p_note,'')), ''), note) WHERE id = c.id;
    RETURN public.lwb_rate_card_apply(c.id, NULL);
  END IF;
  IF length(btrim(coalesce(p_note,''))) < 3 THEN RAISE EXCEPTION 'Write why it is sent back'; END IF;
  UPDATE public.lwb_hired_rate_card SET status = 'SENT_BACK', note = left(btrim(p_note), 300) WHERE id = c.id;
  IF c.set_by IS NOT NULL AND c.set_by IS DISTINCT FROM auth.uid() THEN
    INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
    VALUES (c.set_by, 'Trip rent sent back', trim_scale(c.size_ton)::text || ' Ton → ' || c.party_name || ': ' || left(btrim(p_note), 200) || '. Set it again in Vehicle Master > Trip rent to set.', 'HIRED_RATE_SENT_BACK');
  END IF;
  RETURN 0;
END;
$fn$;

-- Load (KG) of some POs: orders.total_weight.
CREATE OR REPLACE FUNCTION public.lwb_rate_card_load(p_orders text[])
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT round(sum(coalesce(o.total_weight, 0)), 1) FROM public.orders o
  WHERE o.order_no = ANY (coalesce(p_orders, '{}')) AND lower(coalesce(o.status,'')) NOT IN ('cancelled','canceled','rejected');
$fn$;

-- "Trip rent to set": same as lwb_hired_rate_list + vehicle size, load of the POs, the card rate of that size + party,
-- the rate card itself and the sizes in use.
CREATE OR REPLACE FUNCTION public.lwb_hired_rate_list2()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v jsonb := public.lwb_hired_rate_list();
BEGIN
  RETURN v || jsonb_build_object(
    'groups', coalesce((SELECT jsonb_agg(g.x || jsonb_build_object('size_ton', vh.size_ton, 'load_kg', CASE WHEN jsonb_typeof(g.x->'orders') = 'array' THEN public.lwb_rate_card_load(ARRAY(SELECT jsonb_array_elements_text(g.x->'orders'))) END,
        'card', (SELECT jsonb_build_object('id', c.id, 'rate', c.rate, 'status', c.status, 'note', c.note,
                   'set_by_name', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = c.set_by))
                 FROM public.lwb_hired_rate_card c WHERE c.size_ton = vh.size_ton AND c.party_key = g.x->>'party_key')) ORDER BY g.n)
      FROM jsonb_array_elements(coalesce(v->'groups','[]'::jsonb)) WITH ORDINALITY g(x, n)
      LEFT JOIN public.lwb_vehicles vh ON vh.id = (g.x->>'vehicle_id')::uuid), '[]'::jsonb),
    'rates', coalesce((SELECT jsonb_agg(r.x || jsonb_build_object('from_card', q.from_card, 'size_ton', vh.size_ton) ORDER BY r.n)
      FROM jsonb_array_elements(coalesce(v->'rates','[]'::jsonb)) WITH ORDINALITY r(x, n)
      LEFT JOIN public.lwb_hired_party_rates q ON q.id = (r.x->>'id')::bigint
      LEFT JOIN public.lwb_vehicles vh ON vh.id = q.vehicle_id), '[]'::jsonb),
    'card', coalesce((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'size_ton', c.size_ton, 'party_key', c.party_key, 'party', c.party_name,
        'rate', c.rate, 'status', c.status, 'note', c.note, 'set_by_name', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = c.set_by),
        'verified_by_name', (SELECT u.full_name FROM public.user_profiles u WHERE u.id = c.verified_by), 'verified_at', c.verified_at,
        'vehicles', (SELECT count(*) FROM public.lwb_vehicles x JOIN public.lwb_hired_vehicles h ON h.vehicle_id = x.id AND h.active AND h.rent_type = 'PARTY'
                     WHERE x.size_ton = c.size_ton)) ORDER BY c.party_name, c.size_ton)
      FROM public.lwb_hired_rate_card c), '[]'::jsonb),
    'sizes', coalesce((SELECT jsonb_agg(DISTINCT s ORDER BY s) FROM (
        SELECT x.size_ton AS s FROM public.lwb_vehicles x WHERE x.size_ton IS NOT NULL
        UNION SELECT c.size_ton FROM public.lwb_hired_rate_card c) z), '[]'::jsonb));
END;
$fn$;

-- Hired rent ledger: same as lwb_hired_ledger + vehicle size and the load (KG) of each trip line.
CREATE OR REPLACE FUNCTION public.lwb_hired_ledger2(p_vehicle uuid, p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v jsonb := public.lwb_hired_ledger(p_vehicle, p_from, p_to);
BEGIN
  RETURN jsonb_set(jsonb_set(v, '{vehicle,size_ton}', coalesce((SELECT to_jsonb(x.size_ton) FROM public.lwb_vehicles x WHERE x.id = p_vehicle), 'null'::jsonb)),
    '{lines}', coalesce((SELECT jsonb_agg(CASE WHEN jsonb_typeof(l.x->'order_nos') = 'array' AND jsonb_array_length(l.x->'order_nos') > 0
        THEN l.x || jsonb_build_object('load_kg', public.lwb_rate_card_load(ARRAY(SELECT jsonb_array_elements_text(l.x->'order_nos')))) ELSE l.x END ORDER BY l.n)
      FROM jsonb_array_elements(coalesce(v->'lines','[]'::jsonb)) WITH ORDINALITY l(x, n)), '[]'::jsonb));
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_rate_card_apply(bigint,uuid), public.lwb_rate_card_vehicle_trg(), public.lwb_rate_card_own_trg(), public.lwb_rate_card_load(text[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_rate_card_set(numeric,text,numeric,text), public.lwb_rate_card_verify(bigint,boolean,numeric,text),
  public.lwb_hired_rate_list2(), public.lwb_hired_ledger2(uuid,date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_rate_card_set(numeric,text,numeric,text), public.lwb_rate_card_verify(bigint,boolean,numeric,text),
  public.lwb_hired_rate_list2(), public.lwb_hired_ledger2(uuid,date,date) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
