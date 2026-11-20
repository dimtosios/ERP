-- =====================================================================
-- iSmile ERP  -  E210_sales.sql   (Draft 2, "sales lite": NON-FISCAL delivery note + retail receipts + print)
-- Purpose : the sales document types DN (delivery note without invoice), RR (retail receipt, goods) and RS (retail
--           receipt, services) on the generic E130 core: customer counterparty, lines by item with sale price and VAT
--           per line (the core arithmetic of doc_save_draft, as E180: net = qty x price x (1 - discount), VAT per line
--           rounded half up, default VAT class = the item's), number per branch at post from a GAPLESS series,
--           states draft -> posted -> cancelled (cancel = reversing stock moves, approver roles, reason).
--           DN: delivery block extra.delivery {address, carrier, vehicle, reason}, extra.to_be_billed (default true),
--               STOCK OUT through the E140 engine at the official cost (cost rule 'issue', as CONS; the negative-stock
--               warning / ack / block path is unchanged).
--           RR: extra.payment_method (cash / card / bank / other: the money was collected at issue). Stock out only for
--               lines WITHOUT a delivery-note reference; a line that bills a DN line carries extra.dn_line_id (plain
--               link, NOT a conversion: doc_conversions / E135 untouched) and the header ref_document_id = that DN, so
--               the DN cannot be cancelled while the RR lives (E130 ERP_DOC_HAS_CHILDREN). E140 stock_effect /
--               stock_post skip such lines.
--           RS: like RR without stock (service items or description lines).
--           NON-FISCAL v1 (STATE 111-112): every document is an internal document; doc_types.fiscal = false while no
--           provider exists; erp.sales_fiscal_needed (true for all three: myDATA 9.3 / 11.1 / 11.2) is reported by
--           sales_get exactly like trf_fiscal_needed of a TRF (STATE 82); printed / shown with the watermark
--           "NOT A FISCAL DOCUMENT".
--           Print: erp_api.sales_get returns the document + issuer (tenants.name, tenant_settings.issuer / logo_url),
--           branch, customer, VAT breakdown, billing state of a DN, collection data of an RR; the page renders the
--           print view (browser Print -> Save as PDF; no server-side PDF).
-- HOOK     : receipt of collection (RCPT, next task): erp.sales_collection(tenant, document) returns what an RR / RS
--           collected (method, amount, date, branch, customer) for the RCPT that the next task creates on post.
-- Run order: after E190 (needs E130 core, E140 stock engine, E120 master). Standalone: names no CRM object.
--           Safe to re-run.
-- Redefines: nothing. Enables the DN / RR / RS catalogue rows (E120) and sets their posting columns (E130).
-- Tests    : tests/E210_sales_tests.sql, tests/E990 (registry + fixtures)
-- =====================================================================

do $$ begin
  if to_regprocedure('erp.stock_post(uuid,uuid,jsonb)') is null then raise exception 'run E140_stock_engine.sql first'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. The types (03 recipe step 1), transitions, capabilities. Seeded rows change only by these updates.
--    01 C1: DN create W A M O, cancel M O; RR create A C M O, cancel (v1, no RCR yet) M O; RS create A M O, cancel M O.
--    Read: 02 matrix rows "SQ, SO, DN" and "SINV ... RR, RS" (readonly r; warehouse reads DN only).
-- ---------------------------------------------------------------------
update erp.doc_types set enabled = true, fiscal = false, stock_sign = -1, cost_rule = 'issue', needs_warehouse = true, price_kind = 'sale', needs_counterparty = true,
       approval_key = null, header_extra = '{delivery,to_be_billed}', line_extra = '{}', validator = 'doc_sales_validate', seed_version = 2
 where doc_type = 'DN' and seed_version < 2;
update erp.doc_types set enabled = true, fiscal = false, stock_sign = -1, cost_rule = 'issue', needs_warehouse = true, price_kind = 'sale', needs_counterparty = false,
       approval_key = null, header_extra = '{payment_method}', line_extra = '{dn_line_id}', validator = 'doc_sales_validate', seed_version = 2
 where doc_type = 'RR' and seed_version < 2;
update erp.doc_types set enabled = true, fiscal = false, stock_sign = 0, cost_rule = 'none', needs_warehouse = false, price_kind = 'sale', needs_counterparty = false,
       approval_key = null, header_extra = '{payment_method}', line_extra = '{}', validator = 'doc_sales_validate', seed_version = 2
 where doc_type = 'RS' and seed_version < 2;

insert into erp.doc_transitions (doc_type, from_state, to_state, cap, condition, action, label, sort) values
  ('DN', 'draft', 'posted', 'create', null, 'post', 'doc.action.post', 10),
  ('DN', 'posted', 'cancelled', 'approve', null, 'cancel', 'doc.action.cancel', 90),
  ('RR', 'draft', 'posted', 'create', null, 'post', 'doc.action.post', 10),
  ('RR', 'posted', 'cancelled', 'approve', null, 'cancel', 'doc.action.cancel', 90),
  ('RS', 'draft', 'posted', 'create', null, 'post', 'doc.action.post', 10),
  ('RS', 'posted', 'cancelled', 'approve', null, 'cancel', 'doc.action.cancel', 90)
on conflict do nothing;

insert into erp.capabilities (capability, area, note) values
  ('doc.dn.read', 'sales', 'delivery notes'), ('doc.dn.create', 'sales', 'issue delivery notes'), ('doc.dn.approve', 'sales', 'cancel delivery notes'),
  ('doc.rr.read', 'sales', 'retail receipts (goods)'), ('doc.rr.create', 'sales', 'issue retail receipts (goods)'), ('doc.rr.approve', 'sales', 'cancel retail receipts (goods)'),
  ('doc.rs.read', 'sales', 'retail receipts (services)'), ('doc.rs.create', 'sales', 'issue retail receipts (services)'), ('doc.rs.approve', 'sales', 'cancel retail receipts (services)')
on conflict (capability) do nothing;
insert into erp.role_cap_defaults (role, capability)
select r, c from (values
  ('owner', 'doc.dn.read'), ('owner', 'doc.dn.create'), ('owner', 'doc.dn.approve'),
  ('owner', 'doc.rr.read'), ('owner', 'doc.rr.create'), ('owner', 'doc.rr.approve'),
  ('owner', 'doc.rs.read'), ('owner', 'doc.rs.create'), ('owner', 'doc.rs.approve'),
  ('manager', 'doc.dn.read'), ('manager', 'doc.dn.create'), ('manager', 'doc.dn.approve'),
  ('manager', 'doc.rr.read'), ('manager', 'doc.rr.create'), ('manager', 'doc.rr.approve'),
  ('manager', 'doc.rs.read'), ('manager', 'doc.rs.create'), ('manager', 'doc.rs.approve'),
  ('warehouse', 'doc.dn.read'), ('warehouse', 'doc.dn.create'),
  ('accounting', 'doc.dn.read'), ('accounting', 'doc.dn.create'), ('accounting', 'doc.rr.read'), ('accounting', 'doc.rr.create'),
  ('accounting', 'doc.rs.read'), ('accounting', 'doc.rs.create'),
  ('clinic_user', 'doc.rr.read'), ('clinic_user', 'doc.rr.create'),
  ('readonly', 'doc.dn.read'), ('readonly', 'doc.rr.read'), ('readonly', 'doc.rs.read')) v(r, c)
on conflict do nothing;
select erp.role_caps_sync();

-- the RR lines that bill a delivery-note line (validator / billing state); the index starts with tenant_id
create index if not exists document_lines_dn_line_idx on erp.document_lines (tenant_id, (extra ->> 'dn_line_id')) where extra ? 'dn_line_id';

-- ---------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------
-- quantity of a DN line billed by retail-receipt lines of documents that are not cancelled (drafts count, as in 02
-- "remaining quantity"), except p_except (the receipt being validated); p_posted_only = only posted receipts
create or replace function erp.dn_line_billed(p_tenant uuid, p_line uuid, p_except uuid, p_posted_only boolean default false) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(o.qty_base), 0) from erp.document_lines o join erp.documents od on od.tenant_id = o.tenant_id and od.document_id = o.document_id
   where o.tenant_id = p_tenant and (o.extra ->> 'dn_line_id') = p_line::text and o.extra ? 'dn_line_id'
     and od.document_id is distinct from p_except and od.state <> 'cancelled' and (not p_posted_only or od.state = 'posted')
