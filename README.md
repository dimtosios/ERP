# iSmile ERP

Multi-tenant ERP suite (stock, documents, expenses, purchasing, sales). Standalone: it does not read or write any CRM
file or table. Moved from branch `erp-dev` of `dimtosios/ismile-crm` (last commit there: 0af6589, T16).

- Docs: `docs/erp/` (start with `STATE.md` and `05_roadmap.md`).
- Build: `python3 erp/build_erp.py` -> `erp.html`.
- Tests: `bash erp/backend/run_erp_tests.sh` (mode A, empty database).
- Mode B (`--with-crm`, `--all`) needs a checkout of the CRM repo, because it runs the CRM suites with the ERP on top.
  Until the runner takes a CRM path, run it from a checkout where the CRM files sit next to `erp/`.
