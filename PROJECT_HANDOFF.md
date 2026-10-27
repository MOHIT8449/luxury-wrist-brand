# LUXURY WRIST BRAND ERP — Project Handover

**Checkpoint:** 21 October 2026 (Asia/Kolkata)
**Purpose:** Continue the same ERP project from a new ChatGPT conversation without restarting or losing the agreed requirements.
**Status:** Active development / verification. Do not assume all modules are completed or fully tested.

## Source and infrastructure

- GitHub source: https://github.com/MOHIT8449/luxury-wrist-brand
- Deployed website: https://luxury-wrist-brand.pages.dev
- Database and authentication: Supabase (project slug `txkbhadzdbxpieunfvox`)
- Static HTML + JavaScript frontend deployed from GitHub through Cloudflare Pages.
- Check the latest code in GitHub and screenshots / real Supabase results before claiming anything is working.
- **Never put Supabase service-role keys, Twilio Auth Tokens, Meta tokens, passwords or OTPs in GitHub or chats.**
- Staff emails, personal telephone numbers and private business records are intentionally omitted from this public repo handover.

## Non-negotiable user requirements

- Explain in **Hindi/Hinglish**, with **one or two exact steps at a time**; user generally sends screenshots after each step.
- **Tally remains a separate, independent accounting system.** Do not import or paste Tally data into this ERP, do not generate an official GST/Tally invoice in this ERP and do not sync Tally without explicit new approval.
- ERP serves office staff according to Admin-assigned permissions. Accounts role is **view-only for core operational records**, while any existing internal ERP bill interface is **not a statutory invoice**. Validate actual RLS/RPC access before expanding any editing rights.
- Never create fake sales, delivery, stock, return or cash/payment entries in production merely for testing.
- Every staff member uses their own ERP login. Auth users are created by Admin; no public self-signup.
- For a driver: assigned PO must match the **same Indian mobile number** saved with the driver's ERP profile and saved dispatch assignment; do not match by name alone.
- Warehouse/order flow: Salesman PO → Sales Head approve/modify → assign driver, vehicle and loading person → print → Dispatch actual loading → Accounts view and Tally bill separately → Driver delivery/POD/collection report → Office payment verification → Party Ledger/Outstanding → Returns/damage/stock management.
- UOM: **UOM1 = Cases**, **UOM0 = loose pieces**; rates are per case. SKU Master stores `pcs_per_case`, unit weight per case, and optional cases per pallet. Pallet/CS selection in sales order; manager can adjust approved quantity/rate/unit weight when reviewing PO.
- Driver collection is **report-only** until separately verified and posted by authorized Office staff. Do not automatically affect Tally, outstanding, stock or ledgers based only on a driver report.

## Existing website modules and important source files

- `login.html`: Email + password working; Mobile SMS OTP tab exists but **not operational** pending SMS provider configuration and phone registration in Supabase Auth.
- `dashboard.html`: role-based channel/dashboard; Admin User Permissions, Add New User link, Driver role and phone mapping.
- `order-entry.html`: Sales PO with Party Master, SKU, case/pallet quantity, rate, weight, transport choice.
- `warehouse-orders.html`: Sales Head review, approve/modify, Driver/Vehicle/Loading Person allocation and PO print.
- `loading-dispatch.html`: Dispatch/loading recording.
- `transport-allocation.html`: transport assignment view.
- `accounts-invoice.html`: view loaded PO; internal ERP bill references, **separate from Tally**.
- `customer-master.html`, `supplier-master.html`, `sku-master.html`: masters.
- `opening-stock.html`, `goods-inward.html`: stock functions; verify SQL/live behavior before recording material.
- `sales-return.html`, `credit-note.html`: return/credit functions; full ledger integration not yet verified.
- `group-party-loading.html`: optional group loading.
- `driver-delivery.html`: Driver PO / Delivery Status / POD / Collection Report UI.
- `README_DRIVER_DELIVERY.md`: further Driver Module details and safeguards.

## Driver & Delivery: latest verified progress

