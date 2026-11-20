-- =====================================================================
-- iSmile ERP  -  tests for E210_sales.sql (Draft 2, sales lite): DN delivery note, RR retail receipt (goods), RS retail
-- receipt (services). Catalogue (types, transitions, capabilities as data), gapless numbering per branch (incl. a
-- rolled-back post and a non-gapless series refused), VAT arithmetic per line (item default / chosen class, half up),
-- delivery block / to-be-billed / payment-method validation, DN stock out at the official cost (average), negative-stock
-- warning / ack / block, cancel symmetry (stock and item cost state back, number kept, reason, approver roles), RR with
-- and without a delivery-note reference (no stock for referenced lines, remaining quantity, DN not cancellable while
-- billed, not-to-be-billed / customer / branch checks), RS (services, no stock), roles (01 C1 + 02 matrix), sales_get
-- (non-fiscal flags, watermark, issuer from settings, VAT breakdown, billing state, collection), the RCPT hook
-- erp.sales_collection, settings issuer validation, tenant isolation.
-- One transaction, ROLLED BACK. Last line: ALL TESTS PASSED + number of checks.
-- =====================================================================
begin;
\ir _helpers.sql

create table t.ids (a uuid, b uuid);
insert into t.ids select t.tenant('sa'), t.tenant('sb');
create function t.a() returns uuid language sql security definer as $$ select a from t.ids $$;
create function t.b() returns uuid language sql security definer as $$ select b from t.ids $$;
select t.init(t.a()), t.init(t.b());
select t.branch(t.a(), 'A1', 0), t.branch(t.a(), 'A2', 1), t.branch(t.b(), 'B1', 0);
select t.member(t.a(), 1, 'owner'), t.member(t.a(), 2, 'manager', array[t.br(t.a(), 'A1')]), t.member(t.a(), 3, 'warehouse', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 4, 'accounting', '{}', true), t.member(t.a(), 5, 'clinic_user', array[t.br(t.a(), 'A1')]), t.member(t.a(), 6, 'readonly', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 8, 'manager', array[t.br(t.a(), 'A2')]), t.member(t.b(), 11, 'owner');
insert into erp.warehouses (tenant_id, branch_id, code, name) values (t.a(), t.br(t.a(), 'A1'), 'W1', 'W one'), (t.a(), t.br(t.a(), 'A2'), 'W2', 'W two'),
  (t.b(), t.br(t.b(), 'B1'), 'BW', 'B w');
insert into erp.items (tenant_id, code, name, base_unit_id, kind, vat_class_id)
select t.a(), c, 'Item ' || c, (select unit_id from erp.units where tenant_id = t.a() and code = 'PCS'), k, (select vat_class_id from erp.vat_classes where tenant_id = t.a() and code = v)
  from (values ('IT1', 'goods', 'VAT24'), ('IT2', 'goods', 'VAT6'), ('SVC', 'service', 'VAT24')) x(c, k, v);
insert into erp.items (tenant_id, code, name, base_unit_id) values (t.b(), 'BIT', 'B item', (select unit_id from erp.units where tenant_id = t.b() and code = 'PCS'));
insert into erp.counterparties (tenant_id, name, kind, tax_id, street, city) values (t.a(), 'Cust', 'customer', '094014201', 'Main 1', 'Serres'), (t.a(), 'Both', 'both', null, null, null),
  (t.a(), 'Supplier', 'supplier', null, null, null), (t.b(), 'B cust', 'customer', null, null, null);
create function t.wh(p_code text) returns uuid language sql security definer as $$ select warehouse_id from erp.warehouses where code = p_code $$;
create function t.it(p_code text) returns uuid language sql security definer as $$ select item_id from erp.items where code = p_code $$;
create function t.cp(p_name text) returns uuid language sql security definer as $$ select counterparty_id from erp.counterparties where name = p_name $$;
create function t.vat(p_code text) returns uuid language sql security definer as $$ select vat_class_id from erp.vat_classes where tenant_id = t.a() and code = p_code $$;
create function t.whbr(p_code text) returns uuid language sql security definer as $$ select branch_id from erp.warehouses where code = p_code $$;
create function t.bal(p_wh text, p_item text) returns numeric language sql security definer as $$
  select coalesce((select qty from erp.stock_balances where warehouse_id = t.wh(p_wh) and item_id = t.it(p_item)), 0) $$;
create function t.num(n numeric) returns text language sql immutable as $$
  select case when n is null then '' when n::text like '%.%' then rtrim(rtrim(n::text, '0'), '.') else n::text end $$;
