"""Smoke test (Demo): erp/demo/demo.html, the self-contained demo page (erp.html + seed + the stub client of these smokes).
Checks that demo.html is what build_demo.py gives today (so it never drifts from erp.html / the stub / the seed), that the
page makes NO network request (only the file itself is loaded; CSP connect-src 'none'), the banner and the role switcher,
the seeded state (low-stock and negative-stock alerts, transfer waiting for receipt, transfer with a difference), then walks
the README script: goods receipt by barcode (on hand grows, low badge gone), consumption past zero as the clinic user
(warning dialog, "Post anyway", negative stock report), transfer dispatched by the owner and received short by the
Thessaloniki warehouse (generated ADJ), the seeded difference ADJ posted by the Serres manager (transfer closed, transit
back to zero), an expense over the approval limit submitted by accounting and approved by the manager, the expense report,
and the item CSV import with errors then clean. Role views: nav per role. No storage is used (the page runs in a context
whose storage throws).
usage (repo root): python3 -I erp/backend/tests/ui/smoke_erp_demo.py erp.html erp/backend/tests/ui/mock_supabase_erp.js
(the arguments are accepted like the other smokes; this test reads erp/demo/demo.html next to them)"""
import sys, pathlib, json, subprocess
from playwright.sync_api import sync_playwright

root = pathlib.Path(sys.argv[1]).resolve().parent if len(sys.argv) > 1 else pathlib.Path.cwd()
demo = root / "erp" / "demo" / "demo.html"
seed = json.loads((root / "erp" / "demo" / "seed_demo.json").read_text(encoding="utf-8"))
errors, ok = [], []


def check(cond, msg):
    (ok if cond else errors).append(msg)


def wait_text(pg, sel, text):
    pg.wait_for_function("([s, t]) => { const e = document.querySelector(s); return !!e && e.textContent.indexOf(t) >= 0; }", arg=[sel, text])


def bal(pg, wh, code):
    return pg.evaluate("([w, c]) => __erpDemo.balance(w, c)", [wh, code])


def role(pg, key, hash_="#/home"):
    pg.select_option("#demo-role", key)
    pg.wait_for_function("k => { const e = document.querySelector('#home-lead, #main'); return !!e && __erpDemo.user().key === k && !!document.querySelector('#nav'); }", arg=key)
    pg.wait_for_function("e => document.querySelector('.top .muted') && document.querySelector('.top .muted').textContent === e",
                         arg=[u for u in seed["users"] if u["key"] == key][0]["email"])
    pg.evaluate("h => { location.hash = h; }", hash_)


def close(pg):
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")


def item(code):
    return [i for i in seed["items"] if i["code"] == code][0]


