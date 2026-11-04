-- LUXURY WRIST BRAND ERP — ACCOUNTS: COMPANY PAYMENT IN ONE ENTRY + BANK MATCH COUNT
--
-- Runs by itself when merged to main (after lwb_employee_master_setup.sql, lwb_company_brand_setup.sql
-- and lwb_bank_statement_setup.sql). Safe to run again. Nothing is dropped or deleted.
--
-- Mohit (4 Nov 2026): Accounts must not enter the same money twice. Paying Coca-Cola / Rajnigandha was
-- saved on Company / Brand > Pay company AND again as Cash Out on the Accounts Dashboard (the company page
-- does not post to cash / bank). Now Accounts enters it once: Cash Out > head "Supplier payment" > company.
-- lwb_acc_add_entry5 saves the money entry and the company payment together (same date, amount, mode).
-- Cancelling the money entry cancels the company payment; a linked company payment can not be cancelled
-- on the company page by itself.
--
-- Also lwb_bank_stmt_open_count(): bank statement lines still to match (suspense), for the Accounts home.

BEGIN;

ALTER TABLE public.lwb_company_payments ADD COLUMN IF NOT EXISTS acc_entry_id uuid;
CREATE UNIQUE INDEX IF NOT EXISTS lwb_company_payments_acc_uq ON public.lwb_company_payments (acc_entry_id) WHERE acc_entry_id IS NOT NULL;

-- Everything as lwb_acc_add_entry4, plus p.company_id (uuid) = this Cash Out pays that company.
CREATE OR REPLACE FUNCTION public.lwb_acc_add_entry5(p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_id uuid; v_co uuid; v_head text; v_name text; v_mode text;
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Only active Accounts or Admin can enter money'; END IF;
  BEGIN v_co := nullif(p->>'company_id','')::uuid;
  EXCEPTION WHEN others THEN RAISE EXCEPTION 'Choose the company again';
  END;
  IF v_co IS NOT NULL THEN
    IF coalesce(p->>'kind','') <> 'OUT' THEN RAISE EXCEPTION 'A company payment goes only on Cash Out'; END IF;
    BEGIN
      SELECT c.name INTO v_head FROM public.lwb_acc_categories c WHERE c.id = nullif(p->>'category_id','')::bigint;
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'Choose the head again';
    END;
    IF lower(btrim(coalesce(v_head,''))) <> 'supplier payment' THEN RAISE EXCEPTION 'A company payment needs the head Supplier payment'; END IF;
    IF nullif(p->>'staff_id','') IS NOT NULL OR nullif(p->>'vehicle_id','') IS NOT NULL THEN RAISE EXCEPTION 'Choose the company, not staff or a vehicle'; END IF;
    SELECT co.name INTO v_name FROM public.lwb_companies co WHERE co.id = v_co;
    IF v_name IS NULL THEN RAISE EXCEPTION 'Company not found'; END IF;
    IF nullif(btrim(coalesce(p->>'party','')),'') IS NULL THEN p := p || jsonb_build_object('party', v_name); END IF;
  END IF;
  v_id := public.lwb_acc_add_entry4(p);
  IF v_co IS NOT NULL THEN
    v_mode := upper(coalesce(nullif(p->>'mode',''),'CASH'));
    IF v_mode = 'RTGS' THEN v_mode := 'BANK'; END IF;
    INSERT INTO public.lwb_company_payments (company_id, pay_date, amount, mode, ref_no, note, created_by, acc_entry_id)
    SELECT v_co, e.entry_date, e.amount, v_mode, left(e.ref_no, 80),
           left(coalesce(nullif(btrim(e.remark),''), 'Accounts Dashboard Cash Out'), 300), auth.uid(), e.id
    FROM public.lwb_acc_entries e WHERE e.id = v_id;
  END IF;
  RETURN v_id;
END;
$fn$;

-- Money entry cancelled -> its company payment is cancelled too (bills show unpaid again).
CREATE OR REPLACE FUNCTION public.lwb_acc_entry_company_cancel()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NEW.cancelled_at IS NOT NULL AND OLD.cancelled_at IS NULL THEN
    UPDATE public.lwb_company_payments SET cancelled_at = now(), cancelled_by = coalesce(NEW.cancelled_by, auth.uid())
    WHERE acc_entry_id = NEW.id AND cancelled_at IS NULL;
  END IF;
  RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS lwb_acc_entry_company_cancel_trg ON public.lwb_acc_entries;
CREATE TRIGGER lwb_acc_entry_company_cancel_trg AFTER UPDATE OF cancelled_at ON public.lwb_acc_entries
  FOR EACH ROW EXECUTE FUNCTION public.lwb_acc_entry_company_cancel();

-- Same as lwb_company_brand_setup.sql, but a payment made from the Accounts Dashboard is cancelled there.
CREATE OR REPLACE FUNCTION public.lwb_company_pay_cancel(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_company_admin() THEN RAISE EXCEPTION 'Admin only'; END IF;
  IF EXISTS (SELECT 1 FROM public.lwb_company_payments p WHERE p.id = p_id AND p.acc_entry_id IS NOT NULL AND p.cancelled_at IS NULL) THEN
    RAISE EXCEPTION 'This payment was entered as Cash Out on the Accounts Dashboard. Cancel that entry there.';
  END IF;
  UPDATE public.lwb_company_payments SET cancelled_at = now(), cancelled_by = auth.uid() WHERE id = p_id AND cancelled_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found or already cancelled'; END IF;
END;
$fn$;

-- Bank statement lines not matched yet (all active banks, any date).
CREATE OR REPLACE FUNCTION public.lwb_bank_stmt_open_count()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_acc_user() THEN RAISE EXCEPTION 'Accounts or Admin only'; END IF;
  RETURN (SELECT jsonb_build_object('cnt', count(*), 'credit', coalesce(sum(s.credit),0), 'debit', coalesce(sum(s.debit),0), 'oldest', min(s.txn_date))
          FROM public.lwb_bank_stmt_lines s JOIN public.lwb_acc_banks b ON b.id = s.bank_id AND b.active
          WHERE s.status = 'OPEN');
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_acc_add_entry5(jsonb), public.lwb_bank_stmt_open_count(), public.lwb_company_pay_cancel(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.lwb_acc_entry_company_cancel() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_acc_add_entry5(jsonb), public.lwb_bank_stmt_open_count(), public.lwb_company_pay_cancel(uuid) TO authenticated;

COMMIT;
