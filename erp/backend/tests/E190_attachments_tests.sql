-- =====================================================================
-- iSmile ERP  -  tests for E190_attachments.sql (Draft 1: supplier delivery note -> DRAFT goods receipt): the
-- attachments table (size / type limits, magic bytes, sha256, append-only + soft delete, RLS), attachment_add / list /
-- get / delete (roles, branches, tenant isolation, idempotency), the extraction contract and grn_draft_from_extraction
-- (supplier by tax ID, item by barcode / code / exact name, unmatched and low-confidence lines block posting until
-- fixed, idempotent by client_key, never posted automatically, file linked), last purchase price after the post.
-- One transaction, ROLLED BACK. Last line: ALL TESTS PASSED + number of checks.
-- =====================================================================
begin;
\ir _helpers.sql

create table t.ids (a uuid, b uuid);
insert into t.ids select t.tenant('dna'), t.tenant('dnb');
create function t.a() returns uuid language sql security definer as $$ select a from t.ids $$;
create function t.b() returns uuid language sql security definer as $$ select b from t.ids $$;
select t.init(t.a()), t.init(t.b());
select t.branch(t.a(), 'A1', 0), t.branch(t.a(), 'A2', 1), t.branch(t.b(), 'B1', 0);
select t.member(t.a(), 1, 'owner'), t.member(t.a(), 2, 'manager', array[t.br(t.a(), 'A1')]), t.member(t.a(), 3, 'warehouse', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 4, 'accounting', '{}', true), t.member(t.a(), 5, 'clinic_user', array[t.br(t.a(), 'A1')]), t.member(t.a(), 6, 'readonly', array[t.br(t.a(), 'A1')]),
       t.member(t.a(), 8, 'manager', array[t.br(t.a(), 'A2')]), t.member(t.b(), 11, 'owner');
insert into erp.warehouses (tenant_id, branch_id, code, name) values (t.a(), t.br(t.a(), 'A1'), 'AW1', 'A1 main'), (t.a(), t.br(t.a(), 'A2'), 'AW2', 'A2 main'),
  (t.b(), t.br(t.b(), 'B1'), 'BW1', 'B1 main');
insert into erp.series (tenant_id, branch_id, doc_type, code) values (t.a(), t.br(t.a(), 'A1'), 'GRN', 'GRN-A1'), (t.a(), t.br(t.a(), 'A1'), 'CONS', 'CONS-A1');
insert into erp.counterparties (tenant_id, name, kind, tax_id, country) values (t.a(), 'Ortho Supplies SA', 'supplier', '094014201', 'GR'),
  (t.a(), 'A customer', 'customer', '094019245', 'GR'), (t.b(), 'Ortho Supplies SA (B)', 'supplier', '094014201', 'GR');
create function t.pcs(p_t uuid) returns uuid language sql security definer as $$ select unit_id from erp.units where tenant_id = p_t and code = 'PCS' $$;
insert into erp.items (tenant_id, code, name, base_unit_id, kind, active) values
  (t.a(), 'BRK', 'Bracket MBT 022', t.pcs(t.a()), 'consumable', true), (t.a(), 'WIRE16', 'NiTi wire 0.16', t.pcs(t.a()), 'consumable', true),
  (t.a(), 'ELA', 'Elastic ligatures', t.pcs(t.a()), 'consumable', true), (t.a(), 'OLD1', 'Old item', t.pcs(t.a()), 'consumable', false),
  (t.a(), 'SRV1', 'Sterilisation service', t.pcs(t.a()), 'service', true), (t.a(), 'TW1', 'Twin', t.pcs(t.a()), 'goods', true),
  (t.a(), 'TW2', 'Twin', t.pcs(t.a()), 'goods', true), (t.b(), 'BRK', 'Bracket MBT 022', t.pcs(t.b()), 'consumable', true);
insert into erp.item_barcodes (tenant_id, barcode, item_id) select tenant_id, '4006381333931', item_id from erp.items where code = 'BRK';
create function t.item(p_code text) returns uuid language sql security definer as $$ select item_id from erp.items where tenant_id = t.a() and code = p_code $$;
create function t.wh(p_code text) returns uuid language sql security definer as $$ select warehouse_id from erp.warehouses where code = p_code $$;
create function t.codes(p jsonb) returns text language sql immutable as $$ select coalesce(string_agg(coalesce(e ->> 'line_no', '-') || ':' || (e ->> 'code') || ':' || coalesce(e ->> 'field', '-'), ','
  order by (e ->> 'line_no')::int nulls first, e ->> 'field', e ->> 'code'), '') from jsonb_array_elements(p) e $$;
