/* ---------- config ---------- */
// Same Supabase project / Auth as the CRM (05 question 1, default). The publishable key is public by design;
// no secret, provider key or service-role key ever appears in a front-end file.
var SB_URL = 'https://tmgmiojvqdivuoorvmfl.supabase.co', SB_KEY = 'sb_publishable_UO9ur1Futgz71_pKZleHyg_lbRiJJXf';
var API_TIMEOUT_MS = 8000;
var arrivedByLink = /[#&]type=(invite|recovery|signup)/.test(location.hash);
var sb = window.supabase.createClient(SB_URL, SB_KEY, {auth: {persistSession: true, autoRefreshToken: true, detectSessionInUrl: true}});

/* ---------- helpers ---------- */
function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
function t(k, p) {
  var s = has(STR, k) ? STR[k] : k;
  if (p) s = s.replace(/\{(\w+)\}/g, function (m, n) { return p[n] == null ? '' : String(p[n]); });
  return s;
}
function $(id) { return document.getElementById(id); }
function val(id) { var e = $(id); return e ? e.value : ''; }
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return {'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'}[c]; }); }
function uuid() {
  if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
  var b = new Uint8Array(16); crypto.getRandomValues(b); b[6] = (b[6] & 15) | 64; b[8] = (b[8] & 63) | 128;
  var h = Array.prototype.map.call(b, function (x) { return (x + 256).toString(16).slice(1); }).join('');
  return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
}
// dates: the server speaks ISO yyyy-mm-dd, the page shows dd/mm/yyyy
function fmtDate(iso) { var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso || ''); return m ? m[3] + '/' + m[2] + '/' + m[1] : ''; }
function parseDate(s) {
  var m = /^\s*(\d{1,2})\/(\d{1,2})\/(\d{4})\s*$/.exec(s || ''); if (!m) return null;
  var d = new Date(Date.UTC(+m[3], +m[2] - 1, +m[1]));
  if (d.getUTCDate() !== +m[1] || d.getUTCMonth() !== +m[2] - 1) return null;
  return d.toISOString().slice(0, 10);
}
function eur(n) { return '€' + (Number(n) || 0).toLocaleString('en-GB', {minimumFractionDigits: 2, maximumFractionDigits: 2}); }

/* ---------- api ---------- */
// Every server call goes through api(): erp_api schema only (no table reads from the page), idempotency key on
// writes, 8 s timeout, error code mapping. Reply: {ok, data, error: {code, text, message, detail}}.
function mapError(e) {
  var msg = (e && e.message) || '';
  var m = /^(ERP_[A-Z_]+):\s*([\s\S]*)$/.exec(msg);
  var code = m ? m[1] : (e && e.code === 'PGRST202' ? 'ERP_RPC_MISSING' : 'ERP_NETWORK');
  var detail = null;
  if (e && e.details) { try { detail = JSON.parse(e.details); } catch (x) { detail = e.details; } }
  var text = has(STR, 'err.' + code) ? t('err.' + code) : (m ? m[2] : (msg || t('err.unknown')));
  return {code: code, text: text, message: msg, detail: detail};
}
async function api(name, args, opts) {
  opts = opts || {};
  var a = Object.assign({}, args || {});
  if (opts.write && !a.p_idempotency_key) a.p_idempotency_key = opts.key || uuid();
  var timer, r;
  var timeout = new Promise(function (res) { timer = setTimeout(function () { res({data: null, error: {message: 'ERP_TIMEOUT: timeout'}}); }, API_TIMEOUT_MS); });
  try { r = await Promise.race([sb.schema('erp_api').rpc(name, a), timeout]); }
  catch (e) { r = {data: null, error: {message: String((e && e.message) || e)}}; }
  finally { clearTimeout(timer); }
  if (r.error) return {ok: false, data: null, error: mapError(r.error)};
  return {ok: true, data: r.data, error: null};
}

/* ---------- state ---------- */
var S = {screen: 'boot', me: null, email: '', msg: '', bindConflict: false, err: '', route: null};
var ACT = {};   // click handlers by data-act
var FORM = {};  // submit handlers by data-form

