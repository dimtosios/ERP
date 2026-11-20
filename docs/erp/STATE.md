# ERP build state (branch `erp-dev`; nothing applied to live)

Short implementation log for Fable. The CRM's `ARCHITECT_STATE.md` is not touched by ERP work.

## Done
- T01 skeleton: `erp/` folders, `erp/build_erp.py` -> `erp.html`, `erp/backend/run_erp_tests.sh`, login / set-password /
  "No access" shell, stub client + smoke test.

- T02 E100 tenancy: platform tables, permission matrix as data, helpers, RLS fast form (enabled + forced), RPCs whoami /
  branch_list / branch_save / settings_get / settings_save / audit_list; suites E100 (69 checks) + generated E990.

- T03 E110 members: invite by email, first-login binding by `sub`, conflict alert, list / update (last-owner guard) /
  reset binding, `erp.tenant_onboard` + `seed/tenant1_onboarding.sql`; suite E110 (63 checks); standalone mode B green.

- T04 app core: `api()` (idempotency key, 8 s timeout, error mapping), strings, nav + role guard from `caps`, drawer
  framework (disabled while saving, "Not saved", unsaved-changes guard), admin screen (members, branches,
  settings). Smoke: stub (34 checks) + real local DB through a bridge (9 checks).

- F1 checkpoint (independent review, 2026-11-18): PASS WITH FIXES, see `docs/erp/REVIEW_F1.md` (18 findings: 2 high,
  2 medium, 6 low, 8 info; every code defect fixed with a test). New suite `tests/E991_adversarial_tests.sql` (64 checks)
  and `tests/concurrency_last_owner.sh` (two-session race, runner mode A). C0 run list: REVIEW_F1.md section 4.

- T05 E120 part 1: units, VAT classes, item categories (tree, read-only valuation override), items, barcodes (EAN check
  digit), per-tenant defaults by a trigger on `erp.tenants`; RPCs unit / vat_class / category list + save, item list /
  get / save; suite E120 (54 checks) + E990 registry / fixtures.

- T06 E120 part 2: warehouses (branch-scoped writes) + one system transit warehouse per tenant, counterparties (Greek AFM
  check digit, EL prefix, ext_ref hooks), document-type catalogue (26 types of 01 C), series (default per type / branch
  / year, fixed after the first number, `series_create_defaults`); suite E120 now 103 checks.

- T07 master-data screen (`erp/app/10_master.js`): one "Master data" menu with tabs Items, Categories, Units, VAT
  classes, Warehouses, Customers & suppliers, Series; table-driven lists (keyset "Load more", search) and drawers that
  send only the changed keys (+ id / version); tabs by read capability, New / Save by write capability. Form helpers
  moved to `00_core.js`. Smoke: stub `smoke_erp_master.py` (27 checks) + real DB (`smoke_erp_db.py`, 12 checks).

- T08 CSV import: `item_import`, `counterparty_import` (all or nothing, dry run, every problem with its row number, match
  by code / tax ID, codes resolved for unit / category / VAT); import drawer with a CSV parser in `00_core.js`
  (quotes, `;` `,` TAB, BOM); suite E120 now 118 checks, smoke master 34 checks.

- T09 E130 documents core: `doc_types` posting columns, `doc_transitions` (the only place transitions live), documents +
  lines (immutable once not draft, trigger), `series_for` + `next_number` (series row locked first, number taken last
  inside the posting transaction), generic draft save (totals, rounding, problems vs shape errors, version, client_key),
  get / list / delete, `doc_set_state` (post, approval limit, reject, cancel with reason, lock date). Suite E130 (62
  checks); `tests/concurrency_numbering.sh`: 8 sessions x 15 posts into one series with 24 rollbacks -> 1..96, no gap.
  Table design (03 section 7, for the reviewer): documents (tenant_id, document_id) + FKs (branch, series, warehouses,
  counterparty, ref document), unique (tenant, series, number), unique (tenant, client_key), list index (tenant,
  branch, type, doc_date desc, id desc); document_lines (tenant_id, line_id), unique (tenant, document, line_no),
  FKs (item, unit, VAT, source line), qty / qty_base numeric(16,4), prices (16,4), amounts (14,2), unit_cost (18,6).

- T10 E140 stock engine: ledger `stock_moves` (append-only; only the costing code rewrites cost columns, under
  `erp.recost`), balances, `item_costs` (average + FIFO deficit), FIFO layers + per-run consumption, valuation periods
  (seed average); ONE costing step `erp.cost_move` used by posting and by `erp.cost_replay` (cancel, backdating);
  negative stock warning / ack / block, provisional cost + one value-only correction per covering receipt;
  `erp.stock_integrity`. Golden G1-G5 (28 steps, both methods) + cancel symmetry, replay, backdating, negative cover,
  guards, RLS: suite E140 (37 checks).

- T11 E150: OPN (manager prepares, owner posts; organisation-wide series) and GRN without PO (supplier, supplier DN
  number / date, MARK, discount, last purchase price) with transitions, capabilities and validator; opening-stock import
  (`opening_import`: all or nothing, dry run, row problems, one OPN draft of up to 2000 lines). Suite E150 (27 checks).

- T12: ADJ_IN / ADJ_OUT (reason codes, ADJ+ without cost at the current cost, value limit `thresholds.adj_value` with
  submit / approve / reject), CONS (clinic_user own branch, cost centre, `ext_ref`, `ext_line_ref`; reversal = cancel by
  manager / owner), `doc_check`, negative-stock and low-stock alerts (E140 `erp.stock_alerts`: one open per warehouse
  and item, self-resolving), report `report_negative_stock` + view `rpt_erp_negative_stock`, golden G7. Suite E150 now
  61 checks.

