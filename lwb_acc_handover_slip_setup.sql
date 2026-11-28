-- LUXURY WRIST BRAND ERP — CASH HANDOVER SLIP: SIGNATURES + BAG NO + A5 PRINT (Mohit, 28 Nov 2026)
--
-- Mohit: when the cash box is handed over we want a proper slip: the date, how many notes of each kind now,
-- how many were there at the last closing, who got the cash, the bag / seal no., and the signature of the
-- cashier who gives it and of the person who takes it. The slip prints on A5 (our printer size).
-- Builds on lwb_acc_shift_handover_setup.sql + lwb_acc_cash_split_handover_setup.sql + lwb_acc_cash_diff_damaged_setup.sql.
-- Money does not change: no cash book / ledger row is written by this file.
--
--   lwb_acc_shift_handovers.bag_no / give_sign / recv_sign (+ signed at)   new columns
--   lwb_acc_shift_sign(id, side, sign, bag)   GIVE = the giver (or Admin) signs the whole handover + bag no.
--                                             RECV = the person who takes that part (or Admin) signs his part
--   lwb_acc_shift_slip(id)                    everything the A5 slip prints (parts, notes, last closing notes, signs)

BEGIN;

ALTER TABLE public.lwb_acc_shift_handovers ADD COLUMN IF NOT EXISTS bag_no text;
ALTER TABLE public.lwb_acc_shift_handovers ADD COLUMN IF NOT EXISTS give_sign text;
ALTER TABLE public.lwb_acc_shift_handovers ADD COLUMN IF NOT EXISTS give_signed_at timestamptz;
ALTER TABLE public.lwb_acc_shift_handovers ADD COLUMN IF NOT EXISTS recv_sign text;
ALTER TABLE public.lwb_acc_shift_handovers ADD COLUMN IF NOT EXISTS recv_signed_at timestamptz;

DO $do$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lwb_acc_shift_sign_size') THEN
    ALTER TABLE public.lwb_acc_shift_handovers ADD CONSTRAINT lwb_acc_shift_sign_size
      CHECK ((bag_no IS NULL OR length(bag_no) <= 40) AND (give_sign IS NULL OR length(give_sign) <= 200000)
             AND (recv_sign IS NULL OR length(recv_sign) <= 200000));
  END IF;
