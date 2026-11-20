#!/bin/bash
# iSmile ERP: F2-03 (review F2). The owner moves the lock date WHILE a document dated inside the newly locked period
# is posted. post_document reads the lock date FOR SHARE, so the post waits for the settings change and then refuses
# (ERP_LOCKED_PERIOD). Before F2 it read the old date and posted into the locked period. Called by run_erp_tests.sh
# (mode A) with the database name; commits a small fixture (tenant code 'lockr', TEST type ZLK). Exit 1 on failure.
DB="$1"
q() { su postgres -c "psql -X -q -tA -v ON_ERROR_STOP=1 -d $DB" ; }
T=50000000-0000-4000-8000-0000000000f3
SUB=00000000-0000-4000-e000-0000000000f3
CL="'{\"sub\": \"$SUB\", \"email\": \"lockr@erp.test\", \"role\": \"authenticated\"}'"
DOC=$(q <<SQL | tail -1
insert into erp.tenants (tenant_id, code, name) values ('$T', 'lockr', 'Lock date race') on conflict do nothing;
select erp.tenant_init('$T');
insert into erp.branches (tenant_id, code, name) values ('$T', 'L1', 'L one') on conflict do nothing;
insert into erp.members (tenant_id, email, role, all_branches, auth_user_id, bound_at) values ('$T', 'lockr@erp.test', 'owner', true, '$SUB', now()) on conflict do nothing;
insert into erp.doc_types (doc_type, name, area, cap_prefix, sort, enabled, price_kind) values ('ZLK', 'Lock race', 'warehouse', 'zlk', 996, true, 'cost') on conflict do nothing;
insert into erp.doc_transitions (doc_type, from_state, to_state, cap, action, label) values ('ZLK', 'draft', 'posted', 'create', 'post', 'x') on conflict do nothing;
insert into erp.capabilities (capability, area) values ('doc.zlk.read', 'test'), ('doc.zlk.create', 'test') on conflict do nothing;
insert into erp.role_caps (tenant_id, role, capability) values ('$T', 'owner', 'doc.zlk.read'), ('$T', 'owner', 'doc.zlk.create') on conflict do nothing;
insert into erp.series (tenant_id, branch_id, doc_type, code) select '$T', branch_id, 'ZLK', 'ZLK' from erp.branches where tenant_id = '$T' on conflict do nothing;
update erp.tenant_settings set lock_date = null where tenant_id = '$T';
begin;
set local role authenticated;
select set_config('request.jwt.claims', $CL, true) is null;
select erp_api.doc_save_draft('ZLK', jsonb_build_object('branch_id', (select branch_id from erp.branches where tenant_id = '$T' and code = 'L1'),
       'doc_date', erp_api.whoami() ->> 'today', 'lines', jsonb_build_array(jsonb_build_object('description', 'x', 'qty', 1, 'unit_price', 1))), gen_random_uuid()) ->> 'document_id';
commit;
SQL
)
# session 1: the owner sets the lock date to today (row locked, commits after 2 s)
su postgres -c "psql -X -q -tA -d $DB" > /tmp/erp_lock_1.txt 2>&1 <<SQL &
begin;
update erp.tenant_settings set lock_date = (select doc_date from erp.documents where document_id = '$DOC') where tenant_id = '$T';
select pg_sleep(2);
commit;
SQL
P1=$!
sleep 0.7
# session 2: posts the document dated today while the change is in flight
su postgres -c "psql -X -q -tA -d $DB" > /tmp/erp_lock_2.txt 2>&1 <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claims', $CL, true) is null;
select erp_api.doc_set_state('$DOC', 'posted', '{}', gen_random_uuid()) #>> '{document,state}';
commit;
SQL
wait $P1
ST=$(echo "select state from erp.documents where document_id = '$DOC'" | q)
if [ "$ST" = "draft" ] && grep -q "ERP_LOCKED_PERIOD" /tmp/erp_lock_2.txt; then
  echo "concurrency: lock date moved while a post of that date runs -> the post waits and is refused (ERP_LOCKED_PERIOD)"; rc=0
else
  echo "FAIL concurrency lock date: document state $ST (posted inside a period locked at the same moment)"; cat /tmp/erp_lock_1.txt /tmp/erp_lock_2.txt; rc=1
fi
echo "update erp.tenant_settings set lock_date = null where tenant_id = '$T'; delete from erp.documents where document_id = '$DOC' and state = 'draft';" | q >/dev/null 2>&1
rm -f /tmp/erp_lock_1.txt /tmp/erp_lock_2.txt
exit $rc
