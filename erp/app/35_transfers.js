/* ---------- transfers: list, draft / dispatch / cancel, receipt by line (T18-lite) ---------- */
// The transfer drawer IS the stock document drawer (30_stock.js, DOC_FORM.TRF): header source / destination / date /
// delivery, lines by item code / barcode, server problems, buttons from `actions`, the negative-stock dialog on
// dispatch ("Dispatch anyway" = ack_warnings). This file adds the list, the destination picker (trf_warehouses: every
// branch), the transfer section (per-line dispatched / received / difference, generated adjustments, fiscal note)
// and the receipt form. The destination branch sees a transfer only once dispatched (server rule, STATE 72).
var TRF_STATES = ['draft', 'dispatched', 'received', 'received_with_difference', 'closed', 'cancelled'];
var TRF = {rows: [], next: null, seq: 0, f: {state: '', branch: ''}, whs: null};
async function trfWarehouses() {
  if (TRF.whs) return TRF.whs;
  var r = await api('trf_warehouses');
  TRF.whs = r.ok && r.data ? r.data.rows : [];
  return TRF.whs;
}
function trfWhLabel(id) { var w = (TRF.whs || []).find(function (x) { return x.warehouse_id === id; }); return w ? w.code : ''; }
screen({id: 'transfers', nav: 'nav.transfers', caps: ['doc.trf.read'],
  render: function () {
    TRF.rows = []; TRF.next = null;
    return '<h1>' + esc(t('trf.title')) + '</h1><div id="trf-bar" class="row" style="margin-bottom:10px"></div><div id="trf-body"><p class="muted">' + esc(t('app.loading')) + '</p></div>';
  },
  mount: async function () { await trfWarehouses(); trfBar(); trfLoad(true); }
});
function trfBar() {
  var bar = $('trf-bar'); if (!bar) return;
  var brs = (S.me.branches || []);
  bar.innerHTML = sel('trf-state', [['', t('stk.all_states')]].concat(TRF_STATES.map(function (x) { return [x, t('doc.state.' + x)]; })), TRF.f.state).replace('<select', '<select style="width:auto"') +
    (brs.length > 1 ? sel('trf-branch', [['', t('trf.all_branches')]].concat(brs.map(function (b) { return [b.branch_id, b.code + ' · ' + b.name]; })), TRF.f.branch).replace('<select', '<select style="width:auto"') : '') +
    '<span class="grow"></span>' + (can('doc.trf.create') ? '<button class="primary" id="trf-new" data-act="trf-new">' + esc(t('trf.new')) + '</button>' : '');
}
document.addEventListener('change', function (e) {
  if (e.target.id === 'trf-state') { TRF.f.state = e.target.value; trfLoad(true); }
  else if (e.target.id === 'trf-branch') { TRF.f.branch = e.target.value; trfLoad(true); }
});
async function trfLoad(reset) {
  var my = ++TRF.seq, f = {doc_type: 'TRF'};
  if (TRF.f.state) f.state = TRF.f.state; if (TRF.f.branch) f.branch_id = TRF.f.branch;
  var r = await api('doc_list', {p_filter: f, p_cursor: reset ? null : TRF.next, p_limit: 50});
  var body = $('trf-body'); if (my !== TRF.seq || !body) return;
  if (!r.ok) { body.innerHTML = '<div class="msg bad">' + esc(r.error.text) + '</div>'; return; }
  TRF.rows = (reset ? [] : TRF.rows).concat(r.data.rows || []); TRF.next = r.data.next;
  body.innerHTML = tbl('trf-table', ['stk.col.date', 'stk.col.number', 'trf.col.from', 'trf.col.to', 'trf.col.lines', 'stk.col.state'], TRF.rows.map(function (d) {
    return '<tr class="click" data-act="trf-open" data-id="' + esc(d.document_id) + '"><td>' + esc(fmtDate(d.doc_date)) + '</td><td>' + esc(d.doc_no || '') + '</td><td>' +
      esc(d.warehouse_code || '') + '</td><td>' + esc(trfWhLabel(d.dest_warehouse_id)) + '</td><td>' + esc(d.line_count != null ? d.line_count : '') + '</td><td>' + stateBadge(d.state) + '</td></tr>';
  }), 'trf.empty') + (TRF.next ? '<div class="row end" style="margin-top:10px"><button id="trf-more" data-act="trf-more">' + esc(t('list.more')) + '</button></div>' : '');
}
ACT['trf-more'] = function () { trfLoad(false); };
async function trfOpen(id) {
  var r = await api('trf_get', {p_document_id: id});
  if (!r.ok) { toast(r.error.text); return; }
  await stkWarehouses(); await trfWarehouses();
  if (D) drawerClose(true);
  docDrawer(r.data);
}
ACT['trf-open'] = function (el) { trfOpen(el.getAttribute('data-id')); };
ACT['trf-new'] = async function () {
  var whs = await stkWarehouses(); await trfWarehouses();
  docDrawer({doc_type: 'TRF', state: 'draft', lines: [], extra: {}, can_edit: true, actions: [], problems: [], warehouse_id: whs.length === 1 ? whs[0].warehouse_id : '', doc_date: S.me.today});
};

