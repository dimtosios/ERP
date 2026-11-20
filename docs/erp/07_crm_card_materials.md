# 07. CRM card "Materials" table linked to the ERP (Integration Pack item IP6)

Status: DESIGN ONLY (2026-11-16). NOT NOW: nothing here is built, connected or changed in the CRM until the owner
activates the Integration Pack (06 section 3). The CRM and the ERP stay separate projects. This file exists now so
that the ERP core (E0-E5) is built ready for it. IP6 replaces IP4 and IP5 of 06 (same ideas, full design).

## 1. Product behaviour
**Where**: a new tab "Materials" in the CRM card drawer, next to the treatment tabs. Hidden unless the flag is on.

**Table columns** (one row = one line):
| Column | Rule |
|---|---|
| Item | picked from the ERP catalogue: type-ahead search (code, name, supplier code) or barcode scan; free text is not allowed |
| Quantity, Unit | unit defaults to the item's base unit; other units only if the ERP has a conversion |
| Source | branch / warehouse; default = the card's clinic mapped to its ERP branch and default warehouse |
| Availability | live figure for the source + the other branches; badge "low" (below reorder point) or "negative" |
| Status | Planned -> Requested -> Consumed; Cancelled from any state |
| Episode / phase | optional link to the card's treatment episode |
| Notes, who / when | free note (no stock meaning); created-by, consumed-by, timestamps |

**Actions**
- **Add line / Apply template**: lines start as Planned. Nothing is sent to the ERP.
- **Request order** (selected Planned lines): creates ONE ERP draft material request (document type REQ, no stock
  effect). ERP purchasing staff turn it into a purchase order, an inter-branch transfer or a delivery-note request;
  the clinic user does not choose which. The line shows the ERP document number and its state.
- **Consume** (selected Planned / Requested lines): posts ONE ERP internal-consumption document (CONS) per source
  warehouse, at the official cost. Stock moves only here.
- **Negative stock** (owner decision: allowed with a warning): the ERP answers with a warning first; the user
  confirms ("stock will go to -3") and the call is repeated with the acknowledgement. Only the two blocking cases
  of 05 question 3 (lot, transit warehouse) refuse.
- **Cancel**: Planned = local only. Requested = ERP request line cancelled if still draft, else refused with the
  reason. Consumed = ERP reversal document (stock returns at the original cost); needs the manager role.
- A Consumed line is never edited: cancel and add a new one.

**Episodes / phases**: a line belongs to the card and optionally to one treatment episode. Closing an episode
warns about lines still Planned / Requested (keep, move to the next episode, or cancel). Lines are never deleted.

**Templates per treatment type** (for example "bracket kit", "Invisalign start"): a named list of item + quantity,
kept on the CRM side because treatment types are CRM concepts. Applying one adds Planned lines; items that are no
longer active in the ERP are listed and skipped.

**Cost per treatment** (read-only, owner / manager): total and per-episode material cost, read live from the ERP.
Costs are not shown to other roles.

## 2. Data ownership
| Data | Stored in | Rule |
|---|---|---|
| Items, units, barcodes, stock, reorder points, cost, lots | ERP | only source; the CRM never caches stock |
| REQ / CONS / reversal documents, numbering, audit | ERP | only place where stock or cost changes |
| Card line: card, episode, ERP item id + code / name / unit snapshot, qty, source code, status, notes, who / when, idempotency key, ERP document id / number, sync state | CRM (thin table) | holds what staff intended, plus references |
| Templates | CRM | item id + snapshot + qty |
| Clinic -> branch / warehouse mapping | ERP (`erp.int_branch_map`) | the CRM sends its own clinic code only |
| Cost | ERP | the CRM shows it live and stores none |
Rules:
1. One CRM line produces at most one CONS line (idempotency key). The CRM status is a mirror; if the two disagree,
   the ERP document wins and the reconciliation report shows the line.
