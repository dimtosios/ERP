-- =====================================================================
-- iSmile ERP  -  E120_master.sql   (tasks T05, T06, T08)
-- Purpose : master data. Part 1 (T05): units, VAT classes, item categories (tree, valuation override column),
--           items, barcodes. Part 2 (T06): warehouses + the transit warehouse, counterparties (tax ID checksum,
--           ext_ref), the document-type catalogue and document series. CSV import of items / counterparties (T08).
-- Run order: after E100, E110. Standalone: names no CRM object. Safe to re-run.
-- Redefines: nothing. Adds capabilities + defaults to the E100 matrix (role_caps_sync) and an AFTER INSERT trigger on
--           erp.tenants that gives every new tenant its default units, VAT classes and transit warehouse.
-- Tests    : tests/E120_master_tests.sql, tests/E990_generated_isolation_tests.sql (registry + fixtures)
-- =====================================================================

do $$ begin
  if to_regprocedure('erp.require_member()') is null then raise exception 'run E100_tenancy.sql first'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 0. Small shared helpers (internal)
-- ---------------------------------------------------------------------
create or replace function erp.try_numeric(p text) returns numeric
language plpgsql immutable set search_path = '' as $$
begin return p::numeric; exception when others then return null; end $$;

create or replace function erp.try_uuid(p text) returns uuid
language sql immutable set search_path = '' as $$
  select case when p ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then p::uuid end
$$;

-- a json key that is present and not empty
create or replace function erp.jset(p jsonb, k text) returns boolean
language sql immutable set search_path = '' as $$ select p ? k and nullif(btrim(coalesce(p ->> k, '')), '') is not null $$;

-- problems for keys outside a whitelist
create or replace function erp.unknown_keys(p jsonb, p_allowed text[]) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(erp.problem('not_editable', k, format('%s cannot be set here.', k)) order by k), '[]'::jsonb)
    from jsonb_object_keys(p) k where not (k = any (p_allowed))
$$;

-- an optional number >= 0 (problem when not a number / negative); returns null when absent
create or replace function erp.jnum_problem(p jsonb, k text, p_min numeric default 0) returns jsonb
language sql immutable set search_path = '' as $$
  select case when not erp.jset(p, k) then '[]'::jsonb
              when erp.try_numeric(p ->> k) is null then jsonb_build_array(erp.problem('invalid', k, format('%s must be a number.', k)))
              when erp.try_numeric(p ->> k) < p_min then jsonb_build_array(erp.problem('invalid', k, format('%s must be %s or more.', k, p_min)))
              else '[]'::jsonb end
$$;

-- an id the caller gives must be a uuid of its own tenant (otherwise ERP_TENANT, nothing told about other tenants)
create or replace function erp.require_own(p_tenant uuid, p_kind text, p_id uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
declare ok boolean;
begin
  ok := case p_kind
    when 'unit'      then exists (select 1 from erp.units x where x.tenant_id = p_tenant and x.unit_id = p_id)
    when 'vat'       then exists (select 1 from erp.vat_classes x where x.tenant_id = p_tenant and x.vat_class_id = p_id)
    when 'category'  then exists (select 1 from erp.item_categories x where x.tenant_id = p_tenant and x.category_id = p_id)
    when 'item'      then exists (select 1 from erp.items x where x.tenant_id = p_tenant and x.item_id = p_id)
    when 'warehouse' then exists (select 1 from erp.warehouses x where x.tenant_id = p_tenant and x.warehouse_id = p_id)
    when 'counterparty' then exists (select 1 from erp.counterparties x where x.tenant_id = p_tenant and x.counterparty_id = p_id)
    when 'series'    then exists (select 1 from erp.series x where x.tenant_id = p_tenant and x.series_id = p_id)
    else false end;
  -- E180 (T19): expense categories. A separate statement, planned only when asked (the table is created by E180)
  if p_kind = 'expense_category' then
    ok := exists (select 1 from erp.expense_categories x where x.tenant_id = p_tenant and x.category_id = p_id);
  end if;
  if p_id is null or not ok then
    perform erp.err('ERP_TENANT', format('%s %s does not belong to your organisation.', initcap(replace(p_kind, '_', ' ')), coalesce(p_id::text, 'null')));
  end if;
end $$;

-- keyset page helper: rows (jsonb array, already limit + 1) -> {rows, next} with the cursor built from the last row
create or replace function erp.page_reply(p_rows jsonb, p_lim int, p_keys text[]) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare r jsonb := coalesce(p_rows, '[]'::jsonb); nxt jsonb := '{}'; k text;
begin
  if jsonb_array_length(r) > p_lim then
    r := r - p_lim;
    foreach k in array p_keys loop nxt := nxt || jsonb_build_object(k, r -> (p_lim - 1) -> k); end loop;
    return jsonb_build_object('rows', r, 'next', nxt);
  end if;
  return jsonb_build_object('rows', r, 'next', null);
end $$;

-- ---------------------------------------------------------------------
-- 1. Tables, part 1 (T05)
-- ---------------------------------------------------------------------
create table if not exists erp.units (
  tenant_id  uuid not null references erp.tenants (tenant_id),
  unit_id    uuid not null default gen_random_uuid(),
  code       text not null check (code ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,11}$'),
  name       text not null check (btrim(name) <> '' and length(name) <= 60),
  decimals   smallint not null default 0 check (decimals between 0 and 4),
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (tenant_id, unit_id)
);
create unique index if not exists units_code_uq on erp.units (tenant_id, lower(code));

-- VAT classes: rate + myDATA VAT category + exemption reason (02 / 01 A). The rate of a class is never changed once a
-- posted line used it (E130 trigger): add a new class instead. Seeded defaults: ACCOUNTANT CONFIRMS (STATE.md).
create table if not exists erp.vat_classes (
  tenant_id       uuid not null references erp.tenants (tenant_id),
  vat_class_id    uuid not null default gen_random_uuid(),
  code            text not null check (code ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,15}$'),
  name            text not null check (btrim(name) <> '' and length(name) <= 80),
  rate            numeric(5,2) not null check (rate between 0 and 100),
  mydata_category smallint check (mydata_category between 1 and 20),
  exemption_code  text check (exemption_code ~ '^[0-9]{1,3}$'),
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  primary key (tenant_id, vat_class_id)
);
create unique index if not exists vat_classes_code_uq on erp.vat_classes (tenant_id, lower(code));

-- categories: a tree (parent in the same tenant, no cycle, depth <= 8). valuation_override is READ-ONLY here:
-- only the valuation switch (T39, owner) sets it; the effective method comes from erp.valuation_periods (E140).
create table if not exists erp.item_categories (
  tenant_id          uuid not null references erp.tenants (tenant_id),
  category_id        uuid not null default gen_random_uuid(),
  parent_id          uuid,
  code               text not null check (code ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,19}$'),
  name               text not null check (btrim(name) <> '' and length(name) <= 120),
  valuation_override text check (valuation_override in ('avg', 'fifo')),
  active             boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  primary key (tenant_id, category_id),
  foreign key (tenant_id, parent_id) references erp.item_categories (tenant_id, category_id)
);
create unique index if not exists item_categories_code_uq on erp.item_categories (tenant_id, lower(code));
create index if not exists item_categories_parent_idx on erp.item_categories (tenant_id, parent_id);

create table if not exists erp.items (
  tenant_id           uuid not null references erp.tenants (tenant_id),
  item_id             uuid not null default gen_random_uuid(),
  code                text not null check (code ~ '^[A-Za-z0-9][A-Za-z0-9_./-]{0,39}$'),
  name                text not null check (btrim(name) <> '' and length(name) <= 200),
  description         text check (length(description) <= 2000),
  kind                text not null default 'goods' check (kind in ('goods', 'consumable', 'service')),
  base_unit_id        uuid not null,
  category_id         uuid,
  vat_class_id        uuid,
  min_level           numeric(16,4) check (min_level >= 0),
  reorder_level       numeric(16,4) check (reorder_level >= 0),
  lot_tracked         boolean not null default false,
  sales_price         numeric(16,4) check (sales_price >= 0),
  last_purchase_price numeric(18,6),           -- set by posting (GRN / PINV), never typed
  active              boolean not null default true,
  version             int not null default 1,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  primary key (tenant_id, item_id),
  foreign key (tenant_id, base_unit_id) references erp.units (tenant_id, unit_id),
  foreign key (tenant_id, category_id) references erp.item_categories (tenant_id, category_id),
  foreign key (tenant_id, vat_class_id) references erp.vat_classes (tenant_id, vat_class_id)
);
create unique index if not exists items_code_uq on erp.items (tenant_id, lower(code));
create index if not exists items_name_idx on erp.items (tenant_id, lower(name) text_pattern_ops, item_id);
create index if not exists items_code_idx on erp.items (tenant_id, lower(code) text_pattern_ops);
create index if not exists items_category_idx on erp.items (tenant_id, category_id);
create index if not exists items_unit_idx on erp.items (tenant_id, base_unit_id);
create index if not exists items_vat_idx on erp.items (tenant_id, vat_class_id);

-- many barcodes per item; a barcode is unique per tenant
create table if not exists erp.item_barcodes (
  tenant_id  uuid not null references erp.tenants (tenant_id),
  barcode    text not null check (barcode ~ '^[A-Za-z0-9._-]{3,64}$'),
  item_id    uuid not null,
  created_at timestamptz not null default now(),
  primary key (tenant_id, barcode),
  foreign key (tenant_id, item_id) references erp.items (tenant_id, item_id)
);
create index if not exists item_barcodes_item_idx on erp.item_barcodes (tenant_id, item_id);

-- category tree guard: parent of the same tenant, no cycle, depth <= 8
create or replace function erp.tg_category_tree() returns trigger
language plpgsql set search_path = '' as $$
declare cur uuid := new.parent_id; depth int := 1;
begin
  while cur is not null loop
    if cur = new.category_id then perform erp.err('ERP_VALIDATION', 'A category cannot be its own parent or ancestor.',
                                                  jsonb_build_array(erp.problem('cycle', 'parent_id', 'A category cannot be its own parent or ancestor.'))); end if;
    depth := depth + 1;
    if depth > 8 then perform erp.err('ERP_VALIDATION', 'Categories nest at most 8 levels.',
                                      jsonb_build_array(erp.problem('too_deep', 'parent_id', 'Categories nest at most 8 levels.'))); end if;
    select c.parent_id into cur from erp.item_categories c where c.tenant_id = new.tenant_id and c.category_id = cur;
  end loop;
  return new;
end $$;
drop trigger if exists item_categories_tree on erp.item_categories;
create trigger item_categories_tree before insert or update of parent_id on erp.item_categories
  for each row execute function erp.tg_category_tree();

-- ---------------------------------------------------------------------
-- 1b. Tables, part 2 (T06): warehouses, counterparties, document-type catalogue, series
-- ---------------------------------------------------------------------
-- A warehouse belongs to exactly one branch; the one system warehouse kind = in_transit has none (02).
create table if not exists erp.warehouses (
  tenant_id    uuid not null references erp.tenants (tenant_id),
  warehouse_id uuid not null default gen_random_uuid(),
  branch_id    uuid,
  code         text not null check (code ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,19}$'),
  name         text not null check (btrim(name) <> '' and length(name) <= 120),
  kind         text not null default 'normal' check (kind in ('normal', 'in_transit')),
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (tenant_id, warehouse_id),
  foreign key (tenant_id, branch_id) references erp.branches (tenant_id, branch_id),
  check ((kind = 'in_transit') = (branch_id is null))
);
create unique index if not exists warehouses_code_uq on erp.warehouses (tenant_id, lower(code));
create unique index if not exists warehouses_transit_uq on erp.warehouses (tenant_id) where kind = 'in_transit';
create index if not exists warehouses_branch_idx on erp.warehouses (tenant_id, branch_id);

-- counterparties (customer / supplier / both). Hooks for suite mode (06 section 6): ext_source + ext_ref, unique per
-- tenant when set; only E900 (phase IP) writes ext_source = 'crm'. No patient / health data ever.
create table if not exists erp.counterparties (
  tenant_id          uuid not null references erp.tenants (tenant_id),
  counterparty_id    uuid not null default gen_random_uuid(),
  code               text check (code ~ '^[A-Za-z0-9][A-Za-z0-9_./-]{0,29}$'),
  kind               text not null default 'supplier' check (kind in ('customer', 'supplier', 'both')),
  name               text not null check (btrim(name) <> '' and length(name) <= 200),
  tax_id             text check (tax_id ~ '^[A-Z0-9]{2,20}$'),
  tax_office         text check (length(tax_office) <= 80),
  country            text not null default 'GR' check (country ~ '^[A-Z]{2}$'),
  street             text check (length(street) <= 200),
  city               text check (length(city) <= 80),
  postal_code        text check (length(postal_code) <= 20),
  email              text check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  phone              text check (length(phone) <= 40),
  payment_terms_days int check (payment_terms_days between 0 and 365),
  notes              text check (length(notes) <= 2000),
  active             boolean not null default true,
  ext_source         text check (ext_source in ('manual', 'import', 'crm')),
  ext_ref            text check (length(ext_ref) <= 100),
  ext_synced_at      timestamptz,
  version            int not null default 1,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  primary key (tenant_id, counterparty_id),
  check (ext_ref is null or ext_source is not null)
);
create unique index if not exists counterparties_code_uq on erp.counterparties (tenant_id, lower(code)) where code is not null;
create unique index if not exists counterparties_tax_uq on erp.counterparties (tenant_id, country, tax_id) where tax_id is not null;
create unique index if not exists counterparties_ext_uq on erp.counterparties (tenant_id, ext_source, ext_ref) where ext_ref is not null;
create index if not exists counterparties_name_idx on erp.counterparties (tenant_id, lower(name) text_pattern_ops, counterparty_id);

-- document-type catalogue (01 C). Seeded here with every type of the catalogue, enabled = false; the file that
-- implements a type enables it and owns its posting attributes (E130 adds those columns) and transitions.
create table if not exists erp.doc_types (
  doc_type           text primary key check (doc_type ~ '^[A-Z][A-Z_]{1,9}$'),
  name               text not null,
  area               text not null check (area in ('purchasing', 'sales', 'warehouse', 'money')),
  fiscal             boolean not null default false,
  gapless_default    boolean not null default false,
  series_scope       text not null default 'branch' check (series_scope in ('branch', 'tenant')),
  needs_counterparty boolean not null default false,
  cap_prefix         text not null check (cap_prefix ~ '^[a-z][a-z_]{1,20}$'),
  sort               int not null default 100,
  enabled            boolean not null default false,
  seed_version       int not null default 1
);
comment on table erp.doc_types is 'platform catalog: document types of 01 C (no tenant data)';
insert into erp.doc_types (doc_type, name, area, fiscal, gapless_default, series_scope, needs_counterparty, cap_prefix, sort) values
  ('PO',      'Purchase order',            'purchasing', false, false, 'branch', true,  'po',   10),
  ('GRN',     'Goods receipt',             'purchasing', false, false, 'branch', true,  'grn',  20),
  ('PINV',    'Supplier invoice',          'purchasing', false, false, 'branch', true,  'pinv', 30),
  ('EXP',     'Expense document',          'purchasing', false, false, 'branch', false, 'exp',  40),
  ('PCRN',    'Supplier credit note',      'purchasing', false, false, 'branch', true,  'pcrn', 50),
  ('PRET',    'Purchase return',           'purchasing', true,  true,  'branch', true,  'pret', 60),
  ('SQ',      'Quote',                     'sales',      false, false, 'branch', true,  'sq',   110),
  ('SO',      'Sales order',               'sales',      false, false, 'branch', true,  'so',   120),
  ('DN',      'Delivery note',             'sales',      true,  true,  'branch', true,  'dn',   130),
  ('SINV',    'Sales invoice',             'sales',      true,  true,  'branch', true,  'sinv', 140),
  ('SVC',     'Service invoice',           'sales',      true,  true,  'branch', true,  'svc',  150),
  ('CRN',     'Credit note',               'sales',      true,  true,  'branch', true,  'crn',  160),
  ('RR',      'Retail receipt (goods)',    'sales',      true,  true,  'branch', false, 'rr',   170),
  ('RS',      'Retail receipt (services)', 'sales',      true,  true,  'branch', false, 'rs',   180),
  ('RCR',     'Retail credit',             'sales',      true,  true,  'branch', false, 'rcr',  190),
  ('REQ',     'Material request',          'warehouse',  false, false, 'branch', false, 'req',  210),
  ('OPN',     'Opening balance',           'warehouse',  false, false, 'tenant', false, 'opn',  220),
  ('TRF',     'Transfer',                  'warehouse',  false, true,  'branch', false, 'trf',  230),
  ('ADJ_IN',  'Stock adjustment +',        'warehouse',  false, false, 'branch', false, 'adj',  240),
  ('ADJ_OUT', 'Stock adjustment -',        'warehouse',  false, false, 'branch', false, 'adj',  250),
  ('CONS',    'Internal consumption',      'warehouse',  false, false, 'branch', false, 'cons', 260),
  ('STK',     'Stocktake',                 'warehouse',  false, false, 'branch', false, 'stk',  270),
  ('RCPT',    'Receipt',                   'money',      false, false, 'branch', true,  'rcpt', 310),
  ('PAY',     'Payment',                   'money',      false, false, 'branch', false, 'pay',  320),
  ('MTR',     'Money transfer',            'money',      false, false, 'tenant', false, 'mtr',  330),
  ('CBAL',    'Opening balances (money)',  'money',      false, false, 'tenant', false, 'cbal', 340)
on conflict (doc_type) do nothing;

-- series (02 "Numbering and series"): branch null = tenant-wide; one active default per (type, branch, year).
-- The number is taken only at post / submit by erp.next_number (E130); last_no records the last number given, and
-- from then on type, branch, year, gapless, numbering and next_no are fixed.
create table if not exists erp.series (
  tenant_id   uuid not null references erp.tenants (tenant_id),
  series_id   uuid not null default gen_random_uuid(),
  branch_id   uuid,
  doc_type    text not null references erp.doc_types (doc_type),
  code        text not null check (code ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,19}$'),
  fiscal_year int check (fiscal_year between 2000 and 2100),
  next_no     bigint not null default 1 check (next_no >= 1),
  last_no     bigint,
  gapless     boolean not null default false,
  numbering   text not null default 'local' check (numbering in ('local', 'provider')),
  is_default  boolean not null default true,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (tenant_id, series_id),
  foreign key (tenant_id, branch_id) references erp.branches (tenant_id, branch_id)
);
create unique index if not exists series_code_uq on erp.series (tenant_id, doc_type, lower(code), coalesce(fiscal_year, 0));
create unique index if not exists series_default_uq on erp.series (tenant_id, doc_type, coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid), coalesce(fiscal_year, 0))
  where is_default and active;
