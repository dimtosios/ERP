-- =====================================================================
-- iSmile ERP  -  tests for E180_expenses.sql (T19 / T20 "Expenses lite"): expense categories (defaults, tree, save,
-- roles, tenant), the EXP document (line VAT arithmetic, default VAT of the category, validation, state machine,
-- approval limit thresholds.exp_value: submit / approve / reject, roles of 01 C1 "EXP" and branches, cancel with a
-- reason, lock date, idempotency: key and client_key, number per branch, copy), report_expenses (by category /
-- supplier, filters, cancelled out, branch scope) and the view rpt_erp_expenses, tenant isolation.
-- One transaction, ROLLED BACK. Last line: ALL TESTS PASSED + number of checks.
-- =====================================================================
begin;
\ir _helpers.sql

create table t.ids (a uuid, b uuid);
insert into t.ids select t.tenant('xa'), t.tenant('xb');
create function t.a() returns uuid language sql security definer as $$ select a from t.ids $$;
create function t.b() returns uuid language sql security definer as $$ select b from t.ids $$;
select t.init(t.a()), t.init(t.b());
select t.branch(t.a(), 'A1', 0), t.branch(t.a(), 'A2', 1), t.branch(t.b(), 'B1', 0);
select t.member(t.a(), 1, 'owner'), t.member(t.a(), 2, 'manager', array[t.br(t.a(), 'A1')]), t.member(t.a(), 3, 'warehouse', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 4, 'accounting', '{}', true), t.member(t.a(), 5, 'clinic_user', array[t.br(t.a(), 'A1')]), t.member(t.a(), 6, 'readonly', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 8, 'manager', array[t.br(t.a(), 'A2')]), t.member(t.b(), 11, 'owner');
insert into erp.counterparties (tenant_id, name, kind) values (t.a(), 'Power Co', 'supplier'), (t.a(), 'Phone Co', 'both'), (t.a(), 'A customer', 'customer'),
  (t.b(), 'B supplier', 'supplier');
insert into erp.items (tenant_id, code, name, base_unit_id) values (t.a(), 'IT1', 'Item one', (select unit_id from erp.units where tenant_id = t.a() and code = 'PCS'));
create function t.cp(p_name text) returns uuid language sql security definer as $$ select counterparty_id from erp.counterparties where name = p_name $$;
create function t.cat(p_code text) returns uuid language sql security definer as $$ select category_id from erp.expense_categories where tenant_id = t.a() and code = p_code $$;
create function t.bcat(p_code text) returns uuid language sql security definer as $$ select category_id from erp.expense_categories where tenant_id = t.b() and code = p_code $$;
create function t.bvat() returns uuid language sql security definer as $$ select vat_class_id from erp.vat_classes where tenant_id = t.b() limit 1 $$;
create function t.vat(p_code text) returns uuid language sql security definer as $$ select vat_class_id from erp.vat_classes where tenant_id = t.a() and code = p_code $$;
create function t.today() returns date language sql security definer as $$ select erp.today(t.a()) $$;
create function t.doc(p_id text) returns erp.documents language sql security definer as $$ select d from erp.documents d where document_id = p_id::uuid $$;
create function t.codes(p jsonb) returns text language sql immutable as $$ select string_agg(coalesce(e ->> 'line_no', '-') || ':' || (e ->> 'code') || ':' || coalesce(e ->> 'field', '-'), ','
  order by e ->> 'line_no' nulls first, e ->> 'field', e ->> 'code') from jsonb_array_elements(p) e $$;
create function t.acts(p jsonb) returns text language sql immutable as $$ select coalesce(string_agg(a ->> 'to_state', ',' order by a ->> 'to_state'), '') from jsonb_array_elements(p -> 'actions') a $$;
create table t.v (k text primary key, id text);
create function t.put(p_k text, p_id text) returns void language sql security definer as $$ insert into t.v values (p_k, p_id) on conflict (k) do update set id = excluded.id $$;
create function t.id(p_k text) returns text language sql security definer as $$ select id from t.v where k = p_k $$;
create function t.l(p_cat text, p_net numeric, p_vat text default null, p_desc text default null) returns jsonb language sql security definer as $$
  select jsonb_strip_nulls(jsonb_build_object('expense_category_id', t.cat(p_cat), 'qty', 1, 'unit_price', p_net, 'vat_class_id', t.vat(p_vat), 'description', p_desc)) $$;
