-- =====================================================================
-- iSmile ERP  -  E150_stock_docs.sql   (tasks T11, T12)
-- Purpose : the stock document types of E2 (01 C1 / C3): OPN opening balance, GRN goods receipt without PO (T11),
--           ADJ_IN / ADJ_OUT stock adjustments with a value approval limit, CONS internal consumption (cost centre,
--           ext_ref; reversal = cancel) (T12), with their capabilities, transitions and validator; the opening-stock
--           CSV import (T11); doc_check (problems + negative-stock warnings before posting), the negative-stock report
--           (view erp.rpt_erp_negative_stock + RPC report_negative_stock) (T12).
-- Run order: after E140. Standalone: names no CRM object. Safe to re-run.
-- Redefines: nothing. Enables catalogue rows of erp.doc_types (E120) and sets their posting columns (E130).
-- T16      : doc_stock_validate calls erp.trf_adj_validate (E160) for every ADJ (transfer difference adjustments).
-- Draft 1  : doc_stock_validate calls erp.grn_dn_validate (E190) for every GRN (lines read from a delivery note).
-- Tests    : tests/E150_stock_docs_tests.sql, tests/E990 (registry)
-- =====================================================================

do $$ begin
  if to_regprocedure('erp.cost_move(uuid,bigint,bigint)') is null then raise exception 'run E140_stock_engine.sql first'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Types (03 recipe step 1). Seeded rows change only by this explicit, versioned update.
-- ---------------------------------------------------------------------
update erp.doc_types set enabled = true, stock_sign = 1, cost_rule = 'line', needs_warehouse = true, price_kind = 'cost', needs_counterparty = false,
       header_extra = '{}', line_extra = '{}', validator = 'doc_stock_validate', seed_version = 2
 where doc_type = 'OPN' and seed_version < 2;
update erp.doc_types set enabled = true, stock_sign = 1, cost_rule = 'line', needs_warehouse = true, price_kind = 'cost', needs_counterparty = true,
       header_extra = '{mark}', line_extra = '{}', validator = 'doc_stock_validate', seed_version = 2
 where doc_type = 'GRN' and seed_version < 2;

update erp.doc_types set enabled = true, stock_sign = 1, cost_rule = 'line_or_current', needs_warehouse = true, price_kind = 'cost', needs_counterparty = false,
       approval_key = 'adj_value', header_extra = '{reason}', line_extra = '{}', validator = 'doc_stock_validate', seed_version = 2
 where doc_type = 'ADJ_IN' and seed_version < 2;
update erp.doc_types set enabled = true, stock_sign = -1, cost_rule = 'issue', needs_warehouse = true, price_kind = 'none', needs_counterparty = false,
       approval_key = 'adj_value', header_extra = '{reason}', line_extra = '{}', validator = 'doc_stock_validate', seed_version = 2
 where doc_type = 'ADJ_OUT' and seed_version < 2;
update erp.doc_types set enabled = true, stock_sign = -1, cost_rule = 'issue', needs_warehouse = true, price_kind = 'none', needs_counterparty = false,
       header_extra = '{cost_centre}', line_extra = '{}', validator = 'doc_stock_validate', seed_version = 2
 where doc_type = 'CONS' and seed_version < 2;

-- transitions (02 state machines; 01 C1 / C3 "create / approve / void"):
--   OPN  M O / O / O : a manager prepares, the owner posts (approval), the owner cancels
--   GRN  W M O / - / M O
insert into erp.doc_transitions (doc_type, from_state, to_state, cap, condition, action, label, sort) values
  ('OPN', 'draft', 'pending_approval', 'create', null, 'none', 'doc.action.submit', 20),
  ('OPN', 'draft', 'posted', 'approve', null, 'post', 'doc.action.post', 10),
  ('OPN', 'pending_approval', 'posted', 'approve', null, 'post', 'doc.action.approve', 30),
  ('OPN', 'pending_approval', 'draft', 'approve', null, 'none', 'doc.action.reject', 40),
  ('OPN', 'posted', 'cancelled', 'approve', null, 'cancel', 'doc.action.cancel', 90),
  ('GRN', 'draft', 'posted', 'create', null, 'post', 'doc.action.post', 10),
  ('GRN', 'posted', 'cancelled', 'approve', null, 'cancel', 'doc.action.cancel', 90),
  ('CONS', 'draft', 'posted', 'create', null, 'post', 'doc.action.post', 10),
  ('CONS', 'posted', 'cancelled', 'approve', null, 'cancel', 'doc.action.reverse', 90)
