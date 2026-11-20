-- =====================================================================
-- iSmile ERP  -  T15 measurement helpers (scratch load database only; loaded by measure_erp.py on every run).
-- Timings are SERVER-SIDE: clock_timestamp() around each RPC call inside the database (no network, no JSON
-- transfer to a client). The calls run as role authenticated with the claims of a load member, i.e. through
-- require_member / require_cap / RLS exactly as the app's calls would.
-- =====================================================================
create schema if not exists load;
grant usage on schema load to authenticated;
grant select on load.tenants to authenticated;

-- act as a member of a load tenant ('owner' | 'wh'), for the current transaction
create or replace function load.login(p_code text, p_who text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', md5(p_who || ':' || p_code)::uuid,
                    'email', case p_who when 'owner' then 'owner@' else 'wh@' end || p_code || '.load', 'role', 'authenticated')::text, true) is null;
$$;

-- an item code of a load tenant (IT000001 ...)
create or replace function load.code(p_n int) returns text language sql immutable as $$ select 'IT' || lpad(p_n::text, 6, '0') $$;

-- a draft of p_lines lines in warehouse W001 (branch BR1) through erp_api.doc_save_draft; p_hot > 0 = lines on items 1..p_hot only;
-- p_item = every line on that one item. Returns the document id.
create or replace function load.draft(p_code text, p_type text, p_lines int, p_seed int, p_hot int default 0, p_date date default null,
                                      p_item uuid default null, p_qty numeric default null, p_price numeric default null, p_notes text default null) returns uuid language plpgsql as $$
declare t uuid; br uuid; wh uuid; lines jsonb; n int; sup uuid;
begin
  select tenant_id, items into t, n from load.tenants where code = p_code;
  select branch_id into br from erp.branches where tenant_id = t and code = 'BR1';
  select warehouse_id into wh from erp.warehouses where tenant_id = t and code = 'W001';
  select counterparty_id into sup from erp.counterparties where tenant_id = t and code = 'SUP1';
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('item_id', coalesce(p_item, i.item_id),
                                                        'qty', coalesce(p_qty, case when p_type = 'GRN' then 10 else 1 end),
                                                        'unit_price', case when p_type = 'GRN' then coalesce(p_price, 2.5) end)) order by l) into lines
    from generate_series(1, p_lines) l
    join erp.items i on i.tenant_id = t
     and i.code = load.code(1 + case when p_hot > 0 then (p_seed + l) % p_hot else (p_seed * 31 + l * 101) % n end);
  return (erp_api.doc_save_draft(p_type, jsonb_strip_nulls(jsonb_build_object('branch_id', br, 'warehouse_id', wh, 'lines', lines, 'doc_date', p_date, 'notes', p_notes,
            'counterparty_id', case when p_type = 'GRN' then sup end)), gen_random_uuid()) ->> 'document_id')::uuid;
end $$;

-- pgbench: one document (CONS or GRN) of 3 lines on the 5 hot items of load_std, posted as the warehouse member
create or replace function load.bench_post(p_type text) returns bigint language plpgsql as $$
declare d uuid; r jsonb;
begin
  perform load.login('load_std', 'wh');
  d := load.draft('load_std', p_type, 3, (random() * 1000)::int, 5);
  r := erp_api.doc_set_state(d, 'posted', '{"ack_warnings": true}', gen_random_uuid());
  return (r #>> '{document,number}')::bigint;
end $$;

-- time p_n executions of p_sql (one statement; $1 = the iteration number 1..p_n). Returns the timings in ms.
create or replace function load.time_sql(p_sql text, p_n int) returns numeric[] language plpgsql as $$
declare i int; t0 timestamptz; ms numeric[] := '{}'; dummy text;
begin
  for i in 1 .. p_n loop
    t0 := clock_timestamp();
    execute p_sql into dummy using i;
    ms := ms || round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 3);
  end loop;
  return ms;
end $$;

-- p50 / p95 / max / n of a timing array, as jsonb
create or replace function load.stats(p_ms numeric[]) returns jsonb language sql immutable as $$
  select jsonb_build_object('n', count(*), 'p50', round(percentile_cont(0.5) within group (order by v)::numeric, 1),
                            'p95', round(percentile_cont(0.95) within group (order by v)::numeric, 1), 'max', round(max(v), 1))
    from unnest(p_ms) v
$$;

