# 06. CRM boundary and the optional Integration Pack

Owner decisions 2026-11-16 (binding): the CRM and the ERP are SEPARATE products, each sellable alone, and they can
run together as one SUITE (section 6). The ERP core never depends on the CRM and does not change it; every link is
the optional, additive Integration Pack (section 3), ON per tenant in suite mode.

## 1. Boundary
- OFF LIMITS for all ERP work: `app.js`, `index.html`, `build_index.py`, `schema.sql`, `rls.sql`, `functions.sql`,
  `backend/*.sql` 010-190, `run_db_tests.sh`, existing CRM Edge Functions and `_shared` files, every CRM table,
  policy, trigger, grant and setting. CRM file numbers up to 299 stay reserved for the CRM; the ERP uses the E prefix.
- Core ERP files (E100-E600) name NO CRM object (`public.*`, `app.*`): no read, no foreign key, no view, no trigger.
  They must install and pass their tests on an empty database that has no CRM objects.
- Own model: tenants, members (Supabase Auth users invited by the tenant owner), branches, warehouses,
  counterparties. iSmile is tenant #1 and is set up like any other tenant: its three branches are typed in the
  onboarding screen and its users are invited by email. No staff sync, no clinic sync.
- Patients as such do not exist in the ERP: no Patient ID, card data or health data in any `erp` table, log or
  export. In suite mode a CRM person may become an ERP CUSTOMER with the fields of section 6 only.
- Shared with the CRM today: only the Supabase project / Auth and the Netlify site (`erp.html` is its own page; the
  CRM has no link to it; question 1 in 05). One dashboard step, done by the owner: add `erp_api` to exposed schemas.
- Isolation: `erp_api` RPCs set a statement timeout of 8 s and background jobs run in small batches, so the ERP
  cannot starve the CRM. Dropping schemas `erp` and `erp_api` leaves the CRM exactly as it was (tested, 03).

## 2. Who records what
| Data | Recorded in | Note |
|---|---|---|
| Patients, treatment, appointments, agreements, instalments, patient receipts | CRM | the ERP does not see them |
| CRM `expenses` screen | CRM, unchanged | NOT read, moved or retired by the ERP |
| Items, stock, lots, costs, warehouses | ERP (stock master) | - |
| Supplier invoices, expense documents, expense categories, supplier payments | ERP (own capability, 01 C1 / C4) | accountant pack |
| Non-patient customers, sales documents, their receipts | ERP | accountant pack |
| Fiscal documents (MARK, QR) | Provider (legal copy) + ERP (reference) | accountant |
The same expense must not be typed in both systems: that is an operating rule for the owner (question 2 in 05), not
a software link. The accountant pack contains ERP data only.

## 3. Integration Pack (phase IP): OPTIONAL, off by default, NOT part of E0..E10 unless the owner activates it
Rules for every item: additive; lives in `erp/backend/E900_integration.sql` (+ suite), behind
`tenant_settings.integration_enabled = false`; the core never calls it and passes all tests without it; no foreign
key to a CRM table; ERP tasks never edit a CRM file. Any CRM-side adapter is a separate CRM-project task that only the
owner can order, with its own plan and review.
| # | Item | ERP side (ready to add later) | CRM side (only if the owner orders it) |
|---|---|---|---|
| IP1 | Patient receipts -> ERP -> e-invoicing provider | inbound contract of section 4 | adapter that pushes receipts, or a file export |
| IP2 | Staff -> members | `erp_api.int_members_import(json)`: upsert members from a list (email, role, branch codes) | export of the staff list |
| IP3 | CRM person as ERP customer (suite counterparty pull, section 6) | `int_customer_search / link / refresh / erase`, hooks `ext_source` + `ext_ref` | read facade `crm_int` + erasure hook (additive, not now) |
| IP4 | Consumption per treatment | `ext_ref` on CONS lines + report "cost per external reference"; deep link `erp.html#consume?ref=` | a link button, if ever wanted |
| IP5 | Stock alerts / material cost shown in the CRM | read RPCs `int_alerts()`, `int_cost(ext_ref)` | bell group, cost line |
| IP6 | CRM card "Materials" table (order requests, consumption, availability, cost); replaces IP4 / IP5 | facade `erp_api.int_*`, see `07_crm_card_materials.md` | additive table + drawer tab, flag off by default |
`ext_ref` columns belong to the core (plain optional text, usable by any tenant for its own references); everything
else of the table is built only when activated.