create table t.v (k text primary key, id text);
create function t.put(p_k text, p_id text) returns void language sql security definer as $$ insert into t.v values (p_k, p_id) on conflict (k) do update set id = excluded.id $$;
create function t.id(p_k text) returns text language sql security definer as $$ select id from t.v where k = p_k $$;
-- file bytes: a PDF / JPEG / PNG header + filler up to p_n bytes; base64 without line breaks
create function t.pdf(p_n int default 300) returns bytea language sql immutable as $$ select '\x255044462d312e340a'::bytea || convert_to(repeat('x', p_n - 9), 'UTF8') $$;
create function t.jpg() returns bytea language sql immutable as $$ select '\xffd8ffe000104a464946'::bytea || convert_to(repeat('j', 50), 'UTF8') $$;
create function t.png() returns bytea language sql immutable as $$ select '\x89504e470d0a1a0a0000000d49484452'::bytea || convert_to(repeat('p', 50), 'UTF8') $$;
create function t.b64(p bytea) returns text language sql immutable as $$ select translate(encode(p, 'base64'), E'\n', '') $$;
create function t.add(p_branch text, p_name text, p_bytes bytea, p_more jsonb default '{}') returns jsonb language sql as $$
  select erp_api.attachment_add(jsonb_build_object('branch_id', t.br(t.a(), p_branch), 'filename', p_name, 'content_base64', t.b64(p_bytes)) || p_more, gen_random_uuid()) $$;
create function t.line(p_desc text, p_code text, p_bc text, p_qty text, p_price text, p_conf numeric) returns jsonb language sql immutable as $$
  select jsonb_strip_nulls(jsonb_build_object('description', p_desc, 'supplier_code', p_code, 'barcode', p_bc, 'qty', p_qty, 'unit', 'PCS', 'unit_price', p_price, 'confidence', p_conf)) $$;
create function t.ext(p_lines jsonb, p_tax text default '094014201', p_more jsonb default '{}') returns jsonb language sql stable as $$
  select jsonb_build_object('schema', 'delivery_note_extraction/1', 'extractor', 'test/1', 'supplier', jsonb_build_object('tax_id', p_tax, 'name', 'Ortho Supplies'),
                            'dn_number', 'DA-1234', 'dn_date', (current_date - 2)::text, 'lines', p_lines, 'warnings', jsonb_build_array('Page 2 was blurred.')) || p_more $$;
create function t.draft(p_ext jsonb, p_att text, p_wh text, p_key text) returns jsonb language sql as $$
  select erp_api.grn_draft_from_extraction(p_ext, p_att::uuid, t.wh(p_wh), p_key) $$;
create function t.go(p_id text, p_to text, p_opts jsonb default '{}') returns jsonb language sql as $$
  select erp_api.doc_set_state(p_id::uuid, p_to, p_opts, gen_random_uuid()) $$;
create function t.att(p_id text) returns erp.attachments language sql security definer as $$ select a from erp.attachments a where attachment_id = p_id::uuid $$;
create function t.doc(p_id text) returns erp.documents language sql security definer as $$ select d from erp.documents d where document_id = p_id::uuid $$;
create function t.ln(p_doc text, p_no int) returns erp.document_lines language sql security definer as $$ select l from erp.document_lines l where document_id = p_doc::uuid and line_no = p_no $$;
grant execute on all functions in schema t to authenticated;
grant select, insert, update on t.v to authenticated;
create table t.k (k uuid);
insert into t.k values (gen_random_uuid());
grant select on t.k to authenticated;
-- the full extraction of the main case: 8 lines, every matching path
create function t.main_ext() returns jsonb language sql stable as $$ select t.ext(jsonb_build_array(
  t.line('Bracket MBT 022 (box)', 'X-1', '4006381333931', '10', '2.50', 0.97),          -- 1 barcode
  t.line('Wire', 'wire16', null, '5', '3,20', 0.91),                                    -- 2 our item code (case-insensitive), comma decimal
  t.line('ELASTIC LIGATURES', null, null, '2', '1.10', 0.85),                           -- 3 exact name
  t.line('Unknown thing', 'ZZZ', '9999999999999', '1', '4', 0.99),                      -- 4 no item
  t.line('Bracket again', null, '4006381333931', '3', '2.50', 0.55),                    -- 5 barcode, low confidence
  t.line('Old item', 'OLD1', null, '1', '1', 0.99),                                     -- 6 inactive item: not matched
  t.line('Sterilisation', 'SRV1', null, '1', '1', 0.99),                                -- 7 service: not matched
  t.line('Twin', null, null, '1', '1', 0.99))) $$;                                      -- 8 two items have the name: not matched

-- ---------- catalogue / structure ----------
select t.ok((select header_extra = '{mark,dn}' and line_extra = '{dn}' and seed_version = 3 from erp.doc_types where doc_type = 'GRN'),
            'GRN catalogue row: header extra mark + dn, line extra dn (seed version 3)');
