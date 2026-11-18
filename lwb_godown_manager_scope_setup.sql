-- LUXURY WRIST BRAND ERP — GODOWN MANAGER SEES ONLY HIS OWN WORK (18 Nov 2026)
--
-- Mohit asked (18 Nov 2026):
--   1. A task is seen only by the person it is given to, the person who gave it, the Sales Head and Admin.
--      (A Godown Manager saw tasks given to salesmen and Accounts.)
--   2. A Godown Manager sees only the orders the Sales Head / Admin gave to him for loading
--      (Pending Work "Load vehicle & confirm": no more "not given to anyone").
--   3. Purchase: the "vehicle arrived" popup and the photo task go only to the Godown Manager chosen on
--      the entry (it was every Godown Manager). Nobody chosen = no popup / task.
--   4. Purchase vehicle photo: new PURCHASE_BILL document type VEHICLE (number plate photo).
--   5. Loading: dispatch_assignments.loaded_from = the shutter / gate the vehicle was loaded from.
-- Run after lwb_task_management_setup.sql, lwb_order_flow_popups_setup.sql, lwb_purchase_register_setup.sql,
-- lwb_purchase_arrived_all_setup.sql, lwb_documents_setup.sql and lwb_employee_roles_setup.sql. Safe to run again.
-- No order, stock, bill, payment or Tally data is changed.

BEGIN;

-- 1. Task visibility
CREATE OR REPLACE FUNCTION public.lwb_task_visible(p_to uuid, p_by uuid, p_to_role text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  WITH me AS (SELECT public.lwb_task_my_role() AS r)
  SELECT me.r <> '' AND (p_to = auth.uid() OR p_by = auth.uid() OR me.r IN ('admin','manager'))
  FROM me;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_task_visible(uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_task_visible(uuid,uuid,text) TO authenticated;

-- 2, 3, 4: patch three functions in place (only the lines named here change).
DO $do$
DECLARE d text; n text; f regprocedure;
BEGIN
  -- Pending Work: Godown Manager counts only vehicles given to him.
  f := to_regprocedure('public.lwb_my_verify_queue()');
  IF f IS NOT NULL THEN
    d := pg_get_functiondef(f);
    n := replace(d, 'a.loading_manager_id IS NULL OR a.loading_manager_id = auth.uid()', 'a.loading_manager_id = auth.uid()');
    IF n <> d THEN EXECUTE n; ELSIF d !~ 'v_role <> ''warehouse'' OR a.loading_manager_id = auth.uid\(\)' THEN
      RAISE WARNING 'lwb_my_verify_queue: loading line not found, not changed'; END IF;
  END IF;

  -- Purchase photo task: no names given = the Godown Manager chosen on the bill (was every Godown Manager).
  f := to_regprocedure('public.lwb_purchase_photo_task(uuid,uuid[])');
  IF f IS NOT NULL THEN
    d := pg_get_functiondef(f);
    n := replace(d, '(p_assignees IS NULL OR cardinality(p_assignees) = 0 OR p.id = ANY(p_assignees))',
      '(CASE WHEN p_assignees IS NULL OR cardinality(p_assignees) = 0 THEN p.id = (SELECT x.godown_user_id FROM public.lwb_goods_inward x WHERE x.id = p_inward) ELSE p.id = ANY(p_assignees) END)');
    IF n <> d THEN EXECUTE n; ELSIF d !~ 'THEN p.id = \(SELECT x.godown_user_id' THEN
      RAISE WARNING 'lwb_purchase_photo_task: assignee line not found, not changed'; END IF;
  END IF;

  -- Purchase bill documents: + VEHICLE (vehicle photo, number plate).
  f := to_regprocedure('public.lwb_doc_types(text)');
  IF f IS NOT NULL THEN
    d := pg_get_functiondef(f);
    n := replace(d, 'WHEN ''PURCHASE_BILL'' THEN ARRAY[''BILL'',''DAMAGE'',''OTHER'']', 'WHEN ''PURCHASE_BILL'' THEN ARRAY[''BILL'',''DAMAGE'',''VEHICLE'',''OTHER'']');
    IF n <> d THEN EXECUTE n; ELSIF d !~ '''VEHICLE'',''OTHER''\]' THEN RAISE WARNING 'lwb_doc_types: PURCHASE_BILL line not found, not changed'; END IF;
  END IF;
END
$do$;

-- 3. "Vehicle arrived" popup: only the chosen Godown Manager.
CREATE OR REPLACE FUNCTION public.lwb_purchase_arrived(p_inward uuid, p_godown uuid DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE g record; v_txt text; v_by text; v_n integer := 0;
BEGIN
  IF public.lwb_pr_role() NOT IN ('admin','manager') THEN RAISE EXCEPTION 'Only Admin / Sales Head can send the purchase vehicle to a Godown Manager'; END IF;
  SELECT x.id, x.invoice_no, x.vehicle_no INTO g FROM public.lwb_goods_inward x WHERE x.id = p_inward;
  IF g.id IS NULL THEN RAISE EXCEPTION 'Purchase bill not found'; END IF;
  IF p_godown IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_godown AND p.active = true AND lower(btrim(p.role)) = 'warehouse') THEN
    RAISE EXCEPTION 'Choose an active Godown Manager login';
  END IF;
  UPDATE public.lwb_goods_inward SET godown_user_id = p_godown WHERE id = p_inward;
  IF p_godown IS NULL OR EXISTS (SELECT 1 FROM public.lwb_purchase_checks c WHERE c.inward_id = p_inward) THEN RETURN 0; END IF;
  -- Moved to another Godown Manager: close the old popups.
  UPDATE public.erp_notifications SET is_read = true
  WHERE ref_type = 'PURCHASE_BILL' AND ref_id = p_inward::text AND notification_type = 'PURCHASE_ARRIVED' AND is_read = false
    AND user_id <> p_godown;
  v_txt := public.lwb_pdr_bill_text(p_inward);
  SELECT nullif(btrim(p.full_name),'') INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.erp_notifications(user_id, title, message, notification_type, ref_type, ref_id)
  SELECT p_godown, left('Purchase vehicle arrived: ' || coalesce(nullif(btrim(g.vehicle_no),''), 'Inv ' || g.invoice_no), 150),
         left(v_txt || '. Check the goods. Add the vehicle photo, report damage / gasless / shortage with photos or videos, or press All OK.'
              || coalesce(' Entry by ' || v_by || '.', ''), 600),
         'PURCHASE_ARRIVED', 'PURCHASE_BILL', p_inward::text
  WHERE NOT EXISTS (SELECT 1 FROM public.erp_notifications n WHERE n.user_id = p_godown AND n.ref_type = 'PURCHASE_BILL'
                    AND n.ref_id = p_inward::text AND n.notification_type = 'PURCHASE_ARRIVED' AND n.is_read = false);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_purchase_arrived(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_arrived(uuid, uuid) TO authenticated;

-- 5. Loaded from which shutter / gate
ALTER TABLE public.dispatch_assignments ADD COLUMN IF NOT EXISTS loaded_from text;
DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'dispatch_assignments_loaded_from_chk') THEN
    ALTER TABLE public.dispatch_assignments ADD CONSTRAINT dispatch_assignments_loaded_from_chk
      CHECK (loaded_from IS NULL OR length(btrim(loaded_from)) BETWEEN 1 AND 40);
  END IF;
END $do$;

COMMIT;

NOTIFY pgrst, 'reload schema';
