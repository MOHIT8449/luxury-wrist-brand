-- LUXURY WRIST BRAND ERP | DRIVER ROLE CHECK FIX
-- Fix: "user_profiles_role_check" is rejecting DRIVER during Admin Save Role.
-- Safe: preserves the existing CHECK expression, adding only DRIVER as an
-- additional allowed value. Does NOT insert users or update existing profiles.
-- Run once (or again safely) in the Supabase SQL Editor.

BEGIN;

DO $driver_role_fix$
DECLARE
  v_existing_expr text;
BEGIN
  SELECT pg_get_expr(c.conbin,c.conrelid)
  INTO v_existing_expr
  FROM pg_constraint c
  WHERE c.conrelid = 'public.user_profiles'::regclass
    AND c.conname = 'user_profiles_role_check'
    AND c.contype = 'c';

  IF v_existing_expr IS NULL THEN
    RAISE EXCEPTION 'Cannot safely update: user_profiles_role_check CHECK constraint not found. No changes made.';
  END IF;

  -- Preserve ALL previously allowed roles and other conditions rather than
  -- guessing what the existing CHECK allows.
  EXECUTE 'ALTER TABLE public.user_profiles DROP CONSTRAINT user_profiles_role_check';
  EXECUTE format(
    'ALTER TABLE public.user_profiles ADD CONSTRAINT user_profiles_role_check CHECK ((%s) OR (lower(btrim(role)) = %L))',
    v_existing_expr, 'driver'
  );
END
$driver_role_fix$;

COMMIT;

-- Read-only verification:
SELECT conname, pg_get_constraintdef(oid) AS updated_rule
FROM pg_constraint
WHERE conrelid='public.user_profiles'::regclass
  AND conname='user_profiles_role_check';
