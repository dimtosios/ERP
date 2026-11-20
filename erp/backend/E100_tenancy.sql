-- =====================================================================
-- iSmile ERP  -  E100_tenancy.sql   (task T02)
-- Purpose : schemas erp / erp_api; platform tables: tenants (tenant #1 seed), branches, members, roles +
--           capabilities + role_caps (the permission matrix as data), tenant_settings, tenant_usage, alerts,
--           audit_log (append-only), idempotency_keys; helpers jwt_*, my_tenants, my_branches, is_owner, can,
--           require_member, err, audit, idempotency, today, check_limit; RLS (fast form) on every table;
--           RPCs whoami, branch_list, branch_save, settings_get, settings_save, audit_list; alert_list, alert_resolve (T14).
-- Run order: FIRST ERP file. Standalone: names no CRM object (public / app). Safe to re-run.
-- Redefines: nothing.
-- Tests    : tests/E100_tenancy_tests.sql, tests/E990_generated_isolation_tests.sql, tests/E991_adversarial_tests.sql
-- =====================================================================

do $$ begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = current_user and (rolsuper or rolbypassrls)) then
    raise exception 'ERP files must run as a role with BYPASSRLS (Supabase: postgres); current_user = %', current_user;
  end if;
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'authenticated') then
    raise exception 'role authenticated is missing (Supabase creates it; locally run_erp_tests.sh does)';
  end if;
end $$;

create schema if not exists erp;
create schema if not exists erp_api;
revoke all on schema erp from public;
revoke all on schema erp_api from public;
grant usage on schema erp to authenticated;
grant usage on schema erp_api to authenticated;
-- (per-schema default privileges cannot remove the global PUBLIC execute, so every file ends with explicit revokes)

-- ---------------------------------------------------------------------
-- 1. Errors (03 section 3): ERP_<CODE>: <sentence>; detail = jsonb text (problem array for ERP_VALIDATION)
-- ---------------------------------------------------------------------
create or replace function erp.err(p_code text, p_message text, p_detail jsonb default null) returns void
language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = 'P0001', message = p_code || ': ' || p_message, detail = coalesce(p_detail::text, '');
end $$;

-- problems = jsonb array of {code, line_no, field, message}; raises ERP_VALIDATION when not empty
create or replace function erp.raise_problems(p_problems jsonb) returns void
language plpgsql set search_path = '' as $$
begin
  if p_problems is not null and jsonb_array_length(p_problems) > 0 then
    perform erp.err('ERP_VALIDATION', jsonb_array_length(p_problems) || ' problem(s): ' ||
      (select string_agg(coalesce(e ->> 'field', '-') || ' ' || (e ->> 'message'), '; ') from jsonb_array_elements(p_problems) e), p_problems);
  end if;
end $$;

create or replace function erp.problem(p_code text, p_field text, p_message text, p_line_no int default null) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('code', p_code, 'line_no', p_line_no, 'field', p_field, 'message', p_message)
$$;

