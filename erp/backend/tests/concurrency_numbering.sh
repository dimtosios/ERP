#!/bin/bash
# iSmile ERP: numbering under concurrency (T09; 02 "Numbering and series"). Called by run_erp_tests.sh (mode A) with
# the database name. 8 sessions post 15 documents each into ONE series at the same time; every 5th transaction is
# ROLLED BACK after its post. Expected: the committed documents carry exactly the numbers 1..N (no gap, no
# duplicate), the series' next_no = N + 1, no deadlock / error. Commits a small fixture (tenant code 'numc', a TEST
# document type ZTST without stock) into the scratch database. Exit 1 on failure.
DB="$1"
q() { su postgres -c "psql -X -q -tA -v ON_ERROR_STOP=1 -d $DB" ; }
T=40000000-0000-4000-8000-0000000000ac
SUB=00000000-0000-4000-e000-0000000000c1
q <<SQL >/dev/null
insert into erp.tenants (tenant_id, code, name) values ('$T', 'numc', 'Numbering') on conflict do nothing;
select erp.tenant_init('$T');
insert into erp.branches (tenant_id, code, name) values ('$T', 'N1', 'N one') on conflict do nothing;
insert into erp.members (tenant_id, email, role, all_branches, auth_user_id, bound_at) values ('$T', 'numc@erp.test', 'owner', true, '$SUB', now()) on conflict do nothing;
insert into erp.doc_types (doc_type, name, area, cap_prefix, sort, enabled, price_kind) values ('ZTST', 'Numbering test', 'warehouse', 'ztst', 998, true, 'cost') on conflict do nothing;
insert into erp.doc_transitions (doc_type, from_state, to_state, cap, action, label) values ('ZTST', 'draft', 'posted', 'create', 'post', 'doc.action.post') on conflict do nothing;
insert into erp.capabilities (capability, area) values ('doc.ztst.read', 'test'), ('doc.ztst.create', 'test') on conflict do nothing;
insert into erp.role_caps (tenant_id, role, capability) values ('$T', 'owner', 'doc.ztst.read'), ('$T', 'owner', 'doc.ztst.create') on conflict do nothing;
insert into erp.series (tenant_id, branch_id, doc_type, code, gapless) select '$T', branch_id, 'ZTST', 'ZT', true from erp.branches where tenant_id = '$T'
  on conflict do nothing;
insert into erp.items (tenant_id, code, name, base_unit_id) select '$T', 'NI', 'item', unit_id from erp.units where tenant_id = '$T' and code = 'PCS' on conflict do nothing;
SQL
BR=$(echo "select branch_id from erp.branches where tenant_id = '$T'" | q)
IT=$(echo "select item_id from erp.items where tenant_id = '$T'" | q)
DIR=$(mktemp -d /tmp/erp_numc.XXXXXX); chmod a+rwx "$DIR"
for s in 1 2 3 4 5 6 7 8; do
  f="$DIR/s$s.sql"; : > "$f"
  for i in $(seq 1 15); do
    end=commit; [ $((i % 5)) -eq 0 ] && end=rollback
    cat >> "$f" <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "$SUB", "email": "numc@erp.test", "role": "authenticated"}', true) is null;
select erp_api.doc_set_state((erp_api.doc_save_draft('ZTST', '{"branch_id": "$BR", "notes": "s$s-$i-$end", "lines": [{"item_id": "$IT", "qty": 1, "unit_price": 1}]}',
       gen_random_uuid()) ->> 'document_id')::uuid, 'posted', '{}', gen_random_uuid()) #>> '{document,number}';
$end;
SQL
  done
  chmod a+r "$f"
done
for s in 1 2 3 4 5 6 7 8; do su postgres -c "psql -X -q -tA -v ON_ERROR_STOP=1 -d $DB -f $DIR/s$s.sql" > "$DIR/out$s.txt" 2>&1 & done
wait
ERR=$(cat "$DIR"/out*.txt | grep -c "ERROR")
R=$(echo "select count(*) || ',' || coalesce(min(number), 0) || ',' || coalesce(max(number), 0) || ',' || count(distinct number) || ',' ||
             (select next_no from erp.series where tenant_id = '$T' and code = 'ZT') || ',' || count(*) filter (where notes like '%rollback')
        from erp.documents where tenant_id = '$T' and doc_type = 'ZTST' and state = 'posted'" | q)
rm -rf "$DIR"
# 8 sessions x 15 = 120 posts, 24 rolled back -> 96 committed numbers 1..96, next_no 97, none of the rolled back ones
if [ "$ERR" = "0" ] && [ "$R" = "96,1,96,96,97,0" ]; then
  echo "concurrency: 8 sessions x 15 posts into one series (24 rolled back) -> numbers 1..96, no gap, no duplicate, next_no 97"
  exit 0
fi
echo "FAIL concurrency numbering: errors=$ERR result(count,min,max,distinct,next_no,rolled_back_kept)=$R"
exit 1
