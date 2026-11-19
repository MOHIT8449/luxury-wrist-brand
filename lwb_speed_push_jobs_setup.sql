-- LUXURY WRIST BRAND ERP — speed: phone push queue index (19 Nov 2026).
-- Runs by itself on merge (Supabase apply workflow). Safe to run again. Changes no data and no rules.
-- lwb_push_flush() runs every minute and looked at every row of lwb_push_jobs (5,600 rows, read in full
-- about 60,000 times so far) to find the last 15 minutes of jobs. With this index it reads only those rows.
CREATE INDEX IF NOT EXISTS lwb_push_jobs_created_idx ON public.lwb_push_jobs (created_at);
ANALYZE public.lwb_push_jobs;