-- ---------------------------------------------------------------------
-- 2. Platform tables
-- ---------------------------------------------------------------------
create table if not exists erp.tenants (
  tenant_id  uuid primary key default gen_random_uuid(),
  code       text not null check (code ~ '^[a-z0-9][a-z0-9_-]{1,39}$'),
  name       text not null check (btrim(name) <> ''),
  plan       text not null default 'standard',
  limits     jsonb not null default '{}'::jsonb check (jsonb_typeof(limits) = 'object'),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
-- platform-wide uniqueness of the tenant code (the one index that cannot start with tenant_id)
create unique index if not exists tenants_code_uq on erp.tenants (code);

create table if not exists erp.branches (
  tenant_id        uuid not null references erp.tenants (tenant_id),
  branch_id        uuid not null default gen_random_uuid(),
  code             text not null check (code ~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,19}$'),
  name             text not null check (btrim(name) <> ''),
  establishment_no int check (establishment_no between 0 and 99999),
  address          text,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  primary key (tenant_id, branch_id)
);
create unique index if not exists branches_code_uq on erp.branches (tenant_id, lower(code));
create unique index if not exists branches_estab_uq on erp.branches (tenant_id, establishment_no) where establishment_no is not null;

-- Roles and capabilities are a PLATFORM CATALOG (no tenant data, same for every tenant). The tenant's own matrix is
-- erp.role_caps, copied from erp.role_cap_defaults and changed per tenant by rows (02 "Permissions matrix").
create table if not exists erp.roles (
  role        text primary key check (role ~ '^[a-z][a-z_]{1,30}$'),
  sort        int not null default 100,
  facade_only boolean not null default false   -- a role used only by an integration facade (07 section 5 item 4; none seeded)
);
comment on table erp.roles is 'platform catalog: ERP roles (no tenant data)';
create table if not exists erp.capabilities (
  capability text primary key check (capability ~ '^[a-z][a-z0-9_.]{2,60}$'),
  area       text not null,
  note       text
);
comment on table erp.capabilities is 'platform catalog: capability names checked by erp.can() (no tenant data)';
create table if not exists erp.role_cap_defaults (
  role       text not null references erp.roles (role),
  capability text not null references erp.capabilities (capability),
  primary key (role, capability)
);
comment on table erp.role_cap_defaults is 'platform catalog: default matrix copied into erp.role_caps of every tenant (no tenant data)';
create table if not exists erp.role_caps (
  tenant_id  uuid not null references erp.tenants (tenant_id),
  role       text not null references erp.roles (role),
  capability text not null references erp.capabilities (capability),
  allowed    boolean not null default true,   -- a tenant removes a default by allowed = false (kept on re-run)
  primary key (tenant_id, role, capability)
);

create table if not exists erp.members (
  tenant_id    uuid not null references erp.tenants (tenant_id),
  member_id    uuid not null default gen_random_uuid(),
  email        text not null check (email = lower(btrim(email)) and email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  display_name text,
  auth_user_id uuid,                            -- Supabase Auth user id (JWT sub), bound at the first sign-in (E110)
  role         text not null references erp.roles (role),
  branch_ids   uuid[] not null default '{}',
  all_branches boolean not null default false,  -- sees every branch, also future ones (owner always does)
  active       boolean not null default true,
  invited_by   uuid,
  invited_at   timestamptz not null default now(),
  bound_at     timestamptz,
  updated_at   timestamptz not null default now(),
  primary key (tenant_id, member_id)
);
-- v1: one email = one tenant AND one login (sub) = one member row (02). Identity lookups are by login, across tenants
-- by nature, so these two indexes cannot start with tenant_id (documented exception). The login index is UNIQUE
-- (review F1, finding F1-01): a login bound in two tenants would get the capabilities of one tenant in the other
-- (erp.can / RLS read every bound row of the login), so v1 refuses it; multi-tenant members need a tenant context first.
create unique index if not exists members_email_uq on erp.members (email);
drop index if exists erp.members_auth_idx;
create unique index if not exists members_auth_uq on erp.members (auth_user_id) where auth_user_id is not null;
create unique index if not exists members_tenant_auth_uq on erp.members (tenant_id, auth_user_id) where auth_user_id is not null;

create table if not exists erp.tenant_settings (
  tenant_id           uuid primary key references erp.tenants (tenant_id),
  time_zone           text not null default 'Europe/Athens',
  valuation_method    text not null default 'average' check (valuation_method in ('average', 'fifo')),  -- owner decision: average
  negative_stock      text not null default 'warn' check (negative_stock in ('warn', 'block')),           -- owner decision: warn
  lock_date           date,
  thresholds          jsonb not null default '{}'::jsonb check (jsonb_typeof(thresholds) = 'object'),
  logo_url            text check (logo_url is null or logo_url ~ '^https://'),
  hide_money          boolean not null default false,
  integration_enabled boolean not null default false,   -- suite mode (06 section 6); only phase IP may use it
  version             int not null default 1,
  updated_at          timestamptz not null default now()
);

create table if not exists erp.tenant_usage (
  tenant_id uuid not null references erp.tenants (tenant_id),
  kind      text not null,
  period    text not null,           -- 'YYYY-MM' in the tenant time zone
  used      bigint not null default 0,
  primary key (tenant_id, kind, period)
);

create table if not exists erp.alerts (
  tenant_id   uuid not null references erp.tenants (tenant_id),
  alert_id    uuid not null default gen_random_uuid(),
  branch_id   uuid,                  -- null = tenant-wide (owner / all-branches members)
  kind        text not null,
  severity    text not null default 'info' check (severity in ('info', 'warning', 'critical')),
  message_key text not null,
  params      jsonb not null default '{}'::jsonb,
  ref_table   text,
  ref_id      text,
  dedupe_key  text,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid,
  primary key (tenant_id, alert_id),
  foreign key (tenant_id, branch_id) references erp.branches (tenant_id, branch_id)
);
create unique index if not exists alerts_open_dedupe_uq on erp.alerts (tenant_id, dedupe_key) where resolved_at is null and dedupe_key is not null;
create index if not exists alerts_open_idx on erp.alerts (tenant_id, branch_id, created_at desc) where resolved_at is null;

create table if not exists erp.audit_log (
  tenant_id  uuid not null references erp.tenants (tenant_id),
  audit_id   bigint generated always as identity,
  at         timestamptz not null default now(),
  member_id  uuid,
  actor      text not null,
  action     text not null,
  table_name text,
  row_id     text,
  branch_id  uuid,
  old_row    jsonb,
  new_row    jsonb,
  request_id text,
  ip         text,
  primary key (tenant_id, audit_id)
);
create index if not exists audit_log_at_idx on erp.audit_log (tenant_id, at desc, audit_id desc);

-- write RPC replies stored per (tenant, key): a repeat returns the stored reply (03 section 3). No grants at all.
create table if not exists erp.idempotency_keys (
  tenant_id    uuid not null references erp.tenants (tenant_id),
  idem_key     uuid not null,
  rpc          text not null,
  request_hash text not null,
  result       jsonb,
  member_id    uuid,
  created_at   timestamptz not null default now(),
  primary key (tenant_id, idem_key)
);

-- ---------------------------------------------------------------------
-- 3. Append-only guard (audit_log; later files attach it to their ledgers)
-- ---------------------------------------------------------------------
create or replace function erp.tg_append_only() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform erp.err('ERP_APPEND_ONLY', format('%s is append-only: %s is not allowed.', tg_table_name, lower(tg_op)));
  return null;
end $$;
drop trigger if exists audit_log_append_only on erp.audit_log;
create trigger audit_log_append_only before update or delete on erp.audit_log for each row execute function erp.tg_append_only();
drop trigger if exists audit_log_no_truncate on erp.audit_log;
create trigger audit_log_no_truncate before truncate on erp.audit_log for each statement execute function erp.tg_append_only();

-- members.branch_ids must name branches of the same tenant (an array cannot carry a foreign key)
create or replace function erp.tg_members_branches() returns trigger
language plpgsql set search_path = '' as $$
begin
  if exists (select 1 from unnest(new.branch_ids) b(id)
              where not exists (select 1 from erp.branches x where x.tenant_id = new.tenant_id and x.branch_id = b.id)) then
    perform erp.err('ERP_TENANT', 'A branch of this member does not belong to the organisation.');
  end if;
  new.branch_ids := coalesce((select array_agg(distinct id order by id) from unnest(new.branch_ids) id), '{}');
  return new;
end $$;
drop trigger if exists members_branches on erp.members;
create trigger members_branches before insert or update of branch_ids, tenant_id on erp.members
  for each row execute function erp.tg_members_branches();

-- ---------------------------------------------------------------------
-- 4. Identity and permission helpers
--    Supabase / PostgREST put the verified login token in request.jwt.claims (sub = Auth user id, email).
--    The ERP reads the claims itself, so it needs no object of the auth schema and runs on an empty database.
-- ---------------------------------------------------------------------
create or replace function erp.jwt_claims() returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$$;
create or replace function erp.jwt_sub() returns uuid
language sql stable set search_path = '' as $$
  select case when erp.jwt_claims() ->> 'sub' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then (erp.jwt_claims() ->> 'sub')::uuid end
$$;
create or replace function erp.jwt_email() returns text
language sql stable set search_path = '' as $$
  select nullif(lower(btrim(coalesce(erp.jwt_claims() ->> 'email', ''))), '')
$$;

-- The caller's active member rows (v1: at most one, email unique). Only BOUND rows (auth_user_id = sub) count.
create or replace function erp.my_tenants() returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(m.tenant_id order by m.tenant_id), '{}')
    from erp.members m join erp.tenants t on t.tenant_id = m.tenant_id and t.active
   where m.auth_user_id = erp.jwt_sub() and m.active
$$;
-- Branches the caller may see: owner / all_branches = every branch of the tenant (also inactive ones), else branch_ids.
create or replace function erp.my_branches() returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(x.branch_id order by x.branch_id), '{}') from (
    select b.branch_id
      from erp.members m join erp.tenants t on t.tenant_id = m.tenant_id and t.active
      join erp.branches b on b.tenant_id = m.tenant_id
     where m.auth_user_id = erp.jwt_sub() and m.active
       and (m.role = 'owner' or m.all_branches or b.branch_id = any (m.branch_ids))) x