select t.ok((select relrowsecurity and relforcerowsecurity from pg_catalog.pg_class where oid = 'erp.attachments'::regclass), 'attachments: RLS enabled and forced');
select t.ok((select attstorage = 'e' from pg_catalog.pg_attribute where attrelid = 'erp.attachments'::regclass and attname = 'content'), 'content stored external (no compression attempt)');
select t.ok((select string_agg(a.attname, ',' order by k.n) from pg_catalog.pg_index i, unnest(i.indkey) with ordinality k(attnum, n)
               join pg_catalog.pg_attribute a on a.attrelid = 'erp.attachments'::regclass and a.attnum = k.attnum
              where i.indrelid = 'erp.attachments'::regclass and i.indisprimary) = 'tenant_id,attachment_id', 'primary key (tenant_id, attachment_id)');
select t.ok(erp.attachment_sniff(t.pdf()) = 'application/pdf' and erp.attachment_sniff(t.jpg()) = 'image/jpeg' and erp.attachment_sniff(t.png()) = 'image/png'
            and erp.attachment_sniff(convert_to('hello world', 'UTF8')) is null and erp.attachment_sniff('\x504b0304'::bytea) is null,
            'magic bytes: %PDF-, FF D8 FF, PNG signature; text / zip refused');

-- ---------- attachment_add: limits, types, sha256 ----------
set local role authenticated;
select t.as(3);   -- warehouse of A1
select t.put('f1', (t.add('A1', 'note 1.pdf', t.pdf())) ->> 'attachment_id');
select t.ok((select a.mime = 'application/pdf' and a.size_bytes = 300 and a.sha256 = encode(sha256(t.pdf()), 'hex') and a.document_id is null
               and a.branch_id = t.br(t.a(), 'A1') and a.filename = 'note 1.pdf' and a.deleted_at is null from t.att(t.id('f1')) a),
            'warehouse adds a PDF to its branch: mime from the bytes, size, sha256, not linked');
select t.ok((t.add('A1', 'photo.jpg', t.jpg(), '{"mime": "image/jpg"}')) ->> 'mime' = 'image/jpeg' and (t.add('A1', 'scan.png', t.png())) ->> 'mime' = 'image/png',
            'JPEG (declared image/jpg) and PNG accepted');
select t.ok(t.codes(t.problems($$select t.add('A1', 'notes.txt', convert_to('just some text', 'UTF8'))$$)) = '-:type:content_base64', 'a text file is refused by its content');
select t.ok(t.codes(t.problems($$select t.add('A1', 'fake.pdf', '\x504b030414000000'::bytea)$$)) = '-:type:content_base64', 'a zip renamed .pdf is refused (magic bytes, not the name)');
select t.ok(t.codes(t.problems($$select t.add('A1', 'x.png', t.pdf(), '{"mime": "image/png"}')$$)) = '-:type:mime', 'declared type that disagrees with the bytes is refused');
select t.ok(t.codes(t.problems($$select erp_api.attachment_add(jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'filename', 'e.pdf', 'content_base64', ''), gen_random_uuid())$$))
            = '-:required:content_base64', 'an empty file is refused');
select t.ok(t.codes(t.problems($$select t.add('A1', 'big.pdf', t.pdf(5242881))$$)) = '-:too_large:content_base64', '5 MB + 1 byte is refused');
select t.ok((t.add('A1', 'max.pdf', t.pdf(5242880))) ->> 'size_bytes' = '5242880', 'exactly 5 MB is accepted');
select t.ok(t.codes(t.problems($$select erp_api.attachment_add(jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'filename', 'b.pdf', 'content_base64', repeat('A', 7000000)), gen_random_uuid())$$))
            = '-:too_large:content_base64', 'an oversized base64 text is refused before decoding');
select t.ok(t.codes(t.problems($$select erp_api.attachment_add(jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'filename', 'b.pdf', 'content_base64', '%%%not base64'), gen_random_uuid())$$))
            = '-:invalid:content_base64', 'content that is not base64 is refused');
select t.ok(t.codes(t.problems($$select t.add('A1', '../etc/passwd.pdf', t.pdf())$$)) = '-:invalid:filename'
            and t.codes(t.problems($$select t.add('A1', '  ', t.pdf())$$)) = '-:required:filename', 'file name: required, no path separators');
select t.ok(t.codes(t.problems($$select t.add('A1', 'k.pdf', t.pdf(), '{"colour": "red"}')$$)) = '-:not_editable:colour', 'unknown keys are refused');
select t.ok(t.codes(t.problems($$select erp_api.attachment_add(jsonb_build_object('filename', 'k.pdf', 'content_base64', t.b64(t.pdf())), gen_random_uuid())$$)) = '-:required:branch_id',
            'a file not linked to a document needs a branch');
select t.fails($$select erp_api.attachment_add(jsonb_build_object('branch_id', t.br(t.b(), 'B1'), 'filename', 'k.pdf', 'content_base64', t.b64(t.pdf())), gen_random_uuid())$$,
               'ERP_TENANT', 'a branch of tenant B: ERP_TENANT');
