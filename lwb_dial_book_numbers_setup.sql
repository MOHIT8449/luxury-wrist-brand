-- LUXURY WRIST BRAND ERP — DIAL BOOK: EXTRA NUMBERS + NO DUPLICATE NUMBERS (27 Nov 2026)
--
-- Mohit asked (27 Nov 2026):
--   * A party (or a team member) often has 2-3 numbers: keep the main number and add extra numbers
--     (Primary + 2nd / 3rd). Call asks which number when there are more.
--   * No number may be saved twice. A new number is saved only when it is really new; a number that is
--     already in the ERP (any party, extra number, login or Employee Master) is simply not saved: no error
--     popup to anyone, no notification. The page only says "already saved with <name>".
--   * The Admin contacts file has every number once.
--
--   lwb_contact_numbers      extra numbers: kind PARTY / TEAM / STAFF + ref, mobile (unique), label.
--   lwb_dial_owner(mobile)   who already has this number (first match), or NULL.
--   lwb_dial_number_add      Admin / Sales Head / Accounts any contact; Salesman his own parties. Max 3 extra.
--   lwb_dial_number_remove   Admin / Sales Head, or who added it.
--   lwb_dial_call(kind, ref, source, number_id)  number_id = an extra number (NULL = main number).
--   lwb_dial_book()          + extras (masked) and dup_with (another contact has the same main number).
--   lwb_dial_export()        every number once (extra numbers as more phone numbers of the same contact).
--
-- At the end a read-only count (numbers only, no names / phone numbers) shows in the run log:
-- how many party numbers are the same as another party / login number.
-- Safe to run again. Nothing is dropped except the old 3-argument lwb_dial_call (same name, new last argument).

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_contact_numbers (
  id bigserial PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('PARTY','TEAM','STAFF')),
  ref text NOT NULL,
  mobile text NOT NULL CHECK (mobile ~ '^[6-9][0-9]{9}$'),
  label text CHECK (label IS NULL OR length(label) <= 30),
  created_by uuid DEFAULT auth.uid(),
  created_by_name text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_contact_numbers_mobile_uidx ON public.lwb_contact_numbers(mobile);
CREATE INDEX IF NOT EXISTS lwb_contact_numbers_ref_idx ON public.lwb_contact_numbers(kind, ref);
ALTER TABLE public.lwb_contact_numbers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_contact_numbers FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_contact_numbers_id_seq FROM PUBLIC, anon, authenticated;

-- Who already has this number: party main number, extra number, login, Employee Master (first match).
CREATE OR REPLACE FUNCTION public.lwb_dial_owner(p_mobile text)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  WITH m AS (SELECT public.lwb_dial_mob(p_mobile) AS v)
  SELECT x FROM (
    SELECT jsonb_build_object('kind', 'PARTY', 'ref', c.id::text, 'name', btrim(c.customer_name), 'extra', false) AS x, 1 AS o
      FROM public.lwb_customer_master c, m WHERE m.v IS NOT NULL AND coalesce(c.is_active, true) AND public.lwb_dial_mob(c.mobile) = m.v
    UNION ALL
    SELECT jsonb_build_object('kind', n.kind, 'ref', n.ref, 'name',
             coalesce((SELECT btrim(c.customer_name) FROM public.lwb_customer_master c WHERE n.kind = 'PARTY' AND c.id::text = n.ref),
                      (SELECT btrim(p.full_name) FROM public.user_profiles p WHERE n.kind = 'TEAM' AND p.id::text = n.ref),
                      (SELECT btrim(s.name) FROM public.lwb_acc_staff s WHERE n.kind = 'STAFF' AND s.id::text = n.ref), '?'),
             'extra', true, 'id', n.id), 2
      FROM public.lwb_contact_numbers n, m WHERE n.mobile = m.v
    UNION ALL
    SELECT jsonb_build_object('kind', CASE WHEN lower(btrim(coalesce(p.role, ''))) = 'driver' THEN 'DRIVER' ELSE 'TEAM' END,
             'ref', p.id::text, 'name', btrim(p.full_name), 'extra', false), 3
      FROM public.user_profiles p, m WHERE m.v IS NOT NULL AND p.active = true AND public.lwb_dial_mob(p.mobile) = m.v
    UNION ALL
    SELECT jsonb_build_object('kind', 'STAFF', 'ref', s.id::text, 'name', btrim(s.name), 'extra', false), 4
      FROM public.lwb_acc_staff s, m WHERE m.v IS NOT NULL AND s.active AND public.lwb_dial_mob(s.mobile) = m.v
  ) q ORDER BY o LIMIT 1
