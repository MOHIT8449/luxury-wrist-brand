-- PO transport is compulsory (Mohit, 20 Nov 2026)
-- New Order now refuses to save a PO without Delivery / Self pickup / Direct vehicle (order-entry.html).
-- Old POs saved with no transport are set to DELIVERY, as Mohit asked ("jisme nahi hai usme Delivery daal dijiye").
-- Rajnigandha quick slip POs keep an empty transport on purpose (driver + vehicle are on the slip), so they are left alone.
-- An empty transport already counted as Delivery for the rate slab, so no rate check changes. Safe to run again.

BEGIN;

UPDATE public.orders o
SET transportation = 'DELIVERY'
WHERE coalesce(btrim(o.transportation), '') = ''
  AND NOT EXISTS (SELECT 1 FROM public.lwb_quick_slips s WHERE s.order_id = o.id);

COMMIT;
