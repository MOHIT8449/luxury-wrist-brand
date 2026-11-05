# LUXURY WRIST BRAND ERP — Project Handover

**Checkpoint:** 21 October 2026 (Asia/Kolkata)
**Purpose:** Continue the same ERP project from a new ChatGPT conversation without restarting or losing the agreed requirements.
**Status:** Active development / verification. Do not assume all modules are completed or fully tested.

## Return goods into stock + party credit limit on PO (5 Nov 2026)

- Same day, Mohit: Damage, Leakage and Breakage are one return option ("Damage / Leakage / Breakage (OLN)", claim). Driver return entry (driver-delivery.html) offers only that + Gasless + Low fill (saved as DAMAGE; old LEAKAGE / BREAKAGE rows show the same label). Receive popup places: Saleable | Damage / Leakage / Breakage (OLN) -> DAMAGE | Gasless | Expiry; `lwb_return_default_bucket` sends Leakage / Breakage to DAMAGE. Stock Transfer categories are unchanged.

- Mohit picked these from the full site review (project files `site-review-modules/review.md`).
- Returns: `lwb_return_stock_setup.sql` (test `tests/return-stock`, 4 PGlite tests). Godown "Receive goods → stock" on an approved driver return opens a popup: each SKU line goes to Saleable / Damage / Leakage / Breakage / Gasless / Expiry (default = driver's reason, Low fill = Damage). `lwb_receive_return_goods2(return, [{item_id, bucket}], note)` writes APPROVED `lwb_stock_moves` rows (kind RETURN_IN, from_bucket PARTY, source RETURN, order_id, return_item_id; unique per line), so `lwb_live_stock` / Stock Transfer / category ledger change at once. SKU not in SKU Master = skipped and written in the receive note. Old `lwb_receive_return_goods` now calls it with defaults. `lwb_return_receive_lines(return)` for the popup. Returns received before this are not back-filled. **If `lwb_driver_payment_setup.sql` is run again, run this file after it.**
- Credit: `lwb_party_credit_limit_setup.sql` (test `tests/party-credit`, 4 tests). `lwb_customer_master.credit_limit` (₹, blank = none, checked per brand; Party Master field, `lwb_party_master_save` patched in place). `lwb_party_credit(party, company)` = bills due (`lwb_tally_bill_rows`) + opening − advance of that brand, oldest unpaid bill days, credit days (party+brand, else party, else brand market days), over_limit / over_days; field salesman only his parties. `lwb_order_credit(order)`. `party-credit.js` (LWBCredit). New PO: red box under the party (one line per brand when All brands), confirm on Submit when over; a field salesman's Rajnigandha slip PO over credit is saved pending (no slip) for Sales Head approval. PO / Sales review popup shows the same box for open POs. Not blocked on the server.
- Checked with a mocked database at 390 / 1366 px: no side scroll, no JS errors. Not yet checked on live data. Screenshots: project files `return-stock-credit/`.

## Phone / app: forms in popups, photo buttons gold, keyboard Next (4 Nov 2026)

- Mohit: in the app no page should show an add form with the list under it; the form opens in a popup, less scrolling, Next on the keyboard goes to the next field, photo buttons stand out. No SQL.
- List first + "+ New ..." popup (`master-popup.js` mount): Vehicle / Employee Master (`fleet-master.html`; Excel opens from an "Excel" button in the list row; Edit opens the popup; closes after a good save; phone cards), Opening Stock (list + "+ Enter" per SKU without opening = popup with that SKU picked), Payment Collection, Goods in Transit, Party Ledger Opening Balance ("+ Opening" next to Refresh; `#openingPanel` opens it), Sales Bill PDFs ("⬆ Upload PDF").
- New `LWBMasterPopup.sheet({card, close, title})`: a page's own show / hide form card becomes a popup (opens when the page un-hides the card, ✕ / Esc / outside tap press the page's Close). Used by Complaint Box, Tasks, Godown Report, Market Report (Sales Head / Admin only; salesman keeps the form on the page).
- master-popup phone cards: "#" column hidden; a last column named Action or Review is the button row. Popup forms `.fm-grid` two columns, sticky Save row.
- `erp-shell.css`: on phone / touch, camera buttons (erp-docs 📷 Camera, Accounts 📷 Take photo, Driver Take Photo, Market photo tiles) are gold with a glow; plain photo file inputs get a gold button.
- `erp-keys.js`: sets `enterkeyhint` on focus (Next, Done on the last field, Search in a list search) unless the page set its own.
- Checked with a mocked database at 390 / 1366 px on all 55 pages: no side scroll, no new JS errors. Not yet checked on live data. Screenshots: project files `app-compact-popups/`.

## Party money brand-wise: Rajnigandha and Coca-Cola never mixed (4 Nov 2026)

