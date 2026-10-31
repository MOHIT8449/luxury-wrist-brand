-- LUXURY WRIST BRAND ERP — ONE STAFF LIST: DRIVER MASTER MERGED INTO EMPLOYEE MASTER
--
-- Runs by itself when merged to main (after lwb_employee_master_setup.sql, lwb_fleet_master_setup.sql,
-- lwb_documents_setup.sql and lwb_latest_first_setup.sql). Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (31 Oct 2026): no separate Driver Master. Every staff member is kept once in Employee Master
-- with a Work / Post (Driver, Loader, Godown Manager, Manager, ...). Wherever a person is picked
-- (PO Approval & Driver, Transport Assignment) the list of that post comes from Employee Master by itself,
-- and vehicles from Vehicle Master.
--
-- This file:
--   * adds the driver details to lwb_acc_staff (alternate mobile, licence no. / expiry, default vehicle,
--     transporter, address);
--   * copies every Driver Master row (lwb_drivers) into Employee Master once: matched by mobile number,
--     else by the same name without a mobile, else added as a new employee with Work / Post "Driver"
--     (salary 0). lwb_drivers.staff_id remembers where each driver went, so running again copies nothing twice.
--     The driver's photo / licence / Aadhaar / bank files and numbers move to that employee.
--     lwb_drivers itself is kept untouched as a record (no row is deleted);
--   * lwb_emp_list2 / lwb_emp_save2: Employee Master with the driver details (they call lwb_emp_list /
--     lwb_emp_save, so the salary rules stay in one place);
--   * lwb_staff_pick(role): active employees of one Work / Post (name, mobile, vehicle; no salary) for the
--     pick lists.
-- The Driver Portal is not changed: a driver login is still matched to orders by the same 10-digit mobile.
-- No order, dispatch, bill, stock, payment, ledger or Tally data is changed.

BEGIN;

ALTER TABLE public.lwb_acc_staff
  ADD COLUMN IF NOT EXISTS alt_mobile text,
  ADD COLUMN IF NOT EXISTS license_no text,
  ADD COLUMN IF NOT EXISTS license_expiry date,
  ADD COLUMN IF NOT EXISTS default_vehicle_id uuid,
  ADD COLUMN IF NOT EXISTS transporter_name text,
  ADD COLUMN IF NOT EXISTS address text;

DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_acc_staff_alt_mobile_chk') THEN
    ALTER TABLE public.lwb_acc_staff ADD CONSTRAINT lwb_acc_staff_alt_mobile_chk CHECK (alt_mobile IS NULL OR alt_mobile ~ '^[6-9][0-9]{9}$');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_acc_staff_driver_text_chk') THEN
    ALTER TABLE public.lwb_acc_staff ADD CONSTRAINT lwb_acc_staff_driver_text_chk
      CHECK (length(coalesce(license_no,'')) <= 40 AND length(coalesce(transporter_name,'')) <= 150 AND length(coalesce(address,'')) <= 500);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_acc_staff_vehicle_fk') THEN
    ALTER TABLE public.lwb_acc_staff ADD CONSTRAINT lwb_acc_staff_vehicle_fk
      FOREIGN KEY (default_vehicle_id) REFERENCES public.lwb_vehicles(id) ON DELETE SET NULL;
  END IF;
END $do$;

-- Where each old Driver Master row went.
ALTER TABLE public.lwb_drivers ADD COLUMN IF NOT EXISTS staff_id bigint;

