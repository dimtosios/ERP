-- =====================================================================
-- iSmile ERP  -  tests for E140_stock_engine.sql (T10): golden valuation cases G1-G5 (tests/golden, average AND FIFO
-- per move, state after every step, open layers, integrity), cancel symmetry (post + cancel leaves balances, layers
-- and costs exactly as before), cancel with later moves (replay as if the document never existed), backdated post
-- (replay from its date, later costs and document lines rewritten), negative stock warning without / with ack, the
-- 'block' setting, ledger guards (append-only, cost columns only by the costing code), master-data guards, RLS of
-- the stock tables. Uses TEST document types TIN / TOUT / TRIN / TROUT (one per cost rule).
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
select t.member(t.a(), 1, 'owner'), t.member(t.a(), 3, 'warehouse', array[t.br(t.a(), 'A1')]), t.member(t.a(), 6, 'readonly', array[t.br(t.a(), 'A2')]),
       t.member(t.b(), 11, 'owner');
insert into erp.warehouses (tenant_id, branch_id, code, name) values (t.a(), t.br(t.a(), 'A1'), 'W1', 'W one'), (t.a(), t.br(t.a(), 'A1'), 'W1B', 'W one b'),
  (t.a(), t.br(t.a(), 'A2'), 'W2', 'W two');
insert into erp.doc_types (doc_type, name, area, cap_prefix, sort, enabled, stock_sign, cost_rule, needs_warehouse, price_kind) values
  ('TIN', 'Test in', 'warehouse', 'tst', 990, true, 1, 'line', true, 'cost'),
  ('TOUT', 'Test out', 'warehouse', 'tst', 991, true, -1, 'issue', true, 'none'),
  ('TRIN', 'Test customer return', 'warehouse', 'tst', 992, true, 1, 'source_out', true, 'none'),
  ('TROUT', 'Test supplier return', 'warehouse', 'tst', 993, true, -1, 'source_in', true, 'none');
insert into erp.doc_transitions (doc_type, from_state, to_state, cap, action, label)
select dt, f, t2, c, a, 'x' from unnest(array['TIN', 'TOUT', 'TRIN', 'TROUT']) dt,
  (values ('draft', 'posted', 'create', 'post'), ('posted', 'cancelled', 'approve', 'cancel')) v(f, t2, c, a);
insert into erp.capabilities (capability, area) values ('doc.tst.read', 'test'), ('doc.tst.create', 'test'), ('doc.tst.approve', 'test');
insert into erp.role_caps (tenant_id, role, capability) values (t.a(), 'owner', 'doc.tst.read'), (t.a(), 'owner', 'doc.tst.create'), (t.a(), 'owner', 'doc.tst.approve'),
  (t.a(), 'warehouse', 'doc.tst.read'), (t.a(), 'warehouse', 'doc.tst.create'), (t.b(), 'owner', 'doc.tst.read'), (t.b(), 'owner', 'doc.tst.create');
insert into erp.series (tenant_id, branch_id, doc_type, code)
select t.a(), b.branch_id, dt, dt || '-' || b.code from erp.branches b, unnest(array['TIN', 'TOUT', 'TRIN', 'TROUT']) dt where b.tenant_id = t.a();

create function t.wh(p_code text) returns uuid language sql security definer as $$ select warehouse_id from erp.warehouses where tenant_id = t.a() and code = p_code $$;
create function t.mkitem(p_code text) returns uuid language sql security definer as $$
  insert into erp.items (tenant_id, code, name, base_unit_id) select t.a(), p_code, 'Item ' || p_code, unit_id from erp.units where tenant_id = t.a() and code = 'PCS'
  returning item_id $$;
create function t.ic(p_item uuid) returns erp.item_costs language sql security definer as $$ select c from erp.item_costs c where tenant_id = t.a() and item_id = p_item $$;
create function t.num(n numeric) returns text language sql immutable as $$
  select case when n is null then '' when n::text like '%.%' then rtrim(rtrim(n::text, '0'), '.') else n::text end $$;
create function t.layers(p_item uuid) returns text language sql security definer as $$
  select coalesce(string_agg(t.num(qty_left) || '@' || t.num(unit_cost), ';' order by layer_date, seq, layer_id), '')
    from erp.stock_layers where tenant_id = t.a() and item_id = p_item and qty_left > 0 and void_run is null $$;
