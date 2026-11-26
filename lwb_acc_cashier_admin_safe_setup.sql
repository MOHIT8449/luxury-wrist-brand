-- LUXURY WRIST BRAND ERP — ADMIN KEEPS THE CASH AT NIGHT, IS NOT THE CASHIER (Mohit, 26 Nov 2026)
--
-- Mohit: in the day the cash box goes from one cashier to the next. At night the cash is handed to Admin (Mohit) only
-- to keep it; in the morning Admin hands it to the cashier of the day. Admin holding the cash must not make him "the
-- cashier". So:
--   cashier of the day = the received parts of the latest handover that was received by a NON-Admin
--                        (Accounts / Sales Head / Cashier role); a handover to Admin only moves the cash.
--   lwb_acc_cashier_batch()      that batch
--   lwb_acc_duty_cashier(user)   Sales Head in that batch (was: in the latest received batch)
--   lwb_acc_today_cashier()      {cashiers:[...], holders:[...], pending} for the top-bar chip
-- Builds on lwb_acc_duty_cashier_setup.sql and lwb_acc_cash_people_roles_setup.sql.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_acc_cashier_batch()
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT h.batch_id FROM public.lwb_acc_shift_handovers h JOIN public.user_profiles p ON p.id = h.given_to
  WHERE h.status = 'RECEIVED' AND lower(btrim(p.role)) <> 'admin'
  GROUP BY h.batch_id ORDER BY max(h.given_at) DESC, h.batch_id DESC LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_duty_cashier(p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT p_user IS NOT NULL
    AND EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user AND p.active = true AND lower(btrim(p.role)) = 'manager')
    AND EXISTS (SELECT 1 FROM public.lwb_acc_shift_handovers h
                WHERE h.status = 'RECEIVED' AND h.given_to = p_user AND h.batch_id = public.lwb_acc_cashier_batch());
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_on_duty()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT jsonb_build_object('on_duty', public.lwb_acc_duty_cashier(auth.uid()),
    'since', (SELECT h.received_at FROM public.lwb_acc_shift_handovers h WHERE public.lwb_acc_duty_cashier(auth.uid())
              AND h.status = 'RECEIVED' AND h.given_to = auth.uid() AND h.batch_id = public.lwb_acc_cashier_batch() LIMIT 1),
    'amount', (SELECT h.received_amount FROM public.lwb_acc_shift_handovers h WHERE public.lwb_acc_duty_cashier(auth.uid())
              AND h.status = 'RECEIVED' AND h.given_to = auth.uid() AND h.batch_id = public.lwb_acc_cashier_batch() LIMIT 1));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_today_cashier()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_cb bigint := public.lwb_acc_cashier_batch(); v_hb bigint;
BEGIN
  IF NOT public.lwb_acc_cash_role_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Sales Head only'; END IF;
  SELECT h.batch_id INTO v_hb FROM public.lwb_acc_shift_handovers h WHERE h.status = 'RECEIVED'
  GROUP BY h.batch_id ORDER BY max(h.given_at) DESC, h.batch_id DESC LIMIT 1;
  RETURN jsonb_build_object(
    'me', auth.uid(),
    'cashiers', coalesce((SELECT jsonb_agg(jsonb_build_object('id', h.given_to, 'name', public.lwb_acc_shift_name(h.given_to),
                  'role', lower(btrim(public.lwb_acc_shift_role(h.given_to))), 'since', h.received_at) ORDER BY h.id)
                FROM public.lwb_acc_shift_handovers h WHERE h.batch_id = v_cb AND h.status = 'RECEIVED'), '[]'::jsonb),
    'holders', coalesce((SELECT jsonb_agg(jsonb_build_object('id', h.given_to, 'name', public.lwb_acc_shift_name(h.given_to),
                  'role', lower(btrim(public.lwb_acc_shift_role(h.given_to))), 'since', h.received_at) ORDER BY h.id)
                FROM public.lwb_acc_shift_handovers h WHERE h.batch_id = v_hb AND h.status = 'RECEIVED'), '[]'::jsonb),
    'pending', (SELECT string_agg(public.lwb_acc_shift_name(h.given_to), ' + ' ORDER BY h.id)
                FROM public.lwb_acc_shift_handovers h WHERE h.status = 'PENDING'));
END
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_cashier_batch(), public.lwb_acc_duty_cashier(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_acc_on_duty(), public.lwb_acc_today_cashier() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_on_duty(), public.lwb_acc_today_cashier() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

SELECT 'today cashier rpc' AS item, (to_regprocedure('public.lwb_acc_today_cashier()') IS NOT NULL)::text AS ok
UNION ALL SELECT 'cashier batch', (to_regprocedure('public.lwb_acc_cashier_batch()') IS NOT NULL)::text;
