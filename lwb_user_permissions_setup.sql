-- LUXURY WRIST BRAND ERP | ADMIN USER ROLE MANAGEMENT
-- Run ONCE in Supabase SQL Editor.
-- Creates two Admin-only RPC functions. Does not change existing user roles,
-- remove users, modify orders, or change Tally.
--
-- Only an ACTIVE ADMIN in public.user_profiles can list users and set roles.
-- The Auth user must already exist in Supabase Authentication > Users.
-- This migration cannot grant Accounts permission to write.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_admin_list_users()
RETURNS TABLE (
  user_id uuid,
  email text,
  full_name text,
  erp_role text,
  is_active boolean,
  has_profile boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.user_profiles p
    WHERE p.id = auth.uid()
      AND p.active IS TRUE
      AND lower(btrim(p.role)) = 'admin'
  ) THEN
    RAISE EXCEPTION 'Admin permission required to view ERP users';
  END IF;

  RETURN QUERY
    SELECT
      u.id,
      u.email::text,
      p.full_name::text,
      p.role::text,
      p.active,
      (p.id IS NOT NULL)
    FROM auth.users AS u
    LEFT JOIN public.user_profiles AS p ON p.id = u.id
    ORDER BY u.created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.lwb_admin_set_user_role(
  p_user_id uuid,
  p_role text,
  p_full_name text,
  p_active boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role text := lower(btrim(coalesce(p_role, '')));
  v_email text;
  v_name text;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.user_profiles p
    WHERE p.id = auth.uid()
      AND p.active IS TRUE
      AND lower(btrim(p.role)) = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only an active ERP Admin may assign user roles';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'Select an existing Supabase Authentication user';
  END IF;

  IF v_role NOT IN ('admin', 'accounts', 'manager', 'sales', 'warehouse', 'transport') THEN
    RAISE EXCEPTION 'Invalid ERP role: %', v_role;
  END IF;

  IF p_active IS NULL THEN
    RAISE EXCEPTION 'Active / Inactive status must be selected';
  END IF;

  SELECT email::text INTO v_email
  FROM auth.users WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Supabase Authentication user not found';
  END IF;

  -- Keep the currently signed-in admin active and authorized.
  IF p_user_id = auth.uid() AND (v_role <> 'admin' OR p_active IS NOT TRUE) THEN
    RAISE EXCEPTION 'You cannot remove your own Admin role or deactivate your account';
  END IF;

  v_name := coalesce(nullif(btrim(p_full_name), ''), split_part(v_email, '@', 1));
  IF length(v_name) > 150 THEN
    RAISE EXCEPTION 'Name is too long';
  END IF;

  INSERT INTO public.user_profiles (id, full_name, role, active)
  VALUES (p_user_id, v_name, v_role, p_active)
  ON CONFLICT (id) DO UPDATE SET
    full_name = EXCLUDED.full_name,
    role      = EXCLUDED.role,
    active    = EXCLUDED.active;
END;
$$;

-- RPCs are callable by signed-in users, but each function verifies their
-- current Admin role INSIDE the database. Anonymous execution is revoked.
REVOKE ALL ON FUNCTION public.lwb_admin_list_users() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lwb_admin_set_user_role(uuid,text,text,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_admin_list_users() TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_admin_set_user_role(uuid,text,text,boolean) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Read-only verification:
SELECT routine_name
FROM information_schema.routines
WHERE routine_schema='public'
  AND routine_name IN ('lwb_admin_list_users','lwb_admin_set_user_role')
ORDER BY routine_name;
