-- =====================================================================
-- iSmile ERP  -  F2 review suite (independent reviewer, 2026-11-19): one block per confirmed finding of
-- docs/erp/REVIEW_F2.md; every block FAILS on the code before the F2 fixes (stated per block), plus the independent
-- golden set R1-R4 (tests/golden/R*.csv, re-computed by tests/costing_model.py) and a rollback-atomicity check.
-- Real E2 types (GRN / CONS / OPN) and TEST types TIN / TOUT (cost rule line / issue).
-- One transaction, ROLLED BACK. Last line: ALL TESTS PASSED + number of checks.
-- =====================================================================
begin;
\ir _helpers.sql

create table t.ids (a uuid);
insert into t.ids select t.tenant('fa');
create function t.a() returns uuid language sql security definer as $$ select a from t.ids $$;
select t.init(t.a());
select t.branch(t.a(), 'A1', 0), t.branch(t.a(), 'A2', 1);
select t.member(t.a(), 1, 'owner'), t.member(t.a(), 3, 'warehouse', array[t.br(t.a(), 'A1')]);
insert into erp.warehouses (tenant_id, branch_id, code, name) values (t.a(), t.br(t.a(), 'A1'), 'W1', 'W one'), (t.a(), t.br(t.a(), 'A2'), 'W2', 'W two');
insert into erp.counterparties (tenant_id, name, kind) values (t.a(), 'Supplier', 'supplier');
insert into erp.doc_types (doc_type, name, area, cap_prefix, sort, enabled, stock_sign, cost_rule, needs_warehouse, price_kind) values
  ('TIN', 'Test in', 'warehouse', 'tst', 990, true, 1, 'line', true, 'cost'),
  ('TOUT', 'Test out', 'warehouse', 'tst', 991, true, -1, 'issue', true, 'none'),
  ('TRIN', 'Test customer return', 'warehouse', 'tst', 992, true, 1, 'source_out', true, 'none'),
  ('TROUT', 'Test supplier return', 'warehouse', 'tst', 993, true, -1, 'source_in', true, 'none')
on conflict (doc_type) do nothing;
insert into erp.doc_transitions (doc_type, from_state, to_state, cap, action, label)
select dt, f, t2, c, a, 'x' from unnest(array['TIN', 'TOUT', 'TRIN', 'TROUT']) dt,
  (values ('draft', 'posted', 'create', 'post'), ('posted', 'cancelled', 'approve', 'cancel')) v(f, t2, c, a)
on conflict do nothing;
insert into erp.capabilities (capability, area) values ('doc.tst.read', 'test'), ('doc.tst.create', 'test'), ('doc.tst.approve', 'test') on conflict do nothing;
insert into erp.role_caps (tenant_id, role, capability) values (t.a(), 'owner', 'doc.tst.read'), (t.a(), 'owner', 'doc.tst.create'), (t.a(), 'owner', 'doc.tst.approve');
insert into erp.series (tenant_id, branch_id, doc_type, code) select t.a(), b.branch_id, dt, dt || '-' || b.code from erp.branches b, unnest(array['TIN', 'TOUT', 'TRIN', 'TROUT']) dt
 where b.tenant_id = t.a();
create function t.wh(p_code text) returns uuid language sql security definer as $$ select warehouse_id from erp.warehouses where tenant_id = t.a() and code = p_code $$;
create function t.mkitem(p_code text) returns uuid language sql security definer as $$
  insert into erp.items (tenant_id, code, name, base_unit_id) select t.a(), p_code, 'Item ' || p_code, unit_id from erp.units where tenant_id = t.a() and code = 'PCS'
  returning item_id $$;
create function t.it(p_code text) returns uuid language sql security definer as $$ select item_id from erp.items where tenant_id = t.a() and code = p_code $$;
create function t.today() returns date language sql security definer as $$ select erp.today(t.a()) $$;
create function t.ic(p_code text) returns erp.item_costs language sql security definer as $$ select c from erp.item_costs c where tenant_id = t.a() and item_id = t.it(p_code) $$;
create function t.mv(p_doc uuid) returns erp.stock_moves language sql security definer as $$
  select m from erp.stock_moves m where tenant_id = t.a() and document_id = p_doc and kind = 'normal' order by move_id limit 1 $$;
