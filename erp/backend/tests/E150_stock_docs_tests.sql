-- =====================================================================
-- iSmile ERP  -  tests for E150_stock_docs.sql: GRN (T11: supplier, prices, discount, stock + cost + last purchase
-- price, cancel by approver only), OPN (manager prepares, owner approves; organisation-wide series), opening-stock
-- import (dry run, every problem by row, all or nothing, OPN draft); T12: ADJ+ / ADJ- (reasons, current cost, value
-- limit, approval), CONS (clinic_user, cost centre, ext_ref, reversal), doc_check, negative-stock warning / ack /
-- block, alerts (negative, low stock; one per warehouse and item; self-resolving), negative-stock report + view,
-- golden G7; role matrix of the types, tenancy.
-- One transaction, ROLLED BACK. Last line: ALL TESTS PASSED + number of checks.
-- =====================================================================
begin;
\ir _helpers.sql

create table t.ids (a uuid, b uuid);
insert into t.ids select t.tenant('ka'), t.tenant('kb');
create function t.a() returns uuid language sql security definer as $$ select a from t.ids $$;
create function t.b() returns uuid language sql security definer as $$ select b from t.ids $$;
select t.init(t.a()), t.init(t.b());
select t.branch(t.a(), 'A1', 0), t.branch(t.a(), 'A2', 1), t.branch(t.b(), 'B1', 0);
select t.member(t.a(), 1, 'owner'), t.member(t.a(), 2, 'manager', array[t.br(t.a(), 'A1')]), t.member(t.a(), 3, 'warehouse', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 4, 'accounting', '{}', true), t.member(t.a(), 5, 'clinic_user', array[t.br(t.a(), 'A1')]), t.member(t.a(), 6, 'readonly', array[t.br(t.a(), 'A1')]),
       t.member(t.b(), 11, 'owner');
insert into erp.warehouses (tenant_id, branch_id, code, name) values (t.a(), t.br(t.a(), 'A1'), 'W1', 'W one'), (t.a(), t.br(t.a(), 'A2'), 'W2', 'W two'),
  (t.b(), t.br(t.b(), 'B1'), 'BW', 'B w');
insert into erp.items (tenant_id, code, name, base_unit_id, kind)
select t.a(), c, 'Item ' || c, (select unit_id from erp.units where tenant_id = t.a() and code = 'PCS'), k from (values ('IT1', 'goods'), ('IT2', 'consumable'), ('SVC', 'service')) v(c, k);
insert into erp.counterparties (tenant_id, name, kind) values (t.a(), 'Supplier', 'supplier'), (t.a(), 'Customer', 'customer');
create function t.wh(p_code text) returns uuid language sql security definer as $$ select warehouse_id from erp.warehouses where code = p_code $$;
create function t.it(p_code text) returns uuid language sql security definer as $$ select item_id from erp.items where tenant_id = t.a() and code = p_code $$;
create function t.cp(p_name text) returns uuid language sql security definer as $$ select counterparty_id from erp.counterparties where tenant_id = t.a() and name = p_name $$;
create function t.today() returns date language sql security definer as $$ select erp.today(t.a()) $$;
create function t.doc(p_id text) returns erp.documents language sql security definer as $$ select d from erp.documents d where document_id = p_id::uuid $$;
create function t.bal(p_wh text, p_item text) returns numeric language sql security definer as $$
  select coalesce((select qty from erp.stock_balances where warehouse_id = t.wh(p_wh) and item_id = t.it(p_item)), 0) $$;
create function t.ic(p_item text) returns erp.item_costs language sql security definer as $$ select c from erp.item_costs c where item_id = t.it(p_item) $$;
create function t.codes(p jsonb) returns text language sql immutable as $$ select string_agg(coalesce(e ->> 'line_no', '-') || ':' || (e ->> 'code') || ':' || coalesce(e ->> 'field', '-'), ','
  order by e ->> 'line_no' nulls first, e ->> 'field', e ->> 'code') from jsonb_array_elements(p) e $$;
create table t.v (k text primary key, id text);
create function t.put(p_k text, p_id text) returns void language sql security definer as $$ insert into t.v values (p_k, p_id) on conflict (k) do update set id = excluded.id $$;
create function t.id(p_k text) returns text language sql security definer as $$ select id from t.v where k = p_k $$;
grant execute on all functions in schema t to authenticated;
grant select, insert, update on t.v to authenticated;

set local role authenticated;
select t.as(1);
select t.ok((select string_agg(r ->> 'code', ',' order by r ->> 'code') from jsonb_array_elements((erp_api.series_create_defaults(t.br(t.a(), 'A1'), gen_random_uuid())) -> 'created') r)
            = 'ADJ_IN-A1,ADJ_OUT-A1,CONS-A1,GRN-A1,OPN,TRF-A1', 'series defaults: ADJ+, ADJ-, CONS, GRN, TRF (E160) per branch, OPN organisation-wide (the enabled stock types)');
