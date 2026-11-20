-- =====================================================================
-- iSmile ERP  -  E190_attachments.sql   (Draft 1: supplier delivery-note file -> DRAFT goods receipt)
-- Purpose : the platform table `attachments` (02 platform list, STATE 13): a file stored IN the database (bytea, at
--           most 5 MB, PDF / JPEG / PNG only, checked by its first bytes, sha256), linked to a GRN, append-only
--           except the link and a soft delete; RPCs attachment_add / attachment_list / attachment_get /
--           attachment_delete. The extraction contract `delivery_note_extraction` (below, section 4) and the RPC
--           grn_draft_from_extraction: a DRAFT GRN from an extraction (supplier by tax ID, each line to an item by
--           barcode, then item code, then exact name); unmatched / low-confidence lines stay on the draft flagged in
--           line `extra.dn` and block posting (erp.grn_dn_validate, called by E150 doc_stock_validate). NEVER posts.
-- NOT here : the extractor itself (a future Edge Function on live; this file never calls a service), a storage bucket
--           (live decision; the bytes are in the table), purge of soft-deleted files, attachments of other types.
-- Run order: after E180 (needs E130 core, E150 GRN). Standalone: names no CRM object. Safe to re-run.
-- Redefines: nothing. Changes the GRN catalogue row: header_extra + 'dn', line_extra 'dn' (seed_version 3).
-- Tests    : tests/E190_attachments_tests.sql, tests/E990 (registry + fixtures)
-- =====================================================================

do $$ begin
  if to_regprocedure('erp.doc_stock_validate(uuid,uuid)') is null then raise exception 'run E150_stock_docs.sql first'; end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Table. tenant_id first; the bytes live in the row (storage external: PDF / JPEG / PNG are already compressed)
-- ---------------------------------------------------------------------
create table if not exists erp.attachments (
  tenant_id     uuid not null references erp.tenants (tenant_id),
  attachment_id uuid not null default gen_random_uuid(),
  branch_id     uuid not null,
  document_id   uuid,
  kind          text not null default 'delivery_note' check (kind in ('delivery_note')),
  filename      text not null check (btrim(filename) <> '' and length(filename) <= 200 and filename !~ '[/\\[:cntrl:]]'),
  mime          text not null check (mime in ('application/pdf', 'image/jpeg', 'image/png')),
  size_bytes    int not null check (size_bytes between 1 and 5242880),
  sha256        text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  content       bytea not null,
  uploaded_by   uuid not null,
  uploaded_at   timestamptz not null default now(),
  deleted_at    timestamptz,
  deleted_by    uuid,
  primary key (tenant_id, attachment_id),
  foreign key (tenant_id, branch_id) references erp.branches (tenant_id, branch_id),
  foreign key (tenant_id, uploaded_by) references erp.members (tenant_id, member_id),
  -- a deleted draft leaves its files unlinked (PostgreSQL 15+: only the link column is set to null)
  foreign key (tenant_id, document_id) references erp.documents (tenant_id, document_id) on delete set null (document_id),
  check (octet_length(content) = size_bytes),
  check ((deleted_at is null) = (deleted_by is null))
);
alter table erp.attachments alter column content set storage external;
create index if not exists attachments_document_idx on erp.attachments (tenant_id, document_id) where document_id is not null;
create index if not exists attachments_branch_idx on erp.attachments (tenant_id, branch_id);

-- append-only: only the link (document_id) and the soft delete (null -> value, once) may change; no delete, no truncate
create or replace function erp.tg_attachments_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op <> 'UPDATE' then perform erp.err('ERP_APPEND_ONLY', 'Attachments are append-only (delete = soft delete).'); end if;
  if (to_jsonb(new) - 'document_id' - 'deleted_at' - 'deleted_by') <> (to_jsonb(old) - 'document_id' - 'deleted_at' - 'deleted_by')
     or (old.deleted_at is not null and (new.deleted_at is distinct from old.deleted_at or new.deleted_by is distinct from old.deleted_by)) then
    perform erp.err('ERP_APPEND_ONLY', 'An attachment cannot be changed (only linked or deleted once).');
  end if;
  return new;
