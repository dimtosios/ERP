"""Smoke test (T18-lite): Transfers screen. Nav entry by caps, list with state badges and filters (state, branch), new
transfer (source, destination of ANOTHER branch from trf_warehouses, item by code, delivery, no price), dispatch with the
negative-stock dialog ("Dispatch anyway" = ack_warnings), fiscal note, receipt BY LINE with a difference (reason
required, to_state chosen from the quantities), per-line result, the generated ADJ_OUT (TRANSIT warehouse read-only,
lines fixed, no delete / copy), its post closes the transfer, cancel of a dispatched transfer with a reason, the
destination role at phone width (receive everything = 'received'), roles without doc.trf.read get no menu.
Stubbed supabase-js, no network.
usage (repo root): python3 -I erp/backend/tests/ui/smoke_erp_transfers.py erp.html erp/backend/tests/ui/mock_supabase_erp.js"""
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
    pg.wait_for_function("([s, t]) => { const e = document.querySelector(s); return e && e.textContent.indexOf(t) >= 0; }", arg=[sel, text])


def page(br, role, w=1280, h=860, hash_="#/transfers", wait="#trf-bar"):
    pg = br.new_context(viewport={"width": w, "height": h}).new_page()
    pg.on("console", lambda m: m.type == "error" and errors.append("console(%s): %s" % (role, m.text)))
    pg.on("pageerror", lambda e: errors.append("pageerror(%s): %s" % (role, e)))
    pg.on("dialog", lambda d: (errors.append("unexpected native dialog: " + d.message), d.dismiss()))
    pg.add_init_script("try{localStorage.setItem('mock_role',%s);localStorage.setItem('mock_session','1')}catch(e){}" % json.dumps(role))
    pg.route("**/supabase.min.js", lambda r: r.fulfill(path=str(mock), content_type="application/javascript"))
    pg.route("https://**", lambda r: r.abort() if "supabase.min.js" not in r.request.url else r.fallback())
    pg.goto(html.as_uri() + hash_)
    pg.wait_for_selector(wait)
    return pg


def close(pg):
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")


