-- =====================================================================
-- iSmile ERP  -  E180_expenses.sql   (tasks T19 + T20 backend, "Expenses lite")
-- Purpose : expense categories (tenant tree, default VAT class, active flag; default set per tenant) and the EXP
--           expense document (01 C1 "EXP", 02 "Expenses"): a normal document of the E130 core whose lines carry an
--           expense category instead of an item (document_lines.expense_category_id, E130) with net / VAT / gross per
--           line, supplier optional, supplier's document number / date (ext_number / ext_date), MARK, cost centre,
--           paid-on-the-spot flag + payment method (stored only), value approval limit thresholds.exp_value, number
--           per branch at post, cancel with a reason. No stock, no AP / PAY effect.
--           Report: view erp.rpt_erp_expenses (posted EXP lines) + RPC report_expenses (by category or supplier).
-- LITE     : NOT here (STATE.md): attachments, recurring templates, open amounts / AP and the PAY stub, allocation
--           to payments (T29), myDATA expense classification (accountant).
-- Run order: after E160 (needs E130 core, E120 master). Standalone: names no CRM object. Safe to re-run.
-- Redefines: nothing. Enables the EXP catalogue row (E120) and sets its posting columns (E130); adds the foreign key of
--            document_lines.expense_category_id (column created by E130). erp.require_own (E120) knows the kind
--            'expense_category'.
-- Tests    : tests/E180_expenses_tests.sql, tests/E990 (registry + fixtures)
-- =====================================================================

do $$ begin
  if to_regprocedure('erp.doc_set_state(uuid,uuid,text,jsonb)') is null then raise exception 'run E130_documents_core.sql first'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Expense categories: a tree per tenant (parent in the same tenant, no cycle, depth <= 8), default VAT class
-- ---------------------------------------------------------------------
create table if not exists erp.expense_categories (
  tenant_id            uuid not null references erp.tenants (tenant_id),
  category_id          uuid not null default gen_random_uuid(),
  parent_id            uuid,
  code                 text not null check (code ~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,19}$'),
  name                 text not null check (btrim(name) <> '' and length(name) <= 120),
  default_vat_class_id uuid,
  active               boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  primary key (tenant_id, category_id),
  foreign key (tenant_id, parent_id) references erp.expense_categories (tenant_id, category_id),
  foreign key (tenant_id, default_vat_class_id) references erp.vat_classes (tenant_id, vat_class_id)
);
create unique index if not exists expense_categories_code_uq on erp.expense_categories (tenant_id, lower(code));
create index if not exists expense_categories_parent_idx on erp.expense_categories (tenant_id, parent_id);
create index if not exists expense_categories_vat_idx on erp.expense_categories (tenant_id, default_vat_class_id);

do $$ begin
  if not exists (select 1 from pg_catalog.pg_constraint where conname = 'document_lines_expense_category_fk') then
    alter table erp.document_lines add constraint document_lines_expense_category_fk
      foreign key (tenant_id, expense_category_id) references erp.expense_categories (tenant_id, category_id);
  end if;
end $$;

create or replace function erp.tg_expense_category_tree() returns trigger
language plpgsql set search_path = '' as $$
declare cur uuid := new.parent_id; depth int := 1;
begin
  while cur is not null loop
    if cur = new.category_id then perform erp.err('ERP_VALIDATION', 'A category cannot be its own parent or ancestor.',
                                                  jsonb_build_array(erp.problem('cycle', 'parent_id', 'A category cannot be its own parent or ancestor.'))); end if;
    depth := depth + 1;
    if depth > 8 then perform erp.err('ERP_VALIDATION', 'Categories nest at most 8 levels.',
                                      jsonb_build_array(erp.problem('too_deep', 'parent_id', 'Categories nest at most 8 levels.'))); end if;
    select c.parent_id into cur from erp.expense_categories c where c.tenant_id = new.tenant_id and c.category_id = cur;
  end loop;
  return new;
