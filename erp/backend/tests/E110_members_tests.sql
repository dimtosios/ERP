-- =====================================================================
-- iSmile ERP  -  tests for E110_members.sql (T03): first-login binding (also conflicts), invitations, member
-- changes (last-owner guard, branch scoping, plan hook), reset of the login link, member list paging / filters,
-- tenant onboarding (tenant #1 and a new tenant, re-run), idempotency, audit. One transaction, ROLLED BACK.
-- Last line: ALL TESTS PASSED + number of checks.
-- =====================================================================
begin;
\ir _helpers.sql

create table t.ids (a uuid, b uuid);
insert into t.ids select t.tenant('ma'), t.tenant('mb');
create function t.a() returns uuid language sql security definer as $$ select a from t.ids $$;
create function t.b() returns uuid language sql security definer as $$ select b from t.ids $$;
select t.init(t.a()), t.init(t.b());
select t.branch(t.a(), 'A1', 0), t.branch(t.a(), 'A2', 1), t.branch(t.b(), 'B1', 0);
select t.member(t.a(), 1, 'owner'), t.member(t.a(), 2, 'manager', array[t.br(t.a(), 'A1')]), t.member(t.a(), 3, 'warehouse', array[t.br(t.a(), 'A1')]),
       t.member(t.b(), 11, 'owner');
create function t.mid(p_email text) returns uuid language sql security definer as $$ select member_id from erp.members where email = p_email $$;
create function t.mrow(p_email text) returns erp.members language sql security definer as $$ select m from erp.members m where email = p_email $$;
create function t.alerts(p_kind text) returns bigint language sql security definer as $$ select count(*) from erp.alerts where kind = p_kind and resolved_at is null $$;
grant execute on all functions in schema t to authenticated;
set local role authenticated;

-- ---------- invitations ----------
select t.as(1);
select t.keep(erp_api.member_invite(jsonb_build_object('email', ' New.Person@Clinic.TEST ', 'role', 'warehouse', 'branch_ids', jsonb_build_array(t.br(t.a(), 'A2')),
                                                       'display_name', 'New Person'), '00000000-0000-4000-c000-000000000001'));
select t.ok(t.j() ->> 'email' = 'new.person@clinic.test' and t.j() ->> 'status' = 'pending' and t.j() ->> 'role' = 'warehouse'
            and t.j() -> 'branch_ids' = jsonb_build_array(t.br(t.a(), 'A2')) and t.j() ->> 'invited_by' = t.mid('user1@erp.test')::text and not (t.j() ? 'auth_user_id'),
            'owner invites: email normalised, pending, branches, invited_by; no auth id in the reply');
select t.ok((erp_api.member_invite(jsonb_build_object('email', ' New.Person@Clinic.TEST ', 'role', 'warehouse', 'branch_ids', jsonb_build_array(t.br(t.a(), 'A2')),
                                                       'display_name', 'New Person'), '00000000-0000-4000-c000-000000000001')) ->> 'member_id' = t.j() ->> 'member_id'
            and t.count($$select 1 from erp.members where email = 'new.person@clinic.test'$$) = 1, 'same idempotency key: same reply, one row');
select t.ok((select string_agg(e ->> 'code' || ':' || (e ->> 'field'), ',' order by e ->> 'field') from jsonb_array_elements(
             t.problems($$select erp_api.member_invite('{"email": "not-an-email", "role": "boss", "colour": "red"}', gen_random_uuid())$$)) e)
            = 'required:branch_ids,not_editable:colour,invalid:email,invalid:role', 'invite validation: every problem at once');
select t.ok(t.problems($$select erp_api.member_invite('{"email": "x1@erp.test", "role": "readonly"}', gen_random_uuid())$$) -> 0 ->> 'field' = 'branch_ids',
            'a non-owner without branches and without all_branches is refused');
select t.ok(t.problems($$select erp_api.member_invite('{"email": "USER2@erp.test", "role": "readonly", "all_branches": true}', gen_random_uuid())$$) -> 0 ->> 'code' = 'email_taken',
            'email already a member of this tenant: email_taken');
select t.ok(t.problems($$select erp_api.member_invite('{"email": "user11@erp.test", "role": "readonly", "all_branches": true}', gen_random_uuid())$$) -> 0 ->> 'message'
            = 'This email is already a member or invited, and cannot be invited again.', 'email of ANOTHER tenant: same neutral message (v1 one email = one tenant)');
select t.fails(format($$select erp_api.member_invite('{"email": "x2@erp.test", "role": "readonly", "branch_ids": ["%s"]}', gen_random_uuid())$$, t.br(t.b(), 'B1')),
               'ERP_TENANT', 'invite with a branch of tenant B: ERP_TENANT');
reset role;
insert into erp.roles (role, sort, facade_only) values ('card_test', 900, true);
set local role authenticated;
select t.ok(t.problems($$select erp_api.member_invite('{"email": "x3@erp.test", "role": "card_test", "all_branches": true}', gen_random_uuid())$$) -> 0 ->> 'field' = 'role',
            'a facade-only role cannot be given in the admin screen');
select t.keep(erp_api.member_invite('{"email": "acc@erp.test", "role": "accounting", "all_branches": true}', gen_random_uuid()));
select t.ok((t.j() ->> 'all_branches')::boolean and t.j() -> 'branch_ids' = '[]'::jsonb, 'accounting invited with all branches');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'member.invite' and row_id = '$$ || (t.j() ->> 'member_id') || $$' and new_row ->> 'email' = 'acc@erp.test'$$) = 1,
            'invite is audited');
