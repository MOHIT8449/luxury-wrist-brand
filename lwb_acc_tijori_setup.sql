-- LUXURY WRIST BRAND ERP — NIGHT CASH TO ADMIN = TIJORI (SAFE) (Mohit, 28 Nov 2026)
--
-- Mohit: in the day the cash box goes only between the 3 Sales Heads and Accounts (lwb_acc_cash_people_28nov_setup.sql).
-- At night the collection goes to Admin (Mohit) to keep in the tijori (safe). Admin is not the cashier: he does not
-- count the notes in the day. So Admin is not in the @ tag list, but the Hand over popup has one extra button
-- "🔒 Tijori · Admin". Admin gets the bell "X is handing you Rs …" and confirms it with Received ✓ (and signs).
-- The Cashier page then shows "🔒 In Tijori (Admin) Rs …"; in the morning Admin hands it to the cashier of the day.
-- A handover to Admin already does not change "today's cashier" (lwb_acc_cashier_admin_safe_setup.sql).
--
--   lwb_acc_shift_can_take(user)   + any active Admin (the tijori), besides the chosen people
--   lwb_acc_tijori_people()        the active Admin logins (for the Tijori button and the 🔒 tag)
-- No money / book row changes here.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_can_take(p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT (EXISTS (SELECT 1 FROM public.lwb_acc_cash_people c WHERE c.user_id = p_user) AND public.lwb_acc_cash_role_ok(p_user))
      OR EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user AND p.active = true AND lower(btrim(p.role)) = 'admin');
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_tijori_people()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) AND NOT public.lwb_acc_shift_can_take(auth.uid()) THEN RETURN '[]'::jsonb; END IF;
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'name', coalesce(nullif(btrim(p.full_name),''), 'Admin'),
            'role', 'admin', 'me', p.id = auth.uid()) ORDER BY p.full_name)
          FROM public.user_profiles p WHERE p.active = true AND lower(btrim(p.role)) = 'admin'), '[]'::jsonb);
END
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_shift_can_take(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_acc_tijori_people() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_tijori_people() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: true, then the Admin logins that can take the night cash
SELECT 'tijori people' AS item, (to_regprocedure('public.lwb_acc_tijori_people()') IS NOT NULL)::text AS ok;
