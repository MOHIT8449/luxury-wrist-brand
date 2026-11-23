-- Cash Sale party (Mohit, 23 Nov 2026)
-- Small walk-in sales (Rs 5 to Rs 500 items) all go to ONE party "CASH SALE". No ledger per buyer:
-- only the buyer's name and mobile are kept on the PO (orders.cash_buyer_name / cash_buyer_mobile).
-- No transport on a Cash Sale PO: it is saved as SELF PICKUP (buyer takes the goods), no driver popup.
-- The party details rule (mobile / address) never blocks the Cash Sale party.
-- Safe to run again.

BEGIN;

ALTER TABLE public.lwb_customer_master
  ADD COLUMN IF NOT EXISTS is_cash_sale boolean NOT NULL DEFAULT false;

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS cash_buyer_name text,
  ADD COLUMN IF NOT EXISTS cash_buyer_mobile text;

-- One Cash Sale party: an existing "CASH SALE" / "CASH SALES" row is marked, else a new one is added.
UPDATE public.lwb_customer_master
SET is_cash_sale = true, is_active = true
WHERE upper(regexp_replace(btrim(customer_name), '\s+', ' ', 'g')) IN ('CASH SALE', 'CASH SALES')
  AND NOT EXISTS (SELECT 1 FROM public.lwb_customer_master c WHERE c.is_cash_sale);

INSERT INTO public.lwb_customer_master (customer_name, gst_registration_status, billing_address, city, state, credit_days, is_active, is_cash_sale)
SELECT 'CASH SALE', 'UNREGISTERED', 'Walk-in counter sale', NULL, 'Gujarat', 0, true, true
WHERE NOT EXISTS (SELECT 1 FROM public.lwb_customer_master c WHERE c.is_cash_sale);

CREATE OR REPLACE FUNCTION public.lwb_is_cash_sale_party(p_name text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.lwb_customer_master c
    WHERE c.is_cash_sale AND upper(btrim(c.customer_name)) = upper(btrim(coalesce(p_name, ''))));
$fn$;
REVOKE ALL ON FUNCTION public.lwb_is_cash_sale_party(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_is_cash_sale_party(text) TO authenticated;

-- A new Cash Sale PO is always SELF PICKUP (no transport choice).
CREATE OR REPLACE FUNCTION public.lwb_orders_cash_sale_transport()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF public.lwb_is_cash_sale_party(NEW.customer_name) THEN
    NEW.transportation := 'SELF PICKUP';
  END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_orders_cash_sale_transport() FROM PUBLIC, anon;
DROP TRIGGER IF EXISTS trg_lwb_orders_cash_sale_transport ON public.orders;
CREATE TRIGGER trg_lwb_orders_cash_sale_transport BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.lwb_orders_cash_sale_transport();

-- Party details rule (same as lwb_party_pan_optional_location_setup.sql) + Cash Sale is never blocked.
CREATE OR REPLACE FUNCTION public.lwb_orders_party_details_guard()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  m public.lwb_customer_master%ROWTYPE;
  v_missing text[];
  v_limit integer;
BEGIN
  IF NOT public.lwb_is_sales_user() THEN RETURN NEW; END IF;
  SELECT * INTO m FROM public.lwb_customer_master
  WHERE upper(btrim(customer_name)) = upper(btrim(coalesce(NEW.customer_name,'')))
  ORDER BY is_active DESC NULLS LAST LIMIT 1 FOR UPDATE;
  IF NOT FOUND OR m.is_cash_sale THEN RETURN NEW; END IF;
  v_missing := array_remove(public.lwb_party_missing(m.mobile, m.billing_address, m.pan, m.gstin), 'PAN / GSTIN');
  IF cardinality(v_missing) = 0 THEN RETURN NEW; END IF;
  v_limit := coalesce(m.kyc_free_orders, (SELECT s.kyc_free_orders FROM public.lwb_sales_settings s WHERE s.id = 1), 3);
  IF m.kyc_orders_used >= v_limit THEN
    RAISE EXCEPTION 'Party details missing: % has no %. Fill the party details first (% orders were allowed without them).',
      m.customer_name, array_to_string(v_missing, ', '), v_limit;
  END IF;
  UPDATE public.lwb_customer_master SET kyc_orders_used = kyc_orders_used + 1 WHERE id = m.id;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_orders_party_details_guard() FROM PUBLIC, anon;

-- Buyer name + mobile on a Cash Sale PO (PO Entry calls this right after saving the PO).
CREATE OR REPLACE FUNCTION public.lwb_set_order_cash_buyer(p_order_id uuid, p_name text, p_mobile text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_o public.orders%ROWTYPE;
  v_role text;
  v_name text := upper(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'));
  v_mobile text := regexp_replace(coalesce(p_mobile, ''), '\D', '', 'g');
BEGIN
  SELECT lower(btrim(p.role)) INTO v_role FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
  IF v_role IS NULL THEN RAISE EXCEPTION 'Login is not active.'; END IF;
  IF length(v_mobile) = 12 AND left(v_mobile, 2) = '91' THEN v_mobile := substr(v_mobile, 3); END IF;
  IF length(v_mobile) = 11 AND left(v_mobile, 1) = '0' THEN v_mobile := substr(v_mobile, 2); END IF;
  IF length(v_name) < 2 THEN RAISE EXCEPTION 'Enter the buyer name.'; END IF;
  IF v_mobile !~ '^[6-9][0-9]{9}$' THEN RAISE EXCEPTION 'Mobile must be a 10-digit number.'; END IF;

  SELECT * INTO v_o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found.'; END IF;
  IF NOT public.lwb_is_cash_sale_party(v_o.customer_name) THEN RAISE EXCEPTION 'This PO is not a Cash Sale.'; END IF;
  IF NOT (v_role IN ('admin','manager') OR v_o.created_by = auth.uid()) THEN
    RAISE EXCEPTION 'Only the person who made this PO or Admin can change the buyer.';
  END IF;

  UPDATE public.orders SET cash_buyer_name = left(v_name, 80), cash_buyer_mobile = v_mobile WHERE id = v_o.id;
  RETURN jsonb_build_object('name', left(v_name, 80), 'mobile', v_mobile);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_set_order_cash_buyer(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_set_order_cash_buyer(uuid, text, text) TO authenticated;

COMMIT;