$$;
-- True only when the caller is owner in EVERY tenant it belongs to: identical to "is owner" in v1 (one tenant per
-- email) and never more permissive once multi-tenant members (accountants) are allowed.
create or replace function erp.is_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(bool_and(m.role = 'owner'), false)
    from erp.members m join erp.tenants t on t.tenant_id = m.tenant_id and t.active
   where m.auth_user_id = erp.jwt_sub() and m.active
$$;
-- Owner or all-branches member: may see tenant-wide rows that carry no branch (alerts, audit).
create or replace function erp.sees_all_branches() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(bool_and(m.role = 'owner' or m.all_branches), false)
    from erp.members m join erp.tenants t on t.tenant_id = m.tenant_id and t.active
   where m.auth_user_id = erp.jwt_sub() and m.active
$$;

-- The caller's member row (v1 one tenant). Returns null for a non-member.
create or replace function erp.current_member() returns erp.members
language sql stable security definer set search_path = '' as $$
  select m from erp.members m join erp.tenants t on t.tenant_id = m.tenant_id and t.active
   where m.auth_user_id = erp.jwt_sub() and m.active
   order by m.tenant_id limit 1
$$;
create or replace function erp.current_tenant() returns uuid
language sql stable security definer set search_path = '' as $$
  select (erp.current_member()).tenant_id
$$;
-- First line of every erp_api function: raises ERP_AUTH for a non-member and returns the member row.
create or replace function erp.require_member() returns erp.members
language plpgsql stable security definer set search_path = '' as $$
declare m erp.members;
begin
  m := erp.current_member();
  if m.member_id is null then
    perform erp.err('ERP_AUTH', 'This login is not an active member of an ERP organisation.');
  end if;
  return m;
end $$;

-- can(capability, branch): the role of the caller has the capability in its tenant (erp.role_caps, allowed) and,
-- when a branch is given, the branch belongs to that tenant and is visible to the caller.
create or replace function erp.can(p_cap text, p_branch uuid default null) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from erp.members m
      join erp.tenants t on t.tenant_id = m.tenant_id and t.active
      join erp.role_caps rc on rc.tenant_id = m.tenant_id and rc.role = m.role and rc.capability = p_cap and rc.allowed
     where m.auth_user_id = erp.jwt_sub() and m.active
       and (p_branch is null or (
             exists (select 1 from erp.branches b where b.tenant_id = m.tenant_id and b.branch_id = p_branch)
             and (m.role = 'owner' or m.all_branches or p_branch = any (m.branch_ids)))))
$$;
create or replace function erp.require_cap(p_cap text, p_branch uuid default null) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not erp.can(p_cap, p_branch) then
    perform erp.err('ERP_FORBIDDEN', format('Your role or branch does not allow %s.', p_cap));
  end if;
