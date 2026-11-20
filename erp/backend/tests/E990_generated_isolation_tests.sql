-- =====================================================================
-- iSmile ERP  -  GENERATED tenancy / role suite over ALL E files (03 section 5 "Tenancy" and "Roles").
-- Built from the catalog, so a new table or erp_api function without coverage FAILS here:
--   tables : RLS enabled + forced, a policy, tenant_id first in the primary key (or a platform catalog), a fixture
--            row of tenant B, and members of tenant A in every role read 0 rows of tenant B;
--   rpcs   : every erp_api function has a case below (t.rpc); a non-member gets ERP_AUTH; tenant-B ids raise
--            ERP_TENANT or the reply holds nothing of B; role matrix = erp.role_caps x RPC (allowed -> ok, else
--            ERP_FORBIDDEN); security definer, search_path '', statement_timeout, granted to authenticated only;
--   erp.*  : no internal function executable by authenticated except the policy helpers.
-- One transaction, ROLLED BACK. Last line: ALL TESTS PASSED + number of checks.
-- =====================================================================
begin;
\ir _helpers.sql

-- ---------- fixtures: tenants A and B, every role in A, rows of B in every tenant table ----------
create table t.ids (a uuid, b uuid);
insert into t.ids select t.tenant('isoa'), t.tenant('isob');
create function t.a() returns uuid language sql security definer as $$ select a from t.ids $$;
create function t.b() returns uuid language sql security definer as $$ select b from t.ids $$;
select t.init(t.a()), t.init(t.b());
select t.branch(t.a(), 'A1', 0), t.branch(t.a(), 'A2', 1), t.branch(t.b(), 'B1', 0), t.branch(t.b(), 'B2', 1);
select t.member(t.a(), 21, 'owner'), t.member(t.a(), 22, 'manager', array[t.br(t.a(), 'A1')]), t.member(t.a(), 23, 'warehouse', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 24, 'accounting', '{}', true), t.member(t.a(), 25, 'clinic_user', array[t.br(t.a(), 'A1')]), t.member(t.a(), 26, 'readonly', array[t.br(t.a(), 'A1')]),
       t.member(t.b(), 31, 'owner'), t.member(t.b(), 32, 'manager', array[t.br(t.b(), 'B1')]), t.member(t.b(), 33, 'readonly', '{}', false, false);
create table t.role_login (role text, n int);
insert into t.role_login values ('owner', 21), ('manager', 22), ('warehouse', 23), ('accounting', 24), ('clinic_user', 25), ('readonly', 26);
-- E130 (T09): a TEST document type ZISO (no stock) so the document RPCs have a type in every role / tenant
do $do$ begin
  if to_regclass('erp.documents') is not null then
    insert into erp.doc_types (doc_type, name, area, cap_prefix, sort, enabled, price_kind) values ('ZISO', 'Isolation test', 'warehouse', 'ziso', 999, true, 'cost');
    insert into erp.doc_transitions (doc_type, from_state, to_state, cap, action, label) values ('ZISO', 'draft', 'posted', 'create', 'post', 'doc.action.post'),
      ('ZISO', 'posted', 'cancelled', 'approve', 'cancel', 'doc.action.cancel');
    insert into erp.capabilities (capability, area) values ('doc.ziso.read', 'test'), ('doc.ziso.create', 'test'), ('doc.ziso.approve', 'test');
    insert into erp.role_cap_defaults (role, capability) select r, c from (values ('owner', 'doc.ziso.read'), ('owner', 'doc.ziso.create'), ('owner', 'doc.ziso.approve'),
      ('manager', 'doc.ziso.read'), ('manager', 'doc.ziso.create'), ('manager', 'doc.ziso.approve'), ('warehouse', 'doc.ziso.read'), ('warehouse', 'doc.ziso.create'),
      ('accounting', 'doc.ziso.read'), ('readonly', 'doc.ziso.read')) v(r, c);
    perform erp.role_caps_sync();
    insert into erp.series (tenant_id, branch_id, doc_type, code) select tenant_id, branch_id, 'ZISO', 'ZI-' || code from erp.branches where tenant_id in (t.a(), t.b());
  end if;
  if to_regclass('erp.doc_conversions') is not null then   -- E135 (T44): a target type ZIST and the pair ZISO -> ZIST
    insert into erp.doc_types (doc_type, name, area, cap_prefix, sort, enabled, price_kind) values ('ZIST', 'Isolation target', 'warehouse', 'ziso', 995, true, 'cost');
    insert into erp.doc_conversions (source_type, target_type, kind) values ('ZISO', 'ZIST', 'bill');
  end if;
  if to_regclass('erp.stock_moves') is not null then   -- E140 (T10): stock test types ZSIN / ZSOUT
    insert into erp.doc_types (doc_type, name, area, cap_prefix, sort, enabled, stock_sign, cost_rule, needs_warehouse, price_kind) values
      ('ZSIN', 'Isolation stock in', 'warehouse', 'ziso', 997, true, 1, 'line', true, 'cost'), ('ZSOUT', 'Isolation stock out', 'warehouse', 'ziso', 996, true, -1, 'issue', true, 'none');
    insert into erp.doc_transitions (doc_type, from_state, to_state, cap, action, label) values ('ZSIN', 'draft', 'posted', 'create', 'post', 'x'), ('ZSOUT', 'draft', 'posted', 'create', 'post', 'x');
    insert into erp.series (tenant_id, branch_id, doc_type, code) select tenant_id, branch_id, d, d || '-' || code from erp.branches, unnest(array['ZSIN', 'ZSOUT']) d
     where tenant_id in (t.a(), t.b());
  end if;
end $do$;
-- B writes through its own RPCs (audit_log, idempotency_keys, tenant_usage get B rows), alerts by the internal raiser
set local role authenticated;
select t.as(31);
select erp_api.branch_save('{"code": "B3", "name": "B third"}', gen_random_uuid()) is not null;
select erp_api.settings_save(jsonb_build_object('version', (select version from erp.tenant_settings), 'hide_money', true), gen_random_uuid()) is not null;
reset role;
select erp.alert_raise(t.b(), 'test', 'info', 'alert.test', '{}', t.br(t.b(), 'B1')) is not null, erp.alert_raise(t.b(), 'test', 'info', 'alert.test') is not null,
       erp.alert_raise(t.a(), 'test', 'info', 'alert.test', '{}', t.br(t.a(), 'A1')) is not null;
