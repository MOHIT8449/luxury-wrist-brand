-- LUXURY WRIST BRAND ERP — CASH HANDOVER ONLY TO THE 3 SALES HEADS + ACCOUNTS (Mohit, 28 Nov 2026)
--
-- Mohit: a cashier may hand the cash box only to our Sales Heads and Accounts (Yogesh bhai). Not to Admin for now:
-- Admin never counts the notes. In the night the person holding the cash (e.g. Yogesh) confirms it and gives it
-- to Admin with Close Day, as before. Admin can still tick himself again later in "⚙ Who can take cash".
-- Only the list (lwb_acc_cash_people) changes; no money, holders or old handovers are touched.

BEGIN;

-- take Admin (and any other role) off the list
DELETE FROM public.lwb_acc_cash_people c
WHERE NOT EXISTS (SELECT 1 FROM public.user_profiles p WHERE p.id = c.user_id AND p.active = true
                  AND lower(btrim(p.role)) IN ('manager','accounts'));

-- every active Sales Head and Accounts login is on the list
INSERT INTO public.lwb_acc_cash_people (user_id, sort)
SELECT p.id, 100 + row_number() OVER (ORDER BY lower(btrim(p.role)) = 'accounts', p.full_name)
FROM public.user_profiles p
WHERE p.active = true AND lower(btrim(p.role)) IN ('manager','accounts')
ON CONFLICT (user_id) DO NOTHING;

COMMIT;

-- Result: the people who may take the cash now (should be the 3 Sales Heads + Accounts, no Admin)
SELECT p.full_name, lower(btrim(p.role)) AS role FROM public.lwb_acc_cash_people c
JOIN public.user_profiles p ON p.id = c.user_id ORDER BY c.sort, p.full_name;
