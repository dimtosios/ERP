// Stub of supabase-js for the ERP smoke tests: no network. Emulates Auth and the erp_api RPCs the page calls.
// Controls (localStorage, set by the test before the page loads):
//   mock_session '1' = signed in;  mock_role = owner | manager | warehouse | accounting | clinic_user | readonly | none
//   mock_fail = comma list of RPC names that answer ERP_VALIDATION;  mock_null = comma list that answer null (0 rows)
//   mock_conflict '1' = member_bind answers bound_to_other_login
//   mock_exp_limit = a number: the expense approval limit (thresholds.exp_value) the page starts with
// Demo build (erp/demo/build_demo.py): window.__ERP_DEMO = {store, hook}. The controls above are then read from the in-memory
// `store` (never from browser storage) and `hook(api)` runs once at the end to load the demo seed and wrap handlers.
(function () {
  var CALLS = window.__calls = [];
  var DEMO = window.__ERP_DEMO || null;
  function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
  function ls(k) { if (DEMO) return has(DEMO.store, k) ? DEMO.store[k] : null; try { return localStorage.getItem(k); } catch (e) { return null; } }
  function lsSet(k, v) {
    if (DEMO) { if (v == null) delete DEMO.store[k]; else DEMO.store[k] = v; return; }
    try { if (v == null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) {}
  }
  var ROLE = ls('mock_role') || 'owner';
  var HOME = 'b1';   // the one branch of a non-owner member (the demo's role switcher changes it)
  var FAIL = (ls('mock_fail') || '').split(',').filter(Boolean);
  var NULLS = (ls('mock_null') || '').split(',').filter(Boolean);
  // mirror of erp.role_cap_defaults (E100 / E110 / E120 seeds)
  var MASTER_O = ['item.read', 'item.detail.read', 'item.write', 'master.archive', 'vat.read', 'vat.write', 'cost.read', 'counterparty.archive',
                  'warehouse.read', 'warehouse.write', 'counterparty.read', 'counterparty.write', 'series.read'];
  var CAPS = {
    owner: ['tenant.settings.read', 'tenant.settings.write', 'member.read', 'member.manage', 'branch.read', 'branch.write', 'audit.read', 'alert.read', 'alert.resolve']
      .concat(MASTER_O, ['series.write']),
    manager: ['tenant.settings.read', 'member.read', 'branch.read', 'audit.read', 'alert.read', 'alert.resolve'].concat(MASTER_O),
    warehouse: ['branch.read', 'alert.read', 'item.read', 'item.detail.read', 'item.write', 'vat.read', 'warehouse.read', 'warehouse.write', 'counterparty.read'],
    accounting: ['tenant.settings.read', 'member.read', 'branch.read', 'audit.read', 'alert.read', 'item.read', 'item.detail.read', 'vat.read', 'vat.write', 'cost.read',
                 'warehouse.read', 'counterparty.read', 'counterparty.write', 'series.read'],
    clinic_user: ['branch.read', 'alert.read', 'item.read', 'warehouse.read'],
    readonly: ['branch.read', 'alert.read', 'item.read', 'item.detail.read', 'vat.read', 'cost.read', 'warehouse.read', 'counterparty.read']
  };
  // E150 (T11 / T12) document capabilities + stock.read
  var DOCCAPS = {
    owner: ['opn.read', 'opn.create', 'opn.approve', 'grn.read', 'grn.create', 'grn.approve', 'adj.read', 'adj.create', 'adj.approve', 'cons.read', 'cons.create', 'cons.approve',
            'trf.read', 'trf.create', 'trf.approve', 'exp.read', 'exp.create', 'exp.approve'],
    manager: ['opn.read', 'opn.create', 'grn.read', 'grn.create', 'grn.approve', 'adj.read', 'adj.create', 'adj.approve', 'cons.read', 'cons.create', 'cons.approve',
              'trf.read', 'trf.create', 'trf.approve', 'exp.read', 'exp.create', 'exp.approve'],
    warehouse: ['opn.read', 'grn.read', 'grn.create', 'adj.read', 'adj.create', 'cons.read', 'cons.create', 'trf.read', 'trf.create', 'exp.read'],
    accounting: ['opn.read', 'grn.read', 'adj.read', 'cons.read', 'trf.read', 'exp.read', 'exp.create'],
    clinic_user: ['cons.read', 'cons.create'],
    readonly: ['opn.read', 'grn.read', 'adj.read', 'cons.read', 'trf.read', 'exp.read']
  };
  Object.keys(CAPS).forEach(function (r) { CAPS[r] = CAPS[r].concat(DOCCAPS[r].map(function (c) { return 'doc.' + c; }), ['stock.read']); });
  ['owner', 'manager', 'accounting'].forEach(function (r) { CAPS[r].push('expense.category.write'); });   // E180 (T19)
  var BR = [
    {branch_id: 'b1', code: 'SER', name: 'Serres', establishment_no: 0, address: 'Serres', active: true},
    {branch_id: 'b2', code: 'THE', name: 'Thessaloniki', establishment_no: 1, address: null, active: true},
    {branch_id: 'b3', code: 'ALE', name: 'Alexandreia', establishment_no: 2, address: null, active: true}
  ];
  var MEM = [];
  for (var i = 0; i < 65; i++) MEM.push({member_id: 'm' + i, email: 'person' + String(i).padStart(2, '0') + '@clinic.test', display_name: i % 3 ? 'Person ' + i : null,
    role: ['manager', 'warehouse', 'clinic_user', 'accounting', 'readonly'][i % 5], branch_ids: [BR[i % 3].branch_id], all_branches: false,
    active: i % 11 !== 5, status: i % 11 === 5 ? 'inactive' : (i % 4 === 0 ? 'pending' : 'active'), invited_at: '2026-11-10T09:00:00Z', bound_at: i % 4 === 0 ? null : '2026-11-11T09:00:00Z'});
  MEM.unshift({member_id: 'm-owner', email: 'owner@clinic.test', display_name: 'The Owner', role: 'owner', branch_ids: [], all_branches: true, active: true,
    status: 'active', invited_at: '2026-11-01T09:00:00Z', bound_at: '2026-11-01T09:05:00Z'});
  // master data (E120)
  var UNITS = [{unit_id: 'u1', code: 'PCS', name: 'Pieces', decimals: 0, active: true}, {unit_id: 'u2', code: 'BOX', name: 'Box', decimals: 0, active: true},
               {unit_id: 'u3', code: 'KG', name: 'Kilogram', decimals: 3, active: true}];
  var CATS = [{category_id: 'c1', parent_id: null, code: 'ORTHO', name: 'Orthodontics', path: 'ORTHO', active: true},
              {category_id: 'c2', parent_id: 'c1', code: 'BRK', name: 'Brackets', path: 'ORTHO / BRK', active: true}];
  var VATS = [{vat_class_id: 'v1', code: 'VAT24', name: 'VAT 24%', rate: '24.00', mydata_category: 1, exemption_code: null, active: true},
              {vat_class_id: 'v2', code: 'VAT13', name: 'VAT 13%', rate: '13.00', mydata_category: 2, exemption_code: null, active: true}];
  var ITEMS = [];
  for (var j = 0; j < 70; j++) ITEMS.push({item_id: 'i' + j, code: 'IT-' + String(j).padStart(3, '0'), name: (j % 2 ? 'Bracket ' : 'Wire ') + j, kind: j % 7 ? 'consumable' : 'goods',
    base_unit_id: 'u1', unit_code: 'PCS', lot_tracked: false, active: j % 13 !== 5, barcodes: j === 3 ? ['4006381333931'] : [], category_id: j % 3 ? 'c2' : null,
    category_code: j % 3 ? 'BRK' : null, vat_class_id: 'v1', vat_code: 'VAT24', min_level: null, reorder_level: null, sales_price: '12.5000', last_purchase_price: '7.250000', version: 1});
  var WHS = [{warehouse_id: 'w1', branch_id: 'b1', branch_code: 'SER', code: 'SER-MAIN', name: 'Serres main', kind: 'normal', active: true},
             {warehouse_id: 'w2', branch_id: 'b2', branch_code: 'THE', code: 'THE-MAIN', name: 'Thessaloniki main', kind: 'normal', active: true}];
  var CPS = [{counterparty_id: 'p1', code: 'SUP1', kind: 'supplier', name: 'Ortho Supplies SA', tax_id: '094014201', country: 'GR', city: 'Serres', active: true, version: 1},
             {counterparty_id: 'p2', code: null, kind: 'both', name: 'Dental GmbH', tax_id: 'DE123456789', country: 'DE', city: 'Berlin', active: true, version: 3}];
  var SER = [{series_id: 's1', branch_id: 'b1', branch_code: 'SER', doc_type: 'GRN', code: 'GRN-SER', fiscal_year: null, next_no: 18, last_no: 17, gapless: false, numbering: 'local',
              is_default: true, active: true, in_use: true}];
  var TYPES = [{doc_type: 'GRN', name: 'Goods receipt', area: 'purchasing', fiscal: false, series_scope: 'branch', enabled: true},
               {doc_type: 'OPN', name: 'Opening balance', area: 'warehouse', fiscal: false, series_scope: 'tenant', enabled: true},
               {doc_type: 'DN', name: 'Delivery note', area: 'sales', fiscal: true, series_scope: 'branch', enabled: false}];
  var NEXTID = 100;
  // stock (E140 / E150)
  var ONHAND = [
    {warehouse_id: 'w1', warehouse_code: 'SER-MAIN', branch_id: 'b1', item_id: 'i1', item_code: 'IT-001', item_name: 'Bracket 1', unit_code: 'PCS', qty: '25.0000', reserved: '0.0000',
     available: '25.0000', min_level: '30.0000', low: true, negative: false, avg_cost: '4.500000', value: '112.50'},
    {warehouse_id: 'w1', warehouse_code: 'SER-MAIN', branch_id: 'b1', item_id: 'i2', item_code: 'IT-002', item_name: 'Wire 2', unit_code: 'PCS', qty: '-3.0000', reserved: '0.0000',
     available: '-3.0000', min_level: null, low: false, negative: true, avg_cost: '2.000000', value: '-6.00'},
    {warehouse_id: 'w2', warehouse_code: 'THE-MAIN', branch_id: 'b2', item_id: 'i1', item_code: 'IT-001', item_name: 'Bracket 1', unit_code: 'PCS', qty: '4.0000', reserved: '0.0000',
     available: '4.0000', min_level: '30.0000', low: true, negative: false, avg_cost: '4.500000', value: '18.00'}];
  var STOCKQ = {i1: 25, i2: -3, i3: 100};
  var DOCS = [{document_id: 'd1', doc_type: 'GRN', state: 'posted', branch_id: 'b1', warehouse_id: 'w1', warehouse_code: 'SER-MAIN', counterparty_id: 'p1', counterparty_name: 'Ortho Supplies SA',
               doc_no: 'GRN-SER/000017', number: 17, doc_date: '2026-11-17', total_net: '45.00', total_cost: '45.00', version: 2,
               lines: [{line_id: 'l1', line_no: 1, item_id: 'i1', item_code: 'IT-001', item_name: 'Bracket 1', qty: '10.0000', qty_base: '10.0000', unit_price: '4.5000', net: '45.00', cost_value: '45.00'}]}];
  var ALERTS = [{alert_id: 'al1', branch_id: 'b1', kind: 'negative_stock', severity: 'warning', message_key: 'alert.negative_stock', created_at: '2026-11-18T08:00:00Z',
                 params: {item_code: 'IT-002', warehouse_code: 'SER-MAIN', qty: '-3.0000', doc_no: 'CONS-SER/000004'}},
                {alert_id: 'al2', branch_id: 'b1', kind: 'low_stock', severity: 'info', message_key: 'alert.low_stock', created_at: '2026-11-18T07:00:00Z',
                 params: {item_code: 'IT-001', warehouse_code: 'SER-MAIN', qty: '25.0000', min_level: '30.0000'}}];
  // E160 (T16 / T18): transfers. t1 SER -> THE dispatched (source side for b1); t2 THE -> SER dispatched (b1 receives)
  DOCS.push({document_id: 't1', doc_type: 'TRF', state: 'dispatched', branch_id: 'b1', warehouse_id: 'w1', warehouse_code: 'SER-MAIN', dest_warehouse_id: 'w2', doc_no: 'TRF-SER/000001',
             doc_date: '2026-11-16', version: 2, extra: {}, lines: [{line_id: 't1-0', line_no: 1, item_id: 'i1', item_code: 'IT-001', item_name: 'Bracket 1', qty: '4.0000', qty_base: '4.0000'}]},
            {document_id: 't2', doc_type: 'TRF', state: 'dispatched', branch_id: 'b2', warehouse_id: 'w2', warehouse_code: 'THE-MAIN', dest_warehouse_id: 'w1', doc_no: 'TRF-THE/000003',
             doc_date: '2026-11-17', version: 2, extra: {}, lines: [{line_id: 't2-0', line_no: 1, item_id: 'i1', item_code: 'IT-001', item_name: 'Bracket 1', qty: '2.0000', qty_base: '2.0000'},
                                                                 {line_id: 't2-1', line_no: 2, item_id: 'i3', item_code: 'IT-003', item_name: 'Elastic 3', qty: '6.0000', qty_base: '6.0000'}]});
  var TRFX = {};   // transfer id -> {receipt, recv: {line_id: [qty, reason]}, adj: [doc ids]}
  var ALLWHS = WHS.concat([{warehouse_id: 'w3', branch_id: 'b3', branch_code: 'ALE', code: 'ALE-MAIN', name: 'Alexandreia main', kind: 'normal', active: true}]);
  function whBranch(id) { var w = ALLWHS.find(function (x) { return x.warehouse_id === id; }); return w ? w.branch_id : null; }
  function mine(br) { return ROLE === 'owner' || br === HOME; }
  function trfVisible(d) { return mine(d.branch_id) || (d.state !== 'draft' && mine(whBranch(d.dest_warehouse_id))); }
  function trfOut(d) {
    var o = docOut(d), x = TRFX[d.document_id] || {};
    o.transfer = {source_branch_id: d.branch_id, dest_branch_id: whBranch(d.dest_warehouse_id), dest_warehouse_code: (ALLWHS.find(function (w) { return w.warehouse_id === d.dest_warehouse_id; }) || {}).code,
      fiscal_needed: whBranch(d.dest_warehouse_id) !== d.branch_id, receipt: x.receipt || null,
      lines: (d.lines || []).map(function (l) {
        var r = (x.recv || {})[l.line_id], sent = Number(l.qty), got = r ? r[0] : null, adjDone = (x.adj || []).every(function (id) { return DOCS.find(function (z) { return z.document_id === id; }).state === 'posted'; });
        return {line_id: l.line_id, line_no: l.line_no, item_id: l.item_id, dispatched_qty: l.qty, received_qty: r ? String(got) : null, diff_qty: r ? String(got - sent) : null, diff_reason: r ? r[1] : null,
                in_transit: d.state === 'dispatched' ? String(sent) : (d.state === 'received_with_difference' && r && got < sent && !adjDone ? String(sent - got) : '0')};
      }),
      adjustments: (x.adj || []).map(function (id) { var a = DOCS.find(function (z) { return z.document_id === id; }); return {document_id: a.document_id, doc_type: a.doc_type, state: a.state, doc_no: a.doc_no}; })};
    return o;
  }
  var ITEMBY = {'IT-001': {item_id: 'i1', name: 'Bracket 1'}, 'IT-002': {item_id: 'i2', name: 'Wire 2'}, 'IT-003': {item_id: 'i3', name: 'Elastic 3'}, '4006381333931': {item_id: 'i3', name: 'Elastic 3', code: 'IT-003'}};
  var DCAP = {OPN: 'opn', GRN: 'grn', ADJ_IN: 'adj', ADJ_OUT: 'adj', CONS: 'cons', TRF: 'trf', EXP: 'exp'};
  // E180 (T19 / T20): expense categories and expenses. e1 posted in SER (paid by card), e2 posted in THE (owner only)
  var EXPCATS = [{category_id: 'ec1', parent_id: null, code: 'RENT', name: 'Rent', path: 'RENT', default_vat_class_id: 'v0', vat_code: 'VAT0', vat_rate: '0.00', active: true},
                 {category_id: 'ec2', parent_id: null, code: 'UTIL', name: 'Utilities', path: 'UTIL', default_vat_class_id: 'v1', vat_code: 'VAT24', vat_rate: '24.00', active: true},
                 {category_id: 'ec3', parent_id: null, code: 'TEL', name: 'Telephone', path: 'TEL', default_vat_class_id: 'v1', vat_code: 'VAT24', vat_rate: '24.00', active: true},
                 {category_id: 'ec4', parent_id: null, code: 'OLD', name: 'Old category', path: 'OLD', default_vat_class_id: null, vat_code: null, vat_rate: null, active: false}];
  VATS.push({vat_class_id: 'v0', code: 'VAT0', name: 'VAT exempt', rate: '0.00', mydata_category: 7, exemption_code: null, active: true});
  DOCS.push({document_id: 'e1', doc_type: 'EXP', state: 'posted', branch_id: 'b1', branch_code: 'SER', counterparty_id: 'p1', counterparty_name: 'Ortho Supplies SA', doc_no: 'EXP-SER/000001',
             doc_date: '2026-11-15', ext_number: 'INV-55', version: 2, extra: {paid: true, payment_method: 'card'}, total_net: '100.00', total_vat: '24.00', total_gross: '124.00',
             lines: [{line_id: 'e1-0', line_no: 1, expense_category_id: 'ec2', description: 'Electricity', qty: '1.0000', unit_price: '100.0000', vat_class_id: 'v1', net: '100.00', vat: '24.00', gross: '124.00'}]},
            {document_id: 'e2', doc_type: 'EXP', state: 'posted', branch_id: 'b2', branch_code: 'THE', counterparty_id: null, doc_no: 'EXP-THE/000001',
             doc_date: '2026-11-16', version: 2, extra: {}, total_net: '500.00', total_vat: '0.00', total_gross: '500.00',
             lines: [{line_id: 'e2-0', line_no: 1, expense_category_id: 'ec1', qty: '1.0000', unit_price: '500.0000', vat_class_id: 'v0', net: '500.00', vat: '0.00', gross: '500.00'}]});
  function expActions(d) {
    var a = [], over = SET.thresholds && SET.thresholds.exp_value != null && Number(d.total_net || 0) > Number(SET.thresholds.exp_value);
    if (!mine(d.branch_id)) return a;
    if (d.state === 'draft' && can('doc.exp.approve')) a.push({to_state: 'posted', label: 'doc.action.post', action: 'post'});
    else if (d.state === 'draft' && can('doc.exp.create')) a.push(over ? {to_state: 'pending_approval', label: 'doc.action.submit', action: 'none'} : {to_state: 'posted', label: 'doc.action.post', action: 'post'});
    if (d.state === 'pending_approval' && can('doc.exp.approve')) a.push({to_state: 'posted', label: 'doc.action.approve', action: 'post'}, {to_state: 'draft', label: 'doc.action.reject', action: 'none'});
    if (d.state === 'posted' && can('doc.exp.create')) a.push({to_state: 'cancelled', label: 'doc.action.cancel', action: 'cancel'});
    return a;
  }
  function docActions(d) {
    var c = DCAP[d.doc_type], a = [];
    if (d.doc_type === 'EXP') return expActions(d);
    if (d.doc_type === 'TRF') {
      var src = mine(d.branch_id), dst = mine(whBranch(d.dest_warehouse_id));
      if (d.state === 'draft' && src && can('doc.trf.create')) a.push({to_state: 'dispatched', label: 'doc.action.dispatch', action: 'post'});
      if (d.state === 'dispatched' && dst && can('doc.trf.create')) a.push({to_state: 'received', label: 'doc.action.receive', action: 'receive'},
                                                                         {to_state: 'received_with_difference', label: 'doc.action.receive_difference', action: 'receive'});
      if (d.state === 'dispatched' && src && can('doc.trf.approve')) a.push({to_state: 'cancelled', label: 'doc.action.cancel', action: 'cancel'});
      return a;
    }
    if (d.state === 'draft' && can('doc.' + c + '.create')) a.push(d.doc_type === 'OPN' && !can('doc.opn.approve') ? {to_state: 'pending_approval', label: 'doc.action.submit', action: 'none'}
                                                                                                         : {to_state: 'posted', label: 'doc.action.post', action: 'post'});
    if (d.state === 'posted' && can('doc.' + c + '.approve')) a.push({to_state: 'cancelled', label: d.doc_type === 'CONS' ? 'doc.action.reverse' : 'doc.action.cancel', action: 'cancel'});
    return a;
  }
  function docOut(d) {
    var o = JSON.parse(JSON.stringify(d)); o.actions = docActions(d); o.can_edit = d.state === 'draft' && can('doc.' + DCAP[d.doc_type] + '.create');
    o.line_count = (d.lines || []).length;
    o.problems = d.state !== 'draft' ? [] : d.doc_type === 'EXP'
      ? (d.lines || []).filter(function (l) { return !l.expense_category_id || !l.vat_class_id; }).map(function (l) { return {code: 'required', field: l.expense_category_id ? 'vat_class_id' : 'expense_category_id', line_no: l.line_no,
          message: l.expense_category_id ? 'Choose the VAT class.' : 'Choose the expense category.'}; })
      : (d.lines || []).filter(function (l) { return !l.item_id; }).map(function (l) { return {code: 'required', field: 'item_id', line_no: l.line_no, message: 'Item is required.'}; });
    if (!can('cost.read')) { delete o.total_cost; (o.lines || []).forEach(function (l) { delete l.cost_value; }); }
    return o;
  }
  function scope(rows) { return ROLE === 'owner' ? rows : rows.filter(function (r) { return !r.branch_id || r.branch_id === HOME; }); }
  function listOf(rows, cap, a, keyf) { if (!can(cap)) return err('ERP_FORBIDDEN', 'no'); return {data: page(rows, a, keyf), error: null}; }
  function saver(rows, key, cap, required, a, param, extra) {
    if (!can(cap)) return err('ERP_FORBIDDEN', 'no');
    var v = a[param] || {}, cur = v[key] ? rows.find(function (x) { return x[key] === v[key]; }) : null;
    if (v[key] && !cur) return err('ERP_TENANT', 'not yours');
    var merged = Object.assign({}, cur || {}, v);
    var miss = required.filter(function (k) { return !merged[k]; });
    if (miss.length) return err('ERP_VALIDATION', miss.length + ' problem(s)', miss.map(function (k) { return {code: 'required', field: k, message: k + ' is required.'}; }));
    if (cur && v.version != null && cur.version != null && v.version !== cur.version) return err('ERP_CONFLICT', 'version');
    if (cur) { Object.assign(cur, v); if (cur.version != null) cur.version++; if (extra) extra(cur); return {data: cur, error: null}; }
    var row = Object.assign({active: true}, v); row[key] = 'n' + (NEXTID++); if (extra) extra(row); rows.push(row);
    return {data: row, error: null};
  }
  function mockImport(a, cap, add) {
    if (!can(cap)) return err('ERP_FORBIDDEN', 'no');
    var rows = a.p_rows || [], errs = [];
    rows.forEach(function (r, i) { if (r.code === 'BAD' || r.name === 'BAD') errs.push({row: i + 1, code: 'invalid', field: 'code', message: 'Mock bad row.'}); });
    if (!errs.length && !a.p_dry_run) rows.forEach(add);
    return {data: {dry_run: !!a.p_dry_run || errs.length > 0, rows: rows.length, created: rows.length, updated: 0, errors: errs}, error: null};
  }
  var SET = {time_zone: 'Europe/Athens', negative_stock: 'warn', valuation_method: 'average', lock_date: null, hide_money: false, logo_url: null, version: 1,
             thresholds: ls('mock_exp_limit') ? {exp_value: Number(ls('mock_exp_limit'))} : {}};   // mock_exp_limit: thresholds.exp_value at load
  var IDEM = {};
  function err(code, msg, detail) { return {data: null, error: {message: code + ': ' + msg, details: detail ? JSON.stringify(detail) : null, code: 'P0001'}}; }
  function can(c) { return (CAPS[ROLE] || []).indexOf(c) >= 0; }
  function page(rows, a, keyf) {
    var lim = a.p_limit || 50, start = 0;
    if (a.p_cursor) { for (var i = 0; i < rows.length; i++) if (keyf(rows[i]) === a.p_cursor.k) { start = i + 1; break; } }
    var out = rows.slice(start, start + lim);
    return {rows: out, next: start + lim < rows.length ? {k: keyf(out[out.length - 1])} : null};
  }
  var H = {
    member_bind: function () { return {data: ls('mock_conflict') === '1' ? {bound: false, reason: 'bound_to_other_login'} : {bound: ROLE !== 'none'}, error: null}; },
    whoami: function () {
      if (ROLE === 'none') return err('ERP_AUTH', 'This login is not an active member of an ERP organisation.');
      var mine = ROLE === 'owner' ? BR : BR.filter(function (b) { return b.branch_id === HOME; });
      return {data: {member_id: 'm-me', email: 'me@clinic.test', display_name: 'Me', role: ROLE, all_branches: ROLE === 'owner',
        tenant: {tenant_id: 't1', code: 'ismile', name: 'iSmile', plan: 'standard'}, branches: mine, caps: CAPS[ROLE],
        settings: {time_zone: SET.time_zone, negative_stock: SET.negative_stock, valuation_method: SET.valuation_method, hide_money: SET.hide_money, lock_date: SET.lock_date},
        today: '2026-11-18'}, error: null};
    },
    branch_list: function (a) { if (!can('branch.read')) return err('ERP_FORBIDDEN', 'no'); return {data: {rows: BR.filter(function (b) { return a.p_include_inactive || b.active; }), next: null}, error: null}; },
    branch_save: function (a) {
      if (!can('branch.write')) return err('ERP_FORBIDDEN', 'no');
      var b = a.p_branch || {}, cur = b.branch_id ? BR.find(function (x) { return x.branch_id === b.branch_id; }) : null;
      var merged = Object.assign({}, cur || {}, b);
      if (!merged.code || !merged.name) return err('ERP_VALIDATION', '1 problem', [{code: 'required', field: merged.code ? 'name' : 'code', message: 'Required.'}]);
      var row;
      if (b.branch_id) { row = BR.find(function (x) { return x.branch_id === b.branch_id; }); Object.assign(row, b); }
      else { row = Object.assign({branch_id: 'b' + (BR.length + 1), active: true}, b); BR.push(row); }
      return {data: row, error: null};
    },
    settings_get: function () { if (!can('tenant.settings.read')) return err('ERP_FORBIDDEN', 'no'); return {data: Object.assign({}, SET, {can_write: can('tenant.settings.write')}), error: null}; },
    settings_save: function (a) {
      if (!can('tenant.settings.write')) return err('ERP_FORBIDDEN', 'no');
      var p = a.p_settings || {};
      if (p.version !== SET.version) return err('ERP_CONFLICT', 'version');
      ['time_zone', 'negative_stock', 'lock_date', 'hide_money', 'logo_url', 'thresholds'].forEach(function (k) { if (k in p) SET[k] = p[k]; });
      SET.version++; return {data: Object.assign({}, SET), error: null};
    },
    member_list: function (a) {
      if (!can('member.read')) return err('ERP_FORBIDDEN', 'no');
      var q = ((a.p_filter || {}).q || '').toLowerCase();
      var rows = MEM.filter(function (m) { return !q || m.email.indexOf(q) >= 0 || String(m.display_name || '').toLowerCase().indexOf(q) >= 0; })
        .sort(function (x, y) { return x.email < y.email ? -1 : 1; });
      return {data: page(rows, a, function (m) { return m.email; }), error: null};
    },
    member_invite: function (a) {
      if (!can('member.manage')) return err('ERP_FORBIDDEN', 'no');
      var m = a.p_member || {};
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(m.email || '')) return err('ERP_VALIDATION', '1 problem', [{code: 'email_invalid', field: 'email', message: 'Not a valid email address.'}]);
      var row = Object.assign({member_id: 'm' + MEM.length, display_name: null, branch_ids: [], all_branches: false, active: true, status: 'pending', invited_at: '2026-11-18T10:00:00Z', bound_at: null}, m);
      row.email = row.email.toLowerCase(); MEM.push(row); return {data: row, error: null};
    },
    member_update: function (a) {
      if (!can('member.manage')) return err('ERP_FORBIDDEN', 'no');
      var row = MEM.find(function (x) { return x.member_id === a.p_member_id; });
      if (!row) return err('ERP_TENANT', 'not yours');
      Object.assign(row, a.p_changes || {}); if (row.active === false) row.status = 'inactive'; return {data: row, error: null};
    },
    unit_list: function (a) { return listOf(UNITS, 'item.read', a, function (r) { return r.code; }); },
    unit_save: function (a) { return saver(UNITS, 'unit_id', 'item.write', ['code', 'name'], a, 'p_unit'); },
    category_list: function (a) { return listOf(CATS, 'item.read', a, function (r) { return r.code; }); },
    category_save: function (a) { return saver(CATS, 'category_id', 'item.write', ['code', 'name'], a, 'p_category', function (r) { r.path = r.code; }); },
    vat_class_list: function (a) { return listOf(VATS, 'vat.read', a, function (r) { return r.code; }); },
    vat_class_save: function (a) { return saver(VATS, 'vat_class_id', 'vat.write', ['code', 'name', 'rate'], a, 'p_vat'); },
    item_list: function (a) {
      var q = ((a.p_filter || {}).q || '').toLowerCase();
      var rows = ITEMS.filter(function (r) { return !q || r.code.toLowerCase().indexOf(q) === 0 || r.name.toLowerCase().indexOf(q) >= 0 || r.barcodes.indexOf((a.p_filter || {}).q) >= 0; });
      var res = listOf(rows, 'item.read', a, function (r) { return r.code; });
      if (res.data && !can('item.detail.read')) res.data.rows = res.data.rows.map(function (r) { return {item_id: r.item_id, code: r.code, name: r.name, kind: r.kind, base_unit_id: r.base_unit_id,
        unit_code: r.unit_code, lot_tracked: r.lot_tracked, active: r.active, barcodes: r.barcodes}; });
      return res;
    },
    item_save: function (a) {
      return saver(ITEMS, 'item_id', 'item.write', ['code', 'name', 'base_unit_id'], a, 'p_item', function (r) {
        var u = UNITS.find(function (x) { return x.unit_id === r.base_unit_id; }); r.unit_code = u ? u.code : '?'; r.barcodes = r.barcodes || []; if (r.version == null) r.version = 1;
      });
    },
    warehouse_list: function (a) { return listOf(scope(WHS), 'warehouse.read', a, function (r) { return r.code; }); },
    warehouse_save: function (a) { return saver(WHS, 'warehouse_id', 'warehouse.write', ['branch_id', 'code', 'name'], a, 'p_warehouse', function (r) { r.kind = 'normal'; }); },
    counterparty_list: function (a) {
      var q = ((a.p_filter || {}).q || '').toLowerCase();
      return listOf(CPS.filter(function (r) { return !q || r.name.toLowerCase().indexOf(q) >= 0 || r.tax_id === (a.p_filter || {}).q; })
        .sort(function (x, y) { return x.name.toLowerCase() < y.name.toLowerCase() ? -1 : 1; }), 'counterparty.read', a, function (r) { return r.name; });
    },
    counterparty_save: function (a) { return saver(CPS, 'counterparty_id', 'counterparty.write', ['name'], a, 'p_counterparty', function (r) { if (r.version == null) r.version = 1; }); },
    item_import: function (a) { return mockImport(a, 'item.write', function (r) { ITEMS.push(Object.assign({item_id: 'n' + (NEXTID++), unit_code: r.unit, base_unit_id: 'u1', barcodes: [], active: true, kind: 'goods', version: 1}, r)); }); },
    counterparty_import: function (a) { return mockImport(a, 'counterparty.write', function (r) { CPS.push(Object.assign({counterparty_id: 'n' + (NEXTID++), kind: 'supplier', active: true, version: 1}, r)); }); },
    doc_type_list: function () { return {data: TYPES, error: null}; },
    series_list: function (a) { return listOf(scope(SER), 'series.read', a, function (r) { return r.doc_type + r.code; }); },
    series_save: function (a) { return saver(SER, 'series_id', 'series.write', ['doc_type', 'code'], a, 'p_series', function (r) { r.next_no = r.next_no || 1; }); },
    series_create_defaults: function () {
      if (!can('series.write')) return err('ERP_FORBIDDEN', 'no');
      var row = {series_id: 'n' + (NEXTID++), branch_id: null, doc_type: 'OPN', code: 'OPN', next_no: 1, gapless: false, is_default: true, active: true, in_use: false};
      SER.push(row); return {data: {created: [row], skipped: ['GRN']}, error: null};
    },
    stock_on_hand: function (a) {
      if (!can('stock.read')) return err('ERP_FORBIDDEN', 'no');
      var f = a.p_filter || {}, rows = ONHAND.filter(function (r) { return (ROLE === 'owner' || r.branch_id === HOME) && (!f.warehouse_id || r.warehouse_id === f.warehouse_id)
        && (!f.only || (f.only === 'low' && r.low) || (f.only === 'negative' && r.negative)) && (!f.q || r.item_code.toLowerCase().indexOf(f.q.toLowerCase()) === 0); });
      rows = rows.map(function (r) { var o = Object.assign({}, r); if (!can('cost.read')) { delete o.avg_cost; delete o.value; } return o; });
      return {data: page(rows, a, function (r) { return r.item_code + r.warehouse_code; }), error: null};
    },
    stock_card: function (a) {
      if (!can('stock.read')) return err('ERP_FORBIDDEN', 'no');
      var rows = [{move_id: 1, move_date: '2026-11-10', kind: 'normal', doc_type: 'OPN', doc_no: 'OPN/000001', warehouse_code: 'SER-MAIN', qty: '20.0000', running_qty: '20.0000', value: '80.00', provisional: false},
                  {move_id: 2, move_date: '2026-11-17', kind: 'normal', doc_type: 'GRN', doc_no: 'GRN-SER/000017', warehouse_code: 'SER-MAIN', qty: '10.0000', running_qty: '30.0000', value: '45.00', provisional: false},
                  {move_id: 3, move_date: '2026-11-18', kind: 'normal', doc_type: 'CONS', doc_no: 'CONS-SER/000003', warehouse_code: 'SER-MAIN', qty: '-5.0000', running_qty: '25.0000', value: '-20.83', provisional: false}];
      if (!can('cost.read')) rows.forEach(function (r) { delete r.value; });
      return {data: {rows: rows, next: null, opening_qty: '0.0000', item: {item_id: a.p_item_id, code: 'IT-001', name: 'Bracket 1'}}, error: null};
    },
    item_lookup: function (a) {
      var h = ITEMBY[(a.p_query || '').toUpperCase()] || ITEMBY[a.p_query];
      if (!h) return {data: {rows: []}, error: null};
      var code = h.code || (a.p_query || '').toUpperCase();
      return {data: {rows: [{item_id: h.item_id, code: code, name: h.name, unit_code: 'PCS', base_unit_id: 'u1', on_hand: String(STOCKQ[h.item_id]), barcode_match: !!h.code}]}, error: null};
    },
    doc_list: function (a) {
      var f = a.p_filter || {}, types = f.doc_type ? [f.doc_type] : (f.doc_types || []);
      types = types.filter(function (x) { return can('doc.' + DCAP[x] + '.read'); });
      if (!types.length) return err('ERP_FORBIDDEN', 'no');
      var rows = DOCS.filter(function (d) { return types.indexOf(d.doc_type) >= 0 && (!f.state || d.state === f.state) && (d.doc_type !== 'TRF' || trfVisible(d)) && (d.doc_type !== 'EXP' || mine(d.branch_id))
          && (!f.branch_id || d.branch_id === f.branch_id || (d.doc_type === 'TRF' && whBranch(d.dest_warehouse_id) === f.branch_id)); })
        .map(function (d) { var o = docOut(d); delete o.lines; return o; });
      return {data: page(rows, a, function (r) { return r.document_id; }), error: null};
    },
    doc_get: function (a) { var d = DOCS.find(function (x) { return x.document_id === a.p_document_id; }); if (!d) return err('ERP_TENANT', 'not yours'); return {data: docOut(d), error: null}; },
    doc_save_draft: function (a) {
      if (!can('doc.' + DCAP[a.p_type] + '.create')) return err('ERP_FORBIDDEN', 'no');
      var p = a.p_doc || {}, d = p.document_id ? DOCS.find(function (x) { return x.document_id === p.document_id; }) : null;
      if (d && d.state !== 'draft') return err('ERP_DOC_IMMUTABLE', 'posted');
      if (!d) { d = {document_id: 'n' + (NEXTID++), doc_type: a.p_type, state: 'draft', version: 0, doc_no: null}; DOCS.unshift(d); }
      Object.keys(p).forEach(function (k) { if (k !== 'lines' && k !== 'document_id' && k !== 'version') d[k] = p[k]; });
      d.version++;
      if (p.lines) d.lines = p.lines.map(function (l, i) {
        var code = Object.keys(ITEMBY).find(function (k) { return ITEMBY[k].item_id === l.item_id && !ITEMBY[k].code; });
        var net = l.unit_price != null ? (Math.round(Number(l.qty) * Number(l.unit_price) * (1 - Number(l.discount_pct || 0) / 100) * 100) / 100).toFixed(2) : '0.00';
        return Object.assign({line_id: d.document_id + '-' + i, line_no: i + 1, item_code: code || '', item_name: code ? ITEMBY[code].name : '', qty_base: l.qty, net: net}, l);
      });
      if (d.doc_type === 'EXP') (d.lines || []).forEach(function (l) {
        var v = VATS.find(function (x) { return x.vat_class_id === l.vat_class_id; }), vat = v ? Math.round(Number(l.net) * Number(v.rate)) / 100 : 0;
        l.vat = vat.toFixed(2); l.gross = (Number(l.net) + vat).toFixed(2);
      });
      d.total_net = (d.lines || []).reduce(function (s, l) { return s + Number(l.net); }, 0).toFixed(2);
      d.total_vat = (d.lines || []).reduce(function (s, l) { return s + Number(l.vat || 0); }, 0).toFixed(2);
      d.total_gross = (d.lines || []).reduce(function (s, l) { return s + Number(l.gross || l.net); }, 0).toFixed(2);
      d.counterparty_name = (CPS.find(function (c) { return c.counterparty_id === d.counterparty_id; }) || {}).name;
      d.branch_code = (BR.find(function (b) { return b.branch_id === d.branch_id; }) || {}).code;
      d.warehouse_code = (WHS.find(function (w) { return w.warehouse_id === d.warehouse_id; }) || {}).code;
      return {data: docOut(d), error: null};
    },
    doc_set_state: function (a) {
      var d = DOCS.find(function (x) { return x.document_id === a.p_document_id; }); if (!d) return err('ERP_TENANT', 'not yours');
      var act = docActions(d).find(function (x) { return x.to_state === a.p_to_state; });
      if (!act) return err('ERP_FORBIDDEN', 'not allowed');
      var o = a.p_options || {};
      if (d.doc_type === 'TRF' && a.p_to_state === 'dispatched') {
        if (!d.dest_warehouse_id) return err('ERP_VALIDATION', '1 problem', [{code: 'required', field: 'dest_warehouse_id', message: 'Destination warehouse is required.'}]);
        var tw = (d.lines || []).filter(function (l) { return (STOCKQ[l.item_id] || 0) - Number(l.qty) < 0; })
          .map(function (l) { return {code: 'W_STOCK_NEGATIVE', item_id: l.item_id, item_code: l.item_code, warehouse_id: d.warehouse_id, warehouse_code: d.warehouse_code, qty_after: String((STOCKQ[l.item_id] || 0) - Number(l.qty))}; });
        if (tw.length && !o.ack_warnings) return {data: {posted: false, warnings: tw, document: docOut(d)}, error: null};
        (d.lines || []).forEach(function (l) { STOCKQ[l.item_id] = (STOCKQ[l.item_id] || 0) - Number(l.qty); });
        d.state = 'dispatched'; d.doc_no = 'TRF-SER/' + String(NEXTID++).padStart(6, '0'); d.version++;
        return {data: {posted: true, warnings: tw, document: docOut(d)}, error: null};
      }
      if (d.doc_type === 'TRF' && act.action === 'receive') {
        var recv = {}, diff = false, probs = [];
        (o.lines || []).forEach(function (x) { recv[x.line_id] = [Number(x.received_qty), x.reason || null]; });
        (d.lines || []).forEach(function (l) {
          if (!recv[l.line_id]) recv[l.line_id] = [Number(l.qty), null];
          if (recv[l.line_id][0] !== Number(l.qty)) { diff = true; if (!recv[l.line_id][1]) probs.push({code: 'required', field: 'reason', line_no: l.line_no, message: 'A difference needs a reason.'}); }
        });
        if (!probs.length && diff !== (a.p_to_state === 'received_with_difference')) probs.push({code: 'state', field: 'to_state', message: 'The target state does not match the quantities.'});
        if (probs.length) return err('ERP_VALIDATION', probs.length + ' problem(s)', probs);
        var x = TRFX[d.document_id] = {receipt: {receipt_date: o.receipt_date || '2026-11-18', received_at: '2026-11-18T10:00:00Z', received_by_email: 'me@clinic.test', closed_at: null}, recv: recv, adj: []};
        var short = (d.lines || []).filter(function (l) { return recv[l.line_id][0] < Number(l.qty); });
        if (short.length) {
          var adj = {document_id: 'n' + (NEXTID++), doc_type: 'ADJ_OUT', state: 'draft', source: 'system', branch_id: whBranch(d.dest_warehouse_id), warehouse_id: 'wt', warehouse_code: 'TRANSIT',
                     ref_document_id: d.document_id, doc_no: null, doc_date: x.receipt.receipt_date, version: 1, extra: {reason: 'lost'}, notes: 'Transfer ' + d.doc_no + ': shortage on receipt (out of transit).',
                     lines: short.map(function (l, i) { return {line_id: 'aj' + i, line_no: i + 1, item_id: l.item_id, item_code: l.item_code, item_name: l.item_name, description: recv[l.line_id][1],
                                                                qty: String(Number(l.qty) - recv[l.line_id][0]), qty_base: String(Number(l.qty) - recv[l.line_id][0])}; })};
          DOCS.unshift(adj); x.adj.push(adj.document_id);
        }
        d.state = a.p_to_state; d.version++;
        return {data: {posted: false, warnings: [], receipt: {receipt_date: x.receipt.receipt_date, adjustments: x.adj}, document: docOut(d)}, error: null};
      }
      if (a.p_to_state === 'cancelled' && !o.reason) return err('ERP_VALIDATION', '1 problem', [{code: 'required', field: 'reason', message: 'A reason is required.'}]);
      if (a.p_to_state === 'posted') {
        var sign = d.doc_type === 'CONS' || d.doc_type === 'ADJ_OUT' ? -1 : 1;
        var warn = (d.lines || []).filter(function (l) { return sign < 0 && d.warehouse_id !== 'wt' && (STOCKQ[l.item_id] || 0) - Number(l.qty) < 0; })
          .map(function (l) { return {code: 'W_STOCK_NEGATIVE', item_id: l.item_id, item_code: l.item_code, warehouse_id: d.warehouse_id, warehouse_code: d.warehouse_code, qty_after: String((STOCKQ[l.item_id] || 0) - Number(l.qty))}; });
        if (warn.length && !o.ack_warnings) return {data: {posted: false, warnings: warn, document: docOut(d)}, error: null};
        if (d.warehouse_id !== 'wt') (d.lines || []).forEach(function (l) { STOCKQ[l.item_id] = (STOCKQ[l.item_id] || 0) + sign * Number(l.qty); });
        d.state = 'posted'; d.doc_no = d.doc_type + '-SER/' + String(NEXTID++).padStart(6, '0'); d.version++;
        var parent = d.ref_document_id && DOCS.find(function (z) { return z.document_id === d.ref_document_id && z.doc_type === 'TRF'; });
        if (parent && TRFX[parent.document_id].adj.every(function (id) { return DOCS.find(function (z) { return z.document_id === id; }).state === 'posted'; })) {
          parent.state = 'closed'; parent.version++; TRFX[parent.document_id].receipt.closed_at = '2026-11-18T11:00:00Z';
        }
        return {data: {posted: true, warnings: warn, document: docOut(d)}, error: null};
      }
      d.state = a.p_to_state; if (o.reason) d.cancel_reason = o.reason; d.version++;
      return {data: {posted: false, warnings: [], document: docOut(d)}, error: null};
    },
    expense_category_list: function (a) {
      if (!can('doc.exp.read')) return err('ERP_FORBIDDEN', 'no');
      return {data: page(EXPCATS.filter(function (c) { return a.p_include_inactive || c.active; }), a, function (r) { return r.code; }), error: null};
    },
    expense_category_save: function (a) {
      return saver(EXPCATS, 'category_id', 'expense.category.write', ['code', 'name'], a, 'p_category', function (r) {
        var v = VATS.find(function (x) { return x.vat_class_id === r.default_vat_class_id; }), par = EXPCATS.find(function (x) { return x.category_id === r.parent_id; });
        r.vat_code = v ? v.code : null; r.vat_rate = v ? v.rate : null; r.path = (par ? par.path + ' / ' : '') + r.code;
      });
    },
    report_expenses: function (a) {
      if (!can('doc.exp.read')) return err('ERP_FORBIDDEN', 'no');
      var f = a.p_filter || {}, grp = f.group_by || 'category', by = {}, tot = {docs: 0, lines: 0, net: 0, vat: 0, gross: 0, paid_gross: 0};
      DOCS.filter(function (d) { return d.doc_type === 'EXP' && d.state === 'posted' && mine(d.branch_id) && (!f.branch_id || d.branch_id === f.branch_id)
                                   && (!f.date_from || d.doc_date >= f.date_from) && (!f.date_to || d.doc_date <= f.date_to); }).forEach(function (d) {
        tot.docs++;
        (d.lines || []).forEach(function (l) {
          var k = grp === 'supplier' ? (d.counterparty_id || '') : l.expense_category_id, c = EXPCATS.find(function (x) { return x.category_id === k; }) || {};
          var r = by[k] = by[k] || {key_id: k || null, code: grp === 'supplier' ? null : c.code, name: grp === 'supplier' ? (d.counterparty_name || null) : c.name, path: c.path, docs: 0, lines: 0, net: 0, vat: 0, gross: 0, paid_gross: 0, _d: {}};
          if (!r._d[d.document_id]) { r._d[d.document_id] = 1; r.docs++; }
          [r, tot].forEach(function (x) { x.lines++; x.net += Number(l.net); x.vat += Number(l.vat); x.gross += Number(l.gross); if ((d.extra || {}).paid) x.paid_gross += Number(l.gross); });
        });
      });
      var rows = Object.keys(by).map(function (k) { var r = by[k]; delete r._d; ['net', 'vat', 'gross', 'paid_gross'].forEach(function (m) { r[m] = r[m].toFixed(2); }); return r; })
        .sort(function (x, y) { return Number(y.gross) - Number(x.gross); });
      ['net', 'vat', 'gross', 'paid_gross'].forEach(function (m) { tot[m] = tot[m].toFixed(2); });
      return {data: {group_by: grp, date_from: f.date_from || '2026-11-01', date_to: f.date_to || '2026-11-18', rows: rows, totals: tot, truncated: false}, error: null};
    },
    trf_get: function (a) {
      if (!can('doc.trf.read')) return err('ERP_FORBIDDEN', 'no');
      var d = DOCS.find(function (x) { return x.document_id === a.p_document_id; });
      if (!d) return err('ERP_TENANT', 'not yours');
      if (d.doc_type !== 'TRF') return err('ERP_VALIDATION', '1 problem', [{code: 'invalid', field: 'p_document_id', message: 'Not a transfer.'}]);
      if (!trfVisible(d)) return err('ERP_FORBIDDEN', 'no');
      return {data: trfOut(d), error: null};
    },
    trf_warehouses: function () {
      if (!can('doc.trf.read')) return err('ERP_FORBIDDEN', 'no');
      return {data: {rows: ALLWHS.map(function (w) { return {warehouse_id: w.warehouse_id, branch_id: w.branch_id, branch_code: w.branch_code, code: w.code, name: w.name, active: w.active}; })}, error: null};
    },
    doc_delete_draft: function (a) { var i = DOCS.findIndex(function (x) { return x.document_id === a.p_document_id; }); DOCS.splice(i, 1); return {data: {deleted: true}, error: null}; },
    doc_copy: function (a) {
      var s0 = DOCS.find(function (x) { return x.document_id === a.p_document_id; });
      var d = JSON.parse(JSON.stringify(s0)); d.document_id = 'n' + (NEXTID++); d.state = 'draft'; d.doc_no = null; d.version = 1; DOCS.unshift(d);
      return {data: docOut(d), error: null};
    },
    report_negative_stock: function () {
      if (!can('stock.read')) return err('ERP_FORBIDDEN', 'no');
      var r = {warehouse_id: 'w1', warehouse_code: 'SER-MAIN', item_id: 'i2', item_code: 'IT-002', item_name: 'Wire 2', qty: '-3.0000', days_negative: 2, doc_no: 'CONS-SER/000004',
               posted_by_email: 'nurse@clinic.test'};
      if (can('cost.read')) r.provisional_value = '6.00';
      return {data: {rows: [r], next: null}, error: null};
    },
    alert_list: function () {
      if (!can('alert.read')) return err('ERP_FORBIDDEN', 'no');
      return {data: {rows: ALERTS.filter(function (x) { return !x.resolved_at; }).map(function (x) { return Object.assign({can_resolve: can('alert.resolve')}, x); }), next: null}, error: null};
    },
    alert_resolve: function (a) {
      if (!can('alert.resolve')) return err('ERP_FORBIDDEN', 'no');
      var x = ALERTS.find(function (y) { return y.alert_id === a.p_alert_id; }); x.resolved_at = '2026-11-18T12:00:00Z'; return {data: {alert_id: x.alert_id, resolved_at: x.resolved_at}, error: null};
    },
    opening_import: function (a) {
      if (!can('doc.opn.create')) return err('ERP_FORBIDDEN', 'no');
      var rows = a.p_rows || [], errs = [];
      rows.forEach(function (r, i) { if (!ITEMBY[(r.item || '').toUpperCase()]) errs.push({row: i + 1, code: 'unknown', field: 'item', message: 'Item ' + r.item + ' does not exist.'}); });
      var total = rows.reduce(function (s, r) { return s + Number(r.qty) * Number(String(r.unit_cost).replace(',', '.')); }, 0).toFixed(2);
      if (errs.length || a.p_dry_run) return {data: {dry_run: true, rows: rows.length, total_value: total, errors: errs}, error: null};
      var d = {document_id: 'n' + (NEXTID++), doc_type: 'OPN', state: 'draft', version: 1, warehouse_id: a.p_doc.warehouse_id, doc_date: '2026-11-18', total_net: total,
               lines: rows.map(function (r, i) { return {line_id: 'o' + i, line_no: i + 1, item_id: ITEMBY[r.item.toUpperCase()].item_id, item_code: r.item.toUpperCase(), qty: r.qty, unit_price: r.unit_cost}; })};
      DOCS.unshift(d);
      return {data: {dry_run: false, rows: rows.length, total_value: total, errors: [], document: docOut(d)}, error: null};
    },
    member_reset_binding: function (a) {
      if (!can('member.manage')) return err('ERP_FORBIDDEN', 'no');
      var row = MEM.find(function (x) { return x.member_id === a.p_member_id; });
      row.bound_at = null; row.status = 'pending'; return {data: row, error: null};
    }
  };
  var listeners = [];
  function session() { return ls('mock_session') === '1' ? {access_token: 'x', user: {email: ROLE === 'none' ? 'stranger@else.test' : 'me@clinic.test'}} : null; }
  function emit(ev) { var s = session(); listeners.forEach(function (f) { setTimeout(function () { f(ev, s); }, 0); }); }
  window.supabase = {createClient: function () {
    return {
      auth: {
        getSession: async function () { return {data: {session: session()}, error: null}; },
        onAuthStateChange: function (f) { listeners.push(f); setTimeout(function () { f('INITIAL_SESSION', session()); }, 0); return {data: {subscription: {unsubscribe: function () {}}}}; },
        signInWithPassword: async function (c) {
          CALLS.push({name: 'auth.signIn', args: {email: c.email}});
          if (c.password !== 'right-password') return {data: null, error: {message: 'Invalid login credentials'}};
          lsSet('mock_session', '1'); emit('SIGNED_IN'); return {data: {session: session()}, error: null};
        },
        signOut: async function () { CALLS.push({name: 'auth.signOut'}); lsSet('mock_session', null); emit('SIGNED_OUT'); return {error: null}; },
        resetPasswordForEmail: async function (em) { CALLS.push({name: 'auth.reset', args: {email: em}}); return {data: {}, error: null}; },
        updateUser: async function () { return {data: {}, error: null}; }
      },
      schema: function (sch) {
        return {rpc: async function (name, args) {
          CALLS.push({schema: sch, name: name, args: JSON.parse(JSON.stringify(args || {}))});
          await new Promise(function (r) { setTimeout(r, 30); });
          if (sch !== 'erp_api') return {data: null, error: {message: 'wrong schema ' + sch}};
          if (FAIL.indexOf(name) >= 0) return err('ERP_VALIDATION', '1 problem', [{code: 'mock', field: null, message: 'Mock validation problem.'}]);
          if (NULLS.indexOf(name) >= 0) return {data: null, error: null};
          if (!H[name]) return {data: null, error: {message: 'Could not find the function erp_api.' + name, code: 'PGRST202'}};
          var k = args && args.p_idempotency_key;
          if (k && IDEM[k]) return IDEM[k];
          var r = H[name](args || {});
          if (k && !r.error) IDEM[k] = r;
          return r;
        }};
      }
    };
  }};
  if (DEMO && DEMO.hook) DEMO.hook({H: H, emit: emit, can: can, err: err, page: page, docOut: docOut, trfOut: trfOut, docActions: docActions, mine: mine,
    setRole: function (r, home) { ROLE = r; HOME = home; }, role: function () { return ROLE; }, home: function () { return HOME; },
    data: {BR: BR, MEM: MEM, UNITS: UNITS, CATS: CATS, VATS: VATS, ITEMS: ITEMS, WHS: WHS, ALLWHS: ALLWHS, CPS: CPS, SER: SER, TYPES: TYPES, ONHAND: ONHAND,
           STOCKQ: STOCKQ, DOCS: DOCS, ALERTS: ALERTS, EXPCATS: EXPCATS, ITEMBY: ITEMBY, TRFX: TRFX, SET: SET, CAPS: CAPS}});
})();
