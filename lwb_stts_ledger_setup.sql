-- LUXURY WRIST BRAND ERP — STTS LEDGER: company Sales Register + STTS Ledger checked against the Rate List (13 Nov 2026)
--
-- Runs by itself when merged to main (after lwb_rate_scheme_setup.sql and lwb_rate_ledger_setup.sql). Safe to run again.
--
-- Mohit asked (13 Nov 2026): upload the DMS Sales Register (CSV) and the company STTS Ledger (XLS); by invoice no.
-- and item, check that the scheme on each bill (free bottles / ₹ off per case) matches the Rate List of that day and
-- that the company accepted the same in STTS. Kept apart from Rate & Scheme. Page: stts-ledger.html (stts-match.js).
--   * lwb_stts_sales    : one row per Sales Register bill line (bill no. + line no.). Upload again = replaced, never doubled.
--   * lwb_stts_claims   : STTS Ledger lines (PI = purchase margin, SI = scheme on our sales bills). The portal gives the
--                         whole month each time, so an upload replaces every STTS line of the dates it covers.
--   * lwb_stts_uploads  : who uploaded what, dates, lines, result.
--   * lwb_stts_pack_links: company pack code (e.g. 250MLPLBTN1X28) -> Rate List pack name.
--   * RPCs lwb_stts_data(months), lwb_stts_sales_upload(rows, file), lwb_stts_claims_upload(rows, file),
--     lwb_stts_pack_link(pack, rate_pack). Read / upload: active Admin, Sales Head, Accounts. Pack link: Admin, Sales Head.
-- No order, bill, stock, rate, ledger or Tally data is changed.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_stts_role()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
  SELECT lower(btrim(p.role)) FROM public.user_profiles p
   WHERE p.id = auth.uid() AND p.active = true AND lower(btrim(p.role)) IN ('admin','manager','accounts');
$fn$;

CREATE TABLE IF NOT EXISTS public.lwb_stts_uploads (
  id bigserial PRIMARY KEY,
  kind text NOT NULL CHECK (kind IN ('SALES','STTS')),
  file_name text,
  from_day date,
  to_day date,
  lines integer NOT NULL DEFAULT 0,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);

CREATE TABLE IF NOT EXISTS public.lwb_stts_sales (
  doc text NOT NULL,
  line_no integer NOT NULL,
  day date NOT NULL,
  type text, outlet_code text, outlet text, item_code text, item text NOT NULL, brand text,
  bpc numeric(10,2) NOT NULL DEFAULT 0, pc numeric(14,3) NOT NULL DEFAULT 0, ea numeric(14,2) NOT NULL DEFAULT 0,
  line numeric(14,2) NOT NULL DEFAULT 0, disc numeric(14,2) NOT NULL DEFAULT 0, net numeric(14,2) NOT NULL DEFAULT 0,
  promo numeric(14,2) NOT NULL DEFAULT 0, landed numeric(12,4) NOT NULL DEFAULT 0,
  salesman text, free boolean NOT NULL DEFAULT false,
  upload_id bigint REFERENCES public.lwb_stts_uploads(id) ON DELETE SET NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (doc, line_no)
);
CREATE INDEX IF NOT EXISTS lwb_stts_sales_day_idx ON public.lwb_stts_sales (day);

