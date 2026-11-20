-- =====================================================================
-- iSmile ERP  -  E110_members.sql   (task T03)
-- Purpose : member invitations by email, first-login binding (Supabase Auth user id = JWT sub), member list /
--           change / deactivate / reset of the login link, tenant onboarding (tenant #1 and any later tenant).
-- Run order: after E100. Standalone: names no CRM object. Safe to re-run.
-- Redefines: nothing.
-- Tests    : tests/E110_members_tests.sql, tests/E990_generated_isolation_tests.sql (RPC registry rows),
--            tests/E991_adversarial_tests.sql, tests/concurrency_last_owner.sh (runner)
-- How a person gets in: (1) the owner invites the email here (member_invite); (2) the person gets a LOGIN for the
-- same email: the owner invites it in Supabase (Authentication > Users > Invite user) or, when the email already
-- has a login (e.g. CRM staff in suite mode), the person uses "Forgot password"; (3) at the first sign-in the page
-- calls member_bind, which links the invitation to that login. Only a bound member has access (E100 helpers).
-- =====================================================================

do $$ begin
  if to_regprocedure('erp.require_member()') is null then raise exception 'run E100_tenancy.sql first'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. JSON shape of a member (no auth user id leaves the server)
-- ---------------------------------------------------------------------
create or replace function erp.member_json(m erp.members) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('member_id', m.member_id, 'email', m.email, 'display_name', m.display_name, 'role', m.role,
                            'branch_ids', to_jsonb(m.branch_ids), 'all_branches', m.all_branches or m.role = 'owner', 'active', m.active,
                            'status', case when not m.active then 'inactive' when m.auth_user_id is null then 'pending' else 'active' end,
                            'invited_at', m.invited_at, 'invited_by', m.invited_by, 'bound_at', m.bound_at, 'updated_at', m.updated_at)
$$;

-- Shared validation of role / branches / all_branches / display_name for invite and update. Returns the problems;
-- a branch id of another tenant raises ERP_TENANT at once.
create or replace function erp.member_check(p_tenant uuid, p_role text, p_branch_ids jsonb, p_all boolean, p_name text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare probs jsonb := '[]'; e jsonb;
begin
  if p_role is null or p_role = '' then
    probs := probs || erp.problem('required', 'role', 'Role is required.');
  elsif not exists (select 1 from erp.roles r where r.role = p_role) then
    probs := probs || erp.problem('invalid', 'role', format('Unknown role %s.', p_role));
  elsif exists (select 1 from erp.roles r where r.role = p_role and r.facade_only) then
    probs := probs || erp.problem('invalid', 'role', format('Role %s is reserved for an integration and cannot be given here.', p_role));
  end if;
  if p_branch_ids is not null and jsonb_typeof(p_branch_ids) <> 'array' then
    probs := probs || erp.problem('invalid', 'branch_ids', 'branch_ids must be a list.');
  elsif p_branch_ids is not null then
    for e in select * from jsonb_array_elements(p_branch_ids) loop
      if jsonb_typeof(e) <> 'string' or (e #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        probs := probs || erp.problem('invalid', 'branch_ids', 'A branch id is not valid.');
      else
        perform erp.require_branch_of_tenant(p_tenant, (e #>> '{}')::uuid);
      end if;
    end loop;
  end if;
  if coalesce(p_role, '') not in ('', 'owner') and not coalesce(p_all, false)
     and (p_branch_ids is null or jsonb_typeof(p_branch_ids) <> 'array' or jsonb_array_length(p_branch_ids) = 0) then
    probs := probs || erp.problem('required', 'branch_ids', 'Choose at least one branch, or all branches.');
  end if;
  if p_name is not null and length(p_name) > 120 then
    probs := probs || erp.problem('invalid', 'display_name', 'Name: at most 120 characters.');
  end if;
  return probs;
end $$;

create or replace function erp.uuid_array(p jsonb) returns uuid[]
language sql immutable set search_path = '' as $$
  select coalesce((select array_agg(distinct (e #>> '{}')::uuid) from jsonb_array_elements(coalesce(p, '[]'::jsonb)) e), '{}'::uuid[])
$$;

-- ---------------------------------------------------------------------
-- 2. First-login binding (self-service; the only RPC a non-member may call usefully)
-- ---------------------------------------------------------------------
-- Reply: {bound: true, tenant_id, already} | {bound: false, reason: 'no_invitation' | 'bound_to_other_login' |
-- 'login_in_other_organisation'}.
-- Binds the ACTIVE invitation whose email = the login email to the login's sub. An invitation already bound to a
-- different login is never re-bound (the owner resets it with member_reset_binding); an alert tells the owner.
-- A login already bound to a member row (another tenant, also an inactive row) is not bound a second time (v1: one
-- login = one member row, E100 members_auth_uq). An anonymous Supabase login never binds.
create or replace function erp_api.member_bind(p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare v_sub uuid := erp.jwt_sub(); v_email text := erp.jwt_email(); m erp.members; prev jsonb; res jsonb;
begin
  if v_sub is null or v_email is null then
    perform erp.err('ERP_AUTH', 'Sign in first.');
  end if;
  if coalesce(erp.jwt_claims() ->> 'is_anonymous', 'false') <> 'false' then
    perform erp.err('ERP_AUTH', 'An anonymous login cannot join an ERP organisation.');
  end if;
  select x.* into m from erp.members x join erp.tenants t on t.tenant_id = x.tenant_id and t.active
   where x.email = v_email and x.active for update of x;
  if not found then
    return jsonb_build_object('bound', false, 'reason', 'no_invitation');
  end if;
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'member_bind', jsonb_build_object('sub', v_sub));
  if prev is not null then return prev; end if;
  if m.auth_user_id = v_sub then
    return jsonb_build_object('bound', true, 'tenant_id', m.tenant_id, 'already', true);
  end if;
  if m.auth_user_id is not null then
    perform erp.alert_raise(m.tenant_id, 'member_bind_conflict', 'warning', 'alert.member_bind_conflict', jsonb_build_object('email', m.email),
                            null, 'members', m.member_id::text, 'member_bind_conflict:' || m.member_id);
    return jsonb_build_object('bound', false, 'reason', 'bound_to_other_login');
  end if;
  if exists (select 1 from erp.members x where x.auth_user_id = v_sub) then
    return jsonb_build_object('bound', false, 'reason', 'login_in_other_organisation');
  end if;
  update erp.members set auth_user_id = v_sub, bound_at = now(), updated_at = now()
   where tenant_id = m.tenant_id and member_id = m.member_id;
  perform erp.audit(m.tenant_id, 'member.bind', 'members', m.member_id::text, jsonb_build_object('status', 'pending'), jsonb_build_object('status', 'active'));
  res := jsonb_build_object('bound', true, 'tenant_id', m.tenant_id, 'already', false);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'member_bind', jsonb_build_object('sub', v_sub), res);
end $$;

-- ---------------------------------------------------------------------
-- 3. Member administration
-- ---------------------------------------------------------------------
-- member_list: filter keys q (email / name contains), status (pending | active | inactive), role; keyset (email, member_id)
create or replace function erp_api.member_list(p_filter jsonb default '{}', p_cursor jsonb default null, p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare me erp.members; lim int := least(greatest(coalesce(p_limit, 50), 1), 200); rows jsonb; n int; q text;
begin
  me := erp.require_member();
  perform erp.require_cap('member.read');
  p_filter := coalesce(p_filter, '{}');
  q := nullif(lower(btrim(p_filter ->> 'q')), '');
  with page as (
    select m as r from erp.members m
     where m.tenant_id = me.tenant_id
       and (q is null or strpos(m.email, q) > 0 or strpos(lower(coalesce(m.display_name, '')), q) > 0)
       and (p_filter ->> 'role' is null or m.role = p_filter ->> 'role')
       and (p_filter ->> 'status' is null or p_filter ->> 'status' =
            case when not m.active then 'inactive' when m.auth_user_id is null then 'pending' else 'active' end)
       and (p_cursor is null or (m.email, m.member_id) > (p_cursor ->> 'email', (p_cursor ->> 'member_id')::uuid))
     order by m.email, m.member_id limit lim + 1)
  select jsonb_agg(erp.member_json(page.r) order by (page.r).email, (page.r).member_id), count(*) into rows, n from page;
  rows := coalesce(rows, '[]'::jsonb);
  if n > lim then
    rows := rows - lim;
    return jsonb_build_object('rows', rows, 'next', jsonb_build_object('email', rows -> (lim - 1) ->> 'email', 'member_id', rows -> (lim - 1) ->> 'member_id'));
  end if;
  return jsonb_build_object('rows', rows, 'next', null);
end $$;

-- member_invite: keys email, role, branch_ids (list), all_branches, display_name. Creates a PENDING member.
create or replace function erp_api.member_invite(p_member jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare me erp.members; prev jsonb; m erp.members; probs jsonb := '[]'; v_email text; v_name text; v_all boolean; res jsonb; k text;
begin
  me := erp.require_member();
  perform erp.require_cap('member.manage');
  prev := erp.idem_begin(me.tenant_id, p_idempotency_key, 'member_invite', p_member);
  if prev is not null then return prev; end if;
  if p_member is null or jsonb_typeof(p_member) <> 'object' then p_member := '{}'; end if;
  if p_member ->> 'role' = 'owner' and me.role <> 'owner' then
    perform erp.err('ERP_FORBIDDEN', 'Only an owner can invite an owner.');
  end if;
  for k in select jsonb_object_keys(p_member) loop
    if k not in ('email', 'role', 'branch_ids', 'all_branches', 'display_name') then
      probs := probs || erp.problem('not_editable', k, format('%s cannot be set here.', k));
    end if;
  end loop;
  v_email := lower(btrim(coalesce(p_member ->> 'email', '')));
  v_name := nullif(btrim(p_member ->> 'display_name'), '');
  v_all := coalesce((p_member ->> 'all_branches')::boolean, false);
  if v_email = '' then probs := probs || erp.problem('required', 'email', 'Email is required.');
  elsif v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then probs := probs || erp.problem('invalid', 'email', 'Not a valid email address.');
  elsif exists (select 1 from erp.members x where x.email = v_email) then
    -- same message whether the email is in this tenant or another one (nothing is told about other tenants)
    probs := probs || erp.problem('email_taken', 'email', 'This email is already a member or invited, and cannot be invited again.');
  end if;
  probs := probs || erp.member_check(me.tenant_id, p_member ->> 'role', p_member -> 'branch_ids', v_all, v_name);
  perform erp.raise_problems(probs);
  perform erp.check_limit(me.tenant_id, 'users');
  insert into erp.members (tenant_id, email, display_name, role, branch_ids, all_branches, invited_by)
  values (me.tenant_id, v_email, v_name, p_member ->> 'role', erp.uuid_array(p_member -> 'branch_ids'), v_all, me.member_id)
  returning * into m;
  perform erp.usage_bump(me.tenant_id, 'members.invited');
  perform erp.audit(me.tenant_id, 'member.invite', 'members', m.member_id::text, null, erp.member_json(m));
  res := erp.member_json(m);
  return erp.idem_end(me.tenant_id, p_idempotency_key, 'member_invite', p_member, res);
end $$;

-- Member administration of one tenant runs one at a time (review F1, finding F1-02): without it two owners demoting
-- (or unlinking) each other at the same moment both see "another owner exists" and the tenant ends with none.
-- Callers take it right after require_member, then read the caller again (a change committed meanwhile is seen).
create or replace function erp.members_lock(p_tenant uuid) returns erp.members
language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('erp.members:' || p_tenant, 0));
  return erp.require_member();
end $$;

-- the tenant must keep at least one ACTIVE, BOUND owner (else nobody could administer it)
create or replace function erp.other_active_owners(p_tenant uuid, p_member uuid) returns bigint
language sql stable security definer set search_path = '' as $$
  select count(*) from erp.members m
   where m.tenant_id = p_tenant and m.member_id <> p_member and m.role = 'owner' and m.active and m.auth_user_id is not null
$$;

-- member_update: keys role, branch_ids, all_branches, display_name, active (only the keys given change).
-- The email cannot change: deactivate and invite the new address.
create or replace function erp_api.member_update(p_member_id uuid, p_changes jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare me erp.members; prev jsonb; old erp.members; m erp.members; probs jsonb := '[]'; k text; res jsonb;
        v_role text; v_br jsonb; v_all boolean; v_name text; v_active boolean;
begin
  me := erp.require_member();
  perform erp.require_cap('member.manage');
  me := erp.members_lock(me.tenant_id);
  perform erp.require_cap('member.manage');
  prev := erp.idem_begin(me.tenant_id, p_idempotency_key, 'member_update', jsonb_build_object('id', p_member_id, 'changes', p_changes));
  if prev is not null then return prev; end if;
  select * into old from erp.members x where x.tenant_id = me.tenant_id and x.member_id = p_member_id for update;
  if not found then
    perform erp.err('ERP_TENANT', format('Member %s does not belong to your organisation.', coalesce(p_member_id::text, 'null')));
  end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' then p_changes := '{}'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if k not in ('role', 'branch_ids', 'all_branches', 'display_name', 'active') then
      probs := probs || erp.problem('not_editable', k, format('%s cannot be changed here.', k));
    end if;
  end loop;
  v_role := coalesce(p_changes ->> 'role', old.role);
  v_br := case when p_changes ? 'branch_ids' then p_changes -> 'branch_ids' else to_jsonb(old.branch_ids) end;
  v_all := case when p_changes ? 'all_branches' then coalesce((p_changes ->> 'all_branches')::boolean, false) else old.all_branches end;
  v_name := case when p_changes ? 'display_name' then nullif(btrim(p_changes ->> 'display_name'), '') else old.display_name end;
  v_active := case when p_changes ? 'active' then coalesce((p_changes ->> 'active')::boolean, old.active) else old.active end;
  if (old.role = 'owner' or v_role = 'owner') and me.role <> 'owner' then
    perform erp.err('ERP_FORBIDDEN', 'Only an owner can give, change or remove the owner role.');
  end if;
  probs := probs || erp.member_check(me.tenant_id, v_role, v_br, v_all, v_name);
  if old.role = 'owner' and old.active and old.auth_user_id is not null and (v_role <> 'owner' or not v_active)
     and erp.other_active_owners(me.tenant_id, old.member_id) = 0 then
    probs := probs || erp.problem('last_owner', case when v_role <> 'owner' then 'role' else 'active' end,
                                  'The organisation must keep at least one active owner.');
  end if;
  perform erp.raise_problems(probs);
  if v_active and not old.active then perform erp.check_limit(me.tenant_id, 'users'); end if;
  update erp.members set role = v_role, branch_ids = erp.uuid_array(v_br), all_branches = v_all, display_name = v_name, active = v_active,
         updated_at = now()
   where tenant_id = me.tenant_id and member_id = old.member_id returning * into m;
  perform erp.audit(me.tenant_id, 'member.update', 'members', m.member_id::text, erp.member_json(old) - 'updated_at', erp.member_json(m) - 'updated_at');
  res := erp.member_json(m);
  return erp.idem_end(me.tenant_id, p_idempotency_key, 'member_update', jsonb_build_object('id', p_member_id, 'changes', p_changes), res);
end $$;

-- member_reset_binding: unlink the login (lost / recreated Auth user); the next sign-in with the email binds again.
create or replace function erp_api.member_reset_binding(p_member_id uuid, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare me erp.members; prev jsonb; old erp.members; m erp.members; res jsonb;
begin
  me := erp.require_member();
  perform erp.require_cap('member.manage');
  me := erp.members_lock(me.tenant_id);
  perform erp.require_cap('member.manage');
  prev := erp.idem_begin(me.tenant_id, p_idempotency_key, 'member_reset_binding', to_jsonb(p_member_id));
  if prev is not null then return prev; end if;
  select * into old from erp.members x where x.tenant_id = me.tenant_id and x.member_id = p_member_id for update;
  if not found then
    perform erp.err('ERP_TENANT', format('Member %s does not belong to your organisation.', coalesce(p_member_id::text, 'null')));
  end if;
  if old.member_id = me.member_id then
    perform erp.raise_problems(jsonb_build_array(erp.problem('self', 'member_id', 'You cannot unlink your own login.')));
  end if;
  if old.role = 'owner' and me.role <> 'owner' then
    perform erp.err('ERP_FORBIDDEN', 'Only an owner can unlink the login of an owner.');
  end if;
  if old.role = 'owner' and old.active and old.auth_user_id is not null and erp.other_active_owners(me.tenant_id, old.member_id) = 0 then
    perform erp.raise_problems(jsonb_build_array(erp.problem('last_owner', 'member_id', 'The organisation must keep at least one active owner.')));
  end if;
  update erp.members set auth_user_id = null, bound_at = null, updated_at = now()
   where tenant_id = me.tenant_id and member_id = old.member_id returning * into m;
  update erp.alerts set resolved_at = now(), resolved_by = me.member_id
   where tenant_id = me.tenant_id and dedupe_key = 'member_bind_conflict:' || old.member_id and resolved_at is null;
  perform erp.audit(me.tenant_id, 'member.reset_binding', 'members', m.member_id::text,
                    jsonb_build_object('status', case when old.auth_user_id is null then 'pending' else 'active' end, 'bound_at', old.bound_at),
                    jsonb_build_object('status', 'pending', 'bound_at', null));
  res := erp.member_json(m);
  return erp.idem_end(me.tenant_id, p_idempotency_key, 'member_reset_binding', to_jsonb(p_member_id), res);
end $$;

-- ---------------------------------------------------------------------
-- 4. Onboarding (SQL editor / owner of the platform only; NOT granted to any API role)
--    Creates the tenant when missing (code unique), its settings + permission matrix, and a pending OWNER invitation
--    unless the tenant already has an active owner. Branches and other members are typed in the admin screen.
--    p_owner_auth_user_id (optional, review F1 finding F1-04): the owner's EXISTING Supabase login id, read in the SQL
--    editor (`(select id from auth.users where email = '...')`, never in an E file). Given, the owner row is bound at
--    once, so there is no window in which another login could claim the owner invitation.
--    Re-runnable: a second call changes nothing (except binding a still-pending owner row when the id is given).
-- ---------------------------------------------------------------------
drop function if exists erp.tenant_onboard(text, text, text);
create or replace function erp.tenant_onboard(p_code text, p_name text, p_owner_email text, p_owner_auth_user_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_tenant uuid; v_email text := lower(btrim(coalesce(p_owner_email, ''))); m erp.members; created boolean := false; invited boolean := false;
        bound boolean := false; n int; has_row boolean;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'ERP_VALIDATION: owner email % is not valid', p_owner_email;
  end if;
  select tenant_id into v_tenant from erp.tenants where code = p_code;
  if v_tenant is null then
    insert into erp.tenants (code, name) values (p_code, p_name) returning tenant_id into v_tenant;
    created := true;
  end if;
  perform erp.tenant_init(v_tenant);
  select * into m from erp.members where email = v_email;
  has_row := found;
  if has_row and m.tenant_id <> v_tenant then
    raise exception 'ERP_VALIDATION: % is already a member of another ERP organisation', v_email;
  end if;
  if p_owner_auth_user_id is not null and exists (select 1 from erp.members x where x.auth_user_id = p_owner_auth_user_id and x.email <> v_email) then
    raise exception 'ERP_VALIDATION: login % is already bound to another ERP member', p_owner_auth_user_id;
  end if;
  perform set_config('erp.actor', 'onboarding', true);
  if not exists (select 1 from erp.members x where x.tenant_id = v_tenant and x.role = 'owner' and x.active) then
    if has_row then
      update erp.members set role = 'owner', all_branches = true, active = true, updated_at = now()
       where tenant_id = v_tenant and member_id = m.member_id;
    else
      insert into erp.members (tenant_id, email, role, all_branches) values (v_tenant, v_email, 'owner', true);
    end if;
    invited := true;
    perform erp.audit(v_tenant, 'tenant.onboard', 'members', v_email, null, jsonb_build_object('email', v_email, 'role', 'owner'));
  end if;
  if p_owner_auth_user_id is not null then
    update erp.members set auth_user_id = p_owner_auth_user_id, bound_at = now(), updated_at = now()
     where tenant_id = v_tenant and email = v_email and role = 'owner' and active and auth_user_id is null;
    get diagnostics n = row_count;
    bound := n > 0;
    if bound then
      perform erp.audit(v_tenant, 'member.bind', 'members', v_email, jsonb_build_object('status', 'pending'), jsonb_build_object('status', 'active'));
    end if;
  end if;
  return jsonb_build_object('tenant_id', v_tenant, 'code', p_code, 'tenant_created', created, 'owner_invited', invited,
                            'owner_bound', bound, 'owner_email', v_email);
end $$;

-- ---------------------------------------------------------------------
-- 5. Function grants (E100 section 11)
-- ---------------------------------------------------------------------
select erp.lock_down();
grant execute on function erp_api.member_bind(uuid), erp_api.member_list(jsonb, jsonb, int), erp_api.member_invite(jsonb, uuid),
                          erp_api.member_update(uuid, jsonb, uuid), erp_api.member_reset_binding(uuid, uuid) to authenticated;