1. `lwb_driver_delivery_setup.sql` ran in Supabase and showed **two results**: `delivery_reports_table` and `pod_private_bucket`. Private image bucket and driver reporting structures have been created.
2. A driver Auth user was created with Email login, given **DRIVER** role and saved Indian mobile in Dashboard; the Dashboard displayed a success confirmation for both role and phone mapping.
3. Initially, `user_profiles_role_check` rejected `driver`. The fix `lwb_allow_driver_role_fix.sql` was run; the subsequent assignment succeeded.
4. Driver Delivery page was accessible, but a screenshot still showed **Connecting to ERP / zero orders**. This is NOT verification of successful loading. Need to check whether list completes or errors and ensure that a *real*, assigned, actually loaded PO exists for this driver.
5. Sales Head's Driver dropdown originally only showed historical `dispatch_assignments`. This made the newly created driver invisible until first assignment.
6. Protected SQL function `lwb_sales_head_active_drivers()` was created in `lwb_sales_head_driver_directory.sql` and successfully executed in Supabase; screenshot confirmed one function row.
7. **Current GitHub `warehouse-orders.html` has now been verified to call `db.rpc("lwb_sales_head_active_drivers")` and merge active ERP DRIVER profiles with historic dispatch driver/vehicle selections.** For matching phone numbers, active ERP profile names take priority over old historical driver names. Browser dropdown behavior after deployment is **NOT YET CONFIRMED by screenshot**.

8. `lwb_driver_list_assigned_orders()` already exists in Supabase (verified 23 Oct 2026). Its live definition is now saved in `lwb_driver_assigned_orders_setup.sql` for record; no need to run it.
9. Sales Head and Transport screens now only accept a valid 10-digit Indian Driver Mobile and save it as 10 digits, because the Driver Portal matches orders by this number.

### Immediate NEXT STEP (high priority)

- With Admin/Sales Head login, open https://luxury-wrist-brand.pages.dev/warehouse-orders.html, perform a HARD REFRESH, open an **approved, not-yet-loading** PO, and click Driver Name dropdown.
- Check that the new active ERP driver appears and that selecting it fills the mapped driver mobile. If absent, read the on-page directory warning, browser console and latest GitHub code/RPC; debug without guessing.
- **Safety:** An older historical dispatch entry may use the same mobile number as the newly created Driver user. Inspect real assignment ownership; reusing a number could expose historic orders to the new login due to phone-only matching. Do not silently assume all old assigned POs belong to the newly provisioned Driver.
- Assign a real PO with correct driver+vehicle+loading person; only after actual loading confirm that driver's portal shows it. Do not fabricate orders or receipt data.
- Confirm independent authenticated driver session (new/incognito browser) rather than Admin's cached session.
- If portal remains stuck on `Connecting to ERP...`, inspect its initialization and the `lwb_driver_list_delivery_orders` RPC rather than claiming there are simply no POs.

## SMS and WhatsApp status (pending)

- User created a **Twilio Limited Trial** account, but its Messaging Services page showed **Upgrade** to create/manage service. User **explicitly decided NOT to upgrade** now.
- Supabase Phone Provider was toggled on but Twilio credentials and SMS sending configuration were not supplied; Supabase Auth user list showed no phones registered. Mobile OTP sign-in gave "Signups not allowed for otp". Continue using working **Email + Password** login.
- WhatsApp Business API automated driver notifications are **not live/confirmed**. Meta setup had account restrictions/delays. Never claim a WhatsApp was delivered just because an assignment was saved. WhatsApp integration work is postponed.
- Do not confuse Twilio SMS OTP (login) with WhatsApp Business API (outbound loading notifications).

## Workflow modules remaining to complete, in order

1. **Driver & Delivery** — assigned loaded PO, party details/address, delivery status, private POD photo, driver collection report; verify end-to-end and security.
2. **Payment Collection** — Office-verified cash/UPI/bank/cheque, pending, approval audit and cash rules. Never automatically post from driver reports.
3. **Party Ledger & Outstanding** — party-wise balance, receipts and credit/debit adjustments in independent ERP, no Tally import.
   - Built (branch `party-ledger`): `lwb_party_ledger_setup.sql` + `party-ledger.html` + `payment-collection.html`. Checked live 23 Oct 2026: `lwb_payment_collections` and `lwb_invoice_outstanding` were NEVER created (Phase 1 SQL not run), so this one script also creates them. Debit = ERP Internal Bills + old tax_invoices + optional Opening Balance (Admin only). Credit = Admin-POSTED payments + APPROVED driver returns + approved sales returns. Driver returns are approved / rejected on `driver-returns.html` (`lwb_driver_return_review_setup.sql`, Admin or Accounts; manager/warehouse view only). Approval only changes the ERP ledger; stock is not moved.
4. **Sales Return & Damage** — saleable restock; leakage/breakage to damaged/destroy; gasless to company return; same-bill deduction vs subsequent credit note and ledger settlement. Return from same party, proper original sale price, age and approval checks.
5. **Live Inventory & Stock** — inward, outward, reserve, returns, closing case/PCS by main warehouse; preserve movement audit trail and prevent fake stock.

