"""Smoke test (Draft 1): supplier delivery note -> DRAFT goods receipt, in the Stock > Documents GRN drawer. New GRN: the
"Delivery note" box (file input, file name + size shown, Upload disabled until a file is chosen, client-side 5 MB / type
checks), upload to the chosen warehouse's branch (attachment_add payload: base64 of the exact bytes), "Create draft from
note" with the DEFAULT mock extractor (labelled "MOCK extractor - sample data") -> grn_draft_from_extraction (client_key
from the file id, no idempotency-key argument), the draft opens with unmatched lines highlighted, the problems listed,
Post refused by the server; fixing: item chosen for an unmatched line, "Mark checked" on a low-confidence line (custom
window.ERP_EXTRACTOR: the extractor is pluggable), the line extra.dn round-trips in doc_save_draft, then Post works.
Existing GRN: files listed, Open (attachment_get -> a link + an inline photo preview), Delete (confirm). Roles: readonly
sees the files but cannot upload, clinic_user has no GRN. Phone width: the box and the buttons fit. Stubbed supabase-js.
usage (repo root): python3 -I erp/backend/tests/ui/smoke_erp_delivery_note.py erp.html erp/backend/tests/ui/mock_supabase_erp.js"""
import sys, pathlib, json, base64, tempfile
from playwright.sync_api import sync_playwright

html, mock = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
errors, ok = [], []
tmp = pathlib.Path(tempfile.mkdtemp(prefix="erp_dn_"))
PDF = b"%PDF-1.4\n% delivery note\n" + b"x" * 200
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 60
(tmp / "note 17.pdf").write_bytes(PDF)
(tmp / "page2.png").write_bytes(PNG)
(tmp / "big.pdf").write_bytes(b"%PDF-" + b"y" * 5242880)
(tmp / "notes.txt").write_bytes(b"just text")


def check(cond, msg):
    (ok if cond else errors).append(msg)


def calls(pg, name):
    return pg.evaluate("n => __calls.filter(c => c.name === n)", name)


def wait_calls(pg, name, n):
    pg.wait_for_function("([n, k]) => __calls.filter(c => c.name === n).length >= k", arg=[name, n])


def wait_text(pg, sel, text):
    pg.wait_for_function("([s, t]) => { const e = document.querySelector(s); return !!e && e.textContent.indexOf(t) >= 0; }", arg=[sel, text])


def page(br, role, w=1280, h=860, extractor=None):
    pg = br.new_context(viewport={"width": w, "height": h}).new_page()
    pg.on("console", lambda m: m.type == "error" and errors.append("console(%s): %s" % (role, m.text)))
    pg.on("pageerror", lambda e: errors.append("pageerror(%s): %s" % (role, e)))
    pg.on("dialog", lambda d: (errors.append("unexpected native dialog: " + d.message), d.dismiss()))
    pg.add_init_script("try{localStorage.setItem('mock_role',%s);localStorage.setItem('mock_session','1');localStorage.removeItem('mock_fail')}catch(e){}" % json.dumps(role))
    if extractor:
        pg.add_init_script(extractor)
    pg.route("**/supabase.min.js", lambda r: r.fulfill(path=str(mock), content_type="application/javascript"))
    pg.route("https://**", lambda r: r.abort() if "supabase.min.js" not in r.request.url else r.fallback())
    pg.goto(html.as_uri() + "#/stock/documents")
    pg.wait_for_selector("#stk-table")
    return pg


def new_grn(pg):
    pg.select_option("#stk-newtype", "GRN"); pg.click("#stk-new"); pg.wait_for_selector("#dn-box")


# a custom extractor (pluggable): one barcode line, one low-confidence line matched by code, one unmatched line
CUSTOM = """window.ERP_EXTRACTOR = async function (ctx) {
  window.__ext_ctx = {name: ctx.file ? ctx.file.name : null, att: ctx.attachment.attachment_id, wh: ctx.warehouse.code};
  return {schema: 'delivery_note_extraction/1', extractor: 'acme-ocr/2', supplier: {tax_id: 'DE123456789', name: 'Dental GmbH'}, dn_number: 'LS-778', dn_date: '2026-11-17',
          lines: [{description: 'Elastic', barcode: '4006381333931', qty: 6, unit_price: 0.8, confidence: 0.99},
                  {description: 'Bracket', supplier_code: 'IT-001', qty: 4, unit_price: 4.5, confidence: 0.6},
                  {description: 'Mystery part', supplier_code: 'Q-9', qty: 1, unit_price: 9, confidence: 0.95}], warnings: []};
};"""


