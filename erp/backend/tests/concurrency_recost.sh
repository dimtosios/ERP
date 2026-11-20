#!/bin/bash
# iSmile ERP: F2-02 (review F2). The recost job runs while a session that already holds an item's lock (it posted a
# document of that item) posts a backdated document of the same item that goes to the recost queue. Before F2 the
# job locked the queue row first and then waited for the item lock, while the poster held the item lock and waited
# for the queue row: deadlock (one of the two aborted). Now the job only TRIES the item lock (lock order item ->
# queue row everywhere): it skips the busy item, the post commits, no deadlock. Called by run_erp_tests.sh (mode A)
# with the database name; commits a small fixture (tenant code 'recr', TEST types ZRI / ZRO). Exit 1 on failure.
DB="$1"
q() { su postgres -c "psql -X -q -tA -v ON_ERROR_STOP=1 -d $DB" ; }
T=50000000-0000-4000-8000-0000000000f2
SUB=00000000-0000-4000-e000-0000000000f2
CL="'{\"sub\": \"$SUB\", \"email\": \"recr@erp.test\", \"role\": \"authenticated\"}'"
post() { # type, qty, price or null, day offset
  echo "select erp_api.doc_set_state((erp_api.doc_save_draft('$1', jsonb_build_object('branch_id', (select branch_id from erp.branches where tenant_id = '$T' and code = 'R1'),
    'warehouse_id', (select warehouse_id from erp.warehouses where tenant_id = '$T' and code = 'RW'), 'doc_date', ((erp_api.whoami() ->> 'today')::date + $4),
    'lines', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('item_id', (select item_id from erp.items where tenant_id = '$T' and code = 'RX'), 'qty', $2, 'unit_price', $3)))),
    gen_random_uuid()) ->> 'document_id')::uuid, 'posted', '{\"ack_warnings\": true}', gen_random_uuid()) ->> 'posted';"
}
q > /dev/null <<SQL
insert into erp.tenants (tenant_id, code, name) values ('$T', 'recr', 'Recost race') on conflict do nothing;
select erp.tenant_init('$T');
insert into erp.branches (tenant_id, code, name) values ('$T', 'R1', 'R one') on conflict do nothing;
insert into erp.members (tenant_id, email, role, all_branches, auth_user_id, bound_at) values ('$T', 'recr@erp.test', 'owner', true, '$SUB', now()) on conflict do nothing;
insert into erp.warehouses (tenant_id, branch_id, code, name) select '$T', branch_id, 'RW', 'R w' from erp.branches where tenant_id = '$T' on conflict do nothing;
insert into erp.doc_types (doc_type, name, area, cap_prefix, sort, enabled, stock_sign, cost_rule, needs_warehouse, price_kind) values
  ('ZRI', 'Race in', 'warehouse', 'zrr', 997, true, 1, 'line', true, 'cost'), ('ZRO', 'Race out', 'warehouse', 'zrr', 998, true, -1, 'issue', true, 'none') on conflict do nothing;
insert into erp.doc_transitions (doc_type, from_state, to_state, cap, action, label) values ('ZRI', 'draft', 'posted', 'create', 'post', 'x'), ('ZRO', 'draft', 'posted', 'create', 'post', 'x')
on conflict do nothing;
insert into erp.capabilities (capability, area) values ('doc.zrr.read', 'test'), ('doc.zrr.create', 'test') on conflict do nothing;
insert into erp.role_caps (tenant_id, role, capability) values ('$T', 'owner', 'doc.zrr.read'), ('$T', 'owner', 'doc.zrr.create') on conflict do nothing;
insert into erp.series (tenant_id, branch_id, doc_type, code) select '$T', branch_id, d, d from erp.branches, unnest(array['ZRI', 'ZRO']) d where tenant_id = '$T' on conflict do nothing;
insert into erp.items (tenant_id, code, name, base_unit_id) select '$T', 'RX', 'race item', unit_id from erp.units where tenant_id = '$T' and code = 'PCS' on conflict do nothing;
begin;
set local role authenticated;
select set_config('request.jwt.claims', $CL, true) is null;
$(post ZRI 10 5 -3)
$(post ZRO 2 null -1)
set local erp.recost_inline_limit = '0';
$(post ZRI 5 7 -2)
commit;
SQL
N=$(echo "select count(*) from erp.recost_queue where tenant_id = '$T'" | q)
[ "$N" = "1" ] || { echo "FAIL concurrency recost: fixture not queued ($N)"; exit 1; }
# session P: posts an issue of RX (holds the item lock), waits, then a backdated receipt of RX that goes to the queue
su postgres -c "psql -X -q -tA -d $DB" > /tmp/erp_rc_p.txt 2>&1 <<SQL &
begin;
set local role authenticated;
select set_config('request.jwt.claims', $CL, true) is null;
$(post ZRO 1 null 0)
select pg_sleep(2);
set local erp.recost_inline_limit = '0';
$(post ZRI 1 6 -2)
commit;
SQL
P1=$!
sleep 0.7
# session J: the 5-minute job
echo "select erp.recost_job();" | su postgres -c "psql -X -q -tA -d $DB" > /tmp/erp_rc_j.txt 2>&1
wait $P1
POSTED=$(echo "select count(*) from erp.documents where tenant_id = '$T' and state = 'posted'" | q)
if ! grep -qi "deadlock\|ERROR" /tmp/erp_rc_p.txt /tmp/erp_rc_j.txt && [ "$POSTED" = "5" ] && grep -q '"skipped": 1' /tmp/erp_rc_j.txt; then
  echo "concurrency: recost job against a queued backdated post of the same item -> the job skips the busy item, no deadlock, the post commits"
  rc=0
else
  echo "FAIL concurrency recost ($POSTED posted)"; cat /tmp/erp_rc_p.txt /tmp/erp_rc_j.txt; rc=1
fi
echo "select erp.recost_job(1000, 100000);" | q > /dev/null
INT=$(echo "select jsonb_array_length(erp.stock_integrity('$T'))" | q)
[ "$INT" = "0" ] || { echo "FAIL concurrency recost: integrity $INT"; rc=1; }
rm -f /tmp/erp_rc_p.txt /tmp/erp_rc_j.txt
exit $rc