create function t.bal(p_wh uuid, p_item uuid) returns numeric language sql security definer as $$
  select coalesce((select qty from erp.stock_balances where tenant_id = t.a() and warehouse_id = p_wh and item_id = p_item), 0) $$;
create function t.today() returns date language sql security definer as $$ select erp.today(t.a()) $$;
create function t.integrity(p_item uuid) returns jsonb language sql security definer as $$ select erp.stock_integrity(t.a(), p_item) $$;
create function t.move(p_line uuid) returns erp.stock_moves language sql security definer as $$
  select m from erp.stock_moves m where tenant_id = t.a() and line_id = p_line and kind = 'normal' order by move_id limit 1 $$;
create function t.line(p_doc uuid) returns uuid language sql security definer as $$ select line_id from erp.document_lines where tenant_id = t.a() and document_id = p_doc and line_no = 1 $$;
create function t.snap(p_item uuid) returns jsonb language sql security definer as $$
  select jsonb_build_object('cost', (select to_jsonb(c) - 'last_move_id' - 'updated_at' from erp.item_costs c where tenant_id = t.a() and item_id = p_item),
                            'layers', t.layers(p_item),
                            'balances', (select jsonb_object_agg(warehouse_id, qty) from erp.stock_balances where tenant_id = t.a() and item_id = p_item and qty <> 0)) $$;
-- one document of one line, posted (ack): returns the document id
create function t.doc(p_type text, p_item uuid, p_qty numeric, p_cost numeric default null, p_src uuid default null, p_wh text default 'W1',
                      p_date date default null) returns uuid language plpgsql as $$
declare d jsonb; r jsonb;
begin
  d := erp_api.doc_save_draft(p_type, jsonb_build_object('branch_id', (select branch_id from erp.warehouses where warehouse_id = t.wh(p_wh)), 'warehouse_id', t.wh(p_wh),
         'lines', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('item_id', p_item, 'qty', p_qty, 'unit_price', p_cost, 'source_line_id', p_src))))
         || case when p_date is not null then jsonb_build_object('doc_date', p_date) else '{}'::jsonb end, gen_random_uuid());
  r := erp_api.doc_set_state((d ->> 'document_id')::uuid, 'posted', '{"ack_warnings": true}', gen_random_uuid());
  if not (r ->> 'posted')::boolean then raise exception 'not posted: %', r; end if;
  return (d ->> 'document_id')::uuid;
end $$;
create function t.cancel(p_doc uuid) returns jsonb language sql as $$ select erp_api.doc_set_state(p_doc, 'cancelled', '{"reason": "test"}', gen_random_uuid()) $$;
grant execute on all functions in schema t to authenticated;

-- ---------- golden cases ----------
create table t.graw (step int, op text, qty numeric, unit_cost numeric, src_step int, exp_qty numeric, exp_value_avg numeric, exp_value_fifo numeric,
                     exp_move_avg numeric, exp_move_fifo numeric, exp_layers text);
create table t.golden (cs text, step int, op text, qty numeric, unit_cost numeric, src_step int, exp_qty numeric, exp_value_avg numeric, exp_value_fifo numeric,
                       exp_move_avg numeric, exp_move_fifo numeric, exp_layers text);
\copy t.graw from 'golden/G1.csv' with (format csv, header)
insert into t.golden select 'G1', * from t.graw; truncate t.graw;
\copy t.graw from 'golden/G2.csv' with (format csv, header)
insert into t.golden select 'G2', * from t.graw; truncate t.graw;
\copy t.graw from 'golden/G3.csv' with (format csv, header)
insert into t.golden select 'G3', * from t.graw; truncate t.graw;
\copy t.graw from 'golden/G4.csv' with (format csv, header)
insert into t.golden select 'G4', * from t.graw; truncate t.graw;
\copy t.graw from 'golden/G5.csv' with (format csv, header)
insert into t.golden select 'G5', * from t.graw; truncate t.graw;
update t.golden set exp_layers = coalesce(exp_layers, '');
create table t.gres (cs text, step int, doc uuid, line uuid, got text, want text);
grant select, insert on t.golden, t.gres to authenticated;
create table t.s (k text primary key, j jsonb);
create table t.dd (k text primary key, id uuid);
create table t.w (j jsonb);
grant select, insert, update, delete on t.s, t.dd, t.w to authenticated;
select t.ok((select count(*) from t.golden) = 28 and (select count(distinct cs) from t.golden) = 5, 'golden: 5 cases, 28 steps loaded from tests/golden/*.csv');

