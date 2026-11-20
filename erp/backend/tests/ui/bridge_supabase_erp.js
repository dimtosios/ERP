// Stub of supabase-js that BRIDGES erp_api RPCs to a real local PostgreSQL (used by smoke_erp_db.py): every rpc is a
// POST to http://erp-bridge.test/rpc/<name>, which the Playwright test answers by running the SQL function as role
// authenticated with the JWT claims of the stub login (localStorage bridge_sub / bridge_email). Auth is faked: the
// page is always signed in. Reply shape = PostgREST: {data} or {error: {message, details, code}}.
(function () {
  var CALLS = window.__calls = [];
  function ls(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  var listeners = [];
  function session() { return {access_token: 'bridge', user: {email: ls('bridge_email')}}; }
  window.supabase = {createClient: function () {
    return {
      auth: {
        getSession: async function () { return {data: {session: session()}, error: null}; },
        onAuthStateChange: function (f) { listeners.push(f); setTimeout(function () { f('INITIAL_SESSION', session()); }, 0); return {data: {subscription: {unsubscribe: function () {}}}}; },
        signInWithPassword: async function () { return {data: {session: session()}, error: null}; },
        signOut: async function () { listeners.forEach(function (f) { f('SIGNED_OUT', null); }); return {error: null}; },
        resetPasswordForEmail: async function () { return {data: {}, error: null}; },
        updateUser: async function () { return {data: {}, error: null}; }
      },
      schema: function (sch) {
        return {rpc: async function (name, args) {
          CALLS.push({schema: sch, name: name, args: JSON.parse(JSON.stringify(args || {}))});
          var r = await fetch('http://erp-bridge.test/rpc/' + encodeURIComponent(sch) + '/' + encodeURIComponent(name),
            {method: 'POST', body: JSON.stringify({args: args || {}, sub: ls('bridge_sub'), email: ls('bridge_email')})});
          return await r.json();
        }};
      }
    };
  }};
})();