create function t.cost(p_item text) returns text language sql security definer as $$
  select concat_ws('|', t.num(c.qty), c.value_avg, c.value_fifo, c.avg_cost,
                   (select coalesce(string_agg(t.num(l.qty_left) || '@' || t.num(l.unit_cost), ';' order by l.layer_date, l.seq, l.layer_id), '')
                      from erp.stock_layers l where l.item_id = c.item_id and l.qty_left > 0 and l.void_run is null))
    from erp.item_costs c where c.item_id = t.it(p_item) $$;
create function t.moves(p_doc text) returns bigint language sql security definer as $$ select count(*) from erp.stock_moves where document_id = p_doc::uuid $$;
create function t.doc(p_id text) returns erp.documents language sql security definer as $$ select d from erp.documents d where document_id = p_id::uuid $$;
create function t.codes(p jsonb) returns text language sql immutable as $$ select string_agg(coalesce(e ->> 'line_no', '-') || ':' || (e ->> 'code') || ':' || coalesce(e ->> 'field', '-'), ','
  order by e ->> 'line_no' nulls first, e ->> 'field', e ->> 'code') from jsonb_array_elements(p) e $$;
create function t.acts(p jsonb) returns text language sql immutable as $$ select coalesce(string_agg(a ->> 'to_state', ',' order by a ->> 'to_state'), '') from jsonb_array_elements(p -> 'actions') a $$;
create table t.v (k text primary key, id text);
create function t.put(p_k text, p_id text) returns void language sql security definer as $$ insert into t.v values (p_k, p_id) on conflict (k) do update set id = excluded.id $$;
create function t.id(p_k text) returns text language sql security definer as $$ select id from t.v where k = p_k $$;
create function t.l(p_item text, p_qty numeric, p_price numeric default null, p_vat text default null) returns jsonb language sql security definer as $$
  select jsonb_strip_nulls(jsonb_build_object('item_id', t.it(p_item), 'qty', p_qty, 'unit_price', p_price, 'vat_class_id', t.vat(p_vat))) $$;
create function t.dn(p_wh text, p_lines jsonb, p_more jsonb default '{}') returns jsonb language sql as $$
  select erp_api.doc_save_draft('DN', jsonb_build_object('branch_id', t.whbr(p_wh), 'warehouse_id', t.wh(p_wh), 'counterparty_id', t.cp('Cust'),
                                                         'extra', '{"delivery": {"reason": "sale", "address": "Main 1, Serres", "carrier": "Own van", "vehicle": "ABC-1234"}}'::jsonb,
                                                         'lines', p_lines) || p_more, gen_random_uuid()) $$;
create function t.rr(p_wh text, p_lines jsonb, p_more jsonb default '{}') returns jsonb language sql as $$
  select erp_api.doc_save_draft('RR', jsonb_build_object('branch_id', t.whbr(p_wh), 'warehouse_id', t.wh(p_wh), 'extra', '{"payment_method": "card"}'::jsonb,
                                                         'lines', p_lines) || p_more, gen_random_uuid()) $$;
create function t.go(p_id text, p_to text, p_opts jsonb default '{}') returns jsonb language sql as $$
  select erp_api.doc_set_state(p_id::uuid, p_to, p_opts, gen_random_uuid()) $$;
create function t.post(p_id text, p_ack boolean default false) returns jsonb language sql as $$ select t.go(p_id, 'posted', jsonb_build_object('ack_warnings', p_ack)) $$;
create function t.next(p_code text) returns bigint language sql security definer as $$ select next_no from erp.series where tenant_id = t.a() and code = p_code $$;
create function t.dnl(p_doc text, p_no int) returns uuid language sql security definer as $$ select line_id from erp.document_lines where document_id = p_doc::uuid and line_no = p_no $$;
create function t.line(p_doc text, p_item text) returns uuid language sql security definer as $$
  select line_id from erp.document_lines where document_id = p_doc::uuid and item_id = t.it(p_item) $$;
create function t.grn(p_wh text, p_item text, p_qty numeric, p_cost numeric) returns jsonb language sql as $$
  select t.post((erp_api.doc_save_draft('GRN', jsonb_build_object('branch_id', t.whbr(p_wh), 'warehouse_id', t.wh(p_wh), 'counterparty_id', t.cp('Supplier'),
                   'lines', jsonb_build_array(jsonb_build_object('item_id', t.it(p_item), 'qty', p_qty, 'unit_price', p_cost))), gen_random_uuid())) ->> 'document_id') $$;
grant execute on all functions in schema t to authenticated;
grant select, insert, update on t.v to authenticated;

