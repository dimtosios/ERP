# 03. Opus handbook: how to write the ERP code

Read for every task: this file, the task line in 05, and only the sections of 01 / 02 / 04 / 06 the task names.
Fable designs and reviews; Opus writes code. If a rule here conflicts with what the task needs, STOP and ask.

## 1. Repo layout (exact)
```
erp/backend/E100_tenancy.sql            tenants, branches, members, role_caps, settings, alerts, audit, helpers
erp/backend/E110_members.sql            invitations, first-login binding, whoami, onboarding seed
erp/backend/E120_master.sql             units, VAT classes, categories, items, barcodes, warehouses, counterparties
erp/backend/E130_documents_core.sql     doc_types, doc_transitions, series, next_number, documents, lines, links
erp/backend/E140_stock_engine.sql       moves, balances, layers, item_costs, post_document, valuation, recost
erp/backend/E150_stock_docs.sql         OPN, GRN, ADJ, CONS
erp/backend/E160_transfer.sql           TRF + transit            E170_stocktake.sql   STK
erp/backend/E180_expenses.sql           expense categories, EXP document, recurring templates
erp/backend/E200_purchasing.sql         PO, PINV, PCRN, PRET     E210_sales.sql       SQ, SO, DN, SINV, SVC, CRN, RR, RS, RCR
erp/backend/E220_reservations.sql
erp/backend/E300_money.sql              accounts, RCPT, PAY, MTR, CBAL, allocations
erp/backend/E310_statements.sql         statements, aging, journals, VAT summary, withholding
erp/backend/E400_fiscal.sql             provider_accounts, fiscal_outbox, fiscal_events, submit / apply
erp/backend/E500_reports_export.sql     rpt_erp_* views, accountant pack
erp/backend/E600_lots_units_prices.sql  lots / FEFO, alternative units, price lists, valuation switch
erp/backend/E900_integration.sql        OPTIONAL Integration Pack (06 section 3); NOT built unless Fable opens phase IP
                                        (IP6 card-materials facade: 07; core readiness items: 07 section 5, built in T02 / T09 / T10 / T12 / T14)
erp/backend/README.md                   run order, which file redefines what
erp/backend/API.md                      contract for the front-end, one section per file
erp/backend/tests/E1NN_*_tests.sql      one suite per SQL file (begin ... rollback)
erp/backend/tests/golden/               valuation cases as CSV (input moves, expected avg / FIFO)
erp/backend/tests/load/                 gen_erp_load.sql, measure_erp.py, RESULTS.md
erp/backend/tests/ui/                   Playwright smoke + mock_supabase_erp.js
erp/backend/run_erp_tests.sh            runs all E files and suites TWICE, exits 1 on failure
erp/app/00_core.js 10_master.js 20_documents.js 30_stock.js 40_purchasing.js 50_sales.js 60_money.js
        70_fiscal.js 80_reports.js 90_admin.js    strings.en.js    erp.css    shell.html
erp/build_erp.py                        shell.html + css + strings + app/*.js (name order) -> erp.html (repo root)
backend/supabase/functions/erp-*/       Edge Functions, NEW folders only; shared code in _shared/erp-providers/ (new)
```
- Numbers: steps of 10 inside a block (E1xx stock, E2xx trade, E3xx money, E4xx fiscal, E5xx reports, E6xx depth).
  A fix goes into the file that owns the object; a new file only for a new feature.
- **CRM is OFF LIMITS (owner decision)**: never edit `app.js`, `index.html`, `build_index.py`, `schema.sql`,
  `rls.sql`, `functions.sql`, `backend/*.sql` 010-190, `run_db_tests.sh` or existing Edge Functions. They may be
  READ as style reference only.
- Run order: E files in name order, on a database with OR without the CRM. No E file may read, create, alter,
  reference or grant on anything in `public` or `app`. `build_erp.py` is deterministic (same input = same bytes) and prints the size; `erp.html` is
  committed. No Netlify build step or function.

## 2. Recipe: implementing one document type
Do the steps in this order; one PR may hold one document type or two closely related ones.
1. **Catalogue row**: read the type's row in 01 C. Insert its `doc_types` row (code, direction, stock sign, money
   effect, fiscal flag, needs counterparty, needs approval rule) and its `doc_transitions` rows (02). Seed with
   `on conflict do nothing`; changes to seeded rows use an explicit `update ... where` guarded by a version column.