create index if not exists series_branch_idx on erp.series (tenant_id, branch_id);

-- ---------------------------------------------------------------------
-- 2. Capabilities (02 matrix rows "Items, categories, units, warehouses", "Counterparties, VAT classes, price
--    lists", "Tenant settings, members, series", "Cost and stock value")
-- ---------------------------------------------------------------------
insert into erp.capabilities (capability, area, note) values
  ('item.read',            'master', 'items, units, categories (clinic_user: name, unit, on hand)'),
  ('item.detail.read',     'master', 'item prices, levels, VAT class (everyone but clinic_user)'),
  ('item.write',           'master', 'create / change items, units, categories'),
  ('master.archive',       'master', 'deactivate items, units, categories, warehouses (owner, manager)'),
  ('vat.read',             'master', 'VAT classes'),
  ('vat.write',            'master', 'create / change VAT classes'),
  ('counterparty.archive', 'master', 'deactivate counterparties and VAT classes (owner, manager)'),
  ('cost.read',            'stock',  'cost columns and stock value (02: returned only with this capability)'),
  ('warehouse.read',       'master', 'warehouses of the visible branches'),
  ('warehouse.write',      'master', 'create / change warehouses of an own branch'),
  ('counterparty.read',    'master', 'customers and suppliers'),
  ('counterparty.write',   'master', 'create / change customers and suppliers'),
  ('series.read',          'master', 'document series'),
  ('series.write',         'master', 'create / change document series (owner)')
on conflict (capability) do nothing;
insert into erp.role_cap_defaults (role, capability)
select r, c from (values
  ('owner', 'item.read'), ('owner', 'item.detail.read'), ('owner', 'item.write'), ('owner', 'master.archive'),
  ('owner', 'vat.read'), ('owner', 'vat.write'), ('owner', 'cost.read'), ('owner', 'counterparty.archive'),
  ('manager', 'item.read'), ('manager', 'item.detail.read'), ('manager', 'item.write'), ('manager', 'master.archive'),
  ('manager', 'vat.read'), ('manager', 'vat.write'), ('manager', 'cost.read'), ('manager', 'counterparty.archive'),
  ('warehouse', 'item.read'), ('warehouse', 'item.detail.read'), ('warehouse', 'item.write'), ('warehouse', 'vat.read'),
  ('accounting', 'item.read'), ('accounting', 'item.detail.read'), ('accounting', 'vat.read'), ('accounting', 'vat.write'), ('accounting', 'cost.read'),
  ('clinic_user', 'item.read'),
  ('readonly', 'item.read'), ('readonly', 'item.detail.read'), ('readonly', 'vat.read'), ('readonly', 'cost.read'),
  -- part 2 (T06)
  ('owner', 'warehouse.read'), ('owner', 'warehouse.write'), ('owner', 'counterparty.read'), ('owner', 'counterparty.write'),
  ('owner', 'series.read'), ('owner', 'series.write'),
  ('manager', 'warehouse.read'), ('manager', 'warehouse.write'), ('manager', 'counterparty.read'), ('manager', 'counterparty.write'), ('manager', 'series.read'),
  ('warehouse', 'warehouse.read'), ('warehouse', 'warehouse.write'), ('warehouse', 'counterparty.read'),
  ('accounting', 'warehouse.read'), ('accounting', 'counterparty.read'), ('accounting', 'counterparty.write'), ('accounting', 'series.read'),
  ('clinic_user', 'warehouse.read'),
  ('readonly', 'warehouse.read'), ('readonly', 'counterparty.read')) v(r, c)
on conflict do nothing;
select erp.role_caps_sync();

-- ---------------------------------------------------------------------
-- 3. Defaults for every tenant (existing ones now, new ones by the tenants trigger)
-- ---------------------------------------------------------------------
create or replace function erp.master_init(p_tenant uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into erp.units (tenant_id, code, name, decimals) values
    (p_tenant, 'PCS', 'Pieces', 0), (p_tenant, 'BOX', 'Box', 0), (p_tenant, 'PACK', 'Pack', 0),
    (p_tenant, 'KG', 'Kilogram', 3), (p_tenant, 'L', 'Litre', 3), (p_tenant, 'M', 'Metre', 2)
  on conflict do nothing;
  -- Greek VAT rates as editable defaults; myDATA category numbers from [L4], unverified: ACCOUNTANT CONFIRMS
  insert into erp.vat_classes (tenant_id, code, name, rate, mydata_category) values
    (p_tenant, 'VAT24', 'VAT 24%', 24, 1), (p_tenant, 'VAT13', 'VAT 13%', 13, 2), (p_tenant, 'VAT6', 'VAT 6%', 6, 3),
    (p_tenant, 'VAT0', 'VAT exempt 0% (exemption reason: accountant)', 0, 7)
  on conflict do nothing;
  -- one system transit warehouse per tenant, no branch (02 "Branch and warehouse model"); never selectable by users
  insert into erp.warehouses (tenant_id, branch_id, code, name, kind) values (p_tenant, null, 'TRANSIT', 'In transit', 'in_transit')
  on conflict do nothing;
end $$;

create or replace function erp.tg_tenants_master() returns trigger
language plpgsql security definer set search_path = '' as $$
begin perform erp.master_init(new.tenant_id); return null; end $$;
drop trigger if exists tenants_e120_init on erp.tenants;
create trigger tenants_e120_init after insert on erp.tenants for each row execute function erp.tg_tenants_master();
do $$ begin perform erp.master_init(tenant_id) from erp.tenants; end $$;

-- ---------------------------------------------------------------------
-- 4. JSON shapes
-- ---------------------------------------------------------------------
create or replace function erp.unit_json(u erp.units) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('unit_id', u.unit_id, 'code', u.code, 'name', u.name, 'decimals', u.decimals, 'active', u.active, 'updated_at', u.updated_at)
$$;
create or replace function erp.vat_json(v erp.vat_classes) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('vat_class_id', v.vat_class_id, 'code', v.code, 'name', v.name, 'rate', v.rate, 'mydata_category', v.mydata_category,
                            'exemption_code', v.exemption_code, 'active', v.active, 'updated_at', v.updated_at)
$$;
create or replace function erp.category_json(c erp.item_categories) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('category_id', c.category_id, 'parent_id', c.parent_id, 'code', c.code, 'name', c.name,
                            'valuation_override', c.valuation_override, 'active', c.active, 'updated_at', c.updated_at,
                            'path', (with recursive up as (
                                       select x.category_id, x.parent_id, x.code, 1 lvl from erp.item_categories x where x.tenant_id = c.tenant_id and x.category_id = c.category_id
                                       union all
                                       select p.category_id, p.parent_id, p.code, up.lvl + 1 from erp.item_categories p join up on p.tenant_id = c.tenant_id and p.category_id = up.parent_id
                                        where up.lvl < 9)
                                     select string_agg(code, ' / ' order by lvl desc) from up))
$$;
-- item: full shape with item.detail.read; clinic_user gets name, code, unit, kind, barcodes only (02 matrix);
-- last_purchase_price only with cost.read.
create or replace function erp.item_json(i erp.items, p_detail boolean, p_cost boolean) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('item_id', i.item_id, 'code', i.code, 'name', i.name, 'kind', i.kind, 'base_unit_id', i.base_unit_id,
                            'unit_code', (select u.code from erp.units u where u.tenant_id = i.tenant_id and u.unit_id = i.base_unit_id),
                            'lot_tracked', i.lot_tracked, 'active', i.active,
                            'barcodes', coalesce((select jsonb_agg(b.barcode order by b.barcode) from erp.item_barcodes b where b.tenant_id = i.tenant_id and b.item_id = i.item_id), '[]'::jsonb))
      || case when p_detail then jsonb_build_object('description', i.description, 'category_id', i.category_id,
                            'category_code', (select c.code from erp.item_categories c where c.tenant_id = i.tenant_id and c.category_id = i.category_id),
                            'vat_class_id', i.vat_class_id,
                            'vat_code', (select v.code from erp.vat_classes v where v.tenant_id = i.tenant_id and v.vat_class_id = i.vat_class_id),
                            'min_level', i.min_level, 'reorder_level', i.reorder_level, 'sales_price', i.sales_price,
                            'version', i.version, 'updated_at', i.updated_at) else '{}'::jsonb end
      || case when p_cost then jsonb_build_object('last_purchase_price', i.last_purchase_price) else '{}'::jsonb end
$$;

-- EAN-8 / UPC-A (12) / EAN-13 check digit for all-digit barcodes of those lengths; other codes are internal (no check)
create or replace function erp.barcode_ok(p text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare n int := length(p); s int := 0; i int; d int;
begin
  if p !~ '^[0-9]+$' or n not in (8, 12, 13) then return true; end if;
  for i in 1 .. n - 1 loop
    d := substr(p, n - i, 1)::int;                -- from the right, skipping the check digit
    s := s + d * case when i % 2 = 1 then 3 else 1 end;
  end loop;
  return (10 - s % 10) % 10 = substr(p, n, 1)::int;
end $$;

-- ---------------------------------------------------------------------
-- 5. RPCs part 1: units, VAT classes, categories, items
-- ---------------------------------------------------------------------
create or replace function erp_api.unit_list(p_include_inactive boolean default false, p_cursor jsonb default null, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 100), 1), 500); rows jsonb;
begin
  m := erp.require_member();
  perform erp.require_cap('item.read');
  select jsonb_agg(erp.unit_json(u) order by lower(u.code), u.unit_id) into rows from (
    select * from erp.units u where u.tenant_id = m.tenant_id and (p_include_inactive or u.active)
       and (p_cursor is null or (lower(u.code), u.unit_id) > (lower(p_cursor ->> 'code'), erp.try_uuid(p_cursor ->> 'unit_id')))
     order by lower(u.code), u.unit_id limit lim + 1) u;
  return erp.page_reply(rows, lim, array['code', 'unit_id']);
end $$;

-- unit_save: keys unit_id (update), code, name, decimals (0-4), active. Deactivating needs master.archive.
create or replace function erp_api.unit_save(p_unit jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; old erp.units; u erp.units; id uuid; probs jsonb; res jsonb; v_code text; v_name text; v_dec int; v_active boolean;
begin
  m := erp.require_member();
  perform erp.require_cap('item.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'unit_save', p_unit);
  if prev is not null then return prev; end if;
  if p_unit is null or jsonb_typeof(p_unit) <> 'object' then p_unit := '{}'; end if;
  probs := erp.unknown_keys(p_unit, array['unit_id', 'code', 'name', 'decimals', 'active']);
  if erp.jset(p_unit, 'unit_id') then
    id := erp.try_uuid(p_unit ->> 'unit_id');
    perform erp.require_own(m.tenant_id, 'unit', id);
    select * into old from erp.units where tenant_id = m.tenant_id and unit_id = id for update;
  end if;
  v_code := btrim(coalesce(p_unit ->> 'code', old.code, ''));
  v_name := btrim(coalesce(p_unit ->> 'name', old.name, ''));
  v_active := coalesce((p_unit ->> 'active')::boolean, old.active, true);
  if p_unit ? 'decimals' and (p_unit ->> 'decimals') !~ '^[0-4]$' then probs := probs || erp.problem('invalid', 'decimals', 'Decimals: 0 to 4.');
  else v_dec := coalesce((p_unit ->> 'decimals')::int, old.decimals, 0); end if;
  if v_code = '' then probs := probs || erp.problem('required', 'code', 'Code is required.');
  elsif v_code !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,11}$' then probs := probs || erp.problem('invalid', 'code', 'Code: letters, digits, . - _, up to 12.');
  elsif exists (select 1 from erp.units x where x.tenant_id = m.tenant_id and lower(x.code) = lower(v_code) and x.unit_id is distinct from id) then
    probs := probs || erp.problem('duplicate', 'code', format('Unit %s already exists.', v_code)); end if;
  if v_name = '' then probs := probs || erp.problem('required', 'name', 'Name is required.');
  elsif length(v_name) > 60 then probs := probs || erp.problem('invalid', 'name', 'Name: at most 60 characters.'); end if;
  if not v_active and coalesce(old.active, true) then
    perform erp.require_cap('master.archive');
    if id is not null and exists (select 1 from erp.items i where i.tenant_id = m.tenant_id and i.base_unit_id = id and i.active) then
      probs := probs || erp.problem('in_use', 'active', 'Active items use this unit.'); end if;
  end if;
  perform erp.raise_problems(probs);
  if id is null then
    insert into erp.units (tenant_id, code, name, decimals, active) values (m.tenant_id, v_code, v_name, v_dec, v_active) returning * into u;
    perform erp.audit(m.tenant_id, 'unit.create', 'units', u.unit_id::text, null, erp.unit_json(u));
  else
    update erp.units set code = v_code, name = v_name, decimals = v_dec, active = v_active, updated_at = now()
     where tenant_id = m.tenant_id and unit_id = id returning * into u;
    perform erp.audit(m.tenant_id, 'unit.update', 'units', u.unit_id::text, erp.unit_json(old) - 'updated_at', erp.unit_json(u) - 'updated_at');
  end if;
  res := erp.unit_json(u);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'unit_save', p_unit, res);
end $$;

create or replace function erp_api.vat_class_list(p_include_inactive boolean default false, p_cursor jsonb default null, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 100), 1), 500); rows jsonb;
begin
  m := erp.require_member();
  perform erp.require_cap('vat.read');
  select jsonb_agg(erp.vat_json(v) order by lower(v.code), v.vat_class_id) into rows from (
    select * from erp.vat_classes v where v.tenant_id = m.tenant_id and (p_include_inactive or v.active)
       and (p_cursor is null or (lower(v.code), v.vat_class_id) > (lower(p_cursor ->> 'code'), erp.try_uuid(p_cursor ->> 'vat_class_id')))
     order by lower(v.code), v.vat_class_id limit lim + 1) v;
  return erp.page_reply(rows, lim, array['code', 'vat_class_id']);