select t.fails($$select t.add('A2', 'k.pdf', t.pdf())$$, 'ERP_FORBIDDEN', 'warehouse of A1 cannot add a file to branch A2');
-- idempotency: same key + same request = same row; same key + other request = mismatch
select t.put('i1', (erp_api.attachment_add(jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'filename', 'idem.pdf', 'content_base64', t.b64(t.pdf(400))), (select k from t.k))) ->> 'attachment_id');
select t.ok((erp_api.attachment_add(jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'filename', 'idem.pdf', 'content_base64', t.b64(t.pdf(400))), (select k from t.k))) ->> 'attachment_id' = t.id('i1')
            and (select count(*) from erp.attachments where filename = 'idem.pdf') = 1, 'a retry with the same key returns the same file, stored once');
select t.fails($$select erp_api.attachment_add(jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'filename', 'idem.pdf', 'content_base64', t.b64(t.pdf(401))), (select k from t.k))$$,
               'ERP_IDEMPOTENT_MISMATCH', 'the same key with other bytes: ERP_IDEMPOTENT_MISMATCH');
reset role;
select t.ok(exists (select 1 from erp.audit_log where tenant_id = t.a() and action = 'attachment.add' and row_id = t.id('f1') and new_row ->> 'sha256' = encode(sha256(t.pdf()), 'hex')),
            'audit: attachment.add with filename / size / sha256');
-- roles (02 GRN row: owner / manager / warehouse create; accounting / readonly read; clinic_user nothing)
set local role authenticated;
select t.as(5); select t.fails($$select t.add('A1', 'c.pdf', t.pdf())$$, 'ERP_FORBIDDEN', 'clinic_user cannot add a file');
select t.as(4); select t.fails($$select t.add('A1', 'c.pdf', t.pdf())$$, 'ERP_FORBIDDEN', 'accounting cannot add a file (read only on GRN)');
select t.as(6); select t.fails($$select t.add('A1', 'c.pdf', t.pdf())$$, 'ERP_FORBIDDEN', 'readonly cannot add a file');
select t.as(8); select t.fails($$select t.add('A1', 'c.pdf', t.pdf())$$, 'ERP_FORBIDDEN', 'manager of A2 cannot add to A1');
select t.put('f2', (t.add('A2', 'a2 note.pdf', t.pdf())) ->> 'attachment_id');
select t.as(2); select t.ok((t.add('A1', 'm.pdf', t.pdf())) ->> 'mime' = 'application/pdf', 'manager of A1 adds a file');
-- only goods receipts take files
select t.put('cons', (erp_api.doc_save_draft('CONS', jsonb_build_object('branch_id', t.br(t.a(), 'A1'), 'warehouse_id', t.wh('AW1'),
  'lines', jsonb_build_array(jsonb_build_object('item_id', t.item('BRK'), 'qty', 1))), gen_random_uuid())) ->> 'document_id');
select t.ok(t.codes(t.problems($$select erp_api.attachment_add(jsonb_build_object('document_id', t.id('cons'), 'filename', 'c.pdf', 'content_base64', t.b64(t.pdf())), gen_random_uuid())$$))
            = '-:invalid:document_id', 'a file cannot be attached to a CONS (goods receipts only in this build)');
reset role;

-- ---------- append-only ----------
select t.fails($$update erp.attachments set filename = 'renamed.pdf' where attachment_id = t.id('f1')::uuid$$, 'ERP_APPEND_ONLY', 'the file name cannot change (even as table owner)');
select t.fails($$update erp.attachments set content = t.pdf(301), size_bytes = 301 where attachment_id = t.id('f1')::uuid$$, 'ERP_APPEND_ONLY', 'the bytes cannot change');
select t.fails($$delete from erp.attachments where attachment_id = t.id('f1')::uuid$$, 'ERP_APPEND_ONLY', 'no hard delete');
select t.fails($$truncate erp.attachments$$, 'ERP_APPEND_ONLY', 'no truncate');
select t.fails($$insert into erp.attachments (tenant_id, branch_id, filename, mime, size_bytes, sha256, content, uploaded_by)
                 select t.a(), t.br(t.a(), 'A1'), 'x.exe', 'application/x-msdownload', 3, repeat('0', 64), '\x4d5a90'::bytea, member_id from erp.members where email = 'user1@erp.test'$$,
               '', 'table check: only the three types');

-- ---------- grn_draft_from_extraction: the main case ----------
set local role authenticated;
select t.as(3);
select t.keep(t.draft(t.main_ext(), t.id('f1'), 'AW1', 'dn:test:0001'));
select t.put('g1', t.j() -> 'document' ->> 'document_id');
select t.ok((select d.doc_type = 'GRN' and d.state = 'draft' and d.number is null and d.doc_no is null and d.posted_at is null and d.warehouse_id = t.wh('AW1')
                    and d.branch_id = t.br(t.a(), 'A1') and d.counterparty_id = (select counterparty_id from erp.counterparties where tenant_id = t.a() and name = 'Ortho Supplies SA')
                    and d.ext_number = 'DA-1234' and d.ext_date = current_date - 2 and d.client_key = 'dn:test:0001' from t.doc(t.id('g1')) d) and (t.j() ->> 'created')::boolean,
            'a DRAFT GRN of the warehouse''s branch: supplier by tax ID, supplier''s number / date, client_key; no number, not posted');