CREATE TABLE IF NOT EXISTS public.lwb_stts_claims (
  id bigserial PRIMARY KEY,
  doc_type text NOT NULL, mer text, sale_type text, outlet_code text, outlet text,
  doc text NOT NULL, day date NOT NULL, item_code text, item text,
  pc numeric(14,3) NOT NULL DEFAULT 0, uc numeric(14,4) NOT NULL DEFAULT 0, amt numeric(14,2) NOT NULL DEFAULT 0, paid text,
  upload_id bigint REFERENCES public.lwb_stts_uploads(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS lwb_stts_claims_day_idx ON public.lwb_stts_claims (day);
CREATE INDEX IF NOT EXISTS lwb_stts_claims_doc_idx ON public.lwb_stts_claims (doc);

CREATE TABLE IF NOT EXISTS public.lwb_stts_pack_links (
  hccb_pack text PRIMARY KEY,
  rate_pack text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

-- No direct reads or writes: everything goes through the RPCs below.
ALTER TABLE public.lwb_stts_uploads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_stts_sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_stts_claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lwb_stts_pack_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.lwb_stts_uploads, public.lwb_stts_sales, public.lwb_stts_claims, public.lwb_stts_pack_links
  FROM PUBLIC, anon, authenticated;

-- Everything the page needs for the last p_months months (plus the Rate Ledger free bottle / OMS per pack).
CREATE OR REPLACE FUNCTION public.lwb_stts_data(p_months integer DEFAULT 6)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_from date;
BEGIN
  IF public.lwb_stts_role() IS NULL THEN RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can open the STTS Ledger.'; END IF;
  v_from := (date_trunc('month', (now() AT TIME ZONE 'Asia/Kolkata')::date) - make_interval(months => greatest(0, least(coalesce(p_months, 6), 24) - 1)))::date;
  RETURN jsonb_build_object(
    'role', public.lwb_stts_role(),
    'sales', coalesce((SELECT jsonb_agg(jsonb_build_object('doc',s.doc,'line_no',s.line_no,'day',s.day,'type',s.type,'outlet_code',s.outlet_code,
        'outlet',s.outlet,'item_code',s.item_code,'item',s.item,'brand',s.brand,'bpc',s.bpc,'pc',s.pc,'ea',s.ea,'line',s.line,'disc',s.disc,
        'net',s.net,'promo',s.promo,'landed',s.landed,'salesman',s.salesman,'free',s.free) ORDER BY s.day, s.doc, s.line_no)
      FROM public.lwb_stts_sales s WHERE s.day >= v_from), '[]'::jsonb),
    'claims', coalesce((SELECT jsonb_agg(jsonb_build_object('doc_type',c.doc_type,'mer',c.mer,'sale_type',c.sale_type,'outlet_code',c.outlet_code,
        'outlet',c.outlet,'doc',c.doc,'day',c.day,'item_code',c.item_code,'item',c.item,'pc',c.pc,'uc',c.uc,'amt',c.amt,'paid',c.paid) ORDER BY c.day, c.id)
      FROM public.lwb_stts_claims c WHERE c.day >= v_from), '[]'::jsonb),
    'uploads', coalesce((SELECT jsonb_agg(x ORDER BY (x->>'created_at') DESC) FROM (
        SELECT jsonb_build_object('id',u.id,'kind',u.kind,'file_name',u.file_name,'from_day',u.from_day,'to_day',u.to_day,'lines',u.lines,
          'note',u.note,'created_at',u.created_at,'by_name',coalesce(nullif(btrim(p.full_name),''), p.role)) x
        FROM public.lwb_stts_uploads u LEFT JOIN public.user_profiles p ON p.id = u.created_by
        ORDER BY u.created_at DESC LIMIT 40) t), '[]'::jsonb),
    'links', coalesce((SELECT jsonb_object_agg(l.hccb_pack, l.rate_pack) FROM public.lwb_stts_pack_links l), '{}'::jsonb),
    'packs', coalesce((SELECT jsonb_agg(p.pack_name ORDER BY p.sort_no, p.pack_name) FROM public.lwb_rate_packs p WHERE p.active), '[]'::jsonb),
    'rates', coalesce((SELECT jsonb_agg(jsonb_build_object('id',h.id,'created_at',h.created_at,'valid_from',h.valid_from,
        'rows',(SELECT coalesce(jsonb_agg(jsonb_build_object('name',r->>'name','fb',r->'fb','oms',r->'oms')), '[]'::jsonb)
                FROM jsonb_array_elements(coalesce(h.rows,'[]'::jsonb)) r)) ORDER BY h.created_at DESC)
      FROM public.lwb_rate_history h), '[]'::jsonb));
END;
$fn$;

-- Sales Register upload: same bill + line no. is replaced, other bills stay.
CREATE OR REPLACE FUNCTION public.lwb_stts_sales_upload(p_rows jsonb, p_file text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_up bigint; v_n integer; v_new integer := 0; v_chg integer := 0; v_same integer := 0; v_from date; v_to date; v_note text;
BEGIN
  IF public.lwb_stts_role() IS NULL THEN RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can upload to the STTS Ledger.'; END IF;
  IF jsonb_typeof(coalesce(p_rows,'null'::jsonb)) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN RAISE EXCEPTION 'No lines to save.'; END IF;
  IF jsonb_array_length(p_rows) > 20000 THEN RAISE EXCEPTION 'Too many lines in one file (max 20000).'; END IF;
  CREATE TEMP TABLE IF NOT EXISTS lwb_stts_tmp_s (LIKE public.lwb_stts_sales) ON COMMIT DROP;
  DELETE FROM lwb_stts_tmp_s;
  INSERT INTO lwb_stts_tmp_s(doc,line_no,day,type,outlet_code,outlet,item_code,item,brand,bpc,pc,ea,line,disc,net,promo,landed,salesman,free,updated_at)
  SELECT DISTINCT ON (btrim(r.doc), r.line_no) btrim(r.doc), r.line_no, r.day, r.type, r.outlet_code, r.outlet, r.item_code, r.item, r.brand,
         coalesce(r.bpc,0), coalesce(r.pc,0), coalesce(r.ea,0), coalesce(r.line,0), coalesce(r.disc,0), coalesce(r.net,0),
         coalesce(r.promo,0), coalesce(r.landed,0), r.salesman, coalesce(r.free,false), now()
    FROM jsonb_to_recordset(p_rows) AS r(doc text, line_no integer, day date, type text, outlet_code text, outlet text, item_code text,
         item text, brand text, bpc numeric, pc numeric, ea numeric, line numeric, disc numeric, net numeric, promo numeric, landed numeric,
         salesman text, free boolean)
   WHERE nullif(btrim(r.doc),'') IS NOT NULL AND r.line_no IS NOT NULL AND r.day IS NOT NULL AND nullif(btrim(r.item),'') IS NOT NULL
   ORDER BY btrim(r.doc), r.line_no;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RAISE EXCEPTION 'No valid lines (bill no., line no., date and item are needed).'; END IF;
  SELECT min(day), max(day) INTO v_from, v_to FROM lwb_stts_tmp_s;
  SELECT count(*) FILTER (WHERE s.doc IS NULL),
         count(*) FILTER (WHERE s.doc IS NOT NULL AND (s.day,s.item,s.pc,s.ea,s.line,s.disc,s.net,s.promo,s.free,s.outlet)
                          IS DISTINCT FROM (t.day,t.item,t.pc,t.ea,t.line,t.disc,t.net,t.promo,t.free,t.outlet)),
         count(*) FILTER (WHERE s.doc IS NOT NULL AND (s.day,s.item,s.pc,s.ea,s.line,s.disc,s.net,s.promo,s.free,s.outlet)
                          IS NOT DISTINCT FROM (t.day,t.item,t.pc,t.ea,t.line,t.disc,t.net,t.promo,t.free,t.outlet))
    INTO v_new, v_chg, v_same
    FROM lwb_stts_tmp_s t LEFT JOIN public.lwb_stts_sales s ON s.doc = t.doc AND s.line_no = t.line_no;
  v_note := v_new||' new · '||v_chg||' changed · '||v_same||' already there';
  INSERT INTO public.lwb_stts_uploads(kind,file_name,from_day,to_day,lines,note,created_by)
  VALUES ('SALES', left(p_file,200), v_from, v_to, v_n, v_note, auth.uid()) RETURNING id INTO v_up;
  INSERT INTO public.lwb_stts_sales AS s (doc,line_no,day,type,outlet_code,outlet,item_code,item,brand,bpc,pc,ea,line,disc,net,promo,landed,salesman,free,upload_id,updated_at)
  SELECT doc,line_no,day,type,outlet_code,outlet,item_code,item,brand,bpc,pc,ea,line,disc,net,promo,landed,salesman,free,v_up,now() FROM lwb_stts_tmp_s
  ON CONFLICT (doc, line_no) DO UPDATE SET day=excluded.day, type=excluded.type, outlet_code=excluded.outlet_code, outlet=excluded.outlet,
    item_code=excluded.item_code, item=excluded.item, brand=excluded.brand, bpc=excluded.bpc, pc=excluded.pc, ea=excluded.ea, line=excluded.line,
    disc=excluded.disc, net=excluded.net, promo=excluded.promo, landed=excluded.landed, salesman=excluded.salesman, free=excluded.free,
    upload_id=excluded.upload_id, updated_at=now();
  RETURN jsonb_build_object('upload_id',v_up,'lines',v_n,'added',v_new,'changed',v_chg,'same',v_same,
    'note','Sales Register saved: '||v_note||'.');
END;
$fn$;

-- STTS upload: the newest file replaces every STTS line of the dates it covers (first to last date in the file).
CREATE OR REPLACE FUNCTION public.lwb_stts_claims_upload(p_rows jsonb, p_file text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
DECLARE v_up bigint; v_n integer; v_del integer; v_from date; v_to date; v_note text;
BEGIN
  IF public.lwb_stts_role() IS NULL THEN RAISE EXCEPTION 'Only Admin, Sales Head or Accounts can upload to the STTS Ledger.'; END IF;
  IF jsonb_typeof(coalesce(p_rows,'null'::jsonb)) <> 'array' OR jsonb_array_length(p_rows) = 0 THEN RAISE EXCEPTION 'No lines to save.'; END IF;
  IF jsonb_array_length(p_rows) > 20000 THEN RAISE EXCEPTION 'Too many lines in one file (max 20000).'; END IF;
  CREATE TEMP TABLE IF NOT EXISTS lwb_stts_tmp_c (LIKE public.lwb_stts_claims) ON COMMIT DROP;
  DELETE FROM lwb_stts_tmp_c;
  INSERT INTO lwb_stts_tmp_c(id,doc_type,mer,sale_type,outlet_code,outlet,doc,day,item_code,item,pc,uc,amt,paid)
  SELECT 0, upper(btrim(r.doc_type)), r.mer, r.sale_type, r.outlet_code, r.outlet, btrim(r.doc), r.day, r.item_code, r.item,
         coalesce(r.pc,0), coalesce(r.uc,0), coalesce(r.amt,0), nullif(btrim(coalesce(r.paid,'')),'')
    FROM jsonb_to_recordset(p_rows) AS r(doc_type text, mer text, sale_type text, outlet_code text, outlet text, doc text, day date,
         item_code text, item text, pc numeric, uc numeric, amt numeric, paid text)
   WHERE nullif(btrim(r.doc),'') IS NOT NULL AND nullif(btrim(r.doc_type),'') IS NOT NULL AND r.day IS NOT NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RAISE EXCEPTION 'No valid lines (doc type, doc no. and date are needed).'; END IF;
  SELECT min(day), max(day) INTO v_from, v_to FROM lwb_stts_tmp_c;
  DELETE FROM public.lwb_stts_claims WHERE day BETWEEN v_from AND v_to;
  GET DIAGNOSTICS v_del = ROW_COUNT;
  v_note := v_n||' lines (PI '||(SELECT count(*) FROM lwb_stts_tmp_c WHERE doc_type='PI')||', SI '||(SELECT count(*) FROM lwb_stts_tmp_c WHERE doc_type='SI')||
            ') · replaced '||v_del||' old lines of these dates';
  INSERT INTO public.lwb_stts_uploads(kind,file_name,from_day,to_day,lines,note,created_by)
  VALUES ('STTS', left(p_file,200), v_from, v_to, v_n, v_note, auth.uid()) RETURNING id INTO v_up;
  INSERT INTO public.lwb_stts_claims(doc_type,mer,sale_type,outlet_code,outlet,doc,day,item_code,item,pc,uc,amt,paid,upload_id)
  SELECT doc_type,mer,sale_type,outlet_code,outlet,doc,day,item_code,item,pc,uc,amt,paid,v_up FROM lwb_stts_tmp_c;
  RETURN jsonb_build_object('upload_id',v_up,'lines',v_n,'replaced',v_del,'note','STTS Ledger saved: '||v_note||'.');
END;
$fn$;

CREATE OR REPLACE FUNCTION public.lwb_stts_pack_link(p_pack text, p_rate_pack text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $fn$
BEGIN
  IF coalesce(public.lwb_stts_role(),'') NOT IN ('admin','manager') THEN RAISE EXCEPTION 'Only Admin or Sales Head can link packs.'; END IF;
  IF nullif(btrim(coalesce(p_pack,'')),'') IS NULL THEN RAISE EXCEPTION 'Company pack is missing.'; END IF;
  IF nullif(btrim(coalesce(p_rate_pack,'')),'') IS NULL THEN
    DELETE FROM public.lwb_stts_pack_links WHERE hccb_pack = upper(btrim(p_pack)); RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_rate_packs p WHERE upper(btrim(p.pack_name)) = upper(btrim(p_rate_pack))) THEN
    RAISE EXCEPTION 'Rate List pack % not found.', p_rate_pack;
  END IF;
  INSERT INTO public.lwb_stts_pack_links(hccb_pack, rate_pack, updated_at, updated_by)
  VALUES (upper(btrim(p_pack)), btrim(p_rate_pack), now(), auth.uid())
  ON CONFLICT (hccb_pack) DO UPDATE SET rate_pack = excluded.rate_pack, updated_at = now(), updated_by = auth.uid();
END;
$fn$;

REVOKE ALL ON FUNCTION public.lwb_stts_role(), public.lwb_stts_data(integer), public.lwb_stts_sales_upload(jsonb, text),
  public.lwb_stts_claims_upload(jsonb, text), public.lwb_stts_pack_link(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_stts_role(), public.lwb_stts_data(integer), public.lwb_stts_sales_upload(jsonb, text),
  public.lwb_stts_claims_upload(jsonb, text), public.lwb_stts_pack_link(text, text) TO authenticated;

COMMIT;
