-- =====================================================================
-- iSmile ERP  -  E160_transfer.sql   (task T16)
-- Purpose : TRF internal transfer (01 C3, 02 "Document state machines", "Branch and warehouse model"):
--           draft -> dispatched (number of the SOURCE branch's gapless series; stock source -> the tenant's transit
--           warehouse) -> received (transit -> destination, every line as dispatched) or -> received_with_difference
--           (transit -> destination for the received quantity; the difference becomes a generated ADJ_OUT out of
--           transit (shortage) and / or ADJ_IN into the destination (excess), DRAFTS that go through the normal ADJ
--           path: value limit, submit / approve / reject) -> closed automatically when those adjustments are posted;
--           dispatched -> cancelled (manager / owner of the source: reversing moves, the stock returns from transit).
--           The moved quantity keeps the cost of the dispatch under both methods (E140 cost rule 'transfer': the
--           item's company-wide cost state and FIFO layers never change, receipt moves copy the dispatch move's cost).
--           Transit: blocks below zero (02, 05 question 3), holds only open transfers' quantities, zero for every
--           received / closed / cancelled transfer (erp.trf_integrity, nightly job). Visible to the source AND the
--           destination branch (E130 doc_types.dest_visible); the receipt is taken by the destination
--           (doc_transitions.side = 'dest').
--           Fiscal TRF between establishments (9.3) is T36: erp.trf_fiscal_needed is the hook, v1 posts every TRF as
--           an internal, non-fiscal document. REQ -> TRF conversion is T45.
-- Run order: after E150. Standalone: names no CRM object. Safe to re-run.
-- Redefines: nothing. Enables the TRF catalogue row (E120) and sets its posting / visibility columns (E130). Uses the
--            E130 hooks (doc_types.action_fn, doc_ref_changed, transitions side / actions receive, close) and the
--            E140 costing (cost rule 'transfer', erp.stock_cost_new); E150 doc_stock_validate calls
--            erp.trf_adj_validate for an adjustment that references a transfer.
-- Locks    : dispatch = erp.post_document (document row, series, items ascending, balances, usage row last).
--            Receipt = document row (doc_lock), items ascending (erp.stock_lock), balances; no series, no usage row.
--            Auto-close (posting a difference ADJ): the ADJ's own post locks, then the TRF row LAST (only that ADJ
--            post locks a received TRF after item locks; the receipt is committed before the ADJ exists).
-- Tests    : tests/E160_transfer_tests.sql (golden tests/golden/G10.csv), tests/concurrency_transfer.sh (runner),
--            tests/E990 (registry + fixtures)
-- =====================================================================

do $$ begin
  if to_regprocedure('erp.doc_stock_validate(uuid,uuid)') is null then raise exception 'run E150_stock_docs.sql first'; end if;
  if to_regprocedure('erp.stock_cost_new(uuid,uuid,uuid,date,bigint[])') is null then raise exception 'E140_stock_engine.sql (T16 version) must run first'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Type, transitions, capabilities (03 recipe step 1). Seeded rows change only by this versioned update.
-- ---------------------------------------------------------------------
-- header extra: delivery = {carrier, vehicle, notes} (01 C3 "delivery block"; the fiscal delivery data of T36 extend it)
update erp.doc_types set enabled = true, stock_sign = -1, cost_rule = 'transfer', needs_warehouse = true, price_kind = 'none', needs_counterparty = false,
       header_extra = '{delivery}', line_extra = '{}', validator = 'doc_trf_validate', dest_visible = true, action_fn = 'trf_action', seed_version = 2
 where doc_type = 'TRF' and seed_version < 2;

-- 02 "TRF internal": draft -> dispatched -> received (-> received_with_difference -> closed after ADJ approval);
-- dispatched -> cancelled (stock returns from transit). 01 C3: create W M O (source); the receiver W M O confirms
-- (destination); void M O before receipt (source). Close = the posted difference adjustments (automatic, E160 child
-- hook); the manual row is the fallback when the poster of the ADJ may not close the transfer.
insert into erp.doc_transitions (doc_type, from_state, to_state, cap, condition, action, label, sort, side) values
  ('TRF', 'draft', 'dispatched', 'create', null, 'post', 'doc.action.dispatch', 10, 'source'),
  ('TRF', 'dispatched', 'received', 'create', null, 'receive', 'doc.action.receive', 20, 'dest'),
  ('TRF', 'dispatched', 'received_with_difference', 'create', null, 'receive', 'doc.action.receive_difference', 25, 'dest'),
  ('TRF', 'received_with_difference', 'closed', 'create', null, 'close', 'doc.action.close', 30, 'dest'),
  ('TRF', 'dispatched', 'cancelled', 'approve', null, 'cancel', 'doc.action.cancel', 90, 'source')
on conflict do nothing;

insert into erp.capabilities (capability, area, note) values
  ('doc.trf.read', 'stock', 'transfers (source or destination branch)'), ('doc.trf.create', 'stock', 'dispatch transfers (source), confirm receipt (destination)'),
  ('doc.trf.approve', 'stock', 'cancel a dispatched transfer (source)')
on conflict (capability) do nothing;
-- 02 matrix "TRF, ADJ, STK": owner c a, manager c a, warehouse c (approve: no), accounting r, clinic_user -, readonly r
insert into erp.role_cap_defaults (role, capability)
select r, c from (values
  ('owner', 'doc.trf.read'), ('owner', 'doc.trf.create'), ('owner', 'doc.trf.approve'),
  ('manager', 'doc.trf.read'), ('manager', 'doc.trf.create'), ('manager', 'doc.trf.approve'),
  ('warehouse', 'doc.trf.read'), ('warehouse', 'doc.trf.create'),
  ('accounting', 'doc.trf.read'), ('readonly', 'doc.trf.read')) v(r, c)
