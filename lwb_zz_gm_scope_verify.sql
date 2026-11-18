-- One-off check (not for main): fails loudly if a Godown Manager scope patch is missing.
DO $$
DECLARE bad text := '';
BEGIN
  IF pg_get_functiondef('public.lwb_my_verify_queue()'::regprocedure) ~ 'loading_manager_id IS NULL OR' THEN bad := bad || ' verify_queue'; END IF;
  IF pg_get_functiondef('public.lwb_doc_types(text)'::regprocedure) !~ 'VEHICLE' THEN bad := bad || ' doc_types'; END IF;
  IF pg_get_functiondef('public.lwb_purchase_photo_task(uuid,uuid[])'::regprocedure) !~ 'godown_user_id' THEN bad := bad || ' photo_task'; END IF;
  IF to_regclass('public.dispatch_assignments') IS NULL OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='dispatch_assignments' AND column_name='loaded_from') THEN bad := bad || ' loaded_from'; END IF;
  IF bad <> '' THEN RAISE EXCEPTION 'GM scope missing:%', bad; END IF;
END $$;