end $$;
drop trigger if exists expense_categories_tree on erp.expense_categories;
create trigger expense_categories_tree before insert or update of parent_id on erp.expense_categories
  for each row execute function erp.tg_expense_category_tree();

-- default categories of every tenant (existing ones now, new ones by the tenants trigger). Editable defaults; the VAT
-- class of each is a convenience only (STATE 92: accountant confirms)
create or replace function erp.expense_init(p_tenant uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into erp.expense_categories (tenant_id, code, name, default_vat_class_id)
  select p_tenant, v.code, v.name, (select x.vat_class_id from erp.vat_classes x where x.tenant_id = p_tenant and x.code = v.vat)
    from (values ('RENT', 'Rent', 'VAT0'), ('UTIL', 'Utilities (electricity, water)', 'VAT24'), ('TEL', 'Telephone and internet', 'VAT24'),
                 ('OFFICE', 'Office supplies', 'VAT24'), ('FEES', 'Professional fees (accountant, lawyer)', 'VAT24'),
                 ('MAINT', 'Repairs and maintenance', 'VAT24'), ('MKT', 'Marketing and advertising', 'VAT24'),
                 ('TRAVEL', 'Travel and fuel', 'VAT24'), ('BANK', 'Bank charges', 'VAT0'), ('OTHER', 'Other expenses', 'VAT24')) v(code, name, vat)
  on conflict do nothing;
end $$;
create or replace function erp.tg_tenants_expenses() returns trigger
language plpgsql security definer set search_path = '' as $$
begin perform erp.expense_init(new.tenant_id); return null; end $$;
drop trigger if exists tenants_e180_init on erp.tenants;
-- the name sorts after tenants_e120_init (default VAT classes exist when this trigger runs)
create trigger tenants_e180_init after insert on erp.tenants for each row execute function erp.tg_tenants_expenses();
do $$ begin perform erp.expense_init(tenant_id) from erp.tenants; end $$;

-- ---------------------------------------------------------------------
-- 2. The EXP type (03 recipe step 1), its transitions and capabilities. Seeded rows change only by this update.
--    01 C1 "EXP": create A M O / approve above the tenant limit M O / void A M O; read: 02 "PINV" row (owner, manager,
--    accounting, warehouse r, readonly r; clinic_user -).
-- ---------------------------------------------------------------------
update erp.doc_types set enabled = true, stock_sign = 0, cost_rule = 'none', needs_warehouse = false, price_kind = 'cost', needs_counterparty = false,
       approval_key = 'exp_value', header_extra = '{mark,paid,payment_method,cost_centre}', line_extra = '{}', validator = 'doc_exp_validate', seed_version = 2
 where doc_type = 'EXP' and seed_version < 2;

insert into erp.doc_transitions (doc_type, from_state, to_state, cap, condition, action, label, sort) values
  ('EXP', 'draft', 'posted', 'create', 'under_threshold', 'post', 'doc.action.post', 10),
  ('EXP', 'draft', 'posted', 'approve', null, 'post', 'doc.action.post', 10),
  ('EXP', 'draft', 'pending_approval', 'create', 'over_threshold', 'none', 'doc.action.submit', 20),
  ('EXP', 'pending_approval', 'posted', 'approve', null, 'post', 'doc.action.approve', 30),
  ('EXP', 'pending_approval', 'draft', 'approve', null, 'none', 'doc.action.reject', 40),
  ('EXP', 'posted', 'cancelled', 'create', null, 'cancel', 'doc.action.cancel', 90)
on conflict do nothing;

insert into erp.capabilities (capability, area, note) values
  ('doc.exp.read', 'expenses', 'expense documents, expense report'), ('doc.exp.create', 'expenses', 'record, post up to the limit and cancel expenses'),
  ('doc.exp.approve', 'expenses', 'approve expenses above the limit'), ('expense.category.write', 'expenses', 'create / change / deactivate expense categories')
on conflict (capability) do nothing;
insert into erp.role_cap_defaults (role, capability)
select r, c from (values
  ('owner', 'doc.exp.read'), ('owner', 'doc.exp.create'), ('owner', 'doc.exp.approve'), ('owner', 'expense.category.write'),
  ('manager', 'doc.exp.read'), ('manager', 'doc.exp.create'), ('manager', 'doc.exp.approve'), ('manager', 'expense.category.write'),
  ('accounting', 'doc.exp.read'), ('accounting', 'doc.exp.create'), ('accounting', 'expense.category.write'),
  ('warehouse', 'doc.exp.read'), ('readonly', 'doc.exp.read')) v(r, c)
on conflict do nothing;
select erp.role_caps_sync();

-- ---------------------------------------------------------------------
-- 3. Validator (called by erp.doc_validate through doc_types.validator): problems, never an exception
-- ---------------------------------------------------------------------
create or replace function erp.doc_exp_validate(p_tenant uuid, p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare d erp.documents; probs jsonb := '[]'; ck text; l record; paid boolean;
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc;
  select c.kind into ck from erp.counterparties c where c.tenant_id = p_tenant and c.counterparty_id = d.counterparty_id;
  if ck = 'customer' then probs := probs || erp.problem('invalid', 'counterparty_id', 'An expense needs a supplier (or none).'); end if;
  if d.extra ? 'mark' and (d.extra ->> 'mark') !~ '^[0-9]{1,20}$' then probs := probs || erp.problem('invalid', 'extra.mark', 'MARK: the myDATA number (digits).'); end if;
  if d.ext_date is not null and d.ext_date > d.doc_date then probs := probs || erp.problem('invalid', 'ext_date', 'The supplier''s document date is after the expense date.'); end if;
  if length(d.extra ->> 'cost_centre') > 60 then probs := probs || erp.problem('invalid', 'extra.cost_centre', 'Cost centre: at most 60 characters.'); end if;
  if d.extra ? 'paid' and jsonb_typeof(d.extra -> 'paid') <> 'boolean' then
    probs := probs || erp.problem('invalid', 'extra.paid', 'Paid must be true or false.');
  else
    paid := coalesce((d.extra ->> 'paid')::boolean, false);
    if paid and nullif(d.extra ->> 'payment_method', '') is null then
      probs := probs || erp.problem('required', 'extra.payment_method', 'Choose how it was paid.');
    elsif d.extra ? 'payment_method' and not paid then
      probs := probs || erp.problem('invalid', 'extra.payment_method', 'A payment method is kept only for an expense paid on the spot.');
    elsif d.extra ? 'payment_method' and (d.extra ->> 'payment_method') not in ('cash', 'card', 'bank', 'other') then
      probs := probs || erp.problem('invalid', 'extra.payment_method', 'Payment method: cash, card, bank or other.');
    end if;
  end if;
  for l in select x.line_no, x.item_id, x.unit_price, x.vat_class_id, x.expense_category_id, c.active cat_active, c.code cat_code, v.active vat_active, v.code vat_code
             from erp.document_lines x
             left join erp.expense_categories c on c.tenant_id = x.tenant_id and c.category_id = x.expense_category_id
             left join erp.vat_classes v on v.tenant_id = x.tenant_id and v.vat_class_id = x.vat_class_id
            where x.tenant_id = p_tenant and x.document_id = p_doc order by x.line_no loop
    if l.item_id is not null then probs := probs || erp.problem('invalid', 'item_id', 'An expense line has a category, not an item (stock goes on a goods receipt).', l.line_no); end if;
    if l.expense_category_id is null then probs := probs || erp.problem('required', 'expense_category_id', 'Choose the expense category.', l.line_no);
    elsif not l.cat_active then probs := probs || erp.problem('inactive', 'expense_category_id', format('Category %s is not active.', l.cat_code), l.line_no); end if;
    if l.vat_class_id is null then probs := probs || erp.problem('required', 'vat_class_id', 'Choose the VAT class.', l.line_no);
    elsif not l.vat_active then probs := probs || erp.problem('inactive', 'vat_class_id', format('VAT class %s is not active.', l.vat_code), l.line_no); end if;
    if l.unit_price is null then probs := probs || erp.problem('required', 'unit_price', 'The net amount is required.', l.line_no); end if;
  end loop;
  return probs;
end $$;

-- ---------------------------------------------------------------------
-- 4. Category RPCs
-- ---------------------------------------------------------------------
create or replace function erp.expense_category_json(c erp.expense_categories) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('category_id', c.category_id, 'parent_id', c.parent_id, 'code', c.code, 'name', c.name,
                            'default_vat_class_id', c.default_vat_class_id,
                            'vat_code', (select v.code from erp.vat_classes v where v.tenant_id = c.tenant_id and v.vat_class_id = c.default_vat_class_id),
                            'vat_rate', (select v.rate from erp.vat_classes v where v.tenant_id = c.tenant_id and v.vat_class_id = c.default_vat_class_id),
                            'active', c.active, 'updated_at', c.updated_at,
                            'path', (with recursive up as (
                                       select x.category_id, x.parent_id, x.code, 1 lvl from erp.expense_categories x where x.tenant_id = c.tenant_id and x.category_id = c.category_id
                                       union all
                                       select p.category_id, p.parent_id, p.code, up.lvl + 1 from erp.expense_categories p join up on p.tenant_id = c.tenant_id and p.category_id = up.parent_id
                                        where up.lvl < 9)
                                     select string_agg(code, ' / ' order by lvl desc) from up))
$$;

-- expense_category_list: flat list ordered by code (the page builds the tree from parent_id); next = {code, category_id}
create or replace function erp_api.expense_category_list(p_include_inactive boolean default false, p_cursor jsonb default null, p_limit int default 200) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; lim int := least(greatest(coalesce(p_limit, 200), 1), 500); rows jsonb;
begin
  m := erp.require_member();
  perform erp.require_cap('doc.exp.read');
  select jsonb_agg(erp.expense_category_json(c) order by lower(c.code), c.category_id) into rows from (
    select * from erp.expense_categories c where c.tenant_id = m.tenant_id and (coalesce(p_include_inactive, false) or c.active)
       and (p_cursor is null or (lower(c.code), c.category_id) > (lower(p_cursor ->> 'code'), erp.try_uuid(p_cursor ->> 'category_id')))
     order by lower(c.code), c.category_id limit lim + 1) c;
  return erp.page_reply(rows, lim, array['code', 'category_id']);
end $$;

-- expense_category_save: keys category_id (update), parent_id (null = top level), code, name, default_vat_class_id
-- (null = none), active. Deactivation is refused while an active sub-category exists.
create or replace function erp_api.expense_category_save(p_category jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; old erp.expense_categories; c erp.expense_categories; id uuid; v_parent uuid; v_vat uuid; probs jsonb; res jsonb;
        v_code text; v_name text; v_active boolean;
begin
  m := erp.require_member();
  perform erp.require_cap('expense.category.write');
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'expense_category_save', p_category);
  if prev is not null then return prev; end if;
  if p_category is null or jsonb_typeof(p_category) <> 'object' then p_category := '{}'; end if;
  probs := erp.unknown_keys(p_category, array['category_id', 'parent_id', 'code', 'name', 'default_vat_class_id', 'active']);
  if erp.jset(p_category, 'category_id') then
    id := erp.try_uuid(p_category ->> 'category_id');
    perform erp.require_own(m.tenant_id, 'expense_category', id);
    select * into old from erp.expense_categories where tenant_id = m.tenant_id and category_id = id for update;
  end if;
  if p_category ? 'parent_id' then
    if erp.jset(p_category, 'parent_id') then
      v_parent := erp.try_uuid(p_category ->> 'parent_id');
      perform erp.require_own(m.tenant_id, 'expense_category', v_parent);
    end if;
  else v_parent := old.parent_id; end if;
  if p_category ? 'default_vat_class_id' then
    if erp.jset(p_category, 'default_vat_class_id') then
      v_vat := erp.try_uuid(p_category ->> 'default_vat_class_id');
      perform erp.require_own(m.tenant_id, 'vat', v_vat);
      if not (select v.active from erp.vat_classes v where v.tenant_id = m.tenant_id and v.vat_class_id = v_vat) then
        probs := probs || erp.problem('inactive', 'default_vat_class_id', 'The VAT class is not active.'); end if;
    end if;
  else v_vat := old.default_vat_class_id; end if;
  v_code := btrim(coalesce(p_category ->> 'code', old.code, ''));
  v_name := btrim(coalesce(p_category ->> 'name', old.name, ''));
  if p_category ? 'active' and jsonb_typeof(p_category -> 'active') <> 'boolean' then
    probs := probs || erp.problem('invalid', 'active', 'Active must be true or false.');
  else v_active := coalesce((p_category ->> 'active')::boolean, old.active, true); end if;
  if v_code = '' then probs := probs || erp.problem('required', 'code', 'Code is required.');
  elsif v_code !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,19}$' then probs := probs || erp.problem('invalid', 'code', 'Code: letters, digits, . - _, up to 20.');
  elsif exists (select 1 from erp.expense_categories x where x.tenant_id = m.tenant_id and lower(x.code) = lower(v_code) and x.category_id is distinct from id) then
    probs := probs || erp.problem('duplicate', 'code', format('Category %s already exists.', v_code)); end if;
  if v_name = '' then probs := probs || erp.problem('required', 'name', 'Name is required.');
  elsif length(v_name) > 120 then probs := probs || erp.problem('invalid', 'name', 'Name: at most 120 characters.'); end if;
  if v_parent is not null and v_parent = id then probs := probs || erp.problem('cycle', 'parent_id', 'A category cannot be its own parent.'); end if;
  if v_active is false and coalesce(old.active, true)
     and exists (select 1 from erp.expense_categories x where x.tenant_id = m.tenant_id and x.parent_id = id and x.active) then
    probs := probs || erp.problem('in_use', 'active', 'Active sub-categories exist.'); end if;
  perform erp.raise_problems(probs);
  if id is null then
    insert into erp.expense_categories (tenant_id, parent_id, code, name, default_vat_class_id, active)
    values (m.tenant_id, v_parent, v_code, v_name, v_vat, v_active) returning * into c;
    perform erp.audit(m.tenant_id, 'expense_category.create', 'expense_categories', c.category_id::text, null, erp.expense_category_json(c));
  else
    update erp.expense_categories set parent_id = v_parent, code = v_code, name = v_name, default_vat_class_id = v_vat, active = v_active, updated_at = now()
     where tenant_id = m.tenant_id and category_id = id returning * into c;
    perform erp.audit(m.tenant_id, 'expense_category.update', 'expense_categories', c.category_id::text,
                      erp.expense_category_json(old) - 'updated_at', erp.expense_category_json(c) - 'updated_at');
  end if;
  res := erp.expense_category_json(c);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'expense_category_save', p_category, res);