END $do$;

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_sign(p_id bigint, p_side text, p_sign text, p_bag text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_acc_shift_handovers%ROWTYPE; v_side text := upper(btrim(coalesce(p_side,'')));
  v_bag text := nullif(upper(btrim(regexp_replace(coalesce(p_bag,''), '\s+', ' ', 'g'))),'');
BEGIN
  SELECT * INTO h FROM public.lwb_acc_shift_handovers WHERE id = p_id FOR UPDATE;
  IF h.id IS NULL OR h.status = 'CANCELLED' THEN RAISE EXCEPTION 'This handover is not there any more'; END IF;
  IF p_sign IS NULL OR p_sign NOT LIKE 'data:image/png;base64,%' OR length(p_sign) > 200000 THEN RAISE EXCEPTION 'Sign again'; END IF;
  IF length(coalesce(v_bag,'')) > 40 THEN RAISE EXCEPTION 'Bag no. is too long'; END IF;
  IF v_side = 'GIVE' THEN
    IF h.given_by <> auth.uid() AND NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only the person who handed the cash (or Admin) signs here'; END IF;
    UPDATE public.lwb_acc_shift_handovers SET give_sign = p_sign, give_signed_at = now(), bag_no = coalesce(v_bag, bag_no)
    WHERE batch_id = h.batch_id AND status <> 'CANCELLED';
  ELSIF v_side = 'RECV' THEN
    IF h.given_to <> auth.uid() AND NOT public.lwb_acc_admin() THEN
      RAISE EXCEPTION 'Only % (or Admin) signs for this cash', public.lwb_acc_shift_name(h.given_to); END IF;
    UPDATE public.lwb_acc_shift_handovers SET recv_sign = p_sign, recv_signed_at = now() WHERE id = p_id;
  ELSE RAISE EXCEPTION 'Choose GIVE or RECV'; END IF;
  RETURN jsonb_build_object('ok', true, 'batch', h.batch_id);
END
$fn$;

-- The A5 slip: one handover (all its parts). Last closing = the newest count before this handover:
-- the night Close Day count or the handover before it, whichever is later.
CREATE OR REPLACE FUNCTION public.lwb_acc_shift_slip(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE h public.lwb_acc_shift_handovers%ROWTYPE; v_last jsonb; v_close jsonb; v_prev jsonb;
BEGIN
  SELECT * INTO h FROM public.lwb_acc_shift_handovers WHERE id = p_id;
  IF h.id IS NULL THEN RAISE EXCEPTION 'Handover not found'; END IF;
  IF NOT public.lwb_acc_shift_ok(auth.uid()) AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_shift_handovers x
       WHERE x.batch_id = h.batch_id AND (x.given_to = auth.uid() OR x.given_by = auth.uid())) THEN
    RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  SELECT jsonb_build_object('kind', 'CLOSE', 'at', c.closed_at, 'day', c.close_date, 'by_name', public.lwb_acc_shift_name(c.closed_by),
           'counted', c.counted, 'notes', c.counted_notes)
    INTO v_close FROM public.lwb_acc_day_close c
   WHERE c.closed_at < h.given_at AND c.counted_notes IS NOT NULL ORDER BY c.closed_at DESC, c.id DESC LIMIT 1;
  SELECT jsonb_build_object('kind', 'HANDOVER', 'at', x.given_at, 'day', (x.given_at AT TIME ZONE 'Asia/Kolkata')::date,
           'by_name', public.lwb_acc_shift_name(x.given_by), 'counted', sum(x.counted) OVER (PARTITION BY x.batch_id), 'notes', x.counted_notes)
    INTO v_prev FROM public.lwb_acc_shift_handovers x
   WHERE x.status <> 'CANCELLED' AND x.batch_id <> h.batch_id AND x.given_at < h.given_at AND x.counted_notes IS NOT NULL
   ORDER BY x.given_at DESC, x.id LIMIT 1;
  v_last := CASE WHEN v_prev IS NULL THEN v_close WHEN v_close IS NULL THEN v_prev
                 WHEN (v_prev->>'at')::timestamptz > (v_close->>'at')::timestamptz THEN v_prev ELSE v_close END;
  RETURN jsonb_build_object(
    'id', h.batch_id, 'slip_no', h.batch_id, 'at', h.given_at, 'day', (h.given_at AT TIME ZONE 'Asia/Kolkata')::date,
    'by_name', public.lwb_acc_shift_name(h.given_by), 'by_role', public.lwb_acc_shift_role(h.given_by),
    'book', h.book_cash, 'notes', h.counted_notes, 'note', h.note, 'bag_no', h.bag_no,
    'give_sign', h.give_sign, 'give_signed_at', h.give_signed_at,
    'parts', (SELECT jsonb_agg(jsonb_build_object('id', x.id, 'to_name', public.lwb_acc_shift_name(x.given_to), 'to_role', public.lwb_acc_shift_role(x.given_to),
                'amount', x.counted, 'status', x.status, 'received', x.received_amount, 'received_at', x.received_at, 'receive_note', x.receive_note,
                'recv_sign', x.recv_sign, 'recv_signed_at', x.recv_signed_at) ORDER BY x.id)
              FROM public.lwb_acc_shift_handovers x WHERE x.batch_id = h.batch_id AND x.status <> 'CANCELLED'),
    'total', (SELECT sum(x.counted) FROM public.lwb_acc_shift_handovers x WHERE x.batch_id = h.batch_id AND x.status <> 'CANCELLED'),
    'extra', coalesce((SELECT jsonb_agg(jsonb_build_object('kind', e.kind, 'name', e.name, 'amount', e.amount) ORDER BY e.id)
              FROM public.lwb_acc_shift_extra e WHERE e.batch_id = h.batch_id AND e.cancelled_at IS NULL), '[]'::jsonb),
    'diff', (SELECT jsonb_build_object('kind', d.kind, 'amount', d.amount) FROM public.lwb_acc_cash_diff d
              WHERE d.batch_id = h.batch_id AND d.cancelled_at IS NULL ORDER BY d.id DESC LIMIT 1),
    'last', v_last,
    'printed_by', public.lwb_acc_shift_name(auth.uid()), 'printed_at', now());
END
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_shift_sign(bigint,text,text,text), public.lwb_acc_shift_slip(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_shift_sign(bigint,text,text,text), public.lwb_acc_shift_slip(bigint) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'sign columns' AS item, (SELECT count(*) = 5 FROM information_schema.columns WHERE table_schema = 'public'
  AND table_name = 'lwb_acc_shift_handovers' AND column_name IN ('bag_no','give_sign','give_signed_at','recv_sign','recv_signed_at'))::text AS ok
UNION ALL SELECT 'sign function', (to_regprocedure('public.lwb_acc_shift_sign(bigint,text,text,text)') IS NOT NULL)::text
UNION ALL SELECT 'slip function', (to_regprocedure('public.lwb_acc_shift_slip(bigint)') IS NOT NULL)::text;
