#!/bin/bash
# T15: builds the ERP load database (scratch, local only) and runs the generator. Never points at a remote host.
#   bash erp/backend/tests/load/run_erp_load.sh [db=erp_load] [scale]   scale: full (default) | quick (1/10 of the documents)
set -e
DB="${1:-erp_load}"; SCALE="${2:-full}"
case "$DB" in erp_load|erp_load_*) ;; *) echo "refusing: scratch DB name must be erp_load*"; exit 1;; esac
HERE="$(cd "$(dirname "$0")" && pwd)"; BACK="$(cd "$HERE/../.." && pwd)"
TMP=$(mktemp -d /tmp/erp_load.XXXXXX); cp -r "$BACK/." "$TMP"; chmod -R a+rX "$TMP"
su postgres -c "psql -X -q -c 'drop database if exists $DB' -c 'create database $DB'" 2>&1 | grep -v NOTICE || true
su postgres -c "psql -X -q -d $DB -c \"do \\\$\\\$ begin if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if; end \\\$\\\$\""
for f in $(cd "$TMP" && ls E[0-9]*.sql | sort); do su postgres -c "psql -X -q -v ON_ERROR_STOP=1 -d $DB -f $TMP/$f" >/dev/null 2>&1 || { echo "load $f failed"; exit 1; }; done
su postgres -c "psql -X -q -v ON_ERROR_STOP=1 -d $DB -f $TMP/tests/load/gen_erp_load.sql" >/dev/null
F=1; [ "$SCALE" = "quick" ] && F=10
gen() { echo "$(date +%T) generating $1"; su postgres -c "psql -X -q -v ON_ERROR_STOP=1 -d $DB -c \"call load.gen_tenant('$1', $2, $3, $4, $5, 365)\"" 2>&1 | grep -v NOTICE || true; }
# standard tenant: 5,000 items, 10 warehouses, 20,000 documents x 5 lines = 100,000 moves (+ 10 OPN x 40)
gen load_std 5000 10 $((20000 / F)) 5
# 18 small tenants: 500 items, 2 warehouses, 1,000 documents x 5 lines
for i in $(seq -w 1 18); do gen load_s$i 500 2 $((1000 / F)) 5; done
# stress tenant (10 x the standard: 50,000 items, 100 warehouses, 200,000 documents, 1,000,000 moves)
[ "$SCALE" = "full" ] && [ -n "$STRESS" ] && gen load_stress 50000 100 200000 5
su postgres -c "psql -X -q -d $DB -c 'vacuum analyze'" >/dev/null 2>&1
su postgres -c "psql -X -d $DB -c \"select t.code, (select count(*) from erp.items i where i.tenant_id = t.tenant_id) items,
  (select count(*) from erp.documents d where d.tenant_id = t.tenant_id) documents, (select count(*) from erp.stock_moves m where m.tenant_id = t.tenant_id) moves,
  l.finished - l.started took from erp.tenants t join load.tenants l on l.tenant_id = t.tenant_id order by t.code\""
rm -rf "$TMP"