## Safe handoff protocol for future ChatGPT sessions

- Read **this file** and `README_DRIVER_DELIVERY.md` first.
- Fetch relevant current GitHub HTML/SQL before code modifications; do not assume yesterday's code is still current.
- Test JS syntax and check actual database constraint/schema names before posting migrations.
- Deploy using GitHub commits. **GitHub commit != live Cloudflare deploy != successful functional test**. Ask for a screenshot of actual browser and database results.
- Do not perform live write operations with fake data to test.
- Guide the user with one or two steps at a time and stop for screenshot.

**New chat kickoff text:**
"Continue our LUXURY WRIST BRAND ERP project. Read `PROJECT_HANDOFF.md` from GitHub repo `MOHIT8449/luxury-wrist-brand`. The Driver/Delivery SQL is complete; DRIVER role and mobile mapping were saved; `lwb_sales_head_active_drivers` RPC ran successfully; `warehouse-orders.html` now merges active ERP drivers into the dropdown. First verify the new driver's name in Sales Head dropdown, correct matching mobile and actual loaded PO in Driver Portal. Email login only; Twilio/WhatsApp postponed. Guide me step by step in Hindi."

## Sales Team module (25 Oct 2026)

- SQL: `lwb_sales_team_setup.sql` (run once). Roles unchanged: Sales Head = MANAGER, salesmen = SALES.
- `sales-team.html` (Admin + Sales Head): set each SALES login as FIELD (own parties only) or OFFICE (all parties), assign parties, per-salesman SKU visibility (ONLY / HIDE), monthly targets (company + per salesman), morning plan notes and due days.
- `sales-tracking.html` (Admin + Sales Head): target vs achievement, daily work per salesman, SKU sales and margin (rate − Rate & Scheme landing excl. ROI), salesman SKUs, party-wise sales, no-order parties (2 / 3–4 / 5–9 / 10+ days / never).
- `my-sales.html` (SALES): today's plan, own target, own parties, orders and SKUs.
- FIELD salesman limits are database RLS (restrictive policies on `lwb_customer_master`, `orders`, `order_items`, `sku_master`) and `lwb_ledger_viewer()` excludes FIELD salesmen. A SALES user not yet set up keeps the old access.
- Morning bell (`SALES_PLAN`): pg_cron job `lwb_morning_sales_plan` at 8:30 IST when pg_cron is enabled; otherwise created when the salesman opens the Dashboard / My Sales, or by "Send today's plan".
- PO numbers now come from `lwb_next_order_no()` (field salesmen cannot read all orders).

## Logins by mobile or email (25 Oct 2026)

- SQL: `lwb_user_login_setup.sql`. Manage Users > Add New User creates the Supabase Auth user directly (Admin sets the password; no email confirmation). A user with no email gets the internal login email `m<mobile>@staff.lwb-erp.in`.
- Login page has one field: mobile number or email. A mobile is mapped to its login email by `lwb_login_email(login, password)`, which answers only when the password is correct and locks a mobile for 15 minutes after 8 wrong tries.
- Login mobile = `user_profiles.mobile` (also the driver mobile); it must be unique. Admin can change mobile / password per user. The SMS OTP tab was removed (it was never live).
- Phone: PO Entry SKU lines are cards under 640px; `manifest.webmanifest` lets staff "Add to Home screen".

## Godown Report (26 Oct 2026)

- SQL: `lwb_godown_report_setup.sql`. Godown managers use the WAREHOUSE role (shown as "WAREHOUSE — Godown Manager / Dispatch"), so they keep every warehouse screen.
- `godown-report.html` (admin, manager, warehouse): Vehicle Arrived (→ loading/unloading → done / left), Damage / Leakage (SKU, cases, pcs, photo in private bucket `lwb-godown-photos`), Staff Absent, Other Issue. Each report notifies active Admin + MANAGER users; they mark Seen / Action Taken and the reporter is notified. Reports never change stock.

## Per-user page access (26 Oct 2026)

- SQL: `lwb_user_page_access_setup.sql` (after the login SQL). Table `lwb_user_page_access(user_id, hidden text[])` stores only pages unticked for one user; saved by `lwb_admin_set_page_access(user_id, hidden)` (Admin only; Manage Users can never be hidden from an Admin).
- Manage Users > Pages: tick boxes for the user's role menu (role default = all ticked). Pages of other roles are greyed out; giving a page outside the role also needs the database rules for that page opened, so it is not offered yet.
- `erp-shell.js` drops hidden pages from the menu, dashboard Quick Access and search, and sends a user who opens a hidden page to their first open page. The list is cached in localStorage (`lwbHiddenPages`, filled at login) and re-read on every page. Hiding is a screen/menu control; data rules still follow the role.

