-- LUXURY WRIST BRAND ERP — DIAL BOOK: COMPANY PEOPLE (brand company sales team) (28 Nov 2026)
--
-- Mohit asked (28 Nov 2026): besides Parties, Team, Drivers and Services, a group for the company people we discuss
-- with (not drivers, not our team): the brand company sales team at every level (GSM, RTM, ASM, SO ...). Every number
-- once in the phone book, easy to call.
--
--   lwb_dial_services.grp         + 'COMPANY' (company = firm, post = category, person = name, area)
--   lwb_dial_calls.kind           + 'COMPANY'
--   lwb_dial_service_save(...)    + COMPANY (company, post and name needed); same who-may rules as Services
--   lwb_company_short(name)       COCA-COLA -> CC, RAJNIGANDHA -> RG (same as the party phone names), else the name
--   lwb_dial_all()                + COMPANY rows (kind COMPANY, tag = post). Phone / Gmail name:
--                                    NAME COMPANY POST AREA   e.g.  RAJESH PATEL CC GSM SURAT
--                                 NOTE: this file now owns lwb_dial_all (copy of lwb_vehicle_driver_history_setup.sql
--                                 + COMPANY); if that file is run again, run this file after it. If
--                                 lwb_dial_services_setup.sql is run again, run this file after it too.
--
-- Safe to run again. Nothing is dropped or deleted (two check rules are widened).

BEGIN;

