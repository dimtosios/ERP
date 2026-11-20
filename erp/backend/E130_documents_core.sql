-- =====================================================================
-- iSmile ERP  -  E130_documents_core.sql   (task T09)
-- Purpose : the document core shared by every type (02 "Document state machines", "Numbering and series", 03 recipe):
--           posting attributes of erp.doc_types, erp.doc_transitions (the ONLY place transitions live), documents,
--           document_lines (immutable once not draft: trigger), erp.next_number (gapless, inside the posting
--           transaction), generic draft save / get / list / delete, erp.doc_set_state + erp.post_document /
--           erp.cancel_document (the stock effects are called from E140 when a type moves stock).
-- Run order: after E120. Standalone: names no CRM object. Safe to re-run.
-- Redefines: nothing. Adds columns to erp.doc_types (E120) and a rate guard trigger on erp.vat_classes (E120).
-- Hooks    : erp.stock_lock(tenant, doc), erp.stock_check(tenant, doc), erp.stock_post(tenant, doc, warnings),
--            erp.stock_cancel(tenant, doc) are owned by E140 and called here only for types that move stock.
--            erp.doc_value(tenant, doc) is defined here (net of the lines) and REDEFINED by E140 (cost value). A type-specific validator erp.<doc_types.validator>(tenant, doc)
--            returns a problem array.
-- Tests    : tests/E130_documents_tests.sql, tests/concurrency_numbering.sh (runner), tests/E990 (registry + fixtures)
-- T16      : generic hooks for two-branch documents (TRF): doc_types.dest_visible (the branch of dest_warehouse_id also
--            reads the document: doc_lock / doc_visible / doc_list / RLS), doc_transitions.side (the branch whose
--            capability a transition checks: source = branch_id, dest = the destination warehouse's branch),
--            doc_types.action_fn + transition actions receive / close (a type's own state work, called by
--            doc_set_state), the parent notification erp.doc_ref_changed (a document that references another one
--            changed state: the parent type's action_fn decides), state received_with_difference, cost rule
--            'transfer', transit warehouse allowed on system documents (the TRF difference ADJ_OUT, E160).
-- =====================================================================

do $$ begin
  if to_regclass('erp.series') is null then raise exception 'run E120_master.sql first'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Posting attributes of the document types (seeded by the file that implements a type)
-- ---------------------------------------------------------------------
alter table erp.doc_types add column if not exists stock_sign smallint not null default 0 check (stock_sign in (-1, 0, 1));
-- cost_rule: none | line (inbound at the line's cost: net / qty_base) | line_or_current (line cost, else the current
-- official cost) | current | issue (outbound: average / FIFO) | source_out (inbound at the cost of the linked outbound
-- line: customer return) | source_in (outbound at the cost of the linked inbound line: supplier return)
-- transfer (T16): a cost-neutral move between warehouses (dispatch / receipt of a TRF; E140 erp.cost_move)
alter table erp.doc_types add column if not exists cost_rule text not null default 'none'
  check (cost_rule in ('none', 'line', 'line_or_current', 'current', 'issue', 'source_out', 'source_in', 'transfer'));
alter table erp.doc_types drop constraint if exists doc_types_cost_rule_check;
alter table erp.doc_types add constraint doc_types_cost_rule_check
  check (cost_rule in ('none', 'line', 'line_or_current', 'current', 'issue', 'source_out', 'source_in', 'transfer'));
alter table erp.doc_types add column if not exists needs_warehouse boolean not null default false;
alter table erp.doc_types add column if not exists price_kind text not null default 'none' check (price_kind in ('none', 'cost', 'sale'));
alter table erp.doc_types add column if not exists approval_key text;                 -- tenant_settings.thresholds key (value limit)
alter table erp.doc_types add column if not exists header_extra text[] not null default '{}';   -- keys allowed in documents.extra
alter table erp.doc_types add column if not exists line_extra text[] not null default '{}';     -- keys allowed in document_lines.extra
alter table erp.doc_types add column if not exists validator text check (validator ~ '^doc_[a-z_]+_validate$');
-- T16: the destination branch (branch of documents.dest_warehouse_id) also reads the document and takes the transitions
-- whose side = 'dest' (02 "A transfer is visible to both its source and its destination branch")
alter table erp.doc_types add column if not exists dest_visible boolean not null default false;
-- T16: the type's own work for transition actions receive / close and for erp.doc_ref_changed (name from the catalogue,
-- never from input): erp.<action_fn>(tenant, document, action, to_state, options) returns jsonb
alter table erp.doc_types add column if not exists action_fn text check (action_fn ~ '^[a-z_]+_action$');

-- transitions: one row per (type, from, to, capability suffix); several rows = alternatives. condition: null (always),
-- 'under_threshold' / 'over_threshold' (document value vs tenant_settings.thresholds[doc_types.approval_key]; no
-- threshold set = unlimited = always under). action: post | cancel | none (state change only).
create table if not exists erp.doc_transitions (
  doc_type   text not null references erp.doc_types (doc_type),
  from_state text not null,
  to_state   text not null,
  cap        text not null check (cap in ('create', 'approve')),
  condition  text check (condition in ('under_threshold', 'over_threshold')),
  action     text not null default 'none' check (action in ('none', 'post', 'cancel', 'receive', 'close')),
  label      text not null,                      -- strings.en.js key of the button, e.g. doc.action.post
  sort       int not null default 100,
  primary key (doc_type, from_state, to_state, cap)
);
-- T16: receive / close = the type's own work (doc_types.action_fn); side = whose branch the capability is checked on
alter table erp.doc_transitions drop constraint if exists doc_transitions_action_check;
alter table erp.doc_transitions add constraint doc_transitions_action_check check (action in ('none', 'post', 'cancel', 'receive', 'close'));
alter table erp.doc_transitions add column if not exists side text not null default 'source' check (side in ('source', 'dest'));
comment on table erp.doc_transitions is 'platform catalog: allowed state transitions per document type (02); read by erp.doc_set_state only';

-- ---------------------------------------------------------------------
-- 2. Documents and lines
-- ---------------------------------------------------------------------
create table if not exists erp.documents (
  tenant_id         uuid not null references erp.tenants (tenant_id),
  document_id       uuid not null default gen_random_uuid(),
  doc_type          text not null references erp.doc_types (doc_type),
  branch_id         uuid not null,
  series_id         uuid,
  number            bigint,
  doc_no            text,
  doc_date          date not null,
  state             text not null default 'draft' check (state in ('draft', 'pending_approval', 'posted', 'cancelled', 'approved', 'partly_fulfilled',
                                                                  'closed', 'submitted', 'issued', 'failed', 'dispatched', 'received', 'received_with_difference',
                                                                  'counting', 'aborted')),
  warehouse_id      uuid,
  dest_warehouse_id uuid,
  counterparty_id   uuid,
  ref_document_id   uuid,
  ext_number        text check (length(ext_number) <= 60),
  ext_date          date,
  due_date          date,
  notes             text check (length(notes) <= 4000),
  ext_ref           text check (length(ext_ref) <= 100),     -- free external reference (CONS / REQ; 02, 07 section 5)
  currency          text not null default 'EUR' check (currency = 'EUR'),
  total_net         numeric(14,2) not null default 0,
  total_vat         numeric(14,2) not null default 0,
  total_gross       numeric(14,2) not null default 0,
  total_cost        numeric(14,2),                          -- official stock value of the lines, set by posting
  extra             jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object'),
  client_key        text check (client_key ~ '^[A-Za-z0-9:_.-]{8,120}$'),   -- stable key of the caller (07 section 5)
  source            text not null default 'ui' check (source in ('ui', 'import', 'external', 'system')),
  created_by        uuid,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  approved_by       uuid,
  approved_at       timestamptz,
  posted_by         uuid,
  posted_at         timestamptz,
  cancelled_by      uuid,
  cancelled_at      timestamptz,
  cancel_reason     text check (length(cancel_reason) <= 500),
  version           int not null default 1,
  primary key (tenant_id, document_id),
  foreign key (tenant_id, branch_id) references erp.branches (tenant_id, branch_id),
  foreign key (tenant_id, series_id) references erp.series (tenant_id, series_id),
  foreign key (tenant_id, warehouse_id) references erp.warehouses (tenant_id, warehouse_id),
  foreign key (tenant_id, dest_warehouse_id) references erp.warehouses (tenant_id, warehouse_id),
  foreign key (tenant_id, counterparty_id) references erp.counterparties (tenant_id, counterparty_id),
  foreign key (tenant_id, ref_document_id) references erp.documents (tenant_id, document_id),
  check ((number is null) = (state = 'draft') or state in ('pending_approval', 'approved', 'submitted', 'failed', 'counting', 'aborted')),
  check (number is null or series_id is not null)
);
create unique index if not exists documents_number_uq on erp.documents (tenant_id, series_id, number) where number is not null;
create unique index if not exists documents_client_key_uq on erp.documents (tenant_id, client_key) where client_key is not null;
create index if not exists documents_list_idx on erp.documents (tenant_id, branch_id, doc_type, doc_date desc, document_id desc);
create index if not exists documents_date_idx on erp.documents (tenant_id, doc_date desc, document_id desc);
create index if not exists documents_ref_idx on erp.documents (tenant_id, ref_document_id) where ref_document_id is not null;
create index if not exists documents_cp_idx on erp.documents (tenant_id, counterparty_id, doc_date desc) where counterparty_id is not null;
-- T16: state received_with_difference (TRF); the destination side of two-branch documents (list and policy)
alter table erp.documents drop constraint if exists documents_state_check;
alter table erp.documents add constraint documents_state_check check (state in ('draft', 'pending_approval', 'posted', 'cancelled', 'approved', 'partly_fulfilled',
  'closed', 'submitted', 'issued', 'failed', 'dispatched', 'received', 'received_with_difference', 'counting', 'aborted'));
create index if not exists documents_dest_idx on erp.documents (tenant_id, dest_warehouse_id, doc_date desc, document_id desc) where dest_warehouse_id is not null;

create table if not exists erp.document_lines (
  tenant_id      uuid not null references erp.tenants (tenant_id),
  line_id        uuid not null default gen_random_uuid(),
  document_id    uuid not null,
  line_no        int not null check (line_no between 1 and 9999),
  item_id        uuid,
  description    text check (length(description) <= 500),
  lot_id         uuid,                                  -- lots arrive with T37
  qty            numeric(16,4) not null,
  unit_id        uuid,
  qty_base       numeric(16,4) not null,
  unit_price     numeric(16,4),
  discount_pct   numeric(7,4) not null default 0 check (discount_pct between 0 and 100),
  vat_class_id   uuid,
  net            numeric(14,2) not null default 0,
  vat            numeric(14,2) not null default 0,
  gross          numeric(14,2) not null default 0,
  unit_cost      numeric(18,6),                         -- official cost per base unit, set by posting (recost may rewrite)
  cost_value     numeric(14,2),                         -- official stock value of the line (absolute), set by posting
  source_line_id uuid,                                  -- conversions / returns (02 "Document conversion")
  ext_line_ref   text check (length(ext_line_ref) <= 100),
  extra          jsonb not null default '{}'::jsonb check (jsonb_typeof(extra) = 'object'),
  primary key (tenant_id, line_id),
  unique (tenant_id, document_id, line_no),
  foreign key (tenant_id, document_id) references erp.documents (tenant_id, document_id) on delete cascade,
  foreign key (tenant_id, item_id) references erp.items (tenant_id, item_id),
  foreign key (tenant_id, unit_id) references erp.units (tenant_id, unit_id),
  foreign key (tenant_id, vat_class_id) references erp.vat_classes (tenant_id, vat_class_id),
  foreign key (tenant_id, source_line_id) references erp.document_lines (tenant_id, line_id)
);
create index if not exists document_lines_item_idx on erp.document_lines (tenant_id, item_id);
create index if not exists document_lines_source_idx on erp.document_lines (tenant_id, source_line_id) where source_line_id is not null;
create index if not exists document_lines_vat_idx on erp.document_lines (tenant_id, vat_class_id) where vat_class_id is not null;

-- ---------------------------------------------------------------------
-- 3. Immutability (02: a non-draft document is never edited; whitelist notes / due_date). The posting / state code
--    sets erp.doc_write = on for its own changes; recost (E140) sets erp.recost = on for the cost columns only.
-- ---------------------------------------------------------------------
create or replace function erp.tg_documents_immutable() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    if old.state <> 'draft' then perform erp.err('ERP_DOC_IMMUTABLE', format('Document %s is %s and cannot be deleted.', coalesce(old.doc_no, old.document_id::text), old.state)); end if;
    return old;
  end if;
  if old.state = 'draft' or current_setting('erp.doc_write', true) = 'on' then return new; end if;
  if (to_jsonb(new) - 'notes' - 'due_date' - 'updated_at' - 'version') <> (to_jsonb(old) - 'notes' - 'due_date' - 'updated_at' - 'version')
     and not (current_setting('erp.recost', true) = 'on'
              and (to_jsonb(new) - 'total_cost' - 'updated_at') = (to_jsonb(old) - 'total_cost' - 'updated_at')) then
    perform erp.err('ERP_DOC_IMMUTABLE', format('Document %s is %s: only notes and the due date can change.', coalesce(old.doc_no, old.document_id::text), old.state));
  end if;
  return new;
end $$;
drop trigger if exists documents_immutable on erp.documents;
create trigger documents_immutable before update or delete on erp.documents for each row execute function erp.tg_documents_immutable();

create or replace function erp.tg_lines_immutable() returns trigger
language plpgsql set search_path = '' as $$
declare st text; r record;
begin
  r := case when tg_op = 'INSERT' then new else old end;
  select d.state into st from erp.documents d where d.tenant_id = r.tenant_id and d.document_id = r.document_id;
  if st is null or st = 'draft' or current_setting('erp.doc_write', true) = 'on' then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'UPDATE' and current_setting('erp.recost', true) = 'on'
     and (to_jsonb(new) - 'unit_cost' - 'cost_value') = (to_jsonb(old) - 'unit_cost' - 'cost_value') then
    return new;
  end if;
  perform erp.err('ERP_DOC_IMMUTABLE', format('The lines of a %s document cannot change.', st));
  return null;
end $$;
drop trigger if exists document_lines_immutable on erp.document_lines;
create trigger document_lines_immutable before insert or update or delete on erp.document_lines for each row execute function erp.tg_lines_immutable();

-- the rate of a VAT class used by a non-draft line never changes (02: add a new class instead)
create or replace function erp.tg_vat_rate_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.rate is distinct from old.rate and exists (
       select 1 from erp.document_lines l join erp.documents d on d.tenant_id = l.tenant_id and d.document_id = l.document_id
        where l.tenant_id = old.tenant_id and l.vat_class_id = old.vat_class_id and d.state <> 'draft') then
    perform erp.err('ERP_VALIDATION', 'This VAT class is used by posted documents: its rate cannot change. Add a new class.',
                    jsonb_build_array(erp.problem('in_use', 'rate', 'This VAT class is used by posted documents: its rate cannot change. Add a new class.')));
  end if;
  return new;
end $$;
drop trigger if exists vat_classes_rate_guard on erp.vat_classes;
create trigger vat_classes_rate_guard before update of rate on erp.vat_classes for each row execute function erp.tg_vat_rate_guard();

-- ---------------------------------------------------------------------
-- 4. Numbering (02): the number is taken at post, inside the posting transaction; a rollback returns it (gapless)
-- ---------------------------------------------------------------------
-- the series of a document: its own series_id, else the active default of (type, branch or none, year of the date),
-- else the active default without a year. ERP_SERIES_MISSING when there is none. Locks the series row (lock order 1).
create or replace function erp.series_for(p_tenant uuid, p_doc_type text, p_branch uuid, p_date date, p_series uuid) returns erp.series
language plpgsql security definer set search_path = '' as $$
declare s erp.series; dt erp.doc_types; v_branch uuid;
begin
  select * into dt from erp.doc_types where doc_type = p_doc_type;
  v_branch := case when dt.series_scope = 'branch' then p_branch end;
  if p_series is not null then
    select * into s from erp.series x where x.tenant_id = p_tenant and x.series_id = p_series for update;
    if s.series_id is null or s.doc_type <> p_doc_type or not s.active or s.branch_id is distinct from v_branch
       or (s.fiscal_year is not null and s.fiscal_year <> extract(year from p_date)) then
      perform erp.err('ERP_SERIES_MISSING', format('Series %s cannot number this %s document (type, branch, year or inactive).', coalesce(s.code, p_series::text), p_doc_type));
    end if;
    return s;
  end if;
  select * into s from erp.series x
   where x.tenant_id = p_tenant and x.doc_type = p_doc_type and x.branch_id is not distinct from v_branch and x.is_default and x.active
     and (x.fiscal_year is null or x.fiscal_year = extract(year from p_date))
   order by x.fiscal_year nulls last limit 1 for update;
  if s.series_id is null then
    perform erp.err('ERP_SERIES_MISSING', format('There is no active default %s series for this %s. The owner creates it in Master data, Series.',
                                                  p_doc_type, case when v_branch is null then 'organisation' else 'branch' end));
  end if;
  return s;
end $$;

-- next number of a series (row already locked by series_for in the same transaction)
create or replace function erp.next_number(p_tenant uuid, p_series uuid) returns bigint
language sql security definer set search_path = '' as $$
  update erp.series set next_no = next_no + 1, last_no = next_no, updated_at = now()
   where tenant_id = p_tenant and series_id = p_series
  returning last_no
$$;

-- ---------------------------------------------------------------------
-- 5. Capabilities of a type: doc.<cap_prefix>.read | create | approve (seeded by the implementing file)
-- ---------------------------------------------------------------------
create or replace function erp.doc_cap(p_doc_type text, p_kind text) returns text
language sql stable set search_path = '' as $$
  select 'doc.' || d.cap_prefix || '.' || p_kind from erp.doc_types d where d.doc_type = p_doc_type
$$;
create or replace function erp.doc_require(p_doc_type text, p_kind text, p_branch uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not erp.can(erp.doc_cap(p_doc_type, p_kind), p_branch) then
    perform erp.err('ERP_FORBIDDEN', format('Your role or branch does not allow %s for %s documents.', p_kind, p_doc_type));
  end if;
end $$;
-- T16 two-branch documents: the destination branch = branch of dest_warehouse_id, only for doc_types.dest_visible
create or replace function erp.doc_dest_branch(p_tenant uuid, d erp.documents) returns uuid
language sql stable security definer set search_path = '' as $$
  select w.branch_id from erp.doc_types dt join erp.warehouses w on w.tenant_id = p_tenant and w.warehouse_id = d.dest_warehouse_id
   where dt.doc_type = d.doc_type and dt.dest_visible and w.kind = 'normal'
$$;
-- the caller has doc.<prefix>.<kind> on the branch of the side (source = branch_id, dest = destination branch); a
-- missing destination never passes (erp.can with a null branch would not check any branch)
create or replace function erp.doc_can(p_tenant uuid, d erp.documents, p_kind text, p_side text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(x.b is not null and erp.can(erp.doc_cap(d.doc_type, p_kind), x.b), false)
    from (select case when p_side = 'dest' then erp.doc_dest_branch(p_tenant, d) else d.branch_id end b) x
$$;
-- read: on the source branch, or on the destination branch of a two-branch type once it left draft (a draft is the
-- source's work in progress)
create or replace function erp.doc_can_read(p_tenant uuid, d erp.documents) returns boolean
language sql stable security definer set search_path = '' as $$
  select erp.doc_can(p_tenant, d, 'read', 'source') or (d.state <> 'draft' and erp.doc_can(p_tenant, d, 'read', 'dest'))
$$;
-- types the caller may read (doc.<prefix>.read)
create or replace function erp.readable_doc_types() returns text[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(d.doc_type order by d.doc_type), '{}') from erp.doc_types d where erp.can('doc.' || d.cap_prefix || '.read')
$$;

-- ---------------------------------------------------------------------
-- 6. JSON shapes
-- ---------------------------------------------------------------------
create or replace function erp.doc_line_json(l erp.document_lines, p_cost boolean) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('line_id', l.line_id, 'line_no', l.line_no, 'item_id', l.item_id, 'item_code', i.code, 'item_name', i.name,
                            'description', l.description, 'qty', l.qty, 'unit_id', l.unit_id, 'unit_code', u.code, 'qty_base', l.qty_base,
                            'unit_price', l.unit_price, 'discount_pct', l.discount_pct, 'vat_class_id', l.vat_class_id, 'net', l.net, 'vat', l.vat, 'gross', l.gross,
                            'source_line_id', l.source_line_id, 'ext_line_ref', l.ext_line_ref, 'extra', l.extra)
      || case when p_cost then jsonb_build_object('unit_cost', l.unit_cost, 'cost_value', l.cost_value) else '{}'::jsonb end
    from (select 1) one
    left join erp.items i on i.tenant_id = l.tenant_id and i.item_id = l.item_id
    left join erp.units u on u.tenant_id = l.tenant_id and u.unit_id = l.unit_id
$$;
create or replace function erp.doc_head_json(d erp.documents, p_cost boolean) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('document_id', d.document_id, 'doc_type', d.doc_type, 'state', d.state, 'branch_id', d.branch_id,
                            'branch_code', (select b.code from erp.branches b where b.tenant_id = d.tenant_id and b.branch_id = d.branch_id),
                            'series_id', d.series_id, 'number', d.number, 'doc_no', d.doc_no, 'doc_date', d.doc_date,
                            'warehouse_id', d.warehouse_id, 'warehouse_code', (select w.code from erp.warehouses w where w.tenant_id = d.tenant_id and w.warehouse_id = d.warehouse_id),
                            'dest_warehouse_id', d.dest_warehouse_id, 'counterparty_id', d.counterparty_id,
                            'counterparty_name', (select c.name from erp.counterparties c where c.tenant_id = d.tenant_id and c.counterparty_id = d.counterparty_id),
                            'ref_document_id', d.ref_document_id, 'ext_number', d.ext_number, 'ext_date', d.ext_date, 'due_date', d.due_date, 'notes', d.notes,
                            'ext_ref', d.ext_ref, 'currency', d.currency, 'total_net', d.total_net, 'total_vat', d.total_vat, 'total_gross', d.total_gross,
                            'extra', d.extra, 'client_key', d.client_key, 'source', d.source, 'created_at', d.created_at, 'updated_at', d.updated_at,
                            'approved_at', d.approved_at, 'posted_at', d.posted_at, 'cancelled_at', d.cancelled_at, 'cancel_reason', d.cancel_reason, 'version', d.version,
                            'line_count', (select count(*) from erp.document_lines l where l.tenant_id = d.tenant_id and l.document_id = d.document_id))
      || case when p_cost then jsonb_build_object('total_cost', d.total_cost) else '{}'::jsonb end
$$;

-- ---------------------------------------------------------------------
-- 7. Validation (02 / 03 recipe step 3): ALL problems at once; save returns them, post blocks on them
-- ---------------------------------------------------------------------
create or replace function erp.doc_validate(p_tenant uuid, p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare d erp.documents; dt erp.doc_types; probs jsonb := '[]'; l record; w erp.warehouses; n int := 0; extra_probs jsonb;
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc;
  select * into dt from erp.doc_types where doc_type = d.doc_type;
  if dt.needs_warehouse then
    select * into w from erp.warehouses x where x.tenant_id = p_tenant and x.warehouse_id = d.warehouse_id;
    if w.warehouse_id is null then probs := probs || erp.problem('required', 'warehouse_id', 'Warehouse is required.');
    -- the transit warehouse only on a SYSTEM document (T16: the TRF difference ADJ_OUT, checked by its type validator)
    elsif w.kind <> 'normal' and d.source <> 'system' then probs := probs || erp.problem('invalid', 'warehouse_id', 'The transit warehouse cannot be chosen.');
    elsif w.kind = 'normal' and w.branch_id <> d.branch_id then probs := probs || erp.problem('invalid', 'warehouse_id', 'The warehouse belongs to another branch.');
    elsif not w.active then probs := probs || erp.problem('inactive', 'warehouse_id', format('Warehouse %s is not active.', w.code)); end if;
  end if;
  if dt.needs_counterparty and d.counterparty_id is null then probs := probs || erp.problem('required', 'counterparty_id', 'Counterparty is required.');
  elsif d.counterparty_id is not null and not exists (select 1 from erp.counterparties c where c.tenant_id = p_tenant and c.counterparty_id = d.counterparty_id and c.active) then
    probs := probs || erp.problem('inactive', 'counterparty_id', 'The counterparty is not active.'); end if;
  if d.doc_date > erp.today(p_tenant) then probs := probs || erp.problem('future_date', 'doc_date', 'The document date is in the future.'); end if;
  for l in select x.*, i.code item_code, i.active item_active, i.kind item_kind, i.base_unit_id
             from erp.document_lines x left join erp.items i on i.tenant_id = x.tenant_id and i.item_id = x.item_id
            where x.tenant_id = p_tenant and x.document_id = p_doc order by x.line_no loop
    n := n + 1;
    if dt.stock_sign <> 0 and l.item_id is null then probs := probs || erp.problem('required', 'item_id', 'Item is required.', l.line_no); continue; end if;
    if l.item_id is not null and not l.item_active then probs := probs || erp.problem('inactive', 'item_id', format('Item %s is not active.', l.item_code), l.line_no); end if;
    if dt.stock_sign <> 0 and l.item_kind = 'service' then probs := probs || erp.problem('invalid', 'item_id', format('%s is a service: it has no stock.', l.item_code), l.line_no); end if;
    if l.qty <= 0 then probs := probs || erp.problem('invalid', 'qty', 'Quantity must be more than 0.', l.line_no); end if;
    if l.item_id is not null and l.unit_id is distinct from l.base_unit_id then
      probs := probs || erp.problem('unit_invalid', 'unit_id', format('Only the base unit of %s can be used (alternative units: T38).', l.item_code), l.line_no); end if;
    if dt.cost_rule = 'line' and l.unit_price is null then probs := probs || erp.problem('required', 'unit_price', 'Unit cost is required.', l.line_no); end if;
    if dt.price_kind = 'none' and l.unit_price is not null then probs := probs || erp.problem('invalid', 'unit_price', 'This document type has no prices.', l.line_no); end if;
  end loop;
  if n = 0 then probs := probs || erp.problem('required', 'lines', 'Add at least one line.'); end if;
  -- converted lines (E135, T44): item / unit locked, quantity within the remaining, counterparty of the source
  if to_regprocedure('erp.doc_conversion_validate(uuid,uuid)') is not null
     and exists (select 1 from erp.document_lines x where x.tenant_id = p_tenant and x.document_id = p_doc and x.source_line_id is not null) then
    probs := probs || erp.doc_conversion_validate(p_tenant, p_doc);
  end if;
  if dt.validator is not null and to_regprocedure('erp.' || dt.validator || '(uuid,uuid)') is not null then
    execute format('select erp.%I($1, $2)', dt.validator) into extra_probs using p_tenant, p_doc;   -- name from the catalogue, never from input
    probs := probs || coalesce(extra_probs, '[]'::jsonb);
  end if;
  return probs;
end $$;

-- ---------------------------------------------------------------------
-- 8. State machine (02): erp.doc_set_state is the ONLY place a state changes; it reads erp.doc_transitions
-- ---------------------------------------------------------------------
create or replace function erp.doc_condition_ok(p_tenant uuid, d erp.documents, p_condition text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare lim numeric; v numeric; k text;
begin
  if p_condition is null then return true; end if;
  select dt.approval_key into k from erp.doc_types dt where dt.doc_type = d.doc_type;
  select erp.try_numeric(s.thresholds ->> k) into lim from erp.tenant_settings s where s.tenant_id = p_tenant;
  if k is null or lim is null then return p_condition = 'under_threshold'; end if;   -- no limit set: never needs approval
  v := erp.doc_value(p_tenant, d.document_id);
  return case p_condition when 'under_threshold' then v <= lim else v > lim end;
end $$;

-- value of a document for the approval limits: the lines' net amounts. E140 REDEFINES it to value stock documents at
-- their cost (outbound lines at the current official cost).
create or replace function erp.doc_value(p_tenant uuid, p_doc uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(abs(l.net)), 0) from erp.document_lines l where l.tenant_id = p_tenant and l.document_id = p_doc
$$;

-- the transitions the CALLER may take now (buttons; doc_set_state checks the same rows)
create or replace function erp.doc_actions(p_tenant uuid, d erp.documents) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(distinct jsonb_build_object('to_state', t.to_state, 'label', t.label, 'action', t.action, 'sort', t.sort)), '[]'::jsonb)
    from erp.doc_transitions t
   where t.doc_type = d.doc_type and t.from_state = d.state
     and erp.doc_can(p_tenant, d, t.cap, t.side)
     and erp.doc_condition_ok(p_tenant, d, t.condition)
$$;

-- reply of every document RPC: header + lines + actions (+ problems for a draft)
create or replace function erp.doc_json(p_tenant uuid, p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare d erp.documents; cst boolean := erp.can('cost.read');
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc;
  return erp.doc_head_json(d, cst)
    || jsonb_build_object('lines', coalesce((select jsonb_agg(erp.doc_line_json(l, cst) order by l.line_no) from erp.document_lines l
                                              where l.tenant_id = p_tenant and l.document_id = p_doc), '[]'::jsonb),
                          'actions', (select coalesce(jsonb_agg(a order by (a ->> 'sort')::int, a ->> 'to_state'), '[]'::jsonb) from jsonb_array_elements(erp.doc_actions(p_tenant, d)) a),
                          'problems', case when d.state = 'draft' then erp.doc_validate(p_tenant, p_doc) else '[]'::jsonb end,
                          'can_edit', d.state = 'draft' and erp.can(erp.doc_cap(d.doc_type, 'create'), d.branch_id));
end $$;

-- the document row of the caller's tenant (else ERP_TENANT), locked, visible (branch) and readable (type) (else ERP_FORBIDDEN)
create or replace function erp.doc_lock(p_tenant uuid, p_doc uuid) returns erp.documents
language plpgsql security definer set search_path = '' as $$
declare d erp.documents;
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc for update;
  if d.document_id is null then
    perform erp.err('ERP_TENANT', format('Document %s does not belong to your organisation.', coalesce(p_doc::text, 'null')));
  end if;
  if not erp.doc_can_read(p_tenant, d) then
    perform erp.err('ERP_FORBIDDEN', format('Your role or branch does not allow reading this %s document.', d.doc_type));
  end if;
  return d;
end $$;

-- read check without a lock: the document exists in the tenant, its branch is visible and its type readable
create or replace function erp.doc_visible(p_tenant uuid, p_doc uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
declare d erp.documents;
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc;
  if d.document_id is null then
    perform erp.err('ERP_TENANT', format('Document %s does not belong to your organisation.', coalesce(p_doc::text, 'null')));
  end if;
  if not erp.doc_can_read(p_tenant, d) then
    perform erp.err('ERP_FORBIDDEN', format('Your role or branch does not allow reading this %s document.', d.doc_type));
  end if;
end $$;

-- post: one transaction, lock order series -> items -> balances (02) -> the tenant_usage row (last, held only until
-- commit). ONE document per transaction: a transaction that posts several documents holds the usage row while it
-- takes the next series / item locks and can deadlock with a concurrent post of the same tenant (seen in T15 with
-- the load generator's 250-document batches; no RPC does this). Returns {posted, warnings}. With warnings and
-- without p_ack nothing is written (the caller replies with the warnings; the page asks and posts again with ack).
create or replace function erp.post_document(p_tenant uuid, p_doc uuid, p_ack boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d erp.documents; dt erp.doc_types; s erp.series; probs jsonb; warn jsonb := '[]'; no bigint; lock_d date;
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc for update;
  select * into dt from erp.doc_types where doc_type = d.doc_type;
  s := erp.series_for(p_tenant, d.doc_type, d.branch_id, d.doc_date, d.series_id);          -- 1. series row lock
  if dt.stock_sign <> 0 then perform erp.stock_lock(p_tenant, p_doc); end if;              -- 2. item locks (E140)
  probs := erp.doc_validate(p_tenant, p_doc);
  perform erp.raise_problems(probs);
  -- FOR SHARE (F2-03): a concurrent change of the lock date (settings_save locks the row) waits for this post, or this
  -- post waits for it and reads the new date: never a document posted inside a period locked at the same moment
  select st.lock_date into lock_d from erp.tenant_settings st where st.tenant_id = p_tenant for share;
  if lock_d is not null and d.doc_date <= lock_d then
    perform erp.err('ERP_LOCKED_PERIOD', format('The period up to %s is locked: a document dated %s cannot be posted.', to_char(lock_d, 'DD/MM/YYYY'), to_char(d.doc_date, 'DD/MM/YYYY')));
  end if;
  if dt.stock_sign <> 0 then warn := erp.stock_check(p_tenant, p_doc); end if;           -- 3. balances (negative stock)
  if jsonb_array_length(warn) > 0 and not coalesce(p_ack, false) then
    return jsonb_build_object('posted', false, 'warnings', warn);
  end if;
  perform erp.check_limit(p_tenant, 'documents');
  no := erp.next_number(p_tenant, s.series_id);
  perform set_config('erp.doc_write', 'on', true);
  update erp.documents set series_id = s.series_id, number = no, doc_no = s.code || '/' || lpad(no::text, 6, '0'), state = 'posted',
         posted_by = (erp.current_member()).member_id, posted_at = now(), updated_at = now(), version = version + 1
   where tenant_id = p_tenant and document_id = p_doc;
  if dt.stock_sign <> 0 then perform erp.stock_post(p_tenant, p_doc, warn); end if;        -- moves, balances, cost, alerts
  perform set_config('erp.doc_write', 'off', true);
  perform erp.usage_bump(p_tenant, 'documents');
  if jsonb_array_length(warn) > 0 then
    perform erp.audit(p_tenant, 'doc.warnings_acknowledged', 'documents', p_doc::text, null, jsonb_build_object('warnings', warn), d.branch_id);
  end if;
  return jsonb_build_object('posted', true, 'warnings', warn);
end $$;

-- cancel a posted document: refused in a locked period or when a live document depends on it; stock is reversed
-- by E140 (reversing moves at the original date and cost). Returns the negative-stock warnings of the reversal (F2-05).
do $$ begin
  if exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'erp' and p.proname = 'cancel_document' and p.prorettype = 'pg_catalog.void'::pg_catalog.regtype) then
    drop function erp.cancel_document(uuid, uuid, text);
  end if;
end $$;
create or replace function erp.cancel_document(p_tenant uuid, p_doc uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d erp.documents; dt erp.doc_types; lock_d date; warn jsonb := '[]';
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc for update;
  select * into dt from erp.doc_types where doc_type = d.doc_type;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    perform erp.raise_problems(jsonb_build_array(erp.problem('required', 'reason', 'A reason is required to cancel a posted document.')));
  end if;
  select st.lock_date into lock_d from erp.tenant_settings st where st.tenant_id = p_tenant for share;   -- F2-03
  if lock_d is not null and d.doc_date <= lock_d then
    perform erp.err('ERP_LOCKED_PERIOD', format('The period up to %s is locked: a document dated %s cannot be cancelled.', to_char(lock_d, 'DD/MM/YYYY'), to_char(d.doc_date, 'DD/MM/YYYY')));
  end if;
  if exists (select 1 from erp.documents x where x.tenant_id = p_tenant and x.ref_document_id = p_doc and x.state not in ('draft', 'cancelled'))
     or exists (select 1 from erp.document_lines t join erp.document_lines s on s.tenant_id = t.tenant_id and s.line_id = t.source_line_id
                  join erp.documents x on x.tenant_id = t.tenant_id and x.document_id = t.document_id
                 where s.tenant_id = p_tenant and s.document_id = p_doc and x.state not in ('draft', 'cancelled')) then
    perform erp.err('ERP_DOC_HAS_CHILDREN', format('Document %s has later documents that depend on it: cancel them first.', d.doc_no));
  end if;
  if dt.stock_sign <> 0 then
    perform erp.stock_lock(p_tenant, p_doc);
    warn := erp.stock_cancel_check(p_tenant, p_doc);          -- F2-05: under the item locks, before the reversal
    perform erp.stock_cancel(p_tenant, p_doc);
  end if;
  perform set_config('erp.doc_write', 'on', true);
  update erp.documents set state = 'cancelled', cancelled_by = (erp.current_member()).member_id, cancelled_at = now(), cancel_reason = btrim(p_reason),
         updated_at = now(), version = version + 1
   where tenant_id = p_tenant and document_id = p_doc;
  perform set_config('erp.doc_write', 'off', true);
  if jsonb_array_length(warn) > 0 then
    perform erp.audit(p_tenant, 'doc.cancel_negative_stock', 'documents', p_doc::text, null, jsonb_build_object('warnings', warn), d.branch_id);
  end if;
  return warn;
end $$;

-- T16: the type's own work for a transition action (receive / close) or a notification ('child'): erp.<action_fn>
-- of the document's type (catalogue name, never input). A type without action_fn cannot have such transitions.
create or replace function erp.doc_type_action(p_tenant uuid, p_doc uuid, p_action text, p_to text, p_options jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare fn text; r jsonb;
begin
  select dt.action_fn into fn from erp.documents d join erp.doc_types dt on dt.doc_type = d.doc_type where d.tenant_id = p_tenant and d.document_id = p_doc;
  if fn is null or to_regprocedure('erp.' || fn || '(uuid,uuid,text,text,jsonb)') is null then
    if p_action = 'child' then return '{}'::jsonb; end if;
    perform erp.err('ERP_STATE', format('Transition action %s has no implementation for this document type.', p_action));
  end if;
  execute format('select erp.%I($1, $2, $3, $4, $5)', fn) into r using p_tenant, p_doc, p_action, p_to, coalesce(p_options, '{}'::jsonb);
  return coalesce(r, '{}'::jsonb);
end $$;

-- T16: a document that references p_parent (ref_document_id) moved to p_state: the parent's type may react (TRF closes
-- when its difference adjustment is posted, and refuses its cancellation). Types without action_fn: nothing.
create or replace function erp.doc_ref_changed(p_tenant uuid, p_parent uuid, p_child uuid, p_state text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform erp.doc_type_action(p_tenant, p_parent, 'child', p_state, jsonb_build_object('child_id', p_child, 'state', p_state));
end $$;

create or replace function erp.doc_set_state(p_tenant uuid, p_doc uuid, p_to text, p_options jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d erp.documents; tr erp.doc_transitions; res jsonb := jsonb_build_object('posted', false, 'warnings', '[]'::jsonb); from_state text; ok boolean := false;
begin
  d := erp.doc_lock(p_tenant, p_doc);
  from_state := d.state;
  -- the capability is checked on the branch of the transition's side (T16: dest = the destination branch of a TRF)
  for tr in select * from erp.doc_transitions t where t.doc_type = d.doc_type and t.from_state = d.state and t.to_state = p_to order by t.sort, t.cap loop
    if erp.doc_can(p_tenant, d, tr.cap, tr.side) and erp.doc_condition_ok(p_tenant, d, tr.condition) then ok := true; exit; end if;
  end loop;
  if not ok then
    if exists (select 1 from erp.doc_transitions t where t.doc_type = d.doc_type and t.from_state = d.state and t.to_state = p_to
                  and erp.doc_can(p_tenant, d, t.cap, t.side)) then
      perform erp.err('ERP_STATE', format('%s -> %s needs approval for this value (limit of the organisation).', d.state, p_to));
    elsif exists (select 1 from erp.doc_transitions t where t.doc_type = d.doc_type and t.from_state = d.state and t.to_state = p_to) then
      perform erp.err('ERP_FORBIDDEN', format('Your role or branch does not allow %s -> %s for %s documents.', d.state, p_to, d.doc_type));
    else
      perform erp.err('ERP_STATE', format('A %s document cannot go from %s to %s.', d.doc_type, d.state, p_to));
    end if;
  end if;
  if tr.action = 'post' then
    res := erp.post_document(p_tenant, p_doc, coalesce((p_options ->> 'ack_warnings')::boolean, false));
    -- held: warnings without ack, nothing written (the API does not store this reply under the idempotency key)
    if not (res ->> 'posted')::boolean then return res || jsonb_build_object('held', true); end if;
  elsif tr.action = 'cancel' then
    res := res || jsonb_build_object('warnings', erp.cancel_document(p_tenant, p_doc, p_options ->> 'reason'));
  elsif tr.action in ('receive', 'close') then
    res := res || erp.doc_type_action(p_tenant, p_doc, tr.action, p_to, p_options);
  end if;
  perform set_config('erp.doc_write', 'on', true);
  update erp.documents set state = p_to, updated_at = now(),
         approved_by = case when tr.cap = 'approve' and p_to in ('posted', 'approved') then (erp.current_member()).member_id else approved_by end,
         approved_at = case when tr.cap = 'approve' and p_to in ('posted', 'approved') then now() else approved_at end
   where tenant_id = p_tenant and document_id = p_doc;
  perform set_config('erp.doc_write', 'off', true);
  perform erp.audit(p_tenant, 'doc.' || p_to, 'documents', p_doc::text, jsonb_build_object('state', from_state),
                    jsonb_build_object('state', p_to, 'doc_no', (select x.doc_no from erp.documents x where x.tenant_id = p_tenant and x.document_id = p_doc))
                      || case when p_options ? 'reason' then jsonb_build_object('reason', p_options ->> 'reason') else '{}'::jsonb end, d.branch_id);
  -- T16: the referenced document's type may react (after this document's own effects are written)
  if d.ref_document_id is not null then perform erp.doc_ref_changed(p_tenant, d.ref_document_id, p_doc, p_to); end if;
  -- posted = the post action ran (stock moved, number taken): also for a TRF dispatch (to_state dispatched)
  return res || jsonb_build_object('posted', p_to = 'posted' or tr.action = 'post');
end $$;

-- ---------------------------------------------------------------------
-- 9. RPCs
-- ---------------------------------------------------------------------
-- doc_save_draft: create (no document_id) or replace a DRAFT. p_doc keys: document_id + version (update), client_key,
-- branch_id, doc_date (default today), series_id, warehouse_id, dest_warehouse_id, counterparty_id, ref_document_id,
-- ext_number, ext_date, due_date, notes, ext_ref, extra (keys of doc_types.header_extra), lines: [{item_id,
-- description, qty, unit_id (default: the item's base unit), unit_price, discount_pct, vat_class_id (default: the
-- item's), ext_line_ref, source_line_id, extra (keys of doc_types.line_extra)}] (the list REPLACES the lines; at
-- most 500). Shape errors and ids of another tenant refuse the save; business problems are returned in `problems`
-- (a draft may be incomplete) and block posting.
create or replace function erp_api.doc_save_draft(p_type text, p_doc jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; payload jsonb := jsonb_build_object('type', p_type, 'doc', p_doc); dt erp.doc_types; old erp.documents; d erp.documents;
        id uuid; probs jsonb := '[]'; v_branch uuid; v_date date; e jsonb; n int := 0; k text; v_wh uuid; v_dwh uuid; v_cp uuid; v_ref uuid; v_ser uuid;
        it erp.items; v_unit uuid; v_vat uuid; v_rate numeric; q numeric; pr numeric; disc numeric; net numeric; vat numeric; v_src uuid; res jsonb;
        lines jsonb; v_ext_date date; v_due date; isnew boolean;
begin
  m := erp.require_member();
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'doc_save_draft', payload);
  if prev is not null then return prev; end if;
  select * into dt from erp.doc_types where doc_type = p_type;
  if dt.doc_type is null or not dt.enabled then
    perform erp.raise_problems(jsonb_build_array(erp.problem('invalid', 'p_type', format('Document type %s is not available.', coalesce(p_type, 'null')))));
  end if;
  if p_doc is null or jsonb_typeof(p_doc) <> 'object' then p_doc := '{}'; end if;
  probs := erp.unknown_keys(p_doc, array['document_id', 'version', 'client_key', 'branch_id', 'doc_date', 'series_id', 'warehouse_id', 'dest_warehouse_id',
                                         'counterparty_id', 'ref_document_id', 'ext_number', 'ext_date', 'due_date', 'notes', 'ext_ref', 'extra', 'lines']);
  -- the existing draft: by id, or by the caller's stable client_key
  if erp.jset(p_doc, 'document_id') then
    id := erp.try_uuid(p_doc ->> 'document_id');
  elsif erp.jset(p_doc, 'client_key') then
    select x.document_id into id from erp.documents x where x.tenant_id = m.tenant_id and x.client_key = p_doc ->> 'client_key';
    if id is not null then perform erp.doc_visible(m.tenant_id, id); end if;
    if id is not null and (select x.state from erp.documents x where x.tenant_id = m.tenant_id and x.document_id = id) <> 'draft' then
      -- a retry of an external caller after its document was posted: return it as it is
      return erp.idem_end(m.tenant_id, p_idempotency_key, 'doc_save_draft', payload, erp.doc_json(m.tenant_id, id));
    end if;
  end if;
  isnew := id is null;
  if not isnew then
    old := erp.doc_lock(m.tenant_id, id);
    if old.doc_type <> p_type then perform erp.raise_problems(jsonb_build_array(erp.problem('invalid', 'p_type', 'The document type cannot change.'))); end if;
    if old.state <> 'draft' then perform erp.err('ERP_DOC_IMMUTABLE', format('Document %s is %s and cannot be edited.', coalesce(old.doc_no, old.document_id::text), old.state)); end if;
    perform erp.doc_require(p_type, 'create', old.branch_id);
    if erp.jset(p_doc, 'document_id') and (p_doc ->> 'version') is distinct from old.version::text then
      perform erp.err('ERP_CONFLICT', format('The draft was changed by someone else (version %s, yours %s).', old.version, coalesce(p_doc ->> 'version', 'none')));
    end if;
  end if;
  -- header
  if p_doc ? 'branch_id' then
    v_branch := erp.try_uuid(p_doc ->> 'branch_id');
    perform erp.require_branch_of_tenant(m.tenant_id, v_branch);
  else v_branch := old.branch_id; end if;
  if v_branch is null then perform erp.raise_problems(probs || erp.problem('required', 'branch_id', 'Branch is required.')); end if;
  perform erp.doc_require(p_type, 'create', v_branch);
  if p_doc ? 'doc_date' then
    if (p_doc ->> 'doc_date') !~ '^\d{4}-\d{2}-\d{2}$' then probs := probs || erp.problem('invalid', 'doc_date', 'Date: yyyy-mm-dd.');
    else begin v_date := (p_doc ->> 'doc_date')::date; exception when others then probs := probs || erp.problem('invalid', 'doc_date', 'Not a real date.'); end; end if;
  else v_date := coalesce(old.doc_date, erp.today(m.tenant_id)); end if;
  foreach k in array array['ext_date', 'due_date'] loop
    if erp.jset(p_doc, k) and (p_doc ->> k) !~ '^\d{4}-\d{2}-\d{2}$' then probs := probs || erp.problem('invalid', k, 'Date: yyyy-mm-dd.'); end if;
  end loop;
  begin v_ext_date := case when p_doc ? 'ext_date' then nullif(p_doc ->> 'ext_date', '')::date else old.ext_date end; exception when others then probs := probs || erp.problem('invalid', 'ext_date', 'Not a real date.'); end;
  begin v_due := case when p_doc ? 'due_date' then nullif(p_doc ->> 'due_date', '')::date else old.due_date end; exception when others then probs := probs || erp.problem('invalid', 'due_date', 'Not a real date.'); end;
  if p_doc ? 'warehouse_id' then if erp.jset(p_doc, 'warehouse_id') then v_wh := erp.try_uuid(p_doc ->> 'warehouse_id'); perform erp.require_own(m.tenant_id, 'warehouse', v_wh); end if;
  else v_wh := old.warehouse_id; end if;
  if p_doc ? 'dest_warehouse_id' then if erp.jset(p_doc, 'dest_warehouse_id') then v_dwh := erp.try_uuid(p_doc ->> 'dest_warehouse_id'); perform erp.require_own(m.tenant_id, 'warehouse', v_dwh); end if;
  else v_dwh := old.dest_warehouse_id; end if;
  if p_doc ? 'counterparty_id' then if erp.jset(p_doc, 'counterparty_id') then v_cp := erp.try_uuid(p_doc ->> 'counterparty_id'); perform erp.require_own(m.tenant_id, 'counterparty', v_cp); end if;
  else v_cp := old.counterparty_id; end if;
  if p_doc ? 'series_id' then if erp.jset(p_doc, 'series_id') then v_ser := erp.try_uuid(p_doc ->> 'series_id'); perform erp.require_own(m.tenant_id, 'series', v_ser); end if;
  else v_ser := old.series_id; end if;
  if p_doc ? 'ref_document_id' then
    if erp.jset(p_doc, 'ref_document_id') then v_ref := erp.try_uuid(p_doc ->> 'ref_document_id'); perform erp.doc_visible(m.tenant_id, v_ref); end if;
  else v_ref := old.ref_document_id; end if;
  if p_doc ? 'extra' then
    if jsonb_typeof(p_doc -> 'extra') <> 'object' then probs := probs || erp.problem('invalid', 'extra', 'extra must be an object.');
    else probs := probs || (select coalesce(jsonb_agg(erp.problem('not_editable', 'extra.' || x, format('%s is not a field of %s.', x, p_type))), '[]'::jsonb)
                              from jsonb_object_keys(p_doc -> 'extra') x where not (x = any (dt.header_extra))); end if;
  end if;
  if erp.jset(p_doc, 'client_key') and (p_doc ->> 'client_key') !~ '^[A-Za-z0-9:_.-]{8,120}$' then
    probs := probs || erp.problem('invalid', 'client_key', 'client_key: 8-120 letters, digits, : _ . -'); end if;
  if length(p_doc ->> 'notes') > 4000 or length(p_doc ->> 'ext_number') > 60 or length(p_doc ->> 'ext_ref') > 100 then
    probs := probs || erp.problem('invalid', 'notes', 'A text field is too long.'); end if;
  lines := case when p_doc ? 'lines' then p_doc -> 'lines' end;
  if lines is not null and jsonb_typeof(lines) <> 'array' then probs := probs || erp.problem('invalid', 'lines', 'lines must be a list.'); lines := null; end if;
  if jsonb_array_length(coalesce(lines, '[]')) > 500 then probs := probs || erp.problem('too_many', 'lines', 'At most 500 lines.'); end if;
  -- shape of every line (ids of another tenant raise ERP_TENANT at once)
  if lines is not null then
    for e in select * from jsonb_array_elements(lines) loop
      n := n + 1;
      if jsonb_typeof(e) <> 'object' then probs := probs || erp.problem('invalid', 'lines', 'A line must be an object.', n); continue; end if;
      probs := probs || (select coalesce(jsonb_agg(erp.problem('not_editable', x, format('%s cannot be set on a line.', x), n)), '[]'::jsonb) from jsonb_object_keys(e) x
                          where not (x = any (array['line_id', 'item_id', 'description', 'qty', 'unit_id', 'unit_price', 'discount_pct', 'vat_class_id', 'ext_line_ref', 'source_line_id', 'extra'])));
      if erp.jset(e, 'item_id') then perform erp.require_own(m.tenant_id, 'item', erp.try_uuid(e ->> 'item_id')); end if;
      if erp.jset(e, 'unit_id') then perform erp.require_own(m.tenant_id, 'unit', erp.try_uuid(e ->> 'unit_id')); end if;
      if erp.jset(e, 'vat_class_id') then perform erp.require_own(m.tenant_id, 'vat', erp.try_uuid(e ->> 'vat_class_id')); end if;
      if erp.jset(e, 'source_line_id') then
        if not exists (select 1 from erp.document_lines x where x.tenant_id = m.tenant_id and x.line_id = erp.try_uuid(e ->> 'source_line_id')) then
          perform erp.err('ERP_TENANT', 'A source line does not belong to your organisation.'); end if;
        -- F2-06: the caller must be able to read the source document (branch and type), as doc_convert requires
        perform erp.doc_visible(m.tenant_id, (select x.document_id from erp.document_lines x where x.tenant_id = m.tenant_id and x.line_id = (e ->> 'source_line_id')::uuid));
      end if;
      if not erp.jset(e, 'item_id') and not erp.jset(e, 'description') then probs := probs || erp.problem('required', 'item_id', 'Item or description is required.', n); end if;
      if not erp.jset(e, 'qty') or erp.try_numeric(e ->> 'qty') is null then probs := probs || erp.problem('invalid', 'qty', 'Quantity must be a number.', n);
      elsif abs(erp.try_numeric(e ->> 'qty')) >= 1e12 or erp.try_numeric(e ->> 'qty') <> round(erp.try_numeric(e ->> 'qty'), 4) then
        probs := probs || erp.problem('invalid', 'qty', 'Quantity: at most 4 decimals.', n); end if;
      if erp.jset(e, 'unit_price') and (erp.try_numeric(e ->> 'unit_price') is null or erp.try_numeric(e ->> 'unit_price') < 0 or erp.try_numeric(e ->> 'unit_price') >= 1e12) then
        probs := probs || erp.problem('invalid', 'unit_price', 'Price must be a number >= 0.', n); end if;
      if erp.jset(e, 'discount_pct') and (erp.try_numeric(e ->> 'discount_pct') is null or erp.try_numeric(e ->> 'discount_pct') not between 0 and 100) then
        probs := probs || erp.problem('invalid', 'discount_pct', 'Discount: 0 to 100 %.', n); end if;
      if e ? 'extra' and (jsonb_typeof(e -> 'extra') <> 'object' or exists (select 1 from jsonb_object_keys(e -> 'extra') x where not (x = any (dt.line_extra)))) then
        probs := probs || erp.problem('not_editable', 'extra', 'A line field is not allowed for this type.', n); end if;
      if length(e ->> 'description') > 500 or length(e ->> 'ext_line_ref') > 100 then probs := probs || erp.problem('invalid', 'description', 'A text field is too long.', n); end if;
    end loop;
  end if;
  perform erp.raise_problems(probs);
  -- write the header
  if isnew then
    insert into erp.documents (tenant_id, doc_type, branch_id, series_id, doc_date, warehouse_id, dest_warehouse_id, counterparty_id, ref_document_id, ext_number,
                               ext_date, due_date, notes, ext_ref, extra, client_key, source, created_by)
    values (m.tenant_id, p_type, v_branch, v_ser, v_date, v_wh, v_dwh, v_cp, v_ref, nullif(btrim(p_doc ->> 'ext_number'), ''), v_ext_date, v_due,
            nullif(btrim(p_doc ->> 'notes'), ''), nullif(btrim(p_doc ->> 'ext_ref'), ''), coalesce(p_doc -> 'extra', '{}'), nullif(p_doc ->> 'client_key', ''),
            case when erp.jset(p_doc, 'client_key') then 'external' else 'ui' end, m.member_id)
    returning * into d;
  else
    update erp.documents set branch_id = v_branch, series_id = v_ser, doc_date = v_date, warehouse_id = v_wh, dest_warehouse_id = v_dwh, counterparty_id = v_cp,
           ref_document_id = v_ref,
           ext_number = case when p_doc ? 'ext_number' then nullif(btrim(p_doc ->> 'ext_number'), '') else ext_number end, ext_date = v_ext_date, due_date = v_due,
           notes = case when p_doc ? 'notes' then nullif(btrim(p_doc ->> 'notes'), '') else notes end,
           ext_ref = case when p_doc ? 'ext_ref' then nullif(btrim(p_doc ->> 'ext_ref'), '') else ext_ref end,
           extra = case when p_doc ? 'extra' then p_doc -> 'extra' else extra end, updated_at = now(), version = version + 1
     where tenant_id = m.tenant_id and document_id = id returning * into d;
  end if;
  -- lines (replaced). net = round(qty x price x (1 - discount), 2); VAT per line rounded half-up (02)
  if lines is not null then
    delete from erp.document_lines where tenant_id = m.tenant_id and document_id = d.document_id;
    n := 0;
    for e in select * from jsonb_array_elements(lines) loop
      n := n + 1;
      it := null;
      if erp.jset(e, 'item_id') then select * into it from erp.items where tenant_id = m.tenant_id and item_id = (e ->> 'item_id')::uuid; end if;
      v_unit := coalesce(erp.try_uuid(e ->> 'unit_id'), it.base_unit_id);
      v_vat := case when e ? 'vat_class_id' then erp.try_uuid(e ->> 'vat_class_id') else case when dt.price_kind = 'sale' then it.vat_class_id end end;
      select x.rate into v_rate from erp.vat_classes x where x.tenant_id = m.tenant_id and x.vat_class_id = v_vat;
      q := round(erp.try_numeric(e ->> 'qty'), 4);
      pr := round(erp.try_numeric(e ->> 'unit_price'), 4);
      disc := coalesce(round(erp.try_numeric(e ->> 'discount_pct'), 4), 0);
      net := coalesce(round(q * pr * (1 - disc / 100), 2), 0);
      vat := coalesce(round(net * v_rate / 100, 2), 0);
      v_src := erp.try_uuid(e ->> 'source_line_id');
      insert into erp.document_lines (tenant_id, document_id, line_no, item_id, description, qty, unit_id, qty_base, unit_price, discount_pct, vat_class_id,
                                      net, vat, gross, source_line_id, ext_line_ref, extra)
      values (m.tenant_id, d.document_id, n, it.item_id, nullif(btrim(e ->> 'description'), ''), q, v_unit,
              q,                                   -- qty_base = qty x factor; base unit only until T38 (validation flags other units)
              pr, disc, v_vat, net, vat, net + vat, v_src, nullif(btrim(e ->> 'ext_line_ref'), ''), coalesce(e -> 'extra', '{}'));
    end loop;
    update erp.documents x set total_net = coalesce(s.n, 0), total_vat = coalesce(s.v, 0), total_gross = coalesce(s.g, 0)
      from (select sum(l.net) n, sum(l.vat) v, sum(l.gross) g from erp.document_lines l where l.tenant_id = m.tenant_id and l.document_id = d.document_id) s
     where x.tenant_id = m.tenant_id and x.document_id = d.document_id;
  end if;
  perform erp.audit(m.tenant_id, case when isnew then 'doc.create' else 'doc.update' end, 'documents', d.document_id::text, null,
                    jsonb_build_object('doc_type', p_type, 'lines', (select count(*) from erp.document_lines l where l.tenant_id = m.tenant_id and l.document_id = d.document_id)), v_branch);
  res := erp.doc_json(m.tenant_id, d.document_id);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'doc_save_draft', payload, res);
end $$;

create or replace function erp_api.doc_get(p_document_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; d erp.documents;
begin
  m := erp.require_member();
  perform erp.doc_visible(m.tenant_id, p_document_id);
  return erp.doc_json(m.tenant_id, p_document_id);
end $$;

-- doc_list: documents of the visible branches and readable types, newest first; next = {doc_date, document_id}.
-- Filter: doc_type (or doc_types list), branch_id, warehouse_id, counterparty_id, state, date_from, date_to,
-- q (number, external number or notes contains). Rows = header shape (no lines). T16: a two-branch type (TRF) is
-- listed for its source AND, once not a draft, its destination branch (branch_id filter matches either side).
create or replace function erp_api.doc_list(p_filter jsonb default '{}', p_cursor jsonb default null, p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 50), 1), 200); rows jsonb; types text[]; br uuid[]; q text; cst boolean := erp.can('cost.read');
        v_from date; v_to date; v_branch uuid; v_wh uuid; v_cp uuid; c_date date; c_id uuid; dtypes text[]; dwh uuid[];
begin
  m := erp.require_member();
  p_filter := coalesce(p_filter, '{}');
  types := erp.readable_doc_types();
  if p_filter ? 'doc_type' then types := array(select x from unnest(types) x where x = p_filter ->> 'doc_type'); end if;
  if jsonb_typeof(p_filter -> 'doc_types') = 'array' then types := array(select x from unnest(types) x where x in (select jsonb_array_elements_text(p_filter -> 'doc_types'))); end if;
  if cardinality(types) = 0 then perform erp.err('ERP_FORBIDDEN', 'Your role does not allow reading these documents.'); end if;
  br := erp.my_branches();
  -- T16: two-branch types (TRF) are also listed for the destination branch (warehouses of the visible branches)
  dtypes := array(select x from unnest(types) x join erp.doc_types dt on dt.doc_type = x where dt.dest_visible);
  if cardinality(dtypes) > 0 then
    dwh := array(select w.warehouse_id from erp.warehouses w where w.tenant_id = m.tenant_id and w.kind = 'normal' and w.branch_id = any (br));
  end if;
  if erp.jset(p_filter, 'branch_id') then v_branch := erp.try_uuid(p_filter ->> 'branch_id'); perform erp.require_branch_of_tenant(m.tenant_id, v_branch); end if;
  if erp.jset(p_filter, 'warehouse_id') then v_wh := erp.try_uuid(p_filter ->> 'warehouse_id'); perform erp.require_own(m.tenant_id, 'warehouse', v_wh); end if;
  if erp.jset(p_filter, 'counterparty_id') then v_cp := erp.try_uuid(p_filter ->> 'counterparty_id'); perform erp.require_own(m.tenant_id, 'counterparty', v_cp); end if;
  begin v_from := nullif(p_filter ->> 'date_from', '')::date; v_to := nullif(p_filter ->> 'date_to', '')::date;
  exception when others then perform erp.raise_problems(jsonb_build_array(erp.problem('invalid', 'date_from', 'Dates: yyyy-mm-dd.'))); end;
  q := nullif(lower(btrim(p_filter ->> 'q')), '');
  if p_cursor is not null then c_date := (p_cursor ->> 'doc_date')::date; c_id := erp.try_uuid(p_cursor ->> 'document_id'); end if;
  select jsonb_agg(erp.doc_head_json(d, cst) order by d.doc_date desc, d.document_id desc) into rows from (
    select * from erp.documents d
     where d.tenant_id = m.tenant_id and d.doc_type = any (types)
       and (d.branch_id = any (br) or (d.dest_warehouse_id = any (dwh) and d.doc_type = any (dtypes) and d.state <> 'draft'))
       and (v_branch is null or d.branch_id = v_branch
            or (d.doc_type = any (dtypes) and d.state <> 'draft'
                and d.dest_warehouse_id in (select w.warehouse_id from erp.warehouses w where w.tenant_id = m.tenant_id and w.branch_id = v_branch)))
       and (v_wh is null or d.warehouse_id = v_wh or d.dest_warehouse_id = v_wh)
       and (v_cp is null or d.counterparty_id = v_cp)
       and (p_filter ->> 'state' is null or d.state = p_filter ->> 'state')
       and (v_from is null or d.doc_date >= v_from) and (v_to is null or d.doc_date <= v_to)
       and (q is null or strpos(lower(coalesce(d.doc_no, '')), q) > 0 or strpos(lower(coalesce(d.ext_number, '')), q) > 0 or strpos(lower(coalesce(d.notes, '')), q) > 0)
       and (c_date is null or (d.doc_date, d.document_id) < (c_date, c_id))
     order by d.doc_date desc, d.document_id desc limit lim + 1) d;
  return erp.page_reply(rows, lim, array['doc_date', 'document_id']);
end $$;

create or replace function erp_api.doc_delete_draft(p_document_id uuid, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; d erp.documents; res jsonb;
begin
  m := erp.require_member();
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'doc_delete_draft', to_jsonb(p_document_id));
  if prev is not null then return prev; end if;
  d := erp.doc_lock(m.tenant_id, p_document_id);
  perform erp.doc_require(d.doc_type, 'create', d.branch_id);
  if d.state <> 'draft' then perform erp.err('ERP_DOC_IMMUTABLE', format('Document %s is %s: only a draft can be deleted (cancel a posted one).', coalesce(d.doc_no, ''), d.state)); end if;
  delete from erp.documents where tenant_id = m.tenant_id and document_id = p_document_id;
  perform erp.audit(m.tenant_id, 'doc.delete', 'documents', p_document_id::text, jsonb_build_object('doc_type', d.doc_type, 'state', 'draft'), null, d.branch_id);
  res := jsonb_build_object('deleted', true, 'document_id', p_document_id);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'doc_delete_draft', to_jsonb(p_document_id), res);
end $$;

-- doc_set_state: the one state-changing RPC (post, submit for approval, approve, reject, cancel, ...). p_options:
-- ack_warnings (boolean, post with W_STOCK_NEGATIVE warnings), reason (cancel: required; reject: optional); a type's
-- own actions read more keys (T16 TRF receipt: receipt_date, lines; API.md E160). Reply: {posted, warnings, document}
-- (+ the type's keys). With warnings and without ack: posted = false, nothing changed, the reply is not stored.
create or replace function erp_api.doc_set_state(p_document_id uuid, p_to_state text, p_options jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; payload jsonb := jsonb_build_object('id', p_document_id, 'to', p_to_state, 'options', p_options); r jsonb; res jsonb;
begin
  m := erp.require_member();
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'doc_set_state', payload);
  if prev is not null then return prev; end if;
  if p_options is not null and jsonb_typeof(p_options) <> 'object' then p_options := '{}'; end if;
  r := erp.doc_set_state(m.tenant_id, p_document_id, p_to_state, coalesce(p_options, '{}'));
  res := (r - 'held') || jsonb_build_object('document', erp.doc_json(m.tenant_id, p_document_id));
  if coalesce((r ->> 'held')::boolean, false) then return res; end if;   -- warnings: not stored, the page asks and posts again
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'doc_set_state', payload, res);
end $$;

-- ---------------------------------------------------------------------
-- 10. RLS + grants
-- ---------------------------------------------------------------------
alter table erp.doc_transitions enable row level security;
alter table erp.doc_transitions force row level security;
alter table erp.documents enable row level security;
alter table erp.documents force row level security;
alter table erp.document_lines enable row level security;
alter table erp.document_lines force row level security;
drop policy if exists doc_transitions_read on erp.doc_transitions;
create policy doc_transitions_read on erp.doc_transitions for select to authenticated using (true);
-- documents: tenant, visible branch, readable type (the type list is one sub-select per query: fast form)
drop policy if exists documents_read on erp.documents;
-- T16: a two-branch type (doc_types.dest_visible) is also visible to the destination warehouse's branch (not as a draft)
create policy documents_read on erp.documents for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[])
         and ((select erp.is_owner()) or branch_id = any ((select erp.my_branches())::uuid[])
              or (dest_warehouse_id = any ((select array_agg(w.warehouse_id) from erp.warehouses w where w.branch_id = any ((select erp.my_branches())::uuid[]))::uuid[])
                  and doc_type = any ((select array_agg(t.doc_type) from erp.doc_types t where t.dest_visible)::text[]) and state <> 'draft'))
         and doc_type = any ((select array_agg(t.doc_type) from erp.doc_types t where erp.can('doc.' || t.cap_prefix || '.read'))::text[]));
drop policy if exists document_lines_read on erp.document_lines;
create policy document_lines_read on erp.document_lines for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[])
         and exists (select 1 from erp.documents d where d.tenant_id = document_lines.tenant_id and d.document_id = document_lines.document_id));
do $$ declare r text; begin
  foreach r in array array['public', 'anon', 'service_role'] loop
    if r = 'public' or exists (select 1 from pg_catalog.pg_roles where rolname = r) then
      execute format('revoke all on erp.doc_transitions, erp.documents, erp.document_lines from %s', r);
    end if;
  end loop;
end $$;
revoke insert, update, delete, truncate, references, trigger on erp.doc_transitions, erp.documents, erp.document_lines from authenticated;
grant select on erp.doc_transitions, erp.documents, erp.document_lines to authenticated;

select erp.lock_down();
grant execute on function erp_api.doc_save_draft(text, jsonb, uuid), erp_api.doc_get(uuid), erp_api.doc_list(jsonb, jsonb, int),
                          erp_api.doc_delete_draft(uuid, uuid), erp_api.doc_set_state(uuid, text, jsonb, uuid) to authenticated;
