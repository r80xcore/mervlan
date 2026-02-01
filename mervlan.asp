<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <!-- mervlan.asp version="0.47" -->
<meta http-equiv="X-UA-Compatible" content="IE=Edge">
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="-1">
<link rel="shortcut icon" href="images/favicon.png">
<link rel="icon" href="images/favicon.png">

<title>Merlin VLAN Manager</title>

<!-- Keep the stock ASUSWRT-Merlin CSS so the shell looks normal -->
<link rel="stylesheet" type="text/css" href="index_style.css">
<link rel="stylesheet" type="text/css" href="form_style.css">

<!-- Ensure jQuery is present before ASUS core scripts -->
<script type="text/javascript">
if (typeof window.jQuery === "undefined" && typeof window.$ === "undefined") {
  document.write('<script src="/js/jquery.js"><\/script>');
}
</script>

<!-- Core ASUS scripts that build the chrome/menu -->
<script type="text/javascript" src="/state.js"></script>
<script type="text/javascript" src="/general.js"></script>
<script type="text/javascript" src="/popup.js"></script>
<script type="text/javascript" src="/help.js"></script>
<script type="text/javascript" src="/validator.js"></script>

<script>
function SetCurrentPage() {
  document.form.next_page.value = window.location.pathname.substring(1);
  document.form.current_page.value = window.location.pathname.substring(1);
}

function initial(){
  SetCurrentPage();
  if (typeof show_menu === "function") {
    show_menu(); // fills TopBanner, mainMenu, tabMenu, etc
  } else if (window.console && typeof console.error === "function") {
    console.error("show_menu() not available");
  }
}
</script>
<script type="text/javascript">
var _mvmLast = { name: null, t: 0 };

// === Loading overlay guard: block early hides until minimum time passes ===
(function() {
  var origHide = window.hideLoading;
  var origShow = window.showLoading;
  var mvmLoadingUntil = 0;

  // Call this to enforce a minimum visible duration (ms)
  window._mvmHoldLoadingFor = function(ms) {
    var until = Date.now() + ms;
    if (until > mvmLoadingUntil) mvmLoadingUntil = until;
  };

  // Block early hides - this is the key to reliable timing
  window.hideLoading = function() {
    if (Date.now() < mvmLoadingUntil) return; // blocked: too early
    if (typeof origHide === "function") return origHide.apply(this, arguments);
    // fallback
    var overlay = document.getElementById("Loading");
    if (overlay) overlay.style.display = "none";
  };

  // Ensure showLoading doesn't use a tiny duration that expires before our minimum
  window.showLoading = function(arg) {
    if (typeof arg === "number") {
      var remainSec = Math.ceil((mvmLoadingUntil - Date.now()) / 1000);
      if (remainSec > 0) arg = Math.max(arg, remainSec);
    }
    if (typeof origShow === "function") return origShow.apply(this, arguments);
    // fallback
    var overlay = document.getElementById("Loading");
    if (overlay) overlay.style.display = "block";
  };
})();

// Hide the ASUS loading overlay even when the skin only exposes showLoading(flag)
function hideLoadingSafe() {
  if (typeof hideLoading === "function") {
    try { hideLoading(); } catch (e) {}
  } else if (typeof showLoading === "function" && showLoading.length > 0) {
    try { showLoading(0); } catch (e2) {}
  } else {
    var overlay = document.getElementById("Loading");
    if (overlay) {
      overlay.style.display = "none";
    }
  }
}

// Show the ASUS loading overlay while tolerating different skin signatures
function showLoadingSafe(secHint) {
  if (typeof showLoading !== "function") {
    var overlay = document.getElementById("Loading");
    if (overlay) overlay.style.display = "block";
    return;
  }
  try {
    if (showLoading.length > 0) {
      // Pass a sane duration (seconds), not 1 which expires immediately
      var s = (typeof secHint === "number" && secHint > 0) ? secHint : 30;
      showLoading(s);
    } else {
      showLoading();
    }
  } catch (e) {}
}

