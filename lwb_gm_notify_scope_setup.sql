-- LUXURY WRIST BRAND ERP — GODOWN MANAGER GETS ONLY HIS OWN WORK BELLS (19 Nov 2026)
--
-- Mohit (19 Nov 2026): a Godown Manager (role warehouse) must get a notification only for work given to him:
--   * loading of a vehicle / PO he is assigned to (dispatch_assignments.loading_manager_id or Self Pickup
--     lwb_order_pickup.godown_user_id), incl. "Loading moved to another Godown Manager";
--   * a purchase vehicle he has to unload / check / add photos for (PURCHASE_ARRIVED, sent only to the
--     Godown Manager chosen on the bill);
--   * tasks given to him (TASK_*, the purchase photo task is a task too);
--   * market return goods of his own loaded vehicle (DELIVERY_RETURN_RECEIVE, lwb_return_gm = him);
--   * team chat (CHAT_MSG, phone push only) and Admin's Dashboard announcement (ANNOUNCEMENT).
-- Everything else (bill made, PO change, PO approved, delivered, rate checks, cash, ...) is not sent to him.
--
--   1. lwb_gm_bell_ok(user, type, order, ref_type, ref_id, title)  true = this bell may go to this user.
--   2. BEFORE INSERT trigger on erp_notifications: a bell for a Godown Manager that is not his work is dropped
--      (so no phone push either: the push trigger runs AFTER INSERT).
--   3. RESTRICTIVE SELECT policy: old bells already in his list that are not his work are hidden.
--   4. Old unread bells of that kind are marked read once (nothing deleted).
-- Other roles: unchanged. Safe to run again.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_gm_bell_ok(p_user uuid, p_type text, p_order uuid, p_ref_type text, p_ref_id text, p_title text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE t text := upper(regexp_replace(coalesce(p_type,''), '^CC_', ''));
BEGIN
  IF p_user IS NULL OR NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = p_user AND lower(btrim(p.role)) = 'warehouse') THEN
    RETURN true;
  END IF;
  IF t LIKE 'TASK\_%' OR t IN ('CHAT_MSG','ANNOUNCEMENT') THEN RETURN true; END IF;

  IF t = 'PURCHASE_ARRIVED' THEN
    -- Only the Godown Manager chosen on the purchase bill.
    BEGIN
      RETURN p_ref_type = 'PURCHASE_BILL' AND EXISTS (SELECT 1 FROM public.lwb_goods_inward g
        WHERE g.id::text = p_ref_id AND g.godown_user_id = p_user);
    EXCEPTION WHEN undefined_table OR undefined_column OR invalid_text_representation THEN RETURN true;
    END;
  END IF;

  IF t = 'LOADING_ASSIGNMENT_DISPATCH' THEN
    IF coalesce(p_title,'') ILIKE 'Loading Moved%' THEN RETURN true; END IF;
    IF p_order IS NULL THEN RETURN false; END IF;
    IF EXISTS (SELECT 1 FROM public.dispatch_assignments a WHERE a.order_id = p_order AND a.loading_manager_id = p_user) THEN RETURN true; END IF;
    BEGIN
      RETURN EXISTS (SELECT 1 FROM public.lwb_order_pickup k WHERE k.order_id = p_order AND k.godown_user_id = p_user);
    EXCEPTION WHEN undefined_table OR undefined_column THEN RETURN false;
    END;
  END IF;

  IF t = 'DELIVERY_RETURN_RECEIVE' THEN
    IF p_order IS NULL THEN RETURN false; END IF;
    BEGIN
      RETURN public.lwb_return_gm(p_order) = p_user;
    EXCEPTION WHEN undefined_function THEN
      RETURN EXISTS (SELECT 1 FROM public.dispatch_assignments a WHERE a.order_id = p_order AND a.loading_manager_id = p_user);
    END;
  END IF;

  RETURN false;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_gm_bell_ok(uuid,text,uuid,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_gm_bell_ok(uuid,text,uuid,text,text,text) TO authenticated;

-- 2. Drop a new bell that is not the Godown Manager's own work.
CREATE OR REPLACE FUNCTION public.lwb_gm_bell_filter()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_gm_bell_ok(NEW.user_id, NEW.notification_type, NEW.order_id, NEW.ref_type, NEW.ref_id, NEW.title) THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_gm_bell_filter() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_lwb_gm_bell_filter ON public.erp_notifications;
CREATE TRIGGER trg_lwb_gm_bell_filter BEFORE INSERT ON public.erp_notifications
  FOR EACH ROW EXECUTE FUNCTION public.lwb_gm_bell_filter();

-- 3. Hide old bells of other work from a Godown Manager (his own login only; others unchanged).
CREATE OR REPLACE FUNCTION public.lwb_i_am_gm()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = auth.uid() AND lower(btrim(role)) = 'warehouse');
$fn$;
REVOKE ALL ON FUNCTION public.lwb_i_am_gm() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_i_am_gm() TO authenticated;

ALTER TABLE public.erp_notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lwb_gm_own_work_bells ON public.erp_notifications;
CREATE POLICY lwb_gm_own_work_bells ON public.erp_notifications AS RESTRICTIVE FOR SELECT TO authenticated
  USING (NOT public.lwb_i_am_gm() OR public.lwb_gm_bell_ok(user_id, notification_type, order_id, ref_type, ref_id, title));

-- 4. Old unread bells of other work: marked read once (kept, not deleted).
UPDATE public.erp_notifications n SET is_read = true
WHERE n.is_read = false
  AND EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = n.user_id AND lower(btrim(p.role)) = 'warehouse')
  AND NOT public.lwb_gm_bell_ok(n.user_id, n.notification_type, n.order_id, n.ref_type, n.ref_id, n.title);

-- Check: fails the run if the filter is not in place.
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_gm_bell_filter' AND tgrelid = 'public.erp_notifications'::regclass) THEN
    RAISE EXCEPTION 'Godown Manager bell filter trigger missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'erp_notifications' AND policyname = 'lwb_gm_own_work_bells') THEN
    RAISE EXCEPTION 'Godown Manager bell policy missing';
  END IF;
END $do$;

COMMIT;
NOTIFY pgrst, 'reload schema';
