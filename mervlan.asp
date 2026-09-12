<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <!-- mervlan.asp version="0.57" -->
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
var MVM_WEB_LOAD_NONCE = (typeof Date.now === "function" ? Date.now().toString(36) : String(new Date().getTime())) + "-" + Math.random().toString(36).slice(2, 7);
var _mvmRefreshGuard = {
  count: 0,
  refresh_self: undefined,
  redirect_self: undefined,
  refresh_parent: undefined,
  redirect_parent: undefined
};

function _mvmRestoreFunction(target, key, value) {
  if (!target) return;
  try {
    if (typeof value !== "undefined") target[key] = value;
    else delete target[key];
  } catch (e) {
    try { target[key] = value; } catch (e2) {}
  }
}

function mvmAcquireRefreshGuard() {
  if (_mvmRefreshGuard.count === 0) {
    _mvmRefreshGuard.refresh_self = (typeof window.refreshpage !== "undefined") ? window.refreshpage : undefined;
    _mvmRefreshGuard.redirect_self = (typeof window.redirect_page !== "undefined") ? window.redirect_page : undefined;
    _mvmRefreshGuard.refresh_parent = (window.parent && window.parent !== window && typeof window.parent.refreshpage !== "undefined") ? window.parent.refreshpage : undefined;
    _mvmRefreshGuard.redirect_parent = (window.parent && window.parent !== window && typeof window.parent.redirect_page !== "undefined") ? window.parent.redirect_page : undefined;
  }
  _mvmRefreshGuard.count++;
  window.refreshpage = function() {};
  window.redirect_page = function() {};
  if (window.parent && window.parent !== window) {
    try { window.parent.refreshpage = function() {}; } catch (e) {}
    try { window.parent.redirect_page = function() {}; } catch (e2) {}
  }
}

function mvmReleaseRefreshGuard() {
  if (_mvmRefreshGuard.count <= 0) return;
  _mvmRefreshGuard.count--;
  if (_mvmRefreshGuard.count !== 0) return;
  _mvmRestoreFunction(window, "refreshpage", _mvmRefreshGuard.refresh_self);
  _mvmRestoreFunction(window, "redirect_page", _mvmRefreshGuard.redirect_self);
  if (window.parent && window.parent !== window) {
    try { _mvmRestoreFunction(window.parent, "refreshpage", _mvmRefreshGuard.refresh_parent); } catch (e) {}
    try { _mvmRestoreFunction(window.parent, "redirect_page", _mvmRefreshGuard.redirect_parent); } catch (e2) {}
  }
  _mvmRefreshGuard.refresh_self = undefined;
  _mvmRefreshGuard.redirect_self = undefined;
  _mvmRefreshGuard.refresh_parent = undefined;
  _mvmRefreshGuard.redirect_parent = undefined;
}

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

</script>

<script type="text/javascript">

/* Request-owned ASUS start_apply transport.  A request owns its form, its
 * response frame, its callbacks, and its cleanup.  The Promise settles on a
 * transport event only; backend completion is reported separately by the
 * correlated progress/ack files in the embedded WebUI. */
function _mvmRequestId() {
  var stamp = (typeof Date.now === "function") ? Date.now().toString(36) : String(new Date().getTime());
  var random = Math.random().toString(36).slice(2, 8);
  return "tx" + stamp + random;
}

function _mvmLog(requestId, message) {
  if (window.console && typeof console.log === "function") {
    console.log("[MVM tx " + requestId + "] " + message);
  }
}

function _mvmCopyFormField(form, sourceField) {
  if (!sourceField || !sourceField.name) return;
  var field = document.createElement("input");
  field.type = "hidden";
  field.name = sourceField.name;
  field.value = typeof sourceField.value === "string" ? sourceField.value : "";
  form.appendChild(field);
}

function _mvmRequestField(form, name, value) {
  var field = form.elements[name];
  if (!field) {
    field = document.createElement("input");
    field.type = "hidden";
    field.name = name;
    form.appendChild(field);
  }
  field.value = String(value == null ? "" : value);
  return field;
}