2. No double counting: staff must not also type the same consumption in `erp.html`. The CONS document carries
   `source = external` and the line reference, so the ERP screens show where it came from.
3. No foreign keys, views or triggers across the two projects. References are plain text / uuid values.
4. Deleting the CRM table leaves the ERP correct; dropping the ERP leaves the CRM lines readable (snapshots).

## 3. Integration contract
### 3.1 Transport options
| | A. Same Supabase project, RPC facade | B. Separate ERP project, Edge Function + API key |
|---|---|---|
| Call | CRM front-end adapter -> `supabase.schema('erp_api').rpc('int_*')` with the user's own session | CRM Edge Function `erp-proxy` (holds the key) -> ERP Edge Function `erp-int` |
| Identity | the real user, who is also an ERP member with a narrow role | one key per tenant; user id sent as a field |
| CRM code | one small JS adapter, no secret | adapter + proxy function + key rotation |
| Latency / cost | one round trip | two hops, function limits |
| Isolation | timeouts of 06 section 1; same database | full |
| When | now (05 question 1 default: same project) | if the ERP moves out or for another vendor's CRM |
**Recommendation: A**, with payloads that are transport-neutral JSON so that B is the same contract behind
another transport. The CRM adapter exposes one interface (`erpClient.search / availability / request / consume /
status / cost`), so switching to B changes one file.

### 3.2 Functions (all in `erp_api`, all return `{ok, data, warnings[], error{code, message}}`)
| Function | Input | Output |
|---|---|---|
| `int_ping()` | - | `{enabled, contract_version}` |
| `int_catalog_search(p_q, p_barcode, p_limit, p_after)` | text or barcode, keyset cursor | `[{item_id, code, name, base_unit, units[], active}]` |
| `int_availability(p_item_ids[], p_branch_code)` | up to 50 items | per item: `[{branch_code, warehouse_code, on_hand, reserved, available, low, negative}]` |
| `int_request_create(p_key, p_payload)` | `{branch_code, ext_ref, needed_by, lines[{line_ref, item_id, qty, unit, note}]}` | `{doc_id, doc_no, state}` |
| `int_consume_post(p_key, p_payload)` | `{branch_code, warehouse_code?, date, ext_ref, ack_warnings, lines[{line_ref, item_id, qty, unit}]}` | `{doc_id, doc_no, state, lines[{line_ref, base_qty, cost}]}` (cost only with the capability) |
| `int_line_cancel(p_key, p_doc_id, p_line_refs[])` | - | `{doc_id, reversal_doc_id?, state}` |
| `int_doc_status(p_keys[] or p_doc_ids[])` | up to 100 | `[{key, doc_id, doc_no, type, state, lines[{line_ref, state}]}]` |
| `int_cost(p_ext_refs[])` | card / episode references | `[{ext_ref, total_cost, provisional}]` |
`int_alerts()` (low / negative stock for a bell) is optional and later.

**Idempotency**: `p_key` is a UUID created by the CRM and saved on the lines BEFORE the call. Same key + same
payload = the first answer again (no second document). Same key + different payload = `ERP_IDEMPOTENT_MISMATCH`.
Keys are unique per tenant + source; stored on `erp.documents.client_key` (core column).

**Warnings** (not errors): `NEGATIVE_STOCK`, `LOW_STOCK`, `PROVISIONAL_COST`. With `NEGATIVE_STOCK` and
`ack_warnings = false` nothing is posted and the reply has `needs_ack = true`.

**Error codes**: `ERP_INT_DISABLED`, `ERP_FORBIDDEN`, `ERP_BRANCH_UNMAPPED`, `ERP_ITEM_NOT_FOUND`,
`ERP_ITEM_INACTIVE`, `ERP_UNIT_INVALID`, `ERP_QTY_INVALID`, `ERP_PERIOD_LOCKED`, `ERP_STOCK_BLOCKED` (lot /
transit), `ERP_DOC_NOT_FOUND`, `ERP_DOC_STATE`, `ERP_IDEMPOTENT_MISMATCH`, `ERP_LIMIT` (batch too large). Timeouts
and network failures are transport errors and are always retryable; of the codes above none is retried
automatically.

