# Rules for working on this repo

## Test site first, live only after the owner's OK (from 13 Nov 2026)

- Open every pull request against the branch **`next`**, not `main`.
  Merging into `next` updates only the TEST site
  (https://test-site.luxury-wrist-brand.pages.dev) and the TEST Supabase
  database (`.github/workflows/test-site.yml`). Live staff see nothing.
- The owner (Mohit) checks the change on the test site, logging in as the
  dummy role logins (`test.admin@lwb.test`, `test.saleshead@`,
  `test.salesman@`, `test.accounts@`, `test.godown@`, `test.transport@`,
  `test.driver@lwb.test`). Only after he writes OK: open a pull request
  `next` -> `main`. Merging that is what makes it live (SQL runs on live by
  `supabase-apply.yml`, as before).
- Do not merge to `main` directly, except a fix the owner asks to go live at
  once. Anything merged to `main` is copied into `next` automatically.
- Never edit the `test-site` branch: it is rebuilt by the workflow.
- The branch preview links Cloudflare makes for `next` and PR branches
  (`next.luxury-wrist-brand.pages.dev`, ...) still use the LIVE database.
  Only `test-site.luxury-wrist-brand.pages.dev` is the test site.
- Refresh the test database from live: Actions > "Test DB copy from live"
  (type WIPE-TEST). Copied logins get random passwords; push / cron are off.