-- Work / Post key: 'driver', 'loader', 'godown manager', ... (blank = '').
CREATE OR REPLACE FUNCTION public.lwb_emp_role(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$ SELECT lower(regexp_replace(btrim(coalesce(p,'')), '\s+', ' ', 'g')); $fn$;

-- Last 10 digits of an Indian mobile ('' when it is not one).
CREATE OR REPLACE FUNCTION public.lwb_emp_phone(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE WHEN d ~ '^[6-9][0-9]{9}$' THEN d WHEN d ~ '^(91|0)[6-9][0-9]{9}$' THEN right(d, 10) ELSE '' END
  FROM (SELECT regexp_replace(coalesce(p,''), '\D', '', 'g') AS d) x;
$fn$;

-- ---------------------------------------------------------------------------
-- Copy Driver Master into Employee Master (once per driver).
-- ---------------------------------------------------------------------------
DO $do$
DECLARE d record; v_sid bigint; v_mob text; v_name text; s public.lwb_acc_staff%ROWTYPE; v_docs boolean;
BEGIN
  v_docs := to_regclass('public.lwb_documents') IS NOT NULL AND to_regclass('public.lwb_doc_info') IS NOT NULL;
  FOR d IN SELECT * FROM public.lwb_drivers WHERE staff_id IS NULL ORDER BY created_at, id LOOP
    v_mob := public.lwb_emp_phone(d.mobile);
    v_name := left(btrim(regexp_replace(d.driver_name, '\s+', ' ', 'g')), 80);
    v_sid := NULL;
    -- 1. same mobile (a driver already in Employee Master first)
    IF v_mob <> '' THEN
      SELECT x.id INTO v_sid FROM public.lwb_acc_staff x WHERE public.lwb_emp_phone(x.mobile) = v_mob
      ORDER BY (public.lwb_emp_role(x.designation) = 'driver') DESC, x.active DESC, x.id LIMIT 1;
    END IF;
    -- 2. same name, no mobile saved on the employee
    IF v_sid IS NULL THEN
      SELECT x.id INTO v_sid FROM public.lwb_acc_staff x
      WHERE lower(btrim(x.name)) = lower(v_name) AND public.lwb_emp_phone(x.mobile) = '' LIMIT 1;
    END IF;
    IF v_sid IS NOT NULL THEN
      SELECT * INTO s FROM public.lwb_acc_staff WHERE id = v_sid;
      UPDATE public.lwb_acc_staff SET
        designation = 'Driver',
        note = CASE WHEN public.lwb_emp_role(s.designation) IN ('', 'driver') THEN s.note
                    ELSE left(btrim(coalesce(s.note || ' · ', '') || 'Work / Post was ' || s.designation), 300) END,
        mobile = CASE WHEN public.lwb_emp_phone(s.mobile) = '' AND v_mob <> '' THEN v_mob ELSE s.mobile END,
        alt_mobile = coalesce(s.alt_mobile, nullif(public.lwb_emp_phone(d.alt_mobile), '')),
        license_no = coalesce(s.license_no, left(nullif(upper(btrim(d.license_no)), ''), 40)),
        license_expiry = coalesce(s.license_expiry, d.license_expiry),
        default_vehicle_id = coalesce(s.default_vehicle_id, d.default_vehicle_id),
        transporter_name = coalesce(s.transporter_name, left(nullif(btrim(d.transporter_name), ''), 150)),
        address = coalesce(s.address, left(nullif(btrim(d.address), ''), 500)),
        active = s.active OR d.is_active
      WHERE id = v_sid;
    ELSE
      -- Name already used by another employee (other mobile): keep both, add the last 4 digits.
      IF EXISTS (SELECT 1 FROM public.lwb_acc_staff x WHERE lower(btrim(x.name)) = lower(v_name)) THEN
        v_name := left(v_name, 72) || ' (' || right(coalesce(nullif(v_mob, ''), d.mobile), 4) || ')';
      END IF;
      INSERT INTO public.lwb_acc_staff (name, mobile, designation, monthly_salary, active, note, created_by, created_at,
        alt_mobile, license_no, license_expiry, default_vehicle_id, transporter_name, address)
      VALUES (v_name, nullif(v_mob, ''), 'Driver', 0, d.is_active, left(nullif(btrim(d.note), ''), 300), d.created_by, d.created_at,
        nullif(public.lwb_emp_phone(d.alt_mobile), ''), left(nullif(upper(btrim(d.license_no)), ''), 40), d.license_expiry,
        d.default_vehicle_id, left(nullif(btrim(d.transporter_name), ''), 150), left(nullif(btrim(d.address), ''), 500))
      RETURNING id INTO v_sid;
    END IF;
    UPDATE public.lwb_drivers SET staff_id = v_sid WHERE id = d.id;
    IF v_docs THEN
      -- Photo, licence, Aadhaar, bank, PAN files: same files, now shown on the employee.
      UPDATE public.lwb_documents SET entity_type = 'STAFF', entity_id = v_sid::text
      WHERE entity_type = 'DRIVER' AND entity_id = d.id::text;
      -- Aadhaar no. / PAN / bank numbers: what the employee already has wins, the driver's fills the gaps.
      INSERT INTO public.lwb_doc_info AS t (entity_type, entity_id, info, updated_by, updated_at)
      SELECT 'STAFF', v_sid::text, i.info, i.updated_by, i.updated_at FROM public.lwb_doc_info i
      WHERE i.entity_type = 'DRIVER' AND i.entity_id = d.id::text
      ON CONFLICT (entity_type, entity_id) DO UPDATE SET info = excluded.info || t.info;
    END IF;
  END LOOP;
END $do$;

-- Who may read the pick lists: whoever could read Driver Master before (Admin, Manager, Transport, Godown),
-- Employee Master keepers, and logins given PO Approval / Transport Assignment by Admin.
CREATE OR REPLACE FUNCTION public.lwb_staff_pick_reader()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.lwb_fleet_reader() OR public.lwb_emp_editor() THEN RETURN true; END IF;
  IF to_regprocedure('public.lwb_has_page(text)') IS NULL THEN RETURN false; END IF;
  RETURN EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) <> 'driver')
     AND (public.lwb_has_page('warehouse-orders.html') OR public.lwb_has_page('transport-allocation.html'));
