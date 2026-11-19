#!/usr/bin/env bash
# Steps of the Mumbai move. OLD_URL / NEW_URL come from the workflow. Prints counts and errors only.
set -uo pipefail
step="${1:-test}"
W="$RUNNER_TEMP/mig"; mkdir -p "$W"
OLD_API="https://$OLD_REF.supabase.co"; NEW_API="https://$NEW_REF.supabase.co"
errs(){ grep -E 'ERROR|FATAL|psql:' "$1" | grep -v DETAIL | cut -c1-220 | head -${2:-30}; }

counts(){ # $1 url -> "schema.table rows" for public, auth, storage
  psql "$1" -Atq -F' ' -c "select format('select %L||'' ''||count(*) from %I.%I;', n.nspname||'.'||c.relname, n.nspname, c.relname)
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where c.relkind='r' and n.nspname in ('public','auth','storage') order by 1" | psql "$1" -Atq 2>/dev/null | sort
}

storage_policies(){ # old storage policies -> $W/sp.sql
  psql "$OLD_URL" -Atq -c "select format('drop policy if exists %I on %I.%I; create policy %I on %I.%I as %s for %s to %s%s%s;', policyname, schemaname, tablename, policyname, schemaname, tablename, permissive, cmd, (select string_agg(case when r='public' then 'public' else quote_ident(r) end, ', ') from unnest(roles) r), coalesce(' using ('||qual||')',''), coalesce(' with check ('||with_check||')','')) from pg_policies where schemaname='storage' order by tablename, policyname" > "$W/sp.sql"
}

case "$step" in
test)
  echo "Old tables / rows:"; counts "$OLD_URL" | awk '{t++; r+=$2} END{print t" tables, "r" rows"}'
  echo "New tables / rows:"; counts "$NEW_URL" | awk '{t++; r+=$2} END{print t" tables, "r" rows"}'
  for k in OLD_KEY NEW_KEY SUPABASE_ACCESS_TOKEN; do [ -n "${!k:-}" ] && echo "$k: set" || echo "$k: MISSING"; done
  ;;

copy)
  # 1. Dump from the old project (read only).
  supabase db dump --db-url "$OLD_URL" -f "$W/roles.sql" --role-only >/dev/null 2>"$W/d1.log" || { errs "$W/d1.log"; exit 1; }
  supabase db dump --db-url "$OLD_URL" -f "$W/schema.sql" >/dev/null 2>"$W/d2.log" || { errs "$W/d2.log"; exit 1; }
  supabase db dump --db-url "$OLD_URL" -f "$W/data.sql" --use-copy --data-only >/dev/null 2>"$W/d3.log" || { errs "$W/d3.log"; exit 1; }
  ls -la "$W" | awk '/\.sql/{print $5, $9}'
  # cron jobs and realtime tables of the old project, to make again on the new one
  psql "$OLD_URL" -Atq -c "select format('select cron.schedule(%L,%L,%L);', jobname, schedule, command) from cron.job where active" > "$W/cron.sql"
  psql "$OLD_URL" -Atq -c "select format('alter publication supabase_realtime add table %I.%I;', schemaname, tablename) from pg_publication_tables where pubname='supabase_realtime'" > "$W/rt.sql"
  storage_policies
  echo "cron jobs: $(wc -l < "$W/cron.sql"), realtime tables: $(wc -l < "$W/rt.sql"), storage policies: $(wc -l < "$W/sp.sql")"
  # 2. New project: empty its public schema and auth / storage rows, so this step can run again.
  echo "$(date +%T) wipe new"
  psql "$NEW_URL" -v ON_ERROR_STOP=1 -o /dev/null > "$W/w.log" 2>&1 <<'SQL' || { errs "$W/w.log"; exit 1; }
set lock_timeout = '30s';
\echo m1
do $$ declare r record; begin
  for r in select jobname from cron.job loop perform cron.unschedule(r.jobname); end loop;
exception when others then null; end $$;
\echo m2
drop schema if exists public cascade;
\echo m3
create schema public;
grant usage on schema public to postgres, anon, authenticated, service_role;
grant all on schema public to postgres, service_role;
alter default privileges in schema public grant all on tables to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to postgres, anon, authenticated, service_role;
\echo m4
truncate auth.users cascade;
\echo m5
do $$ begin
  if exists (select 1 from storage.objects) or exists (select 1 from storage.buckets) then
    perform set_config('storage.allow_delete_query','true',true);
    delete from storage.objects; delete from storage.buckets;
  end if;
