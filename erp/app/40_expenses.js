/* ---------- expenses: list, categories, report (T20-lite) ---------- */
// The expense drawer IS the stock document drawer (30_stock.js, DOC_FORM.EXP): header branch / date / supplier /
// supplier's number and date / MARK / paid + method / cost centre / notes, server problems, buttons from `actions`
// (post, submit / approve / reject above the limit, cancel with a reason). This file adds the menu with its tabs, the
// expense line (category, description, net, VAT class; VAT and gross shown as the server computes them: per line,
// rounded half up), the categories admin and the report (by category / supplier, CSV download built in the page).
var EXP_STATES = ['draft', 'pending_approval', 'posted', 'cancelled'];
var EXP_METHODS = ['cash', 'card', 'bank', 'other'];
var EXP = {tab: null, rows: [], next: null, seq: 0, f: {state: '', branch: '', q: ''}, cats: null, vats: null, rep: null,
           rf: {group: 'category', from: '', to: '', branch: ''}};
onLogin(function () { EXP.cats = null; EXP.vats = null; EXP.rep = null; EXP.f = {state: '', branch: '', q: ''}; EXP.rf = {group: 'category', from: '', to: '', branch: ''}; });
var EXP_TABS = [
  {id: 'list', label: 'exp.tab.list'},
  {id: 'categories', label: 'exp.tab.categories'},
  {id: 'report', label: 'exp.tab.report'}
];
async function expCats(force) {
  if (EXP.cats && !force) return EXP.cats;
  var r = await api('expense_category_list', {p_include_inactive: true, p_limit: 500});
  EXP.cats = r.ok && r.data ? r.data.rows : [];
  return EXP.cats;
}
async function expVats() {
  if (EXP.vats) return EXP.vats;
  var r = await api('vat_class_list', {p_include_inactive: false, p_limit: 200});
  EXP.vats = r.ok && r.data ? r.data.rows : [];
  return EXP.vats;
}
async function expPrep() { await Promise.all([expCats(), expVats(), stkSuppliers()]); }
function expCat(id) { return (EXP.cats || []).find(function (c) { return c.category_id === id; }); }
function expVat(id) { return (EXP.vats || []).find(function (v) { return v.vat_class_id === id; }); }
function expRound(n) { return Math.sign(n) * Math.round(Math.abs(n) * 100 + 1e-9) / 100; }   // half up, as the server
screen({id: 'expenses', nav: 'nav.expenses', caps: ['doc.exp.read'],
  render: function (sub) {
    var want = sub[0];
    EXP.tab = EXP_TABS.some(function (x) { return x.id === want; }) ? want : 'list'; EXP.rows = []; EXP.next = null;
    return '<h1>' + esc(t('exp.title')) + '</h1><div class="tabs" id="exp-tabs">' + EXP_TABS.map(function (x) {
      return '<a href="#/expenses/' + x.id + '" data-act="go" data-to="expenses" data-sub="' + x.id + '" class="' + (x.id === EXP.tab ? 'on' : '') + '">' + esc(t(x.label)) + '</a>';
    }).join('') + '</div><div id="exp-bar" class="row" style="margin-bottom:10px"></div><div id="exp-body"><p class="muted">' + esc(t('app.loading')) + '</p></div>';
  },
  mount: async function () { await expPrep(); expBar(); expLoad(true); }
});
function expBranchOpts(all) { return [['', t(all ? 'trf.all_branches' : 'md.choose')]].concat((S.me.branches || []).map(function (b) { return [b.branch_id, b.code + ' · ' + b.name]; })); }
function expBar() {
  var bar = $('exp-bar'); if (!bar) return;
  var brs = S.me.branches || [], h = '';
  if (EXP.tab === 'list') {
    h = sel('exp-state', [['', t('stk.all_states')]].concat(EXP_STATES.map(function (x) { return [x, t('doc.state.' + x)]; })), EXP.f.state).replace('<select', '<select style="width:auto"') +
      (brs.length > 1 ? sel('exp-branch', expBranchOpts(true), EXP.f.branch).replace('<select', '<select style="width:auto"') : '') +
      '<input id="exp-q" style="max-width:220px" placeholder="' + esc(t('exp.search')) + '" value="' + esc(EXP.f.q) + '">' +
      '<span class="grow"></span>' + (can('doc.exp.create') ? '<button class="primary" id="exp-new" data-act="exp-new">' + esc(t('exp.new')) + '</button>' : '');
  } else if (EXP.tab === 'categories') {
    h = '<span class="grow"></span>' + (can('expense.category.write') ? '<button class="primary" id="exc-new" data-act="exc-new">' + esc(t('exp.cat.new')) + '</button>' : '');
  } else {
    if (!EXP.rf.from) { EXP.rf.from = S.me.today.slice(0, 8) + '01'; EXP.rf.to = S.me.today; }
    h = sel('exr-group', [['category', t('exp.rep.by_category')], ['supplier', t('exp.rep.by_supplier')]], EXP.rf.group).replace('<select', '<select style="width:auto"') +
      '<input id="exr-from" style="width:120px" aria-label="' + esc(t('exp.rep.from')) + '" value="' + esc(fmtDate(EXP.rf.from)) + '">' +
      '<input id="exr-to" style="width:120px" aria-label="' + esc(t('exp.rep.to')) + '" value="' + esc(fmtDate(EXP.rf.to)) + '">' +
      (brs.length > 1 ? sel('exr-branch', expBranchOpts(true), EXP.rf.branch).replace('<select', '<select style="width:auto"') : '') +
      '<button class="primary" id="exr-run" data-act="exr-run">' + esc(t('exp.rep.run')) + '</button><span class="grow"></span>' +
      '<button id="exr-csv" data-act="exr-csv">' + esc(t('exp.rep.csv')) + '</button>';
  }
  bar.innerHTML = h;
}
document.addEventListener('change', function (e) {
  var id = e.target.id;
  if (id === 'exp-state') { EXP.f.state = e.target.value; expLoad(true); }
  else if (id === 'exp-branch') { EXP.f.branch = e.target.value; expLoad(true); }
  else if (id === 'exr-group') { EXP.rf.group = e.target.value; expLoad(true); }
  else if (id === 'exr-branch') { EXP.rf.branch = e.target.value; expLoad(true); }
});
var expqTimer = null;
document.addEventListener('input', function (e) {
  if (e.target.id !== 'exp-q') return;
  clearTimeout(expqTimer); var v = e.target.value.trim();
  expqTimer = setTimeout(function () { EXP.f.q = v; expLoad(true); }, 300);
});
function expBody(h) { var el = $('exp-body'); if (el) el.innerHTML = h; }
async function expLoad(reset) {
  if (!$('exp-body')) return;
  var my = ++EXP.seq, tab = EXP.tab, r;
  if (tab === 'list') {
    var f = {doc_type: 'EXP'}; if (EXP.f.state) f.state = EXP.f.state; if (EXP.f.branch) f.branch_id = EXP.f.branch; if (EXP.f.q) f.q = EXP.f.q;
    r = await api('doc_list', {p_filter: f, p_cursor: reset ? null : EXP.next, p_limit: 50});
  } else if (tab === 'categories') {
    await expCats(true); r = {ok: true, data: {rows: EXP.cats, next: null}};
  } else {
    var g = {group_by: EXP.rf.group, date_from: EXP.rf.from, date_to: EXP.rf.to}; if (EXP.rf.branch) g.branch_id = EXP.rf.branch;
    r = await api('report_expenses', {p_filter: g});
  }
  if (my !== EXP.seq || EXP.tab !== tab || !$('exp-body')) return;
  if (!r.ok) { expBody('<div class="msg bad">' + esc(r.error.text) + '</div>'); return; }
  if (tab === 'report') { EXP.rep = r.data; expBody(expReportView()); return; }
  EXP.rows = (reset ? [] : EXP.rows).concat(r.data.rows || []); EXP.next = r.data.next;
  var focus = document.activeElement && document.activeElement.id === 'exp-q';
  expBody(tab === 'list' ? expListView() : expCatView());
  if (focus) { var q = $('exp-q'); q.focus(); q.setSelectionRange(q.value.length, q.value.length); }
}
ACT['exp-more'] = function () { expLoad(false); };
function expListView() {
  return tbl('exp-table', ['stk.col.date', 'stk.col.number', 'exp.col.supplier', 'exp.col.ext_number', 'exp.col.branch', 'stk.col.state', 'exp.col.gross', 'exp.col.paid'], EXP.rows.map(function (d) {
    var paid = (d.extra || {}).paid === true;
    return '<tr class="click" data-act="exp-doc" data-id="' + esc(d.document_id) + '"><td>' + esc(fmtDate(d.doc_date)) + '</td><td>' + esc(d.doc_no || '') + '</td><td>' +
      esc(d.counterparty_name || '') + '</td><td>' + esc(d.ext_number || '') + '</td><td>' + esc(d.branch_code || '') + '</td><td>' + stateBadge(d.state) + '</td><td>' +
      esc(eur(d.total_gross)) + '</td><td>' + (paid ? '<span class="badge good">' + esc(t('exp.method.' + ((d.extra || {}).payment_method || 'other'))) + '</span>' : '<span class="muted">' + esc(t('exp.unpaid')) + '</span>') + '</td></tr>';
  }), 'exp.empty') + (EXP.next ? '<div class="row end" style="margin-top:10px"><button id="exp-more" data-act="exp-more">' + esc(t('list.more')) + '</button></div>' : '');
}