## Salesman order follow-up (26 Oct 2026)

- SQL: `lwb_sales_order_followup_setup.sql` (after the sales team SQL).
- My Sales > My Orders (and two Dashboard tiles for SALES) use `lwb_my_orders(days)`: own orders, plus a Field salesman's party orders, with stage (waiting for approval → approved → driver assigned → loading → loaded / billed → delivered / part / not delivered, or cancelled with reason), driver/vehicle and the delivery report.
- Edit: `lwb_sales_edit_order(order_id, [{id, cases}])` lets only the salesman who created the order change cases or remove lines while it waits for approval (same pending list as PO Approval). Totals are recalculated, a pallet line becomes a cases line, and Admin + MANAGER get an `ORDER_EDITED` bell. After approval only the Sales Head changes it (PO Approval page, as before).
- Cancel: `lwb_sales_cancel_order(order_id, reason)` for the creator while pending; reason required. Trigger `trg_lwb_notify_order_cancelled` sends `ORDER_CANCELLED`: salesman cancelled → Admin + MANAGER; someone else cancelled → the salesman, with the reason.
- Delivery bell: trigger `trg_lwb_notify_order_delivered` on `lwb_delivery_reports` sends `ORDER_DELIVERED` / `ORDER_PARTIAL` / `ORDER_NOT_DELIVERED` to the creating salesman and the party's Field salesman.

## Salesman PO Entry rules (26 Oct 2026)

- SQL: `lwb_order_entry_rules_setup.sql`. `lwb_is_field_salesman()` now means "SALES login not set up as OFFICE", so a salesman not set up yet also sees and orders only his assigned parties (party RLS, order RLS, party rates, ledger).
- `lwb_party_last_rates` also returns `slab3_then` (Slab 3 on the bill date, from `lwb_rate_history` by pack name). PO Entry rate = last bill rate + (Slab 3 now − Slab 3 then); slab rate when the party was never billed.
- PO Entry for SALES hides "Rate kis slab se bhare" (stays Auto), Vehicle Number and the Party Master link.

## Salesman on Party Master (26 Oct 2026)

- SQL: `lwb_party_salesman_assign_setup.sql`. `lwb_assign_parties` accepts any active SALES login; one not in `lwb_salesmen` yet is added as FIELD on the first assignment.
- Sales Team Setup > Party Assignment lists every active SALES login ("not set up" until the first party).
- Party Master: "Salesman (whose party)" in the add/edit form, a Salesman column in the list, a salesman picker for Bulk Add, and a "Salesman" column in Excel export / template / import (name or login mobile; OFFICE = none; blank keeps the saved one). All save through `lwb_assign_parties`.

## Salesman phone Order Entry (26 Oct 2026)

- `order-entry.html` only, no SQL. For a SALES login, Order No, Date, Company and Sales Person are hidden (all filled automatically; Sales Person shows if the profile has no name).
- Phone (≤760px, sales): Transportation is three tap buttons (tap again to clear), one short card per SKU (Pallet only for Direct Vehicle), a dashed "+ Add SKU" under the list, and a fixed bar above the bottom nav with ₹ total, SKU/cases and Submit. Share / Print / Excel is folded under one link. Inputs use 16px so iPhone does not zoom.
- All roles: "Party's usual SKUs" buttons (from `lwb_party_last_rates`) fill the next empty SKU line with one tap.

## Party details rule + salesman new party (26 Oct 2026)

- SQL: `lwb_party_details_rule_setup.sql`. Party details are complete with a 10-digit mobile, a billing address and a PAN or GSTIN (`lwb_party_missing`).
- Trigger `trg_lwb_orders_party_details` (BEFORE INSERT on orders, SALES logins only): counts the order in `lwb_customer_master.kyc_orders_used` while details are missing and refuses it once that reaches the limit (`lwb_customer_master.kyc_free_orders`, else `lwb_sales_settings.kyc_free_orders`, default 3). Admin / Sales Head orders are not counted.
- PO Entry: a banner with "Fill details" (`lwb_sales_fill_party_details` fills empty fields only) and "+ Add new party" in the party list (`lwb_sales_create_party`: full details needed, duplicate names refused, assigned to the salesman, PARTY_CREATED notification to Admin / Sales Head).
- PO Entry: one line per SKU (the SKU list leaves out SKUs already on another line; Submit also checks).
- Default limit: Sales Team Setup > Morning Plan. Per-party limit and "Details missing only" filter: Party Master.