## 4. IP1 contract: patient receipts to the provider (design only, nothing is built in the CRM now)
Purpose: a receipt recorded in the CRM is sent to the ERP, which issues the fiscal retail receipt through the
certified provider (04) and returns MARK / QR. Needs E8 and gate G2. Options, in order of preference:
- **A. Inbound RPC (push)**: `erp_api.int_receipt_push(p_key text, p_payload jsonb)` called by a CRM-side adapter
  signed in as a member with role `integration` (capability `int.receipt.push` only). Idempotent on `p_key`
  (source + external receipt id; same key with another payload = `ERP_IDEMPOTENT_MISMATCH`). Payload: `external_id`,
  `date`, `branch_code`, `gross`, `vat_class`, `method`, `description`, optional `customer_ext_ref` (linked customer, section 6) or `customer {name, tax_id, address}`
  (a retail receipt needs none), optional `void_of`. Reply `{doc_id, state}`; `erp_api.int_receipt_status(p_key)`
  returns state, mark, uid, qr_url and PDF link for the caller to store or print.
- **B. File import**: the same fields as CSV / JSON uploaded in the ERP by the accounting role (dry run + error
  list). Needs no CRM code at all.
- **C. Pull through a read-only bridge**: the ERP reads CRM tables. Not recommended (couples the ERP to the CRM's
  shape); only on an explicit owner request.
Common rules: rows land in `erp.inbound_receipts` (received / issued / rejected / voided) and become an RS document
in a fiscal series, sent through the normal outbox. The money stays recorded where it was taken: these documents are
flagged `source = external` and are excluded from ERP cash journals, aging and allocations (no double counting). A
void arrives as `void_of` and follows the provider's cancel / credit rule (04). The payload carries no health data;
the description text is fixed by the accountant.

## 5. iSmile go-live steps
| Step | What | Gate |
|---|---|---|
| C0 | Expose `erp_api`, run E100+ on live, tenant #1 with branches and invited members; owner only | F1; backup gate G1 (05) |
| C1 | Items, suppliers and opening stock imported by CSV after a first stocktake per clinic (OPN) | owner signs the opening quantities |
| C2 | Pilot in ONE clinic for 2-4 weeks: GRN, CONS, ADJ, TRF, STK | weekly count of 20 items matches |
| C3 | All clinics; expense documents on | F4 |
| C4 | Purchasing + money in the ERP (opening balances CBAL) | accountant agrees the date |
| C5 | Fiscal documents through the provider (delivery notes / transfers first) | G2 |
Rollback at any step: stop using `erp.html`; the CRM is unaffected because nothing in it changed.

## 6. Deployment modes and suite counterparty data (owner decision A; replaces "opaque reference only")
| Mode | Runs | Counterparties | Switch |
|---|---|---|---|
| Standalone CRM | CRM only; no `erp` schema needed | - | no ERP tenant |
| Standalone ERP | ERP only, also on a database with no CRM | typed / imported in the ERP only; `ext_source` empty; no CRM tab, every `int_*` returns `ERP_INT_DISABLED` | `integration_enabled = false` (default) |
| Suite | both: same Supabase project, same login (one Auth user is CRM staff and ERP member, IP2), a menu link each way | CRM persons pulled as ERP customers; suppliers stay ERP-only | `tenant_settings.integration_enabled = true` + `int_crm_org` + clinic -> branch map (`erp.int_branch_map`) |
**What may cross (CRM -> ERP only, read-only, suite mode only)**: person id, first / last name, phone, email, postal
address, tax ID and tax office if the CRM holds them, clinic code. **Never**: treatment type, diagnosis, notes,
labels, pipeline stage, appointments, agreement / instalment data, date of birth, the Patient ID (card name). The
materials facade (07) keeps its own opaque `card:` / `episode:` references, and the ERP must NOT join them to a
customer (no "materials per named customer" report): cost per treatment is shown only inside the CRM.

