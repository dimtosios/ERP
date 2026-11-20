"""Smoke test (T04) against a REAL local database: erp.html with bridge_supabase_erp.js, every erp_api call executed
by PostgreSQL as role authenticated with the stub login's JWT claims (like PostgREST). Fresh database erp_ui with all
E files, tenant onboarded with an owner invitation; then: first sign-in binds, admin adds a branch, invites a member,
saves settings (dd/mm/yyyy -> date in the DB), a duplicate code shows the server's problem list, the invited person
binds with its own login and sees no Admin, a stranger sees "No access". Needs root (su postgres) like the runner.
usage (repo root): python3 -I erp/backend/tests/ui/smoke_erp_db.py erp.html <ignored mock path>"""
import sys, pathlib, json, subprocess, shutil, tempfile, os, re
from playwright.sync_api import sync_playwright

html = pathlib.Path(sys.argv[1]).resolve()
here = pathlib.Path(__file__).resolve().parent
backend = here.parent.parent
bridge = here / "bridge_supabase_erp.js"
DB = "erp_ui"
errors, ok = [], []


def check(cond, msg):
    (ok if cond else errors).append(msg)


def psql(sql, db=DB):
    r = subprocess.run(["su", "postgres", "-c", "psql -X -q -tA -v ON_ERROR_STOP=1 -v VERBOSITY=default -d %s" % db],
                       input=sql, capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def lit(v):
    if v is None:
        return "null"
    if isinstance(v, (dict, list)):
        v = json.dumps(v)
    elif isinstance(v, bool):
        v = "true" if v else "false"
    return "'" + str(v).replace("'", "''") + "'"


def rpc(route, request):
    m = re.search(r"/rpc/([a-z_]+)/([a-z_]+)$", request.url)
    body = json.loads(request.post_data or "{}")
    if not m or m.group(1) != "erp_api":
        return route.fulfill(status=200, content_type="application/json", body=json.dumps({"data": None, "error": {"message": "bad schema"}}))
    claims = json.dumps({"sub": body.get("sub"), "email": body.get("email"), "role": "authenticated"})
    args = ", ".join("%s => %s" % (k, lit(v)) for k, v in sorted(body.get("args", {}).items()) if re.match(r"^p_[a-z_]+$", k))
    sql = "begin;\nset local role authenticated;\nselect set_config('request.jwt.claims', %s, true) is null;\nselect (erp_api.%s(%s))::text;\ncommit;\n" % (lit(claims), m.group(2), args)
    code, out, err = psql(sql)
    if code == 0:
        val = out.strip().splitlines()[-1] if out.strip() else ""
        res = {"data": json.loads(val) if val else None, "error": None}
    else:
        em = re.search(r"ERROR:\s+(.*)", err)
        dm = re.search(r"DETAIL:\s+(.*)", err)
        msg = em.group(1).strip() if em else err.strip()
        res = {"data": None, "error": {"message": msg, "details": dm.group(1).strip() if dm else None,
                                       "code": "PGRST202" if "does not exist" in msg else "P0001"}}
    route.fulfill(status=200, content_type="application/json", body=json.dumps(res))


def page(br, sub, email, hash_=""):
    pg = br.new_context(viewport={"width": 1280, "height": 860}).new_page()
    pg.on("pageerror", lambda e: errors.append("pageerror(%s): %s" % (email, e)))
    pg.on("dialog", lambda d: (errors.append("unexpected native dialog: " + d.message), d.dismiss()))
    pg.add_init_script("localStorage.setItem('bridge_sub', %s); localStorage.setItem('bridge_email', %s);" % (json.dumps(sub), json.dumps(email)))
    pg.route("**/supabase.min.js", lambda r: r.fulfill(path=str(bridge), content_type="application/javascript"))
    pg.route("http://erp-bridge.test/**", rpc)
    pg.route("https://**", lambda r: r.abort())
    pg.goto(html.as_uri() + hash_)
    return pg


# fresh database with every E file (as the owner role, like the SQL editor)
tmp = pathlib.Path(tempfile.mkdtemp(prefix="erp_ui_"))
for f in sorted(backend.glob("E[0-9]*.sql")):
    shutil.copy(f, tmp / f.name)
os.chmod(tmp, 0o755)
for f in tmp.iterdir():
    os.chmod(f, 0o644)
psql("drop database if exists %s;\ncreate database %s;\n" % (DB, DB), db="postgres")
for f in sorted(tmp.glob("E*.sql")):
    c, o, e = psql("\\i %s\n" % f)
    if c != 0:
        errors.append("load %s: %s" % (f.name, e[-300:]))
psql("select erp.tenant_onboard('uitest', 'UI Test', 'owner@ui.test');")
OWNER, ANNA, STRANGER = "00000000-0000-4000-9000-000000000001", "00000000-0000-4000-9000-000000000002", "00000000-0000-4000-9000-000000000003"

with sync_playwright() as p:
    br = p.chromium.launch()
    pg = page(br, OWNER, "owner@ui.test")
    pg.wait_for_selector("#home-lead", timeout=15000)
    check("UI Test" in pg.inner_text(".top") and "Owner" in pg.inner_text("#home-lead") and "No branch" in pg.inner_text("#main"),
          "first sign-in: member_bind binds the invitation, whoami -> owner of an empty tenant")
    check(psql("select bound_at is not null from erp.members where email = 'owner@ui.test';")[1].strip() == "t", "DB: the owner invitation is bound")
    pg.click("#nav a[data-to=admin]"); pg.wait_for_selector("#m-table")
    pg.click("#adm-tabs a[data-sub=branches]"); pg.wait_for_selector("#b-table")
    pg.click("[data-act=branch-new]"); pg.fill("#b-code", "SER"); pg.fill("#b-name", "Serres"); pg.fill("#b-estab", "0")
    pg.click("#d-save"); pg.wait_for_selector("#drawer", state="detached")
    pg.wait_for_function("document.querySelectorAll('#b-table tbody tr.click').length === 1")
    check(psql("select b.code || '/' || b.establishment_no from erp.branches b join erp.tenants t using (tenant_id) where t.code = 'uitest';")[1].strip() == "SER/0",
          "add branch: row in the DB")
    pg.click("[data-act=branch-new]"); pg.fill("#b-code", "ser"); pg.fill("#b-name", "Again"); pg.click("#d-save")
    pg.wait_for_function("document.getElementById('d-msg').textContent.length > 0")
    check("Not saved" in pg.inner_text("#d-msg") and "already used" in pg.inner_text("#d-msg"), "duplicate code: server problem list shown ('Not saved')")
    pg.click("#drawer header [data-act=drawer-close]"); pg.click("#modal-ok"); pg.wait_for_selector("#drawer", state="detached")
    pg.click("#adm-tabs a[data-sub=members]"); pg.wait_for_selector("#m-table")
    pg.click("[data-act=member-new]"); pg.fill("#m-email", "Anna@UI.test"); pg.select_option("#m-role", "clinic_user")
    pg.check("#m-branches input"); pg.click("#d-save"); pg.wait_for_selector("#drawer", state="detached")
    pg.wait_for_function("document.querySelectorAll('#m-table tbody tr.click').length === 2")
    check("anna@ui.test" in pg.inner_text("#m-table") and "Invited" in pg.inner_text("#m-table"), "invite: pending member listed")
    pg.click("#adm-tabs a[data-sub=settings]"); pg.wait_for_selector("#s-form")
    pg.fill("#s-lock", "31/01/2026"); pg.click("#s-save")
    pg.wait_for_function("document.getElementById('s-lock') && document.getElementById('s-lock').value === '31/01/2026' && !document.getElementById('s-save').disabled")
    pg.wait_for_timeout(300)
    check(psql("select lock_date || '/' || version from erp.tenant_settings s join erp.tenants t using (tenant_id) where t.code = 'uitest';")[1].strip() == "2026-01-31/2",
          "settings: lock date saved as a date, version 2")
    check(psql("select count(*) from erp.audit_log a join erp.tenants t using (tenant_id) where t.code = 'uitest' and a.action <> 'tenant.onboard';")[1].strip() == "4",
          "audit: bind, branch, invite, settings = 4 rows")
    # master data against the real database (T07)
    pg.goto(html.as_uri() + "#/master/warehouses"); pg.wait_for_selector("#md-table")
    pg.click("#md-new"); pg.wait_for_selector("#drawer"); pg.fill("#w-code", "SER-MAIN"); pg.fill("#w-name", "Serres main")
    pg.click("#d-save"); pg.wait_for_selector("#drawer", state="detached")
    check(psql("select w.code || '/' || b.code from erp.warehouses w join erp.branches b using (tenant_id, branch_id) join erp.tenants t using (tenant_id) where t.code = 'uitest';")[1].strip()
          == "SER-MAIN/SER", "master: warehouse saved in the DB under the only branch")
    pg.goto(html.as_uri() + "#/master/items"); pg.wait_for_selector("#md-table")
    pg.click("#md-new"); pg.wait_for_selector("#drawer"); pg.fill("#i-code", "BR-1"); pg.fill("#i-name", "Bracket"); pg.select_option("#i-unit", label="PCS · Pieces")
    pg.fill("#i-bc", "4006381333932"); pg.click("#d-save")
    pg.wait_for_function("document.getElementById('d-msg').textContent.length > 0")
    check("wrong check digit" in pg.inner_text("#d-msg"), "master: the server's EAN check-digit problem is shown")
    pg.fill("#i-bc", "4006381333931"); pg.fill("#i-price", "12,5"); pg.click("#d-save"); pg.wait_for_selector("#drawer", state="detached")
    check(psql("select i.code || '/' || i.sales_price || '/' || b.barcode from erp.items i join erp.item_barcodes b using (tenant_id, item_id) join erp.tenants t using (tenant_id) where t.code = 'uitest';")[1].strip()
          == "BR-1/12.5000/4006381333931", "master: item with price (comma decimal) and barcode saved in the DB")
    # stock against the real database (T14): series by "Create missing", a supplier, GRN posted, CONS past zero with ack
    pg.goto(html.as_uri() + "#/master/series"); pg.wait_for_selector("#s-def-go")
    pg.click("#s-def-go"); pg.wait_for_function("document.getElementById('toast') && document.getElementById('toast').textContent.indexOf('created') >= 0")
    psql("insert into erp.counterparties (tenant_id, name, kind) select tenant_id, 'Dental Depot', 'supplier' from erp.tenants where code = 'uitest';")
    pg.goto(html.as_uri() + "#/stock/documents"); pg.wait_for_selector("#stk-new")
    pg.select_option("#stk-newtype", "GRN"); pg.click("#stk-new"); pg.wait_for_selector("#doc-lines")
    pg.select_option("#d-wh", label="SER-MAIN · Serres main"); pg.select_option("#d-cp", label="Dental Depot")
    pg.fill("#doc-lines .dl-code", "4006381333931"); pg.press("#doc-lines .dl-code", "Tab")
    pg.wait_for_function("document.querySelector('#doc-lines .dl-name').textContent.indexOf('Bracket') >= 0")
    pg.fill("#doc-lines .dl-qty", "10"); pg.fill("#doc-lines .dl-price", "2,5")
    pg.click("#d-save"); pg.wait_for_selector("#drawer footer [data-act=doc-action]")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]")
    pg.wait_for_function("document.getElementById('drawer') && document.getElementById('drawer').textContent.indexOf('Posted') >= 0")
    check(psql("select d.doc_no || '/' || b.qty || '/' || c.value_avg from erp.documents d join erp.tenants t using (tenant_id) join erp.stock_balances b on b.tenant_id = d.tenant_id "
               "join erp.item_costs c on c.tenant_id = d.tenant_id and c.item_id = b.item_id where t.code = 'uitest' and d.doc_type = 'GRN';")[1].strip() == "GRN-SER/000001/10.0000/25.00",
          "stock: GRN found the item by barcode, posted GRN-SER/000001, 10 in stock at 25.00")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")
    pg.select_option("#stk-newtype", "CONS"); pg.click("#stk-new"); pg.wait_for_selector("#doc-lines")
    pg.select_option("#d-wh", label="SER-MAIN · Serres main"); pg.fill("#doc-lines .dl-code", "BR-1"); pg.press("#doc-lines .dl-code", "Tab")
    pg.wait_for_function("document.querySelector('#doc-lines .dl-name').textContent.indexOf('Bracket') >= 0"); pg.fill("#doc-lines .dl-qty", "12")
    pg.click("#d-save")
    pg.wait_for_selector("#drawer footer [data-act=doc-action]")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]"); pg.wait_for_selector("#modal-text")
    check("BR-1" in pg.inner_text("#modal-text") and "-2" in pg.inner_text("#modal-text") and
          psql("select count(*) from erp.documents d join erp.tenants t using (tenant_id) where t.code = 'uitest' and d.doc_type = 'CONS' and d.state = 'draft';")[1].strip() == "1",
          "stock: the real negative-stock warning is shown, the CONS is still a draft")
    pg.click("#modal-ok")
    pg.wait_for_function("document.getElementById('drawer') && document.getElementById('drawer').textContent.indexOf('Posted') >= 0")
    check(psql("select b.qty || '/' || (select count(*) from erp.alerts a where a.tenant_id = b.tenant_id and a.kind = 'negative_stock' and a.resolved_at is null) "
               "from erp.stock_balances b join erp.tenants t using (tenant_id) where t.code = 'uitest';")[1].strip() == "-2.0000/1",
          "stock: Post anyway -> balance -2 and one negative-stock alert in the DB")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")
    # transfers against the real database (T18): SER -> THE, dispatch past zero (ack), receipt short by 2 with a reason,
    # the generated ADJ_OUT out of TRANSIT posted -> the transfer closes, transit empty, integrity clean
    TQ = "from erp.documents d join erp.tenants t using (tenant_id) where t.code = 'uitest' and d.doc_type = "
    psql("insert into erp.branches (tenant_id, code, name, establishment_no) select tenant_id, 'THE', 'Thessaloniki', 1 from erp.tenants where code = 'uitest';\n"
         "insert into erp.warehouses (tenant_id, branch_id, code, name) select b.tenant_id, b.branch_id, 'THE-MAIN', 'Thessaloniki main' from erp.branches b "
         "join erp.tenants t using (tenant_id) where t.code = 'uitest' and b.code = 'THE';\n")
    pg.goto(html.as_uri() + "#/master/series"); pg.reload(); pg.wait_for_selector("#s-def-go")   # whoami again (new branch); its series: the ADJ takes a number
    pg.wait_for_function("__calls.filter(c => c.name === 'series_list').length >= 1")
    pg.select_option("#s-def-branch", value=psql("select branch_id from erp.branches where code = 'THE';")[1].strip())
    pg.click("#s-def-go"); pg.wait_for_function("__calls.filter(c => c.name === 'series_create_defaults').length >= 1")
    for _ in range(60):
        if psql("select count(*) from erp.series s join erp.branches b using (tenant_id, branch_id) where b.code = 'THE';")[1].strip() not in ("", "0"):
            break
        pg.wait_for_timeout(250)
    pg.goto(html.as_uri() + "#/transfers"); pg.wait_for_selector("#trf-new")
    pg.click("#trf-new"); pg.wait_for_selector("#d-dest")
    pg.select_option("#d-wh", label="SER-MAIN · Serres main"); pg.select_option("#d-dest", label="THE-MAIN · Thessaloniki main (THE)")
    pg.fill("#doc-lines .dl-code", "BR-1"); pg.press("#doc-lines .dl-code", "Tab")
    pg.wait_for_function("document.querySelector('#doc-lines .dl-name').textContent.indexOf('Bracket') >= 0"); pg.fill("#doc-lines .dl-qty", "5")
    pg.click("#d-save"); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=dispatched]")
    check("not a fiscal document" in pg.inner_text("#trf-fiscal") and "establishments" in pg.inner_text("#trf-fiscal"), "transfer: trf_get fiscal note, fiscal_needed between SER and THE")
    pg.click("#drawer footer [data-act=doc-action][data-to=dispatched]"); pg.wait_for_selector("#modal-text")
    check("BR-1" in pg.inner_text("#modal-text") and "-7" in pg.inner_text("#modal-text"), "transfer: the real negative-stock warning on dispatch")
    pg.click("#modal-ok")
    pg.wait_for_function("document.getElementById('drawer') && document.getElementById('drawer').textContent.indexOf('Dispatched') >= 0")
    tw = "(select warehouse_id from erp.warehouses w join erp.tenants t using (tenant_id) where t.code = 'uitest' and w.kind = 'in_transit')"
    check(psql("select d.state || '/' || d.doc_no || '/' || (select qty from erp.stock_balances where warehouse_id = %s) %s 'TRF';" % (tw, TQ))[1].strip().startswith("dispatched/TRF")
          and psql("select qty from erp.stock_balances where warehouse_id = %s;" % tw)[1].strip() == "5.0000", "transfer: dispatched with a number, 5 in transit")
    pg.click("#drawer footer [data-act=trf-receive]"); pg.wait_for_selector("#rc-lines")
    pg.fill("#rc-lines .rc-qty", "3"); pg.fill("#rc-lines .rc-reason", "2 broken"); pg.click("#trf-receive-go")
    pg.wait_for_function("document.getElementById('trf-adjs') && document.getElementById('drawer').textContent.indexOf('Received with difference') >= 0")
    check(psql("select (select string_agg(w.code || '=' || b.qty, ',' order by w.code) from erp.stock_balances b join erp.warehouses w using (tenant_id, warehouse_id) "
               "where b.tenant_id = d.tenant_id and w.code in ('THE-MAIN', 'TRANSIT')) || '/' || (select a.state from erp.documents a where a.ref_document_id = d.document_id and a.doc_type = 'ADJ_OUT') "
               "%s 'TRF';" % TQ)[1].strip() == "THE-MAIN=3.0000,TRANSIT=2.0000/draft",
          "receipt by line: 3 in THE-MAIN, the shortage of 2 stays in transit, ADJ_OUT draft generated")
    pg.click("#trf-adjs a[data-act=stk-doc]"); pg.wait_for_selector("#d-wh-ro")
    check(pg.input_value("#d-wh-ro") == "TRANSIT" and pg.locator("#doc-lines .dl-code[disabled]").count() == 1, "generated ADJ_OUT: TRANSIT read-only, lines fixed")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]")
    pg.wait_for_function("document.getElementById('drawer') && document.getElementById('drawer').textContent.indexOf('Posted') >= 0")
    check(psql("select d.state || '/' || (select qty from erp.stock_balances where warehouse_id = %s) || '/' || jsonb_array_length(erp.trf_integrity(d.tenant_id)) "
               "|| '/' || jsonb_array_length(erp.stock_integrity(d.tenant_id)) %s 'TRF';" % (tw, TQ))[1].strip() == "closed/0.0000/0/0",
          "ADJ_OUT posted: the transfer is closed, transit empty, transfer + stock integrity clean")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")
    pg.wait_for_function("document.getElementById('trf-table') && document.getElementById('trf-table').textContent.indexOf('Closed') >= 0")
    check("THE-MAIN" in pg.inner_text("#trf-table"), "transfers list: closed, destination code")
    # expenses against the real database (T20-lite): an EXP of SER (the series came with "Create missing" above), the
    # category's default VAT, paid by cash, posted with a number; report by category; cancel with a reason; new category
    EQ = "from erp.documents d join erp.tenants t using (tenant_id) where t.code = 'uitest' and d.doc_type = 'EXP'"
    cat = lambda c: psql("select category_id from erp.expense_categories e join erp.tenants t using (tenant_id) where t.code = 'uitest' and e.code = '%s';" % c)[1].strip()
    pg.goto(html.as_uri() + "#/expenses"); pg.wait_for_selector("#exp-new")
    pg.click("#exp-new"); pg.wait_for_selector("#doc-lines .exl")
    pg.select_option("#d-branch", label="SER · Serres"); pg.select_option("#d-cp", label="Dental Depot"); pg.fill("#d-extno", "A-991")
    pg.check("#d-paid"); pg.select_option("#d-pm", "cash")
    pg.select_option("#doc-lines .exl .dl-cat", cat("UTIL")); pg.fill("#doc-lines .exl .dl-net", "10.05")
    check(pg.locator("#doc-lines .exl .dl-vat option:checked").inner_text().startswith("VAT24") and "€2.41" in pg.inner_text("#doc-lines .exl .dl-amt"),
          "expense: UTIL brings VAT24 (the tenant's default categories), VAT 2.41 shown before saving")
    pg.click("#d-save"); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=posted]")
    check(pg.inner_text("#doc-totals") == "Net €10.05 · VAT €2.41 · gross €12.46", "expense: saved draft totals from the server")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]")
    pg.wait_for_function("document.getElementById('drawer') && document.getElementById('drawer').textContent.indexOf('Posted') >= 0")
    check(psql("select d.state || '/' || d.doc_no || '/' || d.total_gross || '/' || (d.extra ->> 'payment_method') || '/' "
               "|| (select c.name from erp.counterparties c where c.tenant_id = d.tenant_id and c.counterparty_id = d.counterparty_id) %s;" % EQ)[1].strip() == "posted/EXP-SER/000001/12.46/cash/Dental Depot",
          "expense posted in the DB: EXP-SER/000001, gross 12.46, paid by cash, supplier")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")
    pg.click("#exp-tabs a[data-sub=report]"); pg.wait_for_selector("#exr-table")
    check("UTIL" in pg.inner_text("#exr-table") and "€12.46" in pg.inner_text("#exr-table"), "report by category from report_expenses")
    pg.click("#exp-tabs a[data-sub=list]"); pg.wait_for_selector("#exp-table tbody tr.click")
    pg.click("#exp-table tbody tr.click:has-text('EXP-SER/000001')"); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=cancelled]")
    pg.click("#drawer footer [data-act=doc-action][data-to=cancelled]"); pg.wait_for_selector("#modal-input")
    pg.fill("#modal-input", "entered twice"); pg.click("#modal-ok")
    pg.wait_for_function("document.getElementById('drawer') && document.getElementById('drawer').textContent.indexOf('Cancelled') >= 0")
    check(psql("select d.state || '/' || d.doc_no || '/' || d.cancel_reason %s;" % EQ)[1].strip() == "cancelled/EXP-SER/000001/entered twice",
          "expense cancelled in the DB with its reason, number kept")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")
    pg.click("#exp-tabs a[data-sub=categories]"); pg.wait_for_selector("#exc-new")
    pg.click("#exc-new"); pg.wait_for_selector("#ec-code"); pg.fill("#ec-code", "LAB"); pg.fill("#ec-name", "Dental lab"); pg.select_option("#ec-vat", label="VAT24 (24%)")
    pg.click("#d-save"); pg.wait_for_function("document.getElementById('exc-table') && document.getElementById('exc-table').textContent.indexOf('LAB') >= 0")
    check(psql("select e.name || '/' || v.code from erp.expense_categories e join erp.vat_classes v on v.tenant_id = e.tenant_id and v.vat_class_id = e.default_vat_class_id "
               "join erp.tenants t on t.tenant_id = e.tenant_id where t.code = 'uitest' and e.code = 'LAB';")[1].strip() == "Dental lab/VAT24",
          "new expense category saved in the DB with its default VAT")
    pg.context.close()

    pg = page(br, ANNA, "anna@ui.test")
    pg.wait_for_selector("#home-lead", timeout=15000)
    check("Clinic user" in pg.inner_text("#home-lead") and pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock"] and "SER" in pg.inner_text("#main"),
          "invited member signs in: bound, role clinic_user, own branch, no Admin")
    pg.context.close()

    pg = page(br, STRANGER, "stranger@ui.test")
    pg.wait_for_selector("#noaccess", timeout=15000)
    check("stranger@ui.test" in pg.inner_text("#noaccess"), "stranger: No access")
    pg.context.close()
    br.close()

psql("drop database if exists %s;" % DB, db="postgres") if not os.environ.get("KEEP_DB") else None
shutil.rmtree(tmp, ignore_errors=True)
for m in ok:
    print("PASS:", m)
for m in errors:
    print("FAIL:", m)
print("smoke_erp_db: %d passed, %d failed" % (len(ok), len(errors)))
sys.exit(1 if errors else 0)