-- later files: add the fixture rows of their own tables for tenant B here (the coverage check below requires them)
-- E120 part 1 (T05): a category, an item with a barcode (units / VAT classes come from the tenant trigger)
set local role authenticated;
select t.as(31);
do $do$ begin
  if to_regprocedure('erp_api.item_save(jsonb,uuid)') is not null then
    perform erp_api.category_save('{"code": "BCAT", "name": "B category"}', gen_random_uuid());
    perform erp_api.item_save(jsonb_build_object('code', 'BITEM', 'name', 'B item', 'base_unit_id', (select unit_id from erp.units where code = 'PCS'),
                                                 'category_id', (select category_id from erp.item_categories where code = 'BCAT'), 'barcodes', jsonb_build_array('B-0001')), gen_random_uuid());
  end if;
  if to_regprocedure('erp_api.series_save(jsonb,uuid)') is not null then   -- E120 part 2 (T06)
    perform erp_api.warehouse_save(jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'B1'), 'code', 'BW1', 'name', 'B main'), gen_random_uuid());
    perform erp_api.counterparty_save('{"name": "B supplier", "code": "BCP"}', gen_random_uuid());
    perform erp_api.series_save(jsonb_build_object('doc_type', 'GRN', 'branch_id', (select branch_id from erp.branches where code = 'B1'), 'code', 'GRN-B1'), gen_random_uuid());
  end if;
  if to_regprocedure('erp_api.doc_save_draft(text,jsonb,uuid)') is not null then   -- E130 (T09)
    perform erp_api.doc_set_state((erp_api.doc_save_draft('ZISO', jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'B1'),
      'lines', jsonb_build_array(jsonb_build_object('item_id', (select item_id from erp.items where code = 'BITEM'), 'qty', 1, 'unit_price', 2))), gen_random_uuid()) ->> 'document_id')::uuid,
      'posted', '{}', gen_random_uuid());
  end if;
  if to_regprocedure('erp_api.doc_convert(uuid[],text,jsonb,uuid)') is not null then   -- E135: B converts its posted ZISO (document_links)
    perform erp_api.doc_convert(array[(select document_id from erp.documents where doc_type = 'ZISO' and state = 'posted' limit 1)], 'ZIST', null, gen_random_uuid());
  end if;
  if to_regclass('erp.stock_moves') is not null then   -- E140: one receipt and one issue of B (moves, balances, costs, layers, consumption)
    perform erp_api.doc_set_state((erp_api.doc_save_draft(d, jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'B1'),
      'warehouse_id', (select warehouse_id from erp.warehouses where code = 'BW1'),
      'lines', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('item_id', (select item_id from erp.items where code = 'BITEM'), 'qty', q, 'unit_price', c)))), gen_random_uuid()) ->> 'document_id')::uuid,
      'posted', '{}', gen_random_uuid())
      from (values ('ZSIN', 5, 2), ('ZSOUT', 2, null)) v(d, q, c);
    -- T13: a backdated receipt (cost_revisions of the issue), then one more with the inline limit 0 (recost_queue)
    perform erp_api.doc_set_state((erp_api.doc_save_draft('ZSIN', jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'B1'),
      'warehouse_id', (select warehouse_id from erp.warehouses where code = 'BW1'), 'doc_date', current_date - 3,
      'lines', jsonb_build_array(jsonb_build_object('item_id', (select item_id from erp.items where code = 'BITEM'), 'qty', 5, 'unit_price', 4))), gen_random_uuid()) ->> 'document_id')::uuid,
      'posted', '{}', gen_random_uuid());
    perform set_config('erp.recost_inline_limit', '0', true);
    perform erp_api.doc_set_state((erp_api.doc_save_draft('ZSIN', jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'B1'),
      'warehouse_id', (select warehouse_id from erp.warehouses where code = 'BW1'), 'doc_date', current_date - 4,
      'lines', jsonb_build_array(jsonb_build_object('item_id', (select item_id from erp.items where code = 'BITEM'), 'qty', 1, 'unit_price', 9))), gen_random_uuid()) ->> 'document_id')::uuid,
      'posted', '{}', gen_random_uuid());
    perform set_config('erp.recost_inline_limit', '', true);
  end if;
  if to_regprocedure('erp_api.trf_get(uuid)') is not null then   -- E160 (T16): B dispatches a transfer and receives it short (doc_trf, doc_trf_lines)
    perform erp_api.warehouse_save(jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'B2'), 'code', 'BW2', 'name', 'B second'), gen_random_uuid());
    perform erp_api.series_save(jsonb_build_object('doc_type', 'TRF', 'branch_id', (select branch_id from erp.branches where code = 'B1'), 'code', 'TRF-B1', 'gapless', true), gen_random_uuid());
    perform erp_api.doc_set_state((erp_api.doc_save_draft('TRF', jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'B1'),
      'warehouse_id', (select warehouse_id from erp.warehouses where code = 'BW1'), 'dest_warehouse_id', (select warehouse_id from erp.warehouses where code = 'BW2'), 'notes', 'B transfer',
      'lines', jsonb_build_array(jsonb_build_object('item_id', (select item_id from erp.items where code = 'BITEM'), 'qty', 2))), gen_random_uuid()) ->> 'document_id')::uuid,
      'dispatched', '{"ack_warnings": true}', gen_random_uuid());
    perform erp_api.doc_set_state((select document_id from erp.documents where notes = 'B transfer'), 'received_with_difference',
      jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('line_id', (select line_id from erp.document_lines l join erp.documents d using (tenant_id, document_id) where d.notes = 'B transfer'),
                                                                     'received_qty', 1, 'reason', 'short'))), gen_random_uuid());
  end if;
  if to_regprocedure('erp_api.attachment_add(jsonb,uuid)') is not null then   -- E190 (Draft 1): a file of B1, then a GRN draft from it (attachments)
    perform erp_api.grn_draft_from_extraction('{"extractor": "iso", "lines": [{"description": "B item", "qty": 1, "unit_price": 1, "confidence": 1}]}',
      (erp_api.attachment_add(jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'B1'), 'filename', 'b note.pdf',
         'content_base64', encode('\x255044462d312e340a78787878'::bytea, 'base64')), gen_random_uuid()) ->> 'attachment_id')::uuid,
      (select warehouse_id from erp.warehouses where code = 'BW1'), 'iso:b:dn:0001');
  end if;
