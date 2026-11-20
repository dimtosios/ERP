-- =====================================================================
-- iSmile ERP  -  tests for E130_documents_core.sql (T09): draft save (totals, rounding, problems vs shape errors,
-- version, client_key), numbering (series choice, gapless, rollback returns the number, ERP_SERIES_MISSING),
-- immutability trigger, state machine from erp.doc_transitions (post, approval limit, reject, cancel with reason,
-- ERP_STATE / ERP_FORBIDDEN), lock date, future date, branch / type visibility, list paging and filters, VAT rate
-- guard, idempotency, audit. Uses two TEST document types (no stock) created inside the transaction.
-- One transaction, ROLLED BACK. Last line: ALL TESTS PASSED + number of checks.
-- =====================================================================
begin;
\ir _helpers.sql

create table t.ids (a uuid, b uuid);
insert into t.ids select t.tenant('da'), t.tenant('db');
create function t.a() returns uuid language sql security definer as $$ select a from t.ids $$;
create function t.b() returns uuid language sql security definer as $$ select b from t.ids $$;
select t.init(t.a()), t.init(t.b());
select t.branch(t.a(), 'A1', 0), t.branch(t.a(), 'A2', 1), t.branch(t.b(), 'B1', 0);
select t.member(t.a(), 1, 'owner'), t.member(t.a(), 2, 'manager', array[t.br(t.a(), 'A1')]), t.member(t.a(), 3, 'warehouse', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 4, 'accounting', '{}', true), t.member(t.a(), 6, 'readonly', array[t.br(t.a(), 'A1')]), t.member(t.b(), 11, 'owner');

-- test types: ZNOTE (sale prices, no stock) and ZAPP (value approval); capabilities doc.znote.* / doc.zapp.*
insert into erp.doc_types (doc_type, name, area, series_scope, needs_counterparty, cap_prefix, sort, enabled, price_kind, approval_key, header_extra, line_extra)
values ('ZNOTE', 'Test note', 'sales', 'branch', false, 'znote', 900, true, 'sale', null, '{reason}', '{colour}'),
       ('ZAPP', 'Test approval', 'warehouse', 'branch', false, 'zapp', 901, true, 'cost', 'zapp_value', '{}', '{}');
insert into erp.doc_transitions (doc_type, from_state, to_state, cap, condition, action, label, sort) values
  ('ZNOTE', 'draft', 'posted', 'create', null, 'post', 'doc.action.post', 10),
  ('ZNOTE', 'posted', 'cancelled', 'approve', null, 'cancel', 'doc.action.cancel', 90),
  ('ZAPP', 'draft', 'posted', 'create', 'under_threshold', 'post', 'doc.action.post', 10),
  ('ZAPP', 'draft', 'posted', 'approve', null, 'post', 'doc.action.post', 10),
  ('ZAPP', 'draft', 'pending_approval', 'create', 'over_threshold', 'none', 'doc.action.submit', 20),
  ('ZAPP', 'pending_approval', 'posted', 'approve', null, 'post', 'doc.action.approve', 30),
  ('ZAPP', 'pending_approval', 'draft', 'approve', null, 'none', 'doc.action.reject', 40),
  ('ZAPP', 'posted', 'cancelled', 'approve', null, 'cancel', 'doc.action.cancel', 90);
insert into erp.capabilities (capability, area) values ('doc.znote.read', 'test'), ('doc.znote.create', 'test'), ('doc.znote.approve', 'test'),
  ('doc.zapp.read', 'test'), ('doc.zapp.create', 'test'), ('doc.zapp.approve', 'test');
