-- =====================================================================
-- iSmile ERP  -  tests for E120_master.sql (T05, T06): units, VAT classes, categories (tree), items + barcodes,
-- warehouses + transit, counterparties (tax ID checksum, ext_ref), document-type catalogue, series. Validation (all
-- problems at once), duplicates, cross-tenant ids, role limits (archive, detail / cost columns), idempotency, audit,
-- keyset paging, tenant defaults. One transaction, ROLLED BACK. Last line: ALL TESTS PASSED + number of checks.
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
       t.member(t.a(), 4, 'accounting', '{}', true), t.member(t.a(), 5, 'clinic_user', array[t.br(t.a(), 'A1')]), t.member(t.a(), 6, 'readonly', array[t.br(t.a(), 'A1')]),
       t.member(t.b(), 11, 'owner');
create function t.unit(p_t uuid, p_code text) returns uuid language sql security definer as $$ select unit_id from erp.units where tenant_id = p_t and code = p_code $$;
create function t.vat(p_t uuid, p_code text) returns uuid language sql security definer as $$ select vat_class_id from erp.vat_classes where tenant_id = p_t and code = p_code $$;
create function t.cat(p_t uuid, p_code text) returns uuid language sql security definer as $$ select category_id from erp.item_categories where tenant_id = p_t and code = p_code $$;
create function t.item(p_t uuid, p_code text) returns uuid language sql security definer as $$ select item_id from erp.items where tenant_id = p_t and code = p_code $$;
create function t.codes(p jsonb) returns text language sql immutable as $$ select string_agg(e ->> 'code' || ':' || coalesce(e ->> 'field', '-'), ',' order by e ->> 'field', e ->> 'code') from jsonb_array_elements(p) e $$;
grant execute on all functions in schema t to authenticated;
insert into erp.items (tenant_id, code, name, base_unit_id) values (t.b(), 'BITEM', 'B item', t.unit(t.b(), 'PCS'));

-- ---------- tenant defaults (trigger on erp.tenants) ----------
select t.ok((select count(*) from erp.units where tenant_id = t.a()) = 6 and t.unit(t.a(), 'PCS') is not null
            and (select string_agg(code || '=' || rate, ',' order by code) from erp.vat_classes where tenant_id = t.a()) = 'VAT0=0.00,VAT13=13.00,VAT24=24.00,VAT6=6.00',
            'a new tenant gets 6 default units and 4 VAT classes');
select t.ok(exists (select 1 from erp.units where tenant_id = '00000000-0000-4000-8000-000000000001' and code = 'PCS'), 'tenant #1 got the defaults at file load');
select erp.master_init(t.a());
select t.ok((select count(*) from erp.units where tenant_id = t.a()) = 6, 'master_init re-run adds nothing');

set local role authenticated;
-- ---------- units ----------
select t.as(3);
select t.keep(erp_api.unit_save('{"code": "TUBE", "name": "Tube", "decimals": 0}', '00000000-0000-4000-c120-000000000001'));
select t.ok(t.j() ->> 'code' = 'TUBE' and (t.j() ->> 'active')::boolean, 'warehouse creates a unit');
select t.ok((erp_api.unit_save('{"code": "TUBE", "name": "Tube", "decimals": 0}', '00000000-0000-4000-c120-000000000001')) = t.j()
            and t.count($$select 1 from erp.units where code = 'TUBE'$$) = 1, 'same key: stored reply, one row');
select t.fails($$select erp_api.unit_save('{"code": "TUBE2", "name": "Tube", "decimals": 0}', '00000000-0000-4000-c120-000000000001')$$, 'ERP_IDEMPOTENT_MISMATCH',
               'same key, other payload: ERP_IDEMPOTENT_MISMATCH');
select t.ok(t.codes(t.problems($$select erp_api.unit_save('{"code": "tube", "name": "", "decimals": 7, "colour": 1}', gen_random_uuid())$$))
            = 'duplicate:code,not_editable:colour,invalid:decimals,required:name', 'unit validation: duplicate code (case-insensitive), decimals, name, unknown key at once');
select t.fails(format($$select erp_api.unit_save('{"unit_id": "%s", "active": false}', gen_random_uuid())$$, t.unit(t.a(), 'TUBE')), 'ERP_FORBIDDEN',
               'warehouse cannot deactivate a unit (master.archive)');
select t.fails(format($$select erp_api.unit_save('{"unit_id": "%s", "name": "x"}', gen_random_uuid())$$, t.unit(t.b(), 'PCS')), 'ERP_TENANT', 'unit of tenant B: ERP_TENANT');
select t.as(5);
select t.fails($$select erp_api.unit_save('{"code": "X", "name": "x"}', gen_random_uuid())$$, 'ERP_FORBIDDEN', 'clinic_user cannot create a unit');
select t.ok(jsonb_array_length((erp_api.unit_list()) -> 'rows') = 7, 'clinic_user lists the units (item.read)');
select t.as(2);
select t.ok((erp_api.unit_save(jsonb_build_object('unit_id', t.unit(t.a(), 'TUBE'), 'active', false), gen_random_uuid())) ->> 'active' = 'false', 'manager deactivates an unused unit');
select t.ok(jsonb_array_length((erp_api.unit_list()) -> 'rows') = 6 and jsonb_array_length((erp_api.unit_list(true)) -> 'rows') = 7, 'unit_list hides inactive unless asked');
select t.ok((select jsonb_agg(r ->> 'code') from jsonb_array_elements((erp_api.unit_list(true, null, 3)) -> 'rows') r) = '["BOX", "KG", "L"]'
            and (select jsonb_agg(r ->> 'code') from jsonb_array_elements((erp_api.unit_list(true, (erp_api.unit_list(true, null, 3)) -> 'next', 3)) -> 'rows') r) = '["M", "PACK", "PCS"]',
            'unit_list keyset paging: pages of 3 follow each other');

