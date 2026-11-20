/* ---------- Draft 1: supplier delivery note -> DRAFT goods receipt (GRN drawer section) ---------- */
// The GRN drawer gets a "Delivery note" box: pick a PDF / photo (phone camera works through the file picker), upload it
// (attachment_add, at most 5 MB, PDF / JPEG / PNG; the server checks the bytes), list / open / delete the files of the
// receipt. On a NEW receipt "Create draft from note" runs the extractor and asks the server for a DRAFT GRN
// (grn_draft_from_extraction, client_key = the file's id, so a retry returns the same draft). The draft opens with its
// unmatched / low-confidence lines highlighted; posting stays a separate, manual step.
// The extractor is pluggable: window.ERP_EXTRACTOR = async function ({file, attachment, warehouse}) -> extraction
// (contract `delivery_note_extraction`, E190 section 4). The real one is a future Edge Function; until then the
// default is a deterministic MOCK that returns the same sample for any file and says so on the draft.
var DN_MAX = 5242880, DN_TYPES = ['application/pdf', 'image/jpeg', 'image/png'];
function dnMockExtractor(ctx) {
  return Promise.resolve({schema: 'delivery_note_extraction/1', extractor: 'mock', supplier: {tax_id: '094014201', name: 'Ortho Supplies SA'},
    dn_number: 'MOCK-0001', dn_date: (S.me && S.me.today) || null,
    lines: [{description: 'Bracket MBT 022', supplier_code: 'OS-BR22', barcode: '4006381333931', qty: 10, unit: 'PCS', unit_price: 2.5, confidence: 0.97},
            {description: 'NiTi wire 0.16 upper', supplier_code: 'OS-W16U', barcode: null, qty: 5, unit: 'PCS', unit_price: 3.2, confidence: 0.91},
            {description: 'Elastic ligatures (blurred)', supplier_code: null, barcode: null, qty: 2, unit: 'BOX', unit_price: 1.1, confidence: 0.55}],
    warnings: ['MOCK extractor - sample data, not read from ' + ((ctx && ctx.file && ctx.file.name) || 'the file') + '.']});
}
function dnExtractor() { return typeof window.ERP_EXTRACTOR === 'function' ? window.ERP_EXTRACTOR : dnMockExtractor; }
function dnSize(n) { var v = Number(n) || 0; return v >= 1048576 ? (v / 1048576).toFixed(1) + ' MB' : Math.max(1, Math.round(v / 1024)) + ' KB'; }
function dnInfo(d) { return (d.extra || {}).dn || null; }

