<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <!-- view_logs.html version="0.45" -->
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
  show_menu(); // fills TopBanner, mainMenu, tabMenu, etc
}
</script>
<script type="text/javascript">
var _mvmLast = { name: null, t: 0 };

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
function showLoadingSafe() {
  if (typeof showLoading !== "function") {
    return;
  }
  try {
    if (showLoading.length > 0) {
      showLoading(1);
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
  if (skipRefresh) {
    // Minimize any server-side wait UI when we plan to suppress refresh
    if (actionWaitField) {
      actionWaitField.value = "0";
      actionWaitField.setAttribute("value", "0");
    }
  }

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
  if (wantLoading) {
    showLoadingSafe();
  } else {
    hideLoadingSafe();
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
      hideLoadingSafe();
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
  // "save_vlanmgr",
  "collectclients_vlanmgr",
  "sync_vlanmgr",
  "apply_vlanmgr",
  "genkey_vlanmgr",
  // "checkservice_vlanmgr",
  // "collectclients_vlanmgr",
]);

const MVM_NO_LOADING = new Set([
  // Actions that should NOT show the loading overlay:
  // "checkservice_vlanmgr",
  // "collectclients_vlanmgr",
]);

// Optional: actions that need a longer/shorter wait (seconds)
const MVM_WAIT_OVERRIDE = {
  // "sync_vlanmgr": 30,
  // "apply_vlanmgr": 20,
};

/* Build final opts for an action using the policy + any per-call override */
function mvmOptsFor(actionName, overrideOpts) {
  const opts = {
    loading: !MVM_NO_LOADING.has(actionName),
    skipRefresh: MVM_NO_REFRESH.has(actionName),
    waitSec: (Object.prototype.hasOwnProperty.call(MVM_WAIT_OVERRIDE, actionName)
              ? MVM_WAIT_OVERRIDE[actionName]
              : 5),
    target: "hidden_frame",
  };
  if (overrideOpts && typeof overrideOpts === "object") {
    // Let buttons override anything ad-hoc
    if ("loading" in overrideOpts)     opts.loading = overrideOpts.loading;
    if ("skipRefresh" in overrideOpts) opts.skipRefresh = overrideOpts.skipRefresh;
    if ("waitSec" in overrideOpts)     opts.waitSec = overrideOpts.waitSec;
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
function MVM_genkey(opts)                    { return MVM_exec("genkey_vlanmgr",        null,        mvmOptsFor("genkey_vlanmgr",        opts)); }
function MVM_enableService(opts)             { return MVM_exec("enableservice_vlanmgr", null,        mvmOptsFor("enableservice_vlanmgr", opts)); }
function MVM_disableService(opts)            { return MVM_exec("disableservice_vlanmgr",null,        mvmOptsFor("disableservice_vlanmgr",opts)); }
function MVM_checkService(opts)              { return MVM_exec("checkservice_vlanmgr",  null,        mvmOptsFor("checkservice_vlanmgr",  opts)); }
function MVM_collectClients(opts)            { return MVM_exec("collectclients_vlanmgr",null,        mvmOptsFor("collectclients_vlanmgr",opts)); }

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

            <!-- THE IFRAME -->
            <iframe
              id="vlan_iframe"
              src="/user/mervlan/index.html"
              style="
                width:100%;
                min-height: 950px;
                border:0;
                background:transparent;
                overflow:visible;
              "
              frameborder="0"
              scrolling="auto">
            </iframe>

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