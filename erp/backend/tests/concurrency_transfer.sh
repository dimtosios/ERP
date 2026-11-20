#!/bin/bash
# iSmile ERP: transfers under concurrency (T16). Called by run_erp_tests.sh (mode A) with the database name.
#   1. receive vs cancel of the SAME dispatched transfer at the same moment (both orders): the document row lock
#      serialises them; the second gets ERP_STATE; exactly one effect (transit back to zero once, by one path).
#   2. two dispatches draining the same stock (10 on hand, 7 + 7): the item lock serialises them; under 'block' the
#      second is refused (ERP_STOCK_NEGATIVE), under 'warn' without ack it is held (posted false, nothing written);
#      the numbers stay gapless (1, 2, ...) and integrity (stock + transit) is clean.
# Commits a small fixture (tenant code 'trfc') into the scratch database. Exit 1 on failure.
DB="$1"
q() { su postgres -c "psql -X -q -tA -v ON_ERROR_STOP=1 -d $DB" ; }
T=50000000-0000-4000-8000-0000000000af
SUB=00000000-0000-4000-e000-0000000000f1
CL="'{\"sub\": \"$SUB\", \"email\": \"trfc@erp.test\", \"role\": \"authenticated\"}'"
q <<SQL >/dev/null
insert into erp.tenants (tenant_id, code, name) values ('$T', 'trfc', 'Transfer race') on conflict do nothing;
select erp.tenant_init('$T');
insert into erp.branches (tenant_id, code, name) values ('$T', 'C1', 'C one'), ('$T', 'C2', 'C two') on conflict do nothing;
insert into erp.members (tenant_id, email, role, all_branches, auth_user_id, bound_at) values ('$T', 'trfc@erp.test', 'owner', true, '$SUB', now()) on conflict do nothing;
insert into erp.warehouses (tenant_id, branch_id, code, name) select '$T', branch_id, 'TC-' || code, 'wh ' || code from erp.branches where tenant_id = '$T' on conflict do nothing;
insert into erp.items (tenant_id, code, name, base_unit_id) select '$T', 'TCI', 'item', unit_id from erp.units where tenant_id = '$T' and code = 'PCS' on conflict do nothing;
insert into erp.counterparties (tenant_id, name) values ('$T', 'TC supplier');
insert into erp.series (tenant_id, branch_id, doc_type, code, gapless) select '$T', branch_id, d, d || '-' || code, d = 'TRF'
  from erp.branches, unnest(array['TRF', 'GRN']) d where tenant_id = '$T' on conflict do nothing;
SQL
# api: run SQL as the member in one transaction; $1 = SQL, $2 = seconds to sleep before commit
api() {
  su postgres -c "psql -X -q -tA -d $DB" <<SQL 2>&1
begin;
set local role authenticated;
set local request.jwt.claims = $CL;
$1
select pg_sleep($2);
commit;
SQL
}
W1="(select warehouse_id from erp.warehouses where tenant_id = '$T' and code = 'TC-C1')"
W2="(select warehouse_id from erp.warehouses where tenant_id = '$T' and code = 'TC-C2')"
IT="(select item_id from erp.items where tenant_id = '$T' and code = 'TCI')"
B1="(select branch_id from erp.branches where tenant_id = '$T' and code = 'C1')"
grn() { api "select erp_api.doc_set_state((erp_api.doc_save_draft('GRN', jsonb_build_object('branch_id', $B1, 'warehouse_id', $W1,
         'counterparty_id', (select counterparty_id from erp.counterparties where tenant_id = '$T' limit 1),
         'lines', jsonb_build_array(jsonb_build_object('item_id', $IT, 'qty', $1, 'unit_price', 3))), gen_random_uuid()) ->> 'document_id')::uuid, 'posted', '{}', gen_random_uuid()) is not null;" 0 >/dev/null; }
draft() { api "select erp_api.doc_save_draft('TRF', jsonb_build_object('branch_id', $B1, 'warehouse_id', $W1, 'dest_warehouse_id', $W2,
         'lines', jsonb_build_array(jsonb_build_object('item_id', $IT, 'qty', $1))), gen_random_uuid()) ->> 'document_id';" 0 | grep -E '^[0-9a-f-]{36}$'; }
dispatch() { api "select erp_api.doc_set_state('$1', 'dispatched', '{\"ack_warnings\": $3}', gen_random_uuid()) ->> 'posted';" $2; }
receive() { api "select erp_api.doc_set_state('$1', 'received', '{}', gen_random_uuid()) #>> '{document,state}';" $2; }
cancel() { api "select erp_api.doc_set_state('$1', 'cancelled', '{\"reason\": \"race\"}', gen_random_uuid()) #>> '{document,state}';" $2; }
val() { echo "$1" | q; }
rc=0
fail() { echo "FAIL concurrency transfer: $*"; rc=1; }