end $$;
SQL
  grep -E '^m[0-9]' "$W/w.log" | tr '\n' ' '; echo
  # Skip data for tables the new project does not let postgres write (Supabase-managed, e.g. storage.buckets_vectors).
  psql "$NEW_URL" -Atq -c "select n.nspname||'.'||c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind in ('r','p') and n.nspname not in ('pg_catalog','information_schema','public') and not has_table_privilege(c.oid,'INSERT')" > "$W/skip.txt"
  awk -v SK="$W/skip.txt" 'BEGIN{while((getline l<SK)>0)sk[l]=1}
    /^COPY /{t=$2; gsub(/"/,"",t); if(t in sk){skip=1; print "skipped "t > "/dev/stderr"; next}}
    skip{ if($0=="\\.") skip=0; next } {print}' "$W/data.sql" > "$W/data2.sql" 2>"$W/skip.log"
  mv "$W/data2.sql" "$W/data.sql"; sort -u "$W/skip.log" | tr '\n' ' '; echo
  echo "data tables: $(grep -c '^COPY ' "$W/data.sql")"
  echo "$(date +%T) restore"
  # 3. Restore into the new project.
  psql "$NEW_URL" -q -o /dev/null -f "$W/roles.sql" > "$W/r1.log" 2>&1; errs "$W/r1.log" 5
  psql "$NEW_URL" -q -v ON_ERROR_STOP=1 -o /dev/null --single-transaction \
    -c "create extension if not exists pg_cron with schema pg_catalog; create extension if not exists pg_net with schema extensions; create extension if not exists pgcrypto with schema extensions;" \
    -f "$W/schema.sql" -c "set session_replication_role = replica" -f "$W/data.sql" > "$W/r2.log" 2>&1 \
    || { echo "::error::Restore failed"; errs "$W/r2.log"; exit 1; }
  errs "$W/r2.log" 10
  echo "$(date +%T) restored"
  psql "$NEW_URL" -q -o /dev/null -f "$W/rt.sql" > "$W/r3.log" 2>&1; errs "$W/r3.log" 5
  psql "$NEW_URL" -q -o /dev/null -f "$W/cron.sql" > "$W/r4.log" 2>&1; errs "$W/r4.log" 5
  psql "$NEW_URL" -q -o /dev/null -v ON_ERROR_STOP=1 --single-transaction -f "$W/sp.sql" > "$W/r5.log" 2>&1 && echo "storage policies applied" || { echo "::error::storage policies failed"; errs "$W/r5.log" 5; }
  # 4. Point the push webhook at the new project.
  psql "$NEW_URL" -q -o /dev/null -c "update public.lwb_push_config set project_url='$NEW_API' where id=1" 2>&1 | head -3
  psql "$NEW_URL" -q -o /dev/null -c "notify pgrst, 'reload schema'"
  echo "Restore done"
  bash "$0" verify
  ;;

verify)
  counts "$OLD_URL" > "$W/old.txt"; counts "$NEW_URL" > "$W/new.txt"
  echo "Old: $(awk '{t++; r+=$2} END{print t" tables, "r" rows"}' "$W/old.txt")"
  echo "New: $(awk '{t++; r+=$2} END{print t" tables, "r" rows"}' "$W/new.txt")"
  echo "Tables that differ (name old new):"
  join -a1 -a2 -e MISSING -o 0,1.2,2.2 "$W/old.txt" "$W/new.txt" | awk '$2!=$3' | grep -vE '^auth\.(refresh_tokens|sessions|audit_log_entries|flow_state|one_time_tokens|mfa_)' | head -40
  for f in "OLD_URL:old" "NEW_URL:new"; do u=${f%%:*}; echo "${f##*:}: functions $(psql "${!u}" -Atqc "select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'"), policies $(psql "${!u}" -Atqc "select count(*) from pg_policies where schemaname='public'"), triggers $(psql "${!u}" -Atqc "select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal"), cron $(psql "${!u}" -Atqc "select count(*) from cron.job")"; done
  ;;

storage)
  [ -n "${OLD_KEY:-}" ] && [ -n "${NEW_KEY:-}" ] || { echo "::error::OLD_SUPABASE_SECRET_KEY / NEW_SUPABASE_SECRET_KEY missing"; exit 1; }
  psql "$OLD_URL" -Atq -F$'\t' -c "select bucket_id, name, coalesce(metadata->>'mimetype','application/octet-stream') from storage.objects where name not like '%.emptyFolderPlaceholder' order by 1,2" > "$W/objs.tsv"
  echo "objects: $(wc -l < "$W/objs.tsv")"
  ok=0; bad=0
  while IFS=$'\t' read -r b n m; do
    p=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$n")
    if curl -sf -o "$W/f.bin" -H "apikey: $OLD_KEY" -H "Authorization: Bearer $OLD_KEY" "$OLD_API/storage/v1/object/$b/$p" \
      && curl -sf -o /dev/null -X POST -H "apikey: $NEW_KEY" -H "Authorization: Bearer $NEW_KEY" -H "x-upsert: true" -H "content-type: $m" --data-binary "@$W/f.bin" "$NEW_API/storage/v1/object/$b/$p"; then ok=$((ok+1)); else bad=$((bad+1)); echo "failed: $b/(file $((ok+bad)))"; fi
  done < "$W/objs.tsv"
  echo "copied $ok, failed $bad"
  ;;