reset role;
select t.ok((select used from erp.tenant_usage where tenant_id = t.a() and kind = 'members.invited') = 2, 'usage counter: 2 invitations');
update erp.tenants set limits = '{"users": 5}' where tenant_id = t.a();
set local role authenticated;
select t.fails($$select erp_api.member_invite('{"email": "x4@erp.test", "role": "readonly", "all_branches": true}', gen_random_uuid())$$, 'ERP_LIMIT', 'plan hook: users limit (5 active) -> ERP_LIMIT');
reset role;
update erp.tenants set limits = '{}' where tenant_id = t.a();
set local role authenticated;
select t.as(2);
select t.fails($$select erp_api.member_invite('{"email": "x5@erp.test", "role": "readonly", "all_branches": true}', gen_random_uuid())$$, 'ERP_FORBIDDEN', 'manager cannot invite');

-- ---------- first-login binding ----------
select t.logout();
select t.fails($$select erp_api.member_bind(gen_random_uuid())$$, 'ERP_AUTH', 'bind without login: ERP_AUTH');
select t.login(t.sub(40), 'NEW.person@clinic.test');
select t.fails($$select erp_api.whoami()$$, 'ERP_AUTH', 'before binding the invited person has no access');
select t.keep(erp_api.member_bind('00000000-0000-4000-c000-000000000002'));
select t.ok((t.j() ->> 'bound')::boolean and t.j() ->> 'tenant_id' = t.a()::text and not (t.j() ->> 'already')::boolean, 'first sign-in binds the invitation (email case-insensitive)');
select t.ok((erp_api.whoami()) ->> 'role' = 'warehouse' and (erp_api.whoami()) #>> '{branches,0,code}' = 'A2', 'after binding: whoami works with role and branch');
select t.ok((erp_api.member_bind('00000000-0000-4000-c000-000000000002')) = t.j(), 'same key: stored reply');
select t.ok((erp_api.member_bind(gen_random_uuid())) ->> 'already' = 'true', 'a later sign-in: already bound, nothing changes');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'member.bind' and actor = 'new.person@clinic.test'$$) = 1, 'binding is audited once');
select t.login(t.sub(41), 'new.person@clinic.test');
select t.keep(erp_api.member_bind(gen_random_uuid()));
select t.ok(not (t.j() ->> 'bound')::boolean and t.j() ->> 'reason' = 'bound_to_other_login' and (t.mrow('new.person@clinic.test')).auth_user_id = t.sub(40),
            'same email, OTHER login (sub): not re-bound');
select t.ok(t.alerts('member_bind_conflict') = 1, '...and the owner gets one alert');
select erp_api.member_bind(gen_random_uuid());
select t.ok(t.alerts('member_bind_conflict') = 1, '...only one, also when it happens again (dedupe)');
select t.fails($$select erp_api.whoami()$$, 'ERP_AUTH', 'the other login still has no access');
select t.login(t.sub(42), 'nobody@erp.test');
select t.ok((erp_api.member_bind(gen_random_uuid())) = '{"bound": false, "reason": "no_invitation"}', 'no invitation: bound false, nothing told');
select t.as(1);
select t.keep(erp_api.member_invite('{"email": "late@erp.test", "role": "readonly", "all_branches": true}', gen_random_uuid()));
select erp_api.member_update((t.j() ->> 'member_id')::uuid, '{"active": false}', gen_random_uuid());
select t.login(t.sub(43), 'late@erp.test');
select t.ok((erp_api.member_bind(gen_random_uuid())) ->> 'reason' = 'no_invitation', 'a deactivated invitation does not bind');