end $$;
drop trigger if exists attachments_guard on erp.attachments;
create trigger attachments_guard before update or delete on erp.attachments for each row execute function erp.tg_attachments_guard();
drop trigger if exists attachments_no_truncate on erp.attachments;
create trigger attachments_no_truncate before truncate on erp.attachments for each statement execute function erp.tg_append_only();

-- ---------------------------------------------------------------------
-- 2. The GRN carries the delivery-note data in extra (catalogue row; seeded rows change only by this update)
--    header extra.dn = {attachment_id, extractor, supplier {tax_id, name, matched}, warnings[]}
--    line extra.dn   = {status matched | unmatched | low_confidence, match barcode | code | name | null, description,
--                       supplier_code, barcode, unit, confidence, checked (the user confirmed a low-confidence line)}
-- ---------------------------------------------------------------------
update erp.doc_types set header_extra = '{mark,dn}', line_extra = '{dn}', seed_version = 3 where doc_type = 'GRN' and seed_version < 3;

-- the problems of a GRN drafted from a delivery note (called by erp.doc_stock_validate, E150): problems, never an exception
create or replace function erp.grn_dn_validate(p_tenant uuid, p_doc uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare d erp.documents; probs jsonb := '[]'; l record; s jsonb;
begin
  select * into d from erp.documents where tenant_id = p_tenant and document_id = p_doc;
  if d.extra ? 'dn' and jsonb_typeof(d.extra -> 'dn') <> 'object' then probs := probs || erp.problem('invalid', 'extra.dn', 'Delivery-note data must be an object.'); end if;
  s := case when jsonb_typeof(d.extra -> 'dn' -> 'supplier') = 'object' then d.extra -> 'dn' -> 'supplier' end;
  if d.counterparty_id is null and s is not null and not coalesce((s ->> 'matched')::boolean, false) then
    probs := probs || erp.problem('not_matched', 'counterparty_id', format('Supplier not found (tax ID %s, %s): choose the supplier.',
                                  coalesce(nullif(s ->> 'tax_id', ''), '-'), coalesce(nullif(s ->> 'name', ''), '-')));
  end if;
  for l in select x.line_no, x.item_id, x.extra -> 'dn' dn from erp.document_lines x
            where x.tenant_id = p_tenant and x.document_id = p_doc and x.extra ? 'dn' order by x.line_no loop
    if jsonb_typeof(l.dn) <> 'object' then probs := probs || erp.problem('invalid', 'extra.dn', 'Delivery-note data must be an object.', l.line_no); continue; end if;
    if l.dn ->> 'status' = 'unmatched' and l.item_id is null then
      probs := probs || erp.problem('not_matched', 'item_id', format('Item not matched: "%s". Choose the item.',
                                    left(coalesce(nullif(l.dn ->> 'description', ''), nullif(l.dn ->> 'supplier_code', ''), nullif(l.dn ->> 'barcode', ''), '?'), 120)), l.line_no);
    elsif l.dn ->> 'status' = 'low_confidence' and coalesce(l.dn ->> 'checked', 'false') <> 'true' then
      probs := probs || erp.problem('check_line', 'extra.dn', 'Read from the delivery note with low confidence: check item, quantity and price, then mark it checked.', l.line_no);
    end if;
  end loop;
  return probs;
end $$;

-- ---------------------------------------------------------------------
-- 3. Attachment RPCs. Capabilities: doc.grn.create adds / deletes (on the file's branch; a file of a POSTED or
--    cancelled GRN needs doc.grn.approve to delete), doc.grn.read lists / reads (branch + the linked GRN readable).
-- ---------------------------------------------------------------------
-- the type by its first bytes (magic numbers); null = not allowed
create or replace function erp.attachment_sniff(p bytea) returns text
language sql immutable set search_path = '' as $$
  select case when substring(p from 1 for 5) = '\x255044462d'::bytea then 'application/pdf'
              when substring(p from 1 for 3) = '\xffd8ff'::bytea then 'image/jpeg'
              when substring(p from 1 for 8) = '\x89504e470d0a1a0a'::bytea then 'image/png' end
$$;
create or replace function erp.attachment_json(a erp.attachments) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('attachment_id', a.attachment_id, 'branch_id', a.branch_id, 'document_id', a.document_id, 'kind', a.kind,
                            'filename', a.filename, 'mime', a.mime, 'size_bytes', a.size_bytes, 'sha256', a.sha256,
                            'uploaded_by', a.uploaded_by, 'uploaded_by_email', (select m.email from erp.members m where m.tenant_id = a.tenant_id and m.member_id = a.uploaded_by),
                            'uploaded_at', a.uploaded_at, 'deleted_at', a.deleted_at)
$$;
-- the attachment of the caller's tenant (else ERP_TENANT), readable with p_cap on its branch and its GRN visible
create or replace function erp.attachment_of(p_tenant uuid, p_id uuid, p_cap text, p_lock boolean) returns erp.attachments
language plpgsql security definer set search_path = '' as $$
declare a erp.attachments;
begin
  if p_lock then select * into a from erp.attachments x where x.tenant_id = p_tenant and x.attachment_id = p_id for update;
  else select * into a from erp.attachments x where x.tenant_id = p_tenant and x.attachment_id = p_id; end if;
  if a.attachment_id is null then perform erp.err('ERP_TENANT', format('Attachment %s does not belong to your organisation.', coalesce(p_id::text, 'null'))); end if;
  perform erp.require_cap(p_cap, a.branch_id);
  if a.document_id is not null then perform erp.doc_visible(p_tenant, a.document_id); end if;
  return a;
end $$;

-- attachment_add: keys document_id (a GRN: the file is linked and takes its branch) or branch_id (a file not linked
-- yet, e.g. before "Create draft from note"), filename, mime (optional; must agree with the bytes), content_base64.
-- At most 5 MB; PDF / JPEG / PNG by the first bytes. Reply: the attachment (no content).
create or replace function erp_api.attachment_add(p_attachment jsonb, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; payload jsonb; d erp.documents; v_branch uuid; v_doc uuid; probs jsonb; raw bytea; b64 text; fname text; sniff text; a erp.attachments; res jsonb;
begin
  m := erp.require_member();
  if p_attachment is null or jsonb_typeof(p_attachment) <> 'object' then p_attachment := '{}'; end if;
  -- the request hash of the idempotency key: the fields + an md5 of the content (the bytes are not stored twice)
  payload := (p_attachment - 'content_base64') || jsonb_build_object('content_md5', md5(coalesce(p_attachment ->> 'content_base64', '')));
  if erp.jset(p_attachment, 'document_id') then
    v_doc := erp.try_uuid(p_attachment ->> 'document_id');
    select * into d from erp.documents x where x.tenant_id = m.tenant_id and x.document_id = v_doc;
    if d.document_id is null then perform erp.err('ERP_TENANT', format('Document %s does not belong to your organisation.', coalesce(v_doc::text, 'null'))); end if;
    v_branch := d.branch_id;
  else
    v_branch := erp.try_uuid(p_attachment ->> 'branch_id');
    if v_branch is null then perform erp.raise_problems(jsonb_build_array(erp.problem('required', 'branch_id', 'Choose the branch (warehouse) first.'))); end if;
    perform erp.require_branch_of_tenant(m.tenant_id, v_branch);
  end if;
  perform erp.require_cap('doc.grn.create', v_branch);
  if v_doc is not null then perform erp.doc_visible(m.tenant_id, v_doc); end if;
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'attachment_add', payload);
  if prev is not null then return prev; end if;
  probs := erp.unknown_keys(p_attachment, array['document_id', 'branch_id', 'filename', 'mime', 'content_base64']);
  if v_doc is not null and d.doc_type <> 'GRN' then probs := probs || erp.problem('invalid', 'document_id', 'Files can be attached to goods receipts only.'); end if;
  if v_doc is not null and erp.jset(p_attachment, 'branch_id') and erp.try_uuid(p_attachment ->> 'branch_id') is distinct from v_branch then
    probs := probs || erp.problem('invalid', 'branch_id', 'The branch is the document''s.'); end if;
  fname := btrim(coalesce(p_attachment ->> 'filename', ''));
  if fname = '' then probs := probs || erp.problem('required', 'filename', 'The file name is required.');
  elsif length(fname) > 200 or fname ~ '[/\\[:cntrl:]]' then probs := probs || erp.problem('invalid', 'filename', 'File name: at most 200 characters, no / or \.'); end if;
  b64 := regexp_replace(coalesce(p_attachment ->> 'content_base64', ''), '\s', '', 'g');
  if b64 = '' then probs := probs || erp.problem('required', 'content_base64', 'The file is empty.');
  elsif length(b64) > 6990508 then probs := probs || erp.problem('too_large', 'content_base64', 'The file is larger than 5 MB.');   -- 4 x ceil(5 MB / 3)
  else
    begin raw := decode(b64, 'base64'); exception when others then probs := probs || erp.problem('invalid', 'content_base64', 'The content is not valid base64.'); end;
  end if;
  if raw is not null then
    if octet_length(raw) = 0 then probs := probs || erp.problem('required', 'content_base64', 'The file is empty.');
    elsif octet_length(raw) > 5242880 then probs := probs || erp.problem('too_large', 'content_base64', 'The file is larger than 5 MB.');
    else
      sniff := erp.attachment_sniff(raw);
      if sniff is null then probs := probs || erp.problem('type', 'content_base64', 'Only PDF, JPEG or PNG files (checked by their content).');
      elsif erp.jset(p_attachment, 'mime') and lower(p_attachment ->> 'mime') <> sniff and not (lower(p_attachment ->> 'mime') = 'image/jpg' and sniff = 'image/jpeg') then
        probs := probs || erp.problem('type', 'mime', format('The file is a %s, not %s.', sniff, p_attachment ->> 'mime')); end if;
    end if;
  end if;
  perform erp.raise_problems(probs);
  perform erp.check_limit(m.tenant_id, 'attachments');
  insert into erp.attachments (tenant_id, branch_id, document_id, filename, mime, size_bytes, sha256, content, uploaded_by)
  values (m.tenant_id, v_branch, v_doc, fname, sniff, octet_length(raw), encode(sha256(raw), 'hex'), raw, m.member_id) returning * into a;
  perform erp.usage_bump(m.tenant_id, 'attachments');
  perform erp.audit(m.tenant_id, 'attachment.add', 'attachments', a.attachment_id::text, null,
                    jsonb_build_object('filename', a.filename, 'mime', a.mime, 'size_bytes', a.size_bytes, 'sha256', a.sha256, 'document_id', a.document_id), v_branch);
  res := erp.attachment_json(a);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'attachment_add', payload, res);
