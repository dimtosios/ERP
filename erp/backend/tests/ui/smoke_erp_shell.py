"""Smoke test (T01): erp.html shell. Login form, wrong password message, sign in -> member_bind + whoami, home for a
member, "No access" for a non-member (and the conflict hint), forgot-password call, sign out, every RPC through the
erp_api schema, phone width without horizontal scroll. Stubbed supabase-js, no network.
usage (repo root): python3 -I erp/backend/tests/ui/smoke_erp_shell.py erp.html erp/backend/tests/ui/mock_supabase_erp.js"""
import sys, pathlib, json
from playwright.sync_api import sync_playwright

html, mock = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
errors, ok = [], []


def check(cond, msg):
    (ok if cond else errors).append(msg)


def calls(pg, name=None):
    return pg.evaluate("n => __calls.filter(c => !n || c.name === n)", name)


def page(br, store, w=1280, h=860):
    pg = br.new_context(viewport={"width": w, "height": h}).new_page()
    pg.on("console", lambda m: m.type == "error" and errors.append("console: " + m.text))
    pg.on("pageerror", lambda e: errors.append("pageerror: %s" % e))
    pg.on("dialog", lambda d: (errors.append("unexpected native dialog: " + d.message), d.dismiss()))
    pg.add_init_script("try{var L=%s;Object.keys(L).forEach(function(k){localStorage.setItem(k,L[k]);})}catch(e){}" % json.dumps(store))
    pg.route("**/supabase.min.js", lambda r: r.fulfill(path=str(mock), content_type="application/javascript"))
    pg.route("https://**", lambda r: r.abort() if "supabase.min.js" not in r.request.url else r.fallback())
    pg.goto(html.as_uri())
    return pg


with sync_playwright() as p:
    br = p.chromium.launch()
    # 1. signed out: login form
    pg = page(br, {"mock_role": "owner"})
    pg.wait_for_selector("form[data-form=login]")
    check(pg.locator("#a-email").count() == 1 and pg.locator("#a-pw").count() == 1, "signed out: login form with email and password")
    pg.click("#a-go")
    check("Enter email and password" in pg.inner_text("#a-msg"), "empty form: message, no call")
    pg.fill("#a-email", "me@clinic.test"); pg.fill("#a-pw", "wrong"); pg.click("#a-go")
    pg.wait_for_function("document.querySelector('#a-msg').textContent.indexOf('Invalid') >= 0")
    check(not pg.locator("#a-go").is_disabled(), "wrong password: message shown, button enabled again")
    pg.click("[data-act=forgot]")
    pg.wait_for_function("__calls.some(c => c.name === 'auth.reset')")
    check(calls(pg, "auth.reset")[0]["args"]["email"] == "me@clinic.test", "forgot password sends the typed email")
    pg.fill("#a-pw", "right-password"); pg.click("#a-go")
    pg.wait_for_selector("#main")
    names = [c["name"] for c in calls(pg) if "schema" in c]
    check(names[:2] == ["member_bind", "whoami"], "after sign in: member_bind then whoami %s" % names[:3])
    check(all(c["schema"] == "erp_api" for c in calls(pg) if "schema" in c), "every RPC goes to the erp_api schema")
    check(calls(pg, "member_bind")[0]["args"].get("p_idempotency_key"), "member_bind carries an idempotency key")
    check("iSmile" in pg.inner_text(".top") and "Owner" in pg.inner_text("#main"), "member: home shows tenant and role")
    pg.click("[data-act=signout]"); pg.wait_for_selector("form[data-form=login]")
    check(True, "sign out returns to the login form")
    pg.context.close()

    # 2. non-member: no access
    pg = page(br, {"mock_role": "none", "mock_session": "1"})
    pg.wait_for_selector("#noaccess")
    txt = pg.inner_text("#noaccess")
    check("No access" in txt and "stranger@else.test" in txt and "invite this email" in txt, "non-member: 'No access' with the login email")
    check(pg.locator(".top").count() == 0, "non-member: no app frame / navigation")
    pg.context.close()
    pg = page(br, {"mock_role": "none", "mock_session": "1", "mock_conflict": "1"})
    pg.wait_for_selector("#noaccess")
    check("different login" in pg.inner_text("#noaccess"), "invitation bound to another login: conflict hint")
    pg.context.close()

    # 3. server error that is not ERP_AUTH: error screen with retry
    pg = page(br, {"mock_role": "owner", "mock_session": "1", "mock_fail": "whoami"})
    pg.wait_for_selector("[data-act=retry]")
    check("Some fields need attention" in pg.inner_text("#app"), "other error: mapped text + retry button")
    pg.context.close()

    # 4. phone width
    pg = page(br, {"mock_role": "owner", "mock_session": "1"}, w=375, h=740)
    pg.wait_for_selector("#main")
    check(pg.evaluate("document.documentElement.scrollWidth <= window.innerWidth"), "phone width: no horizontal scroll")
    pg.context.close()
    br.close()

for m in ok:
    print("PASS:", m)
for m in errors:
    print("FAIL:", m)
print("smoke_erp_shell: %d passed, %d failed" % (len(ok), len(errors)))
sys.exit(1 if errors else 0)
