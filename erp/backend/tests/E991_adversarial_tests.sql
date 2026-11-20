-- =====================================================================
-- iSmile ERP  -  ADVERSARIAL suite (architect checkpoint F1, independent review). Attacks the E0 tenancy layer:
-- one login in two tenants, owner-role escalation by a delegated member.manage, branch.write outside the own
-- branches, settings read by a role the matrix excludes, idempotency-key replay by another member / login, anonymous
-- logins, search_path / temp-table shadowing of SECURITY DEFINER code, anon / service_role / PUBLIC access, object
-- creation in the ERP schemas, internal SECURITY DEFINER functions, views without security_invoker, re-run of E100
-- keeping later files' grants, onboarding with a pre-bound owner. Findings: docs/erp/REVIEW_F1.md (F1-nn).
-- The concurrent last-owner race (F1-02) needs two sessions: run_erp_tests.sh, "concurrency" step.
-- One transaction, ROLLED BACK. Last line: ALL TESTS PASSED + number of checks.
-- =====================================================================
begin;
\ir _helpers.sql

-- fixtures: tenant A (lower uuid) and B; A1 / A2 / B1; owner, manager (A1), clinic_user (A1), readonly (A1) in A
insert into erp.tenants (tenant_id, code, name) values ('10000000-0000-4000-8000-00000000000a', 'adv_a', 'Adv A'),
                                                      ('20000000-0000-4000-8000-00000000000b', 'adv_b', 'Adv B');
create function t.a() returns uuid language sql immutable as $$ select '10000000-0000-4000-8000-00000000000a'::uuid $$;
create function t.b() returns uuid language sql immutable as $$ select '20000000-0000-4000-8000-00000000000b'::uuid $$;
select t.init(t.a()), t.init(t.b());
select t.branch(t.a(), 'A1', 0), t.branch(t.a(), 'A2', 1), t.branch(t.b(), 'B1', 0);
select t.member(t.a(), 1, 'owner'), t.member(t.a(), 2, 'manager', array[t.br(t.a(), 'A1')]), t.member(t.a(), 3, 'clinic_user', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 4, 'readonly', array[t.br(t.a(), 'A1')]), t.member(t.a(), 5, 'owner'), t.member(t.b(), 11, 'owner');
create function t.mid(p_email text) returns uuid language sql security definer as $$ select member_id from erp.members where email = p_email $$;
create function t.mrow(p_email text) returns erp.members language sql security definer as $$ select m from erp.members m where email = p_email $$;
grant execute on all functions in schema t to authenticated;
grant usage on schema t to anon, service_role;                 -- so the anon / service_role attacks below can call t.fails
grant execute on all functions in schema t to anon, service_role;

-- ---------- F1-01: one login (sub) in two tenants ----------
-- the login of readonly user4 (tenant A) gets an owner invitation of tenant B under a second email (e.g. after an
-- email change in Supabase). Before the fix it bound, and then held B's owner capabilities inside tenant A.
insert into erp.members (tenant_id, email, role, all_branches) values (t.b(), 'user4.second@erp.test', 'owner', true);
set local role authenticated;
select t.login(t.sub(4), 'user4.second@erp.test');
select t.keep(erp_api.member_bind(gen_random_uuid()));
select t.ok(not (t.j() ->> 'bound')::boolean and t.j() ->> 'reason' = 'login_in_other_organisation' and (t.mrow('user4.second@erp.test')).auth_user_id is null,
            'F1-01 a login bound in tenant A does not bind an invitation of tenant B');
select t.ok(erp.my_tenants() = array[t.a()] and not erp.can('member.manage') and (select count(*) from erp.members) = 1,
            'F1-01 ...so it keeps readonly rights: one tenant, no member.manage, only its own member row');
select t.fails($$select erp_api.member_invite('{"email": "evil@erp.test", "role": "owner", "all_branches": true}', gen_random_uuid())$$, 'ERP_FORBIDDEN',
               'F1-01 ...and cannot invite in tenant A');
reset role;
select t.fails(format($$update erp.members set auth_user_id = '%s' where email = 'user4.second@erp.test'$$, t.sub(4)), '',
               'F1-01 the database refuses a second member row for the same login (members_auth_uq)');