end $$;

-- vat_class_save: keys vat_class_id, code, name, rate (0-100), mydata_category (1-20), exemption_code (digits), active.
-- Deactivating needs counterparty.archive (02: owner / manager "a" on this matrix row).
create or replace function erp_api.vat_class_save(p_vat jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; old erp.vat_classes; v erp.vat_classes; id uuid; probs jsonb; res jsonb;
        v_code text; v_name text; v_rate numeric; v_cat int; v_ex text; v_active boolean;
begin
  m := erp.require_member();
  perform erp.require_cap('vat.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'vat_class_save', p_vat);
  if prev is not null then return prev; end if;
  if p_vat is null or jsonb_typeof(p_vat) <> 'object' then p_vat := '{}'; end if;
  probs := erp.unknown_keys(p_vat, array['vat_class_id', 'code', 'name', 'rate', 'mydata_category', 'exemption_code', 'active']);
  if erp.jset(p_vat, 'vat_class_id') then
    id := erp.try_uuid(p_vat ->> 'vat_class_id');
    perform erp.require_own(m.tenant_id, 'vat', id);
    select * into old from erp.vat_classes where tenant_id = m.tenant_id and vat_class_id = id for update;
  end if;
  v_code := btrim(coalesce(p_vat ->> 'code', old.code, ''));
  v_name := btrim(coalesce(p_vat ->> 'name', old.name, ''));
  v_active := coalesce((p_vat ->> 'active')::boolean, old.active, true);
  probs := probs || erp.jnum_problem(p_vat, 'rate');
  v_rate := coalesce(erp.try_numeric(p_vat ->> 'rate'), old.rate);
  if v_rate is null then probs := probs || erp.problem('required', 'rate', 'Rate is required.');
  elsif v_rate > 100 or v_rate <> round(v_rate, 2) then probs := probs || erp.problem('invalid', 'rate', 'Rate: 0 to 100 with at most 2 decimals.'); end if;
  if p_vat ? 'mydata_category' then
    if nullif(p_vat ->> 'mydata_category', '') is null then v_cat := null;
    elsif (p_vat ->> 'mydata_category') !~ '^[0-9]{1,2}$' or (p_vat ->> 'mydata_category')::int not between 1 and 20 then
      probs := probs || erp.problem('invalid', 'mydata_category', 'myDATA VAT category: a number 1-20.');
    else v_cat := (p_vat ->> 'mydata_category')::int; end if;
  else v_cat := old.mydata_category; end if;
  v_ex := case when p_vat ? 'exemption_code' then nullif(btrim(p_vat ->> 'exemption_code'), '') else old.exemption_code end;
  if v_ex is not null and v_ex !~ '^[0-9]{1,3}$' then probs := probs || erp.problem('invalid', 'exemption_code', 'Exemption reason: the myDATA code (digits).'); end if;
  if v_code = '' then probs := probs || erp.problem('required', 'code', 'Code is required.');
  elsif v_code !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,15}$' then probs := probs || erp.problem('invalid', 'code', 'Code: letters, digits, . - _, up to 16.');
  elsif exists (select 1 from erp.vat_classes x where x.tenant_id = m.tenant_id and lower(x.code) = lower(v_code) and x.vat_class_id is distinct from id) then
    probs := probs || erp.problem('duplicate', 'code', format('VAT class %s already exists.', v_code)); end if;
  if v_name = '' then probs := probs || erp.problem('required', 'name', 'Name is required.'); end if;
  if not v_active and coalesce(old.active, true) then perform erp.require_cap('counterparty.archive'); end if;
  perform erp.raise_problems(probs);
  if id is null then
    insert into erp.vat_classes (tenant_id, code, name, rate, mydata_category, exemption_code, active)
    values (m.tenant_id, v_code, v_name, v_rate, v_cat, v_ex, v_active) returning * into v;
    perform erp.audit(m.tenant_id, 'vat_class.create', 'vat_classes', v.vat_class_id::text, null, erp.vat_json(v));
  else
    update erp.vat_classes set code = v_code, name = v_name, rate = v_rate, mydata_category = v_cat, exemption_code = v_ex, active = v_active, updated_at = now()
     where tenant_id = m.tenant_id and vat_class_id = id returning * into v;
    perform erp.audit(m.tenant_id, 'vat_class.update', 'vat_classes', v.vat_class_id::text, erp.vat_json(old) - 'updated_at', erp.vat_json(v) - 'updated_at');
  end if;
  res := erp.vat_json(v);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'vat_class_save', p_vat, res);
end $$;

-- category_list: flat list ordered by code (the page builds the tree from parent_id); each row has its path
create or replace function erp_api.category_list(p_include_inactive boolean default false, p_cursor jsonb default null, p_limit int default 200) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 200), 1), 500); rows jsonb;
begin
  m := erp.require_member();
  perform erp.require_cap('item.read');
  select jsonb_agg(erp.category_json(c) order by lower(c.code), c.category_id) into rows from (
    select * from erp.item_categories c where c.tenant_id = m.tenant_id and (p_include_inactive or c.active)
       and (p_cursor is null or (lower(c.code), c.category_id) > (lower(p_cursor ->> 'code'), erp.try_uuid(p_cursor ->> 'category_id')))
     order by lower(c.code), c.category_id limit lim + 1) c;
  return erp.page_reply(rows, lim, array['code', 'category_id']);
