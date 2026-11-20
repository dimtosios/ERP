/* ---------- admin: members, branches, settings (T04) ---------- */
// Opened by owner / manager / accounting (02 matrix row 1). Each tab has its own capability; write buttons only
// with member.manage / branch.write / tenant.settings.write (the server checks again).
var ROLES = ['owner', 'manager', 'warehouse', 'accounting', 'clinic_user', 'readonly'];
var ADM = {tab: 'members', q: '', rows: [], next: null, busy: false, branches: [], settings: null};
var ADMIN_TABS = [
  {id: 'members', label: 'admin.tab.members', caps: ['member.read']},
  {id: 'branches', label: 'admin.tab.branches', caps: ['branch.write', 'member.read', 'tenant.settings.read']},
  {id: 'settings', label: 'admin.tab.settings', caps: ['tenant.settings.read']}
];
function admTabs() { return ADMIN_TABS.filter(function (x) { return canAny(x.caps); }); }

screen({id: 'admin', nav: 'nav.admin', caps: ['member.read', 'branch.write', 'tenant.settings.read'],
  render: function (sub) {
    var tabs = admTabs(), want = sub[0];
    ADM.tab = tabs.some(function (x) { return x.id === want; }) ? want : tabs[0].id;
    return '<h1>' + esc(t('admin.title')) + '</h1><div class="tabs" id="adm-tabs">' + tabs.map(function (x) {
      return '<a href="#/admin/' + x.id + '" data-act="go" data-to="admin" data-sub="' + x.id + '" class="' + (x.id === ADM.tab ? 'on' : '') + '">' + esc(t(x.label)) + '</a>';
    }).join('') + '</div><div id="adm-body"><p class="muted">' + esc(t('app.loading')) + '</p></div>';
  },
  mount: function () {
    if (ADM.tab === 'members') membersLoad(true);
    else if (ADM.tab === 'branches') branchesLoad();
    else settingsLoad();
  }
});
function admBody(h) { var el = $('adm-body'); if (el) el.innerHTML = h; }
function admError(r) { admBody('<div class="msg bad">' + esc(r.error ? r.error.text : t('err.unknown')) + '</div>'); }
async function loadBranches() {
  var r = await api('branch_list', {p_include_inactive: true, p_limit: 500});
  ADM.branches = r.ok && r.data ? r.data.rows : [];
  return r;
}
function branchName(id) { for (var i = 0; i < ADM.branches.length; i++) if (ADM.branches[i].branch_id === id) return ADM.branches[i].code; return '?'; }