## Order weight and minimum order weight (26 Oct 2026)

- SQL: `lwb_min_order_weight_setup.sql` (`lwb_sales_settings.min_order_kg`, default 0 = none; `lwb_customer_master.min_order_kg` per party, blank = default; `lwb_save_min_order_kg`).
- PO Entry: weight per SKU line (salesman too), an "Order weight" box with a progress bar to the minimum, tons in the phone Submit bar. Below the minimum it only shows in orange (no confirm, no block: the minimum is a guide). Weight comes from SKU Master KG per case; SKUs without it are flagged.
- Default minimum: Sales Team Setup > Morning Plan. Per party: Party Master > Edit.

## Salesman modifies the whole order + Today / Month totals (26 Oct 2026)

- SQL: `lwb_sales_modify_order_setup.sql` (`lwb_sales_modify_order(order_id, transportation, items)`): creator only, pending only; keeps rows of SKUs still on the order, deletes removed ones, inserts new ones, recalculates totals, ORDER_EDITED bell to Admin / Sales Head with the change list.
- My Orders > "Modify Order" opens `order-entry.html?edit=<id>` with the order as taken (party and date locked, rates kept). The old inline "Change Cases" is gone (`lwb_sales_edit_order` is no longer called).
- Dashboard for SALES: "Today's Sales" and "This Month's Sales" (₹ and order count) plus the not-delivered / delivered tiles; the party-wise recent orders list and status pills are not shown to salesmen.

## Dashboard focus messages + Outside Market Stock (26 Oct 2026)

- SQL: `lwb_announcements_market_report_setup.sql`.
- Focus messages: `lwb_announcements` (message, optional SKU, `valid_until`, NULL = until removed). Admin / Sales Head post from the Dashboard ("📢 Post focus message": Today / 3 days / 1 week / Until removed) with `lwb_post_announcement`, remove with `lwb_remove_announcement`. Every role sees live messages at the top of the Dashboard; each active user gets an ANNOUNCEMENT bell.
- Outside Market Stock (`market-report.html`, menu Sales, roles admin / manager / sales): outlet, SKU, cases, outside rate, note, up to 3 photos (outlet / stock / vehicle) in private bucket `lwb-market-photos` (folder = uid). All fields optional, at least one needed (`lwb_add_market_report`). MARKET_REPORT bell to Admin / Sales Head; they mark Seen / Action Taken (`lwb_review_market_report`), salesman gets MARKET_REVIEW bell. Salesmen see only their own reports.
- Bell (`erp-operations-notifications.js`): ANNOUNCEMENT and MARKET_REPORT pop up once per device (localStorage `lwbPopped`) while unread and under 2 days old; MARKET_REPORT popup has "Open report".

## Party Assignment Excel import / export (26 Oct 2026)

- Sales Team Setup > Party Assignment: "⬇ Export Excel" (Party Name, City, Salesman for every party; Help sheet lists salesmen and mobiles) and "⬆ Import Excel".
- Import matches Party Name (case / spaces ignored); Salesman = name or login mobile, OFFICE = no salesman, blank = keep. Shows a summary (per salesman counts, rows not found) and assigns only after confirm, via `lwb_assign_parties` in batches of 200. No new SQL.

## Live stock + Goods in Transit on PO Entry (26 Oct 2026)

- SQL: `lwb_live_stock_po_setup.sql`.
- `lwb_po_stock()` returns per SKU: godown cases (floor of saleable_pcs / pcs_per_case from the existing `lwb_live_stock` view) and open transit cases. Empty for roles not allowed.
- Who sees stock: `lwb_sales_settings.stock_view_roles` (default admin, manager, warehouse; Admin always), ticked in Sales Team Setup > Morning Plan (`lwb_save_stock_view_roles`).
- Goods in Transit (`stock-transit.html`, Inventory menu, admin / manager / warehouse): `lwb_stock_transit` entries (truck / invoice no., expected date, SKU lines) via `lwb_add_stock_transit`; "Received in godown" / "Cancel" via `lwb_close_stock_transit`. Receiving does NOT add stock: Goods Inward still does that. The PO Maker in-transit numbers live only in that browser's localStorage and are not used.
- PO Entry: light text under each SKU "Godown · On the way · Total CS" (total turns red when the order is bigger), the empty Cases box shows "Stock N CS", and the SKU list shows stock as option labels. Refreshes every 5 minutes.

