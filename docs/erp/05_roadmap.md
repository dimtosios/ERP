# 05. Roadmap (rev. 4, after the owner's decisions of 2026-11-16)

Effort: S = 1-2 Opus runs, M = 3-5, L = 6+. Each task below is sized for ONE Opus run (SQL + tests + API.md, or one
screen group). Multi-tenancy is in from T02. Order is binding unless Fable changes it here.
The ERP is standalone: no task edits a CRM file or reads a CRM table (06 section 1).

## Go-live gates
- **G1 (before any real stock data on live, step C1 of 06)**: Supabase stays on the free plan (owner decision), so:
  a nightly external `pg_dump` of the whole project to storage the owner controls, a restore tested once into a
  scratch database, and a keep-alive so the project is not paused for inactivity. (Free-plan limits, pausing and
  backup terms change: **owner verifies on the Supabase pricing page**.) Without G1 the ERP stays in demo data.
- **G2 (before the first fiscal document)**: Supabase Pro with backups / PITR, provider contract + sandbox sign-off,
  accountant's mapping (VAT classes, income classification, series, establishment numbers), declaration of the
  issuing channel to AADE. No alternative to Pro here.

## Phases
| Phase | Delivers | Effort | Tasks | Checkpoint |
|---|---|---|---|---|
| E0 | Skeleton, tenancy, roles, member invitations, standalone install test, empty app shell | M | T01-T04 | F1 |
| E1 | Master data + CSV import | M | T05-T08 | - |
| E2 | Document core, stock engine (official average, FIFO kept), OPN, GRN, ADJ, CONS, negative-stock warning, stock screens | L | T09-T15 | F2, then G1 and pilot (C1-C2) |
| E3 | Transfers with transit and receipt confirmation, stocktake | M | T16-T18 | F3 |
| E4 | Expenses: categories, EXP document, recurring templates, screens, expense reports | S | T19-T20 | F4 (C3) |
| E5 | Purchasing: PO, GRN from PO, PINV, PCRN, PRET | M | T21-T24 | - |
| E6 | Sales, non-fiscal: SQ, SO + reservations, DN, SINV, SVC, CRN, RR, RS, RCR, print / PDF / email | L | T25-T28 | F5 |
| E7 | Money: RCPT, PAY, MTR, CBAL, allocation, journals, statements, aging, VAT summary, accountant pack | M | T29-T32 | F6 (C4) |
| E8 | Fiscal: outbox, mock, first provider on sandbox, dashboard; delivery notes and transfers first | L | T33-T36 | F7, then G2 (C5) |
| E9 | Depth: lots / expiry, alternative units, price lists, valuation switch + reports, scanning, reports pack | M | T37-T41 | F8 |
| E10 | Second tenant: onboarding wizard, plan hooks enforced, platform admin | M | T42-T43 | F9 |
| IP | OPTIONAL Integration Pack (06 sections 3-4): inbound receipts -> provider, members import, suite counterparty pull (06 section 6). OFF by default, never required, NOT scheduled; opened only by an explicit owner decision | S-M | none yet | owner + Fable |
**Ready-for-IP6 additions to core tasks (07 section 5; small, no CRM contact)**: T02 role / capability tables can
hold a facade-only role; T09 `documents.client_key` + `source`, unique per tenant, honoured by every posting RPC;
T10 / T14 item-lookup (search + barcode) and availability-per-warehouse read models with `low` / `negative` flags;
T12 `ext_ref` on CONS header, `ext_line_ref` on lines, line costs in the post reply, CONS reversal document.
Phase IP tasks for the CRM card Materials table: IP-T1..IP-T8 and checkpoints FI1-FI3 in 07 section 6 (not scheduled).
E5 does not depend on E4; EXP payments arrive with E7. E7 can run in parallel with E8 once E6 is merged. Later: second provider, SoftOne /
Entersoft layouts, Phase B receipt data, serials, landed costs, AI reports over ERP views.

## Opus task list
(The overdue-instalment SMS is a CRM-project feature with its own plan, docs/SMS_OVERDUE_PLAN.md; not an ERP task.)
1. **T01** Repo skeleton: folders, `build_erp.py`, `run_erp_tests.sh` (own runner, no CRM file touched), README,
   empty `erp.html` shell with its own login form (Supabase Auth) that shows "no access" for non-members.
2. **T02** E100 tenancy: tenants (tenant #1 seed), branches, members, `role_caps`, settings, alerts, audit, helpers
   `my_tenants` / `my_branches` / `is_owner` / `can`, `whoami`; generated tenancy suite.
3. **T03** E110 members: invite by email, first-login binding, tenant #1 onboarding seed; standalone tests (empty
   database without CRM objects; with CRM loaded: CRM suites green, also after `drop schema erp cascade`).