- T13: `cost_revisions` (append-only; every rewrite of an already posted move by a replay), `recost_queue` (backdated
  post with more than 2,000 later moves; `erp.recost_item`, `erp.recost_job`), lock date: never a replay on / before it
  and never moved over a queued recost (`ERP_RECOST_PENDING`), nightly `erp.integrity_job` (critical owner alert while
  the books disagree), RPCs `recost_status` / `recost_run`; golden G8 + G3 replay determinism. Suite E140 now 58 checks.
  **Live steps for the reviewer's run list (pg_cron, as postgres)**: `select cron.schedule('erp-recost', '*/5 * * * *',
  'select erp.recost_job()');` and `select cron.schedule('erp-integrity', '17 2 * * *', 'select erp.integrity_job()');`.

- T44 (E2, conversion core) E135: `doc_conversions` with the 01 C5 matrix as data, `document_links`, remaining per
  source line and kind (view, drafts count), source status view, `doc_convert` (sources locked in id order, partial,
  N:1, idempotent), `doc_copy`, `doc_conversions_for`; target-draft checks inside `doc_validate`. Suite E135 (31 checks,
  test types) + `tests/concurrency_convert.sh` (two sessions, one target). **Checkpoint FC (05) is due for T44: T45-T47
  must not start before it.** `stock_by_source` in `post_document` is T45 (no real pair is enabled yet).

- T14 stock screens (`erp/app/30_stock.js`): Stock menu with On hand (filters, low / negative badges, values with
  cost.read) + stock card drawer, Documents (OPN / GRN / ADJ+ / ADJ- / CONS list; one generic drawer with header fields
  per type, lines by item code / barcode, server totals and problems, buttons from `actions`, negative-stock warning
  dialog with "Post anyway", cancel / reject with a reason, delete, copy; opening-stock import), Negative stock report,
  Alerts (resolve). Read RPCs `stock_on_hand`, `stock_card`, `item_lookup`, `item_availability` (E140) and `alert_list`
  / `alert_resolve` (E100). Smoke: stub `smoke_erp_stock.py` (34 checks, phone width for consumption) + real DB
  (`smoke_erp_db.py` 15 checks: GRN by barcode posted, CONS past zero with ack, alert in the DB).

- T15 load (`erp/backend/tests/load/`): deterministic generator `gen_erp_load.sql` + `run_erp_load.sh` (scratch DB
  `erp_load*`; 20 tenants; standard tenant 5,000 items, 10 warehouses, 20,010 documents, 105,124 moves, all through
  the real posting path), `measure_erp.py` + `measure_erp.sql` (server-side p50 / p95 as the warehouse member under
  RLS), pgbench (50 clients, 2 min, CONS / GRN on 5 hot items, 1 in 10 rolled back). **RESULTS.md**: every 03 target
  met (worst p95: search 39 ms, lists 11 ms, open 20 lines 8 ms, post 20 lines 39 ms, stock card 14 ms; recost
  2,000 later moves 0.8-1.4 s); pgbench 0 deadlocks, 0 failed, every series gapless, integrity clean; CRM board timings
  re-measured with the ERP loaded (same plans, within noise). Made in T15: E140 replay carries the cost state and
  the head FIFO layer in transaction settings (the first run was 2.3-2.9 s: quadratic row-version chains), E140 test
  "replay G2 / G4 / G5 identical"; E130 lock-order note (usage row last, one document per transaction).

- F2 checkpoint (independent review, 2026-11-19): PASS WITH FIXES, see `docs/erp/REVIEW_F2.md` (7 defects: 4 medium, 3 low,
  all fixed with tests that fail on the old code; 8 info). Golden G1-G5 / G7 / G8 re-computed independently: 41 values,
  0 mismatches. New: `tests/costing_model.py` (independent costing model: golden re-compute + differential fuzz in the
  runner), `tests/E142_f2_review_tests.sql` + golden `R1..R4.csv`, `golden/conv_cases.csv` (V1-V9 spec),
  `tests/concurrency_lockdate.sh`, `tests/concurrency_recost.sh`. O2 fixed (`stock_moves.fallback_cost`). Pilot: GO
  after G1 and C0; C1 run list: REVIEW_F2.md section 6.

- T16 E160 TRF internal: draft -> dispatched (gapless number of the SOURCE branch, source -> the tenant's transit
  warehouse, negative-stock warning / ack / block of the source) -> received, or -> received_with_difference (generated
  ADJ_OUT out of transit for a shortage / ADJ_IN into the destination for an excess, DRAFTS through the normal ADJ path:
  value limit, submit / approve / reject) -> closed automatically when they are posted; dispatched -> cancelled (source
  approver, stock back from transit). Cost rule `transfer` in E140 `cost_move` (cost-neutral: item state and FIFO layers
  unchanged; receipt moves copy the dispatch cost: no drift through transit); `erp.stock_cost_new` (cost-now / replay /
  queue decision shared by posting and the receipt). Generic E130 hooks: `doc_types.dest_visible` (destination branch
  reads a non-draft TRF: doc_get / doc_list / RLS), `doc_transitions.side` (receipt / close checked on the destination
  branch), actions `receive` / `close` -> `doc_types.action_fn`, `erp.doc_ref_changed` (the TRF reacts to its
  adjustments), state `received_with_difference`. Receipt tables `doc_trf` / `doc_trf_lines` (append-only), guards
  (generated ADJ not deleted / changed / cancelled; warehouses of open transfers), `erp.trf_integrity` (in the nightly
  job: transit_negative / transit_open / transit_value), RPC `trf_get`, `trf_fiscal_needed` (T36 hook). Suite E160
  (94 checks) + golden G10 (12 steps, also re-computed by `costing_model.py`), `tests/concurrency_transfer.sh`
  (receive vs cancel both orders; two dispatches draining one stock under block / warn; gapless), `tests/
  mutation_transfer.sh` (5 broken copies, all killed; runner mode A). E990 registry + B fixtures (doc_trf, doc_trf_lines).

- T18-lite transfer screen (`erp/app/35_transfers.js`; stocktake NOT included): "Transfers" menu (`doc.trf.read`),
  list (`doc_list` TRF, keyset, filters state / branch, badges per state), the transfer drawer = the stock document
  drawer (DOC_FORM.TRF: source, destination of any branch, delivery carrier / vehicle, lines by code / barcode, no
  price; Dispatch with the negative-stock dialog "Dispatch anyway" -> `ack_warnings`; Cancel with a reason), transfer
  section from `trf_get` (fiscal note, per-line sent / received / difference / reason / in transit, generated
  adjustments with state, "closed after the adjustment is posted"), receipt form BY LINE (phone width; to_state from
  the quantities; a difference needs a reason). Generated ADJ open in the stock drawer: TRANSIT warehouse read-only,
  lines fixed, no delete / copy. Cancel warnings shown (F2-12). New read RPC `trf_warehouses` (E160; E160 suite +3
  checks = 97, E990 registry case). Strings for every TRF state / action label + `ERP_APPEND_ONLY`. Smoke: stub
  `smoke_erp_transfers.py` (32 checks) + real DB (`smoke_erp_db.py` 22 checks: dispatch past zero, short receipt,
  ADJ_OUT posted, transfer closed, transit 0, integrity clean); owner nav checks of the other smokes now include Transfers.

- Expenses lite (T19 + T20 reduced; `E180_expenses.sql`, `erp/app/40_expenses.js`): expense categories (tenant tree,
  default VAT class, active flag, 10 defaults per tenant by trigger; RPCs `expense_category_list` / `_save`), EXP on the
  generic core (lines carry `document_lines.expense_category_id`, new generic column of E130 accepted by
  `doc_save_draft` / returned by `doc_line_json` / copied by `doc_copy`; net / VAT / gross per line by the core rule;
  supplier optional; supplier's number / date, MARK, cost centre, paid on the spot + method stored only), approval limit
  `thresholds.exp_value` (submit / approve / reject), number per branch at post, cancel with a reason (01: A M O),
  lock date, `erp.doc_exp_validate`; report `report_expenses` (by category / supplier, dates, branch, category subtree,
  supplier) + view `rpt_erp_expenses`. Screen "Expenses": List (keyset, state / branch / text filters, paid badge),
  drawer = the shared document drawer (DOC_FORM.EXP), Categories admin (`expense.category.write`), Report (totals, CSV
  download); Admin > Settings: expense approval limit. NOT built (lite): attachments, recurring templates, AP / PAY stub
  and allocation to payments (T29), myDATA expense classification. Suite E180 (88 checks), E990 registry (3 RPCs + B
  category ids), E150 series-defaults expectation (+EXP-A1), stub smoke `smoke_erp_expenses.py` (34), real-DB
  `smoke_erp_db.py` +6 (28: EXP posted EXP-SER/000001 with the category's VAT, report, cancel with reason, new
  category), owner / warehouse nav of the other smokes now include Expenses.

- Demo (`erp/demo/`): `demo.html` = ONE self-contained file (erp.html + `seed_demo.json` + `demo_runtime.js` + the UI
  smokes' stub client, no supabase-js, no key, CSP `connect-src 'none'`, no browser storage; reload = reset) for the
  owner to click through on a phone: tenant "iSmile (demo)", 3 clinics + TRANSIT, 31 orthodontic items, 4 suppliers,
  opening stock, GRN / CONS, a transfer waiting for receipt, one received short with its ADJ waiting, low / negative
  alerts, 6 expenses; banner with a role switcher (owner, manager SER, warehouse THE, clinic_user ALE, accounting SER).
  `build_demo.py` (validates AFM / EAN, `--check`), `README.md` (10-step script). The stub got a demo hook (in-memory
  store, seed hook, `HOME` branch instead of the literal b1; unchanged for the smokes); the runtime adds a ledger at
  average cost, series numbering, alerts and item-import checks. Smoke `smoke_erp_demo.py` (33 checks; fails when
  demo.html is stale). App fix found by the demo: per-login caches (warehouses, suppliers, categories, branches) were
  kept across sign-out / sign-in in one tab; now dropped at every sign-in (`onLogin` in 00_core.js).

- Draft 1, supplier delivery note -> DRAFT goods receipt (`E190_attachments.sql`, `erp/app/37_delivery_note.js`): platform
  table `attachments` (STATE 13 closed: bytes in the row, 5 MB, PDF / JPEG / PNG by magic bytes, sha256, append-only +
  one soft delete, RLS by branch + `doc.grn.read`), RPCs `attachment_add` / `_list` / `_get` / `_delete`; documented
  extraction contract `delivery_note_extraction/1`; `grn_draft_from_extraction` (supplier by normalised tax ID, line ->
  item by barcode, then item code, then exact name; unmatched / low-confidence lines kept and flagged in line
  `extra.dn`, blocking the post through `erp.grn_dn_validate` (hook in E150 `doc_stock_validate`); idempotent by
  client_key; file linked; NEVER posts). GRN catalogue row: `header_extra {mark,dn}`, `line_extra {dn}` (seed 3).
  Screen: Stock > Documents > GRN drawer "Delivery note" box (file picker, name / size, Upload, Create draft from note
  via the pluggable `window.ERP_EXTRACTOR`, default deterministic MOCK labelled "MOCK extractor - sample data"; files
  list with Open (link + photo preview) / Delete; flagged lines highlighted with the note's text, "Mark checked").
  App fixes: the drawer keeps header / line `extra.dn` on save; the document's own supplier is always an option of the
  supplier list (a cached list older than the document cleared it on save, found by the real-DB smoke). Suite E190
  (89 checks), E990 registry (+5 RPCs, A / B attachment fixtures), stub smoke `smoke_erp_delivery_note.py` (28),
  real-DB `smoke_erp_db.py` +6 (34: file bytes / sha256 in the DB, draft by tax ID / barcode, post refused, fixed,
  posted GRN-SER/000002, file served back). `demo.html` rebuilt by `build_demo.py` only (demo sources unchanged; the
  demo update is a later task). Not live.

- Draft 2, sales lite NON-FISCAL (`E210_sales.sql`, `erp/app/50_sales.js`): DN delivery note (customer, delivery block
  `extra.delivery {address, carrier, vehicle, reason}`, `extra.to_be_billed`, lines with sale price and VAT per line by the
  core arithmetic, STOCK OUT at the official cost through E140 (cost rule `issue`, negative-stock warning / ack / block
  unchanged)), RR retail receipt goods (`extra.payment_method` cash / card / bank / other; stock out only for lines
  without a DN reference: a line billing a DN line carries `extra.dn_line_id` + header `ref_document_id` = the DN, plain
  link, NO conversion machinery), RS services receipt (same code path, no stock). Gapless series per branch (DN-/RR-/RS-
  <branch> from "Create missing"; a non-gapless series is a problem), states draft -> posted -> cancelled (cancel M O with
  a reason; DN W A M O, RR A C M O, RS A M O create), `doc_types.fiscal = false` in v1 + `erp.sales_fiscal_needed` (true)
  reported by the new RPC `sales_get` (document + issuer, branch, customer, VAT breakdown, DN billing state, RR / RS
  collection, watermark "NOT A FISCAL DOCUMENT"). RCPT hook `erp.sales_collection`. Generic changes: E140 `stock_effect` /
  `stock_post` skip lines with `extra.dn_line_id`; E100 `tenant_settings.issuer` (settings_save / settings_json, Admin >
  Settings "Issuer" fields). Screen "Sales" (tabs Delivery notes, Retail receipts; keyset list, state / branch / text
  filters, drawer = the shared DOC_FORM drawer with sale lines, quick-add customer, "Add the remaining lines of this
  delivery note", "Print / PDF" = in-page print view + print CSS, browser Save as PDF). Suite E210 (71 checks), E990
  registry (+1 RPC, A / B DN fixtures), E120 / E130 suites now use SINV as the "fiscal, not enabled" example, E150
  series-defaults expectation (+DN-A1, RR-A1, RS-A1), stub smoke `smoke_erp_sales.py` (39), real-DB `smoke_erp_db.py` +6
  (40), nav expectations of the other smokes (+Sales). `demo.html` rebuilt by `build_demo.py` only (stale otherwise; demo
  sources unchanged: the demo shows the Sales menu without sales data). No golden case: no costing rule changed
  (`costing_model.py` untouched). Not live.

## Next
- Draft 2 (sales lite) done on `main`, NOT live and NOT for real sales: DN / RR / RS are fiscal documents (myDATA) and v1
  issues them as internal documents (111). Next task: receipt of collection RCPT linked to RR / RS (and later SINV): reuse
  `erp.sales_collection` (method / amount / branch / customer of a posted RR / RS), the payment-method values of
  `extra.payment_method` (cash / card / bank / other, the same as EXP), the `collection.rcpt` slot of `sales_get` (null
  today), the cancel symmetry (an RR cancel must void its RCPT), the E990 registry pattern; the post hook does not exist
  yet: add it generically in E130 (a `doc_types` after-post / after-cancel function name, like `action_fn`), not in E210.
- Expenses lite done on `main` (not live; clinics try it on a scratch / test project; accountant answers 92-93 before
  real use). Live note: existing branches need Master data > Series "Create missing" once for `EXP-<branch>`.
- T18-lite done on `main` of the ERP repo (not live; clinics try it on a scratch / test project only). Next: T17 (E170 STK) + the stocktake half of T18, then checkpoint **F3** (05: transit always zero for closed transfers, stocktake freeze, approvals). TRF on live
  only after F3 AND the accountant's answer on assumption 82 (fiscal movement document between clinics).
- (unchanged) Live: C0 (REVIEW_F1 section 4, after the owner confirms the Auth settings), then G1, then C1
  (REVIEW_F2 section 6) and the C2 pilot (GRN / CONS / ADJ in one clinic). Checkpoint FC (T44) before T45-T47.
- (history) F2 done (REVIEW_F2.md); T16 (E3) was released to start on `erp-dev` after F2.
- (history) **STOP at checkpoint F2** (05: after T15; reviewer: numbering, `post_document`, golden cases, negative-stock warning
  path, recost, load numbers). Nothing after T15 is started. After F2: G1 and pilot C1-C2; checkpoint FC (T44) before
  T45-T47. Live C0 only after the owner confirms the Auth settings of REVIEW_F1.md section 4 step 0.

## F2 review pack (what to read)
- Diff `c63e0b3..erp-dev` (after the F1 fix) restricted to `erp/` (T05-T15, T44); runner `bash erp/backend/run_erp_tests.sh --all`.
- Numbering: E130 `series_for` / `next_number` / `post_document` (lock order comment), `tests/concurrency_numbering.sh`,
  pgbench section of `tests/load/RESULTS.md`.
- Stock engine: E140 sections 3-5 (`cost_move`, `layer_take`, replay state, `cost_replay`, `stock_post`, queue, jobs);
  golden `tests/golden/*.csv` (**values computed by hand by the implementer; re-compute them independently**, README
  there); E140 / E150 suites; negative-stock path: `stock_check`, `W_STOCK_NEGATIVE` + `ack_warnings`, UI dialog
  (`smoke_erp_stock.py`, `smoke_erp_db.py`).
- Load: `tests/load/RESULTS.md` (deviations listed there: no stress tenant, aging / VAT / stock value n/a).
- Open items for F2 below (O1-O6).

## Open items (after F2; decisions in REVIEW_F2.md section 4)
- O1 Stress tenant (10x) still not measured: NOT a pilot blocker. Required before F9 / T43 (second tenant) or when a
  tenant passes half of the standard scale; plus the C1 on-tier re-measure (O6).
- O2 CLOSED at F2 (F2-01): provisional cost of an item without cost history = `stock_moves.fallback_cost` (last purchase
  price when posted), both methods; replays deterministic. Accountant to confirm the rule.
- O3 CLOSED at F2: independent re-computation (0 mismatches), golden R1-R4, conversion spec `golden/conv_cases.csv`
  (V1 stock part, V6, V7, V9 pending T45 / T46).
- O4 Live steps not done (no live access by rule): pg_cron `erp-recost` / `erp-integrity` (T13 entry), C0 run list.
- O5 Checkpoint FC is due for T44 before T45.
- O6 Load timings are server-side on a 2-CPU sandbox (no PostgREST / network); re-measure on the Supabase tier at C1.

## F1 review pack (what to read)
- Diff `main...erp-dev`: only `erp/`, `erp.html`, `docs/erp/STATE.md` (runner check: no CRM file changed).
- `erp/backend/E100_tenancy.sql` sections 4 (helpers), 9 (RLS + table grants), 11 (`erp.lock_down`), the RPCs;
  `E110_members.sql` (`member_bind`, last-owner guard, `tenant_onboard`).
- Tests: `bash erp/backend/run_erp_tests.sh --all` (empty DB + CRM DB, suites twice, CRM suites before / after /
  after `drop schema erp cascade`, smoke). Generated suite `tests/E990_generated_isolation_tests.sql`.
- Assumptions below, especially 4, 8, 9, 14 (live facts to confirm).
- Facts for the C0 run list (final list: REVIEW_F1.md section 4): run `E100_tenancy.sql`, `E110_members.sql` in the SQL editor
  (as `postgres`); `select erp.tenant_onboard('ismile', 'iSmile', '<owner email>', <owner login id or null>)`; dashboard: add `erp_api` to
  the exposed schemas; add `<site>/erp.html` to the Auth redirect URLs (password links); keep sign-ups OFF;
  publish `erp.html` with the next site deploy (merge to main = Netlify deploy). Rollback: `drop schema erp_api
  cascade; drop schema erp cascade;` (tested locally: CRM suites stay green).

## Assumptions (taken where the docs were open; reviewed at F1: status in [brackets])
1. Layout: `shell.html`, `erp.css`, `strings.en.js` live in `erp/app/` (03 section 1 lists them on the `erp/app/` line).
   `build_erp.py` inlines css, then `strings.en.js`, then the other `erp/app/*.js` in name order, inside one IIFE.
2. No font CDN on the ERP page (03 section 4: "no CDN beyond supabase-js"); system fonts. supabase-js is the same
   pinned version the CRM uses (2.45.4), so no new dependency.
3. Same Supabase project and publishable key as the CRM (05 question 1, default); same Auth login storage, so signing
   out of one page signs out of the other on the same site.
4. Identity comes from `request.jwt.claims` (`sub`, `email`) read by `erp.jwt_*`, not from `auth.uid()`, so no E file
   names the `auth` schema and the core installs on an empty database. Access needs a member row BOUND to `sub`;
   the email alone never grants access.
5. The policy form of 02 needs an explicit cast in PostgreSQL: `tenant_id = any ((select erp.my_tenants())::uuid[])`
   (still one call per query). `erp.is_owner()` = owner in EVERY tenant of the caller: identical in v1, never wider
   once multi-tenant members exist.
6. Roles, capabilities and the default matrix are platform catalogs (no `tenant_id`, comment `platform catalog:`);
   the tenant matrix is `erp.role_caps` (tenant_id first), copied from the defaults; `allowed = false` survives
   re-runs. A facade-only role is a flag on `erp.roles` (none seeded, 07 section 5).
7. Documented index exceptions (cannot start with `tenant_id`): `tenants (code)`, `members (email)` (v1 one email =
   one tenant), `members (auth_user_id)` (identity lookup). [CHANGED at F1 (F1-01): `members_auth_uq` is UNIQUE, v1 one
   login = one member row; `member_bind` answers `login_in_other_organisation`. Multi-tenant members (E10) need a
   tenant context in `can()` / RLS first.]
8. E files must run as a role with BYPASSRLS (Supabase `postgres` has it; E100 refuses otherwise): forced RLS would
   otherwise apply to the security-definer helpers. [OPEN, live check at C0 step 0: `rolbypassrls` of `postgres`; E100
   refuses to run without it, so the failure mode is safe.]
9. `statement_timeout = 8s` is set on every `erp_api` function (PostgREST 12+ applies function settings);
   **verify on live**. Locally the SET clause is checked by the generated suite. [OPEN, F1-14: a function SET clause
   does not time out a direct SQL call; on live it relies on PostgREST >= 12 and the `authenticated` role default
   (Supabase: 8s). C0 step 0 reads both.]
10. New codes `ERP_CONFLICT` (settings version) and `ERP_APPEND_ONLY` (audit log); client-only `ERP_TIMEOUT`,
    `ERP_NETWORK`, `ERP_RPC_MISSING`. Listed in `erp/backend/API.md`.
11. Alerts / audit rows without a branch are visible to owner and all-branches members only; a manager reads audit
    rows of its own branches (02 matrix "own branches").
12. Plan hook signature is `erp.check_limit(tenant, kind)` (02 wrote `check_limit(kind)`); `users` / `branches`
    count live rows, other kinds read `tenant_usage` of the current month. Unlimited unless `tenants.limits` sets it.
13. `attachments` (02 platform list) is not created yet: no E0 task uses it; it comes with the first task that
    stores a file (T19 expense attachment). [CLOSED Draft 1: created by E190 for GRN delivery notes, see 101-110]
14. Invitation email: the ERP stores the invitation; the Supabase login is created by the owner in the Supabase
    dashboard (Invite user), as for the CRM today, or by "Forgot password" for an email that already has a login.
    No Edge Function / service key in E0. Requires "Allow new users to sign up" OFF (CRM setup step 2), otherwise
    anybody could sign up with an invited email; binding trusts the verified email of the login. [CHANGED at F1
    (F1-04, F1-09): also required: "Confirm email" ON, "Secure email change" ON, anonymous sign-ins OFF (else an
    existing login of the shared project could take an invited email); anonymous logins are refused in code; the
    owner is pre-bound at C0 with `tenant_onboard(..., owner login id)`. Owner confirms the settings on live.]
15. An invitation already bound to another login is never re-bound automatically (owner resets it; alert raised).
    The owner cannot unlink its own login; the tenant must keep one active, bound owner (`last_owner`). [CHANGED at F1
    (F1-02, F1-03): member administration is serialised per tenant (advisory lock) and the owner role / an owner's
    row / an owner's login are changed by owners only, also when a tenant gives `member.manage` to another role.]
16. `email_taken` uses the same text for this tenant and another tenant (v1 one email = one tenant), so nothing is
    told about other tenants beyond "cannot be invited". [ACCEPTED for v1 (F1-11): still an existence oracle and lets
    one tenant squat an email; revisit with multi-tenant members (E10 / F9).]
17. Tenant #1 row is seeded by E100 (05 T02); its owner invitation comes from `erp.tenant_onboard` / the seed file
    with the email given at run time (no real email in the repository). Branches are not seeded: typed in the admin
    screen (06 section 1). [CHANGED at F1 (F1-04): optional 4th argument = the owner's existing login id.]
18. A non-owner member needs at least one branch or `all_branches` (otherwise it would see nothing).
19. The admin menu opens for `member.read`, `branch.write` or `tenant.settings.read` (owner, manager, accounting:
    02 matrix row 1 "r"); write buttons follow `member.manage` / `branch.write` / settings `can_write`.
20. The settings form is a page form (not a drawer); the unsaved-changes guard is on drawers (03 section 4).
21. No load test in E0 (03 "Load" applies from the first list / posting path; T15). Lists already use keyset paging.
22. DoD item 6 ("ARCHITECT_STATE.md ERP block") is replaced by this file, as instructed for this run.
Assumptions 1-6, 10-13, 18-22: confirmed at F1 without change. 19: the role guard is UI only; the server checks were
attacked at F1 (E991) and hold.
23. [NEW at F1, F1-06] The `tenant_settings` table policy follows the matrix (`tenant.settings.read`); every member
    still gets the settings subset it needs from `whoami`.
24. [NEW at F1, F1-07] E100 removes only WRITE privileges of `authenticated` on all `erp` tables (all privileges for
    public / anon / service_role), so re-running it keeps later files' SELECT grants. Later files grant SELECT on
    their own tables after `erp.lock_down()`.
25. [NEW T05] Master capabilities (02 matrix, "c" = write, "a" = deactivate): `item.read` all roles; `item.detail.read`
    all but clinic_user (02: clinic_user reads name, unit, on hand); `item.write` owner / manager / warehouse;
    `master.archive` (deactivate items, units, categories, warehouses) owner / manager; `vat.read` all but clinic_user;
    `vat.write` owner / manager / accounting; `counterparty.archive` (counterparties and VAT classes) owner / manager;
    `cost.read` owner / manager / accounting / readonly (warehouse: "qty only by default").
26. [NEW T05] Every tenant gets default units (PCS, BOX, PACK, KG, L, M) and VAT classes (24 / 13 / 6 / 0 %, myDATA
    categories 1 / 2 / 3 / 7 from [L4]) from an AFTER INSERT trigger on `erp.tenants` (E100 is not redefined). Editable
    defaults; **accountant confirms** rates, myDATA categories and the exemption reason of VAT0.
27. [NEW T05] `lot_tracked = true` is refused (`not_available`) until lots / expiry exist (T37): such an item could not
    be posted (02: a lot on every stock line).
28. [NEW T05] No trigram index: `pg_trgm` sits in `extensions` on Supabase and in `public` for the CRM locally, so an E
    file cannot name its operator class portably. Item search = code prefix (btree `text_pattern_ops`) + name contains
    (`strpos`) inside one tenant + exact barcode; measured in T15 against the 150 ms target.
29. [NEW T05] `item_categories.valuation_override` exists but is read-only (not settable by `category_save`); only the
    valuation switch (T39, owner) sets it. The effective method is read from `erp.valuation_periods` (E140).
30. [NEW T05] `item_save` takes an optional `version` (optimistic lock, `ERP_CONFLICT`); barcodes are saved with the item
    (the list replaces them). A unit used by an active item cannot be deactivated; a category with active children
    neither.
31. [NEW T06] The document-type catalogue `erp.doc_types` is created by E120 (series need it, T06) with all 26 types of
    01 C, `enabled = false`; the file that implements a type enables it and E130 adds the posting columns. ADJ+ / ADJ-
    are two types `ADJ_IN` / `ADJ_OUT` sharing the capability prefix `adj` (fixed stock sign per type).
32. [NEW T06] Capabilities: `warehouse.read` all roles, `warehouse.write` owner / manager / warehouse on their branches,
    `counterparty.read` all but clinic_user, `counterparty.write` owner / manager / accounting, `series.read` owner /
    manager / accounting, `series.write` owner (02 rows "Items ... warehouses", "Counterparties", "Tenant settings ...
    series"). Series per scope of 01 C: OPN, MTR, CBAL organisation-wide; the others per branch.
33. [NEW T06] One address per counterparty (street, city, postal code) in v1; delivery addresses come with the delivery
    block (E6). One tax ID per country per tenant (a second branch of a supplier is the same counterparty). Counterparty
    `code` is optional.
34. [NEW T06] `series_create_defaults` creates default series only for enabled NON-fiscal types; fiscal series (gapless,
    yearly reset) are set up by the owner with the accountant (02 "accountant confirms"). A taken code is skipped and
    reported, never overwritten.
35. [NEW T06] A warehouse that holds stock cannot change branch or be deactivated (guard added by E140 when balances
    exist).
36. [NEW T07] The master-data screen is one menu entry with tabs (like Admin), opened by any of `item.read`,
    `warehouse.read`, `counterparty.read`, `series.read`. Decimal commas typed in number fields are sent as points.
    Barcodes are typed comma / space separated in one field.
37. [NEW T08] Imports are ALL OR NOTHING (one bad row = nothing written) and limited to 2000 rows per call (8 s timeout);
    the page sends only the known columns and lists the others as ignored. Items match by code, counterparties by tax ID
    (same country) then code. An empty cell keeps the existing value (it never clears a field).
38. [NEW T09] Document capabilities per type: `doc.<prefix>.read` / `.create` (save draft, post without approval) /
    `.approve` (approve, reject, cancel). 02's "min role" of `doc_transitions` is a capability suffix (the matrix is
    data). Several rows per (type, from, to) are alternatives (e.g. post under the limit by `.create`, any value by
    `.approve`).
39. [NEW T09] A draft is SAVED with its business problems (returned as `problems`; 03 "save = warnings, post =
    blocking"); shape errors and ids of another tenant refuse the save. Posting a document dated in the future is
    refused (`future_date`). Cancelling needs a reason; a rejection reason is kept in the audit row only.
40. [NEW T09] A document of the caller's tenant that it may not see (branch / type) = `ERP_FORBIDDEN`; another
    tenant's = `ERP_TENANT` (like branches, F1-05).
41. [NEW T09] `doc_no` = series code + "/" + 6-digit number (print format; the accountant may want another: change of
    one expression). Choice of series at post: the document's series, else the default of (type, branch or none,
    year), else the default without a year.
42. [NEW T09] `client_key` (07 section 5): a second save with the same key updates the same draft; once posted the
    document is returned unchanged (an external retry never creates a second document). `source` = `external` when
    a client_key is given, else `ui`.
43. [NEW T09] Value approval limit = `tenant_settings.thresholds[doc_types.approval_key]`; no key / no value = no
    approval needed. Value = lines' net in E130; E140 redefines `erp.doc_value` to the cost value of stock lines.
44. [NEW T09] Gapless numbering is proven by `concurrency_numbering.sh` (runner, mode A); the 50-client pgbench run is
    T15 (RESULTS.md), not part of every runner run.
45. [NEW T10] **Golden cases G1-G5 were worked by hand by the implementer**, because the Fable cases (03 section 5) did
    not exist; `tests/golden/README.md` says so. The F2 reviewer re-computes every expected value before trusting them.
46. [NEW T10] Average: `avg_cost = value / qty` (6 decimals) after EVERY move that leaves qty > 0 (not only after
    receipts), outbound value = round(qty x avg_cost, 2); a move's unit cost = |value| / qty (6 decimals), so the line's
    `unit_cost x qty` matches its `cost_value` to the rounding. Quantity 0 always means value 0 (both methods).
47. [NEW T10] Provisional cost of an uncovered quantity: average -> current avg_cost; FIFO -> unit cost of the last
    consumed layer; fallback the item's last purchase price, else 0 (flag `cost_provisional`). The covering receipt
    posts ONE value-only correction move (qty 0) on its own date and document line.
48. [NEW T10] Inbound without a line cost (ADJ+ without cost, unlinked customer return) = the current official cost
    (average: avg_cost; FIFO: the next layer out), the same value under both methods. A linked customer return comes
    back at the per-method unit costs of the original issue.
49. [NEW T10] Supplier return (cost rule `source_in`, G5): average at the receipt's unit cost (unless it empties the
    stock: then the remaining value); FIFO takes the receipt's layer first, else normal FIFO. The separate value-only
    "difference" move of 02 is left to T23 (G5 extended); no PRET type exists before T23.
50. [NEW T10] Cancel = reversing moves at the ORIGINAL date (opposite qty and values) + replay of each item from that
    date skipping the pair (as if the document never existed; later costs and their document lines are rewritten).
    Backdated posts replay at once. T13 adds: queue above 2,000 later moves, `cost_revisions`, lock-date rules, job.
51. [NEW T10] Lots are not costed yet: every move has the "no lot" id; per-lot cost and balances come with T37.
52. [NEW T11] A GRN without PO posts at its line net (discount included) and is NOT flagged `cost_provisional` (in v1
    the flag means a negative-stock provisional cost); how a later supplier invoice corrects GRN costs is T22 (PINV).
    The last purchase price is kept when a GRN is cancelled.
53. [NEW T11] OPN follows 01 "M O / O / O": a manager prepares and submits, only the owner posts (approval step for
    every OPN, no value limit); one line per item; several OPN per warehouse are allowed; a cost of 0 is allowed.
54. [NEW T11] The opening import creates ONE OPN draft of up to 2000 lines (the 500-line limit is the screen's); it is
    posted like any OPN (by the owner).
55. [NEW T11] GRN specific fields: supplier delivery-note number / date = `ext_number` / `ext_date` (date not after the
    receipt), MARK in `extra.mark` (digits, up to 20). Lot / expiry on GRN lines: T37.
56. [NEW T12] ADJ reasons: ADJ+ `found` / `correction`; ADJ- `damaged` / `expired` / `lost` / `correction` (01 C3 list).
    Approval value of ADJ = line net when a cost is typed, else qty x current official cost (E140 `doc_value`). An
    approver (manager / owner) posts any value directly. Destruction / self-supply rules: **accountant**.
57. [NEW T12] CONS cost centre is optional free text (60); the reversal of a CONS (07 section 5 item 5) is the normal
    cancel (reversing moves, stock and cost restored), done by manager / owner. The post reply shows line costs only
    with `cost.read` (a clinic_user posting CONS gets quantities; the facade of phase IP decides its own reply).
58. [NEW T12] New capability `stock.read` (every role): on hand, stock card, negative-stock report (quantities). Values
    always need `cost.read`.
59. [NEW T12] Alerts `negative_stock` / `low_stock` are per (warehouse, item), on the warehouse's branch, visible to
    every member with `alert.read` of that branch (02 named warehouse / manager / owner; clinic_user and readonly also
    see them: harmless, a filter in the alerts screen can narrow it). Email digest: later (SHOULD).
60. [NEW T13] Inline recost limit = 2,000 later moves of the item (02); above it the post is costed at the current state
    and queued; `recost_status` tells the page "recost pending". The limit is the GUC `erp.recost_inline_limit` (default
    2000; tests set it to 0); not reachable through the API (no SET from PostgREST, F1-13).
61. [NEW T13] The jobs are plain functions run by the database owner (`erp.recost_job()` every 5 minutes,
    `erp.integrity_job()` nightly), scheduled on live with pg_cron (owner step, not an E-file object); the owner can
    also run the queue from the page (`recost_run`, `tenant.settings.write`).
62. [NEW T13] `cost_revisions` logs the moves of OTHER documents whose cost a replay changed (the backdated document's
    own new moves are not "revisions"); cancel replays log reason `cancel`, queue runs `queue`.
63. [NEW T44] T44 was done inside E2 (05: "after T09, before the phase's screens"), after T13. Conversion golden V1-V9
    (Fable) do not exist: the suite covers V1-V5 and V8 with TEST types; V6, V7, V9 need the real types (T45 / T46).
64. [NEW T44] Per-tenant switch-off of a pair (02 "can be switched off per tenant") is not built yet (no real pair is
    enabled before T45); `doc_conversions.enabled` is platform-wide. Converted quantities are base units (alternative
    units: T38). A source must be posted / approved (not draft, pending, cancelled, failed, submitted).
65. [NEW T14] Alert list / resolve RPCs are platform RPCs in E100 (alerts are an E100 table). The page shows alert text
    from `message_key` + `params` (strings.en.js), never server text. Error codes of E130 / E140 map to short strings;
    the server sentence stays in the problem list for ERP_VALIDATION.
66. [NEW T14] The stock document drawer saves first when edited, then runs the action; posting with warnings shows the
    dialog and posts again with `ack_warnings` (the server re-checks under the locks). Print / PDF of stock documents
    is not in T14 (03 recipe step 10 "print template": with T28's print templates).
67. [NEW T15] Load "20 tenants" = the platform tenant + `load_std` + 18 small tenants (500 items, 2 warehouses, 1,000
    documents); the stress tenant is optional (`STRESS=1`). Timings are server-side (clock_timestamp around the RPC in
    the database), warm cache, as the `warehouse` member of branch BR1; the 20-line post target is met by CONS and GRN.
68. [NEW T15] pgbench posts as the warehouse member (02 matrix: warehouse creates and posts GRN / CONS), 3 lines on the
    5 hot items, CONS past zero with `ack_warnings`; 1 in 10 transactions posts and rolls back (gapless check covers it).
69. [NEW T15] A recost replay keeps the item's running cost state and the partly consumed FIFO layer in
    transaction-local settings (`erp.replay_key`, `erp.replay_state`, `erp.replay_head`) and writes `item_costs` /
    the layer once at its end; nothing outside `erp.cost_replay` / `erp.cost_move` reads them. Results are unchanged
    (golden + replay checks).
70. [NEW T15] One document is posted per transaction (every RPC does so). A future batch post must commit per document:
    the per-month `tenant_usage` row is taken last and held to commit (deadlock seen with the generator's batches).
71. [NEW F2] Provisional cost (F2-01): see O2 above; STATE 47 now reads "fallback = the purchase price when the move was
    posted, for both methods". A cancel with more than the inline limit of later moves, and any backdated post / cancel of
    an item already queued from an earlier date, go to the recost queue (F2-04). `erp.recost_job(p_max, p_budget_ms)`:
    try-lock per item, 3 s budget (F2-02); the cron command is unchanged. The lock date is read FOR SHARE (F2-03).
    A cancel that takes stock negative warns (reply `warnings`, audited) or is refused under `block` / transit (F2-05).
72. [NEW T16] Two-branch documents are GENERIC E130 hooks, not TRF code in E130: `doc_types.dest_visible`,
    `doc_transitions.side`, `doc_types.action_fn` (+ actions `receive` / `close`), `erp.doc_ref_changed`. The destination
    branch reads a transfer only once it left `draft` (a draft is the source's work in progress). [UNCERTAIN: 02 says
    "visible to both" without a state; showing drafts to the destination is one condition in three places.]
73. [NEW T16] Transfer cost (cost rule `transfer`, E140 `cost_move`): cost-neutral, the item's company-wide state and
    FIFO layers never change. The dispatch move is valued at average = avg_cost, FIFO = value_fifo / qty of the item
    (company-wide layers have no warehouse: a CONVENTION; alternative = the value of the oldest layers, not consumed);
    the whole stock moves at its exact values; without stock = the uncovered-quantity rule of an issue, provisional. The
    paired transit move and the receipt moves copy the dispatch move (part: round(qty x its unit cost, 2)).
    [UNCERTAIN: FIFO convention, F3 / accountant.]
74. [NEW T16] A shortage stays in transit until its ADJ_OUT (out of the TRANSIT warehouse, destination branch) is
    posted; it leaves at the official cost at the ADJ date (normal ADJ rule), not at the dispatch cost. So transit
    QUANTITY is zero for every closed transfer, and its VALUE nets to zero for every settled transfer without a
    shortage (`transit_value`); with a shortage a cents-level value residue can stay on the transit warehouse's moves
    (per-warehouse value is not a v1 concept: 02 "Per-warehouse cost: not in v1"). [UNCERTAIN, accountant.]
75. [NEW T16] An excess: the receipt moves at most the dispatched quantity out of transit; the extra comes in by the
    generated ADJ_IN into the destination at the CURRENT cost (no unit price on its line: a price would show the cost
    to the warehouse role, which has no `cost.read`).
76. [NEW T16] The difference goes through the EXISTING ADJ path as the brief says (value limit `thresholds.adj_value`:
    under it the receiver itself may post it; above it submit -> manager / owner approve or reject). 01 C3 writes
    "difference M O / M O": if that means "always approved by a manager", the generated ADJ must always go
    pending_approval (one rule). The generated ADJ belong to the DESTINATION branch (the receiver reports, its manager
    approves) and are dated the receipt date. [UNCERTAIN: both points, F3.]
77. [NEW T16] Generated ADJ: reason `lost` (shortage) / `found` (excess) by default, editable to any valid reason; the
    receiver's free-text reason is kept per line (`doc_trf_lines.diff_reason`, ADJ line description). They are found
    by REGISTRATION (`doc_trf.adj_out_id / adj_in_id`), not by their reference: reference, type, branch, warehouse,
    items and quantities cannot change (problems `invalid` / `mismatch`), they cannot be deleted (`ERP_STATE`) and, once
    posted, not cancelled (`ERP_DOC_HAS_CHILDREN`; a wrong difference is corrected by a new normal ADJ). A reject sends
    it back to draft; the transfer waits. No other ADJ may reference a transfer. Only system documents may use the
    transit warehouse (E130 `doc_validate`; today only these ADJ_OUT are system documents).
78. [NEW T16] State machine reading of 02: `received` is FINAL for a receipt without difference;
    `received_with_difference -> closed` happens by itself when the last generated ADJ is posted (as the poster, when it
    holds `doc.trf.create` on the destination; else the destination closes it by hand: row received_with_difference ->
    closed). There is no later `received -> received_with_difference` (a difference found later = a normal ADJ).
    [UNCERTAIN reading of the parenthesis in 02.]
79. [NEW T16] Receipt = `doc_set_state(id, 'received' | 'received_with_difference', {receipt_date, lines})`; a line not
    listed is received as dispatched; the target state must match the quantities (problem `state`); a difference needs
    a reason; receipt date >= dispatch date, not in the future, not on / before the lock date (read FOR SHARE). The
    receipt takes no number (the TRF number is the dispatch's) and bumps no usage counter. Lock order: document row,
    items ascending, balances (no series). The auto-close locks the TRF row LAST, after the ADJ's own post locks.
80. [NEW T16] Roles (02 "TRF" + 01 C3): `doc.trf.create` owner / manager / warehouse (dispatch on the source, receipt
    and manual close on the destination); `doc.trf.approve` owner / manager of the SOURCE (cancel, only while
    dispatched: "void M O before receipt"); `doc.trf.read` also accounting / readonly; clinic_user none.
81. [NEW T16] One line per item (duplicates refused); no prices on TRF lines (they move at cost); `extra.delivery =
    {carrier, vehicle, notes}` (01 "delivery block"; T36 extends it for the fiscal document).
82. [NEW T16] **Fiscal (RISK, accountant)**: a transfer between two ESTABLISHMENTS is a fiscal movement document (01 C3,
    myDATA 9.3) = T36. v1 posts EVERY TRF as an internal, non-fiscal document; `trf_fiscal_needed` (different branch and
    establishment number) is reported by `trf_get`. For iSmile every clinic is its own establishment, so every
    inter-clinic transfer is such a movement: the accountant must say whether internal TRFs between clinics may be used
    on live before T36 (they should not be enabled on live before F3 and that answer).
83. [NEW T16] Transit never below zero: the receipt BLOCKS (`ERP_STOCK_NEGATIVE`, whatever the setting), a cancel of a
    dispatched transfer is checked by `stock_cancel_check`; an over-dispatch of the SOURCE uses the CONS warning path
    (warn + ack, or block). No stock alerts on the transit warehouse. The source / destination warehouse of an open
    transfer keeps its branch and stays active.
84. [NEW T16] `doc_set_state` replies `posted: true` for a dispatch (post action, to_state dispatched); a warnings
    reply is marked internally (`held`) and not stored under the idempotency key (was: "not posted and to_state =
    posted", which a TRF dispatch would have stored).
85. [NEW T16] Tests: `costing_model.py` got the transfer rule from the T16 implementer (not independent: F3 re-checks
    G10); the E150 suite expectation of `series_create_defaults` now includes TRF-A1 (a newly enabled type); the runner
    vacuums before EACH fuzz run: the replay's layer give-back update (E140 `cost_replay`) got a pathological plan in the
    queue fuzz once the test database grew (F2-15 class, test environment; RISK for F3: make that statement plan-robust).
    Re-running E130 ALONE after E140 restores E130's `doc_value` (pre-existing; run lists always run the whole list).
86. [NEW T18-lite] Destination picker = new read RPC `trf_warehouses` (cap `doc.trf.read`, every branch, codes / names
    only, never transit): a branch-scoped warehouse member cannot see other branches' warehouses in `warehouse_list`,
    and the destination is usually another clinic. Readers (accounting / readonly) also get the codes (for the "To"
    column). [UNCERTAIN: showing other clinics' warehouse codes to every TRF reader; alternative = a `dest_code`
    column in `doc_list` rows.]
87. [NEW T18-lite] One "Confirm receipt" button stands for the two receive actions (`receive`, `receive_difference`);
    the form picks the state from the quantities (any line differing -> `received_with_difference`), sends every line
    (`received_qty` as typed, `reason` only for a differing line) and checks "a difference needs a reason" locally
    before the call (the server re-checks). Receipt date defaults to the member's today (dd/mm/yyyy, sent ISO).
88. [NEW T18-lite] The transfer drawer reuses the stock document drawer (30_stock.js) instead of a second drawer:
    saving / acting reopens a TRF through `trf_get` (the transfer section needs it). A warehouse not in the caller's
    `warehouse_list` (the other branch's source, the TRANSIT warehouse of a generated ADJ_OUT) is shown as read-only
    text; a `source = system` document (generated ADJ) keeps warehouse / branch / lines (+ line description) as
    loaded, hides Add line / Delete / Copy, and lets reason / notes / date change. Copy stays on a TRF (server
    `doc_copy`).
89. [NEW T18-lite] Fiscal note: every transfer shows "Internal transfer, not a fiscal document (v1)"; when `trf_get`
    says `fiscal_needed` a second sentence says the fiscal movement document comes later (STATE 82, accountant). The
    screen does not block anything on it.
90. [NEW T18-lite] Mock (`mock_supabase_erp.js`) emulates TRF: source / destination visibility (dest only once
    dispatched), actions per side, dispatch warnings, receipt with a generated ADJ_OUT (TRANSIT, no stock check), the
    auto-close after its post. The real-DB smoke creates the second branch's series through Master data > Series
    after a reload (`whoami` is read once per page load: a branch created in another tab appears after a reload).
    The first full run had ONE failure of `smoke_erp_transfers.py` (a JS error inside a wait predicate, not reproduced
    in 9 reruns, 6 of them in parallel): the `d-msg` waits are now null-safe and the smoke turns any exception into a
    FAIL line with its message (the runner shows FAIL lines), so a recurrence names its step. [RISK: watch it.]
91. [NEW Expenses lite] Scope: NOT built: attachments (STATE 13 still open), recurring templates, open amounts / AP, the
    PAY stub and allocation to payments (T29). An EXP stores `extra.paid` + `payment_method` (cash / card / bank / other,
    only when paid) and nothing else about money: an unpaid expense has no open amount anywhere until T29. No myDATA
    expense classification (E3 characterisation) is stored; MARK is kept as text (digits) like the GRN.
92. [NEW Expenses lite] **Accountant confirms**: the 10 default categories (RENT, UTIL, TEL, OFFICE, FEES, MAINT, MKT,
    TRAVEL, BANK, OTHER) and their default VAT classes (RENT, BANK -> VAT0; the rest VAT24) are editable conveniences
    only; electricity (6 %) and water (13 %) differ from the UTIL default: the user picks the class per line.
93. [NEW Expenses lite] **Accountant confirms**: VAT of an expense line = net x rate of the chosen class, rounded per
    line half up (the 02 core rule); there is no manual VAT override, so a supplier document whose printed VAT differs
    by a cent needs a corrected net (RISK for exact matching with myDATA later). VAT deductibility is NOT modelled
    (medical services are largely VAT-exempt, so input VAT is mostly not deductible): the report shows net, VAT and
    gross paid, not deductible VAT; treat gross as the cost until the accountant says otherwise.
94. [NEW Expenses lite] Approval limit `tenant_settings.thresholds.exp_value` compares the NET value (the core
    `doc_value` of a priced document); no value = no approval. Admin > Settings got the field (empty = none); the
    other threshold keys are sent back unchanged.
95. [NEW Expenses lite] Roles (01 C1 "EXP": create A M O, approve above the limit M O, void A M O): the cancel transition
    uses cap `create` (accounting may cancel, also an expense a manager approved); read follows the 02 "PINV" row
    (owner, manager, accounting, warehouse r, readonly r; clinic_user none). Categories: write owner / manager /
    accounting (02 "VAT classes" row: accounting c), deactivation without `master.archive`. [UNCERTAIN: warehouse
    reading expense amounts; `hide_money` is not applied to EXP lists / report yet.]
96. [NEW Expenses lite] Numbering: series per branch (`series_scope = branch`), not gapless (a received document, the
    number is internal). `series_create_defaults` now also creates `EXP-<branch>`.
97. [NEW Expenses lite] Generic core change, not a fork: `document_lines.expense_category_id` (column in E130, FK in
    E180); `doc_save_draft` accepts it (tenant check `erp.require_own(.., 'expense_category', ..)`, E120; a line needs
    an item OR a description OR a category; default VAT = the category's when the key `vat_class_id` is ABSENT, an
    explicit null stays null), `doc_line_json` returns the id (the page names it from `expense_category_list`),
    `doc_copy` copies it. EXP refuses item lines (stock goes through a GRN), a customer-only counterparty, a supplier
    date after the expense date.
98. [NEW Expenses lite] Report: posted only (cancelled out), the caller's branches, default range month-to-date,
    grouped by the line's own category (path shown, no roll-up to the parent; the category filter includes the
    sub-tree) or by supplier (no supplier = one row), at most 1000 rows (totals over everything). CSV is built in the
    page (comma separated, UTF-8).
99. [NEW Expenses lite] Screen: the branch is chosen on a new draft and fixed once saved (change = delete and
    re-enter); the line shows VAT / gross while typing with the server's rule (display only, the saved figures come
    from the server); choosing a category sets its default VAT class.
100. [NEW Expenses lite] Smoke: the mock emulates EXP (limit via `mock_exp_limit`), categories and the report. The
    "server problems" step sets `mock_fail` through an init script: a localStorage write made right before a file://
    reload was lost in 2 of 5 runs, the likely cause of the unexplained T18 flake (STATE 90); `smoke_erp_transfers.py`
    still uses the old pattern (not changed here). [RISK: watch it.]
101. [NEW Draft 1] Storage: the file bytes live in `erp.attachments.content` (bytea, storage external), hard limit 5 MB
    per file (checked on the decoded bytes and, before decoding, on the base64 length), PDF / JPEG / PNG by magic bytes
    only (the file name / declared type never decide). A storage bucket is a LIVE decision (open item L-D1).
102. [NEW Draft 1] Attachments attach to GRN documents only in this build (one capability family: `doc.grn.create`
    adds / deletes, `doc.grn.read` reads, deleting the file of a posted / cancelled GRN needs `doc.grn.approve`).
    A file may exist unlinked (uploaded before "Create draft from note"); it carries the branch of the chosen warehouse
    and is visible only to that branch. Other document types (EXP receipts) are a later task.
103. [NEW Draft 1] Append-only except the link and one soft delete; the bytes of a deleted file stay (no purge). A
    deleted draft leaves its files unlinked (FK `on delete set null (document_id)`, PostgreSQL 15+). Purge / retention
    is a LIVE decision (L-D3).
104. [NEW Draft 1] Extraction contract `delivery_note_extraction/1` (E190 section 4, API.md). Unknown keys are ignored
    (the extractor may add fields); a wrong `schema` value, no lines, more than 500 lines are refused.
105. [NEW Draft 1] Matching: supplier = the ONE active supplier / both whose tax ID equals the normalised extracted
    tax ID (E120 `tax_id_norm`, by the counterparty's country); none or several -> no supplier (problem). Line -> ACTIVE
    non-service item by barcode, then our item code = supplier_code (case-insensitive), then exact name = description
    (case-insensitive, trimmed, only when exactly one item has it). No supplier-code table (supplier item codes) yet:
    when a supplier's codes differ from ours, lines fall to name / unmatched until such a table exists (later task).
106. [NEW Draft 1] Confidence threshold 0.80: below it, or missing, a matched line is `low_confidence` and blocks the
    post until the user marks it checked (`extra.dn.checked = true`). An unmatched line blocks until an item is chosen
    (no "checked" needed). Quantity not a number > 0 -> 0, price not a number >= 0 -> empty: the core validation then
    blocks; unit text is kept for the user only (base unit; alternative units T38).
107. [NEW Draft 1] Never posted automatically: `grn_draft_from_extraction` only calls `doc_save_draft`; a draft with
    every line matched and confident still waits for the user's Post. Source of the draft = `external` (client_key set),
    notes "From delivery note <file name>".
108. [NEW Draft 1] Idempotency of the draft RPC is by `p_client_key` (no idempotency-key argument, as the task's
    signature); the page uses `dn:<attachment_id>`, so a retry or a double tap returns the same draft unchanged (the
    user's fixes are kept). A per-key advisory lock serialises two calls.
109. [NEW Draft 1] The extractor runs in the page (`window.ERP_EXTRACTOR({file, attachment, warehouse})`); default =
    deterministic MOCK (same 3 sample lines for any file, extractor "mock", shown as "MOCK extractor - sample data").
    The real extractor service is a LIVE decision (L-D2); nothing in this build calls an external service.
110. [NEW Draft 1] Open / preview: `attachment_get` returns base64; the page makes a blob link the person taps (a
    pop-up opened after a server call is blocked on phones) and shows photos inline. `attachment_list` / `_get` never
    return a deleted file's bytes; the audit keeps filename / size / sha256.

111. [NEW Draft 2] **NON-FISCAL v1 (RISK, accountant confirms)**: DN (myDATA 9.3), RR (11.1) and RS (11.2) are fiscal
    documents in Greece; v1 issues them as INTERNAL documents (`doc_types.fiscal = false`, local gapless numbering), every
    drawer / print shows "NOT A FISCAL DOCUMENT", and `fiscal_needed = true` is reported by `sales_get` exactly like
    `trf_fiscal_needed` of a TRF (82). They must not replace the legal documents on live before the provider (04 / T36);
    the provider task sets `fiscal = true` back and moves the numbering to fiscal series.
112. [NEW Draft 2] **Accountant confirms: VAT on delivery notes.** A DN without invoice is not a VAT event; v1 lets a DN
    carry prices and per-line VAT (same core arithmetic) as INFORMATION only, price optional. The VAT that counts is the
    billing document's (RR now, SINV later). Safe default: nothing reports DN VAT.
113. [NEW Draft 2] **Accountant confirms: RR vs simplified invoice.** RR = retail receipt to a consumer (customer optional);
    a business customer with a tax ID should get an invoice (SINV) or a simplified invoice: neither exists yet, and v1
    does not stop an RR with a business customer. Safe default for the pilot: RR only for patients / consumers.
114. [NEW Draft 2] RR billing a DN is a PLAIN LINK (01 C5 "DN -> RR: stock NONE"): line `extra.dn_line_id` + header
    `ref_document_id` (one DN per receipt, same branch and customer, DN posted and to be billed, quantity <= the DN line's
    remaining; drafts count, as 02 "remaining"). `doc_conversions` / T44 are untouched (FC pending). The DN cannot be
    cancelled while a receipt lives (E130 `ERP_DOC_HAS_CHILDREN` through `ref_document_id`). [RISK: two receipts billing
    the same DN line at the same moment are serialised only by the series row lock, i.e. when both use the default series
    of the branch (the usual case); T45's conversion locks the source.]
115. [NEW Draft 2] Cancel: DN / RR / RS posted -> cancelled by owner / manager with a reason (reversing moves). 01 C1 says
    "provider cancel" (DN) and "by RCR" (RR / RS): both are fiscal paths that do not exist in v1. Accounting creates but
    does not cancel; clinic_user creates RR only (01 "A C M O") and, without `doc.dn.read`, cannot bill a DN; warehouse
    creates DN and does not read receipts (02 matrix rows "SQ, SO, DN" / "SINV ... RR, RS").
116. [NEW Draft 2] Delivery block keys `address, carrier, vehicle, reason`; reasons sale, sale on approval, sample, repair,
    return, other (accountant confirms the list and its later myDATA movement-purpose mapping); `to_be_billed` default
    true (a DN "not to be billed" cannot be billed and shows that state).
117. [NEW Draft 2] RR money: `extra.payment_method` only (collected at issue, gross = amount); no money record until the
    RCPT task (`erp.sales_collection` is its data source, `sales_get.collection.rcpt` its slot).
118. [NEW Draft 2] Issuer on prints: `tenant_settings.issuer` (E100 column; legal name, tax ID, tax office, address,
    phone, email; Admin > Settings), trading name = `tenants.name`, branch name / address / establishment number from
    `branches`, logo = `logo_url`. Print / PDF = in-page print view with print CSS (browser "Save as PDF"); no new
    dependency, no CDN, no server-side PDF. **Real PDF generation / email (Edge Function) is a later LIVE decision
    (L-D4).**
119. [NEW Draft 2] RS is built (same code path: no warehouse, service items or description lines, payment method).
120. [NEW Draft 2] E140 generic rule: a document line whose `extra` has `dn_line_id` moves no stock (`stock_effect`,
    `stock_post`); only the RR catalogue row allows that key and its validator checks the link. Costing is unchanged
    (no golden case, `costing_model.py` untouched).
121. [NEW Draft 2] Sale lines: the VAT select left empty sends no `vat_class_id` (the item's class); a priced line without
    a VAT class is a problem; no manual VAT override (as 93). Quick-add customer from the drawer: name only, kind
    customer, needs `counterparty.write` (owner / manager / accounting); the other details in Master data.
122. [NEW Draft 2] Tests: E120 / E130 suites used DN as the "fiscal type not enabled" example: now SINV. The stub mock
    emulates DN / RR / RS (+ one posted DN-SER/000001 to Dental GmbH) and `sales_get`; `demo.html` was rebuilt because
    its smoke fails on a stale file (demo sources unchanged, so the demo has the Sales menu but no sales seed).

## Open LIVE items for the owner (Draft 1; not decided here)
- L-D1 Storage: keep files in the database (as built; 5 MB each, counts against the database size of the Supabase
  plan) or move them to a Supabase Storage bucket (private bucket, RLS on `storage.objects`, the table keeps metadata +
  the object path). Decide before real use; a move is a later task.
- L-D2 Extractor service: which OCR / AI service reads the delivery notes (data leaves the project: supplier prices,
  no patient data expected), where it runs (Edge Function + secret key), cost per page, and Greek-language quality.
  The contract `delivery_note_extraction/1` is what it must return.
- L-D3 Retention / purge of deleted files and of files of cancelled receipts (accountant: how long supplier documents
  are kept); size limit per tenant (`tenants.limits.attachments`, monthly count) if wanted.
- L-D4 (Draft 2) Sales documents as files: a real PDF (server-side, e.g. an Edge Function) and sending it by email are
  not built; today the browser prints / saves as PDF. Decide with the provider task (the provider usually returns the
  legal PDF / QR) before building anything.
- L-D5 (Draft 2) DN / RR / RS on live: not before the provider and the accountant's answers 111-113 (they are fiscal
  documents; v1 is internal only).