end $do$;
reset role;

set local role authenticated;
select t.as(21);
do $do$ begin
  if to_regprocedure('erp_api.item_save(jsonb,uuid)') is not null then
    perform erp_api.item_save(jsonb_build_object('code', 'AITEM', 'name', 'A item', 'base_unit_id', (select unit_id from erp.units where code = 'PCS')), gen_random_uuid());
  end if;
  if to_regprocedure('erp_api.series_save(jsonb,uuid)') is not null then
    perform erp_api.counterparty_save('{"name": "A supplier", "code": "ACP"}', gen_random_uuid());
    perform erp_api.series_save(jsonb_build_object('doc_type', 'GRN', 'branch_id', (select branch_id from erp.branches where code = 'A1'), 'code', 'GRN-A1'), gen_random_uuid());
  end if;
  if to_regprocedure('erp_api.doc_save_draft(text,jsonb,uuid)') is not null then
    perform erp_api.warehouse_save(jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'A1'), 'code', 'AW1', 'name', 'A main'), gen_random_uuid());
    perform erp_api.doc_save_draft('ZISO', jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'A1'), 'notes', 'A draft',
      'lines', jsonb_build_array(jsonb_build_object('item_id', (select item_id from erp.items where code = 'AITEM'), 'qty', 1, 'unit_price', 2))), gen_random_uuid());
    perform erp_api.doc_set_state((erp_api.doc_save_draft('ZISO', jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'A1'), 'notes', 'A posted',
      'lines', jsonb_build_array(jsonb_build_object('item_id', (select item_id from erp.items where code = 'AITEM'), 'qty', 1, 'unit_price', 2))), gen_random_uuid()) ->> 'document_id')::uuid,
      'posted', '{}', gen_random_uuid());
  end if;
  if to_regprocedure('erp_api.trf_get(uuid)') is not null then   -- E160: a TRF draft of A1 (read by the source branch's roles)
    perform erp_api.warehouse_save(jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'A2'), 'code', 'AW2', 'name', 'A second'), gen_random_uuid());
    perform erp_api.doc_save_draft('TRF', jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'A1'), 'notes', 'A transfer',
      'warehouse_id', (select warehouse_id from erp.warehouses where code = 'AW1'), 'dest_warehouse_id', (select warehouse_id from erp.warehouses where code = 'AW2'),
      'lines', jsonb_build_array(jsonb_build_object('item_id', (select item_id from erp.items where code = 'AITEM'), 'qty', 1))), gen_random_uuid());
  end if;
  if to_regprocedure('erp_api.attachment_add(jsonb,uuid)') is not null then   -- E190: a GRN draft of A1 with a file ('A note'), one file not linked ('A spare')
    perform erp_api.attachment_add(jsonb_build_object('document_id', (erp_api.doc_save_draft('GRN', jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'A1'),
      'warehouse_id', (select warehouse_id from erp.warehouses where code = 'AW1'), 'notes', 'A grn'), gen_random_uuid())) ->> 'document_id', 'filename', 'A note.pdf',
      'content_base64', encode('\x255044462d312e340a79797979'::bytea, 'base64')), gen_random_uuid());
    perform erp_api.attachment_add(jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'A1'), 'filename', 'A spare.pdf',
      'content_base64', encode('\x255044462d312e340a7a7a7a7a'::bytea, 'base64')), gen_random_uuid());
  end if;
end $do$;
reset role;
-- every id of tenant B, to look for in RPC replies
create table t.bids as
  select t.b()::text id union select branch_id::text from erp.branches where tenant_id = t.b()
  union select member_id::text from erp.members where tenant_id = t.b() union select alert_id::text from erp.alerts where tenant_id = t.b();
do $do$ begin   -- ids of later files' rows of tenant B
  if to_regclass('erp.items') is not null then
    insert into t.bids select unit_id::text from erp.units where tenant_id = t.b() union select vat_class_id::text from erp.vat_classes where tenant_id = t.b()
      union select category_id::text from erp.item_categories where tenant_id = t.b() union select item_id::text from erp.items where tenant_id = t.b();
  end if;
  if to_regclass('erp.series') is not null then
    insert into t.bids select warehouse_id::text from erp.warehouses where tenant_id = t.b() union select counterparty_id::text from erp.counterparties where tenant_id = t.b()
      union select series_id::text from erp.series where tenant_id = t.b();
  end if;
  if to_regclass('erp.documents') is not null then
    insert into t.bids select document_id::text from erp.documents where tenant_id = t.b() union select line_id::text from erp.document_lines where tenant_id = t.b();
  end if;
  if to_regclass('erp.expense_categories') is not null then   -- E180 (T19): the default categories of B (tenant trigger)
    insert into t.bids select category_id::text from erp.expense_categories where tenant_id = t.b();
  end if;
  if to_regclass('erp.attachments') is not null then   -- E190 (Draft 1)
    insert into t.bids select attachment_id::text from erp.attachments where tenant_id = t.b();
  end if;
end $do$;
create function t.bid(p_sql text) returns uuid language plpgsql security definer as $$ declare v uuid; begin execute p_sql into v; return v; end $$;
create function t.bb() returns uuid language sql security definer as $$ select t.br(t.b(), 'B1') $$;
create function t.bm() returns uuid language sql security definer as $$ select member_id from erp.members where tenant_id = t.b() and role = 'manager' $$;
create function t.has_b(p jsonb) returns boolean language sql security definer as $$ select exists (select 1 from t.bids where strpos(p::text, id) > 0) $$;
grant execute on all functions in schema t to authenticated;

