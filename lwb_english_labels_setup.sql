-- LUXURY WRIST BRAND ERP — ENGLISH ONLY LABELS (5 Nov 2026, Mohit: no Hindi words on the website)
-- Renames the one built-in Accounts head that had a Hindi word.
-- "Driver bhatta / food" -> "Driver allowance / food". Old entries keep their head (same id),
-- only the name shown changes. Skipped if the new name already exists. Safe to run again.

BEGIN;

UPDATE public.lwb_acc_categories c
   SET name = 'Driver allowance / food'
 WHERE c.kind = 'OUT'
   AND lower(btrim(c.name)) = 'driver bhatta / food'
   AND NOT EXISTS (SELECT 1 FROM public.lwb_acc_categories x
                    WHERE x.kind = 'OUT' AND lower(btrim(x.name)) = 'driver allowance / food');

COMMIT;