set local role authenticated;
select t.as(1);
do $$ declare g record; it uuid; d uuid; src uuid; c erp.item_costs; mv erp.stock_moves; cur text := ''; begin
  for g in select * from t.golden order by cs, step loop
    if g.cs <> cur then cur := g.cs; it := t.mkitem(g.cs); end if;
    src := (select line from t.gres where cs = g.cs and step = g.src_step);
    d := case g.op when 'in' then t.doc('TIN', it, g.qty, g.unit_cost) when 'out' then t.doc('TOUT', it, g.qty)
                   when 'ret_in' then t.doc('TRIN', it, g.qty, null, src) when 'ret_out' then t.doc('TROUT', it, g.qty, null, src) end;
    c := t.ic(it); mv := t.move(t.line(d));
    insert into t.gres values (g.cs, g.step, d, t.line(d),
      concat_ws('|', t.num(c.qty), c.value_avg, c.value_fifo, mv.value_avg, mv.value_fifo, t.layers(it)),
      concat_ws('|', t.num(g.exp_qty), g.exp_value_avg, g.exp_value_fifo, g.exp_move_avg, g.exp_move_fifo, g.exp_layers));
  end loop;
end $$;
select t.ok(not exists (select 1 from t.gres where got <> want),
            'golden G1-G5: qty | value avg | value FIFO | move avg | move FIFO | layers after every step: ' ||
            coalesce((select string_agg(cs || '#' || step || ' got ' || got || ' want ' || want, '; ' order by cs, step) from t.gres where got <> want), 'all 28 steps equal'));
select t.ok((select count(*) from t.gres) = 28, 'golden: every step posted');
select t.ok(not exists (select 1 from (select distinct cs from t.golden) g where jsonb_array_length(t.integrity((select item_id from erp.items where code = g.cs))) > 0),
            'golden: integrity check clean for every case (balances, cost state and layers = ledger)');
select t.ok((select string_agg(official, ',') from (select distinct m.official from erp.stock_moves m join erp.items i using (tenant_id, item_id) where i.code like 'G_') x) = 'avg',
            'every move carries the official method of its date: avg (owner decision)');
select t.ok((select l.unit_cost || '/' || l.cost_value from erp.document_lines l where l.line_id = (select line from t.gres where cs = 'G2' and step = 4))
            = '11.185833/134.23', 'posted line cost = official (average) value 134.23, unit cost = value / qty');
select t.ok((select d.total_cost from erp.documents d where d.document_id = (select doc from t.gres where cs = 'G2' and step = 4)) = 134.23, 'document total_cost = sum of its lines');

