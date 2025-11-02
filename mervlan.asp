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
function MVM_exec(actionScriptName, settingsObjOrNull) {
  var amng = document.getElementById("amng_custom");

  if (settingsObjOrNull) {
    if (!amng) {
      alert("amng_custom not found in parent form");
      return;
    }
    amng.value = JSON.stringify(settingsObjOrNull);
  } else if (amng) {
    amng.value = "";
  }

  document.form.action_script.value = actionScriptName;
  document.form.action_mode.value = "apply";
  document.form.action_wait.value = "5";

  if (typeof showLoading === "function") {
    showLoading();
  }

  document.form.submit();
}

function MVM_save(settingsObj) {
  MVM_exec("save_vlanmgr", settingsObj);
}

function MVM_trigger(actionScriptName) {
  MVM_exec(actionScriptName);
}

// Convenience wrappers for service-event actions handled by service-event-handler.sh
function MVM_apply() {             MVM_exec("apply_vlanmgr"); }
function MVM_sync() {              MVM_exec("sync_vlanmgr"); }
function MVM_genkey() {            MVM_exec("genkey_vlanmgr"); }
function MVM_enableService() {     MVM_exec("enableservice_vlanmgr"); }
function MVM_disableService() {    MVM_exec("disableservice_vlanmgr"); }
function MVM_checkService() {      MVM_exec("checkservice_vlanmgr"); }
function MVM_collectClients() {    MVM_exec("collectclients_vlanmgr"); }
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