/* ---------- stock: on hand, stock card, documents (OPN, GRN, ADJ+, ADJ-, CONS), negative stock, alerts (T14) ---------- */
// Lists use keyset paging ("Load more"). The document drawer is generic for the stock types: header fields by type,
// a lines grid (item by code / barcode through item_lookup), totals and problems from the server, and the action
// buttons from the document's `actions` (doc_transitions), so the buttons always match what the server allows.
// Posting with W_STOCK_NEGATIVE warnings opens a dialog; "Post anyway" posts again with ack_warnings = true.
var STOCK_TYPES = ['OPN', 'GRN', 'ADJ_IN', 'ADJ_OUT', 'CONS'];
var STK = {tab: null, rows: [], next: null, seq: 0, f: {q: '', wh: '', only: '', type: '', state: ''}, whs: null, types: null, sups: null};
var DOC_FORM = {   // type -> header fields and line columns
  OPN: {head: ['warehouse', 'date', 'notes'], price: 'cost'},
  GRN: {head: ['warehouse', 'date', 'supplier', 'ext_number', 'ext_date', 'mark', 'notes'], price: 'cost', discount: true},
  ADJ_IN: {head: ['warehouse', 'date', 'reason', 'notes'], price: 'cost_optional', reasons: ['found', 'correction']},
  ADJ_OUT: {head: ['warehouse', 'date', 'reason', 'notes'], reasons: ['damaged', 'expired', 'lost', 'correction']},
  CONS: {head: ['warehouse', 'date', 'cost_centre', 'ext_ref', 'notes'], lineRef: true},
  TRF: {head: ['warehouse', 'dest', 'date', 'delivery', 'notes']},   // T18 (35_transfers.js): source, destination, no price
  // T20 (40_expenses.js): no warehouse; lines = category / description / net / VAT class (expLineRow, expReadLines)
  EXP: {head: ['branch', 'date', 'supplier', 'ext_number', 'ext_date', 'mark', 'paid', 'cost_centre', 'notes'], price: 'net', expense: true}
};
function docCap(type, kind) { var p = {OPN: 'opn', GRN: 'grn', ADJ_IN: 'adj', ADJ_OUT: 'adj', CONS: 'cons', TRF: 'trf', EXP: 'exp'}[type]; return 'doc.' + p + '.' + kind; }
function stockReadTypes() { return STOCK_TYPES.filter(function (x) { return can(docCap(x, 'read')); }); }
function qtyTxt(n) { var v = Number(n); return isNaN(v) ? '' : v.toLocaleString('en-GB', {maximumFractionDigits: 4}); }
function stateBadge(st) { return '<span class="badge ' + ({posted: 'good', draft: '', pending_approval: 'warn', cancelled: 'bad', dispatched: 'warn', received: 'good', received_with_difference: 'warn', closed: 'good'}[st] || '') + '">' + esc(t('doc.state.' + st)) + '</span>'; }
async function stkWarehouses() {
  if (STK.whs) return STK.whs;
  var r = await api('warehouse_list', {p_filter: {}, p_limit: 500});
  STK.whs = r.ok && r.data ? r.data.rows : [];
  return STK.whs;
}
async function stkSuppliers() {
  if (STK.sups) return STK.sups;
  var r = can('counterparty.read') ? await api('counterparty_list', {p_filter: {kind: 'supplier'}, p_limit: 200}) : {ok: false};
  STK.sups = r.ok && r.data ? r.data.rows : [];
  return STK.sups;
}
var STK_TABS = [
  {id: 'onhand', label: 'stk.tab.onhand', caps: ['stock.read']},
  {id: 'documents', label: 'stk.tab.documents', caps: ['doc.opn.read', 'doc.grn.read', 'doc.adj.read', 'doc.cons.read']},
  {id: 'negative', label: 'stk.tab.negative', caps: ['stock.read']},
  {id: 'alerts', label: 'stk.tab.alerts', caps: ['alert.read']}
];
screen({id: 'stock', nav: 'nav.stock', caps: ['stock.read', 'doc.opn.read', 'doc.grn.read', 'doc.adj.read', 'doc.cons.read'],
  render: function (sub) {
    var tabs = STK_TABS.filter(function (x) { return canAny(x.caps); }), want = sub[0];
    STK.tab = tabs.some(function (x) { return x.id === want; }) ? want : tabs[0].id; STK.rows = []; STK.next = null;
    return '<h1>' + esc(t('stk.title')) + '</h1><div class="tabs" id="stk-tabs">' + tabs.map(function (x) {
      return '<a href="#/stock/' + x.id + '" data-act="go" data-to="stock" data-sub="' + x.id + '" class="' + (x.id === STK.tab ? 'on' : '') + '">' + esc(t(x.label)) + '</a>';
    }).join('') + '</div><div id="stk-bar" class="row" style="margin-bottom:10px"></div><div id="stk-body"><p class="muted">' + esc(t('app.loading')) + '</p></div>';
  },
  mount: async function () { await stkBar(); stkLoad(true); }
});
function stkBody(h) { var el = $('stk-body'); if (el) el.innerHTML = h; }
async function stkBar() {
  var bar = $('stk-bar'); if (!bar) return;
  var h = '';
  if (STK.tab === 'onhand' || STK.tab === 'negative') {
    var whs = await stkWarehouses();
    h += sel('stk-wh', [['', t('stk.all_warehouses')]].concat(whs.map(function (w) { return [w.warehouse_id, w.code + ' · ' + w.name]; })), STK.f.wh).replace('<select', '<select style="width:auto"');
  }
  if (STK.tab === 'onhand') {
    h += '<input id="stk-q" style="max-width:260px" placeholder="' + esc(t('stk.search')) + '" value="' + esc(STK.f.q) + '">' +
      sel('stk-only', [['', t('stk.only.all')], ['low', t('stk.only.low')], ['negative', t('stk.only.negative')]], STK.f.only).replace('<select', '<select style="width:auto"');
  }
  if (STK.tab === 'documents') {
    var types = stockReadTypes();
    h += sel('stk-type', [['', t('stk.all_types')]].concat(types.map(function (x) { return [x, t('doc.type.' + x)]; })), STK.f.type).replace('<select', '<select style="width:auto"') +
      sel('stk-state', [['', t('stk.all_states')], ['draft', t('doc.state.draft')], ['pending_approval', t('doc.state.pending_approval')], ['posted', t('doc.state.posted')],
                        ['cancelled', t('doc.state.cancelled')]], STK.f.state).replace('<select', '<select style="width:auto"') +
      '<span class="grow"></span>' + (can('doc.opn.create') ? '<button id="stk-import" data-act="stk-opn-import">' + esc(t('stk.opn_import')) + '</button>' : '');
    var creatable = STOCK_TYPES.filter(function (x) { return can(docCap(x, 'create')); });
    if (creatable.length) h += sel('stk-newtype', creatable.map(function (x) { return [x, t('doc.type.' + x)]; }), creatable[creatable.length - 1]).replace('<select', '<select style="width:auto"') +
      '<button class="primary" id="stk-new" data-act="stk-new">' + esc(t('stk.new_doc')) + '</button>';
  }
  bar.innerHTML = h;
}
document.addEventListener('change', function (e) {
  var id = e.target.id;
  if (id === 'stk-wh') { STK.f.wh = e.target.value; stkLoad(true); }
  else if (id === 'stk-only') { STK.f.only = e.target.value; stkLoad(true); }
  else if (id === 'stk-type') { STK.f.type = e.target.value; stkLoad(true); }
  else if (id === 'stk-state') { STK.f.state = e.target.value; stkLoad(true); }
});
var stkqTimer = null;
document.addEventListener('input', function (e) {
  if (e.target.id !== 'stk-q') return;
  clearTimeout(stkqTimer); var v = e.target.value.trim();
  stkqTimer = setTimeout(function () { STK.f.q = v; stkLoad(true); }, 300);
});
function stkCall() {
  if (STK.tab === 'onhand') {
    var f = {}; if (STK.f.wh) f.warehouse_id = STK.f.wh; if (STK.f.q) f.q = STK.f.q; if (STK.f.only) f.only = STK.f.only;
    return ['stock_on_hand', {p_filter: f, p_limit: 50}];
  }
  if (STK.tab === 'documents') {
    var g = STK.f.type ? {doc_type: STK.f.type} : {doc_types: stockReadTypes()}; if (STK.f.state) g.state = STK.f.state;
    return ['doc_list', {p_filter: g, p_limit: 50}];
  }
  if (STK.tab === 'negative') return ['report_negative_stock', {p_filter: STK.f.wh ? {warehouse_id: STK.f.wh} : {}, p_limit: 100}];
  return ['alert_list', {p_filter: {}, p_limit: 50}];
}
async function stkLoad(reset) {
  if (!$('stk-body')) { if ($('trf-body')) trfLoad(true); else if ($('exp-body')) expLoad(true); return; }   // the drawer is shared with Transfers / Expenses
  var my = ++STK.seq, c = stkCall(), tab = STK.tab;
  c[1].p_cursor = reset ? null : STK.next;
  var r = await api(c[0], c[1]);
  if (my !== STK.seq || STK.tab !== tab) return;
  if (!r.ok) { stkBody('<div class="msg bad">' + esc(r.error.text) + '</div>'); return; }
  STK.rows = (reset ? [] : STK.rows).concat(r.data.rows || []); STK.next = r.data.next;
  var focus = document.activeElement && document.activeElement.id === 'stk-q';
  stkBody(stkView());
  if (focus) { var q = $('stk-q'); q.focus(); q.setSelectionRange(q.value.length, q.value.length); }
}
ACT['stk-more'] = function () { stkLoad(false); };
function tbl(id, heads, rows, empty) {
  return '<div class="tbl-wrap"><table id="' + id + '"><thead><tr>' + heads.map(function (h) { return '<th>' + esc(t(h)) + '</th>'; }).join('') + '</tr></thead><tbody>' +
    (rows.length ? rows.join('') : '<tr><td colspan="' + heads.length + '" class="empty">' + esc(t(empty || 'list.empty')) + '</td></tr>') + '</tbody></table></div>';
}
function qtyCell(r) {
  return '<span class="' + (r.negative ? 'neg' : '') + '">' + esc(qtyTxt(r.qty)) + '</span>' + (r.negative ? ' <span class="badge bad">' + esc(t('stk.negative')) + '</span>' : '') +
    (r.low ? ' <span class="badge warn">' + esc(t('stk.low')) + '</span>' : '');
}
function stkView() {
  var cst = can('cost.read'), h;
  if (STK.tab === 'onhand') {
    h = tbl('stk-table', ['stk.col.item', 'stk.col.name', 'stk.col.warehouse', 'stk.col.qty', 'stk.col.available'].concat(cst ? ['stk.col.avg_cost', 'stk.col.value'] : []),
      STK.rows.map(function (r) {
        return '<tr class="click" data-act="stk-card" data-item="' + esc(r.item_id) + '" data-wh="' + esc(r.warehouse_id) + '"><td>' + esc(r.item_code) + '</td><td>' + esc(r.item_name) +
          '</td><td>' + esc(r.warehouse_code) + '</td><td>' + qtyCell(r) + ' ' + esc(r.unit_code) + '</td><td>' + esc(qtyTxt(r.available)) + '</td>' +
          (cst ? '<td>' + esc(eur(r.avg_cost)) + '</td><td>' + esc(eur(r.value)) + '</td>' : '') + '</tr>';
      }));
  } else if (STK.tab === 'documents') {
    h = tbl('stk-table', ['stk.col.date', 'stk.col.type', 'stk.col.number', 'stk.col.warehouse', 'stk.col.counterparty', 'stk.col.state', 'stk.col.total'], STK.rows.map(function (d) {
      var total = d.total_cost != null && d.state === 'posted' ? d.total_cost : d.total_net;
      return '<tr class="click" data-act="stk-doc" data-id="' + esc(d.document_id) + '"><td>' + esc(fmtDate(d.doc_date)) + '</td><td>' + esc(t('doc.type.' + d.doc_type)) + '</td><td>' +
        esc(d.doc_no || '') + '</td><td>' + esc(d.warehouse_code || '') + '</td><td>' + esc(d.counterparty_name || '') + '</td><td>' + stateBadge(d.state) + '</td><td>' +
        esc(total != null && (cst || d.doc_type === 'GRN' || d.doc_type === 'OPN' || d.doc_type === 'ADJ_IN') ? eur(total) : '') + '</td></tr>';
    }));
  } else if (STK.tab === 'negative') {
    h = tbl('stk-table', ['stk.col.item', 'stk.col.name', 'stk.col.warehouse', 'stk.col.qty', 'stk.col.since', 'stk.col.cause'].concat(cst ? ['stk.col.provisional'] : []),
      STK.rows.map(function (r) {
        return '<tr class="click" data-act="stk-card" data-item="' + esc(r.item_id) + '" data-wh="' + esc(r.warehouse_id) + '"><td>' + esc(r.item_code) + '</td><td>' + esc(r.item_name) +
          '</td><td>' + esc(r.warehouse_code) + '</td><td>' + qtyCell({qty: r.qty, negative: true}) + '</td><td>' + esc(t('stk.days', {n: r.days_negative})) + '</td><td>' +
          esc((r.doc_no || '') + (r.posted_by_email ? ' · ' + r.posted_by_email : '')) + '</td>' + (cst ? '<td>' + esc(eur(r.provisional_value)) + '</td>' : '') + '</tr>';
      }), 'stk.no_negative');
  } else {
    h = tbl('stk-table', ['stk.col.when', 'stk.col.alert', 'stk.col.detail', ''], STK.rows.map(function (a) {
      var p = a.params || {};
      return '<tr><td>' + esc(fmtDate(a.created_at)) + '</td><td><span class="badge ' + (a.severity === 'critical' ? 'bad' : a.severity === 'warning' ? 'warn' : '') + '">' +
        esc(t('alert.kind.' + a.kind)) + '</span></td><td>' + esc(t(a.message_key, p)) + '</td><td>' +
        (a.can_resolve ? '<button data-act="stk-resolve" data-id="' + esc(a.alert_id) + '">' + esc(t('stk.resolve')) + '</button>' : '') + '</td></tr>';
    }), 'stk.no_alerts');
  }
  return h + (STK.next ? '<div class="row end" style="margin-top:10px"><button id="stk-more" data-act="stk-more">' + esc(t('list.more')) + '</button></div>' : '');
}
ACT['stk-resolve'] = async function (el) {
  el.disabled = true;
  var r = await api('alert_resolve', {p_alert_id: el.getAttribute('data-id')}, {write: true});
  if (!r.ok) { el.disabled = false; toast(notSaved(r)); return; }
  toast(t('stk.resolved')); stkLoad(true);
};