/* ---------- drawer parts (called by docHead / docDrawer in 30_stock.js) ---------- */
function trfDestField(d, ro) {
  if (ro) return field('d-dest-ro', 'trf.f.dest', inp('d-dest-ro', (d.transfer && d.transfer.dest_warehouse_code) || trfWhLabel(d.dest_warehouse_id), 'text', true));
  var opts = (TRF.whs || []).filter(function (w) { return w.active || w.warehouse_id === d.dest_warehouse_id; })
    .map(function (w) { return [w.warehouse_id, w.code + ' · ' + w.name + ' (' + w.branch_code + ')']; });
  return field('d-dest', 'trf.f.dest', sel('d-dest', [['', t('md.choose')]].concat(opts), d.dest_warehouse_id || '', false));
}
function trfDeliveryFields(d, ro) {
  var dl = (d.extra || {}).delivery || {};
  return field('d-carrier', 'trf.f.carrier', inp('d-carrier', dl.carrier, 'text', ro)) + field('d-vehicle', 'trf.f.vehicle', inp('d-vehicle', dl.vehicle, 'text', ro));
}
function trfSection(d) {
  var tr = d.transfer, h = '<div id="trf-info">';
  if (!tr) return '';
  h += '<p class="msg" id="trf-fiscal">' + esc(t('trf.fiscal_note')) + (tr.fiscal_needed ? ' ' + esc(t('trf.fiscal_needed')) : '') + '</p>';
  if (tr.receipt) h += '<p class="muted" id="trf-receipt">' + esc(t('trf.received_on', {date: fmtDate(tr.receipt.receipt_date), who: tr.receipt.received_by_email || ''})) +
    (tr.receipt.closed_at ? ' · ' + esc(t('trf.closed_on', {date: fmtDate(tr.receipt.closed_at)})) : '') + '</p>';
  if (d.state !== 'draft' && (tr.lines || []).length) {
    var byId = {}; (d.lines || []).forEach(function (l) { byId[l.line_id] = l; });
    h += '<h2 style="margin-top:14px">' + esc(t('trf.by_line')) + '</h2>' + tbl('trf-lines', ['stk.col.item', 'trf.col.dispatched', 'trf.col.received', 'trf.col.diff', 'trf.col.reason', 'trf.col.in_transit'],
      tr.lines.map(function (l) {
        var dl = byId[l.line_id] || {}, diff = Number(l.diff_qty || 0);
        return '<tr><td>' + esc(dl.item_code || '') + ' <span class="muted">' + esc(dl.item_name || '') + '</span></td><td>' + esc(qtyTxt(l.dispatched_qty)) + '</td><td>' +
          esc(l.received_qty != null ? qtyTxt(l.received_qty) : '') + '</td><td class="' + (diff < 0 ? 'neg' : '') + '">' + esc(l.received_qty != null && diff ? (diff > 0 ? '+' : '') + qtyTxt(diff) : '') +
          '</td><td>' + esc(l.diff_reason || '') + '</td><td>' + esc(qtyTxt(l.in_transit)) + '</td></tr>';
      }));
  }
  if ((tr.adjustments || []).length) {
    h += '<h2 style="margin-top:14px">' + esc(t('trf.adjustments')) + '</h2><ul id="trf-adjs">' + tr.adjustments.map(function (a) {
      return '<li><a href="#" class="link" data-act="stk-doc" data-id="' + esc(a.document_id) + '">' + esc(t('doc.type.' + a.doc_type)) + ' ' + esc(a.doc_no || t('trf.no_number')) + '</a> ' + stateBadge(a.state) + '</li>';
    }).join('') + '</ul>';
  }
  if (d.state === 'received_with_difference') h += '<p class="msg" id="trf-wait">' + esc(t('trf.closes_after_adj')) + '</p>';
  return h + '</div>';
}

