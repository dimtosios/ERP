# ERP checkpoint F1: independent review of E0 (T01-T04)

Date 2026-11-18. Reviewer: independent Opus 5.5 run (did not write the E0 code). Branch `erp-dev`, base 41a8c0b.
Scope (05 F1): tenancy, RLS, grants, invitations / first-login binding, onboarding, standalone install, no CRM file or
object touched. Read: README, 02 (RLS, permission matrix), 03, 05, STATE (22 assumptions), `E100_tenancy.sql`,
`E110_members.sql`, seed, all suites, runner, UI shell (`00_core.js`, `90_admin.js`). Nothing was applied to live.

## 1. Verdict: PASS WITH FIXES

The E0 layer is well built: every table has RLS enabled + forced, SELECT-only grants, every function pins
`search_path = ''`, internals are closed, writes go only through `erp_api` SECURITY DEFINER RPCs, the generated
suite is catalog-driven. The attacks below found two privilege-escalation paths and one race that needed code changes;
all are fixed with tests. One high finding (F1-04) depends on Supabase Auth settings that only the owner can confirm on
live: C0 must not run before step 0 of section 4 is confirmed. T05 and later tasks can start on `erp-dev` now.

Findings: 2 high, 2 medium, 6 low, 8 info (18). Fixed in code: F1-01..F1-03, F1-05..F1-10, and F1-04 partly.

## 2. Findings

| id | severity | what | fixed? | evidence |
|---|---|---|---|---|
| F1-01 | high | One login (`sub`) could be bound in two tenants (bind the 2nd invitation after an email change). `can()`, `my_tenants()` and RLS read every bound row of the login, while the RPCs act on the lowest tenant: a readonly member of A that is owner of B invited an owner into A and read the members of both tenants. | yes: `members_auth_uq` UNIQUE on `members (auth_user_id)`; `member_bind` returns `login_in_other_organisation` | E991 "F1-01" (6 checks). On the original code: readonly user invited an owner into A, `select count(*) from erp.members` = 5 rows of 2 tenants |
| F1-02 | medium | Last-owner rule was a write-skew race: two owners demoting (or unlinking) each other at the same moment both saw "another owner exists"; the tenant was left with no owner (unrecoverable except by SQL). | yes: `erp.members_lock(tenant)` (advisory lock, caller re-read after it) in `member_update` / `member_reset_binding`; `reset_binding` also checks `last_owner` | `tests/concurrency_last_owner.sh` (runner mode A): original code 0 bound owners left, fixed 1 owner left, 2nd call `ERP_FORBIDDEN` |
| F1-03 | medium | `member.manage` is data (02: a tenant may give it to another role). A manager given it could invite an owner, promote itself to owner, demote / deactivate the owners and unlink their logins: full takeover. | yes: the owner role, an owner's row and an owner's login are changed by owners only (`ERP_FORBIDDEN`) | E991 "F1-03" (9 checks); 7 failed on the original code (manager became owner, owner deactivated) |
| F1-04 | high (config) | Binding trusts the email claim of the login. Every existing login of the SHARED Supabase project (CRM staff) can take a pending invitation if it can change its email without confirmation; same with open sign-ups or anonymous sign-ins. Worst case: the owner invitation between C0 and the owner's first sign-in. | partly: `tenant_onboard(code, name, email, owner_login_id)` pre-binds the owner at C0 (no window); anonymous logins refused (F1-09). The rest is Supabase configuration. | E991 "F1-04" (6 checks). **Owner confirms on live: section 4 step 0** |
| F1-05 | low | `branch_save` (update) checked `branch.write` without the branch: a role given `branch.write` could change branches outside its `branch_ids`. | yes: `require_cap('branch.write', id)` on update | E991 "F1-05"; failed on the original |
| F1-06 | low | `tenant_settings` policy let every member read the row (clinic_user / warehouse / readonly: "-" in the 02 matrix) by a direct table read. | yes: policy adds `can('tenant.settings.read')`; `whoami` keeps giving the subset every member needs | E991 "F1-06"; failed on the original |
| F1-07 | low | E100 re-run did `revoke all on all tables in schema erp from authenticated`: re-running E100 after E120+ would silently remove later files' SELECT grants. | yes: authenticated loses only write privileges on all tables; `idempotency_keys` revoked explicitly | E991 "F1-07" runs E100 again inside the suite; failed on the original |
| F1-08 | low | An idempotency key replayed for ANY member of the tenant (same rpc + payload): another member got the stored reply; `member_bind` hashed `{}` so a second login with the same email and key got `{"bound": true, tenant_id}`. | yes: `idem_begin` requires the same member; `member_bind` payload holds the `sub` | E991 "F1-08" (2 checks); failed on the original |
| F1-09 | low | `member_bind` did not refuse an anonymous Supabase login (`is_anonymous`). | yes: `ERP_AUTH` | E991 "F1-09"; failed on the original |
| F1-10 | low | Runner copied the backend to a fixed `/tmp/erp_backend_run`: a second run (another worktree) overwrote the files of the first. | yes: `mktemp -d` per run. The databases `erp_test` / `ismile_test` stay shared: never run two runners at once | runner |
| F1-11 | info | `email_taken` is an existence oracle across tenants and lets one tenant squat any email (v1: one tenant, accepted, STATE 16). | no (E10 / F9) | - |
| F1-12 | info | Audit `ip` is the FIRST `x-forwarded-for` hop, which the client can set: a hint, never evidence. | no | - |
| F1-13 | info | Identity = `request.jwt.claims` (same model as `auth.uid()`): safe while `authenticated` has no raw SQL path. No CRM RPC may run dynamic SQL or `set_config` from user input (CRM is off limits; noted for its own reviews). | no | - |
| F1-14 | info | `statement_timeout` in a function SET clause does not time out the calling statement for a direct SQL call; on live it depends on PostgREST >= 12 (function settings) and the `authenticated` role default. | no: verify at C0 step 0 | STATE 9 |
| F1-15 | info | Functions are executable by PUBLIC from `create` until the file's `erp.lock_down()` at its end. `erp` is not an exposed schema, so no API path reaches them; run each E file as one script. | no | - |
| F1-16 | info | Direct SELECT on `erp.members` returns `auth_user_id` to `member.read` roles (RPC replies hide it). Not reachable: `erp` is not exposed. | no | - |
| F1-17 | info | `tenant_onboard` keeps an existing owner row (also a pending one with a mistyped email) and returns `owner_invited: false`. Recovery: deactivate the wrong row in SQL, run again. | no: C0 step 3 checks the result | - |
| F1-18 | info | pg_graphql: confirm `erp` / `erp_api` are not reflected. Even if they were: RLS + SELECT-only grants, no mutations. | no: optional C0 check | - |

