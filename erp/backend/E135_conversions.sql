-- =====================================================================
-- iSmile ERP  -  E135_conversions.sql   (task T44; owner decision B, 02 "Document conversion", 01 C5)
-- Purpose : "Convert to" / "Copy to" for every document type: the allowed pairs as DATA (erp.doc_conversions, the
--           01 C5 matrix), document_links (source -> target, kind), the remaining quantity per source line and kind
--           (view erp.v_line_remaining, never stored; drafts count), the source status per kind (open / partial /
--           full, view erp.v_doc_conversion_status), erp_api.doc_convert (locks the sources in id order, partial and
--           N:1, idempotent) and erp_api.doc_copy (an unlinked draft of the same type), the conversion checks of a
--           target draft (erp.doc_conversion_validate, called by E130's doc_validate).
-- Run order: after E130 (before E140 by name; it needs no stock object). Standalone: names no CRM object. Safe to re-run.
-- Redefines: nothing. stock_by_source (no second stock move for a line whose source moved the goods) is applied by
--           post_document in T45 (05); the pairs are seeded here.
-- Tests    : tests/E135_conversions_tests.sql (two TEST types), tests/E990 (registry + fixtures)
-- =====================================================================

do $$ begin
  if to_regclass('erp.documents') is null then raise exception 'run E130_documents_core.sql first'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The allowed pairs (01 C5). A pair works only when BOTH types are enabled. kind: fulfil | bill | credit |
--    return | request. stock_rule: as_target (the target posts its own stock) | stock_by_source (the source moved
--    the goods: the target posts money / fiscal data only, T45).
-- ---------------------------------------------------------------------
create table if not exists erp.doc_conversions (
  source_type text not null references erp.doc_types (doc_type),
  target_type text not null references erp.doc_types (doc_type),
  kind        text not null check (kind in ('fulfil', 'bill', 'credit', 'return', 'request')),
  partial     boolean not null default true,
  n_to_one    boolean not null default false,
  stock_rule  text not null default 'as_target' check (stock_rule in ('as_target', 'stock_by_source')),
  enabled     boolean not null default true,
  sort        int not null default 100,
  primary key (source_type, target_type)
);
comment on table erp.doc_conversions is 'platform catalog: allowed document conversions (01 C5); the buttons are read from it';
insert into erp.doc_conversions (source_type, target_type, kind, n_to_one, stock_rule, sort) values
  ('SQ', 'SO', 'fulfil', false, 'as_target', 10), ('SQ', 'DN', 'fulfil', false, 'as_target', 11), ('SQ', 'SINV', 'bill', false, 'as_target', 12),
  ('SQ', 'SVC', 'bill', false, 'as_target', 13), ('SQ', 'RR', 'bill', false, 'as_target', 14), ('SQ', 'RS', 'bill', false, 'as_target', 15),
  ('SO', 'DN', 'fulfil', true, 'as_target', 20), ('SO', 'SINV', 'bill', true, 'as_target', 21), ('SO', 'RR', 'bill', true, 'as_target', 22),
  ('DN', 'SINV', 'bill', true, 'stock_by_source', 30), ('DN', 'RR', 'bill', true, 'stock_by_source', 31),
  ('SINV', 'CRN', 'credit', false, 'as_target', 40), ('SVC', 'CRN', 'credit', false, 'as_target', 41),
  ('RR', 'RCR', 'credit', false, 'as_target', 50), ('RS', 'RCR', 'credit', false, 'as_target', 51),
  ('REQ', 'PO', 'request', true, 'as_target', 60), ('REQ', 'TRF', 'request', false, 'as_target', 61),
  ('PO', 'GRN', 'fulfil', true, 'as_target', 70), ('PO', 'PINV', 'bill', true, 'as_target', 71),
  ('GRN', 'PINV', 'bill', true, 'stock_by_source', 80), ('GRN', 'PRET', 'return', false, 'as_target', 81),
  ('PINV', 'PCRN', 'credit', false, 'as_target', 90), ('PINV', 'PRET', 'return', false, 'as_target', 91)
on conflict (source_type, target_type) do nothing;

create table if not exists erp.document_links (
  tenant_id          uuid not null references erp.tenants (tenant_id),
  link_id            uuid not null default gen_random_uuid(),
  source_document_id uuid not null,
  target_document_id uuid not null,
  kind               text not null check (kind in ('fulfil', 'bill', 'credit', 'return', 'request')),
  created_at         timestamptz not null default now(),
  primary key (tenant_id, link_id),
  unique (tenant_id, source_document_id, target_document_id, kind),
  foreign key (tenant_id, source_document_id) references erp.documents (tenant_id, document_id),
  foreign key (tenant_id, target_document_id) references erp.documents (tenant_id, document_id) on delete cascade
);
create index if not exists document_links_target_idx on erp.document_links (tenant_id, target_document_id);

-- ---------------------------------------------------------------------
-- 2. Remaining quantity per source line and kind (02): source qty_base - target lines of documents NOT cancelled /
--    failed (drafts count, so a second conversion of the same quantity is refused). Never stored.
-- ---------------------------------------------------------------------
create or replace view erp.v_line_remaining with (security_invoker = true) as
  select s.tenant_id, s.document_id, s.line_id, s.line_no, s.item_id, k.kind, s.qty_base,
         s.qty_base - coalesce((select sum(t.qty_base)
                                  from erp.document_lines t
                                  join erp.documents td on td.tenant_id = t.tenant_id and td.document_id = t.document_id
                                  join erp.doc_conversions c2 on c2.source_type = sd.doc_type and c2.target_type = td.doc_type
                                 where t.tenant_id = s.tenant_id and t.source_line_id = s.line_id and c2.kind = k.kind
                                   and td.state not in ('cancelled', 'failed')), 0) remaining
    from erp.document_lines s
    join erp.documents sd on sd.tenant_id = s.tenant_id and sd.document_id = s.document_id
    cross join lateral (select distinct c.kind from erp.doc_conversions c where c.source_type = sd.doc_type) k;

-- source status per document and kind: open (nothing converted), partial, full
create or replace view erp.v_doc_conversion_status with (security_invoker = true) as
  select r.tenant_id, r.document_id, r.kind,
         case when sum(r.remaining) = sum(r.qty_base) then 'open' when sum(greatest(r.remaining, 0)) = 0 then 'full' else 'partial' end status,
         sum(r.qty_base) qty_base, sum(greatest(r.remaining, 0)) remaining
    from erp.v_line_remaining r
   group by r.tenant_id, r.document_id, r.kind;

-- the same computation for the RPCs (definer, one source line): remaining excluding the lines of p_except (the
-- target draft being validated)
create or replace function erp.line_remaining(p_tenant uuid, p_line uuid, p_kind text, p_except uuid default null) returns numeric
language sql stable security definer set search_path = '' as $$
  select s.qty_base - coalesce((select sum(t.qty_base)
                                  from erp.document_lines t
                                  join erp.documents td on td.tenant_id = t.tenant_id and td.document_id = t.document_id
                                  join erp.doc_conversions c2 on c2.source_type = sd.doc_type and c2.target_type = td.doc_type
                                 where t.tenant_id = p_tenant and t.source_line_id = p_line and c2.kind = p_kind
                                   and td.state not in ('cancelled', 'failed') and td.document_id is distinct from p_except), 0)
    from erp.document_lines s join erp.documents sd on sd.tenant_id = s.tenant_id and sd.document_id = s.document_id
   where s.tenant_id = p_tenant and s.line_id = p_line
$$;

-- ---------------------------------------------------------------------
-- 3. Checks of a target draft (02 "Editable in the target draft"): item and unit of a converted line stay the
--    source's; its quantity never above the remaining; the counterparty stays the sources'. Called by
--    erp.doc_validate (E130) when this file is installed.
-- ---------------------------------------------------------------------
create or replace function erp.doc_conversion_validate(p_tenant uuid, p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare d erp.documents; probs jsonb := '[]'; l record; rem numeric;
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc;
  for l in select t.line_no, t.item_id, t.unit_id, t.qty_base, s.item_id s_item, s.unit_id s_unit, c.kind, sd.counterparty_id s_cp, s.line_id s_line, sd.doc_type source_type,
                  sd.state s_state
             from erp.document_lines t
             join erp.document_lines s on s.tenant_id = t.tenant_id and s.line_id = t.source_line_id
             join erp.documents sd on sd.tenant_id = s.tenant_id and sd.document_id = s.document_id
             left join erp.doc_conversions c on c.source_type = sd.doc_type and c.target_type = d.doc_type
            where t.tenant_id = p_tenant and t.document_id = p_doc order by t.line_no loop
    if l.kind is null then
      -- not a conversion: a return line points to the line it returns (cost rules source_out / source_in, E140)
      if (select dt.cost_rule from erp.doc_types dt where dt.doc_type = d.doc_type) in ('source_out', 'source_in') then
        if l.item_id is distinct from l.s_item then probs := probs || erp.problem('locked', 'item_id', 'A return line has the item of the line it returns.', l.line_no); end if;
      else
        probs := probs || erp.problem('not_allowed', 'source_line_id', format('A %s line cannot come from a %s document.', d.doc_type, l.source_type), l.line_no);
      end if;
      continue;
    end if;
    if l.s_state in ('cancelled', 'failed', 'draft') then probs := probs || erp.problem('source_cancelled', 'source_line_id', 'The source document is no longer posted.', l.line_no); end if;
    if l.item_id is distinct from l.s_item or l.unit_id is distinct from l.s_unit then
      probs := probs || erp.problem('locked', 'item_id', 'The item and unit of a converted line are those of its source.', l.line_no); end if;
    rem := erp.line_remaining(p_tenant, l.s_line, l.kind, p_doc);
    if l.qty_base > rem then probs := probs || erp.problem('exceeds', 'qty', format('At most %s remain on the source line.', rem), l.line_no); end if;
    if l.s_cp is distinct from d.counterparty_id then probs := probs || erp.problem('locked', 'counterparty_id', 'The counterparty is that of the source document.'); end if;
  end loop;
  return (select coalesce(jsonb_agg(distinct e), '[]'::jsonb) from jsonb_array_elements(probs) e);
end $$;

-- ---------------------------------------------------------------------
-- 4. RPCs
-- ---------------------------------------------------------------------
-- doc_convert: p_source_ids (1..50 documents of ONE type; N:1 only where the pair allows it, then same branch and
-- counterparty), p_target_type, p_lines null = everything that remains, else [{source_line_id, qty}] (qty in base
-- units, > 0, <= remaining). Returns the new DRAFT (document reply). Locks the sources (id order) first.
create or replace function erp_api.doc_convert(p_source_ids uuid[], p_target_type text, p_lines jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; payload jsonb := jsonb_build_object('sources', to_jsonb(p_source_ids), 'target', p_target_type, 'lines', p_lines);
        src erp.documents; first erp.documents; cv erp.doc_conversions; tdt erp.doc_types; sdt erp.doc_types; n int := 0; d erp.documents; res jsonb;
        sl record; want numeric; rem numeric; e jsonb; ln int := 0; picked jsonb := '{}'; probs jsonb := '[]'; id uuid; full_line boolean;
begin
  m := erp.require_member();
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'doc_convert', payload);
  if prev is not null then return prev; end if;
  if p_source_ids is null or cardinality(p_source_ids) = 0 or cardinality(p_source_ids) > 50 then
    perform erp.raise_problems(jsonb_build_array(erp.problem('required', 'p_source_ids', 'Choose 1 to 50 source documents.')));
  end if;
  -- lock the sources in id order (02 "Locking"), check each one
  foreach id in array (select array_agg(distinct x order by x) from unnest(p_source_ids) x) loop
    src := erp.doc_lock(m.tenant_id, id);
    n := n + 1;
    if first.document_id is null then first := src; end if;
    if src.doc_type <> first.doc_type or src.branch_id <> first.branch_id or src.counterparty_id is distinct from first.counterparty_id then
      perform erp.err('ERP_CONVERT_MIXED', 'Documents converted together must have the same type, branch and counterparty.');
    end if;
    if src.state in ('draft', 'pending_approval', 'cancelled', 'failed', 'submitted') then
      perform erp.err('ERP_STATE', format('Document %s is %s: only a posted / approved document can be converted.', coalesce(src.doc_no, src.document_id::text), src.state));
    end if;
  end loop;
  select * into cv from erp.doc_conversions c where c.source_type = first.doc_type and c.target_type = p_target_type;
  select * into tdt from erp.doc_types where doc_type = p_target_type;
  select * into sdt from erp.doc_types where doc_type = first.doc_type;
  if cv.source_type is null or not cv.enabled or not coalesce(tdt.enabled, false) or not sdt.enabled then
    perform erp.err('ERP_CONVERT_NOT_ALLOWED', format('%s cannot be converted to %s.', first.doc_type, coalesce(p_target_type, 'null')));
  end if;
  if n > 1 and not cv.n_to_one then perform erp.err('ERP_CONVERT_NOT_ALLOWED', format('Several %s cannot go into one %s.', first.doc_type, p_target_type)); end if;
  perform erp.doc_require(p_target_type, 'create', first.branch_id);
  -- the quantities: all that remains, or the lines asked
  if p_lines is not null then
    if jsonb_typeof(p_lines) <> 'array' then perform erp.raise_problems(jsonb_build_array(erp.problem('invalid', 'p_lines', 'p_lines must be a list.'))); end if;
    for e in select * from jsonb_array_elements(p_lines) loop
      ln := ln + 1;
      if erp.try_uuid(e ->> 'source_line_id') is null or not exists (select 1 from erp.document_lines x where x.tenant_id = m.tenant_id
                                                                       and x.line_id = erp.try_uuid(e ->> 'source_line_id') and x.document_id = any (p_source_ids)) then
        perform erp.err('ERP_TENANT', 'A source line is not a line of the chosen documents.');
      end if;
      want := erp.try_numeric(e ->> 'qty');
      if want is null or want <= 0 or want <> round(want, 4) then probs := probs || erp.problem('invalid', 'qty', 'Quantity: a number above 0.', ln);
      else
        rem := erp.line_remaining(m.tenant_id, (e ->> 'source_line_id')::uuid, cv.kind);
        if want > rem then perform erp.err('ERP_CONVERT_EXCEEDS', format('Line %s: %s asked, %s remain.', ln, want, rem)); end if;
        picked := picked || jsonb_build_object(e ->> 'source_line_id', coalesce((picked ->> (e ->> 'source_line_id'))::numeric, 0) + want);
      end if;
    end loop;
    perform erp.raise_problems(probs);
    if exists (select 1 from jsonb_each_text(picked) p where p.value::numeric > erp.line_remaining(m.tenant_id, p.key::uuid, cv.kind)) then
      perform erp.err('ERP_CONVERT_EXCEEDS', 'The same source line is asked more than it has left.');
    end if;
  end if;
  -- the target draft: header from the first source, today's date
  insert into erp.documents (tenant_id, doc_type, branch_id, doc_date, warehouse_id, counterparty_id, ref_document_id, ext_ref, source, created_by)
  values (m.tenant_id, p_target_type, first.branch_id, erp.today(m.tenant_id), case when tdt.needs_warehouse then first.warehouse_id end, first.counterparty_id,
          case when n = 1 then first.document_id end, first.ext_ref, 'ui', m.member_id)
  returning * into d;
  ln := 0;
  for sl in select l.*, sd.document_id src_doc, sd.number src_no from erp.document_lines l join erp.documents sd on sd.tenant_id = l.tenant_id and sd.document_id = l.document_id
             where l.tenant_id = m.tenant_id and l.document_id = any (p_source_ids) order by sd.doc_date, sd.number, sd.document_id, l.line_no loop
    want := case when p_lines is null then erp.line_remaining(m.tenant_id, sl.line_id, cv.kind) else (picked ->> sl.line_id::text)::numeric end;
    continue when want is null or want <= 0;
    ln := ln + 1;
    full_line := want = sl.qty_base;     -- a full line keeps the source's rounded amounts (02 "Totals")
    insert into erp.document_lines (tenant_id, document_id, line_no, item_id, description, qty, unit_id, qty_base, unit_price, discount_pct, vat_class_id,
                                    net, vat, gross, source_line_id, ext_line_ref)
    values (m.tenant_id, d.document_id, ln, sl.item_id, sl.description, round(want * sl.qty / nullif(sl.qty_base, 0), 4), sl.unit_id, want,
            case when tdt.price_kind = 'none' then null else sl.unit_price end, sl.discount_pct, case when tdt.price_kind = 'none' then null else sl.vat_class_id end,
            case when tdt.price_kind = 'none' then 0 when full_line then sl.net else coalesce(round(want * sl.unit_price * (1 - sl.discount_pct / 100), 2), 0) end,
            case when tdt.price_kind = 'none' then 0 when full_line then sl.vat
                 else coalesce(round(round(want * sl.unit_price * (1 - sl.discount_pct / 100), 2)
                                     * (select v.rate from erp.vat_classes v where v.tenant_id = m.tenant_id and v.vat_class_id = sl.vat_class_id) / 100, 2), 0) end,
            0, sl.line_id, sl.ext_line_ref);
  end loop;
  if ln = 0 then perform erp.err('ERP_CONVERT_NOTHING_LEFT', 'Nothing is left to convert on these documents.'); end if;
  update erp.document_lines set gross = net + vat where tenant_id = m.tenant_id and document_id = d.document_id;
  update erp.documents x set total_net = s.n, total_vat = s.v, total_gross = s.g
    from (select sum(l.net) n, sum(l.vat) v, sum(l.gross) g from erp.document_lines l where l.tenant_id = m.tenant_id and l.document_id = d.document_id) s
   where x.tenant_id = m.tenant_id and x.document_id = d.document_id;
  insert into erp.document_links (tenant_id, source_document_id, target_document_id, kind)
  select distinct m.tenant_id, l.document_id, d.document_id, cv.kind
    from erp.document_lines t join erp.document_lines l on l.tenant_id = t.tenant_id and l.line_id = t.source_line_id
   where t.tenant_id = m.tenant_id and t.document_id = d.document_id;
  perform erp.audit(m.tenant_id, 'doc.convert', 'documents', d.document_id::text, null,
                    jsonb_build_object('from', to_jsonb(p_source_ids), 'doc_type', p_target_type, 'kind', cv.kind, 'lines', ln), d.branch_id);
  res := erp.doc_json(m.tenant_id, d.document_id);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'doc_convert', payload, res);
end $$;

-- doc_copy: a new DRAFT of the same type with today's date, the same header and lines (prices kept), NO link
create or replace function erp_api.doc_copy(p_document_id uuid, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; src erp.documents; d erp.documents; res jsonb;
begin
  m := erp.require_member();
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'doc_copy', to_jsonb(p_document_id));
  if prev is not null then return prev; end if;
  perform erp.doc_visible(m.tenant_id, p_document_id);
  select * into src from erp.documents where tenant_id = m.tenant_id and document_id = p_document_id;
  perform erp.doc_require(src.doc_type, 'create', src.branch_id);
  if not (select enabled from erp.doc_types where doc_type = src.doc_type) then
    perform erp.err('ERP_CONVERT_NOT_ALLOWED', format('%s documents cannot be created now.', src.doc_type));
  end if;
  insert into erp.documents (tenant_id, doc_type, branch_id, doc_date, warehouse_id, dest_warehouse_id, counterparty_id, notes, ext_ref, extra, source, created_by)
  values (m.tenant_id, src.doc_type, src.branch_id, erp.today(m.tenant_id), src.warehouse_id, src.dest_warehouse_id, src.counterparty_id, src.notes, src.ext_ref, src.extra,
          'ui', m.member_id)
  returning * into d;
  insert into erp.document_lines (tenant_id, document_id, line_no, item_id, description, qty, unit_id, qty_base, unit_price, discount_pct, vat_class_id, net, vat, gross,
                                  ext_line_ref, extra)
  select m.tenant_id, d.document_id, l.line_no, l.item_id, l.description, l.qty, l.unit_id, l.qty_base, l.unit_price, l.discount_pct, l.vat_class_id, l.net, l.vat, l.gross,
         l.ext_line_ref, l.extra
    from erp.document_lines l where l.tenant_id = m.tenant_id and l.document_id = p_document_id;
  update erp.documents set total_net = src.total_net, total_vat = src.total_vat, total_gross = src.total_gross where tenant_id = m.tenant_id and document_id = d.document_id;
  perform erp.audit(m.tenant_id, 'doc.copy', 'documents', d.document_id::text, null, jsonb_build_object('from', p_document_id, 'doc_type', src.doc_type), d.branch_id);
  res := erp.doc_json(m.tenant_id, d.document_id);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'doc_copy', to_jsonb(p_document_id), res);
