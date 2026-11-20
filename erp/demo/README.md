# ERP demo (no server, nothing saved)

`demo.html` is ONE file: the current ERP page (`erp.html`) with sample data for three clinics, running entirely in the
browser. Open it on a phone or a computer (double-click, or attach / upload it anywhere that serves a file). It makes
no network call (a Content-Security-Policy forbids them), uses no real key and no browser storage. Everything you do
lives in the page's memory: **reload = start again from the sample data**.

The yellow **DEMO** bar at the top has a **View as** switcher: the same data seen by each demo member.

| View as | Role | Clinic |
|---|---|---|
| Owner (all clinics) | owner | all |
| Manager, Serres | manager | Serres |
| Warehouse, Thessaloniki | warehouse | Thessaloniki |
| Clinic user, Alexandreia | clinic_user | Alexandreia |
| Accounting, Serres | accounting | Serres (needed for the approval-limit step) |

Sample data (`seed_demo.json`): tenant "iSmile (demo)", 3 clinics each with a store + the system TRANSIT warehouse,
31 orthodontic items (brackets, archwires, elastics, bands, bonding, retention, aligner supplies, gloves, masks,
mirrors...; EAN-13 barcodes, VAT 24%), 4 suppliers (made-up AFM that pass the check digit), opening stock, posted goods
receipts and consumptions, a transfer waiting for receipt, a transfer received short with its adjustment waiting,
4 low-stock alerts and 1 negative stock, 12 expense categories and 6 posted expenses. Expense approval limit: €300 net.

## 10 things to try

1. **Look around as the owner.** Home shows the three clinics. *Stock > On hand*: choose "Low stock" in the filter;
   *Stock > Alerts* shows the low-stock alerts and the negative ELA-14M in Alexandreia.
2. **Receive goods by barcode.** *Stock > Documents*, type "Goods receipt", **New document**. Warehouse SER-MAIN, supplier
   Orthodontiki Ellas AE. In the item field type (or scan) `5204417100079` and press Tab: it becomes WIR-N016U with
   "on hand 6". Quantity 10, unit cost 9,60. **Save**, then **Post**: number GRN-SER/000002. Back in *On hand* the
   Serres archwire is 16 and no longer "low".
3. **Consume past zero.** View as *Clinic user, Alexandreia* (only Home, Master data and Stock; only "Consumption").
   **New document** (Consumption), item `BON-COMP` (on hand 3), quantity 5, **Save**, **Post**: a warning says it goes to -2.
   **Post anyway**. See *Stock > Negative stock* (who and which document) and *Alerts*.
4. **Dispatch a transfer.** View as *Owner*. *Transfers*, **New transfer**: from SER-MAIN to THE-MAIN, item `BRK-C22`
   quantity 3, **Save**, **Dispatch**. It is now "in transit" (Owner: *On hand* shows it in TRANSIT).
5. **Receive it short.** View as *Warehouse, Thessaloniki*. *Transfers*, open TRF-SER/000002, **Confirm receipt**:
   received 2, reason "One kit damaged", confirm. The transfer is "Received with difference" and lists a generated
   "Adjustment -" draft for the missing kit. (The other waiting transfer, TRF-SER/000001, can be received in full.)
6. **Approve the difference.** View as *Manager, Serres*. *Transfers*, open TRF-THE/000001 (2 boxes of gloves missing),
   click its "Adjustment -" link, **Post**. The transfer becomes "Closed" and nothing is left in transit.
7. **Expense over the approval limit.** View as *Accounting, Serres*. *Expenses*, **New expense**: clinic Serres,
   category "Equipment maintenance", "Autoclave service", net 450. **Save**: only **Submit for approval** is offered
   (450 > 300). Submit. View as *Manager, Serres*, open it, **Approve and post** (EXP-SER/000003, gross €558.00).
   The limit is in *Admin > Settings* (owner).
8. **Expense report.** *Expenses > Report*: totals by category or by supplier, dates, clinic; **Download CSV**.
9. **Low-stock alerts.** *Stock > Alerts* as Owner or Manager: **Resolve** one. It comes back only if the stock moves
   again and is still low. The clinic user sees the alerts of Alexandreia only, without Resolve.
10. **Import items by CSV with errors.** View as *Owner*. *Master data > Items*, **Import CSV**, paste:

    ```
    code;name;unit;vat;category;min_level;barcodes
    WIR-N018U;NiTi archwire .018 upper (10);PACK;VAT24;WIRE;6;5204417200014
    BRK-X;Bracket kit X;BAG;VAT24;BRK;abc;5204417200015
    WIR-N018U;Duplicate row;PACK;VAT24;WIRE;2;
    ```

    **Check (dry run)**: problems by row (unknown unit BAG, min_level not a number, wrong barcode check digit, duplicate
    code) and **Import** stays disabled. Delete the last two lines, check again, **Import**: the new item is listed.

Also: *Admin* (owner) lists the demo members; on *Sign out*, sign in with any demo email above
(`owner@ismile.demo`, `manager.serres@ismile.demo`, `store.thess@ismile.demo`, `assistant.alex@ismile.demo`,
`accounts@ismile.demo`) and any password.

## What is faithful, what is simulated

The page is the real ERP front end. The server is the stub client of the UI smoke tests
(`erp/backend/tests/ui/mock_supabase_erp.js`) loaded with this seed plus `demo_runtime.js` (a small stock ledger at
average cost, document numbering per series, alerts, CSV checks). So:

- **Faithful per role**: menus, tabs and buttons (from the role's capabilities, a copy of `erp.role_cap_defaults`);
  which clinics' warehouses, stock, documents, transfers (source / destination rule), expenses, alerts and the
  negative-stock report a member sees; cost columns hidden without `cost.read`; who may post, submit, approve, cancel,
  dispatch and receive.
- **Simulated / simplified**: the posting rules are the stub's, not the SQL (no lock date, no FIFO, no recost queue, no
  audit trail); an excess on receipt (more than sent) is not turned into an "Adjustment +"; Master data, Admin members
  and Settings are tenant-wide lists (as in the real system) but edits there are only checked lightly; dates are
  relative to the day you open the page.

## Rebuild

```
python3 erp/build_erp.py            # erp.html from erp/app (as always)
python3 erp/demo/build_demo.py      # demo.html = erp.html + seed_demo.json + demo_runtime.js + the stub client
python3 erp/demo/build_demo.py --check
```

`build_demo.py` validates the seed first (AFM and EAN check digits, references). `smoke_erp_demo.py` (run by
`erp/backend/run_erp_tests.sh`) fails when demo.html is stale, so rebuild and commit it after any change to the page,
the stub or the seed.
