-- LUXURY WRIST BRAND ERP — ACCOUNTS DASHBOARD: VEHICLE-WISE EXPENSES
--
-- Runs by itself when merged to main (after lwb_accounts_staff_setup.sql and lwb_fleet_master_setup.sql).
-- Safe to run again. Nothing is dropped or deleted.
--
-- Mohit asked (30 Oct 2026): in Cash Out the party can be a vehicle. A vehicle has many expenses:
-- driver food / bhatta, repair, service, tyre, petrol / diesel ... and he wants to see them per vehicle.
--
-- Vehicles come from the Vehicle Master (lwb_vehicles, Fleet). A Cash Out entry may carry the vehicle;
-- the head (Diesel / Fuel, Repair, Tyre ...) says what the money was for. The Vehicles tab adds them up
-- per vehicle and per head for the dates chosen, with a ledger for each vehicle.

BEGIN;

-- Heads that vehicles need (the old ones Diesel / Fuel, Repair, Maintenance, Food stay as they are).
INSERT INTO public.lwb_acc_categories (kind, name, sort)
SELECT 'OUT', v.name, v.sort FROM (VALUES
  ('Vehicle service', 92), ('Tyre', 93), ('Driver bhatta / food', 94), ('Toll / Parking', 95),
  ('RTO / Insurance / PUC', 96), ('Vehicle washing', 97)) AS v(name, sort)
WHERE NOT EXISTS (SELECT 1 FROM public.lwb_acc_categories c WHERE c.kind = 'OUT' AND lower(btrim(c.name)) = lower(v.name));

ALTER TABLE public.lwb_acc_entries
  ADD COLUMN IF NOT EXISTS vehicle_id uuid REFERENCES public.lwb_vehicles(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS lwb_acc_entries_vehicle_idx ON public.lwb_acc_entries (vehicle_id, entry_date) WHERE vehicle_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Save an entry with an optional vehicle (everything else as lwb_acc_add_entry2).
-- p adds: {"vehicle_id":"<uuid>"}. The party becomes the vehicle no. when none is typed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_acc_add_entry3(p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id uuid; v_veh uuid; v_no text;
BEGIN
  BEGIN v_veh := nullif(p->>'vehicle_id','')::uuid;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Choose the vehicle again';
  END;
  IF v_veh IS NOT NULL THEN
    IF coalesce(p->>'kind','') <> 'OUT' THEN RAISE EXCEPTION 'A vehicle goes only on Cash Out'; END IF;
    SELECT v.vehicle_no INTO v_no FROM public.lwb_vehicles v WHERE v.id = v_veh;
    IF v_no IS NULL THEN RAISE EXCEPTION 'Vehicle not found in Vehicle Master'; END IF;
    IF nullif(p->>'staff_id','') IS NOT NULL THEN RAISE EXCEPTION 'Choose staff or vehicle, not both'; END IF;
  END IF;
  v_id := public.lwb_acc_add_entry2(p);
  IF v_veh IS NOT NULL THEN
    UPDATE public.lwb_acc_entries SET vehicle_id = v_veh, party = coalesce(nullif(btrim(party),''), v_no) WHERE id = v_id;
  END IF;
  RETURN v_id;
END;
$fn$;

-- Vehicles for the Party box (Accounts can read the list even if they can not open Fleet).
CREATE OR REPLACE FUNCTION public.lwb_acc_vehicles()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts Dashboard is for active Accounts or Admin only'; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', v.id, 'no', v.vehicle_no, 'type', v.vehicle_type,
      'own', v.ownership, 'transporter', v.transporter_name) ORDER BY v.vehicle_no)
    FROM public.lwb_vehicles v WHERE v.is_active), '[]'::jsonb);
END;
$fn$;