/* ---------- render: outside the app (login, password, no access) ---------- */
function viewLogin() {
  return '<div class="center"><div class="card"><h1>' + esc(t('login.title')) + '</h1><p class="muted">' + esc(t('login.lead')) + '</p>' +
    '<form data-form="login"><label for="a-email">' + esc(t('login.email')) + '</label><input id="a-email" type="email" autocomplete="username">' +
    '<label for="a-pw">' + esc(t('login.password')) + '</label><input id="a-pw" type="password" autocomplete="current-password">' +
    '<div class="msg" id="a-msg">' + esc(S.msg) + '</div>' +
    '<div class="row end"><button type="button" class="link" data-act="forgot">' + esc(t('login.forgot')) + '</button>' +
    '<button type="submit" class="primary" id="a-go">' + esc(t('login.submit')) + '</button></div></form></div></div>';
}
function viewSetPw() {
  return '<div class="center"><div class="card"><h1>' + esc(t('setpw.title')) + '</h1>' +
    '<form data-form="setpw"><label for="a-pw">' + esc(t('setpw.password')) + '</label><input id="a-pw" type="password" autocomplete="new-password">' +
    '<label for="a-pw2">' + esc(t('setpw.repeat')) + '</label><input id="a-pw2" type="password" autocomplete="new-password">' +
    '<div class="msg" id="a-msg">' + esc(S.msg) + '</div><div class="row end"><button type="submit" class="primary">' + esc(t('setpw.submit')) + '</button></div></form></div></div>';
}
function viewNoAccess() {
  return '<div class="center"><div class="card" id="noaccess"><h1>' + esc(t('noaccess.title')) + '</h1><p>' + esc(t('noaccess.lead', {email: S.email})) + '</p>' +
    '<p class="muted">' + esc(S.bindConflict ? t('noaccess.conflict') : t('noaccess.hint')) + '</p>' +
    '<div class="row end"><button data-act="signout">' + esc(t('app.signout')) + '</button></div></div></div>';
}
function viewError() {
  return '<div class="center"><div class="card"><h1>' + esc(t('app.error_title')) + '</h1><p class="msg bad">' + esc(S.err) + '</p>' +
    '<div class="row end"><button data-act="signout">' + esc(t('app.signout')) + '</button><button class="primary" data-act="retry">' + esc(t('app.retry')) + '</button></div></div></div>';
}
function render() {
  document.title = t('app.title');
  var h;
  if (S.screen === 'login') h = viewLogin();
  else if (S.screen === 'setpw') h = viewSetPw();
  else if (S.screen === 'noaccess') h = viewNoAccess();
  else if (S.screen === 'error') h = viewError();
  else if (S.screen === 'app') h = viewApp();
  else h = '<div class="center muted" id="booting">' + esc(t('app.loading')) + '</div>';
  $('app').innerHTML = h;
  if (S.screen === 'app') mountApp();
}

