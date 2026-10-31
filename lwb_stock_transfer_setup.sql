-- LUXURY WRIST BRAND ERP — STOCK TRANSFER, DAMAGE LEDGER, DESTROY AND NIGHT AUDIT
--
-- Applied automatically when the PR is merged (safe to run again).
--
-- 1. Stock Transfer: Saleable -> Damage / Leakage / Breakage / Gasless / Expiry / Loss.
--    Godown Manager (or Sales Head / Admin) asks; Sales Head or Admin approves.
--    Saleable stock goes down ONLY after approval.
-- 2. From those categories: Destroy (physically destroyed), Return to Company (claim),
--    or Back to Saleable (found / repacked). These need approval too.
-- 3. Category ledger: running balance per SKU of every category.
-- 4. Night Audit: Godown Manager enters the physical count per SKU, the system shows
--    the difference. A shortage stays OPEN until it is Found, or moved to Loss
--    (a Saleable -> Loss transfer that needs approval). The next night's count of the
--    same SKU replaces an older open difference (carried forward with its first date).
-- 5. Daily report: cases handled (goods inward + loaded), transfers, loss, audit result.
--
-- Stock link: the existing view public.lwb_live_stock is renamed to
-- public.lwb_live_stock_base and a new public.lwb_live_stock with the SAME columns is put
-- in front of it: saleable_pcs = base - approved transfers out of saleable (+ back to
-- saleable), damaged_pcs = base + stock now held in Damage/Leakage/Breakage/Gasless/Expiry.
-- So PO Entry, Inventory, Dashboard etc. all see the reduced saleable stock.
-- Undo (only if ever needed):  DROP VIEW public.lwb_live_stock;
--   ALTER VIEW public.lwb_live_stock_base RENAME TO lwb_live_stock;
--
-- Who: request / audit = Admin, Sales Head (manager), Godown Manager (warehouse) or a user
-- ticked for the page. Approve = Admin or Sales Head (a Sales Head cannot approve his own
-- request; Admin can). Accounts = view only. Salesman, Driver, Transport: no access.
-- Orders, bills, payments, party ledger and Tally are NOT changed.

BEGIN;

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_stx_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT lower(btrim(p.role)) FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_stx_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(public.lwb_stx_role() IN ('admin','manager','warehouse'), false)
    OR public.lwb_has_page('stock-transfer.html') OR public.lwb_has_page('stock-audit.html');
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_stx_approver()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(public.lwb_stx_role() IN ('admin','manager'), false);
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_stx_viewer()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT public.lwb_stx_user() OR coalesce(public.lwb_stx_role() = 'accounts', false);
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_stx_today()
RETURNS date LANGUAGE sql STABLE SET search_path = ''
AS $fn$ SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date; $fn$;

REVOKE ALL ON FUNCTION public.lwb_stx_role(), public.lwb_stx_user(), public.lwb_stx_approver(),
  public.lwb_stx_viewer(), public.lwb_stx_today() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_stx_role(), public.lwb_stx_user(), public.lwb_stx_approver(),
  public.lwb_stx_viewer(), public.lwb_stx_today() TO authenticated;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
-- One row = one SKU line of a request. Lines saved together share batch_id.
CREATE TABLE IF NOT EXISTS public.lwb_stock_moves (
  id bigserial PRIMARY KEY,
  batch_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN ('TRANSFER','DESTROY','COMPANY_RETURN','TO_SALEABLE')),
  from_bucket text NOT NULL,
  to_bucket text NOT NULL,
  sku_id uuid NOT NULL,
  sku_name text NOT NULL,
  pcs_per_case integer NOT NULL CHECK (pcs_per_case > 0),
  qty_pcs integer NOT NULL CHECK (qty_pcs > 0),
  requested_pcs integer NOT NULL CHECK (requested_pcs > 0),
  move_date date NOT NULL,
  reason text NOT NULL,
  note text,
  batch_no text,
  expiry_date date,
  witness text,
  method text,
  photo_path text,
  source text NOT NULL DEFAULT 'MANUAL' CHECK (source IN ('MANUAL','AUDIT')),
  audit_line_id bigint,
  status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED','CANCELLED')),
  requested_by uuid NOT NULL DEFAULT auth.uid(),
  requested_at timestamptz NOT NULL DEFAULT now(),
  decided_by uuid,
  decided_at timestamptz,
  decision_note text,
  CHECK (from_bucket IN ('SALEABLE','DAMAGE','LEAKAGE','BREAKAGE','GASLESS','EXPIRY','LOSS')),
  CHECK (to_bucket IN ('SALEABLE','DAMAGE','LEAKAGE','BREAKAGE','GASLESS','EXPIRY','LOSS','DESTROYED','COMPANY_RETURN')),
  CHECK (from_bucket <> to_bucket)
);
CREATE INDEX IF NOT EXISTS lwb_stock_moves_status_idx ON public.lwb_stock_moves(status, sku_id);
CREATE INDEX IF NOT EXISTS lwb_stock_moves_date_idx ON public.lwb_stock_moves(move_date);
CREATE INDEX IF NOT EXISTS lwb_stock_moves_batch_idx ON public.lwb_stock_moves(batch_id);

CREATE TABLE IF NOT EXISTS public.lwb_stock_audits (
  id bigserial PRIMARY KEY,
  audit_date date NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','SUBMITTED')),
  note text,
  created_by uuid NOT NULL DEFAULT auth.uid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  submitted_by uuid,
  submitted_at timestamptz
);

-- diff_pcs = physical - (system - pending loss). Minus = short, plus = excess.
CREATE TABLE IF NOT EXISTS public.lwb_stock_audit_lines (
  id bigserial PRIMARY KEY,
  audit_id bigint NOT NULL REFERENCES public.lwb_stock_audits(id),
  sku_id uuid NOT NULL,
  sku_name text NOT NULL,
  pcs_per_case integer NOT NULL CHECK (pcs_per_case > 0),
  physical_pcs integer NOT NULL CHECK (physical_pcs >= 0),
  system_pcs integer,
  pending_pcs integer NOT NULL DEFAULT 0,
  diff_pcs integer,
  open_since date,
  status text NOT NULL DEFAULT 'DRAFT'
    CHECK (status IN ('DRAFT','MATCH','OPEN','FOUND','RECOUNTED','LOSS_PENDING','LOSS','EXCESS_OK')),
  line_note text,
  resolve_note text,
  resolved_by uuid,
  resolved_at timestamptz,
  move_id bigint,
  UNIQUE (audit_id, sku_id)
);
CREATE INDEX IF NOT EXISTS lwb_stock_audit_lines_open_idx ON public.lwb_stock_audit_lines(sku_id, status);