/**
 * Execute a backend action with optional UI and behavior controls.
 * @param {string} actionScriptName - backend script (e.g., "sync_vlanmgr")
 * @param {?object} settingsObjOrNull - JSON payload for amng_custom
 * @param {?object} opts - { loading?: boolean, waitSec?: number, target?: string,
 *                           skipRefresh?: boolean }
 */
function MVM_exec(actionScriptName, settingsObjOrNull, opts) {
  opts = opts || {};

  if (!MVM_ALLOWED_ACTIONS.has(actionScriptName)) {
    if (window.console && typeof console.warn === "function") {
      console.warn("[MVM] blocked disallowed action", actionScriptName);
    }
    return;
  }

  // Prevent rapid double-clicks from issuing duplicate requests
  var now = (typeof Date.now === "function") ? Date.now() : new Date().getTime();
  if (_mvmLast.name === actionScriptName && (now - _mvmLast.t) < 2000) {
    if (window.console && typeof console.log === "function") {
      console.log("[MVM] deduped", actionScriptName);
    }
    return;
  }
  _mvmLast = { name: actionScriptName, t: now };

  // Write settings payload when provided; clear otherwise
  var amng = document.getElementById("amng_custom");
  if (settingsObjOrNull != null) {
    if (!amng) {
      alert("amng_custom not found in parent form");
      return;
    }
    amng.value = JSON.stringify(settingsObjOrNull);
  } else if (amng) {
    amng.value = "";
  }

  // Populate the hidden Asuswrt form fields that trigger service-event
  document.form.action_script.value = actionScriptName;
  document.form.action_mode.value = "apply"; // required so service-event fires once
  var actionWaitField = document.form.action_wait;
  if (actionWaitField) {
    actionWaitField.value = String((opts.waitSec != null) ? opts.waitSec : 5);
    actionWaitField.setAttribute("value", actionWaitField.value);
  }

  var skipRefresh = !!opts.skipRefresh;
  // Note: we no longer zero out action_wait when skipRefresh is true
  // This allows the loading overlay to show while still preventing page refresh

  var orig = {
    refresh_self: (typeof window.refreshpage !== "undefined") ? window.refreshpage : undefined,
    redirect_self: (typeof window.redirect_page !== "undefined") ? window.redirect_page : undefined,
    refresh_parent: (window.parent && window.parent !== window && typeof window.parent.refreshpage !== "undefined") ? window.parent.refreshpage : undefined,
    redirect_parent: (window.parent && window.parent !== window && typeof window.parent.redirect_page !== "undefined") ? window.parent.redirect_page : undefined
  };

  if (skipRefresh) {
    try {
      if (document.form.next_page) {
        document.form.next_page.value = "";
      }
    } catch (e) {}

    window.refreshpage = function() {};
    window.redirect_page = function() {};

    if (window.parent && window.parent !== window) {
      try { window.parent.refreshpage = function() {}; } catch (e) {}
      try { window.parent.redirect_page = function() {}; } catch (e2) {}
    }
  }

  if (skipRefresh) {
    var sbox = mvmEnsureSandboxFrame();
    document.form.target = sbox.name;
    document.form.setAttribute("target", sbox.name);
  } else {
    document.form.target = opts.target || "hidden_frame";
    document.form.setAttribute("target", document.form.target);
  }

  var wantLoading = (opts.loading !== false);
  var minLoadingMs = (opts.minLoadingMs != null) ? opts.minLoadingMs : 0;
  
  if (wantLoading) {
    // Lock the loading overlay so ASUS firmware cannot dismiss it early
    if (minLoadingMs > 0 && typeof window._mvmHoldLoadingFor === "function") {
      window._mvmHoldLoadingFor(minLoadingMs);
    }
    // Pass duration hint to showLoadingSafe (converts ms to seconds)
    var secHint = minLoadingMs > 0 ? Math.ceil(minLoadingMs / 1000) : 30;
    showLoadingSafe(secHint);
    // Hide after the minimum duration
    if (minLoadingMs > 0) {
      setTimeout(function() { hideLoadingSafe(); }, minLoadingMs);
    }
  } else {
    hideLoadingSafe();
  }

  // Helper to hide loading (only if no minLoadingMs, otherwise the timeout handles it)
  function hideLoadingIfNoMinTime() {
    if (minLoadingMs <= 0) {
      hideLoadingSafe();
    }
    // If minLoadingMs > 0, the setTimeout above will handle hiding
  }

  // Keep overlay hidden if we opted out of loading feedback
  var targetFrameId = skipRefresh ? "mvm_sandbox_iframe" : (document.form.target || "hidden_frame");
  var tf = document.getElementById(targetFrameId);
  if (tf) {
    var oneShot = function() {
      if (tf.removeEventListener) {
        tf.removeEventListener("load", oneShot);
      } else if (tf.detachEvent) {
        tf.detachEvent("onload", oneShot);
      }
      hideLoadingIfNoMinTime();
      if (skipRefresh) {
        if (typeof orig.refresh_self !== "undefined") {
          window.refreshpage = orig.refresh_self;
        } else {
          try { delete window.refreshpage; } catch (e) { window.refreshpage = undefined; }
        }

        if (typeof orig.redirect_self !== "undefined") {
          window.redirect_page = orig.redirect_self;
        } else {
          try { delete window.redirect_page; } catch (e2) { window.redirect_page = undefined; }
        }

        if (window.parent && window.parent !== window) {
          try {
            if (typeof orig.refresh_parent !== "undefined") {
              window.parent.refreshpage = orig.refresh_parent;
            } else {
              window.parent.refreshpage = undefined;
            }
          } catch (e3) {}

          try {
            if (typeof orig.redirect_parent !== "undefined") {
              window.parent.redirect_page = orig.redirect_parent;
            } else {
              window.parent.redirect_page = undefined;
            }
          } catch (e4) {}
        }
        mvmRemoveSandboxFrame();
      } else if (!wantLoading) {
        hideLoadingSafe();
      }
    };
    if (tf.addEventListener) {
      tf.addEventListener("load", oneShot);
    } else if (tf.attachEvent) {
      tf.attachEvent("onload", oneShot);
    }
  } else if (skipRefresh) {
    if (typeof orig.refresh_self !== "undefined") {
      window.refreshpage = orig.refresh_self;
    } else {
      try { delete window.refreshpage; } catch (e) { window.refreshpage = undefined; }
    }

    if (typeof orig.redirect_self !== "undefined") {
      window.redirect_page = orig.redirect_self;
    } else {
      try { delete window.redirect_page; } catch (e2) { window.redirect_page = undefined; }
    }

    if (window.parent && window.parent !== window) {
      try {
        if (typeof orig.refresh_parent !== "undefined") {
          window.parent.refreshpage = orig.refresh_parent;
        } else {
          window.parent.refreshpage = undefined;
        }
      } catch (e3) {}

      try {
        if (typeof orig.redirect_parent !== "undefined") {
          window.parent.redirect_page = orig.redirect_parent;
        } else {
          window.parent.redirect_page = undefined;
        }
      } catch (e4) {}
    }
    mvmRemoveSandboxFrame();
  }

  document.form.submit();
}
</script>