end $$;

-- category_save: keys category_id, parent_id (null = top level), code, name, active. valuation_override is not editable.
create or replace function erp_api.category_save(p_category jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; old erp.item_categories; c erp.item_categories; id uuid; v_parent uuid; probs jsonb; res jsonb;
        v_code text; v_name text; v_active boolean;
begin
  m := erp.require_member();
  perform erp.require_cap('item.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'category_save', p_category);
  if prev is not null then return prev; end if;
  if p_category is null or jsonb_typeof(p_category) <> 'object' then p_category := '{}'; end if;
  probs := erp.unknown_keys(p_category, array['category_id', 'parent_id', 'code', 'name', 'active']);
  if erp.jset(p_category, 'category_id') then
    id := erp.try_uuid(p_category ->> 'category_id');
    perform erp.require_own(m.tenant_id, 'category', id);
    select * into old from erp.item_categories where tenant_id = m.tenant_id and category_id = id for update;
  end if;
  if p_category ? 'parent_id' then
    if erp.jset(p_category, 'parent_id') then
      v_parent := erp.try_uuid(p_category ->> 'parent_id');
      perform erp.require_own(m.tenant_id, 'category', v_parent);
    end if;
  else v_parent := old.parent_id; end if;
  v_code := btrim(coalesce(p_category ->> 'code', old.code, ''));
  v_name := btrim(coalesce(p_category ->> 'name', old.name, ''));
  v_active := coalesce((p_category ->> 'active')::boolean, old.active, true);
  if v_code = '' then probs := probs || erp.problem('required', 'code', 'Code is required.');
  elsif v_code !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,19}$' then probs := probs || erp.problem('invalid', 'code', 'Code: letters, digits, . - _, up to 20.');
  elsif exists (select 1 from erp.item_categories x where x.tenant_id = m.tenant_id and lower(x.code) = lower(v_code) and x.category_id is distinct from id) then
    probs := probs || erp.problem('duplicate', 'code', format('Category %s already exists.', v_code)); end if;
  if v_name = '' then probs := probs || erp.problem('required', 'name', 'Name is required.'); end if;
  if v_parent is not null and v_parent = id then probs := probs || erp.problem('cycle', 'parent_id', 'A category cannot be its own parent.'); end if;
  if not v_active and coalesce(old.active, true) then
    perform erp.require_cap('master.archive');
    if exists (select 1 from erp.item_categories x where x.tenant_id = m.tenant_id and x.parent_id = id and x.active) then
      probs := probs || erp.problem('in_use', 'active', 'Active sub-categories exist.'); end if;
  end if;
  perform erp.raise_problems(probs);
  if id is null then
    insert into erp.item_categories (tenant_id, parent_id, code, name, active) values (m.tenant_id, v_parent, v_code, v_name, v_active) returning * into c;
    perform erp.audit(m.tenant_id, 'category.create', 'item_categories', c.category_id::text, null, erp.category_json(c));
  else
    update erp.item_categories set parent_id = v_parent, code = v_code, name = v_name, active = v_active, updated_at = now()
     where tenant_id = m.tenant_id and category_id = id returning * into c;
    perform erp.audit(m.tenant_id, 'category.update', 'item_categories', c.category_id::text, erp.category_json(old) - 'updated_at', erp.category_json(c) - 'updated_at');
  end if;
  res := erp.category_json(c);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'category_save', p_category, res);
end $$;

-- item_list: filter keys q (code prefix, name contains, or an exact barcode), category_id (with sub-categories),
-- kind, active ('all' | true | false; default true). Ordered by code; next = {code, item_id}.
create or replace function erp_api.item_list(p_filter jsonb default '{}', p_cursor jsonb default null, p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 50), 1), 200); rows jsonb; q text; v_cat uuid; v_act text;
        det boolean := erp.can('item.detail.read'); cst boolean := erp.can('cost.read'); cats uuid[]; bc uuid;
begin
  m := erp.require_member();
  perform erp.require_cap('item.read');
  p_filter := coalesce(p_filter, '{}');
  q := nullif(lower(btrim(p_filter ->> 'q')), '');
  v_act := coalesce(p_filter ->> 'active', 'true');
  if erp.jset(p_filter, 'category_id') then
    v_cat := erp.try_uuid(p_filter ->> 'category_id');
    perform erp.require_own(m.tenant_id, 'category', v_cat);
    with recursive down as (select v_cat id union all select c.category_id from erp.item_categories c join down on c.tenant_id = m.tenant_id and c.parent_id = down.id)
    select array_agg(id) into cats from down;
  end if;
  if q is not null then select b.item_id into bc from erp.item_barcodes b where b.tenant_id = m.tenant_id and b.barcode = btrim(p_filter ->> 'q'); end if;
  select jsonb_agg(erp.item_json(i, det, cst) order by lower(i.code), i.item_id) into rows from (
    select * from erp.items i
     where i.tenant_id = m.tenant_id
       and (v_act = 'all' or i.active = (v_act = 'true'))
       and (q is null or i.item_id = bc or lower(i.code) like replace(replace(q, '%', '\%'), '_', '\_') || '%' or strpos(lower(i.name), q) > 0)
       and (cats is null or i.category_id = any (cats))
       and (p_filter ->> 'kind' is null or i.kind = p_filter ->> 'kind')
       and (p_cursor is null or (lower(i.code), i.item_id) > (lower(p_cursor ->> 'code'), erp.try_uuid(p_cursor ->> 'item_id')))
     order by lower(i.code), i.item_id limit lim + 1) i;
  return erp.page_reply(rows, lim, array['code', 'item_id']);
end $$;