on conflict do nothing;
select erp.role_caps_sync();

-- ---------------------------------------------------------------------
-- 2. Receipt data (typed side tables, 03 recipe step 2: queried and validated). Written once by the receipt;
--    doc_trf.closed_at is set when the transit side of the transfer is settled.
-- ---------------------------------------------------------------------
create table if not exists erp.doc_trf (
  tenant_id    uuid not null references erp.tenants (tenant_id),
  document_id  uuid not null,
  receipt_date date not null,
  received_by  uuid,
  received_at  timestamptz not null default now(),
  adj_out_id   uuid,                                   -- generated ADJ_OUT (shortage, out of transit); null when none
  adj_in_id    uuid,                                   -- generated ADJ_IN (excess, into the destination); null when none
  closed_at    timestamptz,                            -- transit settled: at receipt without a difference, else when the ADJ posted
  primary key (tenant_id, document_id),
  foreign key (tenant_id, document_id) references erp.documents (tenant_id, document_id),
  foreign key (tenant_id, adj_out_id) references erp.documents (tenant_id, document_id),
  foreign key (tenant_id, adj_in_id) references erp.documents (tenant_id, document_id)
);
create index if not exists doc_trf_adj_out_idx on erp.doc_trf (tenant_id, adj_out_id) where adj_out_id is not null;
create index if not exists doc_trf_adj_in_idx on erp.doc_trf (tenant_id, adj_in_id) where adj_in_id is not null;

create table if not exists erp.doc_trf_lines (
  tenant_id    uuid not null references erp.tenants (tenant_id),
  line_id      uuid not null,
  document_id  uuid not null,
  received_qty numeric(16,4) not null check (received_qty >= 0),
  diff_qty     numeric(16,4) not null,                 -- received - dispatched (base units)
  diff_reason  text check (length(diff_reason) <= 200),
  primary key (tenant_id, line_id),
  foreign key (tenant_id, line_id) references erp.document_lines (tenant_id, line_id),
  foreign key (tenant_id, document_id) references erp.doc_trf (tenant_id, document_id)
);
create index if not exists doc_trf_lines_doc_idx on erp.doc_trf_lines (tenant_id, document_id);

-- the receipt is a ledger fact: lines never change; the header only gets closed_at (once)
drop trigger if exists doc_trf_lines_append_only on erp.doc_trf_lines;
create trigger doc_trf_lines_append_only before update or delete on erp.doc_trf_lines for each row execute function erp.tg_append_only();
drop trigger if exists doc_trf_lines_no_truncate on erp.doc_trf_lines;
create trigger doc_trf_lines_no_truncate before truncate on erp.doc_trf_lines for each statement execute function erp.tg_append_only();
create or replace function erp.tg_doc_trf_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' or (to_jsonb(new) - 'closed_at') <> (to_jsonb(old) - 'closed_at') or old.closed_at is not null then
    perform erp.err('ERP_APPEND_ONLY', 'The receipt of a transfer is not changed (only its closing time is set, once).');
  end if;
  return new;
end $$;
drop trigger if exists doc_trf_guard on erp.doc_trf;
create trigger doc_trf_guard before update or delete on erp.doc_trf for each row execute function erp.tg_doc_trf_guard();
drop trigger if exists doc_trf_no_truncate on erp.doc_trf;
create trigger doc_trf_no_truncate before truncate on erp.doc_trf for each statement execute function erp.tg_append_only();