DO $$ DECLARE c text; BEGIN
  FOR c IN SELECT conname FROM pg_constraint WHERE conrelid = 'public.lwb_dial_services'::regclass AND contype = 'c'
             AND pg_get_constraintdef(oid) LIKE '%COMPLAINT%' AND pg_get_constraintdef(oid) NOT LIKE '%COMPANY%' LOOP
    EXECUTE format('ALTER TABLE public.lwb_dial_services DROP CONSTRAINT %I', c);
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_dial_services_grp_chk') THEN
    ALTER TABLE public.lwb_dial_services ADD CONSTRAINT lwb_dial_services_grp_chk CHECK (grp IN ('VENDOR','SERVICE','COMPLAINT','COMPANY'));
  END IF;
  FOR c IN SELECT conname FROM pg_constraint WHERE conrelid = 'public.lwb_dial_calls'::regclass AND contype = 'c'
             AND pg_get_constraintdef(oid) LIKE '%PARTY%' AND pg_get_constraintdef(oid) NOT LIKE '%COMPANY%' LOOP
    EXECUTE format('ALTER TABLE public.lwb_dial_calls DROP CONSTRAINT %I', c);
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_dial_calls_kind_chk2') THEN
    ALTER TABLE public.lwb_dial_calls ADD CONSTRAINT lwb_dial_calls_kind_chk2 CHECK (kind IN ('PARTY','TEAM','STAFF','DRIVER','VEHICLE','SERVICE','COMPANY'));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.lwb_company_short(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN nullif(btrim(coalesce(p, '')), '') IS NULL THEN NULL
              WHEN p ILIKE '%coca%' THEN 'CC' WHEN p ILIKE '%rajni%' THEN 'RG'
              ELSE upper(regexp_replace(btrim(p), '\s+', ' ', 'g')) END
$$;
GRANT EXECUTE ON FUNCTION public.lwb_company_short(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_dial_service_save(p_id bigint, p_grp text, p_category text, p_name text, p_firm text,
  p_area text, p_mobile text, p_note text DEFAULT NULL, p_source text DEFAULT 'Dial Book')
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v_mob text := public.lwb_dial_mob(p_mobile); v_own jsonb; v_id bigint; v_me text;
        v_grp text := upper(btrim(coalesce(p_grp, ''))); v_cat text := upper(regexp_replace(btrim(coalesce(p_category, '')), '\s+', ' ', 'g'));
        v_name text := upper(nullif(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'), ''));
        v_firm text := upper(nullif(regexp_replace(btrim(coalesce(p_firm, '')), '\s+', ' ', 'g'), ''));
        v_area text := upper(nullif(btrim(coalesce(p_area, '')), ''));
BEGIN
  IF coalesce(public.lwb_dial_role(), '') NOT IN ('admin','manager','accounts','cashier') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Accounts or Cashier can save a service number';
  END IF;
  IF v_grp NOT IN ('VENDOR','SERVICE','COMPLAINT','COMPANY') THEN RAISE EXCEPTION 'Choose Vendor, Service or Complaint'; END IF;
  IF v_grp = 'COMPANY' THEN
    IF v_firm IS NULL THEN RAISE EXCEPTION 'Company: choose the company (like COCA-COLA)'; END IF;
    IF length(v_cat) < 2 THEN RAISE EXCEPTION 'Company: enter the post (like GSM, RTM, ASM)'; END IF;
    IF v_name IS NULL THEN RAISE EXCEPTION 'Company: enter the person name'; END IF;
  END IF;
  IF length(v_cat) < 2 THEN RAISE EXCEPTION 'Enter the category (like TYRE, ELECTRICIAN)'; END IF;
  IF v_name IS NULL AND v_firm IS NULL THEN RAISE EXCEPTION 'Enter the name or the firm'; END IF;
  -- Edit with the mobile box left empty keeps the saved number (the page only shows it masked).
  IF v_mob IS NULL AND p_id IS NOT NULL AND nullif(btrim(coalesce(p_mobile, '')), '') IS NULL THEN
    SELECT v.mobile INTO v_mob FROM public.lwb_dial_services v WHERE v.id = p_id AND v.active;
  END IF;
  IF v_mob IS NULL THEN RAISE EXCEPTION 'Mobile: enter a 10-digit mobile'; END IF;
  v_own := public.lwb_dial_owner(v_mob);
  IF v_own IS NOT NULL AND (v_own->>'kind' <> 'SERVICE' OR (v_own->>'ref') IS DISTINCT FROM p_id::text) THEN
    RETURN jsonb_build_object('saved', false, 'same', true, 'owner', v_own->>'name', 'owner_kind', v_own->>'kind');
  END IF;
  SELECT p.full_name INTO v_me FROM public.user_profiles p WHERE p.id = auth.uid();
  IF p_id IS NOT NULL THEN
    UPDATE public.lwb_dial_services SET grp = v_grp, category = left(v_cat, 40), name = left(v_name, 80), firm = left(v_firm, 120),
           area = left(v_area, 60), mobile = v_mob, note = left(nullif(btrim(coalesce(p_note, '')), ''), 200),
           updated_by = auth.uid(), updated_at = now()
     WHERE id = p_id AND active RETURNING id INTO v_id;
    IF v_id IS NULL THEN RAISE EXCEPTION 'Service number not found'; END IF;
  ELSE
    INSERT INTO public.lwb_dial_services(grp, category, name, firm, area, mobile, note, source, created_by, created_by_name, updated_by)
    VALUES (v_grp, left(v_cat, 40), left(v_name, 80), left(v_firm, 120), left(v_area, 60), v_mob,
            left(nullif(btrim(coalesce(p_note, '')), ''), 200), CASE WHEN p_source = 'Expense' THEN 'Expense' ELSE 'Dial Book' END,
            auth.uid(), v_me, auth.uid())
    RETURNING id INTO v_id;
  END IF;
  RETURN jsonb_build_object('saved', true, 'id', v_id, 'masked', public.lwb_dial_mask(v_mob));
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_service_save(bigint, text, text, text, text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_service_save(bigint, text, text, text, text, text, text, text, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_dial_all()
RETURNS TABLE (kind text, ref text, name text, mobile text, sub text, vehicle_no text, tag text, at timestamptz, save_as text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE r text := public.lwb_dial_role(); v_all boolean;
BEGIN
  IF r IS NULL OR r NOT IN ('admin','manager','accounts','sales','warehouse','cashier','transport') THEN
    RAISE EXCEPTION 'Dial Book: not allowed for this login';
  END IF;
  v_all := r IN ('admin','manager','accounts');
  -- Parties: Admin / Sales Head / Accounts all active parties; Salesman only his own; others none.
  IF v_all OR r = 'sales' THEN
    RETURN QUERY
      SELECT 'PARTY'::text, c.id::text, btrim(c.customer_name)::text, public.lwb_dial_mob(c.mobile),
             concat_ws(' · ', nullif(btrim(coalesce(c.city, '')), ''), 'Salesman: ' || nullif(btrim(coalesce(sp.full_name, '')), ''))::text,
             NULL::text, coalesce(c.party_type, 'WS')::text, NULL::timestamptz,
             upper(concat_ws(' ', btrim(c.customer_name), nullif(btrim(coalesce(c.city, '')), ''),
               (SELECT string_agg(CASE WHEN co.name ILIKE '%coca%' THEN 'CC' WHEN co.name ILIKE '%rajni%' THEN 'RG'
                                  ELSE left(regexp_replace(upper(co.name), '[^A-Z]', '', 'g'), 3) END, ' ' ORDER BY co.name)
                  FROM public.lwb_companies co WHERE co.id = ANY (coalesce(c.brand_ids, '{}'))),
               coalesce(c.party_type, 'WS')))::text
      FROM public.lwb_customer_master c
      LEFT JOIN public.lwb_party_salesman a ON a.customer_id = c.id
      LEFT JOIN public.user_profiles sp ON sp.id = a.salesman_id
      WHERE coalesce(c.is_active, true) AND public.lwb_dial_mob(c.mobile) IS NOT NULL
        AND (v_all OR a.salesman_id = auth.uid());
  END IF;
  -- Team: every active login with a mobile (not drivers, not me).
  RETURN QUERY
    SELECT 'TEAM'::text, p.id::text, btrim(p.full_name)::text, public.lwb_dial_mob(p.mobile), NULL::text, NULL::text,
           (CASE lower(btrim(p.role)) WHEN 'admin' THEN 'Admin' WHEN 'manager' THEN 'Sales Head' WHEN 'sales' THEN 'Salesman'
             WHEN 'warehouse' THEN 'Godown Manager' WHEN 'accounts' THEN 'Accounts' WHEN 'cashier' THEN 'Cashier'
             WHEN 'transport' THEN 'Transport' ELSE initcap(p.role) END)::text, NULL::timestamptz,
           upper(btrim(p.full_name) || ' LWB ' || CASE lower(btrim(p.role)) WHEN 'admin' THEN 'ADMIN' WHEN 'manager' THEN 'SALES HEAD'
             WHEN 'sales' THEN 'SALESMAN' WHEN 'warehouse' THEN 'GODOWN MANAGER' WHEN 'accounts' THEN 'ACCOUNTS' WHEN 'cashier' THEN 'CASHIER'
             WHEN 'transport' THEN 'TRANSPORT' ELSE p.role END)::text
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(coalesce(p.role, ''))) <> 'driver' AND p.id <> auth.uid()
      AND nullif(btrim(coalesce(p.full_name, '')), '') IS NOT NULL AND public.lwb_dial_mob(p.mobile) IS NOT NULL;
  -- Employee Master staff (loaders, helpers ...) whose mobile is not already a login: Admin / Sales Head / Accounts / GM.
  IF v_all OR r = 'warehouse' THEN
    RETURN QUERY
      SELECT 'STAFF'::text, s.id::text, btrim(s.name)::text, public.lwb_dial_mob(s.mobile), NULL::text, NULL::text,
             coalesce(nullif(btrim(coalesce(s.designation, '')), ''), 'Staff')::text, NULL::timestamptz,
             upper(btrim(s.name) || ' LWB ' || coalesce(nullif(btrim(coalesce(s.designation, '')), ''), 'STAFF'))::text
      FROM public.lwb_acc_staff s
      WHERE s.active AND public.lwb_dial_mob(s.mobile) IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.active = true AND public.lwb_dial_mob(p.mobile) = public.lwb_dial_mob(s.mobile));
  END IF;
  -- Own drivers (driver logins).
  RETURN QUERY
    SELECT 'DRIVER'::text, p.id::text, btrim(p.full_name)::text, public.lwb_dial_mob(p.mobile), 'Own driver'::text, NULL::text,
           'Driver'::text, NULL::timestamptz, upper(btrim(p.full_name) || ' LWB DRIVER')::text
    FROM public.user_profiles p
    WHERE p.active = true AND lower(btrim(coalesce(p.role, ''))) = 'driver'
      AND nullif(btrim(coalesce(p.full_name, '')), '') IS NOT NULL AND public.lwb_dial_mob(p.mobile) IS NOT NULL;
  -- Purchase truck drivers (Mohit, 28 Nov 2026): the current driver of every vehicle, kept for ever.
  RETURN QUERY
    SELECT 'VEHICLE'::text, v.vehicle_key, (v.vehicle_no || coalesce(' · ' || nullif(btrim(coalesce(v.driver_name, '')), ''), ''))::text,
           v.driver_mobile,
           concat_ws(' · ', nullif(btrim(coalesce(v.transport_name, '')), ''),
                     CASE WHEN t.id IS NOT NULL THEN 'ECRS ' || to_char(t.day, 'DD/MM') END,
                     CASE WHEN h.trips > 1 THEN h.trips || ' trips' END)::text,
           v.vehicle_no, 'Truck driver'::text, v.updated_at,
           public.lwb_vehicle_save_as(v.vehicle_no, v.driver_name, v.transport_name)
    FROM public.lwb_vehicle_driver v
    LEFT JOIN public.lwb_ecrs_trucks t ON t.id = v.ecrs_truck_id
    LEFT JOIN public.lwb_vehicle_driver_hist h ON h.vehicle_key = v.vehicle_key AND h.driver_mobile = v.driver_mobile;
  -- Old drivers: every number once (newest vehicle), not when it is some vehicle's current driver.
  RETURN QUERY
    SELECT 'VEHICLE'::text, (h.vehicle_key || ':' || h.driver_mobile)::text,
           (h.vehicle_no || coalesce(' · ' || nullif(btrim(coalesce(h.driver_name, '')), ''), ''))::text,
           h.driver_mobile,
           concat_ws(' · ', nullif(btrim(coalesce(h.transport_name, '')), ''), 'Last trip ' || to_char(h.last_at AT TIME ZONE 'Asia/Kolkata', 'DD/MM/YY'))::text,
           h.vehicle_no, 'Old driver'::text, h.last_at,
           public.lwb_vehicle_save_as(h.vehicle_no, h.driver_name, h.transport_name)
    FROM (SELECT DISTINCT ON (x.driver_mobile) x.* FROM public.lwb_vehicle_driver_hist x
           WHERE NOT EXISTS (SELECT 1 FROM public.lwb_vehicle_driver c WHERE c.driver_mobile = x.driver_mobile)
           ORDER BY x.driver_mobile, x.last_at DESC) h;
  -- Services (Mohit, 27 Nov 2026): vendors, service agencies, complaint numbers. Every Dial Book login.
  RETURN QUERY
    SELECT 'SERVICE'::text, v.id::text, coalesce(nullif(btrim(coalesce(v.name, '')), ''), v.firm)::text, v.mobile,
           concat_ws(' · ', CASE WHEN nullif(btrim(coalesce(v.name, '')), '') IS NOT NULL THEN nullif(btrim(coalesce(v.firm, '')), '') END,
                     nullif(btrim(coalesce(v.area, '')), ''))::text,
           NULL::text, (CASE v.grp WHEN 'VENDOR' THEN 'Vendor' WHEN 'SERVICE' THEN 'Service' ELSE 'Complaint' END || ' · ' || initcap(v.category))::text,
           v.updated_at,
           upper(concat_ws(' ', nullif(btrim(coalesce(v.name, '')), ''), nullif(btrim(coalesce(v.firm, '')), ''),
                 v.category,
                 'LWB', v.grp))::text
    FROM public.lwb_dial_services v
    WHERE v.active AND v.grp <> 'COMPANY';
  -- Company people (Mohit, 28 Nov 2026): brand company sales team (GSM, RTM, ASM ...). Every Dial Book login.
  RETURN QUERY
    SELECT 'COMPANY'::text, v.id::text, v.name::text, v.mobile,
           concat_ws(' · ', nullif(btrim(coalesce(v.firm, '')), ''), nullif(btrim(coalesce(v.area, '')), ''))::text,
           NULL::text, v.category::text, v.updated_at,
           upper(concat_ws(' ', v.name, public.lwb_company_short(v.firm), v.category, nullif(btrim(coalesce(v.area, '')), '')))::text
    FROM public.lwb_dial_services v
    WHERE v.active AND v.grp = 'COMPANY';
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_all() FROM PUBLIC, anon, authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
