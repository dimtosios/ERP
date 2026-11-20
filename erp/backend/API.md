# iSmile ERP: API contract for the front-end

The page calls ONLY functions of schema `erp_api`: `sb.schema('erp_api').rpc(name, args)` through `api()` in
`erp/app/00_core.js`. Tables are never read or written from the page.

## Conventions (all sections)
- **Identity**: the login token (`request.jwt.claims`: `sub`, `email`). A caller is a member when an ACTIVE `erp.members`
  row of an ACTIVE tenant is bound to its `sub` (binding: `member_bind`, E110). Tenant = from membership, never from
  the payload. v1: one email = one tenant.
- **Every function**: `security definer`, `search_path = ''`, `statement_timeout = 8s`, first `erp.require_member()`
  (`ERP_AUTH`) then `erp.can(capability[, branch])` (`ERP_FORBIDDEN`). Granted to `authenticated` only.
- **Writes** take `p_idempotency_key uuid` (required). A repeat with the same key and the same arguments returns the
  stored reply and writes nothing; same key with other arguments = `ERP_IDEMPOTENT_MISMATCH`. Every write adds an
  `erp.audit_log` row (changed keys only).
- **Lists** take `p_cursor jsonb` (the `next` of the previous reply, null = first page) and `p_limit int`, and
  return `{rows: [...], next: {...} | null}` (keyset paging, stable order).
- **Errors**: `message = 'ERP_<CODE>: <English sentence>'`; for `ERP_VALIDATION` the `details` field holds a JSON
  array of ALL problems `[{code, line_no, field, message}]`. The page maps the code to `err.<CODE>` in
  `strings.en.js` and falls back to the sentence.

## Error codes
| Code | Meaning |
|---|---|
| `ERP_AUTH` | no login, or the login is not an active, bound member of an active tenant |
| `ERP_FORBIDDEN` | role / capability / branch does not allow the action |
| `ERP_TENANT` | an id given by the caller does not belong to the caller's tenant (existence elsewhere is never told) |
| `ERP_VALIDATION` | input problems; array in `details` |
| `ERP_CONFLICT` | optimistic lock: the row changed since it was read (`version`) |
| `ERP_IDEMPOTENT_MISMATCH` | idempotency key reused for a different request |
| `ERP_LIMIT` | plan hook: tenant limit reached (`tenants.limits`; unlimited unless set) |
| `ERP_APPEND_ONLY` | update / delete / truncate of an append-only table (audit log; later ledgers) |
| `ERP_STATE` | the state move does not exist for the type, or the value needs approval (E130) |
| `ERP_DOC_IMMUTABLE` | edit / delete of a document that is not a draft (E130 trigger) |
| `ERP_SERIES_MISSING` | no active series can number the document (E130) |
| `ERP_LOCKED_PERIOD` | document date on / before the lock date: no post, cancel or recost (E130 / E140) |
| `ERP_DOC_HAS_CHILDREN` | cancel refused while a later document depends on it (E130) |
| `ERP_STOCK_NEGATIVE` | the post would take stock below zero where it is blocked (setting `block`, transit warehouse; a TRF receipt never takes transit below zero) (E140 / E160) |
| `ERP_CONVERT_NOTHING_LEFT`, `ERP_CONVERT_EXCEEDS`, `ERP_CONVERT_MIXED`, `ERP_CONVERT_NOT_ALLOWED` | document conversion (E135) |
| `ERP_RECOST_PENDING` | the lock date cannot move while costs before it are queued for recalculation (E140) |
| `ERP_LOT_REQUIRED`, ... | reserved by 03 section 3 for later files |
| `ERP_TIMEOUT`, `ERP_NETWORK`, `ERP_RPC_MISSING` | client side only (`api()`): 8 s timeout, no connection, function not deployed |

## E100 tenancy (T02)

### `whoami() -> jsonb`
Any member. Reply:
```json
{"member_id": "…", "email": "anna@clinic.gr", "display_name": "Anna", "role": "manager", "all_branches": false,
 "tenant": {"tenant_id": "…", "code": "ismile", "name": "iSmile", "plan": "standard"},
 "branches": [{"branch_id": "…", "code": "SER", "name": "Serres", "establishment_no": 0, "address": null, "active": true, "updated_at": "…"}],
 "caps": ["alert.read", "alert.resolve", "audit.read", "branch.read", "member.read", "tenant.settings.read"],
 "settings": {"time_zone": "Europe/Athens", "valuation_method": "average", "negative_stock": "warn", "lock_date": null, "hide_money": false},
 "today": "2026-11-18"}
```
`branches` = active branches the caller sees (owner / all-branches: all). The page builds menus and buttons from
`caps`; the server checks again on every call. Errors: `ERP_AUTH`.

### `branch_list(p_include_inactive boolean = false, p_cursor jsonb = null, p_limit int = 100) -> {rows, next}`
Cap `branch.read`. Visible branches ordered by code; `next = {code, branch_id}`; limit 1..500.

### `branch_save(p_branch jsonb, p_idempotency_key uuid) -> branch row`
Cap `branch.write` (owner). No `branch_id` = create, else change only the keys given. Keys: `code` (1-20 of
letters, digits, `-`, `_`; unique per tenant, case-insensitive), `name`, `establishment_no` (myDATA establishment,
0 = head office, unique per tenant, null allowed), `address`, `active`. Errors: `ERP_VALIDATION` (`required`,
`invalid`, `duplicate`), `ERP_TENANT` (branch of another tenant), `ERP_LIMIT` (`branches`).
```json
{"p_branch": {"code": "SER", "name": "Serres", "establishment_no": 0}, "p_idempotency_key": "6f1c…"}
```

### `settings_get() -> jsonb`
Cap `tenant.settings.read` (owner, manager, accounting). Reply: `time_zone, valuation_method, negative_stock,
lock_date, thresholds, logo_url, hide_money, integration_enabled, version, updated_at, can_write`.

### `settings_save(p_settings jsonb, p_idempotency_key uuid) -> settings`
Cap `tenant.settings.write` (owner). `version` (from `settings_get`) is required: a different version =
`ERP_CONFLICT`. Editable keys: `time_zone` (a PostgreSQL zone name), `negative_stock` (`warn` | `block`), `lock_date`
(yyyy-mm-dd, not in the future, null clears), `hide_money` (boolean), `logo_url` (https), `thresholds` (object of
numbers >= 0; keys are defined by the tasks that use them). `valuation_method` and `integration_enabled` are NOT
editable here (`not_editable`): valuation switch T39, Integration Pack phase IP.

### `audit_list(p_filter jsonb = {}, p_cursor jsonb = null, p_limit int = 50) -> {rows, next}`
Cap `audit.read` (owner, manager, accounting). Newest first; `next = {audit_id}`. Filter: `action` (prefix, e.g.
`branch.`), `table_name`, `row_id`. Rows of a branch the caller does not see are left out; tenant-wide rows (no
branch) only for owner / all-branches members. Row: `audit_id, at, actor, action, table_name, row_id, branch_id, old, new`.

### Capabilities seeded by E100 (`erp.role_cap_defaults`, copied per tenant into `erp.role_caps`)
| Capability | owner | manager | warehouse | accounting | clinic_user | readonly |
|---|---|---|---|---|---|---|
| tenant.settings.read | x | x | | x | | |
| tenant.settings.write | x | | | | | |
| member.read | x | x | | x | | |
| member.manage | x | | | | | |
| branch.read | x | x | x | x | x | x |
| branch.write | x | | | | | |
| audit.read | x | x (own branches) | | x | | |
| alert.read | x | x | x | x | x | x |
| alert.resolve | x | x | | | | |
A tenant changes its matrix by rows of `erp.role_caps` (`allowed = false` removes a default and survives re-runs).