-- Per vehicle: total and per head for the dates; vehicle id + no. on each entry of the dates.
CREATE OR REPLACE FUNCTION public.lwb_acc_vehicle_report(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts Dashboard is for active Accounts or Admin only'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN RAISE EXCEPTION 'Check the dates'; END IF;
  IF p_to - p_from > 400 THEN RAISE EXCEPTION 'Choose up to about one year'; END IF;
  RETURN jsonb_build_object(
    'vehicles', coalesce((SELECT jsonb_agg(x ORDER BY x.total DESC, x.no) FROM (
        SELECT v.id, v.vehicle_no AS no, v.vehicle_type AS type, sum(e.amount) AS total, count(*) AS n,
               max(e.entry_date) AS last_date,
               (SELECT jsonb_agg(jsonb_build_object('head', h.head, 'amount', h.amt) ORDER BY h.amt DESC) FROM (
                  SELECT coalesce(c.name,'Other') AS head, sum(e2.amount) AS amt
                  FROM public.lwb_acc_entries e2 LEFT JOIN public.lwb_acc_categories c ON c.id = e2.category_id
                  WHERE e2.vehicle_id = v.id AND e2.cancelled_at IS NULL AND e2.entry_date BETWEEN p_from AND p_to
                  GROUP BY 1) h) AS heads
        FROM public.lwb_acc_entries e JOIN public.lwb_vehicles v ON v.id = e.vehicle_id
        WHERE e.cancelled_at IS NULL AND e.entry_date BETWEEN p_from AND p_to
        GROUP BY v.id, v.vehicle_no, v.vehicle_type) x), '[]'::jsonb),
    'entries', coalesce((SELECT jsonb_object_agg(e.id, jsonb_build_object('vehicle_id', e.vehicle_id, 'vehicle', v.vehicle_no))
        FROM public.lwb_acc_entries e JOIN public.lwb_vehicles v ON v.id = e.vehicle_id
        WHERE e.cancelled_at IS NULL AND e.entry_date BETWEEN p_from AND p_to), '{}'::jsonb)
  );
END;
$fn$;

-- One vehicle's expenses, date-wise.
CREATE OR REPLACE FUNCTION public.lwb_acc_vehicle_ledger(p_vehicle uuid, p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts Dashboard is for active Accounts or Admin only'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN RAISE EXCEPTION 'Check the dates'; END IF;
  RETURN jsonb_build_object(
    'vehicle', (SELECT jsonb_build_object('id', v.id, 'no', v.vehicle_no, 'type', v.vehicle_type) FROM public.lwb_vehicles v WHERE v.id = p_vehicle),
    'lines', coalesce((SELECT jsonb_agg(jsonb_build_object('date', e.entry_date, 'time', to_char(e.entry_time,'HH24:MI'), 'at', e.created_at,
        'head', c.name, 'mode', e.mode, 'amount', e.amount, 'party', e.party, 'ref', e.ref_no, 'remark', e.remark,
        'gst_bill', e.gst_bill, 'photos', cardinality(e.photo_paths)) ORDER BY e.entry_date, e.entry_time NULLS LAST, e.created_at)
      FROM public.lwb_acc_entries e LEFT JOIN public.lwb_acc_categories c ON c.id = e.category_id
      WHERE e.vehicle_id = p_vehicle AND e.cancelled_at IS NULL AND e.entry_date BETWEEN p_from AND p_to), '[]'::jsonb)
  );
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_add_entry3(jsonb), public.lwb_acc_vehicles(), public.lwb_acc_vehicle_report(date,date),
  public.lwb_acc_vehicle_ledger(uuid,date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_add_entry3(jsonb), public.lwb_acc_vehicles(), public.lwb_acc_vehicle_report(date,date),
  public.lwb_acc_vehicle_ledger(uuid,date,date) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'vehicle on entries' AS item,
  EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'lwb_acc_entries' AND column_name = 'vehicle_id')::text AS ok
UNION ALL SELECT 'vehicle report', (to_regprocedure('public.lwb_acc_vehicle_report(date,date)') IS NOT NULL)::text;
