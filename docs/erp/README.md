# iSmile ERP suite: design set (planning only, 2026-11-16, rev. 4)

Status: NOT started. Architect: Fable. Code: Opus 5.5. Nothing here is built or applied to live.

## Owner decisions 2026-11-16 (latest, final; they override anything older in this set)
1. Official valuation: WEIGHTED AVERAGE. FIFO layers are still stored and available as a report / option (02).
2. Negative stock: ALLOWED with a visible warning, an alert and a negative-stock report; not blocked (02).
3. Purchases and expenses: the ERP has its OWN recording (supplier invoices, expense documents, categories; 01).
   The CRM is a SEPARATE project: it is not changed and its expenses are not read, moved or connected.
4. Patient receipts: a possible FUTURE bridge CRM -> ERP -> e-invoicing provider. Designed only as an optional,
   additive Integration Pack (06 sections 3-4); nothing is built or changed in the CRM; not part of E0..E10 unless
   the owner activates it.
5. Backup gate G1 stays documented (05); who performs it is not a question now.
Result: the ERP CORE is fully standalone (own tenants / members / branches, no CRM table used, no CRM file edited).

## Owner decisions 2026-11-16, second batch (final; they override the first batch where they differ)
A. UMBRELLA MODEL. Three deployment modes: standalone CRM, standalone ERP, SUITE (both under one umbrella: same
   Supabase project and login; Integration Pack ON by a per-tenant flag). In suite mode the ERP may PULL the
   counterparty data it needs from the CRM (name, phone, email, address, tax id if present, clinic = branch):
   read-only, through a narrow facade, role-gated and audited. This REPLACES the earlier "opaque reference only, no
   personal data crosses" rule. Health data (treatment, diagnosis, notes, Patient ID) still never crosses. Full
   rules: 06 section 6. Every CRM change stays additive and NOT NOW.
B. DOCUMENT CONVERSION. Every document has "Convert to" / "Copy to" actions (delivery note -> retail receipt or
   invoice, quote -> order -> delivery note -> invoice, purchase order -> goods receipt -> supplier invoice, many
   delivery notes -> one invoice, partial quantities). All lines are copied, links are kept, stock is never moved
   twice. Matrix: 01 C5; model: 02 "Document conversion"; recipe and tests: 03; tasks T44-T48 and checkpoint FC: 05.
C. Materials card (07): who may consume = default kept (all clinic staff), no longer a question. Material requests =
   ONE REQ document that purchasing converts into a purchase order or a transfer (REQ is now a core type, 01 C3).

## Purpose
A separate, sellable, multi-tenant, standalone operational ERP (stock, purchasing, expenses, sales,
receipts/payments). It shares only the Supabase project / Auth with the CRM; own schema, SQL files, screens, docs. Fiscal documents are
issued ONLY through a certified e-invoicing provider. Accounting depth: operational + exports to the accountant /
SoftOne / Entersoft. No general ledger.

This set supersedes section 2 ("Basic ERP inside the CRM") and phase 3b of `docs/ERP_AI_PLAN.md`. The AI-reports part
(section 3) and the SoftOne web-service notes (section 1) of that file stay valid and are not repeated here.

## Reading order
1. `01_tools_checklist.md`: every function, MUST / SHOULD / LATER, SoftOne / Entersoft equivalent.
2. `02_architecture.md`: tenancy, schema, ledger, numbering, RLS, performance.
3. `03_code_structure.md`: the Opus handbook (layout, document recipe, SQL rules, tests, gates, never-do list).
4. `04_einvoicing_integration.md`: provider adapter, selection checklist, mock contract, failure handling.
5. `06_crm_integration.md`: the CRM boundary (off limits), the optional Integration Pack, go-live steps, deployment
   modes and the suite counterparty rules (section 6).
7. `07_crm_card_materials.md`: OPTIONAL, not now: CRM card "Materials" table linked to the ERP (IP6): behaviour,
   contract `erp_api.int_*`, later CRM changes, what the core must have ready. Read after 06.
6. `05_roadmap.md`: phases E0..E10 + optional IP, Opus tasks, Fable checkpoints, go-live gates, owner questions.

## Earlier owner decisions (still valid)
1. Supabase Pro: not now. So backups / project pausing are go-live gates (05: G1 before real stock data, G2 = Pro
   before any fiscal document).