<script type="text/javascript">
function mvmEnsureSandboxFrame() {
  var id = "mvm_sandbox_iframe";
  var s = document.getElementById(id);
  if (s) {
    return s;
  }

  s = document.createElement("iframe");
  s.id = id;
  s.name = id;
  s.setAttribute("sandbox", "allow-forms allow-scripts");
  s.style.width = "0";
  s.style.height = "0";
  s.style.border = "0";
  s.style.position = "absolute";
  s.style.left = "-99999px";
  document.body.appendChild(s);
  return s;
}
function mvmRemoveSandboxFrame() {
  var s = document.getElementById("mvm_sandbox_iframe");
  if (s && s.parentNode) {
    s.parentNode.removeChild(s);
  }
}
</script>

<script type="text/javascript">
/* === Policy lines you edit === */
const MVM_NO_REFRESH = new Set([
  // Actions that must NOT refresh the page after running:
  "save_vlanmgr",
  "collectclients_vlanmgr",
  "sync_vlanmgr",
  "apply_vlanmgr",
  "executenodes_vlanmgr",
  "executenodesonly_vlanmgr",
  "genkey_vlanmgr",
  "update_vlanmgr",
  "updatedev_vlanmgr",
  "enableservice_vlanmgr",
  "disableservice_vlanmgr",
  "checkservice_vlanmgr"
]);