function _mvmPrepareAction(actionName, settingsObjOrNull, opts) {
  opts = opts || {};
  var baseAction = String(actionName || "");
  var encodedAction = baseAction;
  var payload = settingsObjOrNull;
  var progressToken = (typeof opts.progressToken === "string") ? opts.progressToken : "";
  var selectedNodeSlots = "";

  if (Object.prototype.hasOwnProperty.call(opts, "nodeSlots")) {
    selectedNodeSlots = (typeof opts.nodeSlots === "string") ? opts.nodeSlots : "";
    var slotParts = selectedNodeSlots.split(".");
    var seenSlot = {};
    var slotsValid = baseAction === "sshtrustprobe_vlanmgr" && !!progressToken &&
      /^[1-9][0-9]*(?:\.[1-9][0-9]*)*$/.test(selectedNodeSlots);
    for (var slotIndex = 0; slotsValid && slotIndex < slotParts.length; slotIndex++) {
      var slotNumber = Number(slotParts[slotIndex]);
      if (!Number.isInteger(slotNumber) || slotNumber < 1 || slotNumber > 10 || seenSlot[slotNumber]) {
        slotsValid = false;
      } else {
        seenSlot[slotNumber] = true;
      }
    }
    if (!slotsValid) return { accepted: false, transportState: "submit-error", error: "invalid-node-selection" };
  }

  if (progressToken) {
    if (!/^[A-Za-z0-9._-]{1,96}$/.test(progressToken) || typeof opts.rawAmng === "string") {
      return { accepted: false, transportState: "submit-error", error: "invalid-progress-token" };
    }
    var progressPayload = {};
    if (payload && typeof payload === "object" && !Array.isArray(payload)) {
      Object.keys(payload).forEach(function(key) { progressPayload[key] = payload[key]; });
    }
    progressPayload.vlanmgr_progress_token = progressToken;
    payload = progressPayload;
    if (typeof MVM_ALLOWED_ACTIONS !== "undefined" && MVM_ALLOWED_ACTIONS.has(baseAction)) {
      var progressTokenHex = "";
      for (var pti = 0; pti < progressToken.length; pti++) {
        progressTokenHex += ("0" + progressToken.charCodeAt(pti).toString(16)).slice(-2);
      }
      encodedAction = baseAction + "_pgt_" + progressTokenHex;
      if (selectedNodeSlots) encodedAction += "_nsl_" + selectedNodeSlots;
    }
  }

  var isEncodedUpdateRef = /^updateref_vlanmgr_(?:[kc]_)?[ht]_[0-9a-f]+$/.test(encodedAction);
  var isMaintenanceAction = /^(backupinventory_vlanmgr|deleteallbackups_vlanmgr|undorestore_vlanmgr|undoupdate_vlanmgr)_[0-9a-f]+$/.test(encodedAction) ||
    /^manualbackup_vlanmgr_[0-9a-f]+_[0-9a-f]+$/.test(encodedAction) ||
    /^(deletebackup_vlanmgr|restorebackup_vlanmgr)_[0-9a-f]+_[am]\.[A-Za-z0-9._-]+$/.test(encodedAction);
  var verifiedActionMatch = /^(.+)_vrt_([0-9a-f]+)$/.exec(encodedAction);
  var isVerifiedAction = !!(verifiedActionMatch && typeof MVM_ALLOWED_ACTIONS !== "undefined" && MVM_ALLOWED_ACTIONS.has(verifiedActionMatch[1]));
  var progressActionMatch = /^(.+)_pgt_([0-9a-f]+)(?:_nsl_([1-9][0-9]*(?:\.[1-9][0-9]*)*))?$/.exec(encodedAction);
  var isProgressAction = !!(progressActionMatch && typeof MVM_ALLOWED_ACTIONS !== "undefined" &&
    MVM_ALLOWED_ACTIONS.has(progressActionMatch[1]) &&
    (!progressActionMatch[3] || progressActionMatch[1] === "sshtrustprobe_vlanmgr"));
  // Developer Tools is deliberately a closed transport family.  The handler
  // still authenticates the installed dev marker and MAIN identity; this
  // client-side check only prevents the generic parent transport from
  // accepting arbitrary dynamic action names.
  var isDevToolsAction = /^devtools_vlanmgr_(?:status|cronenable|crondisable)_rid_[a-z0-9-]+$/.test(encodedAction) ||
    /^devtools_vlanmgr_selftest_(?!all_rid_)[a-z0-9-]+_rid_[a-z0-9-]+$/.test(encodedAction);
  if (encodedAction.length > 120 ||
      (typeof MVM_ALLOWED_ACTIONS !== "undefined" && !MVM_ALLOWED_ACTIONS.has(encodedAction) &&
       !isEncodedUpdateRef && !isMaintenanceAction && !isVerifiedAction && !isProgressAction && !isDevToolsAction)) {
    return { accepted: false, transportState: "submit-error", error: "disallowed-action" };
  }
  var now = (typeof Date.now === "function") ? Date.now() : new Date().getTime();
  if (_mvmLast.name === encodedAction && (now - _mvmLast.t) < 2000) {
    return { accepted: false, transportState: "submit-error", error: "deduplicated" };
  }
  _mvmLast = { name: encodedAction, t: now };
  return { accepted: true, action: baseAction, encodedAction: encodedAction, payload: payload, progressToken: progressToken };
}