on conflict do nothing;
--   ADJ  W M O / M O above the tenant value limit / M O (thresholds.adj_value; no limit set = no approval)
insert into erp.doc_transitions (doc_type, from_state, to_state, cap, condition, action, label, sort)
select dt, f, t2, c, cond, a, l, srt from unnest(array['ADJ_IN', 'ADJ_OUT']) dt, (values
  ('draft', 'posted', 'create', 'under_threshold', 'post', 'doc.action.post', 10),
  ('draft', 'posted', 'approve', null, 'post', 'doc.action.post', 10),
  ('draft', 'pending_approval', 'create', 'over_threshold', 'none', 'doc.action.submit', 20),
  ('pending_approval', 'posted', 'approve', null, 'post', 'doc.action.approve', 30),
  ('pending_approval', 'draft', 'approve', null, 'none', 'doc.action.reject', 40),
  ('posted', 'cancelled', 'approve', null, 'cancel', 'doc.action.cancel', 90)) v(f, t2, c, cond, a, l, srt)
on conflict do nothing;

insert into erp.capabilities (capability, area, note) values
  ('doc.opn.read', 'stock', 'opening balances'), ('doc.opn.create', 'stock', 'prepare opening balances'), ('doc.opn.approve', 'stock', 'post / cancel opening balances (owner)'),
  ('doc.grn.read', 'stock', 'goods receipts'), ('doc.grn.create', 'stock', 'register and post goods receipts'), ('doc.grn.approve', 'stock', 'cancel goods receipts'),
  ('doc.adj.read', 'stock', 'stock adjustments + / -'), ('doc.adj.create', 'stock', 'post adjustments up to the limit'), ('doc.adj.approve', 'stock', 'approve / cancel adjustments'),
  ('doc.cons.read', 'stock', 'internal consumption'), ('doc.cons.create', 'stock', 'post consumption'), ('doc.cons.approve', 'stock', 'reverse consumption'),
  ('stock.read', 'stock', 'on hand, stock card, negative-stock report (quantities; values need cost.read)')
on conflict (capability) do nothing;
-- 02 matrix "PO, GRN, PRET": owner c a, manager c a, warehouse c, accounting r, clinic_user -, readonly r. OPN (01 C3):
-- create manager / owner, approve owner; read as the stock documents.
insert into erp.role_cap_defaults (role, capability)
select r, c from (values
  ('owner', 'doc.opn.read'), ('owner', 'doc.opn.create'), ('owner', 'doc.opn.approve'), ('owner', 'doc.grn.read'), ('owner', 'doc.grn.create'), ('owner', 'doc.grn.approve'),
  ('manager', 'doc.opn.read'), ('manager', 'doc.opn.create'), ('manager', 'doc.grn.read'), ('manager', 'doc.grn.create'), ('manager', 'doc.grn.approve'),
  ('warehouse', 'doc.opn.read'), ('warehouse', 'doc.grn.read'), ('warehouse', 'doc.grn.create'),
  ('accounting', 'doc.opn.read'), ('accounting', 'doc.grn.read'),
  ('readonly', 'doc.opn.read'), ('readonly', 'doc.grn.read'),
  -- T12. 02 "TRF, ADJ, STK": owner c a, manager c a, warehouse c (approve: no), accounting r, clinic_user -, readonly r;
  -- "CONS": owner c a, manager c a, warehouse c, accounting r, clinic_user c (own branch), readonly r; on hand: everyone
  ('owner', 'doc.adj.read'), ('owner', 'doc.adj.create'), ('owner', 'doc.adj.approve'), ('owner', 'doc.cons.read'), ('owner', 'doc.cons.create'), ('owner', 'doc.cons.approve'),
  ('manager', 'doc.adj.read'), ('manager', 'doc.adj.create'), ('manager', 'doc.adj.approve'), ('manager', 'doc.cons.read'), ('manager', 'doc.cons.create'), ('manager', 'doc.cons.approve'),
  ('warehouse', 'doc.adj.read'), ('warehouse', 'doc.adj.create'), ('warehouse', 'doc.cons.read'), ('warehouse', 'doc.cons.create'),
  ('accounting', 'doc.adj.read'), ('accounting', 'doc.cons.read'),
  ('clinic_user', 'doc.cons.read'), ('clinic_user', 'doc.cons.create'),
  ('readonly', 'doc.adj.read'), ('readonly', 'doc.cons.read'),
  ('owner', 'stock.read'), ('manager', 'stock.read'), ('warehouse', 'stock.read'), ('accounting', 'stock.read'), ('clinic_user', 'stock.read'), ('readonly', 'stock.read')) v(r, c)
