#!/bin/bash
# iSmile ERP: mutation check of the T16 transfer tests. Each mutation is a deliberately broken copy of the E files
# (cost through transit, transit zero); the E160 suite must FAIL on every one of them (else the tests do not guard the
# rule). Called by run_erp_tests.sh (mode A) with the directory of the E files; uses the scratch database erp_mut.
# Exit 1 when a mutation survives.
SRC="$1"
M=$(mktemp -d /tmp/erp_mut.XXXXXX)
rc=0
mutate() { # $1 = name, $2 = file, $3 = python literal of the old text, $4 = new text
  rm -rf "$M/e"; mkdir -p "$M/e"; cp -r "$SRC/." "$M/e"
  python3 -I - "$M/e/$2" "$3" "$4" <<'PY' || return 1
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
if s.count(old) < 1:
    sys.exit('mutation text not found in %s' % p)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
  chmod -R a+rX "$M"
  su postgres -c "psql -X -q -c 'drop database if exists erp_mut' -c 'create database erp_mut'" >/dev/null 2>&1
  for f in $(cd "$M/e" && ls E[0-9]*.sql | sort); do
    su postgres -c "psql -X -q -v ON_ERROR_STOP=1 -d erp_mut -f $M/e/$f" >/dev/null 2>&1 || { echo "mutation $1: load of $f failed"; rc=1; return; }
  done
  out=$(su postgres -c "cd $M/e/tests && psql -X -v ON_ERROR_STOP=1 -d erp_mut -f $M/e/tests/E160_transfer_tests.sql" 2>&1)
  if echo "$out" | grep -q "ALL TESTS PASSED"; then
    echo "FAIL mutation survived: $1"; rc=1
  else
    echo "mutation killed: $1 -> $(echo "$out" | grep -m1 -oE 'FAIL[^|]*' | cut -c1-150)"
  fi
}
# 1. cost unchanged through transit: the receipt values the moved quantity at the CURRENT cost, not the dispatch's
mutate "receipt at the current cost (cost drift through transit)" E140_stock_engine.sql \
  "    if src.move_id is not null then
      -- the paired transit move and the receipt moves" \
  "    if src.move_id is not null and mv.move_date < mv.move_date then
      -- the paired transit move and the receipt moves"
# 2. cost unchanged: a transfer move costed like a normal issue / receipt (layers consumed, average re-computed)
mutate "transfer costed as a normal move (layers consumed)" E140_stock_engine.sql \
  "  if mv.cost_rule = 'transfer' then" "  if false then"
# 3. transit zero: the receipt takes the stock out of the SOURCE instead of the transit warehouse
mutate "receipt does not empty transit" E160_transfer.sql \
  "      values (p_tenant, p_doc, l.line_id, tw, l.item_id, rdate, 'normal', -moved, 'transfer', src," \
  "      values (p_tenant, p_doc, l.line_id, d.warehouse_id, l.item_id, rdate, 'normal', -moved, 'transfer', src,"
# 4. transit zero: the transfer closes as soon as ONE adjustment is posted (shortage still in transit)
mutate "close while the shortage is still in transit" E160_transfer.sql \
  "     and not exists (select 1 from erp.documents x where x.tenant_id = p_tenant and x.document_id in (t.adj_out_id, t.adj_in_id) and x.state <> 'posted')
     and erp.doc_can(p_tenant, d, 'create', 'dest') and erp.doc_can_read(p_tenant, d) then" \
  "     and erp.doc_can(p_tenant, d, 'create', 'dest') and erp.doc_can_read(p_tenant, d) then
    update erp.doc_trf set closed_at = now() where tenant_id = p_tenant and document_id = p_doc;
    perform set_config('erp.doc_write', 'on', true);
    update erp.documents set state = 'closed' where tenant_id = p_tenant and document_id = p_doc;
    perform set_config('erp.doc_write', 'off', true);
    return jsonb_build_object('closed', true);
  end if;
  if false then"
# 5. the integrity check of transit is vacuous
mutate "transit integrity check vacuous" E160_transfer.sql \
  "     where coalesce(w.qty, 0) <> coalesce(h.qty, 0)" "     where false"
su postgres -c "psql -X -q -c 'drop database if exists erp_mut'" >/dev/null 2>&1
rm -rf "$M"
[ $rc -eq 0 ] && echo "mutation check: every transfer mutation is killed by tests/E160_transfer_tests.sql"
exit $rc