## Tick any page for any user (26 Oct 2026)

- SQL: `lwb_user_extra_pages_setup.sql` (`lwb_user_page_access.extra`, `lwb_has_page(page)`, `lwb_admin_set_pages(user, hidden, extra)`). Its last SELECT lists database rules that still check only the role.
- Manage Users > Pages: own-role pages untick → `hidden`; other-role pages tick → `extra` ("Tick every page" button). Old `lwb_admin_set_page_access` is used if the SQL is not run (other-role ticks then disabled).
- Shell: `menuFor(role,hidden,extra)`; `ERPShell.pageRole / pageRoleFresh(role)` = the role a page treats the user as (his own, or for a ticked other-role page that page's first non-admin MENU role). Guards in every page use it; `ERPShell.mount` still gets the real role. Data-auto pages use `page-role.js` (`lwbPageRole`). `LWBSales.start` returns `role` (page role) and `realRole`.
- Database: a ticked page passes these checks too: `lwb_sales_head` (sales-team / sales-tracking), `lwb_po_entry_user`, `lwb_godown_user`, `lwb_market_reporter`, `lwb_stock_keeper`, `lwb_can_view_stock`, `lwb_pc_user`, `lwb_sp_user`. Core tables (orders, dispatch, payments, bills, returns, inventory movements) have base RLS created outside this repo: those still check the role until updated.

## Tally Bill Check and private Cashbook (26 Oct 2026)

- SQL: `lwb_cashbook_tally_check_setup.sql` (after `lwb_user_extra_pages_setup.sql`). Menu group **Accounts**.
- `tally-check.html` (Admin + Accounts): Mohit asked (26 Oct 2026) to check every night that each dispatched PO has a Tally bill. Accounts chooses the Tally Sales Register export (Excel / CSV, several files allowed); it is **read in the browser only, Tally rows are not saved in the ERP**. Only Tally party name → ERP party links are saved (`lwb_tally_party_map`). Dispatched POs come from `lwb_tally_check_orders(from, to)`: status loaded / invoiced / dispatched / delivered, dated by `dispatch_assignments.loading_completed_at` (IST). ERP amount = internal ERP bill, else loaded qty × rate, else order total. The register has no PO number (Narration empty), so matching is party + date (bill dated dispatch day or next day) + amount; Tally = ERP or ERP + GST 5/12/18/28/40% counts as matched (Mohit did not say yet whether Tally amounts include GST). Several POs / bills for one party and day (Tally makes one bill per brand: voucher types COCA COLA, RAJNIGANDHA) are compared as day totals. Results: Bill missing in Tally, Amount differs, Tally bill with no ERP PO, Matched; Excel export.
- `cashbook.html` = Mohit's own Cashbook app (uploaded 26 Oct 2026), **kept the same on purpose** ("same to same"); do not redesign it. Only change: data lives in `lwb_cashbook` (one JSON row with a version) instead of browser localStorage, through `cashbook-erp.js`. The table has no grants; only `lwb_cashbook_*` SECURITY DEFINER functions, which open for an active Admin (unless Cashbook is unticked for him) or a user ticked "Cashbook" in Manage Users > Pages. A save sends the version it started from; if someone (or another tab) saved first, both changes are merged in the browser (books / entries / parties by id; the same field changed on both: this screen wins) and saved again (26 Oct 2026: Mohit's new books went missing with two Cashbook tabs open). Other users' changes appear within 20 seconds. Its short codes / 2006 year display stay. Passwords: Mohit asked (26 Oct 2026) for ONE password only, so setup asks one password and it opens everything with admin rights; passwords 2 / 3 and the separate admin login were removed (an old password 1 keeps working). The ERP still keeps a copy before the books are ever emptied (and one every 15 minutes, newest 300), and an ERP Admin who is also Cashbook admin restores it from Cashbook > Backup > Earlier copies. Moving old data: Backup in the old Cashbook file, then Restore in the ERP Cashbook.
- Driver cash in the Cashbook (26 Oct 2026, `lwb_cashbook_driver_cash_setup.sql`): a book's "Driver cash (ERP)" button lists driver-reported payments (`lwb_delivery_reports.cash_reported`, last 15 days) not yet in the Cashbook. "Add as Cash In" opens the normal Cash In form filled (amount, date, party via the Cashbook's Tally name links, mode, remark with driver + PO); the saved entry keeps `erpRef` = report id so it leaves the list. "Skip" stores the id in `state.erpSkip`. Read-only on the ERP side: driver reports, payments and ledgers are not changed.
- Stronger Cashbook + Tally queries (26 Oct 2026, `lwb_cashbook_secure_setup.sql`, run after the two files above). Mohit asked for full history, a private link, no one else seeing the page, and Tally duplicate / missing popups kept as queries until both sides are verified.
  - History: every save is diffed in the database against the data before it (`lwb_cashbook_audit_diff`) into `lwb_cashbook_audit` (who, when, action added / changed / verified / reported / change requested / request rejected / deleted / book added / book deleted, changed fields, old and new entry). No grants on the table; read only through `lwb_cashbook_history(key, party, entry)`. Cashbook shows it under **History** (filter by party, search), **Change history** in the party ledger, and **History** in an entry's window. Empty boxes saved as "" / 0 / false are not counted as changes.
  - Secret link: every `lwb_cashbook_*` function now takes `p_key`; the versions without a key are dropped. After Admin uses **Secret link** in the Cashbook (ERP Admin only), only a SHA-256 of the key is stored in `lwb_cashbook.link_key_hash` and nothing answers without the key (shows "Private page"). The page takes the key from `#k=...`, remembers it in localStorage `lwbCbKey` for that browser (refresh / new tab keep working; pasting the link into an open Cashbook tab reloads it) and removes it from the address bar. Lost link: in the SQL Editor `UPDATE public.lwb_cashbook SET link_key_hash = NULL WHERE id = 1;` then make a new one. Cashbook is `hide:1` in the ERP menu (not in menu, search or dashboard; still tickable in Manage Users).
  - Screen: name + time watermark over the page, page blurs when the tab is not in front, Cashbook locks itself (password again) after 5 minutes without use. Screenshots cannot be blocked in a web page; the watermark shows whose screen it was.
  - Tally Bill Check: rows that are exact copies (same bill no., party, date, amount, voucher type) are removed and shown in a popup; the same bill no. on different bills (same voucher type and financial year) and same party/date/amount without bill no. are shown but kept. After each check a popup gives the counts, and every non-matched row is synced to `lwb_tally_queries` (`lwb_tally_queries_sync`): key `po|<PO nos>` or `bill|<party>|<vtype>|<FY>|<bill no>`. Queries in the checked dates that are no longer found are closed "Matched in the check of …" (they reopen if they show again); Admin-closed ones stay closed. **Open queries** card: Accounts / Admin write the reason (status "Reason given"), only Admin closes ("Verified by Admin").
