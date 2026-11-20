-- LUXURY WRIST BRAND ERP — GOODS INWARD: DRIVER NAME / MOBILE MAY BE LEFT BLANK.
--
-- Safe to run again. Applied by the "Supabase apply" workflow on merge.
-- v2: first run stopped (nothing changed) because it also looked at other pages' functions
-- (e.g. lwb_admin_set_driver_mobile); now only Goods Inward functions are touched.
--
-- Mohit (20 Nov 2026): the Rajnigandha "Vehicle & driver details" popup says every detail
-- is optional, but Save failed with "Inward NOT saved: Enter Driver Name (1 to 100 characters)".
-- That check lives in the live lwb_post_goods_inward (made outside this repo), so it is
-- relaxed in place, the same way lwb_goods_inward_godown_setup.sql widened its role check:
--
-- 1. lwb_post_goods_inward(_mrp) and any trigger function on lwb_goods_inward, where the body has
--      IF <condition> THEN RAISE EXCEPTION '...Driver Name...' / '...Driver Mobile...'
--    gets a guard in front of the condition: the check now runs only when a value was typed.
--    So a blank name / mobile saves, a typed name still has to be at most 100 characters and
--    a typed mobile still has to be valid. Nothing else in the function changes.
-- 2. lwb_goods_inward.driver_name / driver_mobile: NOT NULL is removed and any CHECK on them
--    is rebuilt as "blank, or the old rule".
--
-- The brand rule (Coca-Cola must have driver + mobile + Godown Manager) stays on the page.
-- No bill, stock or ledger data is changed. If something is still blocking, this script
-- stops with an error so the workflow run turns red.

DO $do$
DECLARE
  f record;
  d text;
  full_def text;
  n text;
  m text[];
  head text;
  cond text;
  guard text;
  v_name text;
  v_mob text;
  pos int;
  cnt int := 0;
BEGIN
  FOR f IN
    SELECT p.oid, p.oid::regprocedure AS sig, p.prorettype = 'trigger'::regtype AS is_trigger
    FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
    WHERE s.nspname = 'public' AND p.prokind = 'f' AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
      -- only Goods Inward: its save functions and the triggers on lwb_goods_inward (other pages keep their rules)
      AND (p.proname IN ('lwb_post_goods_inward','lwb_post_goods_inward_mrp')
           OR p.oid IN (SELECT t.tgfoid FROM pg_trigger t WHERE t.tgrelid = to_regclass('public.lwb_goods_inward') AND NOT t.tgisinternal))
      AND pg_get_functiondef(p.oid) ~* 'RAISE\s+EXCEPTION[^;]*Driver\s+(Name|Mobile)'
  LOOP
    d := pg_get_functiondef(f.oid);
    full_def := d;
    IF f.is_trigger THEN
      v_name := 'NEW.driver_name'; v_mob := 'NEW.driver_mobile';
    ELSE
      v_name := 'p_driver_name';   v_mob := 'p_driver_mobile';
    END IF;
    n := '';
    -- walk every "IF ... THEN RAISE EXCEPTION '...Driver Name|Mobile...'" one by one
    LOOP
      m := regexp_match(d, '(\m(?:ELS)?IF\M)(\s(?:(?!\mTHEN\M)[^;])*\s)(THEN\s+RAISE\s+EXCEPTION\s+(?:USING\s+MESSAGE\s*=\s*)?E?''[^'']*Driver\s+(Name|Mobile)[^'']*'')', 'i');
      EXIT WHEN m IS NULL;
      head := m[1] || m[2] || m[3];
      pos := strpos(d, head);
      cond := m[2];
      IF cond LIKE '%lwb:driver-optional%' THEN
        n := n || substr(d, 1, pos - 1) || head;
      ELSE
        guard := CASE WHEN lower(m[4]) = 'name' THEN v_name ELSE v_mob END;
        IF strpos(lower(full_def), lower(guard)) = 0 THEN
          RAISE EXCEPTION '% checks the driver but has no %: fix by hand', f.sig, guard;
        END IF;
        n := n || substr(d, 1, pos - 1) || m[1]
             || ' /*lwb:driver-optional*/ nullif(btrim(coalesce(' || guard || '::text, '''')), '''') IS NOT NULL AND ('
             || btrim(cond) || ') ' || m[3];
        cnt := cnt + 1;
      END IF;
      d := substr(d, pos + length(head));
    END LOOP;
    n := n || d;
    IF n IS DISTINCT FROM full_def THEN
      EXECUTE n;
      RAISE NOTICE '% : blank driver name / mobile now allowed', f.sig;
    ELSE
      RAISE NOTICE '% : already allows a blank driver', f.sig;
    END IF;
  END LOOP;
  RAISE NOTICE 'driver checks relaxed: %', cnt;
