-- =====================================================================
-- iSmile ERP  -  tests for E135_conversions.sql (T44): full conversion (totals to the cent, links, status full),
-- partial 6 + 4 (partial -> full), nothing left / above remaining, a deleted or cancelled target gives the quantity
-- back, N:1 with the same counterparty, mixed sources and pairs without N:1 refused, locked item / unit / quantity in
-- the target draft, source with a live target cannot be cancelled, copy, the "Convert to" menu, roles, tenancy,
-- idempotency. Two TEST types ZSRC -> ZTGT (bill, N:1) and ZSRC -> ZCRD (credit, 1:1). (Concurrency: runner,
-- tests/concurrency_convert.sh.) One transaction, ROLLED BACK. Last line: ALL TESTS PASSED + number of checks.
-- =====================================================================
begin;
\ir _helpers.sql

create table t.ids (a uuid, b uuid);
insert into t.ids select t.tenant('va'), t.tenant('vb');
create function t.a() returns uuid language sql security definer as $$ select a from t.ids $$;
create function t.b() returns uuid language sql security definer as $$ select b from t.ids $$;
select t.init(t.a()), t.init(t.b());
select t.branch(t.a(), 'A1', 0), t.branch(t.a(), 'A2', 1), t.branch(t.b(), 'B1', 0);
select t.member(t.a(), 1, 'owner'), t.member(t.a(), 2, 'manager', array[t.br(t.a(), 'A1')]), t.member(t.a(), 6, 'readonly', array[t.br(t.a(), 'A1')]),
       t.member(t.b(), 11, 'owner');
insert into erp.doc_types (doc_type, name, area, cap_prefix, sort, enabled, price_kind, needs_counterparty) values
  ('ZSRC', 'Test source', 'sales', 'zcv', 980, true, 'sale', true), ('ZTGT', 'Test target', 'sales', 'zcv', 981, true, 'sale', true),
  ('ZCRD', 'Test credit', 'sales', 'zcv', 982, true, 'sale', true);
insert into erp.doc_transitions (doc_type, from_state, to_state, cap, action, label)
select dt, f, t2, c, a, 'x' from unnest(array['ZSRC', 'ZTGT', 'ZCRD']) dt, (values ('draft', 'posted', 'create', 'post'), ('posted', 'cancelled', 'approve', 'cancel')) v(f, t2, c, a);
insert into erp.doc_conversions (source_type, target_type, kind, n_to_one) values ('ZSRC', 'ZTGT', 'bill', true), ('ZSRC', 'ZCRD', 'credit', false);
insert into erp.capabilities (capability, area) values ('doc.zcv.read', 'test'), ('doc.zcv.create', 'test'), ('doc.zcv.approve', 'test');
insert into erp.role_caps (tenant_id, role, capability) values (t.a(), 'owner', 'doc.zcv.read'), (t.a(), 'owner', 'doc.zcv.create'), (t.a(), 'owner', 'doc.zcv.approve'),
  (t.a(), 'manager', 'doc.zcv.read'), (t.a(), 'manager', 'doc.zcv.create'), (t.a(), 'readonly', 'doc.zcv.read'), (t.b(), 'owner', 'doc.zcv.read'), (t.b(), 'owner', 'doc.zcv.create');
insert into erp.series (tenant_id, branch_id, doc_type, code) select t.a(), branch_id, d, d || '-' || code from erp.branches, unnest(array['ZSRC', 'ZTGT', 'ZCRD']) d where tenant_id = t.a();
insert into erp.items (tenant_id, code, name, base_unit_id, vat_class_id)
select t.a(), c, 'Item ' || c, (select unit_id from erp.units where tenant_id = t.a() and code = 'PCS'), (select vat_class_id from erp.vat_classes where tenant_id = t.a() and code = 'VAT24')
  from unnest(array['I1', 'I2']) c;
insert into erp.counterparties (tenant_id, name, kind) values (t.a(), 'Cust A', 'customer'), (t.a(), 'Cust B', 'customer');
create function t.it(p_code text) returns uuid language sql security definer as $$ select item_id from erp.items where tenant_id = t.a() and code = p_code $$;
create function t.cp(p_name text) returns uuid language sql security definer as $$ select counterparty_id from erp.counterparties where tenant_id = t.a() and name = p_name $$;
create function t.doc(p_id uuid) returns erp.documents language sql security definer as $$ select d from erp.documents d where document_id = p_id $$;
create function t.lines(p_id uuid) returns jsonb language sql security definer as $$
  select jsonb_agg(jsonb_build_object('item', i.code, 'qty', l.qty_base, 'net', l.net, 'vat', l.vat) order by l.line_no) from erp.document_lines l join erp.items i using (tenant_id, item_id)
   where l.document_id = p_id $$;