-- the read measurements as the warehouse member of p_code (one transaction, rolled back by the caller)
create or replace function load.measure_reads(p_code text, p_n int) returns jsonb language plpgsql as $$
declare t uuid; n int; wh uuid; res jsonb := '{}'; hot uuid; w text;
begin
  perform load.login(p_code, 'wh');
  select tenant_id, items into t, n from load.tenants where code = p_code;
  select warehouse_id into wh from erp.warehouses where tenant_id = t and code = 'W001';
  select item_id into hot from erp.items where tenant_id = t and code = load.code(1);
  w := quote_literal(wh);
  -- warm-up (first call of each function plans the statements)
  perform erp_api.item_lookup('IT00', null, 20), erp_api.stock_on_hand('{}', null, 50), erp_api.doc_list('{}', null, 50);
  res := res || jsonb_build_object(
    'item_lookup_code', load.stats(load.time_sql(format('select erp_api.item_lookup(load.code(1 + ($1 * 37) %% %s), null, 20)::text', n), p_n)),
    'item_lookup_prefix', load.stats(load.time_sql(format('select erp_api.item_lookup(left(load.code(1 + ($1 * 37) %% %s), 6), %s, 20)::text', n, w), p_n)),
    'item_lookup_name', load.stats(load.time_sql('select erp_api.item_lookup((array[''Bracket'',''Wire'',''Elastic'',''Aligner'',''Band''])[1 + $1 % 5] || '' '' || (1 + $1 % 9), null, 20)::text', p_n)),
    'item_lookup_barcode', load.stats(load.time_sql(format('select erp_api.item_lookup(''BC'' || substr(load.code(1 + ($1 * 53) %% %s), 3), null, 20)::text', n), p_n)),
    'stock_on_hand_page', load.stats(load.time_sql(format('select erp_api.stock_on_hand(jsonb_build_object(''warehouse_id'', %s::uuid), null, 50)::text', w), p_n)),
    'stock_on_hand_q', load.stats(load.time_sql(format('select erp_api.stock_on_hand(jsonb_build_object(''q'', load.code(1 + ($1 * 37) %% %s)), null, 50)::text', n), p_n)),
    'item_availability', load.stats(load.time_sql(format('select erp_api.item_availability((select item_id from erp.items where tenant_id = %L and code = load.code(1 + ($1 * 37) %% %s)))::text', t, n), p_n)),
    'doc_list_first', load.stats(load.time_sql('select erp_api.doc_list(''{}'', null, 50)::text', p_n)),
    'doc_list_type_state', load.stats(load.time_sql('select erp_api.doc_list(jsonb_build_object(''doc_type'', (array[''CONS'',''GRN''])[1 + $1 % 2], ''state'', ''posted''), null, 50)::text', p_n)),
    'doc_list_month', load.stats(load.time_sql('select erp_api.doc_list(jsonb_build_object(''date_from'', current_date - 30 * (1 + $1 % 11), ''date_to'', current_date - 30 * ($1 % 11)), null, 50)::text', p_n)),
    'doc_list_page5', load.stats(load.time_sql(format('select erp_api.doc_list(''{}'', jsonb_build_object(''doc_date'', current_date - 3 - $1 %% 300, ''document_id'', %L), 50)::text',
                                                      'ffffffff-ffff-ffff-ffff-ffffffffffff'), p_n)),
    'stock_card_item', load.stats(load.time_sql(format('select erp_api.stock_card((select item_id from erp.items where tenant_id = %L and code = load.code(1 + ($1 * 37) %% %s)), ''{}'', null, 100)::text', t, n), p_n)),
    'stock_card_hot', load.stats(load.time_sql(format('select erp_api.stock_card(%L, ''{}'', null, 100)::text', hot), p_n)),
    'stock_card_hot_last', load.stats(load.time_sql(format('select erp_api.stock_card(%L, jsonb_build_object(''date_from'', current_date - 7), null, 100)::text', hot), p_n)),
    'report_negative_stock', load.stats(load.time_sql('select erp_api.report_negative_stock(''{}'', null, 50)::text', least(p_n, 50))),
    'recost_status', load.stats(load.time_sql('select erp_api.recost_status()::text', least(p_n, 50))));
  if exists (select 1 from erp.documents where tenant_id = t and notes = 'measure20:50') then
    res := res || jsonb_build_object('doc_get_20', load.stats(load.time_sql(format(
      'select erp_api.doc_get((select document_id from erp.documents where tenant_id = %L and notes = ''measure20:'' || (1 + $1 %% 50) limit 1))::text', t), p_n)));
  end if;
  return res;
end $$;

-- 20-line documents: p_n CONS (and GRN) drafts saved, then posted, as the warehouse member. Timings of save and post.
-- The documents stay (notes measure20:i) so doc_get can open them.
create or replace function load.measure_posts(p_code text, p_n int) returns jsonb language plpgsql as $$
declare i int; d uuid; t0 timestamptz; save_ms numeric[] := '{}'; post_ms numeric[] := '{}'; grn_ms numeric[] := '{}'; t uuid; r jsonb;
begin
  select tenant_id into t from load.tenants where code = p_code;
  perform load.login(p_code, 'wh');
  for i in 1 .. p_n loop
    t0 := clock_timestamp();
    d := load.draft(p_code, case when i % 2 = 0 then 'GRN' else 'CONS' end, 20, 1000 + i, p_notes => 'measure20:' || i);
    save_ms := save_ms || round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 3);
    t0 := clock_timestamp();
    r := erp_api.doc_set_state(d, 'posted', '{"ack_warnings": true}', gen_random_uuid());
    if i % 2 = 0 then grn_ms := grn_ms || round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 3);
    else post_ms := post_ms || round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 3); end if;
    if not (r ->> 'posted')::boolean then raise exception 'measure post % not posted: %', i, r; end if;
  end loop;
  return jsonb_build_object('doc_save_draft_20', load.stats(save_ms), 'post_cons_20', load.stats(post_ms), 'post_grn_20', load.stats(grn_ms));
