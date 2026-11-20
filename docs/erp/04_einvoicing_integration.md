# 04. E-invoicing / myDATA integration

Rule: the suite never talks to myDATA. A certified provider issues; we store what it returns. An issued document is
never edited: credit note or provider cancellation only.

## Adapter (provider-agnostic)
One TypeScript interface, one file per provider in `backend/supabase/functions/_shared/erp-providers/`:
`capabilities()` (document types, numbering local / provider, cancel, delivery-note receipt confirmation, webhooks,
sandbox), `submit(doc, idempotencyKey)`, `status(providerId)`, `cancel(providerId, reason)`, `fetchPdf(providerId)`,
`verifyWebhook(request)`. Results are normalised: `issued {mark, uid, qrUrl, series, number, pdfUrl}`,
`rejected {code, message, field}` (final), `pending`, `transient {retryAfter}`. No provider detail leaks into SQL or
the page except a raw-response JSON kept for support.

## Provider choice (owner decision 2)
First provider = the one iSmile's accountant already uses, IF it passes the knock-out items below; otherwise the
simplest provider with a documented API that passes them. The adapter stays provider-agnostic; the mock is built
first, so the choice blocks only task T34 (05).
Candidates (ALL unverified: confirm on the AADE list [L3] and get API docs + sandbox in writing). Named with a REST
API by a third-party comparison [P1]: Epsilon Digital (Epsilon Net), SoftOne, Entersoft, Elorus, Workadu, Timologic,
Edicom. Impact (SoftOne group) and Prosvasis are also known providers (from memory).

### Selection checklist (ask each candidate in writing; K = knock-out)
| # | Question | Why |
|---|---|---|
| 1 K | On the current AADE list of certified providers? | legal validity |
| 2 K | Documented REST API usable by THIRD-PARTY software (not only their own ERP)? Public docs or under NDA? | we are not their ERP |
| 3 K | Sandbox with test tax IDs, free and permanent? | contract tests, accountant sign-off |
| 4 K | Document types: 1.1, 2.1, 5.1 / 5.2, 9.3 delivery note with QR, 11.1 / 11.2 / 11.4? | catalogue 01 C |
| 5 K | Idempotent submit (client key or our series + number as key) and a status lookup by that key? | no double issue |
| 6 | Cancellation through the API? Credit-note correlation by MARK? | void flows |
| 7 | Numbering: ours, theirs, or both? Several series per establishment? | 02 numbering |
| 8 | Phase B delivery-note data (loading, receipt, quantity check) and the date it will be ready? | 2027 rule [L2] |
| 9 | Webhooks (signed?) or polling only; typical and maximum issue time? | worker design |
| 10 | Official PDF with QR returned by the API; delivery to the recipient by email / network? | print rule |
| 11 | Loss-of-connection procedure: what the issuer may do and what the API expects afterwards? | legal fallback |
| 12 | One contract for several issuers (multi-tenant product / reseller terms) or one contract per tenant? | selling the suite |
| 13 | Price: per document, per month, setup; price of the sandbox; minimum term? | cost per tenant |
| 14 | Rate limits, uptime commitment, support hours, status page? | operations |
| 15 | Data location (EU), retention period of documents, export on exit? | GDPR, exit |
| 16 | Received documents (supplier invoices) retrievable by API? | later: auto-fill PINV |
Score 0-2 on items 6-16; any K = no removes the candidate. Keep the answers in `docs/erp/providers/<name>.md`.

## Mapping to myDATA concepts (overview; exact fields come from the provider's spec, not from here)
| Ours | myDATA concept |
|---|---|
| tenant tax ID, branch establishment number | issuer VAT number, branch |
| series code, number | series, aa |
| doc type | invoice type: 1.1 sales invoice, 2.1 service invoice, 5.1 / 5.2 credit note, 9.3 delivery note, 11.1 / 11.2 retail receipt, 8.4 / 8.5 POS receipt / refund [L4] |
| VAT class | VAT category + exemption reason |
| line net / VAT, item kind | line amounts, income classification (category + type): mapped per doc type and item category by the ACCOUNTANT |
| money method | payment method code |
| transfer / delivery fields | movement purpose, dispatch time, vehicle, loading and delivery address [L4] |
| ref_document_id | correlated invoice MARK (credit notes, invoices billing delivery notes) |
| returned | MARK, UID, QR URL, provider signature / authentication code |