/* ---------- expense drawer parts (called by docHead / docLineRow / docPayload in 30_stock.js) ---------- */
ACT['exp-new'] = async function () {
  await expPrep();
  var brs = S.me.branches || [];
  docDrawer({doc_type: 'EXP', state: 'draft', lines: [], extra: {}, can_edit: true, actions: [], problems: [], doc_date: S.me.today,
             branch_id: EXP.f.branch || (brs.length === 1 ? brs[0].branch_id : '')});
};
ACT['exp-doc'] = async function (el) {
  var r = await api('doc_get', {p_document_id: el.getAttribute('data-id')});
  if (!r.ok) { toast(r.error.text); return; }
  await expPrep(); docDrawer(r.data);
};
function expBranchField(d, ro) {
  if (ro || d.document_id) return field('d-branch-ro', 'exp.f.branch', inp('d-branch-ro', d.branch_code || ((S.me.branches || []).find(function (b) { return b.branch_id === d.branch_id; }) || {}).code || '', 'text', true)) +
    (ro ? '' : '<input type="hidden" id="d-branch" value="' + esc(d.branch_id || '') + '">');
  return field('d-branch', 'exp.f.branch', sel('d-branch', expBranchOpts(false), d.branch_id || ''));
}
function expPaidFields(d, ro) {
  var x = d.extra || {};
  return chk('d-paid', 'exp.f.paid', x.paid === true, ro) +
    field('d-pm', 'exp.f.method', sel('d-pm', [['', t('md.choose')]].concat(EXP_METHODS.map(function (m) { return [m, t('exp.method.' + m)]; })), x.payment_method || '', ro));
}
function expCatOpts(cur) {
  return [['', t('exp.f.category')]].concat((EXP.cats || []).filter(function (c) { return c.active || c.category_id === cur; })
    .map(function (c) { return [c.category_id, (c.path || c.code) + ' · ' + c.name]; }));
}
function expVatOpts(cur) {
  var v = (EXP.vats || []).slice();
  if (cur && !expVat(cur)) v.push({vat_class_id: cur, code: '?', rate: 0});
  return [['', t('exp.f.vat')]].concat(v.map(function (x) { return [x.vat_class_id, x.code + ' (' + Number(x.rate) + '%)']; }));
}
function expAmt(net, vatId) {
  var n = Number(String(net == null ? '' : net).replace(',', '.')), v = expVat(vatId);
  if (net === '' || net == null || isNaN(n) || !v) return '';
  var vat = expRound(n * Number(v.rate) / 100);
  return t('exp.line_amt', {vat: eur(vat), gross: eur(expRound(n) + vat)});
}
function expLineRow(l, i, ro) {
  var dis = ro ? ' disabled' : '';
  return '<div class="dline exl" data-i="' + i + '">' +
    sel('', expCatOpts(l.expense_category_id), l.expense_category_id || '', ro).replace('<select id=""', '<select class="dl-cat" aria-label="' + esc(t('exp.f.category')) + '"') +
    '<input class="dl-desc" placeholder="' + esc(t('exp.f.description')) + '" maxlength="500" value="' + esc(l.description || '') + '"' + dis + '>' +
    '<input class="dl-net" inputmode="decimal" placeholder="' + esc(t('exp.f.net')) + '" value="' + esc(l.unit_price != null && l.unit_price !== '' ? Number(l.unit_price) : '') + '"' + dis + '>' +
    sel('', expVatOpts(l.vat_class_id), l.vat_class_id || '', ro).replace('<select id=""', '<select class="dl-vat" aria-label="' + esc(t('exp.f.vat')) + '"') +
    '<span class="dl-amt">' + esc(l.gross != null && l.line_id ? t('exp.line_amt', {vat: eur(l.vat), gross: eur(l.gross)}) : expAmt(l.unit_price, l.vat_class_id)) + '</span>' +
    (ro ? '' : '<button class="link dl-del" data-act="doc-line-del" data-i="' + i + '" title="' + esc(t('doc.remove_line')) + '">✕</button>') + '</div>';
}
function expReadLines() {
  var rows = document.querySelectorAll('#doc-lines .dline');
  DOCD.lines = Array.prototype.map.call(rows, function (r, i) {
    var o = DOCD.lines[i] || {}, q = function (c) { var e = r.querySelector(c); return e ? e.value.trim() : ''; };
    o.expense_category_id = q('.dl-cat') || null; o.description = q('.dl-desc'); o.unit_price = q('.dl-net').replace(',', '.'); o.vat_class_id = q('.dl-vat') || null;
    return o;
  });
  return DOCD.lines;
}
function expPayloadLines(lines) {
  return lines.filter(function (l) { return l.expense_category_id || l.unit_price || l.description; }).map(function (l) {
    var o = {expense_category_id: l.expense_category_id, qty: 1, vat_class_id: l.vat_class_id};
    if (l.unit_price !== '' && l.unit_price != null) o.unit_price = l.unit_price;
    if (l.description) o.description = l.description;
    return o;
  });
}
function expTotals(d) {
  return '<p id="doc-totals"><b>' + esc(t('exp.totals', {net: eur(d.total_net), vat: eur(d.total_vat), gross: eur(d.total_gross)})) + '</b></p>';
}
// the category brings its default VAT class; net / VAT class changes show the line's VAT and gross at once
document.addEventListener('change', function (e) {
  if (!DOCD || !DOCD.form.expense || !e.target.classList) return;
  var row = e.target.closest && e.target.closest('.exl'); if (!row) return;
  if (e.target.classList.contains('dl-cat')) {
    var c = expCat(e.target.value), v = row.querySelector('.dl-vat');
    if (c && c.default_vat_class_id && v) v.value = c.default_vat_class_id;
  }
  var a = row.querySelector('.dl-amt'); if (a) a.textContent = expAmt(row.querySelector('.dl-net').value.trim(), row.querySelector('.dl-vat').value);
});
document.addEventListener('input', function (e) {
  if (!DOCD || !DOCD.form.expense || !e.target.classList || !e.target.classList.contains('dl-net')) return;
  var row = e.target.closest('.exl'), a = row && row.querySelector('.dl-amt');
  if (a) a.textContent = expAmt(e.target.value.trim(), row.querySelector('.dl-vat').value);
});

