# ERP checkpoint F2: independent review of E2 (T05-T15, T44)

Date 2026-11-19. Reviewer: independent Opus 5.5 run (did not write the E1 / E2 code; did not trust its tests or golden
values). Branch `erp-dev`, base bb74fe6. Scope (05 F2): numbering, `post_document`, golden cases, negative-stock
warning path, recost, load numbers; plus the hunt list of the F2 brief (tenancy / roles on every new RPC, definer
search_path and grants, idempotency, numbering under concurrency, immutable ledger, state machine, lock-date bypasses,
recost with average and FIFO layers, negative stock then late receipt, rollback atomicity, integrity job, RLS form,
performance traps). Read: README, 02, 03, 05, STATE (assumptions 1-70, O1-O6), REVIEW_F1, E120-E150 + E135, every
suite, the load kit and RESULTS.md. Nothing was applied to live; no CRM file was changed.

## 1. Verdict: PASS WITH FIXES. Pilot: GO after G1 (and C0), with the C1 run list of section 6

The document core and the stock engine are sound. Numbering is gapless under concurrency (8-session script + the
50-client pgbench run), every new RPC is covered by the generated tenancy / role suite, every definer function pins
`search_path = ''`, the ledger has no update / delete path, and the costing engine is CORRECT against an independent
model on 7,000+ differential checks (section 3). The review found 7 defects (0 critical, 0 high, 4 medium, 3 low) and 8
info items; all 7 defects are fixed on `erp-dev` with tests that fail on the old code (section 2). F2-01 is O2.

The pilot (C1 opening stock, C2 one clinic with GRN / CONS / ADJ) may start once gate G1 (nightly external dump,
tested restore, keep-alive) is met and C0 (REVIEW_F1 section 4) is done. TRF / STK of 06 step C2 are E3 (T16-T18,
F3): the C2 pilot runs without them until F3.

Counts: medium 4 (F2-01, F2-02, F2-03, F2-04), low 3 (F2-05, F2-06, F2-07), info 8 (F2-08 .. F2-15). Fixed: 7 / 7.

## 2. Findings

