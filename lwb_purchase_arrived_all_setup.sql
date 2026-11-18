-- LUXURY WRIST BRAND ERP — "PURCHASE VEHICLE ARRIVED" POPUP TO ALL GODOWN MANAGERS (18 Nov 2026)
--
-- Mohit asked (18 Nov 2026): as soon as a purchase entry is made, the Godown Manager must get the
-- option to upload damage / leakage / breakage / gasless photos and videos for that bill. For now
-- every active Godown Manager gets it, not only the one chosen on Purchase Entry ("abhi sabhi ke
-- liye dikhao"). The chosen manager is still saved on the bill (godown_user_id) for later.
--
-- lwb_purchase_arrived(bill, manager) now:
--   * saves the chosen manager on the bill (as before, NULL = nobody chosen);
--   * sends the PURCHASE_ARRIVED popup to every active Godown Manager who does not have an open one;
--   * sends nothing once the vehicle is checked (as before).
-- When one manager submits the check, lwb_purchase_damage_report closes the popups of everybody.
--
-- Needs: lwb_purchase_damage_report_setup.sql. Same signature, so nothing else changes.
-- Safe to run again. Nothing is dropped or deleted.

BEGIN;

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
  IF EXISTS (SELECT 1 FROM public.lwb_purchase_checks c WHERE c.inward_id = p_inward) THEN RETURN 0; END IF;
  v_txt := public.lwb_pdr_bill_text(p_inward);
  SELECT nullif(btrim(p.full_name),'') INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();
  INSERT INTO public.erp_notifications(user_id, title, message, notification_type, ref_type, ref_id)
  SELECT p.id, left('Purchase vehicle arrived: ' || coalesce(nullif(btrim(g.vehicle_no),''), 'Inv ' || g.invoice_no), 150),
         left(v_txt || '. Check the goods. Report damage / gasless / shortage with photos or videos, or press All OK.'
              || coalesce(' Entry by ' || v_by || '.', ''), 600),
         'PURCHASE_ARRIVED', 'PURCHASE_BILL', p_inward::text
  FROM public.user_profiles p
  WHERE p.active = true AND lower(btrim(p.role)) = 'warehouse'
    AND NOT EXISTS (SELECT 1 FROM public.erp_notifications n WHERE n.user_id = p.id AND n.ref_type = 'PURCHASE_BILL'
                    AND n.ref_id = p_inward::text AND n.notification_type = 'PURCHASE_ARRIVED' AND n.is_read = false);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_purchase_arrived(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_arrived(uuid, uuid) TO authenticated;

COMMIT;

SELECT to_regprocedure('public.lwb_purchase_arrived(uuid,uuid)') IS NOT NULL AS arrived_rpc;