-- ---------- VAT classes ----------
select t.as(4);
select t.keep(erp_api.vat_class_save('{"code": "VAT17", "name": "VAT 17% islands", "rate": 17, "mydata_category": 4}', gen_random_uuid()));
select t.ok(t.j() ->> 'rate' = '17.00' and t.j() ->> 'mydata_category' = '4', 'accounting creates a VAT class');
select t.ok(t.codes(t.problems($$select erp_api.vat_class_save('{"code": "vat17", "name": "x", "rate": 101.5, "mydata_category": 33, "exemption_code": "A1"}', gen_random_uuid())$$))
            = 'duplicate:code,invalid:exemption_code,invalid:mydata_category,invalid:rate', 'VAT validation: duplicate, exemption code, myDATA category, rate');
select t.ok(t.problems($$select erp_api.vat_class_save('{"code": "V2", "name": "x", "rate": 6.555}', gen_random_uuid())$$) -> 0 ->> 'field' = 'rate', 'rate with 3 decimals refused');
select t.fails(format($$select erp_api.vat_class_save('{"vat_class_id": "%s", "active": false}', gen_random_uuid())$$, t.vat(t.a(), 'VAT17')), 'ERP_FORBIDDEN',
               'accounting cannot deactivate a VAT class (owner / manager)');
select t.as(3);
select t.fails($$select erp_api.vat_class_save('{"code": "V3", "name": "x", "rate": 3}', gen_random_uuid())$$, 'ERP_FORBIDDEN', 'warehouse cannot create VAT classes (matrix r)');
select t.ok(jsonb_array_length((erp_api.vat_class_list()) -> 'rows') = 5, 'warehouse reads VAT classes');
select t.as(5);
select t.fails($$select erp_api.vat_class_list()$$, 'ERP_FORBIDDEN', 'clinic_user does not read VAT classes (matrix -)');
select t.ok((select count(*) from erp.vat_classes) = 0, 'clinic_user: the VAT table policy shows no row either');

-- ---------- categories ----------
select t.as(3);
select t.keep(erp_api.category_save('{"code": "ORTHO", "name": "Orthodontics"}', gen_random_uuid()));
select erp_api.category_save(jsonb_build_object('code', 'BRK', 'name', 'Brackets', 'parent_id', t.cat(t.a(), 'ORTHO')), gen_random_uuid());
select erp_api.category_save(jsonb_build_object('code', 'BRK-M', 'name', 'Metal brackets', 'parent_id', t.cat(t.a(), 'BRK')), gen_random_uuid());
select t.ok((select r ->> 'path' from jsonb_array_elements((erp_api.category_list()) -> 'rows') r where r ->> 'code' = 'BRK-M') = 'ORTHO / BRK / BRK-M',
            'category tree: path of a grandchild');
select t.ok(t.problems(format($$select erp_api.category_save('{"category_id": "%s", "parent_id": "%s"}', gen_random_uuid())$$, t.cat(t.a(), 'ORTHO'), t.cat(t.a(), 'BRK-M'))) -> 0 ->> 'code' = 'cycle',
            'a category cannot move under its own grandchild (cycle)');
select t.ok(t.problems(format($$select erp_api.category_save('{"category_id": "%s", "parent_id": "%1$s"}', gen_random_uuid())$$, t.cat(t.a(), 'ORTHO'))) -> 0 ->> 'code' = 'cycle',
            'a category cannot be its own parent');
do $$ declare p uuid := t.cat(t.a(), 'BRK-M'); i int; begin
  for i in 1 .. 5 loop perform erp_api.category_save(jsonb_build_object('code', 'D' || i, 'name', 'deep ' || i, 'parent_id', p), gen_random_uuid()); p := t.cat(t.a(), 'D' || i); end loop;
end $$;
select t.ok(t.problems(format($$select erp_api.category_save('{"code": "D6", "name": "too deep", "parent_id": "%s"}', gen_random_uuid())$$, t.cat(t.a(), 'D5'))) -> 0 ->> 'code' = 'too_deep',
            'categories nest at most 8 levels');
select t.fails(format($$select erp_api.category_save('{"code": "X1", "name": "x", "parent_id": "%s"}', gen_random_uuid())$$, gen_random_uuid()), 'ERP_TENANT', 'unknown parent: ERP_TENANT');
select t.ok(t.problems($$select erp_api.category_save('{"code": "C1", "name": "x", "valuation_override": "fifo"}', gen_random_uuid())$$) -> 0 ->> 'code' = 'not_editable',
            'valuation_override is not editable here (valuation switch, owner, T39)');
select t.as(2);
select t.ok(t.problems(format($$select erp_api.category_save('{"category_id": "%s", "active": false}', gen_random_uuid())$$, t.cat(t.a(), 'ORTHO'))) -> 0 ->> 'code' = 'in_use',
            'a category with active sub-categories cannot be deactivated');

