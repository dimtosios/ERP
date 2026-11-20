-- =====================================================================
-- iSmile ERP  -  tests for E160_transfer.sql (T16): TRF internal transfer. Validation, role matrix (02 "TRF": owner /
-- manager c a, warehouse c, accounting / readonly r, clinic_user -), visibility for the source AND the destination
-- branch (doc_get / doc_list / actions / trf_get), dispatch (gapless number of the source branch, source -> transit,
-- negative-stock warning / ack / block of the source, idempotency, held reply not stored), receipt by line (dest side,
-- received vs received_with_difference, reasons, dates, lock date), cost unchanged through transit (both methods,
-- item cost state and FIFO layers untouched), cancel (source approver, stock back from transit, number kept),
-- difference -> generated ADJ_OUT (transit) / ADJ_IN (destination) through the ADJ value limit (submit / approve /
-- reject), auto-close, guards (delete / edit / cancel of the generated ADJ, foreign ADJ, open-transfer warehouses),
-- backdated receipt, integrity (erp.trf_integrity: transit zero for every closed transfer), golden G10, tenancy.
-- One transaction, ROLLED BACK. Last line: ALL TESTS PASSED + number of checks.
-- =====================================================================
begin;
\ir _helpers.sql

create table t.ids (a uuid, b uuid);
insert into t.ids select t.tenant('ta'), t.tenant('tb');
create function t.a() returns uuid language sql security definer as $$ select a from t.ids $$;
create function t.b() returns uuid language sql security definer as $$ select b from t.ids $$;
select t.init(t.a()), t.init(t.b());
select t.branch(t.a(), 'A1', 0), t.branch(t.a(), 'A2', 1), t.branch(t.a(), 'A3', 2), t.branch(t.b(), 'B1', 0);
select t.member(t.a(), 1, 'owner'), t.member(t.a(), 2, 'manager', array[t.br(t.a(), 'A1')]), t.member(t.a(), 3, 'warehouse', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 4, 'accounting', '{}', true), t.member(t.a(), 5, 'clinic_user', array[t.br(t.a(), 'A1')]), t.member(t.a(), 6, 'readonly', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 7, 'warehouse', array[t.br(t.a(), 'A2')]), t.member(t.a(), 8, 'manager', array[t.br(t.a(), 'A2')]), t.member(t.a(), 9, 'warehouse', array[t.br(t.a(), 'A3')]),
       t.member(t.b(), 11, 'owner');
insert into erp.warehouses (tenant_id, branch_id, code, name) values (t.a(), t.br(t.a(), 'A1'), 'W1', 'W one'), (t.a(), t.br(t.a(), 'A1'), 'W1B', 'W one b'),
  (t.a(), t.br(t.a(), 'A2'), 'W2', 'W two'), (t.a(), t.br(t.a(), 'A3'), 'W3', 'W three'), (t.b(), t.br(t.b(), 'B1'), 'BW', 'B w');
insert into erp.items (tenant_id, code, name, base_unit_id, kind)
select t.a(), c, 'Item ' || c, (select unit_id from erp.units where tenant_id = t.a() and code = 'PCS'), k from (values ('IT1', 'goods'), ('IT2', 'consumable'), ('SVC', 'service')) v(c, k);
insert into erp.counterparties (tenant_id, name, kind) values (t.a(), 'Supplier', 'supplier');
create function t.wh(p_code text) returns uuid language sql security definer as $$ select warehouse_id from erp.warehouses where code = p_code and tenant_id in (t.a(), t.b()) $$;
create function t.tw() returns uuid language sql security definer as $$ select warehouse_id from erp.warehouses where tenant_id = t.a() and kind = 'in_transit' $$;
create function t.it(p_code text) returns uuid language sql security definer as $$ select item_id from erp.items where tenant_id = t.a() and code = p_code $$;
create function t.cp() returns uuid language sql security definer as $$ select counterparty_id from erp.counterparties where tenant_id = t.a() and name = 'Supplier' $$;
create function t.today() returns date language sql security definer as $$ select erp.today(t.a()) $$;
create function t.doc(p_id text) returns erp.documents language sql security definer as $$ select d from erp.documents d where document_id = p_id::uuid $$;
create function t.bal(p_wh uuid, p_item text) returns numeric language sql security definer as $$
  select coalesce((select qty from erp.stock_balances where warehouse_id = p_wh and item_id = t.it(p_item)), 0) $$;
create function t.bal(p_wh text, p_item text) returns numeric language sql security definer as $$ select t.bal(t.wh(p_wh), p_item) $$;
create function t.num(n numeric) returns text language sql immutable as $$
  select case when n is null then '' when n::text like '%.%' then rtrim(rtrim(n::text, '0'), '.') else n::text end $$;
-- the item's company-wide cost state + open layers (the "cost unchanged" fingerprint)
create function t.cost(p_item text) returns text language sql security definer as $$
  select concat_ws('|', t.num(c.qty), c.value_avg, c.value_fifo, c.avg_cost, c.deficit_value,
                   (select coalesce(string_agg(t.num(l.qty_left) || '@' || t.num(l.unit_cost), ';' order by l.layer_date, l.seq, l.layer_id), '')
                      from erp.stock_layers l where l.item_id = c.item_id and l.qty_left > 0 and l.void_run is null))
    from erp.item_costs c where c.item_id = t.it(p_item) $$;
create function t.codes(p jsonb) returns text language sql immutable as $$ select string_agg(coalesce(e ->> 'line_no', '-') || ':' || (e ->> 'code') || ':' || coalesce(e ->> 'field', '-'), ','
  order by e ->> 'line_no' nulls first, e ->> 'field', e ->> 'code') from jsonb_array_elements(p) e $$;
create function t.acts(p jsonb) returns text language sql immutable as $$ select coalesce(string_agg(a ->> 'to_state', ',' order by a ->> 'to_state'), '') from jsonb_array_elements(p -> 'actions') a $$;
create table t.v (k text primary key, id text);
create function t.put(p_k text, p_id text) returns void language sql security definer as $$ insert into t.v values (p_k, p_id) on conflict (k) do update set id = excluded.id $$;
create function t.id(p_k text) returns text language sql security definer as $$ select id from t.v where k = p_k $$;
create function t.whbr(p_code text) returns uuid language sql security definer as $$ select branch_id from erp.warehouses where code = p_code and tenant_id = t.a() $$;
create function t.post(p_id text, p_ack boolean default false) returns jsonb language sql as $$
  select erp_api.doc_set_state(p_id::uuid, 'posted', jsonb_build_object('ack_warnings', p_ack), gen_random_uuid()) $$;