select t.ok(exists (select 1 from pg_catalog.pg_indexes where schemaname = 'erp' and indexname = 'members_auth_uq' and indexdef like 'CREATE UNIQUE INDEX%(auth_user_id)%'),
            'F1-01 unique index on members (auth_user_id)');
-- an inactive row keeps its login too (reset_binding frees it)
update erp.members set active = false where email = 'user4@erp.test';
set local role authenticated;
select t.login(t.sub(4), 'user4.second@erp.test');
select t.ok((erp_api.member_bind(gen_random_uuid())) ->> 'reason' = 'login_in_other_organisation', 'F1-01 a deactivated but still linked row also blocks a second binding');
reset role;
update erp.members set active = true where email = 'user4@erp.test';
delete from erp.members where email = 'user4.second@erp.test';

-- ---------- F1-03: a delegated member.manage never reaches the owner role ----------
insert into erp.role_caps (tenant_id, role, capability) values (t.a(), 'manager', 'member.manage');
set local role authenticated;
select t.as(2);
select t.fails($$select erp_api.member_invite('{"email": "boss2@erp.test", "role": "owner"}', gen_random_uuid())$$, 'ERP_FORBIDDEN',
               'F1-03 manager with member.manage cannot invite an owner');
select t.fails(format($$select erp_api.member_update('%s', '{"role": "owner"}', gen_random_uuid())$$, t.mid('user2@erp.test')), 'ERP_FORBIDDEN',
               'F1-03 ...cannot make itself owner');
select t.fails(format($$select erp_api.member_update('%s', '{"role": "owner"}', gen_random_uuid())$$, t.mid('user4@erp.test')), 'ERP_FORBIDDEN',
               'F1-03 ...cannot make another member owner');
select t.fails(format($$select erp_api.member_update('%s', '{"active": false}', gen_random_uuid())$$, t.mid('user1@erp.test')), 'ERP_FORBIDDEN',
               'F1-03 ...cannot deactivate an owner (even with a second owner present)');
select t.fails(format($$select erp_api.member_update('%s', '{"role": "readonly", "all_branches": true}', gen_random_uuid())$$, t.mid('user5@erp.test')), 'ERP_FORBIDDEN',
               'F1-03 ...cannot demote an owner');
select t.fails(format($$select erp_api.member_reset_binding('%s', gen_random_uuid())$$, t.mid('user1@erp.test')), 'ERP_FORBIDDEN',
               'F1-03 ...cannot unlink an owner''s login');
select t.ok((erp_api.member_invite('{"email": "helper@erp.test", "role": "readonly", "branch_ids": []}'::jsonb
               || jsonb_build_object('branch_ids', jsonb_build_array(t.br(t.a(), 'A1'))), gen_random_uuid())) ->> 'status' = 'pending',
            'F1-03 ...but still manages non-owner members (the delegation works)');
select t.ok((t.mrow('user1@erp.test')).role = 'owner' and (t.mrow('user5@erp.test')).role = 'owner' and (t.mrow('user2@erp.test')).role = 'manager',
            'F1-03 owners unchanged, manager not promoted');
select t.as(1);
select t.ok((erp_api.member_update(t.mid('user5@erp.test'), '{"display_name": "Second owner"}', gen_random_uuid())) ->> 'display_name' = 'Second owner',
            'F1-03 an owner still changes another owner');
reset role;
delete from erp.role_caps where tenant_id = t.a() and role = 'manager' and capability = 'member.manage';

-- ---------- F1-05: branch.write delegated to a manager stays inside its branches ----------
insert into erp.role_caps (tenant_id, role, capability) values (t.a(), 'manager', 'branch.write');
set local role authenticated;
select t.as(2);
select t.fails(format($$select erp_api.branch_save('{"branch_id": "%s", "name": "taken over"}', gen_random_uuid())$$, t.br(t.a(), 'A2')), 'ERP_FORBIDDEN',
               'F1-05 manager (A1) with branch.write cannot change branch A2');