select erp_api.series_create_defaults(t.br(t.a(), 'A2'), gen_random_uuid());

-- ---------- GRN ----------
select t.as(3);
select t.keep(erp_api.doc_save_draft('GRN', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'warehouse_id', t.wh('W2'), 'extra', jsonb_build_object('mark', 'ABC'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 1), jsonb_build_object('item_id', t.it('SVC'), 'qty', 1, 'unit_price', 1))), gen_random_uuid()));
select t.ok(t.codes(t.j() -> 'problems') = '-:required:counterparty_id,-:invalid:extra.mark,-:invalid:warehouse_id,1:required:unit_price,2:invalid:item_id',
            'GRN problems: supplier, MARK digits, warehouse of another branch, unit cost, a service line');
select t.ok(t.codes((erp_api.doc_save_draft('GRN', jsonb_build_object('document_id', t.j() ->> 'document_id', 'version', 1, 'warehouse_id', t.wh('W1'), 'counterparty_id', t.cp('Customer'),
  'extra', '{}'::jsonb, 'lines', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 1, 'unit_price', 1))), gen_random_uuid())) -> 'problems') = '-:invalid:counterparty_id',
            'GRN from a customer: refused (a supplier is needed)');
select t.keep(erp_api.doc_save_draft('GRN', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'warehouse_id', t.wh('W1'), 'counterparty_id', t.cp('Supplier'),
  'ext_number', 'DN-7781', 'ext_date', t.today() - 1, 'extra', jsonb_build_object('mark', '400001234567890'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 10, 'unit_price', 5, 'discount_pct', 10),
                             jsonb_build_object('item_id', t.it('IT2'), 'qty', 3, 'unit_price', '2.505'))), gen_random_uuid()));
select t.put('g1', t.j() ->> 'document_id');
select t.ok(jsonb_array_length(t.j() -> 'problems') = 0 and t.j() ->> 'total_net' = '52.52' and t.j() ->> 'total_vat' = '0.00'
            and (select string_agg(a ->> 'to_state', ',') from jsonb_array_elements(t.j() -> 'actions') a) = 'posted', 'valid GRN: net 45.00 + 7.52 (3 x 2.505 half-up), no VAT, the warehouse member may post');
select t.keep(erp_api.doc_set_state(t.id('g1')::uuid, 'posted', '{}', gen_random_uuid()));
select t.ok(t.j() #>> '{document,doc_no}' = 'GRN-A1/000001' and t.bal('W1', 'IT1') = 10 and t.bal('W1', 'IT2') = 3 and (t.doc(t.id('g1'))).total_cost = 52.52,
            'GRN posted: GRN-A1/000001, stock in W1, total cost = net');
select t.ok((t.ic('IT1')).value_avg = 45.00 and (t.ic('IT1')).avg_cost = 4.5 and (select last_purchase_price from erp.items where item_id = t.it('IT1')) = 4.5
            and (t.ic('IT2')).avg_cost = 2.506667, 'cost: discount included (4.50), 7.52 / 3 = 2.506667; last purchase price set');
select t.ok(not (t.j() -> 'document' ? 'total_cost') and not (t.j() #> '{document,lines,0}' ? 'unit_cost'), 'warehouse member: no cost columns in the reply (no cost.read)');
select t.fails(format($$select erp_api.doc_set_state('%s', 'cancelled', '{"reason": "x"}', gen_random_uuid())$$, t.id('g1')), 'ERP_FORBIDDEN', 'the warehouse member cannot cancel a GRN');
select t.as(4);
select t.ok((erp_api.doc_get(t.id('g1')::uuid)) #>> '{lines,0,cost_value}' = '45.00', 'accounting reads the GRN with its cost');
select t.fails(format($$select erp_api.doc_save_draft('GRN', '{"branch_id": "%s"}', gen_random_uuid())$$, t.br(t.a(), 'A1')), 'ERP_FORBIDDEN', 'accounting cannot create a GRN (matrix r)');
select t.as(5);
select t.fails(format($$select erp_api.doc_get('%s')$$, t.id('g1')), 'ERP_FORBIDDEN', 'clinic_user cannot read a GRN (matrix -)');
select t.as(2);
select t.ok((erp_api.doc_set_state(t.id('g1')::uuid, 'cancelled', '{"reason": "wrong supplier"}', gen_random_uuid())) #>> '{document,state}' = 'cancelled'
            and t.bal('W1', 'IT1') = 0 and (t.ic('IT1')).value_avg = 0, 'manager cancels: stock and value back to 0');

-- ---------- OPN ----------
select t.as(3);
select t.fails(format($$select erp_api.doc_save_draft('OPN', '{"branch_id": "%s"}', gen_random_uuid())$$, t.br(t.a(), 'A1')), 'ERP_FORBIDDEN', 'the warehouse member cannot prepare an OPN');
select t.as(2);
select t.keep(erp_api.doc_save_draft('OPN', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'warehouse_id', t.wh('W1'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 20, 'unit_price', 4), jsonb_build_object('item_id', t.it('IT1'), 'qty', 1, 'unit_price', 4))), gen_random_uuid()));
select t.ok(t.codes(t.j() -> 'problems') = '1:duplicate:item_id', 'OPN: an item on two lines is refused (merge)');
select t.keep(erp_api.doc_save_draft('OPN', jsonb_build_object('document_id', t.j() ->> 'document_id', 'version', 1,
  'lines', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 20, 'unit_price', 4), jsonb_build_object('item_id', t.it('IT2'), 'qty', 7, 'unit_price', 1.1))), gen_random_uuid()));