def scenario(br):

    # ---------- owner: list, filters ----------
    pg = page(br, "owner")
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock", "Transfers", "Expenses", "Admin"], "owner nav has Transfers")
    wait_text(pg, "#trf-table", "TRF-SER/000001")
    txt = pg.inner_text("#trf-table")
    check("TRF-THE/000003" in txt and "THE-MAIN" in txt and "Dispatched (in transit)" in txt and pg.locator("#trf-table .badge.warn").count() == 2,
          "list: both transfers, destination code from trf_warehouses, dispatched badge")
    check(calls(pg, "doc_list")[0]["args"]["p_filter"] == {"doc_type": "TRF"}, "list: doc_list doc_type TRF")
    pg.select_option("#trf-state", "closed"); wait_calls(pg, "doc_list", 2); wait_text(pg, "#trf-table", "No transfer.")
    check(calls(pg, "doc_list")[1]["args"]["p_filter"] == {"doc_type": "TRF", "state": "closed"}, "filter by state")
    pg.select_option("#trf-state", ""); pg.select_option("#trf-branch", "b3"); wait_calls(pg, "doc_list", 4)
    check(calls(pg, "doc_list")[-1]["args"]["p_filter"] == {"doc_type": "TRF", "branch_id": "b3"}, "filter by branch")
    pg.select_option("#trf-branch", ""); wait_calls(pg, "doc_list", 5); wait_text(pg, "#trf-table", "TRF-SER/000001")

    # ---------- new transfer, dispatch past zero ----------
    pg.click("#trf-new"); pg.wait_for_selector("#doc-lines")
    dest = pg.locator("#d-dest option").all_inner_texts()
    check(any("ALE-MAIN" in o and "(ALE)" in o for o in dest) and pg.locator("#doc-lines .dl-price").count() == 0 and pg.locator("#d-carrier").count() == 1,
          "new transfer: destinations of every branch with branch code, no price, delivery fields %s" % dest)
    pg.select_option("#d-wh", "w1"); pg.select_option("#d-dest", "w2"); pg.fill("#d-carrier", "ACS")
    pg.fill("#doc-lines .dl-code", "IT-002"); pg.press("#doc-lines .dl-code", "Tab"); wait_text(pg, "#doc-lines .dl-name", "Wire 2")
    pg.fill("#doc-lines .dl-qty", "5")
    pg.click("#d-save"); wait_calls(pg, "doc_save_draft", 1); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=dispatched]")
    sv = calls(pg, "doc_save_draft")[0]["args"]
    check(sv["p_type"] == "TRF" and sv["p_doc"]["warehouse_id"] == "w1" and sv["p_doc"]["dest_warehouse_id"] == "w2" and sv["p_doc"]["branch_id"] == "b1"
          and sv["p_doc"]["extra"] == {"delivery": {"carrier": "ACS"}} and sv["p_doc"]["lines"] == [{"item_id": "i2", "qty": "5"}],
          "save payload: source, destination, branch, delivery, lines without price %s" % sv["p_doc"])
    check(calls(pg, "trf_get") and "Internal transfer, not a fiscal document (v1)." in pg.inner_text("#trf-fiscal") and "establishments" in pg.inner_text("#trf-fiscal"),
          "saved draft reopened through trf_get: fiscal note (+ fiscal_needed)")
    check(pg.inner_text("#drawer footer [data-act=doc-action][data-to=dispatched]") == "Dispatch", "Dispatch label from the action string")
    n0 = len(calls(pg, "doc_set_state"))
    pg.click("#drawer footer [data-act=doc-action][data-to=dispatched]"); pg.wait_for_selector("#modal-text")
    check("IT-002" in pg.inner_text("#modal-text") and "-8" in pg.inner_text("#modal-text") and pg.inner_text("#modal-ok") == "Dispatch anyway",
          "dispatch past zero: warning dialog, 'Dispatch anyway'")
    pg.click("#modal-ok"); wait_calls(pg, "doc_set_state", n0 + 2); wait_text(pg, "#drawer", "Dispatched (in transit)")
    st = calls(pg, "doc_set_state")
    check(st[n0]["args"]["p_options"] == {} and st[n0 + 1]["args"]["p_options"] == {"ack_warnings": True} and st[n0 + 1]["args"]["p_to_state"] == "dispatched",
          "dispatch: first without ack, then with ack_warnings")
    check("Dispatched" in pg.inner_text("#toast") and pg.locator("#trf-lines").count() == 1 and pg.locator("#drawer .dl-code[disabled]").count() == 1, "dispatched: read-only, per-line table")

    # ---------- owner also holds the destination: receipt by line with a difference ----------
    pg.click("#drawer footer [data-act=trf-receive]"); pg.wait_for_selector("#rc-lines")
    check(pg.locator("#drawer footer [data-act=trf-receive-go]").count() == 1 and pg.input_value("#rc-lines .rc-qty") == "5", "receipt form: one line, received = sent by default")
    pg.fill("#rc-lines .rc-qty", "3"); wait_text(pg, "#rc-summary", "Difference")
    pg.click("#trf-receive-go"); pg.wait_for_function("(document.getElementById('d-msg') || {textContent: ''}).textContent.length > 0")
    check("needs a reason" in pg.inner_text("#d-msg") and len(calls(pg, "doc_set_state")) == n0 + 2, "difference without reason: refused locally, nothing sent")
    pg.fill("#rc-lines .rc-reason", "2 broken in the box"); pg.fill("#rc-date", "18/11/2026"); pg.click("#trf-receive-go")
    wait_calls(pg, "doc_set_state", n0 + 3); wait_text(pg, "#drawer", "Received with difference")
    rc = calls(pg, "doc_set_state")[n0 + 2]["args"]
    check(rc["p_to_state"] == "received_with_difference" and rc["p_options"]["receipt_date"] == "2026-11-18" and len(rc["p_options"]["lines"]) == 1
          and rc["p_options"]["lines"][0]["received_qty"] == "3" and rc["p_options"]["lines"][0]["reason"] == "2 broken in the box" and rc.get("p_idempotency_key"),
          "receipt: received_with_difference, date, line qty + reason, idempotency key %s" % rc)
    pg.wait_for_selector("#trf-adjs")
    lt = pg.inner_text("#trf-lines")
    check("-2" in lt and "2 broken in the box" in lt and "draft" in pg.inner_text("#trf-adjs") and "posted" in pg.inner_text("#trf-wait"),
          "after receipt: difference and reason per line, ADJ draft listed, 'closed after the adjustment is posted'")

    # ---------- the generated ADJ_OUT: transit warehouse read-only ----------
    pg.click("#trf-adjs a[data-act=stk-doc]"); pg.wait_for_selector("#d-wh-ro")
    check(pg.input_value("#d-wh-ro") == "TRANSIT" and pg.locator("#d-wh-ro[disabled]").count() == 1 and "transit" in pg.inner_text("label[for=d-wh-ro]").lower(),
          "ADJ_OUT drawer: TRANSIT warehouse shown read-only")
    check(pg.locator("#doc-lines .dl-code[disabled]").count() == 1 and pg.locator("#doc-line-add").count() == 0 and pg.locator("[data-act=doc-delete]").count() == 0
          and pg.locator("[data-act=doc-copy]").count() == 0 and pg.locator("#doc-sys-note").count() == 1 and pg.locator("#d-reason:not([disabled])").count() == 1,
          "generated ADJ: lines fixed, no add / delete / copy, reason editable, note")
    pg.fill("#d-notes", "checked by phone"); pg.click("#drawer footer [data-act=doc-action][data-to=posted]")
    wait_text(pg, "#drawer", "Posted")
    sv = calls(pg, "doc_save_draft")[-1]["args"]["p_doc"]
    check(sv["warehouse_id"] == "wt" and sv["branch_id"] == "b2" and sv["notes"] == "checked by phone" and sv["lines"][0].get("description") == "2 broken in the box",
          "ADJ edit saved first: warehouse / branch kept, line description kept %s" % sv)
    close(pg)
    wait_text(pg, "#trf-table", "Closed")
    pg.click("#trf-table tbody tr.click:has-text('Closed')"); pg.wait_for_selector("#trf-receipt")
    check("closed" in pg.inner_text("#trf-receipt") and "posted" in pg.inner_text("#trf-adjs").lower() and pg.locator("#drawer footer [data-act=doc-action], #drawer footer [data-act=trf-receive]").count() == 0,
          "transfer closed after the ADJ post, no further action (Copy only)")
    close(pg)

    # ---------- cancel a dispatched transfer (source approver) ----------
    pg.click("#trf-table tbody tr.click:has-text('TRF-SER/000001')"); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=cancelled]")
    check(pg.locator("#drawer footer [data-act=trf-receive]").count() == 1, "owner: receive offered on t1 (owner sees the destination too)")
    pg.click("#drawer footer [data-act=doc-action][data-to=cancelled]"); pg.wait_for_selector("#modal-input")
    check("back from transit" in pg.inner_text("#modal-text"), "transfer cancel question")
    pg.click("#modal-ok"); check("required" in pg.inner_text("#modal-msg"), "cancel: reason required")
    pg.fill("#modal-input", "wrong clinic"); pg.click("#modal-ok"); wait_text(pg, "#drawer", "Cancelled")
    check(calls(pg, "doc_set_state")[-1]["args"]["p_options"] == {"reason": "wrong clinic"}, "cancel sends the reason")
    close(pg)
    pg.context.close()

    # ---------- error path: server problems on save ----------
    pg = page(br, "manager")
    pg.evaluate("localStorage.setItem('mock_fail', 'doc_save_draft')"); pg.reload(); pg.wait_for_selector("#trf-new")
    pg.click("#trf-new"); pg.wait_for_selector("#doc-lines"); pg.click("#d-save")
    pg.wait_for_function("(document.getElementById('d-msg') || {textContent: ''}).textContent.length > 0")
    check("Not saved" in pg.inner_text("#d-msg") and "Mock validation problem." in pg.inner_text("#d-msg"), "server problems: Not saved + list")
    pg.evaluate("localStorage.removeItem('mock_fail')")
    pg.context.close()

    # ---------- warehouse of the destination (b1), phone width: receive everything ----------
    pg = page(br, "warehouse", w=390, h=800)
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock", "Transfers", "Expenses"], "warehouse nav has Transfers (and Expenses: read)")
    wait_text(pg, "#trf-table", "TRF-THE/000003")
    pg.click("#trf-table tbody tr.click:has-text('TRF-THE/000003')"); pg.wait_for_selector("#drawer footer [data-act=trf-receive]")
    check(pg.locator("#drawer footer [data-act=doc-action][data-to=cancelled]").count() == 0 and pg.input_value("#d-wh-ro") == "THE-MAIN",
          "destination: no cancel, source warehouse of the other branch read-only")
    pg.click("#drawer footer [data-act=trf-receive]"); pg.wait_for_selector("#rc-lines")
    check(pg.locator("#rc-lines .rc-line").count() == 2, "receipt form: both lines")
    check(pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1") and
          pg.evaluate("Array.from(document.querySelectorAll('#drawer input, #drawer footer button')).every(e => e.getBoundingClientRect().right <= window.innerWidth + 1)"),
          "phone width: the receipt form and its buttons fit")
    pg.click("#trf-receive-go"); wait_text(pg, "#drawer", "Received")
    rc = calls(pg, "doc_set_state")[-1]["args"]
    check(rc["p_to_state"] == "received" and [x["received_qty"] for x in rc["p_options"]["lines"]] == ["2", "6"] and "reason" not in rc["p_options"]["lines"][0],
          "receive all as sent: to_state received %s" % rc["p_options"])
    check(pg.locator("#trf-adjs").count() == 0 and pg.locator("#trf-wait").count() == 0, "no difference: no adjustment")
    pg.context.close()

    # ---------- no doc.trf.read: no menu, guard ----------
    pg = page(br, "clinic_user", hash_="#/transfers", wait="#nav")
    check("Transfers" not in pg.locator("#nav a").all_inner_texts() and len(calls(pg, "trf_warehouses")) == 0, "clinic_user: no Transfers menu, route guarded")
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
print("smoke_erp_transfers: %d passed, %d failed" % (len(ok), len(errors)))
sys.exit(1 if errors else 0)