2. **Tables**: use `documents` / `document_lines`. Type-specific header fields go in ONE typed side table
   `erp.doc_<code>` (tenant_id, document_id PK) only when the field is queried or validated; otherwise in
   `documents.extra jsonb` with a documented key list. Never add a nullable column to `documents` for one type.
3. **Validation**: `erp.doc_<code>_validate(id) returns jsonb` (array of `{code, line_no, field, message}`): ALL
   problems at once. Called by save (warnings) and by post (blocking).
4. **Draft RPC**: `erp_api.doc_save_draft(p_type, p_doc jsonb, p_idempotency_key)` is generic; add the type's
   field whitelist to its table-driven map. No per-type save function unless Fable agrees.
5. **Posting**: add the type's branch to `erp.post_document` ONLY as data where possible (stock sign, cost source,
   money effect come from `doc_types`); special behaviour (transit, variance, cost correction) is one internal
   function `erp.post_<code>(doc)` called from it. Posting = one transaction: lock (02 order), validate, number,
   moves + balances + cost, open amount, state, audit.
6. **Cancel / void**: reversing moves and allocations with `reverses_id`; refuse when a later document depends on it
   (`ERP_DOC_HAS_CHILDREN`) or the date is locked.
7. **Conversion** (02 "Document conversion", 01 C5): add the type's rows to `erp.doc_conversions` (seed); NO
   per-type convert function: everything goes through `erp_api.doc_convert` / `doc_copy`. Target lines carry
   `source_line_id`; remaining and source status come from `v_line_remaining`, never from a stored counter. If the
   pair is `stock_by_source`, prove with a test that posting the target writes zero stock moves.
8. **Tests** (section 5): state machine, role matrix, tenancy, numbering, stock and cost effect with a golden case,
   cancel symmetry (post + cancel leaves balances, layers and average exactly as before), idempotency.
9. **API.md**: signature, roles, error codes, example payload and reply.
10. **Screen**: list (keyset paging, filters) + drawer (header, lines grid, totals, state bar, actions from
    `doc_transitions` so the buttons match the server). Print template. Strings in `strings.en.js`. Smoke test.
11. **Load**: if the type adds a list or a posting path, add it to `measure_erp.py` and record in RESULTS.md.

## 3. SQL conventions
- **Idempotent**: `create table if not exists`, `create or replace function`, `drop policy if exists` + create,
  `alter table ... add column if not exists`. Every file runs twice in CI. One file owns each function; a later file
  that redefines it says so in its header and in erp/backend/README.md.
- **Header per file**: purpose, run order, what it redefines, its test suite.
- **Naming**: snake_case, singular columns, `_id` suffix, `tenant_id` first in every primary key and index.
- **Functions**: `erp_api.*` = `security definer`, `set search_path = ''`, every object schema-qualified, first lines
  `perform erp.require_member();` then `erp.can('<capability>', branch)`. Internal `erp.*` functions are NOT
  executable by `authenticated` (`revoke all ... from public`). Never `security definer` + dynamic SQL from input.
  Mark `stable` only when truly read-only.
- **Grants**: schema `erp`: `usage` to authenticated, `select` on tables only through RLS, NO insert / update /
  delete grants to anyone but the owner role. Schema `erp_api`: `execute` granted per function explicitly
  (`revoke execute on all functions ... from public` at the top of each file). Secrets tables: no grants.
- **RLS, fast form**: enabled + forced on every table. Policy:
  `tenant_id = any ((select erp.my_tenants())) and ((select erp.is_owner()) or branch_id = any ((select erp.my_branches())))`;
  tenant-wide tables use the first clause only. Helpers always inside `(select ...)`. An index starting with
  `tenant_id` must serve every policy.
- **Locks**: numbers only through `erp.next_number`; item costing under the per-item `pg_advisory_xact_lock` (02);
  stocktake start / approve and recost take the same item locks; queues use `for update skip locked`. Never
  `lock table`. Keep lock order: series, items ascending, balances.
- **Money and time**: types as in 02; no `float`; no `now()` for document dates (use `erp.today(tenant)`).
- **Writes**: only inside RPCs; each takes `p_idempotency_key uuid`, stores it unique per tenant, and returns the
  stored result on a repeat. Each write calls `erp.audit(...)`.
- **Errors**: `raise exception using errcode = 'P0001', message = 'ERP_<CODE>: <English sentence with values>'`.
  The page maps the code to a string key and falls back to the sentence. New codes are added to API.md.