Checked and holding (attacked in E991, no defect): temp tables `members` / `branches` / `role_caps` in `pg_temp` plus a
hostile `search_path` do not change identity, caps or replies; every function in `erp` and `erp_api` pins
`search_path = ''` and every SECURITY DEFINER function belongs to the schema owner; `anon` (even with an owner's
claims), `service_role` (BYPASSRLS, no grants) and PUBLIC get nothing; `authenticated` cannot create objects in
`erp` / `erp_api`, call any internal function (`tenant_onboard`, `audit`, `alert_raise`, `role_caps_sync`,
`members_lock`, `lock_down`, `idem_end`), use the sequence, or insert / update / delete any table (no REFERENCES /
TRIGGER either); `can()` is false for a branch of another tenant; a view without `security_invoker` would fail the
suite (guard for E120+). The UI escapes every server value before `innerHTML`; buttons only follow `caps`.

Permission matrix (02 vs `role_cap_defaults`): matches for E0 capabilities (settings / members: owner c a, manager r,
accounting r, others -; audit: owner, manager own branches, accounting). `branch.read` for every role and
`alert.read` / `alert.resolve` are additions not named in 02 (needed by whoami / alerts; fine).

Standalone / re-run / CRM: E files twice on an empty database and on the CRM database, suites twice, CRM suites 20/20
before, after, and after `drop schema erp_api cascade; drop schema erp cascade;` (no roles, default privileges or
objects outside the two schemas). No CRM file differs from main.

Test quality: E990 is catalog-driven (new tables / RPCs without coverage fail) and does real two-tenant negative reads
for every role. Gaps were: one login in two tenants, delegated capabilities, concurrency, behavioural anon /
service_role checks, search_path of internal functions, views, re-run grants. Added: `tests/E991_adversarial_tests.sql`
(64 checks, runs in both modes, twice) and `tests/concurrency_last_owner.sh`.

## 3. Assumptions (STATE.md)
Changed: 7 (unique login index), 14 (Auth settings, owner pre-bind), 15 (serialised admin, owner-only owner changes),
17 (4th onboarding argument). New: 23 (settings policy), 24 (E100 write-only revoke). Open, live facts: 8 (BYPASSRLS
of `postgres`; E100 refuses otherwise, safe failure), 9 (timeout). Accepted: 16. Others confirmed unchanged.

## 4. Live run list C0 (owner applies; never an agent)
0. **Pre-checks (stop if one fails).** Supabase dashboard, Authentication: "Allow new users to sign up" OFF;
   "Allow anonymous sign-ins" OFF; Email provider "Confirm email" ON and "Secure email change" ON. SQL editor:
   `select current_user, rolbypassrls from pg_roles where rolname = current_user;` -> `postgres`, `true`.
   `select rolname, rolconfig from pg_roles where rolname = 'authenticated';` -> note `statement_timeout` (expect 8s).
   `select nspname from pg_namespace where nspname in ('erp', 'erp_api');` -> no rows (first install).
1. SQL editor, as `postgres`: run `erp/backend/E100_tenancy.sql` (whole file), then `erp/backend/E110_members.sql`.
2. `select erp.tenant_onboard('ismile', 'iSmile', '<owner email>', (select id from auth.users where email = '<owner email>'));`
   Expect `owner_bound: true`. If the owner has no login yet (`owner_bound: false`): Authentication > Users > Invite
   user with the same email, and the owner signs in to `erp.html` right away.
3. Check: `select email, role, active, auth_user_id is not null as bound from erp.members;` -> one row, owner, bound.
4. Settings > API > Exposed schemas: ADD `erp_api` (never `erp`). Authentication > URL configuration: add
   `<site>/erp.html` to the redirect URLs.
5. Deploy: merge `erp-dev` into `main` at this checkpoint (Netlify publishes `erp.html`).
6. Live smoke: owner opens `erp.html`, signs in, sees Home and Admin; a CRM user without an invitation sees "No
   access"; the CRM (`index.html`) still signs in and loads the board.
7. Optional: in the GraphQL explorer confirm no `erp` type is listed (F1-18).
Rollback: remove `erp_api` from the exposed schemas; SQL editor `drop schema erp_api cascade; drop schema erp cascade;`
(tested locally: CRM suites stay green); remove the redirect URL. `erp.html` without the schemas shows an error only.

## 5. Owner decisions / confirmations
- Confirm the four Auth settings of step 0 (F1-04). If "Confirm email" must stay OFF for the CRM, tell Fable before C0:
  then every ERP invitation needs the pre-bind path (owner reads the login id in the SQL editor) instead of `member_bind`.
- Confirm the owner email has a Supabase login (CRM owner) so step 2 pre-binds.