-- No direct access: everything goes through the functions below.
ALTER TABLE public.lwb_stock_moves ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_stock_audits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_stock_audit_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_stock_moves, public.lwb_stock_audits, public.lwb_stock_audit_lines FROM PUBLIC, anon, authenticated;
REVOKE ALL ON SEQUENCE public.lwb_stock_moves_id_seq, public.lwb_stock_audits_id_seq, public.lwb_stock_audit_lines_id_seq FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Balances
-- ---------------------------------------------------------------------------
-- Approved balance and pending-out per SKU per bucket (internal).
CREATE OR REPLACE FUNCTION public.lwb_stx_bal()
RETURNS TABLE(sku_id uuid, bucket text, pcs bigint, pending_out bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT x.sku_id, x.bucket, coalesce(sum(x.pcs) FILTER (WHERE x.st = 'APPROVED'), 0)::bigint,
         coalesce(sum(-x.pcs) FILTER (WHERE x.st = 'PENDING' AND x.pcs < 0), 0)::bigint
  FROM (
    SELECT m.sku_id, m.to_bucket AS bucket, m.qty_pcs::bigint AS pcs, m.status AS st FROM public.lwb_stock_moves m WHERE m.status IN ('APPROVED','PENDING')
    UNION ALL
    SELECT m.sku_id, m.from_bucket, -m.qty_pcs::bigint, m.status FROM public.lwb_stock_moves m WHERE m.status IN ('APPROVED','PENDING')
  ) x
  GROUP BY 1, 2;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_stx_bal() FROM PUBLIC, anon, authenticated;

-- What the lwb_live_stock wrapper adds per SKU. Only numbers, readable by any login
-- that can already read lwb_live_stock.
CREATE OR REPLACE FUNCTION public.lwb_stx_adjust()
RETURNS TABLE(sku_id uuid, saleable_adj bigint, held_pcs bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT b.sku_id,
         coalesce(sum(b.pcs) FILTER (WHERE b.bucket = 'SALEABLE'), 0)::bigint,
         coalesce(sum(b.pcs) FILTER (WHERE b.bucket IN ('DAMAGE','LEAKAGE','BREAKAGE','GASLESS','EXPIRY')), 0)::bigint
  FROM public.lwb_stx_bal() b GROUP BY b.sku_id;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_stx_adjust() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_stx_adjust() TO authenticated;

-- Godown stock before transfers (base view), per SKU (internal).
CREATE OR REPLACE FUNCTION public.lwb_stx_base()
RETURNS TABLE(sku_id uuid, saleable_pcs numeric, damaged_pcs numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_src text := CASE WHEN to_regclass('public.lwb_live_stock_base') IS NOT NULL THEN 'public.lwb_live_stock_base'
                           WHEN to_regclass('public.lwb_live_stock') IS NOT NULL THEN 'public.lwb_live_stock' END;
BEGIN
  IF v_src IS NULL THEN RETURN; END IF;
  RETURN QUERY EXECUTE 'SELECT s.sku_id::uuid, coalesce(sum(s.saleable_pcs),0)::numeric, coalesce(sum(s.damaged_pcs),0)::numeric FROM '
    || v_src || ' s WHERE s.sku_id IS NOT NULL GROUP BY 1';
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_stx_base() FROM PUBLIC, anon, authenticated;

-- Saleable now (after approved transfers) for one SKU.
CREATE OR REPLACE FUNCTION public.lwb_stx_saleable(p_sku uuid)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT (coalesce((SELECT floor(b.saleable_pcs) FROM public.lwb_stx_base() b WHERE b.sku_id = p_sku), 0)
        + coalesce((SELECT a.saleable_adj FROM public.lwb_stx_adjust() a WHERE a.sku_id = p_sku), 0))::bigint;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_stx_saleable(uuid) FROM PUBLIC, anon, authenticated;

-- Pending loss already asked from audit differences of this SKU (internal).
CREATE OR REPLACE FUNCTION public.lwb_stx_audit_pending(p_sku uuid)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT coalesce(sum(m.qty_pcs), 0)::bigint FROM public.lwb_stock_moves m
  WHERE m.sku_id = p_sku AND m.status = 'PENDING' AND m.from_bucket = 'SALEABLE' AND m.source = 'AUDIT';
$fn$;
REVOKE ALL ON FUNCTION public.lwb_stx_audit_pending(uuid) FROM PUBLIC, anon, authenticated;

-- Stock status per SKU: saleable now and every category (pieces).
CREATE OR REPLACE FUNCTION public.lwb_stx_status()
RETURNS TABLE(sku_id uuid, sku_name text, pcs_per_case integer, saleable_pcs bigint, pending_out_pcs bigint,
  damage_pcs bigint, leakage_pcs bigint, breakage_pcs bigint, gasless_pcs bigint, expiry_pcs bigint, loss_pcs bigint,
  destroyed_pcs bigint, company_return_pcs bigint, old_damaged_pcs bigint, open_short_pcs bigint, open_excess_pcs bigint,
  open_since date, linked boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_linked boolean := to_regclass('public.lwb_live_stock_base') IS NOT NULL;
BEGIN
  IF NOT public.lwb_stx_viewer() THEN RAISE EXCEPTION 'Stock transfer: Admin, Sales Head, Godown Manager or Accounts only'; END IF;
  RETURN QUERY
  WITH bal AS (SELECT * FROM public.lwb_stx_bal()),
  base AS (SELECT * FROM public.lwb_stx_base()),
  od AS (SELECT l.sku_id, sum(l.diff_pcs) FILTER (WHERE l.diff_pcs < 0) AS short, sum(l.diff_pcs) FILTER (WHERE l.diff_pcs > 0) AS excess, min(l.open_since) AS since
         FROM public.lwb_stock_audit_lines l WHERE l.status = 'OPEN' GROUP BY 1),
  ids AS (SELECT s.id FROM public.sku_master s WHERE coalesce(s.is_active, true)
          UNION SELECT b.sku_id FROM bal b UNION SELECT od.sku_id FROM od)
  SELECT s.id, s.sku_name::text, greatest(coalesce(s.pcs_per_case,1),1)::integer,
    (coalesce(floor(base.saleable_pcs),0) + coalesce((SELECT b.pcs FROM bal b WHERE b.sku_id = s.id AND b.bucket = 'SALEABLE'),0))::bigint,
    coalesce((SELECT sum(b.pending_out) FROM bal b WHERE b.sku_id = s.id),0)::bigint,
    coalesce((SELECT b.pcs FROM bal b WHERE b.sku_id = s.id AND b.bucket = 'DAMAGE'),0)::bigint,
    coalesce((SELECT b.pcs FROM bal b WHERE b.sku_id = s.id AND b.bucket = 'LEAKAGE'),0)::bigint,
    coalesce((SELECT b.pcs FROM bal b WHERE b.sku_id = s.id AND b.bucket = 'BREAKAGE'),0)::bigint,
    coalesce((SELECT b.pcs FROM bal b WHERE b.sku_id = s.id AND b.bucket = 'GASLESS'),0)::bigint,
    coalesce((SELECT b.pcs FROM bal b WHERE b.sku_id = s.id AND b.bucket = 'EXPIRY'),0)::bigint,
    coalesce((SELECT b.pcs FROM bal b WHERE b.sku_id = s.id AND b.bucket = 'LOSS'),0)::bigint,
    coalesce((SELECT b.pcs FROM bal b WHERE b.sku_id = s.id AND b.bucket = 'DESTROYED'),0)::bigint,
    coalesce((SELECT b.pcs FROM bal b WHERE b.sku_id = s.id AND b.bucket = 'COMPANY_RETURN'),0)::bigint,
    coalesce(floor(base.damaged_pcs),0)::bigint,
    coalesce(-od.short,0)::bigint, coalesce(od.excess,0)::bigint, od.since, v_linked
  FROM ids JOIN public.sku_master s ON s.id = ids.id
  LEFT JOIN base ON base.sku_id = s.id
  LEFT JOIN od ON od.sku_id = s.id
  ORDER BY s.sku_name;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Bells
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_stx_bell(p_roles text[], p_user uuid, p_title text, p_msg text, p_type text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
  SELECT p.id, p_title, left(p_msg, 600), p_type FROM public.user_profiles p
  WHERE p.active = true AND p.id IS DISTINCT FROM auth.uid()
    AND ((p_user IS NOT NULL AND p.id = p_user) OR (p_roles IS NOT NULL AND lower(btrim(p.role)) = ANY (p_roles)));
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_stx_bell(text[],uuid,text,text,text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_stx_label(p_bucket text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = ''
AS $fn$
  SELECT CASE p_bucket WHEN 'COMPANY_RETURN' THEN 'Return to company' WHEN 'DESTROYED' THEN 'Destroyed'
    ELSE initcap(lower(p_bucket)) END;
$fn$;
GRANT EXECUTE ON FUNCTION public.lwb_stx_label(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- Request
-- p: {from_bucket, to_bucket, move_date, reason, note, witness, method, photo_path,
--     lines: [{sku_id, cases, pcs, batch_no, expiry_date}]}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_stx_request(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_from text := upper(btrim(coalesce(p->>'from_bucket','')));
  v_to text := upper(btrim(coalesce(p->>'to_bucket','')));
  v_kind text;
  v_reason text := left(nullif(btrim(coalesce(p->>'reason','')),''), 300);
  v_date date;
  v_batch uuid := gen_random_uuid();
  v_held constant text[] := ARRAY['DAMAGE','LEAKAGE','BREAKAGE','GASLESS','EXPIRY'];
  e jsonb; s record; v_qty bigint; v_avail bigint; v_ids bigint[] := '{}'; v_id bigint; v_total bigint := 0;
  v_seen uuid[] := '{}'; v_by text;
BEGIN
  IF NOT public.lwb_stx_user() THEN RAISE EXCEPTION 'Only Godown Manager, Sales Head or Admin can move stock'; END IF;
  v_kind := CASE
    WHEN v_from = 'SALEABLE' AND v_to = ANY (v_held || 'LOSS'::text) THEN 'TRANSFER'
    WHEN v_from = ANY (v_held) AND v_to = 'DESTROYED' THEN 'DESTROY'
    WHEN v_from = ANY (v_held) AND v_to = 'COMPANY_RETURN' THEN 'COMPANY_RETURN'
    WHEN v_from = ANY (v_held || 'LOSS'::text) AND v_to = 'SALEABLE' THEN 'TO_SALEABLE' END;
  IF v_kind IS NULL THEN RAISE EXCEPTION 'This stock move is not allowed: % to %', v_from, v_to; END IF;
  IF v_reason IS NULL THEN RAISE EXCEPTION 'Enter the reason'; END IF;
  v_date := coalesce(nullif(p->>'move_date','')::date, public.lwb_stx_today());
  IF v_date > public.lwb_stx_today() OR v_date < public.lwb_stx_today() - 31 THEN RAISE EXCEPTION 'Date must be within the last 31 days'; END IF;
  IF v_kind = 'DESTROY' AND nullif(btrim(coalesce(p->>'witness','')),'') IS NULL THEN RAISE EXCEPTION 'Enter who witnessed the destroy'; END IF;
  IF jsonb_typeof(p->'lines') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'lines') = 0 THEN RAISE EXCEPTION 'Add at least one SKU'; END IF;
  IF jsonb_array_length(p->'lines') > 100 THEN RAISE EXCEPTION 'At most 100 SKUs at once'; END IF;

  FOR e IN SELECT v FROM jsonb_array_elements(p->'lines') AS t(v) LOOP
    SELECT m.id, m.sku_name, greatest(coalesce(m.pcs_per_case,1),1) AS ppc INTO s
    FROM public.sku_master m WHERE m.id::text = coalesce(e->>'sku_id','');
    IF s.id IS NULL THEN RAISE EXCEPTION 'Select the SKU from SKU Master'; END IF;
    IF s.id = ANY (v_seen) THEN RAISE EXCEPTION '% is on two lines. Put it on one line.', s.sku_name; END IF;
    v_seen := v_seen || s.id;
    IF coalesce(e->>'cases','0') !~ '^\d{1,6}$' OR coalesce(e->>'pcs','0') !~ '^\d{1,6}$' THEN RAISE EXCEPTION 'Enter whole cases / pieces for %', s.sku_name; END IF;
    v_qty := coalesce(nullif(e->>'cases','')::bigint,0) * s.ppc + coalesce(nullif(e->>'pcs','')::bigint,0);
    IF v_qty <= 0 THEN RAISE EXCEPTION 'Enter the quantity for %', s.sku_name; END IF;
    PERFORM pg_advisory_xact_lock(hashtext('lwb_stx:' || s.id::text));
    IF v_from = 'SALEABLE' THEN
      v_avail := public.lwb_stx_saleable(s.id);
    ELSE
      v_avail := coalesce((SELECT b.pcs FROM public.lwb_stx_bal() b WHERE b.sku_id = s.id AND b.bucket = v_from), 0);
    END IF;
    v_avail := v_avail - coalesce((SELECT b.pending_out FROM public.lwb_stx_bal() b WHERE b.sku_id = s.id AND b.bucket = v_from), 0);
    IF v_qty > v_avail THEN
      RAISE EXCEPTION '% has only % CS % PCS in % (after requests waiting for approval). Asked: % CS % PCS.',
        s.sku_name, greatest(v_avail,0) / s.ppc, greatest(v_avail,0) % s.ppc, public.lwb_stx_label(v_from), v_qty / s.ppc, v_qty % s.ppc;
    END IF;
    INSERT INTO public.lwb_stock_moves(batch_id, kind, from_bucket, to_bucket, sku_id, sku_name, pcs_per_case, qty_pcs, requested_pcs,
      move_date, reason, note, batch_no, expiry_date, witness, method, photo_path, requested_by)
    VALUES (v_batch, v_kind, v_from, v_to, s.id, s.sku_name, s.ppc, v_qty, v_qty, v_date, v_reason,
      left(nullif(btrim(coalesce(p->>'note','')),''), 500), left(nullif(btrim(coalesce(e->>'batch_no','')),''), 40),
      nullif(e->>'expiry_date','')::date, left(nullif(btrim(coalesce(p->>'witness','')),''), 120),
      left(nullif(btrim(coalesce(p->>'method','')),''), 120), left(nullif(btrim(coalesce(p->>'photo_path','')),''), 300), auth.uid())
    RETURNING id INTO v_id;
    v_ids := v_ids || v_id; v_total := v_total + v_qty;
  END LOOP;

  SELECT coalesce(nullif(btrim(u.full_name),''), 'Godown') INTO v_by FROM public.user_profiles u WHERE u.id = auth.uid();
  PERFORM public.lwb_stx_bell(ARRAY['admin','manager'], NULL,
    'Approve stock move: ' || public.lwb_stx_label(v_from) || ' → ' || public.lwb_stx_label(v_to),
    'STM-' || v_ids[1] || ' · ' || array_length(v_ids,1) || ' SKU' || CASE WHEN array_length(v_ids,1) > 1 THEN 's' ELSE '' END
      || ' · ' || v_reason || ' · by ' || coalesce(v_by,'Godown') || '.', 'STOCK_MOVE_PENDING');
  RETURN jsonb_build_object('batch_id', v_batch, 'ids', to_jsonb(v_ids), 'kind', v_kind);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Approve / reject (Admin or Sales Head). p_qty: {"<id>": pcs} to approve less.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_stx_decide(p_ids bigint[], p_action text, p_note text, p_qty jsonb DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_act text := upper(btrim(coalesce(p_action,'')));
  v_note text := left(nullif(btrim(coalesce(p_note,'')),''), 300);
  v_admin boolean := public.lwb_stx_role() = 'admin';
  m public.lwb_stock_moves%ROWTYPE; v_qty bigint; v_avail bigint; v_n integer := 0; v_who uuid; v_first bigint;
BEGIN
  IF NOT public.lwb_stx_approver() THEN RAISE EXCEPTION 'Only Sales Head or Admin can approve stock moves'; END IF;
  IF v_act NOT IN ('APPROVE','REJECT') THEN RAISE EXCEPTION 'Invalid action'; END IF;
  IF v_act = 'REJECT' AND v_note IS NULL THEN RAISE EXCEPTION 'Enter the reason for rejecting'; END IF;
  FOR m IN SELECT * FROM public.lwb_stock_moves x WHERE x.id = ANY (p_ids) ORDER BY x.id FOR UPDATE LOOP
    IF m.status <> 'PENDING' THEN RAISE EXCEPTION 'STM-% is already %', m.id, lower(m.status); END IF;
    IF m.requested_by = auth.uid() AND NOT v_admin THEN RAISE EXCEPTION 'STM-%: you asked for this move. Admin or another Sales Head must approve it.', m.id; END IF;
    IF v_act = 'APPROVE' THEN
      v_qty := coalesce(nullif(p_qty->>(m.id::text),'')::bigint, m.qty_pcs);
      IF v_qty <= 0 OR v_qty > m.qty_pcs THEN RAISE EXCEPTION 'STM-%: approve between 1 and % pieces', m.id, m.qty_pcs; END IF;
      PERFORM pg_advisory_xact_lock(hashtext('lwb_stx:' || m.sku_id::text));
      IF m.from_bucket = 'SALEABLE' THEN v_avail := public.lwb_stx_saleable(m.sku_id);
      ELSE v_avail := coalesce((SELECT b.pcs FROM public.lwb_stx_bal() b WHERE b.sku_id = m.sku_id AND b.bucket = m.from_bucket), 0);
      END IF;
      IF v_qty > v_avail THEN
        RAISE EXCEPTION 'STM-% %: only % CS % PCS left in %. Reject it or approve less.', m.id, m.sku_name,
          greatest(v_avail,0) / m.pcs_per_case, greatest(v_avail,0) % m.pcs_per_case, public.lwb_stx_label(m.from_bucket);
      END IF;
      UPDATE public.lwb_stock_moves SET status = 'APPROVED', qty_pcs = v_qty, decided_by = auth.uid(), decided_at = now(),
        decision_note = coalesce(v_note, CASE WHEN v_qty < m.requested_pcs THEN 'Approved less than asked' END)
      WHERE id = m.id;
      IF m.audit_line_id IS NOT NULL THEN
        UPDATE public.lwb_stock_audit_lines SET status = 'LOSS', resolved_by = auth.uid(), resolved_at = now() WHERE id = m.audit_line_id;
      END IF;
    ELSE
      UPDATE public.lwb_stock_moves SET status = 'REJECTED', decided_by = auth.uid(), decided_at = now(), decision_note = v_note WHERE id = m.id;
      IF m.audit_line_id IS NOT NULL THEN
        UPDATE public.lwb_stock_audit_lines SET status = 'OPEN', move_id = NULL WHERE id = m.audit_line_id AND status = 'LOSS_PENDING';
      END IF;
    END IF;
    v_n := v_n + 1; v_who := m.requested_by; v_first := coalesce(v_first, m.id);
    IF m.requested_by IS DISTINCT FROM auth.uid() THEN
      PERFORM public.lwb_stx_bell(NULL, m.requested_by,
        CASE WHEN v_act = 'APPROVE' THEN 'Stock move approved' ELSE 'Stock move rejected' END,
        'STM-' || m.id || ' · ' || m.sku_name || ' · ' || public.lwb_stx_label(m.from_bucket) || ' → ' || public.lwb_stx_label(m.to_bucket)
          || ' · ' || (CASE WHEN v_act = 'APPROVE' THEN v_qty ELSE m.qty_pcs END) / m.pcs_per_case || ' CS '
          || (CASE WHEN v_act = 'APPROVE' THEN v_qty ELSE m.qty_pcs END) % m.pcs_per_case || ' PCS' || coalesce(' · ' || v_note, '') || '.',
        CASE WHEN v_act = 'APPROVE' THEN 'STOCK_MOVE_APPROVED' ELSE 'STOCK_MOVE_REJECTED' END);
    END IF;
  END LOOP;
  IF v_n = 0 THEN RAISE EXCEPTION 'Nothing to approve'; END IF;
  RETURN v_n;
END;
$fn$;

-- Requester (or approver) cancels a request still waiting.
CREATE OR REPLACE FUNCTION public.lwb_stx_cancel(p_ids bigint[])
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_n integer;
BEGIN
  IF NOT public.lwb_stx_user() THEN RAISE EXCEPTION 'Not allowed'; END IF;
  UPDATE public.lwb_stock_audit_lines l SET status = 'OPEN', move_id = NULL
  FROM public.lwb_stock_moves m
  WHERE m.id = ANY (p_ids) AND m.status = 'PENDING' AND m.audit_line_id = l.id AND l.status = 'LOSS_PENDING'
    AND (m.requested_by = auth.uid() OR public.lwb_stx_approver());
  UPDATE public.lwb_stock_moves SET status = 'CANCELLED', decided_by = auth.uid(), decided_at = now()
  WHERE id = ANY (p_ids) AND status = 'PENDING' AND (requested_by = auth.uid() OR public.lwb_stx_approver());
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RAISE EXCEPTION 'Only your own waiting request can be cancelled'; END IF;
  RETURN v_n;
END;
$fn$;

-- List of moves. p_status NULL = all. Pending ones are always listed whatever the dates.
CREATE OR REPLACE FUNCTION public.lwb_stx_moves(p_status text, p_from date, p_to date)
RETURNS TABLE(id bigint, batch_id uuid, kind text, from_bucket text, to_bucket text, sku_id uuid, sku_name text, pcs_per_case integer,
  qty_pcs integer, requested_pcs integer, move_date date, reason text, note text, batch_no text, expiry_date date, witness text, method text,
  photo_path text, source text, audit_line_id bigint, status text, requested_by uuid, requested_by_name text, requested_at timestamptz,
  decided_by_name text, decided_at timestamptz, decision_note text, can_decide boolean, can_cancel boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_appr boolean := public.lwb_stx_approver(); v_admin boolean := public.lwb_stx_role() = 'admin';
BEGIN
  IF NOT public.lwb_stx_viewer() THEN RAISE EXCEPTION 'Stock transfer: Admin, Sales Head, Godown Manager or Accounts only'; END IF;
  RETURN QUERY
  SELECT m.id, m.batch_id, m.kind, m.from_bucket, m.to_bucket, m.sku_id, m.sku_name, m.pcs_per_case, m.qty_pcs, m.requested_pcs,
    m.move_date, m.reason, m.note, m.batch_no, m.expiry_date, m.witness, m.method, m.photo_path, m.source, m.audit_line_id, m.status,
    m.requested_by, coalesce(nullif(btrim(r.full_name),''), 'User')::text, m.requested_at,
    d.full_name::text, m.decided_at, m.decision_note,
    (m.status = 'PENDING' AND v_appr AND (m.requested_by IS DISTINCT FROM auth.uid() OR v_admin)),
    (m.status = 'PENDING' AND (m.requested_by = auth.uid() OR v_appr))
  FROM public.lwb_stock_moves m
  LEFT JOIN public.user_profiles r ON r.id = m.requested_by
  LEFT JOIN public.user_profiles d ON d.id = m.decided_by
  WHERE (p_status IS NULL OR m.status = upper(p_status))
    AND (m.status = 'PENDING' OR p_from IS NULL OR m.move_date >= p_from)
    AND (m.status = 'PENDING' OR p_to IS NULL OR m.move_date <= p_to)
  ORDER BY (m.status = 'PENDING') DESC, m.move_date DESC, m.id DESC
  LIMIT 2000;
END;
$fn$;

-- Category ledger with running balance. Opening row (move_id NULL) = balance before p_from.
CREATE OR REPLACE FUNCTION public.lwb_stx_ledger(p_bucket text, p_from date, p_to date, p_sku uuid DEFAULT NULL)
RETURNS TABLE(sku_id uuid, sku_name text, pcs_per_case integer, move_id bigint, move_date date, kind text, other_bucket text,
  in_pcs bigint, out_pcs bigint, balance_pcs bigint, reason text, requested_by_name text, approved_by_name text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_b text := upper(btrim(coalesce(p_bucket,'')));
BEGIN
  IF NOT public.lwb_stx_viewer() THEN RAISE EXCEPTION 'Stock transfer: Admin, Sales Head, Godown Manager or Accounts only'; END IF;
  IF v_b NOT IN ('SALEABLE','DAMAGE','LEAKAGE','BREAKAGE','GASLESS','EXPIRY','LOSS','DESTROYED','COMPANY_RETURN') THEN RAISE EXCEPTION 'Choose a category'; END IF;
  RETURN QUERY
  WITH mv AS (
    SELECT m.*, CASE WHEN m.to_bucket = v_b THEN m.qty_pcs ELSE 0 END::bigint AS i, CASE WHEN m.from_bucket = v_b THEN m.qty_pcs ELSE 0 END::bigint AS o,
      CASE WHEN m.to_bucket = v_b THEN m.from_bucket ELSE m.to_bucket END AS other
    FROM public.lwb_stock_moves m
    WHERE m.status = 'APPROVED' AND v_b IN (m.from_bucket, m.to_bucket) AND (p_sku IS NULL OR m.sku_id = p_sku)
      AND (p_to IS NULL OR m.move_date <= p_to)
  ),
  op AS (SELECT mv.sku_id, max(mv.sku_name) AS sku_name, max(mv.pcs_per_case) AS ppc, sum(mv.i - mv.o)::bigint AS bal
         FROM mv WHERE p_from IS NOT NULL AND mv.move_date < p_from GROUP BY mv.sku_id),
  rw AS (
    SELECT op.sku_id, op.sku_name, op.ppc, NULL::bigint AS id, (p_from - 1) AS d, 'OPENING'::text AS kind, NULL::text AS other,
      op.bal AS i, 0::bigint AS o, NULL::timestamptz AS at, NULL::text AS reason, NULL::uuid AS rb, NULL::uuid AS db
    FROM op WHERE op.bal <> 0
    UNION ALL
    SELECT mv.sku_id, mv.sku_name, mv.pcs_per_case, mv.id, mv.move_date, mv.kind, mv.other, mv.i, mv.o, mv.decided_at, mv.reason, mv.requested_by, mv.decided_by
    FROM mv WHERE p_from IS NULL OR mv.move_date >= p_from
  )
  SELECT r.sku_id, r.sku_name, r.ppc, r.id, r.d, r.kind, r.other, r.i, r.o,
    (sum(r.i - r.o) OVER (PARTITION BY r.sku_id ORDER BY r.d, r.at NULLS FIRST, r.id NULLS FIRST))::bigint,
    r.reason, u1.full_name::text, u2.full_name::text
  FROM rw r
  LEFT JOIN public.user_profiles u1 ON u1.id = r.rb
  LEFT JOIN public.user_profiles u2 ON u2.id = r.db
  ORDER BY r.sku_name, r.d, r.at NULLS FIRST, r.id NULLS FIRST;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Night audit
-- ---------------------------------------------------------------------------
-- Count sheet for a date: every active SKU with system saleable now, open difference and
-- the count already saved in a draft (or submitted).
CREATE OR REPLACE FUNCTION public.lwb_stx_audit_sheet(p_date date)
RETURNS TABLE(audit_id bigint, audit_status text, sku_id uuid, sku_name text, pcs_per_case integer, system_pcs bigint, pending_pcs bigint,
  open_diff_pcs bigint, open_since date, physical_pcs integer, diff_pcs integer, line_status text, line_note text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE a public.lwb_stock_audits%ROWTYPE;
BEGIN
  IF NOT public.lwb_stx_viewer() THEN RAISE EXCEPTION 'Night audit: Admin, Sales Head, Godown Manager or Accounts only'; END IF;
  SELECT * INTO a FROM public.lwb_stock_audits x WHERE x.audit_date = coalesce(p_date, public.lwb_stx_today());
  RETURN QUERY
  SELECT a.id, a.status, s.id, s.sku_name::text, greatest(coalesce(s.pcs_per_case,1),1)::integer,
    CASE WHEN a.status = 'SUBMITTED' THEN l.system_pcs::bigint ELSE public.lwb_stx_saleable(s.id) END,
    CASE WHEN a.status = 'SUBMITTED' THEN l.pending_pcs::bigint ELSE public.lwb_stx_audit_pending(s.id) END,
    coalesce((SELECT sum(o.diff_pcs) FROM public.lwb_stock_audit_lines o WHERE o.sku_id = s.id AND o.status = 'OPEN' AND o.audit_id IS DISTINCT FROM a.id),0)::bigint,
    (SELECT min(o.open_since) FROM public.lwb_stock_audit_lines o WHERE o.sku_id = s.id AND o.status = 'OPEN' AND o.audit_id IS DISTINCT FROM a.id),
    l.physical_pcs, l.diff_pcs, l.status, l.line_note
  FROM public.sku_master s
  LEFT JOIN public.lwb_stock_audit_lines l ON l.audit_id = a.id AND l.sku_id = s.id
  WHERE coalesce(s.is_active, true) OR l.id IS NOT NULL
  ORDER BY s.sku_name;
END;
$fn$;

-- Save the count. p_lines: [{sku_id, physical_pcs, note}] (physical_pcs null = not counted).
-- p_submit = true locks the audit: system stock is taken at that moment and differences open.
CREATE OR REPLACE FUNCTION public.lwb_stx_audit_save(p_date date, p_lines jsonb, p_submit boolean, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_date date := coalesce(p_date, public.lwb_stx_today());
  a public.lwb_stock_audits%ROWTYPE; e jsonb; s record; l public.lwb_stock_audit_lines%ROWTYPE;
  v_sys bigint; v_pend bigint; v_diff bigint; v_since date; v_short bigint := 0; v_excess bigint := 0; v_skus integer := 0; v_bad integer := 0; v_by text;
BEGIN
  IF NOT public.lwb_stx_user() THEN RAISE EXCEPTION 'Only Godown Manager, Sales Head or Admin can enter the audit'; END IF;
  IF v_date > public.lwb_stx_today() OR v_date < public.lwb_stx_today() - 3 THEN RAISE EXCEPTION 'Audit date must be today or the last 3 days'; END IF;
  IF jsonb_typeof(coalesce(p_lines,'[]')) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'Invalid count sheet'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('lwb_stx_audit'));
  SELECT * INTO a FROM public.lwb_stock_audits x WHERE x.audit_date = v_date FOR UPDATE;
  IF a.id IS NULL THEN
    INSERT INTO public.lwb_stock_audits(audit_date, note, created_by) VALUES (v_date, left(nullif(btrim(coalesce(p_note,'')),''),500), auth.uid()) RETURNING * INTO a;
  ELSIF a.status = 'SUBMITTED' THEN
    RAISE EXCEPTION 'The audit of % is already submitted', to_char(v_date,'DD-Mon-YYYY');
  ELSE
    UPDATE public.lwb_stock_audits SET note = left(nullif(btrim(coalesce(p_note,'')),''),500), updated_at = now() WHERE id = a.id;
  END IF;

  FOR e IN SELECT v FROM jsonb_array_elements(coalesce(p_lines,'[]')) AS t(v) LOOP
    SELECT m.id, m.sku_name, greatest(coalesce(m.pcs_per_case,1),1) AS ppc INTO s FROM public.sku_master m WHERE m.id::text = coalesce(e->>'sku_id','');
    IF s.id IS NULL THEN RAISE EXCEPTION 'Unknown SKU in the count sheet'; END IF;
    IF nullif(e->>'physical_pcs','') IS NULL THEN
      DELETE FROM public.lwb_stock_audit_lines WHERE audit_id = a.id AND sku_id = s.id;
      CONTINUE;
    END IF;
    IF (e->>'physical_pcs') !~ '^\d{1,9}$' THEN RAISE EXCEPTION 'Enter a whole count for %', s.sku_name; END IF;
    INSERT INTO public.lwb_stock_audit_lines(audit_id, sku_id, sku_name, pcs_per_case, physical_pcs, line_note)
    VALUES (a.id, s.id, s.sku_name, s.ppc, (e->>'physical_pcs')::integer, left(nullif(btrim(coalesce(e->>'note','')),''),200))
    ON CONFLICT (audit_id, sku_id) DO UPDATE SET physical_pcs = excluded.physical_pcs, line_note = excluded.line_note, pcs_per_case = excluded.pcs_per_case;
  END LOOP;

  IF coalesce(p_submit, false) THEN
    IF NOT EXISTS (SELECT 1 FROM public.lwb_stock_audit_lines x WHERE x.audit_id = a.id) THEN RAISE EXCEPTION 'Count at least one SKU before submitting'; END IF;
    FOR l IN SELECT * FROM public.lwb_stock_audit_lines x WHERE x.audit_id = a.id ORDER BY x.sku_name FOR UPDATE LOOP
      v_sys := public.lwb_stx_saleable(l.sku_id);
      v_pend := public.lwb_stx_audit_pending(l.sku_id);
      v_diff := l.physical_pcs - (v_sys - v_pend);
      -- An older open difference of this SKU: the new count replaces it.
      SELECT min(o.open_since) INTO v_since FROM public.lwb_stock_audit_lines o
      WHERE o.sku_id = l.sku_id AND o.status = 'OPEN' AND o.audit_id <> a.id AND sign(o.diff_pcs) = sign(v_diff);
      UPDATE public.lwb_stock_audit_lines o
      SET status = CASE WHEN v_diff = 0 THEN 'FOUND' ELSE 'RECOUNTED' END, resolved_by = auth.uid(), resolved_at = now(),
          resolve_note = CASE WHEN v_diff = 0 THEN 'Matched in audit of ' ELSE 'Carried to audit of ' END || to_char(v_date,'DD-Mon-YYYY')
      WHERE o.sku_id = l.sku_id AND o.status = 'OPEN' AND o.audit_id <> a.id;
      UPDATE public.lwb_stock_audit_lines SET system_pcs = v_sys, pending_pcs = v_pend, diff_pcs = v_diff,
        status = CASE WHEN v_diff = 0 THEN 'MATCH' ELSE 'OPEN' END,
        open_since = CASE WHEN v_diff = 0 THEN NULL ELSE coalesce(v_since, v_date) END
      WHERE id = l.id;
      v_skus := v_skus + 1;
      IF v_diff < 0 THEN v_short := v_short - v_diff; v_bad := v_bad + 1; ELSIF v_diff > 0 THEN v_excess := v_excess + v_diff; v_bad := v_bad + 1; END IF;
    END LOOP;
    UPDATE public.lwb_stock_audits SET status = 'SUBMITTED', submitted_by = auth.uid(), submitted_at = now(), updated_at = now() WHERE id = a.id;
    SELECT coalesce(nullif(btrim(u.full_name),''), 'Godown') INTO v_by FROM public.user_profiles u WHERE u.id = auth.uid();
    PERFORM public.lwb_stx_bell(ARRAY['admin','manager'], NULL,
      CASE WHEN v_bad = 0 THEN 'Night audit: all matched' ELSE 'Night audit: ' || v_bad || ' SKU difference' || CASE WHEN v_bad > 1 THEN 's' ELSE '' END END,
      'AUD-' || a.id || ' · ' || to_char(v_date,'DD-Mon') || ' · ' || v_skus || ' SKUs counted'
        || CASE WHEN v_short > 0 THEN ' · short ' || v_short || ' pcs' ELSE '' END
        || CASE WHEN v_excess > 0 THEN ' · extra ' || v_excess || ' pcs' ELSE '' END || ' · by ' || coalesce(v_by,'Godown') || '.',
      CASE WHEN v_bad = 0 THEN 'STOCK_AUDIT_OK' ELSE 'STOCK_AUDIT_DIFF' END);
  END IF;
  RETURN jsonb_build_object('audit_id', a.id, 'submitted', coalesce(p_submit,false), 'skus', v_skus, 'diff_skus', v_bad, 'short_pcs', v_short, 'excess_pcs', v_excess);
END;
$fn$;

-- Open audit differences (and recent closed ones).
CREATE OR REPLACE FUNCTION public.lwb_stx_audit_diffs(p_all boolean DEFAULT false)
RETURNS TABLE(line_id bigint, audit_id bigint, audit_date date, sku_id uuid, sku_name text, pcs_per_case integer, system_pcs integer,
  pending_pcs integer, physical_pcs integer, diff_pcs integer, open_since date, status text, line_note text, resolve_note text,
  resolved_by_name text, resolved_at timestamptz, move_id bigint, days_open integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_stx_viewer() THEN RAISE EXCEPTION 'Night audit: Admin, Sales Head, Godown Manager or Accounts only'; END IF;
  RETURN QUERY
  SELECT l.id, a.id, a.audit_date, l.sku_id, l.sku_name, l.pcs_per_case, l.system_pcs, l.pending_pcs, l.physical_pcs, l.diff_pcs, l.open_since,
    l.status, l.line_note, l.resolve_note, u.full_name::text, l.resolved_at, l.move_id,
    CASE WHEN l.open_since IS NULL THEN NULL ELSE (public.lwb_stx_today() - l.open_since)::integer END
  FROM public.lwb_stock_audit_lines l JOIN public.lwb_stock_audits a ON a.id = l.audit_id
  LEFT JOIN public.user_profiles u ON u.id = l.resolved_by
  WHERE a.status = 'SUBMITTED' AND coalesce(l.diff_pcs,0) <> 0
    AND (l.status IN ('OPEN','LOSS_PENDING') OR (p_all AND a.audit_date >= public.lwb_stx_today() - 60))
  ORDER BY (l.status = 'OPEN') DESC, l.open_since, l.sku_name;
END;
$fn$;

-- Close a difference: FOUND (stock found, short or extra explained), LOSS (short not found:
-- asks a Saleable -> Loss transfer for the shortage; Sales Head / Admin approve).
CREATE OR REPLACE FUNCTION public.lwb_stx_audit_resolve(p_line_id bigint, p_action text, p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_act text := upper(btrim(coalesce(p_action,'')));
  v_note text := left(nullif(btrim(coalesce(p_note,'')),''), 300);
  l public.lwb_stock_audit_lines%ROWTYPE; v_date date; r jsonb; v_id bigint;
BEGIN
  IF NOT public.lwb_stx_user() THEN RAISE EXCEPTION 'Only Godown Manager, Sales Head or Admin can close a difference'; END IF;
  SELECT * INTO l FROM public.lwb_stock_audit_lines x WHERE x.id = p_line_id FOR UPDATE;
  IF l.id IS NULL OR l.status <> 'OPEN' THEN RAISE EXCEPTION 'This difference is not open'; END IF;
  SELECT a.audit_date INTO v_date FROM public.lwb_stock_audits a WHERE a.id = l.audit_id;
  IF v_act = 'FOUND' THEN
    IF v_note IS NULL THEN RAISE EXCEPTION 'Write where it was found / why it differed'; END IF;
    UPDATE public.lwb_stock_audit_lines SET status = CASE WHEN l.diff_pcs > 0 THEN 'EXCESS_OK' ELSE 'FOUND' END,
      resolve_note = v_note, resolved_by = auth.uid(), resolved_at = now() WHERE id = l.id;
    RETURN jsonb_build_object('status', CASE WHEN l.diff_pcs > 0 THEN 'EXCESS_OK' ELSE 'FOUND' END);
  ELSIF v_act = 'LOSS' THEN
    IF l.diff_pcs >= 0 THEN RAISE EXCEPTION 'Only a shortage can go to Loss'; END IF;
    r := public.lwb_stx_request(jsonb_build_object('from_bucket','SALEABLE','to_bucket','LOSS',
      'move_date', greatest(coalesce(l.open_since, v_date), public.lwb_stx_today() - 31),
      'reason', 'Night audit short not found (AUD-' || l.audit_id || ')', 'note', v_note,
      'lines', jsonb_build_array(jsonb_build_object('sku_id', l.sku_id, 'cases', 0, 'pcs', -l.diff_pcs))));
    v_id := (r->'ids'->>0)::bigint;
    UPDATE public.lwb_stock_moves SET source = 'AUDIT', audit_line_id = l.id WHERE id = v_id;
    UPDATE public.lwb_stock_audit_lines SET status = 'LOSS_PENDING', move_id = v_id, resolve_note = v_note WHERE id = l.id;
    RETURN jsonb_build_object('status','LOSS_PENDING','move_id', v_id);
  END IF;
  RAISE EXCEPTION 'Invalid action';
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_stx_audits(p_from date, p_to date)
RETURNS TABLE(id bigint, audit_date date, status text, note text, skus integer, match_skus integer, diff_skus integer,
  system_pcs bigint, physical_pcs bigint, short_pcs bigint, excess_pcs bigint, system_cases numeric, physical_cases numeric,
  short_cases numeric, excess_cases numeric, counted_by text, submitted_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF NOT public.lwb_stx_viewer() THEN RAISE EXCEPTION 'Night audit: Admin, Sales Head, Godown Manager or Accounts only'; END IF;
  RETURN QUERY
  SELECT a.id, a.audit_date, a.status, a.note, count(l.id)::integer,
    count(l.id) FILTER (WHERE l.diff_pcs = 0)::integer, count(l.id) FILTER (WHERE l.diff_pcs <> 0)::integer,
    coalesce(sum(l.system_pcs - l.pending_pcs),0)::bigint, coalesce(sum(l.physical_pcs),0)::bigint,
    coalesce(sum(-l.diff_pcs) FILTER (WHERE l.diff_pcs < 0),0)::bigint, coalesce(sum(l.diff_pcs) FILTER (WHERE l.diff_pcs > 0),0)::bigint,
    round(coalesce(sum((l.system_pcs - l.pending_pcs)::numeric / l.pcs_per_case),0),2),
    round(coalesce(sum(l.physical_pcs::numeric / l.pcs_per_case),0),2),
    round(coalesce(sum(-l.diff_pcs::numeric / l.pcs_per_case) FILTER (WHERE l.diff_pcs < 0),0),2),
    round(coalesce(sum(l.diff_pcs::numeric / l.pcs_per_case) FILTER (WHERE l.diff_pcs > 0),0),2),
    max(coalesce(nullif(btrim(u.full_name),''),'User'))::text, a.submitted_at
  FROM public.lwb_stock_audits a
  LEFT JOIN public.lwb_stock_audit_lines l ON l.audit_id = a.id
  LEFT JOIN public.user_profiles u ON u.id = coalesce(a.submitted_by, a.created_by)
  WHERE (p_from IS NULL OR a.audit_date >= p_from) AND (p_to IS NULL OR a.audit_date <= p_to)
  GROUP BY a.id ORDER BY a.audit_date DESC;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- Daily report: one row per day. Handled = goods inward cases + cases loaded in vehicles.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.lwb_stx_daily(p_from date, p_to date)
RETURNS TABLE(day date, inward_cases numeric, loaded_cases numeric, handled_cases numeric,
  damage_cases numeric, leakage_cases numeric, breakage_cases numeric, gasless_cases numeric, expiry_cases numeric, loss_cases numeric,
  destroyed_cases numeric, company_return_cases numeric, back_to_saleable_cases numeric, pending_requests integer,
  audit_status text, audit_skus integer, audit_diff_skus integer, audit_short_cases numeric, audit_excess_cases numeric,
  loss_per_1000 numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  d date; v_from date := coalesce(p_from, public.lwb_stx_today()); v_to date := coalesce(p_to, public.lwb_stx_today());
  v_in numeric; v_out numeric; a record; mv record;
BEGIN
  IF NOT public.lwb_stx_viewer() THEN RAISE EXCEPTION 'Stock reports: Admin, Sales Head, Godown Manager or Accounts only'; END IF;
  IF v_to < v_from THEN RAISE EXCEPTION 'From date is after To date'; END IF;
  IF v_to - v_from > 92 THEN RAISE EXCEPTION 'Choose at most 3 months'; END IF;
  d := v_from;
  WHILE d <= v_to LOOP
    -- Goods inward (live table names; a missing column just leaves the number blank).
    v_in := NULL;
    BEGIN
      EXECUTE 'SELECT coalesce(sum(i.cases::numeric + coalesce(i.pcs,0)::numeric / greatest(coalesce(s.pcs_per_case,1),1)),0)
               FROM public.lwb_goods_inward_items i JOIN public.lwb_goods_inward g ON g.id = i.inward_id
               LEFT JOIN public.sku_master s ON s.id = i.sku_id WHERE g.received_date = $1' INTO v_in USING d;
    EXCEPTION WHEN others THEN v_in := NULL;
    END;
    v_out := NULL;
    BEGIN
      EXECUTE 'SELECT coalesce(sum(it.loaded_qty),0)::numeric FROM public.order_items it
               JOIN public.orders o ON o.id = it.order_id
               WHERE lower(coalesce(o.status,'''')) NOT IN (''cancelled'',''canceled'',''rejected'')
                 AND (SELECT (max(x.loading_completed_at) AT TIME ZONE ''Asia/Kolkata'')::date FROM public.dispatch_assignments x WHERE x.order_id = o.id) = $1'
        INTO v_out USING d;
    EXCEPTION WHEN others THEN v_out := NULL;
    END;
    SELECT
      sum(m.qty_pcs::numeric / m.pcs_per_case) FILTER (WHERE m.from_bucket = 'SALEABLE' AND m.to_bucket = 'DAMAGE') AS dmg,
      sum(m.qty_pcs::numeric / m.pcs_per_case) FILTER (WHERE m.from_bucket = 'SALEABLE' AND m.to_bucket = 'LEAKAGE') AS lkg,
      sum(m.qty_pcs::numeric / m.pcs_per_case) FILTER (WHERE m.from_bucket = 'SALEABLE' AND m.to_bucket = 'BREAKAGE') AS brk,
      sum(m.qty_pcs::numeric / m.pcs_per_case) FILTER (WHERE m.from_bucket = 'SALEABLE' AND m.to_bucket = 'GASLESS') AS gas,
      sum(m.qty_pcs::numeric / m.pcs_per_case) FILTER (WHERE m.from_bucket = 'SALEABLE' AND m.to_bucket = 'EXPIRY') AS exp,
      sum(m.qty_pcs::numeric / m.pcs_per_case) FILTER (WHERE m.from_bucket = 'SALEABLE' AND m.to_bucket = 'LOSS') AS los,
      sum(m.qty_pcs::numeric / m.pcs_per_case) FILTER (WHERE m.to_bucket = 'DESTROYED') AS des,
      sum(m.qty_pcs::numeric / m.pcs_per_case) FILTER (WHERE m.to_bucket = 'COMPANY_RETURN') AS ret,
      sum(m.qty_pcs::numeric / m.pcs_per_case) FILTER (WHERE m.to_bucket = 'SALEABLE') AS back
    INTO mv FROM public.lwb_stock_moves m WHERE m.status = 'APPROVED' AND m.move_date = d;
    SELECT x.status, count(l.id)::integer AS n, count(l.id) FILTER (WHERE l.diff_pcs <> 0)::integer AS bad,
      sum(-l.diff_pcs::numeric / l.pcs_per_case) FILTER (WHERE l.diff_pcs < 0) AS short,
      sum(l.diff_pcs::numeric / l.pcs_per_case) FILTER (WHERE l.diff_pcs > 0) AS excess
    INTO a FROM public.lwb_stock_audits x LEFT JOIN public.lwb_stock_audit_lines l ON l.audit_id = x.id
    WHERE x.audit_date = d GROUP BY x.status;
    day := d; inward_cases := round(v_in,2); loaded_cases := round(v_out,2);
    handled_cases := round(coalesce(v_in,0) + coalesce(v_out,0),2);
    damage_cases := round(coalesce(mv.dmg,0),2); leakage_cases := round(coalesce(mv.lkg,0),2); breakage_cases := round(coalesce(mv.brk,0),2);
    gasless_cases := round(coalesce(mv.gas,0),2); expiry_cases := round(coalesce(mv.exp,0),2); loss_cases := round(coalesce(mv.los,0),2);
    destroyed_cases := round(coalesce(mv.des,0),2); company_return_cases := round(coalesce(mv.ret,0),2); back_to_saleable_cases := round(coalesce(mv.back,0),2);
    pending_requests := (SELECT count(*) FROM public.lwb_stock_moves m WHERE m.status = 'PENDING' AND m.move_date = d)::integer;
    audit_status := a.status; audit_skus := a.n; audit_diff_skus := a.bad;
    audit_short_cases := round(coalesce(a.short,0),2); audit_excess_cases := round(coalesce(a.excess,0),2);
    loss_per_1000 := CASE WHEN coalesce(v_in,0) + coalesce(v_out,0) > 0 THEN round(coalesce(mv.los,0) * 1000 / (coalesce(v_in,0) + coalesce(v_out,0)), 2) END;
    RETURN NEXT;
    d := d + 1;
  END LOOP;
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_stx_status(), public.lwb_stx_request(jsonb), public.lwb_stx_decide(bigint[],text,text,jsonb),
  public.lwb_stx_cancel(bigint[]), public.lwb_stx_moves(text,date,date), public.lwb_stx_ledger(text,date,date,uuid),
  public.lwb_stx_audit_sheet(date), public.lwb_stx_audit_save(date,jsonb,boolean,text), public.lwb_stx_audit_diffs(boolean),
  public.lwb_stx_audit_resolve(bigint,text,text), public.lwb_stx_audits(date,date), public.lwb_stx_daily(date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_stx_status(), public.lwb_stx_request(jsonb), public.lwb_stx_decide(bigint[],text,text,jsonb),
  public.lwb_stx_cancel(bigint[]), public.lwb_stx_moves(text,date,date), public.lwb_stx_ledger(text,date,date,uuid),
  public.lwb_stx_audit_sheet(date), public.lwb_stx_audit_save(date,jsonb,boolean,text), public.lwb_stx_audit_diffs(boolean),
  public.lwb_stx_audit_resolve(bigint,text,text), public.lwb_stx_audits(date,date), public.lwb_stx_daily(date,date) TO authenticated;

-- ---------------------------------------------------------------------------
-- Link to live stock: put a wrapper with the same columns in front of lwb_live_stock.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_kind "char"; v_desc text; v_cols text; v_opts text[]; v_acl aclitem[]; v_ok boolean; g record;
BEGIN
  SELECT c.relkind, obj_description(c.oid, 'pg_class') INTO v_kind, v_desc FROM pg_class c WHERE c.oid = to_regclass('public.lwb_live_stock');
  IF v_kind IS NULL THEN
    RAISE NOTICE 'lwb_live_stock not found: transfers are recorded but saleable stock is not linked';
    RETURN;
  END IF;
  IF coalesce(v_desc, '') NOT LIKE 'LWB stock-transfer wrapper%' THEN
    IF v_kind <> 'v' OR to_regclass('public.lwb_live_stock_base') IS NOT NULL THEN
      RAISE NOTICE 'lwb_live_stock is not a plain view: saleable stock is not linked';
      RETURN;
    END IF;
    IF (SELECT count(*) FROM pg_attribute WHERE attrelid = 'public.lwb_live_stock'::regclass AND NOT attisdropped
        AND attname IN ('sku_id','saleable_pcs','damaged_pcs')) <> 3 THEN
      RAISE NOTICE 'lwb_live_stock has no sku_id / saleable_pcs / damaged_pcs: saleable stock is not linked';
      RETURN;
    END IF;
    EXECUTE 'SELECT count(*) = count(DISTINCT sku_id) FROM public.lwb_live_stock' INTO v_ok;
    IF NOT v_ok THEN
      RAISE NOTICE 'lwb_live_stock has more than one row per SKU: saleable stock is not linked';
      RETURN;
    END IF;
    BEGIN
      ALTER VIEW public.lwb_live_stock RENAME TO lwb_live_stock_base;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE 'No right to rename lwb_live_stock: saleable stock is not linked';
      RETURN;
    END;
  END IF;

  SELECT string_agg(CASE a.attname
      WHEN 'saleable_pcs' THEN format('(b.saleable_pcs + coalesce(x.saleable_adj, 0))::%s AS saleable_pcs', format_type(a.atttypid, a.atttypmod))
      WHEN 'damaged_pcs' THEN format('(coalesce(b.damaged_pcs, 0) + coalesce(x.held_pcs, 0))::%s AS damaged_pcs', format_type(a.atttypid, a.atttypmod))
      ELSE format('b.%I', a.attname) END, ', ' ORDER BY a.attnum)
  INTO v_cols FROM pg_attribute a WHERE a.attrelid = 'public.lwb_live_stock_base'::regclass AND a.attnum > 0 AND NOT a.attisdropped;
  SELECT c.reloptions, c.relacl INTO v_opts, v_acl FROM pg_class c WHERE c.oid = 'public.lwb_live_stock_base'::regclass;

  EXECUTE format('CREATE OR REPLACE VIEW public.lwb_live_stock %s AS SELECT %s FROM public.lwb_live_stock_base b LEFT JOIN public.lwb_stx_adjust() x ON x.sku_id = b.sku_id',
    CASE WHEN v_opts IS NULL THEN '' ELSE 'WITH (' || array_to_string(v_opts, ', ') || ')' END, v_cols);
  COMMENT ON VIEW public.lwb_live_stock IS 'LWB stock-transfer wrapper: lwb_live_stock_base + approved stock transfers (lwb_stock_transfer_setup.sql)';

  FOR g IN SELECT DISTINCT e.grantee, e.privilege_type FROM aclexplode(v_acl) e WHERE e.grantee <> (SELECT c.relowner FROM pg_class c WHERE c.oid = 'public.lwb_live_stock_base'::regclass) LOOP
    IF g.grantee = 0 THEN
      EXECUTE format('GRANT %s ON public.lwb_live_stock TO PUBLIC', g.privilege_type);
    ELSE
      EXECUTE format('GRANT %s ON public.lwb_live_stock TO %I', g.privilege_type, pg_get_userbyid(g.grantee));
    END IF;
  END LOOP;
END;
$do$;

COMMIT;
