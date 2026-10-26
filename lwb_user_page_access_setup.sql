-- LUXURY WRIST BRAND ERP — PER-USER PAGE ACCESS (TICK / UNTICK PAGES)
--
-- RUN ONCE in Supabase SQL Editor, after lwb_user_login_setup.sql. Safe to run again.
--
-- * Every role keeps its default pages (the side menu of that role).
-- * Manage Users > Pages: Admin unticks a page for one user. That page leaves
--   the user's menu, dashboard and search, and opening it goes back to an
--   allowed page. Ticking it again gives it back. No role change needed.
-- * Only pages hidden from a user are stored; a new page in a role's menu
--   is shown to that role's users by default.
-- * An Admin can never hide Manage Users from an Admin (no lock-out).
--
-- No order, stock, bill, payment, ledger or Tally data is changed.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_user_page_access (
  user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  hidden     text[] NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

ALTER TABLE public.lwb_user_page_access ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_user_page_access FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_user_page_access TO authenticated;

DROP POLICY IF EXISTS lwb_page_access_read ON public.lwb_user_page_access;
CREATE POLICY lwb_page_access_read ON public.lwb_user_page_access
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.lwb_is_admin());

-- Admin saves the pages hidden from one user (empty list = role default).
CREATE OR REPLACE FUNCTION public.lwb_admin_set_page_access(p_user_id uuid, p_hidden text[])
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_role text;
  v_hidden text[];
BEGIN
  IF NOT public.lwb_is_admin() THEN
    RAISE EXCEPTION 'Only an active Admin can change page access.';
  END IF;
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found.';
  END IF;

  SELECT coalesce(array_agg(DISTINCT k ORDER BY k), '{}') INTO v_hidden
  FROM unnest(coalesce(p_hidden, '{}')) AS u(k)
  WHERE k ~ '^[a-z0-9-]+\.html(#[a-z0-9-]+)?$'
    AND NOT (v_role = 'admin' AND k = 'users.html');

  INSERT INTO public.lwb_user_page_access AS a (user_id, hidden, updated_at, updated_by)
  VALUES (p_user_id, v_hidden, now(), auth.uid())
  ON CONFLICT (user_id) DO UPDATE
    SET hidden = excluded.hidden, updated_at = now(), updated_by = auth.uid();
  RETURN v_hidden;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_admin_set_page_access(uuid, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_admin_set_page_access(uuid, text[]) TO authenticated;

COMMIT;

-- Check (both should be true):
-- SELECT to_regclass('public.lwb_user_page_access') IS NOT NULL AS table_ready,
--        to_regprocedure('public.lwb_admin_set_page_access(uuid,text[])') IS NOT NULL AS save_ready;