const MVM_NO_LOADING = new Set([
  // Actions that should NOT show the loading overlay:
  // "checkservice_vlanmgr",
  // "collectclients_vlanmgr",
  "update_vlanmgr",
  "updatedev_vlanmgr"
]);

const MVM_ALLOWED_ACTIONS = new Set([
  "save_vlanmgr",
  "apply_vlanmgr",
  "sync_vlanmgr",
  "executenodes_vlanmgr",
  "executenodesonly_vlanmgr",
  "genkey_vlanmgr",
  "enableservice_vlanmgr",
  "disableservice_vlanmgr",
  "checkservice_vlanmgr",
  "collectclients_vlanmgr",
  "update_vlanmgr",
  "updatedev_vlanmgr"
]);

// Optional: actions that need a longer/shorter wait (seconds)
const MVM_WAIT_OVERRIDE = {
  // "save_vlanmgr": 5000
  // "sync_vlanmgr": 30,
  // "apply_vlanmgr": 20,
};

// Optional: actions that need a minimum loading screen time (milliseconds)
const MVM_MIN_LOADING_MS = {
  "save_vlanmgr": 5000  // Show loading for at least 1.5s to allow clear+reload verification
};

/* Build final opts for an action using the policy + any per-call override */
function mvmOptsFor(actionName, overrideOpts) {
  const opts = {
    loading: !MVM_NO_LOADING.has(actionName),
    skipRefresh: MVM_NO_REFRESH.has(actionName),
    waitSec: (Object.prototype.hasOwnProperty.call(MVM_WAIT_OVERRIDE, actionName)
              ? MVM_WAIT_OVERRIDE[actionName]
              : 5),
    minLoadingMs: (Object.prototype.hasOwnProperty.call(MVM_MIN_LOADING_MS, actionName)
              ? MVM_MIN_LOADING_MS[actionName]
              : 0),
    target: "hidden_frame",
  };
  if (overrideOpts && typeof overrideOpts === "object") {
    // Let buttons override anything ad-hoc
    if ("loading" in overrideOpts)     opts.loading = overrideOpts.loading;
    if ("skipRefresh" in overrideOpts) opts.skipRefresh = overrideOpts.skipRefresh;
    if ("waitSec" in overrideOpts)     opts.waitSec = overrideOpts.waitSec;
    if ("minLoadingMs" in overrideOpts) opts.minLoadingMs = overrideOpts.minLoadingMs;
    if ("target" in overrideOpts)      opts.target = overrideOpts.target;
  }
  return opts;
}

/* === Wrapper helpers (policy-aware) ===
   You keep calling these from your buttons,
   and you ONLY edit the sets/maps above. */
function MVM_save(settingsObj, opts)         { return MVM_exec("save_vlanmgr",          settingsObj, mvmOptsFor("save_vlanmgr",          opts)); }
function MVM_trigger(actionScriptName, opts) { return MVM_exec(actionScriptName,        null,        mvmOptsFor(actionScriptName,        opts)); }
function MVM_apply(opts)                     { return MVM_exec("apply_vlanmgr",         null,        mvmOptsFor("apply_vlanmgr",         opts)); }
function MVM_sync(opts)                      { return MVM_exec("sync_vlanmgr",          null,        mvmOptsFor("sync_vlanmgr",          opts)); }
function MVM_executeNodes(opts)              { return MVM_exec("executenodes_vlanmgr",  null,        mvmOptsFor("executenodes_vlanmgr",  opts)); }
function MVM_executeNodesOnly(opts)          { return MVM_exec("executenodesonly_vlanmgr",  null,        mvmOptsFor("executenodesonly_vlanmgr",  opts)); }
function MVM_genkey(opts)                    { return MVM_exec("genkey_vlanmgr",        null,        mvmOptsFor("genkey_vlanmgr",        opts)); }
function MVM_enableService(opts)             { return MVM_exec("enableservice_vlanmgr", null,        mvmOptsFor("enableservice_vlanmgr", opts)); }
function MVM_disableService(opts)            { return MVM_exec("disableservice_vlanmgr",null,        mvmOptsFor("disableservice_vlanmgr",opts)); }
function MVM_checkService(opts)              { return MVM_exec("checkservice_vlanmgr",  null,        mvmOptsFor("checkservice_vlanmgr",  opts)); }
function MVM_collectClients(opts)            { return MVM_exec("collectclients_vlanmgr",null,        mvmOptsFor("collectclients_vlanmgr",opts)); }
function MVM_update(opts)                    { return MVM_exec("update_vlanmgr",        null,        mvmOptsFor("update_vlanmgr",        opts)); }
function MVM_updateDev(opts)                 { return MVM_exec("updatedev_vlanmgr",     null,        mvmOptsFor("updatedev_vlanmgr",     opts)); }