Error codes (initial set): `ERP_AUTH` (not a member), `ERP_FORBIDDEN` (role / branch), `ERP_TENANT` (cross-tenant
id), `ERP_VALIDATION` (array attached in `detail`), `ERP_STATE` (transition not allowed), `ERP_LOCKED_PERIOD`,
`ERP_STOCK_NEGATIVE`, `ERP_LOT_REQUIRED`, `ERP_LOT_EXPIRED`, `ERP_STK_FROZEN`, `ERP_DOC_HAS_CHILDREN`,
`ERP_DOC_IMMUTABLE`, `ERP_SERIES_MISSING`, `ERP_ALLOC_OVER` (allocation above open amount),
`ERP_LIMIT` (plan hook), `ERP_IDEMPOTENT_MISMATCH` (same key, different payload), `ERP_FISCAL_PENDING`,
`ERP_FISCAL_REJECTED`, `ERP_RECOST_PENDING` (valuation switch blocked). Warnings are not errors: RPCs return `warnings[]` (first code:
`W_STOCK_NEGATIVE`, 02) and post only with `p_ack_warnings = true`.

## 4. Front-end conventions
- Plain JS like app.js, sections marked `/* ---------- name ---------- */`, no framework, no CDN beyond supabase-js.
- All calls through `api(name, args)` in 00_core.js (adds idempotency key, maps errors, 8 s timeout). No table reads
  from the page except through RPCs.
- English-only UI, no literal text in code: `t('doc.post.confirm', {no})`. Dates dd/mm/yyyy, money `€#,##0.00`.
- Every write button: disabled while running, shows "Not saved" on error or 0 rows, unsaved-changes guard on drawers.
- Buttons and visible columns come from the server (`whoami().caps`, `doc_transitions`); hiding a button is never
  the security control.
- Conversion: the drawer header of a posted document shows "Convert to" (menu of the allowed targets from
  `doc_conversions` + caps, with a line picker and remaining quantities) and "Copy"; a list multi-select offers
  N:1 ("Invoice selected delivery notes"). Badges open / partial / full; links "Created from" / "Converted to".
- No secret, provider key or service-role key in any front-end file or in localStorage.

## 5. Test templates
SQL suites follow the CRM pattern (`t.passes`, a final count check, transaction + rollback). Required suites:
- **Tenancy (generated)**: for EVERY table in `erp` from the catalog: RLS enabled and forced, a policy exists, member
  of tenant A reads 0 rows of tenant B, and every `erp_api` function given a tenant-B id raises `ERP_TENANT` or
  returns nothing. A new table or function without coverage fails the suite.
- **Roles**: one loop over `role_caps` x RPC: allowed roles succeed, the others get `ERP_FORBIDDEN`; branch scoping.
- **Posting**: per document type: effect on balances, moves, open amount; cancel symmetry; immutability trigger.
- **Valuation golden cases** (`tests/golden/*.csv`, worked by hand by Fable, Opus never edits expected values):
  G1 simple buy / sell; G2 three receipts at different prices then partial issues (average and FIFO differ);
  G3 quantity to zero and rounding residue; G4 customer return linked and unlinked; G5 supplier return;
  G6 price correction by PINV after partial consumption; G7 negative stock under `warn` then cover; G8 backdated
  receipt with recost and `cost_revisions`; G9 lot-tracked item, FEFO issue; G10 transfer (cost unchanged, transit
  zero); G11 stocktake variance; G12 switch average -> FIFO and FIFO -> average (rebase, values equal at cut-over).
  Each case asserts qty, value_avg, value_fifo, layers left, and the integrity job result.
- **Conversion golden cases** (`tests/golden/conv_*.csv`, by Fable): V1 DN -> SINV full (totals and VAT equal to
  the cent, zero new stock moves, DN `full`); V2 DN -> RR partial 6 of 10, then 4 (`partial` -> `full`); V3 second
  conversion of a full source and qty above remaining both refused; V4 cancelled / deleted target restores the
  remaining qty and the badge; V5 three DN -> one SINV, other counterparty refused; V6 SQ -> SO -> DN -> SINV -> CRN
  chain (stock moved once, reservation released, chain view complete); V7 PO -> GRN -> PINV (stock once, cost
  correction) and REQ -> PO / TRF; V8 two sessions convert the same DN at once: one succeeds; V9 invoice mixing DN
  lines and free lines moves stock only for the free lines.
- **Numbering / concurrency**: pgbench, 50 clients, 2 minutes, posting to one series and 5 hot items: zero gaps,
  zero duplicates, zero deadlocks, balances = ledger, layers = on hand. Plus a rollback test (failed post returns
  the number).