end $$;
-- An id given by the caller must belong to the caller's tenant (else ERP_TENANT; existence elsewhere is not told).
create or replace function erp.require_branch_of_tenant(p_tenant uuid, p_branch uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_branch is null or not exists (select 1 from erp.branches b where b.tenant_id = p_tenant and b.branch_id = p_branch) then
    perform erp.err('ERP_TENANT', format('Branch %s does not belong to your organisation.', coalesce(p_branch::text, 'null')));
  end if;
end $$;

-- "Today" in the tenant time zone (never now() for document dates, 03 section 3)
create or replace function erp.today(p_tenant uuid) returns date
language sql stable security definer set search_path = '' as $$
  select (now() at time zone coalesce((select s.time_zone from erp.tenant_settings s where s.tenant_id = p_tenant), 'Europe/Athens'))::date
$$;

-- ---------------------------------------------------------------------
-- 5. Plan hooks (02): limits only, unlimited unless tenants.limits names the kind
-- ---------------------------------------------------------------------
create or replace function erp.usage_bump(p_tenant uuid, p_kind text, p_n bigint default 1) returns void
language sql security definer set search_path = '' as $$
  insert into erp.tenant_usage as u (tenant_id, kind, period, used)
  values (p_tenant, p_kind, to_char(erp.today(p_tenant), 'YYYY-MM'), p_n)
  on conflict (tenant_id, kind, period) do update set used = u.used + excluded.used
$$;
create or replace function erp.check_limit(p_tenant uuid, p_kind text) returns void
language plpgsql stable security definer set search_path = '' as $$
declare lim bigint; used bigint;
begin
  select (t.limits ->> p_kind)::bigint into lim from erp.tenants t where t.tenant_id = p_tenant;
  if lim is null then return; end if;
  used := case p_kind
    when 'users'    then (select count(*) from erp.members m where m.tenant_id = p_tenant and m.active)
    when 'branches' then (select count(*) from erp.branches b where b.tenant_id = p_tenant and b.active)
    else coalesce((select u.used from erp.tenant_usage u where u.tenant_id = p_tenant and u.kind = p_kind
                      and u.period = to_char(erp.today(p_tenant), 'YYYY-MM')), 0) end;
  if used >= lim then
    perform erp.err('ERP_LIMIT', format('The plan limit for %s (%s) is reached.', p_kind, lim));
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. Audit (02 "Audit"): every write and state change; old / new hold only the changed keys
-- ---------------------------------------------------------------------
create or replace function erp.audit(p_tenant uuid, p_action text, p_table text, p_row_id text,
                                     p_old jsonb default null, p_new jsonb default null, p_branch uuid default null) returns void
language plpgsql security definer set search_path = '' as $$
declare h jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
        o jsonb := p_old; n jsonb := p_new;
begin
  if p_old is not null and p_new is not null then
    select jsonb_object_agg(k, p_old -> k) filter (where p_old -> k is distinct from p_new -> k),
           jsonb_object_agg(k, p_new -> k) filter (where p_old -> k is distinct from p_new -> k)
      into o, n
      from (select jsonb_object_keys(p_old) k union select jsonb_object_keys(p_new)) keys;
  end if;
  insert into erp.audit_log (tenant_id, member_id, actor, action, table_name, row_id, branch_id, old_row, new_row, request_id, ip)
  values (p_tenant, (erp.current_member()).member_id,
          coalesce(erp.jwt_email(), nullif(current_setting('erp.actor', true), ''), 'system'),
          p_action, p_table, p_row_id, p_branch, o, n,
          nullif(h ->> 'x-request-id', ''), nullif(btrim(split_part(coalesce(h ->> 'x-forwarded-for', ''), ',', 1)), ''));
end $$;

create or replace function erp.alert_raise(p_tenant uuid, p_kind text, p_severity text, p_message_key text, p_params jsonb default '{}',
                                           p_branch uuid default null, p_ref_table text default null, p_ref_id text default null,
                                           p_dedupe_key text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  if p_dedupe_key is not null then
    select a.alert_id into v from erp.alerts a where a.tenant_id = p_tenant and a.dedupe_key = p_dedupe_key and a.resolved_at is null;
    if v is not null then return v; end if;
  end if;
  insert into erp.alerts (tenant_id, branch_id, kind, severity, message_key, params, ref_table, ref_id, dedupe_key)
  values (p_tenant, p_branch, p_kind, p_severity, p_message_key, coalesce(p_params, '{}'), p_ref_table, p_ref_id, p_dedupe_key)
  returning alert_id into v;
  return v;
end $$;

-- ---------------------------------------------------------------------
-- 7. Idempotency (03 section 3): idem_begin returns the stored reply of a repeat (or null), idem_end stores it.
--    The per-key advisory lock makes two concurrent calls with the same key run one after the other.
-- ---------------------------------------------------------------------
create or replace function erp.idem_begin(p_tenant uuid, p_key uuid, p_rpc text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r erp.idempotency_keys;
begin
  if p_key is null then
    perform erp.raise_problems(jsonb_build_array(erp.problem('required', 'p_idempotency_key', 'Every write needs an idempotency key.')));
  end if;
  perform pg_advisory_xact_lock(hashtextextended('erp.idem:' || p_tenant || ':' || p_key, 0));
  select * into r from erp.idempotency_keys k where k.tenant_id = p_tenant and k.idem_key = p_key;
  if not found then return null; end if;
  -- a key replays only for the member that used it (another member never gets someone else's stored reply)
  if r.rpc <> p_rpc or r.request_hash <> md5(p_rpc || ':' || coalesce(p_payload::text, ''))
     or r.member_id is distinct from (erp.current_member()).member_id then
    perform erp.err('ERP_IDEMPOTENT_MISMATCH', format('Idempotency key %s was already used for a different request.', p_key));
  end if;
  return r.result;
end $$;
create or replace function erp.idem_end(p_tenant uuid, p_key uuid, p_rpc text, p_payload jsonb, p_result jsonb) returns jsonb
language sql security definer set search_path = '' as $$
  insert into erp.idempotency_keys (tenant_id, idem_key, rpc, request_hash, result, member_id)
  values (p_tenant, p_key, p_rpc, md5(p_rpc || ':' || coalesce(p_payload::text, '')), p_result, (erp.current_member()).member_id);
  select p_result
$$;

-- ---------------------------------------------------------------------
-- 8. Seeds: roles, capabilities, default matrix (02 "Permissions matrix"), tenant #1
--    Later files add their capabilities and defaults and call erp.role_caps_sync().
-- ---------------------------------------------------------------------
insert into erp.roles (role, sort) values
  ('owner', 10), ('manager', 20), ('warehouse', 30), ('accounting', 40), ('clinic_user', 50), ('readonly', 60)
on conflict (role) do nothing;

insert into erp.capabilities (capability, area, note) values
  ('tenant.settings.read',  'platform', 'read tenant settings'),
  ('tenant.settings.write', 'platform', 'change tenant settings, lock date'),
  ('member.read',           'platform', 'list members and invitations'),
  ('member.manage',         'platform', 'invite, change, deactivate members (E110)'),
  ('branch.read',           'platform', 'list branches'),
  ('branch.write',          'platform', 'create / change branches'),
  ('audit.read',            'platform', 'read the audit log (manager: own branches)'),
  ('alert.read',            'platform', 'read in-app alerts of the visible branches'),
  ('alert.resolve',         'platform', 'resolve alerts')
on conflict (capability) do nothing;

insert into erp.role_cap_defaults (role, capability)
select r, c from (values
  ('owner', 'tenant.settings.read'), ('owner', 'tenant.settings.write'), ('owner', 'member.read'), ('owner', 'member.manage'),
  ('owner', 'branch.read'), ('owner', 'branch.write'), ('owner', 'audit.read'), ('owner', 'alert.read'), ('owner', 'alert.resolve'),
  ('manager', 'tenant.settings.read'), ('manager', 'member.read'), ('manager', 'branch.read'), ('manager', 'audit.read'),
  ('manager', 'alert.read'), ('manager', 'alert.resolve'),
  ('warehouse', 'branch.read'), ('warehouse', 'alert.read'),
  ('accounting', 'tenant.settings.read'), ('accounting', 'member.read'), ('accounting', 'branch.read'), ('accounting', 'audit.read'),
  ('accounting', 'alert.read'),
  ('clinic_user', 'branch.read'), ('clinic_user', 'alert.read'),
  ('readonly', 'branch.read'), ('readonly', 'alert.read')) v(r, c)
on conflict do nothing;

-- copies missing defaults into every tenant (or one); a tenant's allowed = false row is kept
create or replace function erp.role_caps_sync(p_tenant uuid default null) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into erp.role_caps (tenant_id, role, capability, allowed)
  select t.tenant_id, d.role, d.capability, true
    from erp.tenants t cross join erp.role_cap_defaults d
   where p_tenant is null or t.tenant_id = p_tenant
  on conflict (tenant_id, role, capability) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- settings row + matrix for a tenant (used by the seed below and by erp.tenant_onboard in E110)
create or replace function erp.tenant_init(p_tenant uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into erp.tenant_settings (tenant_id) values (p_tenant) on conflict (tenant_id) do nothing;
  perform erp.role_caps_sync(p_tenant);
end $$;

-- tenant #1 = iSmile, set up like any other tenant (its branches and members are typed in the admin screen)
insert into erp.tenants (tenant_id, code, name) values ('00000000-0000-4000-8000-000000000001', 'ismile', 'iSmile')
on conflict do nothing;
do $$ begin perform erp.tenant_init(tenant_id) from erp.tenants; end $$;

-- ---------------------------------------------------------------------
-- 9. Row level security, fast form (02 "RLS"): enabled + forced; helpers inside (select ...); SELECT only.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select c.relname from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'erp' and c.relkind = 'r' loop
    execute format('alter table erp.%I enable row level security', r.relname);
    execute format('alter table erp.%I force row level security', r.relname);
  end loop;
end $$;

drop policy if exists tenants_read on erp.tenants;
create policy tenants_read on erp.tenants for select to authenticated using (tenant_id = any ((select erp.my_tenants())::uuid[]));

drop policy if exists branches_read on erp.branches;
create policy branches_read on erp.branches for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and ((select erp.is_owner()) or branch_id = any ((select erp.my_branches())::uuid[])));

drop policy if exists roles_read on erp.roles;
create policy roles_read on erp.roles for select to authenticated using (true);
drop policy if exists capabilities_read on erp.capabilities;
create policy capabilities_read on erp.capabilities for select to authenticated using (true);
drop policy if exists role_cap_defaults_read on erp.role_cap_defaults;
create policy role_cap_defaults_read on erp.role_cap_defaults for select to authenticated using (true);

drop policy if exists role_caps_read on erp.role_caps;
create policy role_caps_read on erp.role_caps for select to authenticated using (tenant_id = any ((select erp.my_tenants())::uuid[]));

-- members: own row, or every row of the tenant with member.read
drop policy if exists members_read on erp.members;
create policy members_read on erp.members for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (auth_user_id = (select erp.jwt_sub()) or (select erp.can('member.read'))));

-- settings: tenant.settings.read (02 matrix row 1: owner, manager, accounting); whoami gives every member its subset
drop policy if exists tenant_settings_read on erp.tenant_settings;
create policy tenant_settings_read on erp.tenant_settings for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.can('tenant.settings.read')));

drop policy if exists tenant_usage_read on erp.tenant_usage;
create policy tenant_usage_read on erp.tenant_usage for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.is_owner()));