4. **T04** App core: `api()`, error mapping, strings, nav, role guard, admin screen (members, branches, settings).
5. **T05** E120 part 1: units, VAT classes, categories (valuation override column), items, barcodes.
6. **T06** E120 part 2: warehouses + transit, counterparties (tax ID checksum, `ext_ref`), series setup.
7. **T07** Master data screens (lists with keyset paging, drawers).
8. **T08** CSV import (items, counterparties) with dry run and error list.
9. **T09** E130 documents core: `doc_types`, `doc_transitions`, `doc_set_state`, `next_number`, generic draft save,
   immutability trigger; numbering concurrency test.
10. **T10** E140 stock engine: moves, balances, layers, `item_costs`, `post_document`, average + FIFO; golden G1-G5.
11. **T11** OPN and GRN (without PO) + opening-stock CSV import.
12. **T12** ADJ+ / ADJ- with approval threshold, CONS (cost centre, `ext_ref`); negative stock: `doc_check`,
    `warnings[]` + acknowledge, `negative_stock` alert, `rpt_erp_negative_stock`; G7.
13. **T13** Lock date, backdating, `recost_item` + queue, `cost_revisions`, nightly integrity job; G3, G8.
14. **T14** Stock screens: on hand, stock card, document list / drawer for OPN, GRN, ADJ, CONS, low-stock and
    negative-stock alerts, warning dialog, negative-stock report.
15. **T15** Load generator + first RESULTS.md run + pgbench concurrency run.
16. **T16** E160 TRF internal: dispatch, transit, receipt confirmation, difference -> ADJ approval; G10.
17. **T17** E170 STK: freeze, counting sheets, recount, approve / abort, variance ADJ; G11.
18. **T18** Transfer and stocktake screens (phone layout for counting).
19. **T19** E180 expense categories (tree, default VAT), EXP document (AP or paid on the spot with a PAY stub until
    T29), approval limit, attachment, recurring templates; suite.
20. **T20** Expense screens (list, drawer, categories admin), alerts screen, expenses-by-category / supplier report.
21. **T21** E200 PO (approval, partial fulfilment) and GRN from PO lines.
22. **T22** PINV (with / without GRN), price correction of layers, PCRN; G6.
23. **T23** PRET as non-fiscal draft with delivery block; G5 extended.
24. **T24** Purchasing screens, unbilled-receipts and open-orders reports.
25. **T25** E210 SQ, SO; E220 reservations.
26. **T26** DN, SINV (bills DN or combined), SVC, CRN: non-fiscal, numbered, watermark; G4.
27. **T27** RR, RS, RCR with payment method (auto RCPT stub until T29).
28. **T28** Sales screens, print / PDF templates, email send (Edge Function `erp-mail`, provider chosen by Fable).
29. **T29** E300 accounts, RCPT, PAY (approval limit), allocation (PINV, EXP), advances.
30. **T30** MTR, CBAL, cash / bank journals, daily cash close.
31. **T31** E310 statements, aging, VAT summary, withholding field + summary; money screens.
32. **T32** E500 accountant pack CSV (documents, lines, expenses, VAT, money), document register / gap report.
33. **T33** E400 `provider_accounts`, `fiscal_outbox`, `fiscal_events`, `doc_submit`, worker, mock provider + all
    scenarios (04).
34. **T34** Adapter for provider #1 against its sandbox + contract tests (needs the provider chosen).
35. **T35** Credentials function (write-only), fiscal dashboard, webhook + poll functions.
36. **T36** Fiscal switch per document type: DN and TRF between establishments first, then SINV / SVC / CRN, then
    retail; provider PDF in print / email.
37. **T37** E600 lots / expiry / FEFO, expiry alerts; G9.
38. **T38** Alternative units, price lists, supplier item codes.
39. **T39** Valuation switch wizard, valuation-at-date and average-vs-FIFO reports; G12.
40. **T40** Phone-camera barcode scanning for GRN, TRF, STK, CONS.
41. **T41** Reports pack (margin, slow movers, purchases / sales by dimension), `rpt_erp_*` views.
42. **T42** Onboarding wizard, plan hooks enforced (`check_limit`), platform admin (tenant list, usage).
43. **T43** Second tenant on live; isolation re-check with two real tenants.