def scenario(br):
    # ---------- owner, new GRN, default MOCK extractor ----------
    pg = page(br, "owner")
    new_grn(pg)
    check(pg.is_disabled("#dn-upload") and pg.is_disabled("#dn-create") and "No file chosen." in pg.inner_text("#dn-file-name")
          and pg.get_attribute("#dn-file", "accept").startswith("application/pdf,image/jpeg,image/png"),
          "new GRN: Delivery note box, PDF / JPEG / PNG picker, buttons disabled until a file is chosen")
    pg.set_input_files("#dn-file", str(tmp / "big.pdf"))
    check("larger than 5 MB" in pg.inner_text("#d-msg") and pg.is_disabled("#dn-upload"), "a file over 5 MB is refused in the page")
    pg.set_input_files("#dn-file", str(tmp / "notes.txt"))
    check("Only PDF, JPEG or PNG" in pg.inner_text("#d-msg") and pg.is_disabled("#dn-upload"), "a text file is refused in the page")
    pg.set_input_files("#dn-file", str(tmp / "note 17.pdf"))
    check("note 17.pdf" in pg.inner_text("#dn-file-name") and not pg.is_disabled("#dn-upload") and not pg.is_disabled("#dn-create"), "the chosen file name and size are shown")
    pg.click("#dn-upload")
    check(pg.inner_text("#d-msg") == "Choose the warehouse first." and not calls(pg, "attachment_add"), "upload needs the warehouse (its branch)")
    pg.select_option("#d-wh", "w1")
    pg.click("#dn-upload"); wait_calls(pg, "attachment_add", 1); wait_text(pg, "#dn-files", "note 17.pdf")
    a = calls(pg, "attachment_add")[0]["args"]
    check(a["p_attachment"]["branch_id"] == "b1" and a["p_attachment"]["filename"] == "note 17.pdf" and base64.b64decode(a["p_attachment"]["content_base64"]) == PDF
          and a["p_attachment"]["mime"] == "application/pdf" and "document_id" not in a["p_attachment"] and a.get("p_idempotency_key"),
          "attachment_add: branch of the warehouse, file name, exact bytes in base64, idempotency key")
    check("KB" in pg.inner_text("#dn-files") and "PDF" in pg.inner_text("#dn-files") and not pg.is_disabled("#dn-create"), "the uploaded file is listed (size, type); Create is enabled")
    pg.click("#dn-create"); wait_calls(pg, "grn_draft_from_extraction", 1); pg.wait_for_selector("#dn-mock")
    g = calls(pg, "grn_draft_from_extraction")[0]["args"]
    att = calls(pg, "attachment_add")[0]
    check(g["p_extraction"]["extractor"] == "mock" and g["p_extraction"]["schema"] == "delivery_note_extraction/1" and len(g["p_extraction"]["lines"]) == 3
          and g["p_warehouse_id"] == "w1" and g["p_client_key"].startswith("dn:at") and g["p_attachment_id"] == g["p_client_key"][3:] and "p_idempotency_key" not in g,
          "Create draft: default MOCK extraction sent with the file id, warehouse, client_key dn:<file id>, no idempotency-key argument")
    check("MOCK extractor - sample data." in pg.inner_text("#dn-mock") and "check every line" in pg.inner_text("#dn-mock"), "the draft says MOCK extractor - sample data")
    check("Draft" in pg.inner_text("#drawer") and "Nothing is posted" in pg.inner_text("#toast") and pg.input_value("#d-extno") == "MOCK-0001"
          and pg.eval_on_selector("#d-cp", "e => e.options[e.selectedIndex].text") == "Ortho Supplies SA",
          "the DRAFT opens: supplier found by tax ID, note number filled, toast says nothing is posted")
    check(pg.locator("#doc-lines .dline").count() == 3 and pg.locator("#doc-lines .dline.dl-flag").count() == 2
          and "Item not matched" in pg.inner_text("#doc-lines .dline:nth-of-type(2)") and "NiTi wire 0.16 upper" in pg.inner_text("#doc-lines .dline:nth-of-type(2)")
          and "dl-flag" not in pg.get_attribute("#doc-lines .dline:nth-of-type(1)", "class"),
          "unmatched lines are highlighted with what the note said; the matched one is not")
    check("2 not matched" in pg.inner_text("#dn-summary") and "Item not matched" in pg.inner_text("#doc-problem-box") and "MOCK extractor - sample data, not read from note 17.pdf." in pg.inner_text("#dn-warnings"),
          "summary, problems box and the extractor's warning are shown")
    wait_calls(pg, "attachment_list", 1); wait_text(pg, "#dn-files", "note 17.pdf")
    check(not pg.locator("#dn-create").count() and pg.locator("#dn-upload").count() == 1, "the saved draft lists its file; Create is only on a new receipt")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]"); pg.wait_for_function("document.getElementById('d-msg').textContent.length > 0")
    check("Not saved" in pg.inner_text("#d-msg") and "Item not matched" in pg.inner_text("#d-msg") and "Draft" in pg.inner_text("#drawer"),
          "Post is refused while lines are not matched (server problems shown), still a draft")
    pg.click("#drawer header [data-act=drawer-close]")
    if pg.locator("#modal-ok").count():
        pg.click("#modal-ok")
    pg.wait_for_selector("#drawer", state="detached")
    # Open + Delete on the receipt's files; a second page (photo) added to the existing draft
    pg.click("#stk-table tbody tr.click:has-text('Ortho Supplies SA'):has-text('Draft')"); pg.wait_for_selector("#dn-box"); wait_text(pg, "#dn-files", "note 17.pdf")
    pg.set_input_files("#dn-file", str(tmp / "page2.png")); pg.click("#dn-upload")
    wait_calls(pg, "attachment_add", 2); wait_text(pg, "#dn-files", "page2.png")
    check(calls(pg, "attachment_add")[1]["args"]["p_attachment"].get("document_id", "").startswith("n") and "branch_id" not in calls(pg, "attachment_add")[1]["args"]["p_attachment"],
          "a file added to an existing receipt is linked to it")
    pg.click("#dn-files li:has-text('page2.png') [data-act=dn-open]"); pg.wait_for_selector("#dn-files li:has-text('page2.png') .dn-preview")
    href = pg.get_attribute("#dn-files li:has-text('page2.png') a.dn-link", "href")
    check(href.startswith("blob:") and pg.get_attribute("#dn-files li:has-text('page2.png') a.dn-link", "target") == "_blank"
          and pg.evaluate("u => fetch(u).then(r => r.arrayBuffer()).then(b => b.byteLength)", href) == len(PNG),
          "Open: attachment_get -> a link to the exact bytes (new tab) and an inline photo preview")
    pg.click("#dn-files li:has-text('page2.png') [data-act=dn-delete]"); pg.wait_for_selector("#modal-ok"); pg.click("#modal-ok")
    wait_calls(pg, "attachment_delete", 1); pg.wait_for_function("document.getElementById('dn-files').textContent.indexOf('page2.png') < 0")
    check("note 17.pdf" in pg.inner_text("#dn-files"), "Delete (after confirm) removes the file from the list")
    pg.context.close()

    # ---------- warehouse, custom (pluggable) extractor, fix the draft, post ----------
    pg = page(br, "warehouse", extractor=CUSTOM)
    new_grn(pg)
    pg.select_option("#d-wh", "w1"); pg.set_input_files("#dn-file", str(tmp / "note 17.pdf"))
    pg.click("#dn-create"); wait_calls(pg, "grn_draft_from_extraction", 1); pg.wait_for_selector("#dn-summary")
    check(calls(pg, "attachment_add") and pg.evaluate("window.__ext_ctx") == {"name": "note 17.pdf", "att": calls(pg, "grn_draft_from_extraction")[0]["args"]["p_attachment_id"], "wh": "SER-MAIN"},
          "Create without a separate Upload: the file is uploaded first, then window.ERP_EXTRACTOR gets the file, the uploaded attachment and the warehouse")
    check(not pg.locator("#dn-mock").count() and calls(pg, "grn_draft_from_extraction")[0]["args"]["p_extraction"]["extractor"] == "acme-ocr/2",
          "a plugged-in extractor replaces the mock (no MOCK label)")
    check(pg.locator("#doc-lines .dline.dl-flag").count() == 2 and "Check (confidence 60%)" in pg.inner_text("#doc-lines .dline:nth-of-type(2)")
          and "Item not matched" in pg.inner_text("#doc-lines .dline:nth-of-type(3)"), "low-confidence and unmatched lines flagged")
    pg.click("#doc-lines .dline:nth-of-type(2) [data-act=dn-check]")
    check("Checked" in pg.inner_text("#doc-lines .dline:nth-of-type(2)") and pg.locator("#doc-lines .dline.dl-flag").count() == 1, "Mark checked clears the flag of that line")
    pg.fill("#doc-lines .dline:nth-of-type(3) .dl-code", "IT-002"); pg.press("#doc-lines .dline:nth-of-type(3) .dl-code", "Tab")
    pg.wait_for_function("document.querySelector('#doc-lines .dline:nth-of-type(3) .dl-name').textContent.indexOf('Wire 2') >= 0")
    pg.click("#d-save"); wait_calls(pg, "doc_save_draft", 1); wait_text(pg, "#toast", "Saved")
    pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=posted]")
    p = calls(pg, "doc_save_draft")[0]["args"]["p_doc"]
    check(p["extra"]["dn"]["extractor"] == "acme-ocr/2" and p["lines"][1]["extra"]["dn"]["checked"] is True and p["lines"][1]["extra"]["dn"]["status"] == "low_confidence"
          and p["lines"][2]["item_id"] == "i2" and p["lines"][2]["extra"]["dn"]["status"] == "unmatched" and p["lines"][2]["description"] == "Mystery part",
          "save keeps the delivery-note data (header and lines) and sends the chosen item")
    check(pg.locator("#doc-lines .dline.dl-flag").count() == 0 and not pg.locator("#doc-problem-box").count(), "after the fixes no line is flagged and no problem is listed")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]")
    pg.wait_for_function("document.getElementById('drawer') && document.getElementById('drawer').textContent.indexOf('Posted') >= 0")
    check(calls(pg, "doc_set_state")[-1]["args"]["p_to_state"] == "posted", "the warehouse person posts the fixed draft (a separate, manual step)")
    wait_text(pg, "#dn-files", "note 17.pdf")
    check(not pg.locator("#dn-files [data-act=dn-delete]").count(), "posted receipt: warehouse cannot delete its delivery note (needs approve)")
    pg.context.close()

    # ---------- roles, phone ----------
    pg = page(br, "readonly")
    pg.click("#stk-table tbody tr.click:has-text('GRN-SER/000017')"); pg.wait_for_selector("#dn-box"); wait_calls(pg, "attachment_list", 1)
    check(not pg.locator("#dn-file").count() and not pg.locator("#dn-upload").count() and "No file attached." in pg.inner_text("#dn-files"),
          "readonly: sees the Delivery note box of a receipt, no upload")
    pg.context.close()
    pg = page(br, "clinic_user")
    check(pg.locator("#stk-newtype option[value=GRN]").count() == 0, "clinic_user cannot create a GRN (no delivery-note upload)")
    pg.context.close()
    pg = page(br, "warehouse", w=390, h=844)
    new_grn(pg)
    vw = pg.evaluate("document.documentElement.clientWidth")
    boxes = [pg.locator(s).bounding_box() for s in ("#dn-file", "#dn-upload", "#dn-create")]
    check(all(b and b["x"] >= 0 and b["x"] + b["width"] <= vw + 1 for b in boxes) and pg.evaluate("document.documentElement.scrollWidth") <= vw + 1,
          "phone width: file picker and buttons fit, no horizontal scroll")
    pg.context.close()


with sync_playwright() as p:
    br = p.chromium.launch()
    try:
        scenario(br)
    except Exception as e:  # noqa: BLE001
        errors.append("exception: %r" % e)
    br.close()
for m in ok:
    print("PASS:", m)
for m in errors:
    print("FAIL:", m)
print("smoke_erp_delivery_note: %d passed, %d failed" % (len(ok), len(errors)))
sys.exit(1 if errors else 0)
