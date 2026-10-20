-- Luxury Wrist Brand ERP — WhatsApp driver assignment delivery audit.
-- Run ONCE in the same Supabase project before activating the Edge Function.
-- Does NOT change order, inventory, invoice, or dispatch assignment data.
-- Message sending is performed ONLY by the deployed Supabase Edge Function.

BEGIN;

CREATE TABLE IF NOT EXISTS public.lwb_driver_whatsapp_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  assignment_id uuid NOT NULL REFERENCES public.dispatch_assignments(id) ON DELETE RESTRICT,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  fingerprint text NOT NULL CHECK (length(fingerprint) = 64),
  part_no integer NOT NULL CHECK (part_no >= 1),
  part_count integer NOT NULL CHECK (part_count >= 1),
  recipient_mobile text NOT NULL,
  status text NOT NULL DEFAULT 'sending'
    CHECK (status IN ('sending','accepted','failed','unknown')),
  meta_message_id text,
  error_message text,
  attempts integer NOT NULL DEFAULT 1 CHECK (attempts BETWEEN 1 AND 10),
  consent_confirmed_by uuid NOT NULL REFERENCES auth.users(id),
  consent_confirmed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT lwb_driver_whatsapp_part_once
    UNIQUE (assignment_id, fingerprint, part_no)
);

CREATE INDEX IF NOT EXISTS lwb_driver_whatsapp_order_idx
  ON public.lwb_driver_whatsapp_log(order_id, created_at DESC);

ALTER TABLE public.lwb_driver_whatsapp_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lwb_driver_wa_log_read ON public.lwb_driver_whatsapp_log;
CREATE POLICY lwb_driver_wa_log_read
  ON public.lwb_driver_whatsapp_log FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.user_profiles p
      WHERE p.id = auth.uid()
        AND p.active IS TRUE
        AND lower(btrim(p.role)) IN ('admin','manager','transport')
    )
  );

-- Authenticated clients can READ permitted notification statuses but
-- can NEVER forge 'accepted' or write delivery logs.
REVOKE ALL ON TABLE public.lwb_driver_whatsapp_log
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.lwb_driver_whatsapp_log TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Expect exactly one row.
SELECT 'public.lwb_driver_whatsapp_log' AS notification_log_table
WHERE to_regclass('public.lwb_driver_whatsapp_log') IS NOT NULL;