select t.put('o1', t.j() ->> 'document_id');
select t.ok((select string_agg(a ->> 'to_state', ',') from jsonb_array_elements(t.j() -> 'actions') a) = 'pending_approval', 'manager: OPN can only be submitted');
select t.fails(format($$select erp_api.doc_set_state('%s', 'posted', '{}', gen_random_uuid())$$, t.id('o1')), 'ERP_FORBIDDEN', 'manager cannot post an OPN (owner approves)');
select erp_api.doc_set_state(t.id('o1')::uuid, 'pending_approval', '{}', gen_random_uuid());
select t.as(1);
select t.keep(erp_api.doc_set_state(t.id('o1')::uuid, 'posted', '{}', gen_random_uuid()));
select t.ok(t.j() #>> '{document,doc_no}' = 'OPN/000001' and t.bal('W1', 'IT1') = 20 and (t.ic('IT1')).value_avg = 80.00 and (t.doc(t.id('o1'))).approved_by is not null,
            'owner approves: OPN/000001 (organisation-wide series), stock 20 at 4.00');

-- ---------- opening-stock import ----------
select t.as(2);
select t.keep(erp_api.opening_import(jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'warehouse_id', t.wh('W1')),
  '[{"item": "it1", "qty": "5", "unit_cost": "3,25"}, {"item": "NOPE", "qty": "1", "unit_cost": "1"}, {"item": "IT2", "qty": "-1", "unit_cost": "x"},
    {"item": "SVC", "qty": "1", "unit_cost": "1"}, {"item": "IT1", "qty": "1", "unit_cost": "1", "lot": "L1"}]', true, gen_random_uuid()));
select t.ok((t.j() ->> 'dry_run')::boolean and (select string_agg((e ->> 'row') || ':' || (e ->> 'code') || ':' || (e ->> 'field'), ',' order by (e ->> 'row')::int, e ->> 'field', e ->> 'code')
                                                  from jsonb_array_elements(t.j() -> 'errors') e)
            = '2:unknown:item,3:invalid:qty,3:invalid:unit_cost,4:invalid:item,5:duplicate:item,5:not_editable:lot',
            'opening import check: unknown item, bad qty / cost, service, item twice, unknown column; each with its row');
select t.ok(t.count($$select 1 from erp.documents where source = 'import'$$) = 0, 'nothing created');
select t.keep(erp_api.opening_import(jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'warehouse_id', t.wh('W1')),
  '[{"item": "it1", "qty": "5", "unit_cost": "3,25"}, {"item": "IT2", "qty": "2.5", "unit_cost": "0"}]', true, gen_random_uuid()));
select t.ok((t.j() ->> 'dry_run')::boolean and t.j() ->> 'total_value' = '16.25' and jsonb_array_length(t.j() -> 'errors') = 0, 'clean check: total value 16.25');
select t.keep(erp_api.opening_import(jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'warehouse_id', t.wh('W1')),
  '[{"item": "it1", "qty": "5", "unit_cost": "3,25"}, {"item": "IT2", "qty": "2.5", "unit_cost": "0"}]', false, '00000000-0000-4000-c150-000000000001'));
select t.put('imp', t.j() #>> '{document,document_id}');
select t.ok(not (t.j() ->> 'dry_run')::boolean and t.j() #>> '{document,state}' = 'draft' and t.j() #>> '{document,doc_type}' = 'OPN' and t.j() #>> '{document,source}' = 'import'
            and t.j() #>> '{document,total_net}' = '16.25' and jsonb_array_length(t.j() #> '{document,lines}') = 2 and jsonb_array_length(t.j() #> '{document,problems}') = 0,
            'import: ONE OPN draft with the lines, nothing posted');
select t.ok((erp_api.opening_import(jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'warehouse_id', t.wh('W1')),
  '[{"item": "it1", "qty": "5", "unit_cost": "3,25"}, {"item": "IT2", "qty": "2.5", "unit_cost": "0"}]', false, '00000000-0000-4000-c150-000000000001')) #>> '{document,document_id}' = t.id('imp')
            and t.count($$select 1 from erp.documents where source = 'import'$$) = 1, 'same key: same draft, not imported twice');