create function t.ledger_qty(p_code text) returns numeric language sql security definer as $$
  select coalesce(sum(qty_base), 0) from erp.stock_moves where tenant_id = t.a() and item_id = t.it(p_code) $$;
create function t.integrity(p_code text) returns jsonb language sql security definer as $$ select erp.stock_integrity(t.a(), t.it(p_code)) $$;
create function t.queued(p_code text) returns text language sql security definer as $$
  select coalesce((select reason || '@' || (from_date - t.today()) from erp.recost_queue where tenant_id = t.a() and item_id = t.it(p_code)), 'none') $$;
create function t.revs(p_doc uuid) returns bigint language sql security definer as $$ select count(*) from erp.cost_revisions where document_id = p_doc $$;
-- one document of one line; p_type GRN / CONS (real) or TIN / TOUT / TRIN / TROUT (test); posted with ack
create function t.doc(p_type text, p_item text, p_qty numeric, p_cost numeric default null, p_day int default 0, p_wh text default 'W1', p_src uuid default null)
returns uuid language plpgsql as $$
declare d jsonb; r jsonb;
begin
  d := erp_api.doc_save_draft(p_type, jsonb_build_object('branch_id', (select branch_id from erp.warehouses where warehouse_id = t.wh(p_wh)), 'warehouse_id', t.wh(p_wh),
         'doc_date', t.today() + p_day,
         'counterparty_id', case when p_type = 'GRN' then (select counterparty_id from erp.counterparties where tenant_id = t.a() and name = 'Supplier') end,
         'lines', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('item_id', t.it(p_item), 'qty', p_qty, 'unit_price', p_cost, 'source_line_id', p_src)))), gen_random_uuid());
  r := erp_api.doc_set_state((d ->> 'document_id')::uuid, 'posted', '{"ack_warnings": true}', gen_random_uuid());
  if not (r ->> 'posted')::boolean then raise exception 'not posted: %', r; end if;
  return (d ->> 'document_id')::uuid;
end $$;
create function t.cancel(p_doc uuid) returns jsonb language sql as $$ select erp_api.doc_set_state(p_doc, 'cancelled', '{"reason": "test"}', gen_random_uuid()) $$;
create function t.line1(p_doc uuid) returns uuid language sql security definer as $$ select line_id from erp.document_lines where document_id = p_doc and line_no = 1 $$;
create table t.d (k text primary key, id uuid);
create function t.put(p_k text, p_id uuid) returns void language sql security definer as $$ insert into t.d values (p_k, p_id) on conflict (k) do update set id = excluded.id $$;
create function t.id(p_k text) returns uuid language sql security definer as $$ select id from t.d where k = p_k $$;
grant select, insert, update on t.d to authenticated;
grant execute on all functions in schema t to authenticated;

set local role authenticated;
select t.as(1);
select erp_api.series_create_defaults(t.br(t.a(), 'A1'), gen_random_uuid());
select erp_api.series_create_defaults(t.br(t.a(), 'A2'), gen_random_uuid());

-- =================== F2-01 (O2): provisional cost of an item without cost history = the purchase price WHEN POSTED ===================
-- Before F2: average used 0, FIFO used items.last_purchase_price read at REPLAY time, so a later replay re-costed the
-- issue at a later price (a cost_revisions row for a document nothing had changed).
select t.mkitem('O2');
select t.put('o2_grn1', t.doc('GRN', 'O2', 10, 5, -1));                 -- last purchase price 5
select t.put('o2_cons', t.doc('CONS', 'O2', 3, null, -5));             -- before any receipt: no cost history
select t.ok((t.mv(t.id('o2_cons'))).value_avg = -15.00 and (t.mv(t.id('o2_cons'))).value_fifo = -15.00 and (t.mv(t.id('o2_cons'))).cost_provisional
            and (t.mv(t.id('o2_cons'))).fallback_cost = 5,
            'F2-01: an issue before any receipt is costed at the purchase price known when posted (3 x 5.00), average AND FIFO, provisional');
select t.ok((select value_avg || '/' || value_fifo from erp.stock_moves where tenant_id = t.a() and covers_move_id = (t.mv(t.id('o2_grn1'))).move_id and kind = 'value_only')
            is null, 'F2-01: the receipt covered the deficit at the same unit cost: no correction needed');
