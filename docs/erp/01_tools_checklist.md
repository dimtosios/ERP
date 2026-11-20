# 01. Complete tools checklist (final scope, 2026-11-16)

Tags: **MUST** = needed for a usable v1 (phases E0-E8), **SHOULD** = E9-E10, **LATER** = after the first paying tenant.
Equivalents: SoftOne terms from [S1] plus standard Soft1 object names (ITEM, PURDOC, SALDOC, ITEDOC, FINDOC:
unverified per install). Entersoft is mapped at module level only [E1]; row-level names are an assumption to confirm
with a reseller. myDATA type numbers come from [L4] and are **unverified**: the accountant and the provider confirm.

## A. Master data
SoftOne: Είδη, Αποθηκευτικοί χώροι, Παρτίδες, Τιμολογιακές πολιτικές, Πελάτες / Προμηθευτές. Entersoft: Inventory
Management & Logistics; Sales & Distribution; Procurement.
- MUST: items (code, name, kind goods / service / consumable, base unit, category, VAT class, min and reorder level,
  lot-tracked yes / no, active); item categories (tree, optional valuation override); units; VAT classes (rate +
  myDATA VAT category + exemption reason); branches (establishment number, address); warehouses (belong to a branch;
  one transit warehouse per tenant); counterparties (customer / supplier / both, tax ID with checksum, tax office,
  country, addresses, payment terms); expense categories (tree); barcodes (many per item); last purchase
  price and sales price per item; payment methods; cash and bank accounts; document series.
- SHOULD: alternative units with factors (box = 50 pcs); lots with expiry; price lists (customer group, date range);
  supplier item codes; item images; contacts; tax ID lookup (AADE registry / VIES) to prefill name and address.
- LATER: serial numbers; variants; kits; Combined Nomenclature code (delivery notes from 2028 [L2]); credit limits.

## B. Fields shared by every document
- **Header**: tenant, branch, doc type, series, number (empty until posted), doc_date, state, counterparty (when the
  type needs one), warehouse, destination warehouse (transfers), reference to source document(s), external number
  and date (documents received from a supplier), payment terms / due date, notes, totals net / VAT / gross,
  withholding amount, created_by, approved_by, posted_at, cancel reason, idempotency key; fiscal block (provider id,
  MARK, UID, QR URL, issued_at, fiscal state).
- **Delivery block** (delivery notes, transfers, invoice + delivery): movement purpose, dispatch date and time,
  loading and delivery address, carrier / vehicle plate.
- **Line**: line no, item, description, lot (+ expiry), qty, unit, qty_base, unit price, discount %, VAT class, net,
  VAT, gross, unit cost and cost value (filled by posting), source line (for conversions and returns).
- **Outputs**: every document prints to PDF and can be emailed from the page. Fiscal types send the PROVIDER's PDF
  only after issue; before that the print is watermarked "Not a fiscal document".
- **Roles** (02): O owner, M manager, W warehouse, A accounting, C clinic user, R read-only.
  Notation below: create / approve / void. "-" = no approval step (posting by the creator).

## C. Document catalogue
Stock: + in, - out, R reserve, 0 none. Money: AR / AP = opens or reduces a receivable / payable; cash = moves a cash
or bank account. Fiscal "yes" = legal issuing ONLY through the provider (04); before E8 these types exist as
non-fiscal drafts.

