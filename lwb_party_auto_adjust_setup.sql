-- LUXURY WRIST BRAND ERP — PAYMENT RECEIVED EARLIER IS SET AGAINST A NEW BILL BY ITSELF
--
-- Runs by itself when merged to main (after lwb_party_group_billing_setup.sql). Safe to run again.
-- Nothing is dropped or deleted.
--
-- Mohit (30 Oct 2026): AKASH TRADERS showed "due 1,34,460 · advance 1,39,460" while the real balance
-- is an advance of 5,000. A party should have ONE balance. Money a party paid before its bill was made
-- now goes against the bill as soon as Accounts saves the Tally bill amount (oldest bill first);
-- only what is left stays as advance. The screens show the one balance (to collect or advance).
-- Older parties that already have both can use "Adjust now" once.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_party_auto_adjust()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_parent text;
  v_free numeric;
BEGIN
  IF NEW.amount IS NULL OR auth.uid() IS NULL THEN RETURN NULL; END IF;
  SELECT public.lwb_party_parent(o.customer_name) INTO v_parent FROM public.orders o WHERE o.id = NEW.order_id;
  IF v_parent IS NULL OR v_parent = '' THEN RETURN NULL; END IF;
  SELECT COALESCE(sum(f.free),0) INTO v_free FROM public.lwb_party_receipt_free(v_parent) f;
  IF v_free < 0.01 THEN RETURN NULL; END IF;
  -- never block saving the bill
  BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('lwb_party|' || public.lwb_party_key(v_parent)));
    PERFORM public.lwb_party_apply(v_parent, NULL);
  EXCEPTION WHEN others THEN NULL;
  END;
  RETURN NULL;
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_party_auto_adjust() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_lwb_party_auto_adjust ON public.lwb_tally_invoices;
CREATE TRIGGER trg_lwb_party_auto_adjust AFTER INSERT OR UPDATE OF amount ON public.lwb_tally_invoices
  FOR EACH ROW EXECUTE FUNCTION public.lwb_party_auto_adjust();

COMMIT;

-- Result: true
SELECT 'auto adjust on new bill' AS item,
  EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lwb_party_auto_adjust')::text AS ok;
