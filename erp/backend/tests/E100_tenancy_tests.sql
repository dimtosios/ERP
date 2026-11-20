-- =====================================================================
-- iSmile ERP  -  tests for E100_tenancy.sql (T02): seeds and re-run safety, helpers, whoami, branch_list / branch_save,
-- settings_get / settings_save, audit_list, idempotency, plan hook, RLS reads per role and branch, no direct
-- writes, append-only audit. One transaction, ROLLED BACK. Last line: ALL TESTS PASSED + number of checks.
-- =====================================================================
begin;
\ir _helpers.sql

-- fixtures: tenants A / B, branches, one member per role (numbers = login ids)
select t.keep(jsonb_build_object('a', t.tenant('ta'), 'b', t.tenant('tb')));
create function t.a() returns uuid language sql as $$ select (t.j() ->> 'a')::uuid $$;
create function t.b() returns uuid language sql as $$ select tenant_id from erp.tenants where code = 'tb' $$;
create table t.ids as select (t.j() ->> 'a')::uuid a, (t.j() ->> 'b')::uuid b;
create or replace function t.a() returns uuid language sql security definer as $$ select a from t.ids $$;
create or replace function t.b() returns uuid language sql security definer as $$ select b from t.ids $$;
select t.init(t.a()), t.init(t.b());
select t.branch(t.a(), 'A1', 0), t.branch(t.a(), 'A2', 1), t.branch(t.b(), 'B1', 0);
select t.member(t.a(), 1, 'owner'), t.member(t.a(), 2, 'manager', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 3, 'warehouse', array[t.br(t.a(), 'A1')]), t.member(t.a(), 4, 'accounting', '{}', true),
       t.member(t.a(), 5, 'clinic_user', array[t.br(t.a(), 'A2')]), t.member(t.a(), 6, 'readonly', array[t.br(t.a(), 'A1')]),
       t.member(t.b(), 11, 'owner'), t.member(t.b(), 12, 'manager', array[t.br(t.b(), 'B1')]),
       t.member(t.a(), 7, 'manager', array[t.br(t.a(), 'A1')], false, false);
grant execute on all functions in schema t to authenticated;

-- ---------- seeds, re-run safety ----------
select t.ok((select count(*) = 1 from erp.tenants where tenant_id = '00000000-0000-4000-8000-000000000001' and code = 'ismile'), 'tenant #1 iSmile is seeded');
select t.ok(exists (select 1 from erp.tenant_settings where tenant_id = '00000000-0000-4000-8000-000000000001' and valuation_method = 'average' and negative_stock = 'warn' and time_zone = 'Europe/Athens'),
            'tenant settings default: weighted average, negative stock warn, Europe/Athens (owner decisions)');
select t.ok((select count(*) from erp.roles) = 6 and (select count(*) from erp.roles where facade_only) = 0, 'six roles, no facade-only role seeded (07 section 5)');
select t.ok((select count(*) from erp.role_caps where tenant_id = t.a()) = (select count(*) from erp.role_cap_defaults), 'a tenant gets the full default matrix');
update erp.role_caps set allowed = false where tenant_id = t.a() and role = 'readonly' and capability = 'alert.read';
select t.ok(erp.role_caps_sync() = 0 and not (select allowed from erp.role_caps where tenant_id = t.a() and role = 'readonly' and capability = 'alert.read'),
            're-sync adds nothing and keeps a tenant''s removed capability');
update erp.role_caps set allowed = true where tenant_id = t.a() and role = 'readonly' and capability = 'alert.read';
select t.ok(not exists (select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
                         where n.nspname = 'erp' and c.relkind = 'r' and not (c.relrowsecurity and c.relforcerowsecurity)), 'RLS enabled and forced on every erp table');
select t.ok((select string_agg(capability, ',' order by capability) from erp.role_cap_defaults
              where role = 'owner' and capability in (select capability from erp.capabilities where area = 'platform'))   -- E100 seeds; later files add other areas
            = 'alert.read,alert.resolve,audit.read,branch.read,branch.write,member.manage,member.read,tenant.settings.read,tenant.settings.write',
            'owner default capabilities (02 matrix)');
