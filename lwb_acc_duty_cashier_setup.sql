-- LUXURY WRIST BRAND ERP — TODAY'S CASHIER = THE SALES HEAD WHO HOLDS THE CASH BOX (Mohit, 26 Nov 2026)
--
-- Mohit: 3 Sales Heads, 1 Accountant, 1 Admin. One of the Sales Heads is the cashier of the day. The cash box is
-- handed to him (Cash handover: Hand over -> @tag -> he presses Received ✓). From then on he makes every Cash In,
-- Cash Out and Party payment entry, so he must see the Cashier tabs by himself. The other Sales Heads do not.
--
-- Rule: a Sales Head (role 'manager') who holds the cash box now = a received part of the latest handover that has
-- a received part (same "holders" as lwb_acc_shift_list) works as the Cashier. When he hands the box on and the next
-- person presses Received ✓, it moves to that person. Admin / Accounts / Cashier logins are not changed.
--
--   lwb_acc_duty_cashier(user)   true = Sales Head holding the cash box now
--   lwb_acc_on_duty()            for the website: {on_duty, since, amount} of the logged-in user
--   lwb_acc_user(), lwb_acc_cashier(), lwb_acc_shift_ok(user)   also true for the duty cashier
--   every active Sales Head is added to the "who can take cash" list (Admin can still change the list)

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_acc_duty_cashier(p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT p_user IS NOT NULL
    AND EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user AND p.active = true AND lower(btrim(p.role)) = 'manager')
    AND EXISTS (
      SELECT 1 FROM public.lwb_acc_shift_handovers h
      WHERE h.status = 'RECEIVED' AND h.given_to = p_user
        AND h.batch_id = (SELECT x.batch_id FROM public.lwb_acc_shift_handovers x WHERE x.status = 'RECEIVED'
                          GROUP BY x.batch_id ORDER BY max(x.given_at) DESC, x.batch_id DESC LIMIT 1));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_on_duty()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT jsonb_build_object('on_duty', public.lwb_acc_duty_cashier(auth.uid()),
    'since', (SELECT h.received_at FROM public.lwb_acc_shift_handovers h WHERE public.lwb_acc_duty_cashier(auth.uid())
              AND h.status = 'RECEIVED' AND h.given_to = auth.uid() ORDER BY h.received_at DESC LIMIT 1),
    'amount', (SELECT h.received_amount FROM public.lwb_acc_shift_handovers h WHERE public.lwb_acc_duty_cashier(auth.uid())
              AND h.status = 'RECEIVED' AND h.given_to = auth.uid() ORDER BY h.received_at DESC LIMIT 1));
$fn$;

-- cash book RPCs: Admin / Accounts / Cashier / Sales Head holding the cash box
CREATE OR REPLACE FUNCTION public.lwb_acc_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin','cashier'))
      OR public.lwb_acc_duty_cashier(auth.uid());
$fn$;

-- Cashier work (party payment, kasar, is_cashier on the dashboard): Cashier role or the duty cashier
CREATE OR REPLACE FUNCTION public.lwb_acc_cashier()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) = 'cashier')
      OR public.lwb_acc_duty_cashier(auth.uid());
$fn$;

-- cash box staff (hand over, cancel, the full handover list): also the duty cashier, so he can hand it on
CREATE OR REPLACE FUNCTION public.lwb_acc_shift_ok(p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','accounts','cashier'))
      OR public.lwb_acc_duty_cashier(p_user);
$fn$;

-- every active Sales Head may be tagged in a handover
INSERT INTO public.lwb_acc_cash_people (user_id, sort)
SELECT p.id, coalesce((SELECT max(c.sort) FROM public.lwb_acc_cash_people c), 0)
             + row_number() OVER (ORDER BY p.full_name)
FROM public.user_profiles p
WHERE p.active = true AND lower(btrim(p.role)) = 'manager'
ON CONFLICT (user_id) DO NOTHING;

REVOKE ALL ON FUNCTION public.lwb_acc_duty_cashier(uuid), public.lwb_acc_on_duty(), public.lwb_acc_user(),
  public.lwb_acc_cashier(), public.lwb_acc_shift_ok(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_on_duty(), public.lwb_acc_user(), public.lwb_acc_cashier(),
  public.lwb_acc_shift_ok(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.lwb_acc_duty_cashier(uuid) FROM authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true; then the people who may take cash now.
SELECT 'duty cashier' AS item, (to_regprocedure('public.lwb_acc_duty_cashier(uuid)') IS NOT NULL)::text AS ok
UNION ALL SELECT 'on duty rpc', (to_regprocedure('public.lwb_acc_on_duty()') IS NOT NULL)::text
UNION ALL SELECT 'acc user takes duty', (position('lwb_acc_duty_cashier' IN pg_get_functiondef('public.lwb_acc_user()'::regprocedure)) > 0)::text
UNION ALL SELECT 'sales heads in cash list', (NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'manager'
  AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_cash_people c WHERE c.user_id = p.id)))::text;