## Flow and state machine
1. `erp_api.doc_submit(id, key)`: validates, takes the number, reserves stock, state `submitted`, inserts one
   `fiscal_outbox` row (unique per document + action). Same key again = same answer, no second row.
2. Edge Function `erp-fiscal-worker` (pg_cron + pg_net, small batches, `for update skip locked`): loads the tenant's
   credentials, calls `submit`. Before any retry it calls `status` with our key so a lost reply never issues twice.
3. `issued`: store MARK / UID / QR / PDF reference, run `post_document`, notify. `rejected`: state `failed`, error
   shown on the document, user fixes and resubmits (same number). `transient`: backoff 1, 5, 15, 60 min, then `failed`
   with "retry" for a manager. `pending`: wait for webhook or poll.
4. `erp-fiscal-webhook`: verifies signature, stores the event, applies it if newer. `erp-fiscal-poll` covers providers
   without webhooks and anything `submitted` for more than 10 minutes.
5. Cancel: `doc_cancel` -> outbox action `cancel` -> on success state `cancelled` + reversing moves.
Every call and reply is one append-only `fiscal_events` row. Only the service role moves a document out of
`submitted`. A dashboard lists `failed` and stuck documents per tenant.

## Secrets
Per tenant in Supabase Vault (availability on the free plan: verify; fiscal go-live needs Supabase Pro anyway, gate G2 in 05); `erp.provider_accounts` stores provider, mode
(sandbox / live), a vault reference and the last successful check, never the key. Only Edge Functions (service role)
read it. Entered once by the tenant admin through `erp-fiscal-credentials` (write-only: the page can replace, never
read). Webhook URL carries an opaque per-tenant token.

## Failure handling the user sees
Provider down: documents queue as `submitted`; goods must not leave on an unissued delivery note; the legal
loss-of-connection procedure is the provider's and the accountant's call (unverified). Wrong data after issue: credit
note / cancel + new document. Duplicate click: idempotency key. Number gap: document register report.

## Mock provider contract (built before any real provider; the reference for every adapter)
An Edge Function `erp-provider-mock` + adapter `mock.ts`. Local and test only: `provider_accounts.mode = 'live'`
refuses provider `mock`. It keeps its state in `erp.mock_provider_docs` (test schema grants only).
| Call | Request | Reply |
|---|---|---|
| `POST /documents` | header `Idempotency-Key`, body = normalised document (issuer tax ID, branch, type, series, number, date, counterparty, lines, totals, delivery block, correlated MARK) | `201 {providerId, status: "issued", mark, uid, qrUrl, pdfUrl}` or `202 {providerId, status: "pending"}` or `422 {code, message, field}` or `503` with `Retry-After` |
| `GET /documents/{providerId}` and `GET /documents?key=` | - | same body as above; `404` if never received |
| `POST /documents/{providerId}/cancel` | `{reason}` | `200 {status: "cancelled", cancelMark}` or `409 {code}` |
| `GET /documents/{providerId}/pdf` | - | a one-page PDF marked "MOCK" |
| webhook to `erp-fiscal-webhook` | `{providerId, status, mark, uid, qrUrl, occurredAt}` + HMAC-SHA256 header | - |
Rules: the same `Idempotency-Key` always returns the first reply; the same (issuer, series, number) with another key
returns `409 duplicate`; MARK = 15 digits rising, UID = 40 hex. Scenarios are chosen by a marker in the document
notes: `#ok`, `#pending:30s`, `#reject:VAT`, `#timeout-then-issued` (no reply, document exists on lookup),
`#timeout-then-lost` (no reply, lookup 404), `#503x3`, `#late-webhook`, `#webhook-bad-signature`,
`#cancel-refused`. Every real adapter must pass the same scenario suite against its sandbox where the sandbox can
produce the case; the gaps are listed per provider.

## Test strategy
`mock` provider for all suites; contract tests per real provider against its sandbox with a test tax ID; a tenant
goes live per document type only after 5 sandbox documents are checked by its accountant.

## What the tenant and accountant configure
Provider contract and API credentials; declaration of the channel to AADE; series per branch and document type;
VAT classes and exemption reasons; income classification map; establishment numbers; which document types are live.