-- ---------- tables from the catalog ----------
create table t.tabs as
  select c.oid, c.relname, c.relrowsecurity rls, c.relforcerowsecurity frc,
         exists (select 1 from pg_catalog.pg_attribute a where a.attrelid = c.oid and a.attname = 'tenant_id' and not a.attisdropped) has_tenant,
         coalesce(obj_description(c.oid, 'pg_class'), '') like 'platform catalog:%' is_catalog,
         (select count(*) from pg_catalog.pg_policy p where p.polrelid = c.oid) policies,
         (select a.attname from pg_catalog.pg_index i join pg_catalog.pg_attribute a on a.attrelid = c.oid and a.attnum = i.indkey[0]
           where i.indrelid = c.oid and i.indisprimary) pk_first
    from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'erp' and c.relkind in ('r', 'p');
select t.ok((select count(*) from t.tabs) >= 12, 'catalog: ' || (select count(*) from t.tabs) || ' erp tables found');
select t.ok(not exists (select 1 from t.tabs where not (rls and frc)), 'every table: RLS enabled and forced ' || coalesce((select string_agg(relname, ',') from t.tabs where not (rls and frc)), ''));
select t.ok(not exists (select 1 from t.tabs where policies = 0), 'every table has a policy ' || coalesce((select string_agg(relname, ',') from t.tabs where policies = 0), ''));
select t.ok(not exists (select 1 from t.tabs where not has_tenant and not is_catalog), 'every table has tenant_id or is a commented platform catalog '
            || coalesce((select string_agg(relname, ',') from t.tabs where not has_tenant and not is_catalog), ''));
select t.ok(not exists (select 1 from t.tabs where has_tenant and pk_first <> 'tenant_id'), 'tenant_id is the first primary-key column of every tenant table '
            || coalesce((select string_agg(relname, ',') from t.tabs where has_tenant and pk_first <> 'tenant_id'), ''));
select t.ok(not exists (select 1 from t.tabs where is_catalog and has_tenant), 'no platform catalog carries tenant data');
create function t.b_rows(p_rel text) returns bigint language plpgsql security definer as $$
declare n bigint; begin execute format('select count(*) from erp.%I where tenant_id = %L', p_rel, t.b()) into n; return n; end $$;
select t.ok(not exists (select 1 from t.tabs where has_tenant and t.b_rows(relname) = 0),
            'coverage: every tenant table has a fixture row of tenant B; missing: ' || coalesce((select string_agg(relname, ',') from t.tabs where has_tenant and t.b_rows(relname) = 0), 'none'));
-- grants: authenticated never writes a table directly
select t.ok(not exists (select 1 from t.tabs where has_table_privilege('authenticated', oid, 'INSERT') or has_table_privilege('authenticated', oid, 'UPDATE')
                         or has_table_privilege('authenticated', oid, 'DELETE') or has_table_privilege('authenticated', oid, 'TRUNCATE')),
            'no insert / update / delete / truncate privilege on any erp table for authenticated');
select t.ok(not exists (select 1 from t.tabs where exists (select 1 from pg_catalog.pg_roles r where r.rolname = 'anon') and has_table_privilege('anon', oid, 'SELECT')),
            'anon reads no erp table');

-- every role of A: 0 rows of B in every readable tenant table
create function t.b_rows_visible(p_rel text) returns bigint language plpgsql as $$
declare n bigint; begin execute format('select count(*) from erp.%I where tenant_id = %L', p_rel, t.b()) into n; return n; end $$;
create function t.a_rows_visible(p_rel text) returns bigint language plpgsql as $$
declare n bigint; begin execute format('select count(*) from erp.%I', p_rel) into n; return n; end $$;
grant execute on all functions in schema t to authenticated;
grant select on t.tabs, t.role_login, t.bids, t.ids to authenticated;
create table t.leaks (role text, rel text, n bigint);
grant insert, select on t.leaks to authenticated;
set local role authenticated;
do $$ declare r record; x record; begin
  for r in select * from t.role_login loop
    perform t.as(r.n);
    for x in select relname from t.tabs where has_tenant and has_table_privilege('authenticated', oid, 'SELECT') loop
      if t.b_rows_visible(x.relname) > 0 then insert into t.leaks values (r.role, x.relname, t.b_rows_visible(x.relname)); end if;
    end loop;
  end loop;
end $$;
select t.ok(not exists (select 1 from t.leaks), 'every role of tenant A reads 0 rows of tenant B in every table ' || coalesce((select string_agg(role || ':' || rel, ',') from t.leaks), ''));
select t.as(31);
select t.ok(t.a_rows_visible('branches') = 3 and t.a_rows_visible('members') = 3, 'sanity: owner B sees its own rows (the check above is not vacuous)');
reset role;

-- ---------- RPC registry: one row per erp_api function (add a row with every new function) ----------
-- cap = capability the RPC checks (null = any member); call = a valid call for tenant A; cross = a call with a
-- tenant-B id (expect ERP_TENANT) or null = the call itself must return nothing of B.
create table t.rpc (fn text primary key, cap text, call text not null, cross_call text, self_service boolean default false);
insert into t.rpc values
  ('erp_api.whoami()', null, $$select erp_api.whoami()$$, null),
  ('erp_api.branch_list(boolean,jsonb,integer)', 'branch.read', $$select erp_api.branch_list(true)$$, null),
  ('erp_api.branch_save(jsonb,uuid)', 'branch.write', $$select erp_api.branch_save('{"code": "RX", "name": "Role test"}', gen_random_uuid())$$,
     $$select erp_api.branch_save(jsonb_build_object('branch_id', t.bb(), 'name', 'hijack'), gen_random_uuid())$$),
  ('erp_api.settings_get()', 'tenant.settings.read', $$select erp_api.settings_get()$$, null),
  ('erp_api.settings_save(jsonb,uuid)', 'tenant.settings.write',
     $$select erp_api.settings_save(jsonb_build_object('version', (select version from erp.tenant_settings), 'hide_money', false), gen_random_uuid())$$, null),
  ('erp_api.audit_list(jsonb,jsonb,integer)', 'audit.read', $$select erp_api.audit_list()$$, null);
