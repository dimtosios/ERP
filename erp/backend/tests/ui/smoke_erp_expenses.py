"""Smoke test (T20-lite): Expenses screen. Nav entry by caps, list (state / branch filters, paid badge), new expense
(branch, supplier, supplier's number, paid on the spot + method, lines by category: the category brings its default VAT
class, VAT and gross shown per line; inactive categories hidden), save payload, totals net / VAT / gross, post, cancel of
a posted expense with a reason, approval limit (accounting above the limit only submits), categories admin (list, new
with parent and default VAT), report by category / supplier with totals and the CSV download, the expense limit in
Admin > Settings, server problems ("Not saved"), phone width, roles (readonly: no New; clinic_user: no menu).
Stubbed supabase-js, no network.
usage (repo root): python3 -I erp/backend/tests/ui/smoke_erp_expenses.py erp.html erp/backend/tests/ui/mock_supabase_erp.js"""
import sys, pathlib, json
from playwright.sync_api import sync_playwright

html, mock = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
errors, ok = [], []


def check(cond, msg):
    (ok if cond else errors).append(msg)


def calls(pg, name):
    return pg.evaluate("n => __calls.filter(c => c.name === n)", name)


def wait_calls(pg, name, n):
    pg.wait_for_function("([n, k]) => __calls.filter(c => c.name === n).length >= k", arg=[name, n])


def wait_text(pg, sel, text):
    pg.wait_for_function("([s, t]) => { const e = document.querySelector(s); return !!e && e.textContent.indexOf(t) >= 0; }", arg=[sel, text])


def page(br, role, w=1280, h=860, hash_="#/expenses", wait="#exp-bar", limit=None):
    pg = br.new_context(viewport={"width": w, "height": h}, accept_downloads=True).new_page()
    pg.on("console", lambda m: m.type == "error" and errors.append("console(%s): %s" % (role, m.text)))
    pg.on("pageerror", lambda e: errors.append("pageerror(%s): %s" % (role, e)))
    pg.on("dialog", lambda d: (errors.append("unexpected native dialog: " + d.message), d.dismiss()))
    pg.add_init_script("try{localStorage.setItem('mock_role',%s);localStorage.setItem('mock_session','1');%s}catch(e){}"
                       % (json.dumps(role), ("localStorage.setItem('mock_exp_limit','%s')" % limit) if limit is not None else "localStorage.removeItem('mock_exp_limit')"))
    pg.route("**/supabase.min.js", lambda r: r.fulfill(path=str(mock), content_type="application/javascript"))
    pg.route("https://**", lambda r: r.abort() if "supabase.min.js" not in r.request.url else r.fallback())
    pg.goto(html.as_uri() + hash_)
    pg.wait_for_selector(wait)
    return pg


def line(pg, i):
    return "#doc-lines .exl:nth-of-type(%d) " % (i + 1)


