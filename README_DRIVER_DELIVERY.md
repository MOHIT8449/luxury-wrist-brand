# Luxury Wrist Brand ERP — Module 1: Driver & Delivery / POD

Existing workflow: Salesman PO → Sales Head Approval → Driver/Vehicle Assigned →
Dispatch Team Actual Loading → Accounts Internal ERP Bill / Tally separately →
**Driver Delivery / POD / Collection Report** → Office verifies collection (NEXT module).

## Deploy status

The following changes are already saved to the GitHub repo and deploy to
Cloudflare Pages automatically once its GitHub build completes:

- driver-delivery.html — mobile-friendly Driver portal / Manager & Accounts read view
- dashboard.html — Driver Delivery/POD shortcut and DRIVER Role + Mobile mapping
- lwb_driver_delivery_setup.sql — **must still be executed manually in Supabase**.

The module will NOT work until the SQL runs successfully and a Driver Auth
login has been created and mapped to the matching Driver Mobile.

## Step 1 — Supabase setup

Open:
https://supabase.com/dashboard/project/txkbhadzdbxpieunfvox/sql/new

Copy the entire \`lwb_driver_delivery_setup.sql\` and press **Run**.

Expected result: **2 rows**
- \`delivery_reports_table\`
- \`pod_private_bucket\`

Security details:
- ERP DRIVER Role is added to the existing Admin role function.
- Admin-only mapping matches a Driver Auth profile's 10-digit Mobile
  to the saved \`dispatch_assignments.driver_mobile\` number.
- New Driver users cannot directly use broad existing orders/SKU table RLS
  policies; the migration adds a driver-restrictive policy to all **existing
  public tables that already have RLS enabled**.
- Only the assigned Driver can submit; reports are one-per-order and immutable.
- All POD photos are stored in a private \`lwb-delivery-pod\` bucket.
- Existing non-RLS-enabled public tables (if any) need separate access review
  before activating Driver accounts. This migration does not silently change
  their access permissions.

## Step 2 — Create the driver login and map mobile

1. Open Supabase -> Authentication -> Users -> **Add User**.
   Give the driver an **individual email login** and a private password.
   Never share an Admin login with a driver.
2. Open ERP Dashboard as Admin:
   https://luxury-wrist-brand.pages.dev/dashboard.html
3. In **User Permissions** locate that Auth user.
4. Set **ERP Role = DRIVER — Assigned Delivery**.
5. In **Driver Mobile** enter the exact phone number Sales Head saved
   for that driver during Vehicle Assignment.
6. Click **Save Role**. This calls an Admin-only Role RPC followed by an
   Admin-only Mobile Mapping RPC.
7. Ask the Driver to log in on their own mobile device.

Driver Portal URL:
https://luxury-wrist-brand.pages.dev/driver-delivery.html

If DRIVER Role or Mobile mapping is missing, the driver will see no assigned
deliveries or an explanatory access error.

## Step 3 — One real delivery test, no fake cash entries

1. Sales Head: approve PO and assign Driver (with mobile), vehicle and team.
2. Dispatch Team: complete actual loading. Only \`loaded\` / \`invoiced\`
   orders are available on the Driver portal.
3. Driver signs in with assigned ERP email/password.
4. Driver sees only orders assigned to their exact saved phone number.
5. Driver opens PO: vehicle, party, Party Master billing address,
   actual SKU and cases are shown.
   The Party Master billing address is NOT assumed to be the ship-to
   location; confirm destination with Sales Head.
6. Choose DELIVERY STATUS:
   - DELIVERED: receiver name + JPEG/PNG/WebP photo required.
   - PARTIAL: receiver name + photo + discrepancy note required.
   - NOT DELIVERED: explanation required, no collection accepted.
7. Record only actual CASH/UPI/BANK/CHEQUE collected. For no payment,
   enter zero. For noncash payments a genuine payment reference is required.
8. Check confirmation, then **Submit Delivery & Collection Report** once.
   The saved report is read-only to the driver afterwards.
9. Admin, Manager and Accounts can monitor reports read-only from the
   same portal. The POD photo is opened through a short-lived signed URL.

## Payment Safety

- Driver-reported collection is **NOT** an official cash receipt in ERP.
- It does NOT update \`lwb_payment_collections\`, \`lwb_internal_bills\`,
  \`lwb_invoice_outstanding\`, Party Ledger, stock or Tally.
- \`PENDING_OFFICE\` means the office must verify actual payment received
  before any independent payment posting (Module 2).
- Single CASH entries of Rs 2,00,000 or more are blocked, but a complete
  Section 269ST daily/person/transaction review is still an office process.
- Use only actual deliveries / payments in production. Never submit fabricated
  receipts to test the module.

## Remaining Modules

2. Payment Collection: reconcile reported Driver cash/UPI, verify, post
   approved ERP receipt with authorized controls.
3. Party Ledger & Outstanding: party-wise consolidated ERP balance,
   invoice/credit/debit/payment reconciliation (Tally stays separate).
4. Sales Return & Damage: leakage, breakage, gasless, saleable returns,
   credit-note adjustments and damaged stock buckets.
5. Live Inventory & Stock: inward, outward, reserve, closing cases/pieces.

**Not yet done:** push alert notification to Sales Head on submit, cash
verification by Office, outstanding posting, Tally sync (not requested), and
automatic delivery location GPS logging. The Manager's Delivery Monitor
is a read-only list that refreshes; it is not a push notification.