drop policy if exists alerts_read on erp.alerts;
create policy alerts_read on erp.alerts for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.can('alert.read'))
         and ((select erp.is_owner()) or branch_id = any ((select erp.my_branches())::uuid[]) or (branch_id is null and (select erp.sees_all_branches()))));

drop policy if exists audit_log_read on erp.audit_log;
create policy audit_log_read on erp.audit_log for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.can('audit.read'))
         and ((select erp.is_owner()) or branch_id = any ((select erp.my_branches())::uuid[]) or (branch_id is null and (select erp.sees_all_branches()))));

-- secrets / internals: policy present (tenant clause), but no grant at all
drop policy if exists idempotency_keys_none on erp.idempotency_keys;
create policy idempotency_keys_none on erp.idempotency_keys for select to authenticated using (tenant_id = any ((select erp.my_tenants())::uuid[]));

-- grants: SELECT only, through RLS; no insert / update / delete for any API role; internals not granted.
-- authenticated loses only the WRITE privileges on every erp table, so re-running this file keeps the SELECT grants
-- of later files' tables (review F1, finding F1-07); public / anon / service_role lose everything.
do $$ declare r text; begin
  foreach r in array array['public', 'anon', 'authenticated', 'service_role'] loop
    if r = 'public' or exists (select 1 from pg_catalog.pg_roles where rolname = r) then
      execute format(case when r = 'authenticated' then 'revoke insert, update, delete, truncate, references, trigger on all tables in schema erp from %s'
                          else 'revoke all on all tables in schema erp from %s' end, r);
    end if;
  end loop;
end $$;
revoke all on erp.idempotency_keys from authenticated;
grant select on erp.tenants, erp.branches, erp.roles, erp.capabilities, erp.role_cap_defaults, erp.role_caps, erp.members,
                erp.tenant_settings, erp.tenant_usage, erp.alerts, erp.audit_log to authenticated;


-- ---------------------------------------------------------------------
-- 10. RPCs (erp_api): security definer, search_path '', require_member + can first, 8 s statement timeout
-- ---------------------------------------------------------------------
create or replace function erp.branch_json(b erp.branches) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('branch_id', b.branch_id, 'code', b.code, 'name', b.name, 'establishment_no', b.establishment_no,
                            'address', b.address, 'active', b.active, 'updated_at', b.updated_at)
$$;
create or replace function erp.settings_json(s erp.tenant_settings) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('time_zone', s.time_zone, 'valuation_method', s.valuation_method, 'negative_stock', s.negative_stock,
                            'lock_date', s.lock_date, 'thresholds', s.thresholds, 'logo_url', s.logo_url, 'hide_money', s.hide_money,
                            'integration_enabled', s.integration_enabled, 'version', s.version, 'updated_at', s.updated_at)
$$;

