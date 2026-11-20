-- LUXURY WRIST BRAND ERP — GST TAB OF ACCOUNTS (TALLY) (Mohit, 20 Nov 2026)
--
-- Month by month: what the ERP sees (sales GST from the Tally bills made, purchase GST from the purchase
-- bills) next to what Accounts filed and paid (typed in from the GST portal / Tally: GSTR-1 and GSTR-3B
-- dates, tax as per 3B, ITC used, cash paid, challan). Admin and Accounts only; the Cashier does not see it.
--
--   lwb_gst_months            one row per month (month = 1st of the month)
--   lwb_gst_summary(months)   last N months (1-36): ERP figures + saved filing; today
--   lwb_gst_save(p)           save one month's filing
--
-- ERP sales GST = for every PO whose Tally bill date is in the month: item qty (loaded, else approved, else
-- ordered) x rate (incl. tax) x (GST + cess) / (100 + GST + cess), GST / cess from SKU Master; same maths as
-- the Tax Invoice print. It is a check figure; the return is filed from Tally.
-- ERP purchase GST = purchase bills (Purchase Register) by invoice date: total - taxable.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_gst_months (
  month date PRIMARY KEY CHECK (extract(day FROM month) = 1),
  gstr1_on date,
  gstr3b_on date,
  tax_3b numeric(14,2) CHECK (tax_3b IS NULL OR tax_3b >= 0),
  itc_used numeric(14,2) CHECK (itc_used IS NULL OR itc_used >= 0),
  paid numeric(14,2) CHECK (paid IS NULL OR paid >= 0),
  paid_on date,
  challan text CHECK (challan IS NULL OR length(challan) <= 60),
  note text CHECK (note IS NULL OR length(note) <= 300),
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.lwb_gst_months ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_gst_months FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.lwb_gst_user()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = auth.uid() AND p.active = true
                 AND lower(btrim(p.role)) IN ('accounts','admin'));
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_gst_summary(p_months integer DEFAULT 12)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_n integer := least(greatest(coalesce(p_months, 12), 1), 36);
  v_from date;
  v_rows jsonb;
BEGIN
  IF NOT public.lwb_gst_user() THEN RAISE EXCEPTION 'Admin / Accounts only'; END IF;
  v_from := (date_trunc('month', v_today) - make_interval(months => v_n - 1))::date;
  WITH m AS (
    SELECT generate_series(v_from, date_trunc('month', v_today)::date, interval '1 month')::date AS month
  ), bills AS (
    SELECT t.order_id, date_trunc('month', t.invoice_date)::date AS month,
           coalesce((SELECT sum(nullif(b->>'amount','')::numeric) FROM jsonb_array_elements(
                       CASE WHEN jsonb_typeof(to_jsonb(t)->'bills') = 'array' THEN to_jsonb(t)->'bills' ELSE '[]'::jsonb END) b),
                    nullif(to_jsonb(t)->>'amount','')::numeric, 0) AS amount
    FROM public.lwb_tally_invoices t
    JOIN public.orders o ON o.id = t.order_id
    WHERE t.invoice_date >= v_from AND t.invoice_date <= v_today
      AND lower(coalesce(to_jsonb(o)->>'status','')) NOT IN ('cancelled','rejected','deleted')
  ), lines AS (
    SELECT b.month,
           coalesce(nullif(ij->>'loaded_qty','')::numeric, nullif(ij->>'approved_qty','')::numeric,
                    nullif(ij->>'ordered_qty','')::numeric, 0) * coalesce(nullif(ij->>'rate','')::numeric, 0) AS amt,
           coalesce(nullif(s.j->>'gst_rate','')::numeric, 0) + coalesce(nullif(s.j->>'cess_rate','')::numeric, 0) AS pct
    FROM bills b
    JOIN public.order_items i ON i.order_id = b.order_id
    CROSS JOIN LATERAL to_jsonb(i) ij
    LEFT JOIN LATERAL (SELECT to_jsonb(x) AS j FROM public.sku_master x
                       WHERE upper(btrim(x.sku_name::text)) = upper(btrim(ij->>'sku_name')) LIMIT 1) s ON true
  ), sale AS (
    SELECT month, count(*) AS bills, sum(amount) AS amount FROM bills GROUP BY month
  ), sale_tax AS (
    SELECT month, sum(CASE WHEN pct > 0 THEN amt * pct / (100 + pct) ELSE 0 END) AS gst,
           sum(amt) AS erp_amount, count(*) FILTER (WHERE pct = 0 AND amt > 0) AS no_rate
    FROM lines GROUP BY month
  ), pur AS (
    SELECT date_trunc('month', coalesce(nullif(g->>'invoice_date','')::date, nullif(g->>'received_date','')::date))::date AS month,
           count(DISTINCT g->>'id') AS bills,
           sum(coalesce(nullif(it->>'total_amount','')::numeric, 0)) AS total,
           sum(coalesce(nullif(it->>'taxable_amount','')::numeric, 0)) AS taxable
    FROM public.lwb_goods_inward gi
    CROSS JOIN LATERAL to_jsonb(gi) g
    JOIN public.lwb_goods_inward_items ii ON ii.inward_id = gi.id
    CROSS JOIN LATERAL to_jsonb(ii) it
    WHERE coalesce(nullif(g->>'invoice_date','')::date, nullif(g->>'received_date','')::date) BETWEEN v_from AND v_today
    GROUP BY 1
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'month', m.month,
           'sales_bills', coalesce(sale.bills, 0),
           'sales_amount', round(coalesce(sale.amount, 0), 2),
           'sales_gst', round(coalesce(sale_tax.gst, 0), 2),
           'no_rate', coalesce(sale_tax.no_rate, 0),
           'pur_bills', coalesce(pur.bills, 0),
           'pur_amount', round(coalesce(pur.total, 0), 2),
           'pur_gst', round(greatest(coalesce(pur.total, 0) - coalesce(pur.taxable, 0), 0), 2),
           'gstr1_on', g.gstr1_on, 'gstr3b_on', g.gstr3b_on, 'tax_3b', g.tax_3b, 'itc_used', g.itc_used,
           'paid', g.paid, 'paid_on', g.paid_on, 'challan', g.challan, 'note', g.note, 'updated_at', g.updated_at,
           'updated_by', (SELECT p.full_name FROM public.user_profiles p WHERE p.id = g.updated_by))
         ORDER BY m.month DESC), '[]'::jsonb)
  INTO v_rows
  FROM m
  LEFT JOIN sale ON sale.month = m.month
  LEFT JOIN sale_tax ON sale_tax.month = m.month
  LEFT JOIN pur ON pur.month = m.month
  LEFT JOIN public.lwb_gst_months g ON g.month = m.month;
  RETURN jsonb_build_object('today', v_today, 'rows', v_rows);
