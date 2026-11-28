-- LUXURY WRIST BRAND ERP — ECRS "Company dispatch" + driver = vehicle ON THE WAY alert (27 Nov 2026)
--
-- Mohit asked (27 Nov 2026): the driver number is not given on a separate button. When the company sends a
-- truck against an ECRS order, the driver sends the bill. In "Company dispatch" (ECRS page / Purchase List) we
-- check the bill cases against the ECRS order (same, or change the cases that differ) and enter the driver
-- name + mobile there. As soon as the driver mobile is saved, the Godown Manager and the Sales Head get a
-- bell + phone notification: "vehicle ... is on the way".
--
--   lwb_ecrs_trucks  + onway_at, onway_mobile, onway_by  (when / which driver number the alert went for)
--   lwb_ecrs_on_way(p_truck, p_mobile, p_name, p_ordered_cs)
--        Admin / Sales Head / Accounts. Run after lwb_ecrs_dispatch (needs the vehicle no.).
--        Saves the driver on the vehicle (lwb_vehicle_driver_save, same as the Dial Book) and sends the alert
--        to active Godown Manager (warehouse) + Sales Head (manager) logins. The alert goes once per driver
--        number: saving the dispatch again with the same number does not send it again.
--
--   28 Nov 2026 (lwb_vehicle_driver_history_setup.sql): + p_transport (the vehicle's transport, for the phone name
--        "GJ05 BX 4471 RAMESH VIKAS"); driver mobile left blank = the vehicle's saved driver came again (alert still goes);
--        every driver of a vehicle is kept (old drivers are not overwritten any more).
--
-- Safe to run again. Nothing is dropped or deleted (only the old 4-argument function is replaced by the 5-argument one).

BEGIN;

ALTER TABLE public.lwb_ecrs_trucks ADD COLUMN IF NOT EXISTS onway_at timestamptz;
ALTER TABLE public.lwb_ecrs_trucks ADD COLUMN IF NOT EXISTS onway_mobile text;
ALTER TABLE public.lwb_ecrs_trucks ADD COLUMN IF NOT EXISTS onway_by uuid;

DROP FUNCTION IF EXISTS public.lwb_ecrs_on_way(bigint, text, text, numeric);
CREATE OR REPLACE FUNCTION public.lwb_ecrs_on_way(p_truck bigint, p_mobile text, p_name text DEFAULT NULL, p_ordered_cs numeric DEFAULT NULL,
  p_transport text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE t public.lwb_ecrs_trucks; v_mob text := public.lwb_dial_mob(p_mobile); v_no integer; v_sent numeric; v_diff numeric;
        v_name text := upper(left(nullif(btrim(coalesce(p_name, '')), ''), 80)); v_qty text; v_n integer := 0; v_by text;
BEGIN
  IF coalesce(public.lwb_pst_role(), '') NOT IN ('admin','manager','accounts') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can enter the company dispatch';
  END IF;
  SELECT * INTO t FROM public.lwb_ecrs_trucks WHERE id = p_truck FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ECRS order not found'; END IF;
  IF t.dispatched_at IS NULL OR public.lwb_vehicle_fmt(t.vehicle_no) IS NULL THEN
    RAISE EXCEPTION 'Save the company dispatch with the vehicle no. first';
  END IF;
  IF v_mob IS NULL AND nullif(regexp_replace(coalesce(p_mobile, ''), '\D', '', 'g'), '') IS NULL THEN
    -- blank: same driver as last time
    SELECT d.driver_mobile, coalesce(v_name, upper(d.driver_name)) INTO v_mob, v_name
      FROM public.lwb_vehicle_driver d WHERE d.vehicle_key = public.lwb_vehicle_key(t.vehicle_no);
    IF v_mob IS NULL THEN RETURN jsonb_build_object('notified', 0, 'no_driver', true); END IF;
  END IF;
  IF v_mob IS NULL THEN RAISE EXCEPTION 'Driver mobile: enter a 10-digit mobile'; END IF;

  IF to_regprocedure('public.lwb_vehicle_driver_put(text,text,text,text,bigint,timestamptz,text)') IS NOT NULL THEN
    PERFORM public.lwb_vehicle_driver_put(t.vehicle_no, v_mob, v_name, p_transport, t.id, now(), 'ECRS dispatch');
  ELSE
    PERFORM public.lwb_vehicle_driver_save(t.vehicle_no, v_mob, v_name, t.id);
  END IF;

  IF t.onway_mobile IS NOT DISTINCT FROM v_mob THEN
    RETURN jsonb_build_object('notified', 0, 'again', true);
  END IF;

  SELECT count(*) INTO v_no FROM public.lwb_ecrs_trucks x WHERE x.day = t.day AND x.id <= t.id;
  SELECT coalesce(sum(coalesce(nullif(r->>'cs', '')::numeric, 0)), 0) INTO v_sent
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t.sent_rows) = 'array' THEN t.sent_rows ELSE '[]'::jsonb END) r;
  v_diff := v_sent - coalesce(p_ordered_cs, v_sent);
  v_qty := 'Bill ' || to_char(v_sent, 'FM9999990') || ' cs' ||
           CASE WHEN p_ordered_cs IS NULL OR v_diff = 0 THEN ', same as ECRS order ✓'
                WHEN v_diff < 0 THEN ', ' || to_char(-v_diff, 'FM9999990') || ' cs LESS than ECRS order (' || to_char(p_ordered_cs, 'FM9999990') || ')'
                ELSE ', ' || to_char(v_diff, 'FM9999990') || ' cs MORE than ECRS order (' || to_char(p_ordered_cs, 'FM9999990') || ')' END;
  SELECT coalesce(nullif(btrim(p.full_name), ''), 'Office') INTO v_by FROM public.user_profiles p WHERE p.id = auth.uid();

  INSERT INTO public.erp_notifications (user_id, title, message, notification_type)
  SELECT p.id,
         '🚚 Vehicle on the way: ' || public.lwb_vehicle_fmt(t.vehicle_no),
         'ECRS Order ' || v_no || ' (' || to_char(t.day, 'DD/MM') || ')' ||
         CASE WHEN t.invoice_no IS NOT NULL THEN ' · Inv ' || t.invoice_no ELSE '' END || ' · ' || v_qty ||
         ' · Driver ' || coalesce(v_name || ' ', '') || public.lwb_dial_mask(v_mob) ||
         '. Call the driver from Dial Book > Drivers. Entered by ' || coalesce(v_by, 'Office') || '.',
         'PURCHASE_ON_WAY'
    FROM public.user_profiles p
   WHERE p.active = true AND lower(btrim(coalesce(p.role, ''))) IN ('warehouse', 'manager')
     AND p.id IS DISTINCT FROM auth.uid();
  GET DIAGNOSTICS v_n = ROW_COUNT;

  UPDATE public.lwb_ecrs_trucks SET onway_at = now(), onway_mobile = v_mob, onway_by = auth.uid(), updated_at = now()
   WHERE id = t.id;
  RETURN jsonb_build_object('notified', v_n, 'again', false, 'diff', v_diff, 'sent', v_sent);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_ecrs_on_way(bigint, text, text, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_ecrs_on_way(bigint, text, text, numeric, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