$$;
REVOKE ALL ON FUNCTION public.lwb_dial_owner(text) FROM PUBLIC, anon, authenticated;

-- Add an extra number. A number already in the ERP is NOT saved (saved=false + who has it), never an error.
CREATE OR REPLACE FUNCTION public.lwb_dial_number_add(p_kind text, p_ref text, p_mobile text, p_label text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE r text := public.lwb_dial_role(); v_kind text := upper(btrim(coalesce(p_kind, ''))); v_ref text := btrim(coalesce(p_ref, ''));
        v_mob text := public.lwb_dial_mob(p_mobile); v_own jsonb; v_id bigint; v_name text;
BEGIN
  IF v_kind NOT IN ('PARTY','TEAM','STAFF') THEN RAISE EXCEPTION 'Extra number only for a party or a team member'; END IF;
  IF coalesce(r, '') NOT IN ('admin','manager','accounts') AND NOT (r = 'sales' AND v_kind = 'PARTY') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Accounts (or the salesman for his party) can add a number';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_dial_all() a WHERE a.kind = v_kind AND a.ref = v_ref)
     AND NOT (v_kind = 'TEAM' AND v_ref = auth.uid()::text) THEN
    RAISE EXCEPTION 'This contact is not in your Dial Book';
  END IF;
  IF v_mob IS NULL THEN RAISE EXCEPTION 'Enter a 10-digit mobile'; END IF;
  v_own := public.lwb_dial_owner(v_mob);
  IF v_own IS NOT NULL THEN
    RETURN jsonb_build_object('saved', false, 'same', v_own->>'kind' = v_kind AND v_own->>'ref' = v_ref, 'owner', v_own->>'name', 'owner_kind', v_own->>'kind');
  END IF;
  IF (SELECT count(*) FROM public.lwb_contact_numbers n WHERE n.kind = v_kind AND n.ref = v_ref) >= 3 THEN
    RAISE EXCEPTION 'Max 3 extra numbers per contact';
  END IF;
  SELECT p.full_name INTO v_name FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.lwb_contact_numbers(kind, ref, mobile, label, created_by, created_by_name)
  VALUES (v_kind, v_ref, v_mob, left(nullif(btrim(coalesce(p_label, '')), ''), 30), auth.uid(), v_name)
  ON CONFLICT (mobile) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RETURN jsonb_build_object('saved', false, 'owner', '?'); END IF;
  RETURN jsonb_build_object('saved', true, 'id', v_id, 'masked', public.lwb_dial_mask(v_mob));
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_number_add(text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_number_add(text, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_dial_number_remove(p_id bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  DELETE FROM public.lwb_contact_numbers n
  WHERE n.id = p_id AND (coalesce(public.lwb_dial_role(), '') IN ('admin','manager') OR n.created_by = auth.uid());
  IF NOT FOUND THEN RAISE EXCEPTION 'Only Admin / Sales Head or who added it can remove this number'; END IF;
  RETURN true;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_number_remove(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_number_remove(bigint) TO authenticated;

-- List: + extras (masked) and dup_with (other contacts with the same main number).
CREATE OR REPLACE FUNCTION public.lwb_dial_book()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE r text := public.lwb_dial_role(); v jsonb; v_recent jsonb;
BEGIN
  WITH a AS (SELECT * FROM public.lwb_dial_all()),
       d AS (SELECT a.mobile, count(*) AS n FROM a WHERE a.kind IN ('PARTY','TEAM','STAFF','DRIVER') GROUP BY a.mobile HAVING count(*) > 1)
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind', a.kind, 'ref', a.ref, 'name', a.name, 'masked', public.lwb_dial_mask(a.mobile),
           'last4', right(a.mobile, 4), 'sub', a.sub, 'save_as', a.save_as, 'vehicle_no', a.vehicle_no, 'tag', a.tag, 'at', a.at,
           'last_at', lc.created_at, 'last_by', lc.called_by_name, 'last_result', lc.result,
           'extras', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'masked', public.lwb_dial_mask(n.mobile), 'last4', right(n.mobile, 4),
                        'label', n.label, 'by', n.created_by_name) ORDER BY n.id), '[]'::jsonb)
                      FROM public.lwb_contact_numbers n WHERE n.kind = a.kind AND n.ref = a.ref),
           'dup_with', CASE WHEN d.n IS NULL OR a.kind = 'VEHICLE' THEN NULL ELSE
             (SELECT jsonb_agg(b.name ORDER BY b.name) FROM a b WHERE b.mobile = a.mobile AND b.kind <> 'VEHICLE' AND NOT (b.kind = a.kind AND b.ref = a.ref)) END
         ) ORDER BY a.kind, a.name), '[]'::jsonb)
    INTO v
  FROM a
  LEFT JOIN d ON d.mobile = a.mobile
  LEFT JOIN LATERAL (SELECT c.created_at, c.called_by_name, c.result FROM public.lwb_dial_calls c
                     WHERE c.kind = a.kind AND c.ref = a.ref
                       AND (r IN ('admin','manager') OR c.called_by = auth.uid())
                     ORDER BY c.created_at DESC LIMIT 1) lc ON true;
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'ref', x.ref, 'at', x.created_at) ORDER BY x.created_at DESC), '[]'::jsonb)
    INTO v_recent
  FROM (SELECT DISTINCT ON (c.kind, c.ref) c.kind, c.ref, c.created_at FROM public.lwb_dial_calls c
        WHERE c.called_by = auth.uid() AND c.created_at > now() - interval '30 days' AND coalesce(c.source, '') <> 'Download'
        ORDER BY c.kind, c.ref, c.created_at DESC) x
  LIMIT 15;
  RETURN jsonb_build_object('role', r, 'me', auth.uid(), 'all_log', r IN ('admin','manager'), 'export', r = 'admin',
    'add_num', r IN ('admin','manager','accounts','sales'), 'contacts', v, 'recent', v_recent);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_book() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_book() TO authenticated;