select t.ok(t.problems(format($$select erp_api.opening_import('{"branch_id": "%s", "warehouse_id": "%s"}', '[{"item": "IT1", "qty": 1, "unit_cost": 1}]', true, gen_random_uuid())$$,
                              t.br(t.a(), 'A1'), t.wh('W2'))) -> 0 ->> 'field' = 'warehouse_id', 'the warehouse must belong to the branch');
select t.fails(format($$select erp_api.opening_import('{"branch_id": "%s", "warehouse_id": "%s"}', '[{"item": "IT1", "qty": 1, "unit_cost": 1}]', true, gen_random_uuid())$$,
                      t.br(t.b(), 'B1'), t.wh('BW')), 'ERP_TENANT', 'a branch of tenant B: ERP_TENANT');
select t.ok(t.problems(format($$select erp_api.opening_import('{"branch_id": "%s", "warehouse_id": "%s"}', '%s', true, gen_random_uuid())$$, t.br(t.a(), 'A1'), t.wh('W1'),
                              (select jsonb_agg(jsonb_build_object('item', 'IT1', 'qty', 1, 'unit_cost', 1)) from generate_series(1, 2001)))) -> 0 ->> 'code' = 'too_many',
            'more than 2000 rows: refused');
select t.as(3);
select t.fails(format($$select erp_api.opening_import('{"branch_id": "%s", "warehouse_id": "%s"}', '[{"item": "IT1", "qty": 1, "unit_cost": 1}]', true, gen_random_uuid())$$,
                      t.br(t.a(), 'A1'), t.wh('W1')), 'ERP_FORBIDDEN', 'the warehouse member cannot import opening stock');
select t.as(1);
select t.ok((erp_api.doc_set_state(t.id('imp')::uuid, 'posted', '{}', gen_random_uuid())) #>> '{document,doc_no}' = 'OPN/000002' and t.bal('W1', 'IT1') = 25 and t.bal('W1', 'IT2') = 9.5
            and (t.ic('IT1')).value_avg = 96.25, 'the owner posts the imported OPN: stock 25 (80.00 + 16.25)');
reset role;


-- =================== T12: ADJ_IN / ADJ_OUT, CONS, doc_check, alerts, negative-stock report, G7 ===================
create function t.whbr(p_code text) returns uuid language sql security definer as $$ select branch_id from erp.warehouses where code = p_code $$;
create function t.post(p_id text, p_ack boolean default false) returns jsonb language sql as $$
  select erp_api.doc_set_state(p_id::uuid, 'posted', jsonb_build_object('ack_warnings', p_ack), gen_random_uuid()) $$;
create function t.draft(p_type text, p_lines jsonb, p_extra jsonb default '{}', p_wh text default 'W1', p_more jsonb default '{}') returns jsonb language sql as $$
  select erp_api.doc_save_draft(p_type, jsonb_build_object('branch_id', t.whbr(p_wh), 'warehouse_id', t.wh(p_wh),
                                                           'extra', p_extra, 'lines', p_lines) || p_more, gen_random_uuid()) $$;
create function t.alerts(p_kind text) returns text language sql security definer as $$
  select coalesce(string_agg((params ->> 'item_code') || '@' || (params ->> 'warehouse_code') || '=' || (params ->> 'qty'), ',' order by params ->> 'item_code'), '')
    from erp.alerts where tenant_id = t.a() and kind = p_kind and resolved_at is null $$;
grant execute on all functions in schema t to authenticated;
set local role authenticated;
-- stock now: W1 IT1 25 (value 96.25, avg 3.85), IT2 9.5
select t.as(3);
select t.keep(t.draft('ADJ_OUT', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 2))));
select t.ok(t.codes(t.j() -> 'problems') = '-:required:extra.reason', 'ADJ- needs a reason');
select t.ok(t.codes((t.draft('ADJ_OUT', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 2)), '{"reason": "found"}')) -> 'problems') = '-:invalid:extra.reason',
            '"found" is not a reason for ADJ-');
select t.ok(t.codes((t.draft('ADJ_OUT', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 2, 'unit_price', 1)), '{"reason": "damaged"}')) -> 'problems') = '1:invalid:unit_price',
            'ADJ- has no prices (it leaves at cost)');
select t.keep(t.post((t.draft('ADJ_OUT', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 2)), '{"reason": "damaged"}')) ->> 'document_id'));
select t.ok(t.j() #>> '{document,doc_no}' = 'ADJ_OUT-A1/000001' and t.bal('W1', 'IT1') = 23 and (t.ic('IT1')).value_avg = 88.55,
            'no value limit set: the warehouse member posts ADJ- of 2 at 3.85 = 7.70');
