"""Smoke test (T14): stock screens. On hand (flags, values only with cost.read, filter), stock card drawer, documents
list, new GRN (supplier, item by code through item_lookup, cost, payload), post, the negative-stock warning dialog
("Post anyway" = second call with ack_warnings), cancel with a required reason, server problems "Not saved",
negative-stock report, alerts with resolve, opening-stock import (check, then the OPN draft), clinic_user (only CONS,
no values), phone width for the consumption drawer. Stubbed supabase-js, no network.
usage (repo root): python3 -I erp/backend/tests/ui/smoke_erp_stock.py erp.html erp/backend/tests/ui/mock_supabase_erp.js"""
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


def page(br, role, extra=None, w=1280, h=860, hash_="#/stock"):
    store = {"mock_role": role, "mock_session": "1"}
    store.update(extra or {})
    pg = br.new_context(viewport={"width": w, "height": h}).new_page()
    pg.on("console", lambda m: m.type == "error" and errors.append("console(%s): %s" % (role, m.text)))
    pg.on("pageerror", lambda e: errors.append("pageerror(%s): %s" % (role, e)))
    pg.on("dialog", lambda d: (errors.append("unexpected native dialog: " + d.message), d.dismiss()))
    pg.add_init_script("try{var L=%s;Object.keys(L).forEach(function(k){localStorage.setItem(k,L[k]);})}catch(e){}" % json.dumps(store))
    pg.route("**/supabase.min.js", lambda r: r.fulfill(path=str(mock), content_type="application/javascript"))
    pg.route("https://**", lambda r: r.abort() if "supabase.min.js" not in r.request.url else r.fallback())
    pg.goto(html.as_uri() + hash_)
    pg.wait_for_selector("#stk-tabs")
    return pg