-- Call: main number, or one extra number of the same contact.
DROP FUNCTION IF EXISTS public.lwb_dial_call(text, text, text);
CREATE OR REPLACE FUNCTION public.lwb_dial_call(p_kind text, p_ref text, p_source text DEFAULT NULL, p_number_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE a record; v_id bigint; v_name text; v_role text; v_mob text; v_lbl text;
BEGIN
  SELECT * INTO a FROM public.lwb_dial_all() x WHERE x.kind = upper(btrim(coalesce(p_kind, ''))) AND x.ref = btrim(coalesce(p_ref, '')) LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'This number is not in your Dial Book'; END IF;
  v_mob := a.mobile;
  IF p_number_id IS NOT NULL THEN
    SELECT n.mobile, n.label INTO v_mob, v_lbl FROM public.lwb_contact_numbers n WHERE n.id = p_number_id AND n.kind = a.kind AND n.ref = a.ref;
    IF v_mob IS NULL THEN RAISE EXCEPTION 'This number is not of this contact'; END IF;
  END IF;
  IF (SELECT count(*) FROM public.lwb_dial_calls c WHERE c.called_by = auth.uid() AND c.created_at > now() - interval '1 hour') >= 120 THEN
    RAISE EXCEPTION 'Too many calls in one hour. Please wait a little.';
  END IF;
  SELECT p.full_name, lower(btrim(p.role)) INTO v_name, v_role FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.lwb_dial_calls(kind, ref, to_name, to_mobile, vehicle_no, source, called_by, called_by_name, called_by_role)
  VALUES (a.kind, a.ref, a.name || CASE WHEN p_number_id IS NOT NULL THEN ' (' || coalesce(v_lbl, 'extra no.') || ')' ELSE '' END,
          v_mob, a.vehicle_no, left(nullif(btrim(coalesce(p_source, '')), ''), 40), auth.uid(), v_name, v_role)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'mobile', v_mob, 'name', a.name);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_call(text, text, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_call(text, text, text, bigint) TO authenticated;

-- Admin contacts file: every number once. Extra numbers go on the same contact; a number already used
-- by an earlier contact (party first, then team, staff, drivers, trucks) is left out.
CREATE OR REPLACE FUNCTION public.lwb_dial_export()
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v jsonb; v_me record;
BEGIN
  IF coalesce(public.lwb_dial_role(), '') <> 'admin' THEN RAISE EXCEPTION 'Only Admin can download contacts'; END IF;
  WITH a AS (SELECT x.*, CASE x.kind WHEN 'PARTY' THEN 1 WHEN 'TEAM' THEN 2 WHEN 'STAFF' THEN 3 WHEN 'DRIVER' THEN 4 ELSE 5 END AS o FROM public.lwb_dial_all() x),
       nums AS (
         SELECT a.kind, a.ref, a.o, a.name, a.mobile, 0 AS k, 'Primary'::text AS label FROM a
         UNION ALL
         SELECT a.kind, a.ref, a.o, a.name, n.mobile, n.id, coalesce(n.label, 'Extra') FROM a JOIN public.lwb_contact_numbers n ON n.kind = a.kind AND n.ref = a.ref),
       firsts AS (SELECT DISTINCT ON (mobile) * FROM nums ORDER BY mobile, o, name, k)
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind', a.kind, 'name', a.name, 'save_as', a.save_as, 'tag', a.tag, 'sub', a.sub,
           'mobile', (SELECT f.mobile FROM firsts f WHERE f.kind = a.kind AND f.ref = a.ref AND f.k = 0),
           'numbers', (SELECT jsonb_agg(jsonb_build_object('mobile', f.mobile, 'label', f.label) ORDER BY f.k) FROM firsts f WHERE f.kind = a.kind AND f.ref = a.ref))
         ORDER BY a.o, a.name), '[]'::jsonb)
    INTO v
  FROM a WHERE EXISTS (SELECT 1 FROM firsts f WHERE f.kind = a.kind AND f.ref = a.ref);
  SELECT p.full_name INTO v_me FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.lwb_dial_calls(kind, ref, to_name, source, note, called_by, called_by_name, called_by_role)
  VALUES ('TEAM', auth.uid()::text, 'Contacts file', 'Download', jsonb_array_length(v) || ' contacts downloaded', auth.uid(), v_me.full_name, 'admin');
  RETURN v;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_export() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_export() TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';

