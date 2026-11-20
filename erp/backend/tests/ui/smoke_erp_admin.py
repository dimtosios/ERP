"""Smoke test (T04): app core + admin screen. Nav and role guard from whoami().caps, members list (keyset "Load
more", search), invite drawer (save, idempotency key, error path "Not saved" with the problem list, empty reply,
button disabled while running, unsaved-changes guard), member edit sends only the changed keys, reset login link
with confirm, branches list / add / edit (whoami reloaded), settings form (dd/mm/yyyy lock date -> ISO, version,
read-only for a manager), clinic_user without Admin, phone width. Stubbed supabase-js, no network.
usage (repo root): python3 -I erp/backend/tests/ui/smoke_erp_admin.py erp.html erp/backend/tests/ui/mock_supabase_erp.js"""
import sys, pathlib, json
from playwright.sync_api import sync_playwright

html, mock = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
errors, ok = [], []


def check(cond, msg):
    (ok if cond else errors).append(msg)


def calls(pg, name):
    return pg.evaluate("n => __calls.filter(c => c.name === n)", name)


def page(br, role, extra=None, w=1280, h=860, hash_=""):
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
    pg.wait_for_selector("#main")
    return pg


def wait_calls(pg, name, n):
    pg.wait_for_function("([n, k]) => __calls.filter(c => c.name === n).length >= k", arg=[name, n])