functions)
  [ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || { echo "::error::SUPABASE_ACCESS_TOKEN missing"; exit 1; }
  for fn in $(ls supabase/functions); do
    [ -f "supabase/functions/$fn/index.ts" ] || continue
    supabase functions deploy "$fn" --project-ref "$NEW_REF" --use-api --yes > "$W/fn.log" 2>&1 && echo "deployed $fn" || { echo "failed $fn"; tail -3 "$W/fn.log" | cut -c1-200; }
  done
  ;;
preview)
  # Open the Mumbai preview site's login page, check it talks to the new project. Login page only (no data).
  curl -s -o /dev/null -w "new auth health: %{http_code}\n" -H "apikey: sb_publishable_YA2Pow327REqgrWPzVCZiA_nw1F32_o" "$NEW_API/auth/v1/health"
  cd "$W" && npm i -s playwright@1.49.1 >/dev/null 2>&1 && npx -y playwright@1.49.1 install --with-deps chromium >/dev/null 2>&1
  mkdir -p "$GITHUB_WORKSPACE/shots"
  cat > "$W/shot.js" <<'JS'
const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true });
  const p = await ctx.newPage(); const hits = {};
  p.on('response', r => { const u = new URL(r.url()); if (u.host.includes('supabase')) hits[u.host + ' ' + r.status()] = (hits[u.host + ' ' + r.status()] || 0) + 1; });
  for (const pg of ['login.html']) {
    await p.goto('https://claude-mumbai-switch.luxury-wrist-brand.pages.dev/' + pg, { waitUntil: 'networkidle', timeout: 60000 });
    await p.waitForTimeout(3000);
    await p.screenshot({ path: process.env.GITHUB_WORKSPACE + '/shots/' + pg.replace('.html', '') + '.png' });
  }
  console.log('supabase calls:', JSON.stringify(hits)); await b.close();
})();
JS
  node "$W/shot.js"
  ;;

policies)
  storage_policies; echo "storage policies: $(wc -l < "$W/sp.sql")"
  psql "$NEW_URL" -q -o /dev/null -v ON_ERROR_STOP=1 --single-transaction -f "$W/sp.sql" > "$W/r5.log" 2>&1 && echo "applied" || { echo "::error::failed"; errs "$W/r5.log" 5; }
  bash "$0" check
  ;;

cutover)
  # Final move: freeze the old project (maintenance ON), copy everything, open the new one.
  psql "$OLD_URL" -v ON_ERROR_STOP=1 -Atq -c "update public.lwb_maintenance set is_on=true, message='Server Mumbai shift ho raha hai. 30-40 minute mein wapas.', changed_at=now(), changed_by_name='Mumbai shift' where id=1 returning 'old maintenance on: '||is_on" || exit 1
  sleep 20
  bash "$0" copy || { echo "::error::copy failed; old project is still in maintenance"; exit 1; }
  psql "$NEW_URL" -v ON_ERROR_STOP=1 -Atq -c "update public.lwb_maintenance set is_on=false, message='', changed_at=now(), changed_by_name='Mumbai shift' where id=1 returning 'new maintenance on: '||is_on"
  bash "$0" storage
  bash "$0" check
  ;;