on conflict do nothing;
select erp.role_caps_sync();

-- ---------------------------------------------------------------------
-- 2. Validator of the stock documents (03 recipe step 3; called by erp.doc_validate through doc_types.validator)
-- ---------------------------------------------------------------------
create or replace function erp.doc_stock_validate(p_tenant uuid, p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare d erp.documents; probs jsonb := '[]'; ck text;
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc;
  if d.doc_type = 'GRN' then
    select c.kind into ck from erp.counterparties c where c.tenant_id = p_tenant and c.counterparty_id = d.counterparty_id;
    if ck = 'customer' then probs := probs || erp.problem('invalid', 'counterparty_id', 'A goods receipt needs a supplier.'); end if;
    if d.extra ? 'mark' and (d.extra ->> 'mark') !~ '^[0-9]{1,20}$' then probs := probs || erp.problem('invalid', 'extra.mark', 'MARK: the myDATA number (digits).'); end if;
    if d.ext_date is not null and d.ext_date > d.doc_date then probs := probs || erp.problem('invalid', 'ext_date', 'The supplier''s document date is after the receipt.'); end if;
    -- Draft 1 (E190): a GRN drafted from a supplier delivery note keeps unmatched / low-confidence lines flagged
    if to_regprocedure('erp.grn_dn_validate(uuid,uuid)') is not null then probs := probs || erp.grn_dn_validate(p_tenant, p_doc); end if;
  end if;
  if d.doc_type in ('ADJ_IN', 'ADJ_OUT') then
    if nullif(d.extra ->> 'reason', '') is null then probs := probs || erp.problem('required', 'extra.reason', 'Choose the reason of the adjustment.');
    elsif (d.doc_type = 'ADJ_IN' and d.extra ->> 'reason' not in ('found', 'correction'))
       or (d.doc_type = 'ADJ_OUT' and d.extra ->> 'reason' not in ('damaged', 'expired', 'lost', 'correction')) then
      probs := probs || erp.problem('invalid', 'extra.reason', format('Reason %s is not valid for %s.', d.extra ->> 'reason', d.doc_type)); end if;
  end if;
  -- T16 (E160): a transfer's generated difference adjustment stays as generated; no other ADJ references a transfer
  if d.doc_type in ('ADJ_IN', 'ADJ_OUT') and to_regprocedure('erp.trf_adj_validate(uuid,uuid)') is not null then
    probs := probs || erp.trf_adj_validate(p_tenant, p_doc);
  end if;
  if d.doc_type = 'CONS' and length(d.extra ->> 'cost_centre') > 60 then probs := probs || erp.problem('invalid', 'extra.cost_centre', 'Cost centre: at most 60 characters.'); end if;
  if d.doc_type in ('OPN', 'GRN') then
    probs := probs || coalesce((select jsonb_agg(erp.problem('duplicate', 'item_id', format('Item %s is on several lines: merge them.', i.code), x.line_no) order by x.line_no)
                                  from (select l.item_id, min(l.line_no) line_no from erp.document_lines l
                                         where l.tenant_id = p_tenant and l.document_id = p_doc and d.doc_type = 'OPN' and l.item_id is not null
                                         group by l.item_id having count(*) > 1) x join erp.items i on i.tenant_id = p_tenant and i.item_id = x.item_id), '[]'::jsonb);
  end if;
  return probs;
end $$;

-- ---------------------------------------------------------------------
-- 3. Opening-stock CSV import (T11, 01 F): rows {item (code), qty, unit_cost} -> ONE OPN DRAFT of the warehouse
--    (the owner posts it). All or nothing; dry run; problems with their row number; at most 2000 rows (one opening
--    document may be larger than the 500 lines of the screen). p_doc: branch_id, warehouse_id, doc_date (optional).
--    Reply {dry_run, rows, total_value, errors, document (when created)}.
-- ---------------------------------------------------------------------
create or replace function erp_api.opening_import(p_doc jsonb, p_rows jsonb, p_dry_run boolean, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; payload jsonb := jsonb_build_object('doc', p_doc, 'rows', p_rows, 'dry_run', p_dry_run); v_branch uuid; v_wh uuid; v_date date;
        r jsonb; n int := 0; probs jsonb := '[]'; one jsonb; it erp.items; q numeric; c numeric; seen uuid[] := '{}'; total numeric := 0; d erp.documents; res jsonb;
        lines jsonb := '[]';
begin
  m := erp.require_member();
  if p_doc is null or jsonb_typeof(p_doc) <> 'object' then p_doc := '{}'; end if;
  v_branch := erp.try_uuid(p_doc ->> 'branch_id');
  perform erp.require_branch_of_tenant(m.tenant_id, v_branch);
  perform erp.doc_require('OPN', 'create', v_branch);
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'opening_import', payload);
  if prev is not null then return prev; end if;
  perform erp.raise_problems(erp.unknown_keys(p_doc, array['branch_id', 'warehouse_id', 'doc_date']));
  v_wh := erp.try_uuid(p_doc ->> 'warehouse_id');
  perform erp.require_own(m.tenant_id, 'warehouse', v_wh);
  if not exists (select 1 from erp.warehouses w where w.tenant_id = m.tenant_id and w.warehouse_id = v_wh and w.branch_id = v_branch and w.kind = 'normal' and w.active) then
    perform erp.raise_problems(jsonb_build_array(erp.problem('invalid', 'warehouse_id', 'Choose an active warehouse of the branch.')));
  end if;
  begin v_date := coalesce(nullif(p_doc ->> 'doc_date', '')::date, erp.today(m.tenant_id));
  exception when others then perform erp.raise_problems(jsonb_build_array(erp.problem('invalid', 'doc_date', 'Date: yyyy-mm-dd.'))); end;
  perform erp.import_check_rows(p_rows);
  for r in select * from jsonb_array_elements(p_rows) loop
    n := n + 1;
    if jsonb_typeof(r) <> 'object' then probs := probs || erp.import_problems(n, jsonb_build_array(erp.problem('invalid', null, 'A row must be an object.'))); continue; end if;
    one := erp.unknown_keys(r, array['item', 'qty', 'unit_cost']);
    it := null;
    select * into it from erp.items i where i.tenant_id = m.tenant_id and lower(i.code) = lower(btrim(coalesce(r ->> 'item', '')));
    if it.item_id is null then one := one || erp.problem('unknown', 'item', format('Item %s does not exist.', coalesce(r ->> 'item', '')));
    elsif not it.active then one := one || erp.problem('inactive', 'item', format('Item %s is not active.', it.code));
    elsif it.kind = 'service' then one := one || erp.problem('invalid', 'item', format('%s is a service: it has no stock.', it.code));
    elsif it.item_id = any (seen) then one := one || erp.problem('duplicate', 'item', format('Item %s appears twice in the file.', it.code));
    else seen := seen || it.item_id; end if;
    q := erp.try_numeric(replace(btrim(coalesce(r ->> 'qty', '')), ',', '.'));
    c := erp.try_numeric(replace(btrim(coalesce(r ->> 'unit_cost', '')), ',', '.'));
    if q is null or q <= 0 or q <> round(q, 4) or q >= 1e12 then one := one || erp.problem('invalid', 'qty', 'Quantity: a number above 0, at most 4 decimals.'); end if;
    if c is null or c < 0 or c >= 1e12 then one := one || erp.problem('invalid', 'unit_cost', 'Unit cost: a number of 0 or more.'); end if;
    probs := probs || erp.import_problems(n, one);
    if jsonb_array_length(one) = 0 then
      total := total + round(q * round(c, 4), 2);
      lines := lines || jsonb_build_object('item_id', it.item_id, 'unit_id', it.base_unit_id, 'qty', q, 'price', round(c, 4));
    end if;
  end loop;
  if jsonb_array_length(probs) > 0 or coalesce(p_dry_run, true) then
    res := jsonb_build_object('dry_run', true, 'rows', jsonb_array_length(p_rows), 'total_value', total, 'errors', probs);
    if jsonb_array_length(probs) > 0 then return res; end if;
    return erp.idem_end(m.tenant_id, p_idempotency_key, 'opening_import', payload, res);
  end if;
  insert into erp.documents (tenant_id, doc_type, branch_id, doc_date, warehouse_id, source, created_by, notes)
  values (m.tenant_id, 'OPN', v_branch, v_date, v_wh, 'import', m.member_id, format('Opening stock import: %s rows', n)) returning * into d;
  insert into erp.document_lines (tenant_id, document_id, line_no, item_id, qty, unit_id, qty_base, unit_price, net, gross)
  select m.tenant_id, d.document_id, x.ord::int, (x.e ->> 'item_id')::uuid, (x.e ->> 'qty')::numeric, (x.e ->> 'unit_id')::uuid, (x.e ->> 'qty')::numeric,
         (x.e ->> 'price')::numeric, round((x.e ->> 'qty')::numeric * (x.e ->> 'price')::numeric, 2), round((x.e ->> 'qty')::numeric * (x.e ->> 'price')::numeric, 2)
    from jsonb_array_elements(lines) with ordinality x(e, ord);
  update erp.documents set total_net = total, total_gross = total where tenant_id = m.tenant_id and document_id = d.document_id;
  perform erp.audit(m.tenant_id, 'doc.import', 'documents', d.document_id::text, null, jsonb_build_object('doc_type', 'OPN', 'lines', n, 'total_value', total), v_branch);
  res := jsonb_build_object('dry_run', false, 'rows', n, 'total_value', total, 'errors', '[]'::jsonb, 'document', erp.doc_json(m.tenant_id, d.document_id));
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'opening_import', payload, res);
end $$;

