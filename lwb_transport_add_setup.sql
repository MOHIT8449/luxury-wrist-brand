-- LUXURY WRIST BRAND ERP — "➕ Naya transport" from the Company dispatch / Gaadi driver dropdown (28 Nov 2026)
--
-- Mohit asked (28 Nov 2026): Transport is a dropdown of every saved transport (Transport Master). A new one can be added
-- from the dropdown. lwb_transport_add(name): Admin / Sales Head / Accounts / Godown Manager / Salesman. A name already in
-- the master (same letters, any case / spaces) is not added again: that one is returned.
--
-- Safe to run again. Nothing is dropped or deleted.

BEGIN;

CREATE OR REPLACE FUNCTION public.lwb_transport_add(p_name text)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $fn$
DECLARE v text := upper(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g')); r record;
BEGIN
  IF coalesce(public.lwb_dial_role(), '') NOT IN ('admin','manager','accounts','warehouse','sales') THEN
    RAISE EXCEPTION 'Only Admin, Sales Head, Accounts, Godown Manager or Salesman can add a transport';
  END IF;
  IF length(v) < 2 OR length(v) > 150 THEN RAISE EXCEPTION 'Transport name must be 2 to 150 characters'; END IF;
  SELECT t.id, t.transport_name, t.is_active INTO r FROM public.lwb_transport_master t
   WHERE regexp_replace(upper(t.transport_name), '[^A-Z0-9]', '', 'g') = regexp_replace(v, '[^A-Z0-9]', '', 'g')
   ORDER BY t.is_active DESC LIMIT 1;
  IF FOUND THEN
    IF NOT r.is_active THEN UPDATE public.lwb_transport_master SET is_active = true WHERE id = r.id; END IF;
    RETURN jsonb_build_object('name', r.transport_name, 'short', public.lwb_transport_short(r.transport_name), 'added', false);
  END IF;
  INSERT INTO public.lwb_transport_master (transport_name, is_active, created_by) VALUES (v, true, auth.uid());
  RETURN jsonb_build_object('name', v, 'short', public.lwb_transport_short(v), 'added', true);
END $fn$;
REVOKE ALL ON FUNCTION public.lwb_transport_add(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_transport_add(text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