create function t.stock(p_type text, p_wh text, p_item text, p_qty numeric, p_cost numeric default null) returns jsonb language sql as $$
  select t.post((erp_api.doc_save_draft(p_type, jsonb_build_object('branch_id', t.whbr(p_wh), 'warehouse_id', t.wh(p_wh))
                   || case when p_type = 'GRN' then jsonb_build_object('counterparty_id', t.cp()) else '{}'::jsonb end
                   || case when p_type like 'ADJ%' then jsonb_build_object('extra', jsonb_build_object('reason', case when p_type = 'ADJ_IN' then 'found' else 'lost' end)) else '{}'::jsonb end
                   || jsonb_build_object('lines', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('item_id', t.it(p_item), 'qty', p_qty, 'unit_price', p_cost)))),
                 gen_random_uuid()) ->> 'document_id'), true) $$;
create function t.trf(p_from text, p_to text, p_lines jsonb, p_more jsonb default '{}') returns jsonb language sql as $$
  select erp_api.doc_save_draft('TRF', jsonb_build_object('branch_id', t.whbr(p_from), 'warehouse_id', t.wh(p_from), 'dest_warehouse_id', t.wh(p_to), 'lines', p_lines) || p_more,
                                gen_random_uuid()) $$;
create function t.l(p_item text, p_qty numeric) returns jsonb language sql security definer as $$ select jsonb_build_object('item_id', t.it(p_item), 'qty', p_qty) $$;
create function t.dispatch(p_id text, p_ack boolean default false) returns jsonb language sql as $$
  select erp_api.doc_set_state(p_id::uuid, 'dispatched', jsonb_build_object('ack_warnings', p_ack), gen_random_uuid()) $$;
create function t.receive(p_id text, p_to text default 'received', p_opts jsonb default '{}') returns jsonb language sql as $$
  select erp_api.doc_set_state(p_id::uuid, p_to, p_opts, gen_random_uuid()) $$;
create function t.line(p_doc text, p_item text) returns uuid language sql security definer as $$
  select line_id from erp.document_lines where document_id = p_doc::uuid and item_id = t.it(p_item) $$;
create function t.adj(p_trf text, p_type text) returns text language sql security definer as $$
  select (case p_type when 'ADJ_OUT' then adj_out_id else adj_in_id end)::text from erp.doc_trf where document_id = p_trf::uuid $$;
create function t.trfint() returns text language sql security definer as $$ select coalesce(string_agg(p ->> 'check', ','), '') from jsonb_array_elements(erp.trf_integrity(t.a())) p $$;
create function t.integ() returns int language sql security definer as $$ select jsonb_array_length(erp.stock_integrity(t.a())) + jsonb_array_length(erp.trf_integrity(t.a())) $$;
-- the stock move values of a document in a warehouse (signed, avg / fifo)
create function t.mv(p_doc text, p_wh uuid) returns text language sql security definer as $$
  select coalesce(string_agg(m.value_avg || '/' || m.value_fifo, ',' order by m.move_id), '') from erp.stock_moves m where m.document_id = p_doc::uuid and m.warehouse_id = p_wh and m.kind = 'normal' $$;
grant execute on all functions in schema t to authenticated;
grant select, insert, update on t.v to authenticated;

set local role authenticated;
select t.as(1);
select t.ok((select string_agg(r ->> 'code' || ':' || (r ->> 'gapless'), ',' order by r ->> 'code') from jsonb_array_elements((erp_api.series_create_defaults(t.br(t.a(), 'A1'), gen_random_uuid())) -> 'created') r)
            like '%TRF-A1:true%', 'series defaults: TRF-A1 per source branch, gapless (02: TRF is gapless)');
select erp_api.series_create_defaults(t.br(t.a(), 'A2'), gen_random_uuid()), erp_api.series_create_defaults(t.br(t.a(), 'A3'), gen_random_uuid());
-- stock: IT1 10 @ 4 + 10 @ 6 into W1, 5 consumed (avg 75.00, FIFO 80.00: layers 5@4;10@6); IT2 8 @ 1 into W1
select t.stock('GRN', 'W1', 'IT1', 10, 4), t.stock('GRN', 'W1', 'IT1', 10, 6), t.stock('CONS', 'W1', 'IT1', 5), t.stock('GRN', 'W1', 'IT2', 8, 1);
select t.ok(t.cost('IT1') = '15|75.00|80.00|5.000000|0.00|5@4;10@6', 'fixture: IT1 15 in W1, average 75.00, FIFO 80.00');

-- ---------- validation ----------
select t.as(3);
select t.ok(t.codes((t.trf('W1', 'W1', jsonb_build_array(t.l('IT1', 1)))) -> 'problems') = '-:invalid:dest_warehouse_id', 'destination = source: refused');
select t.ok(t.codes((erp_api.doc_save_draft('TRF', jsonb_build_object('branch_id', t.whbr('W1'), 'warehouse_id', t.wh('W1'), 'lines', jsonb_build_array(t.l('IT1', 1))), gen_random_uuid())) -> 'problems')
            = '-:required:dest_warehouse_id', 'destination required');
select t.ok(t.codes((erp_api.doc_save_draft('TRF', jsonb_build_object('branch_id', t.whbr('W1'), 'warehouse_id', t.tw(), 'dest_warehouse_id', t.tw(),
                                                                      'lines', jsonb_build_array(t.l('IT1', 1))), gen_random_uuid())) -> 'problems')
            = '-:invalid:dest_warehouse_id,-:invalid:warehouse_id', 'the transit warehouse is neither source nor destination');
select t.ok(t.codes((t.trf('W1', 'W2', jsonb_build_array(t.l('IT1', 1), t.l('IT1', 2), t.l('SVC', 1), jsonb_build_object('item_id', t.it('IT2'), 'qty', 1, 'unit_price', 2)),
                           '{"extra": {"delivery": {"carrier": "ACS", "plate": "x"}}}')) -> 'problems')
            = '-:not_editable:extra.delivery.plate,1:duplicate:item_id,3:invalid:item_id,4:invalid:unit_price',
            'problems: unknown delivery field, an item twice, a service, a price (a transfer moves at cost)');
