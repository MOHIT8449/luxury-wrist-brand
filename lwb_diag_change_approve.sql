-- DIAGNOSTIC DRY RUN (not for main). Tries Admin approve of the waiting PO change on LXY-00441 and
-- always rolls back; prints only the error text.
DO $diag$
DECLARE v_id uuid; v_admin uuid; v_msg text; v_ctx text; v_res jsonb; v_info text;
BEGIN
  SELECT c.id INTO v_id FROM public.lwb_bill_changes c JOIN public.orders o ON o.id = c.order_id
   WHERE o.order_no = 'LXY-00441' AND c.status = 'WAITING' ORDER BY c.requested_at DESC LIMIT 1;
  SELECT p.id INTO v_admin FROM public.user_profiles p WHERE p.active AND lower(btrim(p.role)) = 'admin'
   ORDER BY (upper(p.full_name) LIKE '%MOHIT%') DESC LIMIT 1;
  SELECT 'st=' || coalesce(o.status::text,'?') || ' col=' || c.qty_col || ' lines=' ||
         (SELECT string_agg(coalesce(l->>'item_id','new') || ':' || coalesce(l->>'qty_old','') || '>' || coalesce(l->>'qty',''), ',') FROM jsonb_array_elements(c.lines) l)
         || ' cur=' || (SELECT string_agg(i.id::text || ':a' || coalesce(i.approved_qty::text,'-') || ':l' || coalesce(i.loaded_qty::text,'-'), ',') FROM public.order_items i WHERE i.order_id = c.order_id)
    INTO v_info FROM public.lwb_bill_changes c JOIN public.orders o ON o.id = c.order_id WHERE c.id = v_id;
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  SET CONSTRAINTS ALL IMMEDIATE;
  BEGIN
    v_res := public.lwb_bill_change_decide(v_id, true, NULL);
    v_msg := 'APPROVE WORKED ' || coalesce(v_res::text,'');
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_ctx = PG_EXCEPTION_CONTEXT;
    v_msg := SQLSTATE || ' ' || SQLERRM || ' @@ ' || replace(coalesce(v_ctx,''), E'\n', ' | ');
  END;
  RAISE EXCEPTION 'DIAG id=% admin=% info=% RESULT: %', v_id IS NOT NULL, v_admin IS NOT NULL, v_info, replace(v_msg, E'\n', ' | ');
END
$diag$;
