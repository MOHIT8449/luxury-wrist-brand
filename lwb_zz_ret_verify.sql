-- One-off check (not for main).
DO $$
DECLARE bad text := '';
BEGIN
  IF to_regprocedure('public.lwb_receive_return_goods3(uuid,jsonb,text)') IS NULL THEN bad := bad || ' goods3'; END IF;
  IF to_regprocedure('public.lwb_return_approved_notify()') IS NOT NULL AND pg_get_functiondef('public.lwb_return_approved_notify()'::regprocedure) !~ 'lwb_return_gm' THEN bad := bad || ' notify'; END IF;
  IF (SELECT count(*) FROM regexp_matches(pg_get_functiondef('public.lwb_my_verify_queue()'::regprocedure), 'lwb_return_gm\(r\.order_id\) IS NULL', 'g')) < 2 THEN bad := bad || ' queue'; END IF;
  IF bad <> '' THEN RAISE EXCEPTION 'Return check missing:%', bad; END IF;
END $$;