-- ---------- member_update ----------
select t.as(1);
select t.keep(erp_api.member_update(t.mid('user2@erp.test'), jsonb_build_object('role', 'accounting', 'branch_ids', jsonb_build_array(t.br(t.a(), 'A1'), t.br(t.a(), 'A2')),
                                                                                'display_name', 'Maria'), gen_random_uuid()));
select t.ok(t.j() ->> 'role' = 'accounting' and jsonb_array_length(t.j() -> 'branch_ids') = 2 and t.j() ->> 'display_name' = 'Maria', 'owner changes role, branches, name');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'member.update' and old_row ->> 'role' = 'manager' and new_row ->> 'role' = 'accounting'
                       and not (new_row ? 'email')$$) = 1, 'update audited with changed keys only');
select t.ok(t.problems(format($$select erp_api.member_update('%s', '{"email": "x@erp.test"}', gen_random_uuid())$$, t.mid('user2@erp.test'))) -> 0 ->> 'code' = 'not_editable',
            'the email cannot be changed');
select t.ok(t.problems(format($$select erp_api.member_update('%s', '{"role": "manager", "all_branches": true}', gen_random_uuid())$$, t.mid('user1@erp.test'))) @> '[{"code": "last_owner", "field": "role"}]',
            'the last active owner cannot be demoted');
select t.ok(t.problems(format($$select erp_api.member_update('%s', '{"active": false}', gen_random_uuid())$$, t.mid('user1@erp.test'))) -> 0 ->> 'code' = 'last_owner',
            '...nor deactivated');
select t.fails(format($$select erp_api.member_update('%s', '{"display_name": "x"}', gen_random_uuid())$$, t.mid('user11@erp.test')), 'ERP_TENANT', 'member of tenant B: ERP_TENANT');
select t.fails($$select erp_api.member_update(gen_random_uuid(), '{"display_name": "x"}', gen_random_uuid())$$, 'ERP_TENANT', 'unknown member id: ERP_TENANT');
select t.fails(format($$select erp_api.member_update('%s', '{"branch_ids": ["%s"]}', gen_random_uuid())$$, t.mid('user3@erp.test'), t.br(t.b(), 'B1')),
               'ERP_TENANT', 'moving a member to a branch of B: ERP_TENANT');
-- a second owner, bound: then the first may step down
select erp_api.member_update(t.mid('user3@erp.test'), '{"role": "owner"}', gen_random_uuid());
select t.ok((erp_api.member_update(t.mid('user1@erp.test'), jsonb_build_object('role', 'manager', 'branch_ids', jsonb_build_array(t.br(t.a(), 'A1'))), gen_random_uuid())) ->> 'role' = 'manager',
            'with another active owner the owner may step down');
select t.ok(jsonb_array_length((erp_api.member_list()) -> 'rows') > 0, 'former owner (now manager) still reads members');
select t.fails(format($$select erp_api.member_update('%s', '{"display_name": "y"}', gen_random_uuid())$$, t.mid('user2@erp.test')), 'ERP_FORBIDDEN', '...but can no longer change them');
select t.as(3);
select erp_api.member_update(t.mid('user1@erp.test'), '{"role": "owner"}', gen_random_uuid());
reset role;
update erp.tenants set limits = '{"users": 1}' where tenant_id = t.a();
set local role authenticated;
select t.as(1);
select t.fails(format($$select erp_api.member_update('%s', '{"active": true}', gen_random_uuid())$$, t.mid('late@erp.test')), 'ERP_LIMIT', 'reactivating over the users limit: ERP_LIMIT');
reset role;
update erp.tenants set limits = '{}' where tenant_id = t.a();
set local role authenticated;

-- ---------- member_reset_binding ----------
select t.as(1);
select t.ok(t.problems(format($$select erp_api.member_reset_binding('%s', gen_random_uuid())$$, t.mid('user1@erp.test'))) -> 0 ->> 'code' = 'self', 'cannot unlink the own login');
select t.keep(erp_api.member_reset_binding(t.mid('new.person@clinic.test'), gen_random_uuid()));
select t.ok(t.j() ->> 'status' = 'pending' and (t.mrow('new.person@clinic.test')).auth_user_id is null and t.alerts('member_bind_conflict') = 0,
            'reset: pending again, the conflict alert is resolved');
select t.fails(format($$select erp_api.member_reset_binding('%s', gen_random_uuid())$$, t.mid('user11@erp.test')), 'ERP_TENANT', 'reset of a member of B: ERP_TENANT');
select t.login(t.sub(41), 'new.person@clinic.test');
select t.ok((erp_api.member_bind(gen_random_uuid())) ->> 'bound' = 'true', 'the new login binds after the reset');
select t.ok((erp_api.whoami()) ->> 'email' = 'new.person@clinic.test', '...and has access');
select t.login(t.sub(40), 'new.person@clinic.test');
select t.fails($$select erp_api.whoami()$$, 'ERP_AUTH', 'the old login no longer has access');