end $$;

-- ---------------------------------------------------------------------
-- 5. Expense report: posted EXP lines (cancelled ones are out). The view runs with the caller's rights (RLS of every
--    table applies); the RPC is the page's way in.
-- ---------------------------------------------------------------------
create or replace view erp.rpt_erp_expenses with (security_invoker = true) as
  select d.tenant_id, d.branch_id, d.document_id, d.doc_no, d.doc_date, d.counterparty_id, cp.name counterparty_name, d.ext_number,
         l.line_id, l.line_no, l.expense_category_id category_id, ec.code category_code, ec.name category_name, l.description,
         l.vat_class_id, v.code vat_code, v.rate vat_rate, l.net, l.vat, l.gross,
         coalesce(d.extra ->> 'paid', 'false') = 'true' paid, d.extra ->> 'payment_method' payment_method, d.extra ->> 'cost_centre' cost_centre
    from erp.documents d
    join erp.document_lines l on l.tenant_id = d.tenant_id and l.document_id = d.document_id
    left join erp.expense_categories ec on ec.tenant_id = l.tenant_id and ec.category_id = l.expense_category_id
    left join erp.counterparties cp on cp.tenant_id = d.tenant_id and cp.counterparty_id = d.counterparty_id
    left join erp.vat_classes v on v.tenant_id = l.tenant_id and v.vat_class_id = l.vat_class_id
   where d.doc_type = 'EXP' and d.state = 'posted';

