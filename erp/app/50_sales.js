/* ---------- sales: delivery notes, retail receipts (Draft 2, NON-FISCAL) ---------- */
// The sales drawer IS the stock document drawer (30_stock.js, DOC_FORM.DN / RR / RS): header warehouse or branch /
// date / customer (+ quick add) / delivery block / to be billed / payment method / delivery-note reference, lines by
// item code or barcode with quantity, sale price and VAT class (empty = the item's class; VAT and gross as the server
// computes them: per line, half up), server problems, buttons from `actions`, the negative-stock dialog on post, cancel
// with a reason. This file adds the menu with its two tabs, the sale line, the "lines from a delivery note" picker of a
// retail receipt and the print view (browser Print -> Save as PDF; every view carries "NOT A FISCAL DOCUMENT").
var SAL_TABS = [
  {id: 'dn', label: 'sal.tab.dn', caps: ['doc.dn.read'], types: ['DN']},
  {id: 'rr', label: 'sal.tab.rr', caps: ['doc.rr.read', 'doc.rs.read'], types: ['RR', 'RS']}
];
var SAL_STATES = ['draft', 'posted', 'cancelled'];
var SAL_METHODS = ['cash', 'card', 'bank', 'other'];
var SAL_REASONS = ['sale', 'sale_on_approval', 'sample', 'repair', 'return', 'other'];
var SAL = {tab: null, rows: [], next: null, seq: 0, f: {state: '', branch: '', q: ''}, custs: null, dns: null};
onLogin(function () { SAL.custs = null; SAL.dns = null; SAL.f = {state: '', branch: '', q: ''}; });
function salTabs() { return SAL_TABS.filter(function (x) { return canAny(x.caps); }); }
async function salCustomers(force) {
  if (SAL.custs && !force) return SAL.custs;
  var r = can('counterparty.read') ? await api('counterparty_list', {p_filter: {kind: 'customer'}, p_limit: 200}) : {ok: false};
  SAL.custs = r.ok && r.data ? r.data.rows.filter(function (c) { return c.kind !== 'supplier'; }) : [];
  return SAL.custs;
}
async function salPrep() { await Promise.all([stkWarehouses(), salCustomers(), can('vat.read') ? expVats() : null]); }
screen({id: 'sales', nav: 'nav.sales', caps: ['doc.dn.read', 'doc.rr.read', 'doc.rs.read'],
  render: function (sub) {
    var tabs = salTabs(), want = sub[0];
    SAL.tab = tabs.some(function (x) { return x.id === want; }) ? want : tabs[0].id; SAL.rows = []; SAL.next = null;
    return '<h1>' + esc(t('sal.title')) + '</h1><p class="msg" id="sal-nonfiscal">' + esc(t('sal.nonfiscal_note')) + '</p><div class="tabs" id="sal-tabs">' + tabs.map(function (x) {
      return '<a href="#/sales/' + x.id + '" data-act="go" data-to="sales" data-sub="' + x.id + '" class="' + (x.id === SAL.tab ? 'on' : '') + '">' + esc(t(x.label)) + '</a>';
    }).join('') + '</div><div id="sal-bar" class="row" style="margin-bottom:10px"></div><div id="sal-body"><p class="muted">' + esc(t('app.loading')) + '</p></div>';
  },
  mount: async function () { await salPrep(); salBar(); salLoad(true); }
});
function salBar() {
  var bar = $('sal-bar'); if (!bar) return;
  var brs = S.me.branches || [], dn = SAL.tab === 'dn';
  bar.innerHTML = sel('sal-state', [['', t('stk.all_states')]].concat(SAL_STATES.map(function (x) { return [x, t('doc.state.' + x)]; })), SAL.f.state).replace('<select', '<select style="width:auto"') +
    (brs.length > 1 ? sel('sal-branch', expBranchOpts(true), SAL.f.branch).replace('<select', '<select style="width:auto"') : '') +
    '<input id="sal-q" style="max-width:220px" placeholder="' + esc(t('sal.search')) + '" value="' + esc(SAL.f.q) + '"><span class="grow"></span>' +
    (dn && can('doc.dn.create') ? '<button class="primary" id="sal-new-dn" data-act="sal-new" data-type="DN">' + esc(t('sal.new_dn')) + '</button>' : '') +
    (!dn && can('doc.rr.create') ? '<button class="primary" id="sal-new-rr" data-act="sal-new" data-type="RR">' + esc(t('sal.new_rr')) + '</button>' : '') +
    (!dn && can('doc.rs.create') ? '<button id="sal-new-rs" data-act="sal-new" data-type="RS">' + esc(t('sal.new_rs')) + '</button>' : '');
}
document.addEventListener('change', function (e) {
  if (e.target.id === 'sal-state') { SAL.f.state = e.target.value; salLoad(true); }
  else if (e.target.id === 'sal-branch') { SAL.f.branch = e.target.value; salLoad(true); }
});
var salqTimer = null;
document.addEventListener('input', function (e) {
  if (e.target.id !== 'sal-q') return;
  clearTimeout(salqTimer); var v = e.target.value.trim();
  salqTimer = setTimeout(function () { SAL.f.q = v; salLoad(true); }, 300);
});
async function salLoad(reset) {
  if (!$('sal-body')) return;
  var my = ++SAL.seq, tab = SAL.tab, def = SAL_TABS.find(function (x) { return x.id === tab; });
  var f = {doc_types: def.types.filter(function (x) { return can(docCap(x, 'read')); })};
  if (SAL.f.state) f.state = SAL.f.state; if (SAL.f.branch) f.branch_id = SAL.f.branch; if (SAL.f.q) f.q = SAL.f.q;
  var r = await api('doc_list', {p_filter: f, p_cursor: reset ? null : SAL.next, p_limit: 50});
  var body = $('sal-body'); if (my !== SAL.seq || SAL.tab !== tab || !body) return;
  if (!r.ok) { body.innerHTML = '<div class="msg bad">' + esc(r.error.text) + '</div>'; return; }
  SAL.rows = (reset ? [] : SAL.rows).concat(r.data.rows || []); SAL.next = r.data.next;
  var dn = tab === 'dn', focus = document.activeElement && document.activeElement.id === 'sal-q';
  body.innerHTML = tbl('sal-table', ['stk.col.date', 'stk.col.number'].concat(dn ? [] : ['sal.col.type'], ['sal.col.customer', 'exp.col.branch', 'stk.col.state', 'exp.col.gross', dn ? 'sal.col.billing' : 'sal.col.method']),
    SAL.rows.map(function (d) {
      var x = d.extra || {};
      return '<tr class="click" data-act="sal-open" data-id="' + esc(d.document_id) + '"><td>' + esc(fmtDate(d.doc_date)) + '</td><td>' + esc(d.doc_no || '') + '</td>' +
        (dn ? '' : '<td>' + esc(t('sal.short.' + d.doc_type)) + '</td>') + '<td>' + esc(d.counterparty_name || '') + '</td><td>' + esc(d.branch_code || '') + '</td><td>' + stateBadge(d.state) +
        '</td><td>' + esc(eur(d.total_gross)) + '</td><td>' + (dn ? (x.to_be_billed === false ? '<span class="badge">' + esc(t('sal.not_billed')) + '</span>' : '<span class="muted">' + esc(t('sal.to_bill')) + '</span>')
                                                               : (x.payment_method ? '<span class="badge good">' + esc(t('exp.method.' + x.payment_method)) + '</span>' : '')) + '</td></tr>';
    }), dn ? 'sal.empty_dn' : 'sal.empty_rr') + (SAL.next ? '<div class="row end" style="margin-top:10px"><button id="sal-more" data-act="sal-more">' + esc(t('list.more')) + '</button></div>' : '');
  if (focus) { var q = $('sal-q'); q.focus(); q.setSelectionRange(q.value.length, q.value.length); }
}
ACT['sal-more'] = function () { salLoad(false); };
async function salOpen(id) {
  var r = await api('sales_get', {p_document_id: id});
  if (!r.ok) { toast(r.error.text); return; }
  await salPrep(); if (r.data.doc_type === 'RR') await salDns(r.data);
  if (D) drawerClose(true);
  docDrawer(r.data);
}
ACT['sal-open'] = function (el) { salOpen(el.getAttribute('data-id')); };
ACT['sal-new'] = async function (el) {
  var type = el.getAttribute('data-type'); await salPrep();
  var whs = STK.whs || [], brs = S.me.branches || [];
  var d = {doc_type: type, state: 'draft', lines: [], can_edit: true, actions: [], problems: [], doc_date: S.me.today,
           extra: type === 'DN' ? {delivery: {reason: 'sale'}, to_be_billed: true} : {payment_method: 'cash'}};
  if (type === 'RS') d.branch_id = SAL.f.branch || (brs.length === 1 ? brs[0].branch_id : '');
  else d.warehouse_id = whs.length === 1 ? whs[0].warehouse_id : '';
  if (type === 'RR') await salDns(d);
  docDrawer(d);
};