select t.ok((select string_agg(role, ',' order by role) from erp.role_cap_defaults where capability = 'tenant.settings.write') = 'owner'
            and (select string_agg(role, ',' order by role) from erp.role_cap_defaults where capability = 'member.read') = 'accounting,manager,owner'
            and (select string_agg(role, ',' order by role) from erp.role_cap_defaults where capability = 'audit.read') = 'accounting,manager,owner',
            'settings write owner only; members and audit read: owner, manager, accounting (02 matrix)');

-- ---------- identity helpers ----------
select t.logout();
select t.ok(erp.jwt_sub() is null and erp.my_tenants() = '{}' and not erp.is_owner(), 'no token: no identity, no tenant');
select t.login(t.sub(1), 'USER1@erp.test ');
select t.ok(erp.jwt_email() = 'user1@erp.test' and erp.my_tenants() = array[t.a()] and erp.is_owner(), 'owner: email normalised, own tenant, is_owner');
select t.ok(cardinality(erp.my_branches()) = 2 and erp.can('branch.write') and erp.can('branch.read', t.br(t.a(), 'A2')), 'owner: all branches, branch.write');
select t.ok(not erp.can('branch.read', t.br(t.b(), 'B1')), 'owner of A: can() is false for a branch of tenant B');
select t.as(2);
select t.ok(erp.my_branches() = array[t.br(t.a(), 'A1')] and not erp.is_owner() and erp.can('member.read') and not erp.can('member.manage'), 'manager: own branch only, reads members, cannot manage');
select t.ok(erp.can('alert.read', t.br(t.a(), 'A1')) and not erp.can('alert.read', t.br(t.a(), 'A2')), 'manager: branch scoping in can()');
select t.as(4);
select t.ok(cardinality(erp.my_branches()) = 2 and erp.sees_all_branches() and not erp.is_owner(), 'accounting with all_branches: every branch, not owner');
select t.login(t.sub(1), 'user1@erp.test');
select set_config('request.jwt.claims', '{"sub": "not-a-uuid", "email": "user1@erp.test"}', true);
select t.ok(erp.jwt_sub() is null and erp.my_tenants() = '{}', 'a malformed sub is no identity (email alone never grants access)');
select t.login(t.sub(7), 'user7@erp.test');
select t.ok(erp.my_tenants() = '{}', 'an invitation that is not bound to a login gives no access');

-- ---------- whoami ----------
set local role authenticated;
select t.logout();
select t.fails($$select erp_api.whoami()$$, 'ERP_AUTH', 'whoami without login: ERP_AUTH');
select t.login(t.sub(99), 'stranger@erp.test');
select t.fails($$select erp_api.whoami()$$, 'ERP_AUTH', 'whoami of a non-member: ERP_AUTH');
select t.as(1);
select t.keep(erp_api.whoami());
select t.ok(t.j() ->> 'role' = 'owner' and t.j() #>> '{tenant,code}' = 'ta' and jsonb_array_length(t.j() -> 'branches') = 2
            and t.j() -> 'caps' ? 'tenant.settings.write' and (t.j() ->> 'all_branches')::boolean and t.j() #>> '{settings,valuation_method}' = 'average',
            'whoami owner: role, tenant, 2 branches, caps, settings');
select t.as(2);
select t.keep(erp_api.whoami());
select t.ok(t.j() ->> 'role' = 'manager' and jsonb_array_length(t.j() -> 'branches') = 1 and t.j() #>> '{branches,0,code}' = 'A1'
            and not (t.j() -> 'caps' ? 'tenant.settings.write'), 'whoami manager: own branch only, no settings write');
reset role;
update erp.members set active = false where tenant_id = t.a() and email = 'user6@erp.test';
set local role authenticated;
select t.as(6);
select t.fails($$select erp_api.whoami()$$, 'ERP_AUTH', 'inactive member: ERP_AUTH');
reset role;
update erp.members set active = true where tenant_id = t.a() and email = 'user6@erp.test';
update erp.tenants set active = false where tenant_id = t.b();
set local role authenticated;
select t.as(11);
select t.fails($$select erp_api.whoami()$$, 'ERP_AUTH', 'member of an inactive tenant: ERP_AUTH');
reset role;
update erp.tenants set active = true where tenant_id = t.b();
set local role authenticated;