### C1. Purchasing (SoftOne: Αγορές / PURDOC. Entersoft: Procurement)
| Code | Document | Specific fields | Stock | Money | Create / approve / void | Series | Fiscal | Tag | SoftOne name |
|---|---|---|---|---|---|---|---|---|---|
| PO | Purchase order (Παραγγελία σε προμηθευτή) | expected date, supplier item code | 0 (expected qty) | none | W M O / M O above tenant limit / M O | branch, not gapless | no | MUST | Παραγγελία αγοράς |
| GRN | Goods receipt = registration of the supplier's delivery note (Καταχώρηση ΔΑ προμηθευτή) | supplier DN number, date, MARK if known; PO lines received; lot / expiry | + at PO price (provisional cost) | none (not yet payable) | W M O / - / M O | branch | no (Phase B receipt confirmation: LATER, via provider) | MUST | Δελτίο παραλαβής |
| PINV | Supplier invoice (Τιμολόγιο αγοράς); with or without prior GRN | supplier invoice number, date, MARK; GRN lines billed; withholding | + only for lines with no GRN; otherwise cost correction | AP + | A M O / - / A M O | branch | no (received; stored, never issued) | MUST | Τιμολόγιο αγοράς |
| EXP | Expense document (Παραστατικό δαπάνης): non-stock supplier invoice, utility bill, receipt, fee | expense category per line, supplier (optional for small receipts), supplier document number, date, MARK if any, VAT class, cost centre, attachment, paid-on-the-spot account | 0 | AP +, or cash - when paid on the spot | A M O / M O above tenant limit / A M O | branch | no (received; stored, never issued) | MUST | Παραστατικό δαπάνης |
| PCRN | Supplier credit note received (Πιστωτικό προμηθευτή) | reference PINV, reason (return / discount) | 0, or cost correction for a price discount | AP - | A M O / - / A M O | branch | no | MUST | Πιστωτικό αγοράς |
| PRET | Purchase return (Δελτίο επιστροφής σε προμηθευτή) | reference GRN / PINV, delivery block | - at the original receipt cost | none until PCRN | W M O / M O / M O | branch, gapless | yes (delivery note, 9.3) | SHOULD | Δελτίο επιστροφής αγοράς |

### C2. Sales (SoftOne: Πωλήσεις / SALDOC. Entersoft: Sales & Distribution)
| Code | Document | Specific fields | Stock | Money | Create / approve / void | Series | Fiscal | Tag | SoftOne name |
|---|---|---|---|---|---|---|---|---|---|
| SQ | Quote (Προσφορά) | valid until | 0 | none | A M O / - / A M O | branch | no | SHOULD | Προσφορά |
| SO | Sales order (Παραγγελία πελάτη) | delivery date | R | none | A M O / - / A M O | branch | no | SHOULD | Παραγγελία πώλησης |
| DN | Delivery note without invoice (Δελτίο αποστολής) | delivery block; to be billed yes / no | - | none | W A M O / - / M O (provider cancel) | branch, gapless | yes (9.3) | MUST | Δελτίο αποστολής |
| SINV | Sales invoice (Τιμολόγιο πώλησης); bills one or more DN, or acts as invoice + delivery note (Τιμολόγιο - ΔΑ) | DN references; delivery block when combined | - only for lines with no DN | AR + | A M O / - / by CRN or provider cancel | branch, gapless | yes (1.1) | MUST | Τιμολόγιο πώλησης / ΤΔΑ |
| SVC | Service invoice (Τιμολόγιο παροχής υπηρεσιών) | withholding | 0 | AR + | A M O / - / as SINV | branch, gapless | yes (2.1) | MUST | ΤΠΥ |
| CRN | Credit note, linked or unlinked (Πιστωτικό τιμολόγιο) | reference invoice, goods returned yes / no | + if goods return (at the original cost) | AR - | A M O / M O / provider cancel only | branch, gapless | yes (5.1 / 5.2) | MUST | Πιστωτικό τιμολόγιο |
| RR | Retail receipt, goods (ΑΛΠ) / simplified invoice | payment method (paid at issue); DN references | - only for lines with no DN | cash + (auto RCPT) | A C M O / - / by RCR | branch, gapless | yes (11.1) | SHOULD | Απόδειξη λιανικής |
| RS | Retail receipt, services (ΑΠΥ) | payment method | 0 | cash + (auto RCPT) | A M O / - / by RCR | branch, gapless | yes (11.2) | SHOULD | Απόδειξη παροχής υπηρεσιών |
| RCR | Retail credit (Πιστωτικό στοιχείο λιανικής) | reference RR / RS | + if goods return | cash - or AR - | A M O / M O / provider cancel only | branch, gapless | yes (11.4) | SHOULD | Πιστωτικό λιανικής |