/* ---------- admin: members ---------- */
function statusBadge(st) { return '<span class="badge ' + (st === 'active' ? 'good' : st === 'pending' ? 'warn' : '') + '">' + esc(t('members.status.' + st)) + '</span>'; }
function memberRow(m) {
  var br = (m.all_branches ? t('home.all_branches') : (m.branch_ids || []).map(branchName).join(', '));
  return '<tr class="click" data-act="member-open" data-id="' + esc(m.member_id) + '"><td>' + esc(m.email) + '</td><td>' + esc(m.display_name || '') + '</td><td>' +
    esc(t('role.' + m.role)) + '</td><td>' + esc(br) + '</td><td>' + statusBadge(m.status) + '</td></tr>';
}
function membersView() {
  var head = '<div class="row" style="margin-bottom:10px"><input id="m-q" class="grow" style="max-width:320px" placeholder="' + esc(t('members.search')) + '" value="' + esc(ADM.q) + '">' +
    '<span class="grow"></span>' + (can('member.manage') ? '<button class="primary" data-act="member-new">' + esc(t('members.invite')) + '</button>' : '') + '</div>';
  var body = ADM.rows.length ? ADM.rows.map(memberRow).join('') : '<tr><td colspan="5" class="empty">' + esc(t('list.empty')) + '</td></tr>';
  return head + '<div class="tbl-wrap"><table id="m-table"><thead><tr><th>' + esc(t('members.col.email')) + '</th><th>' + esc(t('members.col.name')) + '</th><th>' +
    esc(t('members.col.role')) + '</th><th>' + esc(t('members.col.branches')) + '</th><th>' + esc(t('members.col.status')) + '</th></tr></thead><tbody>' + body + '</tbody></table></div>' +
    (ADM.next ? '<div class="row end" style="margin-top:10px"><button id="m-more" data-act="member-more">' + esc(t('list.more')) + '</button></div>' : '');
}
async function membersLoad(reset) {
  if (ADM.busy) return; ADM.busy = true;
  if (reset && !ADM.branches.length) await loadBranches();
  var r = await api('member_list', {p_filter: ADM.q ? {q: ADM.q} : {}, p_cursor: reset ? null : ADM.next, p_limit: 50});
  ADM.busy = false;
  if (ADM.tab !== 'members') return;
  if (!r.ok) { admError(r); return; }
  // the shown rows stay clickable while a reload runs; they are replaced only when the reply is here
  ADM.rows = (reset ? [] : ADM.rows).concat(r.data.rows); ADM.next = r.data.next;
  var focus = document.activeElement && document.activeElement.id === 'm-q';
  admBody(membersView());
  if (focus) { var q = $('m-q'); q.focus(); q.setSelectionRange(q.value.length, q.value.length); }
}
ACT['member-more'] = function () { membersLoad(false); };
var mqTimer = null;
document.addEventListener('input', function (e) {
  if (e.target.id !== 'm-q') return;
  clearTimeout(mqTimer); var v = e.target.value.trim();
  mqTimer = setTimeout(function () { ADM.q = v; membersLoad(true); }, 300);
});
function branchChips(selected, disabled) {
  return '<div class="chips" id="m-branches">' + ADM.branches.filter(function (b) { return b.active || selected.indexOf(b.branch_id) >= 0; }).map(function (b) {
    return '<label><input type="checkbox" name="m-br" value="' + esc(b.branch_id) + '"' + (selected.indexOf(b.branch_id) >= 0 ? ' checked' : '') + (disabled ? ' disabled' : '') + '> ' +
      esc(b.code) + ' · ' + esc(b.name) + '</label>';
  }).join('') + '</div>';
}
function pickedBranches() { return Array.prototype.map.call(document.querySelectorAll('input[name=m-br]:checked'), function (x) { return x.value; }); }
function memberForm(m, isNew) {
  var ro = !can('member.manage');
  var roleOpts = ROLES.map(function (r) { return [r, t('role.' + r)]; });
  return (isNew ? field('m-email', 'members.f.email', inp('m-email', '', 'email')) : '<p><b>' + esc(m.email) + '</b> ' + statusBadge(m.status) + '</p><p class="muted">' +
      esc(m.bound_at ? t('members.bound', {date: fmtDate(m.bound_at)}) : t('members.not_bound')) + '</p>') +
    field('m-name', 'members.f.name', inp('m-name', m.display_name, 'text', ro)) +
    field('m-role', 'members.f.role', sel('m-role', roleOpts, m.role || 'clinic_user', ro)) +
    '<label>' + esc(t('members.f.branches')) + '</label>' + branchChips(m.branch_ids || [], ro) +
    chk('m-all', 'members.f.all_branches', m.all_branches, ro) +
    (isNew ? '<p class="muted">' + esc(t('members.invite_note')) + '</p>' : chk('m-active', 'members.f.active', m.active, ro));
}
ACT['member-new'] = function () {
  drawerOpen({title: t('members.drawer.invite'), body: function () { return memberForm({branch_ids: [], role: 'clinic_user'}, true); },
    save: function () {
      var p = {email: val('m-email').trim(), role: val('m-role'), branch_ids: pickedBranches(), all_branches: $('m-all').checked};
      var nm = val('m-name').trim(); if (nm) p.display_name = nm;
      return api('member_invite', {p_member: p}, {write: true, key: D.key});
    },
    onSaved: function () { membersLoad(true); }});
};
ACT['member-open'] = function (el) {
  var m = ADM.rows.find(function (x) { return x.member_id === el.getAttribute('data-id'); }); if (!m) return;
  var mine = S.me && m.member_id === S.me.member_id;
  drawerOpen({title: t('members.drawer.edit'), readOnly: !can('member.manage'),
    extra: can('member.manage') && m.status === 'active' && !mine ? '<button data-act="member-reset" data-id="' + esc(m.member_id) + '">' + esc(t('members.reset_binding')) + '</button>' : '',
    body: function () { return memberForm(m, false); },
    save: function () {
      var c = {}, nm = val('m-name').trim() || null, br = pickedBranches().sort(), old = (m.branch_ids || []).slice().sort();
      if (nm !== (m.display_name || null)) c.display_name = nm;
      if (val('m-role') !== m.role) c.role = val('m-role');
      if (br.join() !== old.join()) c.branch_ids = br;
      if ($('m-all').checked !== !!m.all_branches) c.all_branches = $('m-all').checked;
      if ($('m-active').checked !== !!m.active) c.active = $('m-active').checked;
      if (!Object.keys(c).length) return Promise.resolve({ok: true, data: m});
      return api('member_update', {p_member_id: m.member_id, p_changes: c}, {write: true, key: D.key});
    },
    onSaved: function () { membersLoad(true); }});
};
ACT['member-reset'] = function (el) {
  var m = ADM.rows.find(function (x) { return x.member_id === el.getAttribute('data-id'); }); if (!m) return;
  confirmBox(t('members.reset_confirm', {email: m.email}), t('members.reset_binding'), t('cancel'), async function () {
    var r = await api('member_reset_binding', {p_member_id: m.member_id}, {write: true});
    if (!r.ok || r.data == null) { drawerMsg(notSaved(r), r.error && Array.isArray(r.error.detail) ? r.error.detail : null); return; }
    drawerClose(true); toast(t('members.reset_done')); membersLoad(true);
  });
};