-- ---------- items ----------
select t.as(3);
select t.keep(erp_api.item_save(jsonb_build_object('code', 'BR-001', 'name', 'Bracket MBT 0.022', 'kind', 'consumable', 'base_unit_id', t.unit(t.a(), 'PCS'),
                                                   'category_id', t.cat(t.a(), 'BRK-M'), 'vat_class_id', t.vat(t.a(), 'VAT24'), 'min_level', 10, 'reorder_level', 25,
                                                   'sales_price', '12.5', 'barcodes', jsonb_build_array('4006381333931', 'INT-77', 'INT-77')), '00000000-0000-4000-c120-000000000002'));
select t.ok(t.j() ->> 'code' = 'BR-001' and t.j() ->> 'unit_code' = 'PCS' and t.j() ->> 'category_code' = 'BRK-M' and t.j() ->> 'vat_code' = 'VAT24'
            and t.j() -> 'barcodes' = '["4006381333931", "INT-77"]' and t.j() ->> 'sales_price' = '12.5000' and t.j() ->> 'version' = '1',
            'warehouse creates an item with category, VAT, levels, price and barcodes (duplicates in the list collapse)');
select t.ok(not (t.j() ? 'last_purchase_price'), 'warehouse reply has no cost column (no cost.read)');
select t.ok(t.codes(t.problems(format($$select erp_api.item_save('{"code": "br-001", "name": "", "kind": "tool", "base_unit_id": null, "min_level": -1, "sales_price": "abc",
                                                                "lot_tracked": true, "barcodes": ["4006381333932", "x", "INT-77"]}', gen_random_uuid())$$)))
            = 'checksum:barcodes,duplicate:barcodes,invalid:barcodes,required:base_unit_id,duplicate:code,invalid:kind,not_available:lot_tracked,invalid:min_level,required:name,invalid:sales_price',
            'item validation: every problem at once (EAN check digit, barcode format, unit, code taken, kind, lots not yet, level, name, price)');
select t.ok(t.problems(format($$select erp_api.item_save('{"code": "X2", "name": "x", "base_unit_id": "%s", "barcodes": ["INT-77"]}', gen_random_uuid())$$, t.unit(t.a(), 'PCS'))) -> 0 ->> 'code'
            = 'duplicate', 'a barcode of another item is refused');
select t.ok(t.problems(format($$select erp_api.item_save('{"code": "SVC1", "name": "Consultation", "kind": "service", "min_level": 1, "base_unit_id": "%s"}', gen_random_uuid())$$,
                              t.unit(t.a(), 'PCS'))) -> 0 ->> 'field' = 'min_level', 'a service has no stock levels');
select t.fails(format($$select erp_api.item_save('{"code": "X3", "name": "x", "base_unit_id": "%s"}', gen_random_uuid())$$, t.unit(t.b(), 'PCS')), 'ERP_TENANT', 'base unit of tenant B: ERP_TENANT');
select t.fails(format($$select erp_api.item_save('{"code": "X4", "name": "x", "base_unit_id": "%s", "vat_class_id": "%s"}', gen_random_uuid())$$, t.unit(t.a(), 'PCS'), t.vat(t.b(), 'VAT24')),
               'ERP_TENANT', 'VAT class of tenant B: ERP_TENANT');
select t.ok(t.problems(format($$select erp_api.item_save('{"code": "X5", "name": "x", "base_unit_id": "%s"}', gen_random_uuid())$$, t.unit(t.a(), 'TUBE'))) -> 0 ->> 'code' = 'inactive',
            'an inactive unit cannot be chosen');
select t.keep(erp_api.item_save(jsonb_build_object('item_id', t.item(t.a(), 'BR-001'), 'version', 1, 'name', 'Bracket MBT 0.022 slot', 'barcodes', jsonb_build_array('INT-77', 'INT-78')), gen_random_uuid()));
select t.ok(t.j() ->> 'version' = '2' and t.j() -> 'barcodes' = '["INT-77", "INT-78"]' and t.j() ->> 'kind' = 'consumable' and t.j() ->> 'sales_price' = '12.5000',
            'change: only the keys given change; barcodes replaced; version + 1');
select t.fails(format($$select erp_api.item_save('{"item_id": "%s", "version": 1, "name": "stale"}', gen_random_uuid())$$, t.item(t.a(), 'BR-001')), 'ERP_CONFLICT',
               'stale version: ERP_CONFLICT');
select t.fails(format($$select erp_api.item_save('{"item_id": "%s", "active": false}', gen_random_uuid())$$, t.item(t.a(), 'BR-001')), 'ERP_FORBIDDEN', 'warehouse cannot deactivate an item');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'item.update' and row_id = '$$ || t.item(t.a(), 'BR-001') || $$' and new_row ? 'name' and not new_row ? 'version'$$) = 1,
            'item change audited with the changed keys');
do $$ declare i int; begin
  for i in 1 .. 12 loop
    perform erp_api.item_save(jsonb_build_object('code', 'W-' || lpad(i::text, 2, '0'), 'name', case when i % 2 = 0 then 'Wire NiTi ' else 'Wire steel ' end || i,
                                                 'base_unit_id', t.unit(t.a(), 'PCS'), 'category_id', case when i <= 3 then t.cat(t.a(), 'BRK') end), gen_random_uuid());
  end loop;
end $$;
select t.ok((select string_agg(r ->> 'code', ',') from jsonb_array_elements((erp_api.item_list('{"q": "w-1"}')) -> 'rows') r) = 'W-10,W-11,W-12', 'item_list q: code prefix');
select t.ok(jsonb_array_length((erp_api.item_list('{"q": "niti"}')) -> 'rows') = 6, 'item_list q: name contains, case-insensitive');
select t.ok((erp_api.item_list('{"q": "INT-78"}')) #>> '{rows,0,code}' = 'BR-001', 'item_list q: exact barcode');
select t.ok(jsonb_array_length((erp_api.item_list(jsonb_build_object('category_id', t.cat(t.a(), 'ORTHO')))) -> 'rows') = 4, 'category filter includes sub-categories (3 in BRK + 1 in BRK-M)');
reset role;
create table t.pg (code text);
grant insert, select on t.pg to authenticated;
set local role authenticated;
select t.as(3);
do $$ declare c jsonb := null; r jsonb; n int := 0; begin
  loop
    r := erp_api.item_list('{}', c, 5);
    insert into t.pg select x ->> 'code' from jsonb_array_elements(r -> 'rows') x;
    c := r -> 'next'; n := n + 1;
    exit when c is null or c = 'null'::jsonb or n > 10;
  end loop;
end $$;
select t.ok((select count(*) from t.pg) = 13 and (select count(distinct code) from t.pg) = 13, 'item_list keyset paging by 5: 13 items, no duplicate, none missing');
select t.as(5);
select t.keep(erp_api.item_get(t.item(t.a(), 'BR-001')));
select t.ok(t.j() ->> 'name' = 'Bracket MBT 0.022 slot' and t.j() ->> 'unit_code' = 'PCS' and not (t.j() ? 'sales_price') and not (t.j() ? 'min_level') and not (t.j() ? 'last_purchase_price'),
            'clinic_user: name, code, unit, barcodes; no price, levels or cost (02 matrix)');
select t.fails($$select erp_api.item_save('{"code": "C9", "name": "x"}', gen_random_uuid())$$, 'ERP_FORBIDDEN', 'clinic_user cannot create items');
select t.as(6);
select t.ok((erp_api.item_get(t.item(t.a(), 'BR-001'))) ? 'last_purchase_price' and (erp_api.item_get(t.item(t.a(), 'BR-001'))) ? 'sales_price', 'readonly: detail and cost columns (r)');
select t.fails(format($$select erp_api.item_get('%s')$$, t.item(t.b(), 'BITEM')), 'ERP_TENANT', 'item of tenant B: ERP_TENANT');
select t.as(2);
select t.ok((erp_api.item_save(jsonb_build_object('item_id', t.item(t.a(), 'W-12'), 'active', false), gen_random_uuid())) ->> 'active' = 'false', 'manager deactivates an item');
select t.ok(jsonb_array_length((erp_api.item_list()) -> 'rows') = 12 and jsonb_array_length((erp_api.item_list('{"active": "all"}')) -> 'rows') = 13
            and jsonb_array_length((erp_api.item_list('{"active": "false"}')) -> 'rows') = 1, 'item_list active filter');
select t.ok(t.problems(format($$select erp_api.unit_save('{"unit_id": "%s", "active": false}', gen_random_uuid())$$, t.unit(t.a(), 'PCS'))) -> 0 ->> 'code' = 'in_use',
            'a unit used by active items cannot be deactivated');
reset role;
select t.ok((select count(*) from erp.items where tenant_id = t.b()) = 1 and (select count(*) from erp.units where tenant_id = t.b()) = 6,
            'nothing was written into tenant B');


-- =================== part 2 (T06) ===================
create function t.wh(p_t uuid, p_code text) returns uuid language sql security definer as $$ select warehouse_id from erp.warehouses where tenant_id = p_t and code = p_code $$;
create function t.cp(p_t uuid, p_name text) returns uuid language sql security definer as $$ select counterparty_id from erp.counterparties where tenant_id = p_t and name = p_name $$;
create function t.ser(p_t uuid, p_code text) returns uuid language sql security definer as $$ select series_id from erp.series where tenant_id = p_t and code = p_code $$;
grant execute on all functions in schema t to authenticated;
insert into erp.counterparties (tenant_id, name, tax_id) values (t.b(), 'B supplier', '094014201');

-- ---------- warehouses + transit ----------
select t.ok((select count(*) from erp.warehouses where tenant_id = t.a() and kind = 'in_transit' and branch_id is null and code = 'TRANSIT') = 1
            and (select count(*) from erp.warehouses where kind = 'in_transit' and tenant_id = '00000000-0000-4000-8000-000000000001') = 1,
            'one system transit warehouse per tenant (new tenant and tenant #1)');
select t.fails(format($$insert into erp.warehouses (tenant_id, code, name, kind) values ('%s', 'T2', 'second transit', 'in_transit')$$, t.a()), '', 'a second transit warehouse is refused by the database');
select t.fails(format($$insert into erp.warehouses (tenant_id, code, name) values ('%s', 'NB', 'no branch')$$, t.a()), '', 'a normal warehouse without a branch is refused by the database');
set local role authenticated;
select t.as(3);
select t.keep(erp_api.warehouse_save(jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'code', 'A1-MAIN', 'name', 'Serres main'), gen_random_uuid()));
select t.ok(t.j() ->> 'branch_code' = 'A1' and t.j() ->> 'kind' = 'normal', 'warehouse member creates a warehouse in its branch');
select t.fails(format($$select erp_api.warehouse_save('{"branch_id": "%s", "code": "A2-X", "name": "x"}', gen_random_uuid())$$, t.br(t.a(), 'A2')), 'ERP_FORBIDDEN',
               'warehouse member cannot create one in another branch');
select t.fails(format($$select erp_api.warehouse_save('{"warehouse_id": "%s", "branch_id": "%s"}', gen_random_uuid())$$, t.wh(t.a(), 'A1-MAIN'), t.br(t.a(), 'A2')), 'ERP_FORBIDDEN',
               '...nor move one into another branch');
select t.ok(t.codes(t.problems(format($$select erp_api.warehouse_save('{"branch_id": "%s", "code": "transit", "name": ""}', gen_random_uuid())$$, t.br(t.a(), 'A1'))))
            = 'reserved:code,required:name', 'TRANSIT is reserved, name required');
select t.ok(t.problems(format($$select erp_api.warehouse_save('{"branch_id": "%s", "code": "a1-main", "name": "x"}', gen_random_uuid())$$, t.br(t.a(), 'A1'))) -> 0 ->> 'code' = 'duplicate',
            'duplicate warehouse code (case-insensitive)');
select t.ok(t.problems($$select erp_api.warehouse_save('{"code": "NOBR", "name": "x"}', gen_random_uuid())$$) -> 0 ->> 'field' = 'branch_id', 'branch required');
select t.fails(format($$select erp_api.warehouse_save('{"warehouse_id": "%s", "name": "x"}', gen_random_uuid())$$, t.wh(t.a(), 'TRANSIT')), 'ERP_FORBIDDEN', 'the transit warehouse cannot be changed');
select t.fails(format($$select erp_api.warehouse_save('{"warehouse_id": "%s", "active": false}', gen_random_uuid())$$, t.wh(t.a(), 'A1-MAIN')), 'ERP_FORBIDDEN',
               'warehouse member cannot deactivate a warehouse (master.archive)');
select t.fails(format($$select erp_api.warehouse_save('{"branch_id": "%s", "code": "BX", "name": "x"}', gen_random_uuid())$$, t.br(t.b(), 'B1')), 'ERP_TENANT', 'branch of tenant B: ERP_TENANT');
select t.as(1);
select erp_api.warehouse_save(jsonb_build_object('branch_id', t.br(t.a(), 'A2'), 'code', 'A2-MAIN', 'name', 'Thessaloniki main'), gen_random_uuid());
select t.ok((select string_agg(r ->> 'code', ',') from jsonb_array_elements((erp_api.warehouse_list()) -> 'rows') r) = 'A1-MAIN,A2-MAIN'
            and (select string_agg(r ->> 'code', ',') from jsonb_array_elements((erp_api.warehouse_list('{"include_transit": true}')) -> 'rows') r) = 'A1-MAIN,A2-MAIN,TRANSIT',
            'owner: transit only when asked');
select t.as(5);
select t.ok((select string_agg(r ->> 'code', ',') from jsonb_array_elements((erp_api.warehouse_list('{"include_transit": true}')) -> 'rows') r) = 'A1-MAIN'
            and (select count(*) from erp.warehouses) = 1, 'clinic_user (A1): its branch only, never transit; RLS agrees');
select t.fails(format($$select erp_api.warehouse_list('{"branch_id": "%s"}')$$, t.br(t.b(), 'B1')), 'ERP_TENANT', 'warehouse_list with a branch of B: ERP_TENANT');

-- ---------- counterparties ----------
select t.as(4);
select t.keep(erp_api.counterparty_save('{"name": "Ortho Supplies SA", "code": "SUP1", "kind": "supplier", "tax_id": "EL 094 014 201", "tax_office": "Serres",
                                          "email": "Orders@Ortho.TEST", "payment_terms_days": 30, "ext_ref": "ACC-001"}', gen_random_uuid()));
select t.ok(t.j() ->> 'tax_id' = '094014201' and t.j() ->> 'country' = 'GR' and t.j() ->> 'email' = 'orders@ortho.test' and t.j() ->> 'ext_source' = 'manual'
            and t.j() ->> 'payment_terms_days' = '30', 'accounting creates a supplier: EL prefix and spaces removed, email lower-case, own ext_ref');
select t.ok(t.codes(t.problems($$select erp_api.counterparty_save('{"name": "", "kind": "vendor", "tax_id": "094014202", "email": "x@", "payment_terms_days": 400, "code": "sup1", "country": "Greece"}', gen_random_uuid())$$))
            = 'duplicate:code,invalid:country,invalid:email,invalid:kind,required:name,invalid:payment_terms_days', 'counterparty validation: all problems at once');
select t.ok(t.problems($$select erp_api.counterparty_save('{"name": "Bad AFM", "tax_id": "094014202"}', gen_random_uuid())$$) -> 0 ->> 'code' = 'checksum', 'Greek tax ID with a wrong check digit');
select t.ok(t.problems($$select erp_api.counterparty_save('{"name": "Dup AFM", "tax_id": "094014201"}', gen_random_uuid())$$) -> 0 ->> 'code' = 'duplicate',
            'the same tax ID twice in one tenant is refused (tenant B has it too: no conflict across tenants)');
select t.ok((erp_api.counterparty_save('{"name": "Dental GmbH", "country": "DE", "tax_id": "DE123456789", "kind": "both"}', gen_random_uuid())) ->> 'tax_id' = 'DE123456789',
            'a foreign tax ID: format only, no Greek checksum');
select t.ok(t.problems($$select erp_api.counterparty_save('{"name": "Other", "ext_ref": "ACC-001"}', gen_random_uuid())$$) -> 0 ->> 'field' = 'ext_ref', 'ext_ref unique per tenant');
select erp_api.counterparty_save('{"name": "Clinic customer", "kind": "customer", "tax_id": "123456783"}', gen_random_uuid());
select t.ok((select string_agg(r ->> 'name', ',') from jsonb_array_elements((erp_api.counterparty_list('{"kind": "supplier"}')) -> 'rows') r) = 'Dental GmbH,Ortho Supplies SA'
            and (select string_agg(r ->> 'name', ',') from jsonb_array_elements((erp_api.counterparty_list('{"kind": "customer"}')) -> 'rows') r) = 'Clinic customer,Dental GmbH',
            'kind filter: both counts as customer and supplier');
select t.ok((erp_api.counterparty_list('{"q": "EL123456783"}')) #>> '{rows,0,name}' = 'Clinic customer' and jsonb_array_length((erp_api.counterparty_list('{"q": "ortho"}')) -> 'rows') = 1,
            'counterparty_list q: exact tax ID (prefix removed) or name');
select t.fails(format($$select erp_api.counterparty_save('{"counterparty_id": "%s", "active": false}', gen_random_uuid())$$, t.cp(t.a(), 'Dental GmbH')), 'ERP_FORBIDDEN',
               'accounting cannot deactivate a counterparty');
select t.keep(erp_api.counterparty_get(t.cp(t.a(), 'Dental GmbH')));
select t.ok((erp_api.counterparty_save(jsonb_build_object('counterparty_id', t.cp(t.a(), 'Dental GmbH'), 'version', 1, 'phone', '+49 30 1234'), gen_random_uuid())) ->> 'version' = '2',
            'change with the read version');
select t.fails(format($$select erp_api.counterparty_save('{"counterparty_id": "%s", "version": 1, "phone": "x"}', gen_random_uuid())$$, t.cp(t.a(), 'Dental GmbH')), 'ERP_CONFLICT', 'stale version: ERP_CONFLICT');
select t.fails(format($$select erp_api.counterparty_get('%s')$$, t.cp(t.b(), 'B supplier')), 'ERP_TENANT', 'counterparty of tenant B: ERP_TENANT');
reset role;
update erp.counterparties set ext_source = 'crm', ext_ref = 'person-1' where tenant_id = t.a() and name = 'Clinic customer';
set local role authenticated;
select t.as(4);
select t.ok(t.problems(format($$select erp_api.counterparty_save('{"counterparty_id": "%s", "ext_ref": "x"}', gen_random_uuid())$$, t.cp(t.a(), 'Clinic customer'))) -> 0 ->> 'code' = 'not_editable',
            'a CRM-linked customer keeps its link (only the integration changes it)');
select t.as(3);
select t.ok(jsonb_array_length((erp_api.counterparty_list('{}')) -> 'rows') = 3, 'warehouse reads counterparties');
select t.fails($$select erp_api.counterparty_save('{"name": "x"}', gen_random_uuid())$$, 'ERP_FORBIDDEN', 'warehouse cannot write counterparties (matrix r)');
select t.as(5);
select t.fails($$select erp_api.counterparty_list()$$, 'ERP_FORBIDDEN', 'clinic_user does not read counterparties (matrix -)');
select t.ok((select count(*) from erp.counterparties) = 0, 'clinic_user: no counterparty row through the table policy either');
select t.as(2);
select t.ok((erp_api.counterparty_save(jsonb_build_object('counterparty_id', t.cp(t.a(), 'Dental GmbH'), 'active', false), gen_random_uuid())) ->> 'active' = 'false',
            'manager deactivates a counterparty');

-- ---------- document types + series ----------
select t.ok(jsonb_array_length(erp_api.doc_type_list()) = 26 and (erp_api.doc_type_list()) -> 0 ->> 'doc_type' = 'PO', 'catalogue: the 26 types of 01 C, in menu order');
select t.as(1);
select t.keep(erp_api.series_save(jsonb_build_object('doc_type', 'GRN', 'branch_id', t.br(t.a(), 'A1'), 'code', 'GRN-A1'), gen_random_uuid()));
select t.ok(t.j() ->> 'next_no' = '1' and (t.j() ->> 'is_default')::boolean and not (t.j() ->> 'gapless')::boolean and t.j() ->> 'branch_code' = 'A1',
            'owner creates a branch series (default, not gapless for GRN)');
select t.ok(t.codes(t.problems($$select erp_api.series_save('{"doc_type": "GRN", "code": "grn-a1"}', gen_random_uuid())$$)) = 'required:branch_id,duplicate:code',
            'branch series needs a branch; code unique per type');
select t.ok(t.problems(format($$select erp_api.series_save('{"doc_type": "OPN", "code": "OPN", "branch_id": "%s"}', gen_random_uuid())$$, t.br(t.a(), 'A1'))) -> 0 ->> 'field' = 'branch_id',
            'OPN series are organisation-wide (01 C3: series "tenant")');
select t.ok(t.codes(t.problems(format($$select erp_api.series_save('{"doc_type": "DN", "code": "DN1", "branch_id": "%s", "gapless": false}', gen_random_uuid())$$, t.br(t.a(), 'A1'))))
            = 'invalid:gapless', 'a fiscal type is always gapless');
select t.ok(t.problems(format($$select erp_api.series_save('{"doc_type": "GRN", "code": "G2", "branch_id": "%s", "numbering": "provider"}', gen_random_uuid())$$, t.br(t.a(), 'A1'))) -> 0 ->> 'field' = 'numbering',
            'provider numbering only for fiscal types');
select t.ok(t.problems($$select erp_api.series_save('{"doc_type": "XX", "code": "X"}', gen_random_uuid())$$) -> 0 ->> 'field' = 'doc_type', 'unknown document type');
select erp_api.series_save(jsonb_build_object('doc_type', 'GRN', 'branch_id', t.br(t.a(), 'A1'), 'code', 'GRN-A1-VAN', 'next_no', 500), gen_random_uuid());
select t.ok((select string_agg(code || '=' || is_default, ',' order by code) from erp.series where tenant_id = t.a()) = 'GRN-A1=false,GRN-A1-VAN=true',
            'a second default series takes the default from the first');
reset role;
update erp.series set last_no = 500, next_no = 501 where tenant_id = t.a() and code = 'GRN-A1-VAN';
set local role authenticated;
select t.as(1);
select t.ok(t.codes(t.problems(format($$select erp_api.series_save('{"series_id": "%s", "next_no": 1, "branch_id": "%s"}', gen_random_uuid())$$, t.ser(t.a(), 'GRN-A1-VAN'), t.br(t.a(), 'A2'))))
            = 'in_use:branch_id,in_use:next_no', 'after the first number: branch and next number are fixed');
select t.ok((erp_api.series_save(jsonb_build_object('series_id', t.ser(t.a(), 'GRN-A1-VAN'), 'active', false), gen_random_uuid())) ->> 'active' = 'false', '...but it can be deactivated');
reset role;
update erp.doc_types set enabled = true where doc_type in ('GRN', 'OPN', 'DN');   -- as if E150 had enabled them (rolled back)
set local role authenticated;
select t.as(1);
select t.keep(erp_api.series_create_defaults(t.br(t.a(), 'A2'), gen_random_uuid()));
select t.ok((select string_agg(r ->> 'code', ',' order by r ->> 'code') from jsonb_array_elements(t.j() -> 'created') r) like '%GRN-A2,OPN%'
            and not exists (select 1 from jsonb_array_elements(t.j() -> 'created') r where r ->> 'doc_type' = 'DN'), 'defaults: GRN-A2 and the tenant-wide OPN; no fiscal DN');
select t.ok(jsonb_array_length((erp_api.series_create_defaults(t.br(t.a(), 'A2'), gen_random_uuid())) -> 'created') = 0, 'second call creates nothing');
select t.keep(erp_api.series_create_defaults(t.br(t.a(), 'A1'), gen_random_uuid()));
select t.ok(not exists (select 1 from jsonb_array_elements(t.j() -> 'created') r where r ->> 'doc_type' = 'GRN') and t.j() -> 'skipped' = '["GRN"]',
            'A1 has no active default GRN series but the code GRN-A1 is taken: skipped and reported, nothing overwritten');
select t.as(2);
select t.fails(format($$select erp_api.series_save('{"doc_type": "GRN", "code": "M1", "branch_id": "%s"}', gen_random_uuid())$$, t.br(t.a(), 'A1')), 'ERP_FORBIDDEN', 'manager cannot change series');
select t.ok(jsonb_array_length((erp_api.series_list('{"include_inactive": true}')) -> 'rows') >= 3, 'manager reads series');
select t.as(3);
select t.fails($$select erp_api.series_list()$$, 'ERP_FORBIDDEN', 'warehouse does not read series (matrix -)');
reset role;


-- =================== CSV import (T08) ===================
set local role authenticated;
select t.as(3);
select t.keep(erp_api.item_import('[{"code": "IMP-1", "name": "Imported one", "unit": "pcs", "category": "brk", "vat": "VAT24", "sales_price": "3,50", "barcodes": "IMP1A;IMP1B"},
                                    {"code": "BR-001", "name": "Bracket renamed by import"},
                                    {"code": "IMP-2", "name": "Bad", "unit": "LITREX", "sales_price": "abc", "category": "NOPE", "colour": "red"},
                                    {"code": "imp-1", "name": "Twice", "unit": "PCS", "barcodes": "IMP1B"}]', true, gen_random_uuid()));
select t.ok((t.j() ->> 'dry_run')::boolean and t.j() ->> 'rows' = '4' and t.j() ->> 'created' = '3' and t.j() ->> 'updated' = '1',
            'item import dry run: 4 rows, 3 new, 1 update (matched by code)');
select t.ok((select string_agg((e ->> 'row') || ':' || (e ->> 'code') || ':' || coalesce(e ->> 'field', '-'), ',' order by (e ->> 'row')::int, e ->> 'field', e ->> 'code')
               from jsonb_array_elements(t.j() -> 'errors') e) = '3:unknown:category,3:not_editable:colour,3:invalid:sales_price,3:unknown:unit,4:duplicate:barcodes,4:duplicate:code',
            'every problem with its row number: unknown unit / category, unknown column, bad price, code and barcode twice in the file');
select t.ok(t.count($$select 1 from erp.items where code in ('IMP-1', 'IMP-2')$$) = 0 and (select name from erp.items where code = 'BR-001') = 'Bracket MBT 0.022 slot',
            'dry run writes nothing');
select t.keep(erp_api.item_import('[{"code": "IMP-1", "name": "Imported one", "unit": "PCS"}, {"code": "IMP-3", "name": "x", "unit": "PCS", "sales_price": "-1"}]', false, gen_random_uuid()));
select t.ok((t.j() ->> 'dry_run')::boolean and jsonb_array_length(t.j() -> 'errors') = 1 and t.j() #>> '{errors,0,row}' = '2' and t.count($$select 1 from erp.items where code = 'IMP-1'$$) = 0,
            'a real run with one bad row writes NOTHING (all or nothing) and reports row 2');
select t.keep(erp_api.item_import('[{"code": "IMP-1", "name": "Imported one", "unit": "pcs", "category": "brk", "vat": "VAT24", "sales_price": "3,50", "barcodes": "IMP1A;IMP1B", "kind": "consumable"},
                                    {"code": "BR-001", "name": "Bracket renamed by import", "sales_price": ""}]', false, '00000000-0000-4000-c120-000000000008'));
select t.ok(not (t.j() ->> 'dry_run')::boolean and t.j() ->> 'created' = '1' and t.j() ->> 'updated' = '1' and jsonb_array_length(t.j() -> 'errors') = 0, 'clean real run: 1 created, 1 updated');
select t.ok((select name || '|' || sales_price || '|' || kind from erp.items where code = 'BR-001') = 'Bracket renamed by import|12.5000|consumable'
            and (select sales_price || '|' || kind from erp.items where code = 'IMP-1') = '3.5000|consumable'
            and t.count($$select 1 from erp.item_barcodes b join erp.items i using (tenant_id, item_id) where i.code = 'IMP-1'$$) = 2,
            'update keeps values of empty cells; new item with decimal comma price, category, VAT, two barcodes');
select t.ok((erp_api.item_import('[{"code": "IMP-1", "name": "Imported one", "unit": "pcs", "category": "brk", "vat": "VAT24", "sales_price": "3,50", "barcodes": "IMP1A;IMP1B", "kind": "consumable"},
                                    {"code": "BR-001", "name": "Bracket renamed by import", "sales_price": ""}]', false, '00000000-0000-4000-c120-000000000008')) = t.j()
            and t.count($$select 1 from erp.items where code = 'IMP-1'$$) = 1, 'same key: stored reply, nothing imported twice');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'item.import' and new_row ->> 'created' = '1'$$) = 1
            and t.count($$select 1 from erp.audit_log where action = 'item.create' and new_row ->> 'code' = 'IMP-1'$$) = 1, 'import audited (summary + each row)');
select t.ok(t.problems(format($$select erp_api.item_import('%s', true, gen_random_uuid())$$, (select jsonb_agg(jsonb_build_object('code', 'X' || g)) from generate_series(1, 2001) g)))
            -> 0 ->> 'code' = 'too_many', 'more than 2000 rows: refused');
select t.ok(t.problems($$select erp_api.item_import('[]', true, gen_random_uuid())$$) -> 0 ->> 'code' = 'required', 'no rows: refused');
select t.fails($$select erp_api.item_import('[{"code": "W-01", "active": "no"}]', true, gen_random_uuid())$$, 'ERP_FORBIDDEN', 'import cannot deactivate without master.archive');
select t.as(5);
select t.fails($$select erp_api.item_import('[{"code": "Z", "name": "z", "unit": "PCS"}]', true, gen_random_uuid())$$, 'ERP_FORBIDDEN', 'clinic_user cannot import items');
select t.as(4);
select t.keep(erp_api.counterparty_import('[{"name": "Ortho Supplies SA (new name)", "tax_id": "EL094014201", "city": "Serres"},
                                           {"name": "New Lab", "tax_id": "800000002", "kind": "supplier", "ext_ref": "LAB-9"},
                                           {"name": "Bad AFM", "tax_id": "800000003"},
                                           {"name": "New Lab again", "tax_id": "800000002"}]', true, gen_random_uuid()));
select t.ok(t.j() ->> 'created' = '3' and t.j() ->> 'updated' = '1'
            and (select string_agg((e ->> 'row') || ':' || (e ->> 'code'), ',' order by (e ->> 'row')::int) from jsonb_array_elements(t.j() -> 'errors') e) = '3:checksum,4:duplicate',
            'counterparty import dry run: match by tax ID (EL prefix), AFM checksum and duplicates in the file reported by row');
select t.keep(erp_api.counterparty_import('[{"name": "Ortho Supplies SA (new name)", "tax_id": "EL094014201", "city": "Serres"},
                                           {"name": "New Lab", "tax_id": "800000002", "kind": "supplier", "ext_ref": "LAB-9"}]', false, gen_random_uuid()));
select t.ok(t.j() ->> 'created' = '1' and t.j() ->> 'updated' = '1'
            and (select name || '|' || city || '|' || email from erp.counterparties where tax_id = '094014201' and tenant_id = t.a()) = 'Ortho Supplies SA (new name)|Serres|orders@ortho.test'
            and (select ext_source || ':' || ext_ref from erp.counterparties where tax_id = '800000002') = 'import:LAB-9',
            'counterparty import: update keeps other fields; new row ext_source = import');
select t.as(3);
select t.fails($$select erp_api.counterparty_import('[{"name": "x"}]', true, gen_random_uuid())$$, 'ERP_FORBIDDEN', 'warehouse cannot import counterparties');
reset role;

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