end $$;

-- attachment_list: the files of one GRN (not deleted unless p_include_deleted), oldest first. Reply {rows}.
create or replace function erp_api.attachment_list(p_document_id uuid, p_include_deleted boolean default false) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; d erp.documents;
begin
  m := erp.require_member();
  select * into d from erp.documents x where x.tenant_id = m.tenant_id and x.document_id = p_document_id;
  if d.document_id is null then perform erp.err('ERP_TENANT', format('Document %s does not belong to your organisation.', coalesce(p_document_id::text, 'null'))); end if;
  perform erp.require_cap('doc.grn.read', d.branch_id);
  perform erp.doc_visible(m.tenant_id, p_document_id);
  return jsonb_build_object('rows', coalesce((select jsonb_agg(erp.attachment_json(a) order by a.uploaded_at, a.attachment_id) from erp.attachments a
                                               where a.tenant_id = m.tenant_id and a.document_id = p_document_id
                                                 and (coalesce(p_include_deleted, false) or a.deleted_at is null)), '[]'::jsonb));
end $$;

-- attachment_get: the attachment WITH content_base64 (to open / preview). A deleted file is not served.
create or replace function erp_api.attachment_get(p_attachment_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; a erp.attachments;
begin
  m := erp.require_member();
  a := erp.attachment_of(m.tenant_id, p_attachment_id, 'doc.grn.read', false);
  if a.deleted_at is not null then perform erp.raise_problems(jsonb_build_array(erp.problem('deleted', 'attachment_id', 'The file was deleted.'))); end if;
  return erp.attachment_json(a) || jsonb_build_object('content_base64', translate(encode(a.content, 'base64'), E'\n', ''));
end $$;

-- attachment_delete: soft delete (the bytes stay, append-only); the reply is the attachment with deleted_at
create or replace function erp_api.attachment_delete(p_attachment_id uuid, p_idempotency_key uuid) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; prev jsonb; a erp.attachments; st text; res jsonb;
begin
  m := erp.require_member();
  a := erp.attachment_of(m.tenant_id, p_attachment_id, 'doc.grn.create', false);
  prev := erp.idem_begin(m.tenant_id, p_idempotency_key, 'attachment_delete', to_jsonb(p_attachment_id));
  if prev is not null then return prev; end if;
  a := erp.attachment_of(m.tenant_id, p_attachment_id, 'doc.grn.create', true);
  if a.deleted_at is not null then perform erp.raise_problems(jsonb_build_array(erp.problem('deleted', 'attachment_id', 'The file was already deleted.'))); end if;
  select x.state into st from erp.documents x where x.tenant_id = m.tenant_id and x.document_id = a.document_id;
  if st is not null and st <> 'draft' then perform erp.require_cap('doc.grn.approve', a.branch_id); end if;   -- evidence of a posted receipt
  update erp.attachments set deleted_at = now(), deleted_by = m.member_id where tenant_id = m.tenant_id and attachment_id = a.attachment_id returning * into a;
  perform erp.audit(m.tenant_id, 'attachment.delete', 'attachments', a.attachment_id::text, jsonb_build_object('filename', a.filename, 'document_id', a.document_id),
                    jsonb_build_object('deleted_at', a.deleted_at), a.branch_id);
  res := erp.attachment_json(a);
  return erp.idem_end(m.tenant_id, p_idempotency_key, 'attachment_delete', to_jsonb(p_attachment_id), res);
end $$;

-- ---------------------------------------------------------------------
-- 4. EXTRACTION CONTRACT `delivery_note_extraction` (version 1). The extractor (future Edge Function; in this build
--    the page's pluggable window.ERP_EXTRACTOR, a MOCK by default) returns ONE json object:
--      {"schema": "delivery_note_extraction/1",            optional; other values are refused
--       "extractor": "mock" | "<service>/<version>",       text <= 60 (shown on the draft)
--       "supplier": {"tax_id": "094014201", "name": "..."},  both optional
--       "dn_number": "ΔΑ-1234",                            text <= 60 -> documents.ext_number
--       "dn_date": "2026-11-18",                           yyyy-mm-dd -> documents.ext_date (else a warning)
--       "lines": [{"description": "...", "supplier_code": "...", "barcode": "...", "qty": 10, "unit": "PCS",
--                  "unit_price": 2.5, "confidence": 0.0 .. 1.0}],       1 .. 500 lines; numbers or numeric text
--       "warnings": ["..."]}                               texts the extractor wants the user to read
--    Unknown keys are ignored (kept out of the draft). A line is matched to an ACTIVE stock item by barcode, then by
--    our item code = supplier_code, then by exact name = description (case-insensitive, only when one item has it).
--    confidence < 0.80 or missing -> status low_confidence (the user marks the line checked); no item -> unmatched.
--    A quantity that is not a number > 0 becomes 0 and a price that is not a number >= 0 is left empty: the core
--    validation then blocks posting until the user fixes them.
-- ---------------------------------------------------------------------
create or replace function erp.dn_text(p jsonb, k text, n int) returns text
language sql immutable set search_path = '' as $$
  select nullif(left(btrim(case when jsonb_typeof(p -> k) in ('string', 'number') then p ->> k end), n), '')
$$;

-- grn_draft_from_extraction: a DRAFT GRN of the warehouse's branch from an extraction + the uploaded file (linked to
-- the draft). Idempotent by p_client_key (8-120 of A-Z a-z 0-9 : _ . -): a second call returns the SAME draft
-- unchanged (the user's fixes are kept). Cap doc.grn.create on the branch. Reply {created, document, summary}; never posts.
create or replace function erp_api.grn_draft_from_extraction(p_extraction jsonb, p_attachment_id uuid, p_warehouse_id uuid, p_client_key text) returns jsonb
language plpgsql security definer set search_path = '' set statement_timeout = '8s' as $$
declare m erp.members; w erp.warehouses; a erp.attachments; existing uuid; probs jsonb := '[]'; e jsonb; n int := 0; lines jsonb := '[]'; warns jsonb := '[]';
        sup jsonb; v_tax text; v_cp uuid; v_item uuid; v_match text; v_bc text; v_code text; v_desc text; v_conf numeric; q numeric; pr numeric; st text;
        v_date date; v_no text; doc jsonb; res jsonb; cnt int; summ jsonb; ext text;
begin
  m := erp.require_member();
  perform erp.require_own(m.tenant_id, 'warehouse', p_warehouse_id);
  select * into w from erp.warehouses x where x.tenant_id = m.tenant_id and x.warehouse_id = p_warehouse_id;
  perform erp.doc_require('GRN', 'create', w.branch_id);
  if p_client_key is null or p_client_key !~ '^[A-Za-z0-9:_.-]{8,120}$' then
    perform erp.raise_problems(jsonb_build_array(erp.problem('invalid', 'p_client_key', 'client_key: 8-120 letters, digits, : _ . -')));
  end if;
  -- one call per key at a time; a repeat returns the existing draft as it is now
  perform pg_advisory_xact_lock(hashtextextended('erp.dn:' || m.tenant_id || ':' || p_client_key, 0));
  select x.document_id into existing from erp.documents x where x.tenant_id = m.tenant_id and x.client_key = p_client_key;
  if existing is not null then
    perform erp.doc_visible(m.tenant_id, existing);
    if (select x.doc_type from erp.documents x where x.tenant_id = m.tenant_id and x.document_id = existing) <> 'GRN' then
      perform erp.raise_problems(jsonb_build_array(erp.problem('duplicate', 'p_client_key', 'The client_key is used by another document.')));
    end if;
    doc := erp.doc_json(m.tenant_id, existing);
    return jsonb_build_object('created', false, 'document', doc, 'summary', erp.dn_summary(doc));
  end if;
  -- the file: own tenant, same branch, not deleted, not linked to another document
  a := erp.attachment_of(m.tenant_id, p_attachment_id, 'doc.grn.create', true);
  if a.deleted_at is not null then probs := probs || erp.problem('deleted', 'p_attachment_id', 'The file was deleted.'); end if;
  if a.document_id is not null then probs := probs || erp.problem('linked', 'p_attachment_id', 'The file already belongs to another document.'); end if;
  if a.branch_id <> w.branch_id then probs := probs || erp.problem('invalid', 'p_attachment_id', 'The file was uploaded for another branch.'); end if;
  -- the extraction (contract above)
  if p_extraction is null or jsonb_typeof(p_extraction) <> 'object' then
    probs := probs || erp.problem('invalid', 'p_extraction', 'The extraction must be an object.'); p_extraction := '{}';
  end if;
  if p_extraction ? 'schema' and p_extraction ->> 'schema' is distinct from 'delivery_note_extraction/1' then
    probs := probs || erp.problem('invalid', 'schema', 'Unknown extraction schema (expected delivery_note_extraction/1).'); end if;
  if coalesce(jsonb_typeof(p_extraction -> 'lines'), 'none') <> 'array' or jsonb_array_length(p_extraction -> 'lines') = 0 then
    probs := probs || erp.problem('required', 'lines', 'The extraction has no lines.');
  elsif jsonb_array_length(p_extraction -> 'lines') > 500 then probs := probs || erp.problem('too_many', 'lines', 'At most 500 lines.'); end if;
  if p_extraction ? 'supplier' and jsonb_typeof(p_extraction -> 'supplier') <> 'object' then probs := probs || erp.problem('invalid', 'supplier', 'supplier must be an object.'); end if;
  if p_extraction ? 'warnings' and jsonb_typeof(p_extraction -> 'warnings') <> 'array' then probs := probs || erp.problem('invalid', 'warnings', 'warnings must be a list.'); end if;
  perform erp.raise_problems(probs);
  ext := coalesce(erp.dn_text(p_extraction, 'extractor', 60), 'unknown');
  warns := coalesce((select jsonb_agg(left(x, 300)) from (select jsonb_array_elements_text(p_extraction -> 'warnings') x
                                                             where jsonb_typeof(p_extraction -> 'warnings') = 'array' limit 20) y), '[]'::jsonb);
  -- supplier by tax ID (normalised by its country), active supplier / both; one match only
  sup := coalesce(p_extraction -> 'supplier', '{}');
  v_tax := erp.dn_text(sup, 'tax_id', 30);
  if v_tax is not null then
    select count(*), min(c.counterparty_id::text)::uuid into cnt, v_cp from erp.counterparties c
     where c.tenant_id = m.tenant_id and c.active and c.kind in ('supplier', 'both') and c.tax_id is not null
       and c.tax_id = erp.tax_id_norm(v_tax, c.country);
    if cnt <> 1 then v_cp := null; end if;
  end if;
  -- header dates / number
  v_no := erp.dn_text(p_extraction, 'dn_number', 60);
  if erp.dn_text(p_extraction, 'dn_date', 10) is not null then
    begin
      if erp.dn_text(p_extraction, 'dn_date', 10) !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'bad'; end if;
      v_date := erp.dn_text(p_extraction, 'dn_date', 10)::date;
    exception when others then v_date := null; warns := warns || to_jsonb(format('Delivery note date "%s" not understood: enter it.', erp.dn_text(p_extraction, 'dn_date', 30)));
    end;
  end if;
  -- lines
  for e in select * from jsonb_array_elements(p_extraction -> 'lines') loop
    n := n + 1;
    if jsonb_typeof(e) <> 'object' then e := '{}'; end if;
    v_bc := erp.dn_text(e, 'barcode', 64); v_code := erp.dn_text(e, 'supplier_code', 60); v_desc := erp.dn_text(e, 'description', 300);
    v_item := null; v_match := null;
    if v_bc is not null then
      select i.item_id into v_item from erp.item_barcodes b join erp.items i on i.tenant_id = b.tenant_id and i.item_id = b.item_id
       where b.tenant_id = m.tenant_id and b.barcode = v_bc and i.active and i.kind <> 'service';
      if v_item is not null then v_match := 'barcode'; end if;
    end if;
    if v_item is null and v_code is not null then
      select i.item_id into v_item from erp.items i where i.tenant_id = m.tenant_id and lower(i.code) = lower(v_code) and i.active and i.kind <> 'service';
      if v_item is not null then v_match := 'code'; end if;
    end if;
    if v_item is null and v_desc is not null then
      select count(*), min(i.item_id::text)::uuid into cnt, v_item from erp.items i
       where i.tenant_id = m.tenant_id and lower(btrim(i.name)) = lower(v_desc) and i.active and i.kind <> 'service';
      if cnt = 1 then v_match := 'name'; else v_item := null; end if;
    end if;
    q := erp.try_numeric(replace(coalesce(erp.dn_text(e, 'qty', 30), ''), ',', '.'));
    if q is null or q <= 0 or q >= 1e12 then q := 0; else q := round(q, 4); end if;
    pr := erp.try_numeric(replace(coalesce(erp.dn_text(e, 'unit_price', 30), ''), ',', '.'));
    if pr is not null and (pr < 0 or pr >= 1e12) then pr := null; end if;
    v_conf := erp.try_numeric(erp.dn_text(e, 'confidence', 30));
    if v_conf is not null and (v_conf < 0 or v_conf > 1) then v_conf := null; end if;
    st := case when v_item is null then 'unmatched' when v_conf is null or v_conf < 0.80 then 'low_confidence' else 'matched' end;
    lines := lines || jsonb_strip_nulls(jsonb_build_object('item_id', v_item, 'description', coalesce(v_desc, v_code, v_bc, format('Line %s of the delivery note', n)),
                                                           'qty', q, 'unit_price', round(pr, 4),
                                                           'extra', jsonb_build_object('dn', jsonb_strip_nulls(jsonb_build_object(
                                                             'status', st, 'match', v_match, 'description', v_desc, 'supplier_code', v_code, 'barcode', v_bc,
                                                             'unit', erp.dn_text(e, 'unit', 20), 'confidence', v_conf, 'checked', false)))));
  end loop;
  -- the draft through the core (validation, totals, audit); then the file is linked
  doc := erp_api.doc_save_draft('GRN', jsonb_strip_nulls(jsonb_build_object('branch_id', w.branch_id, 'warehouse_id', w.warehouse_id, 'counterparty_id', v_cp,
           'ext_number', v_no, 'ext_date', v_date, 'client_key', p_client_key, 'notes', 'From delivery note ' || a.filename,
           'extra', jsonb_build_object('dn', jsonb_build_object('attachment_id', a.attachment_id, 'extractor', ext, 'warnings', warns,
                      'supplier', jsonb_build_object('tax_id', v_tax, 'name', erp.dn_text(sup, 'name', 200), 'matched', v_cp is not null)) ),
           'lines', lines)), gen_random_uuid());
  update erp.attachments set document_id = (doc ->> 'document_id')::uuid where tenant_id = m.tenant_id and attachment_id = a.attachment_id;
  doc := erp.doc_json(m.tenant_id, (doc ->> 'document_id')::uuid);
  summ := erp.dn_summary(doc);
  perform erp.audit(m.tenant_id, 'grn.draft_from_extraction', 'documents', doc ->> 'document_id', null,
                    jsonb_build_object('attachment_id', a.attachment_id, 'extractor', ext) || summ, w.branch_id);
  return jsonb_build_object('created', true, 'document', doc, 'summary', summ);
end $$;

-- counts of a drafted GRN's lines by status (from its json)
create or replace function erp.dn_summary(p_doc jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('lines', count(*),
                            'matched', count(*) filter (where l -> 'extra' -> 'dn' ->> 'status' = 'matched'),
                            'unmatched', count(*) filter (where l -> 'extra' -> 'dn' ->> 'status' = 'unmatched' and l ->> 'item_id' is null),
                            'low_confidence', count(*) filter (where l -> 'extra' -> 'dn' ->> 'status' = 'low_confidence' and coalesce(l -> 'extra' -> 'dn' ->> 'checked', 'false') <> 'true'),
                            'supplier_matched', coalesce((p_doc -> 'extra' -> 'dn' -> 'supplier' ->> 'matched')::boolean, p_doc ->> 'counterparty_id' is not null),
                            'problems', coalesce(jsonb_array_length(p_doc -> 'problems'), 0))
    from jsonb_array_elements(coalesce(p_doc -> 'lines', '[]')) l
$$;

-- ---------------------------------------------------------------------
-- 5. RLS + grants. Read: tenant, doc.grn.read, own branches (owner / all-branches members: every branch)
-- ---------------------------------------------------------------------
alter table erp.attachments enable row level security;
alter table erp.attachments force row level security;
drop policy if exists attachments_read on erp.attachments;
create policy attachments_read on erp.attachments for select to authenticated
  using (tenant_id = any ((select erp.my_tenants())::uuid[]) and (select erp.can('doc.grn.read'))
         and branch_id = any ((select erp.my_branches())::uuid[]));
do $$ declare r text; begin
  foreach r in array array['public', 'anon', 'service_role'] loop
    if r = 'public' or exists (select 1 from pg_catalog.pg_roles where rolname = r) then
      execute format('revoke all on erp.attachments from %s', r);
    end if;
  end loop;
end $$;
revoke insert, update, delete, truncate, references, trigger on erp.attachments from authenticated;
grant select on erp.attachments to authenticated;

select erp.lock_down();
grant execute on function erp_api.attachment_add(jsonb, uuid), erp_api.attachment_list(uuid, boolean), erp_api.attachment_get(uuid),
                          erp_api.attachment_delete(uuid, uuid), erp_api.grn_draft_from_extraction(jsonb, uuid, uuid, text) to authenticated;
