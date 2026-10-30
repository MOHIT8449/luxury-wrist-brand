#!/usr/bin/env bash
# Safety check for SQL files before they go to the live Supabase database.
# A file that drops a table / schema / column or truncates a table is refused
# unless it carries the line  -- lwb:allow-destructive  (added only after the
# owner has said OK in writing). Usage: supabase-sql-check.sh file.sql ...
set -euo pipefail
bad=0
for f in "$@"; do
  if grep -qi '^[[:space:]]*--[[:space:]]*lwb:allow-destructive' "$f"; then
    echo "::warning file=$f::Destructive SQL allowed by lwb:allow-destructive marker"
    continue
  fi
  hits=$(sed 's/--.*$//' "$f" | grep -inE '\b(drop[[:space:]]+(table|schema|database)|truncate|drop[[:space:]]+column)\b' || true)
  if [ -n "$hits" ]; then
    echo "::error file=$f::Destructive SQL found (drop table/schema/column or truncate). Get the owner's OK, then add the line '-- lwb:allow-destructive'."
    echo "$hits"
    bad=1
  fi
done
exit $bad