-- whoami: who the caller is, its tenant, visible branches, capabilities (the page builds buttons from them)
create or replace function erp_api.whoami() returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; tn erp.tenants; s erp.tenant_settings;
begin
  m := erp.require_member();
  select * into tn from erp.tenants where tenant_id = m.tenant_id;
  select * into s from erp.tenant_settings where tenant_id = m.tenant_id;
  return jsonb_build_object(
    'member_id', m.member_id, 'email', m.email, 'display_name', m.display_name, 'role', m.role, 'all_branches', m.all_branches or m.role = 'owner',
    'tenant', jsonb_build_object('tenant_id', tn.tenant_id, 'code', tn.code, 'name', tn.name, 'plan', tn.plan),
    'branches', coalesce((select jsonb_agg(erp.branch_json(b) order by b.code) from erp.branches b
                           where b.tenant_id = m.tenant_id and b.active and b.branch_id = any (erp.my_branches())), '[]'::jsonb),
    'caps', coalesce((select jsonb_agg(rc.capability order by rc.capability) from erp.role_caps rc
                       where rc.tenant_id = m.tenant_id and rc.role = m.role and rc.allowed), '[]'::jsonb),
    'settings', jsonb_build_object('time_zone', s.time_zone, 'valuation_method', s.valuation_method, 'negative_stock', s.negative_stock,
                                   'lock_date', s.lock_date, 'hide_money', s.hide_money),
    'today', erp.today(m.tenant_id));
end $$;

-- branch_list: visible branches, keyset by (code, branch_id); cursor = {"code", "branch_id"} from the previous reply
create or replace function erp_api.branch_list(p_include_inactive boolean default false, p_cursor jsonb default null, p_limit int default 100)
returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 100), 1), 500); rows jsonb; n int;
begin
  m := erp.require_member();
  perform erp.require_cap('branch.read');
  with page as (
    select b as r from erp.branches b
     where b.tenant_id = m.tenant_id and b.branch_id = any (erp.my_branches())
       and (p_include_inactive or b.active)
       and (p_cursor is null or (lower(b.code), b.branch_id) > (lower(p_cursor ->> 'code'), (p_cursor ->> 'branch_id')::uuid))
     order by lower(b.code), b.branch_id limit lim + 1)
  select jsonb_agg(erp.branch_json(page.r) order by lower((page.r).code), (page.r).branch_id), count(*) into rows, n from page;
  rows := coalesce(rows, '[]'::jsonb);
  if n > lim then
    rows := rows - lim;
    return jsonb_build_object('rows', rows, 'next', jsonb_build_object('code', rows -> (lim - 1) ->> 'code', 'branch_id', rows -> (lim - 1) ->> 'branch_id'));
  end if;
  return jsonb_build_object('rows', rows, 'next', null);
end $$;

-- branch_save: create (no branch_id) or change a branch. Fields: code, name, establishment_no, address, active.
create or replace function erp_api.branch_save(p_branch jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; old erp.branches; b erp.branches; id uuid; probs jsonb := '[]'; res jsonb;
        f_code text; f_name text; f_estab int; f_addr text; f_active boolean;
begin
  m := erp.require_member();
  perform erp.require_cap('branch.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'branch_save', p_branch);
  if prev is not null then return prev; end if;
  if p_branch is null or jsonb_typeof(p_branch) <> 'object' then p_branch := '{}'; end if;
  if p_branch ? 'branch_id' and nullif(p_branch ->> 'branch_id', '') is not null then
    if (p_branch ->> 'branch_id') !~* '^[0-9a-f-]{36}$' then perform erp.err('ERP_TENANT', 'Branch id is not valid.'); end if;
    id := (p_branch ->> 'branch_id')::uuid;
    perform erp.require_branch_of_tenant(m.tenant_id, id);
    perform erp.require_cap('branch.write', id);   -- a non-owner given branch.write changes only its own branches
    select * into old from erp.branches where tenant_id = m.tenant_id and branch_id = id for update;
  end if;
  f_code   := btrim(coalesce(p_branch ->> 'code', old.code, ''));
  f_name   := btrim(coalesce(p_branch ->> 'name', old.name, ''));
  f_addr   := case when p_branch ? 'address' then nullif(btrim(p_branch ->> 'address'), '') else old.address end;
  f_active := coalesce((p_branch ->> 'active')::boolean, old.active, true);
  if p_branch ? 'establishment_no' then
    if nullif(p_branch ->> 'establishment_no', '') is null then f_estab := null;
    elsif (p_branch ->> 'establishment_no') !~ '^[0-9]{1,5}$' then
      probs := probs || erp.problem('invalid', 'establishment_no', 'Establishment number must be a whole number 0-99999.');
    else f_estab := (p_branch ->> 'establishment_no')::int; end if;
  else f_estab := old.establishment_no; end if;
  if f_code = '' then probs := probs || erp.problem('required', 'code', 'Code is required.');
  elsif f_code !~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,19}$' then probs := probs || erp.problem('invalid', 'code', 'Code: letters, digits, - or _, up to 20.');
  elsif exists (select 1 from erp.branches x where x.tenant_id = m.tenant_id and lower(x.code) = lower(f_code) and x.branch_id is distinct from id) then
    probs := probs || erp.problem('duplicate', 'code', format('Code %s is already used.', f_code)); end if;
  if f_name = '' then probs := probs || erp.problem('required', 'name', 'Name is required.'); end if;
  if f_estab is not null and exists (select 1 from erp.branches x where x.tenant_id = m.tenant_id and x.establishment_no = f_estab and x.branch_id is distinct from id) then
    probs := probs || erp.problem('duplicate', 'establishment_no', format('Establishment number %s is already used.', f_estab)); end if;
  perform erp.raise_problems(probs);
  if id is null then
    perform erp.check_limit(m.tenant_id, 'branches');
    insert into erp.branches (tenant_id, code, name, establishment_no, address, active)
    values (m.tenant_id, f_code, f_name, f_estab, f_addr, f_active) returning * into b;
    perform erp.usage_bump(m.tenant_id, 'branches.created');
    perform erp.audit(m.tenant_id, 'branch.create', 'branches', b.branch_id::text, null, erp.branch_json(b), b.branch_id);
  else
    update erp.branches set code = f_code, name = f_name, establishment_no = f_estab, address = f_addr, active = f_active, updated_at = now()
     where tenant_id = m.tenant_id and branch_id = id returning * into b;
    perform erp.audit(m.tenant_id, 'branch.update', 'branches', b.branch_id::text, erp.branch_json(old), erp.branch_json(b), b.branch_id);
  end if;
  res := erp.branch_json(b);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'branch_save', p_branch, res);