### 3.3 Auth, tenant and branch mapping
- The caller is an ERP member of the tenant (created with the members import, IP2). New role `card_user` with only
  `int.catalog.read`, `int.stock.read`, `int.request.create`, `int.consume.post`; `int.cancel` and `int.cost.read`
  only for manager / owner. A `card_user` cannot open any other ERP screen or RPC.
- Tenant = from membership, never from the payload. Branch = `branch_code` (the CRM clinic name, for example
  `Serres`) looked up in `erp.int_branch_map(tenant_id, ext_code, branch_id, default_warehouse_id)`, kept and
  edited on the ERP admin screen. Unknown code = `ERP_BRANCH_UNMAPPED`.
- Everything checks `tenant_settings.integration_enabled`; when false every `int_*` returns `ERP_INT_DISABLED`.

### 3.4 Privacy
THIS facade sends only opaque references: `ext_ref` = `card:<uuid>` or `episode:<uuid>`, `line_ref` = line uuid. No
name, phone, diagnosis, treatment type, Patient ID or free-text note; notes stay in the CRM. Since the owner's
suite decision (06 section 6) a CRM person may separately exist in the ERP as a customer, but material consumption
is health-related, so the ERP never joins these references to a customer and offers no such report.

### 3.5 Failure isolation, queue, reconciliation
- The CRM line is saved in the CRM first, always. ERP calls happen after the save and never block it.
- Sync state per line: `none` (Planned), `pending` (call not confirmed), `synced`, `failed` (business error, needs
  a person). A line with `pending` shows "pending sync"; the intended action and key are kept on the line.
- Retry: on drawer open, on app start for the user's own pending lines (small batch), and with a "Sync now" button;
  backoff 5 s / 30 s / 5 min. Because of the key, a retry after an unknown outcome is safe.
- Search and availability with the ERP down: the tab shows "ERP not reachable"; lines can still be added from
  templates and from recently used items (snapshot), availability shows "-".
- Reconciliation report (CRM screen, owner / manager): lines pending or failed for more than 24 h; lines whose
  status differs from `int_doc_status`; ERP documents with `source = external` whose `line_ref` the CRM does not
  have (listed by a second ERP function if ever needed). No automatic repair.
- No database job in the CRM calls the ERP and no ERP job calls the CRM.

### 3.6 Permissions by role
| Action | Clinic staff | Clinician | Manager | Owner |
|---|---|---|---|---|
| View tab, add / edit Planned lines, search, see availability | yes | yes | yes | yes |
| Request order | yes | yes | yes | yes |
| Consume | yes | yes | yes | yes |
| Acknowledge negative stock | yes (logged) | yes | yes | yes |
| Cancel a Consumed line (reversal) | no | no | yes | yes |
| Cost per treatment, reconciliation report, templates admin | no | no | yes | yes |
CRM role names are mapped in the CRM plan when the pack is opened.

## 4. CRM changes needed LATER (all additive; NOT NOW; a separate CRM-project task ordered by the owner)
| # | Change | File / area |
|---|---|---|
| C1 | Tables `card_materials`, `material_templates`, `material_template_lines` | new `backend/NNN_card_materials.sql` (next free CRM number) |
| C2 | RLS: same visibility as the card; cancel / templates by role | same file (and listed in `rerun_after_rls.sql`) |
| C3 | RPCs: `card_materials_list / save / set_status / mark_sync`, `material_template_apply`, `materials_reconcile` | same file; `API.md` new section |
| C4 | Activation flag `materials_enabled` (default false) returned by `whoami` | CRM settings |
| C5 | `erpClient` adapter + drawer tab "Materials" + reconciliation screen | `app.js`, new sections after "card drawer" |
| C6 | Tests: suite + Playwright smoke with a mock ERP | `backend/tests/` |
| C7 | Build: `python3 build_index.py` as today; no new build step | - |
With the flag off the tab is not rendered and no `erp_api` call is made. Rollback = flag off.