-- ---------- RLS reads (SELECT only, per tenant / branch / capability) ----------
select t.as(1);
select t.ok((select count(*) from erp.branches) = 2 and (select count(*) from erp.members) = 7 and (select count(*) from erp.tenants) = 1,
            'owner A reads its 2 branches, 7 members, 1 tenant (nothing of B)');
select t.as(2);
select t.ok((select count(*) from erp.branches) = 1 and (select count(*) from erp.members) = 7, 'manager A1: 1 branch, every member of A (member.read)');
select t.as(3);
select t.ok((select count(*) from erp.branches) = 1 and (select count(*) from erp.members) = 1 and (select email from erp.members) = 'user3@erp.test',
            'warehouse: own branch, only its own member row');
select t.as(11);
select t.ok((select count(*) from erp.branches) = 1 and (select code from erp.branches) = 'B1' and (select count(*) from erp.members where tenant_id = t.a()) = 0,
            'owner B: nothing of A');
select t.as(1);
select t.fails($$select count(*) from erp.idempotency_keys$$, '', 'idempotency_keys: no grant at all');
select t.fails($$insert into erp.branches (tenant_id, code, name) values (t.a(), 'X9', 'x')$$, '', 'no INSERT grant on tables (RPC-only writes)');
select t.fails($$update erp.tenant_settings set hide_money = true$$, '', 'no UPDATE grant on tables');
reset role;
select t.ok(not has_table_privilege('authenticated', 'erp.tenant_settings', 'UPDATE') and not has_table_privilege('authenticated', 'erp.members', 'INSERT')
            and not has_table_privilege('authenticated', 'erp.audit_log', 'DELETE'), 'authenticated has no insert / update / delete privilege');
set local role authenticated;
select t.as(2);
reset role;
update erp.role_caps set allowed = false where tenant_id = t.a() and role = 'manager' and capability = 'member.read';
set local role authenticated;
select t.as(2);
select t.ok((select count(*) from erp.members) = 1, 'tenant override (manager member.read removed): manager sees only its own row');
reset role;
update erp.role_caps set allowed = true where tenant_id = t.a() and role = 'manager' and capability = 'member.read';
set local role authenticated;