select t.keep(t.post((t.draft('ADJ_IN', jsonb_build_array(jsonb_build_object('item_id', t.it('IT2'), 'qty', 1.5)), '{"reason": "found"}')) ->> 'document_id'));
select t.ok(t.bal('W1', 'IT2') = 11 and (t.ic('IT2')).value_avg = (select round(7.70 + 1.5 * round(7.70 / 9.5, 6), 2)),
            'ADJ+ without a cost comes in at the current average cost');
reset role;
update erp.tenant_settings set thresholds = '{"adj_value": 50}' where tenant_id = t.a();
set local role authenticated;
select t.as(3);
select t.keep(t.draft('ADJ_OUT', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 10)), '{"reason": "lost"}'));
select t.put('adj_big', t.j() ->> 'document_id');
select t.ok((erp_api.doc_check(t.id('adj_big')::uuid)) ->> 'value' is null, 'doc_check gives no value without cost.read');
select t.as(2);
select t.ok((erp_api.doc_check(t.id('adj_big')::uuid)) ->> 'value' = '38.50', 'doc_check: value of the ADJ- at the current cost = 38.50 (manager, cost.read)');
select t.as(3);
select t.ok(t.post(t.id('adj_big')) #>> '{document,state}' = 'posted', 'under the limit (38.50 <= 50): posted by the warehouse member');
select t.keep(t.draft('ADJ_IN', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 10, 'unit_price', 6)), '{"reason": "correction"}'));
select t.put('adj_in', t.j() ->> 'document_id');
select t.ok((select string_agg(a ->> 'to_state', ',') from jsonb_array_elements(t.j() -> 'actions') a) = 'pending_approval', 'ADJ+ of 60.00 > 50: only submit');
select t.fails(format($$select t.post('%s')$$, t.id('adj_in')), 'ERP_STATE', 'posting it: ERP_STATE (needs approval)');
select erp_api.doc_set_state(t.id('adj_in')::uuid, 'pending_approval', '{}', gen_random_uuid());
select t.fails(format($$select t.post('%s')$$, t.id('adj_in')), 'ERP_FORBIDDEN', 'the warehouse member cannot approve');
select t.as(2);
select t.ok(t.post(t.id('adj_in')) #>> '{document,state}' = 'posted' and t.bal('W1', 'IT1') = 23 and (t.doc(t.id('adj_in'))).approved_by is not null, 'manager approves the ADJ+');
reset role;
update erp.tenant_settings set thresholds = '{}' where tenant_id = t.a();

-- ---------- CONS ----------
update erp.items set min_level = 20 where item_id = t.it('IT1');
set local role authenticated;
select t.as(5);
select t.keep(t.draft('CONS', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 5, 'ext_line_ref', 'line:7f')), '{"cost_centre": "Surgery 1"}', 'W1',
                      '{"ext_ref": "card:0042"}'));
select t.put('c1', t.j() ->> 'document_id');
select t.ok(t.j() ->> 'ext_ref' = 'card:0042' and t.j() #>> '{lines,0,ext_line_ref}' = 'line:7f' and t.j() #>> '{extra,cost_centre}' = 'Surgery 1' and jsonb_array_length(t.j() -> 'problems') = 0,
            'clinic_user prepares a CONS in its branch: cost centre, ext_ref, ext_line_ref');
select t.keep(t.post(t.id('c1')));
select t.ok(t.j() #>> '{document,state}' = 'posted' and t.bal('W1', 'IT1') = 18 and not (t.j() #> '{document,lines,0}' ? 'cost_value'),
            'clinic_user posts it: stock 18; no cost in its reply (no cost.read)');
select t.ok(t.alerts('low_stock') = 'IT1@W1=18.0000', 'low-stock alert: 18 < minimum 20');
select t.fails(format($$select erp_api.doc_set_state('%s', 'cancelled', '{"reason": "x"}', gen_random_uuid())$$, t.id('c1')), 'ERP_FORBIDDEN', 'clinic_user cannot reverse a CONS');
select t.fails($$select t.draft('CONS', '[]', '{}', 'W2')$$, 'ERP_FORBIDDEN', 'clinic_user (A1) cannot consume in A2');
select t.ok(t.codes((t.draft('CONS', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 1)), jsonb_build_object('cost_centre', repeat('x', 61)))) -> 'problems')
            = '-:invalid:extra.cost_centre', 'cost centre: at most 60 characters');
