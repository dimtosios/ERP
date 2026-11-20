-- =====================================================================
-- iSmile ERP  -  load generator (T15; 03 section 5 "Load"). SCRATCH DATABASE ONLY (run_erp_load.sh creates it).
-- Deterministic (no random(): every choice is a function of the row numbers). Every document goes through the REAL
-- posting path: drafts are inserted set-based, then posted one by one with erp_api.doc_set_state as the tenant
-- owner (numbering, item locks, negative-stock check with ack, costing, alerts), COMMIT every 250 documents.
--   call load.gen_tenant(code, items, warehouses, documents, lines per document, first_day_offset)
-- Mix per tenant: one OPN per warehouse first (opening stock of ~40 items each), then GRN 30 %, CONS 50 %, ADJ+ 10 %,
-- ADJ- 10 %, dates spread oldest -> newest over the period (no backdating). Members: owner + one warehouse member
-- of the first branch (the measurements run as that member, under RLS).
-- =====================================================================
create schema if not exists load;
create table if not exists load.tenants (code text primary key, tenant_id uuid, owner_sub uuid, wh_sub uuid, items int, warehouses int, documents int, lines int,
                                         started timestamptz, finished timestamptz);

create or replace procedure load.gen_tenant(p_code text, p_items int, p_wh int, p_docs int, p_lines int, p_days int)
language plpgsql as $$
declare t uuid; osub uuid; wsub uuid; n int; rd record; k int := 0; br uuid[]; whs uuid[]; pcs uuid; sup uuid; claims text; nb int;
begin
  select tenant_id into t from erp.tenants where code = p_code;
  if t is not null then raise notice 'tenant % exists, skipped', p_code; return; end if;
  insert into erp.tenants (code, name) values (p_code, 'Load ' || p_code) returning tenant_id into t;
  perform erp.tenant_init(t);
  osub := md5('owner:' || p_code)::uuid; wsub := md5('wh:' || p_code)::uuid;
  nb := greatest(1, least(3, p_wh));
  insert into erp.branches (tenant_id, code, name, establishment_no) select t, 'BR' || g, 'Branch ' || g, g - 1 from generate_series(1, nb) g;
  select array_agg(branch_id order by code) into br from erp.branches where tenant_id = t;
  insert into erp.members (tenant_id, email, role, all_branches, auth_user_id, bound_at) values (t, 'owner@' || p_code || '.load', 'owner', true, osub, now());
  insert into erp.members (tenant_id, email, role, branch_ids, auth_user_id, bound_at) values (t, 'wh@' || p_code || '.load', 'warehouse', array[br[1]], wsub, now());
  insert into erp.warehouses (tenant_id, branch_id, code, name)
  select t, br[1 + (g - 1) % nb], 'W' || lpad(g::text, 3, '0'), 'Warehouse ' || g from generate_series(1, p_wh) g;
  select array_agg(warehouse_id order by code) into whs from erp.warehouses where tenant_id = t and kind = 'normal';
  select unit_id into pcs from erp.units where tenant_id = t and code = 'PCS';
  insert into erp.item_categories (tenant_id, code, name) select t, 'CAT' || g, 'Category ' || g from generate_series(1, 20) g;
  insert into erp.items (tenant_id, code, name, base_unit_id, category_id, min_level, kind)
  select t, 'IT' || lpad(g::text, 6, '0'), (array['Bracket', 'Wire', 'Elastic', 'Aligner', 'Band', 'Tube', 'Glove', 'Mask'])[1 + g % 8] || ' ' || g,
         pcs, (select category_id from erp.item_categories c where c.tenant_id = t and c.code = 'CAT' || (1 + g % 20)), case when g % 10 = 0 then 5 end,
         case when g % 3 = 0 then 'consumable' else 'goods' end
    from generate_series(1, p_items) g;
  insert into erp.item_barcodes (tenant_id, barcode, item_id) select t, 'BC' || substr(code, 3), item_id from erp.items where tenant_id = t;
  insert into erp.counterparties (tenant_id, code, name, kind) values (t, 'SUP1', 'Load supplier', 'supplier') returning counterparty_id into sup;
  insert into erp.series (tenant_id, branch_id, doc_type, code)
  select t, case when dt.series_scope = 'branch' then b.branch_id end, dt.doc_type, dt.doc_type || case when dt.series_scope = 'branch' then '-' || b.code else '' end
    from erp.doc_types dt cross join erp.branches b
   where dt.doc_type in ('OPN', 'GRN', 'ADJ_IN', 'ADJ_OUT', 'CONS') and b.tenant_id = t and (dt.series_scope = 'branch' or b.branch_id = br[1]);
  insert into load.tenants values (p_code, t, osub, wsub, p_items, p_wh, p_docs, p_lines, now(), null);
  -- drafts: one OPN per warehouse (40 lines), then the documents in date order
  insert into erp.documents (tenant_id, doc_type, branch_id, doc_date, warehouse_id, counterparty_id, extra, source, notes)
  select t, 'OPN', w.branch_id, current_date - p_days - 1, w.warehouse_id, null, '{}', 'import', 'load:0:' || w.code
    from erp.warehouses w where w.tenant_id = t and w.kind = 'normal';
  insert into erp.document_lines (tenant_id, document_id, line_no, item_id, qty, unit_id, qty_base, unit_price, net, gross)
  select t, d.document_id, l, i.item_id, 50, pcs, 50, 1 + (l % 17) * 0.5, 50 * (1 + (l % 17) * 0.5), 50 * (1 + (l % 17) * 0.5)
    from (select x.document_id, row_number() over (order by x.notes) wn from erp.documents x where x.tenant_id = t and x.doc_type = 'OPN') d
    cross join generate_series(1, 40) l
    join erp.items i on i.tenant_id = t and i.code = 'IT' || lpad((1 + (l * 97 + d.wn * 409) % p_items)::text, 6, '0');
  insert into erp.documents (tenant_id, doc_type, branch_id, doc_date, warehouse_id, counterparty_id, extra, source, notes)
  select t, ty, (select branch_id from erp.warehouses w where w.warehouse_id = whs[1 + (g * 7) % p_wh]),
         current_date - p_days + (g::bigint * p_days / p_docs)::int, whs[1 + (g * 7) % p_wh], case when ty = 'GRN' then sup end,
         case ty when 'ADJ_IN' then '{"reason": "found"}' when 'ADJ_OUT' then '{"reason": "damaged"}' when 'CONS' then '{"cost_centre": "Surgery"}' else '{}' end::jsonb,
         'import', 'load:' || g
    from (select g, case when g % 10 < 3 then 'GRN' when g % 10 < 8 then 'CONS' when g % 10 = 8 then 'ADJ_IN' else 'ADJ_OUT' end ty from generate_series(1, p_docs) g) x;
  insert into erp.document_lines (tenant_id, document_id, line_no, item_id, qty, unit_id, qty_base, unit_price, net, gross)
  select t, d.document_id, l, i.item_id, q, pcs, q, pr, coalesce(round(q * pr, 2), 0), coalesce(round(q * pr, 2), 0)
    from erp.documents d cross join generate_series(1, p_lines) l
    cross join lateral (select split_part(d.notes, ':', 2)::int g) gg
    cross join lateral (select case when d.doc_type = 'GRN' then 20 + (gg.g + l) % 30 else 1 + (gg.g * 3 + l) % 6 end::numeric q,
                               case when d.doc_type in ('GRN', 'ADJ_IN') then 1 + ((gg.g + l * 13) % 40) * 0.25 end::numeric pr) ql
    join erp.items i on i.tenant_id = t and i.code = 'IT' || lpad((1 + (gg.g * 7919 + l * 104729) % p_items)::text, 6, '0')
   where d.tenant_id = t and d.doc_type <> 'OPN' and d.state = 'draft';
  commit;
  -- post everything in date order as the owner (the real path)
  claims := json_build_object('sub', osub, 'email', 'owner@' || p_code || '.load', 'role', 'authenticated')::text;
  perform set_config('request.jwt.claims', claims, false);
  for rd in select document_id from erp.documents where tenant_id = t and state = 'draft' order by doc_date, (doc_type <> 'OPN'), split_part(notes, ':', 2)::int, document_id loop
    perform erp_api.doc_set_state(rd.document_id, 'posted', '{"ack_warnings": true}', gen_random_uuid());
    k := k + 1;
    if k % 250 = 0 then commit; perform set_config('request.jwt.claims', claims, false); end if;
  end loop;
  update load.tenants set finished = now() where code = p_code;
  commit;
  perform set_config('request.jwt.claims', '', false);
end $$;