select t.ok((erp_api.branch_save(jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'name', 'A1 renamed'), gen_random_uuid())) ->> 'name' = 'A1 renamed',
            'F1-05 ...but changes its own branch A1');
reset role;
delete from erp.role_caps where tenant_id = t.a() and role = 'manager' and capability = 'branch.write';

-- ---------- F1-06: tenant_settings table follows the matrix (tenant.settings.read) ----------
set local role authenticated;
select t.as(3);
select t.ok((select count(*) from erp.tenant_settings) = 0, 'F1-06 clinic_user reads no settings row (matrix: -)');
select t.ok((erp_api.whoami()) #>> '{settings,time_zone}' = 'Europe/Athens', 'F1-06 ...whoami still gives it the settings subset it needs');
select t.as(2);
select t.ok((select count(*) from erp.tenant_settings) = 1, 'F1-06 manager reads its tenant settings row');

-- ---------- F1-08: idempotency keys replay only for the member / login that used them ----------
select t.as(1);
select erp_api.branch_save('{"code": "A7", "name": "Seven"}', '00000000-0000-4000-d000-000000000001');
select t.as(5);
select t.fails($$select erp_api.branch_save('{"code": "A7", "name": "Seven"}', '00000000-0000-4000-d000-000000000001')$$, 'ERP_IDEMPOTENT_MISMATCH',
               'F1-08 another owner replaying the same key + payload gets ERP_IDEMPOTENT_MISMATCH, not the stored reply');
select t.as(1);
select t.ok((erp_api.member_invite('{"email": "bindme@erp.test", "role": "readonly", "all_branches": true}', gen_random_uuid())) ->> 'status' = 'pending', 'fixture: invitation bindme');
select t.login(t.sub(60), 'bindme@erp.test');
select t.ok((erp_api.member_bind('00000000-0000-4000-d000-000000000002')) ->> 'bound' = 'true', 'fixture: first login binds bindme');
select t.login(t.sub(61), 'bindme@erp.test');
select t.fails($$select erp_api.member_bind('00000000-0000-4000-d000-000000000002')$$, 'ERP_IDEMPOTENT_MISMATCH',
               'F1-08 a second login reusing the first login''s bind key gets no stored "bound" reply');
select t.fails($$select erp_api.whoami()$$, 'ERP_AUTH', 'F1-08 ...and no access');

-- ---------- F1-09: anonymous Supabase logins never bind ----------
reset role;
insert into erp.members (tenant_id, email, role, all_branches) values (t.a(), 'anon.person@erp.test', 'readonly', true);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', t.sub(62), 'email', 'anon.person@erp.test', 'role', 'authenticated', 'is_anonymous', true)::text, true);
select t.fails($$select erp_api.member_bind(gen_random_uuid())$$, 'ERP_AUTH', 'F1-09 an anonymous login (is_anonymous) cannot bind an invitation');
select t.ok((t.mrow('anon.person@erp.test')).auth_user_id is null, 'F1-09 ...the invitation stays pending');

-- ---------- search_path / temp-table shadowing of SECURITY DEFINER code ----------
select t.as(4);
create temp table members (tenant_id uuid, member_id uuid, email text, role text, auth_user_id uuid, active boolean, branch_ids uuid[], all_branches boolean);
insert into pg_temp.members values (t.b(), gen_random_uuid(), 'user4@erp.test', 'owner', t.sub(4), true, '{}', true);
create temp table branches (tenant_id uuid, branch_id uuid, code text, name text, active boolean);
insert into pg_temp.branches values (t.a(), gen_random_uuid(), 'ZZ', 'shadow', true);
create temp table role_caps (tenant_id uuid, role text, capability text, allowed boolean);
insert into pg_temp.role_caps values (t.a(), 'readonly', 'member.manage', true);
set local search_path = pg_temp, erp, erp_api, public;
select t.ok((erp_api.whoami()) ->> 'role' = 'readonly' and (erp_api.whoami()) #>> '{tenant,code}' = 'adv_a' and not erp.can('member.manage'),
            'temp tables named members / role_caps in pg_temp + hostile search_path: identity and caps unchanged');
select t.ok(not ((erp_api.branch_list()) :: text like '%shadow%'), 'temp table named branches is not read by branch_list');
select t.fails($$select erp_api.member_invite('{"email": "shadow@erp.test", "role": "readonly", "all_branches": true}', gen_random_uuid())$$, 'ERP_FORBIDDEN',
               'shadowed role_caps grants nothing (ERP_FORBIDDEN)');
reset search_path;
drop table pg_temp.members, pg_temp.branches, pg_temp.role_caps;
reset role;
select t.ok(not exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                         where n.nspname in ('erp', 'erp_api') and not coalesce('search_path=""' = any (p.proconfig), false)),
            'every function in erp and erp_api pins search_path = '''' ' ||
            coalesce((select string_agg(p.oid::regprocedure::text, ', ') from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                       where n.nspname in ('erp', 'erp_api') and not coalesce('search_path=""' = any (p.proconfig), false)), ''));
select t.ok(not exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                         where n.nspname in ('erp', 'erp_api') and p.prosecdef and pg_catalog.pg_get_userbyid(p.proowner) <> (select pg_catalog.pg_get_userbyid(nspowner) from pg_catalog.pg_namespace where nspname = 'erp')),
            'every SECURITY DEFINER function is owned by the schema owner (no function owned by an API role)');

-- ---------- anon, service_role, PUBLIC ----------
select t.ok(not has_schema_privilege('anon', 'erp', 'usage') and not has_schema_privilege('anon', 'erp_api', 'usage')
            and not has_schema_privilege('service_role', 'erp_api', 'usage') and not has_schema_privilege('public', 'erp', 'usage'),
            'anon / service_role / PUBLIC: no usage on erp_api (anon, PUBLIC also not on erp)');
set local role anon;
select set_config('request.jwt.claims', json_build_object('sub', t.sub(1), 'email', 'user1@erp.test', 'role', 'anon')::text, true);
select t.fails($$select erp_api.whoami()$$, '', 'anon (even with an owner''s claims) cannot call erp_api');
select t.fails($$select count(*) from erp.members$$, '', 'anon cannot read erp tables');
reset role;
set local role service_role;
select t.fails($$select count(*) from erp.members$$, '', 'service_role (BYPASSRLS) has no grant on erp tables');
select t.fails($$select erp_api.whoami()$$, '', 'service_role cannot call erp_api');
reset role;

-- ---------- authenticated: no DDL in the ERP schemas, no internal SECURITY DEFINER function ----------
set local role authenticated;
select t.as(1);
select t.fails($$create table erp.evil (tenant_id uuid)$$, '', 'authenticated cannot create a table in erp');
select t.fails($$create function erp_api.evil() returns int language sql as 'select 1'$$, '', 'authenticated cannot create a function in erp_api');
select t.fails($$create view erp.evil_v as select 1$$, '', 'authenticated cannot create a view in erp');
select t.fails($$select erp.tenant_onboard('evil', 'Evil', 'evil@erp.test')$$, '', 'tenant_onboard not callable');
select t.fails(format($$select erp.audit('%s', 'x', 'x', 'x')$$, t.b()), '', 'erp.audit (writes another tenant''s log) not callable');
select t.fails(format($$select erp.alert_raise('%s', 'x', 'info', 'x')$$, t.b()), '', 'erp.alert_raise not callable');
select t.fails(format($$select erp.role_caps_sync('%s')$$, t.a()), '', 'erp.role_caps_sync not callable');
select t.fails(format($$select erp.members_lock('%s')$$, t.a()), '', 'erp.members_lock not callable');
select t.fails($$select erp.lock_down()$$, '', 'erp.lock_down not callable');
select t.fails(format($$select erp.idem_end('%s', gen_random_uuid(), 'x', '{}', '{}')$$, t.b()), '', 'erp.idem_end not callable');
select t.fails($$select nextval('erp.audit_log_audit_id_seq')$$, '', 'no sequence usage');
select t.fails(format($$insert into erp.audit_log (tenant_id, actor, action) values ('%s', 'x', 'x')$$, t.a()), '', 'no direct insert into audit_log');
select t.fails(format($$update erp.members set role = 'owner' where email = 'user4@erp.test'$$), '', 'no direct update of members (self-promotion)');
select t.fails($$delete from erp.branches$$, '', 'no direct delete of branches');
select t.fails($$select count(*) from erp.idempotency_keys$$, '', 'idempotency_keys: no select grant');
select t.ok(not erp.can('branch.read', t.br(t.b(), 'B1')) and not erp.can('member.read', t.br(t.b(), 'B1')), 'can() with a branch of tenant B is false for owner A');
reset role;
select t.ok(not exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                         where n.nspname = 'erp' and c.relkind in ('r', 'p', 'v', 'm', 'S')
                           and (has_table_privilege('authenticated', c.oid, 'REFERENCES') or has_table_privilege('authenticated', c.oid, 'TRIGGER')
                                or (c.relkind = 'S' and has_sequence_privilege('authenticated', c.oid, 'USAGE')))),
            'authenticated: no REFERENCES / TRIGGER on erp tables, no sequence usage');
-- views run as their owner (who bypasses RLS) unless security_invoker: every view in the ERP schemas must set it
select t.ok(not exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                         where n.nspname in ('erp', 'erp_api') and c.relkind in ('v', 'm')
                           and not coalesce('security_invoker=true' = any (c.reloptions), false)
                           and (has_table_privilege('authenticated', c.oid, 'SELECT') or has_table_privilege('anon', c.oid, 'SELECT'))),
            'no view readable by an API role without security_invoker (guard for later files)');

-- ---------- F1-07: re-running E100 keeps a later file's SELECT grant and still removes every write ----------
create table erp.zz_later (tenant_id uuid not null references erp.tenants (tenant_id), id int, primary key (tenant_id, id));
grant select, insert on erp.zz_later to authenticated;
\ir ../E100_tenancy.sql
select t.ok(has_table_privilege('authenticated', 'erp.zz_later', 'SELECT') and not has_table_privilege('authenticated', 'erp.zz_later', 'INSERT'),
            'F1-07 E100 re-run: later table keeps SELECT, loses INSERT');
select t.ok((select relrowsecurity and relforcerowsecurity from pg_catalog.pg_class where oid = 'erp.zz_later'::regclass), 'F1-07 ...and gets RLS enabled + forced');
select t.ok(not has_table_privilege('authenticated', 'erp.idempotency_keys', 'SELECT'), 'F1-07 ...idempotency_keys stays closed');
drop table erp.zz_later;

-- ---------- F1-04: onboarding with the owner's existing login pre-binds the owner ----------
select t.keep(erp.tenant_onboard('advc', 'Adv C', 'boss@advc.test', t.sub(70)));
select t.ok((t.j() ->> 'owner_bound')::boolean and (t.j() ->> 'owner_invited')::boolean and (t.mrow('boss@advc.test')).auth_user_id = t.sub(70),
            'F1-04 onboard with the login id: owner invited and bound at once');
select t.ok((erp.tenant_onboard('advc', 'Adv C', 'boss@advc.test', t.sub(70))) ->> 'owner_bound' = 'false', 'F1-04 re-run: nothing changes');
select t.fails(format($$select erp.tenant_onboard('advd', 'Adv D', 'boss@advd.test', '%s')$$, t.sub(1)), 'ERP_VALIDATION',
               'F1-04 a login already bound to another member cannot be pre-bound');
select t.ok((erp.tenant_onboard('adve', 'Adv E', 'boss@adve.test')) ->> 'owner_bound' = 'false' and (t.mrow('boss@adve.test')).auth_user_id is null,
            'F1-04 without the id: pending owner invitation as before');
set local role authenticated;
select t.login(t.sub(70), 'boss@advc.test');
select t.ok((erp_api.whoami()) ->> 'role' = 'owner', 'F1-04 the pre-bound owner has access without member_bind');
select t.login(t.sub(71), 'boss@advc.test');
select t.ok((erp_api.member_bind(gen_random_uuid())) ->> 'reason' = 'bound_to_other_login', 'F1-04 another login with the owner email cannot claim it');
reset role;

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