# ---------- 1. receive vs cancel ----------
grn 20
for order in receive_first cancel_first; do
  D=$(draft 5); dispatch "$D" 0 false >/dev/null
  if [ $order = receive_first ]; then
    receive "$D" 2 > /tmp/erp_trfc_1.txt & P=$!; sleep 0.7; cancel "$D" 0 > /tmp/erp_trfc_2.txt; wait $P; WANT=received
  else
    cancel "$D" 2 > /tmp/erp_trfc_1.txt & P=$!; sleep 0.7; receive "$D" 0 > /tmp/erp_trfc_2.txt; wait $P; WANT=cancelled
  fi
  ST=$(val "select state from erp.documents where document_id = '$D'")
  NREV=$(val "select count(*) from erp.stock_moves where document_id = '$D' and kind = 'reversal'")
  NREC=$(val "select count(*) from erp.doc_trf where document_id = '$D'")
  TR=$(val "select coalesce(sum(qty_base), 0) from erp.stock_moves where document_id = '$D' and warehouse_id = (select warehouse_id from erp.warehouses where tenant_id = '$T' and kind = 'in_transit')")
  if [ $WANT = received ]; then EXP="0/1"; else EXP="2/0"; fi
  if [ "$ST" = "$WANT" ] && grep -q "ERP_STATE" /tmp/erp_trfc_2.txt && [ "$TR" = "0.0000" ] && [ "$NREV/$NREC" = "$EXP" ]; then :
  else fail "$order: state $ST (want $WANT), reversals $NREV, receipts $NREC, transit $TR"; cat /tmp/erp_trfc_1.txt /tmp/erp_trfc_2.txt; fi
done
[ $rc -eq 0 ] && echo "concurrency: receive and cancel of the same transfer at once (both orders) -> one wins, the other gets ERP_STATE, transit 0"

# ---------- 2. two dispatches draining the same stock ----------
for mode in block warn; do
  val "update erp.tenant_settings set negative_stock = '$mode' where tenant_id = '$T'" >/dev/null
  ONHAND=$(val "select qty from erp.stock_balances where warehouse_id = $W1 and item_id = $IT")
  NEED=$(val "select greatest(10 - $ONHAND, 0)"); [ "$NEED" != "0.0000" ] && [ "$NEED" != "0" ] && grn "$NEED"
  # bring W1 to exactly 10 (it holds 10 + 5 from the cancelled transfer of step 1 otherwise): move the rest to C2
  EXTRA=$(val "select qty - 10 from erp.stock_balances where warehouse_id = $W1 and item_id = $IT")
  if [ "$(val "select ($EXTRA)::numeric > 0")" = "t" ]; then D0=$(draft "$EXTRA"); dispatch "$D0" 0 false >/dev/null; receive "$D0" 0 >/dev/null; fi
  N0=$(val "select coalesce(max(number), 0) from erp.documents where tenant_id = '$T' and doc_type = 'TRF'")
  DA=$(draft 7); DB2=$(draft 7)
  dispatch "$DA" 2 false > /tmp/erp_trfc_1.txt & P=$!; sleep 0.7; dispatch "$DB2" 0 false > /tmp/erp_trfc_2.txt; wait $P
  SA=$(val "select state from erp.documents where document_id = '$DA'"); SB=$(val "select state from erp.documents where document_id = '$DB2'")
  NA=$(val "select number from erp.documents where document_id = '$DA'")
  BAL=$(val "select qty from erp.stock_balances where warehouse_id = $W1 and item_id = $IT")
  if [ "$mode" = block ]; then OK2=$(grep -c "ERP_STOCK_NEGATIVE" /tmp/erp_trfc_2.txt); else OK2=$(grep -cx "false" /tmp/erp_trfc_2.txt); fi
  if [ "$SA" = "dispatched" ] && [ "$SB" = "draft" ] && [ "$OK2" -ge 1 ] && [ "$NA" = "$((N0 + 1))" ] && [ "$BAL" = "3.0000" ]; then :
  else fail "$mode: states $SA / $SB, number $NA (after $N0), W1 $BAL"; cat /tmp/erp_trfc_1.txt /tmp/erp_trfc_2.txt; fi
  # the second one, acknowledged under warn, takes the NEXT number (gapless) and goes negative with a warning
  if [ "$mode" = warn ]; then
    dispatch "$DB2" 0 true >/dev/null
    NB=$(val "select number from erp.documents where document_id = '$DB2'")
    [ "$NB" = "$((NA + 1))" ] && [ "$(val "select qty from erp.stock_balances where warehouse_id = $W1 and item_id = $IT")" = "-4.0000" ] || fail "warn + ack: number $NB, W1 not -4"
  fi
done
GAPS=$(val "select count(*) from (select number, lag(number) over (partition by series_id order by number) p from erp.documents where tenant_id = '$T' and doc_type = 'TRF' and number is not null) x where p is not null and number <> p + 1")
INTEG=$(val "select jsonb_array_length(erp.stock_integrity('$T')) + jsonb_array_length(erp.trf_integrity('$T'))")
[ "$GAPS" = "0" ] && [ "$INTEG" = "0" ] || fail "gaps $GAPS, integrity problems $INTEG"
[ $rc -eq 0 ] && echo "concurrency: two dispatches draining the same stock -> one dispatched, the other refused (block) / held (warn); numbers gapless, integrity clean"
val "update erp.tenant_settings set negative_stock = 'warn' where tenant_id = '$T'" >/dev/null
grn 10   # leave the fixture's stock non-negative (no open negative-stock alert for later suites on this database)
rm -f /tmp/erp_trfc_1.txt /tmp/erp_trfc_2.txt
exit $rc