| id | severity | file / object | scenario | fix | test (fails on the old code) |
|---|---|---|---|---|---|
| F2-01 (O2) | medium | E140 `cost_move`, `stock_post` | An issue of an item with no cost history (negative stock before the first receipt) was costed FIFO at `items.last_purchase_price` read at REPLAY time, so any later replay (backdated post, cancel) re-costed an unchanged issue at a later price and wrote a `cost_revisions` row for it (RESULTS.md: 77 of 6,506 replayed moves); the official AVERAGE used 0 for the same issue (and an ADJ+ without cost used the current price), contrary to STATE 47 / `current_cost`. | New ledger input `stock_moves.fallback_cost` = the item's last purchase price when the move is posted (0 when none; never rewritten: the ledger guard covers it). Uncovered quantity of an item without cost history and an inbound without cost use it under BOTH methods. Moves posted before F2 (null) read the current price (none exist on live). | E142 "F2-01" (6 checks), golden R4, fuzz (43 mismatches on the old code, seed 1) |
| F2-02 | medium | E140 `recost_job`, `recost_run` | (a) The job locked queue rows (`FOR UPDATE SKIP LOCKED`) and then took the item lock; a backdated post takes the item lock and then upserts the queue row: deadlock (reproduced: `deadlock detected`, one side aborted). (b) One job transaction recosted up to 50 items and held every processed item's lock until it ended (minutes for large items): posts of those items waited past the 8 s RPC timeout. | `erp.recost_batch`: queue read without row locks, `pg_try_advisory_xact_lock` per item (busy item skipped, stays queued), no new item after a time budget (`recost_job(p_max, p_budget_ms default 3000)`, `recost_run` 3 s). Lock order item -> queue row everywhere. | `tests/concurrency_recost.sh` (deadlock on the old code), E142 "F2-02" (budget) |
| F2-03 | medium | E130 `post_document`, `cancel_document` | Write skew: `settings_save` locks the settings row and moves the lock date while a post of a date inside the new locked period reads the OLD date (plain read) and commits: a document posted / cancelled inside a period locked at the same moment (lock-date control bypass; the queue trigger cannot see the uncommitted queue row either). | Lock date read `FOR SHARE` in post and cancel: the post waits for the settings change and refuses (`ERP_LOCKED_PERIOD`), or the settings change waits for the post. | `tests/concurrency_lockdate.sh` (old code: the document is posted) |
| F2-04 | medium | E140 `stock_cancel`, `cost_replay`, `stock_post`, `stock_integrity`, `integrity_job` | (a) A cancel replayed every later move inline, without the 2,000 limit of 02 (hot item with 6,459 moves: 3.6 s; more: past the 8 s timeout, item locked meanwhile). (b) While an item waited in the queue from date D1, a cancel or an inline backdated replay from D2 > D1 started from a move whose running state did not contain the queued move: `item_costs` disagreed with the ledger until the job, and a nightly integrity run in between raised a FALSE critical alert. (c) Nothing detected a recost job that never runs (pg_cron step missing). | Cancel goes to the queue above the limit (cost row follows the reversal by its values); backdated post / cancel of an item already queued from an earlier date goes to the queue; `cost_replay` starts at the queued date when earlier; `stock_integrity` checks a queued item's cost state after the job; `integrity_job` raises `recost_stale` for a queue row older than 1 hour. | E142 "F2-04" (4 of 8 checks fail on the old code), fuzz queue mode |
| F2-05 | low | E130 `cancel_document`, E140 `stock_cancel_check` | Cancelling a consumed inbound document (GRN) took the stock negative silently: no warning, and it bypassed the `block` setting and the transit rule of 02. | `erp.stock_cancel_check` under the item locks: `ERP_STOCK_NEGATIVE` under `block` / transit; under `warn` the cancel goes ahead, the reply carries `warnings` (`W_STOCK_NEGATIVE`) and it is audited (`doc.cancel_negative_stock`). `cancel_document` returns the warnings (signature change handled idempotently). | E142 "F2-05" |
| F2-06 | low | E130 `doc_save_draft` | `source_line_id` was checked for the tenant only: a member could point a line at a line of a document of a branch / type it cannot read (cost of the source move for return types, remaining quantity of a conversion). Not reachable today (no real return or conversion pair is enabled before T23 / T45). | The source line's document must pass `doc_visible` (`ERP_FORBIDDEN`), as in `doc_convert`. | E142 "F2-06" |
| F2-07 | low | E140 `stock_post` | Every stock line counted ALL later moves of its item (unbounded `count(*)`) to compare with the inline limit. | `erp.later_moves` counts up to limit + 1. | E142 "F2-07" |
| F2-08 | info | E130 / E140 warning path | `ack_warnings` is a boolean, not bound to the warnings the user saw: a concurrent post can deepen the negative between the dialog and the confirm. The audit row records the warnings actually posted. Accepted (02 asks only for an acknowledgement). | - | - |
| F2-09 | info | E140 policies | A direct SELECT on `erp.stock_moves` returns cost columns to members without `cost.read` (warehouse). Not reachable: `erp` is not exposed and the RPCs filter by `cost.read` (same class as F1-16). | - | - |
| F2-10 | info | E130 / E135 policies | `document_lines` / `document_links` policies use a per-row EXISTS (not the fast form). Not on the API path (definer RPCs). Revisit if `erp` is ever exposed. | - | - |
| F2-11 | info | E140 `stock_integrity` | The integrity job does not compare document line costs with their moves (the fuzz does). Suggest adding at F3. | - | - |
| F2-12 | info | `erp/app/30_stock.js` | The cancel dialog ignores the new cancel `warnings` (server audits them and raises the alert). Show them with the T16 / T18 screens. | - | - |
| F2-13 | info | E130 `doc_set_state` | The approval condition (value vs threshold) is evaluated before the item locks; the cost can move by a concurrent post in between (cents). Accepted. | - | - |
| F2-14 | info | E135 | Conversion checks for FC (T44): drafts count in `remaining`, posting re-validates with all other targets: no over-conversion found. `stock_by_source` is not built (T45); V6, V7, V9 need the real types. | - | `golden/conv_cases.csv` |
| F2-15 | info | tests | A local database that collected dead tuples from many rolled-back fuzz runs planned the replay's layer give-back with stale statistics (minutes instead of seconds). Test-environment only; the runner vacuums before the fuzz. Live tables keep normal statistics. | - | - |

Checked and holding (no defect): `series_for` + `next_number` (row lock, number taken last, rollback returns it;
cancelled keeps the number; drafts / pending documents have none) and the pgbench run; idempotency (per-key advisory
lock, same member, warnings replies not stored); state machine (`doc_transitions` the only source; no row lets
`posted` / `cancelled` happen without its action; illegal moves `ERP_STATE`); approvals (OPN owner only, ADJ value
limit, cancel needs `.approve`); ledger guards (`stock_moves` cost columns only under `erp.recost`, no delete /
truncate; `stock_move_layers`, `cost_revisions` append-only); lock date never crossed by a replay; tenancy / roles of
every new RPC (generated suite E990 covers all 50 `erp_api` functions); definer functions pin `search_path`, internal
functions not executable by `authenticated`; rollback atomicity of a post failing after its number (E142).

## 3. Golden cases: independent re-computation