/* ---------- app frame: nav, routing, role guard ---------- */
// A screen: {id, nav: string key or null, caps: [any of these capabilities opens it], render(sub) -> html, mount(sub)}.
// Menus and buttons come from whoami().caps; hiding is never the security control (the server checks every call).
var SCREENS = [];
function screen(def) { SCREENS.push(def); }
function can(cap) { return !!(S.me && S.me.caps && S.me.caps.indexOf(cap) >= 0); }
function canAny(caps) { return !caps || !caps.length || caps.some(can); }
function screenDef(id) { for (var i = 0; i < SCREENS.length; i++) if (SCREENS[i].id === id) return SCREENS[i]; return null; }
function viewApp() {
  var me = S.me, cur = (S.route && S.route.id) || 'home';
  var nav = SCREENS.filter(function (d) { return d.nav && canAny(d.caps); }).map(function (d) {
    return '<a href="#/' + esc(d.id) + '" data-act="go" data-to="' + esc(d.id) + '" class="' + (d.id === cur ? 'on' : '') + '">' + esc(t(d.nav)) + '</a>';
  }).join('');
  return '<div class="top"><span class="brand">' + esc(me.tenant.name) + '</span><nav id="nav">' + nav + '</nav><span class="grow"></span>' +
    '<span class="muted">' + esc(me.email) + '</span><button data-act="signout">' + esc(t('app.signout')) + '</button></div>' +
    '<div class="main" id="main"></div>';
}
function parseRoute() {
  var parts = (location.hash || '').replace(/^#\/?/, '').split('/').filter(Boolean);
  return {id: parts[0] || 'home', sub: parts.slice(1)};
}
function mountApp() { route(); }
function route() {
  var r = parseRoute(), def = screenDef(r.id);
  if (!def) { r = {id: 'home', sub: []}; def = screenDef('home'); }
  if (!canAny(def.caps)) {
    toast(t('guard.not_allowed'));
    r = {id: 'home', sub: []}; def = screenDef('home');
    try { history.replaceState(null, '', '#/home'); } catch (x) {}
  }
  S.route = r;
  var navEl = $('nav');
  if (navEl) Array.prototype.forEach.call(navEl.querySelectorAll('a'), function (a) { a.className = a.getAttribute('data-to') === r.id ? 'on' : ''; });
  $('main').innerHTML = def.render(r.sub);
  if (def.mount) def.mount(r.sub);
}
function go(hash) { if (location.hash === hash) route(); else location.hash = hash; }
ACT.go = function (el) { guardDrawer(function () { go('#/' + el.getAttribute('data-to') + (el.getAttribute('data-sub') ? '/' + el.getAttribute('data-sub') : '')); }); };
window.addEventListener('hashchange', function () { if (S.screen === 'app') { if (D) drawerClose(true); route(); } });

// home: who am I, my branches, today
screen({id: 'home', nav: 'nav.home', caps: [], render: function () {
  var me = S.me;
  var br = me.branches.length ? '<div class="chips">' + me.branches.map(function (b) { return '<span class="badge">' + esc(b.code) + ' · ' + esc(b.name) + '</span>'; }).join('') + '</div>'
    : '<p class="muted">' + esc(t('home.no_branches')) + '</p>';
  return '<h1>' + esc(t('home.title')) + '</h1><p id="home-lead">' + esc(t('home.lead', {tenant: me.tenant.name, email: me.email, role: t('role.' + me.role)})) + '</p>' +
    '<p class="muted">' + esc(t('home.today', {date: fmtDate(me.today), tz: me.settings.time_zone})) + '</p>' +
    '<h2>' + esc(me.all_branches ? t('home.all_branches') : t('home.branches')) + '</h2>' + br;
}});
// reload whoami after a change that alters it (branches, settings) without leaving the screen
async function refreshMe() { var w = await api('whoami'); if (w.ok) S.me = w.data; return w.ok; }

/* ---------- CSV (imports) ---------- */
// RFC 4180 style: quoted fields with "" escapes and line breaks, BOM removed; separator = the most frequent of ; , TAB
// in the first line. Returns an array of rows (arrays of strings); empty lines are dropped.
function parseCsv(text) {
  text = String(text || '').replace(/^\uFEFF/, '');
  var first = text.split(/\r?\n/, 1)[0] || '', seps = [';', ',', '\t'], sep = ';', best = -1;
  seps.forEach(function (c) { var n = first.split(c).length; if (n > best) { best = n; sep = c; } });
  var rows = [], row = [], f = '', q = false, i, ch;
  for (i = 0; i < text.length; i++) {
    ch = text[i];
    if (q) { if (ch === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += ch; continue; }
    if (ch === '"' && f === '') q = true;
    else if (ch === sep) { row.push(f); f = ''; }
    else if (ch === '\n' || ch === '\r') { if (ch === '\r' && text[i + 1] === '\n') i++; row.push(f); f = ''; rows.push(row); row = []; }
    else f += ch;
  }
  if (f !== '' || row.length) { row.push(f); rows.push(row); }
  return rows.filter(function (r) { return r.some(function (x) { return String(x).trim() !== ''; }); });
}
// header row -> objects with the allowed columns only (header names: lower case, spaces to _); reports the others
function csvObjects(text, allowed) {
  var rows = parseCsv(text); if (!rows.length) return {rows: [], ignored: [], header: []};
  var head = rows[0].map(function (h) { return String(h).trim().toLowerCase().replace(/\s+/g, '_'); });
  var ignored = head.filter(function (h) { return h && allowed.indexOf(h) < 0; });
  return {header: head, ignored: ignored, rows: rows.slice(1).map(function (r) {
    var o = {}; head.forEach(function (h, i) { if (allowed.indexOf(h) >= 0 && r[i] != null && String(r[i]).trim() !== '') o[h] = String(r[i]).trim(); }); return o;
  })};
}

/* ---------- form helpers (every screen) ---------- */
function sel(id, opts, cur, disabled) {
  return '<select id="' + id + '"' + (disabled ? ' disabled' : '') + '>' + opts.map(function (o) {
    return '<option value="' + esc(o[0]) + '"' + (String(o[0]) === String(cur) ? ' selected' : '') + '>' + esc(o[1]) + '</option>';
  }).join('') + '</select>';
}
function field(id, label, input) { return '<label for="' + id + '">' + esc(t(label)) + '</label>' + input; }
function inp(id, v, type, disabled) { return '<input id="' + id + '" type="' + (type || 'text') + '" value="' + esc(v == null ? '' : v) + '"' + (disabled ? ' disabled' : '') + '>'; }
function chk(id, label, on, disabled) { return '<label class="check"><input type="checkbox" id="' + id + '"' + (on ? ' checked' : '') + (disabled ? ' disabled' : '') + '> ' + esc(t(label)) + '</label>'; }

/* ---------- drawer, confirm, toast ---------- */
// drawerOpen({title, body() -> html, save: async () -> api reply | {local: problems}, onSaved(data), readOnly})
// Save: button disabled while running; "Not saved: <reason>" on an error OR an empty reply; problems listed;
// one idempotency key per drawer (D.key), renewed after a success; unsaved-changes guard on close.
var D = null;
function drawerOpen(d) {
  D = d; d.key = uuid(); d.dirty = false; d.busy = false;
  $('layer').innerHTML = '<div class="overlay" data-act="drawer-close"></div><div class="drawer" role="dialog" aria-modal="true" id="drawer">' +
    '<header><h2>' + esc(d.title) + '</h2><span class="grow"></span><button class="link" data-act="drawer-close">' + esc(t('drawer.close')) + '</button></header>' +
    '<div class="body"><form id="d-form" autocomplete="off">' + d.body() + '</form><div class="msg bad" id="d-msg"></div></div>' +
    '<footer>' + (d.extra || '') + (d.save && !d.readOnly ? '<button class="primary" id="d-save" data-act="drawer-save">' + esc(t('drawer.save')) + '</button>' : '') + '</footer></div>';
  if (d.mount) d.mount();
  var f = $('d-form'); if (f) { var first = f.querySelector('input:not([disabled]),select:not([disabled])'); if (first) first.focus(); }
}
function drawerClose(force) {
  if (!D) return;
  if (D.dirty && !force) { confirmBox(t('drawer.unsaved'), t('drawer.discard'), t('drawer.keep'), function () { drawerClose(true); }); return; }
  D = null; $('layer').innerHTML = '';
}
function guardDrawer(next) { if (D && D.dirty) confirmBox(t('drawer.unsaved'), t('drawer.discard'), t('drawer.keep'), function () { drawerClose(true); next(); }); else { if (D) drawerClose(true); next(); } }
function drawerMsg(text, problems) {
  var m = $('d-msg'); if (!m) return;
  var list = (problems && problems.length) ? '<ul class="problems">' + problems.map(function (p) { return '<li>' + esc(p.message || p.code) + '</li>'; }).join('') + '</ul>' : '';
  m.innerHTML = text ? esc(text) + list : '';
}
function notSaved(r) {
  if (!r || !r.ok) return t('save.not_saved', {reason: (r && r.error && r.error.text) || t('err.unknown')});
  return t('save.not_saved', {reason: t('save.zero_rows')});
}
ACT['drawer-close'] = function () { drawerClose(false); };
ACT['drawer-save'] = async function () {
  if (!D || D.busy || !D.save) return;
  var d = D, b = $('d-save');
  d.busy = true; b.disabled = true; b.textContent = t('drawer.saving'); drawerMsg('');
  var r;
  try { r = await d.save(); } catch (e) { r = {ok: false, error: {text: String((e && e.message) || e)}}; }
  if (D !== d) return;
  d.busy = false; b.disabled = false; b.textContent = t('drawer.save');
  if (r && r.local) { drawerMsg(t('save.not_saved', {reason: t('err.ERP_VALIDATION')}), r.local); return; }
  if (!r || !r.ok || r.data == null) { drawerMsg(notSaved(r), r && r.error && Array.isArray(r.error.detail) ? r.error.detail : null); return; }
  d.dirty = false; d.key = uuid();
  drawerClose(true); toast(t('save.saved'));
  if (d.onSaved) await d.onSaved(r.data);
};
document.addEventListener('input', function (e) { if (D && e.target.closest('#drawer')) D.dirty = true; });
document.addEventListener('change', function (e) { if (D && e.target.closest('#drawer')) D.dirty = true; });
document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && D && !$('modal-ok')) drawerClose(false); });