-- ---------- catalogue ----------
select t.ok((select string_agg(doc_type || ':' || enabled || ':' || fiscal || ':' || gapless_default || ':' || stock_sign || ':' || cost_rule || ':' || needs_warehouse || ':' || price_kind
                               || ':' || needs_counterparty || ':' || series_scope, ',' order by doc_type) from erp.doc_types where doc_type in ('DN', 'RR', 'RS'))
            = 'DN:true:false:true:-1:issue:true:sale:true:branch,RR:true:false:true:-1:issue:true:sale:false:branch,RS:true:false:true:0:none:false:sale:false:branch',
            'DN / RR / RS enabled: NOT fiscal in v1, gapless per branch, DN / RR issue stock at cost, RS no stock, sale prices, DN needs a customer');
select t.ok((select string_agg(doc_type || ':' || from_state || '>' || to_state || ':' || cap, ',' order by doc_type, from_state) from erp.doc_transitions where doc_type in ('DN', 'RR', 'RS'))
            = 'DN:draft>posted:create,DN:posted>cancelled:approve,RR:draft>posted:create,RR:posted>cancelled:approve,RS:draft>posted:create,RS:posted>cancelled:approve',
            'transitions are data: post by create, cancel by approve');
select t.ok((select string_agg(role || ':' || substr(capability, 5), ',' order by role, capability) from erp.role_caps where tenant_id = t.a() and allowed
               and (capability like 'doc.dn.%' or capability like 'doc.rr.%' or capability like 'doc.rs.%'))
            = 'accounting:dn.create,accounting:dn.read,accounting:rr.create,accounting:rr.read,accounting:rs.create,accounting:rs.read,clinic_user:rr.create,clinic_user:rr.read,'
              'manager:dn.approve,manager:dn.create,manager:dn.read,manager:rr.approve,manager:rr.create,manager:rr.read,manager:rs.approve,manager:rs.create,manager:rs.read,'
              'owner:dn.approve,owner:dn.create,owner:dn.read,owner:rr.approve,owner:rr.create,owner:rr.read,owner:rs.approve,owner:rs.create,owner:rs.read,'
              'readonly:dn.read,readonly:rr.read,readonly:rs.read,warehouse:dn.create,warehouse:dn.read',
            'capabilities (01 C1: DN W A M O / cancel M O; RR A C M O; RS A M O; cancel M O; readonly reads)');

set local role authenticated;
select t.as(1);
select t.ok((select string_agg(r ->> 'code' || ':' || (r ->> 'gapless'), ',' order by r ->> 'code') from jsonb_array_elements((erp_api.series_create_defaults(t.br(t.a(), 'A1'), gen_random_uuid())) -> 'created') r
               where r ->> 'doc_type' in ('DN', 'RR', 'RS')) = 'DN-A1:true,RR-A1:true,RS-A1:true', 'series defaults: DN / RR / RS per branch, gapless');
select erp_api.series_create_defaults(t.br(t.a(), 'A2'), gen_random_uuid());
-- stock: IT1 10 @ 4 + 10 @ 6 into W1 (average 5), IT2 5 @ 2 into W1
select t.grn('W1', 'IT1', 10, 4), t.grn('W1', 'IT1', 10, 6), t.grn('W1', 'IT2', 5, 2);

-- ---------- issuer (tenant settings, printed on sales documents) ----------
select t.ok(t.codes(t.problems($$select erp_api.settings_save(jsonb_build_object('version', (select version from erp.tenant_settings), 'issuer', '{"tax_id": "el 1", "zzz": "x", "phone": 5}'::jsonb), gen_random_uuid())$$))
            = '-:invalid:issuer.phone,-:invalid:issuer.tax_id,-:not_editable:issuer.zzz', 'issuer: unknown key, non-text and a bad tax ID refused together');
select t.keep(erp_api.settings_save(jsonb_build_object('version', (select version from erp.tenant_settings),
                'issuer', '{"legal_name": "iSmile Orthodontics P.C.", "tax_id": "800000000", "tax_office": "Serres", "address": "Merarchias 1, Serres", "phone": "", "email": "info@ismile.test"}'::jsonb), gen_random_uuid()));
select t.ok(t.j() -> 'issuer' = '{"legal_name": "iSmile Orthodontics P.C.", "tax_id": "800000000", "tax_office": "Serres", "address": "Merarchias 1, Serres", "email": "info@ismile.test"}'::jsonb,
            'issuer saved (empty fields dropped) and returned by the settings');

-- ---------- DN draft: arithmetic, defaults, validation ----------
select t.as(3);
select t.keep(t.dn('W1', jsonb_build_array(t.l('IT1', 4, 12.35), t.l('IT2', 3, 1.05, 'VAT13'), t.l('IT1', 1)), '{"extra": {"delivery": {"reason": "sale", "address": "Main 1", "vehicle": "ABC-1234"}, "to_be_billed": true}}'));
select t.put('dn1', t.j() ->> 'document_id');
select t.ok((select string_agg(coalesce(l ->> 'net', '') || '/' || coalesce(l ->> 'vat', '') || '/' || coalesce(l ->> 'gross', ''), ',' order by (l ->> 'line_no')::int) from jsonb_array_elements(t.j() -> 'lines') l)
            = '49.40/11.86/61.26,3.15/0.41/3.56,0.00/0.00/0.00',
            'line VAT: the item''s class (IT1 24 %) or the chosen one (13 %), per line, half up (11.856 -> 11.86, 0.4095 -> 0.41); a line without price is 0');