select t.fails($$select t.trf('W2', 'W1', jsonb_build_array(t.l('IT1', 1)))$$, 'ERP_FORBIDDEN', 'warehouse member of A1 cannot dispatch from A2 (source branch)');
select t.as(5);
select t.fails($$select t.trf('W1', 'W2', jsonb_build_array(t.l('IT1', 1)))$$, 'ERP_FORBIDDEN', 'clinic_user cannot create a transfer (matrix -)');
select t.as(4);
select t.fails($$select t.trf('W1', 'W2', jsonb_build_array(t.l('IT1', 1)))$$, 'ERP_FORBIDDEN', 'accounting cannot create a transfer (matrix r)');

-- ---------- dispatch ----------
select t.as(3);
select t.keep(t.trf('W1', 'W2', jsonb_build_array(t.l('IT1', 6), t.l('IT2', 2)), '{"notes": "to clinic 2", "extra": {"delivery": {"carrier": "own car"}}}'));
select t.put('t1', t.j() ->> 'document_id');
select t.ok(jsonb_array_length(t.j() -> 'problems') = 0 and t.acts(t.j()) = 'dispatched' and t.j() ->> 'dest_warehouse_id' = t.wh('W2')::text,
            'valid draft: the warehouse member of the source may dispatch');
select t.keep(t.dispatch(t.id('t1')));
select t.ok(t.j() #>> '{document,state}' = 'dispatched' and t.j() #>> '{document,doc_no}' = 'TRF-A1/000001' and (t.j() ->> 'posted')::boolean
            and jsonb_array_length(t.j() -> 'warnings') = 0, 'dispatched: TRF-A1/000001 (the source branch''s series), posted = true');
select t.ok(t.bal('W1', 'IT1') = 9 and t.bal(t.tw(), 'IT1') = 6 and t.bal('W2', 'IT1') = 0 and t.bal(t.tw(), 'IT2') = 2,
            'stock: W1 15 -> 9, transit 6 (and IT2 2), destination untouched');
select t.ok(t.cost('IT1') = '15|75.00|80.00|5.000000|0.00|5@4;10@6', 'cost unchanged by the dispatch: item state and FIFO layers as before (no layer consumed)');
select t.ok(t.mv(t.id('t1'), t.wh('W1')) = '-30.00/-32.00,-2.00/-2.00' and t.mv(t.id('t1'), t.tw()) = '30.00/32.00,2.00/2.00',
            'dispatch values: 6 x avg 5 = 30.00, FIFO 6 x 80 / 15 = 32.00; the transit side carries the same value');
select t.as(1);
select t.ok((t.doc(t.id('t1'))).total_cost = 32.00 and (erp_api.doc_get(t.id('t1')::uuid)) #>> '{lines,0,cost_value}' = '30.00',
            'line cost = the dispatch value (official average); total 32.00');
select t.ok(t.integ() = 0 and t.trfint() = '', 'integrity clean: transit 6 + 2 = the open transfer');

-- ---------- visibility and actions: source AND destination ----------
select t.as(7);
select t.keep(erp_api.doc_get(t.id('t1')::uuid));
select t.ok(t.acts(t.j()) = 'received,received_with_difference', 'destination warehouse member (A2) reads the transfer and may receive it');
select t.ok(exists (select 1 from jsonb_array_elements((erp_api.doc_list('{"doc_type": "TRF", "state": "dispatched"}')) -> 'rows') r where r ->> 'document_id' = t.id('t1'))
            and exists (select 1 from jsonb_array_elements((erp_api.doc_list(jsonb_build_object('doc_type', 'TRF', 'branch_id', t.br(t.a(), 'A2')))) -> 'rows') r where r ->> 'document_id' = t.id('t1')),
            'doc_list of the destination branch lists it (also with its branch filter)');
select t.ok((select count(*) from erp.documents where doc_type = 'TRF') = 1, 'RLS: the destination member reads the TRF row directly too');
select t.fails(format($$select t.dispatch('%s')$$, t.id('t1')), 'ERP_STATE', 'a dispatched transfer is not dispatched again');
select t.fails(format($$select erp_api.doc_set_state('%s', 'cancelled', '{"reason": "x"}', gen_random_uuid())$$, t.id('t1')), 'ERP_FORBIDDEN', 'the destination cannot cancel');
select t.as(3);
select t.ok(t.acts(erp_api.doc_get(t.id('t1')::uuid)) = '', 'source warehouse member: no action (receipt = destination, cancel = approver)');
select t.fails(format($$select t.receive('%s')$$, t.id('t1')), 'ERP_FORBIDDEN', 'the source cannot confirm the receipt');
select t.fails(format($$select erp_api.doc_save_draft('TRF', '{"document_id": "%s", "version": 2, "notes": "x"}', gen_random_uuid())$$, t.id('t1')), 'ERP_DOC_IMMUTABLE',
               'a dispatched transfer is not edited');
select t.as(2);
select t.ok(t.acts(erp_api.doc_get(t.id('t1')::uuid)) = 'cancelled', 'source manager: cancel only');
select t.as(8);
select t.ok(t.acts(erp_api.doc_get(t.id('t1')::uuid)) = 'received,received_with_difference', 'destination manager: receive');
select t.as(6);
select t.ok(t.acts(erp_api.doc_get(t.id('t1')::uuid)) = '' and (erp_api.trf_get(t.id('t1')::uuid)) #>> '{transfer,lines,0,in_transit}' = '6.0000', 'readonly (A1) reads it, no action');
select t.as(5);
select t.fails(format($$select erp_api.doc_get('%s')$$, t.id('t1')), 'ERP_FORBIDDEN', 'clinic_user cannot read a transfer');
select t.as(9);
select t.fails(format($$select erp_api.trf_get('%s')$$, t.id('t1')), 'ERP_FORBIDDEN', 'a member of a third branch (A3) does not see it');
select t.ok(not exists (select 1 from jsonb_array_elements((erp_api.doc_list('{"doc_type": "TRF"}')) -> 'rows') r where r ->> 'document_id' = t.id('t1'))
            and (select count(*) from erp.documents where doc_type = 'TRF') = 0, '...nor in its list nor through RLS');
select t.as(11);
select t.fails(format($$select erp_api.trf_get('%s')$$, t.id('t1')), 'ERP_TENANT', 'tenant B: ERP_TENANT');
select t.fails(format($$select erp_api.doc_set_state('%s', 'received', '{}', gen_random_uuid())$$, t.id('t1')), 'ERP_TENANT', 'tenant B cannot receive it');

-- ---------- receipt: checks ----------
select t.as(7);
select t.ok(t.codes(t.problems(format($$select t.receive('%s', 'received', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('line_id', '%s', 'received_qty', 5))))$$,
                                      t.id('t1'), t.line(t.id('t1'), 'IT1')))) = '1:required:reason', 'a difference needs a reason');