-- ---------- cancel symmetry ----------
select t.mkitem('CS1');
select t.doc('TIN', (select item_id from erp.items where code = 'CS1'), 10, 4);
select t.doc('TIN', (select item_id from erp.items where code = 'CS1'), 5, 7);
select t.doc('TOUT', (select item_id from erp.items where code = 'CS1'), 3);
insert into t.s values ('before', t.snap((select item_id from erp.items where code = 'CS1')));
insert into t.dd values ('out', t.doc('TOUT', (select item_id from erp.items where code = 'CS1'), 8));
select t.ok(t.snap((select item_id from erp.items where code = 'CS1')) <> (select j from t.s where k = 'before'), 'cancel symmetry: the outbound changed the state');
select t.ok((t.cancel((select id from t.dd where k = 'out'))) #>> '{document,state}' = 'cancelled', 'outbound cancelled');
select t.ok(t.snap((select item_id from erp.items where code = 'CS1')) = (select j from t.s where k = 'before'),
            'cancel symmetry (outbound): balances, average state, FIFO layers exactly as before');
insert into t.dd values ('in', t.doc('TIN', (select item_id from erp.items where code = 'CS1'), 6, 9.99));
select t.cancel((select id from t.dd where k = 'in'));
select t.ok(t.snap((select item_id from erp.items where code = 'CS1')) = (select j from t.s where k = 'before'),
            'cancel symmetry (inbound): exactly as before');
select t.ok((select count(*) || '/' || sum(qty_base) || '/' || sum(value_avg) || '/' || sum(value_fifo) from erp.stock_moves where document_id = (select id from t.dd where k = 'out'))
            = '2/0.0000/0.00/0.00', 'a cancelled document: normal + reversal move, quantities and values net to zero');
select t.ok(jsonb_array_length(t.integrity((select item_id from erp.items where code = 'CS1'))) = 0, 'integrity clean after the cancels');

-- ---------- cancel with later moves: replay as if the document never existed ----------
select t.mkitem('CL1');
select t.doc('TIN', (select item_id from erp.items where code = 'CL1'), 10, 5);
insert into t.dd values ('cl_out', t.doc('TOUT', (select item_id from erp.items where code = 'CL1'), 4));
insert into t.dd values ('cl_in', t.doc('TIN', (select item_id from erp.items where code = 'CL1'), 10, 7));
insert into t.dd values ('cl_out2', t.doc('TOUT', (select item_id from erp.items where code = 'CL1'), 2));
select t.ok((t.move(t.line((select id from t.dd where k = 'cl_out2')))).value_avg = -12.50, 'before the cancel: the second issue at avg (30 + 70) / 16 = 6.25 -> 12.50');
select t.cancel((select id from t.dd where k = 'cl_out'));
select t.ok(t.num((t.ic((select item_id from erp.items where code = 'CL1'))).qty) = '18' and (t.ic((select item_id from erp.items where code = 'CL1'))).value_avg = 108.00
            and (t.ic((select item_id from erp.items where code = 'CL1'))).value_fifo = 110.00 and t.layers((select item_id from erp.items where code = 'CL1')) = '8@5;10@7',
            'cancel of the first issue: in 10@5, in 10@7, out 2 replayed -> qty 18, avg value 108.00, FIFO 110.00, layers 8@5;10@7');
select t.ok((t.move(t.line((select id from t.dd where k = 'cl_out2')))).value_avg = -12.00 and (t.move(t.line((select id from t.dd where k = 'cl_out2')))).value_fifo = -10.00
            and (select cost_value from erp.document_lines where line_id = t.line((select id from t.dd where k = 'cl_out2'))) = 12.00,
            'the later issue is costed again (avg 6.00 -> 12.00, FIFO 2@5 = 10.00) and its document line follows');
select t.ok(jsonb_array_length(t.integrity((select item_id from erp.items where code = 'CL1'))) = 0, 'integrity clean after a replay');

-- ---------- backdated post ----------
select t.mkitem('BD1');
select t.doc('TIN', (select item_id from erp.items where code = 'BD1'), 10, 5, null, 'W1', t.today() - 2);
insert into t.dd values ('bd_out', t.doc('TOUT', (select item_id from erp.items where code = 'BD1'), 4));
select t.ok((t.move(t.line((select id from t.dd where k = 'bd_out')))).value_avg = -20.00, 'issue of 4 at 5.00 = 20.00');
select t.doc('TIN', (select item_id from erp.items where code = 'BD1'), 10, 7, null, 'W1', t.today() - 1);
select t.ok((t.move(t.line((select id from t.dd where k = 'bd_out')))).value_avg = -24.00 and (t.move(t.line((select id from t.dd where k = 'bd_out')))).value_fifo = -20.00
            and (select total_cost from erp.documents where document_id = (select id from t.dd where k = 'bd_out')) = 24.00,
            'a receipt dated before the issue: the issue is costed again at avg 6.00 (24.00; FIFO stays 20.00), its document follows');
select t.ok(jsonb_array_length(t.integrity((select item_id from erp.items where code = 'BD1'))) = 0, 'integrity clean after the backdated post');

-- ---------- negative stock: warning, ack, provisional cost, cover with a correction ----------
select t.mkitem('NG1');
insert into t.w select erp_api.doc_save_draft('TOUT', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'warehouse_id', t.wh('W1'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', (select item_id from erp.items where code = 'NG1'), 'qty', 5))), gen_random_uuid());
select t.keep(erp_api.doc_set_state(((select j from t.w) ->> 'document_id')::uuid, 'posted', '{}', gen_random_uuid()));
select t.ok(not (t.j() ->> 'posted')::boolean and t.j() #>> '{warnings,0,code}' = 'W_STOCK_NEGATIVE' and t.j() #>> '{warnings,0,qty_after}' = '-5.0000'
            and t.j() #>> '{document,state}' = 'draft' and t.count($$select 1 from erp.stock_moves m join erp.items i using (tenant_id, item_id) where i.code = 'NG1'$$) = 0,
            'stock would go to -5: warning W_STOCK_NEGATIVE, nothing posted, no number');
select t.keep(erp_api.doc_set_state(((select j from t.w) ->> 'document_id')::uuid, 'posted', '{"ack_warnings": true}', gen_random_uuid()));
select t.ok((t.j() ->> 'posted')::boolean and t.j() #>> '{warnings,0,qty_after}' = '-5.0000' and t.bal(t.wh('W1'), (select item_id from erp.items where code = 'NG1')) = -5
            and (t.move(t.line(((select j from t.w) ->> 'document_id')::uuid))).cost_provisional, 'with ack: posted, balance -5, cost provisional');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'doc.warnings_acknowledged'$$) = 1, 'the acknowledgement is audited');
select t.doc('TIN', (select item_id from erp.items where code = 'NG1'), 8, 4);
select t.ok(t.num((t.ic((select item_id from erp.items where code = 'NG1'))).qty) = '3' and (t.ic((select item_id from erp.items where code = 'NG1'))).value_avg = 12.00
            and (t.ic((select item_id from erp.items where code = 'NG1'))).value_fifo = 12.00 and t.layers((select item_id from erp.items where code = 'NG1')) = '3@4'
            and (select value_avg || '/' || value_fifo || '/' || t.num(cover_qty) from erp.stock_moves m join erp.items i using (tenant_id, item_id) where i.code = 'NG1' and m.kind = 'value_only')
                = '-20.00/-20.00/5', 'the receipt covers the deficit first: one value-only correction (-20.00: 5 x 4.00 over the provisional 0), layer 3@4');
select t.ok(jsonb_array_length(t.integrity((select item_id from erp.items where code = 'NG1'))) = 0, 'integrity clean after negative stock and cover');
reset role;
update erp.tenant_settings set negative_stock = 'block' where tenant_id = t.a();
set local role authenticated;
select t.as(1);
select t.fails(format($$select t.doc('TOUT', '%s', 100)$$, (select item_id from erp.items where code = 'NG1')), 'ERP_STOCK_NEGATIVE', 'setting block: ERP_STOCK_NEGATIVE, even with ack');
reset role;
update erp.tenant_settings set negative_stock = 'warn' where tenant_id = t.a();

-- ---------- ledger and master-data guards ----------
select t.fails($$update erp.stock_moves set qty_base = 99 where move_id = (select min(move_id) from erp.stock_moves)$$, 'ERP_APPEND_ONLY', 'a move quantity never changes');
select t.fails($$update erp.stock_moves set value_avg = 1 where move_id = (select min(move_id) from erp.stock_moves)$$, 'ERP_APPEND_ONLY', 'cost columns change only inside the costing code');
select t.fails($$delete from erp.stock_moves where move_id = (select min(move_id) from erp.stock_moves)$$, 'ERP_APPEND_ONLY', 'a move is never deleted');
select t.fails($$update erp.stock_move_layers set qty = 0$$, 'ERP_APPEND_ONLY', 'stock_move_layers is append-only');
select t.fails($$delete from erp.stock_move_layers$$, 'ERP_APPEND_ONLY', 'stock_move_layers rows are never deleted');
select t.fails($$update erp.items set base_unit_id = (select unit_id from erp.units u where u.tenant_id = items.tenant_id and u.code = 'BOX') where code = 'G1'$$, 'ERP_VALIDATION',
               'an item with moves keeps its base unit');
select t.fails(format($$update erp.warehouses set active = false where warehouse_id = '%s'$$, t.wh('W1')), 'ERP_VALIDATION', 'a warehouse holding stock cannot be deactivated');
select t.ok(t.affected(format($$update erp.warehouses set active = false where warehouse_id = '%s'$$, t.wh('W1B'))) = 1, 'an empty warehouse can');

-- ---------- RLS of the stock tables ----------
set local role authenticated;
select t.as(3);
select t.ok((select count(*) from erp.stock_balances) > 0 and (select count(*) from erp.stock_balances where warehouse_id = t.wh('W2')) = 0
            and (select count(*) from erp.item_costs) = 0 and (select count(*) from erp.stock_layers) = 0,
            'warehouse (A1): balances and moves of its warehouses; no cost state, no layers (no cost.read)');
select t.as(6);
select t.ok((select count(*) from erp.stock_balances) = 0 and (select count(*) from erp.item_costs) > 0, 'readonly (A2): no balance of A1; cost state readable (cost.read)');
select t.as(11);
select t.ok((select count(*) from erp.stock_moves) = 0 and (select count(*) from erp.item_costs) = 0, 'tenant B: nothing of A');
reset role;


-- =================== T13: backdating with cost_revisions, recost queue + job, lock date, integrity job ===================
create table t.g8 (step int, op text, day int, qty numeric, unit_cost numeric, exp_move_avg numeric, exp_move_fifo numeric, exp_revised int);
\copy t.g8 from 'golden/G8.csv' with (format csv, header)
create table t.g8doc (step int, doc uuid);
create table t.qd (k text primary key, id uuid);
grant select, insert on t.g8, t.g8doc, t.qd to authenticated;
create function t.revs(p_item uuid) returns bigint language sql security definer as $$ select count(*) from erp.cost_revisions where item_id = p_item $$;
create function t.queue() returns bigint language sql security definer as $$ select count(*) from erp.recost_queue where tenant_id = t.a() $$;
grant execute on all functions in schema t to authenticated;
set local role authenticated;
select t.as(1);
select t.mkitem('G8');
do $$ declare g record; begin
  for g in select * from t.g8 order by step loop
    insert into t.g8doc values (g.step, case g.op when 'in' then t.doc('TIN', (select item_id from erp.items where code = 'G8'), g.qty, g.unit_cost, null, 'W1', t.today() + g.day)
                                                  else t.doc('TOUT', (select item_id from erp.items where code = 'G8'), g.qty, null, null, 'W1', t.today() + g.day) end);
  end loop;
end $$;
select t.ok(not exists (select 1 from t.g8 g join t.g8doc d using (step)
                         where (t.move(t.line(d.doc))).value_avg <> g.exp_move_avg or (t.move(t.line(d.doc))).value_fifo <> g.exp_move_fifo
                            or (select count(*) from erp.cost_revisions r where r.move_id = (t.move(t.line(d.doc))).move_id) <> g.exp_revised),
            'golden G8: after the backdated receipt every move has its expected final values and exactly the expected cost_revisions rows');
select t.ok(t.num((t.ic((select item_id from erp.items where code = 'G8'))).qty) = '13' and (t.ic((select item_id from erp.items where code = 'G8'))).value_avg = 84.50
            and (t.ic((select item_id from erp.items where code = 'G8'))).value_fifo = 95.00 and t.layers((select item_id from erp.items where code = 'G8')) = '3@5;10@8',
            'golden G8 final state: qty 13, average 84.50, FIFO 95.00, layers 3@5;10@8');
select t.ok((select string_agg(distinct reason, ',') from erp.cost_revisions where item_id = (select item_id from erp.items where code = 'G8')) = 'backdate'
            and (select old_value_avg || '>' || new_value_avg from erp.cost_revisions r join t.g8doc d on r.move_id = (t.move(t.line(d.doc))).move_id where d.step = 2) = '-20.00>-26.00',
            'cost_revisions: reason backdate, old -20.00 -> new -26.00 for the first issue');
select t.ok((select total_cost from erp.documents where document_id = (select doc from t.g8doc where step = 3)) = 19.50, 'the later document''s cost follows (19.50)');
select t.ok(jsonb_array_length(t.integrity((select item_id from erp.items where code = 'G8'))) = 0, 'integrity clean after G8');
-- G3 replayed from its first date: deterministic, nothing changes, no revision
reset role;
create table t.g3before as select move_id, value_avg, value_fifo from erp.stock_moves m join erp.items i using (tenant_id, item_id) where i.code = 'G3';
select t.ok(erp.cost_replay(t.a(), (select item_id from erp.items where code = 'G3'), '00000000-0000-0000-0000-000000000000', t.today()) = 6, 'G3 replayed from its date: 6 moves costed again');
select t.ok(not exists (select 1 from t.g3before b join erp.stock_moves m using (move_id) where (m.value_avg, m.value_fifo) <> (b.value_avg, b.value_fifo))
            and t.revs((select item_id from erp.items where code = 'G3')) = 0 and jsonb_array_length(t.integrity((select item_id from erp.items where code = 'G3'))) = 0,
            'G3 replay: identical values (the rounding residue lands on the same move), no cost_revisions row');
-- T15: a replay carries the cost state and the partly consumed FIFO layer in transaction settings and writes them
-- once; replaying G2 / G4 / G5 (layers consumed across several moves, a deficit covered) from their first date
-- must give the same moves, running state, layers and cost rows, and leave no replay setting behind
create table t.rp_before as
  select i.code, m.move_id, m.value_avg, m.value_fifo, m.run_qty, m.run_value_avg, m.run_value_fifo, m.run_avg_cost, m.run_deficit_value, m.run_fifo_last
    from erp.stock_moves m join erp.items i using (tenant_id, item_id) where i.code in ('G2', 'G4', 'G5');
create table t.rp_state as
  select i.code, t.layers(i.item_id) layers, c.qty, c.value_avg, c.value_fifo, c.avg_cost, c.deficit_value, c.fifo_last_cost, c.last_move_id
    from erp.items i join erp.item_costs c using (tenant_id, item_id) where i.code in ('G2', 'G4', 'G5');
select t.ok((select sum(erp.cost_replay(t.a(), i.item_id, '00000000-0000-0000-0000-000000000000', (select min(move_date) from erp.stock_moves m where m.item_id = i.item_id)))
               from erp.items i where i.tenant_id = t.a() and i.code in ('G2', 'G4', 'G5')) > 0, 'G2 / G4 / G5 replayed from their first date');
select t.ok(not exists (select 1 from t.rp_before b join erp.stock_moves m using (move_id)
                         where (m.value_avg, m.value_fifo, m.run_qty, m.run_value_avg, m.run_value_fifo, m.run_avg_cost, m.run_deficit_value, m.run_fifo_last)
                               is distinct from (b.value_avg, b.value_fifo, b.run_qty, b.run_value_avg, b.run_value_fifo, b.run_avg_cost, b.run_deficit_value, b.run_fifo_last))
            and (select count(*) from t.rp_before) = (select count(*) from erp.stock_moves m join erp.items i using (tenant_id, item_id) where i.code in ('G2', 'G4', 'G5')),
            'replay of G2 / G4 / G5: every move and its running state identical, no move added');
select t.ok(not exists (select 1 from t.rp_state s join erp.items i on i.tenant_id = t.a() and i.code = s.code join erp.item_costs c using (tenant_id, item_id)
                         where (t.layers(i.item_id), c.qty, c.value_avg, c.value_fifo, c.avg_cost, c.deficit_value, c.fifo_last_cost, c.last_move_id)
                               is distinct from (s.layers, s.qty, s.value_avg, s.value_fifo, s.avg_cost, s.deficit_value, s.fifo_last_cost, s.last_move_id)),
            'replay of G2 / G4 / G5: layers and item cost rows written back identical');
select t.ok(coalesce(current_setting('erp.replay_key', true), '') = '' and coalesce(current_setting('erp.replay_head', true), '') = ''
            and coalesce(current_setting('erp.replay_state', true), '') = '', 'no replay setting left after the replays');

-- queue: more later moves than the inline limit -> the job / the owner recosts
set local role authenticated;
select t.as(1);
select t.mkitem('Q1');
select t.doc('TIN', (select item_id from erp.items where code = 'Q1'), 10, 5, null, 'W1', t.today() - 3);
insert into t.qd values ('out', t.doc('TOUT', (select item_id from erp.items where code = 'Q1'), 4, null, null, 'W1', t.today() - 1));
set local erp.recost_inline_limit = '0';
select t.doc('TIN', (select item_id from erp.items where code = 'Q1'), 10, 8, null, 'W1', t.today() - 2);
reset erp.recost_inline_limit;
select t.ok(t.queue() = 1 and (erp_api.recost_status()) ->> 'pending' = '1' and (erp_api.recost_status()) #>> '{items,0,item_code}' = 'Q1'
            and (t.move(t.line((select id from t.qd where k = 'out')))).value_avg = -20.00, 'inline limit exceeded: posted, queued (recost pending), the issue still at 20.00');
reset role;
select t.fails(format($$update erp.tenant_settings set lock_date = '%s' where tenant_id = '%s'$$, t.today() - 2, t.a()), 'ERP_RECOST_PENDING',
               'the lock date cannot move over a queued recost');
set local role authenticated;
select t.as(3);
select t.fails($$select erp_api.recost_run(10, gen_random_uuid())$$, 'ERP_FORBIDDEN', 'the warehouse member cannot run the recost');
select t.ok((erp_api.recost_status()) ->> 'pending' = '1', '...but sees that it is pending (stock.read)');
select t.as(1);
select t.keep(erp_api.recost_run(10, gen_random_uuid()));
select t.ok(t.j() ->> 'items' = '1' and t.j() ->> 'pending' = '0' and t.queue() = 0 and (t.move(t.line((select id from t.qd where k = 'out')))).value_avg = -26.00
            and (select reason from erp.cost_revisions where move_id = (t.move(t.line((select id from t.qd where k = 'out')))).move_id) = 'queue',
            'owner runs the recost: the issue is costed at avg 6.50 (26.00), queue empty, revision reason queue');
reset role;
select t.ok(t.affected(format($$update erp.tenant_settings set lock_date = '%s' where tenant_id = '%s'$$, t.today() - 2, t.a())) = 1, 'with the queue empty the lock date can move');
select t.fails(format($$select erp.cost_replay('%s', '%s', '00000000-0000-0000-0000-000000000000', '%s')$$, t.a(), (select item_id from erp.items where code = 'Q1'), t.today() - 2),
               'ERP_LOCKED_PERIOD', 'a replay never starts on or before the lock date');
set local role authenticated;
select t.as(1);
select t.fails(format($$select t.doc('TIN', '%s', 1, 1, null, 'W1', '%s')$$, (select item_id from erp.items where code = 'Q1'), t.today() - 2), 'ERP_LOCKED_PERIOD',
               'a backdated post on the lock date is refused');
reset role;
update erp.tenant_settings set lock_date = null where tenant_id = t.a();
-- the job processes queued items of every tenant
set local role authenticated;
select t.as(1);
set local erp.recost_inline_limit = '0';
select t.doc('TIN', (select item_id from erp.items where code = 'Q1'), 1, 1, null, 'W1', t.today() - 2);
reset erp.recost_inline_limit;
reset role;
select t.ok(t.queue() = 1, 'queued again');
select t.keep(erp.recost_job(10));
select t.ok(t.j() ->> 'items' = '1' and t.queue() = 0 and jsonb_array_length(t.integrity((select item_id from erp.items where code = 'Q1'))) = 0,
            'erp.recost_job (5-minute job): queue processed, integrity clean');
select t.fails($$update erp.cost_revisions set new_value_avg = 0$$, 'ERP_APPEND_ONLY', 'cost_revisions is append-only');
-- integrity job: a broken balance raises ONE owner alert; it resolves when the books agree again
update erp.stock_balances set qty = qty + 1 where tenant_id = t.a() and item_id = (select item_id from erp.items where code = 'Q1');
select t.keep(erp.integrity_job());
select t.ok((t.j() ->> 'with_problems')::int >= 1
            and (select count(*) from erp.alerts where tenant_id = t.a() and kind = 'integrity' and resolved_at is null and severity = 'critical') = 1,
            'integrity job: balance <> ledger -> one critical owner alert');
update erp.stock_balances set qty = qty - 1 where tenant_id = t.a() and item_id = (select item_id from erp.items where code = 'Q1');
select erp.integrity_job();
select t.ok((select count(*) from erp.alerts where tenant_id = t.a() and kind = 'integrity' and resolved_at is null) = 0, '...resolved by the next clean run');
select t.ok(jsonb_array_length(erp.stock_integrity(t.a())) = 0, 'integrity of the whole test tenant clean at the end');

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
