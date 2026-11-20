# 02. Architecture

## Tenancy (standalone core; no CRM table is used)
- `erp.tenants` is the "organization". iSmile is tenant #1, set up like any other tenant. Every `erp` table has
  `tenant_id uuid not null`, first column of every primary key and index.
- `erp.branches` (tenant, code, name, establishment number, address), typed by the tenant owner.
  `erp.members` (tenant, email, auth user id, role, `branch_ids uuid[]`, active, invited_by): the owner invites by
  email; the row binds to the Supabase Auth user at first login. v1: one email = one tenant (unique), policies are
  written with arrays so multi-tenant users (accountants) can be allowed later without rewriting them.
- No sync with CRM `staff` / `clinics` in the core. Deployment modes (06 section 6): standalone ERP (default) or
  SUITE (`tenant_settings.integration_enabled = true`). Hooks in the core, never foreign keys: `counterparties`
  (`ext_source`, `ext_ref`, `ext_synced_at`; unique per tenant when set) and plain-text `ext_ref` on CONS / REQ.
  Only E900 (Integration Pack) may fill them from the CRM; health data never enters any `erp` table.
- Plan hooks only (no billing design): `tenants.plan text`, `tenants.limits jsonb` (users, branches, documents per
  month), `tenant_usage` counters, one function `erp.check_limit(kind)` called by the write RPCs; unlimited for now.
- **The CRM is off limits** (06 section 1): no ERP file reads, alters or references `public.*` / `app.*`.

## Schemas
- `erp`: tables and internal functions; not exposed to PostgREST. `erp_api`: the RPCs the page calls
  (`supabase.schema('erp_api').rpc`). One-time live step: add `erp_api` to the exposed schemas.
- Why not `public` with a prefix: `rls.sql` revokes every grant in `public` on each re-run and 120 rewrites `public`
  policies; a separate schema keeps both suites independent in both directions.

## Branch and warehouse model
- Branch = legal establishment (myDATA establishment number; iSmile: one per clinic).
  A warehouse belongs to exactly one branch; a branch has one or more warehouses (main, surgery room, van).
- One system warehouse `kind = in_transit` per tenant, no branch: stock that left the source and was not yet
  confirmed by the destination. It is never selectable by users and must be zero for a closed transfer.
- Visibility: a member sees the branches in `branch_ids` (owner / accounting: all). A transfer is visible to both
  its source and its destination branch.

## Core tables (conceptual)
- Platform: `tenants`, `branches`, `members`, `role_caps`, `tenant_settings`, `tenant_usage`, `alerts`, `audit_log`, `attachments`.
- Master: `items`, `item_categories`, `units`, `item_units` (factor), `item_barcodes`, `lots`, `vat_classes`,
  `price_lists` + `price_list_items`, `warehouses` (branch, kind normal / in_transit), `counterparties` + `addresses`,
  `expense_categories` (tree, default VAT class).
- Expenses: EXP is a normal document whose lines carry `expense_category_id` instead of an item (no stock move);
  PINV may mix item lines and expense-category lines (freight, services).
- Documents: `doc_types` (code, direction, stock sign, money sign, fiscal yes / no, myDATA type), `series` (tenant,
  branch, doc type, code, `next_no`, active), `documents` (type, series, number, doc_date, branch, warehouse,
  destination warehouse, counterparty, state, totals net / VAT / gross, currency, `ref_document_id`, fiscal fields:
  mark, uid, qr_url, provider id, issued_at; `idempotency_key`), `document_lines` (item, lot, qty, unit, qty_base,
  unit price, discount, VAT class, net, VAT, gross, unit cost,
  `source_line_id`), `document_links` (source, target, kind), `doc_conversions`
  (allowed pairs, 01 C5). `documents.cp_snapshot jsonb` (name, tax ID, tax office, address) is frozen at post /
  submit and is what prints; later changes of the counterparty never alter a posted document.
- Stock: `stock_moves` (document line, warehouse, item, lot, qty_base signed, unit_cost, value, move_date, reverses
  move id), `stock_balances` (warehouse, item, lot: qty, reserved), `item_costs` (tenant, item: qty, average cost),
  `stock_layers` (FIFO cost layers), `stock_move_layers` (which layers an outbound move consumed), `cost_revisions`,
  `valuation_periods`, `recost_queue`, `reservations`, `stocktakes` + `stocktake_lines` (frozen, counted, difference).