- Party Master parties in the Cashbook (26 Oct 2026, Mohit said YES, `lwb_cashbook_erp_parties_setup.sql`): when the Cashbook opens it reads `lwb_customer_master.customer_name` through `lwb_cashbook_erp_parties(p_key)` and adds names it does not have (compared without case / punctuation) to the Cash In party list, marked `erp: true`. `state.erpParties` keeps the names already handled, so a party deleted in the Cashbook is not added again.
- Cashbook code word (26 Oct 2026, Mohit asked for a short code like 401 instead of the long link; `lwb_cashbook_code_setup.sql`): the secret-link key can now be a 3–64 character code. Admin sets it in Cashbook > **Code word**. It is typed in the ERP top-bar **Module Search** + Enter (no module matches it, so `erp-shell.js` opens `cashbook.html#k=<code>`), or in the box on the Cashbook "Private page". The browser then remembers it. Server-side check is unchanged (`lwb_cashbook_ok`, SHA-256 only); the login must still be Admin / ticked. A short numeric code is easy to guess for someone who already has Admin access; Mohit chose convenience.

## Driver phone view and return photos (26 Oct 2026)

- `driver-delivery.html` on a phone: short order cards (tap a card to open), bottom bar To Deliver / Loading / Delivered / All with counts, compact popup, fixed Submit bars that step aside while the keyboard is open (`erp-shell.js` `watchKeyboard()`, now also used for the DRIVER role).
- Return tab: each SKU line is a card (SKU, CS + PCS + Reason, rate, amount). 1 to 10 photos are required (📷 Take Photo opens the camera, 🖼 Gallery), resized to 1280px JPEG and uploaded to the private bucket `lwb-return-photos`.
- SQL: `lwb_driver_return_photos_setup.sql` (run once): `photo_paths` column, bucket + policies, `lwb_driver_submit_delivery_return_with_photos` (wraps the existing submit; return is saved only with its photos), `lwb_office_driver_return_photos` for `driver-returns.html`, which shows the photos as thumbnails (tap to enlarge).
- PCS per Case for driver returns: `lwb_driver_return_pcs_fix.sql` adds `lwb_sku_pcs_per_case(sku_name)` (SKU Master value, else the "1X12" part of the SKU name) and uses it in `lwb_driver_return_options` / `lwb_driver_submit_delivery_return`, so PCS is never locked for SKUs whose SKU Master PCS per Case is empty.
- Return edit / approval: `lwb_driver_return_edit_setup.sql` adds status CANCELLED, `lwb_driver_list_order_returns`, `lwb_driver_cancel_delivery_return`, `lwb_driver_edit_delivery_return` (old return → CANCELLED, changed one saved as a new PENDING return), lets Sales Head (MANAGER) approve / reject on Driver Returns Approval, and makes `lwb_driver_return_options` count only APPROVED returns in `return_deduction` / net (`pending_deduction` shown apart). Driver collects the full amount until a return is approved.