with sync_playwright() as p:
    br = p.chromium.launch()

    # ---------- owner ----------
    pg = page(br, "owner")
    navs = pg.locator("#nav a").all_inner_texts()
    check(navs == ["Home", "Master data", "Stock", "Transfers", "Expenses", "Sales", "Admin"], "owner nav: Home, Master data, Stock, Transfers, Expenses, Sales, Admin %s" % navs)
    check("iSmile" in pg.inner_text(".top") and "SER" in pg.inner_text("#main"), "home: tenant + branches")
    pg.click("#nav a[data-to=admin]")
    pg.wait_for_selector("#m-table")
    check(pg.locator("#adm-tabs a").all_inner_texts() == ["Members", "Branches", "Settings"], "owner: three admin tabs")
    check(pg.locator("#m-table tbody tr").count() == 50 and pg.locator("#m-more").count() == 1, "members: first page of 50 + Load more")
    pg.click("#m-more"); pg.wait_for_function("document.querySelectorAll('#m-table tbody tr').length === 66")
    ml = calls(pg, "member_list")
    check(ml[0]["args"]["p_cursor"] is None and ml[1]["args"]["p_cursor"] == {"k": "person48@clinic.test"}, "Load more sends the keyset cursor of the reply %s" % ml[1]["args"].get("p_cursor"))
    pg.fill("#m-q", "person01"); wait_calls(pg, "member_list", 3)
    pg.wait_for_function("document.querySelectorAll('#m-table tbody tr').length === 1")
    check(calls(pg, "member_list")[-1]["args"]["p_filter"] == {"q": "person01"} and pg.locator("#m-q").evaluate("e => e === document.activeElement"),
          "search: p_filter.q, one row, focus kept in the search box")
    pg.fill("#m-q", ""); wait_calls(pg, "member_list", 4); pg.wait_for_function("document.querySelectorAll('#m-table tbody tr').length === 50")

    # invite: unsaved guard first
    pg.click("[data-act=member-new]"); pg.wait_for_selector("#drawer")
    pg.fill("#m-email", "new.one@clinic.test")
    pg.click("#drawer header [data-act=drawer-close]")
    check(pg.locator("#modal-text").count() == 1 and "unsaved" in pg.inner_text("#modal-text"), "unsaved changes: confirm before closing")
    pg.click("#modal-cancel")
    check(pg.locator("#drawer").count() == 1 and pg.input_value("#m-email") == "new.one@clinic.test", "Keep editing: drawer and typed value stay")
    pg.select_option("#m-role", "warehouse")
    pg.check("#m-branches input[value=b2]")
    pg.fill("#m-name", "New One")
    dis = pg.evaluate("() => { const b = document.getElementById('d-save'); b.click(); const d = b.disabled; b.click(); return d; }")
    check(dis, "save button disabled while running")
    pg.wait_for_selector("#drawer", state="detached")
    inv = calls(pg, "member_invite")
    check(len(inv) == 1, "double click: ONE member_invite call (%d)" % len(inv))
    a = inv[0]["args"]
    check(a["p_member"] == {"email": "new.one@clinic.test", "role": "warehouse", "branch_ids": ["b2"], "all_branches": False, "display_name": "New One"}
          and len(a.get("p_idempotency_key", "")) == 36, "invite payload + idempotency key %s" % a)
    check("Saved" in pg.inner_text("#toast"), "toast Saved")
    wait_calls(pg, "member_list", 5)

    # member edit: only changed keys; reset login link
    pg.wait_for_selector("#m-table tbody tr")
    pg.click("#m-table tbody tr:nth-child(2)"); pg.wait_for_selector("#drawer")
    pg.select_option("#m-role", "readonly")
    pg.click("#d-save"); pg.wait_for_selector("#drawer", state="detached")
    up = calls(pg, "member_update")[-1]["args"]
    check(up["p_changes"] == {"role": "readonly"} and up["p_member_id"], "member edit sends only the changed key %s" % up)
    pg.wait_for_function("__calls.filter(c => c.name === 'member_list').length >= 6")
    pg.wait_for_selector("#m-table tbody tr")
    # first row with status active that is not me
    rows = pg.locator("#m-table tbody tr")
    idx = next(i for i in range(rows.count()) if "Active" in rows.nth(i).inner_text())
    rows.nth(idx).click(); pg.wait_for_selector("#drawer")
    check(pg.locator("[data-act=member-reset]").count() == 1, "active member: Reset login link button")
    pg.click("[data-act=member-reset]"); pg.wait_for_selector("#modal-ok")
    pg.click("#modal-ok"); wait_calls(pg, "member_reset_binding", 1)
    pg.wait_for_selector("#drawer", state="detached")
    check(True, "reset login link: confirm, call, drawer closed")

    # branches
    pg.click("#adm-tabs a[data-sub=branches]"); pg.wait_for_selector("#b-table")
    check(pg.locator("#b-table tbody tr").count() == 3, "branches: 3 rows")
    n_who = len(calls(pg, "whoami"))
    pg.click("[data-act=branch-new]"); pg.wait_for_selector("#drawer")
    pg.fill("#b-code", "KAT"); pg.fill("#b-name", "Katerini"); pg.fill("#b-estab", "3")
    pg.click("#d-save"); pg.wait_for_selector("#drawer", state="detached")
    check(calls(pg, "branch_save")[-1]["args"]["p_branch"] == {"code": "KAT", "name": "Katerini", "establishment_no": "3", "address": None, "active": True},
          "add branch payload %s" % calls(pg, "branch_save")[-1]["args"]["p_branch"])
    pg.wait_for_function("document.querySelectorAll('#b-table tbody tr').length === 4")
    check(len(calls(pg, "whoami")) > n_who, "whoami reloaded after a branch change")
    pg.click("#b-table tbody tr:first-child"); pg.wait_for_selector("#drawer")
    pg.fill("#b-name", "Serres centre"); pg.click("#d-save"); pg.wait_for_selector("#drawer", state="detached")
    check(calls(pg, "branch_save")[-1]["args"]["p_branch"] == {"branch_id": "b1", "name": "Serres centre"}, "edit branch sends id + changed key only")

    # settings
    pg.click("#adm-tabs a[data-sub=settings]"); pg.wait_for_selector("#s-form")
    check(pg.input_value("#s-val") == "Weighted average" and pg.locator("#s-val").is_disabled(), "valuation shown read-only: Weighted average")
    pg.fill("#s-lock", "31/02/2026"); pg.click("#s-save")
    check("lock date" in pg.inner_text("#s-msg") and len(calls(pg, "settings_save")) == 0, "invalid dd/mm/yyyy: message, no call")
    pg.fill("#s-lock", "31/01/2026"); pg.check("#s-hide"); pg.click("#s-save")
    wait_calls(pg, "settings_save", 1)
    ss = calls(pg, "settings_save")[0]["args"]["p_settings"]
    check(ss == {"version": 1, "lock_date": "2026-01-31", "hide_money": True}, "settings_save: version + changed keys, ISO date %s" % ss)
    pg.wait_for_function("document.getElementById('s-lock') && document.getElementById('s-lock').value === '31/01/2026' && __calls.filter(c => c.name === 'settings_get').length >= 2")
    check(True, "settings reloaded with dd/mm/yyyy")
    pg.context.close()

    # ---------- error paths ----------
    pg = page(br, "owner", {"mock_fail": "member_invite", "mock_null": "branch_save"}, hash_="#/admin/members")
    pg.wait_for_selector("#m-table")
    pg.click("[data-act=member-new]"); pg.fill("#m-email", "x@clinic.test"); pg.click("#d-save")
    pg.wait_for_function("document.getElementById('d-msg').textContent.length > 0")
    msg = pg.inner_text("#d-msg")
    check("Not saved" in msg and "Some fields need attention" in msg and "Mock validation problem" in msg and not pg.locator("#d-save").is_disabled(),
          "server error: 'Not saved' + problem list, drawer stays, button enabled")
    pg.click("#drawer header [data-act=drawer-close]"); pg.click("#modal-ok"); pg.wait_for_selector("#drawer", state="detached")
    pg.click("#adm-tabs a[data-sub=branches]"); pg.wait_for_selector("#b-table")
    pg.click("[data-act=branch-new]"); pg.fill("#b-code", "X"); pg.fill("#b-name", "X"); pg.click("#d-save")
    pg.wait_for_function("document.getElementById('d-msg').textContent.length > 0")
    check("Not saved" in pg.inner_text("#d-msg") and "returned nothing" in pg.inner_text("#d-msg"), "empty reply (0 rows): 'Not saved'")
    pg.context.close()

    # ---------- manager: reads, no write buttons ----------
    pg = page(br, "manager", hash_="#/admin/members")
    pg.wait_for_selector("#m-table")
    check(pg.locator("[data-act=member-new]").count() == 0, "manager: no Invite button")
    pg.click("#m-table tbody tr:first-child"); pg.wait_for_selector("#drawer")
    check(pg.locator("#d-save").count() == 0 and pg.locator("#m-role").is_disabled(), "manager: member drawer read-only")
    pg.click("#drawer header [data-act=drawer-close]"); pg.wait_for_selector("#drawer", state="detached")
    pg.click("#adm-tabs a[data-sub=settings]"); pg.wait_for_selector("#s-form")
    check(pg.locator("#s-save").count() == 0 and "Only the owner" in pg.inner_text("#s-form"), "manager: settings read-only")
    pg.click("#adm-tabs a[data-sub=branches]"); pg.wait_for_selector("#b-table")
    check(pg.locator("[data-act=branch-new]").count() == 0, "manager: no Add branch")
    pg.context.close()

    # ---------- clinic_user: no Admin, guard on a typed URL ----------
    pg = page(br, "clinic_user", hash_="#/admin/settings")
    pg.wait_for_selector("#home-lead")
    check(pg.locator("#nav a").all_inner_texts() == ["Home", "Master data", "Stock", "Sales"], "clinic_user nav: Home, Master data, Stock (no Admin)")
    check("cannot open" in pg.inner_text("#toast") and len(calls(pg, "settings_get")) == 0, "typed #/admin: role guard toast, home, no admin call")
    check(all(c.get("schema") == "erp_api" for c in pg.evaluate("__calls") if "schema" in c), "every RPC through erp_api")
    pg.context.close()

    # ---------- phone width ----------
    pg = page(br, "owner", w=375, h=740, hash_="#/admin/members")
    pg.wait_for_selector("#m-table")
    check(pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth"), "phone width: admin members without horizontal page scroll")
    pg.click("[data-act=member-new]"); pg.wait_for_selector("#drawer")
    check(pg.evaluate("document.getElementById('drawer').getBoundingClientRect().width <= window.innerWidth"), "phone width: drawer fits")
    pg.context.close()
    br.close()

for m in ok:
    print("PASS:", m)
for m in errors:
    print("FAIL:", m)
print("smoke_erp_admin: %d passed, %d failed" % (len(ok), len(errors)))
sys.exit(1 if errors else 0)