`tests/costing_model.py` is a reference model written by the reviewer from the RULES (02 "Valuation", E140 header,
STATE 46-49) without reading values from or calling the SQL; Decimal arithmetic, PostgreSQL half-away-from-zero
rounding. It re-computes every golden CSV from its INPUT columns. Every case was also worked by hand.

| case | checks | result |
|---|---|---|
| G1 simple buy / sell | 3 steps (qty, avg, FIFO, layers, move values) | equal |
| G2 three receipts, partial issues | 6 | equal (e.g. 134.23 / 123.00; 223.71 / 231.60) |
| G3 rounding residue | 6 | equal (3.34 on the second issue, residue on the last) |
| G4 customer return linked / unlinked | 6 | equal (linked FIFO 8.67 = 2 x 4.333333, layer 4.335) |
| G5 supplier return | 7 | equal |
| G7 negative stock, cover, correction | 5 | equal (corrections -3.00 / -3.00) |
| G8 backdated receipt | 4 final moves + state | equal (26.00 / 20.00, 19.50 / 15.00; 13, 84.50, 95.00, 3@5;10@8) |
| **total stored values** | **41** | **0 mismatches** |

New independent set (O3), `tests/golden/R1..R4.csv`, asserted by `tests/E142_f2_review_tests.sql` against the
database and re-computed by the model (79 checks with G*, 0 mismatches): R1 partial deficit cover then full cover
(corrections -3.30 and -4.00); R2 receipt backdated before the first receipt and an issue backdated between (FIFO order
changes, partly consumed layers; final 6, 14.60 / 12.00, 6@2); R3 cancel of the receipt that covered a deficit (the
deficit returns, the next receipt corrects -6.00); R4 provisional cost from the purchase-price snapshot (O2), supplier
return (final 13, 89.00 / 89.00, 5@5;8@8).

Differential fuzz (`costing_model.py fuzz`): random scenarios (receipts, purchase receipts that change the last
purchase price, issues into negative stock, linked / unlinked customer returns, supplier returns, backdated documents
up to 12 days, cancels, two warehouses) posted through the real RPCs; every posted move's values, unit costs,
corrections, line cost, final state, layers, integrity and cancelled-pair sums compared with the model. Old code: 43
mismatches in 328 checks (all O2 / average fallback). Fixed code: 0 mismatches in 5,294 checks (seeds 1-6, inline and
queue mode) + 2,026 (seeds 7-8); the runner now runs seeds 11 (inline, 60 scenarios) and 12 (queue, 40) every time.

Conversion golden V1-V9: `tests/golden/conv_cases.csv` (setup, action, expected values, status). V1 amounts / links,
V2-V5 and V8 are covered by E135 and `concurrency_convert.sh` (V2 values re-computed: 20.01 + 13.34 = 33.35, VAT
4.80 + 3.20 = 8.00, equal to the source). PENDING with their tasks: V1 "zero stock moves" and V9 (T45
`stock_by_source`), V6 (T46), V7 (T45 / T22). Checkpoint FC stays due before T45.

## 4. Decisions on open items

**O2 (decided, fixed: F2-01).** The provisional cost of an uncovered quantity is the method's last cost; when the item
has no cost history before the move, it is the item's last purchase price AS KNOWN WHEN THE MOVE WAS POSTED, stored on
the move (`stock_moves.fallback_cost`) as a costing input, under both methods (also for an inbound without cost). The
alternative "price as of the move date" was rejected: with no inbound before the move there is no dated price in the
ledger (it would mean 0), and any price read at replay time makes replays non-deterministic. A replay never changes a
move whose inputs did not change; the covering receipt's correction carries the difference to the real cost. The
change can move official (average) values only for issues of items with no cost history (before F2: 0), which are
flagged provisional and corrected by the next receipt. **Accountant**: confirm that a provisional cost at the last
purchase price is acceptable for consumption booked before the receipt.

**O1 (stress tenant, not measured): NOT required for the pilot.** iSmile (3 clinics) is expected to stay well below
the STANDARD tenant that was measured (5,000 items, 10 warehouses, 29,000+ documents, 130,000+ moves; every 03 target
met). Item-level paths (post, stock card, recost) do not grow with the number of items; lists are bounded by keyset
indexes. Required: (1) at C1, re-run the latency subset of `measure_erp.py` on the Supabase tier (O6) with the iSmile
data (post, lists, stock card through PostgREST); (2) the stress tenant (`STRESS=1`, about 5 h on this host) before
F9 / T43 (second tenant) or when any tenant passes half of the standard scale, whichever comes first; record it in
RESULTS.md.

O3: done (section 3; Fable / owner may still add their own set). O4 / O6: live steps, section 6. O5: FC still due.

## 5. Load numbers after the fixes

