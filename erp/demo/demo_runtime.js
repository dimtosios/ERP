// iSmile ERP demo runtime. build_demo.py inlines it into demo.html BEFORE the smoke tests' stub client
// (erp/backend/tests/ui/mock_supabase_erp.js, reused as is) and BEFORE the app. It:
//  - gives the stub an in-memory control store (window.__ERP_DEMO.store: nothing goes to browser storage),
//  - replaces the stub's test fixtures with the demo seed (window.__ERP_DEMO_SEED = seed_demo.json),
//  - adds a small stock ledger (per warehouse quantity + value at average cost) behind on hand, stock card, item lookup,
//    negative-stock report and alerts, so goods receipts, consumption, transfers and adjustments move the numbers,
//  - numbers posted documents per series (TYPE-BRANCH/000001, OPN/000001),
//  - draws the "DEMO" banner with a role switcher (sign-out + sign-in as another demo member, no reload).
// Everything lives in this page's memory: a reload starts again from the seed.
(function () {
  'use strict';
  var SEED = window.__ERP_DEMO_SEED;
  var USERS = SEED.users, CUR = USERS[0];
  var store = {mock_session: '1', mock_role: CUR.role};
  function pad(n, w) { return String(n).padStart(w || 2, '0'); }
  function isoDay(n) { var d = new Date(); d.setHours(12, 0, 0, 0); d.setDate(d.getDate() - (n || 0)); return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  var TODAY = isoDay(0);
  function r2(n) { return Math.round(n * 100 + (n >= 0 ? 1e-9 : -1e-9)) / 100; }
  function r4(n) { return Math.round(n * 10000) / 10000; }
  function q4(n) { return Number(n).toFixed(4); }
  function by(arr, k, v) { for (var i = 0; i < arr.length; i++) if (arr[i][k] === v) return arr[i]; return null; }
  function fill(arr, rows) { arr.length = 0; rows.forEach(function (r) { arr.push(r); }); }
  function clear(o) { Object.keys(o).forEach(function (k) { delete o[k]; }); }
  function eanOk(b) {
    if (!/^\d{8}$|^\d{12,14}$/.test(b)) return false;
    var d = b.split('').map(Number), c = d.pop(), s = 0;
    d.reverse().forEach(function (x, i) { s += x * (i % 2 ? 1 : 3); });
    return (10 - s % 10) % 10 === c;
  }
  var M, H, X;                 // the stub's api, its handlers, its data arrays
  var BAL = {}, MOVES = [], MOVEID = 0, RESOLVED = {};
  window.__ERP_DEMO = {store: store, hook: hook};
  window.__erpDemo = {switchTo: switchTo, user: function () { return CUR; }, balance: function (wh, code) {
    var w = by(X.WHS.concat(X.TRANSIT), 'code', wh), it = by(X.ITEMS, 'code', code); var b = w && it && BAL[w.warehouse_id + '|' + it.item_id]; return b ? b.qty : 0; }};

  /* ---------- ledger ---------- */
  function bal(w, i) { var k = w + '|' + i; return BAL[k] || (BAL[k] = {warehouse_id: w, item_id: i, qty: 0, value: 0, last: 0, neg_since: null}); }
  function avg(w, i) { var b = BAL[w + '|' + i]; if (b && b.qty > 0) return b.value / b.qty; var it = by(X.ITEMS, 'item_id', i); return it ? Number(it.last_purchase_price) || 0 : 0; }
  function move(d, w, i, qty, value, date, kind) {
    var b = bal(w, i), was = b.qty;
    b.qty = r4(b.qty + qty); b.value = b.qty === 0 ? 0 : r2(b.value + value); b.last = ++MOVEID;
    MOVES.push({move_id: MOVEID, document_id: d.document_id, doc_type: d.doc_type, doc_no: d.doc_no, warehouse_id: w, item_id: i, qty: r4(qty), value: r2(value),
                move_date: date, kind: kind || 'normal', by: CUR.email});
    if (b.qty < 0 && was >= 0) b.neg_since = {date: date, doc_no: d.doc_no, by: CUR.email};
    if (b.qty >= 0) b.neg_since = null;
  }
  var IN = {OPN: 1, GRN: 1, ADJ_IN: 1}, OUT = {CONS: 1, ADJ_OUT: 1};
  function brCode(id) { var b = by(X.BR, 'branch_id', id); return b ? b.code : '?'; }
  function series(type, branch) {
    var code = type === 'OPN' ? 'OPN' : type + '-' + brCode(branch), s = by(X.SER, 'code', code);
    if (!s) {
      s = {series_id: 's-' + code, branch_id: type === 'OPN' ? null : branch, branch_code: type === 'OPN' ? null : brCode(branch), doc_type: type, code: code, fiscal_year: null,
           next_no: 1, last_no: null, gapless: type === 'TRF', numbering: 'local', is_default: true, active: true, in_use: false};
      X.SER.push(s);
    }
    return s;
  }
  function number(d) { var s = series(d.doc_type, d.branch_id), n = s.next_no++; s.last_no = n; s.in_use = true; d.number = n; d.doc_no = s.code + '/' + pad(n, 6); }
  function transition(d, before, after, o) {
    var date = d.doc_date || TODAY;
    if (after === 'cancelled' && (before === 'posted' || before === 'dispatched')) {   // reversal of every move of the document
      MOVES.filter(function (m) { return m.document_id === d.document_id && m.kind !== 'reversal'; }).forEach(function (m) { move(d, m.warehouse_id, m.item_id, -m.qty, -m.value, TODAY, 'reversal'); });
      return;
    }
    if (after === 'posted' && before !== 'posted') {
      number(d);
      if (!IN[d.doc_type] && !OUT[d.doc_type]) return;
      var tot = 0;
      (d.lines || []).forEach(function (l) {
        var q = Number(l.qty), w = d.warehouse_id, v;
        if (IN[d.doc_type]) {
          v = l.unit_price != null && l.unit_price !== '' ? (l.net != null && Number(l.net) ? Number(l.net) : q * Number(l.unit_price)) : q * avg(w, l.item_id);
          move(d, w, l.item_id, q, v, date);
          if (d.doc_type === 'GRN' && l.unit_price) { var it = by(X.ITEMS, 'item_id', l.item_id); if (it) it.last_purchase_price = Number(l.unit_price).toFixed(6); }
        } else { v = q * avg(w, l.item_id); move(d, w, l.item_id, -q, -v, date); }
        l.cost_value = r2(v).toFixed(2); tot += v;
      });
      d.total_cost = r2(tot).toFixed(2);
      return;
    }
    if (after === 'dispatched') {   // source -> transit at the source's average cost
      number(d);
      (d.lines || []).forEach(function (l) {
        var q = Number(l.qty), v = q * avg(d.warehouse_id, l.item_id);
        move(d, d.warehouse_id, l.item_id, -q, -v, date); move(d, 'wt', l.item_id, q, v, date, 'normal'); l.cost_value = r2(v).toFixed(2);
      });
      return;
    }
    if (after === 'received' || after === 'received_with_difference') {   // transit -> destination at the dispatch cost
      var x = X.TRFX[d.document_id] || {}, rd = o.receipt_date || TODAY;
      if (x.receipt) { x.receipt.received_by_email = CUR.email; x.receipt.received_at = rd + 'T10:00:00Z'; }
      (d.lines || []).forEach(function (l) {
        var sent = Number(l.qty), got = x.recv && x.recv[l.line_id] ? x.recv[l.line_id][0] : sent, q = Math.min(got, sent), unit = sent ? Number(l.cost_value || 0) / sent : 0;
        if (q > 0) { move(d, 'wt', l.item_id, -q, -q * unit, rd); move(d, d.dest_warehouse_id, l.item_id, q, q * unit, rd); }
      });
    }
  }

  /* ---------- handlers that need the ledger ---------- */
  function whOf(id) { return by(X.WHS, 'warehouse_id', id) || (id === 'wt' ? X.TRANSIT[0] : null); }
  function seeWh(w) { return !!w && (w.kind === 'in_transit' ? M.role() === 'owner' : M.mine(w.branch_id)); }
  function itemOf(id) { return by(X.ITEMS, 'item_id', id) || {}; }
  function balRow(b) {
    var w = whOf(b.warehouse_id), it = itemOf(b.item_id), min = it.min_level != null ? Number(it.min_level) : null;
    var o = {warehouse_id: b.warehouse_id, warehouse_code: w.code, branch_id: w.branch_id, item_id: b.item_id, item_code: it.code, item_name: it.name, unit_code: it.unit_code,
             qty: q4(b.qty), reserved: '0.0000', available: q4(b.qty), min_level: min != null ? q4(min) : null, low: w.kind !== 'in_transit' && min != null && b.qty >= 0 && b.qty < min,
             negative: b.qty < 0, avg_cost: (b.qty > 0 ? b.value / b.qty : avg(b.warehouse_id, b.item_id)).toFixed(6), value: r2(b.value).toFixed(2)};
    if (!M.can('cost.read')) { delete o.avg_cost; delete o.value; }
    return o;
  }
  function balances(f) {
    return Object.keys(BAL).map(function (k) { return BAL[k]; }).filter(function (b) { return seeWh(whOf(b.warehouse_id)) && (!f.warehouse_id || b.warehouse_id === f.warehouse_id); });
  }
  function sortRows(rows) { return rows.sort(function (a, b) { return a.item_code < b.item_code ? -1 : a.item_code > b.item_code ? 1 : (a.warehouse_code < b.warehouse_code ? -1 : 1); }); }
  function alerts() {
    var out = [];
    balances({}).forEach(function (b) {
      var r = balRow(b), w = whOf(b.warehouse_id), kind = r.negative ? 'negative_stock' : r.low ? 'low_stock' : null; if (!kind) return;
      var id = kind + ':' + b.warehouse_id + ':' + b.item_id, mv = by(MOVES, 'move_id', b.last) || {};
      if (RESOLVED[id] === b.last) return;
      out.push({alert_id: id, branch_id: w.branch_id, kind: kind, severity: r.negative ? 'warning' : 'info', message_key: 'alert.' + kind, created_at: (mv.move_date || TODAY) + 'T08:00:00Z',
                params: r.negative ? {item_code: r.item_code, warehouse_code: r.warehouse_code, qty: r.qty, doc_no: (b.neg_since || {}).doc_no || mv.doc_no}
                                   : {item_code: r.item_code, warehouse_code: r.warehouse_code, qty: r.qty, min_level: r.min_level}, _k: b.last});
    });
    return out.sort(function (a, b) { return b._k - a._k; }).map(function (a) { delete a._k; return Object.assign({can_resolve: M.can('alert.resolve')}, a); });
  }
  function days(from) { return Math.max(0, Math.round((new Date(TODAY + 'T12:00:00') - new Date(from + 'T12:00:00')) / 864e5)); }
  var STOCKDOC = {OPN: 1, GRN: 1, ADJ_IN: 1, ADJ_OUT: 1, CONS: 1};

  function override() {
    var whoami = H.whoami;
    H.whoami = function (a) {
      var r = whoami(a); if (r.error) return r;
      r.data.member_id = 'm-' + CUR.key; r.data.email = CUR.email; r.data.display_name = CUR.name; r.data.today = TODAY;
      r.data.tenant = {tenant_id: 't-demo', code: SEED.tenant.code, name: SEED.tenant.name, plan: 'demo'};
      return r;
    };
    H.stock_on_hand = function (a) {
      if (!M.can('stock.read')) return M.err('ERP_FORBIDDEN', 'no');
      var f = a.p_filter || {}, q = String(f.q || '').toLowerCase();
      var rows = sortRows(balances(f).map(balRow).filter(function (r) {
        var it = itemOf(r.item_id);
        return (!f.only || (f.only === 'low' && r.low) || (f.only === 'negative' && r.negative)) &&
          (!q || r.item_code.toLowerCase().indexOf(q) === 0 || r.item_name.toLowerCase().indexOf(q) >= 0 || (it.barcodes || []).indexOf(f.q) >= 0);
      }));
      return {data: M.page(rows, a, function (r) { return r.item_code + r.warehouse_code; }), error: null};
    };
    H.stock_card = function (a) {
      if (!M.can('stock.read')) return M.err('ERP_FORBIDDEN', 'no');
      var f = a.p_filter || {}, it = itemOf(a.p_item_id), run = 0;
      var rows = MOVES.filter(function (m) { return m.item_id === a.p_item_id && (!f.warehouse_id || m.warehouse_id === f.warehouse_id) && seeWh(whOf(m.warehouse_id)); }).map(function (m) {
        run = r4(run + m.qty);
        var o = {move_id: m.move_id, move_date: m.move_date, kind: m.kind, doc_type: m.doc_type, doc_no: m.doc_no, warehouse_code: whOf(m.warehouse_id).code, qty: q4(m.qty), running_qty: q4(run),
                 value: m.value.toFixed(2), provisional: false};
        if (!M.can('cost.read')) delete o.value;
        return o;
      });
      return {data: {rows: rows.slice(-(a.p_limit || 200)), next: null, opening_qty: '0.0000', item: {item_id: it.item_id, code: it.code, name: it.name}}, error: null};
    };
    H.item_lookup = function (a) {
      if (!M.can('item.read')) return M.err('ERP_FORBIDDEN', 'no');
      var q = String(a.p_query || '').trim(), ql = q.toLowerCase(), act = X.ITEMS.filter(function (i) { return i.active; });
      var hits = act.filter(function (i) { return i.code.toLowerCase() === ql || (i.barcodes || []).indexOf(q) >= 0; });
      if (!hits.length) hits = act.filter(function (i) { return i.code.toLowerCase().indexOf(ql) === 0 || i.name.toLowerCase().indexOf(ql) >= 0; });
      return {data: {rows: hits.slice(0, a.p_limit || 10).map(function (i) {
        var oh = a.p_warehouse_id ? bal(a.p_warehouse_id, i.item_id).qty : balances({}).filter(function (b) { return b.item_id === i.item_id; }).reduce(function (s, b) { return s + b.qty; }, 0);
        return {item_id: i.item_id, code: i.code, name: i.name, unit_code: i.unit_code, base_unit_id: i.base_unit_id, on_hand: q4(oh), barcode_match: (i.barcodes || []).indexOf(q) >= 0};
      })}, error: null};
    };
    H.report_negative_stock = function (a) {
      if (!M.can('stock.read')) return M.err('ERP_FORBIDDEN', 'no');
      var rows = sortRows(balances(a.p_filter || {}).filter(function (b) { return b.qty < 0; }).map(function (b) {
        var r = balRow(b), ns = b.neg_since || {};
        var o = {warehouse_id: r.warehouse_id, warehouse_code: r.warehouse_code, item_id: r.item_id, item_code: r.item_code, item_name: r.item_name, qty: r.qty,
                 days_negative: days(ns.date || TODAY), doc_no: ns.doc_no || null, posted_by_email: ns.by || null};
        if (M.can('cost.read')) o.provisional_value = Math.abs(r2(b.value)).toFixed(2);
        return o;
      }));
      return {data: {rows: rows, next: null}, error: null};
    };
    H.alert_list = function (a) {
      if (!M.can('alert.read')) return M.err('ERP_FORBIDDEN', 'no');
      return {data: M.page(alerts(), a, function (r) { return r.alert_id; }), error: null};
    };
    H.alert_resolve = function (a) {
      if (!M.can('alert.resolve')) return M.err('ERP_FORBIDDEN', 'no');
      var p = String(a.p_alert_id || '').split(':'), b = BAL[p[1] + '|' + p[2]];
      if (!b) return M.err('ERP_TENANT', 'not yours');
      RESOLVED[a.p_alert_id] = b.last;
      return {data: {alert_id: a.p_alert_id, resolved_at: new Date().toISOString()}, error: null};
    };
    var docList = H.doc_list;
    H.doc_list = function (a) {   // stock documents: own branch only (the stub lists every branch); newest date first
      var r = docList(Object.assign({}, a, {p_limit: 100000, p_cursor: null})); if (r.error) return r;
      var rows = r.data.rows.filter(function (d) { return !STOCKDOC[d.doc_type] || M.mine(d.branch_id); });
      rows = rows.map(function (d, i) { return [d, i]; }).sort(function (x, y) { return x[0].doc_date === y[0].doc_date ? x[1] - y[1] : (x[0].doc_date < y[0].doc_date ? 1 : -1); }).map(function (x) { return x[0]; });
      return {data: M.page(rows, a, function (d) { return d.document_id; }), error: null};
    };
    var setState = H.doc_set_state;
    H.doc_set_state = function (a) {
      var d = by(X.DOCS, 'document_id', a.p_document_id);
      if (!d) return setState(a);
      clear(X.STOCKQ); (d.lines || []).forEach(function (l) { if (l.item_id && d.warehouse_id) X.STOCKQ[l.item_id] = bal(d.warehouse_id, l.item_id).qty; });   // the stub's warning check reads STOCKQ
      var before = d.state, r = setState(a);
      if (r.error || !r.data || d.state === before) return r;
      transition(d, before, d.state, a.p_options || {});
      if (d.ref_document_id) { var p = by(X.DOCS, 'document_id', d.ref_document_id); if (p && p.state === 'closed' && X.TRFX[p.document_id]) X.TRFX[p.document_id].receipt.closed_at = TODAY + 'T11:00:00Z'; }
      r.data.document = M.docOut(d);
      return r;
    };
    H.item_import = function (a) {
      if (!M.can('item.write')) return M.err('ERP_FORBIDDEN', 'no');
      var rows = a.p_rows || [], errs = [], seen = {}, created = 0, updated = 0;
      rows.forEach(function (r, i) {
        function e(field, code, msg) { errs.push({row: i + 1, code: code, field: field, message: msg}); }
        var code = String(r.code || '').trim().toUpperCase(), cur = code ? by(X.ITEMS, 'code', code) : null;
        if (!code) e('code', 'required', 'Code is required.');
        else if (seen[code]) e('code', 'duplicate', 'Code ' + code + ' appears twice in the file (row ' + seen[code] + ').');
        else seen[code] = i + 1;
        if (!r.name && !cur) e('name', 'required', 'Name is required for a new item.');
        if (!r.unit && !cur) e('unit', 'required', 'Unit is required for a new item.');
        else if (r.unit && !by(X.UNITS, 'code', String(r.unit).toUpperCase())) e('unit', 'unknown', 'Unit ' + r.unit + ' does not exist.');
        if (r.vat && !by(X.VATS, 'code', String(r.vat).toUpperCase())) e('vat', 'unknown', 'VAT class ' + r.vat + ' does not exist.');
        if (r.category && !by(X.CATS, 'code', String(r.category).toUpperCase())) e('category', 'unknown', 'Category ' + r.category + ' does not exist.');
        if (r.kind && ['goods', 'consumable', 'service'].indexOf(r.kind) < 0) e('kind', 'invalid', 'Kind must be goods, consumable or service.');
        ['min_level', 'reorder_level', 'sales_price'].forEach(function (k) {
          if (r[k] != null && !(Number(String(r[k]).replace(',', '.')) >= 0)) e(k, 'invalid', k + ' must be a number, 0 or more.');
        });
        String(r.barcodes || '').split(/[;|\s]+/).filter(Boolean).forEach(function (b) {
          if (!eanOk(b)) e('barcodes', 'invalid', 'Barcode ' + b + ' is not a valid EAN (check digit).');
          else { var o = X.ITEMS.find(function (x) { return (x.barcodes || []).indexOf(b) >= 0; }); if (o && o.code !== code) e('barcodes', 'duplicate', 'Barcode ' + b + ' belongs to ' + o.code + '.'); }
        });
        if (cur) updated++; else created++;
      });
      if (!errs.length && !a.p_dry_run) rows.forEach(function (r) {
        var code = String(r.code).trim().toUpperCase(), cur = by(X.ITEMS, 'code', code), u = r.unit ? by(X.UNITS, 'code', String(r.unit).toUpperCase()) : null;
        var v = r.vat ? by(X.VATS, 'code', String(r.vat).toUpperCase()) : null, c = r.category ? by(X.CATS, 'code', String(r.category).toUpperCase()) : null;
        var it = cur || {item_id: 'i-' + code, code: code, kind: 'consumable', lot_tracked: false, active: true, barcodes: [], version: 0, vat_class_id: 'v24', vat_code: 'VAT24',
                         category_id: null, category_code: null, min_level: null, reorder_level: null, sales_price: null, last_purchase_price: null};
        if (r.name) it.name = r.name; if (r.kind) it.kind = r.kind;
        if (u) { it.base_unit_id = u.unit_id; it.unit_code = u.code; }
        if (v) { it.vat_class_id = v.vat_class_id; it.vat_code = v.code; }
        if (c) { it.category_id = c.category_id; it.category_code = c.code; }
        ['min_level', 'reorder_level', 'sales_price'].forEach(function (k) { if (r[k] != null) it[k] = String(r[k]).replace(',', '.'); });
        if (r.barcodes) it.barcodes = String(r.barcodes).split(/[;|\s]+/).filter(Boolean);
        if (r.active != null) it.active = !/^(false|no|0)$/i.test(r.active);
        it.version++;
        if (!cur) X.ITEMS.push(it);
        X.ITEMBY[it.code] = {item_id: it.item_id, name: it.name}; (it.barcodes || []).forEach(function (b) { X.ITEMBY[b] = {item_id: it.item_id, name: it.name, code: it.code}; });
      });
      return {data: {dry_run: !!a.p_dry_run || errs.length > 0, rows: rows.length, created: created, updated: updated, errors: errs}, error: null};
    };
    var orig = window.supabase.createClient;   // sign-in on the login form: any password; the email picks the demo member
    window.supabase.createClient = function () {
      var c = orig.apply(this, arguments), si = c.auth.signInWithPassword;
      c.auth.signInWithPassword = async function (cr) {
        var u = by(USERS, 'email', String(cr.email || '').trim().toLowerCase());
        if (!u) return {data: null, error: {message: 'Demo: sign in with one of the demo emails (see the banner), any password.'}};
        select(u); return si({email: cr.email, password: 'right-password'});
      };
      return c;
    };
  }

  /* ---------- seed ---------- */
  function load() {
    var S = SEED, D = X;
    fill(D.BR, S.branches.map(function (b, i) { return {branch_id: b.id, code: b.code, name: b.name, establishment_no: i, address: b.address, active: true}; }));
    var normal = S.warehouses.filter(function (w) { return w.kind !== 'in_transit'; }), tr = S.warehouses.filter(function (w) { return w.kind === 'in_transit'; });
    function whRow(w) { return {warehouse_id: w.id, branch_id: w.branch, branch_code: w.branch ? brCode(w.branch) : null, code: w.code, name: w.name, kind: w.kind || 'normal', active: true}; }
    fill(D.WHS, normal.map(whRow)); fill(D.ALLWHS, normal.map(whRow)); D.TRANSIT = tr.map(whRow);
    fill(D.UNITS, S.units.map(function (u) { return {unit_id: 'u-' + u.code, code: u.code, name: u.name, decimals: 0, active: true}; }));
    fill(D.VATS, S.vat_classes.map(function (v) { return {vat_class_id: v.id, code: v.code, name: v.name, rate: v.rate, mydata_category: v.mydata_category, exemption_code: null, active: true}; }));
    fill(D.CATS, []);
    S.item_categories.forEach(function (c) {
      var p = c.parent ? by(D.CATS, 'code', c.parent) : null;
      D.CATS.push({category_id: 'c-' + c.code, parent_id: p ? p.category_id : null, code: c.code, name: c.name, path: (p ? p.path + ' / ' : '') + c.code, active: true});
    });
    fill(D.ITEMS, S.items.map(function (it) {
      var c = by(D.CATS, 'code', it.category), v = by(D.VATS, 'code', it.vat);
      return {item_id: 'i-' + it.code, code: it.code, name: it.name, kind: 'consumable', base_unit_id: 'u-' + it.unit, unit_code: it.unit, lot_tracked: false, active: true,
              barcodes: [it.barcode], category_id: c.category_id, category_code: c.code, vat_class_id: v.vat_class_id, vat_code: v.code, min_level: String(it.min_level),
              reorder_level: String(it.min_level * 2), sales_price: null, last_purchase_price: it.cost.toFixed(6), version: 1};
    }));
    clear(D.ITEMBY); D.ITEMS.forEach(function (i) { D.ITEMBY[i.code] = {item_id: i.item_id, name: i.name}; i.barcodes.forEach(function (b) { D.ITEMBY[b] = {item_id: i.item_id, name: i.name, code: i.code}; }); });
    fill(D.CPS, S.suppliers.map(function (s) { return {counterparty_id: 'p-' + s.code, code: s.code, kind: 'supplier', name: s.name, tax_id: s.tax_id, tax_office: s.tax_office, country: 'GR',
      city: s.city, phone: s.phone, active: true, version: 1}; }));
    fill(D.EXPCATS, []);
    S.expense_categories.forEach(function (c) {
      var p = c.parent ? by(D.EXPCATS, 'code', c.parent) : null, v = by(D.VATS, 'code', c.vat);
      D.EXPCATS.push({category_id: 'ec-' + c.code, parent_id: p ? p.category_id : null, code: c.code, name: c.name, path: (p ? p.path + ' / ' : '') + c.code,
                      default_vat_class_id: v.vat_class_id, vat_code: v.code, vat_rate: v.rate, active: c.active !== false});
    });
    fill(D.TYPES, [['OPN', 'Opening balance', 'warehouse', 'tenant'], ['GRN', 'Goods receipt', 'purchasing', 'branch'], ['ADJ_IN', 'Adjustment +', 'warehouse', 'branch'],
                   ['ADJ_OUT', 'Adjustment -', 'warehouse', 'branch'], ['CONS', 'Consumption', 'warehouse', 'branch'], ['TRF', 'Transfer', 'warehouse', 'branch'],
                   ['EXP', 'Expense', 'purchasing', 'branch'], ['DN', 'Delivery note', 'sales', 'branch']].map(function (t) {
      return {doc_type: t[0], name: t[1], area: t[2], fiscal: t[0] === 'DN', series_scope: t[3], enabled: t[0] !== 'DN'}; }));
    fill(D.SER, []); series('OPN', null);
    D.BR.forEach(function (b) { ['GRN', 'ADJ_IN', 'ADJ_OUT', 'CONS', 'TRF', 'EXP'].forEach(function (t) { series(t, b.branch_id); }); });
    fill(D.MEM, USERS.map(function (u) { return {member_id: 'm-' + u.key, email: u.email, display_name: u.name, role: u.role, branch_ids: u.home ? [u.home] : [], all_branches: !u.home,
      active: true, status: 'active', invited_at: isoDay(60) + 'T09:00:00Z', bound_at: isoDay(59) + 'T09:00:00Z'}; }).concat((S.extra_members || []).map(function (m, i) {
      return {member_id: 'm-x' + i, email: m.email, display_name: m.name, role: m.role, branch_ids: [m.home], all_branches: false, active: true, status: m.pending ? 'pending' : 'active',
              invited_at: isoDay(20) + 'T09:00:00Z', bound_at: m.pending ? null : isoDay(19) + 'T09:00:00Z'}; })));
    fill(D.DOCS, []); fill(D.ONHAND, []); fill(D.ALERTS, []); clear(D.TRFX); clear(D.STOCKQ);
    Object.assign(D.SET, {time_zone: S.settings.time_zone, negative_stock: S.settings.negative_stock, thresholds: {exp_value: S.settings.exp_limit}});
    // opening stock, then the documents in date order, each by its own member through the stub's own save / post handlers
    var whCode = function (c) { return by(D.WHS, 'code', c); }, itC = function (c) { return by(D.ITEMS, 'code', c); };
    function as(key) { var u = by(USERS, 'key', key || 'owner'); select(u); }
    function ok(r, what) { if (r.error || !r.data) throw new Error('demo seed: ' + what + ': ' + JSON.stringify(r.error)); return r.data; }
    function post(id, to, opts) { var r = ok(H.doc_set_state({p_document_id: id, p_to_state: to, p_options: Object.assign({ack_warnings: true}, opts || {})}), 'post ' + id); return r; }
    as('owner');
    D.WHS.forEach(function (w) {
      var f = S.opening.factor[w.code] || 1;
      var d = ok(H.doc_save_draft({p_type: 'OPN', p_doc: {branch_id: w.branch_id, warehouse_id: w.warehouse_id, doc_date: isoDay(S.opening.days_ago), notes: 'Opening stock',
        lines: S.items.map(function (it) { return {item_id: 'i-' + it.code, qty: String(Math.ceil(it.min_level * f)), unit_price: String(it.cost)}; })}}), 'OPN');
      post(d.document_id, 'posted');
    });
    S.documents.slice().sort(function (a, b) { return b.days_ago - a.days_ago; }).forEach(function (s) {
      as(s.user);
      var p = {doc_date: isoDay(s.days_ago), lines: []}, d;
      if (s.type === 'EXP') {
        var br = by(D.BR, 'code', s.branch);
        p.branch_id = br.branch_id; p.warehouse_id = null; p.counterparty_id = s.supplier ? 'p-' + s.supplier : null; p.ext_number = s.ext_number || ''; p.ext_date = p.doc_date;
        p.extra = s.paid ? {paid: true, payment_method: s.method} : {paid: false};
        p.lines = s.lines.map(function (l) { var c = by(D.EXPCATS, 'code', l[0]); return {expense_category_id: c.category_id, qty: 1, vat_class_id: c.default_vat_class_id, unit_price: String(l[2]), description: l[1]}; });
      } else {
        var w = whCode(s.wh); p.warehouse_id = w.warehouse_id; p.branch_id = w.branch_id;
        if (s.supplier) p.counterparty_id = 'p-' + s.supplier;
        if (s.ext_number) { p.ext_number = s.ext_number; p.ext_date = p.doc_date; }
        if (s.type === 'CONS') p.extra = s.cost_centre ? {cost_centre: s.cost_centre} : {};
        if (s.type === 'TRF') { p.dest_warehouse_id = whCode(s.dest).warehouse_id; p.extra = s.carrier ? {delivery: {carrier: s.carrier}} : {}; }
        p.lines = s.lines.map(function (l) { var o = {item_id: itC(l[0]).item_id, qty: String(l[1])}; if (l[2] != null) o.unit_price = String(l[2]); return o; });
      }
      d = ok(H.doc_save_draft({p_type: s.type, p_doc: p}), s.type);
      post(d.document_id, s.type === 'TRF' ? 'dispatched' : 'posted');
      if (s.receive) {
        as(s.receive.user);
        var doc = by(D.DOCS, 'document_id', d.document_id), diff = false;
        var lines = doc.lines.map(function (l) {
          var x = (s.receive.lines || {})[l.item_id.slice(2)];   // item_id = 'i-' + code
          if (x) { diff = true; return {line_id: l.line_id, received_qty: String(x[0]), reason: x[1]}; }
          return {line_id: l.line_id, received_qty: String(Number(l.qty))};
        });
        post(d.document_id, diff ? 'received_with_difference' : 'received', {receipt_date: isoDay(s.receive.days_ago), lines: lines});
      }
    });
    window.__calls.length = 0;
    as('owner');
  }

  /* ---------- members / role switcher ---------- */
  function select(u) { CUR = u; M.setRole(u.role, u.home || 'b1'); store.mock_role = u.role; }
  function switchTo(key) {
    var u = by(USERS, 'key', key); if (!u) return;
    select(u); store.mock_session = '1';
    var s = document.getElementById('demo-role'); if (s) s.value = key;
    M.emit('SIGNED_OUT'); setTimeout(function () { M.emit('SIGNED_IN'); }, 60);
  }
  function banner() {
    var b = document.createElement('div'); b.id = 'demo-banner'; b.setAttribute('role', 'note');
    b.innerHTML = '<style>#demo-banner{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:6px 12px;align-items:center;padding:7px 12px;' +
      'background:var(--warn-soft);color:var(--ink);border-bottom:2px solid var(--warn);font:13px/1.4 var(--font)}#demo-banner b{color:var(--warn)}' +
      '#demo-banner select{width:auto;padding:3px 6px;font:inherit}#demo-banner .grow{flex:1}</style>' +
      '<span><b>DEMO</b> - sample data, nothing is saved (reload = start again)</span><span class="grow"></span>' +
      '<label for="demo-role">View as</label><select id="demo-role">' + USERS.map(function (u) { return '<option value="' + u.key + '">' + u.label + '</option>'; }).join('') + '</select>';
    document.body.insertBefore(b, document.body.firstChild);
    b.querySelector('#demo-role').addEventListener('change', function (e) { switchTo(e.target.value); });
  }

  function hook(api) {
    M = api; H = api.H; X = api.data;
    override(); load();   // seeding goes through the wrapped handlers (ledger, numbering)
    if (document.body) banner(); else document.addEventListener('DOMContentLoaded', banner);
  }
})();