end $$;

create or replace function erp_api.settings_get() returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; s erp.tenant_settings;
begin
  m := erp.require_member();
  perform erp.require_cap('tenant.settings.read');
  select * into s from erp.tenant_settings where tenant_id = m.tenant_id;
  return erp.settings_json(s) || jsonb_build_object('can_write', erp.can('tenant.settings.write'));
end $$;

-- settings_save: owner. Keys: version (required, optimistic lock), time_zone, negative_stock, lock_date, hide_money,
-- logo_url, thresholds. valuation_method and integration_enabled are NOT changed here (valuation switch T39, phase IP).
create or replace function erp_api.settings_save(p_settings jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; old erp.tenant_settings; s erp.tenant_settings; probs jsonb := '[]'; k text; res jsonb;
        v_tz text; v_neg text; v_lock date; v_hide boolean; v_logo text; v_thr jsonb;
begin
  m := erp.require_member();
  perform erp.require_cap('tenant.settings.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'settings_save', p_settings);
  if prev is not null then return prev; end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then p_settings := '{}'; end if;
  select * into old from erp.tenant_settings where tenant_id = m.tenant_id for update;
  for k in select jsonb_object_keys(p_settings) loop
    if k not in ('version', 'time_zone', 'negative_stock', 'lock_date', 'hide_money', 'logo_url', 'thresholds') then
      probs := probs || erp.problem('not_editable', k, format('%s cannot be changed here.', k));
    end if;
  end loop;
  if (p_settings ->> 'version') is null or (p_settings ->> 'version') !~ '^[0-9]+$' then
    probs := probs || erp.problem('required', 'version', 'The version read with settings_get is required.');
  elsif (p_settings ->> 'version')::int <> old.version then
    perform erp.err('ERP_CONFLICT', format('Settings were changed by someone else (version %s, yours %s).', old.version, p_settings ->> 'version'));
  end if;
  v_tz := coalesce(p_settings ->> 'time_zone', old.time_zone);
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_tz) then
    probs := probs || erp.problem('invalid', 'time_zone', format('Unknown time zone %s.', v_tz)); end if;
  v_neg := coalesce(p_settings ->> 'negative_stock', old.negative_stock);
  if v_neg not in ('warn', 'block') then probs := probs || erp.problem('invalid', 'negative_stock', 'Negative stock: warn or block.'); end if;
  v_lock := old.lock_date;
  if p_settings ? 'lock_date' then
    if nullif(p_settings ->> 'lock_date', '') is null then v_lock := null;
    elsif (p_settings ->> 'lock_date') !~ '^\d{4}-\d{2}-\d{2}$' then probs := probs || erp.problem('invalid', 'lock_date', 'Lock date must be yyyy-mm-dd.');
    else
      begin v_lock := (p_settings ->> 'lock_date')::date;
      exception when others then probs := probs || erp.problem('invalid', 'lock_date', 'Lock date is not a real date.'); end;
      if v_lock > erp.today(m.tenant_id) then probs := probs || erp.problem('invalid', 'lock_date', 'Lock date cannot be in the future.'); end if;
    end if;
  end if;
  v_hide := old.hide_money;
  if p_settings ? 'hide_money' then
    if jsonb_typeof(p_settings -> 'hide_money') <> 'boolean' then probs := probs || erp.problem('invalid', 'hide_money', 'hide_money must be true or false.');
    else v_hide := (p_settings ->> 'hide_money')::boolean; end if;
  end if;
  v_logo := case when p_settings ? 'logo_url' then nullif(btrim(p_settings ->> 'logo_url'), '') else old.logo_url end;
  if v_logo is not null and v_logo !~ '^https://[^[:space:]]+$' then probs := probs || erp.problem('invalid', 'logo_url', 'Logo URL must start with https://.'); end if;
  v_thr := old.thresholds;
  if p_settings ? 'thresholds' then
    if jsonb_typeof(p_settings -> 'thresholds') <> 'object' then probs := probs || erp.problem('invalid', 'thresholds', 'thresholds must be an object.');
    elsif exists (select 1 from jsonb_each(p_settings -> 'thresholds') e where jsonb_typeof(e.value) <> 'number' or (e.value)::numeric < 0) then
      probs := probs || erp.problem('invalid', 'thresholds', 'Every threshold must be a number >= 0.');
    else v_thr := p_settings -> 'thresholds'; end if;
  end if;
  perform erp.raise_problems(probs);
  update erp.tenant_settings set time_zone = v_tz, negative_stock = v_neg, lock_date = v_lock, hide_money = v_hide, logo_url = v_logo,
         thresholds = v_thr, version = version + 1, updated_at = now()
   where tenant_id = m.tenant_id returning * into s;
  perform erp.audit(m.tenant_id, 'settings.update', 'tenant_settings', m.tenant_id::text,
                    erp.settings_json(old) - 'updated_at', erp.settings_json(s) - 'updated_at');
  res := erp.settings_json(s) || jsonb_build_object('can_write', true);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'settings_save', p_settings, res);
end $$;

-- audit_list: newest first, keyset by audit_id. Filter keys: action (prefix), table_name, row_id. Manager sees its
-- branches only, tenant-wide rows (no branch) only for owner / all-branches members (same rule as the policy).
create or replace function erp_api.audit_list(p_filter jsonb default '{}', p_cursor jsonb default null, p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 50), 1), 200); rows jsonb; n int;
        own boolean := erp.is_owner(); allb boolean := erp.sees_all_branches(); br uuid[] := erp.my_branches();