select t.ok((select string_agg(l.line_no || ':' || coalesce(i.code, '-') || ':' || (l.extra -> 'dn' ->> 'status') || ':' || coalesce(l.extra -> 'dn' ->> 'match', '-'), ',' order by l.line_no)
               from erp.document_lines l left join erp.items i on i.tenant_id = l.tenant_id and i.item_id = l.item_id where l.document_id = t.id('g1')::uuid)
            = '1:BRK:matched:barcode,2:WIRE16:matched:code,3:ELA:matched:name,4:-:unmatched:-,5:BRK:low_confidence:barcode,6:-:unmatched:-,7:-:unmatched:-,8:-:unmatched:-',
            'matching: barcode, then our item code, then exact name; inactive / service / ambiguous name stay unmatched; confidence < 0.80 flagged');
select t.ok((select l.qty = 5 and l.unit_price = 3.2 and l.net = 16 and l.description = 'Wire' and l.extra -> 'dn' ->> 'supplier_code' = 'wire16'
                    and (l.extra -> 'dn' ->> 'confidence')::numeric = 0.91 and l.extra -> 'dn' ->> 'unit' = 'PCS' from t.ln(t.id('g1'), 2) l)
            and (select l.item_id is null and l.description = 'Unknown thing' and l.qty = 1 and l.unit_price = 4 from t.ln(t.id('g1'), 4) l),
            'line values: qty, price (comma decimal), net; the extraction kept in line extra.dn; an unmatched line keeps its text');
select t.ok(t.j() -> 'summary' = '{"lines": 8, "matched": 3, "unmatched": 4, "low_confidence": 1, "supplier_matched": true, "problems": 9}'::jsonb,
            'reply summary: 8 lines, 3 matched, 4 not matched, 1 to check, supplier found, 9 problems (unmatched lines give two each)');
select t.ok(t.codes(t.j() -> 'document' -> 'problems') = '4:not_matched:item_id,4:required:item_id,5:check_line:extra.dn,6:not_matched:item_id,6:required:item_id,7:not_matched:item_id,7:required:item_id,8:not_matched:item_id,8:required:item_id',
            'problems on the draft: "item not matched" per unmatched line, "check" for the low-confidence one');
select t.ok((select string_agg(e ->> 'message', '|') from jsonb_array_elements(t.j() -> 'document' -> 'problems') e where e ->> 'line_no' = '4' and e ->> 'code' = 'not_matched')
            = 'Item not matched: "Unknown thing". Choose the item.', 'the problem names the delivery-note text');
select t.ok((select d.extra -> 'dn' ->> 'extractor' = 'test/1' and d.extra -> 'dn' ->> 'attachment_id' = t.id('f1') and d.extra -> 'dn' -> 'warnings' = '["Page 2 was blurred."]'
                    and (d.extra -> 'dn' -> 'supplier' ->> 'matched')::boolean from t.doc(t.id('g1')) d), 'header extra.dn: extractor, file, warnings, supplier matched');
select t.ok((select a.document_id = t.id('g1')::uuid from t.att(t.id('f1')) a) and jsonb_array_length((erp_api.attachment_list(t.id('g1')::uuid)) -> 'rows') = 1
            and (erp_api.attachment_list(t.id('g1')::uuid)) -> 'rows' -> 0 ->> 'filename' = 'note 1.pdf', 'the file is linked to the draft and listed with it');
select t.fails($$select t.go(t.id('g1'), 'posted')$$, 'ERP_VALIDATION', 'posting is blocked while lines are not matched / not checked');
select t.ok((select state = 'draft' and number is null from t.doc(t.id('g1'))), 'still a draft after the refused post');
-- idempotent by client_key: same key, other extraction -> the same draft, unchanged
select t.keep(t.draft(t.ext(jsonb_build_array(t.line('Other', null, null, '99', '1', 1))), t.id('f2'), 'AW1', 'dn:test:0001'));
select t.ok(not (t.j() ->> 'created')::boolean and t.j() -> 'document' ->> 'document_id' = t.id('g1')
            and (select count(*) from erp.documents where client_key = 'dn:test:0001') = 1 and (select count(*) from erp.document_lines where document_id = t.id('g1')::uuid) = 8
            and (select document_id is null from t.att(t.id('f2'))), 'a repeat with the same client_key returns the same draft unchanged (other file not linked)');
