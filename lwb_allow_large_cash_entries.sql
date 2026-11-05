-- Allow cash of Rs 2 lakh or more to be saved (5 Nov 2026).
-- This ERP is the company's own record book (like Tally): a real cash receipt
-- must be recorded in full. Earlier functions refused cash >= Rs 2,00,000 with an
-- "Income Tax 269ST" / "compliance review" error. The pages now only show a soft
-- yellow note; this file removes the hard stop from every live function.
--
-- It edits the LIVE definition of each function (pg_get_functiondef), so the
-- newest version of every function is kept and only the 2 lakh block is cut out.
-- Owner, SECURITY DEFINER, search_path and grants stay the same.
-- Safe to run more than once.

DO $$
DECLARE
  r record;
  v_old text;
  v_new text;
  v_n int := 0;
  -- IF <condition> >= 200000 THEN RAISE EXCEPTION '... 2 lakh ...'; END IF;
  v_re constant text :=
    '\mIF\M[^;]*>=\s*200000\s+THEN\s+RAISE\s+EXCEPTION\s+''[^'']*2 lakh[^'']*''\s*;\s*END\s+IF\s*;';
BEGIN
  FOR r IN
    SELECT p.oid
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.prokind = 'f'
       AND p.prosrc ~* '200000'
       AND p.prosrc ~* '2 lakh'
  LOOP
    v_old := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_old, v_re,
      '-- Rs 2 lakh cash limit removed (internal record book, 5 Nov 2026)', 'gi');
    IF v_new <> v_old THEN
      EXECUTE v_new;
      v_n := v_n + 1;
      RAISE NOTICE 'Removed 2 lakh cash block from %', r.oid::regprocedure;
    END IF;
  END LOOP;
  RAISE NOTICE '2 lakh cash block removed from % function(s)', v_n;
END $$;

-- Check: no public function should still refuse 2 lakh cash.
SELECT p.oid::regprocedure AS still_blocking
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.prokind = 'f'
   AND p.prosrc ~* '>=\s*200000\s+THEN\s+RAISE\s+EXCEPTION\s+''[^'']*2 lakh';
