/* ---------- master data: items, categories, units, VAT classes, warehouses, counterparties, series (T07) ---------- */
// One screen, one tab per kind. Each tab is DATA (MD_TABS): list RPC + args, columns, drawer form, payload builder.
// Lists use the server's keyset cursor ("Load more"); drawers send only the changed keys (+ id / version).
// Tabs follow the read capability, "New" and Save follow the write capability; the server checks every call again.
var MD = {tab: null, q: '', rows: [], next: null, busy: false, seq: 0, ref: {}};
onLogin(function () { MD.ref = {}; });

function mdVal(v) { return v == null ? '' : String(v); }
// changed keys only: vals = {key: value from the form}; numbers / text compared as text, '' = null
function mdDiff(orig, vals) {
  var out = {};
  Object.keys(vals).forEach(function (k) {
    var a = orig[k], b = vals[k];
    if (typeof b === 'boolean' || Array.isArray(b)) { if (JSON.stringify(a == null ? (Array.isArray(b) ? [] : false) : a) !== JSON.stringify(b)) out[k] = b; return; }
    var an = mdVal(a), bn = mdVal(b);
    if (an !== bn && !(an !== '' && bn !== '' && !isNaN(an) && !isNaN(bn) && Number(an) === Number(bn))) out[k] = b === '' ? null : b;
  });
  return out;
}
function mdOpt(list, idKey, label, cur, blank) {
  var o = blank ? [['', t(blank)]] : [];
  return o.concat(list.map(function (x) { return [x[idKey], label(x)]; }));
}
function mdBadge(on) { return '<span class="badge ' + (on ? 'good' : '') + '">' + esc(t(on ? 'md.active' : 'md.inactive')) + '</span>'; }
function mdText(id) { var v = val(id).trim(); return v === '' ? null : v; }
function mdNum(id) { var v = val(id).trim().replace(',', '.'); return v === '' ? null : v; }
function mdChk(id) { var e = $(id); return !!(e && e.checked); }
function mdRef(k) { return MD.ref[k] || []; }
async function mdLoadRef(k) {
  var r;
  if (k === 'units') r = await api('unit_list', {p_include_inactive: true, p_limit: 500});
  else if (k === 'cats') r = await api('category_list', {p_include_inactive: true, p_limit: 500});
  else if (k === 'vats') r = can('vat.read') ? await api('vat_class_list', {p_include_inactive: true, p_limit: 500}) : {ok: true, data: {rows: []}};
  else if (k === 'types') { r = await api('doc_type_list'); if (r.ok) { MD.ref.types = r.data || []; } return r; }
  if (r && r.ok && r.data) MD.ref[k] = r.data.rows || [];
  return r;
}

