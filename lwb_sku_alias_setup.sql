-- LUXURY WRIST BRAND ERP — SKU RENAME = NEW LABEL ONLY, OLD DATA STAYS AS IT IS (6 Nov 2026)
--
-- Runs by itself when merged to main. Safe to run again. Nothing is dropped and no old row is changed.
--
-- Mohit asked (6 Nov 2026): "If I change a name, the data behind it must stay as it is." PO lines,
-- Rajnigandha rate limits and rate links keep the SKU name they were saved with (there is no sku_id on
-- order_items). After "250ML THUMS UP ZERO MRP 10" was renamed to "ZERO 250ML THUMS UP MRP 10" in SKU
-- Master, the old PO line showed under "No brand" on the Dashboard and lost its landing.
--
--   * lwb_sku_alias (alias_key = upper old name -> sku_id): every old name of an SKU.
--     Filled by a trigger whenever SKU Master renames an SKU, plus a one-time fill below for names
--     already renamed (PO line / rate limit / rate link names that are not in SKU Master but have the
--     same words, in any order, as exactly one SKU).
--   * lwb_sku_id_of(name)  -> sku_id of a current or old name (NULL if unknown).
--   * lwb_sku_now(name)    -> the SKU's current name (the name itself if unknown).
--   * lwb_sku_aliases()    -> list for the pages (alias_key, current sku_name).
--   * Rajnigandha rate limit (kept by name): the new name gets a copy, the old row stays as it is.
-- The pages and SQL reports match names through these, so the old line finds its SKU, brand, unit,
-- weight, landing and rate limit, while the row itself is never updated.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_sku_alias (
  alias_key  text PRIMARY KEY,
  sku_id     uuid NOT NULL REFERENCES public.sku_master(id) ON DELETE CASCADE,
  source     text NOT NULL DEFAULT 'RENAME',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lwb_sku_alias_sku_idx ON public.lwb_sku_alias (sku_id);
ALTER TABLE public.lwb_sku_alias ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.lwb_sku_alias FROM anon;
DO $p$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'lwb_sku_alias' AND policyname = 'lwb_sku_alias_read') THEN
    CREATE POLICY lwb_sku_alias_read ON public.lwb_sku_alias FOR SELECT TO authenticated USING (true);
  END IF;
END
$p$;
GRANT SELECT ON public.lwb_sku_alias TO authenticated;