function MVM_execAsync(actionScriptName, settingsObjOrNull, opts) {
  opts = opts || {};
  var prepared = _mvmPrepareAction(actionScriptName, settingsObjOrNull, opts);
  var requestId = _mvmRequestId();
  var requestAccepted = !!prepared.accepted && !!document.body && !!(document.forms["form"] || document.form);
  var promise = new Promise(function(resolve) {
    if (!prepared.accepted) {
      if (window.console && typeof console.warn === "function") console.warn("[MVM tx " + requestId + "] rejected " + prepared.error);
      resolve({ accepted: false, requestId: requestId, action: String(actionScriptName || ""), encodedAction: String(actionScriptName || ""), transportState: prepared.transportState || "submit-error", error: prepared.error });
      return;
    }
    var sourceForm = document.forms["form"] || document.form;
    if (!sourceForm || !document.body) {
      resolve({ accepted: false, requestId: requestId, action: prepared.action, encodedAction: prepared.encodedAction, transportState: "missing-frame", error: "missing-parent-form" });
      return;
    }
    var frame = document.createElement("iframe");
    var form = document.createElement("form");
    var frameId = "mvm_action_frame_" + requestId;
    var formId = "mvm_action_form_" + requestId;
    frame.id = frameId; frame.name = frameId;
    frame.width = "0"; frame.height = "0"; frame.frameBorder = "0";
    frame.style.display = "none";
    form.id = formId; form.name = formId; form.method = "post";
    form.action = sourceForm.action || "start_apply.htm"; form.target = frameId;
    form.style.display = "none";
    for (var fieldIndex = 0; fieldIndex < sourceForm.elements.length; fieldIndex++) {
      var sourceField = sourceForm.elements[fieldIndex];
      if (sourceField.name === "amng_custom") continue;
      _mvmCopyFormField(form, sourceField);
    }
    _mvmRequestField(form, "action_script", prepared.encodedAction);
    _mvmRequestField(form, "action_mode", "apply");
    _mvmRequestField(form, "action_wait", opts.waitSec != null ? opts.waitSec : 5);
    var amng = _mvmRequestField(form, "amng_custom", "");
    if (typeof opts.rawAmng === "string") amng.value = opts.rawAmng;
    else if (prepared.payload != null) {
      try { amng.value = JSON.stringify(prepared.payload); }
      catch (payloadError) {
        resolve({ accepted: false, requestId: requestId, action: prepared.action, encodedAction: prepared.encodedAction, transportState: "submit-error", error: "payload-encode-error" });
        return;
      }
    }
    var skipRefresh = !!opts.skipRefresh;
    var wantLoading = opts.loading !== false;
    var minLoadingMs = opts.minLoadingMs != null ? opts.minLoadingMs : 0;
    var submitted = false;
    var initialLoadPending = true;
    var finalized = false;
    var timer = null;
    var initialLoadSeen = false;
    var frameTimeoutMs = (typeof opts.frameTimeoutMs === "number" && opts.frameTimeoutMs > 0) ? Math.min(opts.frameTimeoutMs, 60000) : 15000;

    function cleanup() {
      if (timer !== null) { clearTimeout(timer); timer = null; }
      if (frame.removeEventListener) { frame.removeEventListener("load", onLoad); frame.removeEventListener("error", onError); }
      if (frame.parentNode) frame.parentNode.removeChild(frame);
      if (form.parentNode) form.parentNode.removeChild(form);
      if (skipRefresh) mvmReleaseRefreshGuard();
      _mvmLog(requestId, "cleanup form=" + formId + " frame=" + frameId);
    }
    function finalize(state) {
      if (finalized) return;
      finalized = true;
      if (state !== "load" && window.console && typeof console.warn === "function") console.warn("[MVM tx " + requestId + "] transport=" + state);
      if (minLoadingMs > 0 && typeof window._mvmHoldLoadingFor === "function") {
        window._mvmHoldLoadingFor(minLoadingMs);
        window.setTimeout(hideLoadingSafe, minLoadingMs);
      } else {
        hideLoadingSafe();
      }
      if (prepared.progressToken) {
        try {
          var progressFrame = document.getElementById("vlan_iframe");
          if (progressFrame && progressFrame.contentWindow) progressFrame.contentWindow.postMessage({
            source: "mervlan", type: "mervlan-action-transport", token: prepared.progressToken,
            action: prepared.encodedAction, state: state, requestId: requestId
          }, "*");
        } catch (e) {}
      }
      _mvmLog(requestId, "transport=" + state + " action=" + prepared.action + " encoded=" + prepared.encodedAction);
      cleanup();
      resolve({ accepted: true, requestId: requestId, action: prepared.action, encodedAction: prepared.encodedAction, transportState: state });
    }
    function onLoad() {
      if (!submitted) { initialLoadSeen = true; initialLoadPending = false; _mvmLog(requestId, "initial-about-blank-load"); return; }
      if (initialLoadPending) { initialLoadPending = false; _mvmLog(requestId, "ignored-initial-load-after-submit"); return; }
      finalize("load");
    }
    function onError() { finalize("error"); }
    if (frame.addEventListener) { frame.addEventListener("load", onLoad); frame.addEventListener("error", onError); }
    document.body.appendChild(frame);
    frame.src = "about:blank";
    document.body.appendChild(form);
    _mvmLog(requestId, "create action=" + prepared.action + " encoded=" + prepared.encodedAction + " form=" + formId + " frame=" + frameId);
    if (skipRefresh) mvmAcquireRefreshGuard();
    if (minLoadingMs > 0 && typeof window._mvmHoldLoadingFor === "function") window._mvmHoldLoadingFor(minLoadingMs);
    if (wantLoading) showLoadingSafe(minLoadingMs > 0 ? Math.ceil(minLoadingMs / 1000) : 30); else hideLoadingSafe();
    window.setTimeout(function() {
      if (finalized) return;
      try {
        submitted = true;
        if (!initialLoadSeen) initialLoadPending = true;
        _mvmLog(requestId, "submit frame=" + frameId);
        form.submit();
        timer = window.setTimeout(function() { finalize("timeout"); }, frameTimeoutMs);
      } catch (submitError) { finalize("submit-error"); }
    }, 0);
  });
  promise.accepted = requestAccepted;
  promise.requestId = requestId;
  return promise;
}