select t.as(2);
select t.ok((t.doc(t.id('c1'))).total_cost = 23.92 and (erp_api.doc_get(t.id('c1')::uuid)) #>> '{lines,0,cost_value}' = '23.92', 'manager sees the CONS cost (5 x avg 110.05 / 23 = 4.784783 -> 23.92)');
select t.ok((erp_api.doc_set_state(t.id('c1')::uuid, 'cancelled', '{"reason": "wrong card"}', gen_random_uuid())) #>> '{document,state}' = 'cancelled' and t.bal('W1', 'IT1') = 23
            and t.alerts('low_stock') = '', 'manager reverses the CONS: stock back to 23, the low-stock alert resolves itself');

-- ---------- negative stock: doc_check, ack, alert, report ----------
select t.as(5);
select t.keep(t.draft('CONS', jsonb_build_array(jsonb_build_object('item_id', t.it('IT2'), 'qty', 15))));
select t.put('neg', t.j() ->> 'document_id');
select t.keep(erp_api.doc_check(t.id('neg')::uuid));
select t.ok(t.j() #>> '{warnings,0,code}' = 'W_STOCK_NEGATIVE' and t.j() #>> '{warnings,0,item_code}' = 'IT2' and t.j() #>> '{warnings,0,qty_after}' = '-4.0000'
            and jsonb_array_length(t.j() -> 'problems') = 0 and (t.doc(t.id('neg'))).state = 'draft', 'doc_check: the warning a post would give, nothing written');
select t.ok(not (t.post(t.id('neg')) ->> 'posted')::boolean and t.bal('W1', 'IT2') = 11, 'post without ack: not posted');
select t.ok((t.post(t.id('neg'), true) ->> 'posted')::boolean and t.bal('W1', 'IT2') = -4 and t.alerts('negative_stock') = 'IT2@W1=-4.0000',
            'post with ack: -4, one negative_stock alert');
select t.keep(t.post((t.draft('CONS', jsonb_build_array(jsonb_build_object('item_id', t.it('IT2'), 'qty', 1)))) ->> 'document_id', true));
select t.ok(t.alerts('negative_stock') = 'IT2@W1=-4.0000' and t.count($$select 1 from erp.alerts where kind = 'negative_stock' and resolved_at is null$$) = 1,
            'a second negative post keeps ONE open alert per (warehouse, item)');
select t.keep(erp_api.report_negative_stock());
select t.ok(jsonb_array_length(t.j() -> 'rows') = 1 and t.j() #>> '{rows,0,item_code}' = 'IT2' and t.j() #>> '{rows,0,qty}' = '-5.0000'
            and t.j() #>> '{rows,0,doc_no}' = 'CONS-A1/000002' and t.j() #>> '{rows,0,days_negative}' = '0' and not (t.j() #> '{rows,0}' ? 'provisional_value'),
            'negative-stock report: item, qty -5, the CONS that took it below zero; no value for clinic_user');
select t.as(1);
select t.ok((erp_api.report_negative_stock()) #>> '{rows,0,provisional_value}' is not null and (erp_api.report_negative_stock()) #>> '{rows,0,posted_by_email}' = 'user5@erp.test',
            'owner: provisional value and the member who posted it');
select t.ok((select count(*) from erp.rpt_erp_negative_stock) = 1 and (select provisional_value from erp.rpt_erp_negative_stock) is not null, 'view rpt_erp_negative_stock (owner)');
select t.as(3);
select t.ok((select count(*) from erp.rpt_erp_negative_stock) = 1 and (select provisional_value from erp.rpt_erp_negative_stock) is null,
            'view as the warehouse member (security_invoker): the row, no value (item_costs hidden by RLS)');
select t.as(6);
select t.ok(jsonb_array_length((erp_api.report_negative_stock(jsonb_build_object('branch_id', t.br(t.a(), 'A1')))) -> 'rows') = 1, 'readonly (A1) reads the report');
select t.as(1);
select erp_api.doc_set_state((t.draft('GRN', jsonb_build_array(jsonb_build_object('item_id', t.it('IT2'), 'qty', 10, 'unit_price', 1)), '{}', 'W1',
                               jsonb_build_object('counterparty_id', t.cp('Supplier'))) ->> 'document_id')::uuid, 'posted', '{}', gen_random_uuid());
select t.ok(t.alerts('negative_stock') = '' and jsonb_array_length((erp_api.report_negative_stock()) -> 'rows') = 0, 'a receipt covers it: alert resolved, report empty');
reset role;
update erp.tenant_settings set negative_stock = 'block' where tenant_id = t.a();
set local role authenticated;
select t.as(1);
select t.keep(t.draft('CONS', jsonb_build_array(jsonb_build_object('item_id', t.it('IT2'), 'qty', 500))));
select t.ok((erp_api.doc_check((t.j() ->> 'document_id')::uuid)) #>> '{problems,0,code}' = 'stock_negative', 'setting block: doc_check reports a blocking problem');
select t.fails(format($$select t.post('%s', true)$$, t.j() ->> 'document_id'), 'ERP_STOCK_NEGATIVE', '...and the post is refused, even with ack');
reset role;
update erp.tenant_settings set negative_stock = 'warn' where tenant_id = t.a();

-- ---------- golden G7: negative stock under warn, then a receipt covers it ----------
create table t.g7 (step int, op text, qty numeric, unit_cost numeric, src_step int, exp_qty numeric, exp_value_avg numeric, exp_value_fifo numeric,
                   exp_move_avg numeric, exp_move_fifo numeric, exp_layers text, exp_corr_avg numeric, exp_corr_fifo numeric, exp_alert int);
\copy t.g7 from 'golden/G7.csv' with (format csv, header)
create table t.g7res (step int, got text, want text);
grant select, insert on t.g7, t.g7res to authenticated;
insert into erp.items (tenant_id, code, name, base_unit_id) select t.a(), 'G7', 'Golden 7', unit_id from erp.units where tenant_id = t.a() and code = 'PCS';
create function t.num(n numeric) returns text language sql immutable as $$
  select case when n is null then '' when n::text like '%.%' then rtrim(rtrim(n::text, '0'), '.') else n::text end $$;
create function t.layers(p_item uuid) returns text language sql security definer as $$
  select coalesce(string_agg(t.num(qty_left) || '@' || t.num(unit_cost), ';' order by layer_date, seq, layer_id), '')
    from erp.stock_layers where item_id = p_item and qty_left > 0 and void_run is null $$;
create function t.g7state(p_doc uuid) returns text language sql security definer as $$
  select concat_ws('|', t.num(c.qty), c.value_avg, c.value_fifo, m.value_avg, m.value_fifo, t.layers(c.item_id), k.value_avg, k.value_fifo,
                   (select count(*) from erp.alerts a where a.kind = 'negative_stock' and a.resolved_at is null and a.params ->> 'item_code' = 'G7'))
    from erp.item_costs c
    join erp.stock_moves m on m.document_id = p_doc and m.kind = 'normal'
    left join erp.stock_moves k on k.document_id = p_doc and k.kind = 'value_only'
   where c.item_id = t.it('G7') $$;
grant execute on all functions in schema t to authenticated;
set local role authenticated;
select t.as(1);
do $$ declare g record; d jsonb; begin
  for g in select * from t.g7 order by step loop
    d := case g.op when 'in' then t.draft('GRN', jsonb_build_array(jsonb_build_object('item_id', t.it('G7'), 'qty', g.qty, 'unit_price', g.unit_cost)), '{}', 'W1',
                                          jsonb_build_object('counterparty_id', t.cp('Supplier')))
                   else t.draft('CONS', jsonb_build_array(jsonb_build_object('item_id', t.it('G7'), 'qty', g.qty))) end;
    perform t.post(d ->> 'document_id', true);
    insert into t.g7res values (g.step, t.g7state((d ->> 'document_id')::uuid),
      concat_ws('|', t.num(g.exp_qty), g.exp_value_avg, g.exp_value_fifo, g.exp_move_avg, g.exp_move_fifo, coalesce(g.exp_layers, ''), g.exp_corr_avg, g.exp_corr_fifo, g.exp_alert));
  end loop;
end $$;
select t.ok(not exists (select 1 from t.g7res where got <> want), 'golden G7 (GRN in, CONS out, warn + ack): ' ||
            coalesce((select string_agg('#' || step || ' got ' || got || ' want ' || want, '; ' order by step) from t.g7res where got <> want), 'all 5 steps equal'));
reset role;
select t.ok(jsonb_array_length(erp.stock_integrity(t.a())) = 0, 'integrity of the whole tenant clean after every T11 / T12 scenario');


-- =================== T14 read models: on hand, stock card, item lookup, availability, alerts ===================
reset role;
update erp.items set min_level = 1000 where item_id = t.it('IT2');
insert into erp.item_barcodes (tenant_id, barcode, item_id) values (t.a(), '4006381333931', t.it('IT2'));
set local role authenticated;
select t.as(1);
select t.post((t.draft('CONS', jsonb_build_array(jsonb_build_object('item_id', t.it('IT2'), 'qty', 1)))) ->> 'document_id', true);
select erp_api.doc_set_state((t.draft('GRN', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 4, 'unit_price', 2)), '{}', 'W2',
                               jsonb_build_object('counterparty_id', t.cp('Supplier'))) ->> 'document_id')::uuid, 'posted', '{}', gen_random_uuid());