create or replace function erp_api.item_get(p_item_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; i erp.items;
begin
  m := erp.require_member();
  perform erp.require_cap('item.read');
  perform erp.require_own(m.tenant_id, 'item', p_item_id);
  select * into i from erp.items where tenant_id = m.tenant_id and item_id = p_item_id;
  return erp.item_json(i, erp.can('item.detail.read'), erp.can('cost.read'));
end $$;

-- the validation + write of one item, shared by item_save and the CSV import (T08). p_item keys: item_id, version
-- (optional optimistic lock), code, name, description, kind, base_unit_id, category_id, vat_class_id, min_level,
-- reorder_level, lot_tracked, sales_price, active, barcodes (list; replaces the item's barcodes when given).
-- p_write false = check only (dry run). Returns {item_id, problems, row}.
create or replace function erp.item_upsert(p_tenant uuid, p_item jsonb, p_write boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare old erp.items; i erp.items; id uuid; probs jsonb; v_code text; v_name text; v_desc text; v_kind text; v_unit uuid; v_cat uuid; v_vat uuid;
        v_min numeric; v_reo numeric; v_lot boolean; v_price numeric; v_active boolean; bcs text[]; b text; e jsonb; v_old_json jsonb;
begin
  if p_item is null or jsonb_typeof(p_item) <> 'object' then p_item := '{}'; end if;
  probs := erp.unknown_keys(p_item, array['item_id', 'version', 'code', 'name', 'description', 'kind', 'base_unit_id', 'category_id', 'vat_class_id',
                                          'min_level', 'reorder_level', 'lot_tracked', 'sales_price', 'active', 'barcodes']);
  if erp.jset(p_item, 'item_id') then
    id := erp.try_uuid(p_item ->> 'item_id');
    perform erp.require_own(p_tenant, 'item', id);
    select * into old from erp.items where tenant_id = p_tenant and item_id = id for update;
    if erp.jset(p_item, 'version') and (p_item ->> 'version') is distinct from old.version::text then
      perform erp.err('ERP_CONFLICT', format('Item %s was changed by someone else (version %s, yours %s).', old.code, old.version, p_item ->> 'version'));
    end if;
  end if;
  v_code := btrim(coalesce(p_item ->> 'code', old.code, ''));
  v_name := btrim(coalesce(p_item ->> 'name', old.name, ''));
  v_desc := case when p_item ? 'description' then nullif(btrim(p_item ->> 'description'), '') else old.description end;
  v_kind := coalesce(nullif(p_item ->> 'kind', ''), old.kind, 'goods');
  v_active := coalesce((p_item ->> 'active')::boolean, old.active, true);
  if v_code = '' then probs := probs || erp.problem('required', 'code', 'Code is required.');
  elsif v_code !~ '^[A-Za-z0-9][A-Za-z0-9_./-]{0,39}$' then probs := probs || erp.problem('invalid', 'code', 'Code: letters, digits, . / - _, up to 40.');
  elsif exists (select 1 from erp.items x where x.tenant_id = p_tenant and lower(x.code) = lower(v_code) and x.item_id is distinct from id) then
    probs := probs || erp.problem('duplicate', 'code', format('Item code %s already exists.', v_code)); end if;
  if v_name = '' then probs := probs || erp.problem('required', 'name', 'Name is required.');
  elsif length(v_name) > 200 then probs := probs || erp.problem('invalid', 'name', 'Name: at most 200 characters.'); end if;
  if length(v_desc) > 2000 then probs := probs || erp.problem('invalid', 'description', 'Description: at most 2000 characters.'); end if;
  if v_kind not in ('goods', 'consumable', 'service') then probs := probs || erp.problem('invalid', 'kind', 'Kind: goods, consumable or service.'); end if;
  -- references: a uuid of another tenant raises ERP_TENANT; an inactive one is a problem
  if p_item ? 'base_unit_id' then
    if erp.jset(p_item, 'base_unit_id') then v_unit := erp.try_uuid(p_item ->> 'base_unit_id'); perform erp.require_own(p_tenant, 'unit', v_unit); end if;
  else v_unit := old.base_unit_id; end if;
  if v_unit is null then probs := probs || erp.problem('required', 'base_unit_id', 'Base unit is required.');
  elsif v_unit is distinct from old.base_unit_id and not exists (select 1 from erp.units u where u.tenant_id = p_tenant and u.unit_id = v_unit and u.active) then
    probs := probs || erp.problem('inactive', 'base_unit_id', 'This unit is not active.'); end if;
  if p_item ? 'category_id' then
    if erp.jset(p_item, 'category_id') then v_cat := erp.try_uuid(p_item ->> 'category_id'); perform erp.require_own(p_tenant, 'category', v_cat); end if;
  else v_cat := old.category_id; end if;
  if p_item ? 'vat_class_id' then
    if erp.jset(p_item, 'vat_class_id') then v_vat := erp.try_uuid(p_item ->> 'vat_class_id'); perform erp.require_own(p_tenant, 'vat', v_vat); end if;
  else v_vat := old.vat_class_id; end if;
  if v_vat is not null and v_vat is distinct from old.vat_class_id and not exists (select 1 from erp.vat_classes v where v.tenant_id = p_tenant and v.vat_class_id = v_vat and v.active) then
    probs := probs || erp.problem('inactive', 'vat_class_id', 'This VAT class is not active.'); end if;
  probs := probs || erp.jnum_problem(p_item, 'min_level') || erp.jnum_problem(p_item, 'reorder_level') || erp.jnum_problem(p_item, 'sales_price');
  v_min := case when p_item ? 'min_level' then round(erp.try_numeric(p_item ->> 'min_level'), 4) else old.min_level end;
  v_reo := case when p_item ? 'reorder_level' then round(erp.try_numeric(p_item ->> 'reorder_level'), 4) else old.reorder_level end;
  v_price := case when p_item ? 'sales_price' then round(erp.try_numeric(p_item ->> 'sales_price'), 4) else old.sales_price end;
  if v_min > 999999999999 or v_reo > 999999999999 or v_price > 999999999999 then probs := probs || erp.problem('invalid', 'sales_price', 'Number too large.'); end if;
  if p_item ? 'lot_tracked' and jsonb_typeof(p_item -> 'lot_tracked') <> 'boolean' then
    probs := probs || erp.problem('invalid', 'lot_tracked', 'lot_tracked must be true or false.');
  else v_lot := coalesce((p_item ->> 'lot_tracked')::boolean, old.lot_tracked, false); end if;
  -- lots / expiry arrive with T37 (E600); until then an item cannot be lot-tracked (it could not be posted)
  if v_lot then probs := probs || erp.problem('not_available', 'lot_tracked', 'Lot tracking comes with a later version (T37).'); end if;
  if v_kind = 'service' and (v_min is not null or v_reo is not null) then
    probs := probs || erp.problem('invalid', 'min_level', 'A service has no stock levels.'); end if;
  if p_item ? 'barcodes' then
    if jsonb_typeof(p_item -> 'barcodes') <> 'array' then probs := probs || erp.problem('invalid', 'barcodes', 'barcodes must be a list.');
    else
      for e in select * from jsonb_array_elements(p_item -> 'barcodes') loop
        b := btrim(e #>> '{}');
        if jsonb_typeof(e) <> 'string' or b !~ '^[A-Za-z0-9._-]{3,64}$' then
          probs := probs || erp.problem('invalid', 'barcodes', format('Barcode %s: 3-64 letters, digits, . - _.', coalesce(b, '?')));
        elsif not erp.barcode_ok(b) then probs := probs || erp.problem('checksum', 'barcodes', format('Barcode %s: wrong check digit.', b));
        elsif exists (select 1 from erp.item_barcodes x where x.tenant_id = p_tenant and x.barcode = b and x.item_id is distinct from id) then
          probs := probs || erp.problem('duplicate', 'barcodes', format('Barcode %s belongs to another item.', b));
        elsif not (b = any (coalesce(bcs, '{}'))) then bcs := coalesce(bcs, '{}') || b; end if;
      end loop;
    end if;
  end if;
  if not v_active and coalesce(old.active, true) and not erp.can('master.archive') then
    perform erp.err('ERP_FORBIDDEN', 'Your role or branch does not allow master.archive.');
  end if;
  if jsonb_array_length(probs) > 0 or not p_write then
    return jsonb_build_object('item_id', id, 'problems', probs, 'row', null);
  end if;
  if id is null then
    insert into erp.items (tenant_id, code, name, description, kind, base_unit_id, category_id, vat_class_id, min_level, reorder_level, lot_tracked, sales_price, active)
    values (p_tenant, v_code, v_name, v_desc, v_kind, v_unit, v_cat, v_vat, v_min, v_reo, v_lot, v_price, v_active) returning * into i;
  else
    v_old_json := erp.item_json(old, true, true);
    update erp.items set code = v_code, name = v_name, description = v_desc, kind = v_kind, base_unit_id = v_unit, category_id = v_cat, vat_class_id = v_vat,
           min_level = v_min, reorder_level = v_reo, lot_tracked = v_lot, sales_price = v_price, active = v_active, version = version + 1, updated_at = now()
     where tenant_id = p_tenant and item_id = id returning * into i;
  end if;
  if bcs is not null or (p_item ? 'barcodes' and jsonb_typeof(p_item -> 'barcodes') = 'array') then
    delete from erp.item_barcodes x where x.tenant_id = p_tenant and x.item_id = i.item_id and not (x.barcode = any (coalesce(bcs, '{}')));
    insert into erp.item_barcodes (tenant_id, barcode, item_id) select p_tenant, x, i.item_id from unnest(coalesce(bcs, '{}')) x on conflict do nothing;
  end if;
  if id is null then
    perform erp.audit(p_tenant, 'item.create', 'items', i.item_id::text, null, erp.item_json(i, true, true));
  else
    perform erp.audit(p_tenant, 'item.update', 'items', i.item_id::text, v_old_json - 'updated_at' - 'version', erp.item_json(i, true, true) - 'updated_at' - 'version');
  end if;
  return jsonb_build_object('item_id', i.item_id, 'problems', '[]'::jsonb, 'row', erp.item_json(i, true, erp.can('cost.read')));
end $$;

-- item_save: create (no item_id) or change the keys given. Deactivating needs master.archive.
create or replace function erp_api.item_save(p_item jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; r jsonb; res jsonb;
begin
  m := erp.require_member();
  perform erp.require_cap('item.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'item_save', p_item);
  if prev is not null then return prev; end if;
  r := erp.item_upsert(m.tenant_id, p_item, true);
  perform erp.raise_problems(r -> 'problems');
  res := r -> 'row';
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'item_save', p_item, res);
end $$;

-- ---------------------------------------------------------------------
-- 5b. RPCs part 2 (T06): warehouses, counterparties, document types, series
-- ---------------------------------------------------------------------
create or replace function erp.warehouse_json(w erp.warehouses) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('warehouse_id', w.warehouse_id, 'branch_id', w.branch_id, 'code', w.code, 'name', w.name, 'kind', w.kind, 'active', w.active,
                            'branch_code', (select b.code from erp.branches b where b.tenant_id = w.tenant_id and b.branch_id = w.branch_id), 'updated_at', w.updated_at)
$$;

-- warehouse_list: warehouses of the visible branches. Filter keys branch_id, include_inactive (boolean),
-- include_transit (boolean; only owner / all-branches members ever see the transit warehouse). next = {code, warehouse_id}.
create or replace function erp_api.warehouse_list(p_filter jsonb default '{}', p_cursor jsonb default null, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 100), 1), 500); rows jsonb; br uuid[] := erp.my_branches(); v_branch uuid;
        inact boolean; trans boolean;
begin
  m := erp.require_member();
  perform erp.require_cap('warehouse.read');
  p_filter := coalesce(p_filter, '{}');
  inact := coalesce((p_filter ->> 'include_inactive')::boolean, false);
  trans := coalesce((p_filter ->> 'include_transit')::boolean, false) and erp.sees_all_branches();
  if erp.jset(p_filter, 'branch_id') then v_branch := erp.try_uuid(p_filter ->> 'branch_id'); perform erp.require_branch_of_tenant(m.tenant_id, v_branch); end if;
  select jsonb_agg(erp.warehouse_json(w) order by lower(w.code), w.warehouse_id) into rows from (
    select * from erp.warehouses w
     where w.tenant_id = m.tenant_id
       and ((w.kind = 'normal' and w.branch_id = any (br)) or (w.kind = 'in_transit' and trans))
       and (v_branch is null or w.branch_id = v_branch)
       and (inact or w.active)
       and (p_cursor is null or (lower(w.code), w.warehouse_id) > (lower(p_cursor ->> 'code'), erp.try_uuid(p_cursor ->> 'warehouse_id')))
     order by lower(w.code), w.warehouse_id limit lim + 1) w;
  return erp.page_reply(rows, lim, array['code', 'warehouse_id']);
end $$;

-- warehouse_save: keys warehouse_id, branch_id (required on create), code, name, active. warehouse.write on the
-- branch (and on the new branch when it moves); deactivating needs master.archive. The transit warehouse is a
-- system row and cannot be changed. (E140 refuses moving / deactivating a warehouse that holds stock.)
create or replace function erp_api.warehouse_save(p_warehouse jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; old erp.warehouses; w erp.warehouses; id uuid; v_branch uuid; probs jsonb; res jsonb; v_code text; v_name text; v_active boolean;
begin
  m := erp.require_member();
  perform erp.require_cap('warehouse.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'warehouse_save', p_warehouse);
  if prev is not null then return prev; end if;
  if p_warehouse is null or jsonb_typeof(p_warehouse) <> 'object' then p_warehouse := '{}'; end if;
  probs := erp.unknown_keys(p_warehouse, array['warehouse_id', 'branch_id', 'code', 'name', 'active']);
  if erp.jset(p_warehouse, 'warehouse_id') then
    id := erp.try_uuid(p_warehouse ->> 'warehouse_id');
    perform erp.require_own(m.tenant_id, 'warehouse', id);
    select * into old from erp.warehouses where tenant_id = m.tenant_id and warehouse_id = id for update;
    if old.kind = 'in_transit' then perform erp.err('ERP_FORBIDDEN', 'The transit warehouse is a system warehouse and cannot be changed.'); end if;
    perform erp.require_cap('warehouse.write', old.branch_id);
  end if;
  if erp.jset(p_warehouse, 'branch_id') then
    v_branch := erp.try_uuid(p_warehouse ->> 'branch_id');
    perform erp.require_branch_of_tenant(m.tenant_id, v_branch);
    perform erp.require_cap('warehouse.write', v_branch);
  else v_branch := old.branch_id; end if;
  v_code := btrim(coalesce(p_warehouse ->> 'code', old.code, ''));
  v_name := btrim(coalesce(p_warehouse ->> 'name', old.name, ''));
  v_active := coalesce((p_warehouse ->> 'active')::boolean, old.active, true);
  if v_branch is null then probs := probs || erp.problem('required', 'branch_id', 'Branch is required.'); end if;
  if v_code = '' then probs := probs || erp.problem('required', 'code', 'Code is required.');
  elsif v_code !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,19}$' then probs := probs || erp.problem('invalid', 'code', 'Code: letters, digits, . - _, up to 20.');
  elsif lower(v_code) = 'transit' then probs := probs || erp.problem('reserved', 'code', 'TRANSIT is the system transit warehouse.');
  elsif exists (select 1 from erp.warehouses x where x.tenant_id = m.tenant_id and lower(x.code) = lower(v_code) and x.warehouse_id is distinct from id) then
    probs := probs || erp.problem('duplicate', 'code', format('Warehouse %s already exists.', v_code)); end if;
  if v_name = '' then probs := probs || erp.problem('required', 'name', 'Name is required.'); end if;
  if not v_active and coalesce(old.active, true) then perform erp.require_cap('master.archive'); end if;
  perform erp.raise_problems(probs);
  if id is null then
    insert into erp.warehouses (tenant_id, branch_id, code, name, active) values (m.tenant_id, v_branch, v_code, v_name, v_active) returning * into w;
    perform erp.audit(m.tenant_id, 'warehouse.create', 'warehouses', w.warehouse_id::text, null, erp.warehouse_json(w), w.branch_id);
  else
    update erp.warehouses set branch_id = v_branch, code = v_code, name = v_name, active = v_active, updated_at = now()
     where tenant_id = m.tenant_id and warehouse_id = id returning * into w;
    perform erp.audit(m.tenant_id, 'warehouse.update', 'warehouses', w.warehouse_id::text, erp.warehouse_json(old) - 'updated_at', erp.warehouse_json(w) - 'updated_at', w.branch_id);
  end if;
  res := erp.warehouse_json(w);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'warehouse_save', p_warehouse, res);
end $$;

-- Greek tax ID (AFM): 9 digits, check digit = (sum of d1..d8 x 2^(9-i)) mod 11 mod 10; all zeros refused
create or replace function erp.afm_ok(p text) returns boolean
language plpgsql immutable set search_path = '' as $$
declare s int := 0; i int;
begin
  if p !~ '^[0-9]{9}$' or p = '000000000' then return false; end if;
  for i in 1 .. 8 loop s := s + substr(p, i, 1)::int * (1 << (9 - i)); end loop;
  return (s % 11) % 10 = substr(p, 9, 1)::int;
end $$;
-- normalised tax id: upper case, no spaces / dots / dashes; a Greek one loses an EL / GR prefix
create or replace function erp.tax_id_norm(p text, p_country text) returns text
language sql immutable set search_path = '' as $$
  select case when p_country = 'GR' then regexp_replace(x, '^(EL|GR)(?=[0-9]{9}$)', '') else x end
    from (select nullif(upper(regexp_replace(coalesce(p, ''), '[[:space:].-]', '', 'g')), '') x) y
$$;

create or replace function erp.counterparty_json(c erp.counterparties) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('counterparty_id', c.counterparty_id, 'code', c.code, 'kind', c.kind, 'name', c.name, 'tax_id', c.tax_id, 'tax_office', c.tax_office,
                            'country', c.country, 'street', c.street, 'city', c.city, 'postal_code', c.postal_code, 'email', c.email, 'phone', c.phone,
                            'payment_terms_days', c.payment_terms_days, 'notes', c.notes, 'active', c.active, 'ext_source', c.ext_source, 'ext_ref', c.ext_ref,
                            'ext_synced_at', c.ext_synced_at, 'version', c.version, 'updated_at', c.updated_at)
$$;

-- validation + write of one counterparty (counterparty_save and the CSV import, T08). Keys: counterparty_id, version,
-- code, kind, name, tax_id, tax_office, country, street, city, postal_code, email, phone, payment_terms_days, notes,
-- active, ext_ref (own reference; ext_source becomes 'manual', or p_source). Returns {counterparty_id, problems, row}.
create or replace function erp.counterparty_upsert(p_tenant uuid, p_cp jsonb, p_write boolean, p_source text default 'manual') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare old erp.counterparties; c erp.counterparties; id uuid; probs jsonb; k text; v jsonb := '{}'; t text; v_tax text; v_country text; v_terms int; v_old_json jsonb;
begin
  if p_cp is null or jsonb_typeof(p_cp) <> 'object' then p_cp := '{}'; end if;
  probs := erp.unknown_keys(p_cp, array['counterparty_id', 'version', 'code', 'kind', 'name', 'tax_id', 'tax_office', 'country', 'street', 'city', 'postal_code',
                                        'email', 'phone', 'payment_terms_days', 'notes', 'active', 'ext_ref']);
  if erp.jset(p_cp, 'counterparty_id') then
    id := erp.try_uuid(p_cp ->> 'counterparty_id');
    perform erp.require_own(p_tenant, 'counterparty', id);
    select * into old from erp.counterparties where tenant_id = p_tenant and counterparty_id = id for update;
    if erp.jset(p_cp, 'version') and (p_cp ->> 'version') is distinct from old.version::text then
      perform erp.err('ERP_CONFLICT', format('Counterparty %s was changed by someone else (version %s, yours %s).', old.name, old.version, p_cp ->> 'version'));
    end if;
  end if;
  -- text fields: given key replaces (empty = null), absent key keeps the old value
  foreach k in array array['code', 'kind', 'name', 'tax_office', 'street', 'city', 'postal_code', 'email', 'phone', 'notes', 'ext_ref'] loop
    t := case when p_cp ? k then nullif(btrim(p_cp ->> k), '') else to_jsonb(old) ->> k end;
    v := v || jsonb_build_object(k, t);
  end loop;
  v_country := upper(coalesce(nullif(btrim(p_cp ->> 'country'), ''), old.country, 'GR'));
  v_tax := case when p_cp ? 'tax_id' then erp.tax_id_norm(p_cp ->> 'tax_id', v_country) else old.tax_id end;
  if v ->> 'code' is not null and (v ->> 'code') !~ '^[A-Za-z0-9][A-Za-z0-9_./-]{0,29}$' then probs := probs || erp.problem('invalid', 'code', 'Code: letters, digits, . / - _, up to 30.');
  elsif v ->> 'code' is not null and exists (select 1 from erp.counterparties x where x.tenant_id = p_tenant and lower(x.code) = lower(v ->> 'code') and x.counterparty_id is distinct from id) then
    probs := probs || erp.problem('duplicate', 'code', format('Code %s is already used.', v ->> 'code')); end if;
  if coalesce(v ->> 'kind', 'supplier') not in ('customer', 'supplier', 'both') then probs := probs || erp.problem('invalid', 'kind', 'Kind: customer, supplier or both.'); end if;
  if v ->> 'name' is null then probs := probs || erp.problem('required', 'name', 'Name is required.');
  elsif length(v ->> 'name') > 200 then probs := probs || erp.problem('invalid', 'name', 'Name: at most 200 characters.'); end if;
  if v_country !~ '^[A-Z]{2}$' then probs := probs || erp.problem('invalid', 'country', 'Country: two letters (ISO), e.g. GR.'); end if;
  if v_tax is not null then
    if v_country = 'GR' and not erp.afm_ok(v_tax) then probs := probs || erp.problem('checksum', 'tax_id', format('%s is not a valid Greek tax ID (AFM).', v_tax));
    elsif v_tax !~ '^[A-Z0-9]{2,20}$' then probs := probs || erp.problem('invalid', 'tax_id', 'Tax ID: 2-20 letters or digits.');
    elsif exists (select 1 from erp.counterparties x where x.tenant_id = p_tenant and x.country = v_country and x.tax_id = v_tax and x.counterparty_id is distinct from id) then
      probs := probs || erp.problem('duplicate', 'tax_id', format('Tax ID %s belongs to another counterparty.', v_tax)); end if;
  end if;
  if v ->> 'email' is not null and lower(v ->> 'email') !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then probs := probs || erp.problem('invalid', 'email', 'Not a valid email address.'); end if;
  if length(v ->> 'tax_office') > 80 then probs := probs || erp.problem('invalid', 'tax_office', 'Tax office: at most 80 characters.'); end if;
  if length(v ->> 'city') > 80 then probs := probs || erp.problem('invalid', 'city', 'City: at most 80 characters.'); end if;
  if length(v ->> 'phone') > 40 then probs := probs || erp.problem('invalid', 'phone', 'Phone: at most 40 characters.'); end if;
  if length(v ->> 'street') > 200 or length(v ->> 'notes') > 2000 or length(v ->> 'postal_code') > 20 then probs := probs || erp.problem('invalid', 'street', 'Address or notes too long.'); end if;
  if p_cp ? 'payment_terms_days' then
    if nullif(p_cp ->> 'payment_terms_days', '') is null then v_terms := null;
    elsif (p_cp ->> 'payment_terms_days') !~ '^[0-9]{1,3}$' or (p_cp ->> 'payment_terms_days')::int > 365 then
      probs := probs || erp.problem('invalid', 'payment_terms_days', 'Payment terms: 0-365 days.');
    else v_terms := (p_cp ->> 'payment_terms_days')::int; end if;
  else v_terms := old.payment_terms_days; end if;
  if p_cp ? 'ext_ref' and old.ext_source = 'crm' then
    probs := probs || erp.problem('not_editable', 'ext_ref', 'The CRM link of this customer is kept by the integration.');
  elsif length(v ->> 'ext_ref') > 100 then probs := probs || erp.problem('invalid', 'ext_ref', 'External reference: at most 100 characters.');
  elsif v ->> 'ext_ref' is not null and exists (select 1 from erp.counterparties x where x.tenant_id = p_tenant and x.ext_ref = v ->> 'ext_ref'
                                                  and x.ext_source = coalesce(old.ext_source, p_source) and x.counterparty_id is distinct from id) then
    probs := probs || erp.problem('duplicate', 'ext_ref', 'This external reference is already used.'); end if;
  if coalesce((p_cp ->> 'active')::boolean, old.active, true) = false and coalesce(old.active, true) and not erp.can('counterparty.archive') then
    perform erp.err('ERP_FORBIDDEN', 'Your role or branch does not allow counterparty.archive.');
  end if;
  if jsonb_array_length(probs) > 0 or not p_write then
    return jsonb_build_object('counterparty_id', id, 'problems', probs, 'row', null);
  end if;
  if id is null then
    insert into erp.counterparties (tenant_id, code, kind, name, tax_id, tax_office, country, street, city, postal_code, email, phone, payment_terms_days, notes,
                                    active, ext_source, ext_ref)
    values (p_tenant, v ->> 'code', coalesce(v ->> 'kind', 'supplier'), v ->> 'name', v_tax, v ->> 'tax_office', v_country, v ->> 'street', v ->> 'city',
            v ->> 'postal_code', lower(v ->> 'email'), v ->> 'phone', v_terms, v ->> 'notes', coalesce((p_cp ->> 'active')::boolean, true),
            case when v ->> 'ext_ref' is not null then p_source end, v ->> 'ext_ref')
    returning * into c;
    perform erp.audit(p_tenant, 'counterparty.create', 'counterparties', c.counterparty_id::text, null, erp.counterparty_json(c));
  else
    v_old_json := erp.counterparty_json(old);
    update erp.counterparties set code = v ->> 'code', kind = coalesce(v ->> 'kind', 'supplier'), name = v ->> 'name', tax_id = v_tax, tax_office = v ->> 'tax_office',
           country = v_country, street = v ->> 'street', city = v ->> 'city', postal_code = v ->> 'postal_code', email = lower(v ->> 'email'), phone = v ->> 'phone',
           payment_terms_days = v_terms, notes = v ->> 'notes', active = coalesce((p_cp ->> 'active')::boolean, old.active),
           ext_ref = v ->> 'ext_ref', ext_source = case when v ->> 'ext_ref' is null then null else coalesce(old.ext_source, p_source) end,
           version = version + 1, updated_at = now()
     where tenant_id = p_tenant and counterparty_id = id returning * into c;
    perform erp.audit(p_tenant, 'counterparty.update', 'counterparties', c.counterparty_id::text, v_old_json - 'updated_at' - 'version', erp.counterparty_json(c) - 'updated_at' - 'version');
  end if;
  return jsonb_build_object('counterparty_id', c.counterparty_id, 'problems', '[]'::jsonb, 'row', erp.counterparty_json(c));
end $$;

-- counterparty_list: filter q (name contains, code prefix, or an exact tax ID), kind (customer: customer + both;
-- supplier: supplier + both), active ('true' default | 'false' | 'all'). Ordered by name; next = {name, counterparty_id}.
create or replace function erp_api.counterparty_list(p_filter jsonb default '{}', p_cursor jsonb default null, p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 50), 1), 200); rows jsonb; q text; v_act text; v_kind text;
begin
  m := erp.require_member();
  perform erp.require_cap('counterparty.read');
  p_filter := coalesce(p_filter, '{}');
  q := nullif(lower(btrim(p_filter ->> 'q')), '');
  v_act := coalesce(p_filter ->> 'active', 'true');
  v_kind := p_filter ->> 'kind';
  select jsonb_agg(erp.counterparty_json(c) order by lower(c.name), c.counterparty_id) into rows from (
    select * from erp.counterparties c
     where c.tenant_id = m.tenant_id
       and (v_act = 'all' or c.active = (v_act = 'true'))
       and (v_kind is null or c.kind = v_kind or (c.kind = 'both' and v_kind in ('customer', 'supplier')))
       and (q is null or strpos(lower(c.name), q) > 0 or lower(c.code) like replace(replace(q, '%', '\%'), '_', '\_') || '%'
            or c.tax_id = erp.tax_id_norm(p_filter ->> 'q', c.country))
       and (p_cursor is null or (lower(c.name), c.counterparty_id) > (lower(p_cursor ->> 'name'), erp.try_uuid(p_cursor ->> 'counterparty_id')))
     order by lower(c.name), c.counterparty_id limit lim + 1) c;
  return erp.page_reply(rows, lim, array['name', 'counterparty_id']);
end $$;

create or replace function erp_api.counterparty_get(p_counterparty_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; c erp.counterparties;
begin
  m := erp.require_member();
  perform erp.require_cap('counterparty.read');
  perform erp.require_own(m.tenant_id, 'counterparty', p_counterparty_id);
  select * into c from erp.counterparties where tenant_id = m.tenant_id and counterparty_id = p_counterparty_id;
  return erp.counterparty_json(c);
end $$;

create or replace function erp_api.counterparty_save(p_counterparty jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; r jsonb; res jsonb;
begin
  m := erp.require_member();
  perform erp.require_cap('counterparty.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'counterparty_save', p_counterparty);
  if prev is not null then return prev; end if;
  r := erp.counterparty_upsert(m.tenant_id, p_counterparty, true);
  perform erp.raise_problems(r -> 'problems');
  res := r -> 'row';
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'counterparty_save', p_counterparty, res);
end $$;

-- document types (catalogue rows; the page builds menus and the series screen from them)
create or replace function erp_api.doc_type_list() returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members;
begin
  m := erp.require_member();
  return coalesce((select jsonb_agg(jsonb_build_object('doc_type', d.doc_type, 'name', d.name, 'area', d.area, 'fiscal', d.fiscal, 'gapless_default', d.gapless_default,
                                                       'series_scope', d.series_scope, 'needs_counterparty', d.needs_counterparty, 'enabled', d.enabled,
                                                       'can_read', erp.can('doc.' || d.cap_prefix || '.read'), 'can_create', erp.can('doc.' || d.cap_prefix || '.create'))
                                    order by d.sort, d.doc_type) from erp.doc_types d), '[]'::jsonb);
end $$;

create or replace function erp.series_json(x erp.series) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('series_id', x.series_id, 'branch_id', x.branch_id, 'branch_code', (select b.code from erp.branches b where b.tenant_id = x.tenant_id and b.branch_id = x.branch_id),
                            'doc_type', x.doc_type, 'code', x.code, 'fiscal_year', x.fiscal_year, 'next_no', x.next_no, 'last_no', x.last_no, 'gapless', x.gapless,
                            'numbering', x.numbering, 'is_default', x.is_default, 'active', x.active, 'in_use', x.last_no is not null, 'updated_at', x.updated_at)
$$;

-- series_list: filter branch_id, doc_type, include_inactive. Ordered by doc type, code; next = {doc_type, code, series_id}.
create or replace function erp_api.series_list(p_filter jsonb default '{}', p_cursor jsonb default null, p_limit int default 100) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 100), 1), 500); rows jsonb; br uuid[] := erp.my_branches(); allb boolean := erp.sees_all_branches();
begin
  m := erp.require_member();
  perform erp.require_cap('series.read');
  p_filter := coalesce(p_filter, '{}');
  select jsonb_agg(erp.series_json(x) order by x.doc_type, lower(x.code), x.series_id) into rows from (
    select * from erp.series x
     where x.tenant_id = m.tenant_id
       and (x.branch_id = any (br) or (x.branch_id is null and (allb or cardinality(br) > 0)))
       and (p_filter ->> 'doc_type' is null or x.doc_type = p_filter ->> 'doc_type')
       and (not erp.jset(p_filter, 'branch_id') or x.branch_id = erp.try_uuid(p_filter ->> 'branch_id'))
       and (coalesce((p_filter ->> 'include_inactive')::boolean, false) or x.active)
       and (p_cursor is null or (x.doc_type, lower(x.code), x.series_id) > (p_cursor ->> 'doc_type', lower(p_cursor ->> 'code'), erp.try_uuid(p_cursor ->> 'series_id')))
     order by x.doc_type, lower(x.code), x.series_id limit lim + 1) x;
  return erp.page_reply(rows, lim, array['doc_type', 'code', 'series_id']);