select t.ok(t.codes(t.problems(format($$select t.receive('%s', 'received', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('line_id', '%s', 'received_qty', 5, 'reason', 'x'))))$$,
                                      t.id('t1'), t.line(t.id('t1'), 'IT1')))) = '-:state:to_state', 'quantities differ: "received" is refused (received_with_difference)');
select t.ok(t.codes(t.problems(format($$select t.receive('%s', 'received_with_difference', '{}')$$, t.id('t1')))) = '-:state:to_state',
            'no difference: "received_with_difference" is refused');
select t.ok(t.codes(t.problems(format($$select t.receive('%s', 'received', jsonb_build_object('receipt_date', t.today() + 1, 'foo', 1,
                                      'lines', jsonb_build_array(jsonb_build_object('line_id', gen_random_uuid(), 'received_qty', 1), jsonb_build_object('line_id', '%s', 'received_qty', -1))))$$,
                                      t.id('t1'), t.line(t.id('t1'), 'IT2'))))
            = '-:not_editable:foo,-:future_date:receipt_date,1:invalid:line_id,2:invalid:received_qty',
            'all problems at once: unknown key, future date, a line of another document, a negative quantity');
select t.ok(t.codes(t.problems(format($$select t.receive('%s', 'received', jsonb_build_object('receipt_date', t.today() - 30))$$, t.id('t1')))) = '-:invalid:receipt_date',
            'the receipt cannot be before the dispatch');
reset role;
update erp.tenant_settings set lock_date = t.today() where tenant_id = t.a();
set local role authenticated;
select t.as(7);
select t.fails(format($$select t.receive('%s')$$, t.id('t1')), 'ERP_LOCKED_PERIOD', 'a receipt inside a locked period is refused');
reset role;
update erp.tenant_settings set lock_date = null where tenant_id = t.a();

-- ---------- receipt without difference: cost unchanged through transit ----------
set local role authenticated;
select t.as(1);
select t.stock('GRN', 'W1', 'IT1', 10, 9);   -- while in transit the average moves: 25 / 165.00 / 170.00, avg 6.6
select t.as(7);
select t.keep(t.receive(t.id('t1'), 'received', '{"receipt_date": null}'));
select t.ok(t.j() #>> '{document,state}' = 'received' and t.j() #>> '{receipt,receipt_date}' = t.today()::text and t.j() #> '{receipt,adjustments}' = '[]'::jsonb,
            'received (default date today), no adjustment');
select t.ok(t.bal('W2', 'IT1') = 6 and t.bal(t.tw(), 'IT1') = 0 and t.bal('W2', 'IT2') = 2 and t.bal(t.tw(), 'IT2') = 0, 'transit back to zero, destination 6 + 2');
select t.ok(t.mv(t.id('t1'), t.wh('W2')) = '30.00/32.00,2.00/2.00' and t.mv(t.id('t1'), t.tw()) = '30.00/32.00,2.00/2.00,-30.00/-32.00,-2.00/-2.00',
            'receipt at the DISPATCH cost (30.00 / 32.00), not at the new average 6.6 (39.60): no drift through transit; transit value nets to 0');
select t.ok(t.cost('IT1') = '25|165.00|170.00|6.600000|0.00|5@4;10@6;10@9', 'cost unchanged by the receipt: state = the GRN''s, layers untouched');
select t.ok(t.integ() = 0 and (select closed_at is not null from erp.doc_trf where document_id = t.id('t1')::uuid), 'integrity clean; the transfer is settled (closed_at)');
select t.keep(erp_api.trf_get(t.id('t1')::uuid));
select t.ok(t.j() #>> '{transfer,lines,0,received_qty}' = '6.0000' and t.j() #>> '{transfer,lines,0,diff_qty}' = '0.0000' and t.j() #>> '{transfer,receipt,received_by_email}' = 'user7@erp.test'
            and t.j() #>> '{transfer,dest_branch_id}' = t.br(t.a(), 'A2')::text and (t.j() #>> '{transfer,fiscal_needed}')::boolean,
            'trf_get: received per line, the receiver, the destination branch, fiscal_needed (A1 / A2 are different establishments: T36 hook)');
select t.fails(format($$select t.receive('%s')$$, t.id('t1')), 'ERP_STATE', 'a received transfer is not received again');
select t.as(1);
select t.fails(format($$select erp_api.doc_set_state('%s', 'cancelled', '{"reason": "x"}', gen_random_uuid())$$, t.id('t1')), 'ERP_STATE', 'a received transfer cannot be cancelled');
select t.ok(t.count($$select 1 from erp.audit_log where action in ('doc.dispatched', 'doc.received', 'trf.receipt') and (row_id = '$$ || t.id('t1') || $$')$$) = 3, 'dispatch and receipt audited');