def scenario(br):

    # ---------- owner: list, filters ----------
    pg = page(br, "owner")
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock", "Transfers", "Expenses", "Sales", "Admin"], "owner nav has Expenses")
    wait_text(pg, "#exp-table", "EXP-SER/000001")
    txt = pg.inner_text("#exp-table")
    check("EXP-THE/000001" in txt and "Ortho Supplies SA" in txt and "INV-55" in txt and "€124.00" in txt and "Card" in txt and "Not paid" in txt,
          "list: both expenses, supplier, supplier's number, gross, paid badge / not paid")
    check(calls(pg, "doc_list")[0]["args"]["p_filter"] == {"doc_type": "EXP"}, "list: doc_list doc_type EXP")
    pg.select_option("#exp-state", "draft"); wait_calls(pg, "doc_list", 2); wait_text(pg, "#exp-table", "No expense.")
    check(calls(pg, "doc_list")[1]["args"]["p_filter"] == {"doc_type": "EXP", "state": "draft"}, "filter by state")
    pg.select_option("#exp-state", ""); pg.select_option("#exp-branch", "b2"); wait_calls(pg, "doc_list", 4)
    check(calls(pg, "doc_list")[-1]["args"]["p_filter"] == {"doc_type": "EXP", "branch_id": "b2"}, "filter by branch")
    pg.select_option("#exp-branch", ""); wait_calls(pg, "doc_list", 5); wait_text(pg, "#exp-table", "EXP-SER/000001")

    # ---------- new expense: two lines, paid by cash ----------
    pg.click("#exp-new"); pg.wait_for_selector("#doc-lines .exl")
    cats = pg.locator(line(pg, 0) + ".dl-cat option").all_inner_texts()
    check(any("UTIL" in c for c in cats) and not any("OLD" in c for c in cats) and pg.locator("#d-wh").count() == 0 and pg.locator("#d-branch").count() == 1,
          "new expense: branch picker, no warehouse, active categories only %s" % cats)
    pg.select_option("#d-branch", "b1"); pg.select_option("#d-cp", "p1"); pg.fill("#d-extno", "ΤΔΑ-123"); pg.fill("#d-extdate", "17/11/2026")
    pg.check("#d-paid"); pg.select_option("#d-pm", "cash")
    pg.select_option(line(pg, 0) + ".dl-cat", "ec2")
    check(pg.input_value(line(pg, 0) + ".dl-vat") == "v1", "the category brings its default VAT class (UTIL -> VAT24)")
    pg.fill(line(pg, 0) + ".dl-desc", "Water"); pg.fill(line(pg, 0) + ".dl-net", "50")
    wait_text(pg, line(pg, 0) + ".dl-amt", "€62.00")
    check(pg.inner_text(line(pg, 0) + ".dl-amt") == "VAT €12.00 · gross €62.00", "line shows VAT and gross while typing")
    pg.click("#doc-line-add"); pg.select_option(line(pg, 1) + ".dl-cat", "ec1"); pg.fill(line(pg, 1) + ".dl-net", "200,5")
    check(pg.input_value(line(pg, 1) + ".dl-vat") == "v0", "RENT -> VAT0")
    pg.click("#d-save"); wait_calls(pg, "doc_save_draft", 1); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=posted]")
    sv = calls(pg, "doc_save_draft")[0]["args"]
    check(sv["p_type"] == "EXP" and sv["p_doc"]["branch_id"] == "b1" and sv["p_doc"]["counterparty_id"] == "p1" and sv["p_doc"]["ext_number"] == "ΤΔΑ-123"
          and sv["p_doc"]["ext_date"] == "2026-11-17" and sv["p_doc"]["extra"] == {"paid": True, "payment_method": "cash"} and "warehouse_id" in sv["p_doc"] and sv["p_doc"]["warehouse_id"] is None,
          "save payload: branch, supplier, supplier's number / date, paid + method %s" % {k: v for k, v in sv["p_doc"].items() if k != "lines"})
    check(sv["p_doc"]["lines"] == [{"expense_category_id": "ec2", "qty": 1, "vat_class_id": "v1", "unit_price": "50", "description": "Water"},
                                   {"expense_category_id": "ec1", "qty": 1, "vat_class_id": "v0", "unit_price": "200.5"}], "save payload: lines by category, qty 1, net as unit price %s" % sv["p_doc"]["lines"])
    check(pg.inner_text("#doc-totals") == "Net €250.50 · VAT €12.00 · gross €262.50" and pg.input_value("#d-branch-ro") == "SER", "saved draft: totals net / VAT / gross, branch fixed")
    check(pg.locator("#drawer footer [data-act=doc-delete]").count() == 1 and pg.locator("#drawer footer [data-act=doc-copy]").count() == 1, "draft: delete and copy offered")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]"); wait_calls(pg, "doc_set_state", 1); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=cancelled]")
    check(calls(pg, "doc_set_state")[0]["args"]["p_to_state"] == "posted" and "EXP-SER/" in pg.inner_text("#drawer header") and pg.locator("#doc-lines .dl-net[disabled]").count() == 2,
          "posted: number in the title, lines read-only, Cancel offered")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")

    # ---------- cancel a posted expense with a reason ----------
    wait_text(pg, "#exp-table", "EXP-SER/000001")
    pg.click("#exp-table tbody tr.click:has-text('EXP-SER/000001')"); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=cancelled]")
    check("Electricity" in pg.input_value(line(pg, 0) + ".dl-desc") and pg.inner_text(line(pg, 0) + ".dl-amt") == "VAT €24.00 · gross €124.00" and pg.is_checked("#d-paid"),
          "open a posted expense: line amounts from the server, paid flag")
    n = len(calls(pg, "doc_set_state"))
    pg.click("#drawer footer [data-act=doc-action][data-to=cancelled]"); pg.wait_for_selector("#modal-ok")
    pg.fill("#modal-root input", "Duplicate of INV-55"); pg.click("#modal-ok"); wait_calls(pg, "doc_set_state", n + 1)
    c = calls(pg, "doc_set_state")[-1]["args"]
    check(c["p_to_state"] == "cancelled" and c["p_options"] == {"reason": "Duplicate of INV-55"}, "cancel sends the reason")
    wait_text(pg, "#drawer", "Cancelled")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")

    # ---------- categories ----------
    pg.click("#exp-tabs a[data-sub=categories]"); pg.wait_for_selector("#exc-table")
    ct = pg.inner_text("#exc-table")
    check("RENT" in ct and "VAT24 (24%)" in ct and "Inactive" in ct, "categories: code, default VAT, inactive badge")
    pg.click("#exc-new"); pg.wait_for_selector("#ec-code")
    pg.fill("#ec-code", "WATER"); pg.fill("#ec-name", "Water"); pg.select_option("#ec-parent", "ec2"); pg.select_option("#ec-vat", "v2")
    pg.click("#d-save"); wait_calls(pg, "expense_category_save", 1); wait_text(pg, "#exc-table", "UTIL / WATER")
    check(calls(pg, "expense_category_save")[0]["args"]["p_category"] == {"code": "WATER", "name": "Water", "parent_id": "ec2", "default_vat_class_id": "v2"},
          "new category: code, name, parent, default VAT")
    pg.click("#exc-table tbody tr.click:has-text('WATER')"); pg.wait_for_selector("#ec-active")
    pg.uncheck("#ec-active"); pg.click("#d-save"); wait_calls(pg, "expense_category_save", 2)
    check(calls(pg, "expense_category_save")[1]["args"]["p_category"].get("active") is False, "edit: deactivate")
    pg.wait_for_selector("#drawer", state="detached")

    # ---------- report ----------
    pg.click("#exp-tabs a[data-sub=report]"); pg.wait_for_selector("#exr-table")
    check(pg.input_value("#exr-from") == "01/11/2026" and pg.input_value("#exr-to") == "18/11/2026", "report: this month by default")
    r0 = calls(pg, "report_expenses")[0]["args"]["p_filter"]
    check(r0 == {"group_by": "category", "date_from": "2026-11-01", "date_to": "2026-11-18"}, "report call %s" % r0)
    rt = pg.inner_text("#exr-table")
    check("RENT" in rt and "€700.50" in rt and "Total" in rt, "report by category: rows and total (cancelled out) %s" % rt.replace("\n", " | "))
    pg.select_option("#exr-group", "supplier"); wait_calls(pg, "report_expenses", 2); wait_text(pg, "#exr-table", "(no supplier)")
    check(calls(pg, "report_expenses")[-1]["args"]["p_filter"]["group_by"] == "supplier", "report by supplier")
    with pg.expect_download() as dl:
        pg.click("#exr-csv")
    d = dl.value
    body = pathlib.Path(d.path()).read_text(encoding="utf-8")
    check(d.suggested_filename == "expenses_supplier_2026-11-01_2026-11-18.csv" and body.startswith("supplier,supplier_code,documents,net,vat,gross,paid_on_the_spot")
          and "TOTAL" in body, "CSV download: name, header, total row")
    pg.fill("#exr-from", "31/02/2026"); pg.click("#exr-run")
    wait_text(pg, "#exp-body", "Dates: dd/mm/yyyy.")
    check(True, "report: bad date refused in the page")

    # ---------- expense limit in Admin > Settings ----------
    pg.click("#nav a[data-to=admin]"); pg.wait_for_selector("#adm-tabs a[data-sub=settings]"); pg.click("#adm-tabs a[data-sub=settings]")
    pg.wait_for_selector("#s-explim")
    pg.fill("#s-explim", "300"); pg.click("#s-save"); wait_calls(pg, "settings_save", 1)
    check(calls(pg, "settings_save")[0]["args"]["p_settings"].get("thresholds") == {"exp_value": 300}, "settings: expense limit saved as thresholds.exp_value")
    pg.context.close()

    # ---------- accounting above the limit: submit only; phone width ----------
    pg = page(br, "accounting", w=390, h=800, limit=100)
    check("Expenses" in pg.locator("#nav a").all_inner_texts(), "accounting has Expenses")
    pg.click("#exp-new"); pg.wait_for_selector("#doc-lines .exl")
    pg.select_option(line(pg, 0) + ".dl-cat", "ec3"); pg.fill(line(pg, 0) + ".dl-net", "400")
    check(pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1") and
          pg.evaluate("Array.from(document.querySelectorAll('#drawer input, #drawer select, #drawer footer button')).every(e => e.getBoundingClientRect().right <= window.innerWidth + 1)"),
          "phone width: the expense drawer fits")
    pg.click("#d-save"); wait_calls(pg, "doc_save_draft", 1); pg.wait_for_selector("#drawer footer [data-act=doc-action]")
    acts = pg.locator("#drawer footer [data-act=doc-action]").evaluate_all("a => a.map(x => x.getAttribute('data-to'))")
    check(acts == ["pending_approval"], "accounting above the limit: only Submit %s" % acts)
    pg.click("#drawer footer [data-act=doc-action][data-to=pending_approval]"); wait_text(pg, "#drawer", "Waiting for approval")
    check(pg.locator("#drawer footer [data-act=doc-action]").count() == 0, "pending: accounting has no approve")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")
    # server problems: Not saved
    # an init script (not a localStorage write before reload: a file:// reload can miss a write made just before it)
    pg.context.add_init_script("try{localStorage.setItem('mock_fail','doc_save_draft')}catch(e){}"); pg.reload(); pg.wait_for_selector("#exp-new")
    pg.click("#exp-new"); pg.wait_for_selector("#doc-lines"); pg.click("#d-save")
    pg.wait_for_function("(document.getElementById('d-msg') || {textContent: ''}).textContent.length > 0")
    check("Not saved" in pg.inner_text("#d-msg") and "Mock validation problem." in pg.inner_text("#d-msg"), "server problems: Not saved + list")
    pg.context.close()

    # ---------- readonly: reads, no New; clinic_user: no menu ----------
    pg = page(br, "readonly")
    wait_text(pg, "#exp-table", "EXP-SER/000001")
    check(pg.locator("#exp-new").count() == 0 and "EXP-THE/000001" not in pg.inner_text("#exp-table"), "readonly: list of its branch, no New")
    pg.click("#exp-tabs a[data-sub=categories]"); pg.wait_for_selector("#exc-table")
    check(pg.locator("#exc-new").count() == 0 and pg.locator("#exc-table tr.click").count() == 0, "readonly: categories read-only")
    pg.context.close()
    pg = page(br, "clinic_user", wait="#nav")
    check("Expenses" not in pg.locator("#nav a").all_inner_texts() and len(calls(pg, "expense_category_list")) == 0, "clinic_user: no Expenses menu, route guarded")
    pg.context.close()


with sync_playwright() as p:
    br = p.chromium.launch()
    try:
        scenario(br)
    except Exception as e:   # report where it stopped (the runner prints FAIL lines)
        errors.append("exception: %s" % str(e).replace("\n", " | ")[:600])
    br.close()

for m in ok:
    print("PASS:", m)
for m in errors:
    print("FAIL:", m)
print("smoke_erp_expenses: %d passed, %d failed" % (len(ok), len(errors)))
sys.exit(1 if errors else 0)