END;
$fn$;

-- Active employees of one Work / Post (p_role blank = all), A–Z. No salary or ledger.
CREATE OR REPLACE FUNCTION public.lwb_staff_pick(p_role text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_role text := public.lwb_emp_role(p_role);
BEGIN
  IF NOT public.lwb_staff_pick_reader() THEN RAISE EXCEPTION 'You can not read the staff list'; END IF;
  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object('id', s.id, 'emp_code', s.emp_code, 'name', s.name, 'mobile', s.mobile,
      'alt_mobile', s.alt_mobile, 'designation', s.designation, 'role', public.lwb_emp_role(s.designation),
      'default_vehicle_id', s.default_vehicle_id, 'vehicle_no', v.vehicle_no, 'transporter_name', s.transporter_name,
      'license_expiry', s.license_expiry)
      ORDER BY lower(s.name))
    FROM public.lwb_acc_staff s LEFT JOIN public.lwb_vehicles v ON v.id = s.default_vehicle_id
    WHERE s.active AND (v_role = '' OR public.lwb_emp_role(s.designation) = v_role)), '[]'::jsonb);
END;
$fn$;

-- Employee Master list with the driver details.
CREATE OR REPLACE FUNCTION public.lwb_emp_list2()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v jsonb := public.lwb_emp_list();
BEGIN
  RETURN jsonb_set(v, '{rows}', coalesce((
    SELECT jsonb_agg(e.r || jsonb_build_object('alt_mobile', s.alt_mobile, 'license_no', s.license_no,
      'license_expiry', s.license_expiry, 'default_vehicle_id', s.default_vehicle_id, 'vehicle_no', vh.vehicle_no,
      'transporter_name', s.transporter_name, 'address', s.address) ORDER BY e.n)
    FROM jsonb_array_elements(coalesce(v->'rows', '[]'::jsonb)) WITH ORDINALITY e(r, n)
    LEFT JOIN public.lwb_acc_staff s ON s.id = (e.r->>'id')::bigint
    LEFT JOIN public.lwb_vehicles vh ON vh.id = s.default_vehicle_id), '[]'::jsonb));
END;
$fn$;