END
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_gst_save(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Kolkata')::date;
  v_month date;
  d1 date; d3 date; dp date;
  v_tax numeric; v_itc numeric; v_paid numeric;
BEGIN
  IF NOT public.lwb_gst_user() THEN RAISE EXCEPTION 'Admin / Accounts only'; END IF;
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RAISE EXCEPTION 'Nothing to save'; END IF;
  v_month := date_trunc('month', nullif(p->>'month','')::date)::date;
  IF v_month IS NULL OR v_month > date_trunc('month', v_today)::date OR v_month < (v_today - 1200) THEN
    RAISE EXCEPTION 'Choose the month'; END IF;
  d1 := nullif(p->>'gstr1_on','')::date; d3 := nullif(p->>'gstr3b_on','')::date; dp := nullif(p->>'paid_on','')::date;
  IF d1 > v_today OR d3 > v_today OR dp > v_today THEN RAISE EXCEPTION 'A date can not be after today'; END IF;
  IF d1 < v_month OR d3 < v_month OR dp < v_month THEN RAISE EXCEPTION 'A date can not be before the month itself'; END IF;
  v_tax := round(nullif(p->>'tax_3b','')::numeric, 2); v_itc := round(nullif(p->>'itc_used','')::numeric, 2);
  v_paid := round(nullif(p->>'paid','')::numeric, 2);
  IF v_tax < 0 OR v_itc < 0 OR v_paid < 0 THEN RAISE EXCEPTION 'Amounts can not be less than zero'; END IF;
  IF v_tax > 100000000 OR v_itc > 100000000 OR v_paid > 100000000 THEN RAISE EXCEPTION 'Check the amount'; END IF;
  IF v_paid > 0 AND dp IS NULL THEN RAISE EXCEPTION 'Enter the date it was paid'; END IF;
  INSERT INTO public.lwb_gst_months AS g (month, gstr1_on, gstr3b_on, tax_3b, itc_used, paid, paid_on, challan, note, updated_by, updated_at)
  VALUES (v_month, d1, d3, v_tax, v_itc, v_paid, dp, nullif(btrim(coalesce(p->>'challan','')),''),
          nullif(btrim(coalesce(p->>'note','')),''), auth.uid(), now())
  ON CONFLICT (month) DO UPDATE SET gstr1_on = excluded.gstr1_on, gstr3b_on = excluded.gstr3b_on, tax_3b = excluded.tax_3b,
    itc_used = excluded.itc_used, paid = excluded.paid, paid_on = excluded.paid_on, challan = excluded.challan,
    note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
  RETURN jsonb_build_object('ok', true, 'month', v_month);
END
$fn$;

REVOKE ALL ON FUNCTION public.lwb_gst_user(), public.lwb_gst_summary(integer), public.lwb_gst_save(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_gst_user(), public.lwb_gst_summary(integer), public.lwb_gst_save(jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Result: every row should say true.
SELECT 'gst months table' AS item, (to_regclass('public.lwb_gst_months') IS NOT NULL)::text AS ok
UNION ALL SELECT 'gst summary', (to_regprocedure('public.lwb_gst_summary(integer)') IS NOT NULL)::text
UNION ALL SELECT 'gst save', (to_regprocedure('public.lwb_gst_save(jsonb)') IS NOT NULL)::text;
