-- ONE-TIME DATA FIX (18 Nov 2026, Mohit chose "Sales Head, Rajnigandha only"):
-- Vinesh Chalavadiya's login was a Godown Manager (warehouse) login, so Purchase Claims,
-- amounts, bill PDF and photo tasks were hidden. Make it a Sales Head (manager) login
-- limited to the RAJNIGANDHA company. Only user_profiles.role and lwb_user_companies change.
BEGIN;
DO $do$
DECLARE v_id uuid; v_n int; v_co uuid;
BEGIN
  SELECT count(*), min(p.id::text)::uuid INTO v_n, v_id FROM public.user_profiles p
   WHERE p.full_name ILIKE 'vinesh%' AND p.full_name ILIKE '%chalavadiya%';
  IF v_n <> 1 THEN RAISE EXCEPTION 'Expected 1 Vinesh Chalavadiya login, found %', v_n; END IF;
  SELECT c.id INTO v_co FROM public.lwb_companies c WHERE upper(btrim(c.name)) = 'RAJNIGANDHA';
  IF v_co IS NULL THEN RAISE EXCEPTION 'RAJNIGANDHA company not found'; END IF;
  UPDATE public.user_profiles SET role = 'manager' WHERE id = v_id;
  DELETE FROM public.lwb_user_companies WHERE user_id = v_id;
  INSERT INTO public.lwb_user_companies(user_id, company_id) VALUES (v_id, v_co);
END
$do$;
COMMIT;
