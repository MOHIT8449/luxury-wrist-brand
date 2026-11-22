-- One-off (22 Nov 2026, Mohit asked): send ONE demo urgent siren to every active Admin login's phone.
-- Only a bell + phone push; no task, order or money row changes.
INSERT INTO public.erp_notifications(user_id, title, message, notification_type)
SELECT p.id, '🚨 URGENT task · DEMO siren', 'TSK-DEMO · Test siren from Claude. Tap to open the app and hear the siren + vibration.', 'TASK_SIREN'
FROM public.user_profiles p WHERE lower(btrim(p.role))='admin' AND p.active;