/* ---------- stock card (drawer, read-only) ---------- */
ACT['stk-card'] = async function (el) {
  var item = el.getAttribute('data-item'), wh = el.getAttribute('data-wh');
  var r = await api('stock_card', {p_item_id: item, p_filter: wh ? {warehouse_id: wh} : {}, p_limit: 200});
  if (!r.ok) { toast(r.error.text); return; }
  var cst = can('cost.read'), d = r.data;
  drawerOpen({title: t('stk.card_title', {item: d.item.code + ' · ' + d.item.name}), readOnly: true, body: function () {
    return '<p class="muted">' + esc(t('stk.card_opening', {qty: qtyTxt(d.opening_qty)})) + '</p>' +
      tbl('card-table', ['stk.col.date', 'stk.col.number', 'stk.col.warehouse', 'stk.col.qty', 'stk.col.running'].concat(cst ? ['stk.col.value'] : []), (d.rows || []).map(function (m) {
        return '<tr><td>' + esc(fmtDate(m.move_date)) + '</td><td>' + esc(t('doc.type.' + m.doc_type)) + ' ' + esc(m.doc_no || '') + (m.kind !== 'normal' ? ' <span class="badge">' + esc(t('stk.kind.' + m.kind)) + '</span>' : '') +
          '</td><td>' + esc(m.warehouse_code) + '</td><td>' + esc(qtyTxt(m.qty)) + '</td><td class="' + (Number(m.running_qty) < 0 ? 'neg' : '') + '">' + esc(qtyTxt(m.running_qty)) + '</td>' +
          (cst ? '<td>' + esc(eur(m.value)) + (m.provisional ? ' <span class="badge warn">' + esc(t('stk.provisional')) + '</span>' : '') + '</td>' : '') + '</tr>';
      })) + (d.next ? '<p class="muted">' + esc(t('stk.card_more')) + '</p>' : '');
  }});
};