-- ---------- branch_list ----------
select t.as(1);
select t.keep(erp_api.branch_list());
select t.ok(jsonb_array_length(t.j() -> 'rows') = 2 and t.j() -> 'next' = 'null'::jsonb, 'branch_list owner: 2 rows, no next');
select t.keep(erp_api.branch_list(false, null, 1));
select t.ok(jsonb_array_length(t.j() -> 'rows') = 1 and t.j() #>> '{rows,0,code}' = 'A1' and t.j() #>> '{next,code}' = 'A1', 'branch_list limit 1: first page + cursor');
select t.keep(erp_api.branch_list(false, t.j() -> 'next', 1));
select t.ok(jsonb_array_length(t.j() -> 'rows') = 1 and t.j() #>> '{rows,0,code}' = 'A2' and t.j() -> 'next' = 'null'::jsonb, 'branch_list second page via keyset cursor');
select t.as(5);
select t.keep(erp_api.branch_list());
select t.ok(jsonb_array_length(t.j() -> 'rows') = 1 and t.j() #>> '{rows,0,code}' = 'A2', 'branch_list clinic_user: own branch');

-- ---------- branch_save ----------
select t.as(1);
select t.keep(erp_api.branch_save('{"code": "A3", "name": "Third", "establishment_no": 2, "address": "Street 1"}', '00000000-0000-4000-b000-000000000001'));
select t.ok(t.j() ->> 'code' = 'A3' and (t.j() ->> 'establishment_no')::int = 2 and (t.j() ->> 'active')::boolean, 'branch_save creates a branch');
select t.ok((erp_api.branch_save('{"code": "A3", "name": "Third", "establishment_no": 2, "address": "Street 1"}', '00000000-0000-4000-b000-000000000001')) ->> 'branch_id'
            = t.j() ->> 'branch_id' and t.count('select 1 from erp.branches where code = ''A3''') = 1, 'same idempotency key: same reply, no second branch');
select t.fails($$select erp_api.branch_save('{"code": "A4", "name": "Other"}', '00000000-0000-4000-b000-000000000001')$$, 'ERP_IDEMPOTENT_MISMATCH', 'same key, different payload: ERP_IDEMPOTENT_MISMATCH');
select t.fails($$select erp_api.branch_save('{"code": "A4", "name": "Other"}', null)$$, 'ERP_VALIDATION', 'no idempotency key: ERP_VALIDATION');
select t.ok(jsonb_array_length(t.problems($$select erp_api.branch_save('{"code": "", "name": " ", "establishment_no": "x"}', gen_random_uuid())$$)) = 3,
            'validation returns ALL problems at once (code, name, establishment_no)');
select t.ok(t.problems($$select erp_api.branch_save('{"code": "a1", "name": "Dup"}', gen_random_uuid())$$) -> 0 ->> 'code' = 'duplicate', 'duplicate code (case-insensitive)');
select t.ok(t.problems($$select erp_api.branch_save('{"code": "A5", "name": "Dup", "establishment_no": 0}', gen_random_uuid())$$) -> 0 ->> 'field' = 'establishment_no',
            'duplicate establishment number');
select t.keep(erp_api.branch_save(jsonb_build_object('branch_id', t.br(t.a(), 'A3'), 'name', 'Third renamed', 'active', false), gen_random_uuid()));
select t.ok(t.j() ->> 'name' = 'Third renamed' and t.j() ->> 'code' = 'A3' and t.j() ->> 'address' = 'Street 1' and not (t.j() ->> 'active')::boolean,
            'branch_save update: only the given keys change');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'branch.update' and row_id = '$$ || (t.j() ->> 'branch_id') || $$'
                       and old_row = '{"name": "Third", "active": true}' and new_row ->> 'name' = 'Third renamed' and not (new_row ? 'code')$$) = 1,
            'audit row of the update holds only the changed keys');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'branch.create' and actor = 'user1@erp.test' and member_id is not null$$) = 1, 'audit row of the create: actor and member');
select t.fails(format($$select erp_api.branch_save('{"branch_id": "%s", "name": "hack"}', gen_random_uuid())$$, t.br(t.b(), 'B1')), 'ERP_TENANT', 'owner A changing a branch of B: ERP_TENANT');
select t.as(2);
select t.fails($$select erp_api.branch_save('{"code": "M1", "name": "x"}', gen_random_uuid())$$, 'ERP_FORBIDDEN', 'manager cannot create a branch');
reset role;
update erp.tenants set limits = '{"branches": 2}' where tenant_id = t.a();
set local role authenticated;
select t.as(1);
select t.fails($$select erp_api.branch_save('{"code": "A6", "name": "Over"}', gen_random_uuid())$$, 'ERP_LIMIT', 'plan hook: branch limit reached -> ERP_LIMIT');
reset role;
update erp.tenants set limits = '{}' where tenant_id = t.a();
select t.ok((select used from erp.tenant_usage where tenant_id = t.a() and kind = 'branches.created') = 1, 'usage counter bumped by a created branch');
set local role authenticated;