-- Same p as lwb_emp_save + alt_mobile, license_no, license_expiry, default_vehicle_id, transporter_name, address.
-- A Driver needs a 10-digit mobile (the Driver Portal login is matched by it), and two working drivers
-- can not have the same mobile.
CREATE OR REPLACE FUNCTION public.lwb_emp_save2(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE r jsonb; v_id bigint; v_driver boolean := public.lwb_emp_role(p->>'designation') = 'driver';
        v_mob text := public.lwb_emp_phone(p->>'mobile'); v_alt text := nullif(regexp_replace(coalesce(p->>'alt_mobile',''), '\D', '', 'g'), '');
        v_lic text := nullif(upper(btrim(coalesce(p->>'license_no',''))), ''); v_exp date; v_veh uuid;
        v_tr text := nullif(btrim(coalesce(p->>'transporter_name','')), ''); v_addr text := nullif(btrim(coalesce(p->>'address','')), '');
        v_other text;
BEGIN
  IF NOT public.lwb_emp_editor() THEN RAISE EXCEPTION 'Only Admin, Manager, Godown or Accounts can change Employee Master'; END IF;
  BEGIN
    v_id := nullif(p->>'id','')::bigint;
    v_exp := nullif(p->>'license_expiry','')::date;
    v_veh := nullif(p->>'default_vehicle_id','')::uuid;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Check the licence expiry date and the vehicle';
  END;
  IF v_alt IS NOT NULL THEN v_alt := public.lwb_emp_phone(v_alt); IF v_alt = '' THEN RAISE EXCEPTION 'Alternate mobile should be 10 digits'; END IF; END IF;
  IF length(coalesce(v_lic,'')) > 40 THEN RAISE EXCEPTION 'Licence number is too long'; END IF;
  IF length(coalesce(v_tr,'')) > 150 THEN RAISE EXCEPTION 'Transporter name is too long'; END IF;
  IF length(coalesce(v_addr,'')) > 500 THEN RAISE EXCEPTION 'Address is too long'; END IF;
  IF v_veh IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_vehicles x WHERE x.id = v_veh) THEN RAISE EXCEPTION 'Vehicle not found in Vehicle Master'; END IF;
  IF v_driver THEN
    IF v_mob = '' THEN RAISE EXCEPTION 'A Driver needs a 10-digit mobile number (the Driver Portal login is matched by it)'; END IF;
    IF coalesce((p->>'is_active')::boolean, true) THEN
      SELECT x.emp_code || ' · ' || x.name INTO v_other FROM public.lwb_acc_staff x
      WHERE x.active AND public.lwb_emp_role(x.designation) = 'driver' AND public.lwb_emp_phone(x.mobile) = v_mob
        AND x.id IS DISTINCT FROM v_id LIMIT 1;
      IF v_other IS NOT NULL THEN RAISE EXCEPTION 'Mobile % is already given to driver %', v_mob, v_other; END IF;
    END IF;
  END IF;
  r := public.lwb_emp_save(p);
  UPDATE public.lwb_acc_staff SET alt_mobile = v_alt, license_no = v_lic, license_expiry = v_exp, default_vehicle_id = v_veh,
    transporter_name = v_tr, address = v_addr
  WHERE id = (r->>'id')::bigint;
  RETURN r;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_staff_pick_reader(), public.lwb_staff_pick(text), public.lwb_emp_list2(), public.lwb_emp_save2(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_staff_pick_reader(), public.lwb_staff_pick(text), public.lwb_emp_list2(), public.lwb_emp_save2(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_emp_role(text), public.lwb_emp_phone(text) TO authenticated;

-- Driving licence can now be kept on an employee (lwb_documents_setup.sql has the same list).
CREATE OR REPLACE FUNCTION public.lwb_doc_types(p_entity text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE p_entity
    WHEN 'STAFF' THEN ARRAY['PHOTO','DL','AADHAAR','PAN','BANK','OTHER']
    WHEN 'DRIVER' THEN ARRAY['PHOTO','DL','AADHAAR','PAN','BANK','OTHER']
    WHEN 'USER' THEN ARRAY['PHOTO','AADHAAR','PAN','BANK','OTHER']
    WHEN 'VEHICLE' THEN ARRAY['PHOTO','RC','INSURANCE','PUC','FITNESS','PERMIT','OTHER']
    WHEN 'PARTY' THEN ARRAY['SHOP','OWNER','PAN','GST','CHEQUE','OTHER']
    WHEN 'SUPPLIER' THEN ARRAY['GST','PAN','CHEQUE','OTHER']
    WHEN 'PURCHASE_BILL' THEN ARRAY['BILL','DAMAGE','OTHER']
    WHEN 'ASSET' THEN ARRAY['PHOTO','BILL','WARRANTY','OTHER']
    WHEN 'STOCK_MOVE' THEN ARRAY['DAMAGE','OTHER']
    WHEN 'ORDER' THEN ARRAY['LOADED','DAMAGE','OTHER']
    ELSE NULL END;
$fn$;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'driver master rows' AS item, (SELECT count(*) FROM public.lwb_drivers)::text AS value
UNION ALL SELECT 'copied to employee master', (SELECT count(*) FROM public.lwb_drivers WHERE staff_id IS NOT NULL)::text
UNION ALL SELECT 'working drivers in employee master', (SELECT count(*) FROM public.lwb_acc_staff WHERE active AND public.lwb_emp_role(designation) = 'driver')::text;