create function t.exp(p_branch text, p_lines jsonb, p_more jsonb default '{}') returns jsonb language sql as $$
  select erp_api.doc_save_draft('EXP', jsonb_build_object('branch_id', t.br(t.a(), p_branch), 'lines', p_lines) || p_more, gen_random_uuid()) $$;
create function t.go(p_id text, p_to text, p_opts jsonb default '{}') returns jsonb language sql as $$
  select erp_api.doc_set_state(p_id::uuid, p_to, p_opts, gen_random_uuid()) $$;
grant execute on all functions in schema t to authenticated;
grant select, insert, update on t.v to authenticated;

-- ---------- catalogue ----------
select t.ok((select enabled and stock_sign = 0 and price_kind = 'cost' and not needs_counterparty and approval_key = 'exp_value' and series_scope = 'branch' and not fiscal
               from erp.doc_types where doc_type = 'EXP'), 'EXP enabled: no stock, prices, supplier optional, limit key exp_value, numbered per branch, not fiscal');
select t.ok((select string_agg(from_state || '>' || to_state || ':' || cap || ':' || coalesce(condition, '-'), ',' order by from_state, to_state, cap) from erp.doc_transitions where doc_type = 'EXP')
            = 'draft>pending_approval:create:over_threshold,draft>posted:approve:-,draft>posted:create:under_threshold,pending_approval>draft:approve:-,pending_approval>posted:approve:-,posted>cancelled:create:-',
            'EXP transitions are data (post under the limit, submit / approve / reject above it, cancel)');
select t.ok((select string_agg(role || ':' || capability, ',' order by role, capability) from erp.role_caps where tenant_id = t.a() and allowed
               and (capability like 'doc.exp.%' or capability like 'expense.%'))
            = 'accounting:doc.exp.create,accounting:doc.exp.read,accounting:expense.category.write,manager:doc.exp.approve,manager:doc.exp.create,manager:doc.exp.read,manager:expense.category.write,'
              'owner:doc.exp.approve,owner:doc.exp.create,owner:doc.exp.read,owner:expense.category.write,readonly:doc.exp.read,warehouse:doc.exp.read',
            'capabilities (01 C1 EXP: create A M O, approve M O, void A M O; read like PINV in 02): clinic_user has none');

-- ---------- categories ----------
select t.ok((select count(*) from erp.expense_categories where tenant_id = t.a()) = 10 and (select count(*) from erp.expense_categories where tenant_id = t.b()) = 10,
            'every tenant gets the 10 default expense categories');
select t.ok((select v.code from erp.expense_categories c join erp.vat_classes v using (tenant_id) where c.tenant_id = t.a() and c.code = 'RENT' and v.vat_class_id = c.default_vat_class_id) = 'VAT0'
            and (select v.code from erp.expense_categories c join erp.vat_classes v using (tenant_id) where c.tenant_id = t.a() and c.code = 'UTIL' and v.vat_class_id = c.default_vat_class_id) = 'VAT24',
            'default VAT classes of the defaults (RENT 0 %, UTIL 24 %)');
select erp.expense_init(t.a());
select t.ok((select count(*) from erp.expense_categories where tenant_id = t.a()) = 10, 'expense_init is re-run safe');
set local role authenticated;
select t.as(1);
select t.keep(erp_api.expense_category_save(jsonb_build_object('code', 'CLEAN', 'name', 'Cleaning', 'default_vat_class_id', t.vat('VAT24')), gen_random_uuid()));
select t.ok(t.j() ->> 'code' = 'CLEAN' and t.j() ->> 'vat_code' = 'VAT24' and (t.j() ->> 'vat_rate')::numeric = 24 and (t.j() ->> 'active')::boolean, 'owner creates a category with a default VAT class');
select t.keep(erp_api.expense_category_save(jsonb_build_object('code', 'CLEAN.W', 'name', 'Window cleaning', 'parent_id', t.cat('CLEAN')), gen_random_uuid()));
select t.ok(t.j() ->> 'path' = 'CLEAN / CLEAN.W' and t.j() ->> 'default_vat_class_id' is null, 'sub-category: path, no default VAT');
select t.ok(t.codes(t.problems($$select erp_api.expense_category_save('{"code": "clean", "name": " ", "zzz": 1}', gen_random_uuid())$$))
            = '-:duplicate:code,-:required:name,-:not_editable:zzz', 'save: duplicate code (case-insensitive), name required, unknown key: all at once');
