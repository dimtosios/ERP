# iSmile ERP backend

Standalone ERP (own schemas `erp` and `erp_api`). It names no CRM object and installs on an empty database.
Design: `docs/erp/` (02 architecture, 03 handbook). Front-end contract: `API.md`. Progress: `docs/erp/STATE.md`.

## Run order
Run every `E*.sql` file in name order, as the database owner (Supabase SQL editor = `postgres`, which has
BYPASSRLS; the files refuse to run as a role without it). Every file can be re-run; run the whole list again after
a fix.

| File | What it owns | Redefines | Test suite |
|---|---|---|---|
| `E100_tenancy.sql` | schemas `erp` / `erp_api`, tenants (tenant #1 iSmile), branches, members, roles / capabilities / role_caps, settings, usage, alerts, audit_log, idempotency; helpers; RLS; RPCs `whoami`, `branch_*`, `settings_*`, `audit_list` | - | `tests/E100_tenancy_tests.sql` |
| `E110_members.sql` | invitations, first-login binding, member list / change / reset binding, `erp.tenant_onboard` | - | `tests/E110_members_tests.sql` |
| `E120_master.sql` | units, VAT classes, item categories (tree), items, barcodes (T05); warehouses + transit, counterparties, the document-type catalogue `doc_types` (01 C, all types, `enabled = false` until a file implements one), series (T06); trigger `tenants_e120_init` (defaults per tenant) | - | `tests/E120_master_tests.sql` |
| `E130_documents_core.sql` | posting columns of `doc_types`, `doc_transitions`, documents, document_lines (immutability trigger), `series_for` / `next_number`, validation, `doc_set_state` / `post_document` / `cancel_document`, RPCs `doc_save_draft`, `doc_get`, `doc_list`, `doc_delete_draft`, `doc_set_state`; VAT rate guard trigger; T16 generic hooks: `doc_types.dest_visible` / `action_fn`, `doc_transitions.side` and actions `receive` / `close`, `erp.doc_can` / `doc_can_read` / `doc_dest_branch`, `erp.doc_type_action`, `erp.doc_ref_changed` (parent notification), state `received_with_difference` | - (`erp.doc_value` is redefined by E140) | `tests/E130_documents_tests.sql`, `tests/concurrency_numbering.sh` |
| `E135_conversions.sql` | `doc_conversions` (01 C5 matrix), `document_links`, views `v_line_remaining` / `v_doc_conversion_status`, `erp.doc_conversion_validate` (called by E130 `doc_validate`), RPCs `doc_convert`, `doc_copy`, `doc_conversions_for` | - | `tests/E135_conversions_tests.sql`, `tests/concurrency_convert.sh` |
| `E140_stock_engine.sql` | stock_moves (ledger), stock_balances, item_costs, stock_layers, stock_move_layers, valuation_periods (seed average); `erp.cost_move` (the one costing step, average + FIFO), `erp.cost_replay`, hooks `stock_lock / stock_check / stock_post / stock_cancel`, `erp.stock_integrity`; cost rule `transfer` + `erp.stock_cost_new` (T16); alerts (T12, never on the transit warehouse); cost_revisions, recost_queue, `erp.recost_item / recost_job / integrity_job`, RPCs `recost_status / recost_run`, lock-date guard (T13); ledger and master-data guard triggers; trigger `tenants_e140_init` | `erp.doc_value` (E130) | `tests/E140_stock_engine_tests.sql` + `tests/golden/G1..G5, G8.csv`; F2: `tests/E142_f2_review_tests.sql` (+ `golden/R1..R4.csv`), `tests/costing_model.py` (independent model: golden re-compute + differential fuzz), `tests/concurrency_lockdate.sh`, `tests/concurrency_recost.sh` |
| `E150_stock_docs.sql` | types OPN, GRN (T11), ADJ_IN, ADJ_OUT, CONS (T12): rows of `doc_types` enabled, transitions, capabilities, `erp.doc_stock_validate`; `opening_import`; `doc_check`; view `rpt_erp_negative_stock` + `report_negative_stock` | - | `tests/E150_stock_docs_tests.sql` (+ `tests/golden/G7.csv`) |
| `E160_transfer.sql` | type TRF (T16): row of `doc_types` enabled (cost rule `transfer`, `dest_visible`, `action_fn = trf_action`), transitions (dispatch / receive / receive with difference / close / cancel; receipt and close on the destination side), capabilities `doc.trf.*`; receipt tables `doc_trf`, `doc_trf_lines`; `erp.doc_trf_validate`, `erp.trf_adj_validate` (called by E150), `erp.trf_receive` / `trf_close` / `trf_child` (generated difference ADJ, auto-close), `erp.trf_integrity` (called by E140 `integrity_job`), `erp.trf_fiscal_needed` (T36 hook); guards (generated ADJ not deleted / cancelled, warehouses of open transfers); RPC `trf_get` | - (uses the T16 hooks added to E130 / E140 / E150, below) | `tests/E160_transfer_tests.sql` (+ `tests/golden/G10.csv`), `tests/concurrency_transfer.sh`, `tests/mutation_transfer.sh` (broken copies must fail the suite; runner mode A) |
| `E180_expenses.sql` | expense categories (`expense_categories`: tenant tree, default VAT class, 10 defaults per tenant via trigger `tenants_e180_init`), FK of `document_lines.expense_category_id`; type EXP (T19-lite): row of `doc_types` enabled (no stock, price kind cost, limit key `exp_value`), transitions (post / submit / approve / reject / cancel), capabilities `doc.exp.*`, `expense.category.write`; `erp.doc_exp_validate`; RPCs `expense_category_list` / `expense_category_save`, `report_expenses` + view `rpt_erp_expenses`. NOT here (lite): attachments, recurring templates, AP / PAY | - (uses `document_lines.expense_category_id`, accepted by E130 `doc_save_draft`; `erp.require_own` kind `expense_category` in E120) | `tests/E180_expenses_tests.sql` |
| `seed/tenant1_onboarding.sql` | NOT an E file: run once at C0 with `-v owner_email=…` (owner invitation of tenant #1) | - | checked by the runner (twice) |
| (all files) | | | `tests/E990_generated_isolation_tests.sql`: generated tenancy + role-matrix suite over the catalog |
| (all files) | | | `tests/E991_adversarial_tests.sql`: review F1 attacks (cross-tenant login, owner escalation, shadowing, anon / service_role, DDL, re-run grants); `tests/concurrency_last_owner.sh`: two-session last-owner race (runner, mode A) |

Test helpers shared by the suites: `tests/_helpers.sql` (included with `\ir`).

## Grants
Every E file ends with `select erp.lock_down();` and then grants ITS OWN `erp_api` functions to `authenticated`.
`lock_down` (E100) closes all internal `erp` functions and sequences to the API roles (re-opening only the policy
helpers) and all `erp_api` functions to public / anon / service_role. Re-running one file never removes the grants
of another.

## Local tests
```
service postgresql start
bash erp/backend/run_erp_tests.sh            # empty database, no CRM objects
bash erp/backend/run_erp_tests.sh --all      # also: CRM loaded, CRM suites before / after / after drop schema erp
```
The runner loads all E files twice, runs every suite twice, runs the static checks (no CRM object named, `erp.html`
built from the sources, no CRM file changed) and the Playwright smoke tests (`tests/ui`, stubbed supabase-js).

Load (T15, not part of the runner; scratch database `erp_load*` only):
```
bash erp/backend/tests/load/run_erp_load.sh erp_load full     # 20 tenants, standard tenant 20,000 documents (real posting path)
python3 erp/backend/tests/load/measure_erp.py --db erp_load    # p50 / p95 timings, pgbench 50 clients, checks -> RESULTS.md
```
`gen_erp_load.sql` (deterministic generator), `measure_erp.sql` (timing helpers), `pgbench_*.sql`, `RESULTS.md`
(generated; `RESULTS_notes.md` is its hand-written tail).

## Front-end
`python3 erp/build_erp.py` builds `erp.html` (repo root) from `erp/app/`: `shell.html` + `erp.css` + `strings.en.js`
+ `00_core.js` (config, `api()`, error mapping, nav, role guard, form helpers, drawer / confirm / toast, login) + screens
(`10_master.js` master data, `30_stock.js` stock screens, `90_admin.js`) + `99_boot.js` (session start, last). Deterministic; commit the result.

Smoke tests (`tests/ui`): `smoke_erp_shell.py`, `smoke_erp_admin.py`, `smoke_erp_master.py`, `smoke_erp_stock.py` use the stub `mock_supabase_erp.js`;
`smoke_erp_db.py` runs the page against a REAL local database through `bridge_supabase_erp.js` (each RPC executed
as role `authenticated` with the stub login's JWT claims, like PostgREST).