/* ---------- document drawer ---------- */
ACT['stk-new'] = async function () {
  var type = val('stk-newtype'); if (!type) return;
  await stkWarehouses(); if (type === 'GRN') await stkSuppliers();
  var whs = (STK.whs || []);
  docDrawer({doc_type: type, state: 'draft', lines: [], extra: {}, can_edit: true, actions: [], problems: [], warehouse_id: whs.length === 1 ? whs[0].warehouse_id : '', doc_date: S.me.today});
};
ACT['stk-doc'] = async function (el) {
  var r = await api('doc_get', {p_document_id: el.getAttribute('data-id')});
  if (!r.ok) { toast(r.error.text); return; }
  await stkWarehouses(); if (r.data.doc_type === 'GRN') await stkSuppliers();
  docDrawer(r.data);
};
function docLineRow(l, i, form, ro) {
  if (form.expense) return expLineRow(l, i, ro);
  return '<div class="dline" data-i="' + i + '">' +
    '<div class="dl-item"><input class="dl-code" placeholder="' + esc(t('doc.f.item')) + '" value="' + esc(l.item_code || '') + '"' + (ro ? ' disabled' : '') + '>' +
    '<span class="muted dl-name">' + esc(l.item_name || '') + (l.on_hand != null ? ' · ' + esc(t('doc.on_hand', {qty: qtyTxt(l.on_hand)})) : '') + '</span></div>' +
    '<input class="dl-qty" inputmode="decimal" placeholder="' + esc(t('doc.f.qty')) + '" value="' + esc(l.qty != null ? qtyTxt(l.qty).replace(/,/g, '') : '') + '"' + (ro ? ' disabled' : '') + '>' +
    (form.price ? '<input class="dl-price" inputmode="decimal" placeholder="' + esc(t(form.price === 'cost_optional' ? 'doc.f.cost_optional' : 'doc.f.unit_cost')) + '" value="' +
      esc(l.unit_price != null ? Number(l.unit_price) : '') + '"' + (ro ? ' disabled' : '') + '>' : '') +
    (form.discount ? '<input class="dl-disc" inputmode="decimal" placeholder="' + esc(t('doc.f.discount')) + '" value="' + esc(l.discount_pct && Number(l.discount_pct) ? Number(l.discount_pct) : '') + '"' + (ro ? ' disabled' : '') + '>' : '') +
    (form.lineRef ? '<input class="dl-ref" placeholder="' + esc(t('doc.f.line_ref')) + '" value="' + esc(l.ext_line_ref || '') + '"' + (ro ? ' disabled' : '') + '>' : '') +
    '<span class="dl-amt">' + (l.net != null && form.price ? esc(eur(l.net)) : '') + (l.cost_value != null ? ' <span class="muted">' + esc(t('doc.cost', {v: eur(l.cost_value)})) + '</span>' : '') + '</span>' +
    (ro ? '' : '<button class="link dl-del" data-act="doc-line-del" data-i="' + i + '" title="' + esc(t('doc.remove_line')) + '">✕</button>') +
    '<input type="hidden" class="dl-id" value="' + esc(l.item_id || '') + '"><input type="hidden" class="dl-src" value="' + esc(l.source_line_id || '') + '"></div>';
}
function docHead(d, form, ro) {
  var whs = (STK.whs || []).map(function (w) { return [w.warehouse_id, w.code + ' · ' + w.name]; }), h = '';
  var own = d.source !== 'system' && (!d.warehouse_id || (STK.whs || []).some(function (w) { return w.warehouse_id === d.warehouse_id; }));
  form.head.forEach(function (f) {
    if (f === 'warehouse' && !own) h += field('d-wh-ro', d.source === 'system' && d.doc_type === 'ADJ_OUT' ? 'doc.f.warehouse_transit' : (d.doc_type === 'TRF' ? 'trf.f.source' : 'doc.f.warehouse'),
      inp('d-wh-ro', d.warehouse_code || '', 'text', true));
    else if (f === 'warehouse') h += field('d-wh', d.doc_type === 'TRF' ? 'trf.f.source' : 'doc.f.warehouse', sel('d-wh', [['', t('md.choose')]].concat(whs), d.warehouse_id || '', ro));
    else if (f === 'dest') h += trfDestField(d, ro);
    else if (f === 'branch') h += expBranchField(d, ro);
    else if (f === 'paid') h += expPaidFields(d, ro);
    else if (f === 'delivery') h += trfDeliveryFields(d, ro);
    else if (f === 'date') h += field('d-date', 'doc.f.date', inp('d-date', fmtDate(d.doc_date), 'text', ro));
    else if (f === 'supplier') h += field('d-cp', 'doc.f.supplier', sel('d-cp', [['', t('md.choose')]].concat((STK.sups || []).map(function (c) { return [c.counterparty_id, c.name]; })), d.counterparty_id || '', ro));
    else if (f === 'ext_number') h += field('d-extno', 'doc.f.ext_number', inp('d-extno', d.ext_number, 'text', ro));
    else if (f === 'ext_date') h += field('d-extdate', 'doc.f.ext_date', inp('d-extdate', fmtDate(d.ext_date), 'text', ro));
    else if (f === 'mark') h += field('d-mark', 'doc.f.mark', inp('d-mark', (d.extra || {}).mark, 'text', ro));
    else if (f === 'reason') h += field('d-reason', 'doc.f.reason', sel('d-reason', [['', t('md.choose')]].concat(form.reasons.map(function (x) { return [x, t('doc.reason.' + x)]; })), (d.extra || {}).reason || '', ro));
    else if (f === 'cost_centre') h += field('d-cc', 'doc.f.cost_centre', inp('d-cc', (d.extra || {}).cost_centre, 'text', ro));
    else if (f === 'ext_ref') h += field('d-extref', 'doc.f.ext_ref', inp('d-extref', d.ext_ref, 'text', ro));
    else if (f === 'notes') h += field('d-notes', 'doc.f.notes', inp('d-notes', d.notes, 'text', ro));
  });
  return h;
}
var DOCD = null;   // the open document drawer: {doc, form, lines}
function docDrawer(d) {
  var form = DOC_FORM[d.doc_type], ro = !d.can_edit, sys = d.source === 'system', lro = ro || sys;   // generated ADJ: items / quantities fixed
  DOCD = {doc: d, form: form, lines: (d.lines || []).map(function (l) { return Object.assign({}, l); })};
  if (!lro && !DOCD.lines.length) DOCD.lines.push({});
  var recv = false, acts = (d.actions || []).map(function (a) {
    if (a.action === 'receive') { if (recv) return ''; recv = true; return '<button class="primary" data-act="trf-receive">' + esc(t('trf.confirm_receipt')) + '</button>'; }   // one form, by line
    return '<button class="' + (a.action === 'post' || a.action === 'close' ? 'primary' : '') + '" data-act="doc-action" data-to="' + esc(a.to_state) + '">' + esc(t(a.label)) + '</button>';
  }).join('');
  drawerOpen({title: t('doc.type.' + d.doc_type) + (d.doc_no ? ' ' + d.doc_no : ''), readOnly: ro,
    extra: (d.document_id && d.state === 'draft' && d.can_edit && !sys ? '<button data-act="doc-delete">' + esc(t('doc.delete')) + '</button>' : '') +
      (d.document_id && !sys && can(docCap(d.doc_type, 'create')) ? '<button data-act="doc-copy">' + esc(t('doc.copy')) + '</button>' : '') + acts,
    body: function () {
      var probs = (d.problems || []).length ? '<ul class="problems" id="doc-problems">' + d.problems.map(function (p) {
        return '<li>' + esc((p.line_no ? t('doc.line_n', {n: p.line_no}) + ': ' : '') + p.message) + '</li>'; }).join('') + '</ul>' : '';
      return '<p>' + stateBadge(d.state || 'draft') + (d.cancel_reason ? ' <span class="muted">' + esc(d.cancel_reason) + '</span>' : '') + '</p>' +
        (sys && d.ref_document_id ? '<p class="msg" id="doc-sys-note">' + esc(t('doc.system_note')) + '</p>' : '') + docHead(d, form, ro) +
        '<h2 style="margin-top:14px">' + esc(t('doc.lines')) + '</h2><div id="doc-lines">' + DOCD.lines.map(function (l, i) { return docLineRow(l, i, form, lro); }).join('') + '</div>' +
        (lro ? '' : '<button class="link" data-act="doc-line-add" id="doc-line-add">' + esc(t('doc.add_line')) + '</button>') +
        (d.doc_type === 'TRF' ? trfSection(d) : '') +
        (d.document_id && form.price ? (form.expense ? expTotals(d) : '<p id="doc-totals"><b>' + esc(t('doc.total_net', {v: eur(d.total_net)})) + '</b></p>') : '') +
        (d.total_cost != null && d.state === 'posted' ? '<p class="muted">' + esc(t('doc.total_cost', {v: eur(d.total_cost)})) + '</p>' : '') +
        (probs ? '<div class="msg" id="doc-problem-box">' + esc(t('doc.problems')) + probs + '</div>' : '');
    },
    save: ro ? null : function () { return api('doc_save_draft', {p_type: d.doc_type, p_doc: docPayload()}, {write: true, key: D.key}); },
    onSaved: function (doc) { if (doc.doc_type === 'TRF') trfOpen(doc.document_id); else docDrawer(doc); stkLoad(true); }});
}
function docReadLines() {
  if (DOCD.form.expense) return expReadLines();
  var rows = document.querySelectorAll('#doc-lines .dline');
  DOCD.lines = Array.prototype.map.call(rows, function (r, i) {
    var o = DOCD.lines[i] || {}, q = function (c) { var e = r.querySelector(c); return e ? e.value.trim() : ''; };
    o.item_code = q('.dl-code'); o.item_id = q('.dl-id') || null; o.qty = q('.dl-qty').replace(',', '.'); o.source_line_id = q('.dl-src') || null;
    if (r.querySelector('.dl-price')) o.unit_price = q('.dl-price').replace(',', '.');
    if (r.querySelector('.dl-disc')) o.discount_pct = q('.dl-disc').replace(',', '.');
    if (r.querySelector('.dl-ref')) o.ext_line_ref = q('.dl-ref');
    return o;
  });
  return DOCD.lines;
}
function docPayload() {
  var d = DOCD.doc, form = DOCD.form, p = {}, extra = {};
  if (d.document_id) { p.document_id = d.document_id; p.version = d.version; }
  var wh = (STK.whs || []).find(function (w) { return w.warehouse_id === val('d-wh'); });
  p.warehouse_id = $('d-wh') ? (val('d-wh') || null) : (d.warehouse_id || null);
  p.branch_id = wh ? wh.branch_id : (d.branch_id || (S.me.branches[0] || {}).branch_id || null);
  if ($('d-branch')) p.branch_id = val('d-branch') || null;
  if ($('d-dest')) p.dest_warehouse_id = val('d-dest') || null;
  if ($('d-carrier')) { var dl = {carrier: val('d-carrier').trim(), vehicle: val('d-vehicle').trim()}; if (!dl.carrier) delete dl.carrier; if (!dl.vehicle) delete dl.vehicle; extra.delivery = dl; }
  var dt = parseDate(val('d-date')); if (dt) p.doc_date = dt;
  if ($('d-cp')) p.counterparty_id = val('d-cp') || null;
  if ($('d-extno')) p.ext_number = val('d-extno').trim();
  if ($('d-extdate')) p.ext_date = parseDate(val('d-extdate')) || null;
  if ($('d-mark') && val('d-mark').trim()) extra.mark = val('d-mark').trim();
  if ($('d-reason') && val('d-reason')) extra.reason = val('d-reason');
  if ($('d-cc') && val('d-cc').trim()) extra.cost_centre = val('d-cc').trim();
  if ($('d-paid')) { extra.paid = $('d-paid').checked; if (extra.paid && val('d-pm')) extra.payment_method = val('d-pm'); }
  if ($('d-extref')) p.ext_ref = val('d-extref').trim();
  if ($('d-notes')) p.notes = val('d-notes').trim();
  if (form.head.some(function (f) { return f === 'mark' || f === 'reason' || f === 'cost_centre' || f === 'paid'; })) p.extra = extra;
  if (form.head.indexOf('delivery') >= 0) { if (Object.keys(extra.delivery || {}).length) p.extra = {delivery: extra.delivery}; else p.extra = {}; }
  if (form.expense) { p.lines = expPayloadLines(docReadLines()); return p; }
  p.lines = docReadLines().filter(function (l) { return l.item_id || l.qty; }).map(function (l) {
    var o = {item_id: l.item_id, qty: l.qty};
    if (l.unit_price !== undefined && l.unit_price !== '') o.unit_price = l.unit_price;
    if (l.discount_pct) o.discount_pct = l.discount_pct;
    if (l.ext_line_ref) o.ext_line_ref = l.ext_line_ref;
    if (l.source_line_id) o.source_line_id = l.source_line_id;
    if (l.description) o.description = l.description;
    return o;
  });
  return p;
}
ACT['doc-line-add'] = function () {
  docReadLines(); DOCD.lines.push({});
  var box = $('doc-lines'); box.insertAdjacentHTML('beforeend', docLineRow({}, DOCD.lines.length - 1, DOCD.form, false));
  var last = box.querySelectorAll('.dline'), f = last.length ? last[last.length - 1].querySelector('input,select') : null; if (f) f.focus();
  if (D) D.dirty = true;
};
ACT['doc-line-del'] = function (el) {
  docReadLines(); DOCD.lines.splice(Number(el.getAttribute('data-i')), 1);
  $('doc-lines').innerHTML = DOCD.lines.map(function (l, i) { return docLineRow(l, i, DOCD.form, false); }).join('');
  if (D) D.dirty = true;
};
// item by code / barcode: the first lookup match fills the line (name, unit, on hand of the chosen warehouse)
document.addEventListener('change', async function (e) {
  if (!e.target.classList || !e.target.classList.contains('dl-code') || !DOCD) return;
  var row = e.target.closest('.dline'), q = e.target.value.trim(); if (!q) return;
  var r = await api('item_lookup', {p_query: q, p_warehouse_id: val('d-wh') || null, p_limit: 5});
  if (!row.isConnected) return;
  var hit = r.ok && r.data && r.data.rows.length ? (r.data.rows.find(function (x) { return x.barcode_match || x.code.toLowerCase() === q.toLowerCase(); }) || r.data.rows[0]) : null;
  row.querySelector('.dl-id').value = hit ? hit.item_id : '';
  row.querySelector('.dl-name').textContent = hit ? hit.name + ' · ' + t('doc.on_hand', {qty: qtyTxt(hit.on_hand)}) : t('doc.no_item');
  if (hit) e.target.value = hit.code;
});
async function docSaveIfDirty() {
  if (!D || !D.dirty || !DOCD.doc.can_edit) return {ok: true, data: DOCD.doc};
  var r = await api('doc_save_draft', {p_type: DOCD.doc.doc_type, p_doc: docPayload()}, {write: true, key: D.key});
  if (r.ok && r.data) { D.dirty = false; D.key = uuid(); DOCD.doc = r.data; }
  return r;
}
function docShow(doc, msg) { drawerClose(true); if (doc.doc_type === 'TRF') trfOpen(doc.document_id); else docDrawer(doc); if (msg) toast(msg); stkLoad(true); }
async function docAct(to, opts) {
  var btns = document.querySelectorAll('#drawer footer button'); Array.prototype.forEach.call(btns, function (b) { b.disabled = true; });
  var s = await docSaveIfDirty();
  if (!s.ok || !s.data) { Array.prototype.forEach.call(btns, function (b) { b.disabled = false; }); drawerMsg(notSaved(s), s.error && Array.isArray(s.error.detail) ? s.error.detail : null); return; }
  var r = await api('doc_set_state', {p_document_id: DOCD.doc.document_id, p_to_state: to, p_options: opts || {}}, {write: true});
  Array.prototype.forEach.call(btns, function (b) { b.disabled = false; });
  if (!r.ok || !r.data) { drawerMsg(notSaved(r), r.error && Array.isArray(r.error.detail) ? r.error.detail : null); return; }
  var warnTxt = (r.data.warnings || []).map(function (x) { return t('doc.warn.negative', {item: x.item_code, wh: x.warehouse_code, qty: qtyTxt(x.qty_after)}); }).join(' ');
  if ((to === 'posted' || to === 'dispatched') && !r.data.posted && warnTxt) {   // negative stock: ask, then post / dispatch with ack
    confirmBox(t('doc.warn.title') + ' ' + warnTxt, t(to === 'dispatched' ? 'trf.dispatch_anyway' : 'doc.warn.post_anyway'), t('cancel'), function () { docAct(to, Object.assign({}, opts || {}, {ack_warnings: true})); });
    return;
  }
  // F2-12: a cancel that took stock below zero went ahead (audited, alert raised): say so
  docShow(r.data.document, t('doc.done.' + to) + (to === 'cancelled' && warnTxt ? ' ' + t('doc.warn.after_cancel') + ' ' + warnTxt : ''));
}
ACT['doc-action'] = function (el) {
  var to = el.getAttribute('data-to');
  if (to === 'cancelled') { promptBox(t(DOCD.doc.doc_type === 'TRF' ? 'trf.cancel_q' : 'doc.cancel_q'), t('doc.f.reason_text'), t('doc.action.cancel'), function (v) { docAct('cancelled', {reason: v}); }, true); return; }
  if (to === 'draft') { promptBox(t('doc.reject_q'), t('doc.f.reason_text'), t('doc.action.reject'), function (v) { docAct('draft', {reason: v}); }, false); return; }
  docAct(to, {});
};
ACT['doc-delete'] = function () {
  confirmBox(t('doc.delete_q'), t('doc.delete'), t('cancel'), async function () {
    var r = await api('doc_delete_draft', {p_document_id: DOCD.doc.document_id}, {write: true});
    if (!r.ok) { drawerMsg(notSaved(r)); return; }
    drawerClose(true); toast(t('doc.deleted')); stkLoad(true);
  });
};
ACT['doc-copy'] = function () {
  guardDrawer(async function () {
    var r = await api('doc_copy', {p_document_id: DOCD.doc.document_id}, {write: true});
    if (!r.ok || !r.data) { toast(notSaved(r)); return; }
    await stkWarehouses(); docDrawer(r.data); toast(t('doc.copied')); stkLoad(true);
  });
};