select t.fails($$select erp_api.expense_category_save(jsonb_build_object('category_id', t.cat('CLEAN'), 'parent_id', t.cat('CLEAN.W')), gen_random_uuid())$$,
               'ERP_VALIDATION', 'no cycle in the tree');
select t.ok(t.codes(t.problems($$select erp_api.expense_category_save(jsonb_build_object('category_id', t.cat('CLEAN'), 'active', false), gen_random_uuid())$$)) = '-:in_use:active',
            'deactivation refused while an active sub-category exists');
select t.fails($$select erp_api.expense_category_save(jsonb_build_object('code', 'X1', 'name', 'x', 'parent_id', t.bcat('RENT')), gen_random_uuid())$$, 'ERP_TENANT', 'parent of another tenant: ERP_TENANT');
select t.fails($$select erp_api.expense_category_save(jsonb_build_object('category_id', t.bcat('RENT'), 'name', 'hijack'), gen_random_uuid())$$, 'ERP_TENANT', 'category of another tenant: ERP_TENANT');
select t.fails($$select erp_api.expense_category_save(jsonb_build_object('code', 'X2', 'name', 'x', 'default_vat_class_id', t.bvat()), gen_random_uuid())$$,
               'ERP_TENANT', 'VAT class of another tenant: ERP_TENANT');
select t.put('k1', gen_random_uuid()::text);
select t.keep(erp_api.expense_category_save('{"code": "IDEM", "name": "Idem"}', t.id('k1')::uuid));
select t.ok((erp_api.expense_category_save('{"code": "IDEM", "name": "Idem"}', t.id('k1')::uuid)) = t.j()
            and (select count(*) from erp.expense_categories where tenant_id = t.a() and code = 'IDEM') = 1, 'idempotency: the same key returns the same reply, one row');
select t.as(4);
select t.ok((erp_api.expense_category_save(jsonb_build_object('category_id', t.cat('IDEM'), 'active', false), gen_random_uuid())) ->> 'active' = 'false', 'accounting deactivates a category');
select t.ok(jsonb_array_length(erp_api.expense_category_list() -> 'rows') = 12 and jsonb_array_length(erp_api.expense_category_list(true) -> 'rows') = 13,
            'list: 12 active, 13 with the inactive one');
select t.ok((select string_agg(r ->> 'code', ',') from jsonb_array_elements(erp_api.expense_category_list(true, null, 5) -> 'rows') r) = 'BANK,CLEAN,CLEAN.W,FEES,IDEM'
            and (erp_api.expense_category_list(true, null, 5)) #>> '{next,code}' = 'IDEM'
            and (select string_agg(r ->> 'code', ',') from jsonb_array_elements(erp_api.expense_category_list(true, '{"code": "IDEM", "category_id": "ffffffff-ffff-4fff-bfff-ffffffffffff"}', 3) -> 'rows') r) = 'MAINT,MKT,OFFICE',
            'list: ordered by code, keyset pages');
select t.as(3);
select t.fails($$select erp_api.expense_category_save('{"code": "W1", "name": "x"}', gen_random_uuid())$$, 'ERP_FORBIDDEN', 'warehouse cannot change categories');
select t.ok(jsonb_array_length(erp_api.expense_category_list() -> 'rows') = 12, 'warehouse reads categories (doc.exp.read)');
select t.as(6);
select t.fails($$select erp_api.expense_category_save('{"code": "R1", "name": "x"}', gen_random_uuid())$$, 'ERP_FORBIDDEN', 'readonly cannot change categories');
select t.as(5);
select t.fails($$select erp_api.expense_category_list()$$, 'ERP_FORBIDDEN', 'clinic_user does not read expense categories');
select t.ok((select count(*) from erp.expense_categories) = 0, 'RLS: clinic_user reads no expense category row');
select t.as(11);
select t.ok(not exists (select 1 from jsonb_array_elements(erp_api.expense_category_list(true) -> 'rows') r where (r ->> 'category_id')::uuid in (select category_id from erp.expense_categories where tenant_id = t.a()))
            and (select count(*) from erp.expense_categories) = 10, 'tenant B lists / reads only its own categories');