/* ---------- admin: branches ---------- */
async function branchesLoad() {
  var r = await loadBranches();
  if (ADM.tab !== 'branches') return;
  if (!r.ok) { admError(r); return; }
  var rows = ADM.branches.length ? ADM.branches.map(function (b) {
    return '<tr class="click" data-act="branch-open" data-id="' + esc(b.branch_id) + '"><td>' + esc(b.code) + '</td><td>' + esc(b.name) + '</td><td>' +
      esc(b.establishment_no == null ? '' : b.establishment_no) + '</td><td><span class="badge ' + (b.active ? 'good' : '') + '">' + esc(t(b.active ? 'branches.active' : 'branches.inactive')) + '</span></td></tr>';
  }).join('') : '<tr><td colspan="4" class="empty">' + esc(t('list.empty')) + '</td></tr>';
  admBody('<div class="row end" style="margin-bottom:10px">' + (can('branch.write') ? '<button class="primary" data-act="branch-new">' + esc(t('branches.add')) + '</button>' : '') + '</div>' +
    '<div class="tbl-wrap"><table id="b-table"><thead><tr><th>' + esc(t('branches.col.code')) + '</th><th>' + esc(t('branches.col.name')) + '</th><th>' +
    esc(t('branches.col.establishment')) + '</th><th>' + esc(t('branches.col.status')) + '</th></tr></thead><tbody>' + rows + '</tbody></table></div>');
}
function branchForm(b) {
  var ro = !can('branch.write');
  return field('b-code', 'branches.f.code', inp('b-code', b.code, 'text', ro)) + field('b-name', 'branches.f.name', inp('b-name', b.name, 'text', ro)) +
    field('b-estab', 'branches.f.establishment', inp('b-estab', b.establishment_no, 'number', ro)) + field('b-addr', 'branches.f.address', inp('b-addr', b.address, 'text', ro)) +
    chk('b-active', 'branches.f.active', b.active !== false, ro);
}
function branchDrawer(b) {
  var isNew = !b.branch_id;
  drawerOpen({title: t(isNew ? 'branches.drawer.new' : 'branches.drawer.edit'), readOnly: !can('branch.write'), body: function () { return branchForm(b); },
    save: function () {
      var p = isNew ? {} : {branch_id: b.branch_id}, est = val('b-estab').trim();
      var v = {code: val('b-code').trim(), name: val('b-name').trim(), establishment_no: est === '' ? null : est, address: val('b-addr').trim() || null, active: $('b-active').checked};
      Object.keys(v).forEach(function (k) { var o = b[k] == null ? null : (k === 'establishment_no' ? String(b[k]) : b[k]); if (isNew || v[k] !== o) p[k] = v[k]; });
      if (!isNew && Object.keys(p).length === 1) return Promise.resolve({ok: true, data: b});
      return api('branch_save', {p_branch: p}, {write: true, key: D.key});
    },
    onSaved: async function () { await refreshMe(); branchesLoad(); }});
}
ACT['branch-new'] = function () { branchDrawer({active: true}); };
ACT['branch-open'] = function (el) { var b = ADM.branches.find(function (x) { return x.branch_id === el.getAttribute('data-id'); }); if (b) branchDrawer(b); };