function MVM_exec(actionScriptName, settingsObjOrNull, opts) {
  var request = MVM_execAsync(actionScriptName, settingsObjOrNull, opts || {});
  return request.accepted !== false;
}
</script>

<script type="text/javascript">
/* === Policy lines you edit === */
const MVM_NO_REFRESH = new Set([
  // Actions that must NOT refresh the page after running:
  "save_vlanmgr",
  "collectclients_vlanmgr",
  "clearclilog_vlanmgr",
  "sync_vlanmgr",
  "syncsettings_vlanmgr",
  "apply_vlanmgr",
  "executenodes_vlanmgr",
  "executenodesonly_vlanmgr",
  "genkey_vlanmgr",
  "update_vlanmgr",
  "updatedev_vlanmgr",
  "updaterelease_vlanmgr",
  "repairmain_vlanmgr",
  "repairdev_vlanmgr",
  "enableservice_vlanmgr",
  "disableservice_vlanmgr",
  "checkservice_vlanmgr",
  "hwprobe_vlanmgr",
  "macrefresh_vlanmgr",
  "macclientmeta_vlanmgr",
  "sshtrustprobe_vlanmgr",
  "sshtrustenroll_vlanmgr",
  "sshtrustresume_vlanmgr",
  "sshtruststatus_vlanmgr",
  "sshtrustrevoke_vlanmgr",
  "sshtrustabort_vlanmgr"
]);

