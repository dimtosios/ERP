#!/usr/bin/env python3
"""Build erp.html (repo root) from erp/app/shell.html + erp.css + strings.en.js + the other erp/app/*.js (name order).

Deterministic: the same input files give the same bytes. No dependency, no network, no Netlify step.
  python3 erp/build_erp.py           write erp.html and print its size
  python3 erp/build_erp.py --check   exit 1 when erp.html is not what the sources give (used by run_erp_tests.sh)
The CRM build (build_index.py / index.html) is a different product and is never touched by this script."""
import pathlib, sys

here = pathlib.Path(__file__).resolve().parent / "app"
root = here.parent.parent
CSS_MARK, JS_MARK = "/*@@ERP_CSS@@*/", "/*@@ERP_JS@@*/"


def read(p):
    return p.read_text(encoding="utf-8").replace("\r\n", "\n").rstrip("\n") + "\n"


def build():
    shell = read(here / "shell.html")
    for mark in (CSS_MARK, JS_MARK):
        if shell.count(mark) != 1:
            sys.exit("shell.html must contain %s exactly once" % mark)
    parts = [here / "strings.en.js"] + sorted((p for p in here.glob("*.js") if p.name != "strings.en.js"), key=lambda p: p.name)
    js = ["(function(){\n'use strict';\n"]
    for p in parts:
        js.append("/* ===== %s ===== */\n" % p.name)
        js.append(read(p))
    js.append("})();")
    out = shell.replace(CSS_MARK, read(here / "erp.css").rstrip("\n")).replace(JS_MARK, "".join(js))
    if "</script" in "".join(js[1:-1]).lower():
        sys.exit("a source file contains '</script', which would end the inline block")
    return out.encode("utf-8")


if __name__ == "__main__":
    data = build()
    target = root / "erp.html"
    if "--check" in sys.argv:
        same = target.exists() and target.read_bytes() == data
        print("erp.html %s (%d bytes)" % ("is up to date" if same else "is NOT up to date: run python3 erp/build_erp.py", len(data)))
        sys.exit(0 if same else 1)
    target.write_bytes(data)
    print("erp.html written: %d bytes" % len(data))