END $do$;

-- Table: blank / NULL driver name and mobile allowed.
DO $do$
DECLARE
  c record;
  col text;
  expr text;
BEGIN
  IF to_regclass('public.lwb_goods_inward') IS NULL THEN RETURN; END IF;
  FOREACH col IN ARRAY ARRAY['driver_name','driver_mobile'] LOOP
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'lwb_goods_inward' AND column_name = col AND is_nullable = 'NO') THEN
      EXECUTE format('ALTER TABLE public.lwb_goods_inward ALTER COLUMN %I DROP NOT NULL', col);
      RAISE NOTICE 'lwb_goods_inward.% may now be empty', col;
    END IF;
  END LOOP;
  FOR c IN
    SELECT con.conname, pg_get_constraintdef(con.oid) AS def
    FROM pg_constraint con
    WHERE con.conrelid = 'public.lwb_goods_inward'::regclass AND con.contype = 'c'
      AND pg_get_constraintdef(con.oid) ~* '\mdriver_(name|mobile)\M'
      AND pg_get_constraintdef(con.oid) !~* 'lwb_driver_blank_ok'
  LOOP
    col := CASE WHEN c.def ~* '\mdriver_name\M' THEN 'driver_name' ELSE 'driver_mobile' END;
    expr := regexp_replace(c.def, '^CHECK\s*', '', 'i');
    expr := regexp_replace(expr, '\s*NOT VALID\s*$', '', 'i');
    EXECUTE format('ALTER TABLE public.lwb_goods_inward DROP CONSTRAINT %I', c.conname);
    -- "lwb_driver_blank_ok" in the text marks the rebuilt rule so a second run leaves it alone
    EXECUTE format('ALTER TABLE public.lwb_goods_inward ADD CONSTRAINT %I CHECK (nullif(btrim(coalesce(%I, ''lwb_driver_blank_ok'')), ''lwb_driver_blank_ok'') IS NULL OR nullif(btrim(%I), '''') IS NULL OR %s)',
                   c.conname, col, col, expr);
    RAISE NOTICE 'constraint % now allows a blank %', c.conname, col;
  END LOOP;
END $do$;

NOTIFY pgrst, 'reload schema';

-- Check: no unguarded driver check may be left. If one is, stop with an error.
DO $do$
DECLARE
  bad text;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO bad
  FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
  WHERE s.nspname = 'public' AND p.prokind = 'f'
    AND (p.proname IN ('lwb_post_goods_inward','lwb_post_goods_inward_mrp')
         OR p.oid IN (SELECT t.tgfoid FROM pg_trigger t WHERE t.tgrelid = to_regclass('public.lwb_goods_inward') AND NOT t.tgisinternal))
    AND regexp_replace(pg_get_functiondef(p.oid), '\m(ELS)?IF\M\s+/\*lwb:driver-optional\*/(?:(?!\mTHEN\M)[^;])*THEN\s+RAISE\s+EXCEPTION[^;]*;', '', 'gi')
        ~* 'RAISE\s+EXCEPTION[^;]*Driver\s+Name[^;]*\(1\s+to\s+100';
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'Driver Name is still required in: %', bad;
  END IF;
  -- the live message must have been found (and guarded) in a Goods Inward function
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
                 WHERE s.nspname = 'public' AND pg_get_functiondef(p.oid) LIKE '%lwb:driver-optional%') THEN
    SELECT string_agg(p.oid::regprocedure::text, ', ') INTO bad
    FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
    WHERE s.nspname = 'public' AND p.prokind = 'f' AND pg_get_functiondef(p.oid) ~* 'Driver\s+Name\s*\(1\s+to\s+100';
    RAISE EXCEPTION 'Driver Name check not found in Goods Inward functions; message is in: %', coalesce(bad, 'none');
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'lwb_goods_inward'
             AND column_name IN ('driver_name','driver_mobile') AND is_nullable = 'NO') THEN
    RAISE EXCEPTION 'lwb_goods_inward driver columns are still NOT NULL';
  END IF;
  RAISE NOTICE 'OK: Goods Inward saves with a blank driver name / mobile';
END $do$;
