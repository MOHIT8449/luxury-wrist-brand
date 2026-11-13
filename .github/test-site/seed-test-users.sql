-- Dummy test logins, one per role, on the TEST database only.
-- Login: the email below + the password from the GitHub secret
-- STAGING_TEST_PASSWORD (the workflow sets lwb.test_pw first). Running again resets the password.
DO $$
DECLARE
  r record; v_id uuid; v_pw text := current_setting('lwb.test_pw');
BEGIN
  IF length(coalesce(v_pw, '')) < 8 THEN RAISE EXCEPTION 'STAGING_TEST_PASSWORD must be 8+ characters'; END IF;
  FOR r IN SELECT * FROM (VALUES
      ('test.admin@lwb.test',     'TEST Admin',          'admin'),
      ('test.saleshead@lwb.test', 'TEST Sales Head',     'manager'),
      ('test.salesman@lwb.test',  'TEST Salesman',       'sales'),
      ('test.accounts@lwb.test',  'TEST Accounts',       'accounts'),
      ('test.godown@lwb.test',    'TEST Godown Manager', 'warehouse'),
      ('test.transport@lwb.test', 'TEST Transport',      'transport'),
      ('test.driver@lwb.test',    'TEST Driver',         'driver')
    ) t(email, full_name, role)
  LOOP
    SELECT id INTO v_id FROM auth.users WHERE lower(email) = r.email;
    IF v_id IS NULL THEN
      v_id := gen_random_uuid();
      INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new, email_change)
      VALUES ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', r.email,
        extensions.crypt(v_pw, extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', r.full_name),
        now(), now(), '', '', '', '');
      INSERT INTO auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
      VALUES (gen_random_uuid(), v_id::text, v_id,
        jsonb_build_object('sub', v_id::text, 'email', r.email, 'email_verified', true, 'phone_verified', false),
        'email', now(), now(), now());
    ELSE
      UPDATE auth.users SET encrypted_password = extensions.crypt(v_pw, extensions.gen_salt('bf')), updated_at = now()
       WHERE id = v_id;
    END IF;
    IF to_regclass('public.user_profiles') IS NOT NULL THEN
      INSERT INTO public.user_profiles (id, full_name, role, active)
      VALUES (v_id, r.full_name, r.role, true)
      ON CONFLICT (id) DO UPDATE SET full_name = excluded.full_name, role = excluded.role, active = true;
    END IF;
  END LOOP;
END $$;
