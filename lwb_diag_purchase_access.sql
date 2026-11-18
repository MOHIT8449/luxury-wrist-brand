-- READ-ONLY DIAGNOSTIC (never merged): which Purchase List / Check / Claims calls fail
-- for Sales Head logins. Ends with RAISE EXCEPTION so the one-line report shows in the
-- Actions log and the transaction rolls back. Prints initials and ok / error only.
DO $do$
DECLARE
  u record; rep text := ''; t text; v_ids text[]; n bigint; st text; msg text;
  tests text[] := ARRAY['inward','items','checks','open_tasks','doc_list','doc_view_bill','doc_edit_damage','sku','profile','sp_settings','notif','my_cos','claims_page','gi_page','pr_page','pc_user'];
BEGIN
  SELECT array_agg(id::text) INTO v_ids FROM (SELECT g.id FROM public.lwb_goods_inward g ORDER BY g.created_at DESC NULLS LAST LIMIT 5) x;
  FOR u IN
    SELECT p.id, p.role, p.active, p.full_name,
           coalesce((SELECT a.hidden FROM public.lwb_user_page_access a WHERE a.user_id = p.id), '{}') AS hid,
           coalesce((SELECT a.extra FROM public.lwb_user_page_access a WHERE a.user_id = p.id), '{}') AS ext,
           (SELECT count(*) FROM public.lwb_user_companies c WHERE c.user_id = p.id) AS cos
    FROM public.user_profiles p
    WHERE lower(btrim(p.role)) = 'manager' AND p.full_name ILIKE 'vin%'
    ORDER BY p.full_name
  LOOP
    rep := rep || ' || ' || regexp_replace(coalesce(u.full_name,'?'), '(\w)\w*\s*', '\1', 'g')
        || ' role=[' || coalesce(u.role,'NULL') || '] active=' || coalesce(u.active::text,'NULL')
        || ' brands=' || u.cos
        || ' hidden=' || coalesce(array_to_string(ARRAY(SELECT h FROM unnest(u.hid) h WHERE h ~* 'purchase|goods|claim|inward'), ','),'')
        || ' extra=' || coalesce(array_to_string(ARRAY(SELECT h FROM unnest(u.ext) h WHERE h ~* 'purchase|goods|claim|inward'), ','),'') || ' :';
    FOREACH t IN ARRAY tests LOOP
      BEGIN
        PERFORM set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true);
        PERFORM set_config('request.jwt.claim.sub', u.id::text, true);
        SET LOCAL ROLE authenticated;
        n := NULL;
        CASE t
          WHEN 'inward' THEN SELECT count(*) INTO n FROM public.lwb_goods_inward;
          WHEN 'items' THEN SELECT count(*) INTO n FROM public.lwb_goods_inward_items;
          WHEN 'checks' THEN SELECT count(*) INTO n FROM public.lwb_purchase_checks;
          WHEN 'open_tasks' THEN SELECT count(*) INTO n FROM public.lwb_purchase_open_tasks();
          WHEN 'doc_list' THEN SELECT count(*) INTO n FROM public.lwb_doc_list('PURCHASE_BILL', v_ids);
          WHEN 'doc_view_bill' THEN SELECT CASE WHEN public.lwb_doc_access('PURCHASE_BILL','BILL','view') THEN 1 ELSE 0 END INTO n;
          WHEN 'doc_edit_damage' THEN SELECT CASE WHEN public.lwb_doc_access('PURCHASE_BILL','DAMAGE','edit') THEN 1 ELSE 0 END INTO n;
          WHEN 'sku' THEN SELECT count(*) INTO n FROM public.sku_master;
          WHEN 'profile' THEN SELECT count(*) INTO n FROM public.user_profiles WHERE id = u.id;
          WHEN 'sp_settings' THEN SELECT count(*) INTO n FROM public.lwb_sp_settings;
          WHEN 'notif' THEN SELECT count(*) INTO n FROM public.erp_notifications WHERE false;
          WHEN 'my_cos' THEN SELECT coalesce(array_length(public.lwb_my_companies(),1),-1) INTO n;
          WHEN 'claims_page' THEN SELECT CASE WHEN public.lwb_has_page('purchase-claims.html') THEN 1 ELSE 0 END INTO n;
          WHEN 'gi_page' THEN SELECT CASE WHEN public.lwb_has_page('goods-inward.html') THEN 1 ELSE 0 END INTO n;
          WHEN 'pr_page' THEN SELECT CASE WHEN public.lwb_has_page('purchase-register.html') THEN 1 ELSE 0 END INTO n;
          WHEN 'pc_user' THEN SELECT CASE WHEN public.lwb_pc_user() THEN 1 ELSE 0 END INTO n;
        END CASE;
        RESET ROLE;
        rep := rep || ' ' || t || '=' || coalesce(n::text,'null');
      EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE, msg = MESSAGE_TEXT;
        rep := rep || ' ' || t || '=ERR(' || st || ':' || left(regexp_replace(msg, '\s+', ' ', 'g'), 90) || ')';
      END;
    END LOOP;
  END LOOP;
  RAISE EXCEPTION 'DIAG%', replace(rep, E'\n', ' ');
END
$do$;