// Convenience helper for silent saves invoked from the embedded SPA
function MVM_save_quiet(settingsObj) {
  return MVM_save(settingsObj, { loading: false, waitSec: 0, skipRefresh: true });
}
</script>
</head>

<body onload="initial();" class="bg">

<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>

<!-- hidden frame plumbing Merlin expects -->
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>

<form method="post" name="form" action="start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" value="">
<input type="hidden" name="next_page" value="">
<input type="hidden" name="group_id" value="">
<input type="hidden" name="modified" value="0">
<input type="hidden" name="action_mode" value="apply">
<input type="hidden" name="action_wait" value="5">
<input type="hidden" name="first_time" value="">
<input type="hidden" name="action_script" value="">
<input type="hidden" name="preferred_lang" id="preferred_lang" value="<% nvram_get("preferred_lang"); %>">
<input type="hidden" name="firmver" value="<% nvram_get("firmver"); %>">
<input type="hidden" name="amng_custom" id="amng_custom" value="">

<table class="content" align="center" cellpadding="0" cellspacing="0">
<tr>
  <td width="17">&nbsp;</td>

  <!-- left sidebar -->
  <td valign="top" width="202">
    <div id="mainMenu"></div>
    <div id="subMenu"></div>
  </td>

  <!-- main content -->
  <td valign="top">
    <!-- tab bar -->
    <div id="tabMenu" class="submenuBlock"></div>

    <table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
    <tr>
      <td align="left" valign="top">
        <table width="760px" border="0" cellpadding="5" cellspacing="0"
               bordercolor="#6b8fa3" class="FormTitle" id="FormTitle">
        <tr>
          <td bgcolor="#4D595D" colspan="3" valign="top">

            <div>&nbsp;</div>
            <div class="formfonttitle">Merlin VLAN Manager</div>
            <div style="margin:10px 0 10px 5px;" class="splitLine"></div>

            <!-- THE IFRAME (STATIC HEIGHT + SINGLE SCROLL) -->
            <iframe
              id="vlan_iframe"
              src="/user/mervlan/index.html"
              style="
                width:100%;
                height:1300px;          /* <-- change this number to tune */
                border:0;
                background:transparent;
                overflow:hidden;        /* no inner scrollbar */
                display:block;
              "
              frameborder="0"
              scrolling="no">
            </iframe>

            <!-- Re-apply iframe scroll settings defensively (some skins override) -->
            <script type="text/javascript">
            (function(){
              var f = document.getElementById("vlan_iframe");
              if(!f) return;

              function apply(){
                try{
                  f.setAttribute("scrolling","no");
                  f.style.overflow = "hidden";
                  f.style.display = "block";
                  // height is static; you tune it above
                }catch(e){}
              }

              // apply now + after iframe load
              apply();
              if(f.addEventListener){
                f.addEventListener("load", apply, false);
              }else if(f.attachEvent){
                f.attachEvent("onload", apply);
              }
            })();
            </script>

          </td>
        </tr>
        </table>
      </td>
    </tr>
    </table>

  </td>

  <td width="10" align="center" valign="top">&nbsp;</td>
</tr>
</table>

<div id="footer"></div>
</form>

</body>
</html>