var confirmNext = null;
function confirmBox(text, okLabel, cancelLabel, onOk) {
  confirmNext = onOk;
  var el = document.createElement('div'); el.id = 'modal-root';
  el.innerHTML = '<div class="modal-bg"></div><div class="modal" role="alertdialog" aria-modal="true"><p id="modal-text">' + esc(text) + '</p>' +
    '<div class="row end"><button data-act="modal-cancel" id="modal-cancel">' + esc(cancelLabel || t('cancel')) + '</button>' +
    '<button class="primary" data-act="modal-ok" id="modal-ok">' + esc(okLabel || t('ok')) + '</button></div></div>';
  document.body.appendChild(el);
}
// promptBox: like confirmBox with one text input; onOk(value) gets the trimmed text (required when p.required)
function promptBox(text, label, okLabel, onOk, required) {
  confirmNext = function () {};
  var el = document.createElement('div'); el.id = 'modal-root';
  el.innerHTML = '<div class="modal-bg"></div><div class="modal" role="dialog" aria-modal="true"><p id="modal-text">' + esc(text) + '</p>' +
    '<label for="modal-input">' + esc(label) + '</label><input id="modal-input" type="text"><div class="msg bad" id="modal-msg"></div>' +
    '<div class="row end"><button data-act="modal-cancel" id="modal-cancel">' + esc(t('cancel')) + '</button>' +
    '<button class="primary" data-act="modal-prompt-ok" id="modal-ok">' + esc(okLabel || t('ok')) + '</button></div></div>';
  document.body.appendChild(el);
  promptNext = {fn: onOk, required: !!required};
  $('modal-input').focus();
}
var promptNext = null;
ACT['modal-prompt-ok'] = function () {
  var v = val('modal-input').trim(), p = promptNext;
  if (p && p.required && !v) { $('modal-msg').textContent = t('prompt.required'); return; }
  promptNext = null; confirmNext = null; confirmClose(); if (p && p.fn) p.fn(v);
};
function confirmClose() { var el = $('modal-root'); if (el) el.parentNode.removeChild(el); }
ACT['modal-cancel'] = function () { confirmNext = null; confirmClose(); };
ACT['modal-ok'] = function () { var f = confirmNext; confirmNext = null; confirmClose(); if (f) f(); };