-- ---------------------------------------------------------------------
-- 4. doc_check (02 "Negative stock" 1): the draft's problems and the warnings a post would give, nothing written,
--    no lock taken. A blocked negative stock (setting 'block', transit) is reported as problem 'stock_negative'.
-- ---------------------------------------------------------------------
create or replace function erp_api.doc_check(p_document_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; d erp.documents; dt erp.doc_types; probs jsonb; warn jsonb := '[]';
begin
  m := erp.require_member();
  perform erp.doc_visible(m.tenant_id, p_document_id);
  select * into d from erp.documents where tenant_id = m.tenant_id and document_id = p_document_id;
  select * into dt from erp.doc_types where doc_type = d.doc_type;
  probs := case when d.state in ('draft', 'pending_approval') then erp.doc_validate(m.tenant_id, p_document_id) else '[]'::jsonb end;
  if dt.stock_sign <> 0 and d.state in ('draft', 'pending_approval') then
    begin
      warn := erp.stock_check(m.tenant_id, p_document_id);
    exception when others then
      if sqlerrm not like 'ERP_STOCK_NEGATIVE%' then raise; end if;
      probs := probs || erp.problem('stock_negative', 'lines', substr(sqlerrm, 21));
    end;
  end if;
  return jsonb_build_object('document_id', p_document_id, 'state', d.state, 'problems', probs, 'warnings', warn,
                            'value', erp.doc_value(m.tenant_id, p_document_id) * case when erp.can('cost.read') then 1 end);
end $$;

-- ---------------------------------------------------------------------
-- 5. Negative-stock report (02 "Negative stock" 4): warehouse, item, qty, negative since (days), causing document
--    and member, provisional value. The view runs with the caller's rights (RLS of every table applies: the value
--    needs cost.read, the member's email member.read); the RPC is the page's way in.
-- ---------------------------------------------------------------------
create or replace view erp.rpt_erp_negative_stock with (security_invoker = true) as
  select b.tenant_id, w.branch_id, b.warehouse_id, w.code warehouse_code, b.item_id, i.code item_code, i.name item_name, b.qty,
         b.negative_since, (now()::date - b.negative_since::date) days_negative,
         m.document_id, d.doc_type, d.doc_no, d.posted_by, mb.email posted_by_email,
         round(-b.qty * ic.avg_cost, 2) provisional_value
    from erp.stock_balances b
    join erp.warehouses w on w.tenant_id = b.tenant_id and w.warehouse_id = b.warehouse_id
    join erp.items i on i.tenant_id = b.tenant_id and i.item_id = b.item_id
    left join erp.stock_moves m on m.tenant_id = b.tenant_id and m.move_id = b.negative_move_id
    left join erp.documents d on d.tenant_id = m.tenant_id and d.document_id = m.document_id
    left join erp.members mb on mb.tenant_id = d.tenant_id and mb.member_id = d.posted_by
    left join erp.item_costs ic on ic.tenant_id = b.tenant_id and ic.item_id = b.item_id and ic.lot_id = b.lot_id
   where b.qty < 0;

-- report_negative_stock: filter branch_id, warehouse_id; visible branches only; ordered by days negative desc, item;
-- next = {negative_since, warehouse_id, item_id}. provisional_value only with cost.read.
create or replace function erp_api.report_negative_stock(p_filter jsonb default '{}', p_cursor jsonb default null, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 100), 1), 500); rows jsonb; br uuid[] := erp.my_branches(); cst boolean := erp.can('cost.read');
        v_branch uuid; v_wh uuid; tz text;