### C3. Warehouse (SoftOne: Αποθήκη / ITEDOC. Entersoft: Inventory)
| Code | Document | Specific fields | Stock | Money | Create / approve / void | Series | Fiscal | Tag | SoftOne name |
|---|---|---|---|---|---|---|---|---|---|
| REQ | Material request (Αίτηση υλικών): a clinic asks for items; purchasing converts it (C5) | needed by, requesting branch, optional `ext_ref` | 0 | none | C W M O / - / M O | branch, not gapless | no | SHOULD | Αίτηση αγοράς |
| OPN | Opening balance (Απογραφή έναρξης) | unit cost per line, lot | + | none | M O / O / O | tenant | no | MUST | Απογραφή έναρξης |
| TRF | Inter-branch / inter-warehouse transfer (Ενδοδιακίνηση): dispatch, then receipt confirmation | source and destination warehouse, delivery block, received qty per line, difference reason | - source, + transit; on receipt - transit, + destination | none | W M O / receiver W M O confirms; difference M O / M O before receipt | source branch, gapless | yes when the warehouses belong to different establishments (9.3), no inside one establishment | MUST | Δελτίο ενδοδιακίνησης |
| ADJ+ / ADJ- | Stock adjustment (Εισαγωγή / Εξαγωγή αποθήκης) | reason code (found, damaged, expired, lost, correction), unit cost for ADJ+ | + / - | none | W M O / M O above tenant value limit / M O | branch | no (destruction and self-supply rules: accountant) | MUST | Δελτίο εισαγωγής / εξαγωγής |
| CONS | Internal consumption (Ανάλωση): to a cost centre | cost centre, optional `ext_ref` (free external reference, 06) | - at cost | none | C W M O / - / M O | branch | no (self-supply VAT: accountant) | MUST | Δελτίο ανάλωσης |
| STK | Stocktake (Απογραφή): counting sheets, freeze, variance posting | warehouse, scope (all / category / list), frozen qty, counted qty, counted_by, recount flag | + / - for variances (two generated ADJ lines sets) | none | W M O count / M O approve / O | branch | no | MUST | Φυσική απογραφή |

Stocktake rules: `start` snapshots on-hand as frozen qty and locks the scoped items in that warehouse (no posting
for them until approve or abort; documents fail with `ERP_STK_FROZEN`); counting sheets print with or without the
frozen qty (blind count); several counters, last count wins, recount on demand; variance = counted - frozen, valued
at current cost; approval posts the variances as one ADJ+ and one ADJ- linked to the STK; uncounted lines are either
"keep" or "set to zero" (chosen at approval, never silently).

### C4. Money (SoftOne: Χρηματοοικονομικά / FINDOC. Entersoft: Receivables and Payables; Cash Flow)
| Code | Document | Specific fields | Stock | Money | Create / approve / void | Series | Fiscal | Tag | SoftOne name |
|---|---|---|---|---|---|---|---|---|---|
| RCPT | Receipt (Απόδειξη είσπραξης) | account, method (cash, card / POS, bank), amount, allocations to SINV / SVC / RR | 0 | cash +, AR - | A M O / - / M O void with reason | branch | no (not a tax document; POS link 8.4 / 8.5: LATER) | MUST | Απόδειξη είσπραξης |
| PAY | Payment (Απόδειξη πληρωμής / Εντολή πληρωμής) | account, method, amount, allocations to PINV / EXP | 0 | cash -, AP - | A M O / M O above tenant limit / M O void | branch | no | MUST | Απόδειξη πληρωμής |
| MTR | Transfer between own accounts (Μεταφορά ταμείου / τράπεζας) | from account, to account | 0 | cash - / + | A M O / - / M O void | tenant | no | MUST | Συμψηφιστική / μεταφορά |
| CBAL | Opening balances of counterparties and accounts | per counterparty / account | 0 | AR / AP / cash | O / - / O | tenant | no | MUST | Υπόλοιπα έναρξης |
- MUST: allocation of a receipt / payment to one or many documents (oldest first or manual), partial allocation,
  unallocated remainder kept as an advance, re-allocation by a new allocation row (never edit); cash and bank
  journal per account with running balance; customer / supplier statement (Καρτέλα) with running balance; aging
  0-30 / 31-60 / 61-90 / 90+ by due date; void with reason, never delete.
- SHOULD: daily cash close per branch (counted vs journal, difference logged); withholding tax on service invoices
  (amount per document, shown on statements and in the accountant pack; rates and when it applies: **accountant**).
- LATER: cheques; instalment plans for ERP customers; bank statement import.
- Expenses: categories tree with default VAT class; recurring expense templates (SHOULD); deductibility and VAT
  treatment per category: **accountant**. CRM boundary (06): patient money and CRM expenses are not in the ERP.