-- ---------- EXP draft: arithmetic and defaults ----------
select t.as(1);
select erp_api.series_create_defaults(t.br(t.a(), 'A1'), gen_random_uuid()), erp_api.series_create_defaults(t.br(t.a(), 'A2'), gen_random_uuid());
select t.ok((select string_agg(code, ',' order by code) from erp.series where tenant_id = t.a() and doc_type = 'EXP') = 'EXP-A1,EXP-A2', 'series defaults: one EXP series per branch');
select t.as(4);
select t.keep(t.exp('A1', jsonb_build_array(t.l('UTIL', 100), t.l('TEL', 10.05, 'VAT13', 'Mobile'), t.l('OFFICE', 2.75, 'VAT6'), t.l('RENT', 500)),
                    jsonb_build_object('counterparty_id', t.cp('Power Co'), 'ext_number', 'INV-77', 'ext_date', t.today() - 1, 'extra', '{"mark": "400001234567", "paid": true, "payment_method": "card", "cost_centre": "Front desk"}'::jsonb)));
select t.put('e1', t.j() ->> 'document_id');
select t.ok((select string_agg(l ->> 'net' || '/' || (l ->> 'vat') || '/' || (l ->> 'gross'), ',' order by (l ->> 'line_no')::int) from jsonb_array_elements(t.j() -> 'lines') l)
            = '100.00/24.00/124.00,10.05/1.31/11.36,2.75/0.17/2.92,500.00/0.00/500.00',
            'line VAT: category default (UTIL 24 %, RENT 0 %) or the chosen class; rounded per line, half up (1.3065 -> 1.31, 0.165 -> 0.17)');