/* ---------- admin: settings ---------- */
function zones(cur) {
  var z = [];
  try { z = Intl.supportedValuesOf('timeZone'); } catch (x) { z = []; }
  if (z.indexOf(cur) < 0) z = [cur].concat(z);
  return z.map(function (x) { return [x, x]; });
}
async function settingsLoad() {
  var r = await api('settings_get');
  if (ADM.tab !== 'settings') return;
  if (!r.ok) { admError(r); return; }
  var s = ADM.settings = r.data, ro = !s.can_write;
  admBody('<div class="card" style="max-width:560px"><form data-form="settings" id="s-form">' +
    (ro ? '<p class="muted">' + esc(t('settings.read_only')) + '</p>' : '') +
    field('s-tz', 'settings.f.time_zone', sel('s-tz', zones(s.time_zone), s.time_zone, ro)) +
    field('s-neg', 'settings.f.negative_stock', sel('s-neg', [['warn', t('settings.neg.warn')], ['block', t('settings.neg.block')]], s.negative_stock, ro)) +
    field('s-val', 'settings.f.valuation', inp('s-val', t('settings.val.' + s.valuation_method), 'text', true)) + '<p class="muted">' + esc(t('settings.val_note')) + '</p>' +
    field('s-lock', 'settings.f.lock_date', inp('s-lock', fmtDate(s.lock_date), 'text', ro)) +
    chk('s-hide', 'settings.f.hide_money', s.hide_money, ro) +
    field('s-explim', 'settings.f.exp_limit', inp('s-explim', (s.thresholds || {}).exp_value != null ? s.thresholds.exp_value : '', 'text', ro)) +
    field('s-logo', 'settings.f.logo_url', inp('s-logo', s.logo_url, 'url', ro)) +
    '<div class="msg bad" id="s-msg"></div>' +
    (ro ? '' : '<div class="row end"><button type="submit" class="primary" id="s-save">' + esc(t('settings.save')) + '</button></div>') + '</form></div>');
}
FORM.settings = async function () {
  var s = ADM.settings, b = $('s-save'), msg = $('s-msg'); if (!s || !b || b.disabled) return;
  var lockTxt = val('s-lock').trim(), lock = lockTxt ? parseDate(lockTxt) : null;
  if (lockTxt && !lock) { msg.textContent = t('save.not_saved', {reason: t('settings.lock_invalid')}); return; }
  var p = {version: s.version};
  if (val('s-tz') !== s.time_zone) p.time_zone = val('s-tz');
  if (val('s-neg') !== s.negative_stock) p.negative_stock = val('s-neg');
  if (lock !== (s.lock_date || null)) p.lock_date = lock;
  if ($('s-hide').checked !== !!s.hide_money) p.hide_money = $('s-hide').checked;
  var logo = val('s-logo').trim() || null; if (logo !== (s.logo_url || null)) p.logo_url = logo;
  var limTxt = val('s-explim').trim().replace(',', '.'), lim = limTxt === '' ? null : Number(limTxt), thr = Object.assign({}, s.thresholds || {});
  if (limTxt !== '' && (isNaN(lim) || lim < 0)) { msg.textContent = t('save.not_saved', {reason: t('settings.exp_limit_invalid')}); return; }
  if (lim !== (thr.exp_value != null ? Number(thr.exp_value) : null)) { if (lim === null) delete thr.exp_value; else thr.exp_value = lim; p.thresholds = thr; }
  b.disabled = true; b.textContent = t('drawer.saving'); msg.textContent = '';
  var r = await api('settings_save', {p_settings: p}, {write: true, key: ADM.settingsKey || (ADM.settingsKey = uuid())});
  b.disabled = false; b.textContent = t('settings.save');
  if (!r.ok || r.data == null) {
    msg.innerHTML = esc(notSaved(r)) + (r.error && Array.isArray(r.error.detail) ? '<ul class="problems">' + r.error.detail.map(function (x) { return '<li>' + esc(x.message) + '</li>'; }).join('') + '</ul>' : '');
    return;
  }
  ADM.settingsKey = null; toast(t('save.saved')); await refreshMe(); settingsLoad();
};
