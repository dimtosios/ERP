#!/bin/bash
# iSmile ERP: local test runner (own runner; the CRM's run_db_tests.sh is only CALLED, never edited).
#   bash erp/backend/run_erp_tests.sh             mode A: EMPTY database without any CRM object
#   bash erp/backend/run_erp_tests.sh --with-crm  mode B: CRM loaded and tested by run_db_tests.sh, ERP on top,
#                                                 CRM suites again after the ERP and after drop schema erp cascade
#   bash erp/backend/run_erp_tests.sh --all       both modes (definition of done, 03 section 6)
# Every mode: static checks, all E files loaded TWICE (re-run safety), every SQL suite run TWICE, Playwright smoke.
# Needs a local PostgreSQL 16 (service postgresql start) and python3 + playwright for the smoke tests.
# Exit code 1 when anything fails.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MODE="${1:-}"
RC=0
fail() { echo "FAIL: $*"; RC=1; }
# private copy per run (readable by the postgres user), so two runs on one machine do not share files
TMP=$(mktemp -d /tmp/erp_backend_run.XXXXXX)
cp -r "$HERE/." "$TMP"; chmod -R a+rX "$TMP"; chmod a+rx "$TMP"
EFILES=$(cd "$HERE" && ls E[0-9]*.sql 2>/dev/null | sort)
SUITES=$(cd "$HERE" && ls tests/E[0-9]*_tests.sql 2>/dev/null | sort)

echo "=== static checks ==="
# 1. no E file names a CRM object (public.* / app.*), comments ignored
python3 -I - "$HERE" <<'PY' || RC=1
import pathlib, re, sys
bad = []
for f in sorted(pathlib.Path(sys.argv[1]).glob("E[0-9]*.sql")):
    for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
        code = line.split("--", 1)[0]
        if re.search(r"(?<![\w.])(public|app|auth|storage)\s*\.", code, re.I):
            bad.append("%s:%d: %s" % (f.name, n, line.strip()))