/* ---------- drawer parts (called by docHead / docLineRow / docReadLines / docPayload in 30_stock.js) ---------- */
function salCustomerField(d, ro) {
  var opts = (SAL.custs || []).map(function (c) { return [c.counterparty_id, c.name + (c.tax_id ? ' · ' + c.tax_id : '')]; });
  if (d.counterparty_id && !opts.some(function (o) { return o[0] === d.counterparty_id; })) opts.push([d.counterparty_id, d.counterparty_name || d.counterparty_id]);
  return field('s-cust', d.doc_type === 'DN' ? 'sal.f.customer' : 'sal.f.customer_opt', sel('s-cust', [['', t(d.doc_type === 'DN' ? 'md.choose' : 'sal.no_customer')]].concat(opts), d.counterparty_id || '', ro)) +
    (!ro && can('counterparty.write') ? '<button type="button" class="link" id="sal-cust-new" data-act="sal-cust-new">' + esc(t('sal.cust_new')) + '</button>' : '');
}
ACT['sal-cust-new'] = function () {
  promptBox(t('sal.cust_new_q'), t('md.f.name'), t('sal.cust_add'), async function (name) {
    var r = await api('counterparty_save', {p_counterparty: {name: name, kind: 'customer'}}, {write: true});
    if (!r.ok || !r.data) { toast(notSaved(r)); return; }
    var row = r.data.row || r.data; (SAL.custs = SAL.custs || []).push(row);
    var s = $('s-cust'); if (s) { var o = document.createElement('option'); o.value = row.counterparty_id; o.textContent = row.name; s.appendChild(o); s.value = row.counterparty_id; }
    if (D) D.dirty = true; toast(t('sal.cust_added', {name: row.name}));
  }, true);
};
function salDeliveryFields(d, ro) {
  var x = (d.extra || {}).delivery || {};
  return field('s-reason', 'sal.f.reason', sel('s-reason', [['', t('md.choose')]].concat(SAL_REASONS.map(function (r) { return [r, t('sal.reason.' + r)]; })), x.reason || '', ro)) +
    field('s-addr', 'sal.f.address', inp('s-addr', x.address, 'text', ro)) + field('s-carrier', 'trf.f.carrier', inp('s-carrier', x.carrier, 'text', ro)) +
    field('s-vehicle', 'trf.f.vehicle', inp('s-vehicle', x.vehicle, 'text', ro));
}
function salBilledField(d, ro) { return chk('s-billed', 'sal.f.to_be_billed', (d.extra || {}).to_be_billed !== false, ro); }
function salPaymentField(d, ro) {
  return field('s-pm', 'sal.f.method', sel('s-pm', [['', t('md.choose')]].concat(SAL_METHODS.map(function (m) { return [m, t('exp.method.' + m)]; })), (d.extra || {}).payment_method || '', ro));
}
// RR: the posted delivery notes (to be billed) a receipt may bill; plain link (no conversion machinery)
async function salDns(d) {
  SAL.dns = [];
  if (!can('doc.dn.read')) return;
  var r = await api('doc_list', {p_filter: {doc_type: 'DN', state: 'posted'}, p_limit: 100});
  SAL.dns = r.ok && r.data ? r.data.rows.filter(function (x) { return (x.extra || {}).to_be_billed !== false; }) : [];
}
function salDnRefField(d, ro) {
  if (!can('doc.dn.read') && !d.ref_document_id) return '';
  var opts = (SAL.dns || []).map(function (x) { return [x.document_id, x.doc_no + ' · ' + (x.counterparty_name || '') + ' · ' + fmtDate(x.doc_date)]; });
  var cur = d.ref_document_id || '', dn = (d.sales || {}).dn;
  if (cur && !opts.some(function (o) { return o[0] === cur; })) opts.push([cur, dn ? dn.doc_no : cur]);
  return field('s-dn', 'sal.f.dn', sel('s-dn', [['', t('sal.no_dn')]].concat(opts), cur, ro)) +
    (ro ? '' : '<button type="button" class="link" id="sal-dn-lines" data-act="sal-dn-lines">' + esc(t('sal.dn_lines')) + '</button>');
}
ACT['sal-dn-lines'] = async function () {
  var id = val('s-dn'); if (!id) { drawerMsg(t('sal.choose_dn')); return; }
  var r = await api('sales_get', {p_document_id: id});
  if (!r.ok) { drawerMsg(r.error.text); return; }
  var dn = r.data, left = {}, added = 0;
  ((dn.sales || {}).billing || {}).lines.forEach(function (b) { left[b.line_id] = Number(b.remaining); });
  salReadLines();
  var taken = DOCD.lines.map(function (l) { return l.dn_line_id; });
  DOCD.lines = DOCD.lines.filter(function (l) { return l.item_id || l.qty || l.description; });
  (dn.lines || []).forEach(function (l) {
    if (!(left[l.line_id] > 0) || taken.indexOf(l.line_id) >= 0) return;
    DOCD.lines.push({item_id: l.item_id, item_code: l.item_code, item_name: l.item_name, qty: String(left[l.line_id]), unit_price: l.unit_price != null ? l.unit_price : '',
                     vat_class_id: l.vat_class_id, dn_line_id: l.line_id, dn_no: dn.doc_no}); added++;
  });
  if (dn.counterparty_id && $('s-cust')) {
    var s = $('s-cust');
    if (!Array.prototype.some.call(s.options, function (o) { return o.value === dn.counterparty_id; })) { var o = document.createElement('option'); o.value = dn.counterparty_id; o.textContent = dn.counterparty_name || ''; s.appendChild(o); }
    s.value = dn.counterparty_id;
  }
  if (!DOCD.lines.length) DOCD.lines.push({});
  $('doc-lines').innerHTML = DOCD.lines.map(function (l, i) { return salLineRow(l, i, DOCD.form, false); }).join('');
  if (D) D.dirty = true;
  drawerMsg(added ? '' : t('sal.dn_nothing_left'));
};
function salVatOpts(cur) {
  var v = (EXP.vats || []).slice();
  if (cur && !expVat(cur)) v.push({vat_class_id: cur, code: '?', rate: 0});
  return [['', t('sal.vat_item')]].concat(v.map(function (x) { return [x.vat_class_id, x.code + ' (' + Number(x.rate) + '%)']; }));
}
function salLineRow(l, i, form, ro) {
  var dis = ro ? ' disabled' : '', fixed = ro || !!l.dn_line_id;   // a billed DN line keeps its item
  return '<div class="dline sll" data-i="' + i + '">' +
    '<div class="dl-item"><input class="dl-code" placeholder="' + esc(t('doc.f.item')) + '" value="' + esc(l.item_code || '') + '"' + (fixed ? ' disabled' : '') + '>' +
    '<span class="muted dl-name">' + esc(l.item_name || '') + (l.on_hand != null ? ' · ' + esc(t('doc.on_hand', {qty: qtyTxt(l.on_hand)})) : '') + '</span></div>' +
    (form.service ? '<input class="dl-desc" placeholder="' + esc(t('sal.f.description')) + '" maxlength="500" value="' + esc(l.description || '') + '"' + dis + '>' : '') +
    '<input class="dl-qty" inputmode="decimal" placeholder="' + esc(t('doc.f.qty')) + '" value="' + esc(l.qty != null && l.qty !== '' ? qtyTxt(l.qty).replace(/,/g, '') : '') + '"' + dis + '>' +
    '<input class="dl-price" inputmode="decimal" placeholder="' + esc(t('sal.f.price')) + '" value="' + esc(l.unit_price != null && l.unit_price !== '' ? Number(l.unit_price) : '') + '"' + dis + '>' +
    sel('', salVatOpts(l.vat_class_id), l.vat_class_id || '', ro).replace('<select id=""', '<select class="dl-vat" aria-label="' + esc(t('exp.f.vat')) + '"') +
    '<span class="dl-amt">' + (l.line_id && l.gross != null ? esc(t('sal.line_amt', {net: eur(l.net), vat: eur(l.vat), gross: eur(l.gross)})) : '') +
    (l.cost_value != null ? ' <span class="muted">' + esc(t('doc.cost', {v: eur(l.cost_value)})) + '</span>' : '') + '</span>' +
    (ro ? '' : '<button class="link dl-del" data-act="doc-line-del" data-i="' + i + '" title="' + esc(t('doc.remove_line')) + '">✕</button>') +
    '<input type="hidden" class="dl-id" value="' + esc(l.item_id || '') + '"><input type="hidden" class="dl-dnl" value="' + esc(l.dn_line_id || (l.extra || {}).dn_line_id || '') + '">' +
    (l.dn_line_id || (l.extra || {}).dn_line_id ? '<span class="dl-dn muted">' + esc(t('sal.from_dn', {no: l.dn_no || ((DOCD && DOCD.doc.sales && DOCD.doc.sales.dn) || {}).doc_no || ''})) + '</span>' : '') + '</div>';
}
function salReadLines() {
  var rows = document.querySelectorAll('#doc-lines .dline');
  DOCD.lines = Array.prototype.map.call(rows, function (r, i) {
    var o = DOCD.lines[i] || {}, q = function (c) { var e = r.querySelector(c); return e ? e.value.trim() : ''; };
    o.item_code = q('.dl-code'); o.item_id = q('.dl-id') || null; o.qty = q('.dl-qty').replace(',', '.'); o.unit_price = q('.dl-price').replace(',', '.');
    o.vat_class_id = q('.dl-vat') || null; o.dn_line_id = q('.dl-dnl') || null;
    if (r.querySelector('.dl-desc')) o.description = q('.dl-desc');
    return o;
  });
  return DOCD.lines;
}
function salPayload(p) {
  var d = DOCD.doc, x = {};
  if ($('s-cust')) p.counterparty_id = val('s-cust') || null;
  if (d.doc_type === 'DN') {
    var dl = {reason: val('s-reason'), address: val('s-addr').trim(), carrier: val('s-carrier').trim(), vehicle: val('s-vehicle').trim()};
    Object.keys(dl).forEach(function (k) { if (!dl[k]) delete dl[k]; });
    x.delivery = dl; x.to_be_billed = $('s-billed') ? $('s-billed').checked : true;
  } else if (val('s-pm')) x.payment_method = val('s-pm');
  p.extra = x;
  if ($('s-dn')) p.ref_document_id = val('s-dn') || null;
  p.lines = salReadLines().filter(function (l) { return l.item_id || l.qty || l.description || l.unit_price; }).map(function (l) {
    var o = {qty: l.qty};
    if (l.item_id) o.item_id = l.item_id;
    if (l.description) o.description = l.description;
    if (l.unit_price !== '' && l.unit_price != null) o.unit_price = l.unit_price;
    if (l.vat_class_id) o.vat_class_id = l.vat_class_id;   // empty = the item's VAT class (key omitted)
    if (l.dn_line_id) o.extra = {dn_line_id: l.dn_line_id};
    return o;
  });
  return p;
}
function salSection(d) {
  var s = d.sales || {}, h = '<div id="sal-info"><p class="msg bad" id="sal-watermark"><b>' + esc(t('sal.watermark')) + '</b> ' + esc(t('sal.fiscal_note')) + '</p>';
  if (d.doc_type === 'DN' && s.billing && d.state === 'posted') {
    h += '<p class="muted" id="sal-billing">' + esc(t('sal.billing.' + s.billing.status)) + (s.billing.receipts || []).map(function (r) {
      return ' · ' + esc(r.doc_no || t('doc.state.draft')) + ' (' + esc(t('doc.state.' + r.state)) + ')'; }).join('') + '</p>';
  }
  if (s.collection && d.state === 'posted') h += '<p class="muted" id="sal-collection">' + esc(t('sal.collected', {m: t('exp.method.' + (s.collection.payment_method || 'other')), v: eur(s.collection.amount)})) + '</p>';
  return h + '</div>';
}

