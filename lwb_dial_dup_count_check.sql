-- LUXURY WRIST BRAND ERP — READ-ONLY CHECK: duplicate party numbers (27 Nov 2026)
-- Prints counts only (no names, no phone numbers) in the run log. Changes nothing.
-- It stops with an ERROR on purpose, so the counts show in the log (the run turns red; nothing is written).
-- Read-only count for the run log (numbers only: no names, no phone numbers).
DO $chk$
DECLARE v_p int; v_num int; v_dup_nums int; v_dup_parties int; v_team int; v_none int;
BEGIN
  SELECT count(*) INTO v_p FROM public.lwb_customer_master c WHERE coalesce(c.is_active, true) AND public.lwb_dial_mob(c.mobile) IS NOT NULL;
  SELECT count(*) INTO v_none FROM public.lwb_customer_master c WHERE coalesce(c.is_active, true) AND public.lwb_dial_mob(c.mobile) IS NULL;
  SELECT count(DISTINCT public.lwb_dial_mob(c.mobile)) INTO v_num FROM public.lwb_customer_master c WHERE coalesce(c.is_active, true) AND public.lwb_dial_mob(c.mobile) IS NOT NULL;
  SELECT count(*), coalesce(sum(n), 0) INTO v_dup_nums, v_dup_parties FROM (
    SELECT public.lwb_dial_mob(c.mobile) m, count(*) n FROM public.lwb_customer_master c
    WHERE coalesce(c.is_active, true) AND public.lwb_dial_mob(c.mobile) IS NOT NULL GROUP BY 1 HAVING count(*) > 1) q;
  SELECT count(DISTINCT public.lwb_dial_mob(c.mobile)) INTO v_team FROM public.lwb_customer_master c
    JOIN public.user_profiles p ON p.active = true AND public.lwb_dial_mob(p.mobile) = public.lwb_dial_mob(c.mobile)
    WHERE coalesce(c.is_active, true);
  RAISE EXCEPTION 'DIAL CHECK: active parties with mobile=%, without valid mobile=%, different numbers=%, numbers used by 2+ parties=% (parties in them=%), party numbers same as a login=%',
    v_p, v_none, v_num, v_dup_nums, v_dup_parties, v_team;
END $chk$;