- Money: `money_accounts` (cash / bank per branch), `money_docs` (receipt / payment, account, counterparty, method,
  amount, state), `allocations` (money doc -> document, amount).
- Fiscal: `provider_accounts`, `fiscal_outbox`, `fiscal_events` (see 04).

## Rules
- **Ledger**: `stock_moves` (quantities), `stock_move_layers`, `allocations`, `audit_log`, `fiscal_events`,
  `cost_revisions` are append-only (no UPDATE / DELETE grants, trigger raises). A correction is a reversing row
  created by a cancel / credit document. Only the recost function may rewrite the COST columns of a move (below).
- **Effects**: one function `erp.post_document(id)` writes stock moves, balances, costs and open amounts in one
  transaction. Internal documents post on `posted`; fiscal ones reserve stock on `submitted` and post on `issued`.
- **Money and rounding**: amounts `numeric(14,2)`; quantity and unit price `numeric(16,4)`; unit cost
  `numeric(18,6)`. Line net = round(qty x price x (1 - discount), 2); VAT per line rounded half-up; document totals =
  sum of rounded lines (verify against provider validation). EUR only in v1: `currency` column exists with a check
  `= 'EUR'`; no rates table, no revaluation. Foreign-currency supplier invoices are entered in EUR.
- **Time**: `timestamptz` for events; `doc_date date` in the tenant time zone (default Europe/Athens); periods and
  reports use `doc_date`. `lock_date` per tenant: no document may be posted, cancelled or recosted on or before it.
- **Units**: every item has one base unit; `item_units` (item, unit, factor > 0, is_purchase_default,
  is_sales_default). Lines keep the entered qty + unit and `qty_base = round(qty x factor, 4)`; stock, cost and
  reports use ONLY `qty_base`. A factor cannot change once a posted line used it (add a new unit instead).
- **Lots / expiry**: `items.lot_tracked`. Lot-tracked items need a lot on every stock line; inbound creates or
  reuses `lots` (item, lot code, expiry). Outbound proposes FEFO (earliest expiry first); the user may override;
  an expired lot is blocked except on ADJ- (reason expired) and PRET. Balances are per (warehouse, item, lot).
- **Serials**: LATER. Reserved design: a serial is a lot with qty 1 (`lots.is_serial`); no new tables.
- **Reservations**: `reservations` (document line, warehouse, item, lot null, qty). Created by SO approval and by a
  fiscal document in `submitted`; released by delivery / issue / cancel. Available = on hand - reserved; the
  negative-stock check uses available. A reservation never touches cost.

## Valuation (official = WEIGHTED AVERAGE; FIFO kept)
Owner decision (final): weighted average is the official method for iSmile, all categories (`valuation_periods`
seed = `avg`); FIFO stays computed as a comparison report and as an option for other tenants. Design: every move is costed under BOTH methods at posting; one of them is the
OFFICIAL method for the item at that date and feeds document cost, margins and the stock value report; the other is
kept as a comparison figure. This makes reports consistent under either method and a switch cheap.
- **Scope**: cost is per tenant + item (company-wide), per lot for lot-tracked items. Transfers between warehouses
  do not change cost and do not consume layers. (Per-warehouse cost: not in v1.)
- **Official method**: `valuation_periods` (tenant, category null = tenant default, method `avg` | `fifo`,
  valid_from). Effective method of an item at a date = nearest category override up the tree, else the tenant row.
  Override level: item category only (not per item), so the accountant can reason about it.
- **Data**: `item_costs` (tenant, item, lot null: qty, value, avg_cost) = moving average state. `stock_layers`
  (tenant, item, lot null, inbound move id, layer_date, seq, qty_in, qty_left, unit_cost, value_left) = FIFO state,
  one layer per inbound move. `stock_moves` carry `unit_cost_avg`, `unit_cost_fifo`, `value_avg`, `value_fifo`,
  `official` (`avg` | `fifo`), `cost_provisional`. `stock_move_layers` (outbound move, layer, qty, value).
- **Inbound** (GRN, PINV without GRN, OPN, ADJ+, variance +): cost = line cost; new layer; average =
  (value + inbound value) / (qty + inbound qty). ADJ+ without a cost uses the current official cost.