select t.ok(t.j() ->> 'total_net' = '52.55' and t.j() ->> 'total_vat' = '12.27' and t.j() ->> 'total_gross' = '64.82' and jsonb_array_length(t.j() -> 'problems') = 0
            and t.j() ->> 'doc_no' is null, 'totals = sums of the rounded lines; a complete draft has no problems and no number');
select t.ok(t.codes(t.j() -> 'problems') is null and t.acts(t.j()) = 'posted', 'warehouse member may post a DN (create)');
select t.ok(t.codes((t.dn('W1', jsonb_build_array(t.l('IT1', 1, 5), t.l('SVC', 1, 5)),
                          jsonb_build_object('counterparty_id', t.cp('Supplier'), 'extra', '{"delivery": {"reason": "gift", "vehicle": "TOO-LONG-VEHICLE-NUMBER-X", "colour": "red"}, "to_be_billed": "yes"}'::jsonb))) -> 'problems')
            = '-:invalid:counterparty_id,-:not_editable:extra.delivery.colour,-:invalid:extra.delivery.reason,-:invalid:extra.delivery.vehicle,-:invalid:extra.to_be_billed,2:invalid:item_id',
            'DN problems at once: a supplier as customer, unknown delivery key, bad reason, long vehicle, to_be_billed not boolean, a service line');
select t.ok(t.codes((t.dn('W1', jsonb_build_array(t.l('IT1', 1, 5)), '{"counterparty_id": null, "extra": {}}')) -> 'problems')
            = '-:required:counterparty_id,-:required:extra.delivery.reason', 'DN needs a customer and the reason of the movement');
select t.ok(t.codes((t.dn('W1', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 1, 'unit_price', 5, 'vat_class_id', null)))) -> 'problems')
            = '1:required:vat_class_id', 'a priced line needs a VAT class (explicit null stays null)');
select t.fails($$select t.dn('W1', jsonb_build_array(jsonb_build_object('item_id', t.it('BIT'), 'qty', 1)))$$, 'ERP_TENANT', 'an item of another tenant: ERP_TENANT');
select t.fails($$select t.dn('W1', jsonb_build_array(t.l('IT1', 1)), jsonb_build_object('counterparty_id', t.cp('B cust')))$$, 'ERP_TENANT', 'a customer of another tenant: ERP_TENANT');
select t.fails($$select t.dn('W1', jsonb_build_array(t.l('IT1', 1)), '{"extra": {"delivery": {"reason": "sale"}, "payment_method": "cash"}}')$$, 'ERP_VALIDATION',
               'payment_method is not a DN field');

-- ---------- DN post: gapless number (rollback returns it), stock out at the official cost ----------
savepoint sp_dn;
select t.ok((t.post(t.id('dn1'))) ->> 'posted' = 'true' and (t.doc(t.id('dn1'))).doc_no = 'DN-A1/000001', 'post inside a savepoint takes DN-A1/000001');
rollback to savepoint sp_dn;
select t.ok((t.doc(t.id('dn1'))).state = 'draft' and t.next('DN-A1') = 1 and t.bal('W1', 'IT1') = 20,
            'rolled back: still a draft, the series is back at 1, no stock moved');
select t.keep(t.post(t.id('dn1')));
select t.ok(t.j() ->> 'posted' = 'true' and (t.doc(t.id('dn1'))).doc_no = 'DN-A1/000001' and (t.doc(t.id('dn1'))).state = 'posted', 'posted again: DN-A1/000001 (no gap)');
select t.ok(t.bal('W1', 'IT1') = 15 and t.bal('W1', 'IT2') = 2, 'stock out: IT1 20 - 5, IT2 5 - 3');
reset role;
select t.ok((select string_agg(l.line_no || ':' || t.num(l.unit_cost) || ':' || l.cost_value, ',' order by l.line_no) from erp.document_lines l where l.document_id = t.id('dn1')::uuid)
            = '1:5:20.00,2:2:6.00,3:5:5.00' and (t.doc(t.id('dn1'))).total_cost = 31.00,
            'cost: official average (IT1 (40 + 60) / 20 = 5, IT2 2), line and document cost set by the engine');
select t.ok((select string_agg(distinct m.cost_rule, ',') from erp.stock_moves m where m.document_id = t.id('dn1')::uuid) = 'issue' and t.cost('IT1') = '15|75.00|80.00|5.000000|5@4;10@6',
            'moves use the issue rule (as CONS): average 75.00 left, FIFO took 5 of the 4.00 layer (80.00 left)');