-- ---------- cancel ----------
select t.as(3);
select t.keep(t.dispatch((t.trf('W1', 'W1B', jsonb_build_array(t.l('IT1', 4)))) ->> 'document_id'));
select t.put('t2', t.j() #>> '{document,document_id}');
select t.ok(t.j() #>> '{document,doc_no}' = 'TRF-A1/000002' and t.bal(t.tw(), 'IT1') = 4 and t.bal('W1', 'IT1') = 15, 'TRF-A1/000002 inside one branch: W1 19 -> 15, transit 4');
select t.fails(format($$select erp_api.doc_set_state('%s', 'cancelled', '{"reason": "x"}', gen_random_uuid())$$, t.id('t2')), 'ERP_FORBIDDEN', 'the warehouse member cannot cancel (approve: no)');
select t.as(2);
select t.fails(format($$select erp_api.doc_set_state('%s', 'cancelled', '{}', gen_random_uuid())$$, t.id('t2')), 'ERP_VALIDATION', 'cancel needs a reason');
select t.keep(erp_api.doc_set_state(t.id('t2')::uuid, 'cancelled', '{"reason": "wrong clinic"}', gen_random_uuid()));
select t.ok(t.j() #>> '{document,state}' = 'cancelled' and t.j() #>> '{document,doc_no}' = 'TRF-A1/000002' and t.bal(t.tw(), 'IT1') = 0 and t.bal('W1', 'IT1') = 19
            and t.bal('W1B', 'IT1') = 0, 'manager cancels: the stock returns from transit to W1, the number is kept');
select t.ok(t.cost('IT1') = '25|165.00|170.00|6.600000|0.00|5@4;10@6;10@9' and t.integ() = 0, 'cancel leaves the cost state and layers as before; integrity clean');

-- ---------- gapless numbering, negative-stock warning of the source, idempotency ----------
select t.as(3);
select t.keep(t.trf('W1', 'W2', jsonb_build_array(t.l('IT2', 9))));
select t.put('t3', t.j() ->> 'document_id');
select t.keep(erp_api.doc_set_state(t.id('t3')::uuid, 'dispatched', '{}', '00000000-0000-4000-c160-000000000001'));
select t.ok(not (t.j() ->> 'posted')::boolean and t.j() #>> '{warnings,0,code}' = 'W_STOCK_NEGATIVE' and t.j() #>> '{warnings,0,qty_after}' = '-3.0000'
            and t.j() #>> '{document,state}' = 'draft' and not (t.j() ? 'held') and (erp_api.doc_check(t.id('t3')::uuid)) #>> '{warnings,0,warehouse_code}' = 'W1',
            'over-dispatch of the source (6 of IT2 left, 9 sent): W_STOCK_NEGATIVE, nothing written (doc_check gives the same)');
select t.keep(erp_api.doc_set_state(t.id('t3')::uuid, 'dispatched', '{"ack_warnings": true}', '00000000-0000-4000-c160-000000000001'));
select t.ok((t.j() ->> 'posted')::boolean and t.j() #>> '{document,doc_no}' = 'TRF-A1/000003' and t.bal('W1', 'IT2') = -3 and t.bal(t.tw(), 'IT2') = 9,
            'same key + ack (the held reply was not stored): dispatched TRF-A1/000003, gapless after the cancelled /000002; W1 at -3');
select t.ok((erp_api.doc_set_state(t.id('t3')::uuid, 'dispatched', '{"ack_warnings": true}', '00000000-0000-4000-c160-000000000001')) #>> '{document,doc_no}' = 'TRF-A1/000003'
            and t.bal(t.tw(), 'IT2') = 9, 'the same key again: the stored reply, nothing dispatched twice');
select t.ok(t.count($$select 1 from erp.alerts where kind = 'negative_stock' and resolved_at is null and params ->> 'warehouse_code' = 'W1'$$) = 1
            and t.count($$select 1 from erp.alerts where tenant_id = t.a() and (params ->> 'warehouse_code') = 'TRANSIT'$$) = 0,
            'one negative-stock alert for W1, never an alert on the transit warehouse');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'doc.warnings_acknowledged' and row_id = '$$ || t.id('t3') || $$'$$) = 1, 'the acknowledgement is audited');
reset role;
update erp.tenant_settings set negative_stock = 'block' where tenant_id = t.a();
set local role authenticated;
select t.as(3);
select t.fails(format($$select t.dispatch('%s', true)$$, (t.trf('W1', 'W2', jsonb_build_array(t.l('IT2', 1)))) ->> 'document_id'), 'ERP_STOCK_NEGATIVE',
               'setting block: an over-dispatch is refused even with ack');
reset role;
update erp.tenant_settings set negative_stock = 'warn' where tenant_id = t.a();
set local role authenticated;
select t.as(1);
select t.stock('GRN', 'W1', 'IT2', 10, 1);
select t.as(7);
select t.receive(t.id('t3'));
select t.ok(t.bal(t.tw(), 'IT2') = 0 and t.bal('W2', 'IT2') = 11 and t.integ() = 0, 'TRF-A1/000003 received: transit 0');