var MD_TABS = [
  {id: 'items', label: 'md.tab.items', caps: ['item.read'], write: 'item.write', rpc: 'item_list', key: 'item_id', search: 'md.items.search', refs: ['units', 'cats', 'vats'],
    args: function () { return {p_filter: MD.q ? {q: MD.q, active: 'all'} : {active: 'all'}, p_limit: 50}; },
    cols: [['md.col.code', function (r) { return esc(r.code); }], ['md.col.name', function (r) { return esc(r.name); }],
           ['md.col.unit', function (r) { return esc(r.unit_code); }], ['md.col.category', function (r) { return esc(r.category_code || ''); }],
           ['md.col.kind', function (r) { return esc(t('md.kind.' + r.kind)); }], ['md.col.status', function (r) { return mdBadge(r.active); }]],
    form: function (r, ro) {
      var det = can('item.detail.read');
      return field('i-code', 'md.f.code', inp('i-code', r.code, 'text', ro)) + field('i-name', 'md.f.name', inp('i-name', r.name, 'text', ro)) +
        field('i-kind', 'md.f.kind', sel('i-kind', ['goods', 'consumable', 'service'].map(function (k) { return [k, t('md.kind.' + k)]; }), r.kind || 'goods', ro)) +
        field('i-unit', 'md.f.unit', sel('i-unit', mdOpt(mdRef('units').filter(function (u) { return u.active || u.unit_id === r.base_unit_id; }), 'unit_id',
          function (u) { return u.code + ' · ' + u.name; }, r.base_unit_id, 'md.choose'), r.base_unit_id || '', ro)) +
        (det ? field('i-cat', 'md.f.category', sel('i-cat', mdOpt(mdRef('cats'), 'category_id', function (c) { return c.path || c.code; }, r.category_id, 'md.none'), r.category_id || '', ro)) +
          (can('vat.read') ? field('i-vat', 'md.f.vat', sel('i-vat', mdOpt(mdRef('vats').filter(function (v) { return v.active || v.vat_class_id === r.vat_class_id; }), 'vat_class_id',
            function (v) { return v.code + ' · ' + v.rate + '%'; }, r.vat_class_id, 'md.none'), r.vat_class_id || '', ro)) : '') +
          '<div class="row"><div class="grow">' + field('i-min', 'md.f.min_level', inp('i-min', r.min_level, 'text', ro)) + '</div><div class="grow">' +
          field('i-reo', 'md.f.reorder_level', inp('i-reo', r.reorder_level, 'text', ro)) + '</div></div>' +
          field('i-price', 'md.f.sales_price', inp('i-price', r.sales_price, 'text', ro)) +
          (r.last_purchase_price != null ? '<p class="muted">' + esc(t('md.last_purchase', {price: eur(r.last_purchase_price)})) + '</p>' : '') +
          field('i-desc', 'md.f.description', inp('i-desc', r.description, 'text', ro)) : '') +
        field('i-bc', 'md.f.barcodes', inp('i-bc', (r.barcodes || []).join(', '), 'text', ro)) +
        chk('i-active', 'md.f.active', r.active !== false, ro || (r.item_id && r.active && !can('master.archive')));
    },
    vals: function (r) {
      var v = {code: mdText('i-code'), name: mdText('i-name'), kind: val('i-kind'), base_unit_id: val('i-unit') || null,
        barcodes: val('i-bc').split(/[,;\s]+/).map(function (x) { return x.trim(); }).filter(Boolean), active: mdChk('i-active')};
      if (can('item.detail.read')) {
        v.category_id = val('i-cat') || null; v.min_level = mdNum('i-min'); v.reorder_level = mdNum('i-reo'); v.sales_price = mdNum('i-price'); v.description = mdText('i-desc');
        if (can('vat.read')) v.vat_class_id = val('i-vat') || null;
      }
      return v;
    },
    save: 'item_save', param: 'p_item', version: true,
    importRpc: 'item_import', importCols: ['code', 'name', 'kind', 'unit', 'category', 'vat', 'min_level', 'reorder_level', 'sales_price', 'barcodes', 'description', 'active']},
  {id: 'categories', label: 'md.tab.categories', caps: ['item.read'], write: 'item.write', rpc: 'category_list', key: 'category_id', refs: ['cats'],
    args: function () { return {p_include_inactive: true, p_limit: 200}; },
    cols: [['md.col.path', function (r) { return esc(r.path || r.code); }], ['md.col.name', function (r) { return esc(r.name); }], ['md.col.status', function (r) { return mdBadge(r.active); }]],
    form: function (r, ro) {
      return field('c-code', 'md.f.code', inp('c-code', r.code, 'text', ro)) + field('c-name', 'md.f.name', inp('c-name', r.name, 'text', ro)) +
        field('c-parent', 'md.f.parent', sel('c-parent', mdOpt(mdRef('cats').filter(function (c) { return c.category_id !== r.category_id; }), 'category_id',
          function (c) { return c.path || c.code; }, r.parent_id, 'md.top_level'), r.parent_id || '', ro)) +
        chk('c-active', 'md.f.active', r.active !== false, ro || (r.category_id && r.active && !can('master.archive')));
    },
    vals: function () { return {code: mdText('c-code'), name: mdText('c-name'), parent_id: val('c-parent') || null, active: mdChk('c-active')}; },
    save: 'category_save', param: 'p_category'},
  {id: 'units', label: 'md.tab.units', caps: ['item.read'], write: 'item.write', rpc: 'unit_list', key: 'unit_id',
    args: function () { return {p_include_inactive: true, p_limit: 200}; },
    cols: [['md.col.code', function (r) { return esc(r.code); }], ['md.col.name', function (r) { return esc(r.name); }],
           ['md.col.decimals', function (r) { return esc(r.decimals); }], ['md.col.status', function (r) { return mdBadge(r.active); }]],
    form: function (r, ro) {
      return field('u-code', 'md.f.code', inp('u-code', r.code, 'text', ro)) + field('u-name', 'md.f.name', inp('u-name', r.name, 'text', ro)) +
        field('u-dec', 'md.f.decimals', sel('u-dec', [0, 1, 2, 3, 4].map(function (n) { return [n, String(n)]; }), r.decimals == null ? 0 : r.decimals, ro)) +
        chk('u-active', 'md.f.active', r.active !== false, ro || (r.unit_id && r.active && !can('master.archive')));
    },
    vals: function () { return {code: mdText('u-code'), name: mdText('u-name'), decimals: Number(val('u-dec')), active: mdChk('u-active')}; },
    save: 'unit_save', param: 'p_unit'},
  {id: 'vat', label: 'md.tab.vat', caps: ['vat.read'], write: 'vat.write', rpc: 'vat_class_list', key: 'vat_class_id',
    args: function () { return {p_include_inactive: true, p_limit: 200}; },
    cols: [['md.col.code', function (r) { return esc(r.code); }], ['md.col.name', function (r) { return esc(r.name); }], ['md.col.rate', function (r) { return esc(r.rate) + '%'; }],
           ['md.col.mydata', function (r) { return esc(r.mydata_category == null ? '' : r.mydata_category); }], ['md.col.status', function (r) { return mdBadge(r.active); }]],
    form: function (r, ro) {
      return field('v-code', 'md.f.code', inp('v-code', r.code, 'text', ro)) + field('v-name', 'md.f.name', inp('v-name', r.name, 'text', ro)) +
        field('v-rate', 'md.f.rate', inp('v-rate', r.rate, 'text', ro)) + field('v-cat', 'md.f.mydata', inp('v-cat', r.mydata_category, 'text', ro)) +
        field('v-ex', 'md.f.exemption', inp('v-ex', r.exemption_code, 'text', ro)) + '<p class="muted">' + esc(t('md.vat_note')) + '</p>' +
        chk('v-active', 'md.f.active', r.active !== false, ro || (r.vat_class_id && r.active && !can('counterparty.archive')));
    },
    vals: function () { return {code: mdText('v-code'), name: mdText('v-name'), rate: mdNum('v-rate'), mydata_category: mdNum('v-cat'), exemption_code: mdText('v-ex'), active: mdChk('v-active')}; },
    save: 'vat_class_save', param: 'p_vat'},
  {id: 'warehouses', label: 'md.tab.warehouses', caps: ['warehouse.read'], write: 'warehouse.write', rpc: 'warehouse_list', key: 'warehouse_id',
    args: function () { return {p_filter: {include_inactive: true}, p_limit: 200}; },
    cols: [['md.col.code', function (r) { return esc(r.code); }], ['md.col.name', function (r) { return esc(r.name); }],
           ['md.col.branch', function (r) { return esc(r.branch_code || ''); }], ['md.col.status', function (r) { return mdBadge(r.active); }]],
    form: function (r, ro) {
      var br = (S.me.branches || []).map(function (b) { return [b.branch_id, b.code + ' · ' + b.name]; });
      return field('w-branch', 'md.f.branch', sel('w-branch', [['', t('md.choose')]].concat(br), r.branch_id || (br.length === 1 ? br[0][0] : ''), ro)) +
        field('w-code', 'md.f.code', inp('w-code', r.code, 'text', ro)) + field('w-name', 'md.f.name', inp('w-name', r.name, 'text', ro)) +
        chk('w-active', 'md.f.active', r.active !== false, ro || (r.warehouse_id && r.active && !can('master.archive')));
    },
    vals: function () { return {branch_id: val('w-branch') || null, code: mdText('w-code'), name: mdText('w-name'), active: mdChk('w-active')}; },
    save: 'warehouse_save', param: 'p_warehouse'},
  {id: 'counterparties', label: 'md.tab.counterparties', caps: ['counterparty.read'], write: 'counterparty.write', rpc: 'counterparty_list', key: 'counterparty_id',
    search: 'md.cp.search',
    args: function () { return {p_filter: MD.q ? {q: MD.q, active: 'all'} : {active: 'all'}, p_limit: 50}; },
    cols: [['md.col.name', function (r) { return esc(r.name); }], ['md.col.code', function (r) { return esc(r.code || ''); }], ['md.col.kind', function (r) { return esc(t('md.cp.' + r.kind)); }],
           ['md.col.tax_id', function (r) { return esc(r.tax_id || ''); }], ['md.col.city', function (r) { return esc(r.city || ''); }], ['md.col.status', function (r) { return mdBadge(r.active); }]],
    form: function (r, ro) {
      function f(id, k, lbl) { return field(id, lbl, inp(id, r[k], 'text', ro)); }
      return f('p-name', 'name', 'md.f.name') + f('p-code', 'code', 'md.f.code_optional') +
        field('p-kind', 'md.f.kind', sel('p-kind', ['supplier', 'customer', 'both'].map(function (k) { return [k, t('md.cp.' + k)]; }), r.kind || 'supplier', ro)) +
        '<div class="row"><div class="grow">' + f('p-tax', 'tax_id', 'md.f.tax_id') + '</div><div style="width:90px">' + f('p-country', 'country', 'md.f.country') + '</div></div>' +
        f('p-office', 'tax_office', 'md.f.tax_office') + f('p-street', 'street', 'md.f.street') +
        '<div class="row"><div class="grow">' + f('p-city', 'city', 'md.f.city') + '</div><div style="width:120px">' + f('p-postal', 'postal_code', 'md.f.postal_code') + '</div></div>' +
        f('p-email', 'email', 'md.f.email') + f('p-phone', 'phone', 'md.f.phone') + f('p-terms', 'payment_terms_days', 'md.f.payment_terms') +
        f('p-ext', 'ext_ref', 'md.f.ext_ref') + f('p-notes', 'notes', 'md.f.notes') +
        chk('p-active', 'md.f.active', r.active !== false, ro || (r.counterparty_id && r.active && !can('counterparty.archive')));
    },
    vals: function () {
      return {name: mdText('p-name'), code: mdText('p-code'), kind: val('p-kind'), tax_id: mdText('p-tax'), country: (mdText('p-country') || 'GR').toUpperCase(),
        tax_office: mdText('p-office'), street: mdText('p-street'), city: mdText('p-city'), postal_code: mdText('p-postal'), email: mdText('p-email'), phone: mdText('p-phone'),
        payment_terms_days: mdNum('p-terms'), ext_ref: mdText('p-ext'), notes: mdText('p-notes'), active: mdChk('p-active')};
    },
    save: 'counterparty_save', param: 'p_counterparty', version: true,
    importRpc: 'counterparty_import', importCols: ['name', 'code', 'kind', 'tax_id', 'tax_office', 'country', 'street', 'city', 'postal_code', 'email', 'phone',
                                                   'payment_terms_days', 'notes', 'ext_ref', 'active']},
  {id: 'series', label: 'md.tab.series', caps: ['series.read'], write: 'series.write', rpc: 'series_list', key: 'series_id', refs: ['types'],
    args: function () { return {p_filter: {include_inactive: true}, p_limit: 200}; },
    cols: [['md.col.doc_type', function (r) { return esc(r.doc_type); }], ['md.col.code', function (r) { return esc(r.code); }], ['md.col.branch', function (r) { return esc(r.branch_code || t('md.org_wide')); }],
           ['md.col.year', function (r) { return esc(r.fiscal_year || ''); }], ['md.col.next_no', function (r) { return esc(r.next_no); }],
           ['md.col.flags', function (r) { return (r.is_default ? '<span class="badge">' + esc(t('md.default')) + '</span> ' : '') + (r.gapless ? '<span class="badge">' + esc(t('md.gapless')) + '</span>' : ''); }],
           ['md.col.status', function (r) { return mdBadge(r.active); }]],
    form: function (r, ro) {
      var used = !!r.in_use, br = (S.me.branches || []).map(function (b) { return [b.branch_id, b.code + ' · ' + b.name]; });
      return field('s-type', 'md.f.doc_type', sel('s-type', mdRef('types').map(function (d) { return [d.doc_type, d.doc_type + ' · ' + d.name]; }), r.doc_type || 'GRN', ro || used)) +
        field('s-branch', 'md.f.branch_org', sel('s-branch', [['', t('md.org_wide')]].concat(br), r.branch_id || '', ro || used)) +
        field('s-code', 'md.f.code', inp('s-code', r.code, 'text', ro)) +
        '<div class="row"><div class="grow">' + field('s-year', 'md.f.fiscal_year', inp('s-year', r.fiscal_year, 'text', ro || used)) + '</div><div class="grow">' +
        field('s-next', 'md.f.next_no', inp('s-next', r.next_no || 1, 'text', ro || used)) + '</div></div>' +
        (used ? '<p class="muted">' + esc(t('md.series_in_use', {no: r.last_no})) + '</p>' : '') +
        chk('s-gap', 'md.f.gapless', !!r.gapless, ro || used) + chk('s-def', 'md.f.is_default', r.is_default !== false, ro) + chk('s-active', 'md.f.active', r.active !== false, ro);
    },
    vals: function (r) {
      var v = {code: mdText('s-code'), is_default: mdChk('s-def'), active: mdChk('s-active')};
      if (!r.in_use) { v.doc_type = val('s-type'); v.branch_id = val('s-branch') || null; v.fiscal_year = mdNum('s-year'); v.next_no = mdNum('s-next'); v.gapless = mdChk('s-gap'); }
      return v;
    },
    extraTop: function () {
      if (!can('series.write')) return '';
      var br = (S.me.branches || []).map(function (b) { return [b.branch_id, b.code]; });
      return br.length ? '<span class="muted">' + esc(t('md.series_defaults')) + '</span>' + sel('s-def-branch', br, br[0][0]).replace('<select', '<select style="width:auto"') +
        '<button id="s-def-go" data-act="md-series-defaults">' + esc(t('md.series_defaults_go')) + '</button>' : '';
    },
    save: 'series_save', param: 'p_series'}
];
function mdTabs() { return MD_TABS.filter(function (x) { return canAny(x.caps); }); }
function mdTab() { for (var i = 0; i < MD_TABS.length; i++) if (MD_TABS[i].id === MD.tab) return MD_TABS[i]; return null; }