## Return notifications: urgent popup + click opens page (2026-10-27)
- erp-operations-notifications.js: every bell row with a page opens it (marks read). Routes by type: driver returns → driver-returns.html?order=<id>; driver's return result / loading → driver-delivery.html?order=<id>[&tab=return]; godown → godown-report; market → market-report; loading dispatch → loading-dispatch / transport; orders → my-sales#orders / warehouse-orders. First page the login can open (erp-shell passes menuForMe pages).
- Unread DELIVERY_RETURN_PENDING / _OPERATIONS pop up on every page ("Verify now" / "Later"), again 15 min after Later (localStorage lwbReturnSnooze), not on driver-returns.html.
- driver-returns.html?order=<id> shows only that order (banner + Show all). driver-delivery.html?order=&tab= opens the order.
- lwb_return_notification_cleanup.sql: trigger on return status — CANCELLED deletes that return's office notifications (same order, created within 5 s of the return), APPROVED/REJECTED marks them read. Plus one-time clean-up.

## Driver order card shows return status (2026-10-27)
- driver-delivery.html: after the order list loads, the driver page calls lwb_driver_list_order_returns for each loaded order (loadReturnSummary). Each card then shows "✅ Return ₹X approved", "⏳ Return ₹X waiting for approval" and "❌ Return ₹X rejected: reason", plus Collect ₹(loaded value − approved). The payment line now says "Payment verification pending" so it is not mixed up with return approval.
- erp-operations-notifications.js: DELIVERY_RETURN_APPROVED / _REJECTED pop up once for the driver, with "Open order" (opens that order's Return tab, marks the notification read). No SQL needed.

## Driver payment (notes + UPI photo), Driver Collections, godown receive (2026-10-27)
- SQL: `lwb_driver_payment_setup.sql` (after `lwb_return_notification_cleanup.sql`, 4 rows true). New columns on `lwb_delivery_reports` (cash_amount, cash_notes jsonb, online_amount/mode/reference/photo_paths, payment_status PENDING/VERIFIED/REJECTED + reviewer) and `lwb_driver_delivery_returns` (goods_received_at/by/note). `payment_mode` now also allows CASH+UPI / CASH+BANK / CASH+CHEQUE.
- driver-delivery.html: payment box = Net / Received / Outstanding at the top, Cash note count (500/200/100/50/20/10 + coins) with auto total, UPI/Bank/Cheque amount + reference + 1–3 screenshot photos (bucket lwb-delivery-pod, path uid/order/upi-*.jpg). Submit goes through `lwb_driver_submit_delivery_with_payment` (old submit + `lwb_driver_save_payment`). After delivery the driver sees the payment and can correct it until Accounts verifies. Unpaid remainder = outstanding. Cards show "💰 Received • Outstanding • status".
- driver-collections.html (Admin / Accounts / Sales Head, menu Delivery): To verify / Outstanding / Verified / Rejected; Verify or Reject (reason) via `lwb_review_driver_collection`, which notifies the driver (DELIVERY_COLLECTION_VERIFIED/_REJECTED). Verify does NOT post ledger / Cashbook / Tally. Cashbook "Driver cash (ERP)" now takes only the cash part.
- Return approved → trigger `trg_lwb_return_approved_notify`: DELIVERY_RETURN_RECEIVE to WAREHOUSE (urgent popup "📦 Receive returned goods", snooze lwbReceiveSnooze) and DELIVERY_RETURN_DEDUCTED to Accounts/Admin (bill, return cut, collect). driver-returns.html Approved tab: "📦 Goods received" button (warehouse/manager/admin, `lwb_receive_return_goods`), which marks the receive notification read.