create function t.line(p_id uuid, p_no int) returns uuid language sql security definer as $$ select line_id from erp.document_lines where document_id = p_id and line_no = p_no $$;
create function t.status(p_id uuid, p_kind text) returns text language sql security definer as $$
  select coalesce((select status from erp.v_doc_conversion_status where document_id = p_id and kind = p_kind), 'none') $$;
create function t.rem(p_line uuid, p_kind text) returns numeric language sql security definer as $$ select remaining from erp.v_line_remaining where line_id = p_line and kind = p_kind $$;
-- a posted ZSRC: I1 10 x 3.335 (net 33.35, VAT 8.00), I2 3 x 1.10 (3.30, 0.79)
create function t.src(p_cp text default 'Cust A') returns uuid language plpgsql as $$
declare d jsonb; begin
  d := erp_api.doc_save_draft('ZSRC', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'counterparty_id', t.cp(p_cp),
         'lines', jsonb_build_array(jsonb_build_object('item_id', t.it('I1'), 'qty', 10, 'unit_price', 3.335), jsonb_build_object('item_id', t.it('I2'), 'qty', 3, 'unit_price', 1.1))), gen_random_uuid());
  perform erp_api.doc_set_state((d ->> 'document_id')::uuid, 'posted', '{}', gen_random_uuid());
  return (d ->> 'document_id')::uuid;
end $$;
create table t.v (k text primary key, id uuid);
create function t.put(p_k text, p_id uuid) returns void language sql security definer as $$ insert into t.v values (p_k, p_id) on conflict (k) do update set id = excluded.id $$;
create function t.id(p_k text) returns uuid language sql security definer as $$ select id from t.v where k = p_k $$;
grant select, insert, update on t.v to authenticated;
grant execute on all functions in schema t to authenticated;

set local role authenticated;
select t.as(1);
select t.put('s1', t.src());
select t.ok(t.status(t.id('s1'), 'bill') = 'open' and t.status(t.id('s1'), 'credit') = 'open' and t.rem(t.line(t.id('s1'), 1), 'bill') = 10, 'a posted source: open per kind, remaining = quantity');
-- V1 full conversion
select t.keep(erp_api.doc_convert(array[t.id('s1')], 'ZTGT', null, '00000000-0000-4000-c135-000000000001'));
select t.put('t1', (t.j() ->> 'document_id')::uuid);
select t.ok(t.j() ->> 'state' = 'draft' and t.j() ->> 'doc_type' = 'ZTGT' and t.j() ->> 'counterparty_id' = t.cp('Cust A')::text and t.j() ->> 'ref_document_id' = t.id('s1')::text
            and t.lines(t.id('t1')) = t.lines(t.id('s1')) and t.j() ->> 'total_gross' = (t.doc(t.id('s1'))).total_gross::text and jsonb_array_length(t.j() -> 'problems') = 0,
            'V1 full: a ZTGT draft with every line, amounts and totals equal to the cent, counterparty and reference copied');
select t.ok((select string_agg(x.source_line_id::text, ',' order by x.line_no) from erp.document_lines x where x.document_id = t.id('t1'))
            = t.line(t.id('s1'), 1)::text || ',' || t.line(t.id('s1'), 2)::text
            and t.count($$select 1 from erp.document_links where kind = 'bill'$$) = 1, 'V1: each target line points to its source line; one document link (bill)');
select t.ok(t.status(t.id('s1'), 'bill') = 'full' and t.status(t.id('s1'), 'credit') = 'open', 'V1: the draft counts: source full for billing, still open for credit');
select t.ok((erp_api.doc_convert(array[t.id('s1')], 'ZTGT', null, '00000000-0000-4000-c135-000000000001')) ->> 'document_id' = t.id('t1')::text
            and t.count($$select 1 from erp.documents where doc_type = 'ZTGT'$$) = 1, 'same key: the same draft, no second conversion');
select t.fails(format($$select erp_api.doc_convert(array['%s'::uuid], 'ZTGT', null, gen_random_uuid())$$, t.id('s1')), 'ERP_CONVERT_NOTHING_LEFT', 'V3: converting a full source again: nothing left');
-- V4 the target is deleted -> the quantity comes back
select erp_api.doc_delete_draft(t.id('t1'), gen_random_uuid());
select t.ok(t.status(t.id('s1'), 'bill') = 'open' and t.count($$select 1 from erp.document_links$$) = 0, 'V4: deleting the target draft gives everything back (links gone)');
-- V2 partial 6 then 4
select t.keep(erp_api.doc_convert(array[t.id('s1')], 'ZTGT', jsonb_build_array(jsonb_build_object('source_line_id', t.line(t.id('s1'), 1), 'qty', 6)), gen_random_uuid()));
select t.put('t2', (t.j() ->> 'document_id')::uuid);
select t.ok(t.lines(t.id('t2')) = '[{"qty": 6.0000, "vat": 4.80, "net": 20.01, "item": "I1"}]' and t.status(t.id('s1'), 'bill') = 'partial' and t.rem(t.line(t.id('s1'), 1), 'bill') = 4,
            'V2: 6 of 10: one line, net recomputed round(6 x 3.335) = 20.01, VAT 4.80; status partial, 4 remain');
