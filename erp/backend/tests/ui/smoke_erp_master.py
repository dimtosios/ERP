"""Smoke test (T07): master-data screen. Tabs follow the read capabilities, "New" / Save the write capabilities;
items list keyset "Load more" + search; new item payload (only filled keys, barcodes split), edit sends only the
changed keys + id + version; error path "Not saved" with the problem list and the empty-reply path; units,
counterparty edit, series "Create missing"; clinic_user read-only without prices; warehouse without Series; phone
width. Stubbed supabase-js, no network.
usage (repo root): python3 -I erp/backend/tests/ui/smoke_erp_master.py erp.html erp/backend/tests/ui/mock_supabase_erp.js"""
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


def page(br, role, extra=None, w=1280, h=860, hash_="#/master"):
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
    pg.wait_for_selector("#md-tabs")
    return pg


def rows(pg):
    return pg.locator("#md-table tbody tr.click").count()


with sync_playwright() as p:
    br = p.chromium.launch()

    # ---------- owner: items ----------
    pg = page(br, "owner")
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock", "Transfers", "Admin"], "owner nav")
    check(pg.locator("#md-tabs a").all_inner_texts() == ["Items", "Categories", "Units", "VAT classes", "Warehouses", "Customers & suppliers", "Series"], "owner: seven tabs")
    pg.wait_for_selector("#md-table")
    check(rows(pg) == 50 and pg.locator("#md-more").count() == 1, "items: first page 50 + Load more")
    pg.click("#md-more"); pg.wait_for_function("document.querySelectorAll('#md-table tbody tr.click').length === 70")
    il = calls(pg, "item_list")
    check(il[0]["args"]["p_cursor"] is None and il[1]["args"]["p_cursor"] == {"k": "IT-049"} and il[1]["args"]["p_filter"] == {"active": "all"},
          "Load more sends the keyset cursor %s" % il[1]["args"])
    pg.fill("#md-q", "wire 1"); wait_calls(pg, "item_list", 3)
    pg.wait_for_function("document.querySelectorAll('#md-table tbody tr.click').length === 5")
    check(calls(pg, "item_list")[-1]["args"]["p_filter"] == {"q": "wire 1", "active": "all"} and pg.locator("#md-q").evaluate("e => e === document.activeElement"),
          "search: p_filter.q, focus kept")
    pg.fill("#md-q", ""); wait_calls(pg, "item_list", 4); pg.wait_for_function("document.querySelectorAll('#md-table tbody tr.click').length === 50")

    pg.click("#md-new"); pg.wait_for_selector("#drawer")
    check(pg.locator("#i-price").count() == 1 and pg.locator("#i-vat").count() == 1 and "Last purchase" not in pg.inner_text("#drawer"), "new item: price + VAT fields")
    pg.fill("#i-code", "NEW-1"); pg.fill("#i-name", "New bracket"); pg.select_option("#i-unit", "u1"); pg.fill("#i-bc", "4006381333931, INT-1;INT-2")
    dis = pg.evaluate("() => { const b = document.getElementById('d-save'); b.click(); const d = b.disabled; b.click(); return d; }")
    check(dis, "save disabled while running")
    pg.wait_for_selector("#drawer", state="detached")
    sv = calls(pg, "item_save")
    check(len(sv) == 1, "double click: one item_save (%d)" % len(sv))
    check(sv[0]["args"]["p_item"] == {"code": "NEW-1", "name": "New bracket", "kind": "goods", "base_unit_id": "u1", "barcodes": ["4006381333931", "INT-1", "INT-2"], "active": True}
          and len(sv[0]["args"]["p_idempotency_key"]) == 36, "new item payload: only filled keys, barcodes split %s" % sv[0]["args"])
    wait_calls(pg, "item_list", 5)
    pg.wait_for_selector("#md-table tbody tr.click")
    pg.click("#md-table tbody tr.click:nth-child(2)"); pg.wait_for_selector("#drawer")
    check("Last purchase price: €7.25" in pg.inner_text("#drawer"), "edit item: last purchase price shown (cost.read)")
    pg.fill("#i-name", "Renamed item"); pg.click("#d-save"); pg.wait_for_selector("#drawer", state="detached")
    up = calls(pg, "item_save")[-1]["args"]["p_item"]
    check(up == {"name": "Renamed item", "item_id": "i1", "version": 1}, "edit sends only the changed key + id + version %s" % up)
    # CSV import: check first, unknown column ignored, problems by row, Import only after a clean check of the same text
    pg.click("#md-import"); pg.wait_for_selector("#imp-text")
    check(pg.locator("#imp-run").is_disabled(), "import: Import disabled before a check")
    pg.fill("#imp-text", "Code;Name;Unit;Colour\nBAD;x;PCS;red\n\"OK-1\";\"Wire; 0.014\";PCS;blue\n")
    pg.click("#imp-check"); wait_calls(pg, "item_import", 1); pg.wait_for_selector("#imp-summary")
    a1 = calls(pg, "item_import")[0]["args"]
    check(a1["p_dry_run"] is True and a1["p_rows"] == [{"code": "BAD", "name": "x", "unit": "PCS"}, {"code": "OK-1", "name": "Wire; 0.014", "unit": "PCS"}],
          "import check: dry run, known columns only, quoted separator kept %s" % a1["p_rows"])
    check("Mock bad row." in pg.inner_text("#imp-errors") and "colour" in pg.inner_text("#imp-ignored") and pg.locator("#imp-run").is_disabled(),
          "import check: problem by row, ignored column listed, Import stays disabled")
    pg.fill("#imp-text", "code;name;unit\nOK-1;Wire 0.014;PCS\nOK-2;Wire 0.016;PCS\n")
    check(pg.locator("#imp-run").is_disabled(), "import: editing the text needs a new check")
    pg.click("#imp-check"); wait_calls(pg, "item_import", 2)
    pg.wait_for_function("!document.getElementById('imp-run').disabled")
    check("2 rows, no problem" in pg.inner_text("#imp-summary"), "clean check: summary, Import enabled")
    pg.click("#imp-run"); wait_calls(pg, "item_import", 3); pg.wait_for_selector("#drawer", state="detached")
    a3 = calls(pg, "item_import")[2]["args"]
    check(a3["p_dry_run"] is False and len(a3["p_rows"]) == 2 and a3["p_idempotency_key"] != calls(pg, "item_import")[1]["args"]["p_idempotency_key"],
          "Import: real run with its own idempotency key")
    check("Imported 2 rows" in pg.inner_text("#toast"), "import: toast")
    pg.context.close()

    # error path + empty reply
    pg = page(br, "owner", {"mock_fail": "item_save"})
    pg.wait_for_selector("#md-table"); pg.click("#md-new"); pg.wait_for_selector("#drawer")
    pg.fill("#i-code", "X"); pg.fill("#i-name", "X"); pg.select_option("#i-unit", "u1"); pg.click("#d-save")
    pg.wait_for_function("document.getElementById('d-msg').textContent.length > 0")
    check("Not saved" in pg.inner_text("#d-msg") and "Mock validation problem." in pg.inner_text("#d-msg") and pg.locator("#drawer").count() == 1,
          "server problems: 'Not saved' + list, drawer stays open")
    pg.context.close()
    pg = page(br, "owner", {"mock_null": "unit_save"}, hash_="#/master/units")
    pg.wait_for_selector("#md-table"); pg.click("#md-new"); pg.fill("#u-code", "TUBE"); pg.fill("#u-name", "Tube"); pg.click("#d-save")
    pg.wait_for_function("document.getElementById('d-msg').textContent.length > 0")
    check("Not saved" in pg.inner_text("#d-msg") and "returned nothing" in pg.inner_text("#d-msg"), "empty reply: 'Not saved: the server returned nothing'")
    pg.context.close()

    # units validation from the server, counterparty edit, series defaults
    pg = page(br, "owner", hash_="#/master/units")
    pg.wait_for_selector("#md-table")
    check(rows(pg) == 3, "units tab: 3 rows")
    pg.click("#md-new"); pg.fill("#u-name", "No code"); pg.click("#d-save")
    pg.wait_for_function("document.getElementById('d-msg').textContent.length > 0")
    check("code is required." in pg.inner_text("#d-msg"), "unit without code: server problem listed")
    pg.click("#drawer header [data-act=drawer-close]"); pg.click("#modal-ok"); pg.wait_for_selector("#drawer", state="detached")
    pg.click("#md-tabs a[data-sub=counterparties]"); pg.wait_for_function("document.getElementById('md-table') && document.getElementById('md-table').textContent.indexOf('Dental') >= 0")
    pg.click("#md-table tbody tr.click:first-child"); pg.wait_for_selector("#drawer")
    pg.fill("#p-city", "Berlin-Mitte"); pg.click("#d-save"); pg.wait_for_selector("#drawer", state="detached")
    cs = calls(pg, "counterparty_save")[-1]["args"]["p_counterparty"]
    check(cs == {"city": "Berlin-Mitte", "counterparty_id": "p2", "version": 3}, "counterparty edit: changed key + id + version %s" % cs)
    pg.click("#md-tabs a[data-sub=series]"); pg.wait_for_function("document.getElementById('md-table') && document.getElementById('md-table').textContent.indexOf('GRN-SER') >= 0")
    check("GRN-SER" in pg.inner_text("#md-table") and "Default" in pg.inner_text("#md-table"), "series list")
    pg.click("#md-table tbody tr.click:first-child"); pg.wait_for_selector("#drawer")
    check(pg.locator("#s-type").is_disabled() and pg.locator("#s-next").is_disabled() and not pg.locator("#s-code").is_disabled(), "series in use: type / next no. locked, code editable")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")
    pg.click("#s-def-go"); wait_calls(pg, "series_create_defaults", 1)
    pg.wait_for_function("document.getElementById('toast') && document.getElementById('toast').textContent.indexOf('created') >= 0")
    check("1 series created" in pg.inner_text("#toast") and "GRN" in pg.inner_text("#toast") and calls(pg, "series_create_defaults")[0]["args"]["p_branch_id"] == "b1",
          "series: Create missing for the chosen branch, toast with skipped types")
    pg.context.close()

    # ---------- clinic_user: read-only, no prices ----------
    pg = page(br, "clinic_user")
    check(pg.locator("#md-tabs a").all_inner_texts() == ["Items", "Categories", "Units", "Warehouses"], "clinic_user: items, categories, units, warehouses only")
    pg.wait_for_selector("#md-table")
    check(pg.locator("#md-new").count() == 0, "clinic_user: no New button")
    pg.click("#md-table tbody tr.click:first-child"); pg.wait_for_selector("#drawer")
    check(pg.locator("#d-save").count() == 0 and pg.locator("#i-price").count() == 0 and pg.locator("#i-name").is_disabled(), "clinic_user: read-only drawer without price fields")
    pg.context.close()

    # ---------- warehouse: no series, VAT read-only ----------
    pg = page(br, "warehouse", hash_="#/master/vat")
    check("Series" not in pg.locator("#md-tabs a").all_inner_texts() and "VAT classes" in pg.locator("#md-tabs a").all_inner_texts(), "warehouse: VAT tab, no Series tab")
    pg.wait_for_selector("#md-table")
    check(pg.locator("#md-new").count() == 0, "warehouse: no New on VAT (vat.write missing)")
    pg.goto(html.as_uri() + "#/master/series"); pg.wait_for_selector("#md-tabs")
    check(pg.locator("#md-tabs a.on").inner_text() == "Items", "warehouse: #/master/series falls back to the first allowed tab")
    pg.context.close()

    # ---------- phone width ----------
    pg = page(br, "owner", w=390, h=800)
    pg.wait_for_selector("#md-table")
    check(pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1"), "phone width: no horizontal page scroll")
    pg.click("#md-table tbody tr.click:first-child"); pg.wait_for_selector("#drawer")
    check(pg.evaluate("document.getElementById('drawer').getBoundingClientRect().width <= window.innerWidth"), "phone width: drawer fits")
    pg.context.close()
    br.close()

for m in ok:
    print("PASS:", m)
for m in errors:
    print("FAIL:", m)
print("smoke_erp_master: %d passed, %d failed" % (len(ok), len(errors)))
sys.exit(1 if errors else 0)