select t.ok(t.j() ->> 'total_net' = '612.80' and t.j() ->> 'total_vat' = '25.48' and t.j() ->> 'total_gross' = '638.28', 'totals = sums of the rounded lines');
select t.ok((t.j() #>> '{lines,0,expense_category_id}')::uuid = t.cat('UTIL') and t.j() #>> '{lines,1,description}' = 'Mobile', 'lines return their expense category');
select t.ok(jsonb_array_length(t.j() -> 'problems') = 0 and t.j() #>> '{extra,payment_method}' = 'card' and t.j() ->> 'state' = 'draft' and t.j() ->> 'doc_no' is null,
            'a complete draft has no problems and no number yet');
select t.ok(t.acts(t.j()) = 'posted', 'accounting, no limit set: Post');
-- validation (save = problems, post = blocking)
select t.keep(t.exp('A1', jsonb_build_array(jsonb_build_object('qty', 1, 'unit_price', 5, 'description', 'no category'),
                                              jsonb_build_object('item_id', (select item_id from erp.items where code = 'IT1'), 'qty', 1, 'unit_price', 5, 'expense_category_id', t.cat('IDEM')),
                                              jsonb_build_object('expense_category_id', t.cat('CLEAN.W'), 'qty', 1)),
                    jsonb_build_object('counterparty_id', t.cp('A customer'), 'ext_date', t.today() + 1, 'extra', '{"mark": "M-1", "paid": true}'::jsonb)));
select t.put('bad', t.j() ->> 'document_id');
select t.ok(t.codes(t.j() -> 'problems') = '-:invalid:counterparty_id,-:invalid:ext_date,-:invalid:extra.mark,-:required:extra.payment_method,'
                                          '1:required:expense_category_id,1:required:vat_class_id,2:inactive:expense_category_id,2:invalid:item_id,2:required:vat_class_id,'
                                          '3:required:unit_price,3:required:vat_class_id',
            'problems: customer, supplier date after, MARK, paid without method; per line: no category, no VAT class, item line, inactive category, no amount');
select t.fails($$select t.go(t.id('bad'), 'posted')$$, 'ERP_VALIDATION', 'a draft with problems does not post');
select t.ok(t.codes((t.exp('A1', jsonb_build_array(t.l('UTIL', 1)), '{"extra": {"paid": "yes"}}')) -> 'problems') = '-:invalid:extra.paid'
            and t.codes((t.exp('A1', jsonb_build_array(t.l('UTIL', 1)), '{"extra": {"paid": false, "payment_method": "cash"}}')) -> 'problems') = '-:invalid:extra.payment_method'
            and t.codes((t.exp('A1', jsonb_build_array(t.l('UTIL', 1)), '{"extra": {"paid": true, "payment_method": "cheque"}}')) -> 'problems') = '-:invalid:extra.payment_method',
            'paid must be a boolean; a method only when paid, and one of cash / card / bank / other');
select t.fails($$select t.exp('A1', '[]', '{"extra": {"bogus": 1}}')$$, 'ERP_VALIDATION', 'unknown header extra key refused');
select t.fails($$select t.exp('A1', jsonb_build_array(jsonb_build_object('expense_category_id', t.bcat('RENT'), 'qty', 1, 'unit_price', 1)))$$, 'ERP_TENANT', 'a category of another tenant on a line: ERP_TENANT');
select t.fails($$select t.exp('A1', '[]', jsonb_build_object('counterparty_id', t.cp('B supplier')))$$, 'ERP_TENANT', 'a supplier of another tenant: ERP_TENANT');
select t.ok(t.codes((t.exp('A1', jsonb_build_array(jsonb_build_object('expense_category_id', t.cat('UTIL'), 'qty', 1, 'unit_price', 1, 'vat_class_id', null)))) -> 'problems') = '1:required:vat_class_id',
            'an explicit null VAT class is kept (no default): required at post');

-- ---------- post, number per branch, roles ----------
select t.keep(t.go(t.id('e1'), 'posted'));
select t.ok(t.j() #>> '{document,state}' = 'posted' and t.j() #>> '{document,doc_no}' = 'EXP-A1/000001' and (t.j() ->> 'posted')::boolean, 'accounting posts: EXP-A1/000001');
select t.ok(t.count($$select 1 from erp.documents d join erp.members m on m.member_id = d.posted_by where d.document_id = '$$ || t.id('e1') || $$' and m.email = 'user4@erp.test'$$) = 1
            and t.count($$select 1 from erp.stock_moves where document_id = '$$ || t.id('e1') || $$'$$) = 0, 'posted by accounting; no stock move');
select t.ok(t.count($$select 1 from erp.audit_log where action = 'doc.posted' and row_id = '$$ || t.id('e1') || $$'$$) = 1, 'the post is audited');
select t.ok(t.acts(t.j() -> 'document') = 'cancelled', 'posted: Cancel for accounting (01: void A M O)');
select t.fails($$select erp_api.doc_save_draft('EXP', jsonb_build_object('document_id', t.id('e1'), 'version', (t.doc(t.id('e1'))).version, 'notes', 'x'), gen_random_uuid())$$,
               'ERP_DOC_IMMUTABLE', 'a posted expense cannot be edited');
select t.as(8);
select t.keep(t.go((t.exp('A2', jsonb_build_array(t.l('TEL', 20)))) ->> 'document_id', 'posted'));
select t.ok(t.j() #>> '{document,doc_no}' = 'EXP-A2/000001', 'manager of A2 posts in A2: its own branch series EXP-A2/000001');
select t.fails($$select t.exp('A1', jsonb_build_array(t.l('TEL', 20)))$$, 'ERP_FORBIDDEN', 'manager of A2 cannot record an expense in A1');
select t.fails($$select erp_api.doc_get(t.id('e1')::uuid)$$, 'ERP_FORBIDDEN', 'manager of A2 cannot read an A1 expense');
select t.as(3);
select t.ok((erp_api.doc_get(t.id('e1')::uuid)) ->> 'doc_no' = 'EXP-A1/000001' and t.acts(erp_api.doc_get(t.id('e1')::uuid)) = '', 'warehouse reads, no actions');
select t.fails($$select t.exp('A1', jsonb_build_array(t.l('TEL', 20)))$$, 'ERP_FORBIDDEN', 'warehouse cannot record an expense');
select t.as(6);
select t.ok(jsonb_array_length((erp_api.doc_list('{"doc_type": "EXP"}')) -> 'rows') >= 1, 'readonly lists expenses');
select t.fails($$select t.go(t.id('e1'), 'cancelled', '{"reason": "x"}')$$, 'ERP_FORBIDDEN', 'readonly cannot cancel');
select t.as(5);
select t.fails($$select erp_api.doc_list('{"doc_type": "EXP"}')$$, 'ERP_FORBIDDEN', 'clinic_user cannot list expenses');
select t.fails($$select erp_api.doc_get(t.id('e1')::uuid)$$, 'ERP_FORBIDDEN', 'clinic_user cannot read an expense');
select t.ok((select count(*) from erp.documents where doc_type = 'EXP') = 0, 'RLS: clinic_user reads no EXP row');

-- ---------- approval limit (thresholds.exp_value, value = net) ----------
reset role;
update erp.tenant_settings set thresholds = '{"exp_value": 500}' where tenant_id = t.a();
set local role authenticated;
select t.as(4);
select t.keep(t.exp('A1', jsonb_build_array(t.l('FEES', 500))));
select t.ok(t.acts(t.j()) = 'posted', 'net 500 = the limit: accounting posts');
select t.keep(t.exp('A1', jsonb_build_array(t.l('FEES', 400), t.l('MAINT', 100.01))));
select t.put('big', t.j() ->> 'document_id');
select t.ok(t.acts(t.j()) = 'pending_approval', 'net 500.01 > the limit: accounting can only submit');
select t.fails($$select t.go(t.id('big'), 'posted')$$, 'ERP_STATE', 'accounting cannot post above the limit');
select t.keep(t.go(t.id('big'), 'pending_approval'));
select t.ok(t.j() #>> '{document,state}' = 'pending_approval' and t.j() #>> '{document,doc_no}' is null and not (t.j() ->> 'posted')::boolean, 'submitted: pending approval, no number');
select t.fails($$select t.go(t.id('big'), 'posted')$$, 'ERP_FORBIDDEN', 'accounting cannot approve');
select t.fails($$select erp_api.doc_save_draft('EXP', jsonb_build_object('document_id', t.id('big'), 'version', (t.doc(t.id('big'))).version, 'notes', 'x'), gen_random_uuid())$$,
               'ERP_DOC_IMMUTABLE', 'a pending expense cannot be edited');
select t.as(2);
select t.ok(t.acts(erp_api.doc_get(t.id('big')::uuid)) = 'draft,posted', 'manager of A1: approve or reject');
select t.keep(t.go(t.id('big'), 'draft', '{"reason": "wrong supplier"}'));
select t.ok(t.j() #>> '{document,state}' = 'draft'
            and t.count($$select 1 from erp.audit_log where action = 'doc.draft' and row_id = '$$ || t.id('big') || $$' and new_row ->> 'reason' = 'wrong supplier'$$) = 1,
            'reject: back to draft, reason in the audit');
select t.as(4);
select t.go(t.id('big'), 'pending_approval');
select t.as(2);
select t.keep(t.go(t.id('big'), 'posted'));
select t.ok(t.j() #>> '{document,state}' = 'posted' and t.j() #>> '{document,doc_no}' = 'EXP-A1/000002'
            and t.count($$select 1 from erp.documents d join erp.members m on m.member_id = d.approved_by where d.document_id = '$$ || t.id('big') || $$' and m.email = 'user2@erp.test'$$) = 1,
            'manager approves: posted EXP-A1/000002, approved_by kept');
select t.as(1);
select t.ok(t.acts(t.exp('A1', jsonb_build_array(t.l('FEES', 9999)))) = 'pending_approval,posted', 'owner posts any value directly (or submits)');
reset role;
update erp.tenant_settings set thresholds = '{}' where tenant_id = t.a();
set local role authenticated;

-- ---------- idempotency ----------
select t.as(4);
select t.put('k2', gen_random_uuid()::text);
select t.keep(erp_api.doc_save_draft('EXP', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'notes', 'idem', 'lines', jsonb_build_array(t.l('BANK', 3))), t.id('k2')::uuid));
select t.ok(t.j() ->> 'document_id'
            = (erp_api.doc_save_draft('EXP', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'notes', 'idem', 'lines', jsonb_build_array(t.l('BANK', 3))), t.id('k2')::uuid)) ->> 'document_id'
            and (select count(*) from erp.documents where notes = 'idem') = 1, 'doc_save_draft: the same key = the same draft');
select t.keep(erp_api.doc_save_draft('EXP', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'client_key', 'bank-feed:2026-11:0001', 'lines', jsonb_build_array(t.l('BANK', 4))), gen_random_uuid()));
select t.put('ck', t.j() ->> 'document_id');
select t.put('k3', gen_random_uuid()::text);
select t.keep(erp_api.doc_set_state(t.id('ck')::uuid, 'posted', '{}', t.id('k3')::uuid));
select t.ok(t.j() #>> '{document,doc_no}' = 'EXP-A1/000003'
            and (erp_api.doc_set_state(t.id('ck')::uuid, 'posted', '{}', t.id('k3')::uuid)) #>> '{document,doc_no}' = 'EXP-A1/000003'
            and (select last_no from erp.series where tenant_id = t.a() and code = 'EXP-A1') = 3, 'doc_set_state: the same key replays the reply, one number taken');
select t.ok((erp_api.doc_save_draft('EXP', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'client_key', 'bank-feed:2026-11:0001', 'lines', jsonb_build_array(t.l('BANK', 99))), gen_random_uuid())) ->> 'doc_no'
            = 'EXP-A1/000003' and (select total_net from erp.documents where document_id = t.id('ck')::uuid) = 4,
            'client_key retry after the post returns the posted expense unchanged (no second document)');

-- ---------- copy keeps categories ----------
select t.keep(erp_api.doc_copy(t.id('e1')::uuid, gen_random_uuid()));
select t.ok(t.j() ->> 'state' = 'draft' and (t.j() #>> '{lines,0,expense_category_id}')::uuid = t.cat('UTIL') and t.j() ->> 'total_gross' = '638.28', 'copy: a draft with the same categories and amounts');
select erp_api.doc_delete_draft((t.j() ->> 'document_id')::uuid, gen_random_uuid());

-- ---------- cancel, lock date ----------
select t.fails($$select t.go(t.id('e1'), 'cancelled', '{}')$$, 'ERP_VALIDATION', 'cancel needs a reason');
reset role;
update erp.tenant_settings set lock_date = t.today() where tenant_id = t.a();
set local role authenticated;
select t.as(4);
select t.fails($$select t.go(t.id('e1'), 'cancelled', '{"reason": "dup"}')$$, 'ERP_LOCKED_PERIOD', 'cancel refused in a locked period');
select t.fails($$select t.go((t.exp('A1', jsonb_build_array(t.l('BANK', 1)))) ->> 'document_id', 'posted')$$, 'ERP_LOCKED_PERIOD', 'post refused in a locked period');
reset role;
update erp.tenant_settings set lock_date = null where tenant_id = t.a();
set local role authenticated;
select t.as(4);
select t.keep(t.go(t.id('e1'), 'cancelled', '{"reason": "duplicate of INV-77"}'));
select t.ok(t.j() #>> '{document,state}' = 'cancelled' and t.j() #>> '{document,doc_no}' = 'EXP-A1/000001' and t.j() #>> '{document,cancel_reason}' = 'duplicate of INV-77'
            and t.acts(t.j() -> 'document') = '', 'cancelled by accounting: number kept, reason stored, no more actions');
select t.fails($$select t.go(t.id('e1'), 'posted')$$, 'ERP_STATE', 'a cancelled expense never posts again');

-- ---------- report ----------
select t.as(1);
select t.go((t.exp('A1', jsonb_build_array(t.l('UTIL', 50), t.l('CLEAN.W', 10, 'VAT24')), jsonb_build_object('counterparty_id', t.cp('Phone Co'), 'extra', '{"paid": true, "payment_method": "cash"}'::jsonb))) ->> 'document_id', 'posted');
select t.go((t.exp('A1', jsonb_build_array(t.l('CLEAN', 20)), jsonb_build_object('doc_date', t.today() - 40))) ->> 'document_id', 'posted');
-- posted A1 in range: big (FEES 400 + MAINT 100.01), ck (BANK 4), Phone Co (UTIL 50 + CLEAN.W 10); A2: TEL 20; e1 cancelled; CLEAN 20 is 40 days back
select t.keep(erp_api.report_expenses(jsonb_build_object('date_from', t.today() - 30, 'date_to', t.today())));
select t.ok(t.j() #>> '{totals,docs}' = '4' and t.j() #>> '{totals,net}' = '584.01' and (t.j() #>> '{totals,vat}')::numeric = round(400 * 0.24, 2) + round(100.01 * 0.24, 2) + 12 + 2.4 + round(20 * 0.24, 2)
            and t.j() #>> '{totals,paid_gross}' = '74.40', 'report totals: posted only (cancelled out), every branch for the owner, paid on the spot apart');
select t.ok((select string_agg(r ->> 'code' || '=' || (r ->> 'net'), ',' order by (r ->> 'gross')::numeric desc) from jsonb_array_elements(t.j() -> 'rows') r)
            = 'FEES=400.00,MAINT=100.01,UTIL=50.00,TEL=20.00,CLEAN.W=10.00,BANK=4.00'
            and (select r ->> 'path' from jsonb_array_elements(t.j() -> 'rows') r where r ->> 'code' = 'CLEAN.W') = 'CLEAN / CLEAN.W', 'by category, gross descending, with the tree path');
select t.keep(erp_api.report_expenses(jsonb_build_object('group_by', 'supplier', 'date_from', t.today() - 30)));
select t.ok((select string_agg(coalesce(r ->> 'name', '(none)') || '=' || (r ->> 'docs') || ':' || (r ->> 'gross'), ',' order by (r ->> 'gross')::numeric desc) from jsonb_array_elements(t.j() -> 'rows') r)
            = '(none)=3:648.81,Phone Co=1:74.40', 'by supplier: an expense without supplier is its own row (key null)');
select t.ok((erp_api.report_expenses(jsonb_build_object('date_from', t.today() - 60, 'category_id', t.cat('CLEAN')))) #>> '{totals,net}' = '30.00',
            'category filter includes the sub-categories (CLEAN 20 + CLEAN.W 10)');
select t.ok((erp_api.report_expenses(jsonb_build_object('date_from', t.today() - 30, 'branch_id', t.br(t.a(), 'A2')))) #>> '{totals,net}' = '20.00'
            and (erp_api.report_expenses(jsonb_build_object('counterparty_id', t.cp('Phone Co'), 'date_from', t.today() - 30))) #>> '{totals,docs}' = '1',
            'branch and supplier filters');
select t.ok((erp_api.report_expenses('{}')) ->> 'date_from' = to_char(date_trunc('month', t.today()), 'YYYY-MM-DD'), 'default range: this month to today');
select t.ok(t.codes(t.problems($$select erp_api.report_expenses('{"group_by": "vat", "date_from": "2026-02-30"}')$$)) = '-:invalid:date_from,-:invalid:group_by',
            'report filter problems');
select t.fails($$select erp_api.report_expenses(jsonb_build_object('branch_id', t.br(t.b(), 'B1')))$$, 'ERP_TENANT', 'report: branch of another tenant');
select t.fails($$select erp_api.report_expenses(jsonb_build_object('category_id', t.bcat('RENT')))$$, 'ERP_TENANT', 'report: category of another tenant');
select t.ok((select count(*) from erp.rpt_erp_expenses where doc_date >= t.today() - 30) = 6 and (select sum(net) from erp.rpt_erp_expenses where doc_date >= t.today() - 30) = 584.01,
            'view rpt_erp_expenses: the posted lines (owner, RLS)');
select t.as(2);
select t.ok((erp_api.report_expenses(jsonb_build_object('date_from', t.today() - 30))) #>> '{totals,net}' = '564.01', 'manager of A1: only A1 in the report');
select t.fails($$select erp_api.report_expenses(jsonb_build_object('branch_id', t.br(t.a(), 'A2')))$$, 'ERP_FORBIDDEN', 'manager of A1 cannot ask for A2');
select t.ok((select count(distinct branch_id) from erp.rpt_erp_expenses) = 1, 'view: manager of A1 reads A1 lines only');
select t.as(5);
select t.fails($$select erp_api.report_expenses()$$, 'ERP_FORBIDDEN', 'clinic_user has no expense report');
select t.ok((select count(*) from erp.rpt_erp_expenses) = 0, 'view: clinic_user reads nothing');
select t.as(11);
select t.ok((erp_api.report_expenses(jsonb_build_object('date_from', t.today() - 60))) #>> '{totals,docs}' = '0' and (select count(*) from erp.rpt_erp_expenses) = 0
            and jsonb_array_length((erp_api.doc_list('{"doc_type": "EXP"}')) -> 'rows') = 0, 'tenant B: no expense of A in report, view or list');
select t.fails($$select erp_api.doc_get(t.id('big')::uuid)$$, 'ERP_TENANT', 'tenant B: an A expense id raises ERP_TENANT');
reset role;

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