select t.fails(format($$select erp_api.doc_convert(array['%s'::uuid], 'ZTGT', '[{"source_line_id": "%s", "qty": 5}]', gen_random_uuid())$$, t.id('s1'), t.line(t.id('s1'), 1)),
               'ERP_CONVERT_EXCEEDS', 'V3: 5 asked, 4 remain: refused');
select t.fails(format($$select erp_api.doc_convert(array['%s'::uuid], 'ZTGT', '[{"source_line_id": "%s", "qty": 3}, {"source_line_id": "%2$s", "qty": 3}]', gen_random_uuid())$$,
                      t.id('s1'), t.line(t.id('s1'), 1)), 'ERP_CONVERT_EXCEEDS', 'the same line twice above its remaining: refused');
select erp_api.doc_set_state(t.id('t2'), 'posted', '{}', gen_random_uuid());
select t.keep(erp_api.doc_convert(array[t.id('s1')], 'ZTGT', null, gen_random_uuid()));
select t.put('t3', (t.j() ->> 'document_id')::uuid);
select t.ok(t.lines(t.id('t3')) = '[{"qty": 4.0000, "vat": 3.20, "net": 13.34, "item": "I1"}, {"qty": 3.0000, "vat": 0.79, "net": 3.30, "item": "I2"}]'
            and t.status(t.id('s1'), 'bill') = 'full', 'V2: the rest (4 + the second line): full');
-- target draft edits are checked
select t.keep(erp_api.doc_save_draft('ZTGT', jsonb_build_object('document_id', t.id('t3'), 'version', 1, 'counterparty_id', t.cp('Cust B'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', t.it('I2'), 'qty', 4, 'unit_price', 3.335, 'source_line_id', t.line(t.id('s1'), 1)),
                             jsonb_build_object('item_id', t.it('I2'), 'qty', 5, 'unit_price', 1.1, 'source_line_id', t.line(t.id('s1'), 2)))), gen_random_uuid()));
select t.ok((select string_agg(coalesce(e ->> 'line_no', '-') || ':' || (e ->> 'code'), ',' order by e ->> 'line_no' nulls first, e ->> 'code') from jsonb_array_elements(t.j() -> 'problems') e)
            = '-:locked,1:locked,2:exceeds', 'target draft: another counterparty, another item on a converted line, more than remains: all blocked');
