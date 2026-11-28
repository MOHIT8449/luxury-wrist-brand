-- LUXURY WRIST BRAND ERP — Dial Book: call log only for Admin (28 Nov 2026)
--
-- Mohit asked (28 Nov 2026): who called whom, when, how many calls: nobody but Admin may see it (a role-wise plan
-- comes later). So for every login except Admin:
--   lwb_dial_book()   no "Last call" (time / who / result) on any contact, no Recent list; all_log / call_log = false
--   lwb_dial_log()    refused ("Call log: only Admin can see it")
-- Calls are still recorded for every login (Call button), only Admin sees them.
-- Same functions as lwb_dial_book_numbers_setup.sql / lwb_dial_book_setup.sql otherwise: if one of those is run again,
-- run this file after it.
--
-- Safe to run again. Nothing is dropped or deleted.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_dial_book()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE r text := public.lwb_dial_role(); v jsonb; v_recent jsonb;
BEGIN
  WITH a AS (SELECT * FROM public.lwb_dial_all()),
       d AS (SELECT a.mobile, count(*) AS n FROM a WHERE a.kind IN ('PARTY','TEAM','STAFF','DRIVER') GROUP BY a.mobile HAVING count(*) > 1)
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind', a.kind, 'ref', a.ref, 'name', a.name, 'masked', public.lwb_dial_mask(a.mobile),
           'last4', right(a.mobile, 4), 'sub', a.sub, 'save_as', a.save_as, 'vehicle_no', a.vehicle_no, 'tag', a.tag, 'at', a.at,
           'last_at', lc.created_at, 'last_by', lc.called_by_name, 'last_result', lc.result,
           'extras', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'masked', public.lwb_dial_mask(n.mobile), 'last4', right(n.mobile, 4),
                        'label', n.label, 'by', n.created_by_name) ORDER BY n.id), '[]'::jsonb)
                      FROM public.lwb_contact_numbers n WHERE n.kind = a.kind AND n.ref = a.ref),
           'dup_with', CASE WHEN d.n IS NULL OR a.kind = 'VEHICLE' THEN NULL ELSE
             (SELECT jsonb_agg(b.name ORDER BY b.name) FROM a b WHERE b.mobile = a.mobile AND b.kind <> 'VEHICLE' AND NOT (b.kind = a.kind AND b.ref = a.ref)) END
         ) ORDER BY a.kind, a.name), '[]'::jsonb)
    INTO v
  FROM a
  LEFT JOIN d ON d.mobile = a.mobile
  LEFT JOIN LATERAL (SELECT c.created_at, c.called_by_name, c.result FROM public.lwb_dial_calls c
                     WHERE r = 'admin' AND c.kind = a.kind AND c.ref = a.ref
                     ORDER BY c.created_at DESC LIMIT 1) lc ON true;
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'ref', x.ref, 'at', x.created_at) ORDER BY x.created_at DESC), '[]'::jsonb)
    INTO v_recent
  FROM (SELECT DISTINCT ON (c.kind, c.ref) c.kind, c.ref, c.created_at FROM public.lwb_dial_calls c
        WHERE r = 'admin' AND c.called_by = auth.uid() AND c.created_at > now() - interval '30 days' AND coalesce(c.source, '') <> 'Download'
        ORDER BY c.kind, c.ref, c.created_at DESC) x
  LIMIT 15;
  RETURN jsonb_build_object('role', r, 'me', auth.uid(), 'all_log', r = 'admin', 'call_log', r = 'admin', 'export', r = 'admin',
    'add_num', r IN ('admin','manager','accounts','sales'), 'contacts', v, 'recent', v_recent);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_book() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_book() TO authenticated;

CREATE OR REPLACE FUNCTION public.lwb_dial_log(p_from date, p_to date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE r text := public.lwb_dial_role(); v_from date := coalesce(p_from, (now() AT TIME ZONE 'Asia/Kolkata')::date);
        v_to date := coalesce(p_to, (now() AT TIME ZONE 'Asia/Kolkata')::date);
BEGIN
  IF coalesce(r, '') <> 'admin' THEN RAISE EXCEPTION 'Call log: only Admin can see it'; END IF;
  IF v_to - v_from > 92 THEN v_from := v_to - 92; END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'at', c.created_at, 'kind', c.kind, 'ref', c.ref,
            'to_name', c.to_name, 'masked', public.lwb_dial_mask(c.to_mobile), 'vehicle_no', c.vehicle_no, 'source', c.source,
            'result', c.result, 'note', c.note, 'by', c.called_by, 'by_name', c.called_by_name, 'by_role', c.called_by_role)
            ORDER BY c.created_at DESC), '[]'::jsonb)
    FROM (SELECT * FROM public.lwb_dial_calls c
          WHERE (c.created_at AT TIME ZONE 'Asia/Kolkata')::date BETWEEN v_from AND v_to
          ORDER BY c.created_at DESC LIMIT 2000) c);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_dial_log(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_dial_log(date, date) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
