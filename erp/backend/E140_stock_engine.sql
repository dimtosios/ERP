-- =====================================================================
-- iSmile ERP  -  E140_stock_engine.sql   (tasks T10, T12, T13)
-- Purpose : the stock ledger and valuation (02 "Valuation", "Rules", "Performance and concurrency"):
--           stock_moves (append-only ledger; only the costing code rewrites COST columns), stock_balances (per
--           warehouse / item / lot), item_costs (moving-average state + FIFO deficit, per item / lot, company-wide),
--           stock_layers (FIFO), stock_move_layers (append-only, per costing run), valuation_periods (official method,
--           seed = average). Every move is costed under BOTH methods; `official` says which one feeds the documents.
--           erp.cost_move = the ONE costing step (posting and replay use it); erp.cost_replay rebuilds an item from a
--           date (cancel now; backdating / recost in T13); hooks of E130: stock_lock, stock_check, stock_post,
--           stock_cancel; erp.stock_integrity (balances = ledger, cost state = ledger, layers = on hand);
--           negative-stock / low-stock alerts after each posting and cancel (erp.stock_alerts, T12);
--           T13: cost_revisions (every cost change of an existing move by a replay), recost_queue (a backdated post with
--           more than erp.recost_inline_limit = 2000 later moves is queued), erp.recost_item / erp.recost_job (queue,
--           "5-minute job"), erp.integrity_job (nightly: owner alert), lock date never moves over a queued recost;
--           RPCs recost_status, recost_run; T14 read models: stock_on_hand, stock_card, item_lookup, item_availability.
-- Run order: after E130. Standalone: names no CRM object. Safe to re-run.
-- Redefines: erp.doc_value (E130): stock documents are valued at cost for the approval limits.
-- Tests    : tests/E140_stock_engine_tests.sql (golden cases tests/golden/G1..G5.csv), tests/E990 (fixtures);
--            F2 review: tests/E142_f2_review_tests.sql, tests/costing_model.py (independent model + fuzz),
--            tests/concurrency_recost.sh. F2 changes: fallback_cost (O2), queue routing of large / stale replays,
--            recost_job lock order + time budget, stock_cancel_check, later_moves (capped count).
--            T16 (suite E160): cost rule 'transfer' in erp.cost_move (cost-neutral: no state or layer change; the
--            paired / receipt moves copy the dispatch move's cost), stock_effect / stock_post write the transit side of
--            a TRF dispatch, erp.stock_cost_new (the cost-now / replay / queue decision, shared with the TRF receipt),
--            no stock alerts on the transit warehouse, integrity_job calls erp.trf_integrity when E160 is installed.
-- Rounding : values numeric(14,2), quantities (16,4), unit costs (18,6). Average: outbound value = round(qty x avg,
--            2); avg = value / qty after every move that leaves qty > 0. FIFO: layers in (layer_date, seq) order; a
--            partly consumed layer gives round(qty x unit cost, 2), a fully consumed one its exact value_left. A move
--            that brings the quantity to 0 takes the remaining value (0 qty = 0 value, both methods).
-- Negative : the uncovered quantity of an outbound is costed at the last official cost (average: avg_cost; FIFO: the
--            unit cost of the last consumed layer) and flagged cost_provisional; the next inbound first covers the
--            deficit and posts ONE value-only correction move (qty 0) per inbound, with the difference. An item with
--            no cost history yet (no inbound before the move) uses the move's fallback_cost = the item's last
--            purchase price WHEN THE MOVE WAS POSTED (F2 decision O2: a costing input, so a replay gives the same
--            value; the price at replay time is never used), under both methods; also for an inbound without cost.
-- =====================================================================

do $$ begin
  if to_regclass('erp.documents') is null then raise exception 'run E130_documents_core.sql first'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------
create table if not exists erp.stock_moves (
  tenant_id        uuid not null references erp.tenants (tenant_id),
  move_id          bigint generated always as identity,
  document_id      uuid not null,
  line_id          uuid,
  warehouse_id     uuid not null,
  item_id          uuid not null,
  lot_id           uuid not null default '00000000-0000-0000-0000-000000000000',   -- "no lot" until T37
  move_date        date not null,
  kind             text not null check (kind in ('normal', 'reversal', 'value_only')),
  qty_base         numeric(16,4) not null,                -- signed: + in, - out; 0 for value_only
  -- inputs of the costing (never rewritten)
  cost_rule        text not null check (cost_rule in ('line', 'line_or_current', 'current', 'issue', 'source_out', 'source_in', 'reversal', 'correction', 'transfer')),
  in_value         numeric(14,2),                         -- inbound 'line' value (the line's net)
  src_move_id      bigint,                                -- source_out / source_in: the linked move
  reverses_move_id bigint,                                -- reversal: the move it reverses
  covers_move_id   bigint,                                -- value_only: the inbound whose deficit cover it corrects
  -- costing results (rewritten only by erp.cost_move under erp.recost = on)
  unit_cost_avg    numeric(18,6),
  unit_cost_fifo   numeric(18,6),
  value_avg        numeric(14,2) not null default 0,      -- signed
  value_fifo       numeric(14,2) not null default 0,      -- signed
  official         text not null default 'avg' check (official in ('avg', 'fifo')),
  cost_provisional boolean not null default false,
  cover_qty        numeric(16,4),                         -- value_only: deficit quantity covered
  cover_value_fifo numeric(14,2),                         -- value_only: provisional FIFO value of that quantity
  layer_run        bigint,                                -- costing run whose stock_move_layers rows are current
  run_qty          numeric(16,4),                         -- item state AFTER this move (item / lot, all warehouses)
  run_value_avg    numeric(14,2),
  run_value_fifo   numeric(14,2),
  run_avg_cost     numeric(18,6),
  run_deficit_value numeric(14,2),
  run_fifo_last    numeric(18,6),
  created_at       timestamptz not null default now(),
  primary key (tenant_id, move_id),
  foreign key (tenant_id, document_id) references erp.documents (tenant_id, document_id),
  foreign key (tenant_id, line_id) references erp.document_lines (tenant_id, line_id),
  foreign key (tenant_id, warehouse_id) references erp.warehouses (tenant_id, warehouse_id),
  foreign key (tenant_id, item_id) references erp.items (tenant_id, item_id),
  check ((kind = 'value_only') = (qty_base = 0))
);
create index if not exists stock_moves_cost_idx on erp.stock_moves (tenant_id, item_id, lot_id, move_date, move_id);
create index if not exists stock_moves_card_idx on erp.stock_moves (tenant_id, item_id, warehouse_id, move_date, move_id);
create index if not exists stock_moves_doc_idx on erp.stock_moves (tenant_id, document_id);
create index if not exists stock_moves_rev_idx on erp.stock_moves (tenant_id, reverses_move_id) where reverses_move_id is not null;
create index if not exists stock_moves_cover_idx on erp.stock_moves (tenant_id, covers_move_id) where covers_move_id is not null;
create index if not exists stock_moves_line_idx on erp.stock_moves (tenant_id, line_id);

create table if not exists erp.stock_balances (
  tenant_id      uuid not null references erp.tenants (tenant_id),
  warehouse_id   uuid not null,
  item_id        uuid not null,
  lot_id         uuid not null default '00000000-0000-0000-0000-000000000000',
  qty            numeric(16,4) not null default 0,
  reserved       numeric(16,4) not null default 0,
  negative_since timestamptz,
  last_move_id   bigint,
  updated_at     timestamptz not null default now(),
  primary key (tenant_id, warehouse_id, item_id, lot_id),
  foreign key (tenant_id, warehouse_id) references erp.warehouses (tenant_id, warehouse_id),
  foreign key (tenant_id, item_id) references erp.items (tenant_id, item_id)
);
-- T16: cost rule 'transfer' (TRF dispatch / receipt moves: cost-neutral, erp.cost_move)
alter table erp.stock_moves drop constraint if exists stock_moves_cost_rule_check;
alter table erp.stock_moves add constraint stock_moves_cost_rule_check
  check (cost_rule in ('line', 'line_or_current', 'current', 'issue', 'source_out', 'source_in', 'reversal', 'correction', 'transfer'));
-- F2 (O2): the provisional-cost fallback of the move = the item's last purchase price when it was posted (0 when none);
-- an INPUT of the costing (never rewritten: not in the stock_moves_guard list). Null only for moves posted before F2.
alter table erp.stock_moves add column if not exists fallback_cost numeric(18,6);
alter table erp.stock_balances add column if not exists negative_move_id bigint;   -- the move that took it below zero (T12 report)
create index if not exists stock_balances_item_idx on erp.stock_balances (tenant_id, item_id);
create index if not exists stock_balances_negative_idx on erp.stock_balances (tenant_id, warehouse_id) where qty < 0;

create table if not exists erp.item_costs (
  tenant_id      uuid not null references erp.tenants (tenant_id),
  item_id        uuid not null,
  lot_id         uuid not null default '00000000-0000-0000-0000-000000000000',
  qty            numeric(16,4) not null default 0,
  value_avg      numeric(14,2) not null default 0,
  avg_cost       numeric(18,6) not null default 0,
  value_fifo     numeric(14,2) not null default 0,
  deficit_value  numeric(14,2) not null default 0,      -- FIFO: provisional value taken out beyond the layers
  fifo_last_cost numeric(18,6),
  last_move_id   bigint,
  updated_at     timestamptz not null default now(),
  primary key (tenant_id, item_id, lot_id),
  foreign key (tenant_id, item_id) references erp.items (tenant_id, item_id)
);

create table if not exists erp.stock_layers (
  tenant_id  uuid not null references erp.tenants (tenant_id),
  layer_id   bigint generated always as identity,
  item_id    uuid not null,
  lot_id     uuid not null default '00000000-0000-0000-0000-000000000000',
  move_id    bigint not null,                           -- the inbound move that created it
  layer_date date not null,
  seq        bigint not null,                           -- = move_id: order inside a date
  qty_in     numeric(16,4) not null check (qty_in > 0),
  qty_left   numeric(16,4) not null check (qty_left >= 0),
  unit_cost  numeric(18,6) not null,
  value_left numeric(14,2) not null,
  void_run   bigint,                                    -- replaced by a costing run (cancel / recost)
  primary key (tenant_id, layer_id),
  foreign key (tenant_id, item_id) references erp.items (tenant_id, item_id),
  check (qty_left <= qty_in)
);
create index if not exists stock_layers_open_idx on erp.stock_layers (tenant_id, item_id, lot_id, layer_date, seq) where qty_left > 0 and void_run is null;
create index if not exists stock_layers_move_idx on erp.stock_layers (tenant_id, move_id);

create table if not exists erp.stock_move_layers (
  tenant_id uuid not null references erp.tenants (tenant_id),
  move_id   bigint not null,
  layer_id  bigint not null,
  run_id    bigint not null default 0,
  qty       numeric(16,4) not null,
  value     numeric(14,2) not null,
  primary key (tenant_id, move_id, layer_id, run_id)
);
create index if not exists stock_move_layers_layer_idx on erp.stock_move_layers (tenant_id, layer_id);

-- official method (02): tenant row (category null) + category overrides, valid from a date; seed = average
create table if not exists erp.valuation_periods (
  tenant_id   uuid not null references erp.tenants (tenant_id),
  period_id   uuid not null default gen_random_uuid(),
  category_id uuid,
  method      text not null check (method in ('avg', 'fifo')),
  valid_from  date not null,
  created_at  timestamptz not null default now(),
  primary key (tenant_id, period_id),
  foreign key (tenant_id, category_id) references erp.item_categories (tenant_id, category_id)
);
create unique index if not exists valuation_periods_uq on erp.valuation_periods (tenant_id, coalesce(category_id, '00000000-0000-0000-0000-000000000000'::uuid), valid_from);

create sequence if not exists erp.cost_run_seq;

-- every rewrite of the costing result of an EXISTING move by a replay (02 "Backdated documents"): append-only
create table if not exists erp.cost_revisions (
  tenant_id       uuid not null references erp.tenants (tenant_id),
  revision_id     bigint generated always as identity,
  run_id          bigint not null,
  reason          text not null,
  move_id         bigint not null,
  document_id     uuid not null,
  item_id         uuid not null,
  old_value_avg   numeric(14,2),
  new_value_avg   numeric(14,2),
  old_value_fifo  numeric(14,2),
  new_value_fifo  numeric(14,2),
  old_unit_cost_avg  numeric(18,6),
  new_unit_cost_avg  numeric(18,6),
  old_unit_cost_fifo numeric(18,6),
  new_unit_cost_fifo numeric(18,6),
  created_at      timestamptz not null default now(),
  primary key (tenant_id, revision_id)
);
create index if not exists cost_revisions_move_idx on erp.cost_revisions (tenant_id, move_id);
create index if not exists cost_revisions_run_idx on erp.cost_revisions (tenant_id, run_id);

-- items whose costing waits for the job (one open row per item / lot, earliest date kept)
create table if not exists erp.recost_queue (
  tenant_id  uuid not null references erp.tenants (tenant_id),
  item_id    uuid not null,
  lot_id     uuid not null default '00000000-0000-0000-0000-000000000000',
  from_date  date not null,
  reason     text not null,
  queued_at  timestamptz not null default now(),
  primary key (tenant_id, item_id, lot_id),
  foreign key (tenant_id, item_id) references erp.items (tenant_id, item_id)
);

-- ---------------------------------------------------------------------
-- 2. Ledger guards
-- ---------------------------------------------------------------------
-- stock_moves: no delete / truncate; an update only of the costing results, only inside the costing code
create or replace function erp.tg_stock_moves_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op <> 'UPDATE' or current_setting('erp.recost', true) is distinct from 'on'
     or (to_jsonb(new) - array['unit_cost_avg', 'unit_cost_fifo', 'value_avg', 'value_fifo', 'official', 'cost_provisional', 'cover_qty', 'cover_value_fifo', 'layer_run',
                                'run_qty', 'run_value_avg', 'run_value_fifo', 'run_avg_cost', 'run_deficit_value', 'run_fifo_last'])
        <> (to_jsonb(old) - array['unit_cost_avg', 'unit_cost_fifo', 'value_avg', 'value_fifo', 'official', 'cost_provisional', 'cover_qty', 'cover_value_fifo', 'layer_run',
                                   'run_qty', 'run_value_avg', 'run_value_fifo', 'run_avg_cost', 'run_deficit_value', 'run_fifo_last']) then
    perform erp.err('ERP_APPEND_ONLY', format('stock_moves is a ledger: %s is not allowed (corrections are reversing documents).', lower(tg_op)));
  end if;
  return new;
end $$;
drop trigger if exists stock_moves_guard on erp.stock_moves;
create trigger stock_moves_guard before update or delete on erp.stock_moves for each row execute function erp.tg_stock_moves_guard();
drop trigger if exists stock_moves_no_truncate on erp.stock_moves;
create trigger stock_moves_no_truncate before truncate on erp.stock_moves for each statement execute function erp.tg_append_only();
drop trigger if exists stock_move_layers_append_only on erp.stock_move_layers;
create trigger stock_move_layers_append_only before update or delete on erp.stock_move_layers for each row execute function erp.tg_append_only();
drop trigger if exists stock_move_layers_no_truncate on erp.stock_move_layers;
create trigger stock_move_layers_no_truncate before truncate on erp.stock_move_layers for each statement execute function erp.tg_append_only();

drop trigger if exists cost_revisions_append_only on erp.cost_revisions;
create trigger cost_revisions_append_only before update or delete on erp.cost_revisions for each row execute function erp.tg_append_only();
drop trigger if exists cost_revisions_no_truncate on erp.cost_revisions;
create trigger cost_revisions_no_truncate before truncate on erp.cost_revisions for each statement execute function erp.tg_append_only();

-- the lock date never moves over a queued recost (its moves would be costed again inside a locked period)
create or replace function erp.tg_lock_date_recost() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.lock_date is not null and new.lock_date is distinct from old.lock_date
     and exists (select 1 from erp.recost_queue q where q.tenant_id = new.tenant_id and q.from_date <= new.lock_date) then
    perform erp.err('ERP_RECOST_PENDING', format('Costs from %s are still being recalculated: the lock date cannot be %s yet. Run the recost first.',
                    (select to_char(min(q.from_date), 'DD/MM/YYYY') from erp.recost_queue q where q.tenant_id = new.tenant_id), to_char(new.lock_date, 'DD/MM/YYYY')));
  end if;
  return new;
end $$;
drop trigger if exists tenant_settings_lock_recost on erp.tenant_settings;
create trigger tenant_settings_lock_recost before update of lock_date on erp.tenant_settings for each row execute function erp.tg_lock_date_recost();

-- master data used by the ledger: base unit and lot tracking of an item with moves never change; a warehouse with
-- stock never changes branch and is not deactivated (STATE 35)
create or replace function erp.tg_items_ledger_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (new.base_unit_id is distinct from old.base_unit_id or new.lot_tracked is distinct from old.lot_tracked or (new.kind = 'service') <> (old.kind = 'service'))
     and exists (select 1 from erp.stock_moves m where m.tenant_id = old.tenant_id and m.item_id = old.item_id) then
    perform erp.err('ERP_VALIDATION', format('Item %s has stock moves: its base unit, lot tracking and service kind cannot change.', old.code),
                    jsonb_build_array(erp.problem('in_use', 'base_unit_id', format('Item %s has stock moves: its base unit, lot tracking and service kind cannot change.', old.code))));
  end if;
  return new;
end $$;
drop trigger if exists items_ledger_guard on erp.items;
create trigger items_ledger_guard before update of base_unit_id, lot_tracked, kind on erp.items for each row execute function erp.tg_items_ledger_guard();

create or replace function erp.tg_warehouses_stock_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (new.branch_id is distinct from old.branch_id or (old.active and not new.active))
     and exists (select 1 from erp.stock_balances b where b.tenant_id = old.tenant_id and b.warehouse_id = old.warehouse_id and b.qty <> 0) then
    perform erp.err('ERP_VALIDATION', format('Warehouse %s holds stock: move or count it out before changing its branch or deactivating it.', old.code),
                    jsonb_build_array(erp.problem('in_use', case when new.branch_id is distinct from old.branch_id then 'branch_id' else 'active' end,
                                                  format('Warehouse %s holds stock.', old.code))));
  end if;
  return new;
end $$;
drop trigger if exists warehouses_stock_guard on erp.warehouses;
create trigger warehouses_stock_guard before update of branch_id, active on erp.warehouses for each row execute function erp.tg_warehouses_stock_guard();

-- valuation seed per tenant (owner decision: weighted average, all categories)
create or replace function erp.tg_tenants_valuation() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into erp.valuation_periods (tenant_id, category_id, method, valid_from) values (new.tenant_id, null, 'avg', '2000-01-01') on conflict do nothing;
  return null;
end $$;
drop trigger if exists tenants_e140_init on erp.tenants;
create trigger tenants_e140_init after insert on erp.tenants for each row execute function erp.tg_tenants_valuation();
insert into erp.valuation_periods (tenant_id, category_id, method, valid_from) select tenant_id, null, 'avg', '2000-01-01' from erp.tenants on conflict do nothing;

-- ---------------------------------------------------------------------
-- 3. Costing helpers
-- ---------------------------------------------------------------------
-- official method of an item at a date: the nearest category up the tree with a period, else the tenant row (02)
create or replace function erp.item_method(p_tenant uuid, p_item uuid, p_date date) returns text
language sql stable security definer set search_path = '' as $$
  with recursive up as (
    select c.category_id, c.parent_id, 1 lvl from erp.items i join erp.item_categories c on c.tenant_id = i.tenant_id and c.category_id = i.category_id
     where i.tenant_id = p_tenant and i.item_id = p_item
    union all
    select c.category_id, c.parent_id, up.lvl + 1 from erp.item_categories c join up on c.tenant_id = p_tenant and c.category_id = up.parent_id where up.lvl < 9)
  select coalesce(
    (select v.method from erp.valuation_periods v join up on v.category_id = up.category_id
      where v.tenant_id = p_tenant and v.valid_from <= p_date order by up.lvl, v.valid_from desc limit 1),
    (select v.method from erp.valuation_periods v where v.tenant_id = p_tenant and v.category_id is null and v.valid_from <= p_date order by v.valid_from desc limit 1),
    'avg')
$$;

-- the item's cost state row (created empty on first use); the caller holds the item lock
create or replace function erp.item_cost_row(p_tenant uuid, p_item uuid, p_lot uuid) returns erp.item_costs
language plpgsql security definer set search_path = '' as $$
declare ic erp.item_costs;
begin
  select * into ic from erp.item_costs where tenant_id = p_tenant and item_id = p_item and lot_id = p_lot;
  if not found then
    insert into erp.item_costs (tenant_id, item_id, lot_id) values (p_tenant, p_item, p_lot) on conflict do nothing;
    select * into ic from erp.item_costs where tenant_id = p_tenant and item_id = p_item and lot_id = p_lot;
  end if;
  return ic;
end $$;

-- the current official unit cost (ADJ+ without a cost, unlinked returns): average -> avg_cost; FIFO -> the next layer
-- out, else the last consumed; fallback the item's last purchase price, else 0
create or replace function erp.current_cost(p_tenant uuid, p_item uuid, p_lot uuid, p_method text) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(case when p_method = 'avg' then (select ic.avg_cost from erp.item_costs ic where ic.tenant_id = p_tenant and ic.item_id = p_item and ic.lot_id = p_lot)
                             else coalesce((select l.unit_cost from erp.stock_layers l where l.tenant_id = p_tenant and l.item_id = p_item and l.lot_id = p_lot
                                             and l.qty_left > 0 and l.void_run is null order by l.layer_date, l.seq, l.layer_id limit 1),
                                           (select ic.fifo_last_cost from erp.item_costs ic where ic.tenant_id = p_tenant and ic.item_id = p_item and ic.lot_id = p_lot)) end, 0),
                  (select i.last_purchase_price from erp.items i where i.tenant_id = p_tenant and i.item_id = p_item), 0)
$$;

-- replay state (T15): during erp.cost_replay the item's running cost state is carried in the transaction-local
-- setting erp.replay_state instead of being written to its item_costs row after every move (thousands of updates of
-- ONE row in one transaction make every later update walk the row's version chain: quadratic). erp.replay_key names
-- the (tenant, item, lot) being replayed; cost_replay writes item_costs once at the end.
create or replace function erp.replay_key(p_tenant uuid, p_item uuid, p_lot uuid) returns text
language sql immutable set search_path = '' as $$ select p_tenant::text || ':' || p_item::text || ':' || p_lot::text $$;
create or replace function erp.replay_get() returns erp.item_costs
language plpgsql stable set search_path = '' as $$
declare r erp.item_costs; a text[] := string_to_array(current_setting('erp.replay_state', true), '|');
begin
  r.qty := a[1]::numeric; r.value_avg := a[2]::numeric; r.value_fifo := a[3]::numeric; r.deficit_value := a[4]::numeric;
  r.avg_cost := a[5]::numeric; r.fifo_last_cost := nullif(a[6], '')::numeric; r.last_move_id := nullif(a[7], '')::bigint;
  return r;
end $$;
create or replace function erp.replay_put(q numeric, va numeric, vf numeric, dv numeric, avgc numeric, flast numeric, last_move bigint) returns void
language sql set search_path = '' as $$
  select set_config('erp.replay_state', concat_ws('|', q, va, vf, dv, avgc, coalesce(flast::text, ''), coalesce(last_move::text, '')), true) is null
$$;

-- FIFO consumption of one layer by an outbound move: {take, value}. During a replay the partly consumed layer (the
-- "head", consumed again by the next outbound moves) is kept in erp.replay_head ('layer_id|qty_left|value_left')
-- and written when another layer becomes the head, when it is used up, or at the end of the replay
-- (erp.replay_head_flush) - for the same reason as erp.replay_state.
create or replace function erp.replay_head_flush(p_tenant uuid) returns void
language plpgsql set search_path = '' as $$
declare a text[] := string_to_array(nullif(current_setting('erp.replay_head', true), ''), '|');
begin
  if a is null then return; end if;
  update erp.stock_layers set qty_left = a[2]::numeric, value_left = a[3]::numeric where tenant_id = p_tenant and layer_id = a[1]::bigint;
  perform set_config('erp.replay_head', '', true);
end $$;
create or replace function erp.layer_take(p_tenant uuid, p_move bigint, p_run bigint, p_layer erp.stock_layers, p_rem numeric, p_replay boolean) returns numeric[]
language plpgsql set search_path = '' as $$
declare a text[]; ql numeric := p_layer.qty_left; vl numeric := p_layer.value_left; take numeric; tval numeric;
begin
  if coalesce(p_replay, false) then
    a := string_to_array(nullif(current_setting('erp.replay_head', true), ''), '|');
    if a is not null and a[1]::bigint = p_layer.layer_id then ql := a[2]::numeric; vl := a[3]::numeric; end if;
  end if;
  take := least(p_rem, ql);
  tval := case when take = ql then vl else round(take * p_layer.unit_cost, 2) end;
  if not coalesce(p_replay, false) then
    update erp.stock_layers set qty_left = ql - take, value_left = vl - tval where tenant_id = p_tenant and layer_id = p_layer.layer_id;
  elsif ql - take > 0 then
    if a is not null and a[1]::bigint <> p_layer.layer_id then perform erp.replay_head_flush(p_tenant); end if;
    perform set_config('erp.replay_head', concat_ws('|', p_layer.layer_id, ql - take, vl - tval), true);
  else
    update erp.stock_layers set qty_left = 0, value_left = vl - tval where tenant_id = p_tenant and layer_id = p_layer.layer_id;
    if a is not null and a[1]::bigint = p_layer.layer_id then perform set_config('erp.replay_head', '', true); end if;
  end if;
  insert into erp.stock_move_layers (tenant_id, move_id, layer_id, run_id, qty, value) values (p_tenant, p_move, p_layer.layer_id, p_run, take, tval);
  return array[take, tval];
end $$;

-- ---------------------------------------------------------------------
-- 4. erp.cost_move: cost ONE normal move against the item's current state (item_costs + layers). Writes the move's
--    cost and running-state columns, its FIFO consumption (run p_run), its layer (inbound) and, for an inbound that
--    covers a deficit, its value-only correction move. The caller holds the item lock (erp.stock_lock / replay).
-- ---------------------------------------------------------------------
create or replace function erp.cost_move(p_tenant uuid, p_move bigint, p_run bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare mv erp.stock_moves; src erp.stock_moves; ic erp.item_costs; lay erp.stock_layers; corr bigint;
        q numeric; va numeric; vf numeric; dv numeric; avgc numeric; flast numeric; meth text; prov boolean := false;
        bq numeric; x numeric; v_a numeric; v_f numeric; k_a numeric := 0; k_f numeric := 0; dq numeric; c numeric := 0; dv_c numeric := 0; tv numeric := 0;
        rem numeric; take numeric; tval numeric; cur numeric; src_layer bigint; old_corr jsonb; nw erp.stock_moves; nw_a numeric; nw_f numeric; in_replay boolean; tk numeric[];
        fb numeric;
begin
  select * into mv from erp.stock_moves where tenant_id = p_tenant and move_id = p_move;
  -- provisional fallback (F2, O2): the price snapshot of the move; moves posted before F2 read the current price
  fb := coalesce(mv.fallback_cost, (select i.last_purchase_price from erp.items i where i.tenant_id = p_tenant and i.item_id = mv.item_id), 0);
  old_corr := (select to_jsonb(m) from erp.stock_moves m where m.tenant_id = p_tenant and m.covers_move_id = p_move and m.kind = 'value_only'
                  and not exists (select 1 from erp.stock_moves r where r.tenant_id = p_tenant and r.reverses_move_id = m.move_id) limit 1);
  in_replay := coalesce(current_setting('erp.replay_key', true) = erp.replay_key(p_tenant, mv.item_id, mv.lot_id), false);
  ic := case when in_replay then erp.replay_get() else erp.item_cost_row(p_tenant, mv.item_id, mv.lot_id) end;
  q := ic.qty; va := ic.value_avg; vf := ic.value_fifo; dv := ic.deficit_value; avgc := ic.avg_cost; flast := ic.fifo_last_cost;
  meth := erp.item_method(p_tenant, mv.item_id, mv.move_date);
  if mv.src_move_id is not null then select * into src from erp.stock_moves where tenant_id = p_tenant and move_id = mv.src_move_id; end if;
  bq := mv.qty_base;
  perform set_config('erp.recost', 'on', true);
  if mv.cost_rule = 'transfer' then
    -- ---------- transfer (T16): cost-neutral. The item's cost state (company-wide) and its FIFO layers do not change
    --            (02: "transfers do not change cost and do not consume layers"); the move only carries a value.
    x := abs(bq);
    if src.move_id is not null then
      -- the paired transit move and the receipt moves: the dispatch move's cost, so nothing drifts through transit
      v_a := case when x = abs(src.qty_base) then abs(src.value_avg) else round(x * src.unit_cost_avg, 2) end;
      v_f := case when x = abs(src.qty_base) then abs(src.value_fifo) else round(x * src.unit_cost_fifo, 2) end;
      prov := src.cost_provisional;
    else
      -- the dispatch: the moved quantity at the item's cost (average: avg_cost; FIFO: open layers' value per unit; the
      -- whole stock moves at its exact values); without stock: the uncovered-quantity rule of an issue (provisional)
      if q > 0 then
        v_a := case when x = q then va else round(x * avgc, 2) end;
        v_f := case when x = q then vf else round(x * vf / q, 2) end;
      else
        v_a := round(x * case when flast is null then fb else avgc end, 2);
        v_f := round(x * coalesce(flast, nullif(avgc, 0), fb), 2);
      end if;
      prov := q < x;
    end if;
    nw_a := sign(bq) * v_a; nw_f := sign(bq) * v_f;
    update erp.stock_moves set unit_cost_avg = round(v_a / x, 6), unit_cost_fifo = round(v_f / x, 6), value_avg = nw_a, value_fifo = nw_f, official = meth,
           cost_provisional = prov, layer_run = null,
           run_qty = q, run_value_avg = va, run_value_fifo = vf, run_avg_cost = avgc, run_deficit_value = dv, run_fifo_last = flast
     where tenant_id = p_tenant and move_id = p_move;
  elsif bq > 0 then
    -- ---------- inbound: value per method ----------
    if mv.cost_rule in ('line', 'line_or_current') and mv.in_value is not null then v_a := mv.in_value; v_f := mv.in_value;
    elsif mv.cost_rule = 'source_out' and src.move_id is not null then
      v_a := round(bq * coalesce(src.unit_cost_avg, 0), 2); v_f := round(bq * coalesce(src.unit_cost_fifo, 0), 2);
    else
      -- = erp.current_cost, from the state in hand (item_costs may be behind during a replay)
      cur := coalesce(nullif(case when meth = 'avg' then avgc
                                  else coalesce((select l.unit_cost from erp.stock_layers l where l.tenant_id = p_tenant and l.item_id = mv.item_id and l.lot_id = mv.lot_id
                                                  and l.qty_left > 0 and l.void_run is null order by l.layer_date, l.seq, l.layer_id limit 1), flast) end, 0),
                      fb);
      v_a := round(bq * cur, 2); v_f := v_a;
    end if;
    -- average: a deficit (q < 0) is first covered at the inbound cost; the difference is the correction k_a
    if q >= 0 then va := va + v_a;
    elsif q + bq >= 0 then k_a := round((q + bq) * v_a / bq, 2) - (va + v_a); va := va + v_a + k_a;
    else k_a := -round(v_a - bq * va / q, 2); va := va + v_a + k_a;
    end if;
    q := q + bq;
    if q > 0 then avgc := round(va / q, 6); elsif q = 0 then va := 0; end if;
    -- FIFO: the deficit (no layers) is covered first; the rest becomes a new layer
    dq := greatest(-(q - bq), 0);
    c := least(dq, bq);
    if c > 0 then
      dv_c := case when c = dq then dv else round(dv * c / dq, 2) end;
      tv := case when c = bq then v_f else round(c * v_f / bq, 2) end;
      k_f := dv_c - tv; dv := dv - dv_c;
    end if;
    if bq - c > 0 then
      insert into erp.stock_layers (tenant_id, item_id, lot_id, move_id, layer_date, seq, qty_in, qty_left, unit_cost, value_left)
      values (p_tenant, mv.item_id, mv.lot_id, mv.move_id, mv.move_date, mv.move_id, bq - c, bq - c, round((v_f - tv) / (bq - c), 6), v_f - tv);
    end if;
    vf := vf + v_f + k_f;
    flast := round(v_f / bq, 6);
    nw_a := v_a; nw_f := v_f;
    update erp.stock_moves set unit_cost_avg = round(v_a / bq, 6), unit_cost_fifo = round(v_f / bq, 6), value_avg = v_a, value_fifo = v_f, official = meth,
           cost_provisional = (mv.cost_rule in ('current', 'line_or_current') and mv.in_value is null and cur = 0), layer_run = null,
           run_qty = q, run_value_avg = va, run_value_fifo = vf, run_avg_cost = avgc, run_deficit_value = dv, run_fifo_last = flast
     where tenant_id = p_tenant and move_id = p_move;
    -- the value-only correction of this inbound (one row, rewritten by a replay; 0 when no longer needed)
    select m.move_id into corr from erp.stock_moves m
     where m.tenant_id = p_tenant and m.covers_move_id = p_move and m.kind = 'value_only'
       and not exists (select 1 from erp.stock_moves r where r.tenant_id = p_tenant and r.reverses_move_id = m.move_id) limit 1;
    if corr is not null then
      update erp.stock_moves set value_avg = k_a, value_fifo = k_f, cover_qty = c, cover_value_fifo = dv_c, official = meth,
             run_qty = q, run_value_avg = va, run_value_fifo = vf, run_avg_cost = avgc, run_deficit_value = dv, run_fifo_last = flast
       where tenant_id = p_tenant and move_id = corr;
    elsif k_a <> 0 or k_f <> 0 then
      insert into erp.stock_moves (tenant_id, document_id, line_id, warehouse_id, item_id, lot_id, move_date, kind, qty_base, cost_rule, covers_move_id,
                                   value_avg, value_fifo, official, cover_qty, cover_value_fifo,
                                   run_qty, run_value_avg, run_value_fifo, run_avg_cost, run_deficit_value, run_fifo_last)
      values (p_tenant, mv.document_id, mv.line_id, mv.warehouse_id, mv.item_id, mv.lot_id, mv.move_date, 'value_only', 0, 'correction', p_move,
              k_a, k_f, meth, c, dv_c, q, va, vf, avgc, dv, flast)
      returning move_id into corr;
    end if;
  else
    -- ---------- outbound ----------
    x := -bq;
    -- average
    if q >= x then
      v_a := case when q = x then va
                  when mv.cost_rule = 'source_in' and src.move_id is not null then round(x * src.unit_cost_avg, 2)
                  else round(x * avgc, 2) end;
    elsif q > 0 then v_a := va + round((x - q) * avgc, 2); prov := true;
    else v_a := round(x * case when flast is null then fb else avgc end, 2); prov := true;   -- no cost history: the snapshot (F2)
    end if;
    va := va - v_a; q := q - x;
    if q > 0 then avgc := round(va / q, 6); elsif q = 0 then va := 0; end if;
    -- FIFO: a supplier return takes its receipt's layer first, then the oldest layers
    rem := x; v_f := 0;
    if mv.cost_rule = 'source_in' and src.move_id is not null then
      select l.layer_id into src_layer from erp.stock_layers l
       where l.tenant_id = p_tenant and l.move_id = src.move_id and l.void_run is null and l.qty_left > 0 order by l.layer_id desc limit 1;
    end if;
    -- (two steps so the open layers are read in index order, lazily, without a sort of all of them)
    if src_layer is not null then
      select * into lay from erp.stock_layers l where l.tenant_id = p_tenant and l.layer_id = src_layer for update;
      tk := erp.layer_take(p_tenant, p_move, p_run, lay, rem, in_replay);
      v_f := v_f + tk[2]; rem := rem - tk[1]; flast := lay.unit_cost;
    end if;
    for lay in select * from erp.stock_layers l
                where l.tenant_id = p_tenant and l.item_id = mv.item_id and l.lot_id = mv.lot_id and l.qty_left > 0 and l.void_run is null
                  and l.layer_id is distinct from src_layer
                order by l.layer_date, l.seq, l.layer_id for update loop
      exit when rem <= 0;
      tk := erp.layer_take(p_tenant, p_move, p_run, lay, rem, in_replay);
      v_f := v_f + tk[2]; rem := rem - tk[1]; flast := lay.unit_cost;
    end loop;
    if rem > 0 then
      tval := round(rem * coalesce(flast, nullif(avgc, 0), fb), 2);
      dv := dv + tval; v_f := v_f + tval; prov := true;
    end if;
    vf := vf - v_f;
    if q = 0 then vf := 0; dv := 0; end if;
    nw_a := -v_a; nw_f := -v_f;
    update erp.stock_moves set unit_cost_avg = round(v_a / x, 6), unit_cost_fifo = round(v_f / x, 6), value_avg = -v_a, value_fifo = -v_f, official = meth,
           cost_provisional = prov, layer_run = p_run,
           run_qty = q, run_value_avg = va, run_value_fifo = vf, run_avg_cost = avgc, run_deficit_value = dv, run_fifo_last = flast
     where tenant_id = p_tenant and move_id = p_move;
  end if;
  -- cost_revisions: a replay (p_run > 0) that changes the result of an ALREADY POSTED move (not a move of the
  -- document whose backdated post started the replay: erp.recost_doc)
  if p_run > 0 and mv.document_id::text is distinct from nullif(current_setting('erp.recost_doc', true), '') then
    if (nw_a, nw_f) is distinct from (mv.value_avg, mv.value_fifo) then
      select * into nw from erp.stock_moves where tenant_id = p_tenant and move_id = p_move;
      insert into erp.cost_revisions (tenant_id, run_id, reason, move_id, document_id, item_id, old_value_avg, new_value_avg, old_value_fifo, new_value_fifo,
                                      old_unit_cost_avg, new_unit_cost_avg, old_unit_cost_fifo, new_unit_cost_fifo)
      values (p_tenant, p_run, coalesce(nullif(current_setting('erp.recost_reason', true), ''), 'recost'), p_move, mv.document_id, mv.item_id,
              mv.value_avg, nw.value_avg, mv.value_fifo, nw.value_fifo, mv.unit_cost_avg, nw.unit_cost_avg, mv.unit_cost_fifo, nw.unit_cost_fifo);
    end if;
    if old_corr is not null and ((old_corr ->> 'value_avg')::numeric, (old_corr ->> 'value_fifo')::numeric) is distinct from (k_a, k_f) then
      insert into erp.cost_revisions (tenant_id, run_id, reason, move_id, document_id, item_id, old_value_avg, new_value_avg, old_value_fifo, new_value_fifo)
      values (p_tenant, p_run, coalesce(nullif(current_setting('erp.recost_reason', true), ''), 'recost'), (old_corr ->> 'move_id')::bigint, mv.document_id, mv.item_id,
              (old_corr ->> 'value_avg')::numeric, k_a, (old_corr ->> 'value_fifo')::numeric, k_f);
    end if;
  end if;
  if in_replay then
    perform erp.replay_put(q, va, vf, dv, avgc, flast, p_move);
  else
    update erp.item_costs set qty = q, value_avg = va, avg_cost = avgc, value_fifo = vf, deficit_value = dv, fifo_last_cost = flast, last_move_id = p_move, updated_at = now()
     where tenant_id = p_tenant and item_id = mv.item_id and lot_id = mv.lot_id;
  end if;
  perform set_config('erp.recost', 'off', true);
end $$;

-- ---------------------------------------------------------------------
-- 5. erp.cost_replay: rebuild one item (+ lot) from a date. State before the date = the running state of the last
--    move before it; FIFO layers are put back as they were (consumption of later moves returned, layers of later
--    moves voided); then every later move is costed again in (move_date, move_id) order by erp.cost_move. A move
--    and its reversal (cancelled document) are skipped as a pair: their values stay opposite. Returns the number
--    of moves costed. The caller holds the item lock. (T13 adds the queue, cost_revisions and backdating.)
-- ---------------------------------------------------------------------
drop function if exists erp.cost_replay(uuid, uuid, uuid, date);
create or replace function erp.cost_replay(p_tenant uuid, p_item uuid, p_lot uuid, p_from date, p_reason text default 'recost') returns int
language plpgsql security definer set search_path = '' as $$
declare run bigint := nextval('erp.cost_run_seq'); prev erp.stock_moves; m erp.stock_moves; n int := 0; lock_d date; rs erp.item_costs; qd date;
begin
  -- F2-04: an item waiting in the recost queue from an EARLIER date has stale running states after that date: start
  -- there (the callers send such items to the queue instead when the replay would be large)
  select q.from_date into qd from erp.recost_queue q where q.tenant_id = p_tenant and q.item_id = p_item and q.lot_id = p_lot;
  if qd < p_from then p_from := qd; end if;
  select st.lock_date into lock_d from erp.tenant_settings st where st.tenant_id = p_tenant;
  if lock_d is not null and p_from <= lock_d then
    perform erp.err('ERP_LOCKED_PERIOD', format('Costs on or before the lock date %s are never recalculated.', to_char(lock_d, 'DD/MM/YYYY')));
  end if;
  perform set_config('erp.recost_reason', p_reason, true);
  perform set_config('erp.recost', 'on', true);
  select * into prev from erp.stock_moves x
   where x.tenant_id = p_tenant and x.item_id = p_item and x.lot_id = p_lot and x.move_date < p_from and x.kind <> 'value_only'
   order by x.move_date desc, x.move_id desc limit 1;
  perform erp.item_cost_row(p_tenant, p_item, p_lot);
  perform erp.replay_put(coalesce(prev.run_qty, 0), coalesce(prev.run_value_avg, 0), coalesce(prev.run_value_fifo, 0), coalesce(prev.run_deficit_value, 0),
                         coalesce(prev.run_avg_cost, 0), prev.run_fifo_last, prev.move_id);
  perform set_config('erp.replay_key', erp.replay_key(p_tenant, p_item, p_lot), true);
  perform set_config('erp.replay_head', '', true);
  -- layers as of before the date: give back what later moves took (their current run), void the layers they created
  update erp.stock_layers l set qty_left = l.qty_left + c.qty, value_left = l.value_left + c.value
    from (select ml.layer_id, sum(ml.qty) qty, sum(ml.value) value
            from erp.stock_moves x join erp.stock_move_layers ml on ml.tenant_id = x.tenant_id and ml.move_id = x.move_id and ml.run_id = x.layer_run
           where x.tenant_id = p_tenant and x.item_id = p_item and x.lot_id = p_lot and x.move_date >= p_from
           group by ml.layer_id) c
   where l.tenant_id = p_tenant and l.layer_id = c.layer_id and l.void_run is null;
  update erp.stock_layers l set void_run = run, qty_left = 0, value_left = 0
   where l.tenant_id = p_tenant and l.item_id = p_item and l.lot_id = p_lot and l.void_run is null
     and l.move_id in (select x.move_id from erp.stock_moves x where x.tenant_id = p_tenant and x.item_id = p_item and x.lot_id = p_lot and x.move_date >= p_from);
  for m in select * from erp.stock_moves x
            where x.tenant_id = p_tenant and x.item_id = p_item and x.lot_id = p_lot and x.move_date >= p_from and x.kind <> 'value_only'
            order by x.move_date, x.move_id loop
    if m.kind = 'reversal' or exists (select 1 from erp.stock_moves r where r.tenant_id = p_tenant and r.reverses_move_id = m.move_id) then
      -- a cancelled pair: no effect; its running state = the state at its place
      rs := erp.replay_get();
      update erp.stock_moves x set layer_run = case when m.qty_base < 0 and m.kind = 'normal' then run else x.layer_run end,
             run_qty = rs.qty, run_value_avg = rs.value_avg, run_value_fifo = rs.value_fifo, run_avg_cost = rs.avg_cost, run_deficit_value = rs.deficit_value,
             run_fifo_last = rs.fifo_last_cost
       where x.tenant_id = p_tenant and x.move_id = m.move_id;
      continue;
    end if;
    perform erp.cost_move(p_tenant, m.move_id, run);
    perform set_config('erp.recost', 'on', true);
    n := n + 1;
  end loop;
  -- the carried state becomes the item's cost row (once); the pending head layer is written
  perform erp.replay_head_flush(p_tenant);
  rs := erp.replay_get();
  update erp.item_costs set qty = rs.qty, value_avg = rs.value_avg, avg_cost = rs.avg_cost, value_fifo = rs.value_fifo, deficit_value = rs.deficit_value,
         fifo_last_cost = rs.fifo_last_cost, last_move_id = rs.last_move_id, updated_at = now()
   where tenant_id = p_tenant and item_id = p_item and lot_id = p_lot;
  perform set_config('erp.replay_key', '', true);
  perform set_config('erp.replay_state', '', true);
  perform set_config('erp.recost', 'off', true);
  delete from erp.recost_queue q where q.tenant_id = p_tenant and q.item_id = p_item and q.lot_id = p_lot and q.from_date >= p_from;
  -- the documents of the replayed moves get their line / total costs again
  perform erp.doc_costs_refresh(p_tenant, x.document_id)
     from (select distinct m2.document_id from erp.stock_moves m2
            where m2.tenant_id = p_tenant and m2.item_id = p_item and m2.lot_id = p_lot and m2.move_date >= p_from) x;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 6. Hooks called by E130 for types that move stock
-- ---------------------------------------------------------------------
-- per-item advisory locks in ascending item id (02 lock order: series, items, balances)
create or replace function erp.stock_lock(p_tenant uuid, p_doc uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare it uuid;
begin
  for it in select distinct l.item_id from erp.document_lines l where l.tenant_id = p_tenant and l.document_id = p_doc and l.item_id is not null order by l.item_id loop
    perform pg_advisory_xact_lock(hashtextextended('erp.item:' || p_tenant || ':' || it, 0));
  end loop;
end $$;

-- the quantity effect of a document per (warehouse, item): + in / - out (service items have none)
-- T16: a 'transfer' type (TRF dispatch) also puts the quantity into the tenant's transit warehouse
create or replace function erp.stock_effect(p_tenant uuid, p_doc uuid) returns table (warehouse_id uuid, item_id uuid, qty numeric)
language sql stable security definer set search_path = '' as $$
  select x.warehouse_id, x.item_id, sum(x.qty) from (
    select d.warehouse_id, l.item_id, l.qty_base * dt.stock_sign qty
      from erp.documents d join erp.doc_types dt on dt.doc_type = d.doc_type
      join erp.document_lines l on l.tenant_id = d.tenant_id and l.document_id = d.document_id
      join erp.items i on i.tenant_id = l.tenant_id and i.item_id = l.item_id and i.kind <> 'service'
     where d.tenant_id = p_tenant and d.document_id = p_doc and dt.stock_sign <> 0
    union all
    select tw.warehouse_id, l.item_id, l.qty_base
      from erp.documents d join erp.doc_types dt on dt.doc_type = d.doc_type and dt.cost_rule = 'transfer'
      join erp.warehouses tw on tw.tenant_id = d.tenant_id and tw.kind = 'in_transit'
      join erp.document_lines l on l.tenant_id = d.tenant_id and l.document_id = d.document_id
      join erp.items i on i.tenant_id = l.tenant_id and i.item_id = l.item_id and i.kind <> 'service'
     where d.tenant_id = p_tenant and d.document_id = p_doc) x
   group by x.warehouse_id, x.item_id
$$;

-- negative-stock check (02, owner decision "allowed with a warning"): warnings W_STOCK_NEGATIVE for every (warehouse,
-- item) whose available quantity (on hand - reserved) would go below zero; ERP_STOCK_NEGATIVE (blocked) for the
-- transit warehouse and when the tenant setting is 'block'. Runs under the item locks.
create or replace function erp.stock_check(p_tenant uuid, p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r record; warn jsonb := '[]'; mode text;
begin
  select s.negative_stock into mode from erp.tenant_settings s where s.tenant_id = p_tenant;
  for r in select e.warehouse_id, e.item_id, e.qty, w.code wh_code, w.kind wh_kind, i.code item_code,
                  coalesce(b.qty, 0) - coalesce(b.reserved, 0) + e.qty qty_after
             from erp.stock_effect(p_tenant, p_doc) e
             join erp.warehouses w on w.tenant_id = p_tenant and w.warehouse_id = e.warehouse_id
             join erp.items i on i.tenant_id = p_tenant and i.item_id = e.item_id
             left join erp.stock_balances b on b.tenant_id = p_tenant and b.warehouse_id = e.warehouse_id and b.item_id = e.item_id
                                           and b.lot_id = '00000000-0000-0000-0000-000000000000'
            where e.qty < 0 order by i.code, w.code loop
    if r.qty_after < 0 then
      if r.wh_kind = 'in_transit' or mode = 'block' then
        perform erp.err('ERP_STOCK_NEGATIVE', format('%s in %s would go to %s: negative stock is not allowed here.', r.item_code, r.wh_code, r.qty_after),
                        jsonb_build_array(jsonb_build_object('code', 'W_STOCK_NEGATIVE', 'item_id', r.item_id, 'item_code', r.item_code, 'warehouse_id', r.warehouse_id,
                                                             'warehouse_code', r.wh_code, 'qty_after', r.qty_after)));
      end if;
      warn := warn || jsonb_build_object('code', 'W_STOCK_NEGATIVE', 'item_id', r.item_id, 'item_code', r.item_code, 'warehouse_id', r.warehouse_id,
                                         'warehouse_code', r.wh_code, 'qty_after', r.qty_after);
    end if;
  end loop;
  return warn;
end $$;

-- the same check for a CANCEL (F2-05): reversing an inbound document takes its quantity out again. Blocked
-- (ERP_STOCK_NEGATIVE) for the transit warehouse and under 'block'; under 'warn' the cancel goes ahead and the
-- warnings are returned and audited (the negative-stock alert follows from erp.stock_alerts).
create or replace function erp.stock_cancel_check(p_tenant uuid, p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r record; warn jsonb := '[]'; mode text;
begin
  select s.negative_stock into mode from erp.tenant_settings s where s.tenant_id = p_tenant;
  for r in select e.warehouse_id, e.item_id, w.code wh_code, w.kind wh_kind, i.code item_code,
                  coalesce(b.qty, 0) - coalesce(b.reserved, 0) - e.qty qty_after
             from erp.stock_effect(p_tenant, p_doc) e
             join erp.warehouses w on w.tenant_id = p_tenant and w.warehouse_id = e.warehouse_id
             join erp.items i on i.tenant_id = p_tenant and i.item_id = e.item_id
             left join erp.stock_balances b on b.tenant_id = p_tenant and b.warehouse_id = e.warehouse_id and b.item_id = e.item_id
                                           and b.lot_id = '00000000-0000-0000-0000-000000000000'
            where e.qty > 0 order by i.code, w.code loop
    if r.qty_after < 0 then
      if r.wh_kind = 'in_transit' or mode = 'block' then
        perform erp.err('ERP_STOCK_NEGATIVE', format('Cancelling would take %s in %s to %s: negative stock is not allowed here.', r.item_code, r.wh_code, r.qty_after),
                        jsonb_build_array(jsonb_build_object('code', 'W_STOCK_NEGATIVE', 'item_id', r.item_id, 'item_code', r.item_code, 'warehouse_id', r.warehouse_id,
                                                             'warehouse_code', r.wh_code, 'qty_after', r.qty_after)));
      end if;
      warn := warn || jsonb_build_object('code', 'W_STOCK_NEGATIVE', 'item_id', r.item_id, 'item_code', r.item_code, 'warehouse_id', r.warehouse_id,
                                         'warehouse_code', r.wh_code, 'qty_after', r.qty_after);
    end if;
  end loop;
  return warn;
end $$;

-- balance of (warehouse, item, lot) += qty; negative_since kept while the quantity is below zero
create or replace function erp.balance_add(p_tenant uuid, p_wh uuid, p_item uuid, p_lot uuid, p_qty numeric, p_move bigint) returns numeric
language plpgsql security definer set search_path = '' as $$
declare v numeric;
begin
  insert into erp.stock_balances as b (tenant_id, warehouse_id, item_id, lot_id, qty, negative_since, negative_move_id, last_move_id)
  values (p_tenant, p_wh, p_item, p_lot, p_qty, case when p_qty < 0 then now() end, case when p_qty < 0 then p_move end, p_move)
  on conflict (tenant_id, warehouse_id, item_id, lot_id) do update
    set qty = b.qty + excluded.qty,
        negative_since = case when b.qty + excluded.qty >= 0 then null else coalesce(b.negative_since, now()) end,
        negative_move_id = case when b.qty + excluded.qty >= 0 then null else coalesce(b.negative_move_id, excluded.last_move_id) end,
        last_move_id = excluded.last_move_id, updated_at = now()
  returning qty into v;
  return v;
end $$;

-- number of moves of an item after a date, counted up to p_cap + 1 (enough to compare with the inline limit)
create or replace function erp.later_moves(p_tenant uuid, p_item uuid, p_date date, p_cap bigint) returns bigint
language sql stable security definer set search_path = '' as $$
  select count(*) from (select 1 from erp.stock_moves x where x.tenant_id = p_tenant and x.item_id = p_item and x.move_date > p_date limit p_cap + 1) z
$$;
-- the item waits in the recost queue from a date before p_date
create or replace function erp.recost_queued_before(p_tenant uuid, p_item uuid, p_date date) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from erp.recost_queue q where q.tenant_id = p_tenant and q.item_id = p_item and q.lot_id = '00000000-0000-0000-0000-000000000000'
                    and q.from_date < p_date)
$$;

-- the costing of NEW moves of one item dated p_date (the caller holds the item lock and inserted them, in move id
-- order): no later move -> each is costed now; up to the inline limit of later moves (and the item not queued from an
-- earlier date) -> the item is replayed from p_date (backdating); else each is costed now at the current state and
-- the item is queued for the job (F2-04 / F2-07). One place for this decision: stock_post and the TRF receipt (E160).
create or replace function erp.stock_cost_new(p_tenant uuid, p_doc uuid, p_item uuid, p_date date, p_moves bigint[]) returns void
language plpgsql security definer set search_path = '' as $$
declare mv bigint; nlater bigint; lim bigint := coalesce(erp.try_numeric(nullif(current_setting('erp.recost_inline_limit', true), '')), 2000);
begin
  nlater := erp.later_moves(p_tenant, p_item, p_date, lim);
  if nlater = 0 then
    foreach mv in array p_moves loop perform erp.cost_move(p_tenant, mv, 0); end loop;
  elsif nlater <= lim and not erp.recost_queued_before(p_tenant, p_item, p_date) then
    perform set_config('erp.recost_doc', p_doc::text, true);
    perform erp.cost_replay(p_tenant, p_item, '00000000-0000-0000-0000-000000000000', p_date, 'backdate');
    perform set_config('erp.recost_doc', '', true);
  else
    -- too many later moves for this transaction: cost it now at the current state, the job replays the item
    foreach mv in array p_moves loop perform erp.cost_move(p_tenant, mv, 0); end loop;
    insert into erp.recost_queue as q (tenant_id, item_id, lot_id, from_date, reason) values (p_tenant, p_item, '00000000-0000-0000-0000-000000000000', p_date, 'backdate')
    on conflict (tenant_id, item_id, lot_id) do update set from_date = least(q.from_date, excluded.from_date);
  end if;
end $$;

-- posting: one normal move per stock line (line order), balances, costing, line / document cost, last purchase price.
-- A document dated before an item's later moves is costed again from its date (backdating; recost logging: T13).
-- T16: a 'transfer' type (TRF dispatch) writes TWO moves per line: out of its warehouse and into the tenant's transit
-- warehouse (src_move_id = the out move), both cost-neutral (erp.cost_move).
create or replace function erp.stock_post(p_tenant uuid, p_doc uuid, p_warnings jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare d erp.documents; dt erp.doc_types; l record; mv bigint; mv2 bigint; src bigint; tw uuid; fb numeric;
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc;
  select * into dt from erp.doc_types where doc_type = d.doc_type;
  if dt.cost_rule = 'transfer' then
    select w.warehouse_id into tw from erp.warehouses w where w.tenant_id = p_tenant and w.kind = 'in_transit';
    if tw is null then perform erp.err('ERP_VALIDATION', 'The organisation has no transit warehouse.'); end if;
  end if;
  for l in select x.*, i.kind item_kind from erp.document_lines x join erp.items i on i.tenant_id = x.tenant_id and i.item_id = x.item_id
            where x.tenant_id = p_tenant and x.document_id = p_doc and i.kind <> 'service' order by x.line_no loop
    src := null;
    if l.source_line_id is not null and dt.cost_rule in ('source_out', 'source_in') then
      select m.move_id into src from erp.stock_moves m
       where m.tenant_id = p_tenant and m.line_id = l.source_line_id and m.kind = 'normal'
         and not exists (select 1 from erp.stock_moves r where r.tenant_id = p_tenant and r.reverses_move_id = m.move_id)
       order by m.move_id limit 1;
    end if;
    fb := coalesce((select i.last_purchase_price from erp.items i where i.tenant_id = p_tenant and i.item_id = l.item_id), 0);
    insert into erp.stock_moves (tenant_id, document_id, line_id, warehouse_id, item_id, move_date, kind, qty_base, cost_rule, in_value, src_move_id, fallback_cost)
    values (p_tenant, p_doc, l.line_id, d.warehouse_id, l.item_id, d.doc_date, 'normal', l.qty_base * dt.stock_sign, dt.cost_rule,
            case when dt.cost_rule in ('line', 'line_or_current') and l.unit_price is not null then l.net end, src, fb)
    returning move_id into mv;
    perform erp.balance_add(p_tenant, d.warehouse_id, l.item_id, '00000000-0000-0000-0000-000000000000', l.qty_base * dt.stock_sign, mv);
    if dt.cost_rule = 'transfer' then
      insert into erp.stock_moves (tenant_id, document_id, line_id, warehouse_id, item_id, move_date, kind, qty_base, cost_rule, src_move_id, fallback_cost)
      values (p_tenant, p_doc, l.line_id, tw, l.item_id, d.doc_date, 'normal', l.qty_base, 'transfer', mv, fb)
      returning move_id into mv2;
      perform erp.balance_add(p_tenant, tw, l.item_id, '00000000-0000-0000-0000-000000000000', l.qty_base, mv2);
      perform erp.stock_cost_new(p_tenant, p_doc, l.item_id, d.doc_date, array[mv, mv2]);
    else
      perform erp.stock_cost_new(p_tenant, p_doc, l.item_id, d.doc_date, array[mv]);
    end if;
    if dt.area = 'purchasing' and dt.stock_sign > 0 and l.qty_base > 0 and l.unit_price is not null then
      update erp.items set last_purchase_price = round(l.net / l.qty_base, 6) where tenant_id = p_tenant and item_id = l.item_id;
    end if;
  end loop;
  perform erp.doc_costs_refresh(p_tenant, p_doc);
  perform erp.stock_alerts(p_tenant, p_doc);
end $$;

-- in-app alerts after a posting / cancel (02 "Negative stock" 2; 01 G "low stock"): ONE open alert per (warehouse,
-- item) and kind, for the warehouse's branch; it resolves itself when the balance is back (>= 0 / >= min level)
create or replace function erp.stock_alerts(p_tenant uuid, p_doc uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record; d erp.documents;
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc;
  for r in select b.warehouse_id, b.item_id, b.qty, w.branch_id, w.code wh_code, i.code item_code, i.min_level
             from (select distinct m.warehouse_id, m.item_id from erp.stock_moves m where m.tenant_id = p_tenant and m.document_id = p_doc and m.qty_base <> 0) x
             join erp.stock_balances b on b.tenant_id = p_tenant and b.warehouse_id = x.warehouse_id and b.item_id = x.item_id and b.lot_id = '00000000-0000-0000-0000-000000000000'
             join erp.warehouses w on w.tenant_id = p_tenant and w.warehouse_id = b.warehouse_id and w.kind = 'normal'   -- never for transit (T16)
             join erp.items i on i.tenant_id = p_tenant and i.item_id = b.item_id loop
    if r.qty < 0 then
      perform erp.alert_raise(p_tenant, 'negative_stock', 'warning', 'alert.negative_stock',
                              jsonb_build_object('item_id', r.item_id, 'item_code', r.item_code, 'warehouse_id', r.warehouse_id, 'warehouse_code', r.wh_code,
                                                 'qty', r.qty, 'document_id', p_doc, 'doc_no', d.doc_no),
                              r.branch_id, 'stock_balances', r.warehouse_id || ':' || r.item_id, 'negative_stock:' || r.warehouse_id || ':' || r.item_id);
    else
      update erp.alerts set resolved_at = now() where tenant_id = p_tenant and dedupe_key = 'negative_stock:' || r.warehouse_id || ':' || r.item_id and resolved_at is null;
    end if;
    if r.min_level is not null and r.qty >= 0 and r.qty < r.min_level then
      perform erp.alert_raise(p_tenant, 'low_stock', 'info', 'alert.low_stock',
                              jsonb_build_object('item_id', r.item_id, 'item_code', r.item_code, 'warehouse_id', r.warehouse_id, 'warehouse_code', r.wh_code,
                                                 'qty', r.qty, 'min_level', r.min_level),
                              r.branch_id, 'stock_balances', r.warehouse_id || ':' || r.item_id, 'low_stock:' || r.warehouse_id || ':' || r.item_id);
    else
      update erp.alerts set resolved_at = now() where tenant_id = p_tenant and dedupe_key = 'low_stock:' || r.warehouse_id || ':' || r.item_id and resolved_at is null;
    end if;
  end loop;
end $$;

-- line cost = the official value of its normal move (absolute) / qty; document total_cost = sum of the lines
create or replace function erp.doc_costs_refresh(p_tenant uuid, p_doc uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('erp.recost', 'on', true);
  update erp.document_lines l
     set cost_value = abs(case m.official when 'avg' then m.value_avg else m.value_fifo end),
         unit_cost = case m.official when 'avg' then m.unit_cost_avg else m.unit_cost_fifo end
    from erp.stock_moves m
   where l.tenant_id = p_tenant and l.document_id = p_doc and m.tenant_id = p_tenant and m.line_id = l.line_id and m.kind = 'normal' and m.document_id = p_doc
     and (m.cost_rule <> 'transfer' or m.src_move_id is null)   -- T16: a TRF line costs as its dispatch (out) move
     and (l.cost_value is distinct from abs(case m.official when 'avg' then m.value_avg else m.value_fifo end)
          or l.unit_cost is distinct from case m.official when 'avg' then m.unit_cost_avg else m.unit_cost_fifo end);
  update erp.documents d set total_cost = (select coalesce(sum(l.cost_value), 0) from erp.document_lines l where l.tenant_id = p_tenant and l.document_id = p_doc)
   where d.tenant_id = p_tenant and d.document_id = p_doc
     and d.total_cost is distinct from (select coalesce(sum(l.cost_value), 0) from erp.document_lines l where l.tenant_id = p_tenant and l.document_id = p_doc);
  perform set_config('erp.recost', 'off', true);
end $$;

-- cancel: one reversing move per move of the document (same date, warehouse, opposite quantity and values), balances
-- back, then every item is costed again from the document date (the pair is skipped: as if it never existed)
create or replace function erp.stock_cancel(p_tenant uuid, p_doc uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare m erp.stock_moves; rv bigint; it record; lim bigint := coalesce(erp.try_numeric(nullif(current_setting('erp.recost_inline_limit', true), '')), 2000);
        ic erp.item_costs;
begin
  for m in select * from erp.stock_moves x where x.tenant_id = p_tenant and x.document_id = p_doc and x.kind in ('normal', 'value_only')
              and not exists (select 1 from erp.stock_moves r where r.tenant_id = p_tenant and r.reverses_move_id = x.move_id) order by x.move_id loop
    insert into erp.stock_moves (tenant_id, document_id, line_id, warehouse_id, item_id, lot_id, move_date, kind, qty_base, cost_rule, reverses_move_id,
                                 unit_cost_avg, unit_cost_fifo, value_avg, value_fifo, official, cost_provisional)
    values (p_tenant, p_doc, m.line_id, m.warehouse_id, m.item_id, m.lot_id, m.move_date, case when m.kind = 'value_only' then 'value_only' else 'reversal' end,
            -m.qty_base, 'reversal', m.move_id, m.unit_cost_avg, m.unit_cost_fifo, -m.value_avg, -m.value_fifo, m.official, m.cost_provisional)
    returning move_id into rv;
    if m.qty_base <> 0 then perform erp.balance_add(p_tenant, m.warehouse_id, m.item_id, m.lot_id, -m.qty_base, rv); end if;
  end loop;
  for it in select x.item_id, x.lot_id, min(x.move_date) d,
                  sum(x.qty_base) filter (where x.kind in ('reversal', 'value_only') and x.reverses_move_id is not null) dq,
                  sum(x.value_avg) filter (where x.kind in ('reversal', 'value_only') and x.reverses_move_id is not null) dva,
                  sum(x.value_fifo) filter (where x.kind in ('reversal', 'value_only') and x.reverses_move_id is not null) dvf
             from erp.stock_moves x where x.tenant_id = p_tenant and x.document_id = p_doc
             group by x.item_id, x.lot_id order by x.item_id loop
    if erp.later_moves(p_tenant, it.item_id, it.d, lim) <= lim and not erp.recost_queued_before(p_tenant, it.item_id, it.d) then
      perform erp.cost_replay(p_tenant, it.item_id, it.lot_id, it.d, 'cancel');
    else
      -- F2-04: too many later moves (or already queued): the cost row follows the reversal by its values now, the
      -- job replays the item from the document date (same rule as a large backdated post, 02 "Backdated documents")
      ic := erp.item_cost_row(p_tenant, it.item_id, it.lot_id);
      update erp.item_costs set qty = ic.qty + it.dq, value_avg = ic.value_avg + it.dva, value_fifo = ic.value_fifo + it.dvf,
             avg_cost = case when ic.qty + it.dq > 0 then round((ic.value_avg + it.dva) / (ic.qty + it.dq), 6) else ic.avg_cost end, updated_at = now()
       where tenant_id = p_tenant and item_id = it.item_id and lot_id = it.lot_id;
      insert into erp.recost_queue as q (tenant_id, item_id, lot_id, from_date, reason) values (p_tenant, it.item_id, it.lot_id, it.d, 'cancel')
      on conflict (tenant_id, item_id, lot_id) do update set from_date = least(q.from_date, excluded.from_date);
    end if;
  end loop;
  perform erp.stock_alerts(p_tenant, p_doc);
end $$;

-- E130's doc_value REDEFINED (header): approval value of a stock document = lines with a cost price at their net,
-- other lines at the current official cost of the item
create or replace function erp.doc_value(p_tenant uuid, p_doc uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(case when dt.price_kind <> 'none' and l.unit_price is not null then abs(l.net)
                           when l.item_id is not null and dt.stock_sign <> 0 then
                             round(l.qty_base * erp.current_cost(p_tenant, l.item_id, '00000000-0000-0000-0000-000000000000', erp.item_method(p_tenant, l.item_id, d.doc_date)), 2)
                           else abs(l.net) end), 0)
    from erp.documents d join erp.doc_types dt on dt.doc_type = d.doc_type
    join erp.document_lines l on l.tenant_id = d.tenant_id and l.document_id = d.document_id
   where d.tenant_id = p_tenant and d.document_id = p_doc
$$;

-- ---------------------------------------------------------------------
-- 7. Integrity (02 "Integrity job"; the nightly job and its alert: T13). Problems as a jsonb array; empty = sound:
--    balance = sum of moves per (warehouse, item, lot); item_costs qty / value_avg / value_fifo = sums of the ledger;
--    FIFO layers left - deficit = on hand and their value - deficit value = value_fifo; qty 0 means value 0.
-- ---------------------------------------------------------------------
create or replace function erp.stock_integrity(p_tenant uuid, p_item uuid default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(p), '[]'::jsonb) from (
    select jsonb_build_object('check', 'balance', 'warehouse_id', coalesce(b.warehouse_id, s.warehouse_id), 'item_id', coalesce(b.item_id, s.item_id),
                              'balance', b.qty, 'ledger', s.qty) p
      from (select * from erp.stock_balances x where x.tenant_id = p_tenant and (p_item is null or x.item_id = p_item)) b
      full join (select m.warehouse_id, m.item_id, m.lot_id, sum(m.qty_base) qty from erp.stock_moves m
                  where m.tenant_id = p_tenant and (p_item is null or m.item_id = p_item) group by 1, 2, 3) s
        on s.warehouse_id = b.warehouse_id and s.item_id = b.item_id and s.lot_id = b.lot_id
     where coalesce(b.qty, 0) <> coalesce(s.qty, 0)
    union all
    select jsonb_build_object('check', 'cost', 'item_id', coalesce(c.item_id, s.item_id), 'qty', c.qty, 'ledger_qty', s.qty, 'value_avg', c.value_avg, 'ledger_avg', s.va,
                              'value_fifo', c.value_fifo, 'ledger_fifo', s.vf)
      from (select * from erp.item_costs x where x.tenant_id = p_tenant and (p_item is null or x.item_id = p_item)) c
      full join (select m.item_id, m.lot_id, sum(m.qty_base) qty, sum(m.value_avg) va, sum(m.value_fifo) vf from erp.stock_moves m
                  where m.tenant_id = p_tenant and (p_item is null or m.item_id = p_item) group by 1, 2) s
        on s.item_id = c.item_id and s.lot_id = c.lot_id
     where (coalesce(c.qty, 0) <> coalesce(s.qty, 0) or coalesce(c.value_avg, 0) <> coalesce(s.va, 0) or coalesce(c.value_fifo, 0) <> coalesce(s.vf, 0)
            or (coalesce(c.qty, 0) = 0 and (coalesce(c.value_avg, 0) <> 0 or coalesce(c.value_fifo, 0) <> 0)))
       -- F2-04: an item waiting for the recost job is checked after the job (its cost state is provisional until then)
       and not exists (select 1 from erp.recost_queue q where q.tenant_id = p_tenant and q.item_id = coalesce(c.item_id, s.item_id) and q.lot_id = coalesce(c.lot_id, s.lot_id))
    union all
    select jsonb_build_object('check', 'layers', 'item_id', c.item_id, 'qty', c.qty, 'layers_qty', coalesce(l.q, 0), 'deficit_value', c.deficit_value,
                              'value_fifo', c.value_fifo, 'layers_value', coalesce(l.v, 0))
      from erp.item_costs c
      left join (select x.item_id, x.lot_id, sum(x.qty_left) q, sum(x.value_left) v from erp.stock_layers x
                  where x.tenant_id = p_tenant and x.void_run is null and (p_item is null or x.item_id = p_item) group by 1, 2) l
        on l.item_id = c.item_id and l.lot_id = c.lot_id
     where c.tenant_id = p_tenant and (p_item is null or c.item_id = p_item)
       and (coalesce(l.q, 0) - greatest(-c.qty, 0) <> c.qty or coalesce(l.v, 0) - c.deficit_value <> c.value_fifo
            or (c.qty > 0 and c.deficit_value <> 0) or (c.qty >= 0 and coalesce(l.q, 0) <> c.qty))
       and not exists (select 1 from erp.recost_queue q where q.tenant_id = p_tenant and q.item_id = c.item_id and q.lot_id = c.lot_id)
  ) x
$$;

-- ---------------------------------------------------------------------
-- 7b. Recost queue, jobs (T13). The jobs run as the database owner, scheduled on live (STATE.md, run list):
--     */5 min erp.recost_job(); nightly erp.integrity_job(). The owner can also run the queue from the page.
-- ---------------------------------------------------------------------
-- recost one queued item (lock order: the item lock, then its queue row), from its queued date
create or replace function erp.recost_item(p_tenant uuid, p_item uuid, p_lot uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare q erp.recost_queue; n int;
begin
  perform pg_advisory_xact_lock(hashtextextended('erp.item:' || p_tenant || ':' || p_item, 0));
  select * into q from erp.recost_queue x where x.tenant_id = p_tenant and x.item_id = p_item and x.lot_id = p_lot for update;
  if q.item_id is null then return 0; end if;
  n := erp.cost_replay(p_tenant, p_item, p_lot, q.from_date, 'queue');
  delete from erp.recost_queue x where x.tenant_id = p_tenant and x.item_id = p_item and x.lot_id = p_lot;
  return n;
end $$;

-- run queued items (F2-02): the queue rows are read WITHOUT a row lock and each item is taken with a TRY of its item
-- lock (an item being posted is skipped and stays queued): the lock order item -> queue row is the posting path's,
-- so a job never deadlocks with a backdated post. One transaction holds the locks of the items it recosted until it
-- ends, so it stops starting new items after p_budget_ms (at least one item per run).
create or replace function erp.recost_batch(p_tenant uuid, p_max int, p_budget_ms int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; items int := 0; moves int := 0; skipped int := 0; t0 timestamptz := clock_timestamp();
begin
  for r in select x.tenant_id, x.item_id, x.lot_id from erp.recost_queue x where p_tenant is null or x.tenant_id = p_tenant
            order by x.queued_at, x.tenant_id, x.item_id limit greatest(coalesce(p_max, 50), 1) loop
    exit when items > 0 and clock_timestamp() - t0 > make_interval(secs => greatest(coalesce(p_budget_ms, 3000), 0) / 1000.0);
    if not pg_try_advisory_xact_lock(hashtextextended('erp.item:' || r.tenant_id || ':' || r.item_id, 0)) then skipped := skipped + 1; continue; end if;
    moves := moves + erp.recost_item(r.tenant_id, r.item_id, r.lot_id);
    items := items + 1;
  end loop;
  return jsonb_build_object('items', items, 'moves', moves, 'skipped', skipped);
end $$;

-- the 5-minute job: queued items of all tenants, oldest first (a new signature since F2: the time budget)
drop function if exists erp.recost_job(int);
create or replace function erp.recost_job(p_max int default 50, p_budget_ms int default 3000) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('erp.actor', 'recost job', true);
  return erp.recost_batch(null, p_max, p_budget_ms);
end $$;

-- the nightly integrity job (02): every tenant's ledger against balances, cost state and layers; one open owner
-- alert 'integrity' (critical) per tenant while problems exist, resolved when the check is clean again. A queue row
-- older than one hour is reported too (F2-04: the recost job is not running, e.g. pg_cron not scheduled).
create or replace function erp.integrity_job() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t uuid; probs jsonb; bad int := 0; n int := 0;
begin
  perform set_config('erp.actor', 'integrity job', true);
  for t in select tenant_id from erp.tenants where active order by tenant_id loop
    n := n + 1;
    probs := erp.stock_integrity(t)
          || coalesce((select jsonb_agg(jsonb_build_object('check', 'recost_stale', 'item_id', q.item_id, 'from_date', q.from_date, 'queued_at', q.queued_at))
                         from erp.recost_queue q where q.tenant_id = t and q.queued_at < now() - interval '1 hour'), '[]'::jsonb);
    -- T16 (E160): transit = the open transfers' quantities, zero for every closed transfer, never negative
    if to_regprocedure('erp.trf_integrity(uuid)') is not null then probs := probs || erp.trf_integrity(t); end if;
    if jsonb_array_length(probs) > 0 then
      bad := bad + 1;
      perform erp.alert_raise(t, 'integrity', 'critical', 'alert.integrity', jsonb_build_object('problems', jsonb_array_length(probs), 'sample', probs -> 0),
                              null, null, null, 'integrity');
    else
      update erp.alerts set resolved_at = now() where tenant_id = t and dedupe_key = 'integrity' and resolved_at is null;
    end if;
  end loop;
  return jsonb_build_object('tenants', n, 'with_problems', bad);
end $$;

-- recost_status: what waits for the recost job (reports show "recost pending" while rows exist)
create or replace function erp_api.recost_status() returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members;
begin
  m := erp.require_member();
  perform erp.require_cap('stock.read');
  return jsonb_build_object('pending', (select count(*) from erp.recost_queue q where q.tenant_id = m.tenant_id),
                            'oldest_from_date', (select min(q.from_date) from erp.recost_queue q where q.tenant_id = m.tenant_id),
                            'items', coalesce((select jsonb_agg(jsonb_build_object('item_id', q.item_id, 'item_code', i.code, 'from_date', q.from_date, 'queued_at', q.queued_at)
                                                                order by q.queued_at)
                                                 from (select * from erp.recost_queue x where x.tenant_id = m.tenant_id order by x.queued_at limit 50) q
                                                 join erp.items i on i.tenant_id = q.tenant_id and i.item_id = q.item_id), '[]'::jsonb));
end $$;

-- recost_run: the owner runs up to p_limit queued items of its tenant now (same work as the job)
create or replace function erp_api.recost_run(p_limit int, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; r jsonb; items int := 0; moves int := 0; res jsonb;
begin
  m := erp.require_member();
  perform erp.require_cap('tenant.settings.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'recost_run', to_jsonb(p_limit));
  if prev is not null then return prev; end if;
  r := erp.recost_batch(m.tenant_id, least(greatest(coalesce(p_limit, 10), 1), 100), 3000);   -- F2-02: 3 s budget under the 8 s timeout
  items := (r ->> 'items')::int; moves := (r ->> 'moves')::int;
  perform erp.audit(m.tenant_id, 'stock.recost_run', 'recost_queue', null, null, jsonb_build_object('items', items, 'moves', moves));
  res := jsonb_build_object('items', items, 'moves', moves, 'pending', (select count(*) from erp.recost_queue q where q.tenant_id = m.tenant_id));
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'recost_run', to_jsonb(p_limit), res);
end $$;

-- ---------------------------------------------------------------------
-- 7c. Read models for the stock screens (T14) and, later, the Materials facade (07 section 5 item 3).
--     Quantities with stock.read; cost columns only with cost.read. Visible warehouses only.
-- ---------------------------------------------------------------------
create or replace function erp.visible_warehouses(p_tenant uuid) returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(w.warehouse_id), '{}') from erp.warehouses w
   where w.tenant_id = p_tenant and w.kind = 'normal' and w.branch_id = any (erp.my_branches())
$$;

-- stock_on_hand: one row per (warehouse, item) with a balance. Filter: warehouse_id, branch_id, q (code prefix, name
-- contains, exact barcode), category_id, only ('negative' | 'low' | 'nonzero'). Order item code, warehouse code;
-- next = {item_code, warehouse_code, item_id, warehouse_id}. Flags low (below min level) / negative.
create or replace function erp_api.stock_on_hand(p_filter jsonb default '{}', p_cursor jsonb default null, p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 50), 1), 200); rows jsonb; whs uuid[]; q text; bc uuid; cst boolean := erp.can('cost.read');
        v_wh uuid; v_branch uuid; v_cat uuid; v_only text;
begin
  m := erp.require_member();
  perform erp.require_cap('stock.read');
  p_filter := coalesce(p_filter, '{}');
  whs := erp.visible_warehouses(m.tenant_id);
  if erp.jset(p_filter, 'warehouse_id') then
    v_wh := erp.try_uuid(p_filter ->> 'warehouse_id'); perform erp.require_own(m.tenant_id, 'warehouse', v_wh);
    if not (v_wh = any (whs)) then perform erp.err('ERP_FORBIDDEN', 'Your branches do not include this warehouse.'); end if;
  end if;
  if erp.jset(p_filter, 'branch_id') then v_branch := erp.try_uuid(p_filter ->> 'branch_id'); perform erp.require_branch_of_tenant(m.tenant_id, v_branch); end if;
  if erp.jset(p_filter, 'category_id') then v_cat := erp.try_uuid(p_filter ->> 'category_id'); perform erp.require_own(m.tenant_id, 'category', v_cat); end if;
  q := nullif(lower(btrim(p_filter ->> 'q')), '');
  if q is not null then select b.item_id into bc from erp.item_barcodes b where b.tenant_id = m.tenant_id and b.barcode = btrim(p_filter ->> 'q'); end if;
  v_only := p_filter ->> 'only';
  select jsonb_agg(jsonb_build_object('warehouse_id', x.warehouse_id, 'warehouse_code', x.wcode, 'branch_id', x.branch_id, 'item_id', x.item_id, 'item_code', x.icode,
                                      'item_name', x.iname, 'unit_code', x.ucode, 'qty', x.qty, 'reserved', x.reserved, 'available', x.qty - x.reserved,
                                      'min_level', x.min_level, 'low', x.min_level is not null and x.qty >= 0 and x.qty < x.min_level, 'negative', x.qty < 0)
                   || case when cst then jsonb_build_object('avg_cost', x.avg_cost, 'value', round(x.qty * coalesce(x.avg_cost, 0), 2)) else '{}'::jsonb end
                   order by lower(x.icode), lower(x.wcode), x.item_id, x.warehouse_id) into rows
    from (select b.warehouse_id, w.code wcode, w.branch_id, b.item_id, i.code icode, i.name iname, u.code ucode, b.qty, b.reserved, i.min_level, ic.avg_cost
            from erp.stock_balances b
            join erp.warehouses w on w.tenant_id = b.tenant_id and w.warehouse_id = b.warehouse_id
            join erp.items i on i.tenant_id = b.tenant_id and i.item_id = b.item_id
            join erp.units u on u.tenant_id = i.tenant_id and u.unit_id = i.base_unit_id
            left join erp.item_costs ic on ic.tenant_id = b.tenant_id and ic.item_id = b.item_id and ic.lot_id = b.lot_id
           where b.tenant_id = m.tenant_id and b.warehouse_id = any (whs)
             and (v_wh is null or b.warehouse_id = v_wh) and (v_branch is null or w.branch_id = v_branch) and (v_cat is null or i.category_id = v_cat)
             and (q is null or i.item_id = bc or lower(i.code) like replace(replace(q, '%', '\%'), '_', '\_') || '%' or strpos(lower(i.name), q) > 0)
             and (v_only is null or (v_only = 'negative' and b.qty < 0) or (v_only = 'low' and i.min_level is not null and b.qty >= 0 and b.qty < i.min_level)
                  or (v_only = 'nonzero' and b.qty <> 0))
             and (p_cursor is null or (lower(i.code), lower(w.code), i.item_id, w.warehouse_id)
                                      > (lower(p_cursor ->> 'item_code'), lower(p_cursor ->> 'warehouse_code'), erp.try_uuid(p_cursor ->> 'item_id'), erp.try_uuid(p_cursor ->> 'warehouse_id')))
           order by lower(i.code), lower(w.code), i.item_id, w.warehouse_id limit lim + 1) x;
  return erp.page_reply(rows, lim, array['item_code', 'warehouse_code', 'item_id', 'warehouse_id']);
end $$;

-- stock_card: the moves of one item (visible warehouses; one warehouse with p_filter.warehouse_id), oldest first,
-- with the running quantity (of the warehouse, or of all visible warehouses); date_from / date_to; next = {move_date,
-- move_id}. Each row: date, document (type, number, id), warehouse, qty, running qty; with cost.read the official
-- unit cost and value, and both methods' values.
create or replace function erp_api.stock_card(p_item_id uuid, p_filter jsonb default '{}', p_cursor jsonb default null, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 100), 1), 500); rows jsonb; whs uuid[]; cst boolean := erp.can('cost.read'); v_wh uuid; v_from date; v_to date;
        c_date date; c_id bigint; opening numeric; i erp.items;
begin
  m := erp.require_member();
  perform erp.require_cap('stock.read');
  perform erp.require_own(m.tenant_id, 'item', p_item_id);
  select * into i from erp.items where tenant_id = m.tenant_id and item_id = p_item_id;
  p_filter := coalesce(p_filter, '{}');
  whs := erp.visible_warehouses(m.tenant_id);
  if erp.jset(p_filter, 'warehouse_id') then
    v_wh := erp.try_uuid(p_filter ->> 'warehouse_id'); perform erp.require_own(m.tenant_id, 'warehouse', v_wh);
    if not (v_wh = any (whs)) then perform erp.err('ERP_FORBIDDEN', 'Your branches do not include this warehouse.'); end if;
    whs := array[v_wh];
  end if;
  begin v_from := nullif(p_filter ->> 'date_from', '')::date; v_to := nullif(p_filter ->> 'date_to', '')::date;
  exception when others then perform erp.raise_problems(jsonb_build_array(erp.problem('invalid', 'date_from', 'Dates: yyyy-mm-dd.'))); end;
  if p_cursor is not null then c_date := (p_cursor ->> 'move_date')::date; c_id := (p_cursor ->> 'move_id')::bigint; end if;
  -- quantity before the first row of this page
  select coalesce(sum(x.qty_base), 0) into opening from erp.stock_moves x
   where x.tenant_id = m.tenant_id and x.item_id = p_item_id and x.warehouse_id = any (whs)
     and ((c_date is null and v_from is not null and x.move_date < v_from) or (c_date is not null and (x.move_date, x.move_id) <= (c_date, c_id)));
  select jsonb_agg(r order by (r ->> 'move_date'), (r ->> 'move_id')::bigint) into rows from (
    select jsonb_build_object('move_id', x.move_id, 'move_date', x.move_date, 'kind', x.kind, 'document_id', x.document_id, 'doc_type', d.doc_type, 'doc_no', d.doc_no,
                              'doc_state', d.state, 'warehouse_id', x.warehouse_id, 'warehouse_code', w.code, 'qty', x.qty_base,
                              'running_qty', opening + sum(x.qty_base) over (order by x.move_date, x.move_id), 'provisional', x.cost_provisional)
           || case when cst then jsonb_build_object('official', x.official, 'value', case x.official when 'avg' then x.value_avg else x.value_fifo end,
                                                    'unit_cost', case x.official when 'avg' then x.unit_cost_avg else x.unit_cost_fifo end,
                                                    'value_avg', x.value_avg, 'value_fifo', x.value_fifo) else '{}'::jsonb end r
      from (select * from erp.stock_moves y
             where y.tenant_id = m.tenant_id and y.item_id = p_item_id and y.warehouse_id = any (whs)
               and (v_from is null or y.move_date >= v_from) and (v_to is null or y.move_date <= v_to)
               and (c_date is null or (y.move_date, y.move_id) > (c_date, c_id))
             order by y.move_date, y.move_id limit lim + 1) x
      join erp.documents d on d.tenant_id = x.tenant_id and d.document_id = x.document_id
      join erp.warehouses w on w.tenant_id = x.tenant_id and w.warehouse_id = x.warehouse_id) z;
  return erp.page_reply(rows, lim, array['move_date', 'move_id'])
      || jsonb_build_object('item', jsonb_build_object('item_id', i.item_id, 'code', i.code, 'name', i.name), 'opening_qty', opening);
end $$;

-- item_lookup: items by code prefix / name / exact barcode with the on hand of one warehouse (or of the visible
-- warehouses) and the low / negative flags (07 section 5 item 3; document lines' item picker)
create or replace function erp_api.item_lookup(p_query text, p_warehouse_id uuid default null, p_limit int default 20) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; q text := nullif(lower(btrim(p_query)), ''); bc uuid; whs uuid[]; lim int := least(greatest(coalesce(p_limit, 20), 1), 50);
begin
  m := erp.require_member();
  perform erp.require_cap('item.read');
  whs := erp.visible_warehouses(m.tenant_id);
  if p_warehouse_id is not null then
    perform erp.require_own(m.tenant_id, 'warehouse', p_warehouse_id);
    if not (p_warehouse_id = any (whs)) then perform erp.err('ERP_FORBIDDEN', 'Your branches do not include this warehouse.'); end if;
    whs := array[p_warehouse_id];
  end if;
  if q is not null then select b.item_id into bc from erp.item_barcodes b where b.tenant_id = m.tenant_id and b.barcode = btrim(p_query); end if;
  return jsonb_build_object('rows', coalesce((select jsonb_agg(jsonb_build_object('item_id', i.item_id, 'code', i.code, 'name', i.name, 'kind', i.kind,
                                                                                  'base_unit_id', i.base_unit_id, 'unit_code', u.code, 'barcode_match', i.item_id = bc,
                                                                                  'on_hand', s.qty, 'available', s.qty - s.reserved,
                                                                                  'low', i.min_level is not null and s.qty >= 0 and s.qty < i.min_level, 'negative', s.qty < 0)
                                                               order by (i.item_id = bc) desc, lower(i.code))
                                                from (select * from erp.items x where x.tenant_id = m.tenant_id and x.active
                                                         and (q is null or x.item_id = bc or lower(x.code) like replace(replace(q, '%', '\%'), '_', '\_') || '%' or strpos(lower(x.name), q) > 0)
                                                       order by (x.item_id = bc) desc nulls last, lower(x.code) limit lim) i
                                                join erp.units u on u.tenant_id = i.tenant_id and u.unit_id = i.base_unit_id
                                                cross join lateral (select coalesce(sum(b.qty), 0) qty, coalesce(sum(b.reserved), 0) reserved from erp.stock_balances b
                                                                     where b.tenant_id = m.tenant_id and b.item_id = i.item_id and b.warehouse_id = any (whs)) s), '[]'::jsonb));
end $$;

-- item_availability: one item per visible warehouse (qty, reserved, available, low, negative) + recost pending flag
create or replace function erp_api.item_availability(p_item_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; i erp.items; cst boolean := erp.can('cost.read');
begin
  m := erp.require_member();
  perform erp.require_cap('stock.read');
  perform erp.require_own(m.tenant_id, 'item', p_item_id);
  select * into i from erp.items where tenant_id = m.tenant_id and item_id = p_item_id;
  return jsonb_build_object('item_id', i.item_id, 'code', i.code, 'name', i.name, 'min_level', i.min_level,
    'recost_pending', exists (select 1 from erp.recost_queue q where q.tenant_id = m.tenant_id and q.item_id = p_item_id),
    'warehouses', coalesce((select jsonb_agg(jsonb_build_object('warehouse_id', w.warehouse_id, 'warehouse_code', w.code, 'qty', coalesce(b.qty, 0),
                                                                'reserved', coalesce(b.reserved, 0), 'available', coalesce(b.qty, 0) - coalesce(b.reserved, 0),
                                                                'low', i.min_level is not null and coalesce(b.qty, 0) >= 0 and coalesce(b.qty, 0) < i.min_level,
                                                                'negative', coalesce(b.qty, 0) < 0) order by w.code)
                              from erp.warehouses w left join erp.stock_balances b on b.tenant_id = w.tenant_id and b.warehouse_id = w.warehouse_id and b.item_id = p_item_id
                             where w.tenant_id = m.tenant_id and w.warehouse_id = any (erp.visible_warehouses(m.tenant_id)) and w.active), '[]'::jsonb))
    || case when cst then jsonb_build_object('avg_cost', (select ic.avg_cost from erp.item_costs ic where ic.tenant_id = m.tenant_id and ic.item_id = p_item_id
                                                           and ic.lot_id = '00000000-0000-0000-0000-000000000000')) else '{}'::jsonb end;
end $$;

-- ---------------------------------------------------------------------
-- 8. RLS + grants. Moves / balances: tenant + visible warehouses (one sub-select per query). Cost state, layers and
--    their consumption: tenant + cost.read (02: cost columns only with cost.read; warehouse reads quantities).
-- ---------------------------------------------------------------------
do $$ declare r text; begin
  foreach r in array array['stock_moves', 'stock_balances', 'item_costs', 'stock_layers', 'stock_move_layers', 'valuation_periods', 'cost_revisions', 'recost_queue'] loop
    execute format('alter table erp.%I enable row level security', r);
    execute format('alter table erp.%I force row level security', r);
  end loop;
end $$;
drop policy if exists stock_moves_read on erp.stock_moves;
create policy stock_moves_read on erp.stock_moves for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and warehouse_id = any ((select array_agg(w.warehouse_id) from erp.warehouses w)::uuid[]));
drop policy if exists stock_balances_read on erp.stock_balances;
create policy stock_balances_read on erp.stock_balances for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and warehouse_id = any ((select array_agg(w.warehouse_id) from erp.warehouses w)::uuid[]));
drop policy if exists item_costs_read on erp.item_costs;
create policy item_costs_read on erp.item_costs for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.can('cost.read')));
drop policy if exists stock_layers_read on erp.stock_layers;
create policy stock_layers_read on erp.stock_layers for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.can('cost.read')));
drop policy if exists stock_move_layers_read on erp.stock_move_layers;
create policy stock_move_layers_read on erp.stock_move_layers for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.can('cost.read')));
drop policy if exists cost_revisions_read on erp.cost_revisions;
create policy cost_revisions_read on erp.cost_revisions for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.can('cost.read')));
drop policy if exists recost_queue_read on erp.recost_queue;
create policy recost_queue_read on erp.recost_queue for select to authenticated using (tenant_id = any ((select erp.my_tenants())::uuid[]));
drop policy if exists valuation_periods_read on erp.valuation_periods;
create policy valuation_periods_read on erp.valuation_periods for select to authenticated using (tenant_id = any ((select erp.my_tenants())::uuid[]));
do $$ declare r text; begin
  foreach r in array array['public', 'anon', 'service_role'] loop
    if r = 'public' or exists (select 1 from pg_catalog.pg_roles where rolname = r) then
      execute format('revoke all on erp.stock_moves, erp.stock_balances, erp.item_costs, erp.stock_layers, erp.stock_move_layers, erp.valuation_periods, erp.cost_revisions, erp.recost_queue from %s', r);
    end if;
  end loop;
end $$;
revoke insert, update, delete, truncate, references, trigger on erp.stock_moves, erp.stock_balances, erp.item_costs, erp.stock_layers, erp.stock_move_layers,
       erp.valuation_periods, erp.cost_revisions, erp.recost_queue from authenticated;
grant select on erp.stock_moves, erp.stock_balances, erp.item_costs, erp.stock_layers, erp.stock_move_layers, erp.valuation_periods, erp.cost_revisions,
      erp.recost_queue to authenticated;

select erp.lock_down();
grant execute on function erp_api.recost_status(), erp_api.recost_run(int, uuid), erp_api.stock_on_hand(jsonb, jsonb, int), erp_api.stock_card(uuid, jsonb, jsonb, int),
                          erp_api.item_lookup(text, uuid, int), erp_api.item_availability(uuid) to authenticated;