var toastTimer = null;
function toast(text) {
  var el = $('toast'); if (!el) { el = document.createElement('div'); el.id = 'toast'; el.className = 'toast'; document.body.appendChild(el); }
  el.textContent = text; el.style.display = '';
  clearTimeout(toastTimer); toastTimer = setTimeout(function () { el.style.display = 'none'; }, 2500);
}

/* ---------- session ---------- */
var entering = false;
async function enter() {
  if (entering) return; entering = true;
  try { await enterOnce(); } finally { entering = false; }
}
async function enterOnce() {
  S.screen = 'boot'; S.bindConflict = false; render();
  var s = await sb.auth.getSession();
  var sess = s && s.data && s.data.session;
  S.email = (sess && sess.user && sess.user.email) || '';
  var b = await api('member_bind', {}, {write: true});
  if (b.ok && b.data && b.data.reason === 'bound_to_other_login') S.bindConflict = true;
  var w = await api('whoami');
  if (!w.ok) {
    if (w.error.code === 'ERP_AUTH') S.screen = 'noaccess';
    else { S.screen = 'error'; S.err = w.error.text; }
    render(); return;
  }
  S.me = w.data; S.screen = 'app'; render();
}
ACT.signout = async function () { await sb.auth.signOut(); };
ACT.retry = function () { enter(); };
ACT.forgot = async function () {
  var em = val('a-email').trim();
  if (!em) { S.msg = t('login.need_email'); $('a-msg').textContent = S.msg; return; }
  var r = await sb.auth.resetPasswordForEmail(em, {redirectTo: location.origin + location.pathname});
  S.msg = r.error ? r.error.message : t('login.reset_sent'); $('a-msg').textContent = S.msg;
};
FORM.login = async function () {
  var em = val('a-email').trim(), pw = val('a-pw');
  if (!em || !pw) { $('a-msg').textContent = t('login.need_both'); return; }
  $('a-go').disabled = true; $('a-msg').textContent = t('login.busy');
  var r = await sb.auth.signInWithPassword({email: em, password: pw});
  if (r.error) { $('a-go').disabled = false; $('a-msg').textContent = r.error.message; }
};
FORM.setpw = async function () {
  var p1 = val('a-pw'), p2 = val('a-pw2');
  if (p1.length < 8) { $('a-msg').textContent = t('setpw.short'); return; }
  if (p1 !== p2) { $('a-msg').textContent = t('setpw.different'); return; }
  var r = await sb.auth.updateUser({password: p1});
  if (r.error) { $('a-msg').textContent = r.error.message; return; }
  try { history.replaceState(null, '', location.pathname); } catch (x) {}
  S.msg = ''; await enter();
};
document.addEventListener('click', function (e) {
  var el = e.target.closest('[data-act]'); if (!el) return;
  var f = ACT[el.getAttribute('data-act')]; if (!f) return;
  e.preventDefault(); f(el, e);
});
document.addEventListener('submit', function (e) {
  var f = FORM[e.target.getAttribute('data-form')]; if (!f) return;
  e.preventDefault(); f(e.target, e);
});