/* ---------- receipt by line (destination branch; phone width) ---------- */
ACT['trf-receive'] = function () {
  var d = DOCD.doc, tr = d.transfer || {}, byId = {};
  (d.lines || []).forEach(function (l) { byId[l.line_id] = l; });
  var lines = (tr.lines || []).map(function (l) { return Object.assign({}, l, {item_code: (byId[l.line_id] || {}).item_code, item_name: (byId[l.line_id] || {}).item_name}); });
  drawerClose(true);
  drawerOpen({title: t('trf.receipt_title', {no: d.doc_no || ''}),
    extra: '<button class="primary" id="trf-receive-go" data-act="trf-receive-go">' + esc(t('trf.confirm_receipt')) + '</button>',
    body: function () {
      return '<p class="muted">' + esc(t('trf.receipt_lead', {from: d.warehouse_code || '', to: tr.dest_warehouse_code || ''})) + '</p>' +
        field('rc-date', 'trf.f.receipt_date', inp('rc-date', fmtDate(S.me.today), 'text')) + '<div id="rc-lines">' + lines.map(function (l) {
          return '<div class="dline rc-line" data-line="' + esc(l.line_id) + '" data-sent="' + esc(Number(l.dispatched_qty)) + '"><div class="dl-item"><b>' + esc(l.item_code || '') + '</b> ' +
            '<span class="muted dl-name">' + esc(l.item_name || '') + ' · ' + esc(t('trf.sent_qty', {qty: qtyTxt(l.dispatched_qty)})) + '</span></div>' +
            '<input class="dl-qty rc-qty" inputmode="decimal" aria-label="' + esc(t('trf.col.received')) + '" value="' + esc(Number(l.dispatched_qty)) + '">' +
            '<input class="rc-reason" placeholder="' + esc(t('trf.f.diff_reason')) + '" maxlength="200"></div>';
        }).join('') + '</div><p class="muted" id="rc-summary">' + esc(t('trf.receipt_same')) + '</p>';
    }});
  D.trf = {doc: d};
};
function trfReceiptRead() {
  var out = [], probs = [], diff = false;
  Array.prototype.forEach.call(document.querySelectorAll('#rc-lines .rc-line'), function (row, i) {
    var q = row.querySelector('.rc-qty').value.trim().replace(',', '.'), why = row.querySelector('.rc-reason').value.trim(), sent = Number(row.getAttribute('data-sent'));
    var n = q === '' ? NaN : Number(q);
    if (isNaN(n) || n < 0) { probs.push({message: t('doc.line_n', {n: i + 1}) + ': ' + t('trf.bad_qty')}); return; }
    var o = {line_id: row.getAttribute('data-line'), received_qty: q};
    if (n !== sent) { diff = true; if (!why) probs.push({message: t('doc.line_n', {n: i + 1}) + ': ' + t('trf.need_reason')}); else o.reason = why; }
    out.push(o);
  });
  return {lines: out, problems: probs, diff: diff};
}
document.addEventListener('input', function (e) {
  if (!D || !D.trf || !e.target.closest('#rc-lines')) return;
  var r = trfReceiptRead(), s = $('rc-summary'); if (s) s.textContent = t(r.diff ? 'trf.receipt_diff' : 'trf.receipt_same');
});
ACT['trf-receive-go'] = async function () {
  if (!D || !D.trf || D.busy) return;
  var d = D.trf.doc, r0 = trfReceiptRead(), rd = parseDate(val('rc-date'));
  if (!rd) r0.problems.push({message: t('trf.bad_date')});
  if (r0.problems.length) { drawerMsg(t('save.not_saved', {reason: t('err.ERP_VALIDATION')}), r0.problems); return; }
  var to = r0.diff ? 'received_with_difference' : 'received', b = $('trf-receive-go'), cur = D;
  D.busy = true; b.disabled = true; drawerMsg('');
  var r = await api('doc_set_state', {p_document_id: d.document_id, p_to_state: to, p_options: {receipt_date: rd, lines: r0.lines}}, {write: true, key: D.key});
  if (D !== cur) return;
  D.busy = false; b.disabled = false;
  if (!r.ok || !r.data) { drawerMsg(notSaved(r), r.error && Array.isArray(r.error.detail) ? r.error.detail : null); return; }
  drawerClose(true); toast(t('doc.done.' + to)); trfOpen(d.document_id); trfLoad(true);
};
