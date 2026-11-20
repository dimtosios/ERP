## How to re-run

    bash erp/backend/tests/load/run_erp_load.sh erp_load full      # builds the scratch DB (about 50 min on 2 CPUs)
    python3 erp/backend/tests/load/measure_erp.py --db erp_load     # timings, pgbench, checks; rewrites this file

`STRESS=1 bash run_erp_load.sh ...` also builds the stress tenant (10 x the standard one: 50,000 items, 100 warehouses,
200,000 documents).
`measure_erp.py` builds the recost probe item once; every run adds 50 x 20-line documents and the pgbench documents.

## Deviations from 03 section 5 "Load" (recorded for F2)

1. **No stress tenant in this run.** The generator posts every document through the real `doc_set_state` path (about
   11 documents per second on this 2-CPU sandbox), so 200,000 documents would take about 5 hours. The tenant is in
   the generator (`STRESS=1`); the "post <= 500 ms on the stress tenant" target is NOT measured. Data per item does not
   grow with the number of items (the locks and indexes are per tenant and item), so the item-level paths (post,
   stock card, recost) are expected to stay near the standard numbers; the list paths are bounded by their indexes
   and page size. This is an expectation, not a measurement.
2. **20 tenants** = the platform tenant + `load_std` + 18 small tenants (500 items, 2 warehouses, 1,000 documents each).
3. **Not applicable yet**: aging and VAT summary for a year (sales / purchase invoices come with E3 / E4), stock value
   at a date (the valuation report comes with T16+). They are added to `measure_erp.py` with their tasks (03 section 3
   step 11).
4. **Timings are server-side** (inside the database). The browser, PostgREST and the network add their own time on
   live; the real-DB Playwright smoke covers the path end to end but is not a timing.
5. **CRM board timings**: see "CRM load test" below.
6. The document mix of the generator puts every type in one or two branches (warehouse = 7g mod 10): some series of
   load_std are empty (e.g. ADJ_IN-BR2). It does not change the timings (lists filter by tenant / branch through indexes).

## Finding: posting several documents in one transaction can deadlock

While the generator was posting (250 documents per transaction, as the owner), a measurement session posting one
document in the same tenant got `deadlock detected` on `erp.tenant_usage` (the per-month document counter that
`post_document` bumps last). The batch transaction already held the usage row and then waited for the series / item
locks the single post held. The app never posts more than one document per transaction (every RPC is one
document), so the lock order series -> items -> balances -> usage row holds and the pgbench run below shows no
deadlock. The rule is now written next to `erp.post_document` (E130): one document per transaction; a future batch
post (e.g. a recurring-documents job) must commit per document or take the tenant's usage row first.

## Recost speed-up made in T15

The first run measured 2.3-2.9 s (inline backdated post) and 2.6-2.7 s (queue) for 2,000 later moves: over target.
Cause (per-statement timings with auto_explain): a replay updated the SAME item_costs row and the SAME partly consumed
FIFO layer once per move inside one transaction; each update walks the row's version chain, so the cost grew with
the square of the moves. E140 now carries the running cost state and the "head" layer in transaction settings
(`erp.replay_state`, `erp.replay_head`) and writes them once at the end of the replay; each move is written with one
update; open layers are read in index order. Same values: the golden suite (G1-G8) and a new check (G2 / G4 / G5
replayed from their first date give identical moves, running state, layers and cost rows) pass; a mutation without
the final write fails the suite. Larger replays are now linear: the hot item IT000001 (6,459 moves after pgbench)
replays in 3.6 s (queue path, no statement timeout in the job).

## Finding for F2: FIFO provisional cost uses the item's CURRENT last purchase price

Replaying the hot items from their first date (everything else equal) changed the FIFO value of 77 of 6,506 moves
(the official average values did not change): an issue into negative stock before any receipt takes its provisional
FIFO cost from `items.last_purchase_price` when no layer / last FIFO cost exists, and on a replay that field already
holds a LATER purchase price. The value-only corrections and the final state agree (integrity clean), but a replay is
not strictly deterministic for FIFO in that case. Not changed in T15 (engine semantics; golden cases do not cover
it); proposed fix: on a replay use the last purchase price as of the move date (or 0, as the average path does).

## CRM load test (03: "CRM board timings unchanged")

`backend/tests/load/measure.py` (the CRM harness, run unchanged, output outside the repo) on the CRM scratch database
`ismile_load` (5,150 cards; no ERP) twice, and on a copy of it with all ERP E files loaded (`ismile_load_erp`, dropped
afterwards): 25 queries x 4 roles = 100 pairs, median of 3, EXPLAIN ANALYZE as `authenticated` under RLS.

| comparison | median ratio | min / max ratio |
|---|---|---|
| baseline run 2 / baseline run 1 (noise) | 0.985 | 0.61 / 1.65 |
| with ERP / baseline run 2 | 1.040 | 0.66 / 1.62 |

Plans unchanged: the large sequential scans are the same in all 100 pairs; shared-buffer hits differ by 0 to 88 per
query (catalog look-ups of a larger catalog). Sum of medians 7,323 ms -> 7,637 ms. Two pairs crossed 300 ms with
the ERP loaded (B2 / B3 manager: 300.5 / 314.6 ms; baselines 278.2 / 307.3 and 280.7 / 294.4 ms). Reading: no change beyond the
run-to-run noise of this host; a 4 % planning overhead cannot be excluded at this sample size.