set local role authenticated;
select t.as(3);
select t.ok(t.acts(erp_api.doc_get(t.id('dn1')::uuid)) = '', 'warehouse cannot cancel a DN (approve: M O)');
select t.fails($$select t.go(t.id('dn1'), 'cancelled', '{"reason": "x"}')$$, 'ERP_FORBIDDEN', 'warehouse cancel refused');

-- non-gapless series refused
select t.as(1);
select erp_api.series_save(jsonb_build_object('doc_type', 'DN', 'branch_id', t.br(t.a(), 'A1'), 'code', 'DN-GAP', 'gapless', false, 'is_default', false), gen_random_uuid());
select t.ok(t.codes((t.dn('W1', jsonb_build_array(t.l('IT1', 1, 1)), jsonb_build_object('series_id', (select series_id from erp.series where code = 'DN-GAP')))) -> 'problems')
            = '-:invalid:series_id', 'a series that is not gapless cannot number a sales document');

-- ---------- negative stock: warning / ack / block ----------
select t.as(2);
select t.keep(t.dn('W1', jsonb_build_array(t.l('IT2', 5, 3))));
select t.put('dn2', t.j() ->> 'document_id');
select t.keep(t.post(t.id('dn2')));
select t.ok(t.j() ->> 'posted' = 'false' and t.j() #>> '{warnings,0,code}' = 'W_STOCK_NEGATIVE' and (t.j() #>> '{warnings,0,qty_after}')::numeric = -3
            and (t.doc(t.id('dn2'))).state = 'draft' and t.next('DN-A1') = 2,
            'past zero: warning, nothing posted, no number taken');
reset role;
update erp.tenant_settings set negative_stock = 'block' where tenant_id = t.a();
set local role authenticated;
select t.as(2);
select t.fails($$select t.post(t.id('dn2'), true)$$, 'ERP_STOCK_NEGATIVE', 'setting block: refused even with ack');
reset role;
update erp.tenant_settings set negative_stock = 'warn' where tenant_id = t.a();
set local role authenticated;
select t.as(2);
select t.keep(t.post(t.id('dn2'), true));
select t.ok(t.j() ->> 'posted' = 'true' and (t.doc(t.id('dn2'))).doc_no = 'DN-A1/000002' and t.bal('W1', 'IT2') = -3, 'ack: posted DN-A1/000002, IT2 at -3');

-- ---------- cancel symmetry ----------
reset role;
create table t.before as select t.cost('IT2') c2, t.bal('W1', 'IT2') b2;
set local role authenticated;
select t.as(2);
select t.fails($$select t.go(t.id('dn2'), 'cancelled', '{}')$$, 'ERP_VALIDATION', 'cancel needs a reason');
select t.keep(t.go(t.id('dn2'), 'cancelled', '{"reason": "wrong customer"}'));
reset role;
select t.ok((t.doc(t.id('dn2'))).state = 'cancelled' and (t.doc(t.id('dn2'))).doc_no = 'DN-A1/000002' and (t.doc(t.id('dn2'))).cancel_reason = 'wrong customer'
            and t.bal('W1', 'IT2') = 2 and t.cost('IT2') = '2|4.00|4.00|2.000000|2@2',
            'manager cancels: stock back (2), item cost state back, number kept, reason stored');
select t.ok((select count(*) from erp.stock_moves m where m.document_id = t.id('dn2')::uuid and m.kind = 'reversal') = 1
            and jsonb_array_length(erp.stock_integrity(t.a())) = 0, 'one reversing move; stock integrity clean');

-- ---------- RR without a delivery note: stock out, payment method ----------
set local role authenticated;
select t.as(5);   -- clinic_user: RR create (01 "A C M O")
select t.keep(t.rr('W1', jsonb_build_array(t.l('IT1', 2, 10)), '{"extra": {}}'));
select t.put('rr1', t.j() ->> 'document_id');
select t.ok(t.codes(t.j() -> 'problems') = '-:required:extra.payment_method', 'RR: the payment method is required');
select t.ok(t.codes((t.rr('W1', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 1)), '{"extra": {"payment_method": "cheque"}}')) -> 'problems')
            = '-:invalid:extra.payment_method,1:required:unit_price', 'RR: unknown method, price required');
