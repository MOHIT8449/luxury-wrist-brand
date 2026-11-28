#!/usr/bin/env bash
# Builds the TEST copy of the website into <out dir>:
# every page and script is copied, the live Supabase URL / key are swapped for
# the TEST project's, and every page gets a small red "TEST SITE" tag so nobody
# mixes it up with the live site. Usage: test-site-build.sh <out dir>
set -euo pipefail
out=${1:?out dir}
. .github/test-site/config.env
[ -n "${TEST_SUPABASE_URL:-}" ] && [ -n "${TEST_SUPABASE_KEY:-}" ] || {
  echo "::error::TEST_SUPABASE_URL / TEST_SUPABASE_KEY are empty in .github/test-site/config.env"; exit 1; }
[ "$TEST_SUPABASE_URL" != "$LIVE_SUPABASE_URL" ] || { echo "::error::Test URL is the live URL"; exit 1; }
case "$TEST_SUPABASE_URL" in https://*.supabase.co) ;; *) echo "::error::Bad TEST_SUPABASE_URL"; exit 1;; esac

rm -rf "$out"; mkdir -p "$out"
# Website files only (no git, tests, Android project, SQL or GitHub settings).
tar --exclude=./.git --exclude=./.github --exclude=./tests --exclude=./android \
    --exclude=./node_modules --exclude='./*.sql' --exclude='./*.md' -cf - . | tar -xf - -C "$out"

esc(){ printf '%s' "$1" | sed 's/[.[\*^$/&]/\\&/g'; }
mapfile -d '' files < <(find "$out" -type f \( -name '*.html' -o -name '*.js' -o -name '*.webmanifest' -o -name '*.css' \) -print0)
sed -i -e "s/$(esc "$LIVE_SUPABASE_URL")/$(esc "$TEST_SUPABASE_URL")/g" \
       -e "s/$(esc "$LIVE_SUPABASE_KEY")/$(esc "$TEST_SUPABASE_KEY")/g" \
       -e "s/$(esc "$LIVE_SITE_URL")/$(esc "$TEST_SITE_URL")/g" "${files[@]}"

# Small fixed tag, bottom-left, never blocks a button (pointer-events none).
tag='<div id="lwbTestTag" style="position:fixed;left:6px;bottom:6px;z-index:2147483647;background:#c62828;color:#fff;font:700 11px/1 system-ui,sans-serif;padding:4px 7px;border-radius:6px;opacity:.9;pointer-events:none;letter-spacing:.5px">TEST SITE</div>'
# Only the page's own (last) </body>, not one inside a print-popup script string.
for f in "${files[@]}"; do
  case "$f" in *.html) TAG="$tag" perl -0pi -e 's{(.*)</body>}{$1$ENV{TAG}</body>}is' "$f";; esac
done
# Phone app name, so an installed test app is not taken for the live one.
[ -f "$out/manifest.webmanifest" ] && sed -i 's/"name"[[:space:]]*:[[:space:]]*"/&TEST · /; s/"short_name"[[:space:]]*:[[:space:]]*"/&TEST /' "$out/manifest.webmanifest"
printf 'This branch is made by .github/workflows/test-site.yml. Do not edit it.\n' > "$out/TEST_SITE_README.txt"

left=$(grep -rl "$LIVE_SUPABASE_URL" "$out" || true)
[ -z "$left" ] || { echo "::error::Live Supabase URL still in: $left"; exit 1; }
echo "Test site built in $out"