-- E110 rows (added when E110 is installed, so the suite also runs after E100 alone)
do $do$ begin
  if to_regprocedure('erp_api.member_list(jsonb,jsonb,integer)') is not null then
    insert into t.rpc (fn, cap, call, cross_call, self_service) values
      ('erp_api.member_bind(uuid)', null, $$select erp_api.member_bind(gen_random_uuid())$$, null, true),
      ('erp_api.member_list(jsonb,jsonb,integer)', 'member.read', $$select erp_api.member_list()$$, null, false),
      ('erp_api.member_invite(jsonb,uuid)', 'member.manage', $$select erp_api.member_invite('{"email": "role.test@erp.test", "role": "readonly", "all_branches": true}', gen_random_uuid())$$,
         $$select erp_api.member_invite(jsonb_build_object('email', 'x.cross@erp.test', 'role', 'readonly', 'branch_ids', jsonb_build_array(t.bb())), gen_random_uuid())$$, false),
      ('erp_api.member_update(uuid,jsonb,uuid)', 'member.manage',
         $$select erp_api.member_update((select member_id from erp.members where email = 'user26@erp.test'), '{"display_name": "Role test"}', gen_random_uuid())$$,
         $$select erp_api.member_update(t.bm(), '{"display_name": "hijack"}', gen_random_uuid())$$, false),
      ('erp_api.member_reset_binding(uuid,uuid)', 'member.manage',
         $$select erp_api.member_reset_binding((select member_id from erp.members where email = 'user26@erp.test'), gen_random_uuid())$$,
         $$select erp_api.member_reset_binding(t.bm(), gen_random_uuid())$$, false);
  end if;
end $do$;
-- E120 rows (T05 / T06)
do $do$ begin
  if to_regprocedure('erp_api.item_save(jsonb,uuid)') is not null then
    insert into t.rpc (fn, cap, call, cross_call) values
      ('erp_api.unit_list(boolean,jsonb,integer)', 'item.read', $$select erp_api.unit_list(true)$$, null),
      ('erp_api.unit_save(jsonb,uuid)', 'item.write', $$select erp_api.unit_save('{"code": "RX", "name": "Role test"}', gen_random_uuid())$$,
         $$select erp_api.unit_save(jsonb_build_object('unit_id', t.bid('select unit_id from erp.units where tenant_id = t.b() limit 1'), 'name', 'hijack'), gen_random_uuid())$$),
      ('erp_api.vat_class_list(boolean,jsonb,integer)', 'vat.read', $$select erp_api.vat_class_list(true)$$, null),
      ('erp_api.vat_class_save(jsonb,uuid)', 'vat.write', $$select erp_api.vat_class_save('{"code": "RX", "name": "Role test", "rate": 5}', gen_random_uuid())$$,
         $$select erp_api.vat_class_save(jsonb_build_object('vat_class_id', t.bid('select vat_class_id from erp.vat_classes where tenant_id = t.b() limit 1'), 'name', 'hijack'), gen_random_uuid())$$),
      ('erp_api.category_list(boolean,jsonb,integer)', 'item.read', $$select erp_api.category_list(true)$$, null),
      ('erp_api.category_save(jsonb,uuid)', 'item.write', $$select erp_api.category_save('{"code": "RX", "name": "Role test"}', gen_random_uuid())$$,
         $$select erp_api.category_save(jsonb_build_object('code', 'RY', 'name', 'x', 'parent_id', t.bid('select category_id from erp.item_categories where tenant_id = t.b() limit 1')), gen_random_uuid())$$),
      ('erp_api.item_list(jsonb,jsonb,integer)', 'item.read', $$select erp_api.item_list('{"active": "all"}')$$,
         $$select erp_api.item_list(jsonb_build_object('category_id', t.bid('select category_id from erp.item_categories where tenant_id = t.b() limit 1')))$$),
      ('erp_api.item_get(uuid)', 'item.read', $$select erp_api.item_get((select item_id from erp.items where code = 'AITEM'))$$,
         $$select erp_api.item_get(t.bid('select item_id from erp.items where tenant_id = t.b() limit 1'))$$),
      ('erp_api.item_save(jsonb,uuid)', 'item.write',
         $$select erp_api.item_save(jsonb_build_object('code', 'RX', 'name', 'Role test', 'base_unit_id', (select unit_id from erp.units where code = 'PCS')), gen_random_uuid())$$,
         $$select erp_api.item_save(jsonb_build_object('item_id', t.bid('select item_id from erp.items where tenant_id = t.b() limit 1'), 'name', 'hijack'), gen_random_uuid())$$);
  end if;
  if to_regprocedure('erp_api.series_save(jsonb,uuid)') is not null then
    insert into t.rpc (fn, cap, call, cross_call) values
      ('erp_api.warehouse_list(jsonb,jsonb,integer)', 'warehouse.read', $$select erp_api.warehouse_list('{"include_inactive": true, "include_transit": true}')$$,
         $$select erp_api.warehouse_list(jsonb_build_object('branch_id', t.bb()))$$),
      ('erp_api.warehouse_save(jsonb,uuid)', 'warehouse.write',
         $$select erp_api.warehouse_save(jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'A1'), 'code', 'RX', 'name', 'Role test'), gen_random_uuid())$$,
         $$select erp_api.warehouse_save(jsonb_build_object('warehouse_id', t.bid('select warehouse_id from erp.warehouses where tenant_id = t.b() and kind = ''normal'' limit 1'), 'name', 'hijack'), gen_random_uuid())$$),
      ('erp_api.counterparty_list(jsonb,jsonb,integer)', 'counterparty.read', $$select erp_api.counterparty_list('{"active": "all"}')$$, null),
      ('erp_api.counterparty_get(uuid)', 'counterparty.read', $$select erp_api.counterparty_get((select counterparty_id from erp.counterparties where code = 'ACP'))$$,
         $$select erp_api.counterparty_get(t.bid('select counterparty_id from erp.counterparties where tenant_id = t.b() limit 1'))$$),
      ('erp_api.counterparty_save(jsonb,uuid)', 'counterparty.write', $$select erp_api.counterparty_save('{"name": "Role test"}', gen_random_uuid())$$,
         $$select erp_api.counterparty_save(jsonb_build_object('counterparty_id', t.bid('select counterparty_id from erp.counterparties where tenant_id = t.b() limit 1'), 'name', 'hijack'), gen_random_uuid())$$),
      ('erp_api.doc_type_list()', null, $$select erp_api.doc_type_list()$$, null),
      ('erp_api.series_list(jsonb,jsonb,integer)', 'series.read', $$select erp_api.series_list('{"include_inactive": true}')$$, null),
      ('erp_api.series_save(jsonb,uuid)', 'series.write',
         $$select erp_api.series_save(jsonb_build_object('doc_type', 'GRN', 'branch_id', (select branch_id from erp.branches where code = 'A1'), 'code', 'RX'), gen_random_uuid())$$,
         $$select erp_api.series_save(jsonb_build_object('series_id', t.bid('select series_id from erp.series where tenant_id = t.b() limit 1'), 'code', 'hijack'), gen_random_uuid())$$),
      ('erp_api.item_import(jsonb,boolean,uuid)', 'item.write', $$select erp_api.item_import('[{"code": "IMPX", "name": "x", "unit": "PCS"}]', false, gen_random_uuid())$$, null),
      ('erp_api.counterparty_import(jsonb,boolean,uuid)', 'counterparty.write', $$select erp_api.counterparty_import('[{"name": "Imp X"}]', false, gen_random_uuid())$$, null),
      ('erp_api.series_create_defaults(uuid,uuid)', 'series.write',
         $$select erp_api.series_create_defaults((select branch_id from erp.branches where code = 'A1'), gen_random_uuid())$$,
         $$select erp_api.series_create_defaults(t.bb(), gen_random_uuid())$$);
  end if;