## E110 members (T03)
How a person gets access: (1) `member_invite` stores a PENDING member for the email; (2) the person gets a Supabase
login for the same email (owner: Supabase Authentication > Users > Invite user; an existing login, e.g. CRM staff,
uses "Forgot password" on `erp.html`); (3) at sign-in the page calls `member_bind`, which links the invitation to
the login (`sub`). Only bound, active members pass `require_member`.

Member row (reply of every member RPC): `member_id, email, display_name, role, branch_ids, all_branches, active,
status (pending | active | inactive), invited_at, invited_by, bound_at, updated_at`. The Auth user id never leaves
the server.

### `member_bind(p_idempotency_key uuid) -> jsonb`
Self-service: the only RPC a not-yet-member calls. Needs a login (`ERP_AUTH` without). Replies:
`{"bound": true, "tenant_id": "…", "already": false}` (just bound) / `{"bound": true, …, "already": true}` /
`{"bound": false, "reason": "no_invitation"}` (no active invitation for the login email; nothing else is told) /
`{"bound": false, "reason": "bound_to_other_login"}` (the invitation is linked to ANOTHER login: never re-bound;
the owner gets one `member_bind_conflict` alert and uses `member_reset_binding`) /
`{"bound": false, "reason": "login_in_other_organisation"}` (the login is already linked to a member row, also an
inactive one or one of another tenant: v1 one login = one member row). An anonymous Supabase login (`is_anonymous`)
gets `ERP_AUTH`. The idempotency key replays only for the same login. Page: call it, then `whoami`.

### `member_list(p_filter jsonb = {}, p_cursor jsonb = null, p_limit int = 50) -> {rows, next}`
Cap `member.read` (owner, manager, accounting). Ordered by email; `next = {email, member_id}`; limit 1..200.
Filter: `q` (email or name contains, case-insensitive), `status`, `role`.

### `member_invite(p_member jsonb, p_idempotency_key uuid) -> member`
Cap `member.manage` (owner). Keys: `email` (required, stored lower-case), `role` (one of the six; a facade-only role
is refused), `branch_ids` (list of branch ids of the tenant), `all_branches` (boolean), `display_name`. A non-owner
needs at least one branch or `all_branches`. Problems: `required`, `invalid`, `email_taken` (same neutral text when
the email belongs to another tenant: v1 one email = one tenant), `not_editable` (unknown key). `ERP_TENANT`: a
branch of another tenant. `ERP_LIMIT`: `users` (active members). `ERP_FORBIDDEN`: role `owner` by a non-owner.
```json
{"p_member": {"email": "anna@clinic.gr", "role": "clinic_user", "branch_ids": ["…"], "display_name": "Anna"}, "p_idempotency_key": "…"}
```

### `member_update(p_member_id uuid, p_changes jsonb, p_idempotency_key uuid) -> member`
Cap `member.manage`. Keys: `role`, `branch_ids`, `all_branches`, `display_name`, `active` (only the keys given
change; the email cannot change: deactivate and invite the new address). `last_owner` problem: the tenant must keep
one active, bound owner. `ERP_TENANT`: member or branch of another tenant. Reactivation checks `ERP_LIMIT` (`users`).
`ERP_FORBIDDEN`: a non-owner (member.manage given to another role) giving the owner role or changing an owner.
Member administration of a tenant is serialised (advisory lock), so two owners cannot remove each other at once.

### `member_reset_binding(p_member_id uuid, p_idempotency_key uuid) -> member`
Cap `member.manage`. Unlinks the login (lost or recreated Auth user); status back to `pending`, the next sign-in
with the email binds again; resolves the member's `member_bind_conflict` alert. Own login: problem `self`. An
owner's login: owners only (`ERP_FORBIDDEN`), and never the last bound owner (`last_owner`).

