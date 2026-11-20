"""Smoke test (Draft 2): Sales screen, NON-FISCAL delivery notes and retail receipts. Nav entry by caps, tabs Delivery
notes / Retail receipts, list (doc_types filter, state filter, billing / payment badges), non-fiscal note; new delivery
note (warehouse, customer, delivery block, to be billed, lines by item code with price and VAT class = the item's when
empty), save payload, post (DN-SER/...), "NOT A FISCAL DOCUMENT" on the drawer, Print / PDF view (issuer from Admin >
Settings, customer, delivery block, lines, VAT breakdown, totals, watermark; window.print called); retail receipt that
bills the posted delivery note ("Add the remaining lines": dn_line_id link, customer taken over, no stock note) plus a
free line, post, billing state of the DN, cancel of the DN refused while billed (ERP_DOC_HAS_CHILDREN); services receipt
(description line); quick-add customer; server problems; phone width; roles (clinic_user: receipts only, no cancel;
warehouse: delivery notes only; readonly: no New). Stubbed supabase-js, no network.
usage (repo root): python3 -I erp/backend/tests/ui/smoke_erp_sales.py erp.html erp/backend/tests/ui/mock_supabase_erp.js"""
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


def page(br, role, w=1280, h=860, hash_="#/sales", wait="#sal-bar"):
    pg = br.new_context(viewport={"width": w, "height": h}).new_page()
    pg.on("console", lambda m: m.type == "error" and errors.append("console(%s): %s" % (role, m.text)))
    pg.on("pageerror", lambda e: errors.append("pageerror(%s): %s" % (role, e)))
    pg.on("dialog", lambda d: (errors.append("unexpected native dialog: " + d.message), d.dismiss()))
    pg.add_init_script("try{localStorage.setItem('mock_role',%s);localStorage.setItem('mock_session','1');localStorage.removeItem('mock_exp_limit')}catch(e){}" % json.dumps(role))
    pg.add_init_script("window.__printed = 0; window.print = function () { window.__printed++; };")
    pg.route("**/supabase.min.js", lambda r: r.fulfill(path=str(mock), content_type="application/javascript"))
    pg.route("https://**", lambda r: r.abort() if "supabase.min.js" not in r.request.url else r.fallback())
    pg.goto(html.as_uri() + hash_)
    pg.wait_for_selector(wait)
    return pg


def line(i):
    return "#doc-lines .sll:nth-of-type(%d) " % (i + 1)


def item(pg, i, code):
    pg.fill(line(i) + ".dl-code", code); pg.press(line(i) + ".dl-code", "Tab")
    pg.wait_for_function("s => { const e = document.querySelector(s); return !!e && e.value !== ''; }", arg=line(i) + ".dl-id")


