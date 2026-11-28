-- LUXURY WRIST BRAND ERP — 📞 CALL BUTTON ON EVERY PAGE (28 Nov 2026)
--
-- Mohit asked (28 Nov 2026): a direct Call button wherever the ERP shows a person we need to call: party outstanding,
-- party ledger, payment collection, party master, our own delivery drivers (loading / dispatch, transport allocation,
-- driver collections, live tracking), the purchase truck driver ...
--
-- Pages only know a party name / party id, a login id, a mobile or a vehicle no. This finds the Dial Book contact
-- for them, so the call goes through lwb_dial_call (full number only at call time, every call logged, log seen by
-- Admin only). Same who-sees-what as the Dial Book: a salesman finds only his own parties, Godown Manager no parties,
-- driver logins nothing. No phone number is returned here.
--
--   lwb_dial_norm(text)          letters + digits, upper case (party name match: "Shree Jagdish Trader." = "SHREE JAGDISH TRADER")
--   lwb_dial_find(p_items jsonb) [{k, v}] -> [{k, v, kind, ref}] only for the ones found.
--                                 k = PARTY (party id or name) | USER (login id: own driver / team) | DRIVER / TEAM (login name: own driver, salesman ...)
--                                     | MOB (mobile) | VEH (vehicle no.)
--
-- Safe to run again. Nothing is dropped or deleted.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_dial_norm(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

CREATE OR REPLACE FUNCTION public.lwb_dial_find(p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE r text := public.lwb_dial_role(); v jsonb;
BEGIN
  -- Not a Dial Book login (driver, no login): no Call buttons, no error on the page.
  IF r IS NULL OR r NOT IN ('admin','manager','accounts','sales','warehouse','cashier','transport') THEN RETURN '[]'::jsonb; END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN RETURN '[]'::jsonb; END IF;
  IF jsonb_array_length(p_items) > 600 THEN RAISE EXCEPTION 'Too many names in one go'; END IF;
  WITH a AS (
         SELECT x.kind, x.ref, x.name, x.mobile, public.lwb_dial_norm(x.name) AS nk,
                CASE x.kind WHEN 'DRIVER' THEN 1 WHEN 'TEAM' THEN 2 WHEN 'STAFF' THEN 3 WHEN 'VEHICLE' THEN 4 WHEN 'PARTY' THEN 5 ELSE 6 END AS o
         FROM public.lwb_dial_all() x),
       i AS (
         SELECT DISTINCT upper(btrim(e->>'k')) AS k, btrim(e->>'v') AS v
         FROM jsonb_array_elements(p_items) e
         WHERE jsonb_typeof(e) = 'object' AND nullif(btrim(coalesce(e->>'v', '')), '') IS NOT NULL),
       m AS (
         SELECT DISTINCT ON (i.k, i.v) i.k, i.v, a.kind, a.ref
         FROM i JOIN a ON
              (i.k = 'PARTY' AND a.kind = 'PARTY' AND (a.ref = i.v OR (a.nk <> '' AND a.nk = public.lwb_dial_norm(i.v))))
           OR (i.k = 'USER'  AND a.kind IN ('DRIVER','TEAM') AND a.ref = i.v)
           OR (i.k IN ('DRIVER','TEAM') AND a.kind = i.k AND a.nk <> '' AND a.nk = public.lwb_dial_norm(i.v))
           OR (i.k = 'MOB'   AND a.mobile = public.lwb_dial_mob(i.v))
           OR (i.k = 'VEH'   AND a.kind = 'VEHICLE' AND a.ref = public.lwb_vehicle_key(i.v))
         ORDER BY i.k, i.v, (a.ref = i.v) DESC, a.o, a.name, a.ref)
  SELECT coalesce(jsonb_agg(jsonb_build_object('k', m.k, 'v', m.v, 'kind', m.kind, 'ref', m.ref)), '[]'::jsonb) INTO v FROM m;
  RETURN v;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_find(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_find(jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