### C5. Conversion matrix ("Convert to" / "Copy to"; model in 02 "Document conversion")
Convert copies ALL lines (item, description, qty, unit, lot, price, discount, VAT class) into a DRAFT of the target
type, linked line by line to the source. P = partial quantities allowed; N:1 = several sources of the same
counterparty and branch into one target. Stock rule: the document that moves the goods FIRST posts the stock; a later
document in the chain posts only money / fiscal data for those lines.
| Source | Allowed targets | P | N:1 | Stock effect of the target lines |
|---|---|---|---|---|
| SQ | SO, DN, SINV, SVC, RR, RS | yes | no | as the target type |
| SO | DN, SINV (invoice + delivery), RR | yes | yes | target posts stock and releases the reservation |
| DN | SINV, RR | yes | yes | NONE (the DN moved the stock); money / fiscal only |
| SINV, SVC | CRN | yes | no | + only when "goods returned" |
| RR, RS | RCR | yes | no | + only when goods return |
| REQ | PO, TRF | yes | yes (to PO) | none (PO) / as TRF |
| PO | GRN, PINV (invoice with stock) | yes | yes | target posts stock |
| GRN | PINV, PRET | yes | yes (to PINV) | PINV: NONE, cost correction only; PRET: - |
| PINV | PCRN, PRET | yes | no | as C1 |
| any type | the same type ("Copy to": new draft, NO link, today's date and prices kept) | - | - | as the type |
Not allowed: RR / RS -> SINV (issue RCR, then SINV); any pair not listed; a target of another tenant, branch group or
counterparty. Lines typed directly on a SINV / RR / PINV (no source line) post their own stock, so one invoice may
mix billed-DN lines and invoice-with-stock lines. Fiscal targets are issued ONLY through the provider (04) and carry
the source document references (for example the DN numbers on the invoice) where the provider's format has them
(accountant confirms the retail-receipt-after-delivery-note case). Tag: MUST for DN -> SINV / RR, PO -> GRN -> PINV,
GRN -> PINV, credits; SHOULD for SQ / SO / REQ chains.

## D. Stock functions
SoftOne: Υπόλοιπα ανά Α.Χ. / παρτίδα, FIFO, κόστος πωληθέντων [S1]. Entersoft: Inventory Management & Logistics.
- MUST: immutable movement ledger; on-hand per warehouse / item / lot; WEIGHTED AVERAGE = official cost (owner decision), FIFO
  layers kept as report / option (02); negative stock allowed with warning + alert + report (02); in-transit stock; stock
  card per item; min / reorder alerts; period lock date; backdating with recost.
- SHOULD: reservations; suggested purchase quantity; lots, expiry alerts, FEFO picking; valuation at a past date;
  method comparison report (average vs FIFO); valuation method switch (cut-over wizard).
- LATER: landed costs; bins; serial numbers; periodic (annual) average if the accountant asks for it.

## E. Reports
- MUST: stock on hand and value; stock card; movement list; purchases and sales by item / counterparty / branch /
  period; open orders and unbilled delivery notes; unbilled goods receipts; customer / supplier statements; aging;
  cash / bank journal; VAT summary per period, rate and direction (for the accountant, not a VAT return); document
  register per series with gap check; consumption per cost centre; expenses by category / supplier / branch / period; negative-stock
  items.
- SHOULD: margin; slow movers; expiry list; withholding summary; saved filters.
- LATER: AI reports (ERP_AI_PLAN section 3) over `rpt_erp_*` views.

## F. Import / export
MUST: CSV import of items, counterparties, opening stock, opening balances (dry run + error list); CSV export of every
list; accountant pack (documents + lines, VAT summary, expenses, receipts / payments) as CSV.
SHOULD: SoftOne and Entersoft import layouts (from the reseller: unverified). LATER: SoftOne web-service push [S2].

## G. Platform
- MUST: tenants, members, six roles, branch scoping, approvals with tenant thresholds, audit log of every write,
  tenant settings (time zone, valuation, negative stock, lock date, thresholds, logo), in-app alerts (low stock, negative stock,
  transfer waiting for receipt, failed fiscal document, approval waiting), e-invoicing adapter + mock + one provider.
- SHOULD: onboarding wizard; plan hooks (limits only, no billing); email alerts; phone-camera barcode scanning;
  mobile layouts; second provider.
- LATER: billing; public API keys; offline counting; label printing.