def scenario(br):
    # ---------- owner: issuer in Admin > Settings ----------
    pg = page(br, "owner", hash_="#/admin/settings", wait="#s-iss-legal_name")
    pg.fill("#s-iss-legal_name", "iSmile Orthodontics P.C."); pg.fill("#s-iss-tax_id", "800 000 000"); pg.fill("#s-iss-address", "Merarchias 1, Serres")
    pg.click("#s-save"); wait_calls(pg, "settings_save", 1)
    check(calls(pg, "settings_save")[0]["args"]["p_settings"].get("issuer") == {"legal_name": "iSmile Orthodontics P.C.", "tax_id": "800000000", "address": "Merarchias 1, Serres"},
          "settings: issuer block sent (tax ID without spaces, empty fields left out)")

    # ---------- owner: Sales menu, delivery notes list ----------
    pg.click("#nav a[data-to=sales]"); pg.wait_for_selector("#sal-bar")
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock", "Transfers", "Expenses", "Sales", "Admin"], "owner nav has Sales")
    check(pg.locator("#sal-tabs a").all_inner_texts() == ["Delivery notes", "Retail receipts"], "two tabs")
    check("NOT fiscal" in pg.inner_text("#sal-nonfiscal"), "non-fiscal note on the screen")
    wait_text(pg, "#sal-table", "DN-SER/000001")
    check("Dental GmbH" in pg.inner_text("#sal-table") and "€74.40" in pg.inner_text("#sal-table") and "To be billed" in pg.inner_text("#sal-table"), "list: number, customer, gross, billing badge")
    check(calls(pg, "doc_list")[0]["args"]["p_filter"] == {"doc_types": ["DN"]}, "list: doc_list doc_types DN")
    pg.select_option("#sal-state", "draft"); wait_calls(pg, "doc_list", 2); wait_text(pg, "#sal-table", "No delivery notes.")
    check(calls(pg, "doc_list")[1]["args"]["p_filter"] == {"doc_types": ["DN"], "state": "draft"}, "filter by state")
    pg.select_option("#sal-state", ""); wait_calls(pg, "doc_list", 3); wait_text(pg, "#sal-table", "DN-SER/000001")

    # ---------- new delivery note ----------
    pg.click("#sal-new-dn"); pg.wait_for_selector("#doc-lines .sll")
    check(pg.input_value("#s-reason") == "sale" and pg.is_checked("#s-billed") and pg.locator("#d-wh").count() == 1, "new DN: reason sale, to be billed, warehouse picker")
    check("NOT A FISCAL DOCUMENT" in pg.inner_text("#sal-watermark"), "drawer carries NOT A FISCAL DOCUMENT")
    pg.select_option("#d-wh", "w1"); pg.select_option("#s-cust", "p2")
    pg.fill("#s-addr", "Tsimiski 10, Thessaloniki"); pg.fill("#s-carrier", "Own van"); pg.fill("#s-vehicle", "NIK-1234")
    item(pg, 0, "IT-001"); pg.fill(line(0) + ".dl-qty", "2"); pg.fill(line(0) + ".dl-price", "15,50")
    pg.click("#doc-line-add"); item(pg, 1, "IT-003"); pg.fill(line(1) + ".dl-qty", "1"); pg.fill(line(1) + ".dl-price", "10"); pg.select_option(line(1) + ".dl-vat", "v2")
    pg.click("#d-save"); wait_calls(pg, "doc_save_draft", 1)
    p = calls(pg, "doc_save_draft")[0]["args"]
    check(p["p_type"] == "DN" and p["p_doc"]["counterparty_id"] == "p2" and p["p_doc"]["warehouse_id"] == "w1" and p["p_doc"]["branch_id"] == "b1"
          and p["p_doc"]["extra"] == {"delivery": {"reason": "sale", "address": "Tsimiski 10, Thessaloniki", "carrier": "Own van", "vehicle": "NIK-1234"}, "to_be_billed": True},
          "save: customer, warehouse / branch, delivery block, to be billed %s" % json.dumps(p["p_doc"].get("extra")))
    check(p["p_doc"]["lines"] == [{"qty": "2", "item_id": "i1", "unit_price": "15.50"}, {"qty": "1", "item_id": "i3", "unit_price": "10", "vat_class_id": "v2"}],
          "lines: decimal comma sent as a point; empty VAT = the item's (key left out) %s" % json.dumps(p["p_doc"]["lines"]))
    pg.wait_for_selector("#sal-print-btn"); wait_calls(pg, "sales_get", 1)
    wait_text(pg, "#doc-totals", "gross")
    check("€31.00" in pg.inner_text(line(0) + ".dl-amt") and "€38.44" in pg.inner_text(line(0) + ".dl-amt") and "€11.30" in pg.inner_text(line(1) + ".dl-amt"),
          "saved lines show net / VAT / gross from the server (24 %, 13 %)")
    check("€49.74" in pg.inner_text("#doc-totals"), "totals net / VAT / gross")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]")
    pg.wait_for_function("document.querySelector('#drawer h2') && document.querySelector('#drawer h2').textContent.indexOf('DN-SER/') >= 0")
    check(pg.locator("#drawer [data-act=doc-action][data-to=cancelled]").count() == 1, "posted DN: owner may cancel")
    dn_no = pg.inner_text("#drawer h2").replace("Delivery note ", "")

    # ---------- print view ----------
    pg.click("#sal-print-btn"); pg.wait_for_selector("#print-view")
    txt = pg.inner_text("#print-view")
    check("NOT A FISCAL DOCUMENT" in pg.inner_text("#pv-banner") and pg.locator("#print-view .pv-wm").count() == 1, "print: watermark banner and background text")
    check("iSmile Orthodontics P.C." in pg.inner_text("#pv-issuer") and "800000000" in pg.inner_text("#pv-issuer") and "Branch SER" in pg.inner_text("#pv-issuer"),
          "print: issuer from the settings and the branch")
    check(pg.inner_text("#pv-no") == dn_no and "Dental GmbH" in pg.inner_text("#pv-customer") and "NIK-1234" in pg.inner_text("#pv-delivery")
          and "Tsimiski 10" in pg.inner_text("#pv-delivery"), "print: number, customer, delivery block")
    check(pg.locator("#pv-lines tbody tr").count() == 2 and "VAT24 (24%)" in pg.inner_text("#pv-vat") and "VAT13 (13%)" in pg.inner_text("#pv-vat") and "€49.74" in pg.inner_text("#pv-total"),
          "print: lines, VAT breakdown, totals")
    pg.click("#pv-print")
    check(pg.evaluate("window.__printed") == 1, "Print calls the browser print (Save as PDF)")
    pg.emulate_media(media="print")
    check(not pg.locator("#drawer").is_visible() and pg.locator("#pv-lines").is_visible() and not pg.locator("#pv-print").is_visible(), "print CSS: only the document, no buttons")
    pg.emulate_media(media="screen")
    pg.click("#pv-close"); check(pg.locator("#print-view").count() == 0, "print view closes")
    pg.click("#drawer header [data-act=drawer-close]")

    # ---------- retail receipt billing the delivery note ----------
    pg.click("#sal-tabs a[data-sub=rr]"); pg.wait_for_selector("#sal-new-rr")
    check(calls(pg, "doc_list")[-1]["args"]["p_filter"] == {"doc_types": ["RR", "RS"]} or any(c["args"]["p_filter"] == {"doc_types": ["RR", "RS"]} for c in calls(pg, "doc_list")),
          "receipts tab lists RR and RS")
    pg.click("#sal-new-rr"); pg.wait_for_selector("#s-dn")
    check(pg.input_value("#s-pm") == "cash", "new RR: paid in cash by default")
    pg.select_option("#d-wh", "w1"); pg.select_option("#s-dn", "sd1"); pg.click("#sal-dn-lines")
    pg.wait_for_selector(line(0) + ".dl-dn")
    check(pg.input_value("#s-cust") == "p2" and pg.input_value(line(0) + ".dl-qty") == "3" and pg.is_disabled(line(0) + ".dl-code")
          and "no stock movement" in pg.inner_text(line(0) + ".dl-dn"), "lines from the DN: remaining 3, item fixed, customer taken over, no-stock note")
    pg.click("#doc-line-add"); item(pg, 1, "IT-003"); pg.fill(line(1) + ".dl-qty", "1"); pg.fill(line(1) + ".dl-price", "5")
    pg.select_option("#s-pm", "card")
    pg.click("#d-save"); wait_calls(pg, "doc_save_draft", 2)
    p = calls(pg, "doc_save_draft")[1]["args"]["p_doc"]
    check(p["ref_document_id"] == "sd1" and p["extra"] == {"payment_method": "card"} and p["lines"][0] == {"qty": "3", "item_id": "i1", "unit_price": "20", "vat_class_id": "v1", "extra": {"dn_line_id": "sd1-0"}}
          and "extra" not in p["lines"][1], "RR payload: DN reference, card, the billed line carries dn_line_id, the free line not %s" % json.dumps(p))
    pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=posted]")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]")
    pg.wait_for_function("document.querySelector('#drawer h2') && document.querySelector('#drawer h2').textContent.indexOf('RR-SER/') >= 0")
    check("Card" in pg.inner_text("#sal-collection") and "€80.60" in pg.inner_text("#sal-collection"), "posted RR: collected at issue (card, gross)")
    pg.click("#sal-print-btn"); pg.wait_for_selector("#print-view")
    check("DN-SER/000001" in pg.inner_text("#pv-payment") and "Card" in pg.inner_text("#pv-payment") and "NOT A FISCAL DOCUMENT" in pg.inner_text("#pv-banner"),
          "RR print: payment method, billed delivery note, watermark")
    pg.click("#pv-close"); pg.click("#drawer header [data-act=drawer-close]")
    # the DN is billed now: its cancel is refused
    pg.click("#sal-tabs a[data-sub=dn]"); wait_text(pg, "#sal-table", "DN-SER/000001")
    pg.click("#sal-table tr:has-text('DN-SER/000001')"); pg.wait_for_selector("#sal-billing")
    check("Fully billed" in pg.inner_text("#sal-billing") and "RR-SER/" in pg.inner_text("#sal-billing"), "DN drawer: fully billed by the receipt")
    pg.click("#drawer [data-act=doc-action][data-to=cancelled]"); pg.fill("#modal-input", "wrong"); pg.click("#modal-ok")
    pg.wait_for_function("(document.getElementById('d-msg') || {textContent: ''}).textContent.length > 0")
    check("Not saved" in pg.inner_text("#d-msg"), "cancel of a billed DN refused (later documents depend on it)")
    pg.click("#drawer header [data-act=drawer-close]")

    # ---------- services receipt + quick-add customer ----------
    pg.click("#sal-tabs a[data-sub=rr]"); pg.wait_for_selector("#sal-new-rs"); pg.click("#sal-new-rs"); pg.wait_for_selector("#d-branch")
    check(pg.locator("#d-wh").count() == 0 and pg.locator(line(0) + ".dl-desc").count() == 1, "RS: branch instead of warehouse, description on the line")
    pg.select_option("#d-branch", "b1")
    pg.click("#sal-cust-new"); pg.fill("#modal-input", "Maria Papadopoulou"); pg.click("#modal-ok"); wait_calls(pg, "counterparty_save", 1)
    check(calls(pg, "counterparty_save")[0]["args"]["p_counterparty"] == {"name": "Maria Papadopoulou", "kind": "customer"}, "quick add: a customer counterparty")
    pg.wait_for_function("document.getElementById('s-cust').selectedOptions[0].textContent === 'Maria Papadopoulou'")
    pg.fill(line(0) + ".dl-desc", "Retainer cleaning"); pg.fill(line(0) + ".dl-qty", "1"); pg.fill(line(0) + ".dl-price", "20")
    pg.click("#d-save"); wait_calls(pg, "doc_save_draft", 3)
    p = calls(pg, "doc_save_draft")[2]["args"]
    check(p["p_type"] == "RS" and p["p_doc"]["branch_id"] == "b1" and p["p_doc"]["lines"] == [{"qty": "1", "description": "Retainer cleaning", "unit_price": "20"}]
          and str(p["p_doc"]["counterparty_id"]).startswith("n"),
          "RS payload: branch, description line, the new customer")
    pg.context.close()

    # ---------- phone width ----------
    pg = page(br, "owner", w=390, h=800)
    wait_text(pg, "#sal-table", "DN-SER/000001"); pg.click("#sal-new-dn"); pg.wait_for_selector("#doc-lines .sll")
    check(pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1"), "phone: no horizontal scroll with the DN drawer open")
    pg.context.close()

    # ---------- roles ----------
    pg = page(br, "clinic_user")
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock", "Sales"] and pg.locator("#sal-tabs a").all_inner_texts() == ["Retail receipts"],
          "clinic_user: Sales with retail receipts only")
    check(pg.locator("#sal-new-rr").count() == 1 and pg.locator("#sal-new-rs").count() == 0, "clinic_user: new retail receipt, no services receipt")
    pg.click("#sal-new-rr"); pg.wait_for_selector("#s-pm")
    check(pg.locator("#s-dn").count() == 0 and pg.locator("#sal-cust-new").count() == 0, "clinic_user: no delivery-note picker, no quick-add customer")
    pg.context.close()
    pg = page(br, "warehouse")
    check(pg.locator("#sal-tabs a").all_inner_texts() == ["Delivery notes"] and pg.locator("#sal-new-dn").count() == 1, "warehouse: delivery notes only, may create")
    wait_text(pg, "#sal-table", "DN-SER/000001"); pg.click("#sal-table tr:has-text('DN-SER/000001')"); pg.wait_for_selector("#sal-print-btn")
    check(pg.locator("#drawer [data-act=doc-action][data-to=cancelled]").count() == 0, "warehouse: no cancel (M O)")
    pg.context.close()
    pg = page(br, "readonly")
    wait_text(pg, "#sal-table", "DN-SER/000001")
    check(pg.locator("#sal-new-dn").count() == 0, "readonly: no New")
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
print("smoke_erp_sales: %d passed, %d failed" % (len(ok), len(errors)))
sys.exit(1 if errors else 0)