begin
  m := erp.require_member();
  perform erp.require_cap('stock.read');
  select s.time_zone into tz from erp.tenant_settings s where s.tenant_id = m.tenant_id;
  p_filter := coalesce(p_filter, '{}');
  if erp.jset(p_filter, 'branch_id') then v_branch := erp.try_uuid(p_filter ->> 'branch_id'); perform erp.require_branch_of_tenant(m.tenant_id, v_branch); end if;
  if erp.jset(p_filter, 'warehouse_id') then v_wh := erp.try_uuid(p_filter ->> 'warehouse_id'); perform erp.require_own(m.tenant_id, 'warehouse', v_wh); end if;
  select jsonb_agg(jsonb_build_object('branch_id', x.branch_id, 'warehouse_id', x.warehouse_id, 'warehouse_code', x.warehouse_code, 'item_id', x.item_id,
                                      'item_code', x.item_code, 'item_name', x.item_name, 'qty', x.qty, 'negative_since', x.negative_since,
                                      'days_negative', (erp.today(m.tenant_id) - (x.negative_since at time zone tz)::date), 'document_id', x.document_id,
                                      'doc_type', x.doc_type, 'doc_no', x.doc_no, 'posted_by_email', x.email)
                   || case when cst then jsonb_build_object('provisional_value', x.pv) else '{}'::jsonb end
                   order by x.negative_since, x.warehouse_id, x.item_id) into rows
    from (select w.branch_id, b.warehouse_id, w.code warehouse_code, b.item_id, i.code item_code, i.name item_name, b.qty, b.negative_since,
                 d.document_id, d.doc_type, d.doc_no, mb.email, round(-b.qty * ic.avg_cost, 2) pv
            from erp.stock_balances b
            join erp.warehouses w on w.tenant_id = b.tenant_id and w.warehouse_id = b.warehouse_id
            join erp.items i on i.tenant_id = b.tenant_id and i.item_id = b.item_id
            left join erp.stock_moves mv on mv.tenant_id = b.tenant_id and mv.move_id = b.negative_move_id
            left join erp.documents d on d.tenant_id = mv.tenant_id and d.document_id = mv.document_id
            left join erp.members mb on mb.tenant_id = d.tenant_id and mb.member_id = d.posted_by
            left join erp.item_costs ic on ic.tenant_id = b.tenant_id and ic.item_id = b.item_id and ic.lot_id = b.lot_id
           where b.tenant_id = m.tenant_id and b.qty < 0 and w.branch_id = any (br)
             and (v_branch is null or w.branch_id = v_branch) and (v_wh is null or b.warehouse_id = v_wh)
             and (p_cursor is null or (b.negative_since, b.warehouse_id, b.item_id) > ((p_cursor ->> 'negative_since')::timestamptz, erp.try_uuid(p_cursor ->> 'warehouse_id'),
                                                                                       erp.try_uuid(p_cursor ->> 'item_id')))
           order by b.negative_since, b.warehouse_id, b.item_id limit lim + 1) x;
  return erp.page_reply(rows, lim, array['negative_since', 'warehouse_id', 'item_id']);
end $$;

-- ---------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------
revoke all on erp.rpt_erp_negative_stock from public;
do $$ begin
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'anon') then revoke all on erp.rpt_erp_negative_stock from anon; end if;
  if exists (select 1 from pg_catalog.pg_roles where rolname = 'service_role') then revoke all on erp.rpt_erp_negative_stock from service_role; end if;
end $$;
grant select on erp.rpt_erp_negative_stock to authenticated;
select erp.lock_down();
grant execute on function erp_api.opening_import(jsonb, jsonb, boolean, uuid), erp_api.doc_check(uuid),
                          erp_api.report_negative_stock(jsonb, jsonb, int) to authenticated;