2. First provider: the accountant's, or any simple one with an API; adapter provider-agnostic; checklist in 04.
3. The ERP suite is the stock master.
4. Valuation: both methods computed and kept; the official one is decided above.
5. All documents are designed (01 C); legal issuing only through the certified provider.
6. No commercial / pricing design now: only tenant plan hooks (02).

## Out of scope
General ledger / double entry, payroll, fixed assets, production / BOM, full WMS (bins, picking waves), POS hardware
and fiscal cash registers, direct transmission to myDATA (not allowed for us by design, and by law after the
transition, see below), EDI, multi-currency (EUR only in v1; the column exists), tax advice of any kind.

## Glossary
| Greek | Term used here |
|---|---|
| Είδος, Αποθηκευτικός χώρος (Α.Χ.) | item, warehouse |
| Υποκατάστημα / Εγκατάσταση | branch (has a myDATA establishment number, 0 = head office) |
| Συναλλασσόμενος (πελάτης / προμηθευτής), ΑΦΜ | counterparty (customer / supplier), tax ID |
| Παραστατικό, Σειρά, Α/Α | document, series, serial number |
| Δελτίο αποστολής (ΔΑ) | delivery note (myDATA 9.3) |
| Ενδοδιακίνηση | inter-branch transfer (a delivery note between own establishments) |
| Καταχώρηση δελτίου (παραλαβή) | delivery-note registration = goods receipt of a supplier's note |
| Τιμολόγιο, Πιστωτικό, ΑΛΠ / ΑΠΥ | invoice, credit note, retail receipt (goods / services) |
| Παραστατικό είσπραξης / πληρωμής | receipt / payment document (money in / out) |
| Απογραφή | stocktake |
| Αποτίμηση (μέσος σταθμικός, FIFO) | stock valuation (weighted average, FIFO) |
| ΜΑΡΚ, UID, QR | myDATA registration number, document hash id, verification code |
| Πάροχος ηλ. τιμολόγησης (ΥΠΑΗΕΣ) | certified e-invoicing provider |
| Καρτέλα, Ενηλικίωση υπολοίπων | counterparty card (statement), aging |

## Legal context (overview only; the owner MUST confirm every point with the accountant)
- Mandatory B2B e-invoicing: businesses with turnover up to EUR 1,000,000 from 2 Nov 2026, transition to 31 Jan 2027;
  from 1 Feb 2027 issuing goes only through a provider or AADE's free apps (timologio / myDATAapp), ERP-direct
  transmission stops [L2]. Larger businesses started earlier in 2026 (to my knowledge 2 Feb 2026; unverified).
- Digital delivery notes: issued in real time before the movement, with QR and MARK [L1]. Phase B from 1 Jan 2027:
  loading / unloading / receipt and quantity-check data; standard item coding (Combined Nomenclature) from
  1 Jan 2028 [L2].
- Businesses declare their issuing channel / provider to AADE [L1] (deadline and form: unverified).
- Not verified here: which decision governs which rule (A.1128/2025, A.1129/2025, A.1044/2026, A.1197/2026 are listed
  on [L1]), exemptions, the loss-of-connection procedure, retention periods, VAT treatment of dental services.

## Sources
- [L1] https://aade.gr/node/15728 (AADE: mandatory e-invoicing and digital movement documents)
- [L2] https://www.ey.com/el_gr/technical/tax/tax-alerts/nees-prothesmies-ilektroniki-timologisi-psifiaka-parastatika-diakinisis
- [L3] https://www.aade.gr/epiheiriseis/mydata-ilektronika-biblia/adeiodotimena-logismika-parohon-ilektronikis-timologisis (official provider list; could not be opened from this session, NOT checked)
- [L4] https://docs.fiskaltrust.eu/docs/poscreators/middleware-doc/greece/terminology (myDATA document types and terms, third party)
- [L5] https://www.aade.gr/sites/default/files/2026-09/myDATA%20API%20Documentation_Providers_v2%200%202_official_0.pdf (provider API spec; found, not read)
- [P1] https://www.lido.app/gr/paroxoi-ilektronikis-timologisis (provider comparison, third party, unverified)
- [S1] https://softone.gr/wp-content/uploads/2024/10/SOFTONE-wholesale-GR.pdf (SoftOne wholesale brochure)
- [S2] https://softone.gr/ws (Soft1 Web Services, from ERP_AI_PLAN)
- [E1] https://platform.softwareone.com/product/entersoft-business-suite/PCP-1889-8146 (Entersoft Business Suite module list, reseller page)