-- ---------- settings ----------
select t.as(2);
select t.keep(erp_api.settings_get());
select t.ok(t.j() ->> 'time_zone' = 'Europe/Athens' and not (t.j() ->> 'can_write')::boolean and (t.j() ->> 'version')::int = 1, 'manager reads settings, cannot write');
select t.fails($$select erp_api.settings_save('{"version": 1, "hide_money": true}', gen_random_uuid())$$, 'ERP_FORBIDDEN', 'manager cannot save settings');
select t.as(5);
select t.fails($$select erp_api.settings_get()$$, 'ERP_FORBIDDEN', 'clinic_user cannot read settings');
select t.as(1);
select t.keep(erp_api.settings_save('{"version": 1, "time_zone": "Europe/Athens", "hide_money": true, "lock_date": "2026-01-31", "thresholds": {"adj_value": 200}}', gen_random_uuid()));
select t.ok((t.j() ->> 'version')::int = 2 and (t.j() ->> 'hide_money')::boolean and t.j() ->> 'lock_date' = '2026-01-31' and (t.j() #>> '{thresholds,adj_value}')::int = 200,
            'owner saves settings; version 2');
select t.fails($$select erp_api.settings_save('{"version": 1, "hide_money": false}', gen_random_uuid())$$, 'ERP_CONFLICT', 'stale version: ERP_CONFLICT');
select t.ok((select string_agg(e ->> 'field', ',' order by e ->> 'field') from jsonb_array_elements(
             t.problems($$select erp_api.settings_save('{"version": 2, "time_zone": "Mars/Base", "negative_stock": "maybe", "lock_date": "2999-01-01", "valuation_method": "fifo", "logo_url": "http://x"}', gen_random_uuid())$$)) e)
            = 'lock_date,logo_url,negative_stock,time_zone,valuation_method', 'settings validation: every problem at once, valuation not editable here');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'settings.update' and branch_id is null and new_row ? 'hide_money' and not (new_row ? 'time_zone')$$) = 1,
            'settings audit: tenant-wide row, changed keys only');

-- ---------- audit_list ----------
select t.keep(erp_api.audit_list());
select t.ok(jsonb_array_length(t.j() -> 'rows') >= 3 and t.j() #>> '{rows,0,action}' = 'settings.update', 'audit_list owner: newest first');
select t.keep(erp_api.audit_list('{"action": "branch."}', null, 1));
select t.ok(jsonb_array_length(t.j() -> 'rows') = 1 and t.j() -> 'next' is not null and t.j() -> 'next' <> 'null'::jsonb, 'audit_list filter + keyset next');
select t.as(2);
select t.keep(erp_api.audit_list());
select t.ok(jsonb_array_length(t.j() -> 'rows') = 0, 'manager of A1: no rows of A3 / tenant-wide settings');
select t.as(4);
select t.ok(jsonb_array_length((erp_api.audit_list()) -> 'rows') >= 3, 'accounting with all branches: sees branch and tenant-wide rows');
select t.as(3);
select t.fails($$select erp_api.audit_list()$$, 'ERP_FORBIDDEN', 'warehouse cannot read the audit log');
select t.as(11);
select t.ok(jsonb_array_length((erp_api.audit_list()) -> 'rows') = 0 and (select count(*) from erp.audit_log) = 0, 'owner B: no audit row of A (RPC and table)');
reset role;

-- ---------- append-only, trigger checks, internal functions closed ----------
select t.fails($$update erp.audit_log set actor = 'x'$$, 'ERP_APPEND_ONLY', 'audit_log: UPDATE refused even for the owner role');
select t.fails($$delete from erp.audit_log$$, 'ERP_APPEND_ONLY', 'audit_log: DELETE refused');
select t.fails($$truncate erp.audit_log$$, 'ERP_APPEND_ONLY', 'audit_log: TRUNCATE refused');
select t.fails(format($$insert into erp.members (tenant_id, email, role, branch_ids) values ('%s', 'x@erp.test', 'readonly', array['%s'::uuid])$$, t.a(), t.br(t.b(), 'B1')),
               'ERP_TENANT', 'member with a branch of another tenant: refused by trigger');
select t.ok(not has_function_privilege('authenticated', 'erp.audit(uuid,text,text,text,jsonb,jsonb,uuid)', 'execute')
            and not has_function_privilege('authenticated', 'erp.idem_begin(uuid,uuid,text,jsonb)', 'execute')
            and not has_function_privilege('anon', 'erp_api.whoami()', 'execute'), 'internal functions closed to authenticated; erp_api closed to anon');
select t.ok(erp.today(t.a()) = (now() at time zone 'Europe/Athens')::date, 'erp.today follows the tenant time zone');

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