end $do$;
do $do$ begin   -- E130 rows (T09)
  if to_regprocedure('erp_api.doc_save_draft(text,jsonb,uuid)') is not null then
    insert into t.rpc (fn, cap, call, cross_call) values
      ('erp_api.doc_save_draft(text,jsonb,uuid)', 'doc.ziso.create',
         $$select erp_api.doc_save_draft('ZISO', jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'A1')), gen_random_uuid())$$,
         $$select erp_api.doc_save_draft('ZISO', jsonb_build_object('branch_id', t.bb()), gen_random_uuid())$$),
      ('erp_api.doc_get(uuid)', 'doc.ziso.read', $$select erp_api.doc_get(t.bid('select document_id from erp.documents where notes = ''A draft'''))$$,
         $$select erp_api.doc_get(t.bid('select document_id from erp.documents where tenant_id = t.b() limit 1'))$$),
      ('erp_api.doc_list(jsonb,jsonb,integer)', 'doc.ziso.read', $$select erp_api.doc_list('{"doc_type": "ZISO"}')$$, null),
      ('erp_api.doc_delete_draft(uuid,uuid)', 'doc.ziso.create', $$select erp_api.doc_delete_draft(t.bid('select document_id from erp.documents where notes = ''A draft'''), gen_random_uuid())$$,
         $$select erp_api.doc_delete_draft(t.bid('select document_id from erp.documents where tenant_id = t.b() limit 1'), gen_random_uuid())$$),
      ('erp_api.doc_set_state(uuid,text,jsonb,uuid)', 'doc.ziso.create',
         $$select erp_api.doc_set_state(t.bid('select document_id from erp.documents where notes = ''A draft'''), 'posted', '{}', gen_random_uuid())$$,
         $$select erp_api.doc_set_state(t.bid('select document_id from erp.documents where tenant_id = t.b() limit 1'), 'cancelled', '{"reason": "x"}', gen_random_uuid())$$);
  end if;