begin
  m := erp.require_member();
  perform erp.require_cap('audit.read');
  p_filter := coalesce(p_filter, '{}');
  with page as (
    select a.* from erp.audit_log a
     where a.tenant_id = m.tenant_id
       and (own or a.branch_id = any (br) or (a.branch_id is null and allb))
       and (p_filter ->> 'action' is null or a.action like (p_filter ->> 'action') || '%')
       and (p_filter ->> 'table_name' is null or a.table_name = p_filter ->> 'table_name')
       and (p_filter ->> 'row_id' is null or a.row_id = p_filter ->> 'row_id')
       and (p_cursor is null or a.audit_id < (p_cursor ->> 'audit_id')::bigint)
     order by a.audit_id desc limit lim + 1)
  select jsonb_agg(jsonb_build_object('audit_id', p.audit_id, 'at', p.at, 'actor', p.actor, 'action', p.action, 'table_name', p.table_name,
                                      'row_id', p.row_id, 'branch_id', p.branch_id, 'old', p.old_row, 'new', p.new_row) order by p.audit_id desc),
         count(*) into rows, n from page p;
  rows := coalesce(rows, '[]'::jsonb);
  if n > lim then
    rows := rows - lim;
    return jsonb_build_object('rows', rows, 'next', jsonb_build_object('audit_id', rows -> (lim - 1) -> 'audit_id'));
  end if;
  return jsonb_build_object('rows', rows, 'next', null);
end $$;

-- alert_list (T14): open alerts (or all with include_resolved) of the visible branches, newest first; tenant-wide
-- alerts (no branch) only for owner / all-branches members (same rule as the policy). Filter kind, branch_id.
-- next = {created_at, alert_id}.
create or replace function erp_api.alert_list(p_filter jsonb default '{}', p_cursor jsonb default null, p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 50), 1), 200); rows jsonb; n int; own boolean := erp.is_owner(); allb boolean := erp.sees_all_branches();
        br uuid[] := erp.my_branches();
begin
  m := erp.require_member();
  perform erp.require_cap('alert.read');
  p_filter := coalesce(p_filter, '{}');
  with page as (
    select a.* from erp.alerts a
     where a.tenant_id = m.tenant_id
       and (own or a.branch_id = any (br) or (a.branch_id is null and allb))
       and (coalesce((p_filter ->> 'include_resolved')::boolean, false) or a.resolved_at is null)
       and (p_filter ->> 'kind' is null or a.kind = p_filter ->> 'kind')
       and (p_filter ->> 'branch_id' is null or a.branch_id::text = p_filter ->> 'branch_id')
       and (p_cursor is null or (a.created_at, a.alert_id) < ((p_cursor ->> 'created_at')::timestamptz, (p_cursor ->> 'alert_id')::uuid))
     order by a.created_at desc, a.alert_id desc limit lim + 1)
  select jsonb_agg(jsonb_build_object('alert_id', p.alert_id, 'branch_id', p.branch_id, 'kind', p.kind, 'severity', p.severity, 'message_key', p.message_key,
                                      'params', p.params, 'created_at', p.created_at, 'resolved_at', p.resolved_at,
                                      'can_resolve', p.resolved_at is null and erp.can('alert.resolve', p.branch_id))
                   order by p.created_at desc, p.alert_id desc), count(*) into rows, n from page p;
  rows := coalesce(rows, '[]'::jsonb);
  if n > lim then
    rows := rows - lim;
    return jsonb_build_object('rows', rows, 'next', jsonb_build_object('created_at', rows -> (lim - 1) ->> 'created_at', 'alert_id', rows -> (lim - 1) ->> 'alert_id'));
  end if;
  return jsonb_build_object('rows', rows, 'next', null);
end $$;

-- alert_resolve: mark one alert resolved (alert.resolve on its branch; a tenant-wide alert: owner / all branches)
create or replace function erp_api.alert_resolve(p_alert_id uuid, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; a erp.alerts; res jsonb;
begin
  m := erp.require_member();
  perform erp.require_cap('alert.resolve');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'alert_resolve', to_jsonb(p_alert_id));
  if prev is not null then return prev; end if;
  select * into a from erp.alerts where tenant_id = m.tenant_id and alert_id = p_alert_id for update;
  if a.alert_id is null then perform erp.err('ERP_TENANT', format('Alert %s does not belong to your organisation.', coalesce(p_alert_id::text, 'null'))); end if;
  if (a.branch_id is null and not erp.sees_all_branches()) or (a.branch_id is not null and not erp.can('alert.resolve', a.branch_id)) then
    perform erp.err('ERP_FORBIDDEN', 'Your role or branch does not allow resolving this alert.');
  end if;
  update erp.alerts set resolved_at = coalesce(resolved_at, now()), resolved_by = coalesce(resolved_by, m.member_id) where tenant_id = m.tenant_id and alert_id = p_alert_id
  returning * into a;
  perform erp.audit(m.tenant_id, 'alert.resolve', 'alerts', a.alert_id::text, null, jsonb_build_object('kind', a.kind), a.branch_id);
  res := jsonb_build_object('alert_id', a.alert_id, 'resolved_at', a.resolved_at);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'alert_resolve', to_jsonb(p_alert_id), res);
end $$;

-- ---------------------------------------------------------------------
-- 11. Function grants. EVERY E file ends with `select erp.lock_down();` and then grants ITS OWN erp_api functions to
--     authenticated. lock_down closes every internal erp function and sequence to the API roles (re-opening only
--     the policy helpers) and closes every erp_api function to public / anon / service_role; it never touches the
--     authenticated grants of erp_api, so re-running one file does not remove another file's grants.
-- ---------------------------------------------------------------------
create or replace function erp.lock_down() returns void
language plpgsql security definer set search_path = '' as $$
declare r text;
begin
  foreach r in array array['public', 'anon', 'authenticated', 'service_role'] loop
    if r = 'public' or exists (select 1 from pg_catalog.pg_roles where rolname = r) then
      execute format('revoke all on all functions in schema erp from %s', r);
      execute format('revoke all on all sequences in schema erp from %s', r);
      if r <> 'authenticated' then execute format('revoke all on all functions in schema erp_api from %s', r); end if;
    end if;
  end loop;
  grant execute on function erp.my_tenants(), erp.my_branches(), erp.is_owner(), erp.sees_all_branches(), erp.jwt_sub(),
                            erp.jwt_claims(), erp.can(text, uuid) to authenticated;
end $$;
select erp.lock_down();
grant execute on function erp_api.whoami(), erp_api.branch_list(boolean, jsonb, int), erp_api.branch_save(jsonb, uuid),
                          erp_api.settings_get(), erp_api.settings_save(jsonb, uuid), erp_api.audit_list(jsonb, jsonb, int),
                          erp_api.alert_list(jsonb, jsonb, int), erp_api.alert_resolve(uuid, uuid) to authenticated;