-- the user fixes the draft through the normal save: items for the unmatched lines, line 5 checked, lines 6-8 removed
select t.keep(erp_api.doc_save_draft('GRN', jsonb_build_object('document_id', t.id('g1'), 'version', (select version from t.doc(t.id('g1'))),
  'lines', (select jsonb_agg(case l.line_no
                when 4 then jsonb_build_object('item_id', t.item('ELA'), 'qty', l.qty, 'unit_price', l.unit_price, 'description', l.description, 'extra', l.extra)
                when 5 then jsonb_build_object('item_id', l.item_id, 'qty', l.qty, 'unit_price', l.unit_price, 'extra', jsonb_set(l.extra, '{dn,checked}', 'true'))
                else jsonb_build_object('item_id', l.item_id, 'qty', l.qty, 'unit_price', l.unit_price, 'extra', l.extra) end order by l.line_no)
              from erp.document_lines l where l.document_id = t.id('g1')::uuid and l.line_no <= 5)), gen_random_uuid()));
select t.ok(t.codes(t.j() -> 'problems') = '', 'after the fixes the draft has no problem');
select t.ok((select (l.extra -> 'dn' ->> 'checked')::boolean and l.extra -> 'dn' ->> 'status' = 'low_confidence' from t.ln(t.id('g1'), 5) l),
            'the line extra survives the save (checked mark kept)');
select t.ok((t.go(t.id('g1'), 'posted')) ->> 'posted' = 'true' and (select state = 'posted' and doc_no = 'GRN-A1/000001' from t.doc(t.id('g1'))),
            'the user posts: GRN-A1/000001');
reset role;
select t.ok((select last_purchase_price = 2.5 from erp.items where tenant_id = t.a() and code = 'BRK') and (select last_purchase_price = 3.2 from erp.items where tenant_id = t.a() and code = 'WIRE16'),
            'posting sets the last purchase price of the items');
select t.ok(exists (select 1 from erp.audit_log where tenant_id = t.a() and action = 'grn.draft_from_extraction' and row_id = t.id('g1') and (new_row ->> 'unmatched')::int = 4),
            'audit: grn.draft_from_extraction with the counts');
select t.fails($$update erp.document_lines set extra = '{}' where document_id = t.id('g1')::uuid$$, 'ERP_DOC_IMMUTABLE', 'the posted lines (and their delivery-note data) are fixed');

-- ---------- never posted automatically, other paths ----------
set local role authenticated;
select t.as(3);
select t.put('f3', (t.add('A1', 'clean.pdf', t.pdf())) ->> 'attachment_id');
select t.keep(t.draft(t.ext(jsonb_build_array(t.line('Bracket', null, '4006381333931', '4', '2.5', 0.99), t.line('w', 'WIRE16', null, '1', '3', 0.95))), t.id('f3'), 'AW1', 'dn:test:clean'));
select t.ok(t.j() -> 'document' ->> 'state' = 'draft' and t.j() -> 'document' ->> 'number' is null and t.codes(t.j() -> 'document' -> 'problems') = ''
            and t.j() -> 'document' -> 'actions' @> '[{"to_state": "posted"}]', 'every line matched and confident: still a DRAFT (never posted automatically), the user may post');
select t.put('f4', (t.add('A1', 'nosup.pdf', t.pdf())) ->> 'attachment_id');
select t.keep(t.draft(t.ext(jsonb_build_array(t.line('Bracket', null, '4006381333931', 'abc', '-1', 0.99)), '999999999', '{"dn_date": "18/11/2026"}'), t.id('f4'), 'AW1', 'dn:test:nosup'));
select t.ok(t.j() -> 'document' ->> 'counterparty_id' is null and t.j() -> 'document' ->> 'ext_date' is null
            and t.j() -> 'document' -> 'extra' -> 'dn' -> 'warnings' @> '["Delivery note date \"18/11/2026\" not understood: enter it."]'
            and t.codes(t.j() -> 'document' -> 'problems') = '-:not_matched:counterparty_id,-:required:counterparty_id,1:invalid:qty,1:required:unit_price',
            'unknown tax ID: no supplier (problem); bad quantity -> 0, bad price -> empty, bad date -> warning; all block posting');
select t.put('f5', (t.add('A1', 'el.pdf', t.pdf())) ->> 'attachment_id');
select t.ok((t.draft(t.ext(jsonb_build_array(t.line('Bracket', null, '4006381333931', '1', '1', 0.99)), 'EL 094 014 201'), t.id('f5'), 'AW1', 'dn:test:el')) -> 'document' ->> 'counterparty_name' = 'Ortho Supplies SA',
            'tax ID with the EL prefix and spaces matches (normalised); a customer with a tax ID is never chosen');