/* ---------- categories ---------- */
function expCatView() {
  var w = can('expense.category.write');
  return tbl('exc-table', ['md.col.code', 'md.col.name', 'exp.col.default_vat', 'exp.col.status'], EXP.rows.map(function (c) {
    return '<tr' + (w ? ' class="click" data-act="exc-open" data-id="' + esc(c.category_id) + '"' : '') + '><td>' + esc(c.path || c.code) + '</td><td>' + esc(c.name) + '</td><td>' +
      esc(c.vat_code ? c.vat_code + ' (' + Number(c.vat_rate) + '%)' : '') + '</td><td>' + (c.active ? '' : '<span class="badge">' + esc(t('md.inactive')) + '</span>') + '</td></tr>';
  }), 'exp.cat.empty');
}
ACT['exc-new'] = function () { expCatDrawer({active: true}); };
ACT['exc-open'] = function (el) { var c = expCat(el.getAttribute('data-id')); if (c) expCatDrawer(c); };
function expCatDrawer(c) {
  var parents = [['', t('exp.cat.top')]].concat((EXP.cats || []).filter(function (x) { return x.category_id !== c.category_id && (x.active || x.category_id === c.parent_id); })
    .map(function (x) { return [x.category_id, (x.path || x.code) + ' · ' + x.name]; }));
  drawerOpen({title: c.category_id ? t('exp.cat.edit', {code: c.code}) : t('exp.cat.new'),
    body: function () {
      return field('ec-code', 'md.f.code', inp('ec-code', c.code)) + field('ec-name', 'md.f.name', inp('ec-name', c.name)) +
        field('ec-parent', 'exp.cat.parent', sel('ec-parent', parents, c.parent_id || '')) +
        field('ec-vat', 'exp.cat.default_vat', sel('ec-vat', [['', t('exp.cat.no_vat')]].concat((EXP.vats || []).map(function (v) { return [v.vat_class_id, v.code + ' (' + Number(v.rate) + '%)']; })), c.default_vat_class_id || '')) +
        (c.category_id ? chk('ec-active', 'md.f.active', c.active) : '');
    },
    save: function () {
      var p = {code: val('ec-code').trim(), name: val('ec-name').trim(), parent_id: val('ec-parent') || null, default_vat_class_id: val('ec-vat') || null};
      if (c.category_id) { p.category_id = c.category_id; p.active = $('ec-active').checked; }
      return api('expense_category_save', {p_category: p}, {write: true, key: D.key});
    },
    onSaved: async function () { await expCats(true); expLoad(true); }});
}