## 5. What the ERP provides from day one (core tasks, see 05)
1. `documents.client_key` + `source` with a unique index per tenant, used by every posting RPC (T09).
2. `ext_ref` on CONS headers and `ext_line_ref` on lines (T12); the post reply returns line costs.
3. Read models used by the ERP's own screens and later by the facade: item lookup (search + barcode) and
   availability per warehouse with `low` / `negative` flags (T10, T14).
4. Role and capability tables able to hold a facade-only role (T02); nothing is seeded yet.
5. Reversal of a posted CONS as a document (T12).
6. E900 stays empty. The facade itself (`int_*`, `int_branch_map`, role `card_user`) is phase IP; the REQ type and REQ -> PO / TRF conversion
   are core (01 C3 / C5, T45).

## 6. Tests and Opus tasks
**Contract tests** run twice: against the real `erp_api` (SQL suite `E900_integration_tests.sql`) and against a
mock ERP (`mock_erp_int.js`, same JSON fixtures in `erp/backend/tests/contract/`) used by the CRM smoke test.
**Golden cases**
| # | Case | Expected |
|---|---|---|
| K1 | Consume twice with the same key | one CONS document, identical reply |
| K2 | Same key, other quantity | `ERP_IDEMPOTENT_MISMATCH`, nothing posted |
| K3 | ERP down during Consume | CRM line saved, `pending`; after retry one document |
| K4 | Unit conversion (box of 10, consume 3 pieces; unknown unit) | base qty 3; `ERP_UNIT_INVALID` |
| K5 | Stock 2, consume 5 | first call `needs_ack`; with ack posted, on hand -3, alert raised |
| K6 | Cancel: Planned / Requested draft / Consumed | local / request line cancelled / reversal, stock and cost restored |
| K7 | Cross-tenant: tenant B member asks for tenant A item, key or `ext_ref` | not found, no data leaked |
| K8 | Flag off | every call `ERP_INT_DISABLED`; core suites green without E900 |
| K9 | Unmapped clinic code | `ERP_BRANCH_UNMAPPED` |
| K10 | Payload with extra fields (a name) | rejected by schema check, nothing stored |

**Opus tasks (phase IP, only after the owner opens it; ERP side first)**
1. IP-T1 E900: flag, `int_branch_map` + admin screen, role `card_user`, `int_ping`.
2. IP-T2 `int_catalog_search`, `int_availability` + suite (K7, K8, K9).
3. IP-T3 `int_request_create` on the core REQ type (conversion REQ -> PO / TRF already exists, T45).
4. IP-T4 `int_consume_post`, `int_line_cancel`, `int_doc_status`, `int_cost` + golden K1, K2, K4, K5, K6, K10.
5. IP-T5 Contract fixtures + `mock_erp_int.js`; `API.md` section "Integration facade".
6. IP-T6 (CRM project) C1-C4 + suite.
7. IP-T7 (CRM project) C5 adapter and tab against the mock; K3.
8. IP-T8 (CRM project) templates, cost view, reconciliation screen; end-to-end run on a scratch database.

**Fable checkpoints**: FI1 after IP-T2 (facade surface, grants, isolation); FI2 after IP-T5 (contract frozen,
version 1); FI3 after IP-T8 (privacy check of payloads and logs, double-counting check, flag off = no trace), then
the owner's go-live in one clinic.

## 7. Decided 2026-11-16 (no open questions)
1. Reference sent by this facade: opaque card / episode uuid (3.4). Customer identity crosses only by the suite
   counterparty pull of 06 section 6.
2. Who may consume: all clinic staff; reversal only manager / owner (3.6).
3. Material requests: ONE REQ document that purchasing converts into a purchase order or a transfer (01 C5).