-- ---------- member_list ----------
select t.as(1);
select t.keep(erp_api.member_list());
select t.ok(jsonb_array_length(t.j() -> 'rows') = 6 and t.j() #>> '{rows,0,email}' = 'acc@erp.test' and t.j() -> 'next' = 'null'::jsonb, 'member_list: 6 members of A, by email');
select t.ok(not t.j()::text like '%user11@erp.test%', 'member_list: nothing of tenant B');
select t.keep(erp_api.member_list('{}', null, 4));
select t.ok(jsonb_array_length(t.j() -> 'rows') = 4 and t.j() -> 'next' <> 'null'::jsonb, 'member_list page 1 of 4 + next');
select t.keep(erp_api.member_list('{}', t.j() -> 'next', 4));
select t.ok(jsonb_array_length(t.j() -> 'rows') = 2 and t.j() -> 'next' = 'null'::jsonb, 'member_list page 2 via keyset');
select t.ok(jsonb_array_length((erp_api.member_list('{"q": "maria"}')) -> 'rows') = 1 and jsonb_array_length((erp_api.member_list('{"status": "inactive"}')) -> 'rows') = 1
            and jsonb_array_length((erp_api.member_list('{"role": "owner"}')) -> 'rows') = 2, 'member_list filters: name, status, role');
select t.as(2);
select t.ok(jsonb_array_length((erp_api.member_list()) -> 'rows') = 6, 'accounting (user2 now) reads members');
reset role;
update erp.members set role = 'warehouse', all_branches = false, branch_ids = array[t.br(t.a(), 'A1')] where email = 'user2@erp.test';
set local role authenticated;
select t.as(2);
select t.fails($$select erp_api.member_list()$$, 'ERP_FORBIDDEN', 'warehouse cannot list members');
reset role;

-- ---------- onboarding ----------
select t.keep(erp.tenant_onboard('newco', 'New Co', 'Boss@NewCo.test'));
select t.ok((t.j() ->> 'tenant_created')::boolean and (t.j() ->> 'owner_invited')::boolean, 'onboard: tenant created, owner invited');
select t.ok((select count(*) from erp.role_caps where tenant_id = (t.j() ->> 'tenant_id')::uuid) = (select count(*) from erp.role_cap_defaults)
            and exists (select 1 from erp.tenant_settings where tenant_id = (t.j() ->> 'tenant_id')::uuid)
            and (select role || '/' || all_branches::text from erp.members where email = 'boss@newco.test') = 'owner/true', 'onboard: matrix, settings, pending owner with all branches');
select t.ok((erp.tenant_onboard('newco', 'New Co', 'boss@newco.test')) ->> 'owner_invited' = 'false' and (select count(*) from erp.tenants where code = 'newco') = 1,
            'onboard again: nothing changes');
select t.fails($$select erp.tenant_onboard('other', 'Other', 'user1@erp.test')$$, 'ERP_VALIDATION', 'onboard with an email of another tenant: refused');
select t.fails($$select erp.tenant_onboard('other2', 'Other', 'no-email')$$, 'ERP_VALIDATION', 'onboard with an invalid email: refused');
select t.ok((erp.tenant_onboard('ismile', 'iSmile', 'owner@ismile.test')) ->> 'tenant_id' = '00000000-0000-4000-8000-000000000001', 'tenant #1 onboarding: the seeded iSmile tenant');
select t.ok(exists (select 1 from erp.members where tenant_id = '00000000-0000-4000-8000-000000000001' and email = 'owner@ismile.test' and role = 'owner'),
            '...gets the owner invitation');
set local role authenticated;
select t.login(t.sub(50), 'boss@newco.test');
select t.ok((erp_api.member_bind(gen_random_uuid())) ->> 'bound' = 'true', 'new owner binds');
select t.ok((erp_api.whoami()) ->> 'role' = 'owner' and jsonb_array_length((erp_api.whoami()) -> 'branches') = 0,
            '...and sees an empty tenant (branches typed in the admin screen)');
select t.ok((erp_api.branch_save('{"code": "HQ", "name": "Head office", "establishment_no": 0}', gen_random_uuid())) ->> 'code' = 'HQ', '...creates its first branch');
select t.ok(jsonb_array_length((erp_api.whoami()) -> 'branches') = 1, '...which whoami lists');
select t.fails($$select erp.tenant_onboard('x', 'x', 'x@x.test')$$, '', 'tenant_onboard is not executable by authenticated');
reset role;

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