/* ---------- opening-stock import (OPN draft) ---------- */
ACT['stk-opn-import'] = async function () {
  var whs = await stkWarehouses(), checked = null;
  drawerOpen({title: t('stk.opn_import'),
    extra: '<button id="opn-check" data-act="opn-check">' + esc(t('imp.check')) + '</button><button class="primary" id="opn-run" data-act="opn-run" disabled>' + esc(t('imp.run')) + '</button>',
    body: function () {
      return '<p class="muted">' + esc(t('stk.opn_lead')) + '</p>' + field('opn-wh', 'doc.f.warehouse', sel('opn-wh', [['', t('md.choose')]].concat(whs.map(function (w) { return [w.warehouse_id, w.code + ' · ' + w.name]; })), '')) +
        '<label for="imp-text">' + esc(t('imp.text')) + '</label><textarea id="imp-text" rows="8" spellcheck="false"></textarea><div id="imp-out"></div>';
    }});
  D.opn = {checked: null};
};
async function opnCall(dry) {
  var text = val('imp-text'), parsed = csvObjects(text, ['item', 'qty', 'unit_cost']), wh = (STK.whs || []).find(function (w) { return w.warehouse_id === val('opn-wh'); });
  var out = $('imp-out');
  if (!wh) { out.innerHTML = '<div class="msg bad">' + esc(t('stk.choose_wh')) + '</div>'; return; }
  if (!parsed.rows.length) { out.innerHTML = '<div class="msg bad">' + esc(t('imp.empty')) + '</div>'; return; }
  if (!dry && D.opn.checked !== text + '|' + wh.warehouse_id) return;
  $('opn-check').disabled = true; $('opn-run').disabled = true;
  var r = await api('opening_import', {p_doc: {branch_id: wh.branch_id, warehouse_id: wh.warehouse_id}, p_rows: parsed.rows, p_dry_run: dry}, {write: true});
  if (!D || !D.opn) return;
  $('opn-check').disabled = false;
  if (!r.ok || !r.data) { out.innerHTML = '<div class="msg bad">' + esc(notSaved(r)) + '</div>'; return; }
  impShow(Object.assign({created: r.data.rows, updated: 0}, r.data), parsed);
  if (dry && !(r.data.errors || []).length) { D.opn.checked = text + '|' + wh.warehouse_id; $('opn-run').disabled = false; $('imp-summary').textContent = t('stk.opn_clean', {rows: r.data.rows, v: eur(r.data.total_value)}); }
  if (!dry && r.data.document) { drawerClose(true); toast(t('stk.opn_done')); docDrawer(r.data.document); stkLoad(true); }
}
ACT['opn-check'] = function () { opnCall(true); };
ACT['opn-run'] = function () { opnCall(false); };
document.addEventListener('input', function (e) { if ((e.target.id === 'imp-text' || e.target.id === 'opn-wh') && D && D.opn) { D.opn.checked = null; var b = $('opn-run'); if (b) b.disabled = true; } });
document.addEventListener('change', function (e) { if (e.target.id === 'opn-wh' && D && D.opn) { D.opn.checked = null; var b = $('opn-run'); if (b) b.disabled = true; } });
