/* ---------- boot (last file: every screen is registered before the first render) ---------- */
var linkDone = false;
sb.auth.onAuthStateChange(function (ev, sess) {
  setTimeout(async function () {
    if (ev === 'PASSWORD_RECOVERY' || (ev === 'SIGNED_IN' && arrivedByLink && !linkDone && S.screen !== 'app')) { linkDone = true; S.screen = 'setpw'; S.msg = ''; render(); return; }
    if (ev === 'SIGNED_OUT' || (ev === 'INITIAL_SESSION' && !sess)) { if (D) drawerClose(true); S.me = null; S.msg = ''; S.screen = 'login'; render(); return; }
    if ((ev === 'SIGNED_IN' || ev === 'INITIAL_SESSION') && sess && S.screen !== 'app' && S.screen !== 'setpw') await enter();
  }, 0);
});
render();