with sync_playwright() as p:
    br = p.chromium.launch()

    # ---------- owner: on hand, card ----------
    pg = page(br, "owner")
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock", "Transfers", "Admin"], "owner nav: Home, Master data, Stock, Transfers, Admin")
    check(pg.locator("#stk-tabs a").all_inner_texts() == ["On hand", "Documents", "Negative stock", "Alerts"], "stock tabs")
    wait_text(pg, "#stk-table", "IT-002")
    txt = pg.inner_text("#stk-table")
    check("negative" in txt and "low" in txt and "€112.50" in txt and "Average cost" in txt, "on hand: negative and low badges, values (cost.read)")
    check(pg.locator("#stk-table tbody tr .neg").count() == 1, "negative quantity shown in red")
    pg.select_option("#stk-only", "negative"); wait_calls(pg, "stock_on_hand", 2)
    pg.wait_for_function("document.querySelectorAll('#stk-table tbody tr.click').length === 1")
    check(calls(pg, "stock_on_hand")[-1]["args"]["p_filter"] == {"only": "negative"}, "filter only=negative sent")
    pg.select_option("#stk-only", ""); wait_calls(pg, "stock_on_hand", 3); pg.wait_for_function("document.querySelectorAll('#stk-table tbody tr.click').length === 3")
    pg.click("#stk-table tbody tr.click:first-child"); pg.wait_for_selector("#card-table")
    check("OPN/000001" in pg.inner_text("#card-table") and "25" in pg.inner_text("#card-table") and pg.locator("#d-save").count() == 0, "stock card drawer: moves, running balance, read-only")
    check(calls(pg, "stock_card")[0]["args"]["p_filter"] == {"warehouse_id": "w1"}, "stock card of the row's warehouse")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")

    # ---------- documents: new GRN, post ----------
    pg.click("#stk-tabs a[data-sub=documents]"); wait_text(pg, "#stk-table", "GRN-SER/000017")
    pg.select_option("#stk-newtype", "GRN"); pg.click("#stk-new"); pg.wait_for_selector("#doc-lines")
    check(pg.locator("#d-cp").count() == 1 and pg.locator("#d-mark").count() == 1 and pg.locator("#doc-lines .dl-price").count() == 1 and pg.locator("#doc-lines .dl-disc").count() == 1,
          "GRN drawer: supplier, MARK, cost and discount per line")
    pg.select_option("#d-wh", "w1"); pg.select_option("#d-cp", "p1"); pg.fill("#d-extno", "DN-5512")
    pg.fill("#doc-lines .dl-code", "it-001"); pg.press("#doc-lines .dl-code", "Tab"); wait_calls(pg, "item_lookup", 1)
    wait_text(pg, "#doc-lines .dl-name", "Bracket 1")
    check(pg.input_value("#doc-lines .dl-code") == "IT-001" and "on hand 25" in pg.inner_text("#doc-lines .dl-name"), "item by code: code normalised, name and on hand shown")
    pg.fill("#doc-lines .dl-qty", "10"); pg.fill("#doc-lines .dl-price", "4,5")
    pg.click("#doc-line-add"); check(pg.locator("#doc-lines .dline").count() == 2, "Add line")
    pg.click("#doc-lines .dline:nth-child(2) .dl-del"); check(pg.locator("#doc-lines .dline").count() == 1, "remove line")
    pg.click("#d-save"); wait_calls(pg, "doc_save_draft", 1); pg.wait_for_selector("#drawer footer [data-act=doc-action]")
    sv = calls(pg, "doc_save_draft")[0]["args"]
    check(sv["p_type"] == "GRN" and sv["p_doc"]["warehouse_id"] == "w1" and sv["p_doc"]["branch_id"] == "b1" and sv["p_doc"]["counterparty_id"] == "p1"
          and sv["p_doc"]["ext_number"] == "DN-5512" and sv["p_doc"]["lines"] == [{"item_id": "i1", "qty": "10", "unit_price": "4.5"}] and sv["p_doc"]["doc_date"] == "2026-11-18",
          "GRN save payload: header, branch from the warehouse, lines with the looked-up item, decimal comma %s" % sv["p_doc"])
    check("Draft" in pg.inner_text("#drawer") and "€45.00" in pg.inner_text("#doc-totals"), "saved draft reopened with total from the server")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]"); wait_calls(pg, "doc_set_state", 1)
    wait_text(pg, "#drawer", "Posted")
    check("Posted." in pg.inner_text("#toast") and pg.locator("#drawer .dl-code[disabled]").count() == 1, "posted: toast, drawer read-only")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")

    # ---------- CONS beyond stock: warning dialog, post anyway ----------
    pg.select_option("#stk-newtype", "CONS"); pg.click("#stk-new"); pg.wait_for_selector("#doc-lines")
    check(pg.locator("#doc-lines .dl-price").count() == 0 and pg.locator("#doc-lines .dl-ref").count() == 1 and pg.locator("#d-cc").count() == 1, "CONS drawer: no price, line reference, cost centre")
    pg.select_option("#d-wh", "w1"); pg.fill("#d-cc", "Surgery 1"); pg.fill("#doc-lines .dl-code", "IT-002"); pg.press("#doc-lines .dl-code", "Tab")
    wait_text(pg, "#doc-lines .dl-name", "Wire 2"); pg.fill("#doc-lines .dl-qty", "2")
    pg.click("#d-save"); wait_calls(pg, "doc_save_draft", 2); pg.wait_for_selector("#drawer footer [data-act=doc-action]")
    check(calls(pg, "doc_save_draft")[1]["args"]["p_doc"]["extra"] == {"cost_centre": "Surgery 1"}, "CONS: cost centre in extra")
    n0 = len(calls(pg, "doc_set_state"))
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]"); pg.wait_for_selector("#modal-text")
    check("below zero" in pg.inner_text("#modal-text") and "IT-002" in pg.inner_text("#modal-text") and "-5" in pg.inner_text("#modal-text"), "warning dialog lists the item and the quantity after")
    check(calls(pg, "doc_set_state")[n0]["args"]["p_options"] == {}, "first post without ack")
    pg.click("#modal-ok"); wait_calls(pg, "doc_set_state", n0 + 2); wait_text(pg, "#drawer", "Posted")
    check(calls(pg, "doc_set_state")[n0 + 1]["args"]["p_options"] == {"ack_warnings": True}, "Post anyway: second call with ack_warnings")
    # cancel with a reason
    pg.click("#drawer footer [data-act=doc-action][data-to=cancelled]"); pg.wait_for_selector("#modal-input")
    pg.click("#modal-ok"); check("required" in pg.inner_text("#modal-msg"), "cancel: the reason is required")
    pg.fill("#modal-input", "wrong patient card"); pg.click("#modal-ok"); wait_text(pg, "#drawer", "Cancelled")
    check(calls(pg, "doc_set_state")[-1]["args"]["p_options"] == {"reason": "wrong patient card"} and calls(pg, "doc_set_state")[-1]["args"]["p_to_state"] == "cancelled",
          "cancel sends the reason")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")

    # ---------- negative report, alerts ----------
    pg.click("#stk-tabs a[data-sub=negative]"); wait_text(pg, "#stk-table", "CONS-SER/000004")
    check("2 days" in pg.inner_text("#stk-table") and "€6.00" in pg.inner_text("#stk-table") and "nurse@clinic.test" in pg.inner_text("#stk-table"), "negative report: days, cause, member, value")
    pg.click("#stk-tabs a[data-sub=alerts]"); wait_text(pg, "#stk-table", "below the minimum")
    check("IT-002 in SER-MAIN is at -3.0000" in pg.inner_text("#stk-table"), "alerts: message from the params")
    pg.click("#stk-table button[data-act=stk-resolve]"); wait_calls(pg, "alert_resolve", 1)
    pg.wait_for_function("document.querySelectorAll('#stk-table tbody tr').length === 1")
    check(calls(pg, "alert_resolve")[0]["args"]["p_alert_id"] == "al1", "resolve an alert")

    # ---------- opening import ----------
    pg.click("#stk-tabs a[data-sub=documents]"); wait_text(pg, "#stk-table", "GRN")
    pg.click("#stk-import"); pg.wait_for_selector("#imp-text")
    pg.select_option("#opn-wh", "w1"); pg.fill("#imp-text", "item;qty;unit_cost\nIT-001;5;3,25\nNOPE;1;1\n")
    pg.click("#opn-check"); wait_calls(pg, "opening_import", 1); pg.wait_for_selector("#imp-errors")
    check("NOPE does not exist" in pg.inner_text("#imp-errors") and pg.locator("#opn-run").is_disabled(), "opening import: problems by row, Import disabled")
    pg.fill("#imp-text", "item;qty;unit_cost\nIT-001;5;3,25\nIT-003;2;1\n")
    pg.click("#opn-check"); wait_calls(pg, "opening_import", 2); pg.wait_for_function("!document.getElementById('opn-run').disabled")
    check("value €18.25" in pg.inner_text("#imp-summary"), "clean check: rows and value")
    pg.click("#opn-run"); wait_calls(pg, "opening_import", 3); pg.wait_for_selector("#doc-lines")
    a3 = calls(pg, "opening_import")[2]["args"]
    check(a3["p_dry_run"] is False and a3["p_doc"] == {"branch_id": "b1", "warehouse_id": "w1"} and len(a3["p_rows"]) == 2 and "Opening balance" in pg.inner_text("#drawer header"),
          "import: real run, then the OPN draft opens")
    pg.context.close()

    # ---------- error path ----------
    pg = page(br, "owner", {"mock_fail": "doc_save_draft"}, hash_="#/stock/documents")
    wait_text(pg, "#stk-table", "GRN")
    pg.select_option("#stk-newtype", "ADJ_OUT"); pg.click("#stk-new"); pg.wait_for_selector("#doc-lines")
    check(pg.locator("#d-reason option").count() == 5, "ADJ- reasons: choose + 4")
    pg.click("#d-save"); pg.wait_for_function("document.getElementById('d-msg').textContent.length > 0")
    check("Not saved" in pg.inner_text("#d-msg") and "Mock validation problem." in pg.inner_text("#d-msg"), "server problems: Not saved + list")
    pg.context.close()

    # ---------- clinic_user: consumption only, no values, phone width ----------
    pg = page(br, "clinic_user", w=390, h=800)
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock"], "clinic_user nav")
    wait_text(pg, "#stk-table", "IT-001")
    check("Average cost" not in pg.inner_text("#stk-table") and "€" not in pg.inner_text("#stk-table") and "THE-MAIN" not in pg.inner_text("#stk-table"), "clinic_user: own branch, no values")
    check(pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1"), "phone width: on hand without horizontal scroll")
    pg.click("#stk-tabs a[data-sub=documents]"); pg.wait_for_selector("#stk-newtype")
    check(pg.locator("#stk-newtype option").all_inner_texts() == ["Consumption"] and pg.locator("#stk-import").count() == 0, "clinic_user: only Consumption can be created, no import")
    pg.click("#stk-new"); pg.wait_for_selector("#doc-lines")
    check(pg.evaluate("document.getElementById('drawer').getBoundingClientRect().width <= window.innerWidth") and
          pg.evaluate("Array.from(document.querySelectorAll('#doc-lines .dline input')).every(e => e.getBoundingClientRect().right <= window.innerWidth)"),
          "phone width: the consumption drawer and its line inputs fit")
    pg.context.close()
    br.close()

for m in ok:
    print("PASS:", m)
for m in errors:
    print("FAIL:", m)
print("smoke_erp_stock: %d passed, %d failed" % (len(ok), len(errors)))
sys.exit(1 if errors else 0)