const MVM_NO_LOADING = new Set([
  // Actions that should NOT show the loading overlay:
  // Service status is a read-only diagnostic; keep the ASUS overlay hidden.
  "checkservice_vlanmgr",
  // The client refresh owns a MerVLAN panel, so suppress ASUS's overlay.
  "collectclients_vlanmgr",
  // MerVLAN owns the long-running progress panel for these actions.
  "apply_vlanmgr",
  "executenodes_vlanmgr",
  "executenodesonly_vlanmgr",
  "sync_vlanmgr",
  "syncsettings_vlanmgr",
  "hwprobe_vlanmgr",
  "macclientmeta_vlanmgr",
  "macrefresh_vlanmgr",
  "genkey_vlanmgr",
  "clearclilog_vlanmgr",
  "update_vlanmgr",
  "updatedev_vlanmgr",
  "updaterelease_vlanmgr",
  "repairmain_vlanmgr",
  "repairdev_vlanmgr",
  "sshtrustprobe_vlanmgr",
  "sshtrustenroll_vlanmgr",
  "sshtrustresume_vlanmgr",
  "sshtruststatus_vlanmgr",
  "sshtrustrevoke_vlanmgr",
  "sshtrustabort_vlanmgr"
]);

const MVM_ALLOWED_ACTIONS = new Set([
  "save_vlanmgr",
  "apply_vlanmgr",
  "sync_vlanmgr",
  "syncsettings_vlanmgr",
  "executenodes_vlanmgr",
  "executenodesonly_vlanmgr",
  "genkey_vlanmgr",
  "enableservice_vlanmgr",
  "disableservice_vlanmgr",
  "checkservice_vlanmgr",
  "collectclients_vlanmgr",
  "clearclilog_vlanmgr",
  "update_vlanmgr",
  "updatedev_vlanmgr",
  "updaterelease_vlanmgr",
  "repairmain_vlanmgr",
  "repairdev_vlanmgr",
  "hwprobe_vlanmgr",
  "macrefresh_vlanmgr",
  "macclientmeta_vlanmgr",
  "sshtrustprobe_vlanmgr",
  "sshtrustenroll_vlanmgr",
  "sshtrustresume_vlanmgr",
  "sshtruststatus_vlanmgr",
  "sshtrustrevoke_vlanmgr",
  "sshtrustabort_vlanmgr"
]);

// Optional: actions that need a longer/shorter wait (seconds)
const MVM_WAIT_OVERRIDE = {
  // "save_vlanmgr": 5000
  // "sync_vlanmgr": 30,
  // "apply_vlanmgr": 20,
};

// Optional: actions that need a minimum loading screen time (milliseconds)
const MVM_MIN_LOADING_MS = {
  "save_vlanmgr": 8000,  // Show loading for at least 8s to allow clear+reload verification
  "hwprobe_vlanmgr": 8000  // Show loading for at least 8s while hw_probe runs
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
    if ("rawAmng" in overrideOpts)     opts.rawAmng = overrideOpts.rawAmng;
    if ("progressToken" in overrideOpts) opts.progressToken = overrideOpts.progressToken;
    if ("nodeSlots" in overrideOpts) opts.nodeSlots = overrideOpts.nodeSlots;
  }
  return opts;
}

/* === Wrapper helpers (policy-aware) ===
   You keep calling these from your buttons,
   and you ONLY edit the sets/maps above. */