end $$;

-- series_save: owner (series.write). Keys series_id, branch_id (required for branch-scope types, empty for tenant-scope
-- types), doc_type, code, fiscal_year, next_no, gapless (fiscal types always gapless), numbering (local | provider;
-- provider only for fiscal types), is_default (taking the default moves it from the other series), active.
-- After the first number (in_use): doc_type, branch_id, fiscal_year, next_no, gapless, numbering are fixed.
create or replace function erp_api.series_save(p_series jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; old erp.series; x erp.series; id uuid; probs jsonb; res jsonb; dt erp.doc_types; k text;
        v_type text; v_branch uuid; v_code text; v_fy int; v_next bigint; v_gap boolean; v_num text; v_def boolean; v_active boolean;
begin
  m := erp.require_member();
  perform erp.require_cap('series.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'series_save', p_series);
  if prev is not null then return prev; end if;
  if p_series is null or jsonb_typeof(p_series) <> 'object' then p_series := '{}'; end if;
  probs := erp.unknown_keys(p_series, array['series_id', 'branch_id', 'doc_type', 'code', 'fiscal_year', 'next_no', 'gapless', 'numbering', 'is_default', 'active']);
  if erp.jset(p_series, 'series_id') then
    id := erp.try_uuid(p_series ->> 'series_id');
    perform erp.require_own(m.tenant_id, 'series', id);
    select * into old from erp.series where tenant_id = m.tenant_id and series_id = id for update;
    if old.last_no is not null then
      foreach k in array array['doc_type', 'branch_id', 'fiscal_year', 'next_no', 'gapless', 'numbering'] loop
        if p_series ? k and (p_series ->> k) is distinct from (to_jsonb(old) ->> k) then
          probs := probs || erp.problem('in_use', k, format('%s cannot change after the series gave its first number.', k));
        end if;
      end loop;
    end if;
  end if;
  v_type := coalesce(p_series ->> 'doc_type', old.doc_type);
  select * into dt from erp.doc_types d where d.doc_type = v_type;
  if v_type is null then probs := probs || erp.problem('required', 'doc_type', 'Document type is required.');
  elsif dt.doc_type is null then probs := probs || erp.problem('invalid', 'doc_type', format('Unknown document type %s.', v_type)); end if;
  if p_series ? 'branch_id' then
    if erp.jset(p_series, 'branch_id') then v_branch := erp.try_uuid(p_series ->> 'branch_id'); perform erp.require_branch_of_tenant(m.tenant_id, v_branch); end if;
  else v_branch := old.branch_id; end if;
  if dt.series_scope = 'branch' and v_branch is null then probs := probs || erp.problem('required', 'branch_id', format('%s series belong to a branch.', v_type));
  elsif dt.series_scope = 'tenant' and v_branch is not null then probs := probs || erp.problem('invalid', 'branch_id', format('%s series are organisation-wide (no branch).', v_type)); end if;
  v_code := btrim(coalesce(p_series ->> 'code', old.code, ''));
  if v_code = '' then probs := probs || erp.problem('required', 'code', 'Code is required.');
  elsif v_code !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,19}$' then probs := probs || erp.problem('invalid', 'code', 'Code: letters, digits, . - _, up to 20.'); end if;
  if p_series ? 'fiscal_year' then
    if nullif(p_series ->> 'fiscal_year', '') is null then v_fy := null;
    elsif (p_series ->> 'fiscal_year') !~ '^(20|21)[0-9]{2}$' then probs := probs || erp.problem('invalid', 'fiscal_year', 'Year: four digits, 2000-2100.');
    else v_fy := (p_series ->> 'fiscal_year')::int; end if;
  else v_fy := old.fiscal_year; end if;
  if v_code <> '' and exists (select 1 from erp.series s where s.tenant_id = m.tenant_id and s.doc_type = v_type and lower(s.code) = lower(v_code)
                                 and coalesce(s.fiscal_year, 0) = coalesce(v_fy, 0) and s.series_id is distinct from id) then
    probs := probs || erp.problem('duplicate', 'code', format('Series %s already exists for %s.', v_code, v_type)); end if;
  if p_series ? 'next_no' then
    if (p_series ->> 'next_no') !~ '^[0-9]{1,15}$' or (p_series ->> 'next_no')::bigint < 1 then probs := probs || erp.problem('invalid', 'next_no', 'Next number: a whole number from 1.');
    else v_next := (p_series ->> 'next_no')::bigint; end if;
  else v_next := coalesce(old.next_no, 1); end if;
  v_gap := coalesce((p_series ->> 'gapless')::boolean, old.gapless, dt.gapless_default, false);
  if dt.fiscal and not v_gap then probs := probs || erp.problem('invalid', 'gapless', format('%s is a fiscal type: its series is always gapless.', v_type)); end if;
  v_num := coalesce(p_series ->> 'numbering', old.numbering, 'local');
  if v_num not in ('local', 'provider') then probs := probs || erp.problem('invalid', 'numbering', 'Numbering: local or provider.');
  elsif v_num = 'provider' and not coalesce(dt.fiscal, false) then probs := probs || erp.problem('invalid', 'numbering', 'Only fiscal types can be numbered by the provider.'); end if;
  v_def := coalesce((p_series ->> 'is_default')::boolean, old.is_default, true);
  v_active := coalesce((p_series ->> 'active')::boolean, old.active, true);
  perform erp.raise_problems(probs);
  if v_def and v_active then   -- the default moves: the other default of the same (type, branch, year) stops being default
    update erp.series s set is_default = false, updated_at = now()
     where s.tenant_id = m.tenant_id and s.doc_type = v_type and s.branch_id is not distinct from v_branch and s.fiscal_year is not distinct from v_fy
       and s.is_default and s.active and s.series_id is distinct from id;
  end if;
  if id is null then
    insert into erp.series (tenant_id, branch_id, doc_type, code, fiscal_year, next_no, gapless, numbering, is_default, active)
    values (m.tenant_id, v_branch, v_type, v_code, v_fy, v_next, v_gap, v_num, v_def, v_active) returning * into x;
    perform erp.audit(m.tenant_id, 'series.create', 'series', x.series_id::text, null, erp.series_json(x), x.branch_id);
  else
    update erp.series set branch_id = v_branch, doc_type = v_type, code = v_code, fiscal_year = v_fy, next_no = v_next, gapless = v_gap, numbering = v_num,
           is_default = v_def, active = v_active, updated_at = now()
     where tenant_id = m.tenant_id and series_id = id returning * into x;
    perform erp.audit(m.tenant_id, 'series.update', 'series', x.series_id::text, erp.series_json(old) - 'updated_at', erp.series_json(x) - 'updated_at', x.branch_id);
  end if;
  res := erp.series_json(x);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'series_save', p_series, res);
