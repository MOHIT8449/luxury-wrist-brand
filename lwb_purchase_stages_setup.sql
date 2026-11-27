-- LUXURY WRIST BRAND ERP — PURCHASE STAGES (27 Nov 2026)
--
-- Mohit asked (27 Nov 2026): the Purchase List must show, like the PO list, at which stage the goods are:
--   1. ECRS ordered      truck punched to the company on the ECRS page (lwb_ecrs_trucks)
--   2. On the way        company dispatched it: vehicle no., invoice no. / date, actual cases per SKU (editable)
--   3. Received / check  Goods Inward saved (lwb_goods_inward) and the vehicle check (lwb_purchase_checks)
--   4. Bill / Tally      bill copy uploaded (documents) and Tally entry done (new, here)
--   5. Claim             damage claim (lwb_purchase_checks.claim_status, already there)
--
--   lwb_ecrs_trucks      + vehicle_no, invoice_no, invoice_date, sent_rows [{sku_id,name,cs}], dispatched_at / by,
--                          closed_at / by / note ("Not coming": the company did not send this order)
--   lwb_purchase_stage   one row per purchase bill: ecrs_truck_id (which ECRS order it is), tally_at / by / voucher.
--                        A bill changed in Purchase List (new id) keeps its row; a deleted bill frees the truck.
--
-- RPCs: lwb_ecrs_dispatch, lwb_ecrs_close, lwb_purchase_link_ecrs, lwb_purchase_tally_done, lwb_purchase_stage_list.
-- A new purchase bill is linked by itself to a dispatched, not yet received truck with the same invoice no.
-- (or else the same vehicle no., dispatched in the 10 days before it was received).
-- Safe to run again. Nothing is dropped or deleted.

BEGIN;

ALTER TABLE public.lwb_ecrs_trucks ADD COLUMN IF NOT EXISTS vehicle_no text;
ALTER TABLE public.lwb_ecrs_trucks ADD COLUMN IF NOT EXISTS invoice_no text;
ALTER TABLE public.lwb_ecrs_trucks ADD COLUMN IF NOT EXISTS invoice_date date;
ALTER TABLE public.lwb_ecrs_trucks ADD COLUMN IF NOT EXISTS sent_rows jsonb;
ALTER TABLE public.lwb_ecrs_trucks ADD COLUMN IF NOT EXISTS dispatched_at timestamptz;
ALTER TABLE public.lwb_ecrs_trucks ADD COLUMN IF NOT EXISTS dispatched_by uuid;
ALTER TABLE public.lwb_ecrs_trucks ADD COLUMN IF NOT EXISTS closed_at timestamptz;
ALTER TABLE public.lwb_ecrs_trucks ADD COLUMN IF NOT EXISTS closed_by uuid;
ALTER TABLE public.lwb_ecrs_trucks ADD COLUMN IF NOT EXISTS close_note text;

CREATE TABLE IF NOT EXISTS public.lwb_purchase_stage (
  inward_id uuid PRIMARY KEY,
  ecrs_truck_id bigint UNIQUE,
  linked_at timestamptz,
  linked_by uuid,
  tally_at timestamptz,
  tally_by uuid,
  tally_voucher text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_purchase_stage ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_purchase_stage FROM PUBLIC, anon, authenticated;

-- Role of the login (lower case), only when active.
CREATE OR REPLACE FUNCTION public.lwb_pst_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
$$;
REVOKE ALL ON FUNCTION public.lwb_pst_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_pst_role() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_pst_key(v text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT nullif(upper(regexp_replace(coalesce(v, ''), '[^A-Za-z0-9]', '', 'g')), '')
$$;
REVOKE ALL ON FUNCTION public.lwb_pst_key(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_pst_key(text) TO authenticated;

-- 2. Company dispatched: vehicle, invoice and the cases it really sent (Admin / Sales Head / Accounts).
CREATE OR REPLACE FUNCTION public.lwb_ecrs_dispatch(p_truck bigint, p_vehicle text, p_invoice text, p_invoice_date date, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE t public.lwb_ecrs_trucks; v_rows jsonb;
BEGIN
  IF coalesce(public.lwb_pst_role(), '') NOT IN ('admin','manager','accounts') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can enter the company dispatch';
  END IF;
  SELECT * INTO t FROM public.lwb_ecrs_trucks WHERE id = p_truck FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ECRS order not found'; END IF;
  IF public.lwb_pst_key(p_vehicle) IS NULL AND public.lwb_pst_key(p_invoice) IS NULL THEN
    RAISE EXCEPTION 'Enter the vehicle no. or the invoice no.';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object('sku_id', r->>'sku_id', 'name', left(coalesce(r->>'name',''), 120),
           'cs', greatest(0, round(coalesce(nullif(r->>'cs','')::numeric, 0), 2)))), '[]'::jsonb)
    INTO v_rows FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_rows) = 'array' THEN p_rows ELSE '[]'::jsonb END) r
   WHERE coalesce(r->>'sku_id', '') <> '';
  UPDATE public.lwb_ecrs_trucks SET
    vehicle_no = upper(nullif(btrim(coalesce(p_vehicle, '')), '')),
    invoice_no = nullif(btrim(coalesce(p_invoice, '')), ''),
    invoice_date = p_invoice_date,
    sent_rows = v_rows,
    dispatched_at = coalesce(t.dispatched_at, now()),
    dispatched_by = coalesce(t.dispatched_by, auth.uid()),
    closed_at = NULL, closed_by = NULL, close_note = NULL,
    updated_at = now()
  WHERE id = p_truck;
  RETURN jsonb_build_object('id', p_truck, 'rows', jsonb_array_length(v_rows));