- Mohit: one party buys both brands; their outstanding is separate and must stay separate. A payment must say which brand (like a PO), and every screen needs All / Rajnigandha / Coca-Cola. Step 1 (money) done here; Step 2 (brand filter on every other report / stock page) is next.
- SQL `lwb_brand_money_setup.sql` (test `tests/brand-money`, PGlite, 5 tests). Brand of a PO = `lwb_order_company(order)` (company of its SKU lines; NULL if mixed). `lwb_tally_payments.company_id` (party payments) and `lwb_party_opening_balances.company_id` (+ unique index party + brand; old one-per-party index dropped). Old rows got the brand by themselves when the party bought only one brand; two-brand parties' old money / opening stay "No brand" until Admin / Accounts picks it.
- `lwb_party_receive(.., p_company_id)` and `lwb_party_adjust(p_party, p_allocs, p_company_id)` (old signatures dropped): money goes only to that brand's bills, rest = that brand's advance (`lwb_party_apply_b`, `lwb_party_receipt_free_b`). No brand sent: party's only brand, else saved as "No brand", not split (bank statement). New Tally bill auto-adjust uses only its brand's advance. `lwb_party_receipt_brand(receipt, company)` gives old money a brand (refused while split to the other brand's PO). `lwb_set_party_opening_balance(.., p_company_id)` (old 4-arg dropped); brand needed for a two-brand party; amount 0 + NULL brand removes an old no-brand row. `lwb_party_openings()`, `lwb_party_ledger_b()` (ledger + company_id). `lwb_party_billing` now also returns company_id per bill / receipt, `advance_b`, `openings_b`, `companies`. Bank statement assign is patched in place (pg_get_functiondef) to pass `p->>'company_id'`.
- **Do not re-run** `lwb_party_group_billing_setup.sql` / `lwb_party_ledger_setup.sql` without this file after them: they would bring back the old 5-arg receive / 4-arg opening (ambiguous calls) and the one-per-party opening index.
- UI: `party-pay.js` popup has brand cards (बाकी per brand), required when 2+ brands; bills / summary / advance of that brand only; button "Save RAJNIGANDHA payment". `party-billing.html`: brand chips (LWBBrand, same saved choice); All = one column per brand + total to look at, "बिना brand" note; a brand = old columns for that brand; Payments tab shows brand tag or "Brand चुनें" select. `party-ledger.html`: brand chips, brand tag per row (All), opening panel with Brand + list of openings with Edit. `bank-statement.html`: Party payment asks the brand (single + bulk).
- Checked with a mocked database at 1366 / 390 px: no side scroll, no JS errors. Not yet checked on live data.

## Brand Data Reset: Rajnigandha fresh start (4 Nov 2026)

- Mohit asked: remove everything done in Rajnigandha till today (payments, purchase / stock, POs, bills, outstanding) so opening outstanding, payments and stock can be entered fresh.
- Page `brand-reset.html` (Admin only; Settings card "Brand Data Reset", Module Search; not in the side menu). Pick brand -> table of what goes (POs + linked, PO payments, party payments, opening balances, purchase bills, stock, payments to company) -> type the brand name -> "Delete <brand> data" -> steps run with a progress bar -> "Download backup" (JSON) + links to Opening Stock, Party opening balance, Billing & Outstanding, Company / Brand.
- SQL `lwb_brand_reset_setup.sql` (test `tests/brand-reset`, 5 PGlite tests). Creates only tables / functions; deletes nothing by itself. `lwb_brand_reset_preview(company)`, `lwb_brand_reset_start(company, typed_name)` (freezes order / inward / party lists in `lwb_brand_resets`), `lwb_brand_reset_step(reset_id)` (40 POs or 40 purchase bills or one stock table per call, all or nothing per call; call again to continue), `lwb_brand_reset_backup(reset_id, after)`. Every removed row is copied to `lwb_brand_reset_rows` first.
- Scope: POs having an SKU of the brand (walker like Admin Delete PO: foreign keys + any order_id column); party payments (no PO) + opening balances only of parties whose every PO is of that brand; Goods Inward bills with that brand's SKUs; `lwb_inventory_movements`, `lwb_stock_moves`, `lwb_stock_audit_lines`, `lwb_stock_transit` rows of its SKUs; `lwb_company_payments` of the company; cheque details / bank checks of removed payments. Kept: SKU Master, rate lists, parties, other brands, Accounts Dashboard cash / bank entries, party payments / opening of parties that also buy another brand (listed as a warning). A PO or purchase bill with two brands stops the reset (listed).

## Keyboard first on every page (4 Nov 2026)

- Mohit: 95% of the work must be done with Tab / Enter / arrows, not the mouse (Tally style). New `erp-keys.js`, loaded by `erp-shell.js` on every ERP page (cashbook.html loads it directly). It runs last (window, bubble) and does nothing when the page already handled the key (`preventDefault`); `data-keys="off"` on an element leaves its keys to the page.
- Enter = next field (skips read-only), Shift+Enter = previous, Ctrl+Enter in a textarea = next. Last field: the Save / Submit button gets the cursor (a real `<form>` still submits). A clear Save button of a block between two blocks is stopped on first. After a page's own name picker takes the Enter (value filled in), the cursor goes on to the next field.
- Search box over a list: Enter / ↓ goes into the first row. ↑ ↓ move between rows (same column), Enter / Space opens. Clickable rows / cards that are not buttons (`onclick`, pointer cursor) get `tabindex=0`. ← → between buttons in one row (Today / 7 Days, tabs).
- Shortcuts: `/` or Ctrl+K page search, Alt+M Module Search, Alt+N "+ New", Ctrl+S / Alt+S Save, Alt+1..9 tab, Alt+H Dashboard, `?` / F1 shortcut list (Hindi). A popup that opens puts the cursor in its first field, Tab stays inside, closing it returns the cursor. On a computer the page search has the cursor on load; a one-time tip says "? दबाएँ".
- `esc-close.js` exposes `LWBEsc.info()` (top popup + kind). Small fixes: order-entry empty last line + Enter goes to Submit; Enter handlers in accounts-invoice, party-billing, dashboard search now `preventDefault`; PO Maker header no longer makes a 6 px side scroll.
- Test: `tests/erp-keys` (Playwright on a small fixture page). Checked 57 pages with a mocked database at 1366 / 390 px: no new JS errors, no side scroll. Not yet checked on live data.

## Admin dashboard: every number opens its list (4 Nov 2026)

- Mohit: on a dashboard, tapping any number must open the full list behind it (e.g. which POs make the ₹50 L profit). Keyboard too.
- `admin-business.js` (Business Overview): all 8 KPI cards, every P&L row, every brand row + Total, every expense head and every Top SKU row carry `data-bzd`; tap or Tab + Enter opens an `erp-list.js` popup. Sales / Gross profit = PO-wise (tap a PO = its SKU lines with rate, landing, cost, profit, "Open PO →"); Purchase = Goods Inward bills (tap = SKUs); Expenses / a head = Accounts money-out lines; Net profit = GP of each PO + each expense (total = net); Outstanding = party-wise due (brand-wise when a brand is chosen); Stock value = SKU × landing; Cash + Bank = cash in hand + each bank; brand row = SKU-wise sales / GP / purchase / stock. A chart day opens that day's POs. Landing / GP columns are hidden when "See profit" is off.
- Expenses list follows NOT_EXPENSE from the order-to-payment audit (Contra / Asset purchase / GST not counted).
- `erp-list.js` (all list popups): ↓ from search goes to the rows, ↑ / ↓ move, Enter opens a row; negative money shows −₹; phone cards in two columns, no "#" line.
- Checked with a mocked database at 1366 px and 390 px: no side scroll, no JS errors. Not yet checked on live data.

## Order → payment audit fixes (4 Nov 2026)

- Admin Business Overview: Expenses / Net profit no longer count Supplier payment, Contra (bank transfer), Asset purchase or GST / Tax paid (`NOT_EXPENSE` in `admin-business.js`). Contra is also left out of money in / out on the Accounts home (`role-dashboard.js` accTotals) and of "All money in / out" and expense-by-head on the Accounts Dashboard (bank-wise rows keep it).
- Dashboard Outstanding now = bills due + party opening balance − advance (same as Billing & Outstanding); opening balance counts as 60+ days.
- Business Overview sales / profit use loaded qty once the PO is loaded (approved before that).
- `lwb_order_payment_audit_fixes.sql`: `lwb_office_receive_driver_payment` limits the money to what is still due (Tally bill − credit + debit notes − office money; no Tally bill: loaded value − office money). `lwb_head_cancel_order` refuses a PO with a Tally bill until a credit note squares it and no money is taken on it. Tests: `tests/order-payment-audit`.
- Open question to Mohit: Billing page "due" subtracts driver-reported money before the office receives it; Outstanding (`lwb_party_bills`) only after verify.

## PO entry on the phone: order setup popup after the party (4 Nov 2026)

- Mohit: on the phone, picking the party opens one popup ("Order for PARTY"): Brand chips, Transport (Delivery / Self pickup / Direct vehicle), Priority, Qty in (Case / Pallet), then "Start order →" which focuses the first SKU.
- The real controls (#brandPick, #tpGroup, #prioGroup) are moved into #setupDlg and back on close, so all old handlers stay. On ≤640 px the form shows only the party plus a summary line ("All brands · Delivery · High · Case ✎ Change") that reopens the popup. Desktop unchanged, no popup there.
- Not opened when editing a PO or opening a draft (pickParty(party, true)); a draft shows the summary line.
- Checked with a mocked database at 412 / 360 / 1366 px: no side scroll, no JS errors. Not yet checked on live data.

## PO entry on the phone: one line per SKU, Next key adds the next line (4 Nov 2026)

- Mohit: salesman order punching was slow on the phone. order-entry.html at ≤640 px now shows each SKU as one line: SKU | Qty (or Pallet) | Rate | ✕, under one small "SKU · Qty · Rate ₹" header (`.m-head`). No amount per line on the phone; the bottom bar shows total ₹ · cases · kg. Desktop table unchanged.
- Keyboard: SKU, Pallet, Qty and Rate have `enterkeyhint="next"`. Enter / Next walks SKU → Qty → Rate → next line; on the last line, a SKU with a quantity gets a new empty line (`lineEnter`). Picking a SKU from the list jumps to Qty (`lineSkuPicked`); Rate text is selected on focus.
- Phone Submit label is "Submit Order" (desktop keeps "Submit to Warehouse Manager").
- Checked with a mocked database at 412 / 360 / 1366 px (Case, Pallet, Direct vehicle CS / PALLET): 44 px lines, no side scroll, no JS errors. Not yet checked on live data.

## Rajnigandha: no own menu items; Rate List brand tabs; slip prints from PO / Sales (4 Nov 2026)

- Settings > "Rate List" (rates.html, was "Rate & Scheme") has brand tabs on top: Coca-Cola (rates.html) | Rajnigandha (rajni-rates.html, Admin only). "Rajnigandha Rate List" left the side menu (nm, par rates.html).
- "Rajnigandha Slips" (quick-slip.html) left the side menu for every role (nm, par PO / Sales); the page still opens from notifications, search, the PO save screen and the banner below.
- warehouse-orders.html: Print (list row and "Print PO" in the popup) on a PO whose every line is a quick-slip brand and that has a slip prints the thermal slip (quick-slip.html?order=..&print=1 in a hidden frame; Android opens the page). Other POs print the A5 PO as before.
- Admin / Sales Head see an amber "Rajnigandha: N waiting for Admin rate OK · M waiting for driver & vehicle" bar above the PO stage tabs (lwb_rate_waiting + lwb_quick_slip_list); it opens quick-slip.html.

## Returns and Inventory page tabs; Fixed Assets and Users popups (4 Nov 2026)

- Side menu: one "Returns" item (Driver Returns). Sales Return and Credit Note are hidden from the menu (still in search / Manage Users) and open as tabs on top of the Returns pages.
- One "Inventory" item. Goods in Transit, Stock Transfer, Night Audit and Opening are tabs on top of Inventory (`PAGE_TABS` + `pageTabs()` in erp-shell.js; a tab shows only if the login may open that page). `par` lights the parent menu item.
- Fixed Assets: list first, "+ New Asset" opens the form in a popup (master-popup.js). Edit opens the same popup; it closes after a good save.
- Manage Users: "+ New User" opens the create-login form in a popup (stays open after Create so the login details can be copied).
- Tally Bill / Tally Check were already hidden from the menu, no change.

## One "Purchase" menu item; Supplier and SKU Master list + popup (4 Nov 2026)

- Mohit: same as PO / Sales for Purchase, and the other masters list-first with the form in a popup. No SQL.
- Menu: "Purchase Entry (Goods Inward)" is `nm` for admin / manager with `par:"purchase-register.html"`; the list item is now "Purchase" (it already had "+ New Purchase"). Goods Inward has a "📋 Purchase List" link.
- New `master-popup.js` (`LWBMasterPopup.mount({panel, bar, newLabel, onNew, canNew, cancelAfter, cards, mainCol})`): moves a page's form section into a popup (✕ / Esc / backdrop / Cancel), adds "+ New …" to the list header, `#new` opens it, and on a phone turns the list table into cards (labels from the table head). Two-column form and sticky Save row on the phone.
- Supplier Master and SKU Master use it (Edit opens the popup, a good save closes it). SKU Master: Bulk add and Excel are buttons in the list row (one open at a time). Customer / Party Master keeps its own popup from the earlier change.
- Checked with a mocked database at 1366 px and 390 px: no side scroll. Not yet checked on live data.
- Still to do from `page-merge/merge-plan.md`: Fixed Assets / Users popups, Returns / Tally / Inventory merges.

## PO Filled %, one "PO / Sales" menu item, Party Master popup (4 Nov 2026)

- Mohit: show how much of a salesman's order was really loaded (order 100, loaded 90 = "90% filled"), merge New + List pages so the menu is shorter, and Party Master = list with "+ New Party" in a popup. No SQL.
- `warehouse-orders.html` (now titled **PO / Sales**): Qty cell of a Loaded / Billed or Delivered PO shows a "N% filled" badge (sum `order_items.loaded_qty` ÷ sum `ordered_qty`; green 100%, amber 90–99%, red below 90%; no badge when nothing loaded was saved, e.g. old POs). Filter **All fill / Full 100% / Short (<100%) / Below 90%** (only loaded / delivered POs pass). Excel has Loaded and Filled % columns. "+ New PO" (Admin / Sales Head) next to ⟳ Refresh.
- Menu: "PO / Sales Order" (`order-entry.html`) is `nm` for admin / manager / sales (not drawn in the side menu; still in Module Search, Manage Users and the phone bottom bar "New Order") and has `par` so "PO / Sales" is lit while it is open. Both list items are named "PO / Sales". `order-entry.html` link "📋 PO List".
- `customer-master.html`: the list is first; add / edit open in a popup (`#pmModal`, Esc / ✕ / Cancel close it, closes after a good save). Bulk add, Excel and Duplicates are buttons in the list's button row (one panel open at a time). `customer-master.html#new` opens the popup (PO entry "+ New Party" link). Phone: one compact card per party, no side scroll.
- Checked with a mocked database at 1366 px and 390 px: no side scroll. Not yet checked on live data.
- Planned next (Mohit agreed the plan, `page-merge/merge-plan.md` in project files): Purchase Entry + Purchase List, other masters as popups, Returns / Tally / Inventory merges.

## Accounts: own work in front, other pages view only, company payment entered once (4 Nov 2026)

- Mohit: Accounts (e.g. YOGESH PATEL) saw data it does not use. Its work is cash in / cash out, matching entries (bank), which order went where, and returns. Other pages it still needs to see, but not change; no money entry should be needed twice.
- Menu (`erp-shell.js`): items carry `vo:"accounts"` (Rajnigandha Slips, Purchase List, Sales Bill PDFs, Sheet & Pallet Ledger, Inventory, Stock Transfer / Damage, Night Stock Audit, Company / Brand, Fixed Assets). For Accounts they move to a "View only" group at the bottom. `ERPShell.viewOnly(role,page)` tells a page to hide its entry / edit buttons: sheet-pallet (no New Entry tab, no return letter save), sales-bill-scans (upload / edit Admin only now), fixed-assets (no edit), companies (no party udhari edit; Pay company shows bills + payments and a link to pay from the Accounts Dashboard). Purchase List, Stock Transfer, Night Stock Audit, Inventory and Rajnigandha Slips were already view only for Accounts. UI only: the RPC permissions are unchanged.
- Same day, Mohit: PO / Sales List, Driver Delivery / POD, Driver Collections, Daily Summary, Billing & Outstanding, Rajnigandha Slips and Sales Bill PDFs are not in the Accounts side menu (`nm:"accounts"`); they stay allowed and are found by Module Search / Dashboard search ("More") and the dashboard cards. Accounts bottom bar: Home, Cash, Bank, Returns.
- One entry for a company payment: SQL `lwb_accounts_company_pay_setup.sql` (test `tests/accounts-dashboard/company-pay.test.mjs`). `lwb_company_payments.acc_entry_id`; `lwb_acc_add_entry5(p)` = entry4 + `p.company_id` (only Cash Out, head Supplier payment) also saves the company payment (RTGS -> BANK). Cancelling the money entry cancels it (trigger); `lwb_company_pay_cancel` refuses a linked payment. Accounts Dashboard Add entry shows "Company paid" when head = Supplier payment; `?new=IN|OUT[&company=<id>]` opens Add entry. Admin's own form on Company / Brand still saves without cash / bank, as before.
- Accounts home (`role-dashboard.js` accounts): one row Cash In / Cash Out / Bank match / Returns; KPIs Cash in hand, Cash In, Cash Out, With drivers, Bank to match (`lwb_bank_stmt_open_count()`); cards Orders where are they (on vehicle, delivered / part / not delivered today), Returns (to approve, approved today, credit note to make), Outstanding (age + top 5); right side Pending Work, Night cash, Cheques (only when due), Brand-wise (view). Removed: Bills to make KPI and table (still in Pending Work), full outstanding list, "+ Give task" for Accounts.
- Checked with a mocked database at 1366 px and 390 px: no side scroll. Not yet checked on live data.

## Billing: bill names stay on the bill, PO item changes through Admin (3 Nov 2026)

- Mohit: a Tally bill name typed by Accounts (often a spelling variant) must not make a party; keep it under the main party as bill name + invoice no. + amount. One PO can have many bills (already allowed). Any change of PO items (qty + / −, rate, wrong SKU sent, SKU added / removed) by Accounts goes to Admin with a popup of the value difference; collection follows the approved value. Ideas shown as 4 options; Mohit picked D (name + invoice + amount only, no item split per bill) plus an "Items" button on each PO.
- SQL `lwb_bill_change_setup.sql` (test `tests/bill-change`, PGlite, 9 tests). `lwb_save_tally_bills` no longer inserts `lwb_tally_party_map` rows (bill name only in `lwb_tally_invoices.bills`; a name linked by hand to another main party is still refused). Table `lwb_bill_changes` (WAITING / APPROVED / SENT_BACK / REPLACED, one WAITING per PO, lines with sku_old / sku, qty_old / qty, rate_old / rate, kind QTY / RATE / SKU / ADD / REMOVE, old / new value, diff, bill_no). RPCs: `lwb_bill_change_items(order)`, `lwb_bill_change_request(order, items, reason, note, bill_no)` (full new line list; a line left out = removed; Accounts -> WAITING + BILL_CHANGE_APPROVAL bell to Admins; Admin -> applied at once), `lwb_bill_change_decide(id, approve, reply)` (Admin; refuses if the PO lines changed after the request, STALE), `lwb_bill_change_list(days)`. Applying changes `loaded_qty` after loading (else `approved_qty`), rate and sku_name; new SKU = new order_items row; the Tally bill amount and the chosen bill line move by the difference (refused if it would go to 0 or below). Bells BILL_CHANGE_APPROVED / BILL_CHANGE_SENT_BACK to the requester.
- `bill-change.js` (LWBBillChange.open / review). `party-billing.html`: "ⓘ Items / Edit" on every Bills to make card and "ⓘ Items" on every To collect bill row; "⏳ Waiting Admin ±₹" tag; new tab "PO changes" (count of waiting; Admin "Check & approve"). Bell opens `party-billing.html?tab=chg&change=<order>`. Bill name list also offers names used before on that main party. Phone: card footer in one row.
- Checked with a mocked client whose RPCs ran this SQL on PGlite at 1366 px and 390 px: no side scroll. Not yet checked on live data. Old auto links already in `lwb_tally_party_map` are left as they are.

## Esc closes any popup, every page (3 Nov 2026)

- Mohit: on any page, Esc must close the open popup, like Back (top one first, one per press).
- New `esc-close.js` (`LWBEsc`), loaded by `erp-shell.js` on every ERP page (cashbook.html loads it directly). No SQL.
- On Esc it finds the top open popup (big fixed backdrops, role=dialog boxes, non-modal `<dialog>`, `<details>` menus, positioned dropdown lists by class like list / menu / results / options / panel). Page code that already handles Esc runs first; if the page did nothing, it presses the popup's ✕ / Close / Cancel button, else taps the backdrop, else hides it. Modal `<dialog>` and the side menu are left to the browser / shell.
- `event.lwbPopup` is set when a popup is open; `order-entry.html` Esc = Save Draft now skips itself then, so Esc only closes the popup.
- Checked with a mocked database (1366 px and 390 px) on 6 pages + popup on popup + Sales Order draft; idle pages show no false popup.

## PO / Sales Order drafts (3 Nov 2026)

- Mohit: when goods are being given / bill made but the party has not confirmed, no PO should be made. Keep it as a Draft (Esc = save draft), open and edit it later, then submit it as a PO.
- SQL `lwb_po_draft_setup.sql` (test `tests/po-draft`, PGlite, 5 tests): table `lwb_po_drafts` (party, sales person, transport, line count, qty / amount / weight, form JSON in `data`; saver / editor names stamped by trigger). RLS: the saver + active Admin / Sales Head read / change / delete; Admin, Sales Head, Salesman can add. A draft is not an order: no PO no., no stock / approval / bell / Tally.
- `order-entry.html`: "📝 Save Draft (Esc)" next to Submit (phone: "📝 Draft"); Esc saves unless a popup, party list or menu is open (then Esc only closes it). Saving again updates the same draft (`?draft=<id>`). "📝 Drafts n" in the header opens the list (Open / 🗑). `?draft=<id>` fills the form (party, brand, transport, vehicle, pickup, priority, slab, SKU lines with rate). After Submit makes the PO, the draft is deleted. Not shown while modifying an existing order.
- `warehouse-orders.html`: "📝 Draft" tab before Pending Review (Admin / Sales Head; hidden until the SQL is run). Click a row / ✏️ Open goes to `order-entry.html?draft=<id>`; 🗑 deletes. Search and Sales person / Transport filters apply. "All" does not count drafts.
- Checked with a mocked database at 1366 px and 390 px: no side scroll. Not yet checked on live data.

## Dashboard top bar in one line (2 Nov 2026)

- Mohit: search, My Tasks, Give task and Post banner were big blocks pushing the Business Overview down. Now one line on `dashboard.html` (all roles): search box + "📋 My Tasks" (count badge, red when one is overdue) + "+ Give task" + "+ Post banner". The task list opens only when "My Tasks" is pressed (closed on every page load); the banner form still opens below on "+ Post banner". Phone: search on top, the 3 buttons in one row. No SQL.
- Brand pick on the role dashboard (Admin / Sales Head) is now a dropdown (`#rdBrand`, All brands / each company) right next to the "Admin view" dropdown in the page head, instead of the chips row (`brandPick()` in role-dashboard.js; same `lwbBrand` saved choice). Other pages keep their chips.

## Admin Business Overview on the Dashboard (2 Nov 2026)

- Mohit asked for a full business view on the Admin dashboard (sales / purchase register, SKU-wise, profit & loss, expenses, charts). 3 mockups were shown; Mohit picked design A. No SQL.
- New `admin-business.js` (`LWBBizDash`), mounted by `role-dashboard.js` admin view in `<section id="bzDash">` (styles `bz-` in `role-dashboard.css`). It replaces the old Admin KPI row and 7-day chart; Order Flow, Salesman today, Pending Work and the old Brand-wise (targets / to pay company) stay below. Alerts now show in its "Needs attention" card.
- Range Today / 7 Days / 30 Days / This Month (default), kept per browser `localStorage lwbBizRange`; follows the Brand chips.
- 8 KPIs: Sales, Purchase, Gross Profit, Expenses, Net Profit, Outstanding, Stock Value, Cash + Bank. Then Sales · Purchase · Gross profit line chart (at least 7 days), Profit & Loss, Brand-wise (sales, qty IC / cs, purchase, gross, margin, to collect, stock value), Expenses donut, Top 8 SKUs (qty, sales, margin bar, stock days), Needs attention.
- Sources: order_items qty × rate by order_date (cancelled / rejected out); landing = Rate & Scheme pack (`landingOf`, same as Today's Profit) else Rajnigandha Rate List landing (`lwb_price_limits_get`); lines without landing are left out of profit and counted in a note. Purchase = `lwb_goods_inward(_items)` total_amount by received_date. Expenses = `lwb_acc_dashboard` OUT lines without "Supplier payment" (company-wide, also when a brand is chosen). Stock = `lwb_po_stock` godown cases × landing. Cash + Bank = closing cash + active bank balances. Gross Profit card on Today opens the order-wise profit popup.
- Checked with a mocked database at 1366 px and 390 px: no side scroll. Not yet checked on live data.
## Purchase menu, Purchase List, Godown photo task, Sales Bill PDFs, duplicate invoice popup (2 Nov 2026)

- Mohit asked: a Purchase list like the PO list, easy to find in the menu; when Goods Inward says Damage / Leakage or Check later, the Godown Manager must get a task to upload photos of that vehicle; a register of the scanned sales bill PDFs uploaded every night, searchable by invoice no.; a popup as soon as a duplicate purchase invoice no. is typed.
- SQL: `lwb_purchase_register_setup.sql` (after `lwb_purchase_claim_setup.sql`, `lwb_documents_setup.sql`, `lwb_task_management_setup.sql`; **if lwb_purchase_claim_setup.sql is run again, run this file again after it**). Test: `tests/purchase-register` (PGlite, 6 tests).
- Menu: new group **Purchase** under Sales: Purchase Entry (Goods Inward), Purchase List (`purchase-register.html`, now admin / manager / warehouse / accounts), Purchase Claims, Sales Bill PDFs (`sales-bill-scans.html`). Removed from Inventory.
- Purchase List: tabs with counts (All / Check pending / Photo pending / Damage-Claim / Verified OK / No bill copy), supplier filter, Today / 7 / 30 Days / Month + dates, Excel, count cards open the list. Invoice no. click shows SKU lines. Godown Manager: Verify + photos, no amounts. Accounts: view only. Phone: one card per bill. `?bill=<id>` opens that bill's Verify (used by the task).
- Vehicle check: `lwb_save_purchase_check` is now SECURITY DEFINER and allows WAREHOUSE while claim is NONE / PENDING. Accounts / warehouse can read `lwb_purchase_checks`.
- Photo task: `lwb_tasks.ref_type / ref_id` ('PURCHASE_BILL', inward id). `lwb_purchase_photo_task(inward, assignees?)` (Admin / Sales Head) gives one task to every active WAREHOUSE login when the bill is not checked (CHECK) or has damage without a DAMAGE photo (PHOTO, urgent); nothing if an open task exists. Goods Inward calls it after save unless "No damage"; Purchase List calls it after a damage check and has a "📷 Task" button. Triggers on `lwb_purchase_checks` and `lwb_documents` (DAMAGE) close the tasks by themselves (`lwb_purchase_task_sync`) and send TASK_DONE to the giver. tasks.html shows "📷 Open bill: check + photos".
- Duplicate invoice: `lwb_purchase_invoice_find(text)` matches ignoring case, spaces, / and -. Goods Inward checks while typing; same supplier = popup + Save blocked (checked again on Save); other supplier = note only.
- Sales Bill PDFs: table `lwb_sales_bill_scans` + private bucket `lwb-sales-bills` (30 MB, PDF / JPG / PNG, path `<bill date>/<uid32>-...`). Upload / edit / remove Admin + Accounts (`lwb_sbs_add`, `lwb_sbs_update`), view / search also Sales Head (`lwb_sbs_find`, exact first then partial). Invoice box takes ranges ("LWB/101-LWB/140, 145"); "From Tally" fills the numbers saved in `lwb_tally_invoices` for that date. "Not in any PDF" = Tally bills of the dates whose number is in no PDF; days with Tally bills but no PDF are listed.

## PO Approval: Brand filter + last 7 days trend graphs (2 Nov 2026)

- Mohit asked: a Brand filter next to Sales person / Transport on `warehouse-orders.html`, and on the Dashboard view graphs of the last 7 days (day-wise rise / fall) for sales amount and quantity. No SQL.
- Brand of a PO = the companies of its SKU lines (`sku_master.company_id`, via `brand-filter.js` / LWBBrand). List shows a PO when any line is of the picked brand; tab counts follow. Lines are read in chunks of 150 order ids (`loadItemsFor`, cached; also fills the Lines column). Filter is hidden when the login has fewer than 2 brands.
- Dashboard "Sales Trend" (Mohit's change, same day): line graphs (up / down like a heartbeat), switch 7 Days / 30 Days / Month-wise (last 6 months, kept per device `localStorage lwbTrendMode`). Sales Amount line + Quantity with one line per brand in its own unit (Rajnigandha IC, Coca-Cola CS; never mixed). Each 7-day / month point shows ▲ / ▼ % vs the one before; badges "Today vs yesterday" / "This month vs last month"; hover / tap shows the day's values. Counts lines (approved qty, else ordered) × rate by `order_date` (India day); cancelled POs not counted. Own Brand + Sales person dropdowns, kept the same as the PO List ones (`syncFilter`). SVG drawn at the card width, redrawn on resize. 30 Days also shows a day-wise box per day (newest first: amount, ▲ / ▼ % vs the day before, brand-wise qty), Mohit asked to see every day's rise / fall.
- Toolbar (search, 3 filters, Today / 7 / 30 Days, dates, Excel) is one line at 1366 px; phone shows the 3 filters in one row.

## One quantity box per SKU line (2 Nov 2026)

- Mohit: the PO line had both Pallet and Qty (CS / BOX) boxes, but an order comes in one unit only. Now "Qty in [Case / Box | Pallet / Carton]" sits under the Delivery Priority buttons, next to "+ Add SKU" (kept per device, `localStorage lwbQtyBig`); only one box shows per line. Words follow the Brand pick (Coca-Cola: Case / Pallet, Rajnigandha: Box / Carton, All: both). Big unit shows "= 260 CS" / "= 60 BOX" under the box; the hidden box is filled from it, so saving is unchanged (cases / boxes are saved).
- Mohit (2 Nov 2026): PO form compact, so 10 SKU lines fit one screen with no up/down scroll (checked at 1366x657 and 1920x945 browser areas). "New Sales Order" and the Brand chips are one header line (no separate page title or "Order Details" / "Order Items" headings); rows, totals bar and buttons are one line each. Vehicle Number shows only for Direct vehicle (not Delivery). The form fills the whole free screen (full width; the SKU card stretches to the screen bottom with totals at the bottom edge; bigger text on screens 1600x850+). Desktop rules are scoped under `#oeMain` because erp-shell.css loads after the page style.
- Carton uses the same SKU Master field as Pallet (`cases_per_pallet`, label now "CS per Pallet / Box per Carton"): for a BOX SKU enter boxes per carton there. No SQL.
- Direct Vehicle whole-pallet mode (CS / PALLET buttons) is unchanged; the switch hides in that mode.

## Rajnigandha rate limit, Admin rate OK and profit (2 Nov 2026)

- Mohit asked: Rajnigandha gives a flat landing per box. Admin sets per SKU the landing, the min sale rate and the std sale rate. A Salesman / Sales Head rate below min must go to Admin; Admin only gets an "Approve" button (Mohit: no reject / change-rate options). Admin sees the profit (rate − landing). Sales roles never see landing / profit unless Admin ticks that person. Coca-Cola (chair rate, MS, QPS, ROI) is Phase 2, not built.
- SQL `lwb_rajni_rate_limit_setup.sql` (test `tests/rajni-rate-limit`): `lwb_sku_price_limits` (sku_key = upper SKU name) + `lwb_sku_price_history`, `lwb_price_viewers`, `lwb_rate_approvals` (WAITING / APPROVED + driver / vehicle typed on save), `lwb_order_landing` (landing kept per slip line when the slip is made). Functions: `lwb_sale_rates` (min + std only, any login), `lwb_price_limits_get/save`, `lwb_price_history`, `lwb_price_viewer_set`, `lwb_rate_request` (RATE_APPROVAL bell to Admins), `lwb_rate_waiting`, `lwb_rate_approve` (Admin; makes the slip with the saved driver / vehicle, RATE_APPROVED bell back), `lwb_slip_profit(from, to)`. Triggers: no `lwb_quick_slips` row below min unless Admin made it or approved it; after a slip only Admin can lower a line below min.
- `rajni-rates.html` (menu Sales > Rajnigandha Rate List, Admin only): edit landing / min / std, profit @ min / std, who-can-see list. `order-entry.html`: std rate fills by itself (after the party's last bill rate), below-min line turns red, button "Send to Admin for rate OK", save calls `lwb_rate_request` instead of the slip. `quick-slip.html`: "Waiting for Admin rate OK" card + approval popup (only Approve), Profit column and Sale / Profit total for Admin / ticked people.

## Rajnigandha quick slip (kachcha parchi) flow (2 Nov 2026)

- Mohit asked: Coca-Cola keeps the full PO flow. A Rajnigandha PO (Sales Head Vinesh Chalavadiya) is made, driver name + vehicle no. typed at once, a small thermal slip (3x4 or 2x4 inch) prints, and the PO goes straight to Accounts for the Tally bill. No approval / transport / loading in between. Slip shows PO, date, party name, party mobile + address (Party Master), SKU / qty / rate / amount, total. Mohit (later the same day): slip has no heading at all, no driver / vehicle lines (they are still entered and saved, shown on the Slips list), no driver mobile, and one "Receiver sign" line instead of Driver / Godown sign.
- SQL `lwb_quick_slip_setup.sql` (test `tests/quick-slip`): `lwb_companies.quick_slip` (ON for RAJNIGANDHA when the column is added), table `lwb_quick_slips` (RPC only), `lwb_quick_slip_dispatch(order, {driver_name, vehicle_no})` (Admin / Sales Head; approved PO whose every SKU is of one quick-slip brand, no dispatch assignment; sets loaded_qty = approved, status 'loaded' so the normal "Make Tally bill" popup goes to Accounts, re-worded "Rajnigandha Slip — Make Tally Bill"; godown "get ready" popup marked read; called again it only corrects driver / vehicle), `lwb_quick_slip_get`, `lwb_quick_slip_printed` (reprint count), `lwb_quick_slip_list(from, to)` (slips + approved Rajnigandha POs still waiting for driver / vehicle, e.g. a salesman's PO approved later).
- `order-entry.html`: Sales Head / Admin save with only quick-slip brand SKUs -> popup Driver Name + Vehicle Number -> PO saved approved -> slip made -> slip prints in a hidden frame (same as Print PO). Mixed Rajnigandha + other brand in one PO is refused (make separate POs). Salesman orders unchanged.
- Brand pick (2 Nov 2026, Mohit's correction): New Sales Order has Brand chips (All brands / RAJNIGANDHA / COCA-COLA; a brand-limited login sees only his; kept per device via LWBBrand). A brand limits the SKU list and the save button says "Save & Print Slip" for a quick-slip brand. Works for every login: a Salesman's Rajnigandha order is saved pending and `lwb_quick_slip_dispatch` turns it into a slip at once (approved_by = salesman, no Sales Head approval; he reads / prints only his own slips, Slips page open to sales). "All brands" with Rajnigandha + Coca-Cola lines saves 2 POs after a confirm (normal PO + slip PO, `createPoRecord`). Two quick-slip brands in one order are refused.
- Brand per salesman (2 Nov 2026, Mohit): Sales Team Setup > Salesmen has a Brand column (All brands / Only RAJNIGANDHA / Only COCA-COLA), saved with Save through `lwb_set_user_companies` (same data as Companies > Team brands). A one-brand salesman sees only that brand on New Sales Order (no chips, just the brand name); the godown Sales Head stays All brands. Only Admin can change a Sales Head's brand.
- `quick-slip.html` (menu Sales > Rajnigandha Slips; Admin, Sales Head, Accounts, Godown): slip list with View / Print / Reprint, waiting POs with "Driver & slip", 3 inch / 2 inch switch (kept per device), page height follows the slip so one long strip prints.

## Delete / Cancel / Modify orders at any stage (2 Nov 2026)

- Mohit: Admin deletes any sales order / PO (dummy and duplicate data); others only Cancel; Sales Head can modify or cancel even after the vehicle is loading / loaded (market cancels).
- SQL: `lwb_order_delete_cancel_setup.sql` (test `tests/order-delete-cancel`). Log table `lwb_order_audit` (DELETE / CANCEL / MODIFY, reason, who; a DELETE keeps a JSON copy of the order + SKU lines). No grants: read it in the SQL editor.
- `lwb_order_delete_preview(ids)` / `lwb_admin_delete_orders(ids, reason)`: Admin only, max 200, all or nothing. Deletes the orders and every linked row, found from the database foreign keys at any depth (ON DELETE SET NULL left to the database) plus any public table with an `order_id uuid` column without a foreign key (bells etc.).
- `lwb_head_cancel_order(id, reason, note)`: Admin / Sales Head, any status until delivered (status delivered or driver report DELIVERED / PARTIAL refuses: use Sales Return). After transport is assigned, Godown Manager (assignment `loading_manager_id`), Driver (mobile) and, once loaded, Accounts get an `ORDER_CANCELLED` bell. The salesman still gets the old cancel bell from the trigger. Salesman's own cancel (My Orders, pending only) is unchanged.
- `lwb_head_modify_order(id, items, note, reason)`: Admin / Sales Head while status is loading / loaded / invoiced and not delivered. Replaces the SKU lines (approved_qty, rate, weight; add / remove), cuts `loaded_qty` down to the new cases, recalculates totals, `ORDER_EDITED` bell to the same people. Earlier stages still save the old way (direct update on PO Approval).
- Page: `warehouse-orders.html` review popup has 🗑 Delete (Admin) and Cancel Order (Admin / Sales Head, any stage before delivery); the selection bar has 🗑 Delete selected (Admin). Delete asks for a reason, shows the linked rows that go with it, then needs DELETE typed. Not verified on live data yet.
- PO list rows (2 Nov 2026, Mohit): the Review / Edit PO / View button and the Challan button are gone. Clicking anywhere on a line (not its checkbox or buttons, `openRow`) opens the PO for edit. Challan prints from the popup (Challan button next to Print PO, approved POs).

## PO Approval list: stage tabs like the company DMS (2 Nov 2026)

- `warehouse-orders.html` only, no SQL. Mohit compared it with HCCB Vxceed DMS (Sales Order list: Posted / In Progress / Closed / Void / Blocked / Expired / Draft / All tabs with counts, date range, column filters, export).
- The 4 stat boxes + status dropdown are replaced by stage tabs with counts: Pending Review, Approved, Transport Assigned (transport_allocated / allocated), Loading, Loaded / Billed (loaded / invoiced / dispatched, not delivered), Delivered (delivery report or delivered status), Cancelled, All, plus Urgent / High, Approval late 12h+, Delivery late 36h+. Before this, a PO with transport assigned showed only under "All".
- The list is no longer the latest 300 orders: it loads orders whose `order_date` is in the chosen range (Today / 7 Days (default) / 30 Days / custom, max 5000) plus every open order (pending, approved, transport_allocated, allocated, loading) of any date.
- Sales person and Transportation filters (tab counts follow the search and filters), 50 per page with a pager and a total line (POs, CS, amount, KG), "Lines" column (SKU count, read from `order_items` for the orders on screen), "Updated HH:MM" next to Refresh, Excel of the current tab (`excel-io.js`).
- Select many (2 Nov 2026): checkbox before each Order No (and one in the header for the page). A gold bar shows count / CS / amount / KG with "Approve selected" (only when all are Pending Review; approves each PO as ordered through the same `approveOrder()` as the popup, one by one, stops at the first one that fails), "Print selected" (one print job, one A5 PO per page, via `printApprovedPO("po", parts)`) and Clear. Selection clears when the tab changes. On a phone the bar floats above the bottom menu.
- PO journey in the review popup: PO made → Approved → Transport assigned → Loading started → Vehicle loaded → Delivered, with time, person / vehicle / driver / godown manager and time taken (from `orders`, `dispatch_assignments`, delivery reports). Cancelled POs end with the reason.
- View switch (2 Nov 2026): a "📋 PO List | 📊 Dashboard" button at the top shows one at a time: Dashboard = the summary cards (`#poSummary`), PO List = tabs, filters and table (`#poListView`). Default PO List; the choice is kept per browser (`localStorage lwbPoView`). Also fixed: the selection bar and list footer ignored `hidden` (their CSS set display:flex), so an empty gold bar showed.
- Compact list (2 Nov 2026): on a computer the table fits the screen with no side scroll (checked at 1366 and 1600 px wide): smaller padding, Sales Person and Transport in one column, buttons in one row (Review / Edit PO, Print, 🚚 Transport (icon only under 1500 px), Challan). PO List / Dashboard switch sits next to the title; the open-PO note is now the date box tooltip. Phone hides the page title (top bar already names the page) and tightens the cards.
- Mohit said (2 Nov 2026) not to build Blocked / Expired for now. Draft was built on 3 Nov 2026 (see PO / Sales Order drafts).
- PO journey, 6 steps (2 Nov 2026, Mohit's list): PO made → Approved → Transport assigned → Loading start → Out for delivery → Delivered. "Out for delivery" = loading started (or loaded) AND Accounts entered the Tally bill no (`lwb_tally_invoices`); time = the later of bill and loading start. Waiting text: "Vehicle loaded · Tally bill pending" or "Bill X made · waiting for loading". Delivered = driver report DELIVERED / PARTIAL (NOT_DELIVERED shows as a note) or delivered status. A later step reached marks earlier ones done (old orders miss timestamps). Data comes from the read-only RPC `lwb_po_journey(p_ids uuid[])` (`lwb_po_journey_setup.sql`, Admin / Sales Head only, max 500, test `tests/po-journey`) because Sales Head cannot read `lwb_tally_invoices`; if the RPC fails the page falls back to `dispatch_assignments` only.
- 📍 Track button on every row of the PO list opens a small popup with the same journey (bottom sheet on phone). Row buttons got 2px less padding so the table still fits 1366 px. Phone stage tabs no longer bleed 4px past the screen.
- Direct print (2 Nov 2026, Mohit): Print / Challan in the PO list no longer opens the review popup first; `printQuietly()` loads the PO with `reviewOrder(id,false,true)` (quiet, no popup) and opens the printer dialog. "Print PO" after saving on New Sales Order loads `warehouse-orders.html?order=..&action=print` in a hidden frame (`printSavedPoInFrame`), so the printer dialog shows over the same page; the frame posts `{lwbPoPrint:"ready"|"done"}`. On Android, or if the frame does not answer in 20 s / cannot load the PO, the link opens the page normally (still no popup).
- Step 7 Collection + Tally bill from the list (2 Nov 2026, Mohit): `lwb_po_journey` now also returns `bill_amount`, `collected` (driver payments not rejected + `lwb_order_office_paid`) and `due` (same formula as `lwb_tally_bill_rows`: bill − credit + debit − collected; no Tally amount = loaded value − approved returns; NULL when no bill and nothing loaded). Return type changed, so the SQL drops the function first. Journey step 7 "Collection": done when due ≤ 0, else "₹X received of ₹Y · ₹Z due"; it is not back-filled by later steps (a party can pay before delivery). Accounts rows get "🧾 Bill" and Accounts / Admin get "🧾 Enter Tally bill no." in the Track popup: a small popup (bill no., amount, date) saving through `lwb_save_tally_bills` with one line in the party's own name. If a bill exists it only shows it and links to Billing & Outstanding (sub-firm bills / changes stay there).

## Self pickup driver details + one-line totals on New Sales Order (2 Nov 2026)
- Mohit asked: when Transportation = SELF PICKUP an outside driver (different every time) takes the goods. Mohit wants it at the end: after everything is filled, pressing Submit with SELF PICKUP opens a popup asking Driver Name, Driver Mobile (10 digits), Vehicle Number (typed) and Godown Manager (Employee Master, Work / Post = Godown Manager; required when the list has anyone). Back returns to the form without saving.
- SQL: `lwb_self_pickup_driver_setup.sql`. Table `lwb_order_pickup` (one row per order; read = whoever can read the order, via orders RLS; write only via RPC). `lwb_pickup_godown_managers()` (any active non-driver login, no salary) and `lwb_set_order_pickup(order, p)` (Admin / Sales Head / Godown / Transport any open order; salesman own order before approval; empty p or not SELF PICKUP clears). Saved after the order is created / modified, like priority. Shown in Message copy, Excel and the save popup.
- Totals (Total SKU, Pallet, Quantity, Amount, Final Weight) are one highlighted horizontal strip instead of a tall box (phone keeps the sticky total bar).
- Search old driver (2 Nov 2026): the popup has "Search old driver (name / mobile / vehicle)"; picking fills name, mobile and vehicle. Source `lwb_pickup_drivers()` (`lwb_self_pickup_driver_search.sql`): earlier `lwb_order_pickup` rows, one per mobile (else name + vehicle), newest first, max 500. A new driver typed once shows up next time.
- Bottom buttons (2 Nov 2026): Order image copy / Message copy / Excel / New Order and the "Share / Print / Excel" link are removed. Only Submit, plus Print for Sales Head / Admin (`headCreatesApprovedPo()`); Salesman has no Print.
- Godown Manager list fix (2 Nov 2026, `lwb_self_pickup_godown_list_fix.sql`): the list was empty because no Employee Master row had Work / Post "Godown Manager"; Godown Managers work with a Godown (warehouse) login. `lwb_pickup_godown_managers()` now returns Employee Master Godown / Warehouse Managers AND active warehouse logins (one per person: linked user_id or same mobile), each with `key` 'S:<staff id>' / 'U:<login id>'. `lwb_order_pickup.godown_user_id` added; `lwb_set_order_pickup` takes `p.godown_key` (old `godown_staff_id` still works).
- Mohit dropped "Search old driver" (types each time); the popup has only the 4 fields. `lwb_pickup_drivers()` stays in the DB, unused.
- Print: Order Entry print shows a "Self pickup: Driver | Mobile | Vehicle | Godown Manager" line; PO Approval PO print / challan fall back to `lwb_order_pickup` when no dispatch assignment exists (PO print also shows Driver Mobile).
- Old preview `erp-pro-redesign.luxury-wrist-brand.pages.dev` is a stale branch preview; the live site is `luxury-wrist-brand.pages.dev`.
- Not yet shown on PO Approval / Loading & Dispatch (they can `select` from `lwb_order_pickup`).
- Test: `tests/self-pickup` (PGlite, 4 tests).

## One staff list: Driver Master merged into Employee Master (31 Oct 2026)
- Mohit asked: no separate Driver Master. Every staff member is kept once in Employee Master with a Work / Post (Driver, Loader, Godown Manager, Manager, Supervisor, Godown helper, Packer, Picker, Salesman, Office, Accounts, Security, Other). Wherever a person is picked, the list of that post comes from Employee Master by itself; vehicles from Vehicle Master.
- SQL: `lwb_employee_roles_setup.sql`. Adds driver details to `lwb_acc_staff` (alt_mobile, license_no, license_expiry, default_vehicle_id, transporter_name, address). Copies every `lwb_drivers` row once (match by mobile, else same name without mobile, else new employee "Driver", salary 0; name clash gets " (last 4 digits)"); `lwb_drivers.staff_id` records where it went. A matched employee with another post becomes Driver and the old post is written in the note. DRIVER documents / Aadhaar-bank numbers are moved to STAFF/<employee id> (files stay where they are). `lwb_drivers` is kept, nothing deleted, and no page writes to it any more.
- RPCs: `lwb_staff_pick(role)` (active employees of one post: name, mobile, vehicle, transporter; no salary; read by Admin, Manager, Transport, Godown, Accounts, or a login ticked for PO Approval / Transport Assignment), `lwb_emp_list2()` / `lwb_emp_save2(p)` (Employee Master with driver details; they wrap `lwb_emp_list` / `lwb_emp_save`). A Driver needs a 10-digit mobile and one mobile = one working driver (Driver Portal still matches orders by that mobile).
- Pages: `fleet-master.html` has Vehicle Master + Employee Master (Work / Post select, driver fields shown only for Driver, Work / Post filter, Excel has the driver columns). Old link `#drivers` opens Employee Master filtered to Drivers; Transport gets a read-only Drivers list. PO Approval (`warehouse-orders.html`) and Transport Assignment use `lwb_staff_pick('driver')`. Godown Manager for loading still comes from Godown logins (`lwb_godown_managers`), because loading confirmation needs the login. STAFF documents now allow DL (driving licence).
- Free / On trip (1 Nov 2026): `lwb_vehicle_pick()` lists every active Vehicle Master vehicle; it and `lwb_staff_pick` carry `on_trip` = order numbers assigned in the last 10 days, status transport_allocated / allocated / loading / loaded / invoiced / dispatched, with no driver delivery report yet (`lwb_trips_open`, internal). PO Approval and Transport Assignment show free ones first; Vehicle Master shows Free / On trip.
- Test: `tests/employee-roles` (PGlite, 7 tests).

## Employee Master <-> ERP login (1 Nov 2026)
- Mohit asked: whoever is added in Employee Master must show up wherever that post is picked (drivers, Godown Managers, salesmen, task assignees). Tasks, Godown Manager (loading) and salesmen go to a person's own login, so each such employee gets a login linked to the employee.
- SQL: `lwb_employee_login_link_setup.sql`. `lwb_acc_staff.user_id` (unique). Linked by itself when the employee mobile = login mobile (backfill now; trigger on `lwb_acc_staff` insert / mobile change; AFTER trigger `zz_lwb_user_emp_autolink` on `user_profiles` that never blocks a login save). `lwb_emp_create_login(staff, password, role?, email?)` (Admin; role from Work / Post via `lwb_emp_login_role`: Driver=driver, Godown Manager=warehouse, Manager=manager, Salesman=sales, Accounts=accounts, Transport=transport), `lwb_emp_link_login(staff, user|null)` (Admin), `lwb_emp_logins()` (Employee Master keepers + Admin).
- Pages: Employee Master has an "ERP Login" column (role tag, or Admin "Create login" which asks the password and shows the login details to share). Manage Users > Add New User has "From Employee Master" (fills name, mobile, role; links after Create) and shows "Employee EMPxxx · post" on linked users. The pick lists (Tasks `lwb_task_people`, `lwb_godown_managers`, salesman lists) are unchanged: they list logins by role, so a linked employee appears there as soon as the login exists.
- Test: `tests/employee-login-link` (PGlite, 4 tests).

## Documents and photos on every record (31 Oct 2026)
- Mohit asked: staff photo compulsory for every employee / driver / salesman; Aadhaar + bank details of employees; driving licence + Aadhaar of drivers; PAN / GST / shop photo of parties; vehicle photo; fixed asset photos; purchase bill PDF / scan; damage / leakage / breakage photos by the Godown Manager.
- SQL: `lwb_documents_setup.sql`. Private bucket `lwb-documents`, path `ENTITY/<record id>/<DOC TYPE>/<uid without dashes>-<time>-<rand>.<jpg|pdf>`. Table `lwb_documents` (Remove = removed_at, never deleted), `lwb_doc_info` (Aadhaar no., PAN, bank account, IFSC, UPI). RPCs `lwb_doc_add / lwb_doc_list / lwb_doc_summary / lwb_doc_remove / lwb_doc_info_get / lwb_doc_info_save`. Access per record type in `lwb_doc_access(entity, doc_type, mode)` (+ ticked page; driver Aadhaar / bank / PAN only admin, manager, accounts).
- Record types: STAFF (Employee Master, lwb_acc_staff.id), DRIVER (lwb_drivers), USER (logins), VEHICLE, PARTY, SUPPLIER, PURCHASE_BILL (lwb_goods_inward.id: BILL + DAMAGE), ASSET, STOCK_MOVE (first STM no. of a request), ORDER (loading photos).
- **Update 31 Oct 2026 (Mohit): all photos / documents are OPTIONAL for now.** `STRICT` at the top of `erp-docs.js` is empty, so "required" slots show as Recommended (orange "No … " tags, no block on Save; Stock Transfer photo also optional). To make a record type compulsory later add it there, e.g. `STAFF:1`, `DRIVER:1`, `USER:1`, `ASSET:1`, `STOCK_MOVE:1`.
- Shared `erp-docs.js`: `ERPDocs.panel` (camera / gallery / PDF, resizes photos, new record = files wait until `flush(id)`), `ERPDocs.open` popup, `summary`, `badge`, `avatars`. Required slots: photo (+ Aadhaar for employees, licence + Aadhaar for drivers) block saving a NEW record; an old record without them asks before saving and shows "… missing" tags + filter "Documents missing".
- Wired: Vehicle / Driver / Employee Master, Manage Users (new login needs a photo; "📷 Photo & Docs" per row), Party Master, Supplier Master, Goods Inward (bill copy + damage photos after posting), Purchase Register (📎 Bill / Photos, damage photos in Verify), Stock Transfer (photo compulsory to Damage / Leakage / Breakage / Gasless / Expiry and Destroy), Loading & Dispatch (loaded vehicle + damage photos), new `fixed-assets.html` (`lwb_fixed_assets_setup.sql`, Asset ID FA001…, photo compulsory, menu Masters > Fixed Assets).
- A browser can not start a printer's scanner (no web access to TWAIN / WIA). Scan to PDF / JPG with the printer's button or app, then choose the file; on a phone take one photo per page.
- Tests: `tests/documents` (PGlite, 9 tests). Browser check with a mocked client at 1280 / 390 px; no live data written.

## Latest added / edited record first in every list (31 Oct 2026)
- Mohit's rule: in every list the record added, edited, modified, approved or cancelled last comes first.
- SQL: `lwb_latest_first_setup.sql`. Adds `updated_at` (and `created_at` if missing) to the list tables, old rows stay NULL (no mass update), and a BEFORE UPDATE trigger `zz_lwb_touch_updated_at` (function `lwb_touch_updated_at`) sets `updated_at = now()` on every real change. New list tables: add them to the array in that file.
- `lwb_emp_list()` now lives in `lwb_latest_first_setup.sql` too (adds `created_at` / `updated_at`); if `lwb_employee_master_setup.sql` is edited, keep those two fields there.
- Pages: `erp-recent.js` (`ERPRecent.sort(rows)`, newest of updated_at / created_at / cancelled_at / approved_at ... first; `ERPRecent.attach(client, table, rows)` for pages that read only some columns). Load it in the page head; new list pages should call it on load.
- Kept on purpose: PO lists keep Urgent / High first (latest first inside each priority); ledgers and day books stay in date order (running balance); dropdowns stay A–Z; Tasks / Complaint Box already sort by last activity.
- Test: `tests/latest-first` (PGlite).

## Stock Transfer, damage ledger, destroy and Night Audit (31 Oct 2026)

- Mohit asked (photo "Stock Transfer"): Saleable -> Damage / Leakage / Breakage / Gasless / Expiry / Loss, approved by Sales Head or Admin before saleable goes down; a ledger per category; Damage-to-Destroy; a nightly Godown Manager audit where a difference stays open until found, else Loss; a daily report (e.g. 5000 handled, 5 lost).
- SQL: `lwb_stock_transfer_setup.sql`. Tables `lwb_stock_moves` (one row per SKU line, `batch_id` groups a request; buckets SALEABLE, DAMAGE, LEAKAGE, BREAKAGE, GASLESS, EXPIRY, LOSS, DESTROYED, COMPANY_RETURN; status PENDING / APPROVED / REJECTED / CANCELLED), `lwb_stock_audits` (one per date, DRAFT / SUBMITTED), `lwb_stock_audit_lines`. No direct table access; RPCs `lwb_stx_*`.
- Allowed moves: Saleable -> 6 categories (TRANSFER); Damage..Expiry -> Destroyed (DESTROY, witness required) or Return to company; any category incl. Loss -> Saleable (TO_SALEABLE, e.g. lost stock found). All need approval (`lwb_stx_decide`, Admin / MANAGER; a Sales Head cannot approve his own request, Admin can; can approve less). Request checks available stock minus waiting requests; approval checks again.
- Stock link: the old view `lwb_live_stock` is renamed `lwb_live_stock_base`; a new `lwb_live_stock` with the same columns = base saleable + `lwb_stx_adjust()` (approved moves) and damaged_pcs + stock held in Damage..Expiry. So PO Entry, Inventory, Dashboard see it. Skipped with a NOTICE (page shows a warning) if the live object is not a plain one-row-per-SKU view. Undo: drop the new view and rename the base back.
- Night audit (`stock-audit.html`): count sheet per SKU (cases + pcs, ✓ = same as system, optional Blind count, print); draft, then Submit takes system stock at that moment. diff = physical - (system - loss waiting). Next count of a SKU replaces an older OPEN difference (RECOUNTED, `open_since` kept) or closes it as FOUND when it matches. Open difference -> Found (note) or Not found -> Loss (a Saleable -> Loss request, source AUDIT; reject / cancel reopens it). Audit never changes stock.
- Reports (`stock-transfer.html`): Stock Status per SKU, Approvals, History, Category Ledger (running balance + opening), Daily Report (`lwb_stx_daily`: handled = Goods Inward cases + loaded cases that day, transfers per category, loss per 1000 handled, audit result). Excel on each.
- Who: request / audit = admin, manager, warehouse (or ticked page); approve = admin, manager; Accounts view only; Sales / Driver / Transport none. Bells: STOCK_MOVE_PENDING (Admin + Sales Head), STOCK_MOVE_APPROVED / REJECTED (requester), STOCK_AUDIT_DIFF / OK (Admin + Sales Head). Photos go to the private `lwb-godown-photos` bucket.
- Tests: `tests/stock-transfer` (PGlite, 12 tests). Browser check with a mocked client whose RPCs ran this SQL on PGlite at 390 / 1280 px; no live data written.

## MRP-based purchase bills: Rajnigandha (31 Oct 2026)

- Pan masala / tobacco purchase bills charge GST on the **Deemed Taxable Value = Total MRP ÷ (1 + GST%)** (rounded to the rupee), and **Line Total = Net Sale + GST**. Checked on DS Group bill 322HA21087 (total ₹11,11,014.00 before ₹0.02 round off).
- `lwb_companies.purchase_billing` TAXABLE / MRP (Rajnigandha set to MRP; editable in Companies > master). Supplier Master has Company / Brand (`lwb_supplier_master.company_id`): Goods Inward then offers only that brand's SKUs.
- Goods Inward MRP lines: Net Sale, MRP per box (remembered in `sku_master.mrp_per_case`), Deemed Value (fills itself, can be typed). Saved through `lwb_post_goods_inward_mrp` (`lwb_purchase_mrp_billing_setup.sql`), which calls the live `lwb_post_goods_inward` and then writes `billing_mode, net_amount, mrp_amount, mrp_per_case, deemed_value` and `total_amount = net + GST` on the lines. Normal bills still call `lwb_post_goods_inward` directly. Test: `tests/purchase-mrp`.

## Count cards open their list (31 Oct 2026)

- Mohit asked: every card that shows a total number must open the list of the records behind it.
- `erp-list.js` (shared): `ERPList.open({title,sub,rows|load,cols,onRow,page})` shows a searchable list popup with totals (table on web, cards on phone); `ERPList.card(el, make)` / `ERPList.ids({numberId: make})` make a card clickable and add "View list ›".
- `lwb_po_summary_lists_setup.sql`: `lwb_po_summary_orders(card, from, to)` returns the orders behind each PO Approval summary card (same rules as `lwb_po_approval_summary`), and `lwb_daily_summary_list(date, card)` the records behind the Daily Summary cards. Read-only. Test: `tests/po-summary-lists`.
- Wired on: PO Approval, Dashboard (all roles), Loading & Dispatch, Transport Assignment, Accounts Dashboard, Billing & Outstanding, Payment Collection, Party Ledger, Daily Summary, Godown Report, Outside Market Stock, My Sales, Sales Tracking, Party Call List, Purchase Claims, Purchase Register, Sheet & Pallet Ledger, Company PO maker. Pages whose cards already switch the list below (Inventory, Team Work Report, Money Overview, Driver Collections, Driver Returns, Tally Bill Check, Driver phone) keep that.
- A new count card should use `ERPList` the same way.

## Automatic Supabase updates (30 Oct 2026)

- `.github/workflows/supabase-apply.yml`: when a PR is merged to `main`, every root `*.sql` file added or changed in it is run on the live Supabase database (commit order, stops on first error) and changed `supabase/functions/*` are deployed. No more pasting SQL in the SQL editor.
- Needs GitHub Actions secrets `SUPABASE_DB_PASSWORD` (database password; a full Session pooler URI in `SUPABASE_DB_URL` also works) and `SUPABASE_ACCESS_TOKEN` (only for Edge Functions).
- Write SQL so it is safe to run again (`create ... if not exists`, `create or replace`), because editing a file re-runs it.
- `-- lwb:no-auto-run` on a line skips a file (record-only / read-only scripts).
- Drop table/schema/column and truncate are refused unless the file has `-- lwb:allow-destructive`, added only after the owner's written OK.
- Applied files are logged in `public.lwb_sql_apply_log`. Actions > Supabase apply > Run workflow re-applies one named file.

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

## Every salesman in Sales Team Setup; salesman sees only his parties (2 Nov 2026)

- Mohit: SKU Visibility / Targets / Morning Plan tick boxes showed only salesmen that already had a party; and a salesman (e.g. Nadim Tinwala) must see only his assigned parties everywhere.
- SQL: `lwb_salesman_party_scope_setup.sql`. Every SALES login gets a `lwb_salesmen` row (FIELD; OFFICE rows kept), and trigger `zz_lwb_user_salesman_autoadd` on `user_profiles` adds new SALES logins (never blocks the save). `lwb_set_sku_visibility`, `lwb_save_sales_targets`, `lwb_add_sales_plan_note` accept any SALES login (helper `lwb_ensure_salesman`, not callable by users).
- Field salesman (any SALES login not set to OFFICE): restrictive SELECT policy `lwb_sales_party_scope` added on `tax_invoices`, `sales_returns`, `sales_return_items`, `lwb_payment_collections` (only rows of orders visible to him / collections he submitted). `lwb_complaint_add` refuses a party or PO that is not his. Party Master, orders, order items, Party Call List, party activity, ledger / outstanding were already limited.
- `sales-team.html` lists every active SALES login in all tabs, and on Salesmen shows Employee Master "Salesman" posts that have no ERP login yet. `complaint-box.html` party field is a dropdown of the user's own parties (`party-list.js`).
- Compact format (Mohit, standing rule for every page): small inputs that never clip text, tight table rows, buttons in one row, no side scroll on phone. `sales.css` now has `.sl-stack` (phone: one compact card per table row, labels from the header); Sales Team Setup uses it on every tab.
- Sales Heads too (2 Nov 2026, `lwb_sales_head_in_team_setup.sql`): `lwb_sales_team()` also returns MANAGER logins (Sales Heads first); they can get parties / targets / area (row in `lwb_salesmen` as OFFICE). Mohit chose: a Sales Head still sees every party. Not in SKU Visibility (Sales Heads always see every SKU).
- Test: `tests/salesman-scope` (PGlite, 5 tests). Browser check with a mocked client at 1366 / 390 px; no live data written.

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
- driver-delivery.html: order cards have a "💰 Payment" button (next to Return) that opens the Delivery tab at the payment entry (change form if already reported). Payment box = Net / Received / Outstanding at the top, Cash note count (500/200/100/50/20/10 with − / + buttons, plain text boxes so no spinner / mouse-wheel change, + coins) with auto total, UPI/Bank/Cheque amount + reference + 1–3 screenshot photos (bucket lwb-delivery-pod, path uid/order/upi-*.jpg). Submit goes through `lwb_driver_submit_delivery_with_payment` (old submit + `lwb_driver_save_payment`). After delivery the driver sees the payment and can correct it until Accounts verifies. Unpaid remainder = outstanding. Cards show "💰 Received • Outstanding • status".
- driver-collections.html (Admin / Accounts / Sales Head, menu Delivery): To verify / Outstanding / Verified / Rejected; Verify or Reject (reason) via `lwb_review_driver_collection`, which notifies the driver (DELIVERY_COLLECTION_VERIFIED/_REJECTED). Verify does NOT post ledger / Cashbook / Tally. Cashbook "Driver cash (ERP)" now takes only the cash part.
- Return approved → trigger `trg_lwb_return_approved_notify`: DELIVERY_RETURN_RECEIVE to WAREHOUSE (urgent popup "📦 Receive returned goods", snooze lwbReceiveSnooze) and DELIVERY_RETURN_DEDUCTED to Accounts/Admin (bill, return cut, collect). driver-returns.html Approved tab: "📦 Goods received" button (warehouse/manager/admin, `lwb_receive_return_goods`), which marks the receive notification read.
- Fix (27 Oct 2026): `lwb_driver_payment_photo_fix.sql` adds storage policy `lwb_delivery_pay_photo_upload` so drivers can upload `upi-*` payment photos in `uid/order_id/` for an order assigned to their phone or reported by them, any order status, until the payment is VERIFIED (the old POD policy needs status loaded / invoiced).

## Loading workflow: Godown Manager, Vehicle Loaded, Tally invoice no. (2026-10-27)
- SQL: `lwb_loading_workflow_setup.sql` (after `lwb_driver_payment_setup.sql`, last SELECT 6 rows true).
- PO Approval & Driver / Transport Assignment: "Godown Manager (Loading)" dropdown of active WAREHOUSE logins (`lwb_godown_managers()`), saved as `dispatch_assignments.loading_manager_id` + `loading_person` (name). Free-text box stays until the SQL is run. Assignment bell (`lwb_notify_loading_assignment`) now goes to that Godown Manager only (all godown staff when none chosen), Sales Head and the driver; the old manager gets "Loading moved" on a change.
- Loading & Dispatch: WAREHOUSE opens on "My Vehicles to Load"; only the assigned Godown Manager (Sales Head / Admin always) can Start / "✅ Confirm Vehicle Loaded" (screen check + trigger `trg_lwb_orders_loading_guard` on orders.status). Status stays `loaded` (shown "VEHICLE LOADED").
- Status → loaded: `trg_lwb_notify_vehicle_loaded` sends TALLY_BILL_PENDING to Accounts (urgent popup "Make Tally bill" until the invoice no. is saved) and VEHICLE_LOADED to Sales Head + Admin.
- Tally Bill & Invoice No. (`accounts-invoice.html`, now in menu Accounts): Accounts enters the Tally invoice no(s) (comma for several brand bills) + date via `lwb_save_tally_invoice`. Table `lwb_tally_invoices` is readable only by Accounts / Admin. First save marks TALLY_BILL_PENDING read and sends TALLY_BILL_DONE (no number) to Sales Head + Admin. orders.status is not changed.
- Driver: `lwb_driver_my_delivery_orders()` wraps `lwb_driver_list_delivery_orders()` (now not executable by logins) and drops a driver's order 12 hours after its delivery report; restrictive policy `lwb_delivery_report_driver_12h`; bell and driver page show only the last 12 hours of notifications.
- Responsibility: driver returns approved / rejected by WAREHOUSE (Godown Manager), Sales Head or Admin (Accounts view only; Accounts no longer get DELIVERY_RETURN_PENDING, filter trigger `trg_lwb_notification_route_filter`). Driver payments verified by Accounts or Admin only (Sales Head views).
- Sales Head copy: deferred trigger `trg_lwb_notify_sales_head_copy` copies every order notification (with order_id) of other logins to active MANAGER users as `CC_<type>` unless they already got one of the same kind for that order in the transaction. CC rows open the same page and never pop up. Errors are swallowed so they never block a save.
- Transport assignment popups (2026-10-27, no SQL): driver gets a one-time "🚚 New Transport Assignment" popup (LOADING_ASSIGNMENT_DRIVER, "Open order"). The assigned Godown Manager gets an urgent "🚛 Vehicle Loading Assignment" popup (LOADING_ASSIGNMENT_DISPATCH titled "Load This Vehicle"; again 15 min after Later, localStorage lwbLoadSnooze) until he opens that order on loading-dispatch.html (?order=<id> opens it and marks the notification read).
- PO Approval (2026-10-27, no SQL): Sales Head can change an approved PO (SKU, cases, rate, weight, note) until loading starts: footer button "Save Changes" (`canEditItems`), status and Driver / Vehicle stay; Cancel only while pending. List rows of approved POs have "🚚 Transport" (opens the order at Driver / Vehicle / Godown Manager) and "🖨 Print" next to Review / View. PO print is now A4 portrait with larger text and a "LUXURY WRIST BRAND" heading. Salesman's own change before approval was already there (My Sales > Modify Order).
- 🚚 Transport button (2026-10-27): opens the review modal in `transport-only` mode (CSS class on #reviewModal): a 620px popup with party / CS / KG / ₹ line, the Driver / Vehicle / Godown Manager / Mobile / Transport fields, and Close + Save in the footer; it closes 1.5 s after a successful save. Review / View still open the full modal.

## PO Print = Delivery Challan format (2026-10-27)
- 🖨 Print on PO Approval now prints a "DELIVERY CHALLAN / Order Bill" on A4, matching the format Mohit shared: Order No, Customer, Transportation, Date & Time, Sales Person, Total Items; a line with Godown Manager, Driver (mobile) and Vehicle No; SKU table with Qty, Rate, Amount, Unit Wt, Total Wt; totals with KG; Amount in Words; manager note if any.
- Footer still says it is not a GST invoice; the Tally bill is separate.
- Update: the challan now prints A4 **landscape**. If a PO has no saved Driver / Vehicle / Godown Manager, Print asks first: "🚚 Assign now" opens the Transport popup, "Print without them" prints with "—".

## Tally bill amount, credit / debit notes, money due per invoice (2026-10-27)
- SQL: `lwb_tally_bill_flow_setup.sql` (run after lwb_loading_workflow_setup.sql, lwb_driver_payment_setup.sql, lwb_cashbook_secure_setup.sql).
  Adds `lwb_tally_invoices.amount`, table `lwb_tally_notes` (CREDIT / DEBIT, Tally note no., date, amount, reason; cancelled, never deleted),
  `lwb_save_tally_bill` (wraps lwb_save_tally_invoice + amount), `lwb_save_tally_note`, `lwb_cancel_tally_note`,
  `lwb_tally_bill_status(p_days)` (Accounts / Admin) and `lwb_cashbook_invoice_due(p_key)` (Cashbook). Both read the internal `lwb_tally_bill_rows`.
- Due = Tally bill amount − credit notes + debit notes − money drivers reported (rejected payments left out). No Tally bill amount yet: ERP net (loaded × rate − approved returns).
- accounts-invoice.html: every row shows the driver's delivery report (Delivered / Part delivered / Not delivered / On the way); the order status stays "loaded" after delivery.
  Tabs Tally bill pending (inline invoice no. + date + amount + Submit; loaded POs, or dispatched / delivered in the last 30 days) /
  Money to collect / Credit note pending (approved return not yet covered by credit notes) / All. The PO modal keeps ERP bill create + print and lists the notes.
- tally-note.js: shared credit / debit note popup. Driver Collections opens it after Verify when a return still needs a credit note (or a delivery with a return is short);
  Driver Returns opens it for Admin after Approve.
- cashbook.html: "Money due (Tally bills)" button in a book (Cash In pre-filled with the due amount); Driver cash list shows the Tally bill no. and due.
- tally-check.html: first matches the bill no. Accounts entered against the register (amount must equal the amount entered), then the old party / date / amount match.
  New result "Bill no. entered, not in Sales Register" (query kind no_tally). Rows matched by party / date with a different bill no. are flagged.
- Receiver name optional (27 Oct 2026, Mohit): `lwb_driver_receiver_optional.sql` relaxes `lwb_delivery_proof_required` to POD photo only and removes the receiver check from `lwb_driver_submit_delivery` (string replace on its current definition). driver-delivery.html shows "(optional)". POD photo is still required for Delivered / Partial.
- POD photo optional (27 Oct 2026, Mohit, after a POD upload RLS error on LXY-00013 he said to leave the upload fix): `lwb_driver_pod_optional.sql` drops `lwb_delivery_proof_required` and switches off the "POD photo required" test in `lwb_driver_submit_delivery` (regex on the live definition). driver-delivery.html: photo "(optional)"; if a chosen photo fails to upload, the driver is asked to submit without it. A draft fix for the upload RLS (SECURITY DEFINER check `lwb_driver_can_upload_pod`) is on branch `driver-pod-upload-fix`, not merged or run.
- Delivery and Payment separate (27 Oct 2026, Mohit): driver popup has its own **💰 Payment** tab. Delivery tab = status, receiver (optional), POD (optional), note → "Submit Delivery" calls `lwb_driver_submit_delivery` with no collection. After a Delivered / Partial submit the Payment tab opens with the payment form (note count, UPI + photo, outstanding) → `lwb_driver_save_payment`. Before delivery the Payment tab says "Submit the delivery first". Cards show "💰 Payment not entered • Outstanding ₹…" until a payment is saved. `lwb_driver_submit_delivery_with_payment` is no longer used by the page.

## Tally bills in sub-firm names (2026-10-27)
- SQL: `lwb_tally_subfirm_bills_setup.sql` (after lwb_tally_bill_flow_setup.sql). Adds `lwb_tally_invoices.bills` jsonb [{firm, no, amount}]
  and `lwb_save_tally_bills(p_order_id, p_invoice_date, p_bills, p_note)`: invoice_no = the numbers joined, amount = total.
  A bill no. is unique per firm (each Tally company numbers its own bills). A sub-firm used is linked to the PO's party in `lwb_tally_party_map`
  (refused if it is already linked to another party), so money, notes, Cashbook and Tally Bill Check stay under ONE main party.
- accounts-invoice.html: one line per Tally bill (firm from the party + its linked sub-firms, invoice no., amount), "+ Sub-firm bill" adds a line.
- tally-check.html: a bill no. matches only a register row of that firm or of a Tally name linked to the PO's party; "same bill no. twice" is checked per file (one file = one Tally company).

## Tally bills from Accounts show in the Cashbook automatically (2026-10-27)
- SQL: `lwb_cashbook_erp_bills_setup.sql` → `lwb_cashbook_erp_bills(p_key)` (last 365 days, bills with an amount; lines, credit / debit note totals).
- cashbook.html `erpFeed()` adds each bill line to `tallyFeed()` under the PO's MAIN party (tallyMatch of the ERP party name), so it shows in
  Outstanding, the party ledger (chip "ERP · PO …"), and the Cash In "Pending bills" list. Credit notes minus debit notes go on the first line as "Credit note".
  A line whose bill no. + amount is already in the imported Tally register is skipped (no double count).
- "Money came: Cash In" (Money due list) and Driver cash "Add as Cash In" select the pending bill when exactly one fits, keeping the amount received.

## Tally Party Mapping: sub-firm -> main party, once (2026-10-28)

- New page `party-mapping.html` (Accounts > Tally Party Mapping, admin/accounts). It edits the same `lwb_tally_party_map` table that Tally Bill Check and the sub-firm bill lines use, through `lwb_tally_party_maps` / `lwb_tally_set_party_map`. No new SQL for the page.
- Three ways to map: type a main party + its sub-firms; choose the Tally Sales Register file (every name that is not an ERP party and not mapped yet is listed, pick the main party, Save all filled); or Excel export / import ("Tally Party (Sub-firm)", "Main Party (ERP)"). The main party must be in the ERP Party Master. Moving a firm that is already under another party asks first. × removes a link.
- Cashbook: `lwb_cashbook_party_maps_setup.sql` (`lwb_cashbook_party_maps(p_key)`, read only). `tallyMatch` uses it after the Cashbook's own saved Tally map, so imported register bills and ERP bills of a sub-firm go to the main party (chip "party mapping").
- Bulk (Mohit, 28 Oct): the upload takes the Tally **List of Ledgers** too (Name / Party / Ledger column, else the first column), not only the Sales Register. Every name is listed in tabs Need mapping / Mapped or skipped / Same as ERP party; the main party is chosen from the ERP list (a name not in the Party Master is refused), a close ERP name is pre-filled as "suggested · check", and Skip marks a non-party ledger (saved as skip, customer_name NULL). "Download to fill in Excel" gives the list for Import Excel; blank main-party rows are ignored on import.
- Rows (Mohit, 28 Oct): the page now keeps the full Tally party list (`lwb_tally_party_list_setup.sql`: table `lwb_tally_parties`, `lwb_tally_party_list()`, `lwb_tally_add_parties(text[])`, `lwb_tally_remove_party(text)`, all gated by `lwb_tally_check_user()`). Accounts adds names once (paste or file); every Tally party is a row with a Main party box (ERP list only) that saves on change. Tabs: Main party not set / Mapped / Skipped / All. The "one main party, many sub-firms" form and Excel stay below. Names already linked show even without the SQL.

## PO sales vs Tally sales, Tally stock vs ERP stock (2026-10-28)

- Tally Bill Check now shows at the top: PO sales (ERP, dispatched POs in the dates), Tally sales (Sales Register, skipped names left out) and the difference, split into GST on matched bills and "Not explained" (red when over ₹1). "Party wise: PO vs Tally" lists each party's PO total, Tally total and unexplained difference (Excel has a Party wise sheet). The result popup counts parties that differ.
- New card "Tally stock vs ERP stock": choose the Tally Stock Summary; items matched by name with `lwb_live_stock` (saleable pcs). A Tally quantity in box / case / ctn is compared with ERP cases, else pieces. Shows Quantity differs / In Tally only / In ERP only. Read only, no SQL.

## Money Overview for Accounts (2026-10-28)

- New page `money-overview.html` (Accounts > Money Overview, admin/accounts), data from `lwb_accounts_money(p_days)` (`lwb_accounts_money_setup.sql`, read only): every loaded PO of the last 120 days from `lwb_tally_bill_rows` plus delivery time, collection time, verify time, payment status, driver and vehicle.
- "Right now": 1 Loaded, Tally bill pending · 2 Bill made, not delivered yet · 3 Money with drivers (collected, payment PENDING) · 4 Outstanding with parties (over 30 days in red) · 5 Received (verified + Cashbook). Period strip (Today / Yesterday / 7 days / month / dates): bills made, delivered, driver collected, verified, Cash In at office.
- Lists: Outstanding party wise (aging 0–7 / 8–30 / 30+, expand to bills), Money with drivers (driver wise, link to Driver Collections), Not delivered yet, Tally bill pending (link to Tally Bill & Invoice No.), All POs; Excel of each.
- Cashbook: when this browser has the Cashbook key (`localStorage.lwbCbKey`) and the user can open the Cashbook, `lwb_cashbook_load` is read: Cash In entries with an invoice no. of an ERP bill (not driver cash added from the ERP, `erpRef`) reduce that bill's outstanding; Cash In entries not from drivers are the "Cash In at office" figure. Nothing is written.

## Complaint Box (29 Oct 2026)

- SQL: `lwb_complaint_box_setup.sql` (run once; check = 4 rows, all true). Tables `lwb_complaints` + `lwb_complaint_replies`, private bucket `lwb-complaint-photos`.
- `complaint-box.html` (every role, menu item under Dashboard): any login raises a complaint / query (Market, Godown, Driver / Delivery, Accounts / Payment, Other) with optional PO, party, photo, Urgent.
- RLS: a login reads only his own complaints; Admin + MANAGER read all. Writes only through `lwb_complaint_add(p)` and `lwb_complaint_reply(id, body, status)`.
- Status OPEN (waiting for office) → ANSWERED (office replied) → RESOLVED. Staff reply sends it back to OPEN; staff can tap "Problem solved"; a reply on a solved one opens it again.
- 🔔 COMPLAINT_NEW / COMPLAINT_REPLY / COMPLAINT_CLOSED to Admin + Sales Head; COMPLAINT_REPLY / COMPLAINT_RESOLVED to the raiser. Bell and popup open `complaint-box.html?id=N` (from "CMP-N" in the message).
- Dashboard Verify / Quick Actions: "Reply to complaints" (Admin / Sales Head, OPEN from others) and "Reply on your complaint" (any other role, ANSWERED).

## Website launch checklist (29 Oct 2026)

- Public pages: `index.html`, `privacy.html`, `terms.html` (style `assets/legal.css`), branded `404.html` (Cloudflare Pages serves it for any missing page).
- Homepage Gallery (30 Oct 2026): 20 warehouse / office photos in `assets/gallery/` (1800px, metadata and GPS removed) with 720px copies in `assets/gallery/thumbs/`. `index.html` shows them in a `#gallery` section (Facility, Warehouse Floor, Office & Dispatch, Stock on Hand) with a tap-to-enlarge viewer (swipe / arrow keys); hero background uses `05-warehouse-floor-1.jpg`. To add a photo: put both sizes in those folders and add one `gallery-item` button.
- `_headers`: every page gets `X-Robots-Tag: noindex` (ERP stays out of Google) except `/`, privacy, terms, robots, sitemap and `og-image.png`; plus HSTS, nosniff, SAMEORIGIN framing and referrer policy.
- `robots.txt`, `sitemap.xml`, `og-image.png` (1200×630 social preview), `favicon.ico` / `favicon-32.png`. Absolute URLs use `luxury-wrist-brand.pages.dev`: change them in `index.html` (canonical, og:url, og:image), `robots.txt` and `sitemap.xml` when a custom domain is added.
- Analytics: turn on Cloudflare Web Analytics in the Pages project (no code, no cookies, so no cookie banner needed).
- Homepage "WhatsApp Us" = office 9274382694; "Call Us" list (office, Coca-Cola sales Harsh / Vishal, Rajnigandha sales Vinas, accounts Yogesh) uses tel: links.

## Party Call List: parties with no order in time (29 Oct 2026)

- SQL: `lwb_party_call_list_setup.sql` (after the sales team SQL; check = 4 rows, all true). Column `lwb_customer_master.order_every_days` (1-90, blank = not on the list), table `lwb_party_calls` (read: Admin / Sales Head all, salesman own calls + calls on his parties; writes only via `lwb_party_call_save(p)`).
- `party-calls.html` (menu Sales, roles admin / manager / sales). Call List: parties whose last order (not cancelled) is N+ days old or never; salesman = his assigned parties, Admin / Sales Head = all (filter by salesman, "Office" = no salesman). Each card: 📞 Call (`tel:+91`), WhatsApp, + PO, Save call result: Order taken / Will order later (date 1-30 days, hidden until then) / No order (reason required) / Not reachable.
- A party called today moves to "Called today" and comes back the next day if still no order; a new PO removes it.
- Call Report (Admin / Sales Head; salesman sees "My Calls"): date range, caller, result, "Why parties did not order" counts, Excel. Set Order Days (Admin / Sales Head): per party box or tick many + "Set for selected" (`lwb_set_party_order_days`).
- Dashboard Verify / Quick Actions: "Call parties: no order in time" with count (`lwb_party_call_due_count`). No bells; orders, stock, ledger and Tally are not changed.


## Compact workspace for all roles (29 Oct 2026)

- `order-entry.html`: `compact-entry` is a presentation class for every allowed role; `sales-entry` remains SALES-only for existing role restrictions and saved vehicle behavior. Admin / Sales Head get the same compact mobile SKU cards, transport chips, total weight and fixed Submit Order bar. Date, company, sales person, slab and vehicle controls stay in More options; landing / margin is opt-in. Print temporarily expands metadata. No SQL or calculation changes.
- Shared `erp-shell.css` / `erp-shell.js`: compact spacing on the 43 pages using the shell, smaller header / bell, searchable mobile side menu, role-specific phone shortcuts respecting per-user page access, keyboard-aware footer and contained report-table scrolling. Driver keeps its existing bottom navigation. Public landing / legal / login pages and standalone Cashbook are outside this shared shell.
- `erp-operations-notifications.js`: removed automatic notification dialogs and repeated reminders. All notification rows, unread counts, routes and manual read controls remain in the bell. Explicit action errors / confirmations remain. Removed the shared observer that duplicated inline save successes as toasts.
- `_headers` revalidates the shared UI assets and PO Entry after deploy.
- Verification: JS syntax and diff checks; local browser mock (no production calls / writes) at 390px and 1280px for Admin / SALES PO entry, PO Approval, Dashboard, Inventory and warehouse Loading. PO entry: 40×640 + 50×520 = ₹51,600; 90 cases / 1,810 kg. PALLET: 1 pallet = 100 cases, ₹64,000 / 1,900 kg with the mock SKU. Sidebar stock search and quiet notification count verified. Other module checks are layout-shell checks, not a full live workflow verification. Real-device login / populated business data should still be checked by staff.


## Dashboard card layout correction (29 Oct 2026)

- User screenshot showed KPI groups squeezed side by side, overlapping labels / sales amounts, and the search icon over its placeholder. `dashboard.html` now uses a grid with individual metric cards (groups are display:contents), slate / green / amber / blue / red accents, wrapping labels and separate footer text; very long money values span the phone row. Search restores 40px left padding. Compact name + role badge replaces the long role explanation.
- Removed the Dashboard Quick Access section and its renderer. `erp-shell.js` does not create the fixed bottom shortcut bar on Dashboard, including after page-access refresh. Other pages keep their quick menus; Pending Work, module search and the side menu remain.
- `_headers`: Dashboard HTML revalidation added.
- Verification used actual Dashboard startup/rendering with a local read-only Supabase mock and the exact `dashboard.html` filename (so production page-specific selectors apply). Populated Admin / Manager fixtures checked at 320 / 390 / 1280 CSS-pixel frames, including ₹1,64,970 and ₹1,23,45,67,890. No metric overflow / text overlap / page horizontal overflow; no Dashboard bottom nav or Quick Access list; zero mock writes and no JS errors.


## Dense PO Entry — five SKU cards (29 Oct 2026)

- Removed Party's usual SKUs UI and its renderer / quick-add helper; party last-rate lookup and rate autofill are retained. Removed Entry help. Admin / Manager landing-and-margin toggle moved inside More options.
- Phone SKU cards use two short rows: SKU / remove, then Qty / Rate / Amount. Direct Vehicle CS mode also includes Pallet in the second row. Mobile rate ± buttons are hidden; rate is edited directly in its numeric field. Card padding / margins, Add SKU, total-weight and share spacing reduced. Informational stock / rate hints stay out of the compact row; low-stock and below-slab warnings still appear. Per-role restrictions, save logic and calculations are unchanged.
- Browser test with actual order-entry.html filename and mocked read-only Supabase: five populated cards are 99 CSS px high, and all five fit in the SKU-list viewport at 360×740 / 390×844; checked desktop 1280×900 and SALES / Admin roles. Direct Vehicle stays at 99px. Totals = 150 cases / ₹83,800 / 2,320 kg; rate edit 640→650 makes ₹84,200. No horizontal overflow or JS errors, zero writes.


## Phone Web Push (29 Oct 2026)

- Live Supabase migration `lwb_phone_web_push` applied; `lwb-web-push` Edge Function deployed and bootstrap succeeded (enabled=true, key pair generated inside server). Trigger on new ERP notifications and retry cron are installed; cron verification succeeded. No phones subscribed yet at server verification.
- `erp-push.js` adds Enable phone alerts / Test / Turn off inside the existing bell. No unsolicited in-page dialogs. `sw.js` handles encrypted phone pushes, recipient/device identity checks, same-origin clicks and post-login destinations. Explicit logout unsubscribes. `warehouse-orders.html?order=…` opens the authorized PO. Existing bell routes and recipients are preserved.
- Login reminder (2 Nov 2026, Mohit asked): on a phone (Android / iPhone UA), if server push is ready and this login has no active subscription, `erp-push.js` shows a "Turn on phone alerts" popup (Later / Allow) once per app open / login (sessionStorage `lwb-push-asked-<user>`, cleared on sign-out). Allow subscribes straight from that tap. If notifications are blocked, it shows Settings steps instead (no OS prompt possible). Desktop and already-on phones see nothing.
- Idle logout fix (2 Nov 2026, Mohit: no notifications after enabling): the 15-minute idle logout (and any expired session) fired SIGNED_OUT, which made `erp-push.js` unsubscribe the phone, so alerts died a few minutes after Enable. Now only a Logout tap (erp-shell.js sets localStorage `lwbPushLogout`) or a different user's login disconnects the phone; idle logout keeps alerts on.
- Android permission fix (2 Nov 2026, Mohit: Enable phone alerts did nothing in the Play app): manifest lacked androidbrowserhelper's `NotificationPermissionRequestActivity`, which Chrome needs to show Android 13+'s Allow dialog inside a TWA. Added it plus a status-bar `SMALL_ICON` (drawable/ic_notification.xml). Needs a new AAB upload to Play.
- Android manifest declares POST_NOTIFICATIONS, so the signed APK must be updated on Android for notification permission delegation. Existing TWA DelegationService remains. See README_PHONE_PUSH.md for staff steps, safe bootstrap, privacy, delivery limits and recovery.
- Seven Node tests pass: endpoint validation, encrypted round-trip, routes, service-worker recipient gating/clicks, opt-in/rebind/logout behavior. Live unauthorized dispatch/bootstrap/test return 401; registration rejects unsafe endpoints; tables/ACLs/RLS and cron verified. Private keys never returned to the client or stored in Git. Real phone permission + Test are the final device verification.

## Compact workspace throughout ERP (29 Oct 2026)

- Removed static introductory instruction banners from Accounts, Customer Master, Payment Collection, Group Loading and Driver Delivery. Accounts no longer opens with the large yellow Tally instructions. Runtime error/status nodes and business scripts/IDs are retained.
- Shared screen-only layout across all 43 ERP pages: reduced nested main padding, cards, forms, modal padding and tables; phone summary cards use two columns; tabs scroll within their panel; input text remains 16px and touch controls at least 40px. Accounts amounts remain readable. Dashboard hero margins match the narrower page gutter. Print styles remain separate.
- Successful ERPShell.alert calls now give a short inline live-region acknowledgement instead of a blocking success dialog. Error alerts, confirmations and prompts remain. Phone Web Push, permissions and notification recipients are unchanged.
- QA: browser inspected static fixtures for all 43 pages at 360px, no page overflow. Populated read-only mock Order Entry at 360/390/1280: five 99px phone SKU cards, correct 150 cases / ₹83,800 / 2,320kg, no errors or writes. Populated Dashboard at 320/390/1280: no card overlap or page overflow, no quick-access/bottom nav. Accounts 390px: no yellow banner, two-column summaries and contained tab/table scrolling. Verified success feedback has no dialog, error opens dialog and delete still requires confirmation. Business-script and element-ID comparison passed for all five HTML edits; JS syntax, whitespace check and existing seven push tests passed. Live business transactions were not created for QA; this is a presentation update, not certification of every operational workflow.

## Admin / Sales Head direct PO approval (29 Oct 2026)

- New Supabase RPC `lwb_head_create_approved_po` creates the PO header and SKU rows atomically with status=approved, approved_qty=ordered_qty, loaded_qty=0, approved_by/created_by=auth.uid(), and server approval timestamp. Totals are calculated from submitted quantities/rates and current SKU Master weights. Pallet quantities validate against current master cases/pallet. Pending-review notification trigger is skipped by the approved status.
- RPC is SECURITY INVOKER with empty search_path; anonymous EXECUTE revoked, authenticated granted, then actual active user_profiles role must be admin/manager. Extra page access, supplied salesman name and user metadata do not confer auto-approval. No RLS or grants on business tables changed. Existing party/KYC insert guard still runs.
- Order Entry uses the RPC only for a new PO by actual Admin / Sales Head login (retained before page-role mapping); button reads Save & Approve PO. Ordinary salesman submissions still use pending_approval and existing review. Existing pending POs and edit flow are unchanged. Approved PO is ready for transport assignment, not loaded or dispatched.
- Migration `lwb_head_po_auto_approval` applied live. Live checks verified caller role guard for all existing profiles plus anonymous, without inserting orders; RPC privileges/search_path/invoker verified and security advisor has no finding for this function. Six isolated PostgreSQL (PGlite) tests cover both allowed roles, denied roles/inactive/login, server identities/totals, invalid and duplicate SKUs, pallet snapshots, transaction rollback on SKU insert failure, and unchanged salesman pending notifications. Browser preview uses mocks only; no live test orders created.

## Compact Transport + saved PO Print / Edit (30 Oct 2026)

- Transport form uses two compact columns on phone: Driver/Mobile, Vehicle/Godown Manager, full-width optional Transport. Existing driver selection autofills mobile and configured default vehicle/transporter. Removed static explanatory paragraphs and normal directory-count hints; runtime warnings remain. One short Save Transport action stays in the footer. Fixed shared modal height conflict so the phone footer covers the full viewport cleanly.
- New Print PO actions appear on non-cancelled order cards and review/transport footer, including pending POs. PO printing does not require driver allocation. Delivery Challan remains separately labelled and retains approval/assignment handling. Printing reads the current saved header, items and assignment for that exact PO; unsaved SKU/note/transport changes block printing. PO status and printed time appear on the copy; it remains distinct from the Tally invoice.
- Approved editable orders now say Edit PO in the list; Save PO stays available before loading. Existing loading lock remains. New Admin/Sales Head PO creation reveals direct Print PO and Edit PO links to that saved order, using the existing authorized order deep link. No business-table or permission changes.
- Verification: five Node VM tests cover latest saved print quantities/rates, pending PO vs challan eligibility, unsaved changes, cancellation, escaping and driver autofill. JS syntax and whitespace checks pass. Browser mocks verified 360/390px phone layout (two columns, 191px transport grid, 57px footer, no overflow/errors), driver/mobile/default vehicle autofill, Print PO without allocation, and editable review footer. No live business test orders or assignments created.

## Accounts Dashboard: cash in / out, bank deposit, night handover, bank check (30 Oct 2026)

- SQL: `lwb_accounts_dashboard_setup.sql` (after `lwb_party_payment_collection_setup.sql`). Page `accounts-dashboard.html` (menu Accounts > Accounts Dashboard, admin + accounts; Accounts phone bottom bar "Cash"; link card on the Dashboard for admin / accounts).
- Money lines are read from their own tables, never copied: Payment Collection (`lwb_tally_payments`), driver money once Office received / verified it (`lwb_delivery_reports`, cash part and UPI part), old `lwb_payment_collections` POSTED, plus new manual entries `lwb_acc_entries` (Cash In with a head, Cash Out / expense with a head, Bank Deposit, Cash from Bank). The private Cashbook is not read. ERP money counts on the India date it was entered / received at the office; entered after that day was closed → next day.
- Heads: `lwb_acc_categories` (seeded Food, Canteen, Salary, Labour charge, Maintenance ...; Accounts adds, Admin switches off). Banks: `lwb_acc_banks` (opening balance + "as on" date, Admin only after creation).
- Cash in hand: `lwb_acc_cash_at(date)` = last night's counted cash (or what came back in the morning) + cash lines after it. First opening cash set once on the page (`lwb_acc_set_opening`; again only by Admin). Night: Close Day counts notes, hands cash to an active Admin / Sales Head (`lwb_acc_close_day`, bell ACC_CASH_HANDOVER; short / extra → ACC_CASH_DIFF to Admin). Morning: "Cash received back" (`lwb_acc_cash_returned`). A closed day takes no more manual entries; Admin "Reopen" cancels the last close (`lwb_acc_reopen_day`).
- Bank check: every UPI / Bank / RTGS / Cheque receipt and every cash deposit waits until Admin verifies it with the bank chosen (`lwb_acc_verify`, `lwb_acc_verify_line`); only verified money counts in the bank balance. One unread ACC_BANK_VERIFY bell per Admin is kept up to date (triggers on new UPI/bank Payment Collection and driver online money; manual entries). Rejection → ACC_BANK_REJECTED to whoever entered it.
- Tests: `tests/accounts-dashboard` (PGlite). Browser check used a mocked client whose RPCs ran this SQL on PGlite; no live data was written.

### Accounts Dashboard round 3: staff ledger, bill photo, GST bill, DD/MM/YYYY date box
- SQL: `lwb_accounts_staff_setup.sql` (after `lwb_accounts_dashboard_setup.sql`). Staff master `lwb_acc_staff` (monthly salary, opening balance: + = to pay him, − = upad with him) and month salary rows `lwb_acc_staff_salary`.
- Salary paid / upad are normal Cash Out entries (heads Salary / Staff advance, `staff_link`) with `staff_id`; upad given back is Cash In head "Staff advance return". Staff ledger = opening + month salaries − paid − upad + returned (`lwb_acc_staff_list`, `lwb_acc_staff_ledger`).
- Entries now carry `photo_paths` (private bucket `lwb-acc-bills`, folder = user id, max 5), `gst_bill`, `gst_amount`, `gstin`. Page saves through `lwb_acc_add_entry2`; extras read through `lwb_acc_extras`.
- Every date on the page is a custom DD/MM/YYYY text box with a 📅 calendar button (`dateBox()`), so the phone / browser locale can not show MM/DD.
- Tests: 8 PGlite tests.
- Add entry form follows the Cashbook layout: Cash In / Cash Out, Date (DD/MM/YYYY) + Time, Party (type name or short code; staff, Party Master `lwb_customer_master`, names used before), Amount + Count notes, Remark, Category + Payment mode, "Bill no. · photo · GST" fold, Save & add new. Time and note count are saved in `lwb_acc_entries.entry_time` / `cash_notes`.

### Accounts Dashboard: vehicle-wise expenses (30 Oct 2026)
- SQL: `lwb_accounts_vehicle_setup.sql` (after `lwb_accounts_staff_setup.sql` and `lwb_fleet_master_setup.sql`). `lwb_acc_entries.vehicle_id` → `lwb_vehicles` (Vehicle Master). New OUT heads: Vehicle service, Tyre, Driver bhatta / food, Toll / Parking, RTO / Insurance / PUC, Vehicle washing.
- Cash Out: pick the vehicle in "Paid to" (type the number, spaces ignored); page saves through `lwb_acc_add_entry3` (vehicle only on Cash Out, not with staff). Vehicles tab = `lwb_acc_vehicle_report(from,to)` per vehicle and head, `lwb_acc_vehicle_ledger(vehicle,from,to)`, Excel.
- Tests: 9 PGlite tests (then 10 with cheques).

## Billing & Outstanding: one flow after loading, group party, party payment with advance (30 Oct 2026)
- Mohit asked: remove Money Overview, Tally Bill & Invoice No., Tally Bill Check, Tally Party Mapping from the Accounts menu (now `hide:1`; pages still open by link, Manage Users can still tick them) and give one clear flow.
- New page `party-billing.html` (Accounts > Billing & Outstanding, admin/accounts; Accounts phone bar "Bills"). Tabs: **Bills to make** (POs whose loading is signed, no Tally bill yet: one line per bill = bill-in name + invoice no. + amount + DD/MM/YYYY date, `lwb_save_tally_bills`), **To collect** (main-party wise: bills due, advance, to collect; expand = each bill with its names/amounts, credit note, Receive, Adjust advance, Ledger), **Payments** (party payments with their split; × undo a split, Cancel a wrong payment), **Party groups** (main party + bill names under it). `accounts-invoice.html` without `?order=` now opens this page; TALLY_BILL_PENDING bell opens `party-billing.html?order=`.
- Group party = the existing links `lwb_tally_party_map` (bill name / ERP party → main party). `lwb_party_parent(name)` follows them. Party Ledger (`lwb_party_ledger`) and `lwb_party_bills` now give every row on the main party; Tally bills are one ledger row per bill line ("bill in PRIYA TRADERS").
- SQL `lwb_party_group_billing_setup.sql`: `lwb_tally_payments.order_id` may be NULL with `party` (party payment, one row per mode as before); `lwb_party_allocs` = split of a party payment over POs. `lwb_order_office_paid` adds the split, so every due figure drops. RPCs: `lwb_party_receive(party,date,lines,allocs,remark)` (allocs NULL = oldest bill first, [] = all advance), `lwb_party_adjust(party,allocs)`, `lwb_party_unadjust(alloc_id)`, `lwb_cancel_tally_payment` (also cancels the split), `lwb_party_group_set(member,parent|NULL)`, `lwb_party_billing(days)` (one JSON for the page). Cash ≥ ₹2 lakh per receipt refused (269ST). `lwb_acc_lines` shows a party payment as Cash In "Party payment" of the main party. `lwb_save_tally_bills` accepts any bill name of the same group.
- `party-pay.js`: shared popup (party combobox, Cash/UPI/Bank/Cheque + note count, Oldest first / Choose bills / Keep as advance, advance adjust). Accounts Dashboard: "💰 Party payment" button; Cash In from a party with bills shows its bills and "Receive against these bills"; Party outstanding tab is main-party wise with advance.
- Tests: `tests/party-group` (PGlite, 7 tests). Browser check used a mocked client whose RPCs ran this SQL on PGlite; no live data was written.
- One balance per party (30 Oct 2026, Mohit: AKASH showed "due 1,34,460 · adv 1,39,460", real advance 5,000): every screen shows net = bills due + opening − paid not yet set against bills (red to collect / green advance; `LWBPartyPay.balText`). "Paid, not adjusted" column + "Adjust now". `lwb_party_auto_adjust_setup.sql`: trigger on `lwb_tally_invoices` amount sets a party's unsplit money against its bills (oldest first) when a bill is saved; never blocks the save. Older parties with both: "Adjust now" once.

### Accounts Dashboard: cash only vs collection, cheque register + reminders (30 Oct 2026)
- Top cards are cash only: Opening + Cash In − Cash Out − Bank deposit = Cash in hand. Below them: party collection of the dates in all modes (cash / UPI / bank / cheque), "To collect" (bills due after advance, from Billing & Outstanding) and cheques not yet in the bank.
- SQL: `lwb_accounts_cheque_setup.sql` (after `lwb_accounts_vehicle_setup.sql`). `lwb_acc_cheques` keyed by (src, src_id) for every Cash In line with mode CHEQUE (Cash In entry, party payment, driver): cheque no., cheque date, party's bank, photos (bucket `lwb-acc-bills`), deposit date + our bank. Status IN_HAND → DEPOSITED → CLEARED / BOUNCED (the last two are Admin's bank check, `lwb_acc_verify`).
- RPCs: `lwb_acc_cheque_list`, `lwb_acc_save_cheque`, `lwb_acc_cheque_deposit`, `lwb_acc_cheque_undeposit`, `lwb_acc_cheque_remind_now`. Reminder `lwb_acc_cheque_remind_internal()` (pg_cron `lwb_acc_cheque_reminder`, 10:00 and 18:00 IST) bells Admin, Accounts and Sales Head (manager) with type ACC_CHEQUE_REMINDER while a cheque is due (cheque date reached, not deposited) or deposited but not cleared.
- Cash In by cheque asks cheque date, party's bank, photo; a party payment by cheque opens the cheque details right after saving.
- Tests: 10 PGlite tests.

### Employee Master (godown staff) + salary limit on upad (30 Oct 2026)
- Masters > Employee Master (`fleet-master.html#employees`, next to Vehicle / Driver Master). Admin, Manager and Godown (warehouse) add / edit; nobody deletes (mark Left). Excel import / export.
- Same rows as the Accounts Dashboard Staff ledger (`lwb_acc_staff`). SQL: `lwb_employee_master_setup.sql` (after the staff + vehicle files) adds `emp_code` (Employee ID, unique; blank = next EMPnnn by trigger, old staff got IDs), `joining_date`, `note`; RPCs `lwb_emp_list`, `lwb_emp_save` (`lwb_emp_editor()` = admin / manager / warehouse / accounts). Opening balance stays with Accounts.
- Salary limit: `lwb_acc_add_entry4` (the dashboard now calls it; it wraps `lwb_acc_add_entry3`). In one month, upad less upad returned can not go over the month's salary (the "Salary of month" row, else fixed salary; 0 = no limit), and salary paid in one month can not go over it either. Over the limit: error starting `OVER_SALARY`; Admin can save anyway (`over_salary:true`, entry marked `over_salary`).
- `lwb_acc_staff_list` is redefined there (adds emp_code, month_cap, month_upad_net). Paid to box finds staff by Employee ID too.
- Tests: 11 PGlite tests.

## Role-wise Dashboard (30 Oct 2026)

- `dashboard.html` now shows a separate home for each role, picked from the logged-in user's role: Admin, Sales Head (MANAGER), Accounts, Godown Manager (WAREHOUSE) and Salesman (SALES). Driver and Transport keep the old order-status Dashboard. Admin has a "… view" dropdown to look at any role's dashboard.
- Code: `role-dashboard.js` (`LWBRoleDash.start({client, role, uid, plan, box})`) + `role-dashboard.css` (class prefix `rd-`). No SQL: it only reads what existing pages read (`orders`, `order_items`, `lwb_po_approval_summary`, `lwb_acc_dashboard`, `lwb_party_billing` via `party-pay.js`, `lwb_acc_cheque_list`, `lwb_po_stock`, `lwb_sales_team`, `lwb_sales_targets`, `lwb_party_activity`, `lwb_delivery_reports`, `dispatch_assignments`, `lwb_vehicles`, `lwb_godown_reports`, `lwb_stock_transit`, `lwb_my_orders`, `lwb_my_sales_plan`, `lwb_party_bills`, `lwb_my_verify_queue`). A card whose data the role may not read, or that is not installed, is left out.
- Admin: today / month sales vs target, outstanding (+ over 30 days), cash in hand, short-stock SKUs, order flow (approval late after 12 h), 7-day sales chart, salesman today, alerts. Sales Head: approval queue (urgent first, then oldest), team target per salesman, driver to assign, no-order 5+ days, today's delivery, top SKUs. Accounts: cash in hand / in / out, money with drivers, bills to make, outstanding by age (0–15 / 16–30 / 31–60 / 60+), cheques due in 7 days, night handover. Godown: to load, loading vehicles with kg vs capacity, vehicles at godown, returns to receive, stock vs open orders, goods in transit, today's godown report. Salesman: quick buttons, target ring, today's plan, my orders, my parties to collect.
- Pending Work card (`lwb_my_verify_queue`) moves into the side column. Search, focus messages and the bell are unchanged. Links respect Manage Users > Pages (hidden pages are not linked).
- Verification: browser run with a mocked read-only Supabase at 1280 / 390 / 320 px for all five roles + driver: no page overflow, no JS errors, zero writes; same with every query refused. Real data still to be checked on the live site per role.

## Company / Brand: Rajnigandha, Coca-Cola (30 Oct 2026)

- SQL: `lwb_company_brand_setup.sql`. `lwb_companies` (seeded RAJNIGANDHA: company credit 4 days, market udhari 1 day; COCA-COLA 0 / 0), `sku_master.company_id`, `lwb_user_companies` (brand-wise Sales Head / Salesman; no row = all brands), `lwb_company_targets` (month × company × salesman, NULL = company total), `lwb_party_company_credit` (party udhari per company), `lwb_company_payments` (money paid to the company).
- Brand-limited Sales Head / Salesman: restrictive RLS `lwb_brand_sku_scope` (sku_master) and `lwb_brand_order_scope` (orders: own order, order without lines, or a line of his company / an SKU without company). Admin, Accounts, Godown always all. SECURITY DEFINER RPCs of other pages are not brand-filtered yet.
- RPCs: `lwb_company_save` (Admin), `lwb_set_sku_company`, `lwb_brand_team`, `lwb_set_user_companies` (Admin any; Sales Head only salesmen within his brands), `lwb_save_company_targets`, `lwb_company_month`, `lwb_set_party_company_credit`, `lwb_company_payables` / `lwb_company_pay` / `lwb_company_pay_cancel` (Admin / Accounts; cancel Admin), `lwb_company_overview(from,to)`.
- Pay company: purchase bills = Goods Inward items whose SKU has that company; pay by = invoice date + company credit days; payments clear oldest bill first. Not posted to Accounts Dashboard cash / bank.
- Outstanding per brand: `lwb_tally_bill_rows` due split by loaded SKU value; late = bill date + party udhari for that company (else company market days).
- Page `companies.html` (Masters > Company / Brand; admin, manager, accounts): Brand summary, Targets, Team brands, Pay company, Party udhari, Companies. SKU Master: Company column / field, brand chips, bulk "Set company", Excel "Company" column.
- `brand-filter.js` (`LWBBrand`): chips, choice kept in localStorage `lwbBrand`. Dashboard: chips for Admin / Sales Head (orders split by brand share), Brand-wise card (Admin, Sales Head, Accounts), brand-wise Sales Head sees only his brands' figures; Salesman "My brand targets".
- Box / Case unit: `lwb_companies.pack_unit` (CASE / BOX; RAJNIGANDHA = BOX on first add) and `sku_master.pack_unit` (NULL = company's). `lwb_company_month` / `lwb_company_overview` return `cases` and `boxes` separately; `LWBBrand.unitOf` / `unitByName` / `qty`. Companies tab "Sells in", SKU Master Unit field / filter / Excel "Unit" column, PO Entry placeholder Boxes / Cases, dashboard qty words.
- Tests: `tests/company-brand` (PGlite, 10 tests). Browser check used a mocked client whose queries ran this SQL on PGlite with RLS; no live data written.

## Task Management (31 Oct 2026)

- SQL: `lwb_task_management_setup.sql` (auto-applied on merge; check = 4 rows, all true). Tables `lwb_tasks` (one row per person; `batch_id` groups a task given to many) + `lwb_task_updates` (every status change / due change / note).
- Chain (channel wise): 1 Admin > 2 Sales Head (MANAGER) > 3 Godown Manager (WAREHOUSE) > 4 Accounts > 5 Salesman / Driver / Transport (`lwb_task_rank`). A login gives tasks to his own level or below (self included); Admin to anyone. `lwb_task_people()` lists who he can pick.
- RLS: a task is read by the person, the giver, Admin, and anyone senior to the person (Team view). Writes only through `lwb_task_add(p)` and `lwb_task_update(id, status, note, due)`.
- Status OPEN → IN_PROGRESS → DONE (person or giver). Giver / Admin: OPEN again, CANCELLED, change due date. A senior in Team view can only write a note.
- 🔔 TASK_NEW to the person; TASK_DONE / TASK_NOTE to the giver; TASK_REOPENED / TASK_CANCELLED / TASK_DUE_CHANGED / TASK_NOTE to the person. `lwb_task_due_bells()` (called when the Dashboard opens): TASK_DUE once a day for my tasks due today / overdue, TASK_OVERDUE once to the giver. Bells and phone push open `tasks.html?id=N` (from "TSK-N").
- `tasks.html` (menu under Dashboard, every role): Give a Task (title, details, due date with Today / Tomorrow / 3 days / 1 week, Urgent, people grouped by role with Select all), tabs My tasks / Given by me / Team, status filter, notes thread.
- Dashboard: "My Tasks" card for every role (pending, overdue first, + Give task, "Given by me: N pending · N late").
- Tests: `tests/task-management` (PGlite, 9 tests). Browser preview with mocked Supabase only; no live tasks created.

## Live Tracking: drivers and staff on a map (31 Oct 2026)

- SQL: `lwb_live_tracking_setup.sql`. Tables `lwb_tracking_settings` (one row: tracked roles, work hours, godown pin + circle, average speed for ETA), `lwb_staff_location` (latest point per user), `lwb_location_history` (route, 1 point a minute or every 40 m, kept 30 days), `lwb_trip_events` (LEFT_GODOWN / REACHED_PARTY / DELIVERY_REPORT / LEFT_PARTY / BACK_GODOWN). `lwb_customer_master.geo_lat / geo_lng` = party pin. No direct table access; everything goes through the RPCs.
- Phone: `live-location.js` (loaded by `erp-shell.js` on every page) asks `lwb_track_me`, then **silently** sends `lwb_track_ping` every 25 s / 50 m while the ERP is open on screen, only for tracked roles (default driver, sales, accounts, warehouse, transport) and only in work hours (default 08:00–21:00 IST). **No on-screen sign** — the staff member sees nothing (the phone's own one-time location prompt and the browser/OS location icon are shown by the phone and cannot be hidden by a website). A blocked permission is saved as DENIED and shown to the office on the map. `_headers` allows `geolocation=(self)`.
- Trip steps are marked **automatically by GPS** inside `lwb_track_ping` (outside godown circle → Left godown; within 150 m of the party pin → Reached; 300 m away after the report → Left party; back in the circle with nothing pending → Back at godown). The driver page shows NONE of this. (`lwb_trip_mark` still exists for an optional future manual fallback but no UI calls it.) Trigger `trg_lwb_trip_delivery_report` adds DELIVERY_REPORT and pins a party at its first delivery (driver GPS within 10 min, ±100 m). Tracking can never block a delivery report.
- `live-tracking.html` (menu Delivery; Admin, MANAGER, WAREHOUSE or a ticked page): map (Leaflet in `assets/leaflet/`, OpenStreetMap tiles with real street names, free). Each on-road driver's **actual travelled path today** is drawn live on the map (his GPS breadcrumb, so it follows the roads and shows which area he is in; recent ~15 min brighter), plus a dashed bee-line to the next party. Driver cards with steps and ETA (straight line × 1.3 at the set speed, no paid API), all-staff list, today's route, party pin by tap, settings (Admin / Sales Head). Auto-refresh every 20 s.
- Limits: a web page / the Chrome-based Android app gets GPS only while it is open on screen. Background tracking with the screen off needs a native Android foreground service (APK change) — not built.
- Tests: `tests/live-tracking` (PGlite, `npm ci && npm test`).

## Fingerprint / face / phone PIN unlock after 15 minutes (1 Nov 2026)
- Mohit asked (1 Nov 2026) to stop typing the password after the 15-minute auto logout. No SQL, no APK change: `quick-unlock.js` uses WebAuthn with the phone's own screen lock (platform authenticator, user verification required), which works inside the Android app (Chrome TWA), Chrome on phones and laptops with Windows Hello / Touch ID.
- After a full login (password + OTP) `login.html` offers "Unlock with fingerprint next time?" (Not now = asked again after 30 days). The key is made on that phone only; `localStorage.lwbUnlock = {uid, cred}`.
- 15 minutes idle with unlock ON for that login on that phone: `erp-shell.js` sets `localStorage.lwbLocked = {uid, back}` and opens `login.html?lock=1` instead of signing out. The Supabase session and the OTP-verified state stay. Every ERP page (and other tabs, via the storage event) sends a locked phone to the lock screen. Unlock = phone fingerprint / face / PIN, then the usual getUser + role + OTP checks, then back to the same page.
- Logout button (top bar or a page's own Logout) with unlock ON for that login on that phone: also LOCKS (`lwbLocked.why = "logout"`, reopens on the dashboard) instead of ending the session, so the next open needs only the fingerprint (Mohit, 1 Nov 2026: after Logout the fingerprint option did not show). "Login with password instead" on the lock screen ends the session fully, e.g. before handing the phone to someone else.
- Without unlock ON (or on a phone that does not support it) the old 15-minute logout and the Logout button are unchanged.
- On / off per phone: tap the round initial (avatar) in the ERP top bar.
- Limit: the lock is a screen lock on the phone; the login session itself stays on the phone while locked (same as before the 15 minutes). Pages without `erp-shell.js` (cashbook.html has its own password) are not locked.

## Bill as soon as the PO is approved; one Submit in Edit PO (1 Nov 2026)
- Mohit asked (1 Nov 2026): once a PO is approved its quantity is fixed, so Accounts and the Godown Manager must see it at once. The party waits at the cash counter for the bill; Accounts should not wait for loading to finish.
- SQL: `lwb_bill_before_loading_setup.sql`. `lwb_po_billable(status)` = approved, transport given, loading or later. `lwb_save_tally_invoice` (copied from `lwb_loading_workflow_setup.sql`) accepts the Tally bill no. from approval on (was: only after loading). `lwb_tally_bill_rows` (copied from `lwb_party_payment_collection_setup.sql`) also lists a PO billed before loading, so it is in To collect from the day of the bill. **If either of those older files is changed again, keep these two changes** (or re-run this file after it).
- `lwb_bills_before_loading()` (Accounts / Admin): approved POs not loaded and not billed (last 60 days). Billing & Outstanding > Bills to make shows them with a "Not loaded yet" tag and the PO value (approved qty × rate); loaded ones still show their loaded value.
- Popups: trigger `trg_lwb_flow_po_approved` (pending → approved, or a PO saved approved) sends `PO_APPROVED_BILL` to Accounts (opens Bills to make) and `PO_APPROVED_LOADING` to Godown Managers (opens Loading & Dispatch). Vehicle loaded on a PO billed already: no "Make Tally bill" popup; Accounts get a "Loaded value differs from the bill" note only when the loaded value is more than ₹1 away from the bill (make a credit / debit note).
- Loading & Dispatch also lists approved POs with no vehicle yet ("APPROVED · NO VEHICLE YET", view only: no Start / Confirm / Challan until the Sales Head gives driver and vehicle).
- Edit PO (`warehouse-orders.html`): the Delivery Challan, Save Driver & Vehicle, Save Transport, Save Note and Save PO buttons are replaced by ONE **Submit** in the footer (`submitPo`): one confirm, then it saves only what changed, in this order: Driver / Vehicle / Godown Manager, SKU lines (with the note), or the note alone. A pending PO still has **Approve PO**. Print PO stays. The list's Challan shortcut is unchanged.
- Tests: `tests/bill-before-loading` (PGlite, `npm ci && npm test`).

## Bank Statement: upload, auto match, Suspense (2 Nov 2026)

- Mohit asked: Admin uploads the bank statement of any dates (1st–7th, later 1st–10th); lines already uploaded are skipped; lines matching ERP money are matched by themselves; the rest wait in a Suspense list (like Tally suspense) where many lines are booked at once as party payment (outstanding drops), cash deposit, UPI / bank income, expense etc.
- SQL `lwb_bank_statement_setup.sql` (after `lwb_accounts_dashboard_setup.sql` + `lwb_party_group_billing_setup.sql`). Tables `lwb_bank_stmt_imports`, `lwb_bank_stmt_lines` (RPC only). Duplicate check = fingerprint per bank of date + debit + credit + narration (letters / digits) + ref + the n-th same line in the file. New heads: Bank charges, Loan EMI / Interest, GST / Tax paid (OUT), Bank interest, Loan received (IN).
- Auto match (`lwb_bank_automatch`, run on each upload): same amount + direction with an ERP line of `lwb_acc_lines()` that waits for the bank check (or is checked into this bank) or is a bank expense / cash withdrawn of this bank; matched when the ERP ref / UTR is in the narration, or when exactly one candidate is within −5…+4 days (cheque −30) on both sides. Match = `lwb_acc_verify` VERIFIED with this bank. Entries with another bank chosen are never matched.
- RPCs: `lwb_bank_stmt_import(bank, file, rows)` (Admin), `lwb_bank_stmt_list(bank, from, to)` (Admin / Accounts; suggestions for open lines), `lwb_bank_stmt_assign(ids[], {type PARTY|DEPOSIT|WITHDRAW|IN|OUT|IGNORE|MATCH, party, category_id, note, src, id})` (Admin; each line on its own, errors returned), `lwb_bank_stmt_undo(id)` (cancels what was booked, matched line not auto-matched again), `lwb_bank_stmt_remove_import(id)` (only when nothing of it is booked).
- PARTY = `lwb_party_receive` (UPI if narration has UPI, else BANK; oldest bill first) + bank-checked. DEPOSIT / WITHDRAW / IN / OUT = `lwb_acc_entries` row on the bank date written directly (closed days allowed: then only the bank balance changes, cash in hand starts from the counted cash).
- Page `bank-statement.html` (Accounts > Bank Statement; Admin books, Accounts view only). Reads Excel / CSV in the browser, finds the header row and columns (Date, Narration, Ref, Withdrawal / Deposit or Amount + Dr/Cr, Balance) by itself; columns can be changed and are remembered per bank. Suspense list with tick-all, sticky bar (book as + party / head + Save) above the phone bottom bar, party guessed from the narration, 🔗 Match popup. Links from Accounts Dashboard (Bank wise card, Bank check tab).
- Tests: `tests/bank-statement` (PGlite). Browser check used a mocked client whose RPCs ran this SQL on PGlite; no live data was written. PDF statements are not read yet.

## Brand filter on every page (Step 2)
- `brand-filter.js` now has `LWBBrand.mount(client,{into,after,onChange})` (All / each company chips, choice shared via localStorage `lwbBrand`, hidden when the user has < 2 brands), `LWBBrand.orderBrands(client,orderIds)` (Map order → Set of companies from its SKU lines) and `LWBBrand.has(set,b)`.
- Order pages filter by PO brand: Driver Collections, Payment Collection, Accounts Invoice, Sales Return, Credit Note, Driver Returns, Loading & Dispatch, Driver Delivery (office view only).
- SKU pages filter by SKU company: Opening Stock, Stock Transfer (Daily Report tab stays all brands), Goods in Transit, Night Audit (display only; the count sheet still saves every SKU), Godown Report (only damage rows; vehicles/staff stay), Market Report, Purchase List, Purchase Claims, Goods Inward (supplier search).
- Report pages count only that brand's SKU lines: Team Report, Sales Tracking, My Sales. Accounts Dashboard: brand chips on Party outstanding tab + "To collect" card.
- `lwb_brand_reports_setup.sql`: `lwb_order_has_company(order, company)`, `lwb_daily_summary_b(date, company)`, `lwb_daily_summary_list_b(date, card, company)`, `lwb_party_call_list_b(p_all, company)` (copies of the old functions with a brand filter; old ones untouched — if lwb_daily_summary / lwb_daily_summary_list / lwb_party_call_list change, change the _b copy too). Daily Summary and Party Call List call the _b version when a brand is chosen. Money Overview filters its PO rows by brand on the page.
- Not brand-wise: Tally Check (Tally bills carry no brand). Legacy `sales.html` is not linked in the menu.