- **Outbound**: average value = round(qty x avg_cost, 2); FIFO consumes layers in (layer_date, seq) order, value =
  sum of consumed layer values. When the item quantity reaches zero, the remaining cents go to that move so that
  quantity 0 always means value 0 (both methods).
- **Returns**: a customer return (CRN / RCR with goods) comes back at the cost of the original outbound line when
  linked, else at the current official cost. A supplier return (PRET) leaves at the cost of the original receipt:
  FIFO takes that layer if it still has quantity, else normal FIFO; the difference is a value-only move.
- **Supplier invoice vs receipt price**: GRN posts at PO price with `cost_provisional`. PINV sets the final price:
  the layer is corrected for `qty_left`, and the part already consumed is posted as a value-only "price variance"
  move (qty 0), so past outbound costs do not change after their period is locked.
- **Negative stock (owner decision: allowed, with warning)**: tenant setting `negative_stock` = `warn` (default)
  or `block` (kept as an option for other tenants). Always blocked (`ERP_STOCK_NEGATIVE`): the transit warehouse and
  a specific lot of a lot-tracked item (question 3 in 05). Under `warn`:
  1. `erp_api.doc_check(doc)` (called before post) and `post_document` return `warnings[]` with
     `{code: 'W_STOCK_NEGATIVE', item, warehouse, qty_after}`; the page lists them in a confirm dialog and posts only
     with `p_ack_warnings = true` (without it nothing is posted). The acknowledgement is audited.
  2. Posting upserts ONE open `alerts` row `negative_stock` per (warehouse, item) for the branch's warehouse /
     manager / owner members (in-app; email digest SHOULD); it closes itself when the balance is >= 0.
  3. On-hand lists and the stock card show the quantity in red with a "negative" badge.
  4. Report `rpt_erp_negative_stock`: warehouse, item, qty, negative since (days), causing document and member,
     provisional value.
  Cost: the uncovered quantity is costed at the last official cost, flagged `cost_provisional`; the next inbound
  first covers the deficit and posts a value-only correction.
- **Backdated documents**: allowed only after `lock_date`. Posting one inserts (item, lot, from_date) in
  `recost_queue`; `erp.recost_item` (same transaction for <= 2,000 later moves, else the 5-minute job) replays that
  item's moves in (move_date, seq) order, rebuilds layers and average, and rewrites ONLY the cost columns of later
  moves and the cost on their document lines; every change is one `cost_revisions` row (run id, move, old, new).
  Quantities, prices and fiscal data never change. Reports show "recost pending" while the queue is not empty.
- **Switching method (cut-over rule)**: only by the owner, only with `valid_from` = first day of a month (default:
  fiscal year start), and only when `lock_date` = the day before and the recost queue is empty. The wizard shows the
  closing value under both methods, then REBASES: the official closing value becomes the opening state of both
  methods (to FIFO: one layer per item / lot at the closing average cost, old layers closed with the cut-over id;
  to average: avg_cost = FIFO value / qty). No earlier move is recalculated. The switch is audited and printed for
  the accountant. Whether and how often a method may change is tax law: **accountant confirms**.
- **Integrity job** (nightly): per item, balances = sum of moves; `item_costs.qty` = sum of `qty_left` = on hand;
  value under each method = sum of its move values. Any difference raises an owner alert.

## Document state machines
All: a `draft` is freely editable and deletable and has NO number. Any other state is never edited (trigger
whitelist: notes, attachments, due date). `cancelled` keeps the number and writes reversing moves / allocations.
| Types | States and transitions |
|---|---|
| PO, SQ, SO | draft -> approved -> partly_fulfilled -> closed; approved -> cancelled (only the unfulfilled part) |
| GRN, PINV, PCRN, OPN, ADJ, CONS, MTR, CBAL | draft -> (pending_approval ->) posted -> cancelled |
| TRF internal | draft -> dispatched -> received (-> received_with_difference -> closed after ADJ approval); dispatched -> cancelled (stock returns from transit) |
| STK | draft -> counting (freeze on) -> pending_approval -> posted; counting -> aborted (freeze off, nothing posted) |
| RCPT, PAY | draft -> (pending_approval ->) posted -> voided (reason; allocations reversed) |
| Fiscal: DN, SINV, SVC, CRN, RR, RS, RCR, PRET, TRF between establishments | draft -> submitted (number taken, stock reserved) -> issued (posted) or failed (edit data, resubmit with the same number); issued -> cancelled only by provider cancellation, else by a credit note; fiscal TRF continues issued -> received |
Each type's allowed transitions and roles live in ONE table `erp.doc_transitions` (type, from, to, min role, needs
approval rule) read by `erp.doc_set_state`; no transition is coded anywhere else. REQ: draft -> approved ->
partly_fulfilled -> closed (as PO).

