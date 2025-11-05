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
 * @param {?object} opts - { loading?: boolean, waitSec?: number, target?: string }
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
  document.form.target = opts.target || "hidden_frame";
  document.form.setAttribute("target", document.form.target);

  var wantLoading = (opts.loading !== false);
  if (wantLoading) {
    showLoadingSafe();
  } else {
    hideLoadingSafe();
  }

  // Keep overlay hidden if we opted out of loading feedback
  if (!wantLoading) {
    var hf = document.getElementById("hidden_frame");
    if (hf) {
      var oneShot = function() {
        if (hf.removeEventListener) {
          hf.removeEventListener("load", oneShot);
        } else if (hf.detachEvent) {
          hf.detachEvent("onload", oneShot);
        }
        hideLoadingSafe();
      };
      if (hf.addEventListener) {
        hf.addEventListener("load", oneShot);
      } else if (hf.attachEvent) {
        hf.attachEvent("onload", oneShot);
      }
    }
  }

  document.form.submit();
}

/* Wrapper helpers — pass opts (loading/waitSec/target) to customize behavior */
function MVM_save(settingsObj, opts)         { MVM_exec("save_vlanmgr",          settingsObj, opts); }
function MVM_trigger(actionScriptName, opts) { MVM_exec(actionScriptName,        null,        opts); }
function MVM_apply(opts)                     { MVM_exec("apply_vlanmgr",         null,        opts); }
function MVM_sync(opts)                      { MVM_exec("sync_vlanmgr",          null,        opts); }
function MVM_genkey(opts)                    { MVM_exec("genkey_vlanmgr",        null,        opts); }
function MVM_enableService(opts)             { MVM_exec("enableservice_vlanmgr", null,        opts); }
function MVM_disableService(opts)            { MVM_exec("disableservice_vlanmgr",null,        opts); }
function MVM_checkService(opts)              { MVM_exec("checkservice_vlanmgr",  null,        opts); }
function MVM_collectClients(opts)            { MVM_exec("collectclients_vlanmgr",null,        opts); }

/* Usage examples:
 *   MVM_sync();                                   // overlay + 5s wait (default)
 *   MVM_sync({ loading: true, waitSec: 30 });      // heavy job, longer wait
 *   MVM_checkService({ loading: false, waitSec: 0 }); // quick status, no overlay
 */

// Optional policy map: entries default to no overlay + instant completion
var MVM_NO_LOADING = {
  checkservice_vlanmgr: true,
  collectclients_vlanmgr: true
};

// Policy-aware entry point: merges defaults with per-call overrides
function MVM_execPolicy(actionScriptName, settingsObjOrNull, overrideOpts) {
  var noLoad = !!MVM_NO_LOADING[actionScriptName];
  var defaults = {
    loading: !noLoad,
    waitSec: noLoad ? 0 : 5,
    target: "hidden_frame"
  };

  if (overrideOpts) {
    if (Object.prototype.hasOwnProperty.call(overrideOpts, "loading")) {
      defaults.loading = overrideOpts.loading;
    }
    if (Object.prototype.hasOwnProperty.call(overrideOpts, "waitSec")) {
      defaults.waitSec = overrideOpts.waitSec;
    }
    if (Object.prototype.hasOwnProperty.call(overrideOpts, "target")) {
      defaults.target = overrideOpts.target;
    }
  }

  MVM_exec(actionScriptName, settingsObjOrNull, defaults);
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