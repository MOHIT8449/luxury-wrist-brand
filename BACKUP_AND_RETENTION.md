# Backup and data retention

Mohit asked (27 Oct 2026) for a backup plan and how long to keep data. This is the plan.

## How long data is kept

- **Nothing in the ERP is deleted.** Orders, deliveries, returns, payments, purchases and notes stay in the database.
- Keep everything for **at least 6 years (72 months)**. Under GST law (CGST Act section 36, Rule 56) business records must be kept for 72 months from the due date of the annual return of that year, and shown to the officer when asked.
- After 6 years: talk to the CA first (records of a year under assessment, appeal or audit must be kept longer). Old years can then be moved to an archive backup, not just deleted.
- Staff see only open orders and today's finished orders (`lwb_staff_visibility_setup.sql`, page **Settings > Staff Data Access**). This is an internal staff access control only. Admin always sees the full history.

## Backups

| Backup | How often | Kept for | Where |
| --- | --- | --- | --- |
| Encrypted database dump (GitHub Actions `Database backup`) | Every night, 03:00 India time | 90 days | GitHub > Actions > Database backup > the run > Artifacts |
| Monthly copy | 1st of every month | 6+ years | Admin downloads the latest nightly file and saves it in Google Drive (folder "ERP Backups") and on a pendrive |
| Supabase's own backups | Daily (Pro plan only) | 7 days on Pro | Supabase Dashboard > Database > Backups |

What a dump contains: roles, database structure (tables, rules, functions) and all table data.
It does **not** contain photos (POD, return, payment, godown, market photos in Storage). Those stay in Supabase Storage.

### One-time setup (Admin)

1. Supabase Dashboard > **Connect** > **Session pooler**: copy the connection string and put the database password in it.
2. GitHub repo > Settings > Secrets and variables > Actions > **New repository secret**:
   - `SUPABASE_DB_URL` = that connection string
   - `BACKUP_PASSWORD` = a long password. Write it down and keep it safe. Without it no backup can be opened.
3. GitHub > Actions > **Database backup** > **Run workflow** once, and check the run is green with one file under Artifacts.

GitHub stops scheduled runs of a repo with no commits for 60 days. If that happens, Actions shows a button to turn it on again.

### Restore test (every month, 10 minutes)

Open a backup to be sure it works:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in lwb-db-YYYY-MM-DD.tar.gz.enc -out backup.tar.gz   # asks BACKUP_PASSWORD
tar xzf backup.tar.gz   # roles.sql, schema.sql, data.sql
```

To restore after a disaster, restore into a **new** Supabase project, never over the live one:

```bash
psql --single-transaction --variable ON_ERROR_STOP=1 \
  --file roles.sql --file schema.sql \
  --command 'SET session_replication_role = replica' --file data.sql \
  --dbname "<new project's connection string>"
```

Then check order counts against the old project before pointing the website to the new one.