END $$;
REVOKE ALL ON FUNCTION public.lwb_ecrs_dispatch(bigint, text, text, date, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_ecrs_dispatch(bigint, text, text, date, jsonb) TO authenticated;

-- "Not coming": the company did not send this ECRS order (p_close false = open it again).
CREATE OR REPLACE FUNCTION public.lwb_ecrs_close(p_truck bigint, p_close boolean, p_note text DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF coalesce(public.lwb_pst_role(), '') NOT IN ('admin','manager','accounts') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can close an ECRS order';
  END IF;
  IF p_close AND EXISTS (SELECT 1 FROM public.lwb_purchase_stage s WHERE s.ecrs_truck_id = p_truck) THEN
    RAISE EXCEPTION 'This ECRS order is already received on a purchase bill';
  END IF;
  UPDATE public.lwb_ecrs_trucks SET closed_at = CASE WHEN p_close THEN now() END,
    closed_by = CASE WHEN p_close THEN auth.uid() END,
    close_note = CASE WHEN p_close THEN left(nullif(btrim(coalesce(p_note, '')), ''), 300) END,
    updated_at = now()
  WHERE id = p_truck;
  IF NOT FOUND THEN RAISE EXCEPTION 'ECRS order not found'; END IF;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.lwb_ecrs_close(bigint, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_ecrs_close(bigint, boolean, text) TO authenticated;

-- Which ECRS order a purchase bill is (p_truck NULL = take the link off).
CREATE OR REPLACE FUNCTION public.lwb_purchase_link_ecrs(p_inward uuid, p_truck bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r text := coalesce(public.lwb_pst_role(), '');
BEGIN
  IF r NOT IN ('admin','manager','accounts','warehouse') THEN RAISE EXCEPTION 'Not allowed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_goods_inward g WHERE g.id = p_inward) THEN RAISE EXCEPTION 'Purchase bill not found'; END IF;
  IF p_truck IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.lwb_ecrs_trucks t WHERE t.id = p_truck) THEN RAISE EXCEPTION 'ECRS order not found'; END IF;
    IF EXISTS (SELECT 1 FROM public.lwb_purchase_stage s WHERE s.ecrs_truck_id = p_truck AND s.inward_id <> p_inward) THEN
      RAISE EXCEPTION 'This ECRS order is already on another purchase bill';
    END IF;
    UPDATE public.lwb_ecrs_trucks SET closed_at = NULL, closed_by = NULL, close_note = NULL WHERE id = p_truck AND closed_at IS NOT NULL;
  END IF;
  INSERT INTO public.lwb_purchase_stage AS s (inward_id, ecrs_truck_id, linked_at, linked_by)
  VALUES (p_inward, p_truck, now(), auth.uid())
  ON CONFLICT (inward_id) DO UPDATE SET ecrs_truck_id = excluded.ecrs_truck_id, linked_at = now(), linked_by = auth.uid(), updated_at = now();
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.lwb_purchase_link_ecrs(uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_link_ecrs(uuid, bigint) TO authenticated;

-- Tally entry of the purchase bill done (Admin / Accounts). p_done false = take it back.
CREATE OR REPLACE FUNCTION public.lwb_purchase_tally_done(p_inward uuid, p_done boolean, p_voucher text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF coalesce(public.lwb_pst_role(), '') NOT IN ('admin','accounts') THEN
    RAISE EXCEPTION 'Only Admin or Accounts can mark the Tally entry';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_goods_inward g WHERE g.id = p_inward) THEN RAISE EXCEPTION 'Purchase bill not found'; END IF;
  INSERT INTO public.lwb_purchase_stage AS s (inward_id, tally_at, tally_by, tally_voucher)
  VALUES (p_inward, CASE WHEN p_done THEN now() END, CASE WHEN p_done THEN auth.uid() END,
          CASE WHEN p_done THEN left(nullif(btrim(coalesce(p_voucher, '')), ''), 60) END)
  ON CONFLICT (inward_id) DO UPDATE SET tally_at = excluded.tally_at, tally_by = excluded.tally_by,
    tally_voucher = excluded.tally_voucher, updated_at = now();
  RETURN jsonb_build_object('inward_id', p_inward, 'done', p_done);
END $$;
REVOKE ALL ON FUNCTION public.lwb_purchase_tally_done(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_tally_done(uuid, boolean, text) TO authenticated;

-- Everything the Purchase List needs for the stages (Admin / Sales Head / Accounts / Godown Manager).
--   trucks: ECRS orders ordered from p_from - 30 days to p_to (open ones of older days too), with the
--           ordered cases per SKU (pallets x cases per pallet) and the linked bill.
--   stage:  lwb_purchase_stage rows (bill -> truck, Tally) with the names of who did it.
CREATE OR REPLACE FUNCTION public.lwb_purchase_stage_list(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE r text := coalesce(public.lwb_pst_role(), ''); v_from date := coalesce(p_from, current_date - 30); v_to date := coalesce(p_to, current_date);
BEGIN
  IF r NOT IN ('admin','manager','accounts','warehouse') THEN RAISE EXCEPTION 'Not allowed'; END IF;
  RETURN jsonb_build_object(
    'trucks', coalesce((
      SELECT jsonb_agg(x ORDER BY x->>'day' DESC, (x->>'id')::bigint DESC) FROM (
        SELECT jsonb_build_object(
          'id', t.id, 'day', t.day, 'no', (SELECT count(*) FROM public.lwb_ecrs_trucks o WHERE o.day = t.day AND o.id <= t.id),
          'cap', t.cap, 'created_at', t.created_at,
          'rows', (SELECT coalesce(jsonb_agg(jsonb_build_object('sku_id', e->>'sku_id', 'name', coalesce(k.sku_name, e->>'name'),
                     'pal', coalesce(nullif(e->>'pal','')::numeric, 0),
                     'cs', coalesce(nullif(e->>'pal','')::numeric, 0) * coalesce(k.cases_per_pallet, 0))), '[]'::jsonb)
                   FROM jsonb_array_elements(CASE WHEN jsonb_typeof(t.rows) = 'array' THEN t.rows ELSE '[]'::jsonb END) e
                   LEFT JOIN public.sku_master k ON k.id::text = e->>'sku_id'),
          'sent_rows', t.sent_rows, 'vehicle_no', t.vehicle_no, 'invoice_no', t.invoice_no, 'invoice_date', t.invoice_date,
          'dispatched_at', t.dispatched_at, 'dispatched_by', (SELECT p.full_name FROM public.user_profiles p WHERE p.id = t.dispatched_by),
          'closed_at', t.closed_at, 'close_note', t.close_note,
          'inward_id', (SELECT s.inward_id FROM public.lwb_purchase_stage s WHERE s.ecrs_truck_id = t.id)) x
        FROM public.lwb_ecrs_trucks t
        WHERE (t.day BETWEEN v_from - 30 AND v_to)
           OR (t.day < v_from AND t.closed_at IS NULL AND NOT EXISTS (SELECT 1 FROM public.lwb_purchase_stage s WHERE s.ecrs_truck_id = t.id))
      ) q), '[]'::jsonb),
    'stage', coalesce((
      SELECT jsonb_agg(jsonb_build_object('inward_id', s.inward_id, 'ecrs_truck_id', s.ecrs_truck_id,
               'tally_at', s.tally_at, 'tally_voucher', s.tally_voucher,
               'tally_by', (SELECT p.full_name FROM public.user_profiles p WHERE p.id = s.tally_by)))
      FROM public.lwb_purchase_stage s), '[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.lwb_purchase_stage_list(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_purchase_stage_list(date, date) TO authenticated;

-- A new purchase bill finds its ECRS order by itself: same invoice no., else same vehicle no.
-- (dispatched in the 10 days before it was received). Only trucks with no bill yet.
CREATE OR REPLACE FUNCTION public.lwb_pst_auto_link()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_truck bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM public.lwb_purchase_stage s WHERE s.inward_id = NEW.id AND s.ecrs_truck_id IS NOT NULL) THEN RETURN NEW; END IF;
  SELECT t.id INTO v_truck FROM public.lwb_ecrs_trucks t
   WHERE t.dispatched_at IS NOT NULL AND t.closed_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.lwb_purchase_stage s WHERE s.ecrs_truck_id = t.id)
     AND public.lwb_pst_key(t.invoice_no) = public.lwb_pst_key(NEW.invoice_no)
   ORDER BY t.dispatched_at DESC LIMIT 1;
  IF v_truck IS NULL AND public.lwb_pst_key(NEW.vehicle_no) IS NOT NULL THEN
    SELECT t.id INTO v_truck FROM public.lwb_ecrs_trucks t
     WHERE t.dispatched_at IS NOT NULL AND t.closed_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.lwb_purchase_stage s WHERE s.ecrs_truck_id = t.id)
       AND public.lwb_pst_key(t.vehicle_no) = public.lwb_pst_key(NEW.vehicle_no)
       AND t.dispatched_at::date BETWEEN coalesce(NEW.received_date, current_date) - 10 AND coalesce(NEW.received_date, current_date)
     ORDER BY t.dispatched_at DESC LIMIT 1;
  END IF;
  IF v_truck IS NOT NULL THEN
    INSERT INTO public.lwb_purchase_stage AS s (inward_id, ecrs_truck_id, linked_at)
    VALUES (NEW.id, v_truck, now())
    ON CONFLICT (inward_id) DO UPDATE SET ecrs_truck_id = excluded.ecrs_truck_id, linked_at = now(), updated_at = now();
  END IF;
  RETURN NEW;
EXCEPTION WHEN unique_violation THEN RETURN NEW; -- never block saving a bill
END $$;
DROP TRIGGER IF EXISTS lwb_pst_auto_link ON public.lwb_goods_inward;
CREATE TRIGGER lwb_pst_auto_link AFTER INSERT ON public.lwb_goods_inward FOR EACH ROW EXECUTE FUNCTION public.lwb_pst_auto_link();

-- A bill changed in Purchase List gets a new id (lwb_purchase_bill_log EDIT): its stage row moves with it.
-- A deleted bill (DELETE) frees its ECRS order and drops its Tally mark.
CREATE OR REPLACE FUNCTION public.lwb_pst_bill_log()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE o public.lwb_purchase_stage;
BEGIN
  SELECT * INTO o FROM public.lwb_purchase_stage WHERE inward_id = NEW.inward_id;
  IF NOT FOUND THEN RETURN NEW; END IF;
  DELETE FROM public.lwb_purchase_stage WHERE inward_id = NEW.inward_id;
  IF upper(coalesce(NEW.action, '')) = 'EDIT' AND NEW.new_inward_id IS NOT NULL THEN
    INSERT INTO public.lwb_purchase_stage AS s (inward_id, ecrs_truck_id, linked_at, linked_by, tally_at, tally_by, tally_voucher)
    VALUES (NEW.new_inward_id, o.ecrs_truck_id, o.linked_at, o.linked_by, o.tally_at, o.tally_by, o.tally_voucher)
    ON CONFLICT (inward_id) DO UPDATE SET ecrs_truck_id = coalesce(excluded.ecrs_truck_id, s.ecrs_truck_id),
      tally_at = excluded.tally_at, tally_by = excluded.tally_by, tally_voucher = excluded.tally_voucher, updated_at = now();
  END IF;
  RETURN NEW;
END $$;
DO $$ BEGIN
  IF to_regclass('public.lwb_purchase_bill_log') IS NOT NULL THEN
    DROP TRIGGER IF EXISTS lwb_pst_bill_log ON public.lwb_purchase_bill_log;
    CREATE TRIGGER lwb_pst_bill_log AFTER INSERT ON public.lwb_purchase_bill_log FOR EACH ROW EXECUTE FUNCTION public.lwb_pst_bill_log();
  END IF;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