/* ---------- print view (browser Print -> Save as PDF) ---------- */
ACT['sal-print'] = async function () {
  if (!DOCD || !DOCD.doc.document_id) return;
  if (D && D.dirty) { drawerMsg(t('sal.print_save_first')); return; }
  var r = await api('sales_get', {p_document_id: DOCD.doc.document_id});
  if (!r.ok) { drawerMsg(r.error.text); return; }
  salPrintShow(r.data);
};
function salPrintShow(d) {
  var s = d.sales || {}, is = s.issuer || {}, c = s.customer, x = d.extra || {}, dl = x.delivery || {}, vats = {};
  (s.vat_breakdown || []).forEach(function (v) { vats[v.vat_class_id] = v; });
  var addr = function (o) { return [o.street, [o.postal_code, o.city].filter(Boolean).join(' '), o.country && o.country !== 'GR' ? o.country : ''].filter(Boolean).join(', '); };
  var lines = (d.lines || []).map(function (l, i) {
    var v = vats[l.vat_class_id];
    return '<tr><td>' + (i + 1) + '</td><td>' + esc(l.item_code || '') + '</td><td>' + esc(l.item_name || l.description || '') + (l.item_name && l.description ? ' · ' + esc(l.description) : '') + '</td><td class="num">' +
      esc(qtyTxt(l.qty)) + '</td><td class="num">' + (l.unit_price != null ? esc(eur(l.unit_price)) : '') + '</td><td class="num">' + (Number(l.discount_pct) ? esc(Number(l.discount_pct) + '%') : '') +
      '</td><td class="num">' + (v ? esc(Number(v.rate) + '%') : '') + '</td><td class="num">' + esc(eur(l.net)) + '</td><td class="num">' + esc(eur(l.vat)) + '</td><td class="num">' + esc(eur(l.gross)) + '</td></tr>';
  }).join('');
  var vtab = (s.vat_breakdown || []).map(function (v) {
    return '<tr><td>' + esc(v.code || '-') + (v.rate != null ? ' (' + esc(Number(v.rate)) + '%)' : '') + '</td><td class="num">' + esc(eur(v.net)) + '</td><td class="num">' + esc(eur(v.vat)) + '</td><td class="num">' + esc(eur(v.gross)) + '</td></tr>';
  }).join('');
  var el = document.createElement('div'); el.id = 'print-view'; el.className = 'print-view';
  el.innerHTML = '<div class="pv-bar"><button class="primary" id="pv-print" data-act="pv-print">' + esc(t('sal.print_btn')) + '</button><button id="pv-close" data-act="pv-close">' + esc(t('drawer.close')) + '</button>' +
    '<span class="muted">' + esc(t('sal.print_hint')) + '</span></div>' +
    '<div class="pv-page"><div class="pv-wm" aria-hidden="true">' + esc(s.watermark || t('sal.watermark')) + '</div>' +
    '<p class="pv-banner" id="pv-banner">' + esc(s.watermark || t('sal.watermark')) + '</p>' +
    '<div class="pv-head"><div class="pv-issuer" id="pv-issuer">' + (is.logo_url ? '<img src="' + esc(is.logo_url) + '" alt="" class="pv-logo">' : '') +
      '<b>' + esc(is.legal_name || is.name || '') + '</b>' + (is.legal_name && is.name && is.legal_name !== is.name ? '<br>' + esc(is.name) : '') +
      (is.tax_id ? '<br>' + esc(t('sal.p.tax_id')) + ' ' + esc(is.tax_id) + (is.tax_office ? ' · ' + esc(is.tax_office) : '') : '') +
      (is.address ? '<br>' + esc(is.address) : '') + (is.phone || is.email ? '<br>' + esc([is.phone, is.email].filter(Boolean).join(' · ')) : '') +
      '<br><span class="muted">' + esc(t('sal.p.branch', {code: (s.branch || {}).code || '', name: (s.branch || {}).name || ''})) +
      ((s.branch || {}).establishment_no != null ? ' · ' + esc(t('sal.p.estab', {n: s.branch.establishment_no})) : '') + ((s.branch || {}).address ? ' · ' + esc(s.branch.address) : '') + '</span></div>' +
    '<div class="pv-title"><h1 id="pv-title">' + esc(t('doc.type.' + d.doc_type)) + '</h1><p><b id="pv-no">' + esc(d.doc_no || t('sal.p.draft')) + '</b><br>' + esc(fmtDate(d.doc_date)) + '</p></div></div>' +
    '<div class="pv-boxes">' + (c ? '<div class="pv-box" id="pv-customer"><b>' + esc(t('sal.p.customer')) + '</b><br>' + esc(c.name) + (c.tax_id ? '<br>' + esc(t('sal.p.tax_id')) + ' ' + esc(c.tax_id) + (c.tax_office ? ' · ' + esc(c.tax_office) : '') : '') +
      (addr(c) ? '<br>' + esc(addr(c)) : '') + '</div>' : '') +
    (d.doc_type === 'DN' ? '<div class="pv-box" id="pv-delivery"><b>' + esc(t('sal.p.delivery')) + '</b><br>' + esc(t('sal.f.reason')) + ': ' + esc(dl.reason ? t('sal.reason.' + dl.reason) : '') +
      (s.warehouse ? '<br>' + esc(t('sal.p.from', {wh: s.warehouse.code + ' · ' + s.warehouse.name})) : '') + (dl.address ? '<br>' + esc(t('sal.f.address')) + ': ' + esc(dl.address) : '') +
      (dl.carrier ? '<br>' + esc(t('sal.p.carrier')) + ': ' + esc(dl.carrier) : '') + (dl.vehicle ? '<br>' + esc(t('sal.p.vehicle')) + ': ' + esc(dl.vehicle) : '') +
      '<br>' + esc(t(x.to_be_billed === false ? 'sal.not_billed' : 'sal.to_bill')) + '</div>'
      : '<div class="pv-box" id="pv-payment"><b>' + esc(t('sal.f.method')) + '</b><br>' + esc(x.payment_method ? t('exp.method.' + x.payment_method) : '') +
        (s.dn ? '<br>' + esc(t('sal.p.dn', {no: s.dn.doc_no})) : '') + '</div>') + '</div>' +
    '<table class="pv-lines" id="pv-lines"><thead><tr><th>#</th><th>' + esc(t('sal.p.code')) + '</th><th>' + esc(t('sal.p.desc')) + '</th><th class="num">' + esc(t('doc.f.qty')) + '</th><th class="num">' +
      esc(t('sal.f.price')) + '</th><th class="num">' + esc(t('sal.p.disc')) + '</th><th class="num">' + esc(t('sal.p.vat_pct')) + '</th><th class="num">' + esc(t('exp.col.net')) + '</th><th class="num">' +
      esc(t('exp.col.vat')) + '</th><th class="num">' + esc(t('exp.col.gross')) + '</th></tr></thead><tbody>' + lines + '</tbody></table>' +
    '<div class="pv-foot"><table class="pv-vat" id="pv-vat"><thead><tr><th>' + esc(t('exp.f.vat')) + '</th><th class="num">' + esc(t('exp.col.net')) + '</th><th class="num">' + esc(t('exp.col.vat')) +
      '</th><th class="num">' + esc(t('exp.col.gross')) + '</th></tr></thead><tbody>' + vtab + '</tbody></table>' +
      '<p class="pv-total" id="pv-total">' + esc(t('exp.totals', {net: eur(d.total_net), vat: eur(d.total_vat), gross: eur(d.total_gross)})) + '</p></div>' +
    (d.state === 'cancelled' ? '<p class="pv-banner">' + esc(t('sal.p.cancelled', {r: d.cancel_reason || ''})) + '</p>' : '') +
    '<p class="pv-note">' + esc(t('sal.fiscal_note')) + '</p></div>';
  document.body.appendChild(el);
  document.body.classList.add('printing');
}
ACT['pv-print'] = function () { window.print(); };
ACT['pv-close'] = function () { var el = $('print-view'); if (el) el.parentNode.removeChild(el); document.body.classList.remove('printing'); };