## Document conversion (convert / copy to; matrix in 01 C5)
- **One RPC**: `erp_api.doc_convert(p_source_ids uuid[], p_target_type, p_lines jsonb, p_idempotency_key)` returns
  a DRAFT target. `p_lines` null = everything that remains; else `[{source_line_id, qty}]`. Allowed pairs, kind
  (`fulfil`, `bill`, `credit`, `return`, `request`), N:1 flag and stock rule are DATA in `erp.doc_conversions`; the
  buttons are read from it. `erp_api.doc_copy(p_id)` makes an unlinked draft of the same type.
- **Trace**: each target line keeps `source_line_id` (one source line; many target lines may point to it);
  `document_links` holds one row per (source document, target document, kind). The drawer shows "Created from" and
  "Converted to" with numbers and states; a chain view walks the links (SQ -> SO -> DN -> SINV -> CRN).
- **Remaining quantity** per source line and kind = source `qty_base` - sum of `qty_base` of its target lines whose
  document is NOT cancelled / deleted / failed-and-discarded. Drafts count, so a second conversion of the same
  quantity is refused (`ERP_CONVERT_NOTHING_LEFT`, `ERP_CONVERT_EXCEEDS`). Never stored: view `erp.v_line_remaining`.
  Deleting a draft target, cancelling it or a provider cancellation gives the quantity back automatically.
- **Source status** (derived, shown as a badge, filterable): `open` (nothing converted), `partial`, `full`; kept per
  kind (an SO can be fully delivered and partly billed). PO / SO / REQ also move to `partly_fulfilled` / `closed`.
  A DN marked "not to be billed" is `full` by definition.
- **Stock is moved once**: `post_document` skips the stock move of a target line when the pair's rule is
  `stock_by_source` (DN -> SINV / RR, GRN -> PINV); such a line posts only AR / AP / cash, and for PINV the cost
  correction. Lines with no source post stock as the type says. Reservations of an SO are released by the DN.
- **Editable in the target draft**: quantity down (never above remaining), remove lines, add free lines, dates,
  notes, payment data; price / discount / VAT class are copied and may be changed only with `convert.price_edit`
  (audited). Locked: item, unit, lot, source link, counterparty (N:1 needs the same counterparty). The source is
  posted and is never edited by a conversion.
- **Who**: `can('<target>.create')` on the target branch + read on the source; conversions that skip a step
  (SO -> SINV, PO -> PINV) can be switched off per tenant in `doc_conversions`.
- **Totals**: copied lines keep the source's rounded net / VAT / gross when qty and price are unchanged, so a full
  conversion has totals equal to the source to the cent; a partial line is recomputed with the standard formula.
- **Void / credit on a chain**: cancel from the end. A source with a live target cannot be cancelled
  (`ERP_DOC_HAS_CHILDREN`). A CRN / RCR / PCRN does NOT reopen the source quantity, except a full credit flagged
  "re-bill", which returns it. Goods come back only by a credit with "goods returned" or a PRET.
- **Locking**: `doc_convert` locks the source documents (`for update`, id order) before computing remaining.

## Numbering and series
- `series` (tenant, branch null = tenant-wide, doc type, code, `fiscal_year` null, `next_no`, `gapless`,
  `numbering` local | provider, active). One default series per (branch, doc type); more are allowed (e.g. a second
  delivery-note series for a van).
- The number is taken at post / submit, never at draft: `erp.next_number(series_id)` does
  `update erp.series set next_no = next_no + 1 ... returning` inside the posting transaction, so a rollback returns
  the number (gapless). Unique (tenant, series, number). `gapless = true` for every fiscal type and for TRF, PRET;
  the others also use the same function (cheap), but their register report does not flag gaps from deleted drafts
  because drafts have no number.
- A failed fiscal document keeps its number and is retried with it; it ends as issued or as a recorded cancelled
  number. Provider-assigned numbering is an adapter capability (04): then `number` is filled from the reply.
