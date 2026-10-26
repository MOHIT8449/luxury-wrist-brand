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
