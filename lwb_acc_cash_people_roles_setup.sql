-- LUXURY WRIST BRAND ERP — CASH BOX ONLY FOR ADMIN / ACCOUNTS / SALES HEAD (Mohit, 26 Nov 2026)
--
-- Mohit: the cashier of the day is only ever one of Admin, Accounts (Yogesh bhai) or a Sales Head. Nobody else may
-- be tagged in a cash handover, and nobody else sees who the cashier is.
--   lwb_acc_shift_can_take(user)   also needs role admin / accounts / manager (or the Cashier role)
--   lwb_acc_cash_people_get()      Admin's pick list shows only those roles
--   lwb_acc_cash_people            other logins (e.g. Salesman) are taken off the list
-- Holders / old handovers are not touched.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_acc_cash_role_ok(p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user AND p.active = true
                 AND lower(btrim(p.role)) IN ('admin','accounts','manager','cashier'));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_shift_can_take(p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.lwb_acc_cash_people c WHERE c.user_id = p_user)
     AND public.lwb_acc_cash_role_ok(p_user);
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_acc_cash_people_get()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_admin boolean := public.lwb_acc_admin();
BEGIN
  IF NOT public.lwb_acc_shift_ok(auth.uid()) THEN RAISE EXCEPTION 'Admin / Accounts / Cashier only'; END IF;
  RETURN jsonb_build_object(
    'is_admin', v_admin,
    'list', coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'name', coalesce(nullif(btrim(p.full_name),''), 'User'),
              'role', lower(btrim(p.role)), 'me', p.id = auth.uid()) ORDER BY c.sort, p.full_name)
            FROM public.lwb_acc_cash_people c JOIN public.user_profiles p ON p.id = c.user_id
            WHERE public.lwb_acc_cash_role_ok(p.id)), '[]'::jsonb),
    'all', CASE WHEN v_admin THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id', p.id, 'name', coalesce(nullif(btrim(p.full_name),''), 'User'),
              'role', lower(btrim(p.role)), 'on', c.user_id IS NOT NULL) ORDER BY c.user_id IS NULL, c.sort, p.full_name)
            FROM public.user_profiles p LEFT JOIN public.lwb_acc_cash_people c ON c.user_id = p.id
            WHERE public.lwb_acc_cash_role_ok(p.id)), '[]'::jsonb) END);
END
$fn$;

-- the list keeps only those roles (a Salesman tagged before is taken off)
DELETE FROM public.lwb_acc_cash_people c WHERE NOT public.lwb_acc_cash_role_ok(c.user_id);

-- Admin saves only those roles
CREATE OR REPLACE FUNCTION public.lwb_acc_cash_people_set(p_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_ids uuid[];
BEGIN
  IF NOT public.lwb_acc_admin() THEN RAISE EXCEPTION 'Only Admin can change who takes the cash'; END IF;
  SELECT coalesce(array_agg(x.id ORDER BY x.n), '{}') INTO v_ids
  FROM (SELECT DISTINCT ON (u) u AS id, n FROM unnest(coalesce(p_ids,'{}')) WITH ORDINALITY AS t(u, n) WHERE u IS NOT NULL ORDER BY u, n) x
  WHERE public.lwb_acc_cash_role_ok(x.id);
  IF cardinality(v_ids) = 0 THEN RAISE EXCEPTION 'Keep at least one person'; END IF;
  IF cardinality(v_ids) > 10 THEN RAISE EXCEPTION 'Keep 10 people or less'; END IF;
  DELETE FROM public.lwb_acc_cash_people c WHERE NOT (c.user_id = ANY (v_ids));
  INSERT INTO public.lwb_acc_cash_people (user_id, sort, added_by)
  SELECT u, n, auth.uid() FROM unnest(v_ids) WITH ORDINALITY AS t(u, n)
  ON CONFLICT (user_id) DO UPDATE SET sort = excluded.sort;
  RETURN jsonb_build_object('ok', true, 'count', cardinality(v_ids));
END
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_cash_role_ok(uuid), public.lwb_acc_shift_can_take(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_acc_cash_people_get(), public.lwb_acc_cash_people_set(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_acc_cash_people_get(), public.lwb_acc_cash_people_set(uuid[]) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: true; then who may take cash now (roles only).
SELECT 'only admin / accounts / sales head' AS item, (NOT EXISTS (SELECT 1 FROM public.lwb_acc_cash_people c
  WHERE NOT public.lwb_acc_cash_role_ok(c.user_id)))::text AS ok;
SELECT lower(btrim(p.role)) AS role, count(*) FROM public.lwb_acc_cash_people c JOIN public.user_profiles p ON p.id = c.user_id GROUP BY 1 ORDER BY 1;