end $$;

-- series_create_defaults: one default series per ENABLED non-fiscal document type for the branch (code TYPE-BRANCH),
-- and one organisation-wide series for each enabled tenant-scope type (code TYPE), where none exists yet. Fiscal types
-- are left to the owner and the accountant (02: gapless / yearly reset, accountant confirms). Reply {created: [series],
-- skipped: [doc types whose default code is taken by another series of the type]}.
create or replace function erp_api.series_create_defaults(p_branch_id uuid, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; b erp.branches; d erp.doc_types; x erp.series; made jsonb := '[]'; skipped jsonb := '[]'; res jsonb;
begin
  m := erp.require_member();
  perform erp.require_cap('series.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'series_create_defaults', to_jsonb(p_branch_id));
  if prev is not null then return prev; end if;
  perform erp.require_branch_of_tenant(m.tenant_id, p_branch_id);
  select * into b from erp.branches where tenant_id = m.tenant_id and branch_id = p_branch_id;
  for d in select * from erp.doc_types where enabled and not fiscal order by sort loop
    if not exists (select 1 from erp.series s where s.tenant_id = m.tenant_id and s.doc_type = d.doc_type and s.fiscal_year is null and s.is_default and s.active
                      and s.branch_id is not distinct from case when d.series_scope = 'branch' then p_branch_id end) then
      insert into erp.series (tenant_id, branch_id, doc_type, code, gapless)
      values (m.tenant_id, case when d.series_scope = 'branch' then p_branch_id end, d.doc_type,
              case when d.series_scope = 'branch' then left(d.doc_type || '-' || b.code, 20) else d.doc_type end, d.gapless_default)
      on conflict do nothing returning * into x;
      if x.series_id is not null then
        made := made || erp.series_json(x);
        perform erp.audit(m.tenant_id, 'series.create', 'series', x.series_id::text, null, erp.series_json(x), x.branch_id);
        x := null;
      else
        skipped := skipped || to_jsonb(d.doc_type);   -- the code is taken by a non-default / inactive series: the owner decides
      end if;
    end if;
  end loop;
  res := jsonb_build_object('created', made, 'skipped', skipped);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'series_create_defaults', to_jsonb(p_branch_id), res);
end $$;

-- ---------------------------------------------------------------------
-- 5c. CSV import (T08): items and counterparties. The page parses the CSV and sends the rows as JSON objects of text
--     (header names below). Every row is checked with the same rules as item_save / counterparty_save; the import is
--     ALL OR NOTHING: with any problem, or with p_dry_run = true, nothing is written and the reply lists every
--     problem as {row, code, field, message} (row = 1-based data row). At most 2000 rows per call.
-- ---------------------------------------------------------------------
create or replace function erp.import_problems(p_row int, p jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(e || jsonb_build_object('row', p_row)), '[]'::jsonb) from jsonb_array_elements(coalesce(p, '[]'::jsonb)) e
$$;
create or replace function erp.import_bool(p text) returns jsonb
language sql immutable set search_path = '' as $$
  select case when p is null or btrim(p) = '' then null
              when lower(btrim(p)) in ('1', 'true', 'yes', 'y', 'active') then 'true'::jsonb
              when lower(btrim(p)) in ('0', 'false', 'no', 'n', 'inactive') then 'false'::jsonb
              else to_jsonb(p) end
$$;
create or replace function erp.import_check_rows(p_rows jsonb) returns void
language plpgsql immutable set search_path = '' as $$
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    perform erp.raise_problems(jsonb_build_array(erp.problem('required', 'p_rows', 'No rows to import.')));
  end if;
  if jsonb_array_length(p_rows) > 2000 then
    perform erp.raise_problems(jsonb_build_array(erp.problem('too_many', 'p_rows', 'At most 2000 rows per import: split the file.')));
  end if;
end $$;

-- item_import: columns code (required; an existing code is UPDATED, a new one CREATED), name, kind, unit (unit code),
-- category (category code), vat (VAT class code), min_level, reorder_level, sales_price, barcodes ("a;b"), description,
-- active. Empty cells of an existing item keep its value. Reply {dry_run, rows, created, updated, errors}.
create or replace function erp_api.item_import(p_rows jsonb, p_dry_run boolean, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; payload jsonb := jsonb_build_object('rows', p_rows, 'dry_run', p_dry_run); r jsonb; n int := 0; probs jsonb := '[]'; one jsonb;
        item jsonb; k text; v text; ex erp.items; created int := 0; updated int := 0; pass int; res jsonb; seen_codes text[] := '{}'; seen_bc text[] := '{}'; b text;
begin
  m := erp.require_member();
  perform erp.require_cap('item.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'item_import', payload);
  if prev is not null then return prev; end if;
  perform erp.import_check_rows(p_rows);
  for pass in 1 .. 2 loop            -- pass 1 checks every row; pass 2 writes, only when pass 1 found nothing
    exit when pass = 2 and (coalesce(p_dry_run, true) or jsonb_array_length(probs) > 0);
    n := 0;
    for r in select * from jsonb_array_elements(p_rows) loop
      n := n + 1;
      if jsonb_typeof(r) <> 'object' then probs := probs || erp.import_problems(n, jsonb_build_array(erp.problem('invalid', null, 'A row must be an object.'))); continue; end if;
      one := erp.unknown_keys(r, array['code', 'name', 'kind', 'unit', 'category', 'vat', 'min_level', 'reorder_level', 'sales_price', 'barcodes', 'description', 'active']);
      item := '{}';
      select * into ex from erp.items i where i.tenant_id = m.tenant_id and lower(i.code) = lower(btrim(coalesce(r ->> 'code', '')));
      if ex.item_id is not null then item := jsonb_build_object('item_id', ex.item_id); end if;
      if pass = 1 then
        if lower(btrim(coalesce(r ->> 'code', ''))) = any (seen_codes) then one := one || erp.problem('duplicate', 'code', format('Code %s appears twice in the file.', r ->> 'code')); end if;
        seen_codes := seen_codes || lower(btrim(coalesce(r ->> 'code', '')));
      end if;
      foreach k in array array['code', 'name', 'kind', 'min_level', 'reorder_level', 'sales_price', 'description'] loop
        v := nullif(btrim(coalesce(r ->> k, '')), '');
        if v is not null then item := item || jsonb_build_object(k, case when k in ('min_level', 'reorder_level', 'sales_price') then replace(v, ',', '.') else v end); end if;
      end loop;
      if ex.item_id is null and not (item ? 'kind') then item := item || '{"kind": "goods"}'; end if;
      v := nullif(btrim(coalesce(r ->> 'unit', '')), '');
      if v is not null then
        item := item || jsonb_build_object('base_unit_id', (select u.unit_id from erp.units u where u.tenant_id = m.tenant_id and lower(u.code) = lower(v)));
        if item ->> 'base_unit_id' is null then one := one || erp.problem('unknown', 'unit', format('Unit %s does not exist.', v)); item := item - 'base_unit_id'; end if;
      elsif ex.item_id is null then item := item || jsonb_build_object('base_unit_id', null); end if;
      v := nullif(btrim(coalesce(r ->> 'category', '')), '');
      if v is not null then
        item := item || jsonb_build_object('category_id', (select c.category_id from erp.item_categories c where c.tenant_id = m.tenant_id and lower(c.code) = lower(v)));
        if item ->> 'category_id' is null then one := one || erp.problem('unknown', 'category', format('Category %s does not exist.', v)); item := item - 'category_id'; end if;
      end if;
      v := nullif(btrim(coalesce(r ->> 'vat', '')), '');
      if v is not null then
        item := item || jsonb_build_object('vat_class_id', (select x.vat_class_id from erp.vat_classes x where x.tenant_id = m.tenant_id and lower(x.code) = lower(v)));
        if item ->> 'vat_class_id' is null then one := one || erp.problem('unknown', 'vat', format('VAT class %s does not exist.', v)); item := item - 'vat_class_id'; end if;
      end if;
      v := nullif(btrim(coalesce(r ->> 'barcodes', '')), '');
      if v is not null then
        item := item || jsonb_build_object('barcodes', (select coalesce(jsonb_agg(x), '[]'::jsonb) from regexp_split_to_table(v, '[;|\s]+') x where x <> ''));
        if pass = 1 then
          foreach b in array (select coalesce(array_agg(x), '{}') from regexp_split_to_table(v, '[;|\s]+') x where x <> '') loop
            if b = any (seen_bc) then one := one || erp.problem('duplicate', 'barcodes', format('Barcode %s appears twice in the file.', b)); end if;
            seen_bc := seen_bc || b;
          end loop;
        end if;
      end if;
      if erp.import_bool(r ->> 'active') is not null then item := item || jsonb_build_object('active', erp.import_bool(r ->> 'active')); end if;
      if jsonb_typeof(item -> 'active') = 'string' then one := one || erp.problem('invalid', 'active', 'active: yes / no.'); item := item - 'active'; end if;
      if pass = 1 then
        -- the row's own checks + every item_save check (an unknown unit code is reported once, as 'unit')
        one := one || coalesce((select jsonb_agg(e) from jsonb_array_elements((erp.item_upsert(m.tenant_id, item, false)) -> 'problems') e
                                 where not (e ->> 'field' = 'base_unit_id' and exists (select 1 from jsonb_array_elements(one) o where o ->> 'field' = 'unit'))), '[]'::jsonb);
        probs := probs || erp.import_problems(n, one);
        if ex.item_id is null then created := created + 1; else updated := updated + 1; end if;
      else
        perform erp.item_upsert(m.tenant_id, item, true);
      end if;
    end loop;
  end loop;
  if not coalesce(p_dry_run, true) and jsonb_array_length(probs) = 0 then
    perform erp.audit(m.tenant_id, 'item.import', 'items', null, null, jsonb_build_object('rows', n, 'created', created, 'updated', updated));
  end if;
  res := jsonb_build_object('dry_run', coalesce(p_dry_run, true) or jsonb_array_length(probs) > 0, 'rows', jsonb_array_length(p_rows),
                            'created', created, 'updated', updated, 'errors', probs);
  if jsonb_array_length(probs) > 0 then return res; end if;   -- not stored: the corrected file is sent again with the same key... or a new one
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'item_import', payload, res);
end $$;

-- counterparty_import: columns name (required), code, kind, tax_id, tax_office, country, street, city, postal_code,
-- email, phone, payment_terms_days, notes, ext_ref, active. A row whose tax ID (same country) or code exists UPDATES
-- that counterparty, else it is CREATED. ext_ref of a new row: ext_source = 'import'. Reply as item_import.
create or replace function erp_api.counterparty_import(p_rows jsonb, p_dry_run boolean, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; payload jsonb := jsonb_build_object('rows', p_rows, 'dry_run', p_dry_run); r jsonb; n int := 0; probs jsonb := '[]'; one jsonb;
        cp jsonb; k text; v text; ex uuid; v_ctry text; tax text; created int := 0; updated int := 0; pass int; res jsonb; seen text[] := '{}'; key text;
begin
  m := erp.require_member();
  perform erp.require_cap('counterparty.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'counterparty_import', payload);
  if prev is not null then return prev; end if;
  perform erp.import_check_rows(p_rows);
  for pass in 1 .. 2 loop
    exit when pass = 2 and (coalesce(p_dry_run, true) or jsonb_array_length(probs) > 0);
    n := 0;
    for r in select * from jsonb_array_elements(p_rows) loop
      n := n + 1;
      if jsonb_typeof(r) <> 'object' then probs := probs || erp.import_problems(n, jsonb_build_array(erp.problem('invalid', null, 'A row must be an object.'))); continue; end if;
      one := erp.unknown_keys(r, array['name', 'code', 'kind', 'tax_id', 'tax_office', 'country', 'street', 'city', 'postal_code', 'email', 'phone',
                                       'payment_terms_days', 'notes', 'ext_ref', 'active']);
      v_ctry := upper(coalesce(nullif(btrim(r ->> 'country'), ''), 'GR'));
      tax := erp.tax_id_norm(r ->> 'tax_id', v_ctry);
      ex := null;
      if tax is not null then select c.counterparty_id into ex from erp.counterparties c where c.tenant_id = m.tenant_id and c.country = v_ctry and c.tax_id = tax; end if;
      if ex is null and nullif(btrim(r ->> 'code'), '') is not null then
        select c.counterparty_id into ex from erp.counterparties c where c.tenant_id = m.tenant_id and lower(c.code) = lower(btrim(r ->> 'code'));
      end if;
      cp := case when ex is not null then jsonb_build_object('counterparty_id', ex) else '{}'::jsonb end;
      foreach k in array array['name', 'code', 'kind', 'tax_id', 'tax_office', 'country', 'street', 'city', 'postal_code', 'email', 'phone', 'payment_terms_days', 'notes', 'ext_ref'] loop
        v := nullif(btrim(coalesce(r ->> k, '')), '');
        if v is not null then cp := cp || jsonb_build_object(k, v); end if;
      end loop;
      if erp.import_bool(r ->> 'active') is not null then cp := cp || jsonb_build_object('active', erp.import_bool(r ->> 'active')); end if;
      if jsonb_typeof(cp -> 'active') = 'string' then one := one || erp.problem('invalid', 'active', 'active: yes / no.'); cp := cp - 'active'; end if;
      if pass = 1 then
        key := coalesce(v_ctry || ':' || tax, 'code:' || lower(btrim(r ->> 'code')), 'row:' || n);
        if key = any (seen) then one := one || erp.problem('duplicate', case when tax is not null then 'tax_id' else 'code' end, 'This counterparty appears twice in the file.'); end if;
        seen := seen || key;
        one := one || ((erp.counterparty_upsert(m.tenant_id, cp, false, 'import')) -> 'problems');
        probs := probs || erp.import_problems(n, one);
        if ex is null then created := created + 1; else updated := updated + 1; end if;
      else
        perform erp.counterparty_upsert(m.tenant_id, cp, true, 'import');
      end if;
    end loop;
  end loop;
  if not coalesce(p_dry_run, true) and jsonb_array_length(probs) = 0 then
    perform erp.audit(m.tenant_id, 'counterparty.import', 'counterparties', null, null, jsonb_build_object('rows', n, 'created', created, 'updated', updated));
  end if;
  res := jsonb_build_object('dry_run', coalesce(p_dry_run, true) or jsonb_array_length(probs) > 0, 'rows', jsonb_array_length(p_rows),
                            'created', created, 'updated', updated, 'errors', probs);
  if jsonb_array_length(probs) > 0 then return res; end if;
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'counterparty_import', payload, res);
end $$;

-- ---------------------------------------------------------------------
-- 6. RLS + grants
-- ---------------------------------------------------------------------
do $$
declare r text;
begin
  foreach r in array array['units', 'vat_classes', 'item_categories', 'items', 'item_barcodes', 'warehouses', 'counterparties', 'doc_types', 'series'] loop
    execute format('alter table erp.%I enable row level security', r);
    execute format('alter table erp.%I force row level security', r);
  end loop;
end $$;
drop policy if exists units_read on erp.units;
create policy units_read on erp.units for select to authenticated using (tenant_id = any ((select erp.my_tenants())::uuid[]));
drop policy if exists vat_classes_read on erp.vat_classes;
create policy vat_classes_read on erp.vat_classes for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.can('vat.read')));
drop policy if exists item_categories_read on erp.item_categories;
create policy item_categories_read on erp.item_categories for select to authenticated using (tenant_id = any ((select erp.my_tenants())::uuid[]));
drop policy if exists items_read on erp.items;
create policy items_read on erp.items for select to authenticated using (tenant_id = any ((select erp.my_tenants())::uuid[]));
drop policy if exists item_barcodes_read on erp.item_barcodes;
create policy item_barcodes_read on erp.item_barcodes for select to authenticated using (tenant_id = any ((select erp.my_tenants())::uuid[]));
drop policy if exists warehouses_read on erp.warehouses;
create policy warehouses_read on erp.warehouses for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and ((select erp.is_owner()) or branch_id = any ((select erp.my_branches())::uuid[])
         or (branch_id is null and (select erp.sees_all_branches()))));