-- Same words in any order, one space, upper case.
CREATE OR REPLACE FUNCTION public.lwb_sku_words(p text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $f$
  SELECT string_agg(w, ' ' ORDER BY w)
  FROM unnest(string_to_array(upper(btrim(regexp_replace(coalesce(p,''), '\s+', ' ', 'g'))), ' ')) w
  WHERE w <> '';
$f$;

CREATE OR REPLACE FUNCTION public.lwb_sku_id_of(p text)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $f$
  SELECT coalesce(
    (SELECT m.id FROM public.sku_master m WHERE upper(btrim(m.sku_name)) = upper(btrim(coalesce(p,'')))
      ORDER BY coalesce(m.is_active, true) DESC LIMIT 1),
    (SELECT a.sku_id FROM public.lwb_sku_alias a WHERE a.alias_key = upper(btrim(coalesce(p,'')))));
$f$;

CREATE OR REPLACE FUNCTION public.lwb_sku_now(p text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $f$
  SELECT coalesce((SELECT m.sku_name FROM public.sku_master m WHERE m.id = public.lwb_sku_id_of(p)), p);
$f$;

CREATE OR REPLACE FUNCTION public.lwb_sku_aliases()
RETURNS TABLE (alias_key text, sku_name text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $f$
  SELECT a.alias_key, m.sku_name FROM public.lwb_sku_alias a JOIN public.sku_master m ON m.id = a.sku_id
  WHERE upper(btrim(m.sku_name)) <> a.alias_key;
$f$;
REVOKE ALL ON FUNCTION public.lwb_sku_aliases() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lwb_sku_aliases() TO authenticated;
GRANT EXECUTE ON FUNCTION public.lwb_sku_id_of(text), public.lwb_sku_now(text), public.lwb_sku_words(text) TO authenticated;

-- Rename in SKU Master: remember the old name. Renaming back to an old name removes that alias.
CREATE OR REPLACE FUNCTION public.lwb_sku_alias_on_rename()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $f$
BEGIN
  IF upper(btrim(coalesce(OLD.sku_name,''))) IS DISTINCT FROM upper(btrim(coalesce(NEW.sku_name,'')))
     AND btrim(coalesce(OLD.sku_name,'')) <> '' THEN
    INSERT INTO public.lwb_sku_alias(alias_key, sku_id, source)
    VALUES (upper(btrim(OLD.sku_name)), NEW.id, 'RENAME')
    ON CONFLICT (alias_key) DO UPDATE SET sku_id = EXCLUDED.sku_id, source = 'RENAME', created_at = now();
    DELETE FROM public.lwb_sku_alias WHERE alias_key = upper(btrim(NEW.sku_name));
    -- Rajnigandha rate limit (landing / min / std) is kept by name: the new name gets a copy, the old row stays.
    IF to_regclass('public.lwb_sku_price_limits') IS NOT NULL THEN
      INSERT INTO public.lwb_sku_price_limits (sku_key, landing, min_rate, std_rate, updated_at, updated_by)
      SELECT upper(btrim(NEW.sku_name)), l.landing, l.min_rate, l.std_rate, now(), auth.uid()
      FROM public.lwb_sku_price_limits l WHERE l.sku_key = upper(btrim(OLD.sku_name))
      ON CONFLICT (sku_key) DO NOTHING;
    END IF;
  END IF;
  RETURN NEW;
END
$f$;
DROP TRIGGER IF EXISTS lwb_sku_alias_on_rename ON public.sku_master;
CREATE TRIGGER lwb_sku_alias_on_rename AFTER UPDATE OF sku_name ON public.sku_master
  FOR EACH ROW EXECUTE FUNCTION public.lwb_sku_alias_on_rename();

-- One-time fill: names already renamed before this file (same words in any order as exactly one SKU).
WITH used AS (
  SELECT DISTINCT upper(btrim(i.sku_name)) AS k FROM public.order_items i WHERE btrim(coalesce(i.sku_name,'')) <> ''
  UNION SELECT upper(btrim(x.sku_key)) FROM public.lwb_sku_price_limits x
  UNION SELECT upper(btrim(x.sku_key)) FROM public.lwb_rate_pack_skus x
), lost AS (
  SELECT u.k FROM used u
  WHERE u.k IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.sku_master m WHERE upper(btrim(m.sku_name)) = u.k)
), hit AS (
  SELECT l.k, min(m.id::text)::uuid AS sku_id, count(*) AS n
  FROM lost l JOIN public.sku_master m ON public.lwb_sku_words(m.sku_name) = public.lwb_sku_words(l.k)
  GROUP BY l.k
)
INSERT INTO public.lwb_sku_alias(alias_key, sku_id, source)
SELECT k, sku_id, 'SAME_WORDS' FROM hit WHERE n = 1
ON CONFLICT (alias_key) DO NOTHING;

-- Same for rate limits of SKUs renamed before this file: the current name gets a copy of the old name's limit.
INSERT INTO public.lwb_sku_price_limits (sku_key, landing, min_rate, std_rate, updated_at, updated_by)
SELECT DISTINCT ON (upper(btrim(m.sku_name))) upper(btrim(m.sku_name)), l.landing, l.min_rate, l.std_rate, now(), l.updated_by
FROM public.lwb_sku_alias a
JOIN public.sku_master m ON m.id = a.sku_id
JOIN public.lwb_sku_price_limits l ON l.sku_key = a.alias_key
WHERE btrim(coalesce(m.sku_name,'')) <> ''
ORDER BY upper(btrim(m.sku_name)), l.updated_at DESC
ON CONFLICT (sku_key) DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Check: old names now linked to their SKU.
SELECT * FROM public.lwb_sku_aliases() ORDER BY 2, 1;