screen({id: 'master', nav: 'nav.master', caps: ['item.read', 'warehouse.read', 'counterparty.read', 'series.read'],
  render: function (sub) {
    var tabs = mdTabs(), want = sub[0];
    var next = tabs.some(function (x) { return x.id === want; }) ? want : tabs[0].id;
    if (next !== MD.tab) { MD.q = ''; }
    MD.tab = next; MD.rows = []; MD.next = null;
    return '<h1>' + esc(t('md.title')) + '</h1><div class="tabs" id="md-tabs">' + tabs.map(function (x) {
      return '<a href="#/master/' + x.id + '" data-act="go" data-to="master" data-sub="' + x.id + '" class="' + (x.id === MD.tab ? 'on' : '') + '">' + esc(t(x.label)) + '</a>';
    }).join('') + '</div><div id="md-body"><p class="muted">' + esc(t('app.loading')) + '</p></div>';
  },
  mount: function () { mdLoad(true); }
});
function mdBody(h) { var el = $('md-body'); if (el) el.innerHTML = h; }
function mdView(tab) {
  var head = '<div class="row" style="margin-bottom:10px">' + (tab.search ? '<input id="md-q" class="grow" style="max-width:320px" placeholder="' + esc(t(tab.search)) + '" value="' + esc(MD.q) + '">' : '') +
    (tab.extraTop ? tab.extraTop() : '') + '<span class="grow"></span>' +
    (can(tab.write) && tab.importRpc ? '<button id="md-import" data-act="md-import">' + esc(t('imp.button')) + '</button>' : '') +
    (can(tab.write) ? '<button class="primary" id="md-new" data-act="md-new">' + esc(t('md.new')) + '</button>' : '') + '</div>';
  var body = MD.rows.length ? MD.rows.map(function (r) {
    return '<tr class="click" data-act="md-open" data-id="' + esc(r[tab.key]) + '">' + tab.cols.map(function (c) { return '<td>' + c[1](r) + '</td>'; }).join('') + '</tr>';
  }).join('') : '<tr><td colspan="' + tab.cols.length + '" class="empty">' + esc(t('list.empty')) + '</td></tr>';
  return head + '<div class="tbl-wrap"><table id="md-table"><thead><tr>' + tab.cols.map(function (c) { return '<th>' + esc(t(c[0])) + '</th>'; }).join('') + '</tr></thead><tbody>' + body + '</tbody></table></div>' +
    (MD.next ? '<div class="row end" style="margin-top:10px"><button id="md-more" data-act="md-more">' + esc(t('list.more')) + '</button></div>' : '');
}
async function mdLoad(reset) {
  var tab = mdTab(); if (!tab) return;
  if (MD.busy && !reset) return;
  var my = ++MD.seq; MD.busy = true;
  if (reset && tab.refs) { for (var i = 0; i < tab.refs.length; i++) await mdLoadRef(tab.refs[i]); }
  var a = tab.args(); a.p_cursor = reset ? null : MD.next;
  var r = await api(tab.rpc, a);
  if (my !== MD.seq || MD.tab !== tab.id) return;   // a newer load (search typed, tab changed) wins
  MD.busy = false;
  if (!r.ok) { mdBody('<div class="msg bad">' + esc(r.error.text) + '</div>'); return; }
  MD.rows = (reset ? [] : MD.rows).concat(r.data.rows || []); MD.next = r.data.next;
  var focus = document.activeElement && document.activeElement.id === 'md-q';
  mdBody(mdView(tab));
  if (focus) { var q = $('md-q'); q.focus(); q.setSelectionRange(q.value.length, q.value.length); }
}
ACT['md-more'] = function () { mdLoad(false); };
var mdqTimer = null;
document.addEventListener('input', function (e) {
  if (e.target.id !== 'md-q') return;
  clearTimeout(mdqTimer); var v = e.target.value.trim();
  mdqTimer = setTimeout(function () { MD.q = v; mdLoad(true); }, 300);
});
function mdDrawer(tab, row) {
  var isNew = !row[tab.key], ro = !can(tab.write);
  drawerOpen({title: t(isNew ? 'md.drawer.new' : 'md.drawer.edit', {what: t(tab.label)}), readOnly: ro, body: function () { return tab.form(row, ro); },
    save: function () {
      var vals = tab.vals(row), p = isNew ? {} : mdDiff(row, vals);
      if (isNew) Object.keys(vals).forEach(function (k) { if (vals[k] !== null && !(Array.isArray(vals[k]) && !vals[k].length)) p[k] = vals[k]; });
      if (!isNew && !Object.keys(p).length) return Promise.resolve({ok: true, data: row});
      if (!isNew) { p[tab.key] = row[tab.key]; if (tab.version && row.version != null) p.version = row.version; }
      var args = {}; args[tab.param] = p;
      return api(tab.save, args, {write: true, key: D.key});
    },
    onSaved: async function () { if (tab.refs) MD.ref = {}; await mdLoad(true); }});
}
ACT['md-new'] = function () { var tab = mdTab(); if (tab) mdDrawer(tab, {}); };
ACT['md-open'] = async function (el) {
  var tab = mdTab(); if (!tab) return;
  var row = MD.rows.find(function (x) { return String(x[tab.key]) === el.getAttribute('data-id'); }); if (!row) return;
  mdDrawer(tab, row);
};
ACT['md-series-defaults'] = async function () {
  var b = $('s-def-go'); if (!b || b.disabled) return;
  b.disabled = true;
  var r = await api('series_create_defaults', {p_branch_id: val('s-def-branch')}, {write: true});
  b.disabled = false;
  if (!r.ok || !r.data) { toast(notSaved(r)); return; }
  toast(t('md.series_defaults_done', {n: (r.data.created || []).length, skipped: (r.data.skipped || []).join(', ') || '-'}));
  mdLoad(true);
};