-- ---------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------
create or replace function erp.transit_warehouse(p_tenant uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select w.warehouse_id from erp.warehouses w where w.tenant_id = p_tenant and w.kind = 'in_transit'
$$;

-- T36 hook: a transfer between two establishments is a fiscal movement document (myDATA 9.3, 01 C3). v1 posts every
-- TRF as an INTERNAL, non-fiscal document; T36 turns this flag into the fiscal path (submit -> issued -> received).
create or replace function erp.trf_fiscal_needed(p_tenant uuid, p_doc uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(sb.branch_id <> db.branch_id and sb.establishment_no is distinct from db.establishment_no, false)
    from erp.documents d
    join erp.branches sb on sb.tenant_id = d.tenant_id and sb.branch_id = d.branch_id
    join erp.warehouses w on w.tenant_id = d.tenant_id and w.warehouse_id = d.dest_warehouse_id
    join erp.branches db on db.tenant_id = w.tenant_id and db.branch_id = w.branch_id
   where d.tenant_id = p_tenant and d.document_id = p_doc
$$;

-- what a transfer still holds in transit, per item: its own transit moves + its generated ADJ_OUT (posted)
create or replace function erp.trf_transit_left(p_tenant uuid, p_doc uuid) returns table (item_id uuid, qty numeric, value_avg numeric, value_fifo numeric)
language sql stable security definer set search_path = '' as $$
  select m.item_id, sum(m.qty_base), sum(m.value_avg), sum(m.value_fifo)
    from erp.stock_moves m
   where m.tenant_id = p_tenant and m.warehouse_id = erp.transit_warehouse(p_tenant)
     and m.document_id in (select p_doc union all select t.adj_out_id from erp.doc_trf t where t.tenant_id = p_tenant and t.document_id = p_doc and t.adj_out_id is not null)
   group by m.item_id
$$;

-- ---------------------------------------------------------------------
-- 4. Validation (03 recipe step 3; called by erp.doc_validate through doc_types.validator)
-- ---------------------------------------------------------------------
create or replace function erp.doc_trf_validate(p_tenant uuid, p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare d erp.documents; dw erp.warehouses; probs jsonb := '[]'; k text;
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc;
  select * into dw from erp.warehouses w where w.tenant_id = p_tenant and w.warehouse_id = d.dest_warehouse_id;
  if dw.warehouse_id is null then probs := probs || erp.problem('required', 'dest_warehouse_id', 'Destination warehouse is required.');
  elsif dw.kind <> 'normal' then probs := probs || erp.problem('invalid', 'dest_warehouse_id', 'The transit warehouse cannot be chosen.');
  elsif dw.warehouse_id = d.warehouse_id then probs := probs || erp.problem('invalid', 'dest_warehouse_id', 'The destination is the source warehouse.');
  elsif not dw.active then probs := probs || erp.problem('inactive', 'dest_warehouse_id', format('Warehouse %s is not active.', dw.code)); end if;
  probs := probs || coalesce((select jsonb_agg(erp.problem('duplicate', 'item_id', format('Item %s is on several lines: merge them.', i.code), x.line_no) order by x.line_no)
                                from (select l.item_id, min(l.line_no) line_no from erp.document_lines l
                                       where l.tenant_id = p_tenant and l.document_id = p_doc and l.item_id is not null
                                       group by l.item_id having count(*) > 1) x join erp.items i on i.tenant_id = p_tenant and i.item_id = x.item_id), '[]'::jsonb);
  if d.extra ? 'delivery' then
    if jsonb_typeof(d.extra -> 'delivery') <> 'object' then probs := probs || erp.problem('invalid', 'extra.delivery', 'Delivery: an object {carrier, vehicle, notes}.');
    else
      for k in select jsonb_object_keys(d.extra -> 'delivery') loop
        if k not in ('carrier', 'vehicle', 'notes') then probs := probs || erp.problem('not_editable', 'extra.delivery.' || k, format('%s is not a delivery field.', k));
        elsif jsonb_typeof(d.extra -> 'delivery' -> k) <> 'string' or length(d.extra -> 'delivery' ->> k) > 100 then
          probs := probs || erp.problem('invalid', 'extra.delivery.' || k, 'Delivery fields: text, at most 100 characters.'); end if;
      end loop;
    end if;
  end if;
  return probs;
end $$;

-- the difference adjustment of a transfer (called by E150 doc_stock_validate for EVERY ADJ): an adjustment generated
-- by a receipt (registered in doc_trf, found by its id, not by its reference) stays exactly as generated (reference,
-- type, branch, warehouse, items and quantities = the receipt difference; date not before the receipt; reason, notes
-- and date may be edited); no other adjustment may reference a transfer.
create or replace function erp.trf_adj_validate(p_tenant uuid, p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare a erp.documents; p erp.documents; t erp.doc_trf; probs jsonb := '[]'; want_wh uuid; sgn int; bad text;
begin
  select * into a from erp.documents where tenant_id = p_tenant and document_id = p_doc;
  select * into t from erp.doc_trf x where x.tenant_id = p_tenant and (x.adj_out_id = p_doc or x.adj_in_id = p_doc);
  if t.document_id is null then
    if a.ref_document_id is not null and exists (select 1 from erp.documents x where x.tenant_id = p_tenant and x.document_id = a.ref_document_id and x.doc_type = 'TRF') then
      return jsonb_build_array(erp.problem('invalid', 'ref_document_id', 'Only the adjustment generated by a transfer receipt can reference the transfer.'));
    end if;
    return probs;
  end if;
  select * into p from erp.documents where tenant_id = p_tenant and document_id = t.document_id;
  if a.ref_document_id is distinct from t.document_id then
    probs := probs || erp.problem('invalid', 'ref_document_id', format('This adjustment settles transfer %s: its reference cannot change.', p.doc_no));
  end if;
  want_wh := case a.doc_type when 'ADJ_OUT' then erp.transit_warehouse(p_tenant) else p.dest_warehouse_id end;
  sgn := case a.doc_type when 'ADJ_OUT' then -1 else 1 end;
  if a.warehouse_id is distinct from want_wh then probs := probs || erp.problem('invalid', 'warehouse_id', 'The warehouse of a transfer difference cannot change.'); end if;
  if a.branch_id is distinct from erp.doc_dest_branch(p_tenant, p) then probs := probs || erp.problem('invalid', 'branch_id', 'The branch of a transfer difference cannot change.'); end if;
  if a.doc_date < t.receipt_date then probs := probs || erp.problem('invalid', 'doc_date', format('The adjustment cannot be dated before the receipt (%s).', to_char(t.receipt_date, 'DD/MM/YYYY'))); end if;
  if p.state <> 'received_with_difference' then probs := probs || erp.problem('invalid', 'ref_document_id', format('Transfer %s is %s.', p.doc_no, p.state)); end if;
  select string_agg(coalesce(i.code, '?'), ', ' order by i.code) into bad
    from (select coalesce(w.item_id, g.item_id) item_id
            from (select dl.item_id, sgn * tl.diff_qty qty from erp.doc_trf_lines tl join erp.document_lines dl on dl.tenant_id = tl.tenant_id and dl.line_id = tl.line_id
                   where tl.tenant_id = p_tenant and tl.document_id = p.document_id and sgn * tl.diff_qty > 0) w
            full join (select x.item_id, sum(x.qty_base) qty from erp.document_lines x where x.tenant_id = p_tenant and x.document_id = p_doc group by x.item_id) g
              on g.item_id = w.item_id
           where w.qty is distinct from g.qty) y
    left join erp.items i on i.tenant_id = p_tenant and i.item_id = y.item_id;
  if bad is not null then
    probs := probs || erp.problem('mismatch', 'lines', format('The lines must be the transfer difference exactly (items %s).', bad));
  end if;
  return probs;
end $$;

-- ---------------------------------------------------------------------
-- 5. The type's own work (doc_types.action_fn, called by E130 erp.doc_set_state / erp.doc_ref_changed)
-- ---------------------------------------------------------------------
-- receipt by line (dispatched -> received | received_with_difference). p_options: receipt_date (default today; not
-- before the dispatch, not in the future, not in a locked period), lines [{line_id, received_qty, reason}] (a line
-- not listed is received as dispatched; a difference needs a reason). The target state must match the quantities.
create or replace function erp.trf_receive(p_tenant uuid, p_doc uuid, p_to text, p_options jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d erp.documents; tw uuid; dw erp.warehouses; dest_br uuid; probs jsonb := '[]'; rdate date; lock_d date; e jsonb; n int := 0; l record; ids uuid[] := '{}';
        r numeric; moved numeric; src bigint; m1 bigint; m2 bigint; bal numeric; has_diff boolean := false; aout uuid; ain uuid; me erp.members;
        rq jsonb := '{}'; rs jsonb := '{}';
begin
  me := erp.current_member();
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc;   -- locked by doc_lock (doc_set_state)
  probs := erp.unknown_keys(p_options, array['receipt_date', 'lines', 'ack_warnings']);
  -- receipt date
  if erp.jset(p_options, 'receipt_date') then
    if (p_options ->> 'receipt_date') !~ '^\d{4}-\d{2}-\d{2}$' then probs := probs || erp.problem('invalid', 'receipt_date', 'Date: yyyy-mm-dd.');
    else begin rdate := (p_options ->> 'receipt_date')::date; exception when others then probs := probs || erp.problem('invalid', 'receipt_date', 'Not a real date.'); end; end if;
  else rdate := erp.today(p_tenant); end if;
  if rdate < d.doc_date then probs := probs || erp.problem('invalid', 'receipt_date', format('The receipt cannot be before the dispatch (%s).', to_char(d.doc_date, 'DD/MM/YYYY'))); end if;
  if rdate > erp.today(p_tenant) then probs := probs || erp.problem('future_date', 'receipt_date', 'The receipt date is in the future.'); end if;
  -- lines given by the receiver
  if p_options ? 'lines' and jsonb_typeof(p_options -> 'lines') <> 'array' then probs := probs || erp.problem('invalid', 'lines', 'lines must be a list.');
  elsif p_options ? 'lines' then
    for e in select * from jsonb_array_elements(p_options -> 'lines') loop
      n := n + 1;
      if jsonb_typeof(e) <> 'object' then probs := probs || erp.problem('invalid', 'lines', 'A line must be an object.', n); continue; end if;
      probs := probs || (select coalesce(jsonb_agg(erp.problem('not_editable', x, format('%s cannot be set on a receipt line.', x), n)), '[]'::jsonb) from jsonb_object_keys(e) x
                          where not (x = any (array['line_id', 'received_qty', 'reason'])));
      if erp.try_uuid(e ->> 'line_id') is null
         or not exists (select 1 from erp.document_lines x where x.tenant_id = p_tenant and x.document_id = p_doc and x.line_id = erp.try_uuid(e ->> 'line_id')) then
        probs := probs || erp.problem('invalid', 'line_id', 'Not a line of this transfer.', n); continue;
      end if;
      if (e ->> 'line_id')::uuid = any (ids) then probs := probs || erp.problem('duplicate', 'line_id', 'The line is given twice.', n); continue; end if;
      ids := ids || (e ->> 'line_id')::uuid;
      r := erp.try_numeric(e ->> 'received_qty');
      if r is null or r < 0 or r >= 1e12 or r <> round(r, 4) then probs := probs || erp.problem('invalid', 'received_qty', 'Received quantity: a number of 0 or more, at most 4 decimals.', n); continue; end if;
      if length(e ->> 'reason') > 200 then probs := probs || erp.problem('invalid', 'reason', 'Reason: at most 200 characters.', n); end if;
      rq := rq || jsonb_build_object(e ->> 'line_id', r);
      if erp.jset(e, 'reason') then rs := rs || jsonb_build_object(e ->> 'line_id', btrim(e ->> 'reason')); end if;
    end loop;
  end if;
  for l in select x.* from erp.document_lines x where x.tenant_id = p_tenant and x.document_id = p_doc order by x.line_no loop
    r := coalesce((rq ->> l.line_id::text)::numeric, l.qty_base);
    if r <> l.qty_base then
      has_diff := true;
      if nullif(rs ->> l.line_id::text, '') is null then probs := probs || erp.problem('required', 'reason', 'A difference needs a reason.', l.line_no); end if;
    end if;
  end loop;
  select * into dw from erp.warehouses w where w.tenant_id = p_tenant and w.warehouse_id = d.dest_warehouse_id;
  if not dw.active then probs := probs || erp.problem('inactive', 'dest_warehouse_id', format('Warehouse %s is not active: cancel the transfer instead.', dw.code)); end if;
  if jsonb_array_length(probs) = 0 and has_diff <> (p_to = 'received_with_difference') then
    probs := probs || erp.problem('state', 'to_state', case when has_diff then 'The received quantities differ from the dispatch: confirm as received_with_difference.'
                                                            else 'The received quantities equal the dispatch: confirm as received.' end);
  end if;
  perform erp.raise_problems(probs);
  -- lock date (FOR SHARE, as E130 post / cancel: F2-03)
  select st.lock_date into lock_d from erp.tenant_settings st where st.tenant_id = p_tenant for share;
  if lock_d is not null and rdate <= lock_d then
    perform erp.err('ERP_LOCKED_PERIOD', format('The period up to %s is locked: a receipt dated %s cannot be posted.', to_char(lock_d, 'DD/MM/YYYY'), to_char(rdate, 'DD/MM/YYYY')));
  end if;
  -- locks: items ascending (the document row is already locked), then balances
  perform erp.stock_lock(p_tenant, p_doc);
  tw := erp.transit_warehouse(p_tenant);
  dest_br := dw.branch_id;
  -- the difference first: generated ADJ DRAFTS of the destination branch (the normal ADJ path follows: value limit,
  -- submit / approve / reject). Shortage = ADJ_OUT out of transit (it stays there until then); excess = ADJ_IN into
  -- the destination. No number and no stock now (their own post, in their own transaction: 02 lock order).
  for l in select x.item_id, x.unit_id, x.line_no, coalesce((rq ->> x.line_id::text)::numeric, x.qty_base) - x.qty_base dq, rs ->> x.line_id::text reason
             from erp.document_lines x where x.tenant_id = p_tenant and x.document_id = p_doc order by x.line_no loop
    continue when l.dq = 0;
    if l.dq < 0 and aout is null then
      insert into erp.documents (tenant_id, doc_type, branch_id, doc_date, warehouse_id, ref_document_id, extra, notes, source, created_by)
      values (p_tenant, 'ADJ_OUT', dest_br, rdate, tw, p_doc, '{"reason": "lost"}', format('Transfer %s: shortage on receipt (out of transit).', d.doc_no), 'system', me.member_id)
      returning document_id into aout;
    elsif l.dq > 0 and ain is null then
      insert into erp.documents (tenant_id, doc_type, branch_id, doc_date, warehouse_id, ref_document_id, extra, notes, source, created_by)
      values (p_tenant, 'ADJ_IN', dest_br, rdate, d.dest_warehouse_id, p_doc, '{"reason": "found"}', format('Transfer %s: more received than dispatched.', d.doc_no), 'system', me.member_id)
      returning document_id into ain;
    end if;
    insert into erp.document_lines (tenant_id, document_id, line_no, item_id, description, qty, unit_id, qty_base)
    values (p_tenant, case when l.dq < 0 then aout else ain end,
            (select coalesce(max(z.line_no), 0) + 1 from erp.document_lines z where z.tenant_id = p_tenant and z.document_id = case when l.dq < 0 then aout else ain end),
            l.item_id, left(l.reason, 500), abs(l.dq), l.unit_id, abs(l.dq));
  end loop;
  if aout is not null then
    perform erp.audit(p_tenant, 'doc.create', 'documents', aout::text, null, jsonb_build_object('doc_type', 'ADJ_OUT', 'source', 'system', 'transfer', p_doc), dest_br);
  end if;
  if ain is not null then
    perform erp.audit(p_tenant, 'doc.create', 'documents', ain::text, null, jsonb_build_object('doc_type', 'ADJ_IN', 'source', 'system', 'transfer', p_doc), dest_br);
  end if;
  -- the receipt header (written once; closed now when nothing differs) and, per line, the transit -> destination moves
  insert into erp.doc_trf (tenant_id, document_id, receipt_date, received_by, adj_out_id, adj_in_id, closed_at)
  values (p_tenant, p_doc, rdate, me.member_id, aout, ain, case when not has_diff then now() end);
  for l in select x.*, i.code item_code from erp.document_lines x join erp.items i on i.tenant_id = x.tenant_id and i.item_id = x.item_id
            where x.tenant_id = p_tenant and x.document_id = p_doc and i.kind <> 'service' order by x.line_no loop
    r := coalesce((rq ->> l.line_id::text)::numeric, l.qty_base);
    moved := least(r, l.qty_base);
    if moved > 0 then
      -- transit never below zero (02 / 05 question 3): blocked, whatever the tenant setting
      select b.qty into bal from erp.stock_balances b where b.tenant_id = p_tenant and b.warehouse_id = tw and b.item_id = l.item_id
                                                         and b.lot_id = '00000000-0000-0000-0000-000000000000';
      if coalesce(bal, 0) < moved then
        perform erp.err('ERP_STOCK_NEGATIVE', format('%s in transit would go to %s: the transit warehouse never goes below zero.', l.item_code, coalesce(bal, 0) - moved),
                        jsonb_build_array(jsonb_build_object('code', 'W_STOCK_NEGATIVE', 'item_id', l.item_id, 'item_code', l.item_code, 'warehouse_id', tw,
                                                             'warehouse_code', 'TRANSIT', 'qty_after', coalesce(bal, 0) - moved)));
      end if;
      -- both receipt moves carry the cost of the line's dispatch move (cost rule 'transfer' with src_move_id)
      select m.move_id into src from erp.stock_moves m
       where m.tenant_id = p_tenant and m.document_id = p_doc and m.line_id = l.line_id and m.kind = 'normal' and m.cost_rule = 'transfer'
         and m.src_move_id is null and m.qty_base < 0
         and not exists (select 1 from erp.stock_moves x where x.tenant_id = p_tenant and x.reverses_move_id = m.move_id)
       order by m.move_id limit 1;
      insert into erp.stock_moves (tenant_id, document_id, line_id, warehouse_id, item_id, move_date, kind, qty_base, cost_rule, src_move_id, fallback_cost)
      values (p_tenant, p_doc, l.line_id, tw, l.item_id, rdate, 'normal', -moved, 'transfer', src,
              coalesce((select i.last_purchase_price from erp.items i where i.tenant_id = p_tenant and i.item_id = l.item_id), 0))
      returning move_id into m1;
      perform erp.balance_add(p_tenant, tw, l.item_id, '00000000-0000-0000-0000-000000000000', -moved, m1);
      insert into erp.stock_moves (tenant_id, document_id, line_id, warehouse_id, item_id, move_date, kind, qty_base, cost_rule, src_move_id, fallback_cost)
      values (p_tenant, p_doc, l.line_id, d.dest_warehouse_id, l.item_id, rdate, 'normal', moved, 'transfer', src,
              coalesce((select i.last_purchase_price from erp.items i where i.tenant_id = p_tenant and i.item_id = l.item_id), 0))
      returning move_id into m2;
      perform erp.balance_add(p_tenant, d.dest_warehouse_id, l.item_id, '00000000-0000-0000-0000-000000000000', moved, m2);
      perform erp.stock_cost_new(p_tenant, p_doc, l.item_id, rdate, array[m1, m2]);
    end if;
    insert into erp.doc_trf_lines (tenant_id, line_id, document_id, received_qty, diff_qty, diff_reason)
    values (p_tenant, l.line_id, p_doc, r, r - l.qty_base, nullif(rs ->> l.line_id::text, ''));
  end loop;
  perform erp.stock_alerts(p_tenant, p_doc);
  perform erp.audit(p_tenant, 'trf.receipt', 'doc_trf', p_doc::text, null,
                    jsonb_build_object('receipt_date', rdate, 'difference', has_diff, 'adj_out', aout, 'adj_in', ain,
                                       'lines', (select jsonb_agg(jsonb_build_object('line_id', t.line_id, 'received', t.received_qty, 'diff', t.diff_qty) order by t.line_id)
                                                   from erp.doc_trf_lines t where t.tenant_id = p_tenant and t.document_id = p_doc)), dest_br);
  return jsonb_build_object('receipt_date', rdate, 'adjustments', to_jsonb(array_remove(array[aout, ain], null)));
end $$;

-- received_with_difference -> closed: every generated adjustment is posted and the transfer holds nothing in transit
create or replace function erp.trf_close(p_tenant uuid, p_doc uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t erp.doc_trf; a record;
begin
  select * into t from erp.doc_trf x where x.tenant_id = p_tenant and x.document_id = p_doc;
  for a in select x.doc_type, x.doc_no, x.state from erp.documents x
            where x.tenant_id = p_tenant and x.document_id in (t.adj_out_id, t.adj_in_id) and x.state <> 'posted' loop
    perform erp.err('ERP_STATE', format('The transfer waits for its difference adjustment %s (%s): post or approve it first.', a.doc_type, a.state));
  end loop;
  if exists (select 1 from erp.trf_transit_left(p_tenant, p_doc) z where z.qty <> 0) then
    perform erp.err('ERP_STATE', 'The transfer still holds stock in transit: it cannot be closed.');
  end if;
  update erp.doc_trf set closed_at = now() where tenant_id = p_tenant and document_id = p_doc;
  return '{}'::jsonb;
end $$;

-- a document referencing the transfer changed state (E130 erp.doc_ref_changed). Only the generated adjustments matter:
-- posted -> the transfer closes when all of them are (as the poster, when it may close it: doc_transitions row
-- received_with_difference -> closed; else it waits for the manual close); cancelled -> refused (the difference
-- would come back into transit of a settled transfer: a new, normal ADJ corrects a wrong difference).
create or replace function erp.trf_child(p_tenant uuid, p_doc uuid, p_child uuid, p_state text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d erp.documents; t erp.doc_trf;
begin
  -- the transfer row first, then the check (two adjustments posted at the same moment: the second one sees the first)
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc for update;
  select * into t from erp.doc_trf x where x.tenant_id = p_tenant and x.document_id = p_doc;
  if t.document_id is null or p_child is distinct from t.adj_out_id and p_child is distinct from t.adj_in_id then return '{}'::jsonb; end if;
  if p_state = 'cancelled' then
    perform erp.err('ERP_DOC_HAS_CHILDREN', format('This adjustment settles the difference of transfer %s: it cannot be cancelled (post a new adjustment instead).', d.doc_no));
  end if;
  if p_state = 'posted' and d.state = 'received_with_difference'
     and not exists (select 1 from erp.documents x where x.tenant_id = p_tenant and x.document_id in (t.adj_out_id, t.adj_in_id) and x.state <> 'posted')
     and erp.doc_can(p_tenant, d, 'create', 'dest') and erp.doc_can_read(p_tenant, d) then
    perform erp.doc_set_state(p_tenant, p_doc, 'closed', '{}'::jsonb);
    return jsonb_build_object('closed', true);
  end if;
  return '{}'::jsonb;
end $$;

-- doc_types.action_fn of TRF: receive | close (transition actions) | child (notification)
create or replace function erp.trf_action(p_tenant uuid, p_doc uuid, p_action text, p_to text, p_options jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  return case p_action
    when 'receive' then jsonb_build_object('receipt', erp.trf_receive(p_tenant, p_doc, p_to, p_options))
    when 'close' then erp.trf_close(p_tenant, p_doc)
    when 'child' then erp.trf_child(p_tenant, p_doc, erp.try_uuid(p_options ->> 'child_id'), p_options ->> 'state')
  end;
end $$;

-- ---------------------------------------------------------------------
-- 6. Guards
-- ---------------------------------------------------------------------
-- a generated difference adjustment is never deleted (the transfer could not close any more)
create or replace function erp.tg_documents_trf_adj_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if exists (select 1 from erp.doc_trf t where t.tenant_id = old.tenant_id and (t.adj_out_id = old.document_id or t.adj_in_id = old.document_id)) then
    perform erp.err('ERP_STATE', 'This adjustment settles a transfer difference: it cannot be deleted (post it, or have it rejected and corrected).');
  end if;
  return old;
end $$;
drop trigger if exists documents_trf_adj_guard on erp.documents;
create trigger documents_trf_adj_guard before delete on erp.documents for each row execute function erp.tg_documents_trf_adj_guard();

-- the source / destination warehouse of an OPEN transfer keeps its branch and stays active (the destination's branch
-- decides who receives; a cancel returns the stock to the source)
create or replace function erp.tg_warehouses_trf_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (new.branch_id is distinct from old.branch_id or (old.active and not new.active))
     and exists (select 1 from erp.documents d where d.tenant_id = old.tenant_id and d.doc_type = 'TRF' and d.state in ('dispatched', 'received_with_difference')
                    and (d.warehouse_id = old.warehouse_id or d.dest_warehouse_id = old.warehouse_id)) then
    perform erp.err('ERP_VALIDATION', format('Warehouse %s has open transfers: receive or cancel them first.', old.code),
                    jsonb_build_array(erp.problem('in_use', case when new.branch_id is distinct from old.branch_id then 'branch_id' else 'active' end,
                                                  format('Warehouse %s has open transfers.', old.code))));
  end if;
  return new;
end $$;
drop trigger if exists warehouses_trf_guard on erp.warehouses;
create trigger warehouses_trf_guard before update of branch_id, active on erp.warehouses for each row execute function erp.tg_warehouses_trf_guard();

-- ---------------------------------------------------------------------
-- 7. Integrity (called by E140 erp.integrity_job): problems as a jsonb array, empty = sound.
--    transit_negative: the transit warehouse below zero; transit_open: a transfer holds in transit exactly what it
--    should (dispatched: the dispatched quantity; received_with_difference: the shortage until its ADJ_OUT is
--    posted; received / closed / cancelled: nothing); transit_value: a settled transfer without a shortage
--    adjustment left no value in transit (cost unchanged through transit).
-- ---------------------------------------------------------------------
create or replace function erp.trf_integrity(p_tenant uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with tw as (select erp.transit_warehouse(p_tenant) w),
  trf as (select d.document_id, d.doc_no, d.state, t.adj_out_id,
                 (select a.state from erp.documents a where a.tenant_id = d.tenant_id and a.document_id = t.adj_out_id) adj_out_state
            from erp.documents d left join erp.doc_trf t on t.tenant_id = d.tenant_id and t.document_id = d.document_id
           where d.tenant_id = p_tenant and d.doc_type = 'TRF' and d.state <> 'draft'),
  want as (select x.document_id, l.item_id,
                  sum(case when x.state = 'dispatched' then l.qty_base
                           when x.state = 'received_with_difference' and x.adj_out_state is distinct from 'posted' then greatest(-coalesce(tl.diff_qty, 0), 0)
                           else 0 end) qty
             from trf x join erp.document_lines l on l.tenant_id = p_tenant and l.document_id = x.document_id
             left join erp.doc_trf_lines tl on tl.tenant_id = p_tenant and tl.line_id = l.line_id
            group by x.document_id, l.item_id),
  have as (select m.document_id trf_id, m.item_id, sum(m.qty_base) qty, sum(m.value_avg) va, sum(m.value_fifo) vf
             from (select coalesce(x.document_id, y.document_id) document_id, m.item_id, m.qty_base, m.value_avg, m.value_fifo
                     from erp.stock_moves m
                     left join trf x on x.document_id = m.document_id
                     left join trf y on y.adj_out_id = m.document_id
                    where m.tenant_id = p_tenant and m.warehouse_id = (select w from tw)) m
            where m.document_id is not null
            group by m.document_id, m.item_id)
  select coalesce(jsonb_agg(p), '[]'::jsonb) from (
    select jsonb_build_object('check', 'transit_negative', 'item_id', b.item_id, 'qty', b.qty) p
      from erp.stock_balances b where b.tenant_id = p_tenant and b.warehouse_id = (select w from tw) and b.qty < 0
    union all
    select jsonb_build_object('check', 'transit_open', 'document_id', coalesce(w.document_id, h.trf_id), 'item_id', coalesce(w.item_id, h.item_id),
                              'expected', coalesce(w.qty, 0), 'in_transit', coalesce(h.qty, 0))
      from want w full join have h on h.trf_id = w.document_id and h.item_id = w.item_id
     where coalesce(w.qty, 0) <> coalesce(h.qty, 0)
    union all
    select jsonb_build_object('check', 'transit_value', 'document_id', x.document_id, 'value_avg', sum(h.va), 'value_fifo', sum(h.vf))
      from trf x join have h on h.trf_id = x.document_id
     where x.state in ('received', 'closed', 'cancelled') and x.adj_out_id is null
     group by x.document_id
    having sum(h.va) <> 0 or sum(h.vf) <> 0
  ) z
$$;

-- ---------------------------------------------------------------------
-- 8. RPC: trf_get (the transfer screen of T18): the document (doc_json) + the transfer block: source and destination
--    branch, fiscal hook flag, receipt (date, by), per line dispatched / received / difference / reason and what is
--    still in transit, the generated adjustments with their state. Read on the source or the destination branch.
-- ---------------------------------------------------------------------
create or replace function erp_api.trf_get(p_document_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; d erp.documents; t erp.doc_trf;
begin
  m := erp.require_member();
  perform erp.doc_visible(m.tenant_id, p_document_id);
  select * into d from erp.documents where tenant_id = m.tenant_id and document_id = p_document_id;
  if d.doc_type <> 'TRF' then
    perform erp.raise_problems(jsonb_build_array(erp.problem('invalid', 'p_document_id', 'Not a transfer.')));
  end if;
  select * into t from erp.doc_trf x where x.tenant_id = m.tenant_id and x.document_id = p_document_id;
  return erp.doc_json(m.tenant_id, p_document_id) || jsonb_build_object('transfer', jsonb_build_object(
    'source_branch_id', d.branch_id, 'dest_branch_id', erp.doc_dest_branch(m.tenant_id, d),
    'dest_warehouse_code', (select w.code from erp.warehouses w where w.tenant_id = d.tenant_id and w.warehouse_id = d.dest_warehouse_id),
    'fiscal_needed', erp.trf_fiscal_needed(m.tenant_id, p_document_id),
    'receipt', case when t.document_id is null then null else jsonb_build_object('receipt_date', t.receipt_date, 'received_at', t.received_at,
               'received_by_email', (select x.email from erp.members x where x.tenant_id = t.tenant_id and x.member_id = t.received_by), 'closed_at', t.closed_at) end,
    'lines', coalesce((select jsonb_agg(jsonb_build_object('line_id', l.line_id, 'line_no', l.line_no, 'item_id', l.item_id, 'dispatched_qty', l.qty_base,
                                                           'received_qty', tl.received_qty, 'diff_qty', tl.diff_qty, 'diff_reason', tl.diff_reason,
                                                           'in_transit', coalesce((select z.qty from erp.trf_transit_left(m.tenant_id, p_document_id) z where z.item_id = l.item_id), 0))
                                        order by l.line_no)
                         from erp.document_lines l left join erp.doc_trf_lines tl on tl.tenant_id = l.tenant_id and tl.line_id = l.line_id
                        where l.tenant_id = m.tenant_id and l.document_id = p_document_id), '[]'::jsonb),
    'adjustments', coalesce((select jsonb_agg(jsonb_build_object('document_id', a.document_id, 'doc_type', a.doc_type, 'state', a.state, 'doc_no', a.doc_no) order by a.doc_type)
                               from erp.documents a where a.tenant_id = m.tenant_id and a.document_id in (t.adj_out_id, t.adj_in_id)), '[]'::jsonb)));
end $$;

-- trf_warehouses (T18): the warehouses a transfer can name, of EVERY branch of the tenant (warehouse_list shows only
-- the caller's branches, but a destination is usually another clinic). Normal warehouses only (never the transit
-- warehouse), inactive ones too (flag `active`: the picker offers the active ones; the list labels old transfers).
-- Cap doc.trf.read on any branch. Codes / names only: no stock, no cost.
create or replace function erp_api.trf_warehouses() returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members;
begin
  m := erp.require_member();
  perform erp.require_cap('doc.trf.read');
  return jsonb_build_object('rows', coalesce((
    select jsonb_agg(jsonb_build_object('warehouse_id', w.warehouse_id, 'branch_id', w.branch_id, 'branch_code', b.code, 'code', w.code, 'name', w.name,
                                        'active', w.active and b.active) order by lower(w.code), w.warehouse_id)
      from erp.warehouses w join erp.branches b on b.tenant_id = w.tenant_id and b.branch_id = w.branch_id
     where w.tenant_id = m.tenant_id and w.kind = 'normal'), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 9. RLS + grants (receipt rows: tenant + the transfer is visible: documents policy, as document_lines)
-- ---------------------------------------------------------------------
alter table erp.doc_trf enable row level security;
alter table erp.doc_trf force row level security;
alter table erp.doc_trf_lines enable row level security;
alter table erp.doc_trf_lines force row level security;
drop policy if exists doc_trf_read on erp.doc_trf;
create policy doc_trf_read on erp.doc_trf for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[])
         and exists (select 1 from erp.documents d where d.tenant_id = doc_trf.tenant_id and d.document_id = doc_trf.document_id));
drop policy if exists doc_trf_lines_read on erp.doc_trf_lines;
create policy doc_trf_lines_read on erp.doc_trf_lines for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[])
         and exists (select 1 from erp.documents d where d.tenant_id = doc_trf_lines.tenant_id and d.document_id = doc_trf_lines.document_id));
do $$ declare r text; begin
  foreach r in array array['public', 'anon', 'service_role'] loop
    if r = 'public' or exists (select 1 from pg_catalog.pg_roles where rolname = r) then
      execute format('revoke all on erp.doc_trf, erp.doc_trf_lines from %s', r);
    end if;
  end loop;
end $$;
revoke insert, update, delete, truncate, references, trigger on erp.doc_trf, erp.doc_trf_lines from authenticated;
grant select on erp.doc_trf, erp.doc_trf_lines to authenticated;

select erp.lock_down();
grant execute on function erp_api.trf_get(uuid) to authenticated;
grant execute on function erp_api.trf_warehouses() to authenticated;