print("no CRM / Supabase-internal object named in E files" if not bad else "FAIL: E files name a CRM object:\n" + "\n".join(bad))
sys.exit(1 if bad else 0)
PY
# 2. erp.html is built from the committed sources, every JS file parses
python3 "$ROOT/erp/build_erp.py" --check || RC=1
for f in "$ROOT"/erp/app/*.js; do node --check "$f" || fail "node --check $f"; done
# 3. no CRM file differs from main (branch commits + working tree)
CRM_RE='^(app\.js|index\.html|build_index\.py|run_db_tests\.sh|ARCHITECT_STATE\.md|backend/(schema|rls|functions)\.sql|backend/[0-9]{3}_.*\.sql|backend/tests/|backend/supabase/functions/(calendar-sync|daily-digest|_shared)/)'
if git -C "$ROOT" rev-parse --verify -q main >/dev/null; then
  CHANGED=$( (git -C "$ROOT" diff --name-only main...HEAD; git -C "$ROOT" diff --name-only HEAD) | sort -u | grep -E "$CRM_RE")
  if [ -n "$CHANGED" ]; then fail "CRM files changed: $CHANGED"; else echo "no CRM file changed against main"; fi
fi

psqlq() { su postgres -c "psql -X -q -v ON_ERROR_STOP=1 -d $1 $2" 2>&1; }
load_erp() { # $1 = database
  for pass in 1 2; do
    for f in $EFILES; do
      out=$(su postgres -c "psql -X -q -v ON_ERROR_STOP=1 -d $1 -f $TMP/$f" 2>&1); ex=$?
      if [ $ex -ne 0 ]; then fail "load pass $pass $f"; echo "$out" | grep -v NOTICE | head -20; fi
    done
    echo "E files loaded, pass $pass: $(echo $EFILES | wc -w) files"
  done
}
run_suites() { # $1 = database, $2 = label
  for run in 1 2; do
    for s in $SUITES; do
      log=/tmp/erp_test_out_$(basename $s .sql)_$2_$run.txt
      su postgres -c "cd $TMP/tests && psql -X -v ON_ERROR_STOP=1 -d $1 -f $TMP/$s" > "$log" 2>&1; ex=$?   # cwd tests/: golden CSV paths
      echo "[$2 run $run] $s exit=$ex PASS=$(grep -c 'PASS:' "$log") $(grep -E '^ ALL TESTS PASSED' "$log" | head -1 | tr -s ' ')"
      if [ $ex -ne 0 ] || ! grep -q "ALL TESTS PASSED" "$log"; then fail "$s ($2 run $run)"; grep -n "FAIL\|ERROR" -A3 "$log" | head -30; fi
    done
  done
}
crm_suites() { # $1 = label; the CRM suite list is read from run_db_tests.sh so it never goes stale
  local list; list=$(grep -o 'for t in [^;]*' "$ROOT/run_db_tests.sh" | tail -1 | sed 's/^for t in //')
  rm -rf /tmp/erp_crm_backend; cp -r "$ROOT/backend" /tmp/erp_crm_backend; chmod -R a+rX /tmp/erp_crm_backend
  local n=0 bad=0
  for mode in off on; do for t in $list; do
    su postgres -c "PGOPTIONS='-c stub.always_block=$mode' psql -X -v ON_ERROR_STOP=1 -d ismile_test -f /tmp/erp_crm_backend/$t" > /tmp/erp_crm_out.txt 2>&1
    ex=$?; n=$((n+1)); if [ $ex -ne 0 ]; then bad=$((bad+1)); fail "CRM suite $t ($1, always_block=$mode)"; grep -n "FAIL\|ERROR" -A3 /tmp/erp_crm_out.txt | head -10; fi
  done; done
  echo "CRM suites $1: $((n-bad))/$n green"
  rm -rf /tmp/erp_crm_backend
}

if [ "$MODE" != "--with-crm" ]; then
  echo "=== mode A: empty database (no CRM objects) ==="
  su postgres -c "psql -X -q -c 'drop database if exists erp_test' -c 'create database erp_test'" 2>&1 | grep -v NOTICE
  # the Supabase API roles exist on every Supabase project; locally they are created if this cluster lacks them
  psqlq erp_test "-c \"do \\\$\\\$ begin
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
    if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
    if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
  end \\\$\\\$\"" | grep -v NOTICE
  CRM_OBJ=$(psqlq erp_test "-tAc \"select count(*) from pg_namespace where nspname in ('app') or exists (select 1 from pg_tables where schemaname = 'public')\"")
  [ "$CRM_OBJ" = "0" ] && echo "database erp_test has no CRM object" || fail "erp_test is not empty ($CRM_OBJ)"
  load_erp erp_test
  run_suites erp_test empty
  # tenant #1 onboarding seed, run twice (re-run safe): exactly one pending owner invitation on tenant #1
  if [ -e "$TMP/seed/tenant1_onboarding.sql" ]; then
    for i in 1 2; do su postgres -c "psql -X -q -v ON_ERROR_STOP=1 -d erp_test -v owner_email=seed.owner@example.test -f $TMP/seed/tenant1_onboarding.sql" >/dev/null 2>&1 || fail "seed run $i"; done
    n=$(psqlq erp_test "-tAc \"select count(*) from erp.members where tenant_id = '00000000-0000-4000-8000-000000000001' and role = 'owner' and email = 'seed.owner@example.test' and auth_user_id is null\"")
    [ "$n" = "1" ] && echo "seed/tenant1_onboarding.sql twice: one pending owner invitation on tenant #1" || fail "onboarding seed ($n)"
  fi
  # two sessions at once (cannot be a rolled-back suite): last-owner race, review F1 finding F1-02
  bash "$HERE/tests/concurrency_last_owner.sh" erp_test || fail "concurrency: last-owner race"
  # numbering: 8 sessions posting into one series at once, some rolled back (T09)
  bash "$HERE/tests/concurrency_numbering.sh" erp_test || fail "concurrency: numbering"
  # conversion: two sessions convert the same source at once (T44, golden V8)
  bash "$HERE/tests/concurrency_convert.sh" erp_test || fail "concurrency: conversion"
  # F2 review: lock date moved during a post (F2-03); recost job against a queued post of the same item (F2-02)
  bash "$HERE/tests/concurrency_lockdate.sh" erp_test || fail "concurrency: lock date"
  bash "$HERE/tests/concurrency_recost.sh" erp_test || fail "concurrency: recost job"
  # T16 transfers: receive vs cancel of one transfer; two dispatches draining the same stock (gapless, integrity)
  bash "$HERE/tests/concurrency_transfer.sh" erp_test || fail "concurrency: transfer"
  # T16 mutation check: deliberately broken copies (cost through transit, transit zero) must fail the E160 suite
  bash "$HERE/tests/mutation_transfer.sh" "$TMP" || fail "mutation check: transfer"
  # F2 review: the independent costing model (tests/costing_model.py, written from the 02 rules, not from the SQL):
  # re-compute every golden CSV from its inputs, then a differential fuzz through the real RPCs (fixed seeds)
  out=$(python3 -I "$TMP/tests/costing_model.py" golden "$TMP/tests/golden" 2>&1); ex=$?
  echo "$out" | tail -1; [ $ex -ne 0 ] && { fail "golden re-compute (costing_model.py)"; echo "$out" | grep MISMATCH | head -20; }
  for f in "inline 11 60" "queue 12 40"; do set -- $f
    # F2-15: fresh statistics and no dead tuples of the previous run (rolled back) before EACH run; otherwise the
    # replay of the fuzz tenant (rows created inside the run's transaction) can get a pathological plan (seen in T16)
    psqlq erp_test "-c 'vacuum analyze'" > /dev/null
    out=$(cd "$TMP/tests" && python3 -I costing_model.py fuzz erp_test $2 $3 $1 2>&1); ex=$?
    echo "$out" | tail -1; [ $ex -ne 0 ] && { fail "costing fuzz $1"; echo "$out" | head -20; }
  done
fi

if [ "$MODE" = "--with-crm" ] || [ "$MODE" = "--all" ]; then
  echo "=== mode B: database with the CRM ==="
  bash "$ROOT/run_db_tests.sh" > /tmp/erp_crm_first.txt 2>&1
  if grep -q "ALL SUITES PASSED" /tmp/erp_crm_first.txt; then echo "CRM suites before the ERP: green (run_db_tests.sh)"; else fail "CRM suites before the ERP"; tail -20 /tmp/erp_crm_first.txt; fi
  load_erp ismile_test
  run_suites ismile_test crm
  crm_suites "after the ERP"
  psqlq ismile_test "-c 'set client_min_messages = warning' -c 'drop schema erp_api cascade' -c 'drop schema erp cascade'" | grep -v "NOTICE\|^DETAIL\|^drop cascades"
  crm_suites "after drop schema erp cascade"
fi

echo "=== Playwright smoke ==="
for s in "$HERE"/tests/ui/smoke_*.py; do
  [ -e "$s" ] || continue
  out=$(cd "$ROOT" && python3 -I "$s" erp.html erp/backend/tests/ui/mock_supabase_erp.js 2>&1); ex=$?
  echo "$(basename $s): $(echo "$out" | tail -1)"
  [ $ex -ne 0 ] && { fail "$(basename $s)"; echo "$out" | grep FAIL | head -20; }
done

rm -rf "$TMP"
echo "run_erp_tests.sh: $([ $RC -eq 0 ] && echo ALL ERP CHECKS PASSED || echo SOME ERP CHECK FAILED)"
exit $RC
