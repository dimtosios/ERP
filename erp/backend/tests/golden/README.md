# Valuation golden cases

One file per case; one row per document (one line, one item, one warehouse), posted in step order. Columns:
`step, op` (`in` receipt at `unit_cost`; `out` issue; `ret_in` customer return of the outbound of `src_step`, empty =
unlinked = current official cost; `ret_out` supplier return of the receipt of `src_step`), `qty`, `unit_cost`,
`src_step`, then the expected item state AFTER the step: `exp_qty`, `exp_value_avg`, `exp_value_fifo`, the step's move
values (signed) `exp_move_avg`, `exp_move_fifo`, and the open FIFO layers `qty@unit_cost;...` in consumption order.
The suite also asserts the integrity check (balances = ledger, cost state = ledger, layers = on hand) after each case.

G1 simple buy / sell; G2 three receipts at different prices then partial issues (average and FIFO differ); G3
quantity to zero and rounding residue; G4 customer return linked and unlinked; G5 supplier return (receipt layer
first, else normal FIFO). Rules: E140 header. **Worked by hand by the implementer (Opus, T10) because the Fable cases
did not exist yet (03 section 5: Fable writes them): the reviewer re-computes every expected value at F2.**
G7 (T12, suite E150 with GRN in / CONS out): negative stock under `warn` (ack), provisional cost at the last cost,
then a receipt covers the deficit: extra columns `exp_corr_avg, exp_corr_fifo` (the value-only correction of that
receipt) and `exp_alert` (1 = an open `negative_stock` alert). G8 (T13, suite E140): a receipt dated BEFORE two issues is posted last (`day` = days before today): the issues are
costed again; columns = the FINAL move values after the backdated post and `exp_revised` (1 = one `cost_revisions`
row for that move); final state qty 13, average 84.50, FIFO 95.00, layers 3@5;10@8 (asserted in the suite). G3 is also
replayed from its first date (T13): nothing may change. G6, G9, G11, G12 belong to later tasks (T17: G11; T22: G6; T37: G9; T39: G12).
G10 (T16, suite E160; **worked by hand by the T16 implementer, re-computed by `costing_model.py` whose transfer rule the
implementer added: the F3 reviewer re-computes it**): transfers W1 -> W2 of one item. Extra columns `wh, wh_to` (op
`in` = GRN, `out` = CONS, or with `wh = TRANSIT` the generated ADJ_OUT of the short receipt of `src_step`), ops `trf`
(dispatch; the step's move = the source move), `trf_in` (receipt of the dispatch of `src_step`, `qty` received; the
step's move = the destination move), `trf_cancel` (cancel of `src_step`); `exp_transit` = the item's transit balance,
`exp_trf_state` = the transfer's state. What it proves: the item's cost state and FIFO layers never change through a
dispatch / receipt / cancel; the receipt carries the DISPATCH cost although a GRN changed the average in between (step 6:
30.00 / 32.00, not 6 x 6.6 = 39.60); a part receipt = round(qty x the dispatch unit cost, 2) (step 11); transit returns
to zero for every received / cancelled / closed transfer; the shortage leaves transit by the ADJ_OUT at the current cost
(step 12), which closes the transfer.
