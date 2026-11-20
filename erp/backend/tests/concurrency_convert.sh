#!/bin/bash
# iSmile ERP: two sessions convert the SAME source at the same moment (T44; 03 golden V8). Called by run_erp_tests.sh
# (mode A) with the database name. doc_convert locks the sources first, so the second session waits, then finds
# nothing left: exactly ONE target draft, the second call gets ERP_CONVERT_NOTHING_LEFT. Commits a small fixture
# (tenant code 'convc', TEST types ZCS -> ZCT) into the scratch database. Exit 1 on failure.
DB="$1"
q() { su postgres -c "psql -X -q -tA -v ON_ERROR_STOP=1 -d $DB" ; }
T=50000000-0000-4000-8000-0000000000ac
SUB=00000000-0000-4000-e000-0000000000d1
CL="'{\"sub\": \"$SUB\", \"email\": \"convc@erp.test\", \"role\": \"authenticated\"}'"
SRC=$(q <<SQL | tail -1
insert into erp.tenants (tenant_id, code, name) values ('$T', 'convc', 'Conversion race') on conflict do nothing;
select erp.tenant_init('$T');
insert into erp.branches (tenant_id, code, name) values ('$T', 'C1', 'C one') on conflict do nothing;
insert into erp.members (tenant_id, email, role, all_branches, auth_user_id, bound_at) values ('$T', 'convc@erp.test', 'owner', true, '$SUB', now()) on conflict do nothing;
insert into erp.doc_types (doc_type, name, area, cap_prefix, sort, enabled, price_kind) values ('ZCS', 'Race source', 'sales', 'zcr', 995, true, 'sale'),
  ('ZCT', 'Race target', 'sales', 'zcr', 994, true, 'sale') on conflict do nothing;
insert into erp.doc_transitions (doc_type, from_state, to_state, cap, action, label) values ('ZCS', 'draft', 'posted', 'create', 'post', 'x') on conflict do nothing;
insert into erp.doc_conversions (source_type, target_type, kind) values ('ZCS', 'ZCT', 'bill') on conflict do nothing;
insert into erp.capabilities (capability, area) values ('doc.zcr.read', 'test'), ('doc.zcr.create', 'test') on conflict do nothing;
insert into erp.role_caps (tenant_id, role, capability) values ('$T', 'owner', 'doc.zcr.read'), ('$T', 'owner', 'doc.zcr.create') on conflict do nothing;
insert into erp.series (tenant_id, branch_id, doc_type, code) select '$T', branch_id, 'ZCS', 'ZCS' from erp.branches where tenant_id = '$T' on conflict do nothing;
insert into erp.items (tenant_id, code, name, base_unit_id) select '$T', 'CI', 'item', unit_id from erp.units where tenant_id = '$T' and code = 'PCS' on conflict do nothing;
begin;
set local role authenticated;
select set_config('request.jwt.claims', $CL, true) is null;
select erp_api.doc_set_state((erp_api.doc_save_draft('ZCS', jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'C1'),
       'lines', jsonb_build_array(jsonb_build_object('item_id', (select item_id from erp.items where code = 'CI'), 'qty', 10, 'unit_price', 1))), gen_random_uuid())
       ->> 'document_id')::uuid, 'posted', '{}', gen_random_uuid()) #>> '{document,document_id}';
commit;
SQL
)
session() { # $1 = sleep before commit
  su postgres -c "psql -X -q -tA -d $DB" <<SQL 2>&1
begin;
set local role authenticated;
select set_config('request.jwt.claims', $CL, true) is null;
select erp_api.doc_convert(array['$SRC'::uuid], 'ZCT', null, gen_random_uuid()) ->> 'state';
select pg_sleep($1);
commit;
SQL
}
session 2 > /tmp/erp_conv_1.txt &
P1=$!
sleep 0.7
session 0 > /tmp/erp_conv_2.txt
wait $P1
N=$(echo "select count(*) from erp.documents where tenant_id = '$T' and doc_type = 'ZCT'" | q)
if [ "$N" = "1" ] && grep -q "ERP_CONVERT_NOTHING_LEFT" /tmp/erp_conv_2.txt; then
  echo "concurrency: two sessions convert the same source at once -> one target draft, the second gets ERP_CONVERT_NOTHING_LEFT"
  rc=0
else
  echo "FAIL concurrency convert: $N target drafts"; cat /tmp/erp_conv_1.txt /tmp/erp_conv_2.txt; rc=1
fi
rm -f /tmp/erp_conv_1.txt /tmp/erp_conv_2.txt
exit $rc