-- the posted EXP lines of a report (filters already checked by the RPC)
create or replace function erp.exp_report_lines(p_tenant uuid, p_br uuid[], p_from date, p_to date, p_branch uuid, p_cp uuid, p_cats uuid[])
returns table (document_id uuid, counterparty_id uuid, category_id uuid, net numeric, vat numeric, gross numeric, paid boolean)
language sql stable security definer set search_path = '' as $$
  select d.document_id, d.counterparty_id, l.expense_category_id, l.net, l.vat, l.gross, coalesce(d.extra ->> 'paid', 'false') = 'true'
    from erp.documents d join erp.document_lines l on l.tenant_id = d.tenant_id and l.document_id = d.document_id
   where d.tenant_id = p_tenant and d.doc_type = 'EXP' and d.state = 'posted' and d.branch_id = any (p_br)
     and d.doc_date between p_from and p_to
     and (p_branch is null or d.branch_id = p_branch) and (p_cp is null or d.counterparty_id = p_cp)
     and (p_cats is null or l.expense_category_id = any (p_cats))
$$;

-- report_expenses: p_filter keys group_by ('category' default | 'supplier'), date_from / date_to (yyyy-mm-dd; default
-- the first day of the current month .. today), branch_id, category_id (with its sub-categories), counterparty_id.
-- Visible branches only (doc.exp.read). Reply {group_by, date_from, date_to, rows: [{key_id, code, name, path, docs,
-- lines, net, vat, gross, paid_gross}], totals: {docs, lines, net, vat, gross, paid_gross}, truncated}. Rows ordered by
-- gross desc; at most 1000 (truncated = true when more; the totals are always over everything).
create or replace function erp_api.report_expenses(p_filter jsonb default '{}') returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; br uuid[]; v_branch uuid; v_cat uuid; v_cp uuid; v_from date; v_to date; grp text; rows jsonb; tot jsonb; n int; probs jsonb := '[]'; cats uuid[];
begin
  m := erp.require_member();
  perform erp.require_cap('doc.exp.read');
  p_filter := coalesce(p_filter, '{}');
  if jsonb_typeof(p_filter) <> 'object' then p_filter := '{}'; end if;
  probs := erp.unknown_keys(p_filter, array['group_by', 'date_from', 'date_to', 'branch_id', 'category_id', 'counterparty_id']);
  grp := coalesce(nullif(p_filter ->> 'group_by', ''), 'category');
  if grp not in ('category', 'supplier') then probs := probs || erp.problem('invalid', 'group_by', 'Group by: category or supplier.'); end if;
  if erp.jset(p_filter, 'branch_id') then
    v_branch := erp.try_uuid(p_filter ->> 'branch_id'); perform erp.require_branch_of_tenant(m.tenant_id, v_branch);
    perform erp.require_cap('doc.exp.read', v_branch);
  end if;
  if erp.jset(p_filter, 'category_id') then v_cat := erp.try_uuid(p_filter ->> 'category_id'); perform erp.require_own(m.tenant_id, 'expense_category', v_cat); end if;
  if erp.jset(p_filter, 'counterparty_id') then v_cp := erp.try_uuid(p_filter ->> 'counterparty_id'); perform erp.require_own(m.tenant_id, 'counterparty', v_cp); end if;
  begin
    v_from := coalesce(nullif(p_filter ->> 'date_from', '')::date, date_trunc('month', erp.today(m.tenant_id))::date);
    v_to := coalesce(nullif(p_filter ->> 'date_to', '')::date, erp.today(m.tenant_id));
  exception when others then probs := probs || erp.problem('invalid', 'date_from', 'Dates: yyyy-mm-dd.'); end;
  if v_from > v_to then probs := probs || erp.problem('invalid', 'date_to', 'The end date is before the start date.'); end if;
  perform erp.raise_problems(probs);
  br := erp.my_branches();
  if v_cat is not null then
    with recursive down as (select v_cat id union all select c.category_id from erp.expense_categories c join down on c.tenant_id = m.tenant_id and c.parent_id = down.id)
    select array_agg(id) into cats from down;
  end if;
  select jsonb_build_object('docs', count(distinct x.document_id), 'lines', count(*), 'net', coalesce(sum(x.net), 0), 'vat', coalesce(sum(x.vat), 0),
                            'gross', coalesce(sum(x.gross), 0), 'paid_gross', coalesce(sum(x.gross) filter (where x.paid), 0)) into tot
    from erp.exp_report_lines(m.tenant_id, br, v_from, v_to, v_branch, v_cp, cats) x;
  if grp = 'category' then
    select count(*), jsonb_agg(r order by (r ->> 'gross')::numeric desc, r ->> 'code') filter (where rn <= 1000) into n, rows from (
      select jsonb_build_object('key_id', x.category_id, 'code', c.code, 'name', c.name, 'path', (erp.expense_category_json(c)) ->> 'path', 'docs', x.docs, 'lines', x.lines,
                                'net', x.net, 'vat', x.vat, 'gross', x.gross, 'paid_gross', x.paid_gross) r,
             row_number() over (order by x.gross desc, c.code) rn
        from (select category_id, count(distinct document_id) docs, count(*) lines, sum(net) net, sum(vat) vat, sum(gross) gross,
                     coalesce(sum(gross) filter (where paid), 0) paid_gross from erp.exp_report_lines(m.tenant_id, br, v_from, v_to, v_branch, v_cp, cats) group by category_id) x
        left join erp.expense_categories c on c.tenant_id = m.tenant_id and c.category_id = x.category_id) y;
  else
    select count(*), jsonb_agg(r order by (r ->> 'gross')::numeric desc, r ->> 'name') filter (where rn <= 1000) into n, rows from (
      select jsonb_build_object('key_id', x.counterparty_id, 'code', c.code, 'name', c.name, 'docs', x.docs, 'lines', x.lines,
                                'net', x.net, 'vat', x.vat, 'gross', x.gross, 'paid_gross', x.paid_gross) r,
             row_number() over (order by x.gross desc, c.name) rn
        from (select counterparty_id, count(distinct document_id) docs, count(*) lines, sum(net) net, sum(vat) vat, sum(gross) gross,
                     coalesce(sum(gross) filter (where paid), 0) paid_gross from erp.exp_report_lines(m.tenant_id, br, v_from, v_to, v_branch, v_cp, cats) group by counterparty_id) x
        left join erp.counterparties c on c.tenant_id = m.tenant_id and c.counterparty_id = x.counterparty_id) y;
  end if;
  return jsonb_build_object('group_by', grp, 'date_from', v_from, 'date_to', v_to, 'rows', coalesce(rows, '[]'::jsonb), 'totals', tot, 'truncated', coalesce(n, 0) > 1000);
end $$;

-- ---------------------------------------------------------------------
-- 6. RLS + grants
-- ---------------------------------------------------------------------
alter table erp.expense_categories enable row level security;
alter table erp.expense_categories force row level security;
drop policy if exists expense_categories_read on erp.expense_categories;
create policy expense_categories_read on erp.expense_categories for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.can('doc.exp.read')));
do $$ declare r text; begin
  foreach r in array array['public', 'anon', 'service_role'] loop
    if r = 'public' or exists (select 1 from pg_catalog.pg_roles where rolname = r) then
      execute format('revoke all on erp.expense_categories, erp.rpt_erp_expenses from %s', r);
    end if;
  end loop;
end $$;
revoke insert, update, delete, truncate, references, trigger on erp.expense_categories from authenticated;
grant select on erp.expense_categories, erp.rpt_erp_expenses to authenticated;

select erp.lock_down();
grant execute on function erp_api.expense_category_list(boolean, jsonb, int), erp_api.expense_category_save(jsonb, uuid),
                          erp_api.report_expenses(jsonb) to authenticated;
