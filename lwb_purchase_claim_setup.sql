-- LUXURY WRIST BRAND ERP — PURCHASE VEHICLE VERIFICATION & DAMAGE CLAIM REGISTER
--
-- RUN ONCE in Supabase SQL Editor. Safe to run again.
--
-- After a purchase vehicle is unloaded, the bill is verified:
--   * "No damage", or
--   * damage / leakage / shortage quantities per SKU (cases + loose PCS).
-- Bills with quantities become claims to send to the company, tracked as
-- PENDING -> SENT -> PASSED (or REJECTED).
-- Quantities only: this does NOT change live stock, purchase bills, payments or Tally.
-- Admin / Manager can view and edit. Deleting a claim is Admin only.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_pc_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true
      AND lower(btrim(p.role)) IN ('admin','manager')
  );
$function$;
CREATE OR REPLACE FUNCTION public.lwb_pc_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles p
    WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) = 'admin'
  );
$function$;
REVOKE ALL ON FUNCTION public.lwb_pc_user() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_pc_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_pc_user() TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_pc_admin() TO authenticated;

-- One verification per purchase bill.
CREATE TABLE IF NOT EXISTS public.lwb_purchase_checks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inward_id uuid NOT NULL UNIQUE REFERENCES public.lwb_goods_inward(id) ON DELETE CASCADE,
  verified_on date NOT NULL,
  has_damage boolean NOT NULL DEFAULT false,
  claim_status text NOT NULL DEFAULT 'NONE' CHECK (claim_status IN ('NONE','PENDING','SENT','PASSED','REJECTED')),
  claim_no text,
  sent_on date,
  settled_on date,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid DEFAULT auth.uid(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid DEFAULT auth.uid(),
  CHECK (has_damage OR claim_status = 'NONE')
);
CREATE INDEX IF NOT EXISTS lwb_purchase_checks_status_idx ON public.lwb_purchase_checks (claim_status, verified_on);

-- Damage / leakage / shortage lines for a verification.
CREATE TABLE IF NOT EXISTS public.lwb_purchase_check_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  check_id uuid NOT NULL REFERENCES public.lwb_purchase_checks(id) ON DELETE CASCADE,
  sku_id uuid,
  sku_name text NOT NULL,
  pcs_per_case integer NOT NULL DEFAULT 1 CHECK (pcs_per_case > 0),
  issue text NOT NULL CHECK (issue IN ('DAMAGE','LEAKAGE','SHORTAGE')),
  cases integer NOT NULL DEFAULT 0 CHECK (cases >= 0),
  pcs integer NOT NULL DEFAULT 0 CHECK (pcs >= 0),
  CHECK (cases + pcs > 0)
);
CREATE INDEX IF NOT EXISTS lwb_purchase_check_items_check_idx ON public.lwb_purchase_check_items (check_id);

-- Saves a verification and its lines in one transaction (replaces earlier lines).
CREATE OR REPLACE FUNCTION public.lwb_save_purchase_check(
  p_inward_id uuid, p_verified_on date, p_note text, p_items jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $function$
DECLARE cid uuid; dmg boolean;
BEGIN
  IF NOT public.lwb_pc_user() THEN RAISE EXCEPTION 'Only Admin / Manager can verify purchase bills'; END IF;
  IF p_verified_on IS NULL THEN RAISE EXCEPTION 'Verification date is required'; END IF;
  dmg := jsonb_typeof(p_items) = 'array' AND jsonb_array_length(p_items) > 0;
  INSERT INTO public.lwb_purchase_checks (inward_id, verified_on, has_damage, claim_status, note)
  VALUES (p_inward_id, p_verified_on, dmg, CASE WHEN dmg THEN 'PENDING' ELSE 'NONE' END, nullif(btrim(p_note),''))
  ON CONFLICT (inward_id) DO UPDATE SET
    verified_on = EXCLUDED.verified_on, has_damage = EXCLUDED.has_damage, note = EXCLUDED.note,
    claim_status = CASE WHEN NOT EXCLUDED.has_damage THEN 'NONE'
                        WHEN public.lwb_purchase_checks.claim_status = 'NONE' THEN 'PENDING'
                        ELSE public.lwb_purchase_checks.claim_status END,
    updated_at = now(), updated_by = auth.uid()
  RETURNING id INTO cid;
  DELETE FROM public.lwb_purchase_check_items WHERE check_id = cid;
  IF dmg THEN
    INSERT INTO public.lwb_purchase_check_items (check_id, sku_id, sku_name, pcs_per_case, issue, cases, pcs)
    SELECT cid, nullif(x->>'sku_id','')::uuid, x->>'sku_name', greatest(coalesce((x->>'pcs_per_case')::int,1),1),
           upper(x->>'issue'), coalesce((x->>'cases')::int,0), coalesce((x->>'pcs')::int,0)
    FROM jsonb_array_elements(p_items) x;
  END IF;
  RETURN cid;
END;
$function$;
REVOKE ALL ON FUNCTION public.lwb_save_purchase_check(uuid, date, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_save_purchase_check(uuid, date, text, jsonb) TO authenticated;

ALTER TABLE public.lwb_purchase_checks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_purchase_check_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lwb_purchase_checks_read ON public.lwb_purchase_checks;
CREATE POLICY lwb_purchase_checks_read ON public.lwb_purchase_checks FOR SELECT TO authenticated USING (public.lwb_pc_user());
DROP POLICY IF EXISTS lwb_purchase_checks_insert ON public.lwb_purchase_checks;
CREATE POLICY lwb_purchase_checks_insert ON public.lwb_purchase_checks FOR INSERT TO authenticated WITH CHECK (public.lwb_pc_user());
DROP POLICY IF EXISTS lwb_purchase_checks_update ON public.lwb_purchase_checks;
CREATE POLICY lwb_purchase_checks_update ON public.lwb_purchase_checks FOR UPDATE TO authenticated USING (public.lwb_pc_user()) WITH CHECK (public.lwb_pc_user());
DROP POLICY IF EXISTS lwb_purchase_checks_delete ON public.lwb_purchase_checks;
CREATE POLICY lwb_purchase_checks_delete ON public.lwb_purchase_checks FOR DELETE TO authenticated USING (public.lwb_pc_admin());

DROP POLICY IF EXISTS lwb_purchase_check_items_read ON public.lwb_purchase_check_items;
CREATE POLICY lwb_purchase_check_items_read ON public.lwb_purchase_check_items FOR SELECT TO authenticated USING (public.lwb_pc_user());
DROP POLICY IF EXISTS lwb_purchase_check_items_write ON public.lwb_purchase_check_items;
CREATE POLICY lwb_purchase_check_items_write ON public.lwb_purchase_check_items FOR ALL TO authenticated USING (public.lwb_pc_user()) WITH CHECK (public.lwb_pc_user());

REVOKE ALL ON TABLE public.lwb_purchase_checks FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.lwb_purchase_check_items FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.lwb_purchase_checks TO authenticated;
GRANT UPDATE (verified_on, has_damage, claim_status, claim_no, sent_on, settled_on, note, updated_at, updated_by) ON TABLE public.lwb_purchase_checks TO authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.lwb_purchase_check_items TO authenticated;

COMMIT;
