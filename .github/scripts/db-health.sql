-- Read-only speed check. Only numbers and object names are printed (public repo logs).
set default_transaction_read_only = on;
set statement_timeout = '60s';
\timing on

\echo == Server ==
select version();
select pg_size_pretty(pg_database_size(current_database())) as db_size;
select name, setting, unit from pg_settings
 where name in ('max_connections','shared_buffers','effective_cache_size','work_mem','max_worker_processes','statement_timeout');

\echo == Connections ==
select coalesce(usename,'-') usr, coalesce(application_name,'-') app, state, count(*)
  from pg_stat_activity group by 1,2,3 order by 4 desc limit 25;
select count(*) filter (where state='active') active, count(*) total,
       max(extract(epoch from now()-query_start)) filter (where state='active') as longest_active_s,
       count(*) filter (where wait_event_type='Lock') waiting_on_lock
  from pg_stat_activity;

\echo == Cache hit ratio (should be > 0.99) ==
select round(sum(blks_hit)::numeric/nullif(sum(blks_hit+blks_read),0),4) as cache_hit from pg_stat_database;

\echo == Biggest tables ==
select relname, n_live_tup rows, n_dead_tup dead, pg_size_pretty(pg_total_relation_size(relid)) size,
       seq_scan, idx_scan, seq_tup_read, last_autovacuum::date, last_autoanalyze::date
  from pg_stat_user_tables order by pg_total_relation_size(relid) desc limit 25;

\echo == Most seq-scanned tables (rows read by full scans) ==
select schemaname, relname, seq_scan, seq_tup_read, idx_scan, n_live_tup
  from pg_stat_user_tables order by seq_tup_read desc limit 20;

\echo == Indexes on hot tables ==
select tablename, indexname, indexdef from pg_indexes
 where schemaname='public' and tablename in ('orders','order_items','erp_notifications','lwb_delivery_reports','dispatch_assignments','lwb_admin_order_marks','lwb_chat_messages','lwb_location_history','lwb_staff_location','user_profiles','sku_master')
 order by 1,2;

\echo == Top statements by total time (pg_stat_statements) ==
do $$ begin
  if to_regclass('extensions.pg_stat_statements') is null and to_regclass('public.pg_stat_statements') is null then
    raise notice 'pg_stat_statements not available';
  end if;
end $$;
select r.rolname, s.calls, round(s.total_exec_time/1000) total_s, round(s.mean_exec_time::numeric,1) mean_ms,
       round(s.max_exec_time::numeric) max_ms, s.rows,
       (select string_agg(distinct m[1], ',') from regexp_matches(s.query, '(?:public|"public")\.("?[a-z_0-9]+"?)', 'g') m) as objects,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 0) as q
  from extensions.pg_stat_statements s join pg_roles r on r.oid = s.userid
 order by s.total_exec_time desc limit 40;

\echo == Slowest by mean (calls > 20) ==
select r.rolname, s.calls, round(s.mean_exec_time::numeric,1) mean_ms, round(s.total_exec_time/1000) total_s,
       (select string_agg(distinct m[1], ',') from regexp_matches(s.query, '(?:public|"public")\.("?[a-z_0-9]+"?)', 'g') m) as objects
  from extensions.pg_stat_statements s join pg_roles r on r.oid = s.userid
 where s.calls > 20 order by s.mean_exec_time desc limit 30;

select stats_reset from extensions.pg_stat_statements_info;

\echo == Function stats (needs track_functions) ==
select funcname, calls, round(total_time/1000) total_s, round((total_time/nullif(calls,0))::numeric,1) mean_ms
  from pg_stat_user_functions order by total_time desc limit 30;

\echo == pg_cron jobs ==
select jobid, schedule, active, left(regexp_replace(command,'\s+',' ','g'),60) cmd from cron.job order by 1;
select jobid, count(*) runs_24h, round(avg(extract(epoch from end_time-start_time))::numeric,2) avg_s,
       round(max(extract(epoch from end_time-start_time))::numeric,2) max_s, count(*) filter (where status<>'succeeded') failed
  from cron.job_run_details where start_time > now()-interval '24 hours' group by 1 order by 1;

\echo == Realtime subscriptions ==
select count(*) realtime_subs from realtime.subscription;
select entity::text, count(*) from realtime.subscription group by 1 order by 2 desc limit 10;

\echo == RLS policies on hot tables ==
select tablename, policyname, cmd, length(qual) qual_len, left(regexp_replace(coalesce(qual,''),'\s+',' ','g'),220) qual
  from pg_policies where schemaname='public' and tablename in ('orders','order_items','erp_notifications','lwb_delivery_reports','dispatch_assignments')
 order by 1,2;

\echo == Disk / WAL ==
select pg_size_pretty(sum(size)) wal_size from pg_ls_waldir();
