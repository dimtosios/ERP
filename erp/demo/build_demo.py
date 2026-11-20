#!/usr/bin/env python3
"""Build erp/demo/demo.html: ONE self-contained file that runs the ERP page with sample data, no server, no network.

  demo.html = erp.html (built from erp/app by build_erp.py)
              - the supabase-js CDN tag  -> seed_demo.json + demo_runtime.js + the smoke tests' stub client
                                            (erp/backend/tests/ui/mock_supabase_erp.js, reused unchanged in behaviour)
              - the project URL / publishable key -> placeholders (the stub never uses them)
              + a Content-Security-Policy that forbids every network request (connect-src 'none', no external script)
Deterministic: the same input files give the same bytes. The seed is validated first (Greek AFM check digit of every
supplier, EAN-13 check digit of every barcode, references between seed parts).
  python3 erp/demo/build_demo.py           write erp/demo/demo.html and print its size
  python3 erp/demo/build_demo.py --check   exit 1 when demo.html is not what the sources give"""
import json, pathlib, sys

here = pathlib.Path(__file__).resolve().parent
root = here.parent.parent
sys.dont_write_bytecode = True   # no __pycache__ in the repo
sys.path.insert(0, str(root / "erp"))
import build_erp  # noqa: E402  (same folder layout; build_erp.build() returns the erp.html bytes)

CDN = '<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js"></script>'
KEY_LINE = "var SB_URL = 'https://tmgmiojvqdivuoorvmfl.supabase.co', SB_KEY = 'sb_publishable_UO9ur1Futgz71_pKZleHyg_lbRiJJXf';"
CSP = ("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
       "img-src data: blob:; connect-src 'none'; form-action 'none'; base-uri 'none'\">")


def afm_ok(v):
    if len(v) != 9 or not v.isdigit():
        return False
    s = sum(int(c) * 2 ** (8 - i) for i, c in enumerate(v[:8]))
    return s % 11 % 10 == int(v[8])


def ean_ok(v):
    if len(v) != 13 or not v.isdigit():
        return False
    s = sum(int(c) * (3 if i % 2 else 1) for i, c in enumerate(v[:12]))
    return (10 - s % 10) % 10 == int(v[12])


def validate(seed):
    bad = []
    units = {u["code"] for u in seed["units"]}
    vats = {v["code"] for v in seed["vat_classes"]}
    cats = {c["code"] for c in seed["item_categories"]}
    codes = [i["code"] for i in seed["items"]]
    whs = {w["code"] for w in seed["warehouses"]}
    sups = {s["code"] for s in seed["suppliers"]}
    ecats = {c["code"] for c in seed["expense_categories"]}
    users = {u["key"] for u in seed["users"]}
    branches = {b["code"] for b in seed["branches"]}
    if len(set(codes)) != len(codes):
        bad.append("duplicate item code")
    bcs = [i["barcode"] for i in seed["items"]]
    if len(set(bcs)) != len(bcs):
        bad.append("duplicate barcode")
    for i in seed["items"]:
        if not ean_ok(i["barcode"]):
            bad.append("EAN check digit: %s %s" % (i["code"], i["barcode"]))
        if i["unit"] not in units or i["vat"] not in vats or i["category"] not in cats:
            bad.append("item reference: %s" % i["code"])
    for s in seed["suppliers"]:
        if not afm_ok(s["tax_id"]):
            bad.append("AFM check digit: %s %s" % (s["code"], s["tax_id"]))
    for c in seed["expense_categories"]:
        if c["vat"] not in vats or (c.get("parent") and c["parent"] not in ecats):
            bad.append("expense category reference: %s" % c["code"])
    for d in seed["documents"]:
        if d["user"] not in users or (d.get("receive") and d["receive"]["user"] not in users):
            bad.append("document user: %s" % d)
        if d["type"] == "EXP":
            if d["branch"] not in branches or any(l[0] not in ecats for l in d["lines"]):
                bad.append("expense reference: %s" % d)
        elif d["wh"] not in whs or (d.get("dest") and d["dest"] not in whs) or any(l[0] not in codes for l in d["lines"]):
            bad.append("document reference: %s" % d)
        if d.get("supplier") and d["supplier"] not in sups:
            bad.append("supplier reference: %s" % d)
    if bad:
        sys.exit("seed_demo.json is not valid:\n  " + "\n  ".join(bad))


def script(js):
    if "</script" in js.lower():
        sys.exit("a demo part contains '</script'")
    return "<script>\n" + js.rstrip("\n") + "\n</script>"


def build():
    seed_text = (here / "seed_demo.json").read_text(encoding="utf-8")
    seed = json.loads(seed_text)
    validate(seed)
    page = build_erp.build().decode("utf-8")
    for mark in (CDN, KEY_LINE, '<meta charset="utf-8">'):
        if page.count(mark) != 1:
            sys.exit("erp.html changed: expected exactly one %r" % mark[:60])
    seed_js = "window.__ERP_DEMO_SEED = " + json.dumps(seed, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/") + ";"
    mock = (root / "erp/backend/tests/ui/mock_supabase_erp.js").read_text(encoding="utf-8")
    runtime = (here / "demo_runtime.js").read_text(encoding="utf-8")
    page = page.replace(CDN, "<!-- demo: no supabase-js; the stub client below answers every call in the page -->\n" +
                        script(seed_js) + "\n" + script(runtime) + "\n" + script(mock))
    page = page.replace(KEY_LINE, "var SB_URL = 'https://demo.invalid', SB_KEY = 'demo-no-key';   // demo build: no project, no key")
    page = page.replace('<meta charset="utf-8">', '<meta charset="utf-8">' + CSP)
    page = page.replace("<title>ERP</title>", "<title>ERP demo</title>")
    if "https://" in page.replace("https://demo.invalid", ""):
        sys.exit("demo.html would still name an https:// address")
    return page.encode("utf-8")


if __name__ == "__main__":
    data = build()
    target = here / "demo.html"
    if "--check" in sys.argv:
        same = target.exists() and target.read_bytes() == data
        print("demo.html %s (%d bytes)" % ("is up to date" if same else "is NOT up to date: run python3 erp/demo/build_demo.py", len(data)))
        sys.exit(0 if same else 1)
    target.write_bytes(data)
    print("demo.html written: %d bytes" % len(data))