/* ---------- report ---------- */
function expReportView() {
  var r = EXP.rep || {}, tot = r.totals || {}, sup = r.group_by === 'supplier';
  var rows = (r.rows || []).map(function (x) {
    return '<tr><td>' + esc(sup ? (x.name || t('exp.rep.no_supplier')) : ((x.path || x.code || '') + ' · ' + (x.name || ''))) + '</td><td>' + esc(x.docs) + '</td><td>' + esc(eur(x.net)) + '</td><td>' +
      esc(eur(x.vat)) + '</td><td><b>' + esc(eur(x.gross)) + '</b></td><td>' + esc(eur(x.paid_gross)) + '</td></tr>';
  });
  if (rows.length) rows.push('<tr id="exr-total"><td><b>' + esc(t('exp.rep.total')) + '</b></td><td>' + esc(tot.docs) + '</td><td>' + esc(eur(tot.net)) + '</td><td>' + esc(eur(tot.vat)) +
    '</td><td><b>' + esc(eur(tot.gross)) + '</b></td><td>' + esc(eur(tot.paid_gross)) + '</td></tr>');
  return '<p class="muted" id="exr-range">' + esc(t('exp.rep.range', {from: fmtDate(r.date_from), to: fmtDate(r.date_to)})) + '</p>' +
    tbl('exr-table', [sup ? 'exp.col.supplier' : 'exp.col.category', 'exp.col.docs', 'exp.col.net', 'exp.col.vat', 'exp.col.gross', 'exp.col.paid_gross'], rows, 'exp.rep.empty') +
    (r.truncated ? '<p class="muted">' + esc(t('exp.rep.truncated')) + '</p>' : '');
}
ACT['exr-run'] = function () {
  var f = parseDate(val('exr-from').trim()), to = parseDate(val('exr-to').trim());
  if (!f || !to) { expBody('<div class="msg bad">' + esc(t('exp.rep.bad_dates')) + '</div>'); return; }
  EXP.rf.from = f; EXP.rf.to = to; expLoad(true);
};
function csvCell(v) { var s = String(v == null ? '' : v); return /[",\n;]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; }
ACT['exr-csv'] = function () {
  var r = EXP.rep; if (!r || !(r.rows || []).length) { toast(t('exp.rep.empty')); return; }
  var sup = r.group_by === 'supplier', lines = [[sup ? 'supplier' : 'category_code', sup ? 'supplier_code' : 'category_name', 'documents', 'net', 'vat', 'gross', 'paid_on_the_spot']];
  r.rows.forEach(function (x) { lines.push(sup ? [x.name || '', x.code || '', x.docs, x.net, x.vat, x.gross, x.paid_gross] : [x.path || x.code || '', x.name || '', x.docs, x.net, x.vat, x.gross, x.paid_gross]); });
  lines.push(['TOTAL', '', r.totals.docs, r.totals.net, r.totals.vat, r.totals.gross, r.totals.paid_gross]);
  var blob = new Blob([lines.map(function (l) { return l.map(csvCell).join(','); }).join('\n') + '\n'], {type: 'text/csv;charset=utf-8'});
  var a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'expenses_' + r.group_by + '_' + r.date_from + '_' + r.date_to + '.csv';
  document.body.appendChild(a); a.click(); setTimeout(function () { URL.revokeObjectURL(a.href); a.parentNode.removeChild(a); }, 0);
};