end $$;

-- doc_conversions_for: the "Convert to" menu of a document (allowed targets the caller may create, with the kind,
-- status and remaining quantity per line) + "Created from" / "Converted to" links
create or replace function erp_api.doc_conversions_for(p_document_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; d erp.documents;
begin
  m := erp.require_member();
  perform erp.doc_visible(m.tenant_id, p_document_id);
  select * into d from erp.documents where tenant_id = m.tenant_id and document_id = p_document_id;
  return jsonb_build_object(
    'targets', coalesce((select jsonb_agg(jsonb_build_object('target_type', c.target_type, 'kind', c.kind, 'partial', c.partial, 'n_to_one', c.n_to_one,
                                                             'status', coalesce((select s.status from erp.v_doc_conversion_status s where s.tenant_id = m.tenant_id
                                                                                   and s.document_id = d.document_id and s.kind = c.kind), 'open'),
                                                             'lines', (select jsonb_agg(jsonb_build_object('source_line_id', l.line_id, 'line_no', l.line_no,
                                                                                         'remaining', erp.line_remaining(m.tenant_id, l.line_id, c.kind)) order by l.line_no)
                                                                         from erp.document_lines l where l.tenant_id = m.tenant_id and l.document_id = d.document_id))
                                          order by c.sort)
                           from erp.doc_conversions c join erp.doc_types t on t.doc_type = c.target_type and t.enabled
                          where c.source_type = d.doc_type and c.enabled and d.state not in ('draft', 'pending_approval', 'cancelled', 'failed', 'submitted')
                            and erp.can(erp.doc_cap(c.target_type, 'create'), d.branch_id)), '[]'::jsonb),
    'created_from', coalesce((select jsonb_agg(jsonb_build_object('document_id', x.document_id, 'doc_type', x.doc_type, 'doc_no', x.doc_no, 'state', x.state, 'kind', k.kind))
                                from erp.document_links k join erp.documents x on x.tenant_id = k.tenant_id and x.document_id = k.source_document_id
                               where k.tenant_id = m.tenant_id and k.target_document_id = d.document_id), '[]'::jsonb),
    'converted_to', coalesce((select jsonb_agg(jsonb_build_object('document_id', x.document_id, 'doc_type', x.doc_type, 'doc_no', x.doc_no, 'state', x.state, 'kind', k.kind))
                                from erp.document_links k join erp.documents x on x.tenant_id = k.tenant_id and x.document_id = k.target_document_id
                               where k.tenant_id = m.tenant_id and k.source_document_id = d.document_id), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 5. RLS + grants
-- ---------------------------------------------------------------------
alter table erp.doc_conversions enable row level security;
alter table erp.doc_conversions force row level security;
alter table erp.document_links enable row level security;
alter table erp.document_links force row level security;
drop policy if exists doc_conversions_read on erp.doc_conversions;
create policy doc_conversions_read on erp.doc_conversions for select to authenticated using (true);
drop policy if exists document_links_read on erp.document_links;
create policy document_links_read on erp.document_links for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[])
         and exists (select 1 from erp.documents d where d.tenant_id = document_links.tenant_id and d.document_id = document_links.source_document_id));
do $$ declare r text; begin
  foreach r in array array['public', 'anon', 'service_role'] loop
    if r = 'public' or exists (select 1 from pg_catalog.pg_roles where rolname = r) then
      execute format('revoke all on erp.doc_conversions, erp.document_links, erp.v_line_remaining, erp.v_doc_conversion_status from %s', r);
    end if;
  end loop;
end $$;
revoke insert, update, delete, truncate, references, trigger on erp.doc_conversions, erp.document_links from authenticated;
grant select on erp.doc_conversions, erp.document_links, erp.v_line_remaining, erp.v_doc_conversion_status to authenticated;
select erp.lock_down();
grant execute on function erp_api.doc_convert(uuid[], text, jsonb, uuid), erp_api.doc_copy(uuid, uuid), erp_api.doc_conversions_for(uuid) to authenticated;