end $do$;
do $do$ begin   -- E150 rows (T11 / T12)
  if to_regprocedure('erp_api.opening_import(jsonb,jsonb,boolean,uuid)') is not null then
    insert into t.rpc (fn, cap, call, cross_call) values
      ('erp_api.opening_import(jsonb,jsonb,boolean,uuid)', 'doc.opn.create',
         $$select erp_api.opening_import(jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'A1'),
             'warehouse_id', t.bid('select warehouse_id from erp.warehouses where code = ''AW1''')), '[{"item": "AITEM", "qty": 1, "unit_cost": 1}]', false, gen_random_uuid())$$,
         $$select erp_api.opening_import(jsonb_build_object('branch_id', t.bb(), 'warehouse_id', t.bid('select warehouse_id from erp.warehouses where code = ''BW1''')),
             '[{"item": "BITEM", "qty": 1, "unit_cost": 1}]', true, gen_random_uuid())$$);
  end if;
  if to_regprocedure('erp_api.doc_check(uuid)') is not null then
    insert into t.rpc (fn, cap, call, cross_call) values
      ('erp_api.doc_check(uuid)', 'doc.ziso.read', $$select erp_api.doc_check(t.bid('select document_id from erp.documents where notes = ''A draft'''))$$,
         $$select erp_api.doc_check(t.bid('select document_id from erp.documents where tenant_id = t.b() limit 1'))$$),
      ('erp_api.report_negative_stock(jsonb,jsonb,integer)', 'stock.read', $$select erp_api.report_negative_stock()$$,
         $$select erp_api.report_negative_stock(jsonb_build_object('branch_id', t.bb()))$$);
  end if;
  if to_regprocedure('erp_api.doc_convert(uuid[],text,jsonb,uuid)') is not null then   -- E135 T44
    insert into t.rpc (fn, cap, call, cross_call) values
      ('erp_api.doc_convert(uuid[],text,jsonb,uuid)', 'doc.ziso.create',
         $$select erp_api.doc_convert(array[t.bid('select document_id from erp.documents where notes = ''A posted''')], 'ZIST', null, gen_random_uuid())$$,
         $$select erp_api.doc_convert(array[t.bid('select document_id from erp.documents where tenant_id = t.b() and state = ''posted'' limit 1')], 'ZIST', null, gen_random_uuid())$$),
      ('erp_api.doc_copy(uuid,uuid)', 'doc.ziso.create', $$select erp_api.doc_copy(t.bid('select document_id from erp.documents where notes = ''A posted'''), gen_random_uuid())$$,
         $$select erp_api.doc_copy(t.bid('select document_id from erp.documents where tenant_id = t.b() limit 1'), gen_random_uuid())$$),
      ('erp_api.doc_conversions_for(uuid)', 'doc.ziso.read', $$select erp_api.doc_conversions_for(t.bid('select document_id from erp.documents where notes = ''A posted'''))$$,
         $$select erp_api.doc_conversions_for(t.bid('select document_id from erp.documents where tenant_id = t.b() limit 1'))$$);
  end if;
  if to_regprocedure('erp_api.alert_list(jsonb,jsonb,integer)') is not null then   -- E100 alerts (T14)
    insert into t.rpc (fn, cap, call, cross_call) values
      ('erp_api.alert_list(jsonb,jsonb,integer)', 'alert.read', $$select erp_api.alert_list('{"include_resolved": true}')$$, null),
      ('erp_api.alert_resolve(uuid,uuid)', 'alert.resolve', $$select erp_api.alert_resolve(t.bid('select alert_id from erp.alerts where tenant_id = t.a() limit 1'), gen_random_uuid())$$,
         $$select erp_api.alert_resolve(t.bid('select alert_id from erp.alerts where tenant_id = t.b() limit 1'), gen_random_uuid())$$);
  end if;
  if to_regprocedure('erp_api.stock_on_hand(jsonb,jsonb,integer)') is not null then   -- E140 read models (T14)
    insert into t.rpc (fn, cap, call, cross_call) values
      ('erp_api.stock_on_hand(jsonb,jsonb,integer)', 'stock.read', $$select erp_api.stock_on_hand()$$,
         $$select erp_api.stock_on_hand(jsonb_build_object('warehouse_id', t.bid('select warehouse_id from erp.warehouses where code = ''BW1''')))$$),
      ('erp_api.stock_card(uuid,jsonb,jsonb,integer)', 'stock.read', $$select erp_api.stock_card(t.bid('select item_id from erp.items where code = ''AITEM'''))$$,
         $$select erp_api.stock_card(t.bid('select item_id from erp.items where code = ''BITEM'''))$$),
      ('erp_api.item_lookup(text,uuid,integer)', 'item.read', $$select erp_api.item_lookup('a')$$,
         $$select erp_api.item_lookup('b', t.bid('select warehouse_id from erp.warehouses where code = ''BW1'''))$$),
      ('erp_api.item_availability(uuid)', 'stock.read', $$select erp_api.item_availability(t.bid('select item_id from erp.items where code = ''AITEM'''))$$,
         $$select erp_api.item_availability(t.bid('select item_id from erp.items where code = ''BITEM'''))$$);
  end if;
  if to_regprocedure('erp_api.trf_get(uuid)') is not null then   -- E160 T16
    insert into t.rpc (fn, cap, call, cross_call) values
      ('erp_api.trf_get(uuid)', 'doc.trf.read', $$select erp_api.trf_get(t.bid('select document_id from erp.documents where notes = ''A transfer'''))$$,
         $$select erp_api.trf_get(t.bid('select document_id from erp.documents where notes = ''B transfer'''))$$),
      ('erp_api.trf_warehouses()', 'doc.trf.read', $$select erp_api.trf_warehouses()$$, null);   -- T18: destinations of every branch
  end if;
  if to_regprocedure('erp_api.report_expenses(jsonb)') is not null then   -- E180 T19 / T20
    insert into t.rpc (fn, cap, call, cross_call) values
      ('erp_api.expense_category_list(boolean,jsonb,integer)', 'doc.exp.read', $$select erp_api.expense_category_list(true)$$, null),
      ('erp_api.expense_category_save(jsonb,uuid)', 'expense.category.write', $$select erp_api.expense_category_save('{"code": "RX", "name": "Role test"}', gen_random_uuid())$$,
         $$select erp_api.expense_category_save(jsonb_build_object('code', 'RY', 'name', 'x', 'parent_id', t.bid('select category_id from erp.expense_categories where tenant_id = t.b() limit 1')), gen_random_uuid())$$),
      ('erp_api.report_expenses(jsonb)', 'doc.exp.read', $$select erp_api.report_expenses()$$, $$select erp_api.report_expenses(jsonb_build_object('branch_id', t.bb()))$$);
  end if;
  if to_regprocedure('erp_api.attachment_add(jsonb,uuid)') is not null then   -- E190 Draft 1
    insert into t.rpc (fn, cap, call, cross_call) values
      ('erp_api.attachment_add(jsonb,uuid)', 'doc.grn.create',
         $$select erp_api.attachment_add(jsonb_build_object('branch_id', (select branch_id from erp.branches where code = 'A1'), 'filename', 'r.pdf',
             'content_base64', encode('\x255044462d312e340a'::bytea, 'base64')), gen_random_uuid())$$,
         $$select erp_api.attachment_add(jsonb_build_object('document_id', t.bid('select document_id from erp.documents where tenant_id = t.b() and doc_type = ''GRN'' limit 1'),
             'filename', 'r.pdf', 'content_base64', encode('\x255044462d312e340a'::bytea, 'base64')), gen_random_uuid())$$),
      ('erp_api.attachment_list(uuid,boolean)', 'doc.grn.read', $$select erp_api.attachment_list(t.bid('select document_id from erp.documents where notes = ''A grn'''), true)$$,
         $$select erp_api.attachment_list(t.bid('select document_id from erp.documents where tenant_id = t.b() and doc_type = ''GRN'' limit 1'))$$),
      ('erp_api.attachment_get(uuid)', 'doc.grn.read', $$select erp_api.attachment_get(t.bid('select attachment_id from erp.attachments where filename = ''A note.pdf'''))$$,
         $$select erp_api.attachment_get(t.bid('select attachment_id from erp.attachments where tenant_id = t.b() limit 1'))$$),
      ('erp_api.attachment_delete(uuid,uuid)', 'doc.grn.create', $$select erp_api.attachment_delete(t.bid('select attachment_id from erp.attachments where filename = ''A note.pdf'''), gen_random_uuid())$$,
         $$select erp_api.attachment_delete(t.bid('select attachment_id from erp.attachments where tenant_id = t.b() limit 1'), gen_random_uuid())$$),
      ('erp_api.grn_draft_from_extraction(jsonb,uuid,uuid,text)', 'doc.grn.create',
         $$select erp_api.grn_draft_from_extraction('{"lines": [{"description": "x", "qty": 1}]}', t.bid('select attachment_id from erp.attachments where filename = ''A spare.pdf'''),
             t.bid('select warehouse_id from erp.warehouses where code = ''AW1'''), 'iso:a:dn:0001')$$,
         $$select erp_api.grn_draft_from_extraction('{"lines": [{"description": "x", "qty": 1}]}', t.bid('select attachment_id from erp.attachments where filename = ''A spare.pdf'''),
             t.bid('select warehouse_id from erp.warehouses where code = ''BW1'''), 'iso:a:dn:0002')$$);
  end if;
  if to_regprocedure('erp_api.recost_status()') is not null then   -- E140 T13
    insert into t.rpc (fn, cap, call, cross_call) values
      ('erp_api.recost_status()', 'stock.read', $$select erp_api.recost_status()$$, null),
      ('erp_api.recost_run(integer,uuid)', 'tenant.settings.write', $$select erp_api.recost_run(5, gen_random_uuid())$$, null);
  end if;