- Yearly reset is optional per series (`fiscal_year` set): a new row per year, created by the owner or on first use.
- Which series must be gapless, and yearly reset: **accountant confirms**.

## Permissions matrix
Roles: `owner`, `manager`, `warehouse`, `accounting`, `clinic_user`, `readonly`. All non-owner roles are limited to
their `branch_ids` (accounting may be given all branches). c = create / post, a = approve / cancel, r = read.
| Area | owner | manager | warehouse | accounting | clinic_user | readonly |
|---|---|---|---|---|---|---|
| Tenant settings, members, series, valuation, lock date | c a | r | - | r | - | - |
| Items, categories, units, warehouses | c a | c a | c | r | r (name, unit, on hand) | r |
| Counterparties, VAT classes, price lists | c a | c a | r | c | - | r |
| PO, GRN, PRET | c a | c a | c | r | - | r |
| PINV, PCRN | c a | c a | r | c | - | r |
| SQ, SO, DN | c a | c a | c (DN) | c | - | r |
| SINV, SVC, CRN, RR, RS, RCR | c a | c a | - | c | c (RR only) | r |
| TRF, ADJ, STK | c a | c a | c (approve: no) | r | - | r |
| CONS | c a | c a | c | r | c (own branch) | r |
| RCPT, PAY, MTR, journals, statements, aging | c a | c a | - | c | - | r (no money if the tenant hides it) |
| Cost and stock value | r | r | r (qty only by default) | r | - | r |
| Fiscal credentials, provider settings | c | - | - | - | - | - |
| Audit log | r | r (own branches) | - | r | - | - |
The matrix is DATA (`erp.role_caps`: role, capability), checked by `erp.can(capability, branch_id)` in every RPC, so
a tenant-specific change is a row, not code. Cost columns are returned only when `can('cost.read')`.

## Audit
`erp.audit_log` (tenant, at, member, action, table, row id, old / new jsonb diff, request id, ip from headers when
present): written by the RPC layer for every write and every state change, append-only, readable per the matrix.
Retention: kept for the
life of the tenant (legal minimum: accountant).

## RLS (fast form from the start, as in 120)
Helpers `erp.my_tenants()`, `erp.my_branches()`, `erp.is_owner()`: stable, security definer, always called as
`(select ...)` so they run once per query. Policy shape:
`tenant_id = any ((select erp.my_tenants())) and ((select erp.is_owner()) or branch_id = any ((select erp.my_branches())))`.
Tenant-wide tables (items, counterparties) use the tenant clause only. `authenticated` gets SELECT through policies
and NO insert / update / delete: every write goes through an `erp_api` RPC (security definer, checks role, tenant,
branch, plan limit, then writes audit). Secrets tables: no grants at all.

## RPC naming
`erp_api.<noun>_<verb>`: `item_save`, `item_list`, `doc_save_draft`, `doc_post`, `doc_submit`, `doc_cancel`,
`stock_on_hand`, `stocktake_start`, `money_doc_post`, `report_vat_summary`. Lists take a keyset cursor + limit and
return `{rows, next}`. Writes take `p_idempotency_key uuid` and return the full row.

## Performance and concurrency
- Targets and data volumes: 03. Indexes always start with `tenant_id`. `stock_moves` (tenant, item, warehouse,
  move_date); `documents` (tenant, branch, type, doc_date desc, id); trigram on item name / code per tenant.
- `stock_balances`, `item_costs` and `stock_layers` are maintained inside `post_document` (not by summing the ledger per request). A
  nightly check proves balance = sum of moves and alerts on any difference. This changes ERP_AI_PLAN ("stock = sum
  only") because of multi-tenant volume.
- Partitioning: not in v1. Keys already contain `tenant_id` and a date, so `stock_moves` / `audit_log` can later be
  range-partitioned by month without changing the API. Trigger to do it: > 20 M moves or slow vacuum.
- Locks, always in this order to avoid deadlocks: series row (via `next_number`), then
  `pg_advisory_xact_lock(hashtextextended('erp.item:' || tenant || ':' || item, 0))` for each item of the document
  in ascending item id, then balance rows. The per-item advisory lock serialises costing, layer consumption and
  recost for that item (also when no balance row exists yet). Reservation and negative-stock checks run under those
  locks. Reports read without locks.
