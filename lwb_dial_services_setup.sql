-- LUXURY WRIST BRAND ERP — DIAL BOOK: SERVICES (vendors, service agencies, complaint numbers) (27 Nov 2026)
--
-- Mohit asked (27 Nov 2026):
--   * Calls to the team need no reason. The reason / result is only for party calls (sales work): dial-book.js.
--   * A "Services" list in the Dial Book for everybody we work with outside the company:
--       VENDOR    we bought from / paid (forklift seller, labour contractor, pallet supplier ...)
--       SERVICE   agencies we take a service from (transport, tyre, mechanic, forklift service, CCTV ...)
--       COMPLAINT who to call when something breaks (electrician, water / plumber, landlord, internet ...)
--     each with a category, firm, area. Phone contact name: NAME FIRM CATEGORY LWB VENDOR / SERVICE / COMPLAINT.
--   * A Cash Out (expense) entry in Accounts can carry the payee mobile: it is saved here with the expense
--     category (source 'Expense'). A number already in the ERP is never saved twice (no error, no popup).
--
--   lwb_dial_services            the list (mobile unique among active rows)
--   lwb_dial_service_save(...)   Admin / Sales Head / Accounts / Cashier. {saved:false, same:true, owner} if the number exists.
--   lwb_dial_service_remove(id)  Admin / Sales Head / Accounts (kept, marked inactive)
--   lwb_dial_services_list()     rows for the Services tab (masked numbers), every Dial Book login
--   lwb_dial_all() / lwb_dial_owner()  + SERVICE rows, so Call, Recent, Call log and the contacts file include them.
--   lwb_dial_calls.kind          + 'SERVICE'
--
-- Run after lwb_dial_book_setup.sql and lwb_dial_book_numbers_setup.sql (re-running those restores the
-- old lwb_dial_all / lwb_dial_owner without services: run this file again after them).
-- Safe to run again. Nothing is dropped or deleted (only the kind check of lwb_dial_calls is widened).

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_dial_services (
  id bigserial PRIMARY KEY,
  grp text NOT NULL CHECK (grp IN ('VENDOR','SERVICE','COMPLAINT')),
  category text NOT NULL CHECK (length(btrim(category)) BETWEEN 2 AND 40),
  name text CHECK (name IS NULL OR length(name) <= 80),
  firm text CHECK (firm IS NULL OR length(firm) <= 120),
  area text CHECK (area IS NULL OR length(area) <= 60),
  mobile text NOT NULL CHECK (mobile ~ '^[6-9][0-9]{9}$'),
  note text CHECK (note IS NULL OR length(note) <= 200),
  source text NOT NULL DEFAULT 'Dial Book' CHECK (source IN ('Dial Book','Expense')),
  active boolean NOT NULL DEFAULT true,
  created_by uuid DEFAULT auth.uid(),
  created_by_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (nullif(btrim(coalesce(name, '')), '') IS NOT NULL OR nullif(btrim(coalesce(firm, '')), '') IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS lwb_dial_services_mobile_uidx ON public.lwb_dial_services(mobile) WHERE active;
ALTER TABLE public.lwb_dial_services ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_dial_services FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_dial_services_id_seq FROM PUBLIC, anon, authenticated;

-- Call log accepts SERVICE.
DO $$ DECLARE c text; BEGIN
  FOR c IN SELECT conname FROM pg_constraint WHERE conrelid = 'public.lwb_dial_calls'::regclass AND contype = 'c'
             AND pg_get_constraintdef(oid) LIKE '%PARTY%' AND pg_get_constraintdef(oid) NOT LIKE '%SERVICE%' LOOP
    EXECUTE format('ALTER TABLE public.lwb_dial_calls DROP CONSTRAINT %I', c);
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_dial_calls_kind_chk') THEN
    ALTER TABLE public.lwb_dial_calls ADD CONSTRAINT lwb_dial_calls_kind_chk CHECK (kind IN ('PARTY','TEAM','STAFF','DRIVER','VEHICLE','SERVICE'));
  END IF;
END $$;

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
    UNION ALL
    SELECT jsonb_build_object('kind', 'SERVICE', 'ref', v.id::text, 'name', coalesce(nullif(btrim(coalesce(v.name, '')), ''), v.firm), 'extra', false), 5
      FROM public.lwb_dial_services v, m WHERE m.v IS NOT NULL AND v.active AND v.mobile = m.v
  ) q ORDER BY o LIMIT 1
$$;
REVOKE ALL ON FUNCTION public.lwb_dial_owner(text) FROM PUBLIC, anon, authenticated;

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
  -- Purchase truck drivers: vehicle + driver entered in the last 30 days.
  RETURN QUERY
    SELECT 'VEHICLE'::text, v.vehicle_key, (v.vehicle_no || coalesce(' · ' || nullif(btrim(coalesce(v.driver_name, '')), ''), ''))::text,
           v.driver_mobile,
           CASE WHEN t.id IS NOT NULL THEN 'ECRS ' || to_char(t.day, 'DD/MM') ELSE 'Purchase truck' END::text,
           v.vehicle_no, 'Truck driver'::text, v.updated_at,
           upper(concat_ws(' ', v.vehicle_no, nullif(btrim(coalesce(v.driver_name, '')), ''), 'TRUCK DRIVER'))::text
    FROM public.lwb_vehicle_driver v
    LEFT JOIN public.lwb_ecrs_trucks t ON t.id = v.ecrs_truck_id
    WHERE v.updated_at > now() - interval '30 days';
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
    WHERE v.active;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_all() FROM PUBLIC, anon, authenticated;

-- Save (new or edit). A number already in the ERP is NOT saved: saved=false + who has it, never an error.
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
  IF v_grp NOT IN ('VENDOR','SERVICE','COMPLAINT') THEN RAISE EXCEPTION 'Choose Vendor, Service or Complaint'; END IF;
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

CREATE OR REPLACE FUNCTION public.lwb_dial_service_remove(p_id bigint)
RETURNS boolean LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
BEGIN
  IF coalesce(public.lwb_dial_role(), '') NOT IN ('admin','manager','accounts') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can remove a service number';
  END IF;
  UPDATE public.lwb_dial_services SET active = false, updated_by = auth.uid(), updated_at = now() WHERE id = p_id AND active;
  RETURN FOUND;
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_service_remove(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_service_remove(bigint) TO authenticated;

-- Services tab: masked numbers + the fields to filter and edit.
CREATE OR REPLACE FUNCTION public.lwb_dial_services_list()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE r text := public.lwb_dial_role();
BEGIN
  IF r IS NULL OR r NOT IN ('admin','manager','accounts','sales','warehouse','cashier','transport') THEN
    RAISE EXCEPTION 'Dial Book: not allowed for this login';
  END IF;
  RETURN jsonb_build_object('can_edit', r IN ('admin','manager','accounts','cashier'), 'can_remove', r IN ('admin','manager','accounts'),
    'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'grp', v.grp, 'category', v.category, 'name', v.name, 'firm', v.firm,
               'area', v.area, 'note', v.note, 'source', v.source, 'masked', public.lwb_dial_mask(v.mobile), 'last4', right(v.mobile, 4),
               'by', v.created_by_name, 'at', v.created_at) ORDER BY v.grp, v.category, coalesce(v.name, v.firm)), '[]'::jsonb)
             FROM public.lwb_dial_services v WHERE v.active));
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_services_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_services_list() TO authenticated;

COMMIT;
NOTIFY pgrst, 'reload schema';