end $$;

-- recost set-up: item RC000001 with one opening GRN (day -2100) and p_moves later moves on p_moves different days
-- (every 10th a GRN at a changing price, the rest CONS of 1), posted in date order as the owner (no replays while building)
create or replace procedure load.recost_setup(p_code text, p_moves int) language plpgsql as $$
declare t uuid; it uuid; i int; d uuid; pcs uuid;
begin
  select tenant_id into t from load.tenants where code = p_code;
  if exists (select 1 from erp.items where tenant_id = t and code = 'RC000001') then return; end if;
  select unit_id into pcs from erp.units where tenant_id = t and code = 'PCS';
  insert into erp.items (tenant_id, code, name, base_unit_id, kind) values (t, 'RC000001', 'Recost probe', pcs, 'goods') returning item_id into it;
  commit;
  perform load.login(p_code, 'owner');
  d := load.draft(p_code, 'GRN', 1, 0, 0, current_date - 2100, it, 100000, 1.0);
  perform erp_api.doc_set_state(d, 'posted', '{"ack_warnings": true}', gen_random_uuid());
  for i in 1 .. p_moves loop
    d := load.draft(p_code, case when i % 10 = 0 then 'GRN' else 'CONS' end, 1, i, 0, current_date - p_moves + i - 1, it,
                    case when i % 10 = 0 then 20 else 1 end, 1 + (i % 7) * 0.1);
    perform erp_api.doc_set_state(d, 'posted', '{"ack_warnings": true}', gen_random_uuid());
    if i % 200 = 0 then commit; perform load.login(p_code, 'owner'); end if;
  end loop;
  commit;
end $$;

-- one backdated GRN on RC000001 dated between the opening and the later moves (the caller rolls it back):
-- the post replays every later move inline. Returns {ms, later_moves, revisions}
create or replace function load.measure_backdate(p_code text) returns jsonb language plpgsql as $$
declare t uuid; it uuid; d uuid; t0 timestamptz; ms numeric; nl int; rv int;
begin
  perform load.login(p_code, 'owner');
  select tenant_id into t from load.tenants where code = p_code;
  select item_id into it from erp.items where tenant_id = t and code = 'RC000001';
  select count(*) into nl from erp.stock_moves where tenant_id = t and item_id = it and move_date > current_date - 2050;
  d := load.draft(p_code, 'GRN', 1, 0, 0, current_date - 2050, it, 500, 3.0);
  t0 := clock_timestamp();
  perform erp_api.doc_set_state(d, 'posted', '{"ack_warnings": true}', gen_random_uuid());
  ms := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 1);
  select count(*) into rv from erp.cost_revisions where tenant_id = t and item_id = it;
  return jsonb_build_object('ms', ms, 'later_moves', nl, 'queued', exists (select 1 from erp.recost_queue q where q.tenant_id = t and q.item_id = it), 'revisions', rv);
end $$;

-- the queue path: replay of the whole item (every move) as the recost job does it (the caller rolls it back)
create or replace function load.measure_replay(p_code text) returns jsonb language plpgsql as $$
declare t uuid; it uuid; t0 timestamptz; ms numeric; n int;
begin
  select tenant_id into t from load.tenants where code = p_code;
  select item_id into it from erp.items where tenant_id = t and code = 'RC000001';
  insert into erp.recost_queue (tenant_id, item_id, lot_id, from_date, reason) values (t, it, '00000000-0000-0000-0000-000000000000', current_date - 2050, 'backdate');
  t0 := clock_timestamp();
  n := erp.recost_item(t, it, '00000000-0000-0000-0000-000000000000');
  ms := round(extract(epoch from clock_timestamp() - t0)::numeric * 1000, 1);
  return jsonb_build_object('ms', ms, 'moves', n);
end $$;

-- after the pgbench run: numbering per series of load_std (gapless, unique) and the ledger integrity of every tenant
create or replace function load.check_after_bench() returns jsonb language sql as $$
  select jsonb_build_object(
    'series', (select jsonb_agg(jsonb_build_object('series', s.code, 'posted', x.n, 'distinct', x.nd, 'min', x.mn, 'max', x.mx,
                                                   'gapless', x.n = x.nd and x.mn = 1 and x.mx = x.n) order by s.code)
                 from erp.series s join load.tenants l on l.tenant_id = s.tenant_id and l.code = 'load_std'
                 join lateral (select count(*) n, count(distinct number) nd, min(number) mn, max(number) mx
                                 from erp.documents d where d.tenant_id = s.tenant_id and d.series_id = s.series_id and d.number is not null) x on x.n > 0),
    'integrity', (select jsonb_object_agg(l.code, jsonb_array_length(erp.stock_integrity(l.tenant_id))) from load.tenants l),
    'unposted_drafts_bench', (select count(*) from erp.documents d join load.tenants l on l.tenant_id = d.tenant_id and l.code = 'load_std'
                               where d.state = 'draft'),
    'recost_queue', (select count(*) from erp.recost_queue));
$$;

grant execute on all functions in schema load to authenticated;