drop policy if exists counterparties_read on erp.counterparties;
create policy counterparties_read on erp.counterparties for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.can('counterparty.read')));
drop policy if exists doc_types_read on erp.doc_types;
create policy doc_types_read on erp.doc_types for select to authenticated using (true);
drop policy if exists series_read on erp.series;
create policy series_read on erp.series for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.can('series.read'))
         and ((select erp.is_owner()) or branch_id = any ((select erp.my_branches())::uuid[]) or branch_id is null));

do $$ declare r text; begin
  foreach r in array array['public', 'anon', 'service_role'] loop
    if r = 'public' or exists (select 1 from pg_catalog.pg_roles where rolname = r) then
      execute format('revoke all on erp.units, erp.vat_classes, erp.item_categories, erp.items, erp.item_barcodes, erp.warehouses, erp.counterparties, erp.doc_types, erp.series from %s', r);
    end if;
  end loop;
end $$;
revoke insert, update, delete, truncate, references, trigger on erp.units, erp.vat_classes, erp.item_categories, erp.items, erp.item_barcodes,
       erp.warehouses, erp.counterparties, erp.doc_types, erp.series from authenticated;
grant select on erp.units, erp.vat_classes, erp.item_categories, erp.items, erp.item_barcodes, erp.warehouses, erp.counterparties, erp.doc_types, erp.series to authenticated;

select erp.lock_down();
grant execute on function erp_api.unit_list(boolean, jsonb, int), erp_api.unit_save(jsonb, uuid),
                          erp_api.vat_class_list(boolean, jsonb, int), erp_api.vat_class_save(jsonb, uuid),
                          erp_api.category_list(boolean, jsonb, int), erp_api.category_save(jsonb, uuid),
                          erp_api.item_list(jsonb, jsonb, int), erp_api.item_get(uuid), erp_api.item_save(jsonb, uuid),
                          erp_api.warehouse_list(jsonb, jsonb, int), erp_api.warehouse_save(jsonb, uuid),
                          erp_api.counterparty_list(jsonb, jsonb, int), erp_api.counterparty_get(uuid), erp_api.counterparty_save(jsonb, uuid),
                          erp_api.doc_type_list(), erp_api.series_list(jsonb, jsonb, int), erp_api.series_save(jsonb, uuid),
                          erp_api.series_create_defaults(uuid, uuid), erp_api.item_import(jsonb, boolean, uuid),
                          erp_api.counterparty_import(jsonb, boolean, uuid) to authenticated;