/* ---------- CSV import (T08): dry run first, import only the text that was checked clean ---------- */
var IMP = null;
ACT['md-import'] = function () {
  var tab = mdTab(); if (!tab || !tab.importRpc) return;
  IMP = {tab: tab, checked: null, busy: false};
  drawerOpen({title: t('imp.title', {what: t(tab.label)}),
    extra: '<button id="imp-check" data-act="imp-check">' + esc(t('imp.check')) + '</button><button class="primary" id="imp-run" data-act="imp-run" disabled>' + esc(t('imp.run')) + '</button>',
    body: function () {
      return '<p class="muted">' + esc(t('imp.lead', {cols: tab.importCols.join(', ')})) + '</p>' +
        '<label for="imp-file">' + esc(t('imp.file')) + '</label><input type="file" id="imp-file" accept=".csv,text/csv,text/plain">' +
        '<label for="imp-text">' + esc(t('imp.text')) + '</label><textarea id="imp-text" rows="8" spellcheck="false"></textarea><div id="imp-out"></div>';
    },
    mount: function () {
      $('imp-file').addEventListener('change', function (e) {
        var f = e.target.files && e.target.files[0]; if (!f) return;
        var rd = new FileReader();
        rd.onload = function () { $('imp-text').value = String(rd.result || ''); impReset(); };
        rd.readAsText(f, 'utf-8');
      });
    }});
};
function impReset() { if (!IMP) return; IMP.checked = null; var b = $('imp-run'); if (b) b.disabled = true; }
document.addEventListener('input', function (e) { if (e.target.id === 'imp-text') impReset(); });
function impShow(res, parsed) {
  var out = $('imp-out'); if (!out) return;
  var h = '<div class="msg ' + (res.errors && res.errors.length ? 'bad' : 'good') + '" id="imp-summary">' +
    esc(t(res.errors && res.errors.length ? 'imp.has_errors' : (res.dry_run ? 'imp.clean' : 'imp.done'), {rows: res.rows, created: res.created, updated: res.updated, n: (res.errors || []).length})) + '</div>';
  if (parsed && parsed.ignored.length) h += '<p class="muted" id="imp-ignored">' + esc(t('imp.ignored', {cols: parsed.ignored.join(', ')})) + '</p>';
  if (res.errors && res.errors.length) {
    h += '<div class="tbl-wrap"><table id="imp-errors"><thead><tr><th>' + esc(t('imp.col.row')) + '</th><th>' + esc(t('imp.col.field')) + '</th><th>' + esc(t('imp.col.problem')) + '</th></tr></thead><tbody>' +
      res.errors.slice(0, 200).map(function (e) { return '<tr><td>' + esc(e.row) + '</td><td>' + esc(e.field || '') + '</td><td>' + esc(e.message || e.code) + '</td></tr>'; }).join('') + '</tbody></table></div>' +
      (res.errors.length > 200 ? '<p class="muted">' + esc(t('imp.more_errors', {n: res.errors.length - 200})) + '</p>' : '');
  }
  out.innerHTML = h;
}
async function impCall(dry) {
  if (!IMP || IMP.busy) return;
  var text = val('imp-text'), parsed = csvObjects(text, IMP.tab.importCols), out = $('imp-out');
  if (!parsed.rows.length) { out.innerHTML = '<div class="msg bad">' + esc(t('imp.empty')) + '</div>'; return; }
  if (!dry && IMP.checked !== text) return;
  IMP.busy = true; $('imp-check').disabled = true; $('imp-run').disabled = true;
  var r = await api(IMP.tab.importRpc, {p_rows: parsed.rows, p_dry_run: dry}, {write: true});
  if (!IMP) return;
  IMP.busy = false; $('imp-check').disabled = false;
  if (!r.ok || !r.data) { out.innerHTML = '<div class="msg bad">' + esc(notSaved(r)) + '</div>' + (r.error && Array.isArray(r.error.detail) ? '<ul class="problems">' +
    r.error.detail.map(function (x) { return '<li>' + esc(x.message) + '</li>'; }).join('') + '</ul>' : ''); return; }
  impShow(r.data, parsed);
  if (dry && !(r.data.errors || []).length) { IMP.checked = text; $('imp-run').disabled = false; }
  if (!dry && !(r.data.errors || []).length && !r.data.dry_run) {
    var tab = IMP.tab; IMP = null; drawerClose(true);
    toast(t('imp.done', {rows: r.data.rows, created: r.data.created, updated: r.data.updated})); if (MD.tab === tab.id) mdLoad(true);
  }
}
ACT['imp-check'] = function () { impCall(true); };
ACT['imp-run'] = function () { impCall(false); };