select t.keep(erp_api.stock_on_hand());
select t.ok((select string_agg((r ->> 'item_code') || '@' || (r ->> 'warehouse_code'), ',') from jsonb_array_elements(t.j() -> 'rows') r) like 'G7@W1,IT1@W1,IT1@W2,IT2@W1%'
            and (select (r ->> 'low')::boolean from jsonb_array_elements(t.j() -> 'rows') r where r ->> 'item_code' = 'IT2') and t.j() #> '{rows,0}' ? 'value',
            'owner: on hand of every warehouse, low flag (IT2 below 1000), values');
select t.as(3);
select t.keep(erp_api.stock_on_hand());
select t.ok(not exists (select 1 from jsonb_array_elements(t.j() -> 'rows') r where r ->> 'warehouse_code' = 'W2') and not (t.j() #> '{rows,0}' ? 'value'),
            'warehouse member (A1): only W1, no values (no cost.read)');
select t.fails(format($$select erp_api.stock_on_hand('{"warehouse_id": "%s"}')$$, t.wh('W2')), 'ERP_FORBIDDEN', 'a warehouse of another branch: ERP_FORBIDDEN');
select t.ok((select string_agg(r ->> 'item_code', ',') from jsonb_array_elements((erp_api.stock_on_hand('{"only": "low"}')) -> 'rows') r) = 'IT2'
            and (erp_api.stock_on_hand('{"q": "4006381333931"}')) #>> '{rows,0,item_code}' = 'IT2', 'filters: only low; q = exact barcode');
select t.ok((erp_api.stock_on_hand('{}', (erp_api.stock_on_hand('{}', null, 1)) -> 'next', 1)) #>> '{rows,0,item_code}' = 'IT1', 'keyset paging of the on-hand list');
select t.as(5);
select t.keep(erp_api.stock_card(t.it('IT1')));
select t.ok(jsonb_array_length(t.j() -> 'rows') >= 6 and (t.j() -> 'rows' -> -1 ->> 'running_qty')::numeric = t.bal('W1', 'IT1') and not (t.j() #> '{rows,0}' ? 'value')
            and t.j() #>> '{rows,0,doc_type}' = 'GRN', 'clinic_user: stock card of IT1 (its branch), running qty ends at the balance, no values');
select t.keep(erp_api.stock_card(t.it('IT1'), '{}', null, 2));
select t.ok((erp_api.stock_card(t.it('IT1'), '{}', t.j() -> 'next', 2)) ->> 'opening_qty' = (t.j() -> 'rows' -> -1 ->> 'running_qty'),
            'stock card paging: the next page opens with the running qty of the previous one');
select t.as(2);
select t.ok((erp_api.stock_card(t.it('IT1'))) #> '{rows,0}' ? 'value_fifo' and (erp_api.stock_card(t.it('IT1'))) #>> '{rows,0,official}' = 'avg', 'manager: values of both methods');
select t.as(11);
select t.fails(format($$select erp_api.stock_card('%s')$$, t.it('IT1')), 'ERP_TENANT', 'tenant B: an item of A is ERP_TENANT');
select t.as(3);
select t.keep(erp_api.item_lookup('4006381333931', t.wh('W1')));
select t.ok(t.j() #>> '{rows,0,code}' = 'IT2' and (t.j() #>> '{rows,0,barcode_match}')::boolean and (t.j() #>> '{rows,0,low}')::boolean
            and (t.j() #>> '{rows,0,on_hand}')::numeric = t.bal('W1', 'IT2'), 'item_lookup: the barcode match first, on hand in W1, low flag');
select t.ok(jsonb_array_length((erp_api.item_lookup('it', null)) -> 'rows') = 3 and (erp_api.item_lookup('svc', null)) #>> '{rows,0,code}' = 'SVC', 'item_lookup by code prefix or name');
select t.keep(erp_api.item_availability(t.it('IT1')));
select t.ok(jsonb_array_length(t.j() -> 'warehouses') = 1 and t.j() #>> '{warehouses,0,warehouse_code}' = 'W1' and not (t.j() ? 'avg_cost'), 'availability per visible warehouse');
select t.keep(erp_api.alert_list('{"kind": "low_stock"}'));
select t.ok(jsonb_array_length(t.j() -> 'rows') = 1 and t.j() #>> '{rows,0,params,item_code}' = 'IT2' and not (t.j() #>> '{rows,0,can_resolve}')::boolean,
            'alert_list: the low-stock alert of A1; the warehouse member cannot resolve it');
select t.fails(format($$select erp_api.alert_resolve('%s', gen_random_uuid())$$, t.j() #>> '{rows,0,alert_id}'), 'ERP_FORBIDDEN', 'alert_resolve needs alert.resolve');
select t.as(2);
select t.keep(erp_api.alert_resolve(((erp_api.alert_list('{"kind": "low_stock"}')) #>> '{rows,0,alert_id}')::uuid, gen_random_uuid()));
select t.ok(t.j() ->> 'resolved_at' is not null and jsonb_array_length((erp_api.alert_list('{"kind": "low_stock"}')) -> 'rows') = 0
            and exists (select 1 from jsonb_array_elements((erp_api.alert_list('{"kind": "low_stock", "include_resolved": true}')) -> 'rows') r where r ->> 'alert_id' = t.j() ->> 'alert_id'),
            'manager resolves it; include_resolved shows it again');
reset role;

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