select t.keep(erp_api.doc_save_draft('RR', jsonb_build_object('document_id', t.id('rr1'), 'version', (t.doc(t.id('rr1'))).version, 'extra', '{"payment_method": "cash"}'::jsonb), gen_random_uuid()));
select t.ok(t.j() ->> 'total_gross' = '24.80' and jsonb_array_length(t.j() -> 'problems') = 0, 'RR 2 x 10 + 24 % = 24.80');
select t.keep(t.post(t.id('rr1')));
select t.ok(t.j() ->> 'posted' = 'true' and (t.doc(t.id('rr1'))).doc_no = 'RR-A1/000001' and t.bal('W1', 'IT1') = 13, 'clinic_user posts RR-A1/000001; stock out 2');
select t.ok(t.acts(erp_api.doc_get(t.id('rr1')::uuid)) = '', 'clinic_user cannot cancel an RR');
select t.fails($$select erp_api.doc_get(t.id('dn1')::uuid)$$, 'ERP_FORBIDDEN', 'clinic_user does not read delivery notes');
select t.fails($$select t.dn('W1', jsonb_build_array(t.l('IT1', 1)))$$, 'ERP_FORBIDDEN', 'clinic_user cannot issue a delivery note');
select t.as(3);
select t.fails($$select erp_api.doc_get(t.id('rr1')::uuid)$$, 'ERP_FORBIDDEN', 'warehouse does not read retail receipts (02)');
select t.as(4);
select t.ok(t.acts(erp_api.doc_get(t.id('rr1')::uuid)) = '', 'accounting cannot cancel an RR (approve: M O)');
select t.as(6);
select t.ok((erp_api.doc_get(t.id('rr1')::uuid)) ->> 'can_edit' = 'false' and t.acts(erp_api.doc_get(t.id('dn1')::uuid)) = ''
            and (select count(*) from jsonb_array_elements((erp_api.doc_list('{"doc_types": ["DN", "RR", "RS"], "state": "posted"}')) -> 'rows') r) = 2, 'readonly reads DN / RR (list: 2 posted), no actions');
select t.fails($$select t.rr('W1', jsonb_build_array(t.l('IT1', 1, 1)))$$, 'ERP_FORBIDDEN', 'readonly cannot issue');
select t.as(8);
select t.fails($$select erp_api.doc_get(t.id('rr1')::uuid)$$, 'ERP_FORBIDDEN', 'manager of another branch does not read A1 receipts');
select t.fails($$select t.rr('W1', jsonb_build_array(t.l('IT1', 1, 1)))$$, 'ERP_FORBIDDEN', 'manager of another branch cannot issue in A1');

-- ---------- RR billing a delivery note: no stock for referenced lines ----------
select t.as(4);
select t.keep(t.rr('W1', jsonb_build_array(
                jsonb_build_object('item_id', t.it('IT1'), 'qty', 3, 'unit_price', 12.35, 'extra', jsonb_build_object('dn_line_id', t.dnl(t.id('dn1'), 1))),
                t.l('IT2', 1, 4)),
              jsonb_build_object('ref_document_id', t.id('dn1'), 'counterparty_id', t.cp('Cust'))));
select t.put('rr2', t.j() ->> 'document_id');
select t.ok(jsonb_array_length(t.j() -> 'problems') = 0 and t.j() ->> 'total_gross' = '50.18', 'RR billing 3 of the DN line (37.05 + 8.89) plus a free line (4.00 + 0.24) = 50.18');
select t.ok(t.codes((t.rr('W1', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 2, 'unit_price', 1, 'extra', jsonb_build_object('dn_line_id', t.dnl(t.id('dn1'), 1))),
                                                   jsonb_build_object('item_id', t.it('IT1'), 'qty', 1, 'unit_price', 1, 'extra', jsonb_build_object('dn_line_id', t.dnl(t.id('dn1'), 1))),
                                                   jsonb_build_object('item_id', t.it('IT2'), 'qty', 1, 'unit_price', 1, 'extra', jsonb_build_object('dn_line_id', t.dnl(t.id('dn1'), 3)))),
                         jsonb_build_object('ref_document_id', t.id('dn1')))) -> 'problems')
            = '-:invalid:counterparty_id,1:duplicate:extra.dn_line_id,1:exceeds:qty,2:duplicate:extra.dn_line_id,2:exceeds:qty,3:invalid:item_id',
            'referenced lines: the DN''s customer, a DN line billed twice, more than the remaining (drafts count), another item');
select t.ok(t.codes((t.rr('W1', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 1, 'unit_price', 1, 'extra', jsonb_build_object('dn_line_id', t.dnl(t.id('dn1'), 1)))))) -> 'problems')
            = '1:invalid:extra.dn_line_id', 'a DN line without the header reference is refused');
select t.ok(t.codes((t.rr('W1', jsonb_build_array(t.l('IT1', 1, 1)), jsonb_build_object('ref_document_id', t.id('rr1')))) -> 'problems')
            = '-:invalid:ref_document_id', 'a retail receipt refers to a delivery note only');