-- Read-only count for the run log (numbers only: no names, no phone numbers).
DO $chk$
DECLARE v_p int; v_num int; v_dup_nums int; v_dup_parties int; v_team int; v_none int;
BEGIN
  SELECT count(*) INTO v_p FROM public.lwb_customer_master c WHERE coalesce(c.is_active, true) AND public.lwb_dial_mob(c.mobile) IS NOT NULL;
  SELECT count(*) INTO v_none FROM public.lwb_customer_master c WHERE coalesce(c.is_active, true) AND public.lwb_dial_mob(c.mobile) IS NULL;
  SELECT count(DISTINCT public.lwb_dial_mob(c.mobile)) INTO v_num FROM public.lwb_customer_master c WHERE coalesce(c.is_active, true) AND public.lwb_dial_mob(c.mobile) IS NOT NULL;
  SELECT count(*), coalesce(sum(n), 0) INTO v_dup_nums, v_dup_parties FROM (
    SELECT public.lwb_dial_mob(c.mobile) m, count(*) n FROM public.lwb_customer_master c
    WHERE coalesce(c.is_active, true) AND public.lwb_dial_mob(c.mobile) IS NOT NULL GROUP BY 1 HAVING count(*) > 1) q;
  SELECT count(DISTINCT public.lwb_dial_mob(c.mobile)) INTO v_team FROM public.lwb_customer_master c
    JOIN public.user_profiles p ON p.active = true AND public.lwb_dial_mob(p.mobile) = public.lwb_dial_mob(c.mobile)
    WHERE coalesce(c.is_active, true);
  RAISE NOTICE 'DIAL CHECK: active parties with mobile=%, without valid mobile=%, different numbers=%, numbers used by 2+ parties=% (parties in them=%), party numbers same as a login=%',
    v_p, v_none, v_num, v_dup_nums, v_dup_parties, v_team;
END $chk$;