### Onboarding (not an API function)
`erp.tenant_onboard(code, name, owner_email, owner_auth_user_id uuid = null)`: SQL editor only (not granted to any
API role). Creates the tenant if missing, its settings and permission matrix, and a pending owner invitation unless an
active owner exists. With the 4th argument (the owner's existing login id, `select id from auth.users where email =
…` typed in the editor) the owner row is bound at once (`owner_bound: true`). Re-runnable. Tenant #1: `erp/backend/seed/tenant1_onboarding.sql` (`psql -v owner_email=…`).

## E120 CSV import (T08)
The page parses the CSV (first row = column names, separator `;` `,` or TAB, quotes) and sends the KNOWN columns as
objects of text. Server rule: ALL OR NOTHING. Every row is checked with the same rules as the save RPC; with any
problem, or with `p_dry_run = true`, nothing is written. At most 2000 rows (`too_many`); empty list (`required`).
Reply `{dry_run, rows, created, updated, errors: [{row, code, field, message}]}` (`row` = 1-based data row; `dry_run`
is true whenever nothing was written). A reply with errors is not stored under the idempotency key; a clean reply is.
| Function | Capability | Columns / matching |
|---|---|---|
| `item_import(p_rows jsonb, p_dry_run boolean, p_idempotency_key)` | `item.write` (+ `master.archive` to deactivate) | `code` (match: existing code = update, else create), `name, kind, unit` (unit code), `category` (code), `vat` (VAT class code), `min_level, reorder_level, sales_price` (decimal comma accepted), `barcodes` (`a;b`), `description, active` (yes / no). Empty cell of an existing item = keep. Problems also: `unknown` (unit / category / VAT code), `duplicate` (code or barcode twice in the file) |
| `counterparty_import(p_rows jsonb, p_dry_run boolean, p_idempotency_key)` | `counterparty.write` | `name, code, kind, tax_id, tax_office, country, street, city, postal_code, email, phone, payment_terms_days, notes, ext_ref, active`. Match: same tax ID (and country), else same code = update; else create (`ext_ref` of a new row: `ext_source = import`). `duplicate`: the same counterparty twice in the file |
Screen: Master data > Items / Customers & suppliers > "Import CSV": file or paste, "Check (dry run)", then "Import"
(enabled only after a clean check of the same text; a new idempotency key per call).

## E130 documents core (T09)
Document = header + lines. A DRAFT has no number and is freely editable / deletable; any other state is never edited
(trigger; whitelist: notes, due date). Capabilities per type: `doc.<prefix>.read` (open / list), `.create` (save
draft, post when no approval is needed), `.approve` (approve, reject, cancel); the prefix is `doc_types.cap_prefix`
(`ADJ_IN` / `ADJ_OUT` share `adj`). A document of the caller's tenant in a branch it does not see, or of a type it
cannot read = `ERP_FORBIDDEN`; an id of another tenant = `ERP_TENANT`.

| Function | Notes |
|---|---|
| `doc_save_draft(p_type text, p_doc jsonb, p_idempotency_key)` | create (no `document_id`) or replace a draft (`document_id` + `version`, else `ERP_CONFLICT`). Header keys: `client_key` (8-120 of `A-Z a-z 0-9 : _ . -`; a second save with the same key updates the same draft; after posting it returns the posted document unchanged), `branch_id`, `doc_date` (yyyy-mm-dd, default today in the tenant zone), `series_id` (else the default series at post), `warehouse_id`, `dest_warehouse_id`, `counterparty_id`, `ref_document_id`, `ext_number`, `ext_date`, `due_date`, `notes`, `ext_ref`, `extra` (keys of the type's list). `lines` REPLACES the lines (max 500): `{item_id, description, qty, unit_id (default base unit), unit_price, discount_pct, vat_class_id (sale types: default the item's), ext_line_ref, source_line_id, extra}`. Line net = round(qty x price x (1 - discount/100), 2); VAT = round(net x rate, 2) per line; totals = sums. Shape errors (unknown key, not a number, ids of another tenant) refuse the save; business problems (missing warehouse, qty <= 0, unit not the base unit, missing cost, future date, ...) are returned in `problems` and block posting. Cap `.create` on the branch |
| `doc_get(p_document_id)` | the document reply (below). Cap `.read` |
| `doc_list(p_filter, p_cursor, p_limit = 50)` | visible branches x readable types, newest first; `next = {doc_date, document_id}`. Filter `doc_type` or `doc_types` (list), `branch_id, warehouse_id, counterparty_id, state, date_from, date_to, q` (number, external number or notes contains). Rows = header shape. No readable type = `ERP_FORBIDDEN` |
| `doc_delete_draft(p_document_id, p_idempotency_key)` | drafts only (`ERP_DOC_IMMUTABLE` otherwise); cap `.create` |
| `doc_set_state(p_document_id, p_to_state, p_options, p_idempotency_key)` | the ONE state-changing call; allowed moves and who = `erp.doc_transitions`. `p_options`: `ack_warnings` (post past `W_STOCK_NEGATIVE`), `reason` (cancel: required; reject: audited). Reply `{posted, warnings, document}`. `posted = false` + warnings = nothing changed (the reply is not stored under the key). Errors: `ERP_STATE` (no such move, or the value needs approval), `ERP_FORBIDDEN`, `ERP_VALIDATION` (the draft's problems), `ERP_SERIES_MISSING`, `ERP_LOCKED_PERIOD` (date on / before the lock date; also for cancel), `ERP_DOC_HAS_CHILDREN` (cancel while a later document depends on it), `ERP_LIMIT` (`documents`). Cancel (F2-05): reversing an inbound document that was consumed returns `warnings` (`W_STOCK_NEGATIVE`, `qty_after`) and goes ahead (audited `doc.cancel_negative_stock`); `ERP_STOCK_NEGATIVE` under the setting `block` or for the transit warehouse. A line's `source_line_id` must belong to a document the caller can read (`ERP_FORBIDDEN`, F2-06). The lock date is read FOR SHARE: a post / cancel running while the owner moves the lock date waits and then sees the new date (F2-03) |

T16 (generic, E130): a type with `doc_types.dest_visible` (TRF) is also read by the branch of its destination
warehouse once it is not a draft; a transition row has a `side` (`source` = `branch_id`, `dest` = the destination's
branch) on whose branch its capability is checked; actions `receive` / `close` run the type's own work
(`doc_types.action_fn`); a document that references another one (`ref_document_id`) notifies the parent's type after
each of its state changes (the TRF reacts to its difference adjustments). State `received_with_difference` (TRF).

Document reply: header `document_id, doc_type, state, branch_id, branch_code, series_id, number, doc_no (series code /
6 digits), doc_date, warehouse_id, warehouse_code, dest_warehouse_id, counterparty_id, counterparty_name,
ref_document_id, ext_number, ext_date, due_date, notes, ext_ref, currency, total_net, total_vat, total_gross, extra,
client_key, source, created_at, updated_at, approved_at, posted_at, cancelled_at, cancel_reason, version, line_count`
(+ `total_cost` with `cost.read`); `lines` (`line_id, line_no, item_id, item_code, item_name, description, qty,
unit_id, unit_code, qty_base, unit_price, discount_pct, vat_class_id, net, vat, gross, source_line_id, ext_line_ref,
extra`, + `unit_cost, cost_value` with `cost.read`); `actions` (the moves the caller may take now: `to_state, label,
action`; the buttons); `problems` (draft); `can_edit`.

Numbering: at post only, `erp.next_number` inside the posting transaction (a rollback returns the number: gapless);
series = the document's `series_id`, else the active default of (type, branch or organisation for OPN / MTR / CBAL,
year of the date), else the default without a year. Approval limit: `tenant_settings.thresholds[<approval_key>]`
(e.g. `adj_value`): a document above it goes `draft -> pending_approval` for a `.create` member; an `.approve`
member posts directly. No limit set = no approval.

## E135 document conversion (T44)
Allowed pairs = `erp.doc_conversions` (the 01 C5 matrix as data: `kind` fulfil / bill / credit / return / request,
`partial`, `n_to_one`, `stock_rule`); a pair works only when both types are enabled (none of the 01 C5 pairs is yet:
they open with T45 / T46). Remaining quantity per source line and kind = source qty_base minus the target lines of
documents that are not cancelled / failed (DRAFTS COUNT); never stored (view `erp.v_line_remaining`; status per kind
`open` / `partial` / `full`: view `erp.v_doc_conversion_status`). A target line keeps `source_line_id`; one
`document_links` row per (source, target, kind). Deleting / cancelling a target gives its quantity back. A source with
a live (posted) target cannot be cancelled (`ERP_DOC_HAS_CHILDREN`). In a target draft the item / unit of a converted
line, its quantity (<= remaining) and the counterparty are checked (problems `locked`, `exceeds`, `source_cancelled`).

| Function | Notes |
|---|---|
| `doc_convert(p_source_ids uuid[], p_target_type text, p_lines jsonb, p_idempotency_key)` | 1-50 posted sources of ONE type, branch and counterparty (else `ERP_CONVERT_MIXED`), locked in id order first; several only where the pair is N:1 (`ERP_CONVERT_NOT_ALLOWED`, also for a pair not in the matrix). `p_lines` null = everything that remains, else `[{source_line_id, qty}]` (base units; above the remaining = `ERP_CONVERT_EXCEEDS`; nothing = `ERP_CONVERT_NOTHING_LEFT`). Returns the target DRAFT (today's date; header from the first source; a full line keeps the source's rounded amounts, a partial one is recomputed). Cap `.create` of the target type on the source branch |
| `doc_copy(p_document_id, p_idempotency_key)` | a new draft of the same type, today's date, lines and prices kept, NO link. Cap `.create` |
| `doc_conversions_for(p_document_id)` | `{targets: [{target_type, kind, partial, n_to_one, status, lines: [{source_line_id, line_no, remaining}]}], created_from: [...], converted_to: [...]}` (the "Convert to" menu: targets the caller may create) |

## E140 stock engine (T10): what posting does (no new RPC; read models come with T14)
For a type that moves stock (`doc_types.stock_sign` +1 / -1), `doc_set_state(..., 'posted')` additionally: takes the
per-item locks (ascending item id, after the series row), checks negative stock, then writes ONE normal stock move per
stock line (service items: none), the balance of (warehouse, item), and costs the move under BOTH methods (weighted
average = official, FIFO kept). Line `unit_cost` / `cost_value` and the document's `total_cost` = the official values
(shown with `cost.read`). Purchasing receipts set the item's `last_purchase_price`.
- **Negative stock** (tenant setting `negative_stock = warn`, default): the reply has `posted: false` and
  `warnings: [{code: "W_STOCK_NEGATIVE", item_id, item_code, warehouse_id, warehouse_code, qty_after}]` and NOTHING is
  written; posting again with `p_options.ack_warnings = true` posts and audits the acknowledgement. The uncovered
  quantity is costed provisionally (last official cost) and corrected by the next receipt (one value-only move).
  `ERP_STOCK_NEGATIVE` (blocked, also with ack): setting `block`, or the transit warehouse.
- **Cancel** of a stock document: one reversing move per move at the ORIGINAL date with opposite quantity and values;
  the item is then costed again from that date as if the document never existed (later documents' costs follow).
- **Backdated** document (dated before an item's later moves): posted, then the item is costed again from its date.
- Guards: a move's quantity / inputs never change and moves are never deleted (`ERP_APPEND_ONLY`); an item with moves
  keeps its base unit / lot tracking / service kind; a warehouse holding stock keeps its branch and stays active
  (`ERP_VALIDATION`, problem `in_use`).

### Recost (T13)
A backdated post (or a cancel) costs the item again from that date in the same transaction when it has at most 2,000
later moves; with more, the post is costed at the current state and the item is QUEUED (`erp.recost_queue`) for the
job (`erp.recost_job(p_max default 50, p_budget_ms default 3000)`, every 5 minutes on live; it reads the queue without row
locks, TRIES each item's lock (a busy item is skipped, never a deadlock with a posting) and starts no new item after
its time budget, F2-02). Since F2 a cancel with more than 2,000 later moves, and any backdated post / cancel of an item
that is already queued from an earlier date, also goes to the queue (the cost row follows the reversal by its values;
`stock_integrity` checks such an item's cost state after the job); the nightly job reports a queue row older than one
hour (`recost_stale`: the recost job is not running). An issue of an item with no cost history is costed at
`stock_moves.fallback_cost` = the last purchase price when it was posted (F2-01, O2), under both methods. Every rewrite of an already posted move is one `erp.cost_revisions`
row (run, move, old / new values; reason `backdate`, `cancel`, `queue`); quantities, prices and fiscal data never
change. No replay starts on or before the lock date (`ERP_LOCKED_PERIOD`) and the lock date cannot move over a queued
recost (`ERP_RECOST_PENDING`). The nightly `erp.integrity_job` raises one critical `integrity` alert (tenant-wide)
while balances / cost state / layers differ from the ledger.

| Function | Capability | Notes |
|---|---|---|
| `recost_status() -> {pending, oldest_from_date, items: [{item_id, item_code, from_date, queued_at}]}` | `stock.read` | "recost pending" banner of the reports |
| `recost_run(p_limit int, p_idempotency_key) -> {items, moves, pending}` | `tenant.settings.write` (owner) | runs up to `p_limit` (1-100) queued items of the tenant now (3 s budget, busy items skipped) |

### Read models (T14; quantities with `stock.read`, cost columns only with `cost.read`; visible warehouses only)
| Function | Notes |
|---|---|
| `stock_on_hand(p_filter, p_cursor, p_limit = 50)` | one row per (warehouse, item) with a balance: `warehouse_id, warehouse_code, branch_id, item_id, item_code, item_name, unit_code, qty, reserved, available, min_level, low, negative` (+ `avg_cost, value`). Filter `warehouse_id` (another branch's: `ERP_FORBIDDEN`), `branch_id`, `q` (code prefix, name, exact barcode), `category_id`, `only` (`low` / `negative` / `nonzero`). `next = {item_code, warehouse_code, item_id, warehouse_id}` |
| `stock_card(p_item_id, p_filter, p_cursor, p_limit = 100)` | moves oldest first (`warehouse_id`, `date_from`, `date_to`): `move_id, move_date, kind (normal / reversal / value_only), document_id, doc_type, doc_no, doc_state, warehouse_code, qty, running_qty, provisional` (+ `official, value, unit_cost, value_avg, value_fifo`); `opening_qty` = quantity before the page; `item`. `next = {move_date, move_id}` |
| `item_lookup(p_query, p_warehouse_id = null, p_limit = 20)` | active items by code prefix / name / exact barcode (barcode match first): `item_id, code, name, kind, base_unit_id, unit_code, barcode_match, on_hand, available, low, negative` (of the warehouse, or of all visible ones). Cap `item.read` |
| `item_availability(p_item_id)` | per visible active warehouse: `qty, reserved, available, low, negative`; `recost_pending` (+ `avg_cost`) |

## E100 alerts (T14)
| Function | Capability | Notes |
|---|---|---|
| `alert_list(p_filter = {}, p_cursor, p_limit = 50)` | `alert.read` | open alerts of the visible branches (tenant-wide ones: owner / all branches), newest first; filter `kind`, `branch_id`, `include_resolved`. Row `alert_id, branch_id, kind, severity, message_key, params, created_at, resolved_at, can_resolve`; `next = {created_at, alert_id}` |
| `alert_resolve(p_alert_id, p_idempotency_key)` | `alert.resolve` on the alert's branch | marks it resolved (a stock alert also resolves itself when the balance is back) |

## E150 stock documents (T11: OPN, GRN; T12: ADJ_IN, ADJ_OUT, CONS)
| Type | Header | Lines | Moves | Who (create / approve) |
|---|---|---|---|---|
| `OPN` opening balance | `branch_id, warehouse_id` (of the branch), `doc_date`; series organisation-wide (`OPN`) | `item_id, qty, unit_price` (= unit cost, required, >= 0); one line per item | + at the line value | `doc.opn.create` manager / owner prepares and submits (`pending_approval`); `doc.opn.approve` owner posts / rejects / cancels |
| `GRN` goods receipt (without PO) | `branch_id, warehouse_id, counterparty_id` (supplier or both), `ext_number` (supplier delivery note), `ext_date` (not after the receipt), `extra.mark` (myDATA MARK, digits) | `item_id, qty, unit_price, discount_pct` (cost = net / qty) | + at net; sets the item's last purchase price | `doc.grn.create` owner / manager / warehouse post; `doc.grn.approve` owner / manager cancel |
Read: `doc.<type>.read` = owner, manager, warehouse, accounting, readonly (clinic_user: no). No VAT on these lines.

| `ADJ_IN` stock adjustment + | `branch_id, warehouse_id, extra.reason` (`found` / `correction`) | `item_id, qty, unit_price` (optional: without it the current official cost) | + | `doc.adj.create` owner / manager / warehouse post up to the limit `thresholds.adj_value` (else submit); `doc.adj.approve` owner / manager approve, reject, cancel, post any value |
| `ADJ_OUT` stock adjustment - | `branch_id, warehouse_id, extra.reason` (`damaged` / `expired` / `lost` / `correction`) | `item_id, qty` (no price) | - at cost | as ADJ_IN; the value = qty x current official cost |
| `CONS` internal consumption | `branch_id, warehouse_id, extra.cost_centre` (optional, 60), `ext_ref` (free external reference, 100) | `item_id, qty, ext_line_ref` | - at cost | `doc.cons.create` owner / manager / warehouse / clinic_user (own branch) post; `doc.cons.approve` owner / manager REVERSE (= cancel: stock and cost restored) |
ADJ / CONS read: owner, manager, warehouse, accounting, readonly (+ clinic_user for CONS). Posting raises / resolves the
in-app alerts `negative_stock` (one open per warehouse and item, branch of the warehouse; resolved when >= 0) and
`low_stock` (quantity below the item's `min_level`; resolved when back). Alert params: `item_id, item_code,
warehouse_id, warehouse_code, qty` (+ `document_id, doc_no` / `min_level`).

### `doc_check(p_document_id) -> {document_id, state, problems, warnings, value}`
Cap `.read` of the type. A draft / pending document: its problems and the warnings a post would give now
(`W_STOCK_NEGATIVE`); a blocked negative (setting `block`) is the problem `stock_negative`. Nothing written, no lock.
`value` (the approval value) only with `cost.read`.

### `report_negative_stock(p_filter = {}, p_cursor, p_limit = 100) -> {rows, next}`
Cap `stock.read` (every role). Balances below zero of the visible branches; filter `branch_id`, `warehouse_id`;
oldest first, `next = {negative_since, warehouse_id, item_id}`. Row: `branch_id, warehouse_id, warehouse_code,
item_id, item_code, item_name, qty, negative_since, days_negative, document_id, doc_type, doc_no` (the document that
took it below zero), `posted_by_email`; `provisional_value` (qty x average cost) only with `cost.read`. Same data for
SQL / reports: view `erp.rpt_erp_negative_stock` (security_invoker: the caller's RLS applies).

### `opening_import(p_doc jsonb, p_rows jsonb, p_dry_run boolean, p_idempotency_key) -> jsonb`
Cap `doc.opn.create` on `p_doc.branch_id`. `p_doc`: `branch_id, warehouse_id` (active, of the branch), `doc_date`
(optional). Rows `{item (code), qty, unit_cost}` (decimal comma accepted), at most 2000 (`too_many`). All or nothing:
problems `unknown`, `inactive`, `invalid` (qty > 0 with 4 decimals, cost >= 0, service item), `duplicate` (item twice),
`not_editable` (other column), each with its `row`. Reply `{dry_run, rows, total_value, errors}`; a clean real run
creates ONE OPN DRAFT (`source = import`) and adds `document` (the document reply). The owner posts it as usual.

## E160 transfers (T16: TRF internal)
| Type | Header | Lines | Who |
|---|---|---|---|
| `TRF` transfer | `branch_id` + `warehouse_id` (source, of the branch), `dest_warehouse_id` (required: an active normal warehouse, not the source; any branch), `doc_date` (= dispatch date), `notes`, `extra.delivery` (optional `{carrier, vehicle, notes}`, text <= 100) | `item_id, qty` (no price: it moves at cost; one line per item; no service items) | `doc.trf.create` owner / manager / warehouse: draft + dispatch on the SOURCE branch, receipt (and the manual close) on the DESTINATION branch; `doc.trf.approve` owner / manager of the source: cancel a dispatched transfer. Read `doc.trf.read`: owner, manager, warehouse, accounting, readonly (clinic_user: no) on the source branch, and on the destination branch once dispatched |

States (02): `draft -> dispatched -> received` (no difference) or `-> received_with_difference -> closed` (after the
generated adjustments are posted); `dispatched -> cancelled`. All moves through `doc_set_state` (E130); the buttons
are `actions` (labels `doc.action.dispatch`, `doc.action.receive`, `doc.action.receive_difference`, `doc.action.close`,
`doc.action.cancel`; strings with T18). The list (`doc_list`, `doc_type: "TRF"`) shows a transfer to its source and,
once dispatched, to its destination branch (`branch_id` filter matches either side; `warehouse_id` either warehouse).

- **Dispatch** `doc_set_state(id, 'dispatched', {ack_warnings})`: like a post (02 lock order; the number of the
  source branch's TRF series, gapless; `posted: true` in the reply). Per line two moves: source `-qty`, the tenant's
  transit warehouse `+qty`. The source may go negative only with the usual warning path (`W_STOCK_NEGATIVE`,
  `posted: false`, nothing written, the reply is not stored under the key; again with `ack_warnings: true`;
  `ERP_STOCK_NEGATIVE` under the setting `block`). Cost: the moved quantity at the item's cost (average: avg_cost;
  FIFO: FIFO value / qty); the item's cost state and FIFO layers do not change (no layer is consumed). Line
  `unit_cost` / `cost_value` = the dispatch's official value.
- **Receipt** `doc_set_state(id, 'received' | 'received_with_difference', {receipt_date, lines})` by the destination:
  `receipt_date` (yyyy-mm-dd, default today; not before the dispatch, not in the future, `ERP_LOCKED_PERIOD` on /
  before the lock date), `lines: [{line_id, received_qty, reason}]` (base units, >= 0; a line not listed = received as
  dispatched; a difference needs `reason` (<= 200)). The target state must match: any difference ->
  `received_with_difference`, none -> `received` (else problem `state` on `to_state`). Moves per line: transit
  `-min(received, dispatched)`, destination `+` the same, both at the DISPATCH cost (no drift through transit; a part
  at round(qty x the dispatch unit cost, 2)). Transit never goes below zero (`ERP_STOCK_NEGATIVE`, whatever the
  setting). Reply adds `receipt: {receipt_date, adjustments: [document ids]}`.
- **Difference**: the receipt creates DRAFTS (`source = system`, destination branch, dated the receipt date,
  `ref_document_id` = the transfer): `ADJ_OUT` OUT OF THE TRANSIT WAREHOUSE for the shortage (reason `lost`; the
  shortage stays in transit until it is posted) and / or `ADJ_IN` into the destination for the excess (reason
  `found`, at the current cost). They follow the normal ADJ path (`thresholds.adj_value`: post under the limit,
  else submit -> approve / reject, E150). Editable: reason, notes, date (not before the receipt); anything else
  (items, quantities, warehouse, branch) = problem `mismatch` / `invalid`; they cannot be deleted (`ERP_STATE`) and,
  once posted, not cancelled (`ERP_DOC_HAS_CHILDREN`). No other ADJ may reference a transfer. When the last of them
  is posted the transfer moves to `closed` by itself (as the poster, when it holds `doc.trf.create` on the
  destination; else the destination closes it: `doc_set_state(id, 'closed', {})`, refused with `ERP_STATE` while an
  adjustment is not posted).
- **Cancel** `doc_set_state(id, 'cancelled', {reason})` (source approver, dispatched only): reversing moves (stock back
  from transit to the source), the number is kept. A received transfer is never cancelled (`ERP_STATE`).
- Transit: `erp.integrity_job` (nightly) reports `transit_negative`, `transit_open` (a transfer holds in transit other
  than: dispatched = its quantities, received_with_difference = its shortage until the ADJ_OUT is posted, otherwise 0)
  and `transit_value` (a settled transfer without a shortage left value in transit). The source / destination
  warehouse of an open transfer keeps its branch and stays active (`ERP_VALIDATION`, problem `in_use`).
- Fiscal: a transfer between two establishments is a fiscal movement document (01 C3, myDATA 9.3): **T36**. v1 posts
  every TRF as an internal, non-fiscal document; `trf_get` tells `fiscal_needed`.

### `trf_get(p_document_id) -> document reply + transfer`
Cap `doc.trf.read` (source, or destination once dispatched). `transfer = {source_branch_id, dest_branch_id,
dest_warehouse_code, fiscal_needed, receipt: {receipt_date, received_at, received_by_email, closed_at} | null, lines:
[{line_id, line_no, item_id, dispatched_qty, received_qty, diff_qty, diff_reason, in_transit}], adjustments:
[{document_id, doc_type, state, doc_no}]}`. Not a transfer: `ERP_VALIDATION`.

### `trf_warehouses() -> {rows: [{warehouse_id, branch_id, branch_code, code, name, active}]}` (T18)
Cap `doc.trf.read` (any branch). The normal warehouses of EVERY branch of the tenant (never the transit warehouse),
inactive ones too (`active` = warehouse and branch active): the destination picker of the Transfers screen and the
"To" column of its list (`warehouse_list` shows only the caller's branches). Codes and names only.

Example (receipt with a difference):
```
doc_set_state('…trf id…', 'received_with_difference',
  {"receipt_date": "2026-11-19", "lines": [{"line_id": "…", "received_qty": 3, "reason": "2 broken in the box"}]}, key)
-> {"posted": false, "warnings": [], "receipt": {"receipt_date": "2026-11-19", "adjustments": ["…ADJ_OUT id…"]},
    "document": {"doc_type": "TRF", "state": "received_with_difference", "doc_no": "TRF-A1/000004", …}}
```

## E180 expenses (T19 / T20 lite: EXP, expense categories, expense report)
EXP is a normal E130 document (`doc_save_draft('EXP', …)`, `doc_get`, `doc_list`, `doc_set_state`, `doc_copy`,
`doc_delete_draft`). Header: `branch_id` (numbered per branch at post: series `EXP-<branch>`), `doc_date`,
`counterparty_id` (optional supplier; a customer-only counterparty is a problem), `ext_number` / `ext_date` (supplier's
document), `notes`, `extra`: `mark` (digits), `paid` (boolean, paid on the spot), `payment_method` (`cash` | `card` |
`bank` | `other`, only when paid), `cost_centre` (60). Lines: `{expense_category_id, description, qty (1), unit_price
(the net amount), vat_class_id (default: the category's default VAT class when the key is absent)}`; net / VAT / gross
per line by the core rule (VAT rounded per line, half up). No item on an EXP line. No stock, AP or payment effect.
Transitions: draft -> posted (`doc.exp.create` up to `thresholds.exp_value` on the net; `doc.exp.approve` any value),
draft -> pending_approval (create, above the limit) -> posted (approve) / -> draft (reject, approve), posted ->
cancelled (`doc.exp.create`, reason required). Lock date as every document. Roles: create owner / manager / accounting,
approve owner / manager, read also warehouse / readonly.

### `expense_category_list(p_include_inactive = false, p_cursor, p_limit = 200) -> {rows, next}`
Cap `doc.exp.read`. Rows `{category_id, parent_id, code, name, path, default_vat_class_id, vat_code, vat_rate, active,
updated_at}` ordered by code; next = `{code, category_id}`. Every tenant starts with 10 defaults (RENT, UTIL, TEL,
OFFICE, FEES, MAINT, MKT, TRAVEL, BANK, OTHER).

### `expense_category_save(p_category jsonb, p_idempotency_key) -> category`
Cap `expense.category.write` (owner, manager, accounting). Keys `category_id` (update), `parent_id`, `code`, `name`,
`default_vat_class_id`, `active`. Tree of 8 levels, no cycle; deactivation refused while an active sub-category exists.

### `report_expenses(p_filter = {}) -> {group_by, date_from, date_to, rows, totals, truncated}`
Cap `doc.exp.read`; posted EXP of the caller's branches. Filter `group_by` (`category` | `supplier`), `date_from` /
`date_to` (default this month to today), `branch_id`, `category_id` (with sub-categories), `counterparty_id`. Rows
`{key_id, code, name, path (category), docs, lines, net, vat, gross, paid_gross}` by gross desc (at most 1000);
`totals {docs, lines, net, vat, gross, paid_gross}`. View `erp.rpt_erp_expenses` (one row per posted EXP line,
caller's RLS).

## E190 attachments + delivery note -> DRAFT GRN (Draft 1)
Files are stored IN the database (`erp.attachments.content` bytea, storage external): at most 5 MB (5 242 880 bytes),
PDF / JPEG / PNG only, decided by the first bytes (`%PDF-`, `FF D8 FF`, PNG signature; a declared `mime` must agree),
`sha256` (hex) kept. Only GRN documents take files in this build. Append-only: only the link (`document_id`, set by the
draft RPC or cleared when a draft is deleted) and a one-time soft delete change; the bytes stay. Audit
`attachment.add` / `attachment.delete` / `grn.draft_from_extraction`; usage counter `attachments` (`check_limit`).

### `attachment_add(p_attachment jsonb, p_idempotency_key) -> attachment`
Cap `doc.grn.create` on the file's branch. Keys `document_id` (a GRN: linked, its branch) or `branch_id` (not linked
yet), `filename` (200, no `/` `\`), `mime` (optional), `content_base64`. Problems: `required`, `too_large`, `type`,
`invalid`. Reply (never the bytes) `{attachment_id, branch_id, document_id, kind, filename, mime, size_bytes, sha256,
uploaded_by, uploaded_by_email, uploaded_at, deleted_at}`. The idempotency hash uses an md5 of the content.

### `attachment_list(p_document_id, p_include_deleted = false) -> {rows}`
Cap `doc.grn.read` on the document's branch + the document readable. Rows as above, oldest first.

### `attachment_get(p_attachment_id) -> attachment + content_base64`
Cap `doc.grn.read` on the file's branch (+ its GRN readable). A deleted file: problem `deleted`.

### `attachment_delete(p_attachment_id, p_idempotency_key) -> attachment`
Soft delete. Cap `doc.grn.create`; a file of a posted / cancelled GRN needs `doc.grn.approve`.

### Extraction contract `delivery_note_extraction` (version 1)
`{schema: "delivery_note_extraction/1" (optional), extractor (60), supplier: {tax_id, name}, dn_number (60), dn_date
(yyyy-mm-dd), lines: [{description, supplier_code, barcode, qty, unit, unit_price, confidence 0..1}] (1-500),
warnings: [text]}`. Unknown keys are ignored. Produced by the extractor (future Edge Function; in this build the page's
`window.ERP_EXTRACTOR`, default a MOCK). Full text: E190 section 4.

### `grn_draft_from_extraction(p_extraction, p_attachment_id, p_warehouse_id, p_client_key) -> {created, document, summary}`
Cap `doc.grn.create` on the warehouse's branch. Creates a DRAFT GRN through `doc_save_draft` (never posts): supplier =
the one active supplier / both whose normalised tax ID equals `supplier.tax_id`; each line -> an ACTIVE non-service
item by barcode, then item code = `supplier_code`, then exact name = `description` (one item only); line `extra.dn =
{status matched | unmatched | low_confidence (confidence < 0.80 or missing), match, description, supplier_code, barcode,
unit, confidence, checked}`; header `extra.dn = {attachment_id, extractor, warnings, supplier {tax_id, name, matched}}`;
`ext_number` / `ext_date` from the note (a bad date -> a warning); bad qty -> 0, bad price -> empty (core problems).
Problems that block posting (`erp.grn_dn_validate` via E150): `not_matched` (line without item; supplier not found),
`check_line` (low confidence until the user sets `extra.dn.checked = true` with `doc_save_draft`). The file must be of
the same branch, not deleted, not linked; it is linked to the draft. Idempotent by `p_client_key` (8-120 of
`A-Z a-z 0-9 : _ . -`; the page uses `dn:<attachment_id>`): a repeat returns `created: false` and the draft as it is
now. `summary = {lines, matched, unmatched, low_confidence, supplier_matched, problems}`.

## E210 sales lite (Draft 2: DN, RR, RS; NON-FISCAL)
Types on the generic core (`doc_save_draft` / `doc_get` / `doc_list` / `doc_set_state` / `doc_copy` / `doc_delete_draft`),
numbered per branch at post from a GAPLESS series (`DN-<branch>`, `RR-<branch>`, `RS-<branch>` from `series_create_defaults`;
a series with `gapless = false` is a problem `invalid series_id`), states `draft -> posted -> cancelled` (cancel: reason,
`doc.<dn|rr|rs>.approve` = owner / manager; reversing stock moves). `doc_types.fiscal = false` in v1 (internal documents).
- DN: warehouse, customer (`counterparty_id` required; kind customer / both), `extra.delivery = {reason (sale |
  sale_on_approval | sample | repair | return | other, required), address (200), carrier (80), vehicle (20)}`,
  `extra.to_be_billed` (boolean, default true). Lines: goods items, `unit_price` optional (sale price), VAT class default =
  the item's when the key `vat_class_id` is ABSENT; a priced line needs a VAT class. Stock OUT at the official cost (cost
  rule `issue`), negative-stock warning / `ack_warnings` / block as for CONS. Create: owner, manager, warehouse, accounting.
- RR: warehouse, customer optional, `extra.payment_method` (cash | card | bank | other, required: collected at issue),
  price required. A line that bills a DN line carries `extra.dn_line_id` and the header `ref_document_id` = that DN (one DN
  per receipt; same branch and customer; DN posted and to be billed; quantity <= the DN line's remaining, drafts count):
  such a line moves NO stock (E140 skips it). A DN with a live (not cancelled, not draft) receipt cannot be cancelled
  (`ERP_DOC_HAS_CHILDREN`). Create: owner, manager, accounting, clinic_user.
- RS: branch (no warehouse), service items or description lines, payment method, no stock. Create: owner, manager, accounting.
- Read: DN owner / manager / warehouse / accounting / readonly; RR, RS owner / manager / accounting / readonly (+ clinic_user RR).

### `sales_get(p_document_id) -> document reply + sales`
Read like `doc_get` (`ERP_TENANT` / `ERP_FORBIDDEN`); a non-sales document is `ERP_VALIDATION`. `sales = {fiscal: false,
fiscal_needed: true, watermark: "NOT A FISCAL DOCUMENT", issuer {name (tenants.name), logo_url, legal_name, tax_id,
tax_office, address, phone, email (tenant_settings.issuer)}, branch {code, name, address, establishment_no}, warehouse
{code, name} | null, customer {name, code, tax_id, tax_office, country, street, city, postal_code, phone, email} | null,
vat_breakdown [{vat_class_id, code, rate, net, vat, gross}]}`, DN: `billing {to_be_billed, status open | partial | full |
not_to_be_billed (posted receipts), lines [{line_id, qty, billed, in_drafts, remaining}], receipts [{document_id, doc_type,
doc_no, state}]}`, RR / RS: `collection {payment_method, amount, rcpt: null}`, RR: `dn {document_id, doc_no} | null`.
The page's print view is built from this reply (browser Print -> Save as PDF).

### Hook for the receipt of collection (next task; internal, not an RPC)
`erp.sales_collection(tenant, document) -> {document_id, doc_type, doc_no, doc_date, branch_id, counterparty_id,
payment_method, amount, currency}` for a POSTED RR / RS, else null. The RCPT task creates its record from it on post.

### Settings: `issuer` (Draft 2)
`settings_save` accepts `issuer` = object of `legal_name, tax_id (2-20 A-Z 0-9), tax_office, address, phone, email`
(texts <= 300; the block is replaced; empty values dropped); `settings_get` returns it.

## Front-end (T04): which screen calls what
| Screen | Calls | Capability shown / used |
|---|---|---|
| Sign-in (every load) | `member_bind`, then `whoami` (`ERP_AUTH` -> "No access") | - |
| Home | (whoami data) | any member |
| Admin > Members | `member_list` (search `q`, keyset "Load more"), `member_invite`, `member_update` (changed keys only), `member_reset_binding` | tab: `member.read`; buttons: `member.manage` |
| Admin > Branches | `branch_list(true)`, `branch_save` (changed keys only), then `whoami` again | tab: `branch.write` or `member.read` or `tenant.settings.read`; button: `branch.write` |
| Admin > Settings | `settings_get`, `settings_save` (`version` + changed keys; lock date typed dd/mm/yyyy, sent ISO) | tab: `tenant.settings.read`; save: `can_write` |
| Master data (T07) > Items, Categories, Units, VAT classes, Warehouses, Customers & suppliers, Series | `*_list` (keyset "Load more", search `q` on items / counterparties), `*_save` (changed keys + id, `version` for items / counterparties), `doc_type_list`, `series_create_defaults` | tab: the list's read capability; New / Save: the write capability; deactivate checkbox: `master.archive` / `counterparty.archive` |
| Stock (T14) > On hand | `warehouse_list`, `stock_on_hand` (filters, keyset), row -> `stock_card` drawer | `stock.read`; values with `cost.read` |
| Stock > Documents | `doc_list` (types OPN / GRN / ADJ_IN / ADJ_OUT / CONS the caller reads), New: `doc_save_draft` (lines: `item_lookup` by code / barcode), `doc_get`, buttons from the document's `actions` -> `doc_set_state` (post; warnings dialog -> again with `ack_warnings`; cancel / reject with a reason), `doc_delete_draft`, `doc_copy`; "Import opening stock": `opening_import` (check, then the OPN draft) | the type's `.read` / `.create`; import: `doc.opn.create` |
| Stock > Documents > GRN drawer, Delivery note box (Draft 1) | `attachment_list` (files of the receipt), file picker -> `attachment_add` (base64; branch of the chosen warehouse, or the receipt), Open -> `attachment_get` (link + photo preview), Delete -> `attachment_delete`; new receipt: "Create draft from note" -> `window.ERP_EXTRACTOR` (default MOCK) -> `grn_draft_from_extraction` (client_key `dn:<file id>`) -> the draft opens, flagged lines, "Mark checked" -> `doc_save_draft` keeps line `extra.dn` | upload / create: `doc.grn.create`; files: `doc.grn.read`; delete on a posted GRN: `doc.grn.approve` |
| Stock > Negative stock | `report_negative_stock` | `stock.read` |
| Stock > Alerts | `alert_list`, `alert_resolve` | `alert.read` / `alert.resolve` |
| Transfers (T18) | `doc_list` (`doc_type: TRF`, filters `state`, `branch_id`; keyset), `trf_warehouses`, `warehouse_list` (source), row -> `trf_get` drawer (the stock document drawer: source / destination / delivery, lines by `item_lookup`; buttons from `actions`: Dispatch -> `doc_set_state('dispatched')` with the warnings dialog -> `ack_warnings`, Cancel with a reason); "Confirm receipt" (one button for the two receive actions) -> receipt form by line -> `doc_set_state('received' \| 'received_with_difference', {receipt_date, lines})`; generated adjustments open in the stock drawer (`doc_get`; TRANSIT warehouse and lines read-only) | menu `doc.trf.read`; New: `doc.trf.create`; buttons from `actions` |
| Expenses (T20) > List | `doc_list` (`doc_type: EXP`, filters `state`, `branch_id`, `date_from`, `q`; keyset), `expense_category_list`, `vat_class_list`, `counterparty_list` (suppliers), row -> `doc_get` drawer (the stock document drawer, DOC_FORM.EXP: branch, date, supplier, supplier's number / date, MARK, paid + method, cost centre; lines category / description / net / VAT class with VAT and gross; buttons from `actions`, cancel / reject with a reason) | menu `doc.exp.read`; New: `doc.exp.create` |
| Expenses > Categories | `expense_category_list(true)`, `expense_category_save` | tab `doc.exp.read`; New / Save: `expense.category.write` |
| Expenses > Report | `report_expenses` (by category / supplier, dates, branch), CSV download built in the page | `doc.exp.read` |
Admin menu entry: any of `member.read`, `branch.write`, `tenant.settings.read` (owner, manager, accounting).
Master data menu entry: any of `item.read`, `warehouse.read`, `counterparty.read`, `series.read` (every role).
All calls go through `api()` (00_core.js): idempotency key per drawer (renewed after a success), 8 s timeout,
`ERP_<CODE>` -> `err.<CODE>` string, problem list from `details`, "Not saved" on an error or an empty reply.

## E120 master data, part 1 (T05): units, VAT classes, categories, items, barcodes
Every new tenant gets (trigger on `erp.tenants`) the units PCS, BOX, PACK, KG, L, M and the VAT classes VAT24 (24 %,
myDATA category 1), VAT13 (2), VAT6 (3), VAT0 (0 %, category 7, exemption reason empty): editable defaults, the
**accountant confirms** rates, categories and exemption reasons. All lists: keyset `next` as noted, `p_limit` 1..500
(items 1..200). All saves: no id = create, else only the keys given change; unknown key = problem `not_editable`;
an id of another tenant = `ERP_TENANT`; reply = the saved row.

| Function | Capability | Notes |
|---|---|---|
| `unit_list(p_include_inactive = false, p_cursor, p_limit = 100)` | `item.read` | order code; `next = {code, unit_id}`. Row: `unit_id, code, name, decimals, active, updated_at` |
| `unit_save(p_unit, p_idempotency_key)` | `item.write` | keys `unit_id, code` (1-12: letters, digits, `. - _`; unique, case-insensitive), `name`, `decimals` (0-4), `active`. Deactivate: `master.archive` and no active item uses it (`in_use`) |
| `vat_class_list(p_include_inactive = false, p_cursor, p_limit = 100)` | `vat.read` | `next = {code, vat_class_id}`. Row: `vat_class_id, code, name, rate, mydata_category, exemption_code, active` |
| `vat_class_save(p_vat, p_idempotency_key)` | `vat.write` | keys `vat_class_id, code, name, rate` (0-100, 2 decimals), `mydata_category` (1-20), `exemption_code` (myDATA code, digits), `active` (deactivate: `counterparty.archive`). The rate of a class used by a posted line cannot change (E130 trigger): add a new class |
| `category_list(p_include_inactive = false, p_cursor, p_limit = 200)` | `item.read` | flat, order code; row `category_id, parent_id, code, name, path ("A / B / C"), valuation_override, active` |
| `category_save(p_category, p_idempotency_key)` | `item.write` | keys `category_id, parent_id` (null = top), `code, name, active`. Problems `cycle`, `too_deep` (8 levels), `in_use` (deactivate with active children; needs `master.archive`). `valuation_override` is read-only (valuation switch T39) |
| `item_list(p_filter = {}, p_cursor, p_limit = 50)` | `item.read` | filter `q` (code prefix, name contains, or an exact barcode), `category_id` (with sub-categories), `kind`, `active` (`"true"` default, `"false"`, `"all"`); order code; `next = {code, item_id}` |
| `item_get(p_item_id)` | `item.read` | one item |
| `item_save(p_item, p_idempotency_key)` | `item.write` | keys `item_id, version` (optional optimistic lock: other version = `ERP_CONFLICT`), `code` (1-40), `name`, `description`, `kind` (`goods` / `consumable` / `service`), `base_unit_id` (required, active), `category_id`, `vat_class_id`, `min_level`, `reorder_level` (>= 0; not for a service), `sales_price` (>= 0), `lot_tracked` (refused until lots arrive, T37: `not_available`), `active` (deactivate: `master.archive`, else `ERP_FORBIDDEN`), `barcodes` (list, replaces the item's barcodes; EAN-8 / UPC-A / EAN-13 check digit for all-digit codes of those lengths: `checksum`; unique per tenant: `duplicate`) |

Item row: `item_id, code, name, kind, base_unit_id, unit_code, lot_tracked, active, barcodes`; plus with
`item.detail.read` (everyone but clinic_user, 02 matrix "name, unit, on hand"): `description, category_id,
category_code, vat_class_id, vat_code, min_level, reorder_level, sales_price, version, updated_at`; plus with
`cost.read` (owner, manager, accounting, readonly): `last_purchase_price` (set by posting, never typed).

| Capability | owner | manager | warehouse | accounting | clinic_user | readonly |
|---|---|---|---|---|---|---|
| item.read | x | x | x | x | x | x |
| item.detail.read | x | x | x | x | | x |
| item.write | x | x | x | | | |
| master.archive | x | x | | | | |
| vat.read | x | x | x | x | | x |
| vat.write | x | x | | x | | |
| counterparty.archive | x | x | | | | |
| cost.read | x | x | | x | | x |
| stock.read (E150) | x | x | x | x | x | x |
| warehouse.read | x | x | x | x | x | x |
| warehouse.write (own branches) | x | x | x | | | |
| counterparty.read | x | x | x | x | | x |
| counterparty.write | x | x | | x | | |
| series.read | x | x | | x | | |
| series.write | x | | | | | |

## E120 master data, part 2 (T06): warehouses, counterparties, document types, series
| Function | Capability | Notes |
|---|---|---|
| `warehouse_list(p_filter = {}, p_cursor, p_limit = 100)` | `warehouse.read` | warehouses of the visible branches; filter `branch_id`, `include_inactive`, `include_transit` (only owner / all-branches members ever get the transit warehouse); `next = {code, warehouse_id}`. Row: `warehouse_id, branch_id, branch_code, code, name, kind (normal / in_transit), active` |
| `warehouse_save(p_warehouse, p_idempotency_key)` | `warehouse.write` on the branch (old and new) | keys `warehouse_id, branch_id` (required), `code` (unique; `TRANSIT` reserved), `name`, `active` (deactivate: `master.archive`). The transit warehouse (one per tenant, created with the tenant, no branch) cannot be changed: `ERP_FORBIDDEN` |
| `counterparty_list(p_filter = {}, p_cursor, p_limit = 50)` | `counterparty.read` | filter `q` (name contains, code prefix, exact tax ID), `kind` (`customer` / `supplier` also return `both`), `active` (`"true"` / `"false"` / `"all"`); order name; `next = {name, counterparty_id}` |
| `counterparty_get(p_counterparty_id)` | `counterparty.read` | one row |
| `counterparty_save(p_counterparty, p_idempotency_key)` | `counterparty.write` | keys `counterparty_id, version` (optional lock, `ERP_CONFLICT`), `code` (optional, unique), `kind` (`customer` / `supplier` / `both`), `name`, `tax_id`, `tax_office`, `country` (ISO 2 letters, default GR), `street, city, postal_code, email, phone, payment_terms_days` (0-365), `notes`, `active` (deactivate: `counterparty.archive`), `ext_ref` (own reference, unique; `ext_source` becomes `manual`; a CRM-linked row, `ext_source = crm`, keeps its link: phase IP only). Greek tax ID: spaces / dots / `EL` prefix removed, 9 digits with the AFM check digit (`checksum`); other countries: 2-20 letters / digits. One tax ID per country per tenant (`duplicate`) |
| `doc_type_list()` | any member | the 26 types of 01 C: `doc_type, name, area, fiscal, gapless_default, series_scope (branch / tenant), needs_counterparty, enabled, can_read, can_create` |
| `series_list(p_filter = {}, p_cursor, p_limit = 100)` | `series.read` | filter `branch_id, doc_type, include_inactive`; `next = {doc_type, code, series_id}`. Row: `series_id, branch_id, branch_code, doc_type, code, fiscal_year, next_no, last_no, gapless, numbering, is_default, active, in_use` |
| `series_save(p_series, p_idempotency_key)` | `series.write` (owner) | keys `series_id, branch_id` (required for branch-scope types, empty for organisation-wide OPN / MTR / CBAL), `doc_type, code` (unique per type and year), `fiscal_year`, `next_no` (>= 1), `gapless` (fiscal types: always), `numbering` (`local`; `provider` only for fiscal types), `is_default` (taking it moves the default from the other series of the same type / branch / year), `active`. After the first number (`in_use`): type, branch, year, next number, gapless, numbering are fixed |
| `series_create_defaults(p_branch_id, p_idempotency_key)` | `series.write` | for every ENABLED non-fiscal type without an active default series: `TYPE-BRANCHCODE` (branch types) or `TYPE` (organisation-wide types). Reply `{created: [series], skipped: [types whose code is taken]}`. Fiscal series are left to the owner + accountant |