-- ---------- receipt with a difference -> generated ADJ through the ADJ path -> auto-close ----------
select t.as(3);
select t.keep(t.dispatch((t.trf('W1', 'W2', jsonb_build_array(t.l('IT1', 5), t.l('IT2', 4)))) ->> 'document_id'));
select t.put('t4', t.j() #>> '{document,document_id}');
select t.as(7);
select t.keep(t.receive(t.id('t4'), 'received_with_difference', jsonb_build_object('lines', jsonb_build_array(
  jsonb_build_object('line_id', t.line(t.id('t4'), 'IT1'), 'received_qty', 3, 'reason', '2 broken in the box'),
  jsonb_build_object('line_id', t.line(t.id('t4'), 'IT2'), 'received_qty', 5, 'reason', 'one more packed')))));
select t.ok(t.j() #>> '{document,state}' = 'received_with_difference' and jsonb_array_length(t.j() #> '{receipt,adjustments}') = 2,
            'received_with_difference: two generated adjustments');
select t.ok(t.bal(t.tw(), 'IT1') = 2 and t.bal('W2', 'IT1') = 9 and t.bal(t.tw(), 'IT2') = 0 and t.bal('W2', 'IT2') = 15,
            'the received quantity moved (3 IT1, 4 IT2 = all dispatched); the shortage 2 stays in transit until its ADJ is posted');
select t.ok(t.mv(t.id('t4'), t.wh('W1')) = '-33.00/-34.00,-4.00/-4.00' and t.mv(t.id('t4'), t.wh('W2')) = '19.80/20.40,4.00/4.00',
            'partial receipt at the dispatch unit cost: dispatch 5 x 6.6 = 33.00 (FIFO 5 x 170 / 25 = 34.00), received 3 = 19.80 / 20.40');
select t.put('ao', t.adj(t.id('t4'), 'ADJ_OUT')); select t.put('ai', t.adj(t.id('t4'), 'ADJ_IN'));
select t.keep(erp_api.doc_get(t.id('ao')::uuid));
select t.ok(t.j() ->> 'doc_type' = 'ADJ_OUT' and t.j() ->> 'state' = 'draft' and t.j() ->> 'source' = 'system' and t.j() ->> 'warehouse_id' = t.tw()::text
            and t.j() ->> 'branch_id' = t.br(t.a(), 'A2')::text and t.j() #>> '{extra,reason}' = 'lost' and t.j() ->> 'ref_document_id' = t.id('t4')
            and t.j() #>> '{lines,0,qty}' = '2.0000' and t.j() #>> '{lines,0,description}' = '2 broken in the box' and jsonb_array_length(t.j() -> 'problems') = 0,
            'ADJ_OUT draft: system, destination branch, OUT OF TRANSIT, 2 x IT1, reason lost, the receiver''s text');
select t.ok((erp_api.doc_get(t.id('ai')::uuid)) #>> '{warehouse_id}' = t.wh('W2')::text and (erp_api.doc_get(t.id('ai')::uuid)) #>> '{lines,0,qty}' = '1.0000'
            and (erp_api.doc_get(t.id('ai')::uuid)) #>> '{extra,reason}' = 'found', 'ADJ_IN draft: 1 x IT2 into the destination, reason found');
select t.ok(t.integ() = 0 and t.trfint() = '', 'integrity: transit 2 = the open shortage of TRF /000004');
select t.ok((erp_api.trf_get(t.id('t4')::uuid)) #>> '{transfer,lines,0,in_transit}' = '2.0000' and (erp_api.trf_get(t.id('t4')::uuid)) #>> '{transfer,lines,0,diff_reason}' = '2 broken in the box'
            and (select string_agg(a ->> 'state', ',') from jsonb_array_elements((erp_api.trf_get(t.id('t4')::uuid)) #> '{transfer,adjustments}') a) = 'draft,draft',
            'trf_get: what is still in transit, the reasons, the adjustments and their state');
-- guards on the generated adjustments
select t.fails(format($$select erp_api.doc_delete_draft('%s', gen_random_uuid())$$, t.id('ao')), 'ERP_STATE', 'the generated ADJ cannot be deleted');
select t.ok(t.codes((erp_api.doc_save_draft('ADJ_OUT', jsonb_build_object('document_id', t.id('ao'), 'version', 1, 'lines', jsonb_build_array(t.l('IT1', 1))), gen_random_uuid())) -> 'problems')
            = '-:mismatch:lines', 'edited quantity: the lines must be the difference exactly');
select t.fails(format($$select t.post('%s')$$, t.id('ao')), 'ERP_VALIDATION', '...and it cannot be posted so');
select t.ok(jsonb_array_length((erp_api.doc_save_draft('ADJ_OUT', jsonb_build_object('document_id', t.id('ao'), 'version', 2, 'doc_date', t.today(),
                                 'extra', '{"reason": "damaged"}'::jsonb, 'lines', jsonb_build_array(t.l('IT1', 2))), gen_random_uuid())) -> 'problems') = 0,
            'back to 2 (reason damaged may be chosen): valid again');
select t.ok(t.codes((erp_api.doc_save_draft('ADJ_OUT', jsonb_build_object('document_id', t.id('ao'), 'version', 3, 'warehouse_id', t.wh('W2')), gen_random_uuid())) -> 'problems')
            = '-:invalid:warehouse_id', 'its warehouse cannot change');
select erp_api.doc_save_draft('ADJ_OUT', jsonb_build_object('document_id', t.id('ao'), 'version', 4, 'warehouse_id', t.tw()), gen_random_uuid());
select t.ok(t.codes((erp_api.doc_save_draft('ADJ_OUT', jsonb_build_object('document_id', t.id('ao'), 'version', 5, 'ref_document_id', null, 'lines', jsonb_build_array(t.l('IT2', 9))),
                                            gen_random_uuid())) -> 'problems') = '-:mismatch:lines,-:invalid:ref_document_id',
            'dropping the reference does not free it: still checked as the generated ADJ (no other quantity out of transit)');
select t.fails(format($$select erp_api.doc_delete_draft('%s', gen_random_uuid())$$, t.id('ao')), 'ERP_STATE', '...and still not deleted');
select erp_api.doc_save_draft('ADJ_OUT', jsonb_build_object('document_id', t.id('ao'), 'version', 6, 'ref_document_id', t.id('t4'), 'lines', jsonb_build_array(t.l('IT1', 2))),
                              gen_random_uuid());
select t.ok(t.codes((erp_api.doc_save_draft('ADJ_IN', jsonb_build_object('branch_id', t.br(t.a(), 'A2'), 'warehouse_id', t.wh('W2'), 'ref_document_id', t.id('t4'),
                       'extra', '{"reason": "found"}'::jsonb, 'lines', jsonb_build_array(t.l('IT2', 1))), gen_random_uuid())) -> 'problems') = '-:invalid:ref_document_id',
            'a user ADJ cannot reference the transfer (only the generated one)');
select t.ok(t.codes((erp_api.doc_save_draft('ADJ_OUT', jsonb_build_object('branch_id', t.br(t.a(), 'A2'), 'warehouse_id', t.tw(),
                       'extra', '{"reason": "lost"}'::jsonb, 'lines', jsonb_build_array(t.l('IT1', 2))), gen_random_uuid())) -> 'problems') = '-:invalid:warehouse_id',
            'a user ADJ cannot take stock out of transit');
select t.fails(format($$select erp_api.doc_set_state('%s', 'closed', '{}', gen_random_uuid())$$, t.id('t4')), 'ERP_STATE', 'manual close before the adjustments are posted: refused');
-- the ADJ value limit: ADJ_OUT 2 x avg 6.6 = 13.20 > 5 -> submit / approve; ADJ_IN 1 x IT2 ~1 <= 5 -> the warehouse member posts it
reset role;
update erp.tenant_settings set thresholds = '{"adj_value": 5}' where tenant_id = t.a();
set local role authenticated;
select t.as(7);
select t.ok(t.acts(erp_api.doc_get(t.id('ao')::uuid)) = 'pending_approval', 'ADJ_OUT over the limit: the warehouse member can only submit it');
select erp_api.doc_set_state(t.id('ao')::uuid, 'pending_approval', '{}', gen_random_uuid());
select t.as(8);
select erp_api.doc_set_state(t.id('ao')::uuid, 'draft', '{"reason": "check the box again"}', gen_random_uuid());
select t.ok((t.doc(t.id('ao'))).state = 'draft' and (t.doc(t.id('t4'))).state = 'received_with_difference', 'the manager rejects it: back to draft, the transfer waits');
select t.as(7);
select erp_api.doc_set_state(t.id('ao')::uuid, 'pending_approval', '{}', gen_random_uuid());
select t.ok(t.post(t.id('ai')) #>> '{document,state}' = 'posted' and t.bal('W2', 'IT2') = 16 and (t.doc(t.id('t4'))).state = 'received_with_difference',
            'ADJ_IN under the limit posted by the receiver: W2 IT2 16; the transfer still waits for its ADJ_OUT');
select t.as(8);
select t.keep(t.post(t.id('ao')));
select t.ok(t.j() #>> '{document,state}' = 'posted' and t.j() #>> '{document,doc_no}' = 'ADJ_OUT-A2/000001' and t.bal(t.tw(), 'IT1') = 0
            and (t.doc(t.id('t4'))).state = 'closed' and (select closed_at is not null from erp.doc_trf where document_id = t.id('t4')::uuid),
            'the A2 manager approves the ADJ_OUT: transit 0 and the transfer CLOSES by itself');
select t.ok(t.cost('IT1') = '23|151.80|162.00|6.600000|0.00|3@4;10@6;10@9' and t.integ() = 0 and t.trfint() = '',
            'the shortage left at the current cost (average 2 x 6.6 = 13.20; FIFO the oldest layer 2 x 4 = 8.00); integrity clean, transit zero for every closed transfer');
select t.fails(format($$select erp_api.doc_set_state('%s', 'cancelled', '{"reason": "x"}', gen_random_uuid())$$, t.id('ao')), 'ERP_DOC_HAS_CHILDREN',
               'the posted difference adjustment of a closed transfer cannot be cancelled');
select t.ok(t.bal(t.tw(), 'IT1') = 0 and (t.doc(t.id('ao'))).state = 'posted', '...nothing came back into transit');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'doc.closed' and row_id = '$$ || t.id('t4') || $$'$$) = 1, 'the close is audited');
reset role;
update erp.tenant_settings set thresholds = '{}' where tenant_id = t.a();

-- ---------- warehouse guard, backdated receipt, manual close fallback ----------
set local role authenticated;
select t.as(1);
-- a receipt dated 5 days ago (10 @ 5): at 2 days ago the item held 10 at 5.00 (the later moves are today's)
select t.post((erp_api.doc_save_draft('GRN', jsonb_build_object('branch_id', t.whbr('W1'), 'warehouse_id', t.wh('W1'), 'counterparty_id', t.cp(), 'doc_date', t.today() - 5,
                 'lines', jsonb_build_array(jsonb_build_object('item_id', t.it('IT1'), 'qty', 10, 'unit_price', 5))), gen_random_uuid())) ->> 'document_id');
select t.as(3);
select t.keep(t.dispatch((t.trf('W1', 'W3', jsonb_build_array(t.l('IT1', 2)), jsonb_build_object('doc_date', t.today() - 2))) ->> 'document_id'));
select t.put('t5', t.j() #>> '{document,document_id}');
select t.as(1);
select t.fails(format($$select erp_api.warehouse_save('{"warehouse_id": "%s", "active": false}', gen_random_uuid())$$, t.wh('W3')), 'ERP_VALIDATION',
               'the destination of an open transfer cannot be deactivated');
select t.as(9);
select t.keep(t.receive(t.id('t5'), 'received', jsonb_build_object('receipt_date', t.today() - 1)));
select t.ok(t.j() #>> '{document,state}' = 'received' and t.bal('W3', 'IT1') = 2 and t.bal(t.tw(), 'IT1') = 0
            and (select min(move_date) from erp.stock_moves where document_id = t.id('t5')::uuid and warehouse_id = t.wh('W3')) = t.today() - 1
            and t.mv(t.id('t5'), t.wh('W1')) = '-10.00/-10.00' and t.mv(t.id('t5'), t.wh('W3')) = '10.00/10.00',
            'backdated dispatch (2 days ago: 2 x 5.00 = the state AT its date, by replay) and receipt (yesterday): receipt = dispatch cost');
select t.ok(t.integ() = 0 and t.count($$select 1 from erp.recost_queue where tenant_id = t.a()$$) = 0, 'replayed inline, integrity clean');
-- a manager without trf rights on the destination posts the ADJ: the transfer waits for the manual close
reset role;
update erp.role_caps set allowed = false where tenant_id = t.a() and role = 'manager' and capability = 'doc.trf.create';
set local role authenticated;
select t.as(3);
select t.keep(t.dispatch((t.trf('W1', 'W2', jsonb_build_array(t.l('IT1', 1)))) ->> 'document_id'));
select t.put('t6', t.j() #>> '{document,document_id}');
select t.as(7);
select t.receive(t.id('t6'), 'received_with_difference', jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('line_id', t.line(t.id('t6'), 'IT1'), 'received_qty', 0, 'reason', 'lost'))));
select t.ok(t.bal(t.tw(), 'IT1') = 1 and t.bal('W2', 'IT1') = 9, 'nothing received: the whole line stays in transit');
select t.as(8);
select t.post(t.adj(t.id('t6'), 'ADJ_OUT'));
select t.ok((t.doc(t.adj(t.id('t6'), 'ADJ_OUT'))).state = 'posted' and (t.doc(t.id('t6'))).state = 'received_with_difference' and t.bal(t.tw(), 'IT1') = 0,
            'ADJ posted by a manager who may not close transfers: the transfer stays received_with_difference');
select t.as(7);
select t.ok(t.acts(erp_api.doc_get(t.id('t6')::uuid)) = 'closed' and (erp_api.doc_set_state(t.id('t6')::uuid, 'closed', '{}', gen_random_uuid())) #>> '{document,state}' = 'closed',
            'the destination warehouse member closes it (manual fallback)');
reset role;
update erp.role_caps set allowed = true where tenant_id = t.a() and role = 'manager' and capability = 'doc.trf.create';
select t.ok(t.integ() = 0, 'integrity clean after every transfer scenario');

-- ---------- integrity detects a transit leak (the job's check is not vacuous) ----------
savepoint leak;
select erp.balance_add(t.a(), t.tw(), t.it('IT2'), '00000000-0000-0000-0000-000000000000', 1, null);
insert into erp.stock_moves (tenant_id, document_id, line_id, warehouse_id, item_id, move_date, kind, qty_base, cost_rule, src_move_id)
select t.a(), t.id('t4')::uuid, t.line(t.id('t4'), 'IT2'), t.tw(), t.it('IT2'), t.today(), 'normal', 1, 'transfer', null;
select t.ok(t.trfint() like '%transit_open%', 'a quantity left in transit by a closed transfer is reported (transit_open)');
rollback to savepoint leak;
select t.ok(t.trfint() = '', 'clean again');

-- ---------- golden G10: cost unchanged through transit, transit zero for closed transfers ----------
create table t.g10 (step int, op text, wh text, wh_to text, qty numeric, unit_cost numeric, src_step int, exp_qty numeric, exp_value_avg numeric, exp_value_fifo numeric,
                    exp_move_avg numeric, exp_move_fifo numeric, exp_layers text, exp_transit numeric, exp_trf_state text);
\copy t.g10 from 'golden/G10.csv' with (format csv, header)
create table t.g10res (step int, got text, want text);
create table t.g10doc (step int, doc uuid);
grant select, insert on t.g10, t.g10res, t.g10doc to authenticated;
insert into erp.items (tenant_id, code, name, base_unit_id) select t.a(), 'G10', 'Golden 10', unit_id from erp.units where tenant_id = t.a() and code = 'PCS';
-- state after a step: item qty / values, the step's move (the LAST normal move of the step's document in the step's
-- warehouse: dispatch = the source move, receipt = the destination move), layers, transit, transfer state, integrity
create function t.g10mv(p_doc uuid, p_wh uuid) returns erp.stock_moves language sql security definer as $$
  select m from erp.stock_moves m where m.document_id = p_doc and m.warehouse_id = p_wh and m.kind = 'normal' and m.item_id = t.it('G10') order by m.move_id desc limit 1 $$;
create function t.g10state(p_step int, p_doc uuid, p_trf uuid, p_wh uuid) returns text language sql security definer as $$
  select concat_ws('|', t.num(c.qty), c.value_avg, c.value_fifo, (t.g10mv(p_doc, p_wh)).value_avg, (t.g10mv(p_doc, p_wh)).value_fifo,
                   (select coalesce(string_agg(t.num(l.qty_left) || '@' || t.num(l.unit_cost), ';' order by l.layer_date, l.seq, l.layer_id), '')
                      from erp.stock_layers l where l.item_id = c.item_id and l.qty_left > 0 and l.void_run is null),
                   t.num(coalesce((select b.qty from erp.stock_balances b where b.warehouse_id = t.tw() and b.item_id = c.item_id), 0)),
                   (select d.state from erp.documents d where d.document_id = p_trf),
                   jsonb_array_length(erp.stock_integrity(t.a(), c.item_id)) + jsonb_array_length(erp.trf_integrity(t.a())))
    from erp.item_costs c where c.item_id = t.it('G10') $$;
grant execute on all functions in schema t to authenticated;
set local role authenticated;
select t.as(1);
do $$ declare g record; d jsonb; doc uuid; trf uuid; wh uuid; begin
  for g in select * from t.g10 order by step loop
    trf := null;
    if g.op in ('in', 'out') and g.wh <> 'TRANSIT' then
      d := erp_api.doc_save_draft(case when g.op = 'in' then 'GRN' else 'CONS' end, jsonb_build_object('branch_id', t.whbr(g.wh), 'warehouse_id', t.wh(g.wh))
             || case when g.op = 'in' then jsonb_build_object('counterparty_id', t.cp()) else '{}'::jsonb end
             || jsonb_build_object('lines', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('item_id', t.it('G10'), 'qty', g.qty, 'unit_price', g.unit_cost)))), gen_random_uuid());
      doc := (d ->> 'document_id')::uuid; wh := t.wh(g.wh);
      perform t.post(doc::text, true);
    elsif g.op = 'out' then          -- the shortage of the transfer received at src_step: its generated ADJ_OUT out of transit
      trf := (select x.doc from t.g10doc x where x.step = g.src_step);
      doc := t.adj(trf::text, 'ADJ_OUT')::uuid; wh := t.tw();
      perform t.post(doc::text);
    elsif g.op = 'trf' then
      d := t.trf(g.wh, g.wh_to, jsonb_build_array(t.l('G10', g.qty)));
      doc := (d ->> 'document_id')::uuid; trf := doc; wh := t.wh(g.wh);
      perform t.dispatch(doc::text, true);
    elsif g.op = 'trf_in' then
      trf := (select x.doc from t.g10doc x where x.step = g.src_step); doc := trf; wh := (select dest_warehouse_id from erp.documents where document_id = trf);
      perform t.receive(trf::text, case when g.qty = (select qty_base from erp.document_lines where document_id = trf) then 'received' else 'received_with_difference' end,
                        jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('line_id', t.line(trf::text, 'G10'), 'received_qty', g.qty, 'reason', 'golden'))));
    elsif g.op = 'trf_cancel' then
      trf := (select x.doc from t.g10doc x where x.step = g.src_step); doc := null; wh := null;
      perform erp_api.doc_set_state(trf, 'cancelled', '{"reason": "golden"}', gen_random_uuid());
    end if;
    insert into t.g10doc values (g.step, coalesce(trf, doc));
    insert into t.g10res values (g.step, t.g10state(g.step, doc, trf, wh),
      concat_ws('|', t.num(g.exp_qty), g.exp_value_avg, g.exp_value_fifo, g.exp_move_avg, g.exp_move_fifo, coalesce(g.exp_layers, ''), t.num(g.exp_transit), g.exp_trf_state, 0));
  end loop;
end $$;
select t.ok(not exists (select 1 from t.g10res where got <> want), 'golden G10 (dispatch, GRN while in transit, receipt at the dispatch cost, cancel, short receipt + ADJ_OUT): ' ||
            coalesce((select string_agg('#' || step || ' got ' || got || ' want ' || want, '; ' order by step) from t.g10res where got <> want), 'all 12 steps equal'));
reset role;
select t.ok(jsonb_array_length(erp.stock_integrity(t.a())) = 0 and jsonb_array_length(erp.trf_integrity(t.a())) = 0
            and (erp.integrity_job()) is not null
            and not exists (select 1 from erp.alerts where tenant_id = t.a() and kind = 'integrity' and resolved_at is null),
            'stock + transit integrity clean; the nightly job raises no integrity alert for the tenant');

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