**Conversion tasks (owner decision B; each runs inside the phase named, before that phase's screens)**
44. **T44** (E2, after T09) `doc_conversions` seed table, `source_line_id`, `document_links`, `v_line_remaining`,
    source-status view, `erp_api.doc_convert` / `doc_copy` with locking and idempotency; suite with two dummy types.
45. **T45** (E5) REQ type (01 C3); pairs REQ -> PO / TRF, PO -> GRN / PINV, GRN -> PINV / PRET, PINV -> PCRN / PRET;
    `stock_by_source` in `post_document`; golden V7.
46. **T46** (E6) pairs SQ -> SO / DN / SINV / SVC / RR / RS, SO -> DN / SINV / RR, DN -> SINV / RR (N:1), credits;
    `cp_snapshot`; golden V1-V6, V8, V9.
47. **T47** (E6, with T28) UI: "Convert to" menu + line picker, "Copy", N:1 from the list, badges, chain view; smoke.
48. **T48** (E8, with T36) fiscal targets from conversions: source references in the provider payload, provider
    cancellation restores remaining; mock scenarios.

## Fable review checkpoints
| # | After | Fable checks | Output |
|---|---|---|---|
| F1 | T04 | tenancy, RLS, grants, invitations, standalone install, no CRM file or object touched | live run list for C0 |
| F2 | T15 | numbering, `post_document`, golden cases, negative-stock warning path, recost, load numbers | pilot go / no-go (needs G1) |
| F3 | T18 | transit always zero for closed transfers, stocktake freeze, approvals | all clinics |
| F4 | T20 | expense document rules, categories, VAT fields (with the accountant) | expenses on |
| FC | T44 | conversion model: remaining view, locking, `stock_by_source`, seeds (Fable writes V1-V9 first) | T45-T47 may start |
| F5 | T28 + T45-T47 | document conversions, reservations, print templates, state tables | sales (non-fiscal) on |
| F6 | T32 | allocation rules, pack contents (with the accountant) | C4 date |
| F7 | T36 | adapter contract, idempotency, secrets, mock scenario results, sandbox documents | G2 list for the owner |
| F8 | T41 | valuation switch on a copy of live data, lots, performance re-run | - |
| F9 | T43 | isolation with two real tenants | second tenant go-live |
Fable writes the golden CSV cases before T10 and the table-design notes before each phase starts.

## Risks
1. Legal rules keep moving (deadlines changed several times in 2025-2026 [L1][L2]): fiscal logic stays inside the
   provider; re-check before E8.
2. No backups on the free plan: G1 / G2 above. A lost stock ledger cannot be rebuilt from documents kept elsewhere.
3. Provider without a usable third-party API or sandbox: mock first, checklist (04), contract before T34.
4. Tenant data leak: generated isolation tests, review gate. Patient data: no health data ever enters the ERP;
   in suite mode only the counterparty fields of 06 section 6, minimised and audited.
5. Valuation or numbering bug after go-live: golden cases, lock date, nightly integrity job, cost revisions log.
6. Two valuation methods confuse users: one official figure everywhere; the other only in the comparison report.
7. Scope creep toward full accounting: the catalogue in 01 is the contract; no general ledger.
8. One Supabase project for the CRM (health data) and other tenants: timeouts, plan hooks, documented exit to a
   second project before the second tenant grows.
9. Selling software used for fiscal documents may bring obligations (declaration, liability): lawyer / accountant
   before the first external tenant.
10. The same expense typed in both the CRM and the ERP: operating rule (question 2), no software link.
11. Stock allowed to go negative hides receiving errors: alert + report reviewed weekly; provisional cost flagged.

## Remaining questions for the owner (default in brackets; work continues on the defaults)
Answered 2026-11-16 and removed: valuation (weighted average), negative stock (allowed + warning), expenses (own ERP
recording, CRM untouched), patient receipts (optional phase IP), who performs G1 (dropped; the gate stays).
1. ERP in the SAME Supabase project as the CRM (own schemas; one dashboard step: expose `erp_api`) or in its own
   project? [Same project now; the standalone install test keeps a move to a separate project cheap.]
2. From which date does iSmile type its purchases / expenses in the ERP instead of the CRM expenses screen?
   [From step C3 for expenses and C4 for supplier invoices; the CRM screen is left as it is, simply not used for them.]
3. Negative stock exceptions: keep blocking a specific LOT going below zero and the transit warehouse?
   [Yes, only these two block; everything else, including fiscal delivery notes, warns.]
4. Suite mode: is one ERP customer linked per CRM PERSON or per CRM CARD (a person may have several cards)?
   [Per person when the CRM has a stable person id; otherwise per card, with a merge tool in the ERP.]
5. Retail receipt for goods already delivered with a delivery note: does the accountant accept it, or must such
   deliveries always be billed by invoice? [Allowed; the receipt carries the delivery-note reference.]