select t.put('f7', (t.add('A1', 'spare.pdf', t.pdf())) ->> 'attachment_id');
select t.ok(t.codes(t.problems($$select t.draft(t.ext(jsonb_build_array(t.line('x', null, null, '1', '1', 1)), '094014201', '{"schema": "other/9"}'), t.id('f7'), 'AW1', 'dn:test:bad1')$$)) = '-:invalid:schema'
            and t.codes(t.problems($$select t.draft(t.ext('[]'), t.id('f7'), 'AW1', 'dn:test:bad2')$$)) = '-:required:lines'
            and t.codes(t.problems($$select t.draft(t.ext('[]') - 'lines', t.id('f7'), 'AW1', 'dn:test:bad4')$$)) = '-:required:lines'
            and t.codes(t.problems($$select t.draft('"text"', t.id('f7'), 'AW1', 'dn:test:bad3')$$)) = '-:required:lines,-:invalid:p_extraction',
            'contract: unknown schema, empty or missing lines, not an object are refused (nothing created)');
select t.ok(t.codes(t.problems($$select t.draft(t.main_ext(), t.id('f1'), 'AW1', 'dn:test:again')$$)) = '-:linked:p_attachment_id', 'a file already linked to a GRN cannot start another draft');
select t.ok(t.codes(t.problems($$select t.draft(t.main_ext(), t.id('f7'), 'AW1', 'short')$$)) = '-:invalid:p_client_key', 'client_key format is checked');
select t.ok((select count(*) from erp.documents where client_key like 'dn:test:bad%' or client_key = 'dn:test:again') = 0, 'refused calls created nothing');
reset role;
-- a file of branch A2 for a warehouse of A1 (owner can do both)
set local role authenticated;
select t.as(1);
select t.ok(t.codes(t.problems($$select t.draft(t.main_ext(), t.id('f2'), 'AW1', 'dn:test:a2')$$)) = '-:invalid:p_attachment_id', 'the file must belong to the warehouse''s branch');
-- roles and tenant
select t.as(5); select t.fails($$select t.draft(t.main_ext(), t.id('f2'), 'AW2', 'dn:test:r5')$$, 'ERP_FORBIDDEN', 'clinic_user cannot draft a GRN');
select t.as(4); select t.fails($$select t.draft(t.main_ext(), t.id('f2'), 'AW2', 'dn:test:r4')$$, 'ERP_FORBIDDEN', 'accounting cannot draft a GRN');
select t.as(3); select t.fails($$select t.draft(t.main_ext(), t.id('f2'), 'AW2', 'dn:test:r3')$$, 'ERP_FORBIDDEN', 'warehouse of A1 cannot draft for A2');
select t.as(8); select t.ok((t.draft(t.main_ext(), t.id('f2'), 'AW2', 'dn:test:r8')) -> 'document' ->> 'state' = 'draft', 'manager of A2 drafts for A2');
select t.as(3); select t.fails($$select erp_api.grn_draft_from_extraction(t.main_ext(), t.id('f2')::uuid, t.wh('BW1'), 'dn:test:x1')$$, 'ERP_TENANT', 'a warehouse of tenant B: ERP_TENANT');
reset role;
set local role authenticated;
select t.as(11);
select t.put('fb', (erp_api.attachment_add(jsonb_build_object('branch_id', t.br(t.b(), 'B1'), 'filename', 'b.pdf', 'content_base64', t.b64(t.pdf())), gen_random_uuid())) ->> 'attachment_id');
select t.as(3);
select t.fails($$select t.draft(t.main_ext(), t.id('fb'), 'AW1', 'dn:test:x2')$$, 'ERP_TENANT', 'a file of tenant B: ERP_TENANT');

-- ---------- read: list / get, roles, tenant, RLS ----------
select t.keep(erp_api.attachment_get(t.id('f3')::uuid));
select t.ok(decode(t.j() ->> 'content_base64', 'base64') = t.pdf() and t.j() ->> 'filename' = 'clean.pdf' and t.j() ->> 'uploaded_by_email' = 'user3@erp.test',
            'attachment_get returns the exact bytes (base64) and the uploader');
select t.as(6); select t.ok((erp_api.attachment_get(t.id('f3')::uuid)) ->> 'sha256' = encode(sha256(t.pdf()), 'hex')
                            and jsonb_array_length((erp_api.attachment_list(t.id('g1')::uuid)) -> 'rows') = 1, 'readonly of A1 reads the files of its branch');
select t.as(4); select t.ok((erp_api.attachment_get(t.id('f2')::uuid)) ->> 'filename' = 'a2 note.pdf', 'accounting (all branches) reads a file of A2');
select t.as(5); select t.fails($$select erp_api.attachment_get(t.id('f3')::uuid)$$, 'ERP_FORBIDDEN', 'clinic_user cannot read files');
select t.as(5); select t.fails($$select erp_api.attachment_list(t.id('g1')::uuid)$$, 'ERP_FORBIDDEN', 'clinic_user cannot list files');
select t.as(3); select t.fails($$select erp_api.attachment_get(t.id('f2')::uuid)$$, 'ERP_FORBIDDEN', 'warehouse of A1 cannot read a file of A2');
select t.as(6); select t.ok((select count(*) from erp.attachments) = (select count(*) from erp.attachments where branch_id = t.br(t.a(), 'A1')) and (select count(*) from erp.attachments) > 0,
                            'RLS: readonly of A1 sees only rows of A1');