**Sync model: pull on demand + link, no mirror table.** The ERP never copies the patient list. A CRM person
enters the ERP only when a user picks them for a document:
1. Customer picker of SQ / SO / DN / SINV / SVC / RR / RS has a "From CRM" tab -> `erp_api.int_customer_search(q)`
   (live, nothing stored). 2. "Create customer" (create-on-first-document) -> `int_customer_link(p_ext_ref)` creates,
   or returns, the ERP counterparty with a snapshot of the fields above. 3. `int_customer_refresh(id)` runs when a
   draft document of a linked customer is opened and from a "Refresh from CRM" button. No scheduled job crosses.
- **Linking key**: unique (`tenant_id`, `ext_source = 'crm'`, `ext_ref` = the CRM person uuid; question 4 in 05).
  Never the name, phone or Patient ID. Linking an existing hand-typed customer = owner / manager action, audited.
- **Transport**: E900 calls a CRM read facade `crm_int.person_search / person_get` (fixed column whitelist, runs
  with the caller's CRM rights so CRM visibility rules apply) by dynamic name; if it is absent the call returns
  `ERP_INT_UNAVAILABLE`, so the core and E900 still install and pass on a database with no CRM.
- **Conflict rules**: the CRM is master for IDENTITY (name, phone, email, clinic): read-only in the ERP for linked
  customers, overwritten at refresh. The ERP is master for FISCAL data (tax ID, tax office, billing name / address,
  payment terms): prefilled from the CRM once when empty, never overwritten later; a difference is shown as a hint.
  Posted / issued documents keep their own `cp_snapshot` (02) and never change.
- **Roles and audit**: capability `int.customer.link` (owner, manager, accounting; `clinic_user` only for RR / RS in
  the own branch). Every search, link, refresh and erase writes `audit_log` (who, when, `ext_ref`, field NAMES).
- **GDPR notes (the owner confirms with the DPO / lawyer)**: same controller (the clinic) for both products, the
  vendor is processor for both; purpose limited to issuing and collecting commercial / fiscal documents; data
  minimised to the list above; ERP customers appear in the tenant's record of processing. Retention: a customer
  with posted documents is kept for the legal fiscal period (accountant sets `retention_years`); with none it is
  deletable. Export: the CRM subject export calls `int_customer_export(ext_ref)` (customer + document list).
  Erasure: the CRM erasure routine calls `int_customer_erase(ext_ref)`: no posted documents = row deleted; else the
  master row is unlinked, restricted and stripped of phone / email, while document snapshots stay under the legal
  obligation. A report lists linked customers whose CRM person no longer exists.
**CRM changes needed LATER (additive, NOT NOW, separate CRM-project task ordered by the owner)**: S1 schema `crm_int`
with the two read functions; S2 erasure / export hooks; S3 "Issue document" link on the card
(`erp.html#new?type=RS&crm=<id>`) and a suite menu link; S4 suite tests. Flag off = none is used.
**ERP tasks (phase IP)**: IP-T9 `int_customer_*` + picker tab + K-cases (flag off, cross-tenant, health field in a
reply rejected, relink refused); IP-T10 refresh / conflict hints, erase / export, report; IP-T11 (CRM project)
S1-S4. Checkpoint FI4: Fable reviews the whitelist, grants, audit and the erase path before any tenant is switched.