select t.doc('GRN', 'O2', 10, 8, 0);                                    -- last purchase price is now 8
select t.put('o2_cons2', t.doc('CONS', 'O2', 2, null, -6));            -- backdated again: the whole item is replayed from -6
select t.ok((t.mv(t.id('o2_cons'))).value_avg = -15.00 and (t.mv(t.id('o2_cons'))).value_fifo = -15.00 and t.revs(t.id('o2_cons')) = 0,
            'F2-01: the replay keeps the first issue at 15.00 / 15.00 (its own snapshot), no cost_revisions row (before F2: FIFO 24.00 and a revision)');
select t.ok((t.mv(t.id('o2_cons2'))).value_avg = -16.00 and (t.mv(t.id('o2_cons2'))).value_fifo = -16.00,
            'F2-01: the new backdated issue takes the price known when IT was posted (2 x 8.00)');
select t.ok(jsonb_array_length(t.integrity('O2')) = 0, 'F2-01: integrity clean');
reset role;
create table t.o2before as select move_id, value_avg, value_fifo from erp.stock_moves where tenant_id = t.a() and item_id = t.it('O2');
select t.ok(erp.cost_replay(t.a(), t.it('O2'), '00000000-0000-0000-0000-000000000000', t.today() - 30) > 0
            and not exists (select 1 from t.o2before b join erp.stock_moves m using (move_id) where (m.value_avg, m.value_fifo) <> (b.value_avg, b.value_fifo)),
            'F2-01: a replay from the first date changes nothing (deterministic: the price snapshot is a costing input)');
select t.fails($$update erp.stock_moves set fallback_cost = 1 where move_id = (select min(move_id) from erp.stock_moves)$$, 'ERP_APPEND_ONLY',
               'F2-01: fallback_cost is an input of the ledger: never rewritten');

-- =================== F2-04: a queued item is never replayed from a stale running state ===================
-- Before F2: a cancel (or a backdated post within the limit) after a queued backdated post replayed from a move whose
-- running state did not contain the queued move: item_costs.qty <> ledger until the job ran (critical integrity alert).
set local role authenticated;
select t.as(1);
select t.mkitem('QS');
select t.doc('TIN', 'QS', 10, 5, -5);
select t.put('qs_out', t.doc('TOUT', 'QS', 2, null, -1));
set local erp.recost_inline_limit = '0';
select t.doc('TIN', 'QS', 5, 7, -3);                                     -- queued (limit 0)
reset erp.recost_inline_limit;
select t.ok(t.queued('QS') = 'backdate@-3', 'F2-04: the backdated receipt is queued from day -3');
select t.cancel(t.id('qs_out'));                                        -- dated -1, after the queued date
select t.ok((t.ic('QS')).qty = t.ledger_qty('QS') and (t.ic('QS')).qty = 15 and t.queued('QS') = 'backdate@-3',
            'F2-04: the cancel goes to the queue too: item_costs qty 15 = ledger (before F2: 13, stale state), still queued from -3');
reset role;
select erp.integrity_job();
select t.ok((select count(*) from erp.alerts where tenant_id = t.a() and kind = 'integrity' and resolved_at is null) = 0,
            'F2-04: the nightly job raises no false critical alert for an item that waits for the recost job');
select t.keep(erp.recost_job(50));
select t.ok(t.j() ->> 'items' = '1' and t.queued('QS') = 'none' and jsonb_array_length(t.integrity('QS')) = 0
            and (t.ic('QS')).value_avg = 85.00 and (t.ic('QS')).value_fifo = 85.00,
            'F2-04: after the job: 10 x 5 + 5 x 7 = 85.00 under both methods (the cancelled issue gone), integrity clean');
-- a cancel with more later moves than the inline limit goes to the queue (before F2: always replayed inline, unbounded)
set local role authenticated;
select t.as(1);
select t.mkitem('QC');
select t.doc('TIN', 'QC', 10, 4, -4);
select t.put('qc_out', t.doc('TOUT', 'QC', 4, null, -3));
select t.doc('TIN', 'QC', 10, 6, -2);
select t.put('qc_out2', t.doc('TOUT', 'QC', 2, null, -1));
set local erp.recost_inline_limit = '1';
select t.cancel(t.id('qc_out'));
reset erp.recost_inline_limit;
select t.ok(t.queued('QC') = 'cancel@-3' and (t.ic('QC')).qty = 18,
            'F2-04: cancel with 2 later moves over a limit of 1: queued (reason cancel), the cost row follows the reversal (qty 18)');
