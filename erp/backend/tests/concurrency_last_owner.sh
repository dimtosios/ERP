#!/bin/bash
# iSmile ERP: two-session race on the last-owner rule (review F1, finding F1-02). Called by run_erp_tests.sh (mode A,
# after the suites) with the database name. Two bound owners demote each other at the same moment; the tenant must
# keep at least one active, bound owner. Before the fix both calls passed the "another owner exists" check in their
# own snapshot and the tenant ended with none. Commits a small fixture (tenant code 'race') into the scratch database.
# Exit 1 on failure.
DB="$1"
q() { su postgres -c "psql -X -q -tA -v ON_ERROR_STOP=1 -d $DB" ; }
T=30000000-0000-4000-8000-0000000000ac
S1=00000000-0000-4000-e000-000000000001
S2=00000000-0000-4000-e000-000000000002
q <<SQL >/dev/null
insert into erp.tenants (tenant_id, code, name) values ('$T', 'race', 'Race') on conflict do nothing;
select erp.tenant_init('$T');
insert into erp.members (tenant_id, email, role, all_branches, auth_user_id, bound_at) values
  ('$T', 'race1@erp.test', 'owner', true, '$S1', now()), ('$T', 'race2@erp.test', 'owner', true, '$S2', now())
on conflict do nothing;
SQL
M1=$(echo "select member_id from erp.members where email = 'race1@erp.test'" | q)
M2=$(echo "select member_id from erp.members where email = 'race2@erp.test'" | q)
session() { # $1 = caller sub, $2 = caller email, $3 = target member, $4 = sleep before commit
  su postgres -c "psql -X -q -tA -d $DB" <<SQL 2>&1
begin;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', '$1', 'email', '$2', 'role', 'authenticated')::text, true);
select erp_api.member_update('$3', '{"role": "manager", "all_branches": true}', gen_random_uuid()) ->> 'role';
select pg_sleep($4);
commit;
SQL
}
session $S1 race1@erp.test "$M2" 2 > /tmp/erp_race_1.txt &
P1=$!
sleep 0.7
session $S2 race2@erp.test "$M1" 0 > /tmp/erp_race_2.txt
wait $P1
N=$(echo "select count(*) from erp.members where tenant_id = '$T' and role = 'owner' and active and auth_user_id is not null" | q)
if [ "$N" -ge 1 ] && grep -q "ERP_FORBIDDEN\|ERP_VALIDATION" /tmp/erp_race_2.txt; then
  echo "concurrency: two owners demoting each other at once -> $N owner left, second call refused ($(grep -o 'ERP_[A-Z_]*' /tmp/erp_race_2.txt | head -1))"
  rc=0
else
  echo "FAIL concurrency: last-owner race left $N bound owners"; echo "session 1:"; cat /tmp/erp_race_1.txt; echo "session 2:"; cat /tmp/erp_race_2.txt
  rc=1
fi
rm -f /tmp/erp_race_1.txt /tmp/erp_race_2.txt
exit $rc