def scenario(br):
    ctx = br.new_context(viewport={"width": 1280, "height": 900}, accept_downloads=True)
    ctx.add_init_script("(function(){var no=function(){throw new Error('storage disabled');};"
                        "try{Object.defineProperty(window,'localStorage',{get:no});Object.defineProperty(window,'sessionStorage',{get:no});}catch(e){}})();")
    pg = ctx.new_page()
    reqs = []
    pg.on("request", lambda r: reqs.append(r.url))
    pg.on("console", lambda m: m.type == "error" and errors.append("console: " + m.text))
    pg.on("pageerror", lambda e: errors.append("pageerror: %s" % e))
    pg.on("dialog", lambda d: (errors.append("unexpected native dialog: " + d.message), d.dismiss()))
    pg.goto(demo.as_uri() + "#/home")
    pg.wait_for_selector("#home-lead")

    # ---------- banner, owner home, seeded state ----------
    check("DEMO" in pg.inner_text("#demo-banner") and "nothing is saved" in pg.inner_text("#demo-banner"), "banner: DEMO, nothing is saved")
    check(pg.locator("#demo-role option").count() == len(seed["users"]), "role switcher lists every demo member")
    check(seed["tenant"]["name"] in pg.inner_text(".top .brand") and "SER · Serres" in pg.inner_text("#main") and "ALE · Alexandreia" in pg.inner_text("#main"),
          "owner home: demo tenant, three clinics")
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock", "Transfers", "Expenses", "Sales", "Admin"], "owner nav")
    pg.evaluate("location.hash = '#/stock/alerts'"); wait_text(pg, "#stk-table", "Negative stock")
    al = pg.inner_text("#stk-table")
    check(al.count("Low stock") >= 3 and "ELA-14M in ALE-MAIN is at -4" in al, "seeded alerts: several low stock + one negative (ELA-14M ALE)")
    pg.evaluate("location.hash = '#/transfers'"); wait_text(pg, "#trf-table", "TRF-SER/000001")
    tt = pg.inner_text("#trf-table")
    check("Dispatched" in tt and "Received with difference" in tt, "seeded transfers: one waiting for receipt, one with a difference")

    # ---------- 1. goods receipt by barcode (owner) ----------
    before = bal(pg, "SER-MAIN", "WIR-N016U")
    pg.evaluate("location.hash = '#/stock/documents'"); pg.wait_for_selector("#stk-new")
    pg.select_option("#stk-newtype", "GRN"); pg.click("#stk-new"); pg.wait_for_selector("#doc-lines .dline")
    pg.select_option("#d-wh", "w1"); pg.select_option("#d-cp", "p-SUP-ORTH"); pg.fill("#d-extno", "ΔΑ 5001")
    pg.fill("#doc-lines .dline .dl-code", item("WIR-N016U")["barcode"]); pg.press("#doc-lines .dline .dl-code", "Tab")
    wait_text(pg, "#doc-lines .dline .dl-name", "NiTi archwire .016 upper")
    check(pg.input_value("#doc-lines .dline .dl-code") == "WIR-N016U" and "on hand 6" in pg.inner_text("#doc-lines .dline .dl-name"), "barcode resolves to the item, on hand in SER-MAIN shown")
    pg.fill("#doc-lines .dline .dl-qty", "10"); pg.fill("#doc-lines .dline .dl-price", "9,60")
    pg.click("#d-save"); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=posted]")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]"); wait_text(pg, "#drawer header", "GRN-SER/000002")
    check(bal(pg, "SER-MAIN", "WIR-N016U") == before + 10, "GRN posted: GRN-SER/000002, SER-MAIN WIR-N016U %s -> %s" % (before, bal(pg, "SER-MAIN", "WIR-N016U")))
    close(pg)
    pg.evaluate("location.hash = '#/stock/onhand'"); pg.wait_for_selector("#stk-q"); pg.fill("#stk-q", "WIR-N016U")
    pg.wait_for_function("() => { const r = document.querySelectorAll('#stk-table tbody tr'); return r.length > 0 && [...r].every(x => x.textContent.indexOf('WIR-N016U') >= 0); }")
    row = pg.inner_text("#stk-table tbody tr:has-text('SER-MAIN')")
    check("16" in row and "low" not in row, "on hand: SER-MAIN WIR-N016U 16, no low badge any more (%s)" % row.replace("\t", " | "))

    # ---------- 2. consume past zero (clinic user, Alexandreia) ----------
    role(pg, "clinic", "#/stock/documents")
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock", "Sales"], "clinic user nav: no Transfers / Expenses / Admin")
    pg.wait_for_selector("#stk-new")
    check(pg.locator("#stk-newtype option").all_inner_texts() == ["Consumption"], "clinic user can only create Consumption")
    st = pg.inner_text("#stk-table")
    check("ALE-MAIN" in st and "SER-MAIN" not in st and "THE-MAIN" not in st, "clinic user sees only Alexandreia documents")
    pg.click("#stk-new"); pg.wait_for_selector("#doc-lines .dline")
    check(pg.input_value("#d-wh") == "w3" and pg.locator("#d-wh option").count() == 2, "one warehouse (ALE-MAIN), preselected")
    pg.fill("#doc-lines .dline .dl-code", "bon-comp"); pg.press("#doc-lines .dline .dl-code", "Tab"); wait_text(pg, "#doc-lines .dline .dl-name", "on hand 3")
    pg.fill("#doc-lines .dline .dl-qty", "5"); pg.fill("#d-cc", "Chair 1")
    pg.click("#d-save"); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=posted]")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]"); pg.wait_for_selector("#modal-ok")
    check("BON-COMP" in pg.inner_text("#modal-text") and "-2" in pg.inner_text("#modal-text"), "negative-stock warning before posting: %s" % pg.inner_text("#modal-text"))
    pg.click("#modal-ok"); wait_text(pg, "#drawer header", "CONS-ALE/000002"); close(pg)
    check(bal(pg, "ALE-MAIN", "BON-COMP") == -2, "posted anyway: ALE-MAIN BON-COMP at -2")
    pg.evaluate("location.hash = '#/stock/negative'"); wait_text(pg, "#stk-table", "BON-COMP")
    check("CONS-ALE/000002" in pg.inner_text("#stk-table") and "assistant.alex@ismile.demo" in pg.inner_text("#stk-table"), "negative stock report: cause and who")

    # ---------- 3. transfer: owner dispatches, Thessaloniki receives short ----------
    role(pg, "owner", "#/transfers"); pg.wait_for_selector("#trf-new")
    pg.click("#trf-new"); pg.wait_for_selector("#d-dest")
    pg.select_option("#d-wh", "w1"); pg.select_option("#d-dest", "w2")
    pg.fill("#doc-lines .dline .dl-code", "BRK-C22"); pg.press("#doc-lines .dline .dl-code", "Tab"); wait_text(pg, "#doc-lines .dline .dl-name", "Ceramic")
    pg.fill("#doc-lines .dline .dl-qty", "3")
    pg.click("#d-save"); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=dispatched]")
    pg.click("#drawer footer [data-act=doc-action][data-to=dispatched]"); wait_text(pg, "#drawer header", "TRF-SER/000002"); close(pg)
    check(bal(pg, "TRANSIT", "BRK-C22") == 3, "dispatched: 3 in transit")
    role(pg, "warehouse", "#/transfers"); wait_text(pg, "#trf-table", "TRF-SER/000002")
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock", "Transfers", "Expenses", "Sales"], "warehouse nav: no Admin")
    pg.click("#trf-table tbody tr:has-text('TRF-SER/000002')"); pg.wait_for_selector("#drawer footer [data-act=trf-receive]")
    pg.click("#drawer footer [data-act=trf-receive]"); pg.wait_for_selector("#rc-lines .rc-line")
    pg.fill("#rc-lines .rc-line .rc-qty", "2"); pg.fill("#rc-lines .rc-line .rc-reason", "One kit damaged")
    the0 = bal(pg, "THE-MAIN", "BRK-C22")
    pg.click("#trf-receive-go"); pg.wait_for_selector("#trf-adjs")
    check("Received with difference" in pg.inner_text("#drawer") and "Adjustment -" in pg.inner_text("#trf-adjs"), "received short: state with difference, generated ADJ draft")
    check(bal(pg, "THE-MAIN", "BRK-C22") == the0 + 2 and bal(pg, "TRANSIT", "BRK-C22") == 1,
          "THE-MAIN got 2 (%s -> %s), 1 left in transit (%s)" % (the0, bal(pg, "THE-MAIN", "BRK-C22"), bal(pg, "TRANSIT", "BRK-C22")))
    close(pg)

    # ---------- 4. manager Serres posts the seeded difference ADJ: transfer closed, transit back to zero ----------
    role(pg, "manager", "#/transfers"); wait_text(pg, "#trf-table", "TRF-THE/000001")
    check(bal(pg, "TRANSIT", "PPE-GLVM") == 2, "seeded shortage: 2 PPE-GLVM in transit")
    pg.click("#trf-table tbody tr:has-text('TRF-THE/000001')"); pg.wait_for_selector("#trf-adjs a")
    pg.click("#trf-adjs a"); pg.wait_for_selector("#doc-sys-note")
    check(pg.input_value("#d-wh-ro") == "TRANSIT", "generated ADJ: TRANSIT warehouse, read-only")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]"); wait_text(pg, "#drawer header", "ADJ_OUT-SER/000001"); close(pg)
    pg.evaluate("location.hash = '#/home'"); pg.evaluate("location.hash = '#/transfers'"); wait_text(pg, "#trf-table", "Closed")
    check(bal(pg, "TRANSIT", "PPE-GLVM") == 0, "ADJ posted: transfer closed, transit 0")

    # ---------- 5. expense over the approval limit: accounting submits, manager approves ----------
    role(pg, "accounting", "#/expenses"); pg.wait_for_selector("#exp-new")
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock", "Transfers", "Expenses", "Sales", "Admin"], "accounting nav %s" % pg.locator("#nav a").all_inner_texts())
    pg.click("#exp-new"); pg.wait_for_selector("#doc-lines .exl")
    pg.select_option("#d-branch", "b1"); pg.fill("#d-extno", "SRV-0042")
    pg.select_option("#doc-lines .exl .dl-cat", "ec-MAINT"); pg.fill("#doc-lines .exl .dl-desc", "Autoclave service"); pg.fill("#doc-lines .exl .dl-net", "450")
    pg.click("#d-save"); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=pending_approval]")
    check(pg.locator("#drawer footer [data-act=doc-action][data-to=posted]").count() == 0, "over the limit (300): accounting can only submit")
    pg.click("#drawer footer [data-act=doc-action][data-to=pending_approval]"); wait_text(pg, "#drawer", "Waiting for approval"); close(pg)
    role(pg, "manager", "#/expenses"); wait_text(pg, "#exp-table", "SRV-0042")
    pg.click("#exp-table tbody tr:has-text('SRV-0042')"); pg.wait_for_selector("#drawer footer [data-act=doc-action][data-to=posted]")
    pg.click("#drawer footer [data-act=doc-action][data-to=posted]"); wait_text(pg, "#drawer header", "EXP-SER/000003"); close(pg)
    check("€558.00" in pg.inner_text("#exp-table"), "approved by the manager: EXP-SER/000003, gross 558.00")

    # ---------- 6. expense report (owner, all clinics) ----------
    role(pg, "owner", "#/expenses/report"); wait_text(pg, "#exp-body", "Rent")
    rep = pg.inner_text("#exp-body")
    check("Rent" in rep and "Equipment maintenance" in rep and "Dental lab work" in rep, "expense report by category")

    # ---------- 7. item CSV import: errors first, then clean ----------
    pg.evaluate("location.hash = '#/master/items'"); pg.wait_for_selector("#md-import")
    pg.click("#md-import"); pg.wait_for_selector("#imp-text")
    bad = ("code;name;unit;vat;category;min_level;barcodes\nWIR-N018U;NiTi archwire .018 upper (10);PACK;VAT24;WIRE;6;5204417200014\n"
           "BRK-X;Bracket kit X;BAG;VAT24;BRK;abc;5204417200015\nWIR-N018U;Duplicate row;PACK;VAT24;WIRE;2;")
    pg.fill("#imp-text", bad); pg.click("#imp-check"); pg.wait_for_selector("#imp-errors")
    et = pg.inner_text("#imp-errors")
    check("BAG does not exist" in et and "min_level" in et and "check digit" in et and "twice" in et, "import check: unit, number, barcode check digit, duplicate code\n" + et)
    check(pg.is_disabled("#imp-run"), "import button stays disabled while there are problems")
    pg.fill("#imp-text", "code;name;unit;vat;category;min_level;barcodes\nWIR-N018U;NiTi archwire .018 upper (10);PACK;VAT24;WIRE;6;5204417200014")
    pg.click("#imp-check"); wait_text(pg, "#imp-summary", "no problem"); pg.click("#imp-run"); pg.wait_for_selector("#drawer", state="detached")
    pg.fill("#md-q", "WIR-N018"); wait_text(pg, "#md-table", "NiTi archwire .018 upper")
    check(True, "imported item listed")

    check(not [u for u in reqs if not u.startswith("file:")], "no network request: %s" % [u for u in reqs if not u.startswith("file:")][:5])
    ctx.close()
    # phone width: banner wraps, no horizontal scroll; the clinic user's stock screen
    ph = br.new_context(viewport={"width": 390, "height": 800}).new_page()
    ph.on("pageerror", lambda e: errors.append("pageerror(phone): %s" % e))
    ph.goto(demo.as_uri() + "#/stock/onhand"); ph.wait_for_selector("#stk-table")
    role(ph, "clinic", "#/stock/onhand"); ph.wait_for_selector("#stk-table tbody tr")
    check(ph.evaluate("document.documentElement.scrollWidth <= window.innerWidth + 1") and ph.is_visible("#demo-role"), "phone width: no horizontal scroll, role switcher visible")
    ph.context.close()


with sync_playwright() as p:
    out = subprocess.run([sys.executable, "-I", str(root / "erp" / "demo" / "build_demo.py"), "--check"], capture_output=True, text=True)
    check(out.returncode == 0, "demo.html is up to date with erp.html, the stub and the seed: " + out.stdout.strip() + out.stderr.strip())
    br = p.chromium.launch()
    try:
        scenario(br)
    except Exception as e:  # a timeout: report it like a failed check
        import traceback
        at = [f.lineno for f in traceback.extract_tb(e.__traceback__) if f.filename == __file__]
        errors.append("scenario stopped: %s (line %s)" % (str(e).splitlines()[0], at))
    br.close()

for m in errors:
    print("FAIL:", m)
print("smoke_erp_demo: %d checks passed, %d failed" % (len(ok), len(errors)))
sys.exit(1 if errors else 0)