end $do$;
grant select on t.rpc to authenticated;
create table t.fns as
  select p.oid, p.oid::regprocedure::text fn, p.prosecdef, p.proconfig
    from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace where n.nspname = 'erp_api';
select t.ok(not exists (select 1 from t.fns f where not exists (select 1 from t.rpc r where r.fn = f.fn)),
            'coverage: every erp_api function has a registry case; missing: ' || coalesce((select string_agg(fn, ', ') from t.fns f where not exists (select 1 from t.rpc r where r.fn = f.fn)), 'none'));
select t.ok(not exists (select 1 from t.rpc r where not exists (select 1 from t.fns f where f.fn = r.fn)), 'registry names only existing functions');
select t.ok(not exists (select 1 from t.fns where not prosecdef or not ('search_path=""' = any (proconfig)) or not ('statement_timeout=8s' = any (proconfig))),
            'every erp_api function: security definer, search_path empty, statement_timeout 8s ' ||
            coalesce((select string_agg(fn, ', ') from t.fns where not prosecdef or not ('search_path=""' = any (proconfig)) or not ('statement_timeout=8s' = any (proconfig))), ''));
select t.ok(not exists (select 1 from t.fns where not has_function_privilege('authenticated', oid, 'execute')), 'every erp_api function is granted to authenticated');
select t.ok(not exists (select 1 from t.fns, pg_catalog.pg_roles r where r.rolname in ('anon', 'service_role') and has_function_privilege(r.oid, t.fns.oid, 'execute')),
            'no erp_api function is executable by anon / service_role');
select t.ok(not exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                         where n.nspname = 'erp' and has_function_privilege('authenticated', p.oid, 'execute')
                           and p.proname not in ('my_tenants', 'my_branches', 'is_owner', 'sees_all_branches', 'jwt_sub', 'jwt_claims', 'can')),
            'internal erp functions closed to authenticated (only the policy helpers are open) ' ||
            coalesce((select string_agg(p.oid::regprocedure::text, ', ') from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                       where n.nspname = 'erp' and has_function_privilege('authenticated', p.oid, 'execute')
                         and p.proname not in ('my_tenants', 'my_branches', 'is_owner', 'sees_all_branches', 'jwt_sub', 'jwt_claims', 'can')), ''));

-- non-member: ERP_AUTH everywhere (self-service member_bind: nothing bound, nothing returned of anyone)
create table t.out (fn text, who text, res text);
grant insert, select, delete on t.out to authenticated;
set local role authenticated;
select t.login(t.sub(98), 'nobody@erp.test');
insert into t.out select fn, 'nonmember', t.try(call) from t.rpc;
select t.ok(not exists (select 1 from t.out o join t.rpc r using (fn) where o.who = 'nonmember' and not r.self_service and o.res not like 'ERP_AUTH%'),
            'non-member: every RPC raises ERP_AUTH ' || coalesce((select string_agg(fn || '=' || res, ', ') from t.out o join t.rpc r using (fn)
                                                                   where o.who = 'nonmember' and not r.self_service and o.res not like 'ERP_AUTH%'), ''));
-- cross-tenant (as owner of A, the widest role)
select t.as(21);
insert into t.out select fn, 'cross', t.try(cross_call) from t.rpc where cross_call is not null;
select t.ok(not exists (select 1 from t.out where who = 'cross' and res not like 'ERP_TENANT%'),
            'tenant-B ids raise ERP_TENANT: ' || (select string_agg(fn || '=' || left(res, 40), ', ') from t.out where who = 'cross'));
reset role;
create table t.nob (fn text, leak boolean);
grant insert, select on t.nob to authenticated;
set local role authenticated;
select t.as(21);
do $$ declare r record; v jsonb; begin
  for r in select * from t.rpc where cross_call is null and not self_service loop
    execute r.call into v; insert into t.nob values (r.fn, t.has_b(v));
  end loop;
end $$;
select t.ok(not exists (select 1 from t.nob where leak), 'replies of A''s calls hold no id of tenant B ' || coalesce((select string_agg(fn, ',') from t.nob where leak), ''));

-- role matrix: erp.role_caps x RPC
do $$ declare r record; x record; res text; begin
  for r in select * from t.role_login loop
    perform t.as(r.n);
    for x in select * from t.rpc where not self_service loop
      insert into t.out values (x.fn, r.role, t.try(x.call));
    end loop;
  end loop;
end $$;
reset role;
create table t.matrix as
  select o.fn, o.who role, o.res, r.cap,
         (r.cap is null or exists (select 1 from erp.role_caps rc where rc.tenant_id = t.a() and rc.role = o.who and rc.capability = r.cap and rc.allowed)) expected_ok
    from t.out o join t.rpc r using (fn) where o.who in (select role from t.role_login);
select t.ok((select count(*) from t.matrix) = 6 * (select count(*) from t.rpc where not self_service), 'role matrix: ' || (select count(*) from t.matrix) || ' role x RPC calls');
select t.ok(not exists (select 1 from t.matrix where expected_ok and res <> 'ok'), 'allowed roles succeed: ' ||
            coalesce((select string_agg(role || '/' || fn || '=' || left(res, 60), ', ') from t.matrix where expected_ok and res <> 'ok'), 'all'));
select t.ok(not exists (select 1 from t.matrix where not expected_ok and res not like 'ERP_FORBIDDEN%'), 'other roles get ERP_FORBIDDEN: ' ||
            coalesce((select string_agg(role || '/' || fn || '=' || left(res, 60), ', ') from t.matrix where not expected_ok and res not like 'ERP_FORBIDDEN%'), 'all'));
select t.ok((select count(*) from t.matrix where not expected_ok) > 0, 'the matrix is not vacuous (some calls are forbidden)');

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