$$;

-- v1 issues every sales document as an INTERNAL, non-fiscal document. Under Greek rules each of them is a myDATA
-- document (DN 9.3, RR 11.1, RS 11.2), so the flag is true for all; the provider task turns it into the fiscal path
-- (submit -> issued) like trf_fiscal_needed of a TRF (STATE 82).
create or replace function erp.sales_fiscal_needed(p_tenant uuid, p_doc uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from erp.documents d where d.tenant_id = p_tenant and d.document_id = p_doc and d.doc_type in ('DN', 'RR', 'RS'))
$$;

-- HOOK for the receipt of collection (RCPT, next task): what a POSTED retail receipt collected at issue. Null for any
-- other document / state. The RCPT task creates its record from this reply on post (and voids it on cancel).
create or replace function erp.sales_collection(p_tenant uuid, p_doc uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('document_id', d.document_id, 'doc_type', d.doc_type, 'doc_no', d.doc_no, 'doc_date', d.doc_date, 'branch_id', d.branch_id,
                            'counterparty_id', d.counterparty_id, 'payment_method', d.extra ->> 'payment_method', 'amount', d.total_gross, 'currency', d.currency)
    from erp.documents d where d.tenant_id = p_tenant and d.document_id = p_doc and d.doc_type in ('RR', 'RS') and d.state = 'posted'
$$;

-- ---------------------------------------------------------------------
-- 3. Validator (called by erp.doc_validate through doc_types.validator): problems, never an exception
-- ---------------------------------------------------------------------
create or replace function erp.doc_sales_validate(p_tenant uuid, p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare d erp.documents; dn erp.documents; probs jsonb := '[]'; ck text; l record; s erp.series; dlv jsonb; k text; dl erp.document_lines; v_dl uuid; left_q numeric;
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc;
  select c.kind into ck from erp.counterparties c where c.tenant_id = p_tenant and c.counterparty_id = d.counterparty_id;
  if ck = 'supplier' then probs := probs || erp.problem('invalid', 'counterparty_id', 'A sales document needs a customer (not a supplier).'); end if;
  -- gapless numbering (02: every fiscal type; these are fiscal documents issued internally in v1)
  select * into s from erp.series x
   where x.tenant_id = p_tenant
     and case when d.series_id is not null then x.series_id = d.series_id
              else x.doc_type = d.doc_type and x.branch_id = d.branch_id and x.is_default and x.active and (x.fiscal_year is null or x.fiscal_year = extract(year from d.doc_date)) end
   order by x.fiscal_year nulls last limit 1;
  if s.series_id is not null and not s.gapless then
    probs := probs || erp.problem('invalid', 'series_id', format('Series %s is not gapless: sales documents are numbered without gaps.', s.code)); end if;
  if d.doc_type = 'DN' then
    dlv := d.extra -> 'delivery';
    if dlv is null or jsonb_typeof(dlv) <> 'object' then
      probs := probs || erp.problem('required', 'extra.delivery.reason', 'Delivery: the reason of the movement is required.');
    else
      for k in select jsonb_object_keys(dlv) loop
        if k not in ('address', 'carrier', 'vehicle', 'reason') then probs := probs || erp.problem('not_editable', 'extra.delivery.' || k, format('%s is not a delivery field.', k));
        elsif jsonb_typeof(dlv -> k) <> 'string' then probs := probs || erp.problem('invalid', 'extra.delivery.' || k, 'Delivery fields are texts.'); end if;
      end loop;
      if nullif(btrim(dlv ->> 'reason'), '') is null then probs := probs || erp.problem('required', 'extra.delivery.reason', 'Delivery: the reason of the movement is required.');
      elsif (dlv ->> 'reason') not in ('sale', 'sale_on_approval', 'sample', 'repair', 'return', 'other') then
        probs := probs || erp.problem('invalid', 'extra.delivery.reason', 'Reason: sale, sale on approval, sample, repair, return or other.'); end if;
      if length(dlv ->> 'address') > 200 then probs := probs || erp.problem('invalid', 'extra.delivery.address', 'Delivery address: at most 200 characters.'); end if;
      if length(dlv ->> 'carrier') > 80 then probs := probs || erp.problem('invalid', 'extra.delivery.carrier', 'Carrier: at most 80 characters.'); end if;
      if length(dlv ->> 'vehicle') > 20 then probs := probs || erp.problem('invalid', 'extra.delivery.vehicle', 'Vehicle: at most 20 characters.'); end if;
    end if;
    if d.extra ? 'to_be_billed' and jsonb_typeof(d.extra -> 'to_be_billed') <> 'boolean' then
      probs := probs || erp.problem('invalid', 'extra.to_be_billed', 'To be billed must be true or false.'); end if;
  else
    if nullif(d.extra ->> 'payment_method', '') is null then probs := probs || erp.problem('required', 'extra.payment_method', 'Choose how it was paid.');
    elsif (d.extra ->> 'payment_method') not in ('cash', 'card', 'bank', 'other') then
      probs := probs || erp.problem('invalid', 'extra.payment_method', 'Payment method: cash, card, bank or other.'); end if;
  end if;
  -- the referenced delivery note (RR only; a plain link)
  if d.ref_document_id is not null then
    select * into dn from erp.documents where tenant_id = p_tenant and document_id = d.ref_document_id;
    if d.doc_type <> 'RR' or dn.doc_type <> 'DN' then probs := probs || erp.problem('invalid', 'ref_document_id', 'Only a retail receipt (goods) refers to a delivery note.');
    else
      if dn.state <> 'posted' then probs := probs || erp.problem('invalid', 'ref_document_id', format('Delivery note %s is not posted.', coalesce(dn.doc_no, 'draft'))); end if;
      if not coalesce((dn.extra ->> 'to_be_billed')::boolean, true) then
        probs := probs || erp.problem('invalid', 'ref_document_id', format('Delivery note %s is marked not to be billed.', dn.doc_no)); end if;
      if dn.branch_id <> d.branch_id then probs := probs || erp.problem('invalid', 'ref_document_id', 'The delivery note belongs to another branch.'); end if;
      if dn.counterparty_id is distinct from d.counterparty_id then
        probs := probs || erp.problem('invalid', 'counterparty_id', 'The customer must be the delivery note''s customer.'); end if;
    end if;
  end if;
  for l in select x.line_no, x.item_id, x.qty_base, x.unit_price, x.vat_class_id, x.extra, i.kind item_kind, i.code item_code, v.active vat_active, v.code vat_code,
                  count(*) over (partition by x.extra ->> 'dn_line_id') n_same, sum(x.qty_base) over (partition by x.extra ->> 'dn_line_id') q_same
             from erp.document_lines x
             left join erp.items i on i.tenant_id = x.tenant_id and i.item_id = x.item_id
             left join erp.vat_classes v on v.tenant_id = x.tenant_id and v.vat_class_id = x.vat_class_id
            where x.tenant_id = p_tenant and x.document_id = p_doc order by x.line_no loop
    if d.doc_type = 'RS' and l.item_id is not null and l.item_kind <> 'service' then
      probs := probs || erp.problem('invalid', 'item_id', format('%s is not a service: goods go on a retail receipt (goods).', l.item_code), l.line_no); end if;
    if d.doc_type in ('RR', 'RS') and l.unit_price is null then probs := probs || erp.problem('required', 'unit_price', 'The price is required.', l.line_no); end if;
    if l.unit_price is not null and l.vat_class_id is null then probs := probs || erp.problem('required', 'vat_class_id', 'Choose the VAT class.', l.line_no);
    elsif l.vat_class_id is not null and not l.vat_active then probs := probs || erp.problem('inactive', 'vat_class_id', format('VAT class %s is not active.', l.vat_code), l.line_no); end if;
    if l.extra ? 'dn_line_id' then
      v_dl := erp.try_uuid(l.extra ->> 'dn_line_id');
      dl := null;
      if v_dl is not null then select * into dl from erp.document_lines where tenant_id = p_tenant and line_id = v_dl; end if;
      if dl.line_id is null or dl.document_id is distinct from d.ref_document_id then
        probs := probs || erp.problem('invalid', 'extra.dn_line_id', 'The line does not belong to the referenced delivery note.', l.line_no);
      else
        if dl.item_id is distinct from l.item_id then probs := probs || erp.problem('invalid', 'item_id', 'The item must be the delivery note line''s item.', l.line_no); end if;
        if l.n_same > 1 then probs := probs || erp.problem('duplicate', 'extra.dn_line_id', 'The same delivery note line is billed twice on this receipt.', l.line_no); end if;
        left_q := dl.qty_base - erp.dn_line_billed(p_tenant, dl.line_id, p_doc);
        if l.q_same > left_q then   -- every line of this receipt billing the same DN line counts
          probs := probs || erp.problem('exceeds', 'qty', format('At most %s left to bill on the delivery note line.', trim(trailing '.' from trim(trailing '0' from left_q::text))), l.line_no); end if;
      end if;
    end if;
  end loop;
  return probs;
end $$;

-- ---------------------------------------------------------------------
-- 4. sales_get: the document (doc_get shape) + a `sales` block for the drawer and the print view:
--    {fiscal: false, fiscal_needed, watermark, issuer {name, legal_name, tax_id, tax_office, address, phone, email,
--     logo_url}, branch {code, name, address, establishment_no}, warehouse {code, name}, customer {...} | null,
--     vat_breakdown [{vat_class_id, code, rate, net, vat, gross}], DN: billing {to_be_billed, status open | partial |
--     full | not_to_be_billed, receipts [{document_id, doc_type, doc_no, state}], lines [{line_id, qty, billed,
--     in_drafts, remaining}]}, RR: dn {document_id, doc_no} | null, RR / RS: collection {payment_method, amount, rcpt:
--     null (the receipt-of-collection record comes with the next task)}}
-- ---------------------------------------------------------------------
create or replace function erp_api.sales_get(p_document_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; d erp.documents; tn erp.tenants; st erp.tenant_settings; b erp.branches; w erp.warehouses; c erp.counterparties; res jsonb; bill jsonb;
begin
  m := erp.require_member();
  perform erp.doc_visible(m.tenant_id, p_document_id);
  select * into d from erp.documents where tenant_id = m.tenant_id and document_id = p_document_id;
  if d.doc_type not in ('DN', 'RR', 'RS') then
    perform erp.raise_problems(jsonb_build_array(erp.problem('invalid', 'p_document_id', format('%s is not a sales document.', d.doc_type))));
  end if;
  select * into tn from erp.tenants where tenant_id = m.tenant_id;
  select * into st from erp.tenant_settings where tenant_id = m.tenant_id;
  select * into b from erp.branches where tenant_id = m.tenant_id and branch_id = d.branch_id;
  select * into w from erp.warehouses where tenant_id = m.tenant_id and warehouse_id = d.warehouse_id;
  select * into c from erp.counterparties where tenant_id = m.tenant_id and counterparty_id = d.counterparty_id;
  res := jsonb_build_object(
    'fiscal', false, 'fiscal_needed', erp.sales_fiscal_needed(m.tenant_id, d.document_id), 'watermark', 'NOT A FISCAL DOCUMENT',
    'issuer', jsonb_build_object('name', tn.name, 'logo_url', st.logo_url) || coalesce(st.issuer, '{}'::jsonb),
    'branch', jsonb_build_object('code', b.code, 'name', b.name, 'address', b.address, 'establishment_no', b.establishment_no),
    'warehouse', case when w.warehouse_id is not null then jsonb_build_object('code', w.code, 'name', w.name) end,
    'customer', case when c.counterparty_id is not null then jsonb_build_object('name', c.name, 'code', c.code, 'tax_id', c.tax_id, 'tax_office', c.tax_office, 'country', c.country,
                       'street', c.street, 'city', c.city, 'postal_code', c.postal_code, 'phone', c.phone, 'email', c.email) end,
    'vat_breakdown', coalesce((select jsonb_agg(jsonb_build_object('vat_class_id', g.vat_class_id, 'code', g.code, 'rate', g.rate, 'net', g.net, 'vat', g.vat, 'gross', g.gross)
                                                order by g.rate desc nulls last, g.code)
                                 from (select l.vat_class_id, v.code, v.rate, sum(l.net) net, sum(l.vat) vat, sum(l.gross) gross
                                         from erp.document_lines l left join erp.vat_classes v on v.tenant_id = l.tenant_id and v.vat_class_id = l.vat_class_id
                                        where l.tenant_id = m.tenant_id and l.document_id = d.document_id group by l.vat_class_id, v.code, v.rate) g), '[]'::jsonb));
  if d.doc_type = 'DN' then
    select jsonb_build_object(
             'to_be_billed', coalesce((d.extra ->> 'to_be_billed')::boolean, true),
             'status', case when not coalesce((d.extra ->> 'to_be_billed')::boolean, true) then 'not_to_be_billed'
                            when coalesce(sum(x.billed), 0) = 0 then 'open' when bool_and(x.billed >= x.qty) then 'full' else 'partial' end,
             'lines', coalesce(jsonb_agg(jsonb_build_object('line_id', x.line_id, 'qty', x.qty, 'billed', x.billed, 'in_drafts', x.all_b - x.billed, 'remaining', x.qty - x.all_b)
                                         order by x.line_no), '[]'::jsonb)) into bill
      from (select l.line_id, l.line_no, l.qty_base qty, erp.dn_line_billed(m.tenant_id, l.line_id, null, true) billed, erp.dn_line_billed(m.tenant_id, l.line_id, null) all_b
              from erp.document_lines l where l.tenant_id = m.tenant_id and l.document_id = d.document_id) x;
    bill := bill || jsonb_build_object('receipts', coalesce((select jsonb_agg(jsonb_build_object('document_id', r.document_id, 'doc_type', r.doc_type, 'doc_no', r.doc_no, 'state', r.state)
                                                                               order by r.doc_date, r.document_id)
                                                               from erp.documents r where r.tenant_id = m.tenant_id and r.ref_document_id = d.document_id and r.doc_type = 'RR'), '[]'::jsonb));
    res := res || jsonb_build_object('billing', bill);
  else
    res := res || jsonb_build_object('collection', jsonb_build_object('payment_method', d.extra ->> 'payment_method', 'amount', d.total_gross, 'rcpt', null));
    if d.doc_type = 'RR' then
      res := res || jsonb_build_object('dn', (select jsonb_build_object('document_id', x.document_id, 'doc_no', x.doc_no) from erp.documents x
                                               where x.tenant_id = m.tenant_id and x.document_id = d.ref_document_id));
    end if;
  end if;
  return erp.doc_json(m.tenant_id, d.document_id) || jsonb_build_object('sales', res);
end $$;

-- ---------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------
select erp.lock_down();
grant execute on function erp_api.sales_get(uuid) to authenticated;
