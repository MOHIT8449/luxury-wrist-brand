-- temp tables only below; nothing real is written
set statement_timeout = '120s';
\echo == System statements (text start) ==
select r.rolname, s.calls, round(s.total_exec_time/1000) total_s, round(s.mean_exec_time::numeric,1) mean_ms, round(s.max_exec_time::numeric) max_ms,
       left(regexp_replace(s.query,'\s+',' ','g'),140) q
  from extensions.pg_stat_statements s join pg_roles r on r.oid=s.userid
 where r.rolname in ('supabase_admin','authenticator','postgres') order by s.total_exec_time desc limit 12;
\echo == 60s live sample: statement time added in the last minute ==
create temp table s0 as select queryid, userid, calls, total_exec_time from extensions.pg_stat_statements;
create temp table act(n int, state text, wait text, obj text);
do $$ declare i int; begin
  for i in 1..60 loop
    insert into act select i, state, coalesce(wait_event_type||':'||wait_event,'cpu'),
      (select string_agg(distinct m[1], ',') from regexp_matches(query, '(?:public|"public")\.("?[a-z_0-9]+"?)', 'g') m)
      from pg_stat_activity where state='active' and pid<>pg_backend_pid() and backend_type='client backend';
    perform pg_sleep(1);
  end loop; end $$;
select r.rolname, s.calls-coalesce(s0.calls,0) calls_1m, round((s.total_exec_time-coalesce(s0.total_exec_time,0))::numeric) ms_1m,
       (select string_agg(distinct m[1], ',') from regexp_matches(s.query, '(?:public|"public")\.("?[a-z_0-9]+"?)', 'g') m) objects
  from extensions.pg_stat_statements s join pg_roles r on r.oid=s.userid
  left join s0 on s0.queryid=s.queryid and s0.userid=s.userid
 where s.total_exec_time-coalesce(s0.total_exec_time,0) > 20
 order by 3 desc limit 30;
\echo == Active backends seen per second (sample) ==
select count(*) samples_with_active, round(count(*)/60.0,2) avg_active, max(c) from (select n, count(*) c from act group by n) x;
select wait, obj, count(*) from act group by 1,2 order by 3 desc limit 15;