reset role;
select erp.recost_job(50);
select t.ok((t.mv(t.id('qc_out2'))).value_avg = -10.00 and (t.mv(t.id('qc_out2'))).value_fifo = -8.00 and jsonb_array_length(t.integrity('QC')) = 0,
            'F2-04: the job replays as if the issue never existed: later issue at avg 5.00 (10.00), FIFO 2 x 4 (8.00)');
-- stale queue (job not scheduled): the integrity job says so
update erp.recost_queue set queued_at = now() - interval '2 hours' where tenant_id = t.a();
insert into erp.recost_queue (tenant_id, item_id, from_date, reason, queued_at) values (t.a(), t.it('QC'), t.today() - 1, 'test', now() - interval '2 hours');
select erp.integrity_job();
select t.ok((select params #>> '{sample,check}' from erp.alerts where tenant_id = t.a() and kind = 'integrity' and resolved_at is null) = 'recost_stale',
            'F2-04: a queue row older than one hour raises the critical integrity alert (recost job not running)');
select erp.recost_job(50);
select erp.integrity_job();
select t.ok((select count(*) from erp.alerts where tenant_id = t.a() and kind = 'integrity' and resolved_at is null) = 0, '...resolved once the queue is processed');

-- =================== F2-02: the recost job stops after its time budget (it holds the item locks it took) ===================
set local role authenticated;
select t.as(1);
select t.mkitem('QB1'), t.mkitem('QB2');
select t.doc('TOUT', 'QB1', 1, null, 0), t.doc('TOUT', 'QB2', 1, null, 0);
set local erp.recost_inline_limit = '0';
select t.doc('TIN', 'QB1', 1, 1, -1), t.doc('TIN', 'QB2', 1, 1, -1);
reset erp.recost_inline_limit;
reset role;
select t.ok((select count(*) from erp.recost_queue where tenant_id = t.a()) = 2, 'two items queued');
select t.keep(erp.recost_job(50, 0));
select t.ok(t.j() ->> 'items' = '1' and (select count(*) from erp.recost_queue where tenant_id = t.a()) = 1,
            'F2-02: budget 0 ms: one item per run, the other stays queued (before F2: no budget, every item in one transaction)');
select t.keep(erp.recost_job());
select t.ok(t.j() ->> 'items' = '1' and (select count(*) from erp.recost_queue where tenant_id = t.a()) = 0, 'the next run takes the rest');
-- (lock order: tests/concurrency_recost.sh runs a queued post against the job in two sessions)

-- =================== F2-05: cancelling an inbound document that was consumed ===================
set local role authenticated;
select t.as(1);
select t.mkitem('CN');
select t.put('cn_grn', t.doc('GRN', 'CN', 10, 2));
select t.doc('CONS', 'CN', 8);
reset role;
update erp.tenant_settings set negative_stock = 'block' where tenant_id = t.a();
set local role authenticated;
select t.as(1);
select t.fails(format($$select erp_api.doc_set_state('%s', 'cancelled', '{"reason": "x"}', gen_random_uuid())$$, t.id('cn_grn')), 'ERP_STOCK_NEGATIVE',
               'F2-05: setting block: cancelling the consumed GRN would take W1 to -8: refused (before F2: cancelled)');
select t.ok((select state from erp.documents where document_id = t.id('cn_grn')) = 'posted', '...nothing changed');
reset role;
update erp.tenant_settings set negative_stock = 'warn' where tenant_id = t.a();
set local role authenticated;
select t.as(1);
select t.keep(t.cancel(t.id('cn_grn')));
select t.ok(t.j() #>> '{document,state}' = 'cancelled' and t.j() #>> '{warnings,0,code}' = 'W_STOCK_NEGATIVE' and (t.j() #>> '{warnings,0,qty_after}')::numeric = -8
            and t.count($$select 1 from erp.audit_log where action = 'doc.cancel_negative_stock'$$) = 1,
            'F2-05: setting warn: cancelled, the reply carries W_STOCK_NEGATIVE (-8) and the cancel is audited (before F2: silent)');

-- =================== F2-06: a source line of a document the caller cannot read ===================
select t.mkitem('SL');
select t.put('sl_a2', t.doc('GRN', 'SL', 5, 1, 0, 'W2'));                -- a GRN of branch A2 (warehouse reads GRN, not A2)
select t.as(3);                                                          -- warehouse of A1 only
select t.fails(format($$select erp_api.doc_save_draft('CONS', jsonb_build_object('branch_id', '%s', 'warehouse_id', '%s',
                 'lines', jsonb_build_array(jsonb_build_object('item_id', '%s', 'qty', 1, 'source_line_id', '%s'))), gen_random_uuid())$$,
                      t.br(t.a(), 'A1'), t.wh('W1'), t.it('SL'), t.line1(t.id('sl_a2'))), 'ERP_FORBIDDEN',
               'F2-06: a line pointing to a line of another branch''s document is refused (before F2: saved; its cost / remaining were used)');

-- =================== F2-07: later moves counted up to the limit only ===================
reset role;
select t.ok(erp.later_moves(t.a(), t.it('QC'), t.today() - 10, 2) = 3 and erp.later_moves(t.a(), t.it('QC'), t.today(), 2000) = 0,
            'F2-07: later_moves stops counting at limit + 1');

-- =================== atomicity: a post that fails after its number leaves nothing behind ===================
create function t.boom() returns trigger language plpgsql as $$
begin if new.item_id = t.it('AT2') then raise exception 'T_BOOM'; end if; return new; end $$;
select t.mkitem('AT1'), t.mkitem('AT2');
create trigger t_boom before insert on erp.stock_balances for each row execute function t.boom();
set local role authenticated;
select t.as(1);
select t.keep(erp_api.doc_save_draft('TIN', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'warehouse_id', t.wh('W1'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', t.it('AT1'), 'qty', 3, 'unit_price', 2), jsonb_build_object('item_id', t.it('AT2'), 'qty', 1, 'unit_price', 2))), gen_random_uuid()));
select t.put('at', (t.j() ->> 'document_id')::uuid);
reset role;
create table t.at_before as select next_no from erp.series where tenant_id = t.a() and code = 'TIN-A1';
set local role authenticated;
select t.as(1);
select t.fails(format($$select erp_api.doc_set_state('%s', 'posted', '{}', gen_random_uuid())$$, t.id('at')), 'T_BOOM', 'a post failing on its second line (after numbering, moves and cost of line 1)');
reset role;
drop trigger t_boom on erp.stock_balances;
select t.ok((select state || '/' || coalesce(number::text, '-') from erp.documents where document_id = t.id('at')) = 'draft/-'
            and (select next_no from erp.series where tenant_id = t.a() and code = 'TIN-A1') = (select next_no from t.at_before)
            and t.count(format($$select 1 from erp.stock_moves where document_id = '%s'$$, t.id('at'))) = 0
            and coalesce((t.ic('AT1')).qty, 0) = 0 and t.count(format($$select 1 from erp.stock_balances where item_id = '%s'$$, t.it('AT1'))) = 0,
            'atomicity: still a draft without a number, series next_no unchanged, no move, no balance, no cost state');

-- =================== independent golden set R1-R4 (tests/golden/R*.csv; re-computed by costing_model.py) ===================
create table t.rraw (step int, op text, day int, qty numeric, unit_cost numeric, src_step int, exp_move_avg numeric, exp_move_fifo numeric,
                     exp_corr_avg numeric, exp_corr_fifo numeric, exp_qty numeric, exp_value_avg numeric, exp_value_fifo numeric, exp_layers text);
create table t.rg (cs text, step int, op text, day int, qty numeric, unit_cost numeric, src_step int, exp_move_avg numeric, exp_move_fifo numeric,
                   exp_corr_avg numeric, exp_corr_fifo numeric, exp_qty numeric, exp_value_avg numeric, exp_value_fifo numeric, exp_layers text);
\copy t.rraw from 'golden/R1.csv' with (format csv, header)
insert into t.rg select 'R1', * from t.rraw; truncate t.rraw;
\copy t.rraw from 'golden/R2.csv' with (format csv, header)
insert into t.rg select 'R2', * from t.rraw; truncate t.rraw;
\copy t.rraw from 'golden/R3.csv' with (format csv, header)
insert into t.rg select 'R3', * from t.rraw; truncate t.rraw;
\copy t.rraw from 'golden/R4.csv' with (format csv, header)
insert into t.rg select 'R4', * from t.rraw; truncate t.rraw;
create table t.rdoc (cs text, step int, doc uuid);
grant select, insert on t.rg, t.rdoc to authenticated;
create function t.layers(p_code text) returns text language sql security definer as $$
  select coalesce(string_agg(rtrim(rtrim(qty_left::text, '0'), '.') || '@' || rtrim(rtrim(unit_cost::text, '0'), '.'), ';' order by layer_date, seq, layer_id), '')
    from erp.stock_layers where tenant_id = t.a() and item_id = t.it(p_code) and qty_left > 0 and void_run is null $$;
grant execute on function t.layers(text) to authenticated;
set local role authenticated;
select t.as(1);
do $$ declare g record; cur text := ''; src uuid; begin
  for g in select * from t.rg order by cs, step loop
    if g.cs <> cur then cur := g.cs; perform t.mkitem(g.cs); end if;
    src := (select line_id from erp.document_lines where document_id = (select doc from t.rdoc where cs = g.cs and step = g.src_step));
    if g.op = 'cancel' then perform t.cancel((select doc from t.rdoc where cs = g.cs and step = g.src_step)); continue; end if;
    insert into t.rdoc values (g.cs, g.step, case g.op when 'in' then t.doc('TIN', g.cs, g.qty, g.unit_cost, g.day) when 'pin' then t.doc('GRN', g.cs, g.qty, g.unit_cost, g.day)
                                                        when 'out' then t.doc('TOUT', g.cs, g.qty, null, g.day) when 'ret_in' then t.doc('TRIN', g.cs, g.qty, null, g.day, 'W1', src)
                                                        when 'ret_out' then t.doc('TROUT', g.cs, g.qty, null, g.day, 'W1', src) end);
  end loop;
end $$;
reset role;
create table t.rres as
  select g.cs, g.step,
         concat_ws('|', m.value_avg, m.value_fifo,
                   coalesce((select sum(c.value_avg) from erp.stock_moves c where c.covers_move_id = m.move_id and c.kind = 'value_only'
                              and not exists (select 1 from erp.stock_moves x where x.reverses_move_id = c.move_id)), 0.00),
                   coalesce((select sum(c.value_fifo) from erp.stock_moves c where c.covers_move_id = m.move_id and c.kind = 'value_only'
                              and not exists (select 1 from erp.stock_moves x where x.reverses_move_id = c.move_id)), 0.00)) got,
         concat_ws('|', g.exp_move_avg, g.exp_move_fifo, coalesce(g.exp_corr_avg, 0.00), coalesce(g.exp_corr_fifo, 0.00)) want
    from t.rg g join t.rdoc d using (cs, step) join erp.stock_moves m on m.document_id = d.doc and m.kind = 'normal'
   where g.exp_move_avg is not null and (select state from erp.documents where document_id = d.doc) = 'posted';
select t.ok(not exists (select 1 from t.rres where got <> want) and (select count(*) from t.rres) = (select count(*) from t.rg where exp_move_avg is not null),
            'golden R1-R4: FINAL move values and corrections of every posted step: ' ||
            coalesce((select string_agg(cs || '#' || step || ' got ' || got || ' want ' || want, '; ') from t.rres where got <> want), 'all equal'));
select t.ok(not exists (select 1 from t.rg g join erp.item_costs c on c.tenant_id = t.a() and c.item_id = t.it(g.cs)
                         where g.exp_qty is not null
                           and concat_ws('|', rtrim(rtrim(c.qty::text, '0'), '.'), c.value_avg, c.value_fifo, t.layers(g.cs))
                               <> concat_ws('|', rtrim(rtrim(g.exp_qty::text, '0'), '.'), g.exp_value_avg, g.exp_value_fifo, coalesce(g.exp_layers, ''))),
            'golden R1-R4: final state qty | average | FIFO | open layers: ' ||
            coalesce((select string_agg(g.cs || ' got ' || concat_ws('|', rtrim(rtrim(c.qty::text, '0'), '.'), c.value_avg, c.value_fifo, t.layers(g.cs)), '; ')
                        from t.rg g join erp.item_costs c on c.tenant_id = t.a() and c.item_id = t.it(g.cs) where g.exp_qty is not null), ''));
select t.ok(not exists (select 1 from (select distinct cs from t.rg) g where jsonb_array_length(t.integrity(g.cs)) > 0), 'golden R1-R4: integrity clean');

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