secrets)
  # Copy edge-function secrets (WA_* etc.) old -> new without printing values (approved by the owner).
  # A temporary function on the old project returns its own env to a one-time random token, then is deleted.
  [ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || { echo "::error::SUPABASE_ACCESS_TOKEN missing"; exit 1; }
  supabase secrets list --project-ref "$OLD_REF" -o json 2>"$W/s.log" | python3 -c 'import sys,json;[print(x["name"]) for x in json.load(sys.stdin) if not x["name"].startswith("SUPABASE_")]' > "$W/names.txt" || { tail -3 "$W/s.log" | cut -c1-200; exit 1; }
  echo "old secret names: $(tr '\n' ' ' < "$W/names.txt")"
  [ -s "$W/names.txt" ] || { echo "nothing to copy"; exit 0; }
  T="$W/exp"; mkdir -p "$T/supabase/functions/lwb-mig-export"; (cd "$T" && supabase init --force >/dev/null 2>&1 || true)
  N=$(openssl rand -hex 24); echo "::add-mask::$N"
  NAMES=$(python3 -c 'import json,sys;print(json.dumps(open(sys.argv[1]).read().split()))' "$W/names.txt")
  cat > "$T/supabase/functions/lwb-mig-export/index.ts" <<TS
const N = "$N"; const K: string[] = $NAMES;
Deno.serve((r) => r.headers.get("x-mig") === N ? Response.json(Object.fromEntries(K.map((k) => [k, Deno.env.get(k) ?? ""]))) : new Response("no", { status: 404 }));
TS
  (cd "$T" && supabase functions deploy lwb-mig-export --project-ref "$OLD_REF" --use-api --no-verify-jwt --yes) > "$W/e.log" 2>&1 || { echo "export deploy failed"; tail -3 "$W/e.log" | cut -c1-200; exit 1; }
  sleep 5; ok=0
  for i in 1 2 3 4 5 6; do curl -sf -H "x-mig: $N" "$OLD_API/functions/v1/lwb-mig-export" -o "$W/sec.json" && { ok=1; break; }; sleep 5; done
  (cd "$T" && supabase functions delete lwb-mig-export --project-ref "$OLD_REF" --yes) > "$W/del.log" 2>&1 || (cd "$T" && supabase functions delete lwb-mig-export --project-ref "$OLD_REF") >> "$W/del.log" 2>&1
  echo "temp function delete: $(tail -1 "$W/del.log" | cut -c1-120)"
  [ "$ok" = 1 ] || { echo "::error::could not read secrets"; exit 1; }
  python3 - "$W/sec.json" "$W/sec.env" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
with open(sys.argv[2],'w') as f:
  for k,v in d.items():
    if v:
      for line in v.splitlines():
        if line.strip(): print("::add-mask::"+line.strip())
      f.write(k+"="+json.dumps(v)+"\n")
print("values found: "+" ".join(k for k,v in d.items() if v))
PY
  supabase secrets set --env-file "$W/sec.env" --project-ref "$NEW_REF" --yes > "$W/ss.log" 2>&1 && echo "set on new project" || { echo "set failed"; tail -3 "$W/ss.log" | cut -c1-200; }
  rm -f "$W/sec.json" "$W/sec.env"
  echo "new secret names: $(supabase secrets list --project-ref "$NEW_REF" -o json 2>/dev/null | python3 -c 'import sys,json;print(" ".join(x["name"] for x in json.load(sys.stdin) if not x["name"].startswith("SUPABASE_")))')"
  ;;

check)
  for f in "OLD_URL:old" "NEW_URL:new"; do u=${f%%:*}; echo "== ${f##*:}"
    psql "${!u}" -Atq -F' ' <<'SQL'
select 'storage policies', count(*) from pg_policies where schemaname='storage';
select 'auth triggers', string_agg(t.tgname, ',' order by t.tgname) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('auth','storage') and not t.tgisinternal;
select 'role settings', r.rolname, array_to_string(s.setconfig, ' | ') from pg_db_role_setting s join pg_roles r on r.oid=s.setrole where r.rolname in ('authenticator','anon','authenticated','service_role','postgres');
select 'maintenance on', is_on from public.lwb_maintenance;
select 'publication', string_agg(tablename, ',') from pg_publication_tables where pubname='supabase_realtime';
select 'vault secrets', count(*) from vault.secrets;
select 'extensions', string_agg(extname, ',' order by extname) from pg_extension;
SQL
  done
  ;;

esac
