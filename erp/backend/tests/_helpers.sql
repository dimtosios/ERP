-- Shared test helpers for the ERP suites (included with \ir by each suite, inside its transaction; CRM pattern:
-- t.passes + a final count, everything rolled back). Not a suite itself (the runner only runs E*_tests.sql).
create schema t;
grant usage on schema t to authenticated;
create table t.passes (label text);
create function t.pass(label text) returns void language sql security definer as $$ insert into t.passes values (label); $$;
create function t.ok(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'FAIL: %', label; end if;
  perform t.pass(label); raise notice 'PASS: %', label;
end $$;
-- the statement must fail and its message must start with p_code (e.g. 'ERP_FORBIDDEN'); '' = any error
create function t.fails(sql text, p_code text, label text) returns void language plpgsql as $$
declare failed boolean := false; msg text;
begin
  begin execute sql; exception when others then failed := true; msg := sqlerrm; end;
  if not failed then raise exception 'FAIL (no error raised): %', label; end if;
  if p_code <> '' and msg not like p_code || '%' then raise exception 'FAIL (wrong error "%", wanted %): %', msg, p_code, label; end if;
  perform t.pass(label); raise notice 'PASS: % [%]', label, replace(msg, E'\n', ' | ');
end $$;
-- run a statement and return the detail of its error (ERP_VALIDATION problem array), null when it succeeds
create function t.problems(sql text) returns jsonb language plpgsql as $$
declare d text;
begin
  begin execute sql; exception when others then get stacked diagnostics d = pg_exception_detail; return nullif(d, '')::jsonb; end;
  return null;
end $$;
-- run a statement as a check that it SUCCEEDS, then undo it (subtransaction), so a role matrix loop leaves no trace
create function t.try(sql text) returns text language plpgsql as $$
begin
  begin execute sql; raise exception 'T_ROLLBACK_OK'; exception when others then
    if sqlerrm = 'T_ROLLBACK_OK' then return 'ok'; end if; return sqlerrm; end;
end $$;
create function t.affected(sql text) returns bigint language plpgsql as $$
declare n bigint; begin execute sql; get diagnostics n = row_count; return n; end $$;
create function t.login(p_sub uuid, p_email text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_sub, 'email', p_email, 'role', 'authenticated')::text, true);
$$;
create function t.logout() returns void language sql as $$ select set_config('request.jwt.claims', '', true); $$;
create table t.r (j jsonb);
create function t.keep(p jsonb) returns void language sql security definer as $$ delete from t.r; insert into t.r values (p); $$;
create function t.j() returns jsonb language sql security definer as $$ select j from t.r $$;
-- fixtures (superuser, no RLS)
create function t.sub(p int) returns uuid language sql immutable as $$ select ('00000000-0000-4000-a000-' || lpad(p::text, 12, '0'))::uuid $$;
create function t.tenant(p_code text) returns uuid language sql security definer as $$
  with ins as (insert into erp.tenants (code, name) values (p_code, 'Test ' || p_code) on conflict do nothing returning tenant_id)
  select coalesce((select tenant_id from ins), (select tenant_id from erp.tenants where code = p_code)) $$;
create function t.init(p_tenant uuid) returns void language sql security definer as $$ select erp.tenant_init(p_tenant) $$;
create function t.branch(p_tenant uuid, p_code text, p_estab int default null) returns uuid language sql security definer as $$
  insert into erp.branches (tenant_id, code, name, establishment_no) values (p_tenant, p_code, 'Branch ' || p_code, p_estab) returning branch_id $$;
create function t.br(p_tenant uuid, p_code text) returns uuid language sql security definer as $$
  select branch_id from erp.branches where tenant_id = p_tenant and code = p_code $$;
-- bound member (auth_user_id = sub); p_bound false = invitation only
create function t.member(p_tenant uuid, p_n int, p_role text, p_branches uuid[] default '{}', p_all boolean default false, p_bound boolean default true)
returns uuid language sql security definer as $$
  insert into erp.members (tenant_id, email, role, branch_ids, all_branches, auth_user_id, bound_at)
  values (p_tenant, 'user' || p_n || '@erp.test', p_role, p_branches, p_all, case when p_bound then t.sub(p_n) end, case when p_bound then now() end)
  returning member_id $$;
create function t.as(p_n int) returns void language sql as $$ select t.login(t.sub(p_n), 'user' || p_n || '@erp.test') $$;
create function t.count(p_sql text) returns bigint language plpgsql security definer as $$
declare n bigint; begin execute 'select count(*) from (' || p_sql || ') x' into n; return n; end $$;
grant execute on all functions in schema t to authenticated;
grant select, insert, delete on t.r to authenticated;