- **Fiscal**: mock provider scenarios (04): success, validation reject, timeout then issued, duplicate submit, late
  webhook, cancel.
- **Standalone**: all E files + suites pass on an EMPTY database with no CRM objects; on a database with the CRM
  loaded, the CRM suites (run, never edited) are green before, after, and after `drop schema erp cascade`.
- **Load** (`gen_erp_load.sql`, deterministic seed): 20 tenants; the standard tenant has 5,000 items, 10 warehouses,
  20,000 documents, 100,000 stock moves; one stress tenant has 10x. Targets, warm cache, as a `warehouse` member
  under RLS, p95: item search / on-hand lookup <= 150 ms; document list page <= 200 ms; open a 20-line document
  <= 150 ms; post a 20-line document <= 300 ms (stress tenant <= 500 ms); stock card of one item <= 200 ms; aging
  and VAT summary for a year <= 1 s; stock value at a date <= 2 s; recost of an item with 2,000 later moves <= 2 s;
  CRM board timings unchanged (re-run the CRM load test). Results in RESULTS.md with the commit hash.
- **Playwright smoke**: per screen with the stubbed client: open list, open drawer, save draft, post (stub), error
  path shows "Not saved"; phone viewport for scan, count and consume screens.

## 6. Definition of done (per task)
1. `bash erp/backend/run_erp_tests.sh` passes twice, in both modes (empty DB; DB with CRM, CRM suites still green).
   `git diff --stat` shows no CRM file.
2. API.md section written. 3. Screen works against the mock and a local DB; smoke test added.
4. Load numbers recorded when a table, index, list or posting path changed. 5. No new string outside
`strings.en.js`; no `TODO` left without a task number. 6. `ARCHITECT_STATE.md` ERP block updated (max 5 lines).
7. PR description lists: files, decisions taken, open questions, what Fable must review. 8. Nothing applied to live.

## 7. Review gates (Opus stops and waits for Fable)
- Before coding a phase: the table design (columns, keys, indexes) as a short markdown note in the PR.
- Before merge, always: every RLS policy and grant; `post_document`; `next_number`; valuation and recost; the
  golden-case results; `doc_transitions` seeds; any Integration Pack file; the adapter interface; anything touching secrets;
  any change to a posted-document rule.
- Before live (checkpoints F1-F7 in 05): Fable reads the diff since the last checkpoint, the test and load output,
  and writes the live run list (files in order, dashboard steps, rollback). The owner applies; never Opus.
- Opus never changes a decision of 01 / 02 / 04 / 06 silently: it proposes in the PR, Fable updates the doc first.

## 8. Commits and PRs
- Work on branch `erp-dev` (pushes to `main` deploy the Netlify site and cost credits). One task = one PR into
  `erp-dev`, title `ERP T<nn>: <what>`; merge to `main` only at a Fable checkpoint, as one batch.
- Small commits, message = what and why; SQL, tests and API.md of a change in the same commit. Never commit
  secrets, dumps with real data, or `erp.html` built from uncommitted sources.
- No ERP PR contains a CRM file. If a task seems to need one, STOP and ask Fable (it becomes a CRM-project task).

## 9. Opus must NEVER
1. Touch the live database, the Supabase dashboard, Netlify settings or any real provider account.
2. Edit ANY CRM file (`app.js`, `index.html`, `build_index.py`, `schema.sql`, `rls.sql`, `functions.sql`,
   `backend/*.sql` 010-190, `run_db_tests.sh`, existing Edge Functions), or read, alter, grant on, reference or add
   a trigger / foreign key / view / policy to any CRM object (`public`, `app`). Build nothing of phase IP unasked.
3. Update or delete a posted or issued document, a stock move quantity, an allocation, an audit or fiscal event
   row; "fix" data with a direct UPDATE instead of a reversing document.
4. Put provider credentials, service-role keys or webhook tokens in front-end code, SQL files, tests or logs.
5. Call myDATA / AADE directly, or mark a document issued without a provider reply.
6. Put patient ids, names, phones or any health data into `erp` tables, logs, test fixtures or exports.
7. Take a number outside `erp.next_number`, or cost a move outside `post_document` / `recost_item`.
8. Edit golden expected values, weaken a test to make it pass, or skip the second run.
9. Add a dependency, framework, CDN, build step or Netlify function.
10. Decide a legal, tax or accounting question: mark it "accountant" and ask.