// the box inside the GRN drawer (header part of the body)
function dnSection(d) {
  var dn = dnInfo(d), lines = d.lines || [], up = can('doc.grn.create') && d.state !== 'cancelled', h = '';
  if (dn) {
    var un = lines.filter(function (l) { var x = (l.extra || {}).dn; return x && x.status === 'unmatched' && !l.item_id; }).length;
    var lo = lines.filter(function (l) { var x = (l.extra || {}).dn; return x && x.status === 'low_confidence' && !x.checked; }).length;
    var n = lines.filter(function (l) { return (l.extra || {}).dn; }).length;
    if (dn.extractor === 'mock') h += '<p class="msg" id="dn-mock"><b>' + esc(t('dn.mock')) + '</b> ' + esc(t('dn.mock_lead')) + '</p>';
    h += '<p id="dn-summary">' + esc(t('dn.summary', {n: n, un: un, lo: lo})) + (dn.supplier && !dn.supplier.matched && !d.counterparty_id ?
      ' <span class="badge bad">' + esc(t('dn.supplier_unmatched', {tax: dn.supplier.tax_id || '-', name: dn.supplier.name || '-'})) + '</span>' : '') + '</p>';
    if ((dn.warnings || []).length) h += '<ul class="problems" id="dn-warnings">' + dn.warnings.map(function (w) { return '<li>' + esc(w) + '</li>'; }).join('') + '</ul>';
  }
  h += '<div id="dn-files">' + (d.document_id ? '<p class="muted">' + esc(t('app.loading')) + '</p>' : '') + '</div>';
  if (up) {
    h += '<label for="dn-file">' + esc(t('dn.file')) + '</label><input type="file" id="dn-file" accept="application/pdf,image/jpeg,image/png,.pdf,.jpg,.jpeg,.png">' +
      '<p class="muted" id="dn-file-name">' + esc(t('dn.no_file')) + '</p><div class="row">' +
      '<button type="button" id="dn-upload" data-act="dn-upload" disabled>' + esc(t('dn.upload')) + '</button>' +
      (d.document_id ? '' : '<button type="button" class="primary" id="dn-create" data-act="dn-create" disabled>' + esc(t('dn.create')) + '</button>') + '</div>';
  }
  return '<div class="dn-box" id="dn-box"><h2>' + esc(t('dn.title')) + '</h2>' + h + '</div>';
}
function dnFilesHtml(rows) {
  if (!rows.length) return '<p class="muted">' + esc(t('dn.none')) + '</p>';
  var doc = DOCD && DOCD.doc, del = can(doc && doc.document_id && doc.state !== 'draft' ? 'doc.grn.approve' : 'doc.grn.create');
  return '<ul class="dn-list">' + rows.map(function (a) {
    return '<li data-id="' + esc(a.attachment_id) + '"><span class="dn-fname">' + esc(a.filename) + '</span> <span class="muted">' + esc(dnSize(a.size_bytes) + ' · ' + t('dn.kind.' + a.mime)) + '</span> ' +
      '<button type="button" class="link" data-act="dn-open" data-id="' + esc(a.attachment_id) + '">' + esc(t('dn.open')) + '</button>' +
      (del ? '<button type="button" class="link" data-act="dn-delete" data-id="' + esc(a.attachment_id) + '">' + esc(t('dn.delete')) + '</button>' : '') +
      '<div class="dn-view"></div></li>';
  }).join('') + '</ul>';
}
async function dnMount(d) {
  if (!D) return;
  D.dn = {file: null, att: null, files: []};
  if (!d.document_id) return;
  var my = D, r = await api('attachment_list', {p_document_id: d.document_id});
  if (D !== my || !$('dn-files')) return;
  my.dn.files = r.ok && r.data ? r.data.rows : [];
  $('dn-files').innerHTML = r.ok ? dnFilesHtml(my.dn.files) : '<p class="msg bad">' + esc(r.error.text) + '</p>';
}
function dnButtons() {
  var up = $('dn-upload'), cr = $('dn-create');
  if (up) up.disabled = !(D && D.dn && D.dn.file);
  if (cr) cr.disabled = !(D && D.dn && (D.dn.att || D.dn.file));
}
document.addEventListener('change', function (e) {
  if (e.target.id !== 'dn-file' || !D || !D.dn) return;
  var f = e.target.files && e.target.files[0], msg = '';
  D.dn.file = null;
  if (f && f.size > DN_MAX) msg = t('dn.too_large');
  else if (f && f.size === 0) msg = t('dn.empty');
  else if (f && f.type && DN_TYPES.indexOf(f.type === 'image/jpg' ? 'image/jpeg' : f.type) < 0) msg = t('dn.bad_type');
  else if (f) D.dn.file = f;
  $('dn-file-name').textContent = f ? f.name + ' · ' + dnSize(f.size) : t('dn.no_file');
  drawerMsg(msg); dnButtons();
});
function dnBase64(file) {
  return new Promise(function (res, rej) {
    var fr = new FileReader();
    fr.onload = function () { var s = String(fr.result || ''); res(s.slice(s.indexOf(',') + 1)); };
    fr.onerror = function () { rej(fr.error); };
    fr.readAsDataURL(file);
  });
}
// upload the chosen file: linked to the receipt when it exists, else to the chosen warehouse's branch
async function dnUpload() {
  var doc = DOCD.doc, f = D.dn.file, p = {filename: f.name, content_base64: await dnBase64(f)};
  if (f.type) p.mime = f.type;
  if (doc.document_id) p.document_id = doc.document_id;
  else {
    var wh = (STK.whs || []).find(function (w) { return w.warehouse_id === val('d-wh'); });
    if (!wh) return {ok: false, error: {text: t('dn.choose_wh')}};
    p.branch_id = wh.branch_id;
  }
  return api('attachment_add', {p_attachment: p}, {write: true});
}
ACT['dn-upload'] = async function (el) {
  if (!D || !D.dn || !D.dn.file) return;
  if (!DOCD.doc.document_id && !val('d-wh')) { drawerMsg(t('dn.choose_wh')); return; }
  var my = D; el.disabled = true; drawerMsg('');
  var r = await dnUpload();
  if (D !== my) return;
  if (!r.ok || !r.data) { drawerMsg(notSaved(r), r.error && Array.isArray(r.error.detail) ? r.error.detail : null); dnButtons(); return; }
  my.dn.att = r.data; my.dn.last = my.dn.file; my.dn.file = null; my.dn.files = my.dn.files.concat([r.data]);
  $('dn-file').value = ''; $('dn-file-name').textContent = t('dn.uploaded', {name: r.data.filename});
  $('dn-files').innerHTML = dnFilesHtml(my.dn.files); dnButtons(); toast(t('dn.uploaded', {name: r.data.filename}));
};
ACT['dn-create'] = async function (el) {
  if (!D || !D.dn) return;
  var my = D, wh = (STK.whs || []).find(function (w) { return w.warehouse_id === val('d-wh'); });
  if (!wh) { drawerMsg(t('dn.choose_wh')); return; }
  el.disabled = true; drawerMsg(''); el.textContent = t('dn.reading');
  var file = my.dn.file || my.dn.last || null;
  if (!my.dn.att) {   // chosen but not uploaded yet: upload first
    var u = await dnUpload();
    if (D !== my) return;
    if (!u.ok || !u.data) { el.textContent = t('dn.create'); drawerMsg(notSaved(u), u.error && Array.isArray(u.error.detail) ? u.error.detail : null); dnButtons(); return; }
    my.dn.att = u.data; my.dn.files = my.dn.files.concat([u.data]); $('dn-files').innerHTML = dnFilesHtml(my.dn.files);
  }
  var ext;
  try { ext = await dnExtractor()({file: file, attachment: my.dn.att, warehouse: wh}); }
  catch (e) { ext = null; }
  if (D !== my) return;
  if (!ext || typeof ext !== 'object') { el.textContent = t('dn.create'); el.disabled = false; drawerMsg(t('dn.extract_failed')); return; }
  // no idempotency-key argument: the RPC is idempotent by its client_key (the file's id)
  var r = await api('grn_draft_from_extraction', {p_extraction: ext, p_attachment_id: my.dn.att.attachment_id, p_warehouse_id: wh.warehouse_id, p_client_key: 'dn:' + my.dn.att.attachment_id});
  if (D !== my) return;
  el.textContent = t('dn.create');
  if (!r.ok || !r.data || !r.data.document) { el.disabled = false; drawerMsg(notSaved(r), r.error && Array.isArray(r.error.detail) ? r.error.detail : null); return; }
  var s = r.data.summary || {};
  drawerClose(true); STK.sups = null; await stkSuppliers(); docDrawer(r.data.document);
  toast(t('dn.created', {n: s.lines || 0, un: s.unmatched || 0, lo: s.low_confidence || 0})); stkLoad(true);
};
ACT['dn-open'] = async function (el) {
  var id = el.getAttribute('data-id'), li = el.closest('li'), my = D;
  el.disabled = true;
  var r = await api('attachment_get', {p_attachment_id: id});
  el.disabled = false;
  if (D !== my || !li.isConnected) return;
  if (!r.ok || !r.data) { drawerMsg(r.error ? r.error.text : t('err.unknown')); return; }
  var bin = atob(r.data.content_base64 || ''), u8 = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
  var url = URL.createObjectURL(new Blob([u8], {type: r.data.mime}));
  // a link the person taps (a pop-up after an await is blocked on phones); photos also shown inline
  li.querySelector('.dn-view').innerHTML = '<a class="dn-link" href="' + esc(url) + '" target="_blank" rel="noopener" download="' + esc(r.data.filename) + '">' + esc(t('dn.open_file', {name: r.data.filename})) + '</a>' +
    (r.data.mime.indexOf('image/') === 0 ? '<img class="dn-preview" alt="' + esc(r.data.filename) + '" src="' + esc(url) + '">' : '');
};
ACT['dn-delete'] = function (el) {
  var id = el.getAttribute('data-id'), my = D;
  confirmBox(t('dn.delete_q'), t('dn.delete'), t('cancel'), async function () {
    var r = await api('attachment_delete', {p_attachment_id: id}, {write: true});
    if (D !== my) return;
    if (!r.ok) { drawerMsg(notSaved(r)); return; }
    my.dn.files = my.dn.files.filter(function (a) { return a.attachment_id !== id; });
    if (my.dn.att && my.dn.att.attachment_id === id) my.dn.att = null;
    $('dn-files').innerHTML = dnFilesHtml(my.dn.files); dnButtons(); toast(t('dn.deleted'));
  });
};
// a line read from the note: what the note said, and its flag (not matched / check); "Mark checked" confirms it
function dnLineInfo(l, i, ro) {
  var x = (l.extra || {}).dn;
  if (!x || x.status === 'matched') return '';
  var txt = x.description || x.supplier_code || x.barcode || '', b = '';
  if (x.status === 'unmatched' && !l.item_id) b = ' <span class="badge bad">' + esc(t('dn.not_matched')) + '</span>';
  else if (x.status === 'low_confidence' && !x.checked) b = ' <span class="badge warn">' + esc(t('dn.check', {c: x.confidence != null ? Math.round(Number(x.confidence) * 100) + '%' : '?'})) + '</span>' +
    (ro ? '' : ' <button type="button" class="link" data-act="dn-check" data-i="' + i + '">' + esc(t('dn.mark_checked')) + '</button>');
  else if (x.status === 'low_confidence') b = ' <span class="badge good">' + esc(t('dn.checked')) + '</span>';
  return '<div class="dl-dn muted">' + esc(t('dn.from_note', {text: txt})) + b + '</div>';
}
function dnLineFlag(l) { var x = (l.extra || {}).dn; return !!x && ((x.status === 'unmatched' && !l.item_id) || (x.status === 'low_confidence' && !x.checked)); }
ACT['dn-check'] = function (el) {
  docReadLines();
  var l = DOCD.lines[Number(el.getAttribute('data-i'))]; if (!l || !l.extra || !l.extra.dn) return;
  l.extra = Object.assign({}, l.extra, {dn: Object.assign({}, l.extra.dn, {checked: true})});
  $('doc-lines').innerHTML = DOCD.lines.map(function (x, i) { return docLineRow(x, i, DOCD.form, false); }).join('');
  if (D) D.dirty = true;
};