select t.as(5); select t.ok((select count(*) from erp.attachments) = 0, 'RLS: clinic_user sees no attachment row');
select t.as(11);
select t.fails($$select erp_api.attachment_get(t.id('f3')::uuid)$$, 'ERP_TENANT', 'tenant B: an A file id raises ERP_TENANT');
select t.fails($$select erp_api.attachment_list(t.id('g1')::uuid)$$, 'ERP_TENANT', 'tenant B: listing an A document raises ERP_TENANT');
select t.fails($$select erp_api.attachment_delete(t.id('f3')::uuid, gen_random_uuid())$$, 'ERP_TENANT', 'tenant B: deleting an A file raises ERP_TENANT');
select t.fails($$select erp_api.attachment_add(jsonb_build_object('document_id', t.id('g1'), 'filename', 'h.pdf', 'content_base64', t.b64(t.pdf())), gen_random_uuid())$$,
               'ERP_TENANT', 'tenant B: attaching to an A document raises ERP_TENANT');
select t.ok((select count(*) from erp.attachments where tenant_id = t.a()) = 0 and (select count(*) from erp.attachments) = 1, 'RLS: tenant B reads 0 rows of A, its own 1');

-- ---------- delete (soft), linked files of drafts / posted receipts ----------
select t.as(3);
select t.keep(erp_api.attachment_delete(t.id('f3')::uuid, gen_random_uuid()));
select t.ok(t.j() ->> 'deleted_at' is not null and jsonb_array_length((erp_api.attachment_list((select document_id from t.att(t.id('f3'))))) -> 'rows') = 0
            and jsonb_array_length((erp_api.attachment_list((select document_id from t.att(t.id('f3'))), true)) -> 'rows') = 1,
            'warehouse deletes the file of a draft: gone from the list, shown with include_deleted');
select t.ok(t.codes(t.problems($$select erp_api.attachment_get(t.id('f3')::uuid)$$)) = '-:deleted:attachment_id'
            and t.codes(t.problems($$select erp_api.attachment_delete(t.id('f3')::uuid, gen_random_uuid())$$)) = '-:deleted:attachment_id',
            'a deleted file is not served and cannot be deleted twice');
select t.ok(t.codes(t.problems($$select t.draft(t.main_ext(), t.id('f3'), 'AW1', 'dn:test:del')$$)) like '%deleted:p_attachment_id%', 'a deleted file cannot start a draft');
select t.fails($$select erp_api.attachment_delete(t.id('f1')::uuid, gen_random_uuid())$$, 'ERP_FORBIDDEN', 'the file of a POSTED receipt: warehouse cannot delete it (needs approve)');
select t.as(6); select t.fails($$select erp_api.attachment_delete(t.id('f2')::uuid, gen_random_uuid())$$, 'ERP_FORBIDDEN', 'readonly cannot delete');
select t.as(2); select t.ok((erp_api.attachment_delete(t.id('f1')::uuid, gen_random_uuid())) ->> 'deleted_at' is not null, 'manager (approve) deletes the file of a posted receipt');
-- a file added to an existing GRN draft is linked at once; deleting the draft keeps the file, unlinked
select t.as(3);
select t.put('f6', (erp_api.attachment_add(jsonb_build_object('document_id', (select document_id from t.att(t.id('f4'))), 'filename', 'page2.jpg', 'content_base64', t.b64(t.jpg())), gen_random_uuid())) ->> 'attachment_id');
select t.ok((select a.document_id = (select document_id from t.att(t.id('f4'))) and a.branch_id = t.br(t.a(), 'A1') from t.att(t.id('f6')) a), 'a second page added to the draft: linked, branch of the document');
select erp_api.doc_delete_draft((select document_id from t.att(t.id('f4'))), gen_random_uuid()) is not null;
reset role;
select t.ok((select count(*) = 2 and bool_and(document_id is null and deleted_at is null and content is not null) from erp.attachments where attachment_id in (t.id('f4')::uuid, t.id('f6')::uuid)),
            'deleting the draft leaves its files (unlinked, bytes kept)');
select t.ok((select deleted_at is not null and content = t.pdf() from t.att(t.id('f3'))), 'soft delete keeps the bytes (append-only)');
select t.ok(exists (select 1 from erp.audit_log where tenant_id = t.a() and action = 'attachment.delete' and row_id = t.id('f3')), 'audit: attachment.delete');
select t.ok((select used from erp.tenant_usage where tenant_id = t.a() and kind = 'attachments') >= 8, 'usage counter attachments is bumped');

select 'ALL TESTS PASSED' as result, count(*) as checks from t.passes;
rollback;