`measure_erp.py` re-run on the T15 load database (`erp_load`, 20 tenants, 50,867 documents, 238,655 moves) with the
F2 code (commit ac089e8); `tests/load/RESULTS.md` rewritten. Same host as T15 (2-CPU sandbox, server-side timings).

| metric (p95, ms) | target | T15 | F2 |
|---|---|---|---|
| post 20-line CONS / GRN | 300 | 39.2 / 33.2 | 38.9 / 35.1 |
| item lookup (worst of 4) / on hand (worst) | 150 | 7.5 / 39.3 | 8.4 / 37.9 |
| document list (worst) / open 20 lines | 200 / 150 | 10.9 / 8.0 | 9.6 / 10.5 |
| stock card (worst) | 200 | 13.8 | 23.1 |
| recost 2,000 later moves inline / queue (max) | 2,000 | 1,352.6 / 1,009.8 | 1,441.0 / 996.5 |
| pgbench 50 clients 120 s: failed / deadlocks / gaps / integrity problems | 0 | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 (3,684 tx, 3,364 posted, 320 rolled back) |

Every 03 target still met; the fixes cost nothing measurable (the extra `fallback_cost` read and the capped count are
per line). Not measured (unchanged from T15): the stress tenant (O1), aging / VAT summary / stock value at a date
(their features do not exist yet), on-tier timings (O6, at C1).

## 6. Live run list C1 (owner applies; never an agent). Preconditions: C0 done (REVIEW_F1 section 4) and G1 met

0. **Gate G1 (stop if any item fails)**: a nightly external `pg_dump` of the whole project to storage the owner
   controls is running; ONE restore has been tested into a scratch database (ERP tables and CRM tables present, row
   counts match); a keep-alive prevents pausing. Owner re-checks the free-plan terms on the Supabase pricing page.
   Take a manual dump right before step 1.
1. SQL editor, as `postgres`, whole files in order: `erp/backend/E120_master.sql`, `E130_documents_core.sql`,
   `E135_conversions.sql`, `E140_stock_engine.sql`, `E150_stock_docs.sql` (E100 / E110 were applied at C0; re-running
   them is safe). Each must end without error.
2. pg_cron (as `postgres`): `select cron.schedule('erp-recost', '*/5 * * * *', 'select erp.recost_job()');` and
   `select cron.schedule('erp-integrity', '17 2 * * *', 'select erp.integrity_job()');`. Check:
   `select jobname, schedule from cron.job where jobname like 'erp-%';` -> 2 rows. (If pg_cron is not enabled: Database
   > Extensions > pg_cron first. Without the recost job a queued item raises `recost_stale` at night.)
3. Settings (owner, Admin screen): negative stock `warn`, lock date empty, `thresholds.adj_value` as agreed with the
   accountant; Master data > Series: "Create defaults" for each clinic branch (GRN, CONS, ADJ+, ADJ-, OPN).
4. Master data: items (CSV import, dry run first), suppliers; warehouses per clinic.
5. First stocktake per pilot clinic, then the opening stock CSV (`opening_import`: dry run, then the OPN draft); the
   owner posts OPN after signing the counted quantities (06 C1).
6. Checks in the SQL editor: `select erp.integrity_job();` -> `with_problems: 0`;
   `select count(*) from erp.recost_queue;` -> 0; spot-check 5 items: on hand = counted, value = qty x unit cost.
7. C2 pilot in ONE clinic (2-4 weeks): GRN, CONS (clinic staff), ADJ; weekly count of 20 items; weekly review of the
   negative-stock report and of any `integrity` alert (critical = stop and call Fable). TRF / STK wait for F3.
8. O6 at C1: run the latency subset of `measure_erp.py` against the live tier (read-only RPCs + one post / cancel of a
   test document in a TEST branch) and append to RESULTS.md.
Rollback: the manual dump of step 0. ERP-only rollback before real use: `drop schema erp_api cascade; drop schema erp
cascade;` (CRM untouched, tested locally); unschedule the two cron jobs (`select cron.unschedule('erp-recost');`,
`select cron.unschedule('erp-integrity');`).

## 7. Files changed by the review

`erp/backend/E130_documents_core.sql` (F2-03, F2-05, F2-06), `E140_stock_engine.sql` (F2-01, F2-02, F2-04, F2-05,
F2-07), `run_erp_tests.sh` (new checks), `API.md`, `README.md`; new tests `tests/E142_f2_review_tests.sql`,
`tests/costing_model.py`, `tests/concurrency_lockdate.sh`, `tests/concurrency_recost.sh`, `tests/golden/R1..R4.csv`,
`tests/golden/conv_cases.csv`; `tests/load/RESULTS.md` (re-run). Runner: `bash erp/backend/run_erp_tests.sh --all`
green (both modes, suites twice, CRM suites 20/20 before / after / after drop); `bash run_db_tests.sh` green.