function MVM_save(settingsObj, opts)         { return MVM_exec("save_vlanmgr",          settingsObj, mvmOptsFor("save_vlanmgr",          opts)); }
function MVM_saveAsync(settingsObj, opts)     { return MVM_execAsync("save_vlanmgr",      settingsObj, mvmOptsFor("save_vlanmgr",      opts)); }
function MVM_trigger(actionScriptName, opts) { return MVM_exec(actionScriptName,        null,        mvmOptsFor(actionScriptName,        opts)); }
function MVM_triggerAsync(actionScriptName, opts) { return MVM_execAsync(actionScriptName, null, mvmOptsFor(actionScriptName, opts)); }
function MVM_triggerVerified(actionScriptName, requestToken, payload, opts) {
  var verifiedPayload = {};
  var sourcePayload = (payload && typeof payload === "object") ? payload : {};
  Object.keys(sourcePayload).forEach(function(key) {
    verifiedPayload[key] = sourcePayload[key];
  });
  var safeToken = String(requestToken || "");
  if (!safeToken || !/^[A-Za-z0-9._-]+$/.test(safeToken)) return false;
  // Carry the correlation token in the event name. custom_settings.txt remains
  // a compatibility payload only; action completion no longer depends on it.
  verifiedPayload.vlanmgr_action_request_token = safeToken;
  var tokenHex = "";
  for (var i = 0; i < safeToken.length; i++) {
    tokenHex += ("0" + safeToken.charCodeAt(i).toString(16)).slice(-2);
  }
  var verifiedActionName = actionScriptName + "_vrt_" + tokenHex;
  return MVM_exec(verifiedActionName, verifiedPayload, mvmOptsFor(actionScriptName, opts));
}
function MVM_triggerVerifiedAsync(actionScriptName, requestToken, payload, opts) {
  var verifiedPayload = {};
  var sourcePayload = (payload && typeof payload === "object") ? payload : {};
  Object.keys(sourcePayload).forEach(function(key) { verifiedPayload[key] = sourcePayload[key]; });
  var safeToken = String(requestToken || "");
  if (!safeToken || !/^[A-Za-z0-9._-]+$/.test(safeToken)) return Promise.resolve({ accepted: false, transportState: "submit-error", error: "invalid-request-token" });
  verifiedPayload.vlanmgr_action_request_token = safeToken;
  var tokenHex = "";
  for (var i = 0; i < safeToken.length; i++) tokenHex += ("0" + safeToken.charCodeAt(i).toString(16)).slice(-2);
  var verifiedActionName = actionScriptName + "_vrt_" + tokenHex;
  return MVM_execAsync(verifiedActionName, verifiedPayload, mvmOptsFor(actionScriptName, opts));
}
function MVM_apply(opts)                     { return MVM_exec("apply_vlanmgr",         null,        mvmOptsFor("apply_vlanmgr",         opts)); }
function MVM_sync(opts)                      { return MVM_exec("sync_vlanmgr",          null,        mvmOptsFor("sync_vlanmgr",          opts)); }
function MVM_executeNodes(opts)              { return MVM_exec("executenodes_vlanmgr",  null,        mvmOptsFor("executenodes_vlanmgr",  opts)); }
function MVM_executeNodesOnly(opts)          { return MVM_exec("executenodesonly_vlanmgr",  null,        mvmOptsFor("executenodesonly_vlanmgr",  opts)); }
function MVM_genkey(opts)                    { return MVM_exec("genkey_vlanmgr",        null,        mvmOptsFor("genkey_vlanmgr",        opts)); }
function MVM_enableService(opts)             { return MVM_exec("enableservice_vlanmgr", null,        mvmOptsFor("enableservice_vlanmgr", opts)); }
function MVM_disableService(opts)            { return MVM_exec("disableservice_vlanmgr",null,        mvmOptsFor("disableservice_vlanmgr",opts)); }
function MVM_checkService(opts)              { return MVM_exec("checkservice_vlanmgr",  null,        mvmOptsFor("checkservice_vlanmgr",  opts)); }
function MVM_collectClients(opts)            { return MVM_exec("collectclients_vlanmgr",null,        mvmOptsFor("collectclients_vlanmgr",opts)); }
function MVM_clearCliLog(opts)               { return MVM_exec("clearclilog_vlanmgr",   null,        mvmOptsFor("clearclilog_vlanmgr",   opts)); }
function MVM_update(opts)                    { return MVM_exec("update_vlanmgr",        null,        mvmOptsFor("update_vlanmgr",        opts)); }
function MVM_updateDev(opts)                 { return MVM_exec("updatedev_vlanmgr",     null,        mvmOptsFor("updatedev_vlanmgr",     opts)); }
// Ref-based updates intentionally use the legacy development update event.
// Older installed service-event handlers already understand this event; the
// updater consumes vlanmgr_update_ref and replaces the fallback "dev" target.
function MVM_updateRelease(ref, opts)        { return MVM_updateRef(ref, "keep", opts); }
function MVM_updateRef(ref, logPolicy, opts) {
  // Backward-compatible two-argument form: MVM_updateRef(ref, opts).
  if (logPolicy && typeof logPolicy === "object") {
    opts = logPolicy;
    logPolicy = "keep";
  }
  logPolicy = logPolicy === "clear" ? "clear" : "keep";
  var value = String(ref || "");
  if (value.length > 80) return false;
  var kind = "";
  var name = "";
  if (value.indexOf("refs/heads/") === 0) {
    kind = "h";
    name = value.slice(11);
  } else if (value.indexOf("refs/tags/") === 0) {
    kind = "t";
    name = value.slice(10);
  }
  if (!kind || !name || !/^[A-Za-z0-9][A-Za-z0-9._\/-]*[A-Za-z0-9]$|^[A-Za-z0-9]$/.test(name)) {
    return false;
  }
  if (name.indexOf("//") !== -1 || name.indexOf("..") !== -1 || name.slice(-5) === ".lock") {
    return false;
  }
  if (name.length > 40) return false;
  var hex = "";
  for (var i = 0; i < name.length; i++) {
    var code = name.charCodeAt(i);
    if (code > 127) return false;
    hex += ("0" + code.toString(16)).slice(-2);
  }
  var actionName = "updateref_vlanmgr_" + (logPolicy === "clear" ? "c" : "k") + "_" + kind + "_" + hex;
  if (actionName.length > 120) return false;
  var actionOpts = { loading: false, skipRefresh: true, waitSec: 0, minLoadingMs: 0, target: "hidden_frame" };
  if (opts && typeof opts === "object") {
    Object.keys(opts).forEach(function(key) { actionOpts[key] = opts[key]; });
  }
  return MVM_exec(actionName, null, actionOpts);
}
function MVM_hexAscii(value) {
  value = String(value || "");
  if (!value) return "";
  var hex = "";
  for (var i = 0; i < value.length; i++) {
    var code = value.charCodeAt(i);
    if (code > 127) return "";
    hex += ("0" + code.toString(16)).slice(-2);
  }
  return hex;
}
function MVM_maintenanceAction(base, requestToken, payload, opts) {
  var token = String(requestToken || "");
  if (!/^[A-Za-z0-9._-]{1,32}$/.test(token)) return false;
  var tokenHex = MVM_hexAscii(token);
  if (!tokenHex) return false;
  var actionName = base + "_" + tokenHex;
  if (payload !== null && typeof payload !== "undefined") {
    var payloadHex = MVM_hexAscii(String(payload));
    if (!payloadHex) return false;
    actionName += "_" + payloadHex;
  }
  if (actionName.length > 120) return false;
  var actionOpts = { loading: false, skipRefresh: true, waitSec: 0, minLoadingMs: 0, target: "hidden_frame" };
  if (opts && typeof opts === "object") {
    Object.keys(opts).forEach(function(key) { actionOpts[key] = opts[key]; });
  }
  return MVM_exec(actionName, null, actionOpts);
}
function MVM_backupArchiveKey(archiveId) {
  var id = String(archiveId || "");
  var match = /^mervlan\.backup\.([0-9]{8}-[0-9]{6}(?:-[0-9]+)?)\.tar\.gz$/.exec(id);
  if (match) return "a." + match[1];
  match = /^mervlan\.manual\.backup\.([0-9]{8}-[0-9]{6})\.([A-Za-z0-9][A-Za-z0-9_-]{0,23})\.tar\.gz$/.exec(id);
  if (match) return "m." + match[1] + "." + match[2];
  return "";
}
function MVM_archiveMaintenanceAction(base, requestToken, archiveId, opts) {
  var token = String(requestToken || "");
  if (!/^[A-Za-z0-9._-]{1,32}$/.test(token)) return false;
  var tokenHex = MVM_hexAscii(token);
  var archiveKey = MVM_backupArchiveKey(archiveId);
  if (!tokenHex || !archiveKey) return false;
  var actionName = base + "_" + tokenHex + "_" + archiveKey;
  if (actionName.length > 120) return false;
  var actionOpts = { loading: false, skipRefresh: true, waitSec: 0, minLoadingMs: 0, target: "hidden_frame" };
  if (opts && typeof opts === "object") {
    Object.keys(opts).forEach(function(key) { actionOpts[key] = opts[key]; });
  }
  return MVM_exec(actionName, null, actionOpts);
}
function MVM_listBackups(requestToken, opts) {
  return MVM_maintenanceAction("backupinventory_vlanmgr", requestToken, null, opts);
}
function MVM_createBackup(requestToken, tag, opts) {
  tag = String(tag || "");
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,23}$/.test(tag)) return false;
  return MVM_maintenanceAction("manualbackup_vlanmgr", requestToken, tag, opts);
}
function MVM_deleteBackup(requestToken, archiveId, opts) {
  return MVM_archiveMaintenanceAction("deletebackup_vlanmgr", requestToken, archiveId, opts);
}
function MVM_deleteAllBackups(requestToken, opts) {
  return MVM_maintenanceAction("deleteallbackups_vlanmgr", requestToken, null, opts);
}
function MVM_restoreBackup(requestToken, archiveId, opts) {
  return MVM_archiveMaintenanceAction("restorebackup_vlanmgr", requestToken, archiveId, opts);
}
function MVM_undoRestore(requestToken, opts) {
  return MVM_maintenanceAction("undorestore_vlanmgr", requestToken, null, opts);
}
function MVM_undoUpdate(requestToken, opts) {
  return MVM_maintenanceAction("undoupdate_vlanmgr", requestToken, null, opts);
}
function MVM_hwprobe(opts) {
  opts = opts || {};
  var payload = (opts.payload && typeof opts.payload === "object") ? opts.payload : null;
  var execOpts = {};
  Object.keys(opts).forEach(function(key) {
    if (key !== "payload") execOpts[key] = opts[key];
  });
  return MVM_exec("hwprobe_vlanmgr", payload, mvmOptsFor("hwprobe_vlanmgr", execOpts));
}
function MVM_hwprobeAsync(opts) {
  opts = opts || {};
  var payload = (opts.payload && typeof opts.payload === "object") ? opts.payload : null;
  var execOpts = {};
  Object.keys(opts).forEach(function(key) { if (key !== "payload") execOpts[key] = opts[key]; });
  return MVM_execAsync("hwprobe_vlanmgr", payload, mvmOptsFor("hwprobe_vlanmgr", execOpts));
}
function MVM_macRefresh(opts)                 { return MVM_exec("macrefresh_vlanmgr",    null,        mvmOptsFor("macrefresh_vlanmgr",    opts)); }
function MVM_macClientMeta(opts) {
  // The embedded client-metadata editor owns its progress panel.  In addition
  // to the policy-set guard, force the parent transport to avoid its generic
  // ASUS loader and its minimum-loader hold for this action.
  var actionOpts = mvmOptsFor("macclientmeta_vlanmgr", opts);
  actionOpts.loading = false;
  actionOpts.skipRefresh = true;
  actionOpts.waitSec = 0;
  actionOpts.minLoadingMs = 0;
  return MVM_exec("macclientmeta_vlanmgr", null, actionOpts);
}