insert into erp.role_caps (tenant_id, role, capability)
select t.a(), r, c from (values ('owner', 'doc.znote.read'), ('owner', 'doc.znote.create'), ('owner', 'doc.znote.approve'),
  ('manager', 'doc.znote.read'), ('manager', 'doc.znote.create'), ('manager', 'doc.znote.approve'),
  ('warehouse', 'doc.znote.read'), ('warehouse', 'doc.znote.create'), ('readonly', 'doc.znote.read'),
  ('owner', 'doc.zapp.read'), ('owner', 'doc.zapp.create'), ('owner', 'doc.zapp.approve'),
  ('manager', 'doc.zapp.read'), ('manager', 'doc.zapp.create'), ('manager', 'doc.zapp.approve'),
  ('warehouse', 'doc.zapp.read'), ('warehouse', 'doc.zapp.create')) v(r, c);
insert into erp.role_caps (tenant_id, role, capability) values (t.b(), 'owner', 'doc.znote.read'), (t.b(), 'owner', 'doc.znote.create');
insert into erp.items (tenant_id, code, name, base_unit_id, vat_class_id)
select t.a(), 'IT1', 'Item one', (select unit_id from erp.units where tenant_id = t.a() and code = 'PCS'), (select vat_class_id from erp.vat_classes where tenant_id = t.a() and code = 'VAT24');
insert into erp.items (tenant_id, code, name, base_unit_id) select t.b(), 'BIT', 'B item', (select unit_id from erp.units where tenant_id = t.b() and code = 'PCS');
create function t.it(p_t uuid, p_code text) returns uuid language sql security definer as $$ select item_id from erp.items where tenant_id = p_t and code = p_code $$;
create function t.unit(p_t uuid, p_code text) returns uuid language sql security definer as $$ select unit_id from erp.units where tenant_id = p_t and code = p_code $$;
create function t.today() returns date language sql security definer as $$ select erp.today(t.a()) $$;
create function t.codes(p jsonb) returns text language sql immutable as $$ select string_agg(e ->> 'code' || ':' || coalesce(e ->> 'field', '-'), ',' order by e ->> 'field', e ->> 'code') from jsonb_array_elements(p) e $$;
create function t.doc(p_id text) returns erp.documents language sql security definer as $$ select d from erp.documents d where document_id = p_id::uuid $$;
create function t.post(p_id text, p_opts jsonb default '{}') returns jsonb language sql as $$ select erp_api.doc_set_state(p_id::uuid, 'posted', p_opts, gen_random_uuid()) $$;
create function t.note(p_branch uuid, p_qty numeric, p_price numeric) returns text language sql as $$
  select (erp_api.doc_save_draft('ZNOTE', jsonb_build_object('branch_id', p_branch, 'lines', jsonb_build_array(jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', p_qty, 'unit_price', p_price))),
                                 gen_random_uuid())) ->> 'document_id' $$;
grant execute on all functions in schema t to authenticated;
create table t.v (k text primary key, id text);
grant select, insert, update, delete on t.v to authenticated;
create function t.id(p_k text) returns text language sql security definer as $$ select id from t.v where k = p_k $$;
create function t.put(p_k text, p_id text) returns void language sql security definer as $$ insert into t.v values (p_k, p_id) on conflict (k) do update set id = excluded.id $$;
grant execute on all functions in schema t to authenticated;

set local role authenticated;
-- ---------- draft save ----------
select t.as(3);
select t.keep(erp_api.doc_save_draft('ZNOTE', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'notes', 'first', 'extra', jsonb_build_object('reason', 'test'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', 3, 'unit_price', 1.235),
                             jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', '2.5', 'unit_price', '10', 'discount_pct', 10, 'extra', jsonb_build_object('colour', 'red')))),
  '00000000-0000-4000-c130-000000000001'));
select t.put('d1', t.j() ->> 'document_id');
select t.ok(t.j() ->> 'state' = 'draft' and t.j() ->> 'number' is null and t.j() ->> 'doc_date' = t.today()::text and t.j() ->> 'version' = '1'
            and t.j() #>> '{lines,0,net}' = '3.71' and t.j() #>> '{lines,0,vat}' = '0.89' and t.j() #>> '{lines,1,net}' = '22.50' and t.j() #>> '{lines,1,vat}' = '5.40'
            and t.j() ->> 'total_net' = '26.21' and t.j() ->> 'total_vat' = '6.29' and t.j() ->> 'total_gross' = '32.50',
            'draft: no number, today, line net = round(qty x price x (1 - disc), 2), VAT per line half-up, totals = sum of lines');
select t.ok(t.j() #>> '{lines,0,unit_code}' = 'PCS' and t.j() #>> '{lines,0,qty_base}' = '3.0000' and t.j() #>> '{lines,0,vat_class_id}' is not null
            and jsonb_array_length(t.j() -> 'problems') = 0 and t.j() -> 'actions' = '[{"sort": 10, "label": "doc.action.post", "action": "post", "to_state": "posted"}]',
            'unit and VAT default from the item (sale type); no problem; the warehouse member may only post');
select t.ok((erp_api.doc_save_draft('ZNOTE', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'notes', 'first', 'extra', jsonb_build_object('reason', 'test'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', 3, 'unit_price', 1.235),
                             jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', '2.5', 'unit_price', '10', 'discount_pct', 10, 'extra', jsonb_build_object('colour', 'red')))),
  '00000000-0000-4000-c130-000000000001')) = t.j() and t.count($$select 1 from erp.documents where doc_type = 'ZNOTE'$$) = 1, 'same key: stored reply, one document');
select t.keep(erp_api.doc_save_draft('ZNOTE', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'doc_date', '2099-01-01', 'lines', jsonb_build_array(jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', 0),
  jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', 1, 'unit_id', t.unit(t.a(), 'BOX')))), gen_random_uuid()));
select t.ok((select string_agg(coalesce(e ->> 'line_no', '-') || ':' || (e ->> 'code'), ',' order by e ->> 'line_no' nulls first) from jsonb_array_elements(t.j() -> 'problems') e)
            = '-:future_date,1:invalid,2:unit_invalid', 'a draft with business problems is SAVED and lists them (future date, qty 0, non-base unit)');
select t.put('bad', t.j() ->> 'document_id');
select t.ok(t.codes(t.problems(format($$select erp_api.doc_save_draft('ZNOTE', '{"branch_id": "%s", "colour": 1, "extra": {"x": 1}, "lines": [{"qty": "abc", "item_id": "%s", "size": 3}]}', gen_random_uuid())$$,
                                      t.br(t.a(), 'A1'), t.it(t.a(), 'IT1'))))
            = 'not_editable:colour,not_editable:extra.x,invalid:qty,not_editable:size', 'shape errors refuse the save: unknown keys (header, extra, line), qty not a number');
select t.fails(format($$select erp_api.doc_save_draft('ZNOTE', '{"branch_id": "%s", "lines": [{"qty": 1, "item_id": "%s"}]}', gen_random_uuid())$$, t.br(t.a(), 'A1'), t.it(t.b(), 'BIT')),
               'ERP_TENANT', 'an item of tenant B on a line: ERP_TENANT');
select t.fails(format($$select erp_api.doc_save_draft('ZNOTE', '{"branch_id": "%s"}', gen_random_uuid())$$, t.br(t.b(), 'B1')), 'ERP_TENANT', 'a branch of tenant B: ERP_TENANT');
select t.fails(format($$select erp_api.doc_save_draft('ZNOTE', '{"branch_id": "%s"}', gen_random_uuid())$$, t.br(t.a(), 'A2')), 'ERP_FORBIDDEN', 'warehouse (A1) cannot create in A2');
select t.ok(t.problems($$select erp_api.doc_save_draft('DN', '{}', gen_random_uuid())$$) -> 0 ->> 'field' = 'p_type', 'a type not enabled yet (DN, fiscal: E8) cannot be saved');
-- update: version required, lines replaced
select t.fails(format($$select erp_api.doc_save_draft('ZNOTE', '{"document_id": "%s", "version": 7, "notes": "x"}', gen_random_uuid())$$, t.id('d1')), 'ERP_CONFLICT', 'stale version: ERP_CONFLICT');
select t.keep(erp_api.doc_save_draft('ZNOTE', jsonb_build_object('document_id', t.id('d1'), 'version', 1, 'lines', jsonb_build_array(jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', 4, 'unit_price', 2.5))), gen_random_uuid()));
select t.ok(t.j() ->> 'version' = '2' and t.j() ->> 'notes' = 'first' and jsonb_array_length(t.j() -> 'lines') = 1 and t.j() ->> 'total_net' = '10.00'
            and t.j() -> 'extra' = '{"reason": "test"}', 'update: lines replaced, header keys not given are kept, version + 1');
-- client_key: a retry with another idempotency key finds the same draft
select t.keep(erp_api.doc_save_draft('ZNOTE', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'client_key', 'ext:card:0001', 'lines', jsonb_build_array(jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', 1, 'unit_price', 1))), gen_random_uuid()));
select t.put('ck', t.j() ->> 'document_id');
select t.ok((erp_api.doc_save_draft('ZNOTE', jsonb_build_object('client_key', 'ext:card:0001', 'lines', jsonb_build_array(jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', 2, 'unit_price', 1))), gen_random_uuid())) ->> 'document_id' = t.id('ck')
            and t.count($$select 1 from erp.documents where client_key = 'ext:card:0001'$$) = 1 and (t.doc(t.id('ck'))).source = 'external', 'client_key: the same draft is updated, never a second one');

-- ---------- numbering ----------
select t.fails(format($$select t.post('%s')$$, t.id('d1')), 'ERP_SERIES_MISSING', 'no series: ERP_SERIES_MISSING (nothing posted)');
select t.ok((t.doc(t.id('d1'))).state = 'draft', '...the draft stays a draft');
reset role;
insert into erp.series (tenant_id, branch_id, doc_type, code, next_no, fiscal_year) values (t.a(), t.br(t.a(), 'A1'), 'ZNOTE', 'ZN-A1', 41, null),
  (t.a(), t.br(t.a(), 'A1'), 'ZNOTE', 'ZN-A1-2027', 1, 2027), (t.a(), t.br(t.a(), 'A2'), 'ZNOTE', 'ZN-A2', 1, null), (t.a(), t.br(t.a(), 'A1'), 'ZAPP', 'ZA-A1', 1, null);
set local role authenticated;
select t.as(3);
select t.keep(t.post(t.id('d1')));
select t.ok((t.j() ->> 'posted')::boolean and t.j() #>> '{document,state}' = 'posted' and t.j() #>> '{document,number}' = '41' and t.j() #>> '{document,doc_no}' = 'ZN-A1/000041'
            and t.j() #>> '{document,posted_at}' is not null and t.j() -> 'warnings' = '[]', 'post: the default series of the branch gives number 41 (next_no), doc_no = series/000041');
select t.ok(t.j() #> '{document,actions}' = '[]'::jsonb, 'posted: the warehouse member has no further action (cancel = approve)');
select t.put('d2', t.note(t.br(t.a(), 'A1'), 1, 1));
select t.ok(t.post(t.id('d2')) #>> '{document,number}' = '42', 'next post: 42');
-- a failed post returns its number (the transaction is rolled back, the series is not advanced)
select t.put('d3', t.note(t.br(t.a(), 'A1'), 1, 1));
select t.ok(t.try(format($$select 1 / (count(*) - count(*)) from (select t.post('%s')) x$$, t.id('d3'))) like 'division by zero%' and t.count($$select 1 from erp.series where code = 'ZN-A1' and next_no = 43$$) = 1
            and (t.doc(t.id('d3'))).state = 'draft', 'a rolled-back post gives its number back (next_no stays 43)');
select t.ok(t.post(t.id('d3')) #>> '{document,number}' = '43', '...and the next post takes 43: no gap');
select t.ok(t.count($$select 1 from erp.documents where doc_type = 'ZNOTE' and number in (41, 42, 43)$$) = 3 and t.count($$select 1 from erp.documents where doc_type = 'ZNOTE' and number is not null$$) = 3,
            'numbers 41, 42, 43: gapless, unique');
reset role;
select t.fails(format($$update erp.documents set number = 41 where document_id = '%s'$$, t.id('ck')), '', 'the database refuses a duplicate number in a series (unique index)');
-- immutability
select t.fails(format($$update erp.documents set total_net = 1 where document_id = '%s'$$, t.id('d1')), 'ERP_DOC_IMMUTABLE', 'trigger: a posted document''s data cannot change');
select t.fails(format($$update erp.document_lines set qty = 9 where document_id = '%s'$$, t.id('d1')), 'ERP_DOC_IMMUTABLE', 'trigger: its lines cannot change');
select t.fails(format($$delete from erp.document_lines where document_id = '%s'$$, t.id('d1')), 'ERP_DOC_IMMUTABLE', 'trigger: its lines cannot be deleted');
select t.fails(format($$delete from erp.documents where document_id = '%s'$$, t.id('d1')), 'ERP_DOC_IMMUTABLE', 'trigger: it cannot be deleted');
select t.ok(t.affected(format($$update erp.documents set notes = 'late note' where document_id = '%s'$$, t.id('d1'))) = 1, 'whitelist: notes of a posted document can change');
set local role authenticated;
select t.as(3);
select t.fails(format($$select erp_api.doc_save_draft('ZNOTE', '{"document_id": "%s", "version": 3, "notes": "x"}', gen_random_uuid())$$, t.id('d1')), 'ERP_DOC_IMMUTABLE', 'doc_save_draft on a posted document: ERP_DOC_IMMUTABLE');
select t.fails(format($$select erp_api.doc_delete_draft('%s', gen_random_uuid())$$, t.id('d1')), 'ERP_DOC_IMMUTABLE', 'doc_delete_draft on a posted document: ERP_DOC_IMMUTABLE');
select t.ok((erp_api.doc_save_draft('ZNOTE', jsonb_build_object('client_key', 'ext:card:0001'), gen_random_uuid())) ->> 'document_id' = t.id('ck'), 'client_key of a draft still works');
select t.ok(t.post(t.id('ck')) #>> '{document,number}' = '44', 'client_key draft posted');
select t.ok((erp_api.doc_save_draft('ZNOTE', jsonb_build_object('client_key', 'ext:card:0001', 'notes', 'retry'), gen_random_uuid())) ->> 'state' = 'posted'
            and (t.doc(t.id('ck'))).notes is null, 'a retry after posting returns the posted document unchanged');
-- year series: a document of 2027 takes the 2027 series... not possible today (future date); date rules
select t.ok(t.problems(format($$select t.post('%s')$$, t.id('bad'))) -> 0 ->> 'code' = 'future_date', 'post blocks on the problems (future date first)');

-- ---------- state machine ----------
select t.fails(format($$select erp_api.doc_set_state('%s', 'draft', '{}', gen_random_uuid())$$, t.id('d1')), 'ERP_STATE', 'posted -> draft does not exist: ERP_STATE');
select t.fails(format($$select erp_api.doc_set_state('%s', 'cancelled', '{"reason": "x"}', gen_random_uuid())$$, t.id('d1')), 'ERP_FORBIDDEN', 'warehouse cannot cancel (approve capability)');
select t.as(2);
select t.ok(t.problems(format($$select erp_api.doc_set_state('%s', 'cancelled', '{}', gen_random_uuid())$$, t.id('d1'))) -> 0 ->> 'field' = 'reason', 'cancel needs a reason');
select t.keep(erp_api.doc_set_state(t.id('d1')::uuid, 'cancelled', '{"reason": "typed twice"}', gen_random_uuid()));
select t.ok(t.j() #>> '{document,state}' = 'cancelled' and t.j() #>> '{document,number}' = '41' and t.j() #>> '{document,cancel_reason}' = 'typed twice', 'manager cancels: number kept, reason stored');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'doc.cancelled' and new_row ->> 'reason' = 'typed twice'$$) = 1
            and t.count($$select 1 from erp.audit_log where action = 'doc.posted' and row_id = '$$ || t.id('d2') || $$'$$) = 1, 'state changes are audited');
-- lock date
reset role;
update erp.tenant_settings set lock_date = erp.today(t.a()) where tenant_id = t.a();
set local role authenticated;
select t.as(2);
select t.put('d4', t.note(t.br(t.a(), 'A1'), 1, 1));
select t.fails(format($$select t.post('%s')$$, t.id('d4')), 'ERP_LOCKED_PERIOD', 'lock date = today: posting today''s document is refused');
select t.fails(format($$select erp_api.doc_set_state('%s', 'cancelled', '{"reason": "x"}', gen_random_uuid())$$, t.id('d2')), 'ERP_LOCKED_PERIOD', '...and so is cancelling one');
reset role;
update erp.tenant_settings set lock_date = null where tenant_id = t.a();
-- approval limit (ZAPP; value = net of the lines in E130, cost value with E140)
update erp.tenant_settings set thresholds = '{"zapp_value": 100}' where tenant_id = t.a();
set local role authenticated;
select t.as(3);
select t.keep(erp_api.doc_save_draft('ZAPP', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'lines', jsonb_build_array(jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', 10, 'unit_price', 15))), gen_random_uuid()));
select t.put('a1', t.j() ->> 'document_id');
select t.ok((select string_agg(a ->> 'to_state', ',') from jsonb_array_elements(t.j() -> 'actions') a) = 'pending_approval' and t.j() #>> '{lines,0,vat}' = '0.00',
            'value 150 > limit 100: the warehouse member can only submit for approval (cost type: no VAT default)');
select t.fails(format($$select t.post('%s')$$, t.id('a1')), 'ERP_STATE', 'posting it directly: ERP_STATE (needs approval)');
select t.ok((erp_api.doc_set_state(t.id('a1')::uuid, 'pending_approval', '{}', gen_random_uuid())) #>> '{document,state}' = 'pending_approval', 'submitted for approval');
select t.fails(format($$select erp_api.doc_save_draft('ZAPP', '{"document_id": "%s", "version": 2, "notes": "x"}', gen_random_uuid())$$, t.id('a1')), 'ERP_DOC_IMMUTABLE', 'pending approval: not editable');
select t.fails(format($$select t.post('%s')$$, t.id('a1')), 'ERP_FORBIDDEN', 'the warehouse member cannot approve');
select t.as(2);
select t.ok((erp_api.doc_set_state(t.id('a1')::uuid, 'draft', '{"reason": "check the price"}', gen_random_uuid())) #>> '{document,state}' = 'draft', 'manager rejects: back to draft');
select t.as(3);
select erp_api.doc_set_state(t.id('a1')::uuid, 'pending_approval', '{}', gen_random_uuid());
select t.as(2);
select t.keep(t.post(t.id('a1')));
select t.ok(t.j() #>> '{document,state}' = 'posted' and t.j() #>> '{document,number}' = '1' and (t.doc(t.id('a1'))).approved_by is not null, 'manager approves: posted, number 1, approved_by set');
select t.as(3);
select t.keep(erp_api.doc_save_draft('ZAPP', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'lines', jsonb_build_array(jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', 10, 'unit_price', 9.99))), gen_random_uuid()));
select t.ok(t.post(t.j() ->> 'document_id') #>> '{document,number}' = '2', 'value 99.90 <= 100: the warehouse member posts directly');
select t.as(2);
select t.keep(erp_api.doc_save_draft('ZAPP', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'lines', jsonb_build_array(jsonb_build_object('item_id', t.it(t.a(), 'IT1'), 'qty', 100, 'unit_price', 9))), gen_random_uuid()));
select t.ok(t.post(t.j() ->> 'document_id') #>> '{document,state}' = 'posted', 'the approver (manager) posts an over-limit document directly');

-- ---------- visibility, list, delete ----------
select t.as(1);
select t.put('o2', t.note(t.br(t.a(), 'A2'), 1, 1));
select t.as(2);
select t.fails(format($$select erp_api.doc_get('%s')$$, t.id('o2')), 'ERP_FORBIDDEN', 'manager (A1) cannot open a document of A2 (same tenant: ERP_FORBIDDEN)');
select t.ok(not exists (select 1 from jsonb_array_elements((erp_api.doc_list('{"doc_type": "ZNOTE"}')) -> 'rows') r where r ->> 'document_id' = t.id('o2')), '...nor list it');
select t.ok((select count(*) from erp.documents where document_id = t.id('o2')::uuid) = 0, '...and RLS hides the row');
select t.as(4);
select t.fails($$select erp_api.doc_list('{"doc_types": ["ZNOTE", "ZAPP"]}')$$, 'ERP_FORBIDDEN', 'accounting without a read capability of these types: ERP_FORBIDDEN');
select t.ok((select count(*) from erp.documents) = 0, 'RLS: no document of an unreadable type');
select t.as(6);
select t.ok(jsonb_array_length((erp_api.doc_list()) -> 'rows') = 6 and (select count(*) from erp.documents) = 6, 'readonly (A1): the 6 ZNOTE documents of A1 (ZAPP not readable)');
select t.ok((erp_api.doc_list('{"q": "000042"}')) #>> '{rows,0,document_id}' = t.id('d2') and jsonb_array_length((erp_api.doc_list('{"state": "draft"}')) -> 'rows') = 2,
            'list filters: q = number, state');
select t.ok((select string_agg(r ->> 'doc_no', ',' order by r ->> 'doc_no') from (select jsonb_array_elements(p1 -> 'rows') r from (select erp_api.doc_list('{"state": "posted"}', null, 2) p1) x
             union all select jsonb_array_elements((erp_api.doc_list('{"state": "posted"}', (erp_api.doc_list('{"state": "posted"}', null, 2)) -> 'next', 2)) -> 'rows')) y)
            = 'ZN-A1/000042,ZN-A1/000043,ZN-A1/000044', 'keyset paging: 2 + 1 posted documents, no duplicate');
select t.fails(format($$select erp_api.doc_delete_draft('%s', gen_random_uuid())$$, t.id('bad')), 'ERP_FORBIDDEN', 'readonly cannot delete a draft');
select t.as(3);
select t.ok((erp_api.doc_delete_draft(t.id('bad')::uuid, gen_random_uuid())) ->> 'deleted' = 'true' and t.count($$select 1 from erp.document_lines where document_id = '$$ || t.id('bad') || $$'$$) = 0,
            'a draft is deleted with its lines (audited)');
select t.as(11);
select t.fails(format($$select erp_api.doc_get('%s')$$, t.id('d2')), 'ERP_TENANT', 'tenant B cannot open a document of A');
select t.fails(format($$select erp_api.doc_set_state('%s', 'posted', '{}', gen_random_uuid())$$, t.id('d4')), 'ERP_TENANT', 'tenant B cannot post a document of A');
reset role;

-- ---------- VAT rate guard ----------
select t.fails(format($$update erp.vat_classes set rate = 23 where tenant_id = '%s' and code = 'VAT24'$$, t.a()), 'ERP_VALIDATION', 'the rate of a VAT class used by posted lines cannot change');
select t.ok(t.affected(format($$update erp.vat_classes set rate = 14 where tenant_id = '%s' and code = 'VAT13'$$, t.a())) = 1, 'an unused class can still change');

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