select t.fails(format($$select erp_api.doc_set_state('%s', 'posted', '{}', gen_random_uuid())$$, t.id('t3')), 'ERP_VALIDATION', '...so it cannot be posted');
select erp_api.doc_save_draft('ZTGT', jsonb_build_object('document_id', t.id('t3'), 'version', 2, 'counterparty_id', t.cp('Cust A'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', t.it('I1'), 'qty', 2, 'unit_price', 3.335, 'source_line_id', t.line(t.id('s1'), 1)))), gen_random_uuid());
select t.ok(t.status(t.id('s1'), 'bill') = 'partial' and t.rem(t.line(t.id('s1'), 1), 'bill') = 2 and t.rem(t.line(t.id('s1'), 2), 'bill') = 3,
            'quantity down / line removed in the target draft: the source shows what remains');
select erp_api.doc_set_state(t.id('t3'), 'posted', '{}', gen_random_uuid());
-- a source with a live target cannot be cancelled; a cancelled target gives its quantity back
select t.fails(format($$select erp_api.doc_set_state('%s', 'cancelled', '{"reason": "x"}', gen_random_uuid())$$, t.id('s1')), 'ERP_DOC_HAS_CHILDREN',
               'cancel the source while posted targets exist: refused');
select erp_api.doc_set_state(t.id('t3'), 'cancelled', '{"reason": "wrong"}', gen_random_uuid());
select t.ok(t.rem(t.line(t.id('s1'), 1), 'bill') = 4 and t.rem(t.line(t.id('s1'), 2), 'bill') = 3, 'V4: cancelling a target gives its quantity back');
-- V5 N:1
select t.put('s2', t.src()), t.put('s3', t.src()), t.put('sx', t.src('Cust B'));
select t.keep(erp_api.doc_convert(array[t.id('s3'), t.id('s2')], 'ZTGT', null, gen_random_uuid()));
select t.ok(jsonb_array_length(t.j() -> 'lines') = 4 and t.j() ->> 'ref_document_id' is null and t.j() ->> 'total_net' = '73.30'
            and t.count($$select 1 from erp.document_links where target_document_id = '$$ || (t.j() ->> 'document_id') || $$'$$) = 2,
            'V5: two sources of the same counterparty into one target: 4 lines, 2 links, totals = sum');
select t.fails(format($$select erp_api.doc_convert(array['%s'::uuid, '%s'::uuid], 'ZTGT', null, gen_random_uuid())$$, t.id('s1'), t.id('sx')), 'ERP_CONVERT_MIXED',
               'V5: another counterparty: refused');
select t.fails(format($$select erp_api.doc_convert(array['%s'::uuid, '%s'::uuid], 'ZCRD', null, gen_random_uuid())$$, t.id('s1'), t.id('sx')), 'ERP_CONVERT_',
               'several sources into a target without N:1: refused');
select t.fails(format($$select erp_api.doc_convert(array['%s'::uuid], 'ZNOTE', null, gen_random_uuid())$$, t.id('s1')), 'ERP_CONVERT_NOT_ALLOWED', 'a pair that is not in the matrix');
select t.keep(erp_api.doc_save_draft('ZSRC', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'counterparty_id', t.cp('Cust A'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', t.it('I1'), 'qty', 1, 'unit_price', 1))), gen_random_uuid()));
select t.fails(format($$select erp_api.doc_convert(array['%s'::uuid], 'ZTGT', null, gen_random_uuid())$$, t.j() ->> 'document_id'), 'ERP_STATE', 'a draft source cannot be converted');
-- credit kind is independent of billing
select t.ok((erp_api.doc_convert(array[t.id('s2')], 'ZCRD', '[]'::jsonb || jsonb_build_object('source_line_id', t.line(t.id('s2'), 2), 'qty', 1), gen_random_uuid())) #>> '{lines,0,qty_base}' = '1.0000'
            and t.status(t.id('s2'), 'bill') = 'full' and t.status(t.id('s2'), 'credit') = 'partial', 'kinds are separate: billed in full, credited in part');
-- menu
select t.keep(erp_api.doc_conversions_for(t.id('s2')));
select t.ok((select string_agg((x ->> 'target_type') || ':' || (x ->> 'status'), ',' order by x ->> 'target_type') from jsonb_array_elements(t.j() -> 'targets') x) = 'ZCRD:partial,ZTGT:full'
            and jsonb_array_length(t.j() -> 'converted_to') = 2 and t.j() #>> '{targets,0,lines,1,remaining}' is not null, 'Convert-to menu: targets with status and remaining per line; converted to');
select t.ok(jsonb_array_length((erp_api.doc_conversions_for(t.id('t2'))) -> 'created_from') = 1, 'the target shows Created from');
-- copy
select t.keep(erp_api.doc_copy(t.id('s1'), gen_random_uuid()));
select t.ok(t.j() ->> 'state' = 'draft' and t.j() ->> 'doc_type' = 'ZSRC' and t.lines((t.j() ->> 'document_id')::uuid) = t.lines(t.id('s1'))
            and not exists (select 1 from jsonb_array_elements(t.j() -> 'lines') l where l ->> 'source_line_id' is not null)
            and t.count($$select 1 from erp.document_links where target_document_id = '$$ || (t.j() ->> 'document_id') || $$'$$) = 0,
            'Copy: a new draft of the same type, lines and prices kept, NO link');
-- roles and tenancy
select t.as(6);
select t.fails(format($$select erp_api.doc_convert(array['%s'::uuid], 'ZCRD', null, gen_random_uuid())$$, t.id('s3')), 'ERP_FORBIDDEN', 'readonly cannot convert');
select t.ok(jsonb_array_length((erp_api.doc_conversions_for(t.id('s3'))) -> 'targets') = 0, 'readonly: no Convert-to targets');
select t.fails(format($$select erp_api.doc_copy('%s', gen_random_uuid())$$, t.id('s3')), 'ERP_FORBIDDEN', 'readonly cannot copy');
select t.as(11);
select t.fails(format($$select erp_api.doc_convert(array['%s'::uuid], 'ZTGT', null, gen_random_uuid())$$, t.id('s3')), 'ERP_TENANT', 'tenant B: a source of A is ERP_TENANT');
select t.fails(format($$select erp_api.doc_copy('%s', gen_random_uuid())$$, t.id('s3')), 'ERP_TENANT', 'tenant B cannot copy a document of A');
reset role;
select t.ok((select count(*) from erp.doc_conversions where source_type in ('DN', 'GRN') and stock_rule = 'stock_by_source') = 3, 'seed: DN -> SINV / RR and GRN -> PINV are stock_by_source (01 C5)');

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