// Convenience helper for silent saves invoked from the embedded SPA
function MVM_save_quiet(settingsObj) {
  // A silent caller must also override save_vlanmgr's generic minimum loader
  // hold; otherwise the ASUS overlay remains visible despite loading:false.
  return MVM_save(settingsObj, { loading: false, waitSec: 0, skipRefresh: true, minLoadingMs: 0 });
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

            <!-- THE IFRAME (AUTO-RESIZED BY JS; TALL VALUE IS EMERGENCY FALLBACK ONLY) -->
            <iframe
              id="vlan_iframe"
              src="about:blank"
              style="
                width:100%;
                height:1750px;
                border:0;
                background:transparent;
                overflow:hidden;
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

              f.src = "/user/mervlan/index.html?mvm_load=" + encodeURIComponent(MVM_WEB_LOAD_NONCE);
              if (window.console && typeof console.log === "function") console.log("[MerVLAN] Web load: " + MVM_WEB_LOAD_NONCE);

              function apply(){
                try{
                  f.setAttribute("scrolling","no");
                  f.style.overflow = "hidden";
                  f.style.display = "block";
                  // height is owned by MVM_resizeVlanIframe; do not reset it here
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

            var MVM_IFRAME_FALLBACK_HEIGHT = 1750;
            var MVM_IFRAME_MIN_HEIGHT = 500;
            var MVM_IFRAME_MAX_HEIGHT = 5000;
            var MVM_IFRAME_PADDING = 24;

            function MVM_resizeVlanIframe(contentHeight) {
              var f = document.getElementById("vlan_iframe");
              if (!f) return;
              var h = parseInt(contentHeight, 10);
              if (!h || h < 1) return;
              var desired = h + MVM_IFRAME_PADDING;
              if (desired < MVM_IFRAME_MIN_HEIGHT) desired = MVM_IFRAME_MIN_HEIGHT;
              if (desired > MVM_IFRAME_MAX_HEIGHT) {
                desired = MVM_IFRAME_MAX_HEIGHT;
                if (window.console && typeof console.warn === "function") {
                  console.warn("[MVM] iframe height clamped", contentHeight, desired);
                }
              }
              var current = parseInt(f.style.height, 10) || f.offsetHeight || MVM_IFRAME_FALLBACK_HEIGHT;
              if (Math.abs(current - desired) < 4) return;
              f.style.height = desired + "px";
            }
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