select t.ok((select count(*) from jsonb_array_elements(((select t.rr('W1', jsonb_build_array(t.l('IT1', 1, 1)), jsonb_build_object('ref_document_id', t.id('dn2'), 'counterparty_id', t.cp('Cust')))) -> 'problems')) p
              where p ->> 'field' = 'ref_document_id' and p ->> 'message' like '%not posted%') = 1, 'a cancelled delivery note cannot be billed');
reset role;
-- the refused drafts above were SAVED (a draft keeps its problems) and count against the remaining quantity: drop them
delete from erp.documents where tenant_id = t.a() and doc_type = 'RR' and state = 'draft' and document_id <> t.id('rr2')::uuid;
create table t.b4 as select t.bal('W1', 'IT1') b1, t.bal('W1', 'IT2') b2, t.cost('IT1') c1;
grant select on t.b4 to authenticated;
set local role authenticated;
select t.as(4);
select t.keep(t.post(t.id('rr2')));
reset role;
select t.ok(t.j() ->> 'posted' = 'true' and (t.doc(t.id('rr2'))).doc_no = 'RR-A1/000002' and t.bal('W1', 'IT1') = (select b1 from t.b4) and t.bal('W1', 'IT2') = (select b2 from t.b4) - 1
            and t.cost('IT1') = (select c1 from t.b4) and t.moves(t.id('rr2')) = 1,
            'RR posted: the DN-referenced IT1 line moves NO stock (cost state unchanged), the free IT2 line goes out (one move)');
select t.ok((select cost_value from erp.document_lines where document_id = t.id('rr2')::uuid and line_no = 1) is null
            and (select cost_value from erp.document_lines where document_id = t.id('rr2')::uuid and line_no = 2) = 2.00, 'cost only on the line that moved stock');
set local role authenticated;
select t.as(1);
select t.keep(erp_api.sales_get(t.id('dn1')::uuid));
select t.ok(t.j() #>> '{sales,billing,status}' = 'partial' and t.j() #>> '{sales,billing,lines,0,billed}' = '3.0000' and t.j() #>> '{sales,billing,lines,0,remaining}' = '1.0000'
            and t.j() #>> '{sales,billing,receipts,0,doc_no}' = 'RR-A1/000002', 'DN billing state: partial, 3 of 4 billed, the receipt listed');
select t.fails($$select t.go(t.id('dn1'), 'cancelled', '{"reason": "x"}')$$, 'ERP_DOC_HAS_CHILDREN', 'a billed delivery note cannot be cancelled while its receipt lives');
select t.keep(t.go(t.id('rr2'), 'cancelled', '{"reason": "customer changed mind"}'));
reset role;
select t.ok(t.bal('W1', 'IT1') = (select b1 from t.b4) and t.bal('W1', 'IT2') = (select b2 from t.b4), 'RR cancel: only the free line comes back');
set local role authenticated;
select t.as(1);
select t.ok((erp_api.sales_get(t.id('dn1')::uuid)) #>> '{sales,billing,status}' = 'open', 'after the receipt''s cancel the DN is open again');
select t.as(2);
select t.keep(t.go(t.id('dn1'), 'cancelled', '{"reason": "returned"}'));
select t.ok((t.doc(t.id('dn1'))).state = 'cancelled' and t.bal('W1', 'IT1') = (select b1 from t.b4) + 5, 'then the DN cancels: its 5 IT1 come back');
-- not to be billed
select t.as(3);
select t.keep(t.dn('W1', jsonb_build_array(t.l('IT1', 1, 2)), '{"extra": {"delivery": {"reason": "sample"}, "to_be_billed": false}}'));
select t.put('dn3', t.j() ->> 'document_id');
select t.post(t.id('dn3'));
select t.as(4);
select t.ok(t.codes((t.rr('W1', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 1, 'unit_price', 1, 'extra', jsonb_build_object('dn_line_id', t.dnl(t.id('dn3'), 1)))),
                         jsonb_build_object('ref_document_id', t.id('dn3'), 'counterparty_id', t.cp('Cust')))) -> 'problems') = '-:invalid:ref_document_id',
            'a delivery note marked not to be billed cannot be billed');
select t.ok((erp_api.sales_get(t.id('dn3')::uuid)) #>> '{sales,billing,status}' = 'not_to_be_billed', 'billing state: not to be billed');

-- ---------- RS: services, no stock ----------
select t.as(4);
select t.ok(t.codes((erp_api.doc_save_draft('RS', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'extra', '{"payment_method": "bank"}'::jsonb,
                       'lines', jsonb_build_array(t.l('IT1', 1, 5))), gen_random_uuid())) -> 'problems') = '1:invalid:item_id', 'RS: goods refused');
select t.keep(erp_api.doc_save_draft('RS', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'counterparty_id', t.cp('Both'), 'extra', '{"payment_method": "bank"}'::jsonb,
                'lines', jsonb_build_array(t.l('SVC', 2, 50), jsonb_build_object('description', 'Retainer cleaning', 'qty', 1, 'unit_price', 20, 'vat_class_id', t.vat('VAT0')))), gen_random_uuid()));
select t.put('rs1', t.j() ->> 'document_id');
select t.ok(jsonb_array_length(t.j() -> 'problems') = 0 and t.j() ->> 'total_gross' = '144.00', 'RS: service item (24 %) + description line (0 %)');
select t.keep(t.post(t.id('rs1')));
select t.ok(t.j() ->> 'posted' = 'true' and (t.doc(t.id('rs1'))).doc_no = 'RS-A1/000001' and t.moves(t.id('rs1')) = 0, 'RS posted RS-A1/000001, no stock move');
select t.as(5);
select t.fails($$select erp_api.doc_save_draft('RS', jsonb_build_object('branch_id', t.br(t.a(), 'A1')), gen_random_uuid())$$, 'ERP_FORBIDDEN', 'clinic_user cannot issue RS (01: A M O)');

-- ---------- sales_get: print data, non-fiscal ----------
select t.as(5);
select t.keep(erp_api.sales_get(t.id('rr1')::uuid));
select t.ok(t.j() #>> '{sales,fiscal}' = 'false' and t.j() #>> '{sales,fiscal_needed}' = 'true' and t.j() #>> '{sales,watermark}' = 'NOT A FISCAL DOCUMENT',
            'non-fiscal: fiscal false, fiscal_needed true (as a TRF), watermark text');
select t.ok(t.j() #>> '{sales,issuer,name}' = 'Test sa' and t.j() #>> '{sales,issuer,tax_id}' = '800000000' and t.j() #>> '{sales,branch,code}' = 'A1'
            and t.j() #>> '{sales,warehouse,code}' = 'W1' and t.j() -> 'sales' -> 'customer' = 'null'::jsonb, 'issuer from the settings, branch, warehouse; no customer on this receipt');
select t.ok(t.j() #>> '{sales,collection,payment_method}' = 'cash' and t.j() #>> '{sales,collection,amount}' = '24.80' and t.j() #>> '{sales,collection,rcpt}' is null
            and t.j() -> 'sales' -> 'dn' = 'null'::jsonb, 'collection data (RCPT: next task)');
select t.ok(not (t.j() #> '{lines,0}' ? 'cost_value'), 'clinic_user gets no cost on the lines');
select t.as(1);
select t.keep(erp_api.sales_get(t.id('rs1')::uuid));
select t.ok(t.j() #> '{sales,vat_breakdown}' = jsonb_build_array(
              jsonb_build_object('vat_class_id', t.vat('VAT24'), 'code', 'VAT24', 'rate', 24.00, 'net', 100.00, 'vat', 24.00, 'gross', 124.00),
              jsonb_build_object('vat_class_id', t.vat('VAT0'), 'code', 'VAT0', 'rate', 0.00, 'net', 20.00, 'vat', 0.00, 'gross', 20.00))
            and t.j() #>> '{sales,customer,name}' = 'Both', 'VAT breakdown by class (rate desc), customer block');
select t.fails($$select erp_api.sales_get((select document_id from erp.documents where doc_type = 'GRN' limit 1))$$, 'ERP_VALIDATION', 'sales_get refuses a non-sales document');
reset role;
select t.ok((erp.sales_collection(t.a(), t.id('rs1')::uuid)) ->> 'amount' = '144.00' and (erp.sales_collection(t.a(), t.id('rs1')::uuid)) ->> 'payment_method' = 'bank'
            and erp.sales_collection(t.a(), t.id('dn3')::uuid) is null and erp.sales_collection(t.a(), t.id('rr2')::uuid) is null,
            'RCPT hook: a posted RR / RS returns method and amount; a DN or a cancelled receipt returns null');

-- ---------- tenant isolation ----------
set local role authenticated;
select t.as(11);
select t.fails($$select erp_api.sales_get(t.id('rr1')::uuid)$$, 'ERP_TENANT', 'tenant B cannot read A''s receipt');
select t.fails($$select t.go(t.id('rs1'), 'cancelled', '{"reason": "x"}')$$, 'ERP_TENANT', 'tenant B cannot cancel A''s receipt');
select t.fails($$select erp_api.doc_save_draft('RR', jsonb_build_object('branch_id', t.br(t.b(), 'B1'), 'ref_document_id', t.id('dn3')), gen_random_uuid())$$, 'ERP_TENANT',
               'tenant B cannot reference A''s delivery note');
select t.ok((select count(*) from erp.documents where doc_type in ('DN', 'RR', 'RS')) = 0, 'RLS: tenant B reads no A sales document');
reset role;

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